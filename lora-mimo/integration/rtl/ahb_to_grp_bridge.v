// ahb_to_grp_bridge.v
//
// CDC-safe AHB (HCLK) to Trouper GRP (IQ_CLK) bridge.
//
// The two clocks are intentionally unrelated: Grouper runs at 16 MHz (25 MHz
// on the test chip -- integration/planning/Open Risks.md #4) while Trouper's
// IQ clock runs at 32 MHz. A request-toggle / acknowledge-toggle handshake
// transfers one transaction at a time. The request bundle is held stable in
// the HCLK domain from before its toggle crosses into IQ_CLK until the
// acknowledge toggle crosses back; the response bundle is held stable in
// IQ_CLK until the next request. This is a standard bundled-data CDC scheme:
// only the single-bit toggles enter two-flop synchronizers.
//
// -----------------------------------------------------------------------------
// CDC hardening (2026-08-28, branch timn/ahb-bridge-cdc-review)
// -----------------------------------------------------------------------------
//   F1  Per-domain reset synchronizers. HRESETn is an external asynchronous
//       reset; it is resynchronized to HCLK and, separately, to IQ_CLK (async
//       assert, sync deassert) before use, so the handshake / synchronizer
//       flops never see recovery/removal metastability on reset release.
//       `set_clock_groups -asynchronous` does NOT cover reset. Both syncs take
//       the same HRESETn today (shared chip-top reset, Open Risks #3); if a
//       second reset pad is ever added, drive the IQ_CLK sync from Trouper's
//       reset and the HCLK sync from Grouper's -- that is exactly the
//       "each half reset by its own domain" requirement in Open Risks #3b,
//       and this structure is ready for it.
//   F3  The 2-flop synchronizers carry (* keep *) in addition to
//       (* ASYNC_REG *): ASYNC_REG is a Vivado attribute, ignored by the
//       Yosys / OpenROAD flow used here, so `keep` is what actually stops the
//       flop pair from being merged or retimed. The async clock-group cut is
//       in chip_top_dual_clock.sdc; the payload nets are additionally bounded
//       there with `set_max_delay -datapath_only` (F2).
//
// Known limitations, NOT addressed here -- see
// integration/planning/Open Risks.md items 5/6/7:
//   F4  Read data is captured on a fixed HOLD_CYCLES delay, not qualified by
//       GRP_READY (which is deliberately ignored, see below). Correct only
//       while HOLD_CYCLES (default 6) >= Trouper's worst-case GRP read latency
//       including its every-other-cycle enable.
//   F5  No error / timeout path: HRESP is tied OKAY, and a GRP access that
//       never completes holds HREADY low forever (Grouper firmware hangs).
//   F6  HTRANS=SEQ is accepted and HBURST is not observed. HTRANS is only
//       looked at in SRC_IDLE, so a master BUSY / wait state in the data phase
//       is not honoured and bursts are serialized one beat at a time at full
//       CDC latency. MMIO-register-bus-only assumption -- fine for this bus,
//       stated here so it is a choice, not an accident.

