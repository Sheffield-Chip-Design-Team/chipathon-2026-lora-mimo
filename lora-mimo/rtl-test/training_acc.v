// training_acc.v
// Training accumulator: cross-correlates each branch against a reference branch
// over 8 LoRa symbols after preamble detection.
// TDM: 2 shared 8x8 multipliers, 2 sub-steps per antenna (sub0→zi, sub1→zq),
// then 1 cycle for E_ref. Total active cycles per sample: 9 + 2 drain = 11.
// Budget: iq_valid arrives every ≥20 cycles — fits comfortably.
// Area change: 4 muls → 2 muls (~−17k µm²).
// GF180MCU, 3.3V, 16 MHz clock domain
//
// Accumulator width reduction:
//   Z_i/Z_q: 32 → 31-bit internal. Accumulates over 8×M samples. Max |Z| at
//     SF12 = 8×4096×2×127² = 1057M < 2^30. 31-bit signed holds ±1073M (1 guard bit).
//     Output ports stay 32-bit (sign-extended at commit).
//   E_ref: 64 → 31-bit internal. Same bound. Output port stays 64-bit.
//   weight_gen already clips Z to [17:0]; Z bit-selection fix handled in weight_gen.v.
//   M_full: 32 → 13-bit. Max value 4096 = 2^12.

module signed_mul8_pipe (
    input  wire              clk,
    input  wire signed [7:0] a,
    input  wire signed [7:0] b,
    output reg  signed [15:0] p
);
    always @(posedge clk) p <= a * b;
endmodule

