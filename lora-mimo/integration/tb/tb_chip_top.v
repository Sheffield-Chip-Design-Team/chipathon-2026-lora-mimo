// tb_chip_top.v
// End-to-end connectivity test for chip_top (Open Item #1): a real Grouper CPU,
// fetching a program from its own ROM, drives MMIO traffic that must traverse
// the entire cross-project path
//
//   picorv32 -> cpu_ss -> ahb_conn_buff CPU->periph pipe -> periph_ss
//   -> interconnect_ss (EXT_PERIPH decode) -> ext_ahb_m_if
//   -> ahb_to_grp_bridge  (HCLK 25 MHz  ->  IQ_CLK 32 MHz  bundled-data CDC)
//   -> trouper_top GRP_* bus -> register arbiter -> reg_bank
//
// with real RTL on both sides. Results are read back over Trouper's SPI slave
// port -- an oracle that shares none of the AHB/GRP path.
//
//   T1  MIMO_CTRL write (single ungated GRP write).
//   T2  W shadow bank 0x30..0x3F written 0xB0..0xBF -- GRP writes at every
//       byte lane (picorv32 replicates the store byte across all 4 AHB lanes).
//   T3  GRP read alignment: an aligned byte read returns the register, an
//       unaligned byte read returns 0. This is a real limitation of Grouper's
//       8-bit ext-periph port, not a bug in the bridge -- periph_ss
//       zero-extends ext_HRDATA into HRDATA[7:0] while picorv32 byte-extracts
//       a load from HRDATA[8*addr[1:0] +: 8]. Grouper firmware can only read
//       GRP registers at word-aligned byte offsets; Trouper's byte-packed
//       Z_kl / Z_kk / N_ACC windows are not fully readable this way.
//       See integration/planning/grp-ext-periph-byte-lane.md.
//
// This is the first *simulation* of grouper's local ahb_conn_buff CPU->periph
// pipeline patch (digital_ss.sv: "Lint-clean; NOT simulated"), of the
// CDC-hardened ahb_to_grp_bridge (F1/F3/F7) against real RTL end to end, and
// the first to drive GRP reads from real CPU code.
//
// Program: integration/fw/chip_top_smoke.S -> code.hex (loaded by rom_ss.sv via
// $readmemh from the working directory). Build + run: scripts/run_tb_chip_top.sh
// (Verilator 5, --binary --timing; iverilog cannot elaborate grouper dev RTL,
// see integration/scripts/check_chip_top.sh).

`timescale 1ns/1ps
`default_nettype none

