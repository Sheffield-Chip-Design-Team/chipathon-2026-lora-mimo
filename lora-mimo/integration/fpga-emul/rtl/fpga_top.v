// fpga_top.v
// FPGA bring-up top for the Grouper picorv32 <-> Trouper AHB3-Lite integration
// (see ../../rtl/grouper_trouper_top.v, the simulation-only version this is modeled on --
// intentionally not modified by this file). Adds a third AHB slave, ahb_gpio_dbg.v, giving
// firmware a bit-banged SPI master wired directly to Trouper's real HOST_CS/SPI_SCK/SPI_MOSI/
// SPI_MISO port plus a STATUS/LED latch, so the exact same AHB-write-then-SPI-readback
// independent-oracle check proven in tb_grouper_trouper_top.v can run standalone on real
// hardware -- no external host, UART, or Ethernet stack needed. Pass/fail is visible two ways:
// on-board LEDs (led_status, at-a-glance) and Vivado ILA probes on the AHB bus + spi_* signals
// (cycle-level debug), per arty_top.v.
//
// This module is sim/synth-portable (plain HCLK/HRESETn ports, no Xilinx primitives) -- the
// Vivado-only clocking/board-I/O wrapper is arty_top.v.
//
// Address map:
//   0x0000_0000-0x7fff_ffff  Grouper ahb_rom (instruction memory), aliased/gated per the same
//                            quirk documented in grouper_trouper_top.v
//   0x0001_0000-0x0001_03FF  Trouper register window (ahb_lite_slave_adapter.v, 8-bit narrowed)
//   0x0002_0000-0x0002_00FF  ahb_gpio_dbg.v (bit-banged SPI + STATUS/LED)

