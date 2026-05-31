// picorv32_wrap.v
// PicoRV32 RV32IM wrapper with AHB-Lite master port and 2 kB CPU SRAM.
//
// Memory map seen by PicoRV32:
//   0x00000–0x007FF  Unified SRAM (2 kB, text + data + stack)
//   0x10000–0x103FF  AHB-Lite peripheral space (reg bank, SPI master, IRQ ctrl)
//
// SRAM uses TWO 1024x8 OCD hard macros.  Each macro carries two byte lanes
// via a 2-phase access scheme:
//
//   Macro A: byte lane 0 (phase 0, addr {word[8:0], 1'b0})
//            byte lane 2 (phase 1, addr {word[8:0], 1'b1})
//   Macro B: byte lane 1 (phase 0, addr {word[8:0], 1'b0})
//            byte lane 3 (phase 1, addr {word[8:0], 1'b1})
//
// mem_ready asserts 2 cycles after the request (1 extra cycle vs the 4-macro
// version).  PicoRV32 handles wait states natively via mem_valid/mem_ready.
//
// Firmware loader works byte-at-a-time during cpu_reset; byte_sel[1] selects
// the SRAM phase (0 for bytes 0/1, 1 for bytes 2/3).
//
// GF180MCU, 3.3V, 32 MHz single clock domain

