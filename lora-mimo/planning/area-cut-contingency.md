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
| 5 | noise_floor_est | Remove entirely | −34k µm² | ✓ | Confirm sigma2 feedback path unused | Low if NFE unused |
| 6 | energy_meas | Remove entirely | −70k µm² | ✓ (baseline) | Move energy threshold logic to firmware; AGC via reg_bank polling | Medium — AGC loop complexity increases |
| 7 | mrc_combiner | 16-bit → 12-bit weights (Option B) | ~−30k µm² | ~ | Narrow weight_gen output ports + reg_bank W shadow | Low — 12-bit gives 72 dB weight SNR, far above needed |
| 8 | DMEM SRAM | OCD 1024×8 → OCD 512×8 | — | — | **−58k µm² macro** | Firmware DMEM must fit in 512 bytes; tight with SW weight_gen | Medium |
| 9 | dc_removal | Remove entirely | ~−25k µm² | ~ | Confirm ADC DC offset acceptable or handle in software | Low for AC-coupled RF path |
| 10 | spi_slave | Remove | −17k µm² | ✓ (baseline) | Host must always be SPI master | Low |
| 11 | psram_buf_ctrl | Remove | −46k µm² | ✓ (baseline) | Requires different lock-detect architecture (no PSRAM replay) | High — architectural change |

---

## Stack analysis — how far can we go?

Starting from baseline ~2.43 mm² (ser-IQ already applied):

| Cuts applied | Stdcell | Macros | Die (65%) |
|---|---|---|---|
| Baseline (NR=2 + TDM CIC + ser-IQ) | 1,167k | 0.41 mm² | **~2.43 mm²** |
| + SW weight_gen (#2) | 1,062k | 0.41 mm² | **~2.27 mm²** |
| + Remove NFE (#5) | 1,028k | 0.41 mm² | **~2.21 mm²** |
| + Remove energy_meas (#6) | 958k | 0.41 mm² | **~2.11 mm²** |
| + mrc 12-bit weights (#7) | 928k | 0.41 mm² | **~2.06 mm²** |
| + DMEM 512B (#8) | 928k | 0.35 mm² | **~1.97 mm²** |
| + SERV (#1) on top of all above | 678k | 0.35 mm² | **~1.58 mm²** |

Sub-2 mm² is achievable without SERV if energy_meas is removed.  
Sub-1.6 mm² requires SERV.

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
