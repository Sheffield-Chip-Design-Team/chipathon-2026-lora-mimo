# Physical Design Change List

This page tracks the remaining work required before the current `rtl-test/mimo_rx_top.v` can support a meaningful full physical-design flow with SRAM macros and the intended `32 MHz` I/O plus `16 MHz` internal architecture.

---

## Current state

The current top-level RTL is not yet a true dual-rate implementation.

- `mimo_rx_top.v` is still effectively a single-clock top driven from `IQ_CLK`
- several block ports are named `clk_32m` and `clk_16m`, but are currently tied to the same net
- the existing top trial config relaxes timing to `62.5 ns`, which is not the same thing as implementing `32 MHz` I/O with `16 MHz` internal logic
- frontend SRAMs are now instantiated as `gf180mcu_fd_ip_sram__sram512x8m8wm1` macros in the top-level RTL
- CPU SRAM in `picorv32_wrap.v` is now instantiated as 4 × `gf180mcu_ocd_ip_sram__sram1024x8m8wm1`, one macro per byte lane

Because of that, a top-level PD run today would still be useful mainly as a macro-aware floorplan/sizing experiment, not yet as proof that the intended dual-rate architecture is implementable.

---

## Progress made

### Completed in this pass

- replaced the behavioral CPU SRAM array in `rtl-test/picorv32_wrap.v` with 4 explicit `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` instances
- added a `rtl-test/sram1024x8_bb.v` synthesis blackbox for the CPU SRAM macro
- aligned the frontend buffer RTL to the planned `gf180mcu_fd_ip_sram__sram512x8m8wm1` family
- updated `rtl-test/sram512x8_bb.v` to match the `fd_ip` frontend SRAM macro name
- updated `rtl-test/ol_picorv32_wrap/config.json` to include the CPU SRAM blackbox plus LEF/LIB views
- updated `rtl-test/ol_mimo_rx_top/config.json` to include both SRAM blackboxes plus LEF/LIB views
- parse-checked `picorv32_wrap` and `mimo_rx_top` successfully in the `chipathon26` container with Yosys
- completed a clean `16 MHz` hard-macro `ol_picorv32_wrap` PD run, proving the wrapper plus 4 CPU SRAM macros can reach GDS with the current `RV32IM` configuration
- completed a matching `RV32I` wrapper PD comparison run to quantify the area impact of removing hardware MUL/DIV
- completed a matching `RV32IM` dual-port versus single-port regfile wrapper PD comparison run

### Recorded decision data: CPU option area tradeoff

The current wrapper comparison gives a useful first decision point for CPU-area reduction:

| Wrapper option | Die area (mm^2) | Instance area (um^2) | Stdcell area (um^2) | Hold result | Decision note |
| --- | --- | --- | --- | --- | --- |
| `RV32IM` dual-port | `2.94` | `2,798,570` | `515,628` | Clean | Known-good wrapper baseline |
| `RV32I` dual-port | `2.74` | `2,603,240` | `438,195` | `-0.485 ns`, `18` hold violations | Stronger CPU-core area reduction, but not signoff-clean |
| `RV32IM` single-port | `2.86` | `2,721,480` | `490,596` | `-0.474 ns`, `1` hold violation | Smaller regfile-driven area reduction, but still not signoff-clean |
| `RV32IM` single-port + no IRQ qregs/counters | `~2.78–2.79` (est.) | `~2,649,000–2,657,000` (est.) | not finalized | run failed before signoff | Low-pain bundle moves area a bit further, but only modestly |

Interpretation:

- removing MUL/DIV reduces wrapper die area by about `0.20 mm^2` and is the stronger of the CPU-only levers measured cleanly so far
- changing dual-port to single-port regfile reduces wrapper die area by about `0.077 mm^2`, so it is a weaker lever
- the additional low-pain bundle (`ENABLE_IRQ_QREGS=0`, `ENABLE_COUNTERS=0`, `ENABLE_COUNTERS64=0`) appears to save another `~0.07–0.08 mm^2` of die area on top of single-port `RV32IM`, based on synthesis-area extrapolation only
- most of these gains are stdcell logic, not SRAM, so the fixed 4-macro CPU memory cost remains
- none of these CPU-only tweaks is large enough by itself to drive the full top from `~3 mm^2+` toward `2 mm^2`
- every non-baseline variant tested so far has introduced either hold regressions or routing-access failures and would need follow-up repair before being treated as a clean replacement
- a bundled low-pain small-core experiment (`ENABLE_IRQ_QREGS=0`, `ENABLE_COUNTERS=0`, `ENABLE_COUNTERS64=0`) on top of `RV32IM` single-port synthesized successfully but failed in detailed routing before final metrics; synthesis area dropped from `1,190,846` to `1,159,165 um^2`, which extrapolates to roughly `~2.65 mm^2` final instance area and `~2.78–2.79 mm^2` die area if routing had completed

