`timescale 1ns/1ps
`default_nettype none

// Regression for ahb_to_grp_bridge -- asynchronous HCLK / IQ_CLK CDC.
//
// F7 (branch timn/ahb-bridge-cdc-review): expanded from the original single
// write+read smoke test to cover:
//   - default HOLD_CYCLES (6), not the old HOLD_CYCLES=2
//   - back-to-back transfers
//   - reset asserted mid-transfer, then recovery (exercises the F1 reset
//     synchronizers: the bus must come back cleanly with no wedged state)
//   - HTRANS=IDLE / BUSY on an idle bus (must be ignored)
//   - 200 randomized write / read-verify transfers against a shadow model
//   - a phase-drifting IQ_CLK (small per-edge jitter) so the async boundary
//     is crossed at many HCLK:IQ_CLK alignments within one run
//   - inline monitors: GRP_WE and GRP_RE never both high; exactly one GRP
//     access pulse per completed AHB transfer (checked over the random
//     block); HREADY high whenever the bus is idle
//
// NOTE: a master-driven wait state / BUSY in the *data* phase is deliberately
// not modelled -- the bridge only inspects HTRANS in SRC_IDLE (F6). Plain
// Verilog-2012 / iverilog-compatible; no concurrent assertions.

module tb_ahb_to_grp_bridge;

    localparam integer HOLD = 6;

    // ---- clocks ------------------------------------------------------------
    reg hclk   = 1'b0;
    reg iq_clk = 1'b0;
    always #31.25 hclk = ~hclk;              // 16 MHz, fixed

    // IQ_CLK ~32 MHz with a small per-edge jitter so the HCLK:IQ_CLK phase
    // relationship drifts across the run (crude but effective async coverage).
    real iq_half = 15.625;
    real iq_jit  = 0.0;
    always begin
        #(iq_half + iq_jit) iq_clk = ~iq_clk;
    end
    always @(posedge hclk) begin
        iq_jit = ({$random} % 400) / 100.0 - 2.0;   // [-2.00, +1.99] ns
    end

    // ---- DUT -------------------------------------------------------------
    reg  [7:0] haddr = 8'd0, hwdata = 8'd0;
    reg        hwrite = 1'b0;
    reg  [1:0] htrans = 2'b00;
    wire [7:0] hrdata;
    wire       hready, hresp;

    wire [7:0] grp_addr, grp_wdata;
    wire       grp_we, grp_re;
    reg  [7:0] grp_rdata = 8'd0;
    reg        grp_ready = 1'b1;
    reg        resetn = 1'b0;

    ahb_to_grp_bridge #(.HOLD_CYCLES(HOLD)) dut (
        .HCLK(hclk), .HRESETn(resetn),
        .HADDR(haddr), .HWRITE(hwrite), .HTRANS(htrans), .HWDATA(hwdata),
        .HRDATA(hrdata), .HREADY(hready), .HRESP(hresp),
        .IQ_CLK(iq_clk),
        .GRP_ADDR(grp_addr), .GRP_WDATA(grp_wdata), .GRP_WE(grp_we),
        .GRP_RE(grp_re), .GRP_RDATA(grp_rdata), .GRP_READY(grp_ready)
    );

    // ---- reference model: Trouper GRP register file ---------------------
    reg [7:0] regs [0:255];
    always @(posedge iq_clk) begin
        if (grp_we) regs[grp_addr] <= grp_wdata;
        if (grp_re) grp_rdata      <= regs[grp_addr];
    end

    // ---- monitors ------------------------------------------------------
    integer errors     = 0;
    integer grp_pulses = 0;   // GRP access pulses seen (windowed, see below)
    integer xfers_done = 0;   // AHB transfers completed  (windowed)
    reg     grp_prev   = 1'b0;
    reg     count_en   = 1'b0; // gate the pulse/xfer equality to the random block

    always @(posedge iq_clk) begin
        if (resetn) begin
            if (grp_we && grp_re) begin
                $display("[%0t] ERROR: GRP_WE and GRP_RE both high", $time);
                errors = errors + 1;
            end
            if (count_en && (grp_we || grp_re) && !grp_prev)
                grp_pulses = grp_pulses + 1;
            grp_prev <= (grp_we || grp_re);
        end else begin
            grp_prev <= 1'b0;
        end
    end

    // HREADY must be high whenever the bus is idle (no transfer in flight).
    reg bus_busy = 1'b0;
    always @(posedge hclk) begin
        if (resetn && !bus_busy && (hready !== 1'b1)) begin
            $display("[%0t] ERROR: HREADY low on idle bus", $time);
            errors = errors + 1;
        end
    end

    // ---- AHB driver --------------------------------------------------
    task automatic ahb_addr_phase(input [7:0] addr, input wr);
        begin
            @(negedge hclk);
            haddr  <= addr;
            hwrite <= wr;
            htrans <= 2'b10;                 // NONSEQ
        end
    endtask

    task automatic ahb_finish(output [7:0] rdata);
        begin
            @(posedge hclk);
            while (hready === 1'b1) @(posedge hclk);   // wait for accept
            while (hready !== 1'b1) @(posedge hclk);   // wait for complete
            rdata      = hrdata;
            bus_busy   = 1'b0;
            if (count_en) xfers_done = xfers_done + 1;
        end
    endtask

    task automatic ahb_write(input [7:0] addr, input [7:0] data);
        reg [7:0] dummy;
        begin
            bus_busy = 1'b1;
            ahb_addr_phase(addr, 1'b1);
            @(negedge hclk);
            htrans <= 2'b00;
            hwdata <= data;
            ahb_finish(dummy);
        end
    endtask

    task automatic ahb_read(input [7:0] addr, output [7:0] data);
        reg [7:0] rd;
        begin
            bus_busy = 1'b1;
            ahb_addr_phase(addr, 1'b0);
            @(negedge hclk);
            htrans <= 2'b00;
            ahb_finish(rd);
            data = rd;
        end
    endtask

    task automatic check(input [7:0] got, input [7:0] exp, input [255:0] tag);
        begin
            if (got !== exp) begin
                $display("[%0t] ERROR: %0s: got %02x exp %02x", $time, tag, got, exp);
                errors = errors + 1;
            end
        end
    endtask

    // ---- stimulus -------------------------------------------------
    integer i;
    reg [7:0] a, d, rb;
    reg [7:0] shadow [0:255];

    initial begin
        for (i = 0; i < 256; i = i + 1) begin
            regs[i]   = 8'h00;
            shadow[i] = 8'h00;
        end

        // reset
        repeat (4) @(posedge iq_clk);
        @(negedge hclk); resetn = 1'b1;
        repeat (4) @(posedge hclk);

        // 1. directed write + readback
        ahb_write(8'h3c, 8'ha5); shadow[8'h3c] = 8'ha5;
        ahb_read (8'h3c, rb);    check(rb, 8'ha5, "directed rb");

        // 2. back-to-back writes then reads
        for (i = 0; i < 8; i = i + 1) begin
            ahb_write(8'h10 + i[7:0], 8'h20 + i[7:0]);
            shadow[8'h10 + i[7:0]] = 8'h20 + i[7:0];
        end
        for (i = 0; i < 8; i = i + 1) begin
            ahb_read(8'h10 + i[7:0], rb);
            check(rb, shadow[8'h10 + i[7:0]], "b2b rb");
        end

        // 3. IDLE / BUSY on an idle bus must be ignored
        @(negedge hclk); htrans <= 2'b00; @(negedge hclk);
        @(negedge hclk); htrans <= 2'b01; @(negedge hclk); htrans <= 2'b00;
        repeat (4) @(posedge hclk);
        ahb_read(8'h3c, rb); check(rb, 8'ha5, "post-idle rb");

        // 4. reset yanked mid-transfer, then recover
        bus_busy = 1'b1;
        ahb_addr_phase(8'h77, 1'b1);
        @(negedge hclk); htrans <= 2'b00; hwdata <= 8'hee;
        @(posedge hclk);
        @(negedge hclk); resetn = 1'b0;             // abort in flight
        repeat (3) @(posedge hclk);
        bus_busy = 1'b0;
        @(negedge hclk); resetn = 1'b1;
        repeat (4) @(posedge hclk);
        // the aborted write may or may not have landed; resync the shadow
        ahb_write(8'h77, 8'h11); shadow[8'h77] = 8'h11;
        ahb_read (8'h77, rb);    check(rb, 8'h11, "post-reset rb");

        // 5. randomized -- gate the pulse/xfer equality monitor to this block
        //    (the abort test above can leave a partial, uncounted GRP pulse).
        @(posedge iq_clk); count_en = 1'b1;
        for (i = 0; i < 200; i = i + 1) begin
            a = $random;
            if ($random % 2) begin
                d = $random;
                ahb_write(a, d);
                shadow[a] = d;
            end else begin
                ahb_read(a, rb);
                check(rb, shadow[a], "rand rb");
            end
        end
        repeat (2 * HOLD) @(posedge iq_clk);
        count_en = 1'b0;

        // ---- final checks ----
        if (grp_pulses !== xfers_done) begin
            $display("ERROR: GRP pulses %0d != AHB transfers %0d (random block)",
                     grp_pulses, xfers_done);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: ahb_to_grp_bridge CDC regression (%0d random transfers, %0d GRP pulses)",
                     xfers_done, grp_pulses);
        else
            $fatal(1, "FAIL: %0d error(s)", errors);
        $finish;
    end

    // watchdog
    initial begin
        #5_000_000;
        $fatal(1, "TIMEOUT");
    end

endmodule

`default_nettype wire
