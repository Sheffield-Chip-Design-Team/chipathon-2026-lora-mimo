`default_nettype none

// Simulation-only integration harness.  Unlike chip_top, it connects the
// PSRAM behavioural model at the controller pads so debug write/read traffic
// is observable, while retaining the real Grouper SoC and AHB-to-GRP bridge.
module tb_grouper_trouper_psram (
    input wire HCLK, IQ_CLK, RESETB,
    input wire UART_RX,
    output wire UART_TX
);
    wire [7:0] haddr, hwdata, hrdata;
    wire hwrite, hready, hresp;
    wire [1:0] htrans;
    wire [2:0] hburst;
    wire hmastlock;
    wire [3:0] hprot;
    wire [2:0] hsize;
    wire [15:0] gpio_in, gpio_out, gpio_oe, gpio_cs, gpio_sl, gpio_ie, gpio_pu, gpio_pd;

    grouper_soc_top #(.NUM_GPIO(16), .EXT_ADDR_WIDTH(8), .EXT_DATA_WIDTH(8)) u_grouper (
        .clk(HCLK), .async_rst_n(RESETB), .uart_tx(UART_TX), .uart_rx(UART_RX),
        .ext_irq(irq_grouper),
        .gpio_in(gpio_in), .gpio_out(gpio_out), .gpio_oe(gpio_oe), .gpio_cs(gpio_cs),
        .gpio_sl(gpio_sl), .gpio_ie(gpio_ie), .gpio_pu(gpio_pu), .gpio_pd(gpio_pd),
        .ext_ahb_m_if_HADDR(haddr), .ext_ahb_m_if_HBURST(hburst),
        .ext_ahb_m_if_HMASTLOCK(hmastlock), .ext_ahb_m_if_HPROT(hprot),
        .ext_ahb_m_if_HSIZE(hsize), .ext_ahb_m_if_HTRANS(htrans),
        .ext_ahb_m_if_HWDATA(hwdata), .ext_ahb_m_if_HWRITE(hwrite),
        .ext_ahb_m_if_HRDATA(hrdata), .ext_ahb_m_if_HREADY(hready), .ext_ahb_m_if_HRESP(hresp)
    );
    assign gpio_in = 16'h0;

    wire [7:0] grp_addr, grp_wdata, grp_rdata;
    wire grp_we, grp_re, grp_ready;
    ahb_to_grp_bridge u_bridge (
        .HCLK(HCLK), .HRESETn(RESETB), .HADDR(haddr), .HWRITE(hwrite), .HTRANS(htrans),
        .HWDATA(hwdata), .HRDATA(hrdata), .HREADY(hready), .HRESP(hresp), .IQ_CLK(IQ_CLK),
        .GRP_ADDR(grp_addr), .GRP_WDATA(grp_wdata), .GRP_WE(grp_we), .GRP_RE(grp_re),
        .GRP_RDATA(grp_rdata), .GRP_READY(grp_ready)
    );

    wire psram_sck, psram_ce_n;
    wire [3:0] psram_sio_out, psram_sio_oe, psram_sio_in;
    wire remod_i, remod_q, irq_out, irq_grouper;
    // Keep the host interface at a defined idle value from time zero. Cocotb
    // drives these simulation-only registers for concurrent-host tests.
    reg host_cs = 1'b1, spi_sck = 1'b0, spi_mosi = 1'b0;
    wire spi_miso;
    // Deterministic, non-DC sigma-delta stimulus.  A live non-zero Z matrix
    // is required for the production eigenvector kernel (unlike the former
    // transaction-only ISR test, which could operate on all-zero training).
    reg [7:0] iq_prbs;
    always @(posedge IQ_CLK or negedge RESETB) begin
        if (!RESETB)
            iq_prbs <= 8'h1;
        else
            iq_prbs <= {iq_prbs[6:0], iq_prbs[7] ^ iq_prbs[5] ^ iq_prbs[4] ^ iq_prbs[3]};
    end
    trouper_top u_trouper (
        .IQ_CLK(IQ_CLK), .RESETB(RESETB),
        .IQ_DATA_I_0(iq_prbs[0]), .IQ_DATA_I_1(iq_prbs[2]),
        .IQ_DATA_I_2(iq_prbs[4]), .IQ_DATA_I_3(iq_prbs[6]),
        .IQ_DATA_Q_0(iq_prbs[1]), .IQ_DATA_Q_1(iq_prbs[3]),
        .IQ_DATA_Q_2(iq_prbs[5]), .IQ_DATA_Q_3(iq_prbs[7]),
        .REMOD_A_I(remod_i), .REMOD_A_Q(remod_q), .PSRAM_SCK(psram_sck), .PSRAM_CE_N(psram_ce_n),
        .PSRAM_SIO_OUT_0(psram_sio_out[0]), .PSRAM_SIO_OUT_1(psram_sio_out[1]),
        .PSRAM_SIO_OUT_2(psram_sio_out[2]), .PSRAM_SIO_OUT_3(psram_sio_out[3]),
        .PSRAM_SIO_IN_0(psram_sio_in[0]), .PSRAM_SIO_IN_1(psram_sio_in[1]),
        .PSRAM_SIO_IN_2(psram_sio_in[2]), .PSRAM_SIO_IN_3(psram_sio_in[3]),
        .PSRAM_SIO_OE_0(psram_sio_oe[0]), .PSRAM_SIO_OE_1(psram_sio_oe[1]),
        .PSRAM_SIO_OE_2(psram_sio_oe[2]), .PSRAM_SIO_OE_3(psram_sio_oe[3]),
        .HOST_CS(host_cs), .SPI_SCK(spi_sck), .SPI_MOSI(spi_mosi), .SPI_MISO(spi_miso),
        .GRP_ADDR_0(grp_addr[0]), .GRP_ADDR_1(grp_addr[1]), .GRP_ADDR_2(grp_addr[2]), .GRP_ADDR_3(grp_addr[3]),
        .GRP_ADDR_4(grp_addr[4]), .GRP_ADDR_5(grp_addr[5]), .GRP_ADDR_6(grp_addr[6]), .GRP_ADDR_7(grp_addr[7]),
        .GRP_WDATA_0(grp_wdata[0]), .GRP_WDATA_1(grp_wdata[1]), .GRP_WDATA_2(grp_wdata[2]), .GRP_WDATA_3(grp_wdata[3]),
        .GRP_WDATA_4(grp_wdata[4]), .GRP_WDATA_5(grp_wdata[5]), .GRP_WDATA_6(grp_wdata[6]), .GRP_WDATA_7(grp_wdata[7]),
        .GRP_WE(grp_we), .GRP_RE(grp_re),
        .GRP_RDATA_0(grp_rdata[0]), .GRP_RDATA_1(grp_rdata[1]), .GRP_RDATA_2(grp_rdata[2]), .GRP_RDATA_3(grp_rdata[3]),
        .GRP_RDATA_4(grp_rdata[4]), .GRP_RDATA_5(grp_rdata[5]), .GRP_RDATA_6(grp_rdata[6]), .GRP_RDATA_7(grp_rdata[7]),
        .GRP_READY(grp_ready), .IRQ_OUT(irq_out), .IRQ_GROUPER(irq_grouper)
    );
    psram_model #(.ADDR_BITS(16), .RD_LAUNCH_SKIP(3)) u_psram (
        .clk_32m(IQ_CLK), .rst_n(RESETB), .ce_n(psram_ce_n),
        .sio_out(psram_sio_out), .sio_oe(psram_sio_oe), .sio_in(psram_sio_in)
    );
endmodule
`default_nettype wire