### Recorded decision data: SERV replacement trial

A first `SERV`-based control-plane wrapper was implemented as `servile_wrap_4macro` using:

- `servile`
- `servile_rf_mem_if`
- 4 × `gf180mcu_ocd_ip_sram__sram1024x8m8wm1`

This gives a like-for-like SRAM-macro count against the current PicoRV32 wrapper while testing how much logic-area reduction a serial control CPU can recover.

| Wrapper option | Die area (mm^2) | Instance area (um^2) | Hold result | Other result | Decision note |
| --- | --- | --- | --- | --- | --- |
| `SERV` baseline, original macro placement | `1.94` | `1,814,430` | `-2.226 ns`, `9` hold violations | DRC `0`, antenna `0`, GDS produced | Strong area result, but not signoff-clean |
| `SERV` `38/45` tight-center SRAM cluster | not finalized | not finalized | failed before timing summary | `DRT-1231` clock-buffer access failure | Pulling SRAMs closer vertically hurt routability |
| `SERV` `38/45` open-center SRAM spread | `1.79` | `1,676,110` | `-2.625 ns`, `25` hold violations | antenna `9`, GDS produced | Better area, but materially worse hold and antenna |

Interpretation:

- `SERV` is a serious CPU replacement candidate from an area perspective even with the same 4 SRAM macros
- compared to the clean `RV32IM` dual-port PicoRV32 wrapper baseline, the first `SERV` baseline cut die area from about `2.94 mm^2` to `1.94 mm^2`
- compared to the `RV32IM` single-port wrapper, the first `SERV` baseline still cut die area from about `2.86 mm^2` to `1.94 mm^2`
- the functional logic area is genuinely tiny; most remaining area is SRAM macros plus physical overhead such as fill/tap/endcap
- macro movement does change the tradeoff, but the first two experiments show the direction clearly:
- `tight-center` made clock-buffer access worse and failed in detailed routing
- `open-center` recovered more area, but made hold and antenna significantly worse
- the current best `SERV` point is therefore still the original loose baseline floorplan, not the tighter placement variants
- the next meaningful `SERV` cleanup is likely SDC repair first, then gentler floorplan tightening, rather than more aggressive macro movement

### Overnight PicoRV32 macro-topology sweep queued for review

To compare macro topology cleanly without changing RTL or density, an overnight sweep was queued on the clean `RV32IM` dual-port `picorv32_wrap` baseline. All queued runs keep:

- the same wrapper RTL
- the same `16 MHz` timing target
- the same `FP_CORE_UTIL 35` and `PL_TARGET_DENSITY_PCT 42`
- only SRAM macro placement changes

Reference points before the sweep:

- clean baseline: original `2x2` macro placement, successful GDS run
- failed comparison: `1x4` bottom-row macro wall, run `969`, which reached post-antenna reroute and then failed on `DRT-0073` clock-buffer access

Queued topology jobs:

- `970` `prv-2x2-low-open`
- `971` `prv-2x2-staggered`
- `972` `prv-t-shape`
- `973` `prv-l-shape`
- `974` `prv-top-row`
- `975` `prv-3plus1`
- `976` `prv-edge-cols`
- `977` `prv-2x2-top-open`

Tomorrow's review criteria:

- which topologies complete versus fail in detailed routing
- whether any topology clears the recurrent post-antenna `clkbuf_*` access failure
- die area and instance area for any completed runs
- hold and antenna behavior for any completed runs
- whether a topology improves on the clean `2x2` baseline enough to justify replacing it

Working hypothesis going into the review:

- a very wide macro wall is probably harmful, based on the failed `1x4` bottom-row test
- the most promising alternatives are likely `2x2`-derived placements that open routing channels or shift blockage away from the clocked logic region
- the sweep should be treated as a floorplan/topology comparison, not a CPU architecture comparison