module picorv32_wrap (
    input  wire        clk_32m,
    input  wire        rst_n,

    // CPU reset (active-high, from CPU_RESET register)
    input  wire        cpu_reset,

    // IRQ input (level-high)
    input  wire        irq_in,

    // AHB-Lite master output
    output wire [31:0] HADDR,
    output wire [1:0]  HTRANS,
    output wire        HWRITE,
    output wire [2:0]  HSIZE,
    output wire [2:0]  HBURST,
    output wire [31:0] HWDATA,
    input  wire [31:0] HRDATA,
    input  wire        HREADY,
    input  wire        HRESP,

    // Firmware-load port (byte-wide, from spi_slave, SPI clock domain)
    input  wire [11:0] fw_ld_addr,
    input  wire [7:0]  fw_ld_wdata,
    input  wire        fw_ld_we,
    output wire [7:0]  fw_ld_rdata,
    output wire        fw_ld_ready
);

    assign fw_ld_ready = 1'b1;

    // -----------------------------------------------------------------------
    // PicoRV32 native memory interface
    // -----------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    wire [31:0] irq = {31'd0, irq_in};

    picorv32 #(
        .ENABLE_MUL           (1),
        .ENABLE_DIV           (1),
        .ENABLE_IRQ           (1),
        .ENABLE_REGS_DUALPORT (1),
        .STACKADDR            (32'h00000800)   // top of 2 kB
    ) u_cpu (
        .clk       (clk_32m),
        .resetn    (!cpu_reset && rst_n),
        .mem_valid (mem_valid),
        .mem_instr (mem_instr),
        .mem_ready (mem_ready),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_wstrb (mem_wstrb),
        .mem_rdata (mem_rdata),
        .irq       (irq),
        .eoi              (),
        .trap             (),
        .mem_la_read      (),
        .mem_la_write     (),
        .mem_la_addr      (),
        .mem_la_wdata     (),
        .mem_la_wstrb     (),
        .pcpi_valid       (),
        .pcpi_insn        (),
        .pcpi_rs1         (),
        .pcpi_rs2         (),
        .pcpi_wr          (1'b0),
        .pcpi_rd          (32'd0),
        .pcpi_wait        (1'b0),
        .pcpi_ready       (1'b0)
    );

    // -----------------------------------------------------------------------
    // Address decoder — 2 kB SRAM at 0x000–0x7FF
    // -----------------------------------------------------------------------
    wire addr_is_sram   = (mem_addr[31:11] == 21'd0);
    wire addr_is_periph = (mem_addr[31:10] == 22'h40);

    // -----------------------------------------------------------------------
    // Firmware loader CDC into the 32 MHz domain
    // -----------------------------------------------------------------------
    reg        fw_we_sync0, fw_we_sync1, fw_we_sync2;
    reg [11:0] fw_addr_meta, fw_addr_sync;
    reg [7:0]  fw_wdata_meta, fw_wdata_sync;

    wire fw_we_pulse = fw_we_sync1 && !fw_we_sync2;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            fw_we_sync0   <= 1'b0;
            fw_we_sync1   <= 1'b0;
            fw_we_sync2   <= 1'b0;
            fw_addr_meta  <= 12'd0;
            fw_addr_sync  <= 12'd0;
            fw_wdata_meta <= 8'd0;
            fw_wdata_sync <= 8'd0;
        end else begin
            fw_we_sync0   <= fw_ld_we;
            fw_we_sync1   <= fw_we_sync0;
            fw_we_sync2   <= fw_we_sync1;
            fw_addr_meta  <= fw_ld_addr;
            fw_addr_sync  <= fw_addr_meta;
            fw_wdata_meta <= fw_ld_wdata;
            fw_wdata_sync <= fw_wdata_meta;
        end
    end

    wire [1:0] fw_byte_sel  = fw_addr_sync[1:0];
    wire [8:0] fw_word_addr = fw_addr_sync[10:2];  // 9-bit word addr, [11] ignored

    // -----------------------------------------------------------------------
    // Two-phase SRAM FSM
    //
    //   P_IDLE: idle.  On cpu_sram_req, present phase-0 address this cycle.
    //   P_PH1:  phase-0 results on macroA/B Q.  Latch byte0/1.
    //           Present phase-1 address this cycle.
    //   P_PH2:  phase-1 results on macroA/B Q.  Assemble 32-bit word.
    //           Assert mem_ready this cycle.
    // -----------------------------------------------------------------------
    localparam P_IDLE = 2'd0;
    localparam P_PH1  = 2'd1;
    localparam P_PH2  = 2'd2;

    reg [1:0]  sram_state;
    reg [8:0]  word_addr_r;
    reg [3:0]  wstrb_r;
    reg [31:0] wdata_r;
    reg [7:0]  byte0_r, byte1_r;

    wire        cpu_sram_req = mem_valid && addr_is_sram && !cpu_reset;
    wire [8:0]  word_addr    = mem_addr[10:2];

    // SRAM macro outputs
    wire [7:0] macA_q, macB_q;

    // Combinatorial SRAM input mux
    reg [9:0]  sram_addr;
    reg        macA_cen,  macB_cen;
    reg        macA_gwen, macB_gwen;
    reg [7:0]  macA_d,    macB_d;

    always @(*) begin
        sram_addr  = 10'd0;
        macA_cen   = 1'b1;
        macB_cen   = 1'b1;
        macA_gwen  = 1'b1;
        macB_gwen  = 1'b1;
        macA_d     = 8'd0;
        macB_d     = 8'd0;

        if (cpu_reset) begin
            if (fw_we_pulse) begin
                // Single-byte write during firmware load
                case (fw_byte_sel)
                    2'd0: begin
                        sram_addr = {fw_word_addr, 1'b0};
                        macA_cen  = 1'b0; macA_gwen = 1'b0;
                        macA_d    = fw_wdata_sync;
                    end
                    2'd1: begin
                        sram_addr = {fw_word_addr, 1'b0};
                        macB_cen  = 1'b0; macB_gwen = 1'b0;
                        macB_d    = fw_wdata_sync;
                    end
                    2'd2: begin
                        sram_addr = {fw_word_addr, 1'b1};
                        macA_cen  = 1'b0; macA_gwen = 1'b0;
                        macA_d    = fw_wdata_sync;
                    end
                    default: begin  // 2'd3
                        sram_addr = {fw_word_addr, 1'b1};
                        macB_cen  = 1'b0; macB_gwen = 1'b0;
                        macB_d    = fw_wdata_sync;
                    end
                endcase
            end else begin
                // Continuous read — keeps SRAM presenting fw address for readback
                sram_addr = {fw_word_addr, fw_byte_sel[1]};
                macA_cen  = 1'b0;
                macB_cen  = 1'b0;
            end
        end else begin
            case (sram_state)
                P_IDLE: begin
                    if (cpu_sram_req) begin
                        // Phase 0: lower two byte lanes
                        sram_addr  = {word_addr, 1'b0};
                        macA_cen   = 1'b0;   macB_cen  = 1'b0;
                        macA_gwen  = !mem_wstrb[0];
                        macB_gwen  = !mem_wstrb[1];
                        macA_d     = mem_wdata[7:0];
                        macB_d     = mem_wdata[15:8];
                    end
                end
                P_PH1: begin
                    // Phase 1: upper two byte lanes
                    sram_addr  = {word_addr_r, 1'b1};
                    macA_cen   = 1'b0;   macB_cen  = 1'b0;
                    macA_gwen  = !wstrb_r[2];
                    macB_gwen  = !wstrb_r[3];
                    macA_d     = wdata_r[23:16];
                    macB_d     = wdata_r[31:24];
                end
                default: begin
                    // P_PH2: no SRAM access; just asserting mem_ready
                end
            endcase
        end
    end

    // FSM sequential updates
    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            sram_state  <= P_IDLE;
            word_addr_r <= 9'd0;
            wstrb_r     <= 4'd0;
            wdata_r     <= 32'd0;
            byte0_r     <= 8'd0;
            byte1_r     <= 8'd0;
        end else if (cpu_reset) begin
            sram_state  <= P_IDLE;
        end else begin
            case (sram_state)
                P_IDLE: begin
                    if (cpu_sram_req) begin
                        word_addr_r <= word_addr;
                        wstrb_r     <= mem_wstrb;
                        wdata_r     <= mem_wdata;
                        sram_state  <= P_PH1;
                    end
                end
                P_PH1: begin
                    // Latch phase-0 results; phase-1 address presented this cycle
                    byte0_r    <= macA_q;
                    byte1_r    <= macB_q;
                    sram_state <= P_PH2;
                end
                P_PH2: begin
                    sram_state <= P_IDLE;
                end
                default: sram_state <= P_IDLE;
            endcase
        end
    end

    wire        sram_ready = (sram_state == P_PH2);
    // byte0=macA_q_ph0 (byte0_r), byte1=macB_q_ph0 (byte1_r),
    // byte2=macA_q (ph1), byte3=macB_q (ph1)
    wire [31:0] sram_rdata = {macB_q, macA_q, byte1_r, byte0_r};

    // fw readback: Q is from previous cycle (1-cycle SRAM latency); SPI
    // synchronizer adds several cycles so this is always stable when read.
    assign fw_ld_rdata = (fw_byte_sel[0] == 1'b0) ? macA_q : macB_q;

    // -----------------------------------------------------------------------
    // SRAM macros — Macro A (byte lanes 0/2), Macro B (byte lanes 1/3)
    // -----------------------------------------------------------------------
    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_cpu_sram_A (
        .CLK  (clk_32m),
        .CEN  (macA_cen),
        .GWEN (macA_gwen),
        .WEN  (8'h00),
        .A    (sram_addr),
        .D    (macA_d),
        .Q    (macA_q)
    );

    gf180mcu_ocd_ip_sram__sram1024x8m8wm1 u_cpu_sram_B (
        .CLK  (clk_32m),
        .CEN  (macB_cen),
        .GWEN (macB_gwen),
        .WEN  (8'h00),
        .A    (sram_addr),
        .D    (macB_d),
        .Q    (macB_q)
    );

    // -----------------------------------------------------------------------
    // AHB-Lite master bridge (peripheral accesses)
    // PicoRV32 native interface -> AHB-Lite
    // -----------------------------------------------------------------------
    localparam AHB_IDLE = 2'd0;
    localparam AHB_ADDR = 2'd1;
    localparam AHB_DATA = 2'd2;

    reg [1:0]  ahb_state;
    reg [31:0] ahb_addr_lat;
    reg        ahb_write_lat;
    reg [31:0] ahb_wdata_lat;
    reg        ahb_valid_r;
    reg [31:0] ahb_rdata_r;

    assign HADDR  = (ahb_state == AHB_ADDR || ahb_state == AHB_DATA)
                    ? ahb_addr_lat : 32'd0;
    assign HTRANS = (ahb_state == AHB_ADDR) ? 2'b10 : 2'b00;
    assign HWRITE = ahb_write_lat;
    assign HSIZE  = 3'b010;
    assign HBURST = 3'b000;
    assign HWDATA = ahb_wdata_lat;

    always @(posedge clk_32m or negedge rst_n) begin
        if (!rst_n) begin
            ahb_state     <= AHB_IDLE;
            ahb_addr_lat  <= 32'd0;
            ahb_write_lat <= 1'b0;
            ahb_wdata_lat <= 32'd0;
            ahb_valid_r   <= 1'b0;
            ahb_rdata_r   <= 32'd0;
        end else begin
            ahb_valid_r <= 1'b0;

            case (ahb_state)
                AHB_IDLE: begin
                    if (mem_valid && addr_is_periph) begin
                        ahb_addr_lat  <= mem_addr;
                        ahb_write_lat <= (mem_wstrb != 4'd0);
                        ahb_wdata_lat <= mem_wdata;
                        ahb_state     <= AHB_ADDR;
                    end
                end

                AHB_ADDR: begin
                    ahb_state <= AHB_DATA;
                end

                AHB_DATA: begin
                    if (HREADY) begin
                        ahb_rdata_r <= HRDATA;
                        ahb_valid_r <= 1'b1;
                        ahb_state   <= AHB_IDLE;
                    end
                end

                default: ahb_state <= AHB_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // mem_ready / mem_rdata mux
    // -----------------------------------------------------------------------
    assign mem_ready = (addr_is_sram   && sram_ready) ||
                       (addr_is_periph && ahb_valid_r) ||
                       (!addr_is_sram && !addr_is_periph && mem_valid);

    assign mem_rdata = addr_is_sram   ? sram_rdata :
                       addr_is_periph ? ahb_rdata_r : 32'd0;

endmodule
