// chip_top.v
// Combined Grouper<->Trouper physical-design top -- Open Item #1, see
// planning/grouper-trouper-landscape-floorplan-2026-08.md.
//
// STATUS: rewritten 2026-08-22 to instantiate real top-level modules from both
// projects instead of hand-picking Grouper submodules (cpu_ss_emc/ahb_rom/
// ahb_ram/ahb_conn_buff) and reimplementing their interconnect ourselves --
// that approach is preserved in git history but abandoned. NOT YET
// RE-VERIFIED (elaborates/synthesizes cleanly, jobs 4661/4665, was against
// the OLD approach -- must be re-run against this version).
//
// Exactly three instantiations:
//   1. grouper_top       Grouper's own real top-level module (renamed
//                         locally from grouper_soc_top -- see below),
//                         instantiated as-is: CPU, ROM, RAM, UART, GPIO,
//                         periph_ss, all real, none of it reimplemented here.
//   2. trouper_top        Trouper's own real top-level module, full pad-level
//                         port list, instantiated as-is.
//   3. ahb_to_grp_bridge   The only new RTL in this file: an 8-bit AHB slave
//                         that drives Trouper's native GRP_* register bus.
//
// grouper_soc_top.sv required a small local patch (not yet upstream) to make
// this possible: it previously tied its own "External AHB Master Interface"
// (digital_ss's ext_ahb_m_if_*) off dead instead of exposing it at its own
// port list -- see that file's header for the patch. That interface is
// already 8-bit (EXT_ADDR_WIDTH/EXT_DATA_WIDTH default to 8) and Grouper's
// own periph_ss already truncates the CPU's 32-bit address down to it
// internally, so the bridge needs no width conversion of its own -- a
// cleaner interface boundary than the old approach's manual 32-bit AHB
// decode + byte narrowing.
//
// Not yet done:
//   - Grouper's own external padframe (UART pins, GPIO pins) is NOT exposed
//     at chip_top's own ports -- tied off below. No named/located Grouper
//     pinout exists on any branch (Open Item #4), so there's nothing real to
//     wire up yet.
//   - Clock domains: HCLK is Grouper's 16 MHz clock and IQ_CLK is Trouper's
//     32 MHz clock. ahb_to_grp_bridge crosses the GRP control protocol with a
//     request/acknowledge CDC handshake; no multi-bit control signal crosses
//     directly between the domains.
//   - Reset polarity: grouper_top's `async_rst_n` and trouper_top's RESETB
//     are both active-low, both driven from HRESETn directly here -- but
//     grouper_top's is documented as asynchronous/board-button-sourced and
//     internally resynchronized (see its own `sync` instance), so this is
//     probably fine as-is, not independently verified.