`default_nettype none

module fpga_top (
    input  wire HCLK,
    input  wire HRESETn,

    // Status/LED outputs -- {FAIL, PASS, DONE}, mirrors ahb_gpio_dbg's led_status register.
    output wire [2:0] led,

    // Debug passthrough -- optional Pmod/scope probe points, also natural ILA probe signals.
    output wire dbg_host_cs,
    output wire dbg_spi_sck,
    output wire dbg_spi_mosi,
    output wire dbg_spi_miso
);

    // =========================================================================
    // Grouper CPU (AHB3-Lite master)
    // =========================================================================
    wire [31:0] c_HADDR;
    wire [2:0]  c_HBURST;
    wire        c_HMASTLOCK;
    wire [3:0]  c_HPROT;
    wire [2:0]  c_HSIZE;
    wire [1:0]  c_HTRANS;
    wire [31:0] c_HWDATA;
    wire        c_HWRITE;
    wire [31:0] c_HRDATA;
    wire        c_HREADY;
    wire        c_HRESP;

    cpu_ss_emc #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (32),
        .NUM_IRQ    (1)
    ) u_cpu_ss (
        .HCLK      (HCLK),
        .HRESETn   (HRESETn),
        .HADDR     (c_HADDR),
        .HBURST    (c_HBURST),
        .HMASTLOCK (c_HMASTLOCK),
        .HPROT     (c_HPROT),
        .HSIZE     (c_HSIZE),
        .HTRANS    (c_HTRANS),
        .HWDATA    (c_HWDATA),
        .HWRITE    (c_HWRITE),
        .HRDATA    (c_HRDATA),
        .HREADY    (c_HREADY),
        .HRESP     (c_HRESP),
        .irq       (1'b0)
    );

    // =========================================================================
    // Address decode
    // =========================================================================
    wire trouper_sel = (c_HADDR >= 32'h0001_0000) && (c_HADDR <= 32'h0001_03FF);
    wire gpio_sel    = (c_HADDR >= 32'h0002_0000) && (c_HADDR <= 32'h0002_00FF);
    wire rom_sel     = !(trouper_sel || gpio_sel);
    wire sys_hready;

    // =========================================================================
    // Grouper ROM (instruction memory) -- gated off for Trouper/GPIO windows; see
    // grouper_trouper_top.v's header comment for why this bypasses periph_ss/ahb_interconnect
    // entirely (SystemVerilog interface ports Icarus can't parse) and why ROM's own address
    // decode otherwise aliases the whole low 2GB.
    // =========================================================================
    wire [31:0] p_HRDATA;
    wire        p_HREADYOUT;
    wire        p_HRESP;

    ahb_rom #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (32)
    ) u_rom (
        .HCLK      (HCLK),
        .HRESETn   (HRESETn),
        .HADDR     (c_HADDR),
        .HBURST    (c_HBURST),
        .HMASTLOCK (c_HMASTLOCK),
        .HPROT     (c_HPROT),
        .HSIZE     (c_HSIZE),
        .HTRANS    (c_HTRANS),
        .HWDATA    (c_HWDATA),
        .HWRITE    (c_HWRITE),
        .HRDATA    (p_HRDATA),
        .HREADYOUT (p_HREADYOUT),
        .HRESP     (p_HRESP),
        .HREADYIN  (sys_hready),
        .HSEL      (rom_sel)
    );

    // =========================================================================
    // ahb_gpio_dbg -- bit-banged SPI master + STATUS/LED latch
    // =========================================================================
    wire [31:0] g_HRDATA;
    wire        g_HREADYOUT;
    wire        g_HRESP;
    wire        spi_miso_w;

    ahb_gpio_dbg #(
        .ADDR_WIDTH (32),
        .DATA_WIDTH (32)
    ) u_gpio (
        .HCLK      (HCLK),
        .HRESETn   (HRESETn),
        .HADDR     (c_HADDR),
        .HTRANS    (c_HTRANS),
        .HWRITE    (c_HWRITE),
        .HWDATA    (c_HWDATA),
        .HSEL      (gpio_sel),
        .HREADYIN  (sys_hready),
        .HRDATA    (g_HRDATA),
        .HREADYOUT (g_HREADYOUT),
        .HRESP     (g_HRESP),
        .spi_cs_n  (dbg_host_cs),
        .spi_sck   (dbg_spi_sck),
        .spi_mosi  (dbg_spi_mosi),
        .spi_miso  (spi_miso_w),
        .led_status(led)
    );

    assign dbg_spi_miso = spi_miso_w;

    // =========================================================================
    // Trouper (AHB3-Lite slave via ahb_lite_slave_adapter, narrowed to 8 bits) -- HOST_CS/
    // SPI_SCK/SPI_MOSI/SPI_MISO wired to ahb_gpio_dbg's bit-banged pins, entirely on-chip.
    // =========================================================================
    wire [7:0] t_HADDR  = c_HADDR[7:0];
    wire [7:0] t_HWDATA = c_HWDATA[7:0];
    wire       t_HWRITE = c_HWRITE;
    wire [1:0] t_HTRANS = c_HTRANS;
    wire [2:0] t_HSIZE  = c_HSIZE;
    wire       t_HSEL   = trouper_sel;
    wire       t_HREADYIN;   // driven below from sys_hready
    wire [7:0] t_HRDATA;
    wire       t_HREADYOUT;
    wire       t_HRESP;

    // Trouper's other pads, tied off -- unused by this AHB+SPI bring-up test.
    wire       remod_i_unused, remod_q_unused;
    wire       psram_sck_unused, psram_ce_n_unused;
    wire [3:0] psram_sio_out_unused, psram_sio_oe_unused;
    wire       irq_out_unused, irq_grouper_unused;

    trouper_top u_trouper (
        .IQ_CLK          (HCLK),
        .RESETB          (HRESETn),
        .IQ_DATA_I_0     (1'b0),
        .IQ_DATA_I_1     (1'b0),
        .IQ_DATA_I_2     (1'b0),
        .IQ_DATA_I_3     (1'b0),
        .IQ_DATA_Q_0     (1'b0),
        .IQ_DATA_Q_1     (1'b0),
        .IQ_DATA_Q_2     (1'b0),
        .IQ_DATA_Q_3     (1'b0),
        .REMOD_A_I       (remod_i_unused),
        .REMOD_A_Q       (remod_q_unused),
        .PSRAM_SCK       (psram_sck_unused),
        .PSRAM_CE_N      (psram_ce_n_unused),
        .PSRAM_SIO_OUT_0 (psram_sio_out_unused[0]),
        .PSRAM_SIO_OUT_1 (psram_sio_out_unused[1]),
        .PSRAM_SIO_OUT_2 (psram_sio_out_unused[2]),
        .PSRAM_SIO_OUT_3 (psram_sio_out_unused[3]),
        .PSRAM_SIO_IN_0  (1'b0),
        .PSRAM_SIO_IN_1  (1'b0),
        .PSRAM_SIO_IN_2  (1'b0),
        .PSRAM_SIO_IN_3  (1'b0),
        .PSRAM_SIO_OE_0  (psram_sio_oe_unused[0]),
        .PSRAM_SIO_OE_1  (psram_sio_oe_unused[1]),
        .PSRAM_SIO_OE_2  (psram_sio_oe_unused[2]),
        .PSRAM_SIO_OE_3  (psram_sio_oe_unused[3]),
        .HOST_CS         (dbg_host_cs),
        .SPI_SCK         (dbg_spi_sck),
        .SPI_MOSI        (dbg_spi_mosi),
        .SPI_MISO        (spi_miso_w),
        .HADDR_0         (t_HADDR[0]),
        .HADDR_1         (t_HADDR[1]),
        .HADDR_2         (t_HADDR[2]),
        .HADDR_3         (t_HADDR[3]),
        .HADDR_4         (t_HADDR[4]),
        .HADDR_5         (t_HADDR[5]),
        .HADDR_6         (t_HADDR[6]),
        .HADDR_7         (t_HADDR[7]),
        .HWDATA_0        (t_HWDATA[0]),
        .HWDATA_1        (t_HWDATA[1]),
        .HWDATA_2        (t_HWDATA[2]),
        .HWDATA_3        (t_HWDATA[3]),
        .HWDATA_4        (t_HWDATA[4]),
        .HWDATA_5        (t_HWDATA[5]),
        .HWDATA_6        (t_HWDATA[6]),
        .HWDATA_7        (t_HWDATA[7]),
        .HWRITE          (t_HWRITE),
        .HTRANS_0        (t_HTRANS[0]),
        .HTRANS_1        (t_HTRANS[1]),
        .HSIZE_0         (t_HSIZE[0]),
        .HSIZE_1         (t_HSIZE[1]),
        .HSIZE_2         (t_HSIZE[2]),
        .HREADYIN        (t_HREADYIN),
        .HSEL            (t_HSEL),
        .HRDATA_0        (t_HRDATA[0]),
        .HRDATA_1        (t_HRDATA[1]),
        .HRDATA_2        (t_HRDATA[2]),
        .HRDATA_3        (t_HRDATA[3]),
        .HRDATA_4        (t_HRDATA[4]),
        .HRDATA_5        (t_HRDATA[5]),
        .HRDATA_6        (t_HRDATA[6]),
        .HRDATA_7        (t_HRDATA[7]),
        .HREADYOUT       (t_HREADYOUT),
        .HRESP           (t_HRESP),
        .IRQ_OUT         (irq_out_unused),
        .IRQ_GROUPER     (irq_grouper_unused)
    );

    // =========================================================================
    // Response mux: single-decoder-level AHB behaviour -- the selected slave's own HREADYOUT
    // is the system HREADY, fed back as HREADYIN to whichever slave is selected.
    // =========================================================================
    assign sys_hready = trouper_sel ? t_HREADYOUT :
                        gpio_sel    ? g_HREADYOUT :
                                      p_HREADYOUT;
    assign t_HREADYIN = sys_hready;

    assign c_HREADY = sys_hready;
    assign c_HRESP  = trouper_sel ? t_HRESP  : gpio_sel ? g_HRESP  : p_HRESP;
    assign c_HRDATA = trouper_sel ? {24'd0, t_HRDATA}   :
                       gpio_sel   ? g_HRDATA             :
                                    p_HRDATA;

endmodule

`default_nettype wire
