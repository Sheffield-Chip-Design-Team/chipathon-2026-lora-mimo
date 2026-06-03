# Area Cut Contingency List

**Date:** 2026-06-03  
**Baseline:** NR=2, PicoRV32IM, HW weight_gen, TDM CIC (no FIR), ser-IQ mrc_combiner  
**Baseline die (65% eff. density):** ~2.43 mm² stdcell ~1,167k µm², macros 0.41 mm²

All synthesis figures AS cells (gf180mcu_as_sc_mcu7t3v3) unless noted.  
✓ = measured   ~ = estimated from planning analysis

---

## Active design choices with cheaper alternative

These are already-decided features that can be reversed if area is tight.

| # | Current choice | Alternative | Stdcell saving | Macro saving | Die saving (65%) | Measured? | Risk |
|---|---|---|---|---|---|---|---|
| 1 | PicoRV32IM | SERV | ~−250k µm² | — | ~−385k mm² → ~−0.38 mm² | ~ | Firmware latency: weight_gen routine takes ~800µs vs 50µs on PicoRV32; check all FW tasks fit in timing windows |
| 2 | HW weight_gen | SW weight_gen | −105k µm² | — | ~−0.16 mm² | ✓ | None — 160× timing margin at SF7; reg_bank saves ~0 extra |
| 3 | NR=2 | NR=4 | +~335k µm² | +~110k µm² | **+0.69 mm²** | ✓ | NR=4 is an upgrade, not a cut |
| 4 | TDM CIC (no FIR) | Shift-add FIR | +~213k µm² | — | **+0.33 mm²** | ✓ | FIR is an upgrade for filter quality |

---

## Additional cuts not yet deployed

These are independent of the choices above and can be stacked.

| # | Block | Cut | Stdcell saving | Measured? | Prerequisite | Risk |
|---|---|---|---|---|---|---|
| 5 | ~~noise_floor_est~~ | ~~Remove entirely~~ | ~~−34k µm²~~ | **Already done** | NFE (`noise_floor_est.v`) is not instantiated in `mimo_rx_top.v` — cut already taken. sigma2 path is energy_meas_coarse → noise_metric → reg_bank directly. | — |
| 6 | energy_meas_coarse | Remove entirely | −70k µm² | ✓ (baseline) | See removal notes below. Removes both energy measurement (AGC) AND noise_metric (sigma2). They are the same block — cannot split. | Medium — AGC blind without it |
| 7 | mrc_combiner | 16-bit → 12-bit weights (Option B) | ~−30k µm² | ~ | Narrow weight_gen output ports + reg_bank W shadow | Low — 12-bit gives 72 dB weight SNR |
| 8 | ~~DMEM SRAM~~ | ~~OCD 1024×8 → OCD 512×8~~ | — | — | ~~−58k µm² macro~~ | **Deprioritised — do not resize** |
| 9 | dc_removal | Remove entirely | ~−25k µm² | ~ | Confirm ADC DC offset acceptable | Low for AC-coupled RF path |
| 10 | spi_slave | Remove | −17k µm² | ✓ (baseline) | Host must always be SPI master | Low |
| 11 | psram_buf_ctrl | Remove | −46k µm² | ✓ (baseline) | Requires different lock-detect architecture | High — architectural change |

### energy_meas removal — implementation notes (#6)

`energy_meas_coarse` has three downstream consumers in `mimo_rx_top.v`:

| Consumer | Signal | Removal action |
|---|---|---|
| `packet_ctrl_fsm` | `energy_snap[0..3]` | Tie to `16'h0000`. Energy gating (`energy_gate_en`) is off by default (reg default = 0) so packet detection is unaffected. |
| `reg_bank` | `energy_snap[0..3]` | Tie to `16'h0000`. Firmware readback (0x40–0x47) returns 0 — acceptable if firmware doesn't use energy for decisions. |
| `noise_floor_est` / sigma2 | `noise_metric[0..3]` | Tie to `10'h000`. NFE should also be removed (#5); if kept it just outputs zero estimates. |

**RTL change:** ~5 lines in `mimo_rx_top.v` — delete `u_em` instantiation, add four `assign energy_snap[k] = 16'h0;` and `assign noise_metric[k] = 10'h0;` lines.

`energy_valid`, `energy_snapshot_valid`, `noise_metric_valid` → tie to `1'b0`.

No changes needed to `packet_ctrl_fsm`, `reg_bank`, or `noise_floor_est` RTL — all handle zero inputs correctly.

---

## Stack analysis — how far can we go?

Starting from baseline ~2.43 mm² (ser-IQ already applied):

| Cuts applied | Stdcell | Macros | Die (65%) |
|---|---|---|---|
NFE (`noise_floor_est`) is already removed from the design — baseline already reflects this.

| Cuts applied | Stdcell | Macros | Die (65%) |
|---|---|---|---|
| Baseline (NR=2 + TDM CIC + ser-IQ, NFE already removed) | 1,167k | 0.41 mm² | **~2.43 mm²** |
| + SW weight_gen (#2) | 1,062k | 0.41 mm² | **~2.27 mm²** |
| + Remove energy_meas_coarse (#6) | 992k | 0.41 mm² | **~2.16 mm²** |
| + mrc 12-bit weights (#7) | 962k | 0.41 mm² | **~2.11 mm²** |
| + SERV (#1) on top of all above | 712k | 0.41 mm² | **~1.73 mm²** |

Sub-2.2 mm² achievable without SERV. Sub-1.8 mm² requires SERV.

---

## What is NOT worth cutting

| Block | Why not |
|---|---|
| mrc_combiner opt-C (fix post_gain_shift) | Measured: only −4k µm² — not worth register map change |
| energy_meas_coarse (vs remove) | Measured: coarse saves only −1.2k vs baseline; remove saves −70k |
| noise_floor_est_coarse (vs remove) | Coarse saves −8k, removal saves −34k — go all the way or not at all |
| CIC order reduction 3→2 | Marginal saving (~5k per instance); degrades alias rejection |
| reg_bank trimming | Measured: NR=2 reduction only −9k; sw weight_gen saves ~0 extra |
| spi_master | Needed for SX1257 configuration — cannot remove |
| frontend_buf_ctrl | Needed for SC detector delay buffer — cannot remove |
| packet_ctrl_fsm | Core control logic — cannot simplify significantly |

---

## Decision order if area is tight

Apply in this order (largest saving, lowest risk first):

1. **SW weight_gen** — zero risk, 160× timing margin. Do this first.
2. **Remove NFE** — if sigma2 path confirmed unused in final system.
3. **Remove energy_meas** — if AGC via firmware polling is acceptable.
4. **mrc 12-bit weights** — if weight_gen port change is acceptable.
5. **DMEM → 512B** — measure firmware footprint with all SW additions first.
6. **SERV** — last resort; validate all firmware timing windows before committing.
