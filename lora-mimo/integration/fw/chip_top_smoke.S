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
 * The bridge sees only HADDR[7:0], so 0x8001_00NN addresses Trouper reg 0xNN.
 *
 * Tests (checked by the testbench over Trouper's independent SPI slave):
 *
 *   T1  MIMO_CTRL write.  Store 0x31 to reg 0x08.  Reset value 0xF0; readback
 *       {antenna_en,2'b0,mimo_mode} = 0x31.
 *
 *   T2  W shadow bank byte lanes.  Store 0xB3..0xBF to 0x33..0x3F (offsets
 *       0x30..0x32 are left for T3b).  Covers GRP writes at every addr[1:0].
 *
 *   T3a GRP single-byte read, aligned vs unaligned.  SC_THR (0x0C/0x0D, RW,
 *       ungated, full 8-bit) is scratch.
 *         lbu 0x08 (MIMO,  = 0x31) -> sb 0x0C    expect 0x0C == 0x31
 *         lbu 0x09 (SF_CFG,= 0x07) -> sb 0x0D    expect 0x0D == 0x07
 *       0x09 is a non-word-aligned offset; it reads correctly only because
 *       periph_ss now replicates ext read data across all byte lanes (grouper
 *       local integration patch -- see grp-ext-periph-byte-lane.md).  Before
 *       that fix this read returned 0x00.
 *
 *   T3b Multi-byte field reconstruction.  Byte-copy Trouper's Z_01_I readback
 *       (0x40..0x42, top-24-bit big-endian, force-loaded by the testbench)
 *       into W shadow bytes 0x30..0x32.  Exercises unaligned GRP reads (0x41,
 *       0x42) and unaligned GRP writes (0x31, 0x32) composed into one field
 *       copy -- the Trouper-estimates -> Grouper -> Trouper-CSR flow, minus
 *       the weight-gen maths.
 *
 * Each GRP access stalls HREADY for the whole ahb_conn_buff wait-state +
 * bridge CDC round trip, so lbu/sb block until complete.  No RAM / stack is
 * touched (state in x5..x14, RV32E-legal).
 */

    .option norvc
    .section .text.init, "ax", @progbits
    .global _start
_start:
    lui   x5,  0x80010            /* x5 = 0x8001_0000  ext-periph window base   */

    /* ---- T1: MIMO_CTRL (0x08) <- 0x31 -------------------------------- */
    addi  x6,  x0, 0x31
    sb    x6,  0x8(x5)

    /* ---- T2: W shadow 0x33..0x3F <- 0xB3..0xBF --------------------- */
    addi  x7,  x0, 3            /* i = 3  (0x30..0x32 reserved for T3b)     */
    addi  x8,  x0, 16
    addi  x11, x0, 0xB0
.Lw:
    add   x9,  x5, x7           /* x9  = 0x8001_0000 + i                    */
    add   x10, x11, x7          /* x10 = 0xB0 + i                           */
    sb    x10, 0x30(x9)
    addi  x7,  x7, 1
    bne   x7,  x8, .Lw

    /* ---- T3a: aligned + unaligned single-byte GRP read ----------- */
    lbu   x12, 0x8(x5)          /* aligned:   MIMO   -> 0x31                */
    sb    x12, 0xC(x5)          /* 0x0C <= 0x31                             */
    lbu   x13, 0x9(x5)          /* unaligned: SF_CFG -> 0x07                */
    sb    x13, 0xD(x5)          /* 0x0D <= 0x07                             */

    /* ---- T3b: Z_01_I bytes 0x40..0x42  ->  W 0x30..0x32 --------- */
    lbu   x12, 0x40(x5)         /* aligned                                  */
    sb    x12, 0x30(x5)
    lbu   x13, 0x41(x5)         /* unaligned read  + unaligned write        */
    sb    x13, 0x31(x5)
    lbu   x14, 0x42(x5)         /* unaligned read  + unaligned write        */
    sb    x14, 0x32(x5)

.Lspin:
    jal   x0, .Lspin
