// sc_detector.v
// Schmidl-Cox preamble detector — NR=2 acquisition (antennas 0 and 1 only)
// Post-lock combining uses all 4 antennas via training_acc independently.
// GF180MCU, 3.3V, 32 MHz single clock domain
//
// Area-reduction changes vs original:
//   signed_mul24_pipe: 5-stage manual partial-product pipeline → 2-stage
//     (input-register + product-register); abc synthesises a compact Wallace
//     tree.  Port width reduced 24→17 bits: accumulator inputs are right-shifted
//     by 6 at symbol boundary so values fit in 16-bit signed; one extra bit of
//     headroom gives the 17-bit port.  eval_valid_pipe 7→3 bits, step delay
//     chain depth 7→3 to match the new 3-cycle latency (1 mux-reg + 2 pipeline).
//     sc_thr firmware value must be divided by 64 vs the original to preserve
//     the same detection threshold (both LHS and RHS of the comparison scale
//     as k² with k = 1/64, so the ratio is invariant but the normalising
//     extraction shifts from [47:24] to [34:18]).
//   Per-sample multipliers: 16 simultaneous combinational 8×8 wires → 1 shared
//     8×8 multiplier, 16-step TDM FSM.  Inputs latched on sample arrival; TDM
//     runs 16 cycles per sample (vs 256-cycle sample window at R=256; even at
//     R=32 the 16-cycle budget fits inside the 32-cycle window).  Saves ~15×
//     8-bit multiplier trees plus associated product registers (~150 k µm²).

/* verilator lint_off DECLFILENAME */
module signed_mul24_pipe (
    input  wire               clk,
    input  wire signed [16:0] a,
    input  wire signed [16:0] b,
    output reg  signed [33:0] p
);
    // 2-stage pipeline: stage 1 registers inputs, stage 2 registers product.
    reg signed [16:0] a_q, b_q;

    always @(posedge clk) begin
        a_q <= a;
        b_q <= b;
        p   <= a_q * b_q;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module sc_detector (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        iq_valid,
    input  wire signed [7:0] cur_i0, cur_i1,
    input  wire signed [7:0] cur_q0, cur_q1,
    input  wire signed [7:0] del_i0, del_i1,
    input  wire signed [7:0] del_q0, del_q1,
    input  wire        delayed_valid,
    input  wire [3:0]  sf,
    input  wire [15:0] sc_thr,
    input  wire [1:0]  sc_hits_req,
    output reg         sc_lock,
    output reg  [31:0] timing_ref,
    output reg  signed [31:0] c_i0, c_q0, c_i1, c_q1,
    output reg  [15:0] sc_stat,
    output reg         sc_hit_dbg,
    output reg  [1:0]  sc_hit_count_dbg,
    output reg  [31:0] sc_first_hit_dbg,
    output reg  [31:0] sc_lock_sample_dbg
);

    // =========================================================
    // Input registers
    // =========================================================
    reg signed [7:0] cur_i0_r, cur_i1_r, cur_q0_r, cur_q1_r;
    reg signed [7:0] del_i0_r, del_i1_r, del_q0_r, del_q1_r;
    reg              iq_valid_r, delayed_valid_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_i0_r <= 8'sd0; cur_i1_r <= 8'sd0;
            cur_q0_r <= 8'sd0; cur_q1_r <= 8'sd0;
            del_i0_r <= 8'sd0; del_i1_r <= 8'sd0;
            del_q0_r <= 8'sd0; del_q1_r <= 8'sd0;
            iq_valid_r <= 1'b0; delayed_valid_r <= 1'b0;
        end else begin
            cur_i0_r <= cur_i0; cur_i1_r <= cur_i1;
            cur_q0_r <= cur_q0; cur_q1_r <= cur_q1;
            del_i0_r <= del_i0; del_i1_r <= del_i1;
            del_q0_r <= del_q0; del_q1_r <= del_q1;
            iq_valid_r      <= iq_valid;
            delayed_valid_r <= delayed_valid;
        end
    end

    reg [31:0] sample_count;
    reg [7:0]  sym_cnt;
    reg [7:0]  M_val;
    always @(*) begin
        case (sf)
            4'd6:    M_val = 8'd64;
            default: M_val = 8'd128;
        endcase
    end

    // =========================================================
    // Per-symbol accumulators (NR=2)
    // =========================================================
    reg signed [31:0] acc_ci0, acc_cq0, acc_ci1, acc_cq1;
    reg signed [31:0] acc_E0cur, acc_E0del, acc_E1cur, acc_E1del;

    // =========================================================
    // TDM per-sample 8×8 multiplier
    //
    // Replaces 16 simultaneous combinational 8×8 wires.
    // When a sample fires (iq_valid_r && delayed_valid_r), all 8
    // inputs are latched and a 16-step serial MAC processes them:
    //
    //   Step  Inputs A×B              Accumulate at odd step
    //   ----  ----------------------  ------------------------------------------
    //   0,1   cur_i0×del_i0, cq0×dq0  acc_ci0 += P0 + P1  (re corr ch0)
    //   2,3   cur_q0×del_i0, ci0×dq0  acc_cq0 += P2 - P3  (im corr ch0)
    //   4,5   cur_i1×del_i1, cq1×dq1  acc_ci1 += P4 + P5  (re corr ch1)
    //   6,7   cur_q1×del_i1, ci1×dq1  acc_cq1 += P6 - P7  (im corr ch1)
    //   8,9   cur_i0², cur_q0²         acc_E0cur += P8 + P9
    //   10,11 del_i0², del_q0²         acc_E0del += P10 + P11
    //   12,13 cur_i1², cur_q1²         acc_E1cur += P12 + P13
    //   14,15 del_i1², del_q1²         acc_E1del += P14 + P15; end TDM
    //
    // Pipeline: tdm_a_r/tdm_b_r registered → tdm_mul (comb) → tdm_mul_r (registered).
    // At odd step N: tdm_mul_r = P_{N-1} (OLD NB), tdm_mul = P_N (comb).
    // =========================================================
    reg signed [7:0] tlat_ci0, tlat_qi0, tlat_di0, tlat_dq0;
    reg signed [7:0] tlat_ci1, tlat_qi1, tlat_di1, tlat_dq1;

    reg        tdm_busy;
    reg [3:0]  tdm_step;
    reg signed [7:0]  tdm_a_r, tdm_b_r;
    wire signed [15:0] tdm_mul = tdm_a_r * tdm_b_r;
    reg  signed [15:0] tdm_mul_r;

    reg signed [31:0] sym_ci0, sym_cq0, sym_ci1, sym_cq1;