### Overnight PicoRV32 macro-topology sweep result

The overnight sweep completed for jobs `970` through `977`. The result is decisive enough to close this branch of exploration:

- seven of the eight topology variants failed in detailed routing with clock-buffer or delay-buffer access errors
- the only topology that completed the full flow was `974` `prv-top-row`
- `prv-top-row` still failed deferred signoff, with hold violations at `nom_tt_025C_3v30`, antenna violations, and max-cap violations

Topology outcomes:

- `970` `2x2-low-open`: failed on `clkbuf_3_0_0`, `clkbuf_3_2_0`, `clkbuf_3_6_0` access
- `971` `2x2-staggered`: failed on `clkbuf_2_1_0` access
- `972` `t-shape`: failed on `clkbuf_2_2_0` and `clkbuf_2_0_0` access
- `973` `l-shape`: failed on `delaybuf_0_clk_32m` access
- `974` `top-row`: completed, but not clean
- `975` `3plus1`: failed on `clkbuf_3_0_0` and `clkbuf_3_5_0` access
- `976` `edge-cols`: failed on `clkbuf_3_7_0` access
- `977` `2x2-top-open`: failed on `clkbuf_0`, `clkbuf_2_0_0`, `clkbuf_2_1_0` access

Completed `top-row` metrics:

- die bbox: `1704.89 x 1722.81 um`
- instance area: `2,806,450 um^2`
- setup WNS: `0`
- hold WNS: `-0.720 ns`
- antenna violations: `9`
- max-cap violations: `1`

Interpretation:

- simple macro-topology changes did not produce a better wrapper floorplan than the original clean `2x2` baseline
- wide macro walls and asymmetric placements mostly made the recurrent clock-access problem worse
- the original successful `2x2` wrapper should remain the reference implementation point for now
- further wrapper work is unlikely to benefit from broad topology sweeps and should instead focus on either small local adjustments around the baseline or on testing the CPU in a larger integrated block

### 2026-05-28 PD-knob area sweep: PicoRV32 wrapper + mimo_rx_top

A second pass focused on synthesis/PD knobs rather than macro topology. The
goal was area minimisation at fixed 16 MHz with both blocks. Detailed
write-up in [PicoRV32 Integration.md](blocks/PicoRV32%20Integration.md)
"Synthesis/PD area-knob sweep" section.

**PicoRV32 wrapper results (baseline 2×2 macro placement):**

| Variant | SYNTH | util/dens | halo | Die (mm²) | SS slack (ns) | Status |
|---|---|---|---|---|---|---|
| baseline | DELAY 0 | 35/42 | 10/5 | 3.06 | +22.78 | clean reference |
| `area_t1` (Tier 1) | **AREA 0** | **50/60** | 10/5 | **2.02** | +0.95 | clean — **−31% die** |
| `area_t12b` (Tier 1+2) | AREA 0 | 50/60 | 10/5 | 2.02 | +0.95 | bit-identical to t1 — Tier 2 inactive |
| `area_halo` (t1 + halo shrink) | AREA 0 | 50/60 | **5/3** | 2.02 | **+5.22** | same area, **+4.3 ns slack recovered** |
| `area_mpw` (push, drop SS) | AREA 0 | 60/70 | 10/5 | — | — | fail DRT-0073 — density wall |

**Density wall finding:** `FP_CORE_UTIL ≥ 60` or `PL_TARGET_DENSITY_PCT ≥ 70` reliably hits `DRT-0073/1231` on clock-buffer pin access points, regardless of CTS buffer cell choice or whether SS corner is in the signoff set. This is the practical area floor for picorv32 + GF180MCU `mcu7t5v0` + the current PDN configuration.

**Critical path observation:** `SYNTH_STRATEGY: AREA 0` restructures the worst combinational path from "10 levels of fat compound gates with high-fanout slew-repair chain" (baseline DELAY 0) to "22+ levels of plain 4-input cells (`and4`/`nand4`/`nor4`) with no slew-repair buffers" (AREA 0). Neither path touches the SRAM macros — both runs are CPU-internal flop→flop. Macro placement does not bound fmax at 16 MHz.

**mimo_rx_top result (job 1003, `config_area_t12c`):**

