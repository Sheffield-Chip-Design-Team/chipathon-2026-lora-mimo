# tb_chip_top — end-to-end chip_top functional testbench

`integration/tb/tb_chip_top.v`, run by `integration/scripts/run_tb_chip_top.sh`
under Verilator 5 (`--binary --timing`) inside `hpretl/iic-osic-tools:chipathon26`.

The full cross-project MMIO path is real RTL on both sides:

```
picorv32 -> cpu_ss -> ahb_conn_buff CPU->periph pipe -> periph_ss
  -> interconnect_ss (EXT_PERIPH 0x8001_0000 decode) -> ext_ahb_m_if
  -> ahb_to_grp_bridge  (HCLK 25 MHz  ->  IQ_CLK 32 MHz  bundled-data CDC)
  -> trouper_top GRP_* bus -> register arbiter -> reg_bank
```

Results are read back over Trouper's SPI slave by an SPI-master model in the tb
("the SPI oracle"). iverilog cannot elaborate grouper `dev` (`case () inside`),
so Verilator is the only functional-sim gate — see the memory note
`check_chip_top_iverilog_dead_on_grouper_dev`.

## Modes

Selected by plusargs (the runner sets them from `FW` / `LOAD` / `STIM` env):

| knob | values | meaning |
|---|---|---|
| `FW` | `smoke` (default), `weightgen` | ROM hand-asm plumbing test vs Trouper's real `firmware/picorv32` MRC weight image on the Grouper CPU |
| `LOAD` | `uart` (default), `backdoor` | weightgen only: real ROM-bootloader boot over `UART_RX`, vs `$readmemh` into `ram_ss` + force `bank_switch` |
| `STIM` | `forced` (default), `iq` | weightgen only: force a known Z vector, vs drive a real ΣΔ IQ capture through Trouper's DSP chain so training produces Z for real |

### FW=smoke  (T1–T3)

Hand-assembled RV32EMC program in ROM (`fw/chip_top_smoke.S`):

- **T1** — single GRP write: `MIMO_CTRL` (0x08) ← 0x31
- **T2** — W shadow 0x33..0x3F written one byte per lane (0xB3..0xBF)
- **T3a** — aligned and non-word-aligned GRP reads (`lbu` 0x08→0x0C, 0x09→0x0D);
  the regression that pins the `periph_ss` lane-replicate fix
  (`planning/grp-ext-periph-byte-lane.md`)
- **T3b** — CPU reconstructs `Z_01_I` (0x40..0x42) into W 0x30..0x32

### FW=weightgen, STIM=forced  (T4)