module training_acc (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] raw_i0, raw_i1, raw_i2, raw_i3,
    input  wire signed [7:0] raw_q0, raw_q1, raw_q2, raw_q3,
    input  wire        sc_lock,
    input  wire [31:0] timing_ref,
    input  wire [3:0]  sf,
    input  wire [1:0]  ref_sel,
    input  wire        noise_en,       // 1 = noise-window mode: arm on idle, ref=ant0, fire noise_ready
    output reg  signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    output reg  signed [63:0] E_ref,
    output reg         training_done,
    output reg         noise_ready,    // level: high after noise window completes, until next sc_lock
    output reg  [9:0]  n_acc
);

    // M = 2^sf — max 4096 fits in 13 bits
    reg [12:0] M_full;
    always @(*) begin
        case (sf)
            4'd6:  M_full = 13'd64;
            4'd7:  M_full = 13'd128;
            4'd8:  M_full = 13'd256;
            4'd9:  M_full = 13'd512;
            4'd10: M_full = 13'd1024;
            4'd11: M_full = 13'd2048;
            4'd12: M_full = 13'd4096;
            default: M_full = 13'd128;
        endcase
    end

    reg [31:0] sample_count;
    reg [31:0] acc_start, acc_end;
    reg        armed;
    reg        noise_mode_r;   // 1 = currently running a noise-window accumulation
    reg        noise_done;     // sticky: noise window already fired this idle period

    // Reference branch combinatorial mux
    reg signed [7:0] ref_i, ref_q;
    always @(*) begin
        case (ref_sel)
            2'd0: begin ref_i = raw_i0; ref_q = raw_q0; end
            2'd1: begin ref_i = raw_i1; ref_q = raw_q1; end
            2'd2: begin ref_i = raw_i2; ref_q = raw_q2; end
            default: begin ref_i = raw_i3; ref_q = raw_q3; end
        endcase
    end

    // TDM state: 0=idle, 1-4=antenna 0-3, 5=E_ref
    reg [2:0] tdm_state;
    // sub_step: 0=zi sub-cycle (I×ref_i, Q×ref_q), 1=zq sub-cycle (Q×ref_i, I×ref_q)
    // Only states 1-4 use sub_step=1; state 5 (E_ref) uses sub_step=0 only.
    reg       sub_step;

    // Latched per-sample inputs (captured when iq_valid triggers TDM)
    reg signed [7:0] raw_ir [0:3];
    reg signed [7:0] raw_qr [0:3];
    reg signed [7:0] ref_ir, ref_qr;
    reg              last_samp;  // this sample was acc_end

    // Pipeline operand registers — state decode kept out of the multiplier path.
    reg signed [7:0] op_a_q, op_b_q, op_c_q, op_d_q;
    reg [2:0]        op_state_q;
    reg              op_sub_q;   // sub_step tag for this op
    reg              op_valid_q;
    reg              op_last_q;

    // 2 shared 8x8 multipliers.
    // sub_step=0: a=I×ref_i (→zi partial), b=Q×ref_q (→zi partial)
    // sub_step=1: a=Q×ref_i (→zq partial), b=I×ref_q (→zq partial)
    // state 5:    a=ref_i², b=ref_q²
    wire signed [15:0] mul_0, mul_1;
    signed_mul8_pipe u_mul_0 (.clk(clk), .a(op_a_q), .b(op_b_q), .p(mul_0));
    signed_mul8_pipe u_mul_1 (.clk(clk), .a(op_c_q), .b(op_d_q), .p(mul_1));

    // Combinatorial sum/diff of multiplier outputs.
    // sum_p = zi contribution (sub_step=0) or E_ref contribution (state 5)
    // diff_p = zq contribution (sub_step=1)
    wire signed [15:0] sum_p  = mul_0 + mul_1;
    wire signed [15:0] diff_p = mul_0 - mul_1;

    reg [1:0] mul_valid_pipe;
    reg [2:0] mul_state_0, mul_state_1;
    reg       mul_sub_0, mul_sub_1;
    reg       mul_last_0, mul_last_1;

    // zi intermediate: latched when sub_step=0 product lands; consumed at sub_step=1.
    reg signed [15:0] zi_latch;

    // Narrow internal accumulators — sign-extended to output ports on commit.
    // Max |Z| = 8×4096×2×127² = 1057M < 2^30. 31-bit signed gives 1 guard bit.
    reg signed [30:0] Z_i0_a, Z_q0_a, Z_i1_a, Z_q1_a;
    reg signed [30:0] Z_i2_a, Z_q2_a, Z_i3_a, Z_q3_a;
    reg signed [30:0] E_ref_a;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count  <= 32'd0;
            armed         <= 1'b0;
            training_done <= 1'b0;
            noise_ready   <= 1'b0;
            noise_mode_r  <= 1'b0;
            noise_done    <= 1'b0;
            n_acc         <= 10'd0;
            acc_start     <= 32'd0;
            acc_end       <= 32'd0;
            tdm_state     <= 3'd0;
            sub_step      <= 1'b0;
            last_samp     <= 1'b0;
            raw_ir[0] <= 8'sd0; raw_ir[1] <= 8'sd0; raw_ir[2] <= 8'sd0; raw_ir[3] <= 8'sd0;
            raw_qr[0] <= 8'sd0; raw_qr[1] <= 8'sd0; raw_qr[2] <= 8'sd0; raw_qr[3] <= 8'sd0;
            ref_ir <= 8'sd0; ref_qr <= 8'sd0;
            op_a_q <= 8'sd0; op_b_q <= 8'sd0; op_c_q <= 8'sd0; op_d_q <= 8'sd0;
            op_state_q <= 3'd0; op_sub_q <= 1'b0; op_valid_q <= 1'b0; op_last_q <= 1'b0;
            mul_valid_pipe <= 2'd0;
            mul_state_0 <= 3'd0; mul_state_1 <= 3'd0;
            mul_sub_0 <= 1'b0; mul_sub_1 <= 1'b0;
            mul_last_0 <= 1'b0; mul_last_1 <= 1'b0;
            zi_latch <= 16'sd0;
            Z_i0_a <= 31'sd0; Z_q0_a <= 31'sd0;
            Z_i1_a <= 31'sd0; Z_q1_a <= 31'sd0;
            Z_i2_a <= 31'sd0; Z_q2_a <= 31'sd0;
            Z_i3_a <= 31'sd0; Z_q3_a <= 31'sd0;
            E_ref_a <= 31'sd0;
            Z_i0 <= 32'sd0; Z_q0 <= 32'sd0;
            Z_i1 <= 32'sd0; Z_q1 <= 32'sd0;
            Z_i2 <= 32'sd0; Z_q2 <= 32'sd0;
            Z_i3 <= 32'sd0; Z_q3 <= 32'sd0;
            E_ref <= 64'sd0;
        end else begin
            if (iq_valid)
                sample_count <= sample_count + 32'd1;

            // Arm on sc_lock rising edge (normal training mode)
            if (sc_lock && !armed) begin
                armed         <= 1'b1;
                training_done <= 1'b0;
                noise_ready   <= 1'b0;
                noise_mode_r  <= 1'b0;
                noise_done    <= 1'b0;
                acc_start     <= timing_ref;
                acc_end       <= timing_ref + (32'd1 << (sf[3:0] + 4'd3)) - 32'd1;
                Z_i0_a <= 31'sd0; Z_q0_a <= 31'sd0;
                Z_i1_a <= 31'sd0; Z_q1_a <= 31'sd0;
                Z_i2_a <= 31'sd0; Z_q2_a <= 31'sd0;
                Z_i3_a <= 31'sd0; Z_q3_a <= 31'sd0;
                E_ref_a <= 31'sd0;
                n_acc <= 10'd0;
            end

            // Arm noise-window accumulation when idle and noise_en asserted
            // ref_sel is overridden internally to ant0; uses 8 symbols of free-running samples
            if (noise_en && !sc_lock && !armed && !noise_done) begin
                armed        <= 1'b1;
                noise_mode_r <= 1'b1;
                noise_ready  <= 1'b0;
                training_done <= 1'b0;
                acc_start    <= sample_count + 32'd1;
                acc_end      <= sample_count + (32'd1 << (sf[3:0] + 4'd3));
                Z_i0_a <= 31'sd0; Z_q0_a <= 31'sd0;
                Z_i1_a <= 31'sd0; Z_q1_a <= 31'sd0;
                Z_i2_a <= 31'sd0; Z_q2_a <= 31'sd0;
                Z_i3_a <= 31'sd0; Z_q3_a <= 31'sd0;
                E_ref_a <= 31'sd0;
                n_acc <= 10'd0;
            end

            // Disarm on sc_lock de-assertion (do not disarm mid-noise-window)
            if (!sc_lock && !noise_mode_r) begin
                armed     <= 1'b0;
                tdm_state <= 3'd0;
                sub_step  <= 1'b0;
            end

            // Trigger TDM on iq_valid within window (only when idle)
            if (armed && iq_valid && tdm_state == 3'd0 &&
                sample_count >= acc_start && sample_count <= acc_end &&
                !training_done && !noise_ready) begin
                raw_ir[0] <= raw_i0; raw_qr[0] <= raw_q0;
                raw_ir[1] <= raw_i1; raw_qr[1] <= raw_q1;
                raw_ir[2] <= raw_i2; raw_qr[2] <= raw_q2;
                raw_ir[3] <= raw_i3; raw_qr[3] <= raw_q3;
                ref_ir    <= noise_mode_r ? raw_i0 : ref_i;
                ref_qr    <= noise_mode_r ? raw_q0 : ref_q;
                last_samp <= (sample_count == acc_end);
                if (n_acc < 10'd1023)
                    n_acc <= n_acc + 10'd1;
                tdm_state <= 3'd1;
                sub_step  <= 1'b0;
            end

            // Shift state metadata through the 2-cycle multiplier pipeline.
            mul_valid_pipe <= {mul_valid_pipe[0], op_valid_q};
            mul_state_0 <= op_state_q;  mul_state_1 <= mul_state_0;
            mul_sub_0   <= op_sub_q;    mul_sub_1   <= mul_sub_0;
            mul_last_0  <= op_last_q;   mul_last_1  <= mul_last_0;

            // Accumulate when products land (mul_valid_pipe[1]).
            if (mul_valid_pipe[1]) begin
                if (mul_state_1 <= 3'd4) begin
                    if (mul_sub_1 == 1'b0) begin
                        // zi = I×ref_i + Q×ref_q — latch for use at sub_step 1
                        zi_latch <= sum_p;
                    end else begin
                        // zq = Q×ref_i − I×ref_q — accumulate both zi and zq (28-bit)
                        case (mul_state_1)
                            3'd1: begin
                                Z_i0_a <= Z_i0_a + {{15{zi_latch[15]}}, zi_latch};
                                Z_q0_a <= Z_q0_a + {{12{diff_p[15]}},   diff_p};
                            end
                            3'd2: begin
                                Z_i1_a <= Z_i1_a + {{15{zi_latch[15]}}, zi_latch};
                                Z_q1_a <= Z_q1_a + {{12{diff_p[15]}},   diff_p};
                            end
                            3'd3: begin
                                Z_i2_a <= Z_i2_a + {{15{zi_latch[15]}}, zi_latch};
                                Z_q2_a <= Z_q2_a + {{12{diff_p[15]}},   diff_p};
                            end
                            default: begin
                                Z_i3_a <= Z_i3_a + {{15{zi_latch[15]}}, zi_latch};
                                Z_q3_a <= Z_q3_a + {{12{diff_p[15]}},   diff_p};
                            end
                        endcase
                    end
                end else begin
                    // state 5: E_ref = ref_i² + ref_q² (28-bit accumulator)
                    E_ref_a <= E_ref_a + {{15{sum_p[15]}}, sum_p};
                    if (mul_last_1) begin
                        // Commit narrow accumulators to wide output ports (sign-extend)
                        Z_i0 <= {{4{Z_i0_a[27]}}, Z_i0_a};
                        Z_q0 <= {{4{Z_q0_a[27]}}, Z_q0_a};
                        Z_i1 <= {{4{Z_i1_a[27]}}, Z_i1_a};
                        Z_q1 <= {{4{Z_q1_a[27]}}, Z_q1_a};
                        Z_i2 <= {{4{Z_i2_a[27]}}, Z_i2_a};
                        Z_q2 <= {{4{Z_q2_a[27]}}, Z_q2_a};
                        Z_i3 <= {{4{Z_i3_a[27]}}, Z_i3_a};
                        Z_q3 <= {{4{Z_q3_a[27]}}, Z_q3_a};
                        E_ref <= {{36{E_ref_a[27]}}, E_ref_a};
                        if (noise_mode_r) begin
                            noise_ready  <= 1'b1;
                            noise_done   <= 1'b1;
                            armed        <= 1'b0;
                            noise_mode_r <= 1'b0;
                        end else begin
                            training_done <= 1'b1;
                        end
                    end
                end
            end

            // Select operands and advance TDM state.
            op_valid_q <= 1'b0;
            if ((sc_lock || noise_mode_r) && tdm_state != 3'd0) begin
                op_state_q <= tdm_state;
                op_sub_q   <= sub_step;
                op_last_q  <= last_samp;
                op_valid_q <= 1'b1;

                if (tdm_state <= 3'd4) begin
                    // Antenna states: 2 sub-steps.
                    // sub_step=0: op_a=I×ref_i, op_c=Q×ref_q
                    // sub_step=1: op_a=Q×ref_i, op_c=I×ref_q
                    if (sub_step == 1'b0) begin
                        case (tdm_state)
                            3'd1: begin op_a_q<=raw_ir[0]; op_c_q<=raw_qr[0]; end
                            3'd2: begin op_a_q<=raw_ir[1]; op_c_q<=raw_qr[1]; end
                            3'd3: begin op_a_q<=raw_ir[2]; op_c_q<=raw_qr[2]; end
                            default: begin op_a_q<=raw_ir[3]; op_c_q<=raw_qr[3]; end
                        endcase
                        op_b_q   <= ref_ir;
                        op_d_q   <= ref_qr;
                        sub_step <= 1'b1;
                    end else begin
                        case (tdm_state)
                            3'd1: begin op_a_q<=raw_qr[0]; op_c_q<=raw_ir[0]; end
                            3'd2: begin op_a_q<=raw_qr[1]; op_c_q<=raw_ir[1]; end
                            3'd3: begin op_a_q<=raw_qr[2]; op_c_q<=raw_ir[2]; end
                            default: begin op_a_q<=raw_qr[3]; op_c_q<=raw_ir[3]; end
                        endcase
                        op_b_q    <= ref_ir;
                        op_d_q    <= ref_qr;
                        sub_step  <= 1'b0;
                        tdm_state <= (tdm_state == 3'd4) ? 3'd5 : tdm_state + 3'd1;
                    end
                end else begin
                    // State 5 (E_ref): single sub-step, ref_i² + ref_q²
                    op_a_q    <= ref_ir;  op_b_q <= ref_ir;
                    op_c_q    <= ref_qr;  op_d_q <= ref_qr;
                    tdm_state <= 3'd0;
                end
            end
        end
    end

endmodule
