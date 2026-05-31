# Die Area Analysis

> **Date:** 2026-05-31
> **Status:** Jobs 1118 (5V) / 1119 (3.3V) running — this analysis predicts their outcome.

## How FP_CORE_UTIL actually works in LibreLane

`FP_CORE_UTIL` sizes the floorplan based on **stdcell area only**:

```
Core area = stdcell_area / FP_CORE_UTIL
```

SRAM macros are then placed *within* that same core area, on top of the stdcell budget.
This means the **effective density** (what DRT sees) is higher than FP_CORE_UTIL implies:

```
Effective density = (stdcell_area + macro_area) / core_area
                  = (stdcell_area + macro_area) / (stdcell_area / FP_CORE_UTIL)
```

The DRT density wall on GF180MCU is **60–65%** (DRT-0073/1231 failures above this).
To stay safe, effective density should be ≤ 55%.

## Current design logic budget

After all area cuts to date (2026-05-31):

| Component | Area |
|---|---|
| Stdcell total | ~1.62 mm² |
| OCD SRAM ×2 (CPU, 2 kB) | ~0.31 mm² |
| FD SRAM ×1 (frontend buf) | ~0.21 mm² |
| **Total logic** | **~2.14 mm²** |

## Die area vs FP_CORE_UTIL

| FP_CORE_UTIL | Core area | Effective density | Routeable? | Die ≈ |
|---|---|---|---|---|
| 55% | 2.95 mm² | 72.5% | **No** — hits DRT wall | — |
| 45% | 3.60 mm² | 59.4% | Marginal | ~3.6 mm² |
| 40% | 4.05 mm² | 52.8% | **Yes** | ~4.0 mm² |
| 35% | 4.63 mm² | 46.2% | Yes (loose) | ~4.6 mm² |

**Conclusion: realistic die size with current logic is ~4 mm² at safe routing density.**

The P&R jobs with FP_CORE_UTIL=55 will likely fail DRT for this reason.
Next run should use FP_CORE_UTIL=40.

## Impact of remaining cut options

| Scenario | Stdcell | Macros | Total logic | Safe die (~40%) |
|---|---|---|---|---|
| Current (all cuts to date) | 1.62 mm² | 0.52 mm² | 2.14 mm² | ~4.0 mm² |
| + SERV swap (−355k stdcell) | 1.27 mm² | 0.52 mm² | 1.79 mm² | ~3.2 mm² |
| + OCD ×2→×1 if fw fits 1 kB | 1.27 mm² | 0.37 mm² | 1.64 mm² | ~2.9 mm² |
| + TDM+FIR decimator (−86k) | 1.18 mm² | 0.37 mm² | 1.55 mm² | ~2.7 mm² |

**SERV is the only remaining cut that changes the die size category (4 mm² → 3 mm²).**
All the per-block TDM optimisations done so far are real savings but do not move
the category boundary — the macros and PicoRV32 dominate.

## Why our per-module synthesis numbers seemed more optimistic

Per-module Yosys synthesis reports stdcell area only. Summing those gives ~1.62 mm²,
which looks small. The die area is much larger because:

1. Macros (0.52 mm²) add on top of stdcell area
2. Routing overhead requires ~2× the logic footprint for safe DRT (FP_CORE_UTIL=40)

The synthesis area is not the die area.

## Action items

- [ ] Confirm chipathon die area limit (determines whether SERV is mandatory)
- [ ] Rerun mimo_rx_top P&R with FP_CORE_UTIL=40 once jobs 1118/1119 complete
- [ ] If limit is ≤ 3 mm²: implement SERV swap (see `planning/blocks/PicoRV32 Integration.md`)
- [ ] If limit is ≤ 2.7 mm²: also need TDM+FIR decimator extension
