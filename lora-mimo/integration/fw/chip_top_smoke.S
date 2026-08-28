/*
 * chip_top_smoke.S
 * Minimal RV32EMC program for the chip_top end-to-end connectivity testbench
 * (integration/tb/tb_chip_top.v).
 *
 * Purpose: prove that a real Grouper CPU instruction-fetching from its own ROM
 * can drive a single MMIO byte write all the way through
 *
 *   picorv32 -> cpu_ss -> ahb_conn_buff pipe -> periph_ss -> interconnect_ss
 *   -> ext_ahb_m_if -> ahb_to_grp_bridge (HCLK->IQ_CLK CDC) -> trouper_top
 *   GRP_* bus -> reg_bank
 *
 * and land in a Trouper configuration register, verified independently over
 * Trouper's SPI slave port.
 *
 * Memory map (grouper hw/rtl/interconnect_ss.sv):
 *   0x0000_0000  ROM  (reset vector, this program)
 *   0x8001_0000..0x8001_ffff  External Peripherals -> ext_ahb_m_if -> bridge
 * The bridge only sees HADDR[7:0], so 0x8001_00NN addresses Trouper reg 0xNN.
 *
 * Target register: MIMO_CTRL @ 0x08 (trouper src/control/reg_bank.v).
 *   write byte : wdata[7:4] -> antenna_en, wdata[0] -> mimo_mode[0]
 *   readback   : {antenna_en, 2'b00, mimo_mode}
 *   reset value: antenna_en=0xF, mimo_mode=0 -> 0xF0
 *   we write 0x31 -> antenna_en=0x3, mimo_mode[0]=1 -> reads back 0x31
 * 0x08 is a word-aligned offset (bits[1:0]=0) so the store byte sits in AHB
 * byte lane 0, which is the lane periph_ss forwards to the 8-bit ext bus.
 * 0x08 has no rx_hold / cfg_wr_ok gate, so the write always takes.
 *
 * The AHB write stalls HREADY (ahb_conn_buff wait states + the bridge's full
 * CDC round trip) until Trouper has captured the request, so no software
 * delay or polling loop is needed here -- the sb simply blocks until done.
 */

    .option norvc                 /* emit plain 32-bit encodings (picorv32 has
                                     COMPRESSED_ISA=1, but norvc keeps the ROM
                                     image trivially inspectable) */
    .section .text.init, "ax", @progbits
    .global _start
_start:
    lui   x5, 0x80010             /* x5 = 0x8001_0000  ext-periph window base   */
    addi  x6, x0, 0x31            /* x6 = 0x31         MIMO_CTRL write value    */
    sb    x6, 0x8(x5)             /* [0x8001_0008] <= 0x31  -> Trouper reg 0x08 */
1:
    jal   x0, 1b                  /* spin forever; testbench drives the check   */