`default_nettype none

module ahb_to_grp_bridge #(
    // Number of IQ_CLK edges for which GRP_WE/GRP_RE are asserted. Trouper's
    // register-bank interface samples only on its internal every-other-cycle
    // enable, so six edges provides three complete capture opportunities.
    parameter integer HOLD_CYCLES = 6
) (
    // Grouper / AHB clock domain (16 MHz).
    input  wire        HCLK,
    input  wire        HRESETn,
    input  wire [7:0]  HADDR,
    input  wire        HWRITE,
    input  wire [1:0]  HTRANS,
    input  wire [7:0]  HWDATA,
    output reg  [7:0]  HRDATA,
    output reg         HREADY,
    output wire        HRESP,

    // Trouper clock domain (32 MHz).
    input  wire        IQ_CLK,
    output reg  [7:0]  GRP_ADDR,
    output reg  [7:0]  GRP_WDATA,
    output reg         GRP_WE,
    output reg         GRP_RE,
    input  wire [7:0]  GRP_RDATA,
    input  wire         GRP_READY
);

    assign HRESP = 1'b0; // AHB OKAY

    // -------------------------------------------------------------------------
    // F1: per-domain reset synchronizers. Async assert, sync deassert. Both
    // are sourced from HRESETn today (shared chip-top reset); split the
    // sources if/when a second reset pad lands (Open Risks #3).
    // -------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE", keep = "true" *) reg hrst_n_meta, hrst_n_sync;
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) {hrst_n_sync, hrst_n_meta} <= 2'b00;
        else          {hrst_n_sync, hrst_n_meta} <= {hrst_n_meta, 1'b1};
    end

    (* ASYNC_REG = "TRUE", keep = "true" *) reg iqrst_n_meta, iqrst_n_sync;
    always @(posedge IQ_CLK or negedge HRESETn) begin
        if (!HRESETn) {iqrst_n_sync, iqrst_n_meta} <= 2'b00;
        else          {iqrst_n_sync, iqrst_n_meta} <= {iqrst_n_meta, 1'b1};
    end

    localparam [1:0] HTRANS_NONSEQ = 2'b10;
    localparam [1:0] SRC_IDLE      = 2'd0,
                     SRC_CAPTURE   = 2'd1,
                     SRC_WAIT_ACK  = 2'd2,
                     SRC_DONE      = 2'd3;
    localparam integer HOLD_WIDTH = (HOLD_CYCLES < 2) ? 1 : $clog2(HOLD_CYCLES + 1);

    // Request bundle: launched by HCLK, sampled only after request-toggle
    // synchronization in IQ_CLK, and held until acknowledgement returns.
    reg [7:0] request_addr;
    reg [7:0] request_wdata;
    reg       request_write;
    reg       request_toggle;

    // Response bundle: written before acknowledgement in IQ_CLK and held
    // until a later request; therefore safe to sample after ack synchronization.
    reg [7:0] response_rdata;
    reg       acknowledge_toggle;

    // Two-flop synchronizers. ASYNC_REG is Vivado-only (ignored by Yosys /
    // OpenROAD); `keep` is what actually prevents this flow from merging or
    // retiming the flop pair. See chip_top_dual_clock.sdc for the async
    // clock-group cut and the -datapath_only payload bound (F2/F3).
    (* ASYNC_REG = "TRUE", keep = "true" *) reg acknowledge_sync_1, acknowledge_sync_2;
    (* ASYNC_REG = "TRUE", keep = "true" *) reg request_sync_1, request_sync_2;

    reg [1:0] src_state;
    reg [HOLD_WIDTH-1:0] hold_count;
    reg request_seen;
    reg dst_active;

    wire ahb_transfer = (HTRANS == HTRANS_NONSEQ) || (HTRANS == 2'b11);

    // Source: accept an AHB transfer, capture write data in the following
    // data phase, then stall HREADY until Trouper has completed the request.
    always @(posedge HCLK or negedge hrst_n_sync) begin
        if (!hrst_n_sync) begin
            request_addr       <= 8'd0;
            request_wdata      <= 8'd0;
            request_write      <= 1'b0;
            request_toggle     <= 1'b0;
            acknowledge_sync_1 <= 1'b0;
            acknowledge_sync_2 <= 1'b0;
            HRDATA             <= 8'd0;
            HREADY             <= 1'b1;
            src_state          <= SRC_IDLE;
        end else begin
            acknowledge_sync_1 <= acknowledge_toggle;
            acknowledge_sync_2 <= acknowledge_sync_1;

            case (src_state)
                SRC_IDLE: begin
                    HREADY <= 1'b1;
                    if (ahb_transfer) begin
                        request_addr  <= HADDR;
                        request_write <= HWRITE;
                        HREADY        <= 1'b0;
                        src_state     <= SRC_CAPTURE;
                    end
                end

                // HWDATA is valid in the AHB data phase, one HCLK after the
                // address/control capture above.
                SRC_CAPTURE: begin
                    request_wdata  <= HWDATA;
                    request_toggle <= ~request_toggle;
                    HREADY         <= 1'b0;
                    src_state      <= SRC_WAIT_ACK;
                end

                SRC_WAIT_ACK: begin
                    HREADY <= 1'b0;
                    if (acknowledge_sync_2 == request_toggle) begin
                        HRDATA    <= response_rdata;
                        HREADY    <= 1'b1;
                        src_state <= SRC_DONE;
                    end
                end

                SRC_DONE: begin
                    // Retain HREADY for the AHB completion edge, then accept
                    // a subsequent transfer on the following cycle.
                    HREADY    <= 1'b1;
                    src_state <= SRC_IDLE;
                end

                default: begin
                    HREADY    <= 1'b1;
                    src_state <= SRC_IDLE;
                end
            endcase
        end
    end

    // Destination: after the synchronized request toggle is observed, latch
    // the stable bundle, hold the native GRP request for HOLD_CYCLES IQ edges,
    // then return read data and acknowledge completion.
    always @(posedge IQ_CLK or negedge iqrst_n_sync) begin
        if (!iqrst_n_sync) begin
            request_sync_1    <= 1'b0;
            request_sync_2    <= 1'b0;
            request_seen      <= 1'b0;
            acknowledge_toggle <= 1'b0;
            response_rdata    <= 8'd0;
            GRP_ADDR          <= 8'd0;
            GRP_WDATA         <= 8'd0;
            GRP_WE            <= 1'b0;
            GRP_RE            <= 1'b0;
            hold_count        <= {HOLD_WIDTH{1'b0}};
            dst_active        <= 1'b0;
        end else begin
            request_sync_1 <= request_toggle;
            request_sync_2 <= request_sync_1;

            if (!dst_active && (request_sync_2 != request_seen)) begin
                GRP_ADDR   <= request_addr;
                GRP_WDATA  <= request_wdata;
                GRP_WE     <= request_write;
                GRP_RE     <= ~request_write;
                hold_count <= HOLD_CYCLES[HOLD_WIDTH-1:0];
                dst_active <= 1'b1;
            end else if (dst_active) begin
                if (hold_count == 0) begin
                    GRP_WE             <= 1'b0;
                    GRP_RE             <= 1'b0;
                    response_rdata     <= GRP_RDATA;
                    request_seen       <= request_sync_2;
                    acknowledge_toggle <= request_sync_2;
                    dst_active         <= 1'b0;
                end else begin
                    hold_count <= hold_count - 1'b1;
                end
            end
        end
    end

    // GRP_READY is intentionally not used as a completion condition: Trouper
    // currently presents it as a combinational status, and the legacy bridge
    // did not make it load-bearing. It remains a port for protocol compatibility.
    wire _unused_grp_ready = GRP_READY;

endmodule

`default_nettype wire
