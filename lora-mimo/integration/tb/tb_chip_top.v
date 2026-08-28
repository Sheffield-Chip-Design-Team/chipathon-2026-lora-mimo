// tb_chip_top.v
// End-to-end connectivity test for chip_top (Open Item #1): a real Grouper CPU,
// fetching a 4-instruction program from its own ROM, drives a single MMIO byte
// write that must traverse the entire cross-project path
//
//   picorv32 -> cpu_ss -> ahb_conn_buff CPU->periph pipe -> periph_ss
//   -> interconnect_ss (EXT_PERIPH decode) -> ext_ahb_m_if
//   -> ahb_to_grp_bridge  (HCLK 25 MHz  ->  IQ_CLK 32 MHz  bundled-data CDC)
//   -> trouper_top GRP_* bus -> register arbiter -> reg_bank
//
// and land in Trouper's MIMO_CTRL register. The result is read back over
// Trouper's SPI slave port, an oracle that shares none of the AHB/GRP path, so
// a bug anywhere in that path cannot also fool the checker.
//
// This is the first *simulation* of grouper's local ahb_conn_buff CPU->periph
// pipeline patch (digital_ss.sv: "Lint-clean; NOT simulated") and of the
// CDC-hardened ahb_to_grp_bridge (F1/F3/F7) against real RTL on both sides.
//
// Program: integration/fw/chip_top_smoke.S  ->  code.hex  (loaded by rom_ss.sv
// via $readmemh from the simulator's working directory). Build it with
// integration/fw/build_chip_top_smoke.sh; scripts/run_tb_chip_top.sh does both.
//
// Simulator: Verilator 5.x, --binary --timing (grouper dev RTL uses
// `case () inside`, which iverilog rejects -- see
// integration/scripts/check_chip_top.sh). Run: scripts/run_tb_chip_top.sh

`timescale 1ns/1ps
`default_nettype none

