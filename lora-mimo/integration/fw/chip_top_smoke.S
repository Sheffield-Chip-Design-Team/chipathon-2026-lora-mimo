/*
 * chip_top_smoke.S
 * RV32EMC program for the chip_top end-to-end connectivity testbench
 * (integration/tb/tb_chip_top.v). Exercises the full cross-project path
 *
 *   picorv32 -> cpu_ss -> ahb_conn_buff CPU->periph pipe -> periph_ss
 *   -> interconnect_ss (EXT_PERIPH decode) -> ext_ahb_m_if
 *   -> ahb_to_grp_bridge  (HCLK 25 MHz  ->  IQ_CLK 32 MHz  bundled-data CDC)
 *   -> trouper_top GRP_* bus -> register arbiter -> reg_bank
 *
 * with real RTL on both sides, driven only by instructions the Grouper CPU
 * fetches from its own ROM.
 *
 * Memory map (grouper hw/rtl/interconnect_ss.sv):
 *   0x0000_0000               ROM (this program, reset vector)
 *   0x8001_0000..0x8001_ffff  External Peripherals -> ext_ahb_m_if -> bridge
 * The bridge sees only HADDR[7:0], so 0x8001_00NN addresses Trouper reg 0xNN
 * (trouper src/control/reg_bank.v; "Register Map.md").
 *
 * Tests (all checked by the testbench over Trouper's independent SPI slave):
 *
 *   T1  MIMO_CTRL write.  Store 0x31 to reg 0x08.  Reset value 0xF0; readback
 *       {antenna_en,2'b0,mimo_mode} = 0x31.  Single ungated GRP write.
 *
 *   T2  W shadow bank, all 16 byte lanes.  Store 0xB0..0xBF to 0x30..0x3F,
 *       one byte per address, back to back.  reg_bank accepts 0x30..0x3F while
 *       W_valid is low.  picorv32 replicates the store byte across all four
 *       AHB byte lanes (mem_la_wdata = {4{rs2[7:0]}}), and periph_ss forwards
 *       HWDATA[7:0], so GRP *writes* work at every byte address regardless of
 *       alignment.
 *
 *   T3  GRP read alignment.  reg_bank.SC_THR (0x0C/0x0D) is used as scratch
 *       (RW, ungated, full 8-bit).
 *         - aligned:   lbu 0x08 (MIMO, = 0x31)  -> sb 0x0C   expect 0x0C == 0x31
 *         - unaligned: lbu 0x09 (SF_CFG, = 0x07) -> sb 0x0D   expect 0x0D == 0x00
 *       The unaligned read returns 0 by construction: periph_ss zero-extends
 *       the 8-bit ext_HRDATA into HRDATA[7:0] (periph_ss.sv ~L597), but
 *       picorv32 byte-extracts a load from HRDATA[8*addr[1:0] +: 8]
 *       (picorv32.v ~L421).  So Grouper firmware can only read GRP registers
 *       whose byte offset is a multiple of 4 -- Trouper's byte-packed Z_kl /
 *       Z_kk / N_ACC readback windows are NOT fully readable this way.  See
 *       integration/planning/grp-ext-periph-byte-lane.md.
 *
 * Each GRP access stalls HREADY for the whole ahb_conn_buff wait-state +
 * bridge CDC round trip, so lbu/sb block until complete -- no software delay
 * or polling.  No RAM / stack is touched (state in x5..x13, RV32E-legal).
 */

    .option norvc                 /* plain 32-bit encodings; keeps code.hex
                                     trivially inspectable */
    .section .text.init, "ax", @progbits
    .global _start
_start:
    lui   x5,  0x80010            /* x5 = 0x8001_0000  ext-periph window base   */

    /* ---- T1: MIMO_CTRL (0x08) <- 0x31 -------------------------------- */
    addi  x6,  x0, 0x31
    sb    x6,  0x8(x5)

    /* ---- T2: W shadow bank 0x30..0x3F <- 0xB0..0xBF ---------------- */
    addi  x7,  x0, 0             /* i = 0                                    */
    addi  x8,  x0, 16           /* loop bound                               */
    addi  x11, x0, 0xB0         /* value base                               */
.Lw:
    add   x9,  x5, x7           /* x9  = 0x8001_0000 + i                    */
    add   x10, x11, x7          /* x10 = 0xB0 + i                           */
    sb    x10, 0x30(x9)         /* [0x8001_0030 + i] <= 0xB0 + i            */
    addi  x7,  x7, 1
    bne   x7,  x8, .Lw

    /* ---- T3: GRP read alignment (SC_THR 0x0C/0x0D as scratch) ------ */
    lbu   x12, 0x8(x5)          /* aligned   read: MIMO  -> 0x31            */
    sb    x12, 0xC(x5)          /* 0x0C <= 0x31  (expect readback 0x31)     */
    lbu   x13, 0x9(x5)          /* unaligned read: SF_CFG -> 0x00           */
    sb    x13, 0xD(x5)          /* 0x0D <= 0x00  (expect readback 0x00)     */

.Lspin:
    jal   x0, .Lspin
