// ahb_gpio_dbg.v
// Minimal AHB3-Lite slave (zero-wait-state, single-cycle response -- same convention as
// Grouper's ahb_rom.sv) giving firmware a bit-banged SPI master + status/LED latch, so the
// picorv32<->Trouper FPGA bring-up (fpga_top.v) can read Trouper's register bank back over its
// real HOST_CS/SPI_SCK/SPI_MOSI/SPI_MISO port as an independent oracle -- exactly the same
// AHB-write-then-SPI-readback methodology as integration/tb/tb_grouper_trouper_top.v -- without
// needing an external host, UART, or Ethernet stack. Vivado ILA probes the AHB bus and the
// spi_* signals directly for cycle-level debug; the STATUS register drives on-board LEDs for an
// at-a-glance PASS/FAIL/DONE without opening Vivado.
//
// Register map (word-addressed, byte writes/reads both land correctly since all live fields fit
// in the low byte):
//   0x00 SPI_CTRL   [0] CS_n (R/W, idle=1)   [1] SCK (R/W)   [2] MOSI (R/W)   [4] MISO (R/O)
//   0x04 STATUS     [0] DONE (R/W)   [1] PASS (R/W)   [2] FAIL (R/W)  -- mirrored to led_status

`default_nettype none

module ahb_gpio_dbg #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  wire                    HCLK,
    input  wire                    HRESETn,

    input  wire [ADDR_WIDTH-1:0]   HADDR,
    input  wire [1:0]              HTRANS,
    input  wire                    HWRITE,
    input  wire [DATA_WIDTH-1:0]   HWDATA,
    input  wire                    HSEL,
    input  wire                    HREADYIN,

    output reg  [DATA_WIDTH-1:0]   HRDATA,
    output wire                    HREADYOUT,
    output wire                    HRESP,

    // Bit-banged SPI master pins -- wired straight into Trouper's host SPI slave port.
    output reg                     spi_cs_n,
    output reg                     spi_sck,
    output reg                     spi_mosi,
    input  wire                    spi_miso,

    // Status latch -- drives on-board LEDs directly.
    output reg  [2:0]              led_status   // {FAIL, PASS, DONE}
);

    localparam [1:0] HTRANS_IDLE = 2'b00;

    // ---------------------------------------------------------------------------------------
    // Address phase latch (standard AHB two-phase pipeline: address+control sampled here,
    // HWDATA for a write is valid together with the *next* address phase).
    // ---------------------------------------------------------------------------------------
    reg        sel_r;
    reg        write_r;
    reg  [3:2] addr_r;

    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            sel_r   <= 1'b0;
            write_r <= 1'b0;
            addr_r  <= 2'b00;
        end else if (HREADYIN) begin
            sel_r   <= HSEL && (HTRANS != HTRANS_IDLE);
            write_r <= HWRITE;
            addr_r  <= HADDR[3:2];
        end
    end

    // ---------------------------------------------------------------------------------------
    // Register writes (data phase)
    // ---------------------------------------------------------------------------------------
    always @(posedge HCLK or negedge HRESETn) begin
        if (!HRESETn) begin
            spi_cs_n <= 1'b1;   // idle = deasserted
            spi_sck  <= 1'b0;
            spi_mosi <= 1'b0;
            led_status <= 3'b000;
        end else if (sel_r && write_r) begin
            case (addr_r)
                2'b00: begin
                    spi_mosi <= HWDATA[2];
                    spi_sck  <= HWDATA[1];
                    spi_cs_n <= HWDATA[0];
                end
                2'b01: led_status <= HWDATA[2:0];
                default: ;
            endcase
        end
    end

    // ---------------------------------------------------------------------------------------
    // Reads
    // ---------------------------------------------------------------------------------------
    always @(*) begin
        case (addr_r)
            2'b00:   HRDATA = {27'd0, spi_miso, 1'b0, spi_mosi, spi_sck, spi_cs_n};
            2'b01:   HRDATA = {29'd0, led_status};
            default: HRDATA = 32'd0;
        endcase
    end

    assign HREADYOUT = 1'b1;   // zero wait states
    assign HRESP     = 1'b0;   // always OKAY

endmodule

`default_nettype wire