module tb_chip_top;

    // ---- Clocks -----------------------------------------------------------
    // chip_top: HCLK is Grouper's 25 MHz test-chip clock, IQ_CLK Trouper's
    // 32 MHz. Deliberately unrelated -- exercises the bridge CDC.
    reg hclk   = 1'b0;
    reg iq_clk = 1'b0;
    always #20.000  hclk   = ~hclk;    // 25   MHz
    always #15.625  iq_clk = ~iq_clk;  // 32   MHz

    reg hresetn = 1'b0;

    // ---- Trouper radio pads: unused, tied idle ---------------------------
    wire iq_i0 = 1'b0, iq_i1 = 1'b0, iq_i2 = 1'b0, iq_i3 = 1'b0;
    wire iq_q0 = 1'b0, iq_q1 = 1'b0, iq_q2 = 1'b0, iq_q3 = 1'b0;

    // ---- Grouper pads --------------------------------------------------
    wire        uart_tx;
    wire        uart_rx = 1'b1;         // UART idle high
    wire [15:0] gpio;                   // driven by chip_top (P&R model), not here

    // ---- Trouper misc outputs ---------------------------------------
    wire remod_i, remod_q;
    wire psram_sck, psram_ce_n;
    wire psram_sio0, psram_sio1, psram_sio2, psram_sio3;
    wire irq_out;

    // ---- SPI oracle pads (host side) ------------------------------------
    reg  spi_cs   = 1'b1;               // active low
    reg  spi_sck  = 1'b0;
    reg  spi_mosi = 1'b0;
    wire spi_miso;

    // =====================================================================
    // DUT
    // =====================================================================
    chip_top dut (
        .HCLK        (hclk),
        .IQ_CLK      (iq_clk),
        .HRESETn     (hresetn),

        .IQ_DATA_I_0 (iq_i0), .IQ_DATA_I_1 (iq_i1),
        .IQ_DATA_I_2 (iq_i2), .IQ_DATA_I_3 (iq_i3),
        .IQ_DATA_Q_0 (iq_q0), .IQ_DATA_Q_1 (iq_q1),
        .IQ_DATA_Q_2 (iq_q2), .IQ_DATA_Q_3 (iq_q3),
        .REMOD_A_I   (remod_i), .REMOD_A_Q (remod_q),

        .PSRAM_SCK   (psram_sck), .PSRAM_CE_N (psram_ce_n),
        .PSRAM_SIO_0 (psram_sio0), .PSRAM_SIO_1 (psram_sio1),
        .PSRAM_SIO_2 (psram_sio2), .PSRAM_SIO_3 (psram_sio3),

        .HOST_CS     (spi_cs),
        .SPI_SCK     (spi_sck),
        .SPI_MOSI    (spi_mosi),
        .SPI_MISO    (spi_miso),

        .IRQ_OUT     (irq_out),

        .UART_TX     (uart_tx),
        .UART_RX     (uart_rx),
        .GPIO_0 (gpio[0]),  .GPIO_1 (gpio[1]),  .GPIO_2 (gpio[2]),  .GPIO_3 (gpio[3]),
        .GPIO_4 (gpio[4]),  .GPIO_5 (gpio[5]),  .GPIO_6 (gpio[6]),  .GPIO_7 (gpio[7]),
        .GPIO_8 (gpio[8]),  .GPIO_9 (gpio[9]),  .GPIO_10(gpio[10]), .GPIO_11(gpio[11]),
        .GPIO_12(gpio[12]), .GPIO_13(gpio[13]), .GPIO_14(gpio[14]), .GPIO_15(gpio[15])
    );

    // ROM hierarchical handle -- rom_ss.sv self-loads code.hex via $readmemh,
    // but re-load explicitly so a wrong working directory fails loud here
    // instead of as a mysterious CPU lockup, and so we can assert it is non-empty.
    localparam ROM = "code.hex";

    // =====================================================================
    // SPI master model (Mode 0, MSB first) -- ported verbatim in behaviour
    // from trouper's tb_trouper_grp_arb.v / the grouper<->trouper feature-branch
    // testbench: 7-bit addr + R/W# bit in the command byte, then data bytes.
    // =====================================================================
    localparam real SCK_HALF = 62.5;   // 8 MHz, within Trouper's 10 MHz max

    task spi_byte(input [7:0] tx, output [7:0] rx);
        integer b;
        begin
            for (b = 7; b >= 0; b = b - 1) begin
                spi_mosi = tx[b];
                #(SCK_HALF);
                spi_sck = 1'b1;
                rx = {rx[6:0], spi_miso};
                #(SCK_HALF);
                spi_sck = 1'b0;
            end
        end
    endtask

    task spi_start; begin spi_cs = 1'b0; #(SCK_HALF); end endtask
    task spi_stop;  begin #(SCK_HALF); spi_cs = 1'b1; #500; end endtask

    task spi_read(input [6:0] a, output [7:0] d);
        reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b1, a}, dump);   // command: R/W#=1 (read), addr
            spi_byte(8'h00, d);          // one data byte clocked out on MISO
            spi_stop;
        end
    endtask

    // ---- Scoreboard ----------------------------------------------------
    integer errors = 0;

    task check(input [511:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-44s got 0x%02h expected 0x%02h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-44s 0x%02h", name, got);
            end
        end
    endtask

    // =====================================================================
    // Test sequence
    // =====================================================================
    reg [7:0] rd;
    localparam [6:0] ADDR_CHIP_ID  = 7'h00;   // RO, constant 0xA7
    localparam [6:0] ADDR_MIMO     = 7'h08;   // reset 0xF0; program writes 0x31

    integer i;

    initial begin
`ifdef DUMP
        $dumpfile("tb_chip_top.vcd");
        $dumpvars(0, tb_chip_top);
`endif
        // Fail fast if code.hex is not where rom_ss.sv looks for it.
        $readmemh(ROM, dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory);
        if (dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory[0] === 32'hxxxxxxxx
            || dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory[0] === 32'h0) begin
            $display("FATAL  ROM word 0 is %08x -- code.hex not loaded (wrong CWD?)",
                     dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory[0]);
            $finish;
        end

        // Reset: hold both domains well past their 2-FF resync depth.
        hresetn = 1'b0;
        repeat (20) @(posedge hclk);
        hresetn = 1'b1;

        // Let the CPU run lui/addi/sb/j. The single sb blocks on HREADY for the
        // whole ahb_conn_buff wait-state + bridge CDC round trip; give a wide
        // margin over that (a few thousand HCLK cycles is >100x the worst case).
        repeat (4000) @(posedge hclk);

        // Sanity: the SPI oracle itself works (independent of the AHB path).
        spi_read(ADDR_CHIP_ID, rd);
        check("CHIP_ID over SPI (oracle sanity)", rd, 8'hA7);

        // Priming read: discard. The very first SPI transaction against a
        // freshly reset trouper spi_slave has historically returned 0x00
        // regardless of register contents (a spi_slave quirk, not this path);
        // Open Risks #26 hardening may have fixed it, but prime anyway so the
        // checked read is never the first.
        spi_read(ADDR_MIMO, rd);

        // Independent oracle: read MIMO_CTRL back over SPI.
        spi_read(ADDR_MIMO, rd);
        check("MIMO_CTRL after CPU->AHB->bridge->GRP write", rd, 8'h31);

        if (errors == 0)
            $display("\nTB PASS - Grouper CPU -> AHB -> ahb_to_grp_bridge -> Trouper reg_bank write verified over SPI");
        else
            $display("\nTB FAIL - %0d error(s)", errors);
        $finish;
    end

    // Global timeout
    initial begin
        #500_000;
        $display("TB FAIL - timeout (no $finish reached)");
        $finish;
    end

endmodule

`default_nettype wire