Backed-off PD knobs (`util 28 / density 36`, FP_ASPECT 1, AREA 0, halos and CTS as in `config_trial_top_ctsabc.json`) on the full mimo top-level produced the **first comprehensive top-level area number** with closed timing across all corners:

| Metric | Value |
|---|---|
| DIEAREA | `5842.93 × 5878.77 µm` (≈ 1:1) |
| Die area | **8.59 mm²** |
| Instances | 318,423 (5 macros: 4× OCD picorv32 RAM + 1× FD frontend buffer) |
| Util achieved | 0.32 (target 0.28) |
| WS at TT 25 °C 3v30 | **+39.35 ns** |
| WS at SS 125 °C 3v00 | **+14.58 ns** |
| WS at FF −40 °C 3v60 | +47.19 ns |
| Hold WS | +0.17 ns |
| TritonRoute DRC | 0 |
| Magic GDS DRC | **38 illegal-overlap errors → flow flagged FAILED** |

Timing closes comfortably at every corner. Routing is clean. The deferred-error failure is GDS-level Magic DRC (illegal overlap, likely PDN strap vs macro halo at the smaller halo settings inherited from the trial config) — fixable by bumping `FP_MACRO_HORIZONTAL_HALO`/`FP_MACRO_VERTICAL_HALO` or adjusting `PDN_HORIZONTAL_HALO`/`PDN_VERTICAL_HALO`. A follow-up `config_area_t12d.json` with halos 12/15 should resolve it.

**Top-level area context:** 8.59 mm² for the full mimo includes the entire SRAM stack (4× 0.155 mm² OCD + 1× 0.21 mm² FD = ~0.83 mm² memory) plus the full DSP datapath (sd_decimator, dc_removal, weight_gen, sc_detector, packet_ctrl_fsm, training_acc, mrc_combiner, etc.), the picorv32 wrapper, AHB-Lite bus, register bank, SPI master/slave, IRQ controller, and frontend buffer controller. Compared to the previously documented `top-row` PicoRV32-only result (~2.94 mm²), the additional DSP + glue logic adds ~5.6 mm² of std-cell area at util 0.32.

**Failed variants (for the record):**

| Job | Variant | Failure | Class |
|---|---|---|---|
| 989 | `b23_flipped` (b2/b3 FS pins up) | DRT-1231 clkbuf_12 | FS orientation breaks routing |
| 992 | `b23_flipped` + CTS fix | DRT-1231 clkbuf_12 | same |
| 993 | `row1x4` (4× macros bottom row) | clean | viable layout, +19.10 ns SS |
| 994 | `cpu_middle` (b0/b1 N up, b2/b3 FS down) | DRT-0073 clkbuf_12+16 | FS orientation breaks routing |
| 996 | `area_t12` (smaller CTS buffers) | DRT-0073 clkbuf_4 | smaller CTS bufs fail at density 60 |
| 997 | `mimo_area_t12` (baseline config, no macro cfg) | PDN-0235 macros unplaced | baseline mimo lacks macro placement |
| 999 | `mimo_area_t12b` (util 35/45 + CTS fix) | DRT-1231 clkbuf_12 IQ_CLK_regs | mimo density wall on 7k-fanout IQ_CLK |
| 1000 | `col4x1` (W orientation, macros left) | DRT-1231 clkbuf_regs_0_clk_32m/Z | W orientation breaks routing |
| 1001 | `area_mpw` (util 60/density 70, drop SS) | DRT-0073 clkbuf_12 | density wall |
| 1002 | `col4x1_e` (E orientation, macros right) | post-flow Hold-fail @ TT | E orientation routes but needs hold-fix |
| 1003 | `mimo_area_t12c` (util 28/density 36) | 38 Magic overlap DRC | clean routing + STA, only GDS-level DRC |

**Practical implication for the design:** the picorv32 wrapper area is now characterised between 2.02 mm² (area-t1/halo) and 3.06 mm² (baseline). The mimo_rx_top sits between 8.59 mm² (area-t12c, pending DRC fix) and the previously-documented ~11+ mm² baseline. With Tier-1 PD knobs locked in, further area reduction requires either RTL changes (Tier 3: RV32I, single-port regfile, IRQ disable) or library swaps (FD-only SRAM plan).

