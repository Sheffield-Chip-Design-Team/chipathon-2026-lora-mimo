// training_acc.v
// Training accumulator: cross-correlates each branch against a reference branch
// over 8 LoRa symbols after preamble detection.
// Single shared 8×8 pipelined multiplier. TDM: ant[1:0] × sub[1:0] = 16 active
// steps. No E_ref (unused in datapath). Total latency: 17 cycles.
// Budget: iq_valid every ≥128 cycles at CIC R=128 — 111 cycles idle.
// GF180MCU, 3.3V, 16 MHz clock domain.
//
// Sub-steps per antenna (sub=0..3):
//   sub=0: I×ref_i  → p_latch
//   sub=1: Q×ref_q  → Z_i_a[ant] += p_latch + mul_out
//   sub=2: Q×ref_i  → p_latch
//   sub=3: I×ref_q  → Z_q_a[ant] += p_latch - mul_out
//          (at ant=3: if last_samp, commit all outputs + assert training_done)
//
// Operand encoding:
//   op_a = (sub[0]^sub[1]) ? raw_qr[ant] : raw_ir[ant]
//   op_b = sub[0]          ? ref_qr      : ref_ir
//
// Accumulator widths:
//   Z_i/Z_q: 31-bit signed. Max |Z| at SF12 = 8×4096×2×127² ≈ 1.06G < 2^30.
//   Output ports 32-bit (sign-extended at commit).

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
    output reg  signed [31:0] Z_i0, Z_q0, Z_i1, Z_q1, Z_i2, Z_q2, Z_i3, Z_q3,
    output reg         training_done,
    output reg  [9:0]  n_acc
);

    reg [31:0] sample_count;
    reg [31:0] acc_start, acc_end;
    reg        armed;

    // Reference branch mux
    reg signed [7:0] ref_i, ref_q;
    always @(*) begin
        case (ref_sel)
            2'd0: begin ref_i = raw_i0; ref_q = raw_q0; end
            2'd1: begin ref_i = raw_i1; ref_q = raw_q1; end
            2'd2: begin ref_i = raw_i2; ref_q = raw_q2; end
            default: begin ref_i = raw_i3; ref_q = raw_q3; end
        endcase
    end

    // TDM counters (drive operand mux combinatorially, registered into op_a/op_b)
    reg [1:0] tdm_ant;
    reg [1:0] tdm_sub;
    reg       tdm_active;

    // 1-cycle delayed tags (synchronised with mul_out)
    reg [1:0] acc_ant;
    reg [1:0] acc_sub;
    reg       acc_active;

    // Latched branch samples and reference (captured at iq_valid trigger)
    reg signed [7:0] raw_ir [0:3];
    reg signed [7:0] raw_qr [0:3];
    reg signed [7:0] ref_ir, ref_qr;
    reg              last_samp;

    // Registered operand inputs → pipelined multiplier
    reg signed [7:0]  op_a, op_b;
    reg signed [15:0] mul_out;
    always @(posedge clk) begin
        op_a   <= (tdm_sub[0] ^ tdm_sub[1]) ? raw_qr[tdm_ant] : raw_ir[tdm_ant];
        op_b   <= tdm_sub[0] ? ref_qr : ref_ir;
        mul_out <= op_a * op_b;
    end

    // Intermediate product latch (holds even-sub product for odd-sub combine)
    reg signed [15:0] p_latch;

    // Internal 31-bit accumulator arrays
    reg signed [30:0] Z_i_a [0:3];
    reg signed [30:0] Z_q_a [0:3];

    // Current-cycle Z_q3 value — used to read the fresh value at the commit step
    wire signed [30:0] z_q_last =
        Z_q_a[3] + {{15{p_latch[15]}}, p_latch} - {{15{mul_out[15]}}, mul_out};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count  <= 32'd0;
            armed         <= 1'b0;
            training_done <= 1'b0;
            n_acc         <= 10'd0;
            acc_start     <= 32'd0;
            acc_end       <= 32'd0;
            tdm_ant       <= 2'd0;
            tdm_sub       <= 2'd0;
            tdm_active    <= 1'b0;
            acc_ant       <= 2'd0;
            acc_sub       <= 2'd0;
            acc_active    <= 1'b0;
            last_samp     <= 1'b0;
            raw_ir[0] <= 8'sd0; raw_ir[1] <= 8'sd0;
            raw_ir[2] <= 8'sd0; raw_ir[3] <= 8'sd0;
            raw_qr[0] <= 8'sd0; raw_qr[1] <= 8'sd0;
            raw_qr[2] <= 8'sd0; raw_qr[3] <= 8'sd0;
            ref_ir <= 8'sd0; ref_qr <= 8'sd0;
            p_latch <= 16'sd0;
            Z_i_a[0] <= 31'sd0; Z_q_a[0] <= 31'sd0;
            Z_i_a[1] <= 31'sd0; Z_q_a[1] <= 31'sd0;
            Z_i_a[2] <= 31'sd0; Z_q_a[2] <= 31'sd0;
            Z_i_a[3] <= 31'sd0; Z_q_a[3] <= 31'sd0;
            Z_i0 <= 32'sd0; Z_q0 <= 32'sd0;
            Z_i1 <= 32'sd0; Z_q1 <= 32'sd0;
            Z_i2 <= 32'sd0; Z_q2 <= 32'sd0;
            Z_i3 <= 32'sd0; Z_q3 <= 32'sd0;
        end else begin
            if (iq_valid)
                sample_count <= sample_count + 32'd1;

            // Disarm when sc_lock deasserts
            if (!sc_lock) begin
                armed      <= 1'b0;
                tdm_active <= 1'b0;
                tdm_ant    <= 2'd0;
                tdm_sub    <= 2'd0;
            end

            // Arm on sc_lock rising edge
            if (sc_lock && !armed) begin
                armed         <= 1'b1;
                training_done <= 1'b0;
                acc_start     <= timing_ref;
                acc_end       <= timing_ref + (32'd1 << (sf[3:0] + 4'd3)) - 32'd1;
                Z_i_a[0] <= 31'sd0; Z_q_a[0] <= 31'sd0;
                Z_i_a[1] <= 31'sd0; Z_q_a[1] <= 31'sd0;
                Z_i_a[2] <= 31'sd0; Z_q_a[2] <= 31'sd0;
                Z_i_a[3] <= 31'sd0; Z_q_a[3] <= 31'sd0;
                n_acc <= 10'd0;
            end

            // Trigger TDM on iq_valid within window when idle
            if (armed && sc_lock && iq_valid && !tdm_active &&
                    sample_count >= acc_start && sample_count <= acc_end &&
                    !training_done) begin
                raw_ir[0] <= raw_i0; raw_qr[0] <= raw_q0;
                raw_ir[1] <= raw_i1; raw_qr[1] <= raw_q1;
                raw_ir[2] <= raw_i2; raw_qr[2] <= raw_q2;
                raw_ir[3] <= raw_i3; raw_qr[3] <= raw_q3;
                ref_ir    <= ref_i;
                ref_qr    <= ref_q;
                last_samp <= (sample_count == acc_end);
                if (n_acc < 10'd1023)
                    n_acc <= n_acc + 10'd1;
                tdm_ant    <= 2'd0;
                tdm_sub    <= 2'd0;
                tdm_active <= 1'b1;
            end else if (tdm_active) begin
                // Advance ant/sub counters
                if (tdm_sub == 2'd3) begin
                    tdm_sub <= 2'd0;
                    if (tdm_ant == 2'd3)
                        tdm_active <= 1'b0;
                    else
                        tdm_ant <= tdm_ant + 2'd1;
                end else
                    tdm_sub <= tdm_sub + 2'd1;
            end

            // Delayed tags track the step whose product is in mul_out
            acc_ant    <= tdm_ant;
            acc_sub    <= tdm_sub;
            acc_active <= tdm_active;

            // Accumulate when product is ready
            if (acc_active) begin
                if (acc_sub[0] == 1'b0) begin
                    // Even sub (0 or 2): latch product
                    p_latch <= mul_out;
                end else if (acc_sub[1] == 1'b0) begin
                    // sub=1: accumulate Z_i
                    Z_i_a[acc_ant] <= Z_i_a[acc_ant]
                        + {{15{p_latch[15]}}, p_latch}
                        + {{15{mul_out[15]}}, mul_out};
                end else begin
                    // sub=3: accumulate Z_q; commit on last sample at ant=3
                    if (acc_ant == 2'd3 && last_samp) begin
                        Z_q_a[3]      <= z_q_last;
                        Z_i0          <= {Z_i_a[0][30], Z_i_a[0]};
                        Z_q0          <= {Z_q_a[0][30], Z_q_a[0]};
                        Z_i1          <= {Z_i_a[1][30], Z_i_a[1]};
                        Z_q1          <= {Z_q_a[1][30], Z_q_a[1]};
                        Z_i2          <= {Z_i_a[2][30], Z_i_a[2]};
                        Z_q2          <= {Z_q_a[2][30], Z_q_a[2]};
                        Z_i3          <= {Z_i_a[3][30], Z_i_a[3]};
                        Z_q3          <= {z_q_last[30], z_q_last};
                        training_done <= 1'b1;
                    end else begin
                        Z_q_a[acc_ant] <= Z_q_a[acc_ant]
                            + {{15{p_latch[15]}}, p_latch}
                            - {{15{mul_out[15]}}, mul_out};
                    end
                end
            end
        end
    end

endmodule