/* verilator lint_off UNUSEDSIGNAL */
    reg signed [47:0] sym_mag_sc, sym_E_ref;
/* verilator lint_on UNUSEDSIGNAL */

    reg [1:0]  hit_count;
    reg [31:0] first_hit_sample, eval_sample_mark;
    reg        metric_valid_pulse;

    // =========================================================
    // Serialised metric engine — 7 multiplications (steps 0..6),
    // single shared signed_mul24_pipe (17-bit, 2-stage, 3-cycle latency).
    // =========================================================
    reg        eval_busy, eval_issue_done;
    reg [3:0]  eval_step;
    reg signed [47:0] eval_mag_acc, eval_e_acc;

    reg signed [16:0] eval_ci0, eval_cq0, eval_ci1, eval_cq1;
    reg signed [16:0] eval_E0cur, eval_E0del, eval_E1cur, eval_E1del;

    reg signed [16:0] eval_mul_a_sel, eval_mul_b_sel;
    wire signed [33:0] eval_prod;
    signed_mul24_pipe u_eval_mul (
        .clk(clk), .a(eval_mul_a_sel), .b(eval_mul_b_sel), .p(eval_prod));

    reg [2:0]  eval_valid_pipe;
    reg [3:0]  eval_step_0, eval_step_1, eval_step_2;
    reg        eval_hit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eval_mul_a_sel <= 17'sd0;
            eval_mul_b_sel <= 17'sd0;
        end else begin
            case (eval_step)
                4'd0: begin eval_mul_a_sel <= eval_ci0;  eval_mul_b_sel <= eval_ci0;  end
                4'd1: begin eval_mul_a_sel <= eval_cq0;  eval_mul_b_sel <= eval_cq0;  end
                4'd2: begin eval_mul_a_sel <= eval_ci1;  eval_mul_b_sel <= eval_ci1;  end
                4'd3: begin eval_mul_a_sel <= eval_cq1;  eval_mul_b_sel <= eval_cq1;  end
                4'd4: begin eval_mul_a_sel <= eval_E0cur; eval_mul_b_sel <= eval_E0del; end
                4'd5: begin eval_mul_a_sel <= eval_E1cur; eval_mul_b_sel <= eval_E1del; end
                default: begin
                    eval_mul_a_sel <= $signed({1'b0, sc_thr});
                    eval_mul_b_sel <= $signed(eval_e_acc[34:18]);
                end
            endcase
        end
    end

    // =========================================================
    // Main sequential block
    // =========================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_count    <= 32'd0;
            sym_cnt         <= 8'd0;
            acc_ci0  <= 32'sd0; acc_cq0  <= 32'sd0;
            acc_ci1  <= 32'sd0; acc_cq1  <= 32'sd0;
            acc_E0cur<= 32'sd0; acc_E0del<= 32'sd0;
            acc_E1cur<= 32'sd0; acc_E1del<= 32'sd0;
            tlat_ci0 <= 8'sd0; tlat_qi0 <= 8'sd0;
            tlat_di0 <= 8'sd0; tlat_dq0 <= 8'sd0;
            tlat_ci1 <= 8'sd0; tlat_qi1 <= 8'sd0;
            tlat_di1 <= 8'sd0; tlat_dq1 <= 8'sd0;
            tdm_busy    <= 1'b0;
            tdm_step    <= 4'd0;
            tdm_a_r     <= 8'sd0; tdm_b_r <= 8'sd0;
            tdm_mul_r   <= 16'sd0;
            sym_ci0  <= 32'sd0; sym_cq0  <= 32'sd0;
            sym_ci1  <= 32'sd0; sym_cq1  <= 32'sd0;
            sym_mag_sc <= 48'sd0; sym_E_ref <= 48'sd0;
            hit_count        <= 2'd0;
            first_hit_sample <= 32'd0;
            eval_sample_mark <= 32'd0;
            metric_valid_pulse <= 1'b0;
            eval_busy       <= 1'b0;
            eval_step       <= 4'd0;
            eval_issue_done <= 1'b0;
            eval_valid_pipe <= 3'd0;
            eval_step_0 <= 4'd0; eval_step_1 <= 4'd0; eval_step_2 <= 4'd0;
            eval_mag_acc <= 48'sd0; eval_e_acc <= 48'sd0;
            eval_hit     <= 1'b0;
            eval_ci0  <= 17'sd0; eval_cq0  <= 17'sd0;
            eval_ci1  <= 17'sd0; eval_cq1  <= 17'sd0;
            eval_E0cur<= 17'sd0; eval_E0del<= 17'sd0;
            eval_E1cur<= 17'sd0; eval_E1del<= 17'sd0;
            sc_lock            <= 1'b0;
            timing_ref         <= 32'd0;
            c_i0 <= 32'sd0; c_q0 <= 32'sd0;
            c_i1 <= 32'sd0; c_q1 <= 32'sd0;
            sc_stat            <= 16'd0;
            sc_hit_dbg         <= 1'b0;
            sc_hit_count_dbg   <= 2'd0;
            sc_first_hit_dbg   <= 32'd0;
            sc_lock_sample_dbg <= 32'd0;
        end else begin
            metric_valid_pulse <= 1'b0;
            sc_hit_dbg         <= 1'b0;

            // -----------------------------------------------------------------
            // Sample arrives: latch inputs, start TDM
            // -----------------------------------------------------------------
            if (iq_valid_r && delayed_valid_r && !tdm_busy) begin
                // Latch all 8 inputs; preload step 0 inputs into multiplier
                tlat_ci0 <= cur_i0_r; tlat_qi0 <= cur_q0_r;
                tlat_di0 <= del_i0_r; tlat_dq0 <= del_q0_r;
                tlat_ci1 <= cur_i1_r; tlat_qi1 <= cur_q1_r;
                tlat_di1 <= del_i1_r; tlat_dq1 <= del_q1_r;
                tdm_a_r  <= cur_i0_r;
                tdm_b_r  <= del_i0_r;
                tdm_step <= 4'd0;
                tdm_busy <= 1'b1;
            end else if (iq_valid_r && !delayed_valid_r) begin
                sample_count <= sample_count + 32'd1;
            end

            // -----------------------------------------------------------------
            // TDM engine: one 8×8 multiply per cycle, 16 cycles per sample
            // -----------------------------------------------------------------
            if (tdm_busy) begin
                tdm_mul_r <= tdm_mul;       // register current comb product
                tdm_step  <= tdm_step + 4'd1;

                // Pre-select inputs for next step (take effect NEXT cycle)
                case (tdm_step)
                    4'd0:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_dq0; end
                    4'd1:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_di0; end
                    4'd2:  begin tdm_a_r <= tlat_ci0; tdm_b_r <= tlat_dq0; end
                    4'd3:  begin tdm_a_r <= tlat_ci1; tdm_b_r <= tlat_di1; end
                    4'd4:  begin tdm_a_r <= tlat_qi1; tdm_b_r <= tlat_dq1; end
                    4'd5:  begin tdm_a_r <= tlat_qi1; tdm_b_r <= tlat_di1; end
                    4'd6:  begin tdm_a_r <= tlat_ci1; tdm_b_r <= tlat_dq1; end
                    4'd7:  begin tdm_a_r <= tlat_ci0; tdm_b_r <= tlat_ci0; end
                    4'd8:  begin tdm_a_r <= tlat_qi0; tdm_b_r <= tlat_qi0; end
                    4'd9:  begin tdm_a_r <= tlat_di0; tdm_b_r <= tlat_di0; end
                    4'd10: begin tdm_a_r <= tlat_dq0; tdm_b_r <= tlat_dq0; end
                    4'd11: begin tdm_a_r <= tlat_ci1; tdm_b_r <= tlat_ci1; end
                    4'd12: begin tdm_a_r <= tlat_qi1; tdm_b_r <= tlat_qi1; end
                    4'd13: begin tdm_a_r <= tlat_di1; tdm_b_r <= tlat_di1; end
                    4'd14: begin tdm_a_r <= tlat_dq1; tdm_b_r <= tlat_dq1; end
                    default: begin end  // step 15: last step
                endcase

                // Accumulate at odd steps.
                // tdm_mul_r = P_{step-1} (OLD NB), tdm_mul = P_step (comb).
                // Correlation: add; imaginary part: subtract second term.
                // Energy squaring: both terms positive.
                case (tdm_step)
                    4'd1:  acc_ci0   <= acc_ci0
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                    4'd3:  acc_cq0   <= acc_cq0
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                - {{16{tdm_mul[15]}},   tdm_mul};
                    4'd5:  acc_ci1   <= acc_ci1
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                    4'd7:  acc_cq1   <= acc_cq1
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                - {{16{tdm_mul[15]}},   tdm_mul};
                    4'd9:  acc_E0cur <= acc_E0cur
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                    4'd11: acc_E0del <= acc_E0del
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                    4'd13: acc_E1cur <= acc_E1cur
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                    4'd15: begin
                        acc_E1del <= acc_E1del
                                + {{16{tdm_mul_r[15]}}, tdm_mul_r}
                                + {{16{tdm_mul[15]}},   tdm_mul};
                        // ----- End of TDM for this sample -----
                        tdm_busy     <= 1'b0;
                        sample_count <= sample_count + 32'd1;

                        if (sym_cnt == M_val - 8'd1) begin
                            sym_cnt <= 8'd0;
                            // Snapshot: acc values include the just-completed step-15 update
                            // via the acc_E1del NB above; others were updated at steps 1..13.
                            // Use the intermediate next-values for the snapshot:
                            sym_ci0 <= acc_ci0; sym_cq0 <= acc_cq0;
                            sym_ci1 <= acc_ci1; sym_cq1 <= acc_cq1;

                            eval_ci0   <= acc_ci0[22:6];   eval_cq0   <= acc_cq0[22:6];
                            eval_ci1   <= acc_ci1[22:6];   eval_cq1   <= acc_cq1[22:6];
                            eval_E0cur <= acc_E0cur[22:6]; eval_E0del <= acc_E0del[22:6];
                            eval_E1cur <= acc_E1cur[22:6]; eval_E1del <= acc_E1del[22:6];

                            eval_mag_acc    <= 48'sd0;
                            eval_e_acc      <= 48'sd0;
                            eval_step       <= 4'd0;
                            eval_issue_done <= 1'b0;
                            eval_valid_pipe <= 3'd0;
                            eval_busy       <= 1'b1;
                            eval_sample_mark <= sample_count + 32'd1;

                            acc_ci0   <= 32'sd0; acc_cq0   <= 32'sd0;
                            acc_ci1   <= 32'sd0; acc_cq1   <= 32'sd0;
                            acc_E0cur <= 32'sd0; acc_E0del <= 32'sd0;
                            acc_E1cur <= 32'sd0; acc_E1del <= 32'sd0;
                        end else begin
                            sym_cnt <= sym_cnt + 8'd1;
                        end
                    end
                    default: begin end
                endcase
            end

            // -----------------------------------------------------------------
            // Metric evaluation engine (unchanged from original)
            // -----------------------------------------------------------------
            if (eval_busy) begin
                eval_valid_pipe <= {eval_valid_pipe[1:0], !eval_issue_done};

                eval_step_0 <= eval_step;
                eval_step_1 <= eval_step_0;
                eval_step_2 <= eval_step_1;

                if (!eval_issue_done) begin
                    if (eval_step == 4'd6)
                        eval_issue_done <= 1'b1;
                    else
                        eval_step <= eval_step + 4'd1;
                end

                if (eval_valid_pipe[2]) begin
                    case (eval_step_2)
                        4'd0: eval_mag_acc <= eval_mag_acc + {{14{eval_prod[33]}}, eval_prod};
                        4'd1: eval_mag_acc <= eval_mag_acc + {{14{eval_prod[33]}}, eval_prod};
                        4'd2: eval_mag_acc <= eval_mag_acc + {{14{eval_prod[33]}}, eval_prod};
                        4'd3: eval_mag_acc <= eval_mag_acc + {{14{eval_prod[33]}}, eval_prod};
                        4'd4: eval_e_acc <= eval_e_acc + {{14{eval_prod[33]}}, eval_prod};
                        4'd5: begin
                            eval_e_acc <= eval_e_acc + {{14{eval_prod[33]}}, eval_prod};
                            sym_mag_sc <= eval_mag_acc;
                        end
                        default: begin
                            sym_E_ref          <= eval_e_acc;
                            eval_hit           <= (eval_e_acc > 48'sd0) &&
                                                  ({1'b0, eval_mag_acc[47:1]} >=
                                                   {{14{eval_prod[33]}}, eval_prod});
                            eval_busy          <= 1'b0;
                            metric_valid_pulse <= 1'b1;
                        end
                    endcase
                end
            end

            // -----------------------------------------------------------------
            // Lock detection
            // -----------------------------------------------------------------
            if (metric_valid_pulse && !sc_lock) begin
                sc_hit_dbg <= eval_hit;
                if (eval_hit) begin
                    if (hit_count == 2'd0)
                        first_hit_sample <= eval_sample_mark;
                    if (hit_count == sc_hits_req) begin
                        sc_lock            <= 1'b1;
                        sc_lock_sample_dbg <= eval_sample_mark;
                        timing_ref <= eval_sample_mark
                                    - ({29'd0, sc_hits_req} + 32'd1) * {24'd0, M_val}
                                    + 32'd1;
                        c_i0 <= sym_ci0; c_q0 <= sym_cq0;
                        c_i1 <= sym_ci1; c_q1 <= sym_cq1;
                        sc_first_hit_dbg <= first_hit_sample;
                        hit_count <= 2'd0;
                    end else begin
                        hit_count <= hit_count + 2'd1;
                    end
                end else begin
                    hit_count <= 2'd0;
                end
                sc_hit_count_dbg <= hit_count;
            end

            sc_stat <= sym_mag_sc[47:32];
        end
    end

endmodule