**Cross-cutting risk — STA against uncharacterised OCD `.lib`:** every PicoRV32 slack number above is computed against a Liberty file whose numerical tables are byte-for-byte copies of the FD 512×8 5 V `.lib`. SPICE characterisation scaffolding has been added at [`characterization/sram_ocd/`](../characterization/sram_ocd/README.md) and [`characterization/sram_fd/`](../characterization/sram_fd/README.md). See [Memory Strategy.md](Memory%20Strategy.md) "OCD Liberty timing model is unverified" for the full audit.

### Full chip block size list — updated 2026-05-31 (session 2)

Four rounds of RTL area reduction have been applied since the original estimate.
All figures are Yosys synthesis with `gf180mcu_as_sc_mcu7t3v3` TT/25°C/3.3 V
(standalone per-module runs; flat synthesis as used by LibreLane).

#### Stdcell blocks

| Block | Original | Round 1 (decimator) | Round 2 (sc/wgen) | Round 3 (energy/noise/cpu) | Current | vs original |
|---|---|---|---|---|---|---|
| `sd_decimator ×4` | 759 k | — | — | — | — | — |
| `sd_decimator_cic_only ×4` | — | 300 k | 300 k | 300 k | **300 k** | **−459 k** |
| `picorv32` core | — | — | 286 k | 286 k | **286 k** | — |
| `sc_detector` | 561 k | 305 k | 193 k | 193 k | **164 k** | **−397 k** |
| `mrc_combiner` | 195 k | 121 k | 121 k | 121 k | **121 k** | −74 k |
| `weight_gen` | 298 k | 184 k | 120 k | 120 k | **120 k** | **−178 k** |
| `training_acc` ² | 211 k | 119 k | 119 k | 119 k | **132 k** | — |
| `reg_bank` | — | — | 103 k | 103 k | **103 k** | — |
| `energy_meas` | — | 98 k | 98 k | **75 k** | **75 k** | **−23 k** |
| `picorv32_pcpi_mul/div` | — | — | 69 k | 69 k | **69 k** | — |
| `dc_removal` | 90 k | 50 k | 50 k | 50 k | **50 k** | −40 k |
| `noise_floor_est` | — | 83 k | 83 k | **34 k** | **34 k** | **−49 k** |
| `packet_ctrl_fsm` | — | — | 33 k | 33 k | **33 k** | — |
| `frontend_buf_ctrl` | 48 k | 30 k | 30 k | 30 k | **30 k** | −18 k |
| `sd_remod` | 35 k | 29 k | 29 k | 29 k | **29 k** | −6 k |
| `picorv32_wrap` glue | — | — | 18 k | **22 k** | **22 k** | +4 k (2-SRAM FSM) |
| `spi_slave` | — | — | 17 k | 17 k | **17 k** | — |
| `spi_master` | — | — | 10 k | 10 k | **10 k** | — |
| `irq_ctrl` + `ahb_lite_bus` | — | — | 5 k | 5 k | **5 k** | — |
| **Stdcell total** | **~2,197 k** | **~1,319 k** | **~1,687 k** ¹ | **~1,616 k** | **~1,566 k** | |

¹ Round 2 total includes CPU and non-DSP blocks not counted in Round 1.
² `training_acc` Round 2 figure (119 k) was local area excluding `signed_mul8_pipe` submodules. Round 3 figure (132 k) is top-module total including 2 × `signed_mul8_pipe` (17 k). True logic reduction is −21 k measured in hierarchical context (153 k → 132 k); stdcell total updated accordingly.

#### SRAM macros

| Macro | Count | Each (µm²) | Total |
|---|---|---|---|
| `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` (CPU) | 2 | 155,527 | **311 k** |
| `gf180mcu_fd_ip_sram__sram512x8m8wm1` (frontend buf) | 1 | 209,357 | **209 k** |
| **SRAM total** | | | **520 k** |

#### Grand total

| Category | µm² |
|---|---|
| Stdcell | ~1,566 k |
| SRAM macros | ~520 k |
| **Total logic** | **~2,086 k ≈ 2.09 mm²** |
| **Realistic die at FP_CORE_UTIL=40** | **~3.8 mm²** (confirmed by job 1127 floorplan) |