module tb_chip_top;

    // ---- Clocks -----------------------------------------------------------
    reg hclk   = 1'b0;
    reg iq_clk = 1'b0;
    always #20.000  hclk   = ~hclk;    // 25   MHz  (Grouper HCLK, test chip)
    always #15.625  iq_clk = ~iq_clk;  // 32   MHz  (Trouper IQ_CLK)

    reg hresetn = 1'b0;

    // ---- Trouper radio pads: unused, tied idle --------------------------
    wire iq_i0 = 1'b0, iq_i1 = 1'b0, iq_i2 = 1'b0, iq_i3 = 1'b0;
    wire iq_q0 = 1'b0, iq_q1 = 1'b0, iq_q2 = 1'b0, iq_q3 = 1'b0;

    // ---- Grouper pads --------------------------------------------------
    wire        uart_tx;
    wire        uart_rx = 1'b1;
    wire [15:0] gpio;                   // driven by chip_top (P&R model), not here

    // ---- Trouper misc outputs ---------------------------------------
    wire remod_i, remod_q;
    wire psram_sck, psram_ce_n;
    wire psram_sio0, psram_sio1, psram_sio2, psram_sio3;
    wire irq_out;

    // ---- SPI oracle pads (host side) ------------------------------------
    reg  spi_cs   = 1'b1;
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

    localparam ROM = "code.hex";

    // Trouper channel-estimate readback (Z_kl pairs) is normally driven by
    // training_acc, which needs a full IQ preamble + training run to produce
    // anything. This is an interface test, not a DSP test: force the reg_bank
    // input wires to a known pattern (leave them forced; no IQ stimulus, so
    // training_acc has nothing real to say). reg_bank exposes bits [31:8] of
    // each, big-endian, at 0x40..: 0x40=i0[31:24] 0x45=q0[15:8] etc.
    task force_z_pattern;
        begin
            force dut.u_trouper.Zpair_i[0] = 32'h11223300;
            force dut.u_trouper.Zpair_q[0] = 32'h44556600;
            force dut.u_trouper.Zpair_i[1] = 32'h77889900;
            force dut.u_trouper.Zpair_q[1] = 32'hAABBCC00;
            force dut.u_trouper.Zpair_i[2] = 32'hDDEEF000;
            force dut.u_trouper.Zpair_q[2] = 32'h12345600;
        end
    endtask

    // =====================================================================
    // SPI master model (Mode 0, MSB first): 7-bit addr + R/W# bit in the
    // command byte, then data bytes; burst reads auto-increment the address.
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
            spi_byte({1'b1, a}, dump);
            spi_byte(8'h00, d);
            spi_stop;
        end
    endtask

    reg [7:0] burst [0:15];
    task spi_read_burst(input [6:0] a, input integer n);
        integer k; reg [7:0] dump;
        begin
            spi_start;
            spi_byte({1'b1, a}, dump);
            for (k = 0; k < n; k = k + 1) spi_byte(8'h00, burst[k]);
            spi_stop;
        end
    endtask

    // ---- Scoreboard --------------------------------------------------
    integer errors = 0;

    task check(input [511:0] name, input [7:0] got, input [7:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-46s got 0x%02h expected 0x%02h", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-46s 0x%02h", name, got);
            end
        end
    endtask

    // =====================================================================
    // Test sequence
    // =====================================================================
    reg [7:0] rd;
    integer   i;
    localparam [6:0] ADDR_CHIP_ID = 7'h00;   // RO, constant 0xA7
    localparam [6:0] ADDR_MIMO    = 7'h08;   // reset 0xF0; T1 writes 0x31
    localparam [6:0] ADDR_SCTHR_H = 7'h0C;   // T3 scratch: aligned read result
    localparam [6:0] ADDR_SCTHR_L = 7'h0D;   // T3 scratch: unaligned read result
    localparam [6:0] ADDR_W_BASE  = 7'h30;   // W shadow bank 0x30..0x3F
    localparam [6:0] ADDR_Z_BASE  = 7'h40;   // Z_kl readback 0x40..

    initial begin
`ifdef DUMP
        $dumpfile("tb_chip_top.vcd");
        $dumpvars(0, tb_chip_top);
`endif
        force_z_pattern;

        // Fail fast if code.hex is not where rom_ss.sv looks for it.
        $readmemh(ROM, dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory);
        if (dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory[0] === 32'hxxxxxxxx
            || dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory[0] === 32'h0) begin
            $display("FATAL  ROM word 0 is %08x -- code.hex not loaded (wrong CWD?)",
                     dut.u_grouper.u_grouper_soc_dig_ss.u_rom_ss.memory[0]);
            $finish;
        end

        hresetn = 1'b0;
        repeat (20) @(posedge hclk);
        hresetn = 1'b1;

        // Let the CPU run T1 (1 write), T2 (16 writes), T3 (2 reads + 2 writes).
        // Each GRP access blocks on HREADY for the full ahb_conn_buff + bridge
        // CDC round trip; 8000 HCLK is many times the worst case.
        repeat (8000) @(posedge hclk);

        // Oracle sanity: SPI path itself works, independent of the AHB path.
        spi_read(ADDR_CHIP_ID, rd);
        check("CHIP_ID over SPI (oracle sanity)", rd, 8'hA7);

        // Priming read (discard): the first SPI transaction after reset has
        // historically returned 0x00 regardless of contents (spi_slave quirk,
        // Open Risks #26); never let the checked read be the first.
        spi_read(ADDR_MIMO, rd);

        // ---- T1 ------------------------------------------------------
        spi_read(ADDR_MIMO, rd);
        check("T1  MIMO_CTRL  <- CPU GRP write", rd, 8'h31);

        // ---- T2: W shadow bank, every byte lane -------------------
        // Inline (not check()): $sformatf into check()'s packed-vector arg
        // comes through blank under Verilator, so summarise the 16 in one line.
        spi_read_burst(ADDR_W_BASE, 16);
        begin : t2
            integer bad;
            bad = 0;
            for (i = 0; i < 16; i = i + 1)
                if (burst[i] !== 8'hB0 + i[7:0]) begin
                    $display("FAIL  T2  W[0x%02h]  got 0x%02h expected 0x%02h",
                             8'h30 + i, burst[i], 8'hB0 + i[7:0]);
                    bad = bad + 1;
                end
            if (bad == 0)
                $display("pass  T2  W[0x30..0x3F] <- CPU GRP write, all 16 byte lanes  (0xB0..0xBF)");
            errors = errors + bad;
        end

        // ---- T3: GRP read alignment ------------------------------
        // Ground truth for the forced Z pattern (SPI peek path, all lanes).
        spi_read(ADDR_Z_BASE + 7'h00, rd); check("T3  Z[0x40] forced (SPI ground truth)", rd, 8'h11);
        spi_read(ADDR_Z_BASE + 7'h01, rd); check("T3  Z[0x41] forced (SPI ground truth)", rd, 8'h22);

        // CPU read results parked in SC_THR scratch by the firmware.
        spi_read(ADDR_SCTHR_H, rd);
        check("T3  CPU aligned GRP read (lbu 0x08 -> 0x0C)", rd, 8'h31);
        spi_read(ADDR_SCTHR_L, rd);
        check("T3  CPU unaligned GRP read returns 0 (lbu 0x09 -> 0x0D)", rd, 8'h00);
        $display("     ^ expected: Grouper 8-bit ext-periph port carries byte lane 0 only");
        $display("       (periph_ss HRDATA[7:0]) -- see grp-ext-periph-byte-lane.md");

        if (errors == 0)
            $display("\nTB PASS - T1 write, T2 all-lane writes, T3 read-alignment all as specified");
        else
            $display("\nTB FAIL - %0d error(s)", errors);
        $finish;
    end

    initial begin
        #1_000_000;
        $display("TB FAIL - timeout (no $finish reached)");
        $finish;
    end

endmodule

`default_nettype wire
