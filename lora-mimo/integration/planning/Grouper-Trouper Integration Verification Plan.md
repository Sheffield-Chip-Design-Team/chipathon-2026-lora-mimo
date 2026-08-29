# Grouper–Trouper Integration Verification Plan

**Scope:** the live Grouper SoC, its AHB-to-GRP bridge, the Trouper top level,
the host-SPI control port, IRQ wiring, and the shared PSRAM interface. This is
a system-level closure backlog; it complements, rather than replaces, the
block plans under `ip/trouper/planning/verification-plan/`.

**Current evidence:** `ram_backdoor/tb_grouper_trouper_psram.v` boots a real
Grouper RAM image via the SRAM macro backdoor, drives live Trouper training,
and proves the production eight-iteration eigenvector ISR reads Z, commits W,
and clears the interrupt. At 16 MHz HCLK it measured 2.145062 ms from the
TRAINING_DONE IRQ assertion to W commit, below the 3 ms replay margin. It does
not yet exercise a host-SPI master, repeated events, post-commit receive use,
or reset recovery.

| # | Test and pass criterion | Type | Harness | Status |
|---|---|---|---|---|
| 1 | **Grouper/host-SPI arbitration.** Start a host-SPI write after TRAINING_DONE asserts, while the real Grouper ISR reads Z and writes W. The host write must eventually be visible by SPI readback; Grouper must still commit valid W and clear its sticky IRQ. | INTERFACE/SYSTEM | `ram_backdoor/tb_grouper_trouper_psram.v` and `test_grouper_trouper_psram.py`; builds on `ip/trouper/rtl-test/tb/tb_trouper_grp_arb.v`. | ✅ done — 16 MHz combined run passes; IRQ→W commit 2.145312 ms, host `COMB_CFG` write overlaps ISR and reads back correctly |
| 2 | **AHB-to-GRP register/protection sweep.** Firmware accesses every Grouper-visible register class. RW values read back correctly; RO Z/status and reserved locations ignore writes; W shadow/commit retains its documented semantics. | SPEC-SIM / INTERFACE | New RAM-linked Grouper firmware plus combined cocotb harness. | ⬜ planned |
| 3 | **Back-to-back IRQ policy.** Create a second training completion while the first ISR is active. Assert the specified pending/coalesced/re-arm behaviour, no silent loss, and one correctly matched service operation per accepted event. | EDGE-SIM / INTERFACE | Combined cocotb harness plus IRQ-test firmware. | ⬜ planned — event policy must be made explicit first |
| 4 | **Training-to-receive closed loop.** Train, run the production ISR, then inject a packet and prove active W is used by the MRC/capture path with the expected receive result. | SYSTEM | Combined harness, borrowing packet stimulus/scoreboards from Trouper capture and two-packet tests. | ⬜ planned |
| 5 | **PSRAM ownership and recovery.** Exercise capture or playback while the debug/backdoor window is requested. Assert ownership exclusion, `DBG_BUSY`/status behaviour, data integrity, and successful access after release. | SPEC-SIM / SYSTEM | Combined harness plus PSRAM model; extends Trouper `psram_ops` coverage. | ⬜ planned |
| 6 | **Reset and boot interruption.** Reset during training, an asserted IRQ, and a W-shadow update. After boot, require no stale commit/IRQ and deterministic reconfiguration through the bridge. | EDGE-SIM / SYSTEM | Combined RAM-boot harness. | ⬜ planned |
| 7 | **Clock-ratio and phase sweep.** Repeat the production IRQ-to-W test at the intended 25 MHz Grouper clock and across HCLK/IQ_CLK starting phases. Keep the 3 ms replay-deadline assertion. | TIMING / SYSTEM | Parameterised combined harness. | ⬜ planned — RTL simulation validates functional timing only, not STA/silicon sign-off |

## Closure order

1. Complete and regress row 1, since two independent control masters share
   Trouper's register-bank read port and arbitration is a live integration risk.
2. Close row 3 before relying on interrupt-driven continuous operation.
3. Close row 4 to prove the calculated W is consumed by the data path.
4. Add rows 2, 5, and 6 for control-plane robustness, then row 7 at the final
   intended HCLK rate.

## Boundaries

- The existing standalone Trouper arbitration bench proves the top-level
  arbitration logic, but not real Grouper AHB timing, firmware ISR behaviour,
  or the external IRQ synchronizer; row 1 supplies those missing conditions.
- A successful simulation at 25 MHz is not a replacement for the outstanding
  physical timing and corner analysis recorded in `planning/Open Risks.md`.