#### Changes made in session 3 (2026-06-01):
- `sc_detector`: NR=2 → NR=1 (single-channel preamble lock), 32→24-bit accumulators, 17→13-bit eval multiplier. 193 k → 164 k (−29 k). SGE job 1138.
- `training_acc`: 4 shared 8×8 muls → 2 muls, 2 sub-cycles per antenna state (sub0=zi, sub1=zq). 11-cycle sample budget vs ≥20-cycle iq\_valid interval. −21 k in hierarchical context (153 k → 132 k). SGE job 1141.

#### Changes made in session 2 (2026-05-31):
- `energy_meas`: 8 parallel squarers → 1 shared TDM squarer, 9-step FSM. 98 k → 75 k (−23 k). SGE job 1120.
- `noise_floor_est`: 4 parallel EMA channels → serialised 1-per-cycle, single 25-bit arithmetic path. 83 k → 34 k (−49 k). SGE job 1120.
- `picorv32_wrap`: 4× OCD 1024×8 → 2× OCD 1024×8 with 2-phase 2 kB access scheme. SRAM saving −310 k. SGE job 1112.
- `mimo_rx_top`: connected `rx_gain_shadow_2/3` ports to `reg_bank` (previously floating).

#### Changes made in session 1 (2026-05-31):
- `sd_decimator_cic_only ×4`: CIC N=3 only, no FIR, zero multipliers. SGE job 1104.
- `sc_detector`: 16 parallel 8×8 multipliers → 1 shared TDM multiplier. SGE job 1108.
- `weight_gen`: 4 simultaneous 16×8 calibration wires → 1 serialised multiplier. SGE job 1108.

#### Reliability notes:
- All stdcell figures from standalone per-module flat synthesis (same flow as LibreLane). Reliable to ±5–10%.
- SRAM areas from LEF physical dimensions — exact.
- Die area of 3.8 mm² from OpenROAD floorplan measurement (job 1127) — confirmed.
- CPU holds timing at 16 MHz (3.3 V, SS/125°C/3.0 V, +2.37 ns slack). 32 MHz fails; CPU clock domain fix needed before tapeout.
- OCD SRAM `.lib` is uncharacterised (byte-copy of FD timing) — STA against OCD macros is not silicon-predictive.

### Still intentionally not solved in this pass

- real `32 MHz` / `16 MHz` clock partitioning
- CDC structure between those domains
- macro placement strategy for the top-level SRAM instances
- extracted timing validation of the SRAM assumptions
- cleanup of the firmware-load/readback interface beyond preserving a PD-ready macro-backed structure

---

## Main blockers

### 1. No real `clk_16m`

- add a real `/2` clock-generation point from `IQ_CLK`
- expose the generated net clearly enough for STA and implementation tools
- stop tying all `clk_16m` ports to the raw `32 MHz` net

### 2. No real internal clock partition

- define exactly which logic remains in the `32 MHz` domain
- define exactly which logic moves to `16 MHz`
- verify that every affected instantiated block is actually wired to the intended domain

### 3. Missing CDC implementation

- add explicit crossings for every `32 MHz -> 16 MHz` interface
- add explicit crossings for every `16 MHz -> 32 MHz` interface
- do not rely on SDC-only treatment for functional clock-domain crossings

### 4. CPU SRAM integration needs refinement, not first-principles replacement

The behavioral CPU SRAM has been removed, but a few details still need architecture cleanup:

- review firmware-load readback behavior against the SPI-side protocol
- decide whether CPU SRAM remains a `32 MHz` interface with multicycle access or becomes a true `16 MHz` block
- validate that the macro-access latency model matches the intended SDC treatment

### 5. Top-level constraints are not aligned with the intended architecture

- the current top-level SDC intent and `ol_mimo_rx_top/config.json` do not reflect a real dual-rate netlist
- `SPI_SCK` should be treated according to the implemented crossing method, not simply as a normal synchronous secondary clock
- SRAM multicycle assumptions must match the actual controller implementation and extracted timing assumptions

---

## Required RTL work

### Clocking

- add a real `clk_16m` generator in the top-level RTL
- distribute `clk_32m` and `clk_16m` intentionally instead of by port naming convention
- decide whether some blocks are better kept in the `32 MHz` domain with clock-enables instead of moving them to a separate clock domain

### Domain partition

Likely `32 MHz` candidates:
- SX1257 input capture
- sigma-delta decimators
- sigma-delta remodulator
- pad-facing interface wrappers

