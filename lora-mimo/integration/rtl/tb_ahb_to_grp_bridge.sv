`timescale 1ns/1ps
`default_nettype none

// Minimal asynchronous-clock regression for ahb_to_grp_bridge.
module tb_ahb_to_grp_bridge;
    reg hclk = 1'b0;
    reg iq_clk = 1'b0;
    reg resetn = 1'b0;
    always #31.25 hclk = ~hclk;  // 16 MHz
    always #15.625 iq_clk = ~iq_clk; // 32 MHz

    reg [7:0] haddr = 8'd0, hwdata = 8'd0;
    reg hwrite = 1'b0;
    reg [1:0] htrans = 2'b00;
    wire [7:0] hrdata;
    wire hready, hresp;
    wire [7:0] grp_addr, grp_wdata;
    wire grp_we, grp_re;
    reg [7:0] grp_rdata = 8'd0;
    reg grp_ready = 1'b1;
    reg [7:0] regs [0:255];

    ahb_to_grp_bridge #(.HOLD_CYCLES(2)) dut (
        .HCLK(hclk), .HRESETn(resetn),
        .HADDR(haddr), .HWRITE(hwrite), .HTRANS(htrans), .HWDATA(hwdata),
        .HRDATA(hrdata), .HREADY(hready), .HRESP(hresp),
        .IQ_CLK(iq_clk),
        .GRP_ADDR(grp_addr), .GRP_WDATA(grp_wdata), .GRP_WE(grp_we),
        .GRP_RE(grp_re), .GRP_RDATA(grp_rdata), .GRP_READY(grp_ready)
    );

    // A simple synchronous model of Trouper's GRP register file.
    always @(posedge iq_clk) begin
        if (grp_we)
            regs[grp_addr] <= grp_wdata;
        if (grp_re)
            grp_rdata <= regs[grp_addr];
    end

    task automatic wait_for_ready;
        begin
            while (hready !== 1'b0)
                @(posedge hclk);
            while (hready !== 1'b1)
                @(posedge hclk);
        end
    endtask

    task automatic ahb_write(input [7:0] addr, input [7:0] data);
        begin
            @(negedge hclk);
            haddr <= addr;
            hwrite <= 1'b1;
            htrans <= 2'b10;
            @(negedge hclk);
            htrans <= 2'b00;
            hwdata <= data;
            wait_for_ready();
        end
    endtask

    task automatic ahb_read(input [7:0] addr, output [7:0] data);
        begin
            @(negedge hclk);
            haddr <= addr;
            hwrite <= 1'b0;
            htrans <= 2'b10;
            @(negedge hclk);
            htrans <= 2'b00;
            wait_for_ready();
            data = hrdata;
        end
    endtask

    reg [7:0] readback;
    initial begin
        regs[8'h3c] = 8'h00;
        repeat (4) @(posedge iq_clk);
        resetn = 1'b1;

        ahb_write(8'h3c, 8'ha5);
        if (regs[8'h3c] !== 8'ha5)
            $fatal(1, "CDC write failed: expected a5, got %02x", regs[8'h3c]);
        ahb_read(8'h3c, readback);
        if (readback !== 8'ha5)
            $fatal(1, "CDC read failed: expected a5, got %02x", readback);

        $display("PASS: asynchronous AHB-to-GRP CDC write/read");
        $finish;
    end
endmodule

`default_nettype wire
