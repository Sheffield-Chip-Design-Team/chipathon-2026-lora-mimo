// tb_fpga_top.v
// Pre-synthesis sanity check for fpga_top.v (the FPGA bring-up top -- see ../rtl/fpga_top.v).
// Unlike tb_grouper_trouper_top.v (which drives an external SPI master testbench task against
// grouper_trouper_top.v's exposed pads), this testbench drives nothing: fpga_top's firmware
// bit-bangs its own SPI readback internally via ahb_gpio_dbg.v, exactly mirroring what happens
// standalone on real hardware. This TB only checks the resulting led[2:0] status latch --
// the same observable a bring-up engineer gets from the board's LEDs, so a pass here is
// direct evidence the same firmware image will report PASS on the real Arty board.
//
// Run: see ../scripts/run.sh

`timescale 1ns/1ps
`default_nettype none

module tb_fpga_top;

    // ---- Clock / reset ----
    reg clk = 1'b0;
    always #15.625 clk = ~clk;        // 32 MHz, matches Trouper's single clock domain

    reg resetn = 1'b0;

    wire [2:0] led;
    wire dbg_host_cs, dbg_spi_sck, dbg_spi_mosi, dbg_spi_miso;

    fpga_top dut (
        .HCLK         (clk),
        .HRESETn      (resetn),
        .led          (led),
        .dbg_host_cs  (dbg_host_cs),
        .dbg_spi_sck  (dbg_spi_sck),
        .dbg_spi_mosi (dbg_spi_mosi),
        .dbg_spi_miso (dbg_spi_miso)
    );

    integer errors = 0;

    task check_bit(input [255:0] name, input got, input exp);
        begin
            if (got !== exp) begin
                $display("FAIL  %-24s got %b expected %b", name, got, exp);
                errors = errors + 1;
            end else begin
                $display("pass  %-24s %b", name, got);
            end
        end
    endtask

    initial begin
        $dumpfile("tb_fpga_top.vcd");
        $dumpvars(1, tb_fpga_top);

        repeat (4) @(posedge clk);
        resetn = 1'b1;

        // Generous margin: the firmware runs the AHB write, two full 8-bit bit-banged SPI
        // transactions (priming + real readback, each with settle-delay loops either side), and
        // the compare/latch -- an order of magnitude more dynamic instructions than the plain
        // 4-instruction AHB-only program in tb_grouper_trouper_top.v.
        repeat (20000) @(posedge clk);

        check_bit("led[0] DONE", led[0], 1'b1);
        check_bit("led[1] PASS", led[1], 1'b1);
        check_bit("led[2] FAIL", led[2], 1'b0);

        if (errors == 0) $display("\nTB PASS — picorv32 -> AHB write -> Trouper reg_bank, independently confirmed by firmware's own bit-banged SPI readback, latched to LEDs");
        else             $display("\nTB FAIL — %0d error(s)", errors);
        $finish;
    end

    // Global timeout
    initial begin
        #3_000_000;
        $display("TB FAIL — timeout");
        $finish;
    end

endmodule

`default_nettype wire