`default_nettype none

module chip_top (
    input  wire HCLK,        // Grouper clock: 16 MHz
    input  wire IQ_CLK,      // Trouper IQ/PSRAM clock: 32 MHz
    input  wire HRESETn,     // shared active-low reset

    // =========================================================================
    // Trouper pad-level ports -- full real list, passed straight through.
    // Matches integration/pd/io_placement_landscape.cfg #N/#W (real pins) and
    // #S/#E (GRP_* bus) exactly; see that file and the planning doc for the
    // side assignment rationale.
    // =========================================================================
    input  wire IQ_DATA_I_0, IQ_DATA_I_1, IQ_DATA_I_2, IQ_DATA_I_3,
    input  wire IQ_DATA_Q_0, IQ_DATA_Q_1, IQ_DATA_Q_2, IQ_DATA_Q_3,
    output wire REMOD_A_I, REMOD_A_Q,

    output wire PSRAM_SCK, PSRAM_CE_N,
    // Temporary P&R model: each physical PSRAM SIO pad is driven directly.
    // The final pad-ring integration must restore output-enable control.
    output wire PSRAM_SIO_0, PSRAM_SIO_1, PSRAM_SIO_2, PSRAM_SIO_3,

    input  wire HOST_CS, SPI_SCK, SPI_MOSI,
    output wire SPI_MISO,

    output wire IRQ_OUT
    // NOTE: RESETB is driven by HRESETn above, not a separate chip_top port.
    // IRQ_GROUPER is Trouper's internal name for the same signal as IRQ_OUT
    // (see trouper_top.v) and is consumed inside this module (wired to
    // grouper_top's IRQ input, once grouper_top actually has one exposed --
    // it doesn't yet, see the tie-off below), not exposed as a chip_top pad.
);

    // =========================================================================
    // Grouper -- real top-level module, instantiated as-is. UART/GPIO pads
    // tied off (Open Item #4 -- no Grouper padframe exposed at chip_top yet).
    // =========================================================================
    wire [7:0] ext_HADDR;
    wire [2:0] ext_HBURST;
    wire       ext_HMASTLOCK;
    wire [3:0] ext_HPROT;
    wire [2:0] ext_HSIZE;
    wire [1:0] ext_HTRANS;
    wire [7:0] ext_HWDATA;
    wire       ext_HWRITE;
    wire [7:0] ext_HRDATA;
    wire       ext_HREADY;
    wire       ext_HRESP;

    wire uart_tx_unused;
    wire [15:0] gpio_out_unused, gpio_oe_unused, gpio_cs_unused,
                gpio_sl_unused, gpio_ie_unused, gpio_pu_unused, gpio_pd_unused;

    grouper_soc_top #(
        .NUM_GPIO       (16),
        .EXT_ADDR_WIDTH (8),
        .EXT_DATA_WIDTH (8)
    ) u_grouper (
        .clk                    (HCLK),
        .async_rst_n            (HRESETn),
        .uart_tx                (uart_tx_unused),
        .uart_rx                (1'b1),          // idle-high, no Grouper padframe yet
        .gpio_in                (16'h0000),
        .gpio_out               (gpio_out_unused),
        .gpio_oe                (gpio_oe_unused),
        .gpio_cs                (gpio_cs_unused),
        .gpio_sl                (gpio_sl_unused),
        .gpio_ie                (gpio_ie_unused),
        .gpio_pu                (gpio_pu_unused),
        .gpio_pd                (gpio_pd_unused),
        .ext_ahb_m_if_HADDR     (ext_HADDR),
        .ext_ahb_m_if_HBURST    (ext_HBURST),
        .ext_ahb_m_if_HMASTLOCK (ext_HMASTLOCK),
        .ext_ahb_m_if_HPROT     (ext_HPROT),
        .ext_ahb_m_if_HSIZE     (ext_HSIZE),
        .ext_ahb_m_if_HTRANS    (ext_HTRANS),
        .ext_ahb_m_if_HWDATA    (ext_HWDATA),
        .ext_ahb_m_if_HWRITE    (ext_HWRITE),
        .ext_ahb_m_if_HRDATA    (ext_HRDATA),
        .ext_ahb_m_if_HREADY    (ext_HREADY),
        .ext_ahb_m_if_HRESP     (ext_HRESP)
    );

    // =========================================================================
    // AHB <-> GRP_* bridge -- 8-bit, sits directly on grouper_top's external
    // AHB master port (see ahb_to_grp_bridge.v header for the protocol this
    // targets and its unverified timing assumptions).
    // =========================================================================
    wire [7:0] grp_addr, grp_wdata, grp_rdata;
    wire       grp_we, grp_re, grp_ready;

    ahb_to_grp_bridge u_bridge (
        .HCLK      (HCLK),
        .HRESETn   (HRESETn),
        .IQ_CLK    (IQ_CLK),
        .HADDR     (ext_HADDR),
        .HWRITE    (ext_HWRITE),
        .HTRANS    (ext_HTRANS),
        .HWDATA    (ext_HWDATA),
        .HRDATA    (ext_HRDATA),
        .HREADY    (ext_HREADY),
        .HRESP     (ext_HRESP),
        .GRP_ADDR  (grp_addr),
        .GRP_WDATA (grp_wdata),
        .GRP_WE    (grp_we),
        .GRP_RE    (grp_re),
        .GRP_RDATA (grp_rdata),
        .GRP_READY (grp_ready)
    );

    // =========================================================================
    // Trouper -- full real port list, straight through to chip_top's own ports.
    // GRP_* bus bit-flattened per trouper_top.v's pad-level naming convention.
    // =========================================================================
    wire irq_out_w, irq_grouper_w;
    wire psram_sio_out_0, psram_sio_out_1, psram_sio_out_2, psram_sio_out_3;
    wire psram_sio_in_0,  psram_sio_in_1,  psram_sio_in_2,  psram_sio_in_3;
    wire psram_sio_oe_0,  psram_sio_oe_1,  psram_sio_oe_2,  psram_sio_oe_3;

    // Do not infer top-level tri-state buffers for this P&R-only model.
    assign PSRAM_SIO_0 = psram_sio_out_0;
    assign PSRAM_SIO_1 = psram_sio_out_1;
    assign PSRAM_SIO_2 = psram_sio_out_2;
    assign PSRAM_SIO_3 = psram_sio_out_3;
    assign psram_sio_in_0 = PSRAM_SIO_0;
    assign psram_sio_in_1 = PSRAM_SIO_1;
    assign psram_sio_in_2 = PSRAM_SIO_2;
    assign psram_sio_in_3 = PSRAM_SIO_3;

    assign IRQ_OUT = irq_out_w;
    // irq_grouper_w (IRQ_GROUPER, same signal as IRQ_OUT) isn't consumed yet --
    // grouper_top has no IRQ input exposed at its own port list (Open Item #4).

    trouper_top u_trouper (
        .IQ_CLK          (IQ_CLK),
        .RESETB          (HRESETn),
        .IQ_DATA_I_0     (IQ_DATA_I_0),
        .IQ_DATA_I_1     (IQ_DATA_I_1),
        .IQ_DATA_I_2     (IQ_DATA_I_2),
        .IQ_DATA_I_3     (IQ_DATA_I_3),
        .IQ_DATA_Q_0     (IQ_DATA_Q_0),
        .IQ_DATA_Q_1     (IQ_DATA_Q_1),
        .IQ_DATA_Q_2     (IQ_DATA_Q_2),
        .IQ_DATA_Q_3     (IQ_DATA_Q_3),
        .REMOD_A_I       (REMOD_A_I),
        .REMOD_A_Q       (REMOD_A_Q),
        .PSRAM_SCK       (PSRAM_SCK),
        .PSRAM_CE_N      (PSRAM_CE_N),
        .PSRAM_SIO_OUT_0 (psram_sio_out_0),
        .PSRAM_SIO_OUT_1 (psram_sio_out_1),
        .PSRAM_SIO_OUT_2 (psram_sio_out_2),
        .PSRAM_SIO_OUT_3 (psram_sio_out_3),
        .PSRAM_SIO_IN_0  (psram_sio_in_0),
        .PSRAM_SIO_IN_1  (psram_sio_in_1),
        .PSRAM_SIO_IN_2  (psram_sio_in_2),
        .PSRAM_SIO_IN_3  (psram_sio_in_3),
        .PSRAM_SIO_OE_0  (psram_sio_oe_0),
        .PSRAM_SIO_OE_1  (psram_sio_oe_1),
        .PSRAM_SIO_OE_2  (psram_sio_oe_2),
        .PSRAM_SIO_OE_3  (psram_sio_oe_3),
        .HOST_CS         (HOST_CS),
        .SPI_SCK         (SPI_SCK),
        .SPI_MOSI        (SPI_MOSI),
        .SPI_MISO        (SPI_MISO),
        .GRP_ADDR_0      (grp_addr[0]),
        .GRP_ADDR_1      (grp_addr[1]),
        .GRP_ADDR_2      (grp_addr[2]),
        .GRP_ADDR_3      (grp_addr[3]),
        .GRP_ADDR_4      (grp_addr[4]),
        .GRP_ADDR_5      (grp_addr[5]),
        .GRP_ADDR_6      (grp_addr[6]),
        .GRP_ADDR_7      (grp_addr[7]),
        .GRP_WDATA_0     (grp_wdata[0]),
        .GRP_WDATA_1     (grp_wdata[1]),
        .GRP_WDATA_2     (grp_wdata[2]),
        .GRP_WDATA_3     (grp_wdata[3]),
        .GRP_WDATA_4     (grp_wdata[4]),
        .GRP_WDATA_5     (grp_wdata[5]),
        .GRP_WDATA_6     (grp_wdata[6]),
        .GRP_WDATA_7     (grp_wdata[7]),
        .GRP_WE          (grp_we),
        .GRP_RE          (grp_re),
        .GRP_RDATA_0     (grp_rdata[0]),
        .GRP_RDATA_1     (grp_rdata[1]),
        .GRP_RDATA_2     (grp_rdata[2]),
        .GRP_RDATA_3     (grp_rdata[3]),
        .GRP_RDATA_4     (grp_rdata[4]),
        .GRP_RDATA_5     (grp_rdata[5]),
        .GRP_RDATA_6     (grp_rdata[6]),
        .GRP_RDATA_7     (grp_rdata[7]),
        .GRP_READY       (grp_ready),
        .IRQ_OUT         (irq_out_w),
        .IRQ_GROUPER     (irq_grouper_w)
    );

endmodule

`default_nettype wire
