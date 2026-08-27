// ahb_to_grp_bridge.v
//
// CDC-safe AHB (HCLK) to Trouper GRP (IQ_CLK) bridge.
//
// The two clocks are intentionally unrelated: Grouper runs at 16 MHz while
// Trouper's IQ clock runs at 32 MHz. A request-toggle / acknowledge-toggle
// handshake transfers one transaction at a time. The request bundle is held
// stable in the HCLK domain from before its toggle crosses into IQ_CLK until
// the acknowledge toggle crosses back; the response bundle is held stable in
// IQ_CLK until the next request. This is a standard bundled-data CDC scheme:
// only the single-bit toggles enter two-flop synchronizers.

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

    // Two-flop synchronizers. ASYNC_REG keeps implementation tools from
    // retiming these into ordinary logic.
    (* ASYNC_REG = "TRUE" *) reg acknowledge_sync_1, acknowledge_sync_2;
    (* ASYNC_REG = "TRUE" *) reg request_sync_1, request_sync_2;

    reg [1:0] src_state;
    reg [HOLD_WIDTH-1:0] hold_count;
    reg request_seen;
    reg dst_active;

    wire ahb_transfer = (HTRANS == HTRANS_NONSEQ) || (HTRANS == 2'b11);

    // Source: accept an AHB transfer, capture write data in the following
    // data phase, then stall HREADY until Trouper has completed the request.
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
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
    always @(posedge IQ_CLK or negedge HRESETn) begin
        if (!HRESETn) begin
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