`fw/weightgen_stimulus.py` (imports Trouper's `sim/models/eigvec_fw`) emits
`weightgen_z.vh` (a `force` task on `dut.u_trouper.Zpair_i/q[...]`) and
`weightgen_golden.hex` (the 16 expected W bytes). The tb forces that Z, pulses
`training_done`, lets the firmware run the 8-iteration fixed-point power method,
then SPI-oracle-reads 0x30..0x3F and compares to the golden — the same bytes
`eigvec_fw.compute_eigvec_fw()` produces. Bit-exact.

### FW=weightgen, STIM=iq  (T5 — real IQ)

`fw/iq_stimulus.py` (reuses Trouper's `cocotb/tests/iq_capture.py`) turns a
measured baseband capture (`sim/examples/*.iq`) into the 1-bit ΣΔ stimulus the
decimator expects, fanned out to 4 branches, one nibble per `IQ_CLK`, written to
`iq_stim.hex`. The tb:

1. holds the Grouper CPU in reset, SPI-oracle-configures Trouper the way a host
   would (SF, BW, `SC_THR`, `SC_HITS_REQ`, release `RX_HOLD`, enable PSRAM, poll
   `INIT_DONE`) — a `psram_model` (Trouper's `cocotb/hdl/psram_model.v`) is wired
   onto chip_top's `psram_sio_*` nets in the tb, since chip_top's P&R model has
   no pad OE;
2. starts the ΣΔ playback and releases the CPU (now running the real weightgen
   firmware, spinning on `IRQ_STATUS`);
3. waits for a **real** `training_done` from the DSP chain, gives the firmware
   the same ~400k-HCLK compute budget as T4, quiesces the CPU, then
   SPI-oracle-reads the measured `Z_kl` (0x40..0x63), `ZDIAG` (0x64..0x6F),
   `N_ACC` (0x21..0x23) and the firmware's `W` shadow (0x30..0x3F) into
   `iq_result.txt`;
4. `fw/check_weightgen_iq.py` rebuilds the Hermitian Z from the measured bytes,
   runs `eigvec_fw.compute_eigvec_fw(Z, n_acc)` and asserts the firmware's W
   matches — closing the loop chip-measured-Z → firmware weights → reference.

Tunables (runner env): `IQ_FILE IQ_SR IQ_SF IQ_BW IQ_START IQ_NSAMP IQ_SNRDB
IQ_GAINS IQ_SEED`.

## Running

```
integration/scripts/run_tb_chip_top.sh                       # smoke / uart
FW=weightgen LOAD=backdoor  .../run_tb_chip_top.sh           # T4 fast
FW=weightgen LOAD=uart      .../run_tb_chip_top.sh           # T4 real boot
STIM=iq                     .../run_tb_chip_top.sh           # T5 (implies FW=weightgen, LOAD=backdoor)
PROBE=1 ...   # trace GRP writes into the W-shadow window
TB_DUMP=1 ... # + VCD
```

Overridable: `GROUPER_ROOT TROUPER_ROOT PICORV32_V DOCKER_IMAGE`. The runner
auto-applies `patches/grouper-local-integration.patch` to the grouper checkout
(`periph_ss` HRDATA lane-replicate + `config.h` `SYS_CLK_HZ` `#ifndef` guard).

If the grouper submodule's nested `ip/picorv32` is not checked out, point
`PICORV32_V` at any populated copy, e.g.
`PICORV32_V=…/chipathon-2026-lora-mimo/lora-mimo/integration/ip/grouper/ip/picorv32/picorv32.v`.

## Gotchas (all handled in the tb)

- **Forced `training_done` must be a pulse, not a hold.** Holding it makes
  `packet_ctrl_fsm` assert `packet_active` and pulse `W_valid`, which gates the
  W-shadow writes. (T5 does not force it — training is real.)
- **GRP poll vs SPI-oracle read collision.** `main()` polls `IRQ_STATUS` forever
  over the GRP bus; `reg_bank` shares one combinational read port
  (`rb_raddr = grp_active ? GRP_ADDR : spi_rd_addr`), so a live GRP access
  corrupts whichever SPI-burst byte coincides with it. The tb holds the picorv32
  in reset (`force cpu_ss.cpu_rst_n = 0`) before every SPI-oracle read; reg_bank
  keeps its state (IQ_CLK domain, untouched by the Grouper reset). T5 also holds
  the CPU during the initial SPI config so those writes can't collide either.
- **UART load timeout.** 2504-byte image over UART at 3.125 Mbaud (`--baud
  3125000` → clk_div=0 at 25 MHz → 320 ns/bit) ≈ 24 ms sim; global timeout is
  120 ms.
- **SRAM model.** Feed grouper's own
  `hw/rtl/ram/gf180mcu_ocd_sram_1024x8m8wm1_rtl_model.v` (+ the pd wrapper), not
  the blackbox stub `check_chip_top.sh` uses.

## Status

- T1–T4 green on all of `smoke/uart`, `weightgen/backdoor`, `weightgen/uart`
  (commit `ca8a107`).
- T5 (real IQ) green: `1_packet_mingain.iq` (SF7/BW125), 4-branch flat channel
  gains `0,-2,-4,-6` dB / phases `0,35,70,110`°. Real preamble lock (`sc_lock`
  ~28.7 ms into playback), `n_acc` = 3583 (= 7·M−1, the expected partial
  window), `ZDIAG` = [45926, 28999, 18309, 11557] — the measured per-branch
  energies track the fed gains — and all 16 firmware W bytes bit-exact vs
  `eigvec_fw(measured Z)`. Also green with `IQ_SNRDB=20` (full-rank Z).
  Verilator sim ~2 s wall.

## Possible future refactor

Rehost as a cocotb harness (like Trouper's `cocotb/trouper_top`) so the Python
stimulus prep and the SPI/config sequence stop being re-implemented in Verilog.
Deferred — the Verilog tb already has firmware load (both paths), bank switch,
bridge, SPI oracle and the psram model working.