Likely `16 MHz` candidates:
- PicoRV32 wrapper and AHB-Lite control plane, if supported by the memory/latency model
- slower DSP/control blocks that are not bitstream-rate-critical

This partition must be validated block by block rather than assumed from the architecture sketch.

### CDC

For each crossing, choose and implement one mechanism:
- synchronizer for static control
- pulse-stretch + acknowledge for event signals
- registered rate-change bridge or FIFO for sample-bearing interfaces
- no unconstrained direct combinational crossing between the two domains

### SRAM integration

- frontend buffer SRAMs: finalize wrapper details and later macro placement strategy
- CPU SRAM: review the firmware-loader behavior now that the storage is macro-backed
- keep macro interfaces stable enough that PD can proceed before the final firmware is frozen

---

## Required physical-design work

### Top config cleanup

- update `rtl-test/ol_mimo_rx_top/config.json` so the clock period and SDC match the actual top-level clocking architecture
- define macro placement strategy for frontend SRAM and CPU SRAM blocks
- re-enable signoff checks incrementally once the architecture is coherent enough for meaningful reports

### Dual-rate SDC rewrite

The final top-level SDC must:
- create the `32 MHz` source clock on `IQ_CLK`
- create the generated `16 MHz` clock on the actual divider output
- constrain CDC paths according to the implemented bridges
- constrain SRAM multicycle behavior according to the chosen controller timing model
- constrain pad timing for the `32 MHz` input/output-facing logic separately from the `16 MHz` internal logic

### Pre-PD validation

Before launching a full top PD run:
- lint the netlist for accidental single-clock wiring
- run RTL simulation with the real dual-rate clocking and CDC logic
- run top-level trial STA and verify that the clock graph matches intent
- confirm that SRAM macro names in RTL match the physical collateral that PD will use

---

## Recommended execution order

1. Add the real `clk_16m` generation point.
2. Partition the top into explicit `32 MHz` and `16 MHz` regions.
3. Implement CDC logic for all inter-domain paths.
4. Rewrite the top-level SDC around the actual generated clock net and real crossings.
5. Update `ol_mimo_rx_top/config.json` further if the clocking split changes macro/timing assumptions.
6. Run a fresh top-level trial PD flow.
7. Only after that treat full top-level PD results as architecture evidence.

---

## Measured area cut table

Using the current best integrated top result:
- `mimo_rx_top` run `987`
- real content only: `stdcell + macros`
- excluding fill, tap, and endcap overhead

Measured real content in `987`:
- total real content: `3.250 mm^2`
- stdcells: `2.419 mm^2`
- macros: `0.831 mm^2`

Measured CPU wrapper reference:
- `picorv32_wrap` run `985`
- real content: `1.168 mm^2`
- wrapper stdcells: `0.547 mm^2`
- CPU SRAM macros: `0.622 mm^2`

Measured macro split inside the integrated top:
- CPU SRAM macros: `0.622 mm^2`
- frontend DSP SRAM macro: `0.209 mm^2`

Approximate integrated-top budget by category:
- CPU subsystem total: `1.168 mm^2`
- frontend DSP SRAM macro: `0.209 mm^2`
- remaining top content after subtracting CPU subsystem and frontend SRAM: `1.872 mm^2`

Interpretation:
- the `~15 mm^2` die from run `987` is mostly floorplan overhead and fill, not real design content
- the real architectural problem is still `3.25 mm^2` of content versus a `2.00 mm^2` target
- the gap to close in real content is about `1.25 mm^2`

Decision ranking from these measured numbers:
1. CPU/control simplification remains the biggest single lever.
2. Frontend SRAM count is a secondary lever, but much smaller than CPU removal/simplification.
3. Remaining DSP/control logic is still large enough that feature cuts are required even after CPU work.
4. Floorplan tightening is necessary later, but it cannot close a `~1.25 mm^2` real-content gap by itself.

---

## Bottom line

The netlist is now materially closer to a meaningful macro-aware PD run because both the frontend SRAMs and CPU SRAM are represented as hard macros in the RTL and configs.

But the architecture question is still open. Until the top gets a real `32 MHz` / `16 MHz` split with explicit CDC and matching SDC, a full top-level PD run would still answer only a limited question: whether the current single-clock approximation with real SRAM macros can be placed and routed.
