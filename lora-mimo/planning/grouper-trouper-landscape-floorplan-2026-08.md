# Grouper<->Trouper landscape floorplan (2026-08)

Status: geometry + combined RTL top (`chip_top.v`) exist and synthesize cleanly
(job 4665, 2026-08-22). No floorplan/PnR run yet. This doc records the agreed
geometry and what's still open before
`lora-mimo/integration/pd/config_landscape_2235.yaml` is run-ready for a full
flow.

## Sources

- Trouper: submodule pinned to `main` (`ad647dc` -- pulled 2026-08-22; was
  stale at `41b0e89`. The pull merged in PR #39
  `die-1117sq-margin-reclaim-nr4-nr3-options`, which is directly relevant here
  -- see Open Items #3, now resolved).
- Grouper: submodule pinned to `timn/pd-landscape-floorplan` (`be38558`).
- Obstruction/pin-order format modeled on Trouper's own L-shape floorplan work:
  `rtl-test/ol_trouper_top/config_lshape_1100_550_pad1.json`,
  `io_placement_bl.cfg`, `pdn_cfg.tcl`, and (now merged to `main`)
  `config_1117sq.json` / `io_placement_1117sq.cfg` -- the latter is sized to
  exactly Trouper's home quadrant below and is the closer precedent to start
  from.

## Geometry

Die: **2235um x 2235um** square, origin at bottom-left (`DIE_AREA "0 0 2235 2235"`).

| Region | Box (x1 y1 x2 y2, um) | Notes |
|---|---|---|
| Obstruction A | `0 0 1117.5 1117.5` | bottom-left quadrant, full square |
| Obstruction B | `1676.25 1117.5 2235 2235` | top-right quadrant, right half only (flush to die's right and top edges); confirmed with user over the alternative of flush-left (inner/seam side) |
| Grouper placeable area | top-left quadrant + free top-right strip (west of Obstruction B) | pins on `#N` / `#W` |
| Trouper placeable area | bottom-right quadrant | pins on `#S` / `#E` |

2235 = 2 x 1117.5 = 4 x 558.75, so both obstructions land on quadrant
boundaries exactly -- no odd fractional splits.

Correction from the first pass of this doc: Obstruction A is the *entire*
bottom-left quadrant (not a half), so this is a clean L-shape for one project
and a plain square for the other -- not the S-shape described earlier.

**Correction 2026-08-27: the two projects were swapped in the first two
passes of this doc.** The executed geometry puts **Grouper in the NW** and
**Trouper in the SE** -- the `MACROS` block places Grouper's 4 SRAMs in the
NW lobe (y~1696, job 5069's placement, kept), and the PDN `VSRC_LOC`
comments label the west sources "Grouper" and the east sources "Trouper".
Job 5069 also landed Trouper's whole datapath on `#E` (the SE square's own
outboard edge).

- **Grouper**: top-left quadrant **plus** the free (left) part of the
  top-right quadrant (west of Obstruction B at x=1665), a true **L-shape**
  (~1.86 Mum^2 placeable). Its 4 SRAMs sit along the top edge of this lobe.
- **Trouper**: bottom-right quadrant only, a plain **1117.5 x 1117.5 square**
  (~1,248,806um^2). No bonus area.

`FP_OBSTRUCTIONS` only blocks **cell placement** -- it does not shape
`DIE_AREA`, constrain IO pin spreading, or block PDN straps. See Open Items #3.

## Files added

- `lora-mimo/integration/pd/config_landscape_2235.yaml` -- die area +
  obstructions + pin-order/PDN references + the real `DESIGN_NAME`/
  `VERILOG_FILES` proven by the synth test (see Open Item #1). Only `MACROS`
  (SRAM, commented out) is still a placeholder -- see Open Item #5.
- `lora-mimo/integration/pd/synth_only_chip_top.yaml` -- the synthesis-only
  sibling config that proved out the `VERILOG_FILES`/`USE_SLANG`/
  `VERILOG_DEFINES` now folded into `config_landscape_2235.yaml` above (no
  floorplan/PDN -- kept as a fast standalone synth-check config).
- `lora-mimo/integration/pd/io_placement_landscape.cfg` -- currently pins
  only Trouper's real pads: datapath on `#E`, and IRQ_OUT/HOST_CS plus the
  shared HCLK/HRESETn on `#N`. `#W`/`#S` are empty, reserved for Grouper's
  still-unnamed pinout (Grouper is the NW L-shape -- see the 2026-08-27
  correction under Geometry). The `GRP_*` bus is no longer chip pads
  (internal, crossed by u_bridge in chip_top.v). Not a real pinout -- see
  Open Items #2, #4.

## Open items (blocking an actual run)

1. **No combined top-level RTL at padframe scope -- IN PROGRESS, first pass
   elaborates cleanly (2026-08-22).** `grouper_trouper_top.v` (from the
   `feature/grouper-trouper-ahb-integration` work, commit `9927434`) targeted
   Trouper's now-superseded `feature/ahb-lite-slave-adapter` branch (an
   AHB-shaped `trouper_top` slave port) and is no longer the right model --
   `main`'s current `trouper_top.v` (PR #39, `ad647dc`) exposes a completely
   different, native flat register bus instead (`GRP_ADDR/WDATA/WE/RE` in,
   `GRP_RDATA/READY` out, protocol reverse-engineered from
   `rtl-test/tb/tb_trouper_grp_arb.v`'s `grp_write`/`grp_read_pulse` tasks,
   not independently verified).

   New files, targeting `main`'s real protocol:
   - `lora-mimo/integration/rtl/ahb_to_grp_bridge.v` -- new AHB3-Lite slave
     that drives the GRP_* bus, replacing the old AHB-adapter approach.
     `HOLD_CYCLES=6` is a deliberately conservative margin over the tb's
     proven 4-cycle hold, not derived from timing analysis.
   - `lora-mimo/integration/rtl/chip_top.v` -- instantiates Trouper's
     `trouper_top` with its **full real pad-level port list** (matches
     `io_placement_landscape.cfg`'s populated sides -- `#N` control, `#E`
     datapath) straight through to chip_top's own ports, plus Grouper's
     CPU+ROM (`cpu_ss_emc` +
     `ahb_rom`, reused from the old integration) bridged to Trouper via the
     new bridge module. Grouper's own external padframe (UART, GPIO, etc.)
     is deliberately NOT exposed yet -- still blocked on Open Item #4 (no
     named Grouper pinout to expose). Single shared clock (`HCLK` ==
     Trouper's `IQ_CLK`) is assumed, not validated.
   - `lora-mimo/integration/scripts/check_chip_top.sh` -- iverilog
     elaboration-only check (no testbench yet).

   **Verified via homelab-sge (job 4661): `chip_top.v` elaborates cleanly**
   against real RTL from both projects (one harmless `vvp.tgt` warning about
   `unique`/`unique0` case qualifiers in `ahb3lite_pkg.sv`, a codegen backend
   limitation, not an error). This only proves it parses/elaborates -- no
   functional testbench exists yet, so the bridge's protocol timing is still
   unverified. Getting the SGE job running took three fixes worth
   remembering: (a) `--project lora-mimo` mounts the project root directly at
   `/foss/designs` inside the container, so job scripts must `cd
   /foss/designs/integration`, not `/foss/designs/lora-mimo/integration`;
   (b) `hqsub` stages from the **persistent NFS mirror**
   (`/srv/eda/designs/timothyn-dev/lora-mimo`), not directly from the local
   working tree -- new local files (all of `integration/`, in this case)
   must be `rsync`'d there first, same pattern as the `block-regression`/
   `run-pnr` skills document; (c) `/foss/designs` is read-only in the
   container (same as the LibreLane `--force-run-dir` gotcha in the
   `sge-job` skill) -- `iverilog -o` must write under `$RUN_DIR`
   (`/foss/runs`), not the source tree.

   **Synthesis test, 2026-08-22 (job 4665): PASSED.** A plain ad hoc
   `yosys -s` run (job 4663) failed immediately -- Grouper's own
   `ahb3lite_pkg.sv` uses a `return` statement inside an SV function, which
   plain Yosys 0.64's built-in SV frontend can't parse (pre-existing, not
   caused by our RTL). Fix: a real LibreLane synthesis-only config,
   `lora-mimo/integration/pd/synth_only_chip_top.yaml` (modeled on Grouper's
   own `librelane/measure/*.yaml` pattern, run via `--to Yosys.Synthesis`),
   which sets `USE_SLANG: true` -- the slang frontend Grouper's own working
   configs already rely on, and the actual difference (not anything about
   chip_top.v). That surfaced a second, real issue: `ahb_rom.sv` defaults to
   a sim-only `$readmemh`, which slang rejects as an unsupported system task
   for synthesis -- fixed by adding `VERILOG_DEFINES: [ROM_INIT_CONST,
   PROG_FILE_VMEM="code_grouper_trouper.vmem"]` + `VERILOG_INCLUDE_DIRS:
   [dir::../fw]`, switching `ahb_rom.sv` to its ASIC-synthesis `` `include ``
   path (matching Grouper's own `config.yaml` convention), reusing the
   existing firmware image.

   **Result: `chip_top` synthesizes cleanly** against `gf180mcu_fd_sc_mcu7t5v0`
   -- 1,187,173 um^2 chip area, 43,699 cells, 41.6% sequential, 31 ports, 435
   lint warnings (pre-existing, not fatal). For scale: that cell area alone is
   already close to the entire 1,247,556 um^2 Grouper quadrant, even though it
   covers both Grouper's CPU *and* all of Trouper's DSP blocks combined --
   expected, since Trouper dominates (its own standalone target is a full
   1117.5um^2 quadrant on its own), but a useful early sanity check that the
   combined top is proportionate to the floorplan, not wildly oversized.
   New file: `lora-mimo/integration/scripts/run_librelane_synth_chip_top.sh`.

   One more `--force-run-dir` gotcha closed along the way: LibreLane's
   default `runs/<tag>` dir (created next to the config file) fails under the
   read-only `/foss/designs` mount -- needed `--force-run-dir "$OUT"` with
   the target directory pre-created (LibreLane won't `mkdir -p` it), per the
   `sge-job` skill.

   **2026-08-22, folded into the floorplan config**: `config_landscape_2235.yaml`
   now carries the same proven `DESIGN_NAME`/`VERILOG_FILES`/`USE_SLANG`/
   `VERILOG_DEFINES`/`VERILOG_INCLUDE_DIRS`/`CLOCK_PORT`/`CLOCK_PERIOD` as
   `synth_only_chip_top.yaml` -- it's now the single up-to-date floorplan
   config (still un-run as a full floorplan/PnR flow, only synthesis has
   been verified so far).

   **2026-08-22, ARCHITECTURE REWRITE.** The above (hand-picking
   `cpu_ss_emc`/`ahb_rom`/`ahb_ram`/`ahb_conn_buff` into `chip_top.v` and
   reimplementing Grouper's own address decode/interconnect ourselves) was
   abandoned in favor of instantiating Grouper's actual real top-level module
   directly. `chip_top.v` is now exactly three instantiations:
   `grouper_soc_top` (Grouper's whole real SoC -- CPU, ROM, RAM, UART, GPIO,
   `periph_ss`, unmodified internally), `trouper_top` (unchanged from
   before), and `ahb_to_grp_bridge` (the only RTL left in this file).

   This needed one prerequisite: `grouper_soc_top.sv` (vendored, in the
   Grouper submodule) previously tied its own "External AHB Master
   Interface" (`digital_ss`'s `ext_ahb_m_if_*`, already 8-bit by default --
   `EXT_ADDR_WIDTH`/`EXT_DATA_WIDTH` = 8) off dead instead of exposing it at
   its own port list. **Patched locally** (not upstream) to route it up to
   `grouper_soc_top`'s ports -- see that file's header comment. This is
   clearly a hook Grouper's own design already intended for exactly this
   (an "external peripheral" bus), not a new interconnect invented here.
   Since Grouper's own `periph_ss` already truncates the CPU's 32-bit
   address down to this 8-bit window internally, `ahb_to_grp_bridge.v` was
   rewritten as a plain 8-bit AHB slave -- no more manual byte-narrowing
   logic, a cleaner boundary than the old approach.

   `VERILOG_FILES` in both `synth_only_chip_top.yaml` and
   `config_landscape_2235.yaml` now list Grouper's **entire** SoC file set
   (copied from Grouper's own authoritative `librelane/classic/config.yaml`,
   minus its padframe wrapper) -- CPU, ROM, RAM, UART, GPIO, SPI-slave,
   interconnect, common blocks, all of it, not a hand-picked subset.
   `config_landscape_2235.yaml`'s `MACROS` instance paths were fixed to
   match this file's actual hierarchy (`u_grouper.u_grouper_soc_dig_ss...`,
   not the old `u_grouper_soc_top...` guess) -- Open Item #5's "chip_top
   doesn't instantiate Grouper's RAM" gap is now closed structurally
   (instance paths match real cells), though the SRAM GDS/LEF submodule
   init gap from that item still stands.

   **Verified via homelab-sge (job 4667, LibreLane synth, `--to
   Yosys.Synthesis`): elaborates and synthesizes cleanly** -- 154,839 cells,
   5,304,033um^2, ~50% sequential. That area figure is NOT comparable to the
   earlier 1,187,173um^2 number -- this run has no `MACRO_RAM` (deliberately,
   same reasoning as before: avoids needing the SRAM macro's GDS/LEF for a
   fast synth-only check), so Grouper's 4KB RAM synthesizes as a huge
   behavioural flop array (~32k of the ~40k total flops) instead of 4 real
   macros. `config_landscape_2235.yaml` *does* set `MACRO_RAM` and would give
   a realistic number, but hasn't itself been run yet -- blocked on Open
   Item #5's remaining gap (the nested `gf180mcu_ocd_ip_sram` submodule isn't
   initialized).

   Two lint issues hit and fixed along the way: (a) `sram1024x8_wrapper.sv`
   was in `synth_only_chip_top.yaml`'s file list even though `MACRO_RAM` is
   off there -- Verilator's lint step still tries to resolve the hardened
   macro it references even though it's dead code with `MACRO_RAM` unset;
   removed it from that file's list (kept in `config_landscape_2235.yaml`,
   where it's actually needed). (b) none else -- the rewrite otherwise
   elaborated clean on the first full run.

   Still open: no testbench for the bridge (only elaboration + synthesis
   confirmed, not functional correctness), Grouper's own padframe (UART/GPIO
   pins) still tied off at chip_top rather than exposed (Open Item #4).
2. **First real combined pinout written 2026-08-27 -- not yet run.**
   `io_placement_landscape.cfg` was rewritten from the old Trouper-only
   guard to place both projects' pads. Side budget (pitch = 2235/22 =
   101.6 um; each edge's other half backs an obstruction and is filled with
   virtual `$N` pins):

   | Region | Edges | Usable slots | Assigned |
   |---|---|---|---|
   | Grouper (NW L) | `#W` y 1117.5-2235 (11) + `#N` x 0-1665 (16) | 27 | `VSS`/`HCLK`/`HRESETn`/`VDD` + `uart_rx`/`uart_tx` + `gpio_0..4` on `#W`; `gpio_5..15` + host SPI (`HOST_CS`/`SPI_SCK`/`SPI_MOSI`/`SPI_MISO`) on `#N`. 24 used, **1 spare on `#N`**. |
   | Trouper (SE sq) | `#S` x 1117.5-2235 (11) + `#E` y 0-1117.5 (11) | 22 | `IQ_CLK`/`IQ_DATA_I,Q[0:3]`/`REMOD_A_I,Q` on `#S`; `PSRAM_*`/`IRQ_OUT`/`VSS`/`VDD` on `#E`. 22 used, **2 spare on `#E`**. |

   Rationale: Trouper datapath stays on its own SE edges; the `<=10 MHz`
   host SPI slave is exiled to `#N`'s east end (nearest Trouper, shortest
   cross-neck route) so the crowded SE side fits Trouper's own `VSS`/`VDD`
   pair. Shared `HCLK`/`HRESETn` sit low on `#W` near the seam. One
   `VSS`/`VDD` pair per project, on that project's own edge.

   Precondition before a run: `chip_top.v` must expose Grouper's
   `uart_*`/`gpio_*` + the `VSS`/`VDD` pads (Open Item #4). The `#N` Grouper
   nets route over the SRAM row on M4/M5 -- the row stays at y=1695.67 for
   now (see the 2026-08-27 note under Open Item #5). Still unverified: the
   `#S`/`#E` Trouper order was carried
   from the standalone `io_placement_1117sq.cfg` by hand, not cross-checked
   against Trouper's RTL port list; and whether the flow treats `SPI_SCK` as
   a synchronized data input (it should -- `spi_slave.v` resyncs it) rather
   than a clock root that a long `#N` route would skew.
3. ~~PDN keepout for the two obstruction boxes is not yet available on
   Trouper `main`.~~ **RESOLVED 2026-08-22**: PR #39 merged the
   `PDN_KEEPOUT_REGION` env-var + `create_obstruction` guard into
   `rtl-test/ol_trouper_top/pdn_cfg.tcl` on `main`. Still needs to actually be
   wired up (exported as a real shell env var, not a JSON key -- confirmed a
   silent no-op as JSON) for both Obstruction A and B when this config runs.
4. **Grouper has no named/located functional pinout at all, on any branch.**
   Checked `timn/pd-landscape-floorplan`, `dev`, and both `librelane/classic/`
   (core-only) and `librelane/chip/` (real padring, but for Grouper's own
   standalone 3932x5122 Chipathon tile, not this shared die) -- all generic
   pad-index abstractions (`bidir[N].pad`, `inputs[N].pad`, `analog[N].pad`),
   no functional signal names anywhere. This is why `#N`/`#W` in
   `io_placement_landscape.cfg` carry nothing for Grouper yet, and why
   Grouper's `planning/` docs can't be used as a substitute -- Grouper's own
   `CLAUDE.md` flags most of them as copy/paste-contaminated with unrelated
   Trouper content.

   **Update 2026-08-27:** the currently-checked-out Grouper submodule (`dev`,
   `488e062`) now *does* name its padframe -- `ip/grouper/info.yaml` lists
   `clk`, `rst_n`, `uart_tx`, `uart_rx`, `gpio_0..15` with io-types, and
   `ip/grouper/librelane/classic/pin_order.cfg` gives a quadrant order for
   the standalone tile (N = bidir in/oe/ie, S = uart_tx + bidir out, W =
   clk/rst_n/uart_rx + bidir cs/sl/pu/pd). That is names for the *standalone*
   Grouper chip, not a chip_top pinout -- chip_top still ties all of it off
   (see chip_top.v) -- but it is the basis to build the chip_top `#N`/`#W`
   Grouper block from.
5. **Grouper SRAM layout needs to go landscape, not just 2x2 -- MACROS block
   written 2026-08-22, two gaps remain.** Confirmed `timn/pd-landscape-floorplan`'s
   `librelane/classic/config.yaml` (the genuine current default -- note
   `config_1330x1370_keepdlyc_fanout32.yaml` in the same dir has a stale "2x2"
   comment block left over an actual row-of-4 instance list, don't use it as
   a reference) uses a real 2x2 `sram1024x8m8wm1` block, portrait:
   660.82um wide x 1092.05um tall, only ~25um of vertical margin in the
   1117.5um-tall Grouper quadrant here.

   `config_landscape_2235.yaml`'s `MACROS` block now has a rotated
   (orientation E, 90 degrees from the reference's S) landscape 2x2:
   1089.84um wide x 662.03um tall, centered in the quadrant (13.83um margin
   each side) and bottom-anchored (23.52um margin), leaving ~430um of height
   above for CPU logic. Gap/channel spacing (58.22/60.43um) and the E
   orientation are both **carried over from the reference unverified** --
   the reference's spacing came from a PDN half-period lattice specific to
   its own design, which our combined chip_top doesn't have defined yet, and
   the orientation choice isn't derived from the macro's actual LEF pin
   geometry.

   **Both gaps now RESOLVED, 2026-08-22:**
   (a) closed by the chip_top.v architecture rewrite (Open Item #1) --
   `grouper_soc_top` brings in the real RAM/`periph_ss` subsystem, and the
   instance-path prefix was fixed to match (`u_grouper.u_grouper_soc_dig_ss...`).
   (b) `git submodule update --init` run inside `integration/ip/grouper` for
   `ip/gf180mcu_ocd_ip_sram` -- gds/lef/vh files confirmed present on disk
   and synced to the SGE NFS mirror.

   **Verified via homelab-sge (job 4677, `config_landscape_2235.yaml` itself,
   `--to Yosys.Synthesis`): the real macro resolves and places correctly in
   the netlist** -- `grep` on the final netlist confirms exactly 4
   `gf180mcu_ocd_ip_sram__sram1024x8m8wm1` instances, at exactly the 4
   instance paths the `MACROS` block names (`u_grouper.u_grouper_soc_dig_ss.
   u_periph_ss.u_ram.u_ram_ss.gen_macro_ram.gen_sram[N].u_wrapper.u_sram_macro`
   for N=0..3) -- confirming the hierarchy-path fix from the rewrite was
   correct. Chip area with the real macros: **1,303,422um^2** (vs.
   5,304,033um^2 with the behavioural-array stand-in from job 4667) -- much
   closer to Grouper's 1,247,556um^2 quadrant target, as expected.

   Fixed two config bugs surfaced by this run, unrelated to the SRAM itself:
   `_STATUS` isn't a valid LibreLane config key (rejected by schema
   validation -- unlike the earlier informal JSON-skeleton stage, moved to a
   plain comment), and `PDN_CFG` pointed at a `pdn_cfg.tcl` that was never
   actually created (only described in comments) -- disabled
   (commented out) until a real file exists.

   Gap/channel spacing (58.22/60.43um) and orientation E are still
   unverified placeholders (see above) -- that part of Open Item #5 remains
   open, just no longer blocked on missing RTL or missing macro files.

   **SRAM row vs. the north edge (2026-08-27).** Job 5069 runs the row
   top-anchored: top at y~2211, ~24um off the die top, forming a solid
   M1-M3 wall (x~377..1666, halos overlap the 20um inter-macro gaps) flush
   with the north edge. The 2026-08-27 pinout (Open Item #2) puts ~13
   Grouper pins on `#N` above this. Those nets route OVER the macros on
   Metal4/Metal5 -- the macro LEF `OBS` blocks Metal1-3 only, M4/M5 are
   clear -- and via down south of the row. Feasible, but forces those nets
   onto M4/M5 for the ~515um span, sharing the layer with the PDN straps
   (`PDN_VERTICAL_LAYER: Metal4`, `PDN_HORIZONTAL_LAYER: Metal5`). **Decision:
   keep the row at y=1695.67 for now; move it down only if a run shows
   congestion / antenna / DRC in that north corridor** -- options then are
   centred (y~1418: ~289um channel each side, but tightens the neck) or
   bottom-anchored (y~1141: north edge fully open, neck ~24um).

   **PDN, 2026-08-22: `pdn_cfg.tcl` written, was previously referenced but
   never created.** Copied from Grouper's own real, battle-tested
   `librelane/classic/pdn_cfg.tcl` (its own comments document several actual
   DRC failures this structure fixes -- degenerate Metal2-Metal4 vias,
   off-grid stripe phase, SRAM tap-band misalignment), since `chip_top.v`
   instantiates the exact same macros through the exact same hierarchy.
   Appended Trouper's `PDN_KEEPOUT_REGION` guard at the end (from
   `rtl-test/ol_trouper_top/pdn_cfg.tcl`, PR #39) for this die's Obstruction
   A/B -- Grouper's own die never needed that, this one does; both pieces
   were genuinely necessary, not redundant.

   Split what's safe to reuse from what isn't: layer/topology choices
   (`VDD_NETS`/`GND_NETS`, `PDN_MULTILAYER`/`RAIL_LAYER`/`VERTICAL_LAYER`/
   `HORIZONTAL_LAYER`/etc., `PDN_MACRO_CONNECTIONS`, `FP_MACRO_*_HALO`) are
   tied to the PDK/std-cell library, not macro position -- copied verbatim
   into `config_landscape_2235.yaml`, should be safe. The strap **geometry**
   numbers (`PDN_VWIDTH`/`VPITCH`/`VSPACING`/`VOFFSET`/etc.) were carried
   over as placeholders only because the script errors without *some*
   value -- they were derived by Grouper for the OLD portrait/orientation-S
   macro layout (a careful 3-constraint derivation tying stripe pitch to
   which Metal3 frame band carries which net) and are **not** re-derived for
   this design's rotated landscape layout. Explicitly flagged in both files
   as unverified for SRAM power specifically -- deliberately not guessed,
   since a wrong pitch here silently floats a rail rather than erroring.

   **Verified via homelab-sge (job 4679): the expanded config (new PDN_CFG
   + all the new PDN_* keys) still validates and synthesizes cleanly** --
   confirms the config schema and file reference are both valid, though this
   run doesn't reach actual PDN generation (`--to Yosys.Synthesis` stops
   before floorplanning).

   **2026-08-22, attempted the re-derivation, escalated to a real tool
   check instead of hand math.** Pulled the actual Metal3 VDD pin geometry
   from the macro's LEF (`gf180mcu_ocd_ip_sram__sram1024x8m8wm1.lef`) to
   hand-derive the rotated tap alignment -- found the real geometry is far
   more intricate than Grouper's own summary comment implies (hundreds of
   small interleaved VDD/VSS tabs along both edges, not two clean solid
   bands), so a trustworthy hand re-derivation from LEF text alone isn't
   realistic -- this matches why Grouper's own team validated their numbers
   with `check_power_grid`, not arithmetic. One solid structural fact did
   come out of it: the macro's OBS margin (Metal1/2/3) is a uniform ~3um
   inset on **all four** native edges (`OBS` rect `3.0 3.0 -> 298.3 512.81`
   inside `SIZE 301.3 x 515.81`), not just left/right as the summary implied
   -- so the frame concept itself survives a 90-degree rotation structurally,
   even though the specific tab pattern along any given edge doesn't.

   Instead, ran the actual thing: `librelane config_landscape_2235.yaml --to
   OpenROAD.GeneratePDN` (new `run_librelane_pdn_check.sh`) -- goes past
   synthesis into real floorplan + macro placement + PDN stripe generation.
   **Verified via homelab-sge (job 4680): reached PDN generation cleanly**
   (macro placement step produced zero warnings) **with only one PDN
   warning in the whole run**: `No via inserted between Metal2 and Metal3 at
   (1696.94, 332.10)... on VDD`. That coordinate sits in the row-channel gap
   between the two SRAM rows, not on an SRAM macro edge -- looks like a
   generic routing-grid alignment miss, not the SRAM-tap-band problem the
   rotation could plausibly have caused. For comparison, Grouper's own
   `TRIAL_NOTES.md` describes 1524 real violations from a genuinely
   misaligned pitch -- this is nowhere near that.

   **Dug into the one warning, 2026-08-22: it's not a real defect.** The
   full `openroad-generatepdn.log` has more than the warning line -- right
   after grid construction, OpenROAD ran its actual connectivity check
   (`PSM-0040`, the real equivalent of `check_power_grid`) and reported
   **`All shapes on net VDD are connected.` / `All shapes on net VSS are
   connected.`**, with both `VDD-grid-errors.rpt` and `VSS-grid-errors.rpt`
   coming back **empty** (zero real errors). So the single `PDN-0110`
   missing-via warning (at a row-channel/macro-halo corner, per the earlier
   coordinate analysis) didn't actually float anything -- the grid has
   redundant paths elsewhere that keep both nets fully tied together
   despite that one gap. This is a genuinely tool-verified pass, not just
   "no errors were fatal."

   Net result: the placeholder PDN strap geometry (carried over unchanged
   from Grouper's own portrait/orientation-S numbers) turns out to work for
   this rotated landscape layout too, at least for this specific
   macro-placement config -- confirmed by the real connectivity checker, not
   assumed. This was WITHOUT the die-level keepout active -- see next.

   **`PDN_KEEPOUT_REGION` wired up, 2026-08-22 -- surfaced a real, new
   failure.** `pdn_cfg.tcl`'s guard extended from Trouper's single-region
   pattern to two env vars (`PDN_KEEPOUT_REGION_A`/`_B`, since this die has
   two obstruction boxes, not Trouper's one). New
   `run_librelane_pdn_keepout_check.sh` exports both
   (`"0 0 1117.5 1117.5"` / `"1676.25 1117.5 2235 2235"`) and re-runs the
   same `--to OpenROAD.GeneratePDN` check.

   **Job 4681: FAILED.** Confirms the obstruction is actually being applied
   (progress -- the env-var wiring itself works), but with it active:
   ```
   [WARNING PDN-0178] Remaining channel (1117.78, 15.38) - (1120.77, 780.78) on Metal3 for nets: VSS
   [ERROR PDN-0179] Unable to repair all channels.
   ```
   That coordinate sits right at Obstruction A's boundary (x=1117.5, the
   Trouper/Grouper seam) -- a narrow ~3um leftover sliver OpenROAD's
   channel-repair couldn't patch. Root cause: the borrowed stripe lattice
   (`PDN_VOFFSET`/`PDN_VPITCH`/the hardcoded Metal3 rung pitch) is positioned
   relative to the die's core origin, not relative to where the obstruction
   sits -- once the keepout actually blocks that area, a stripe segment gets
   orphaned right at the seam with too little room left to legally repair.

   This is a materially different, harder problem than the wiring task
   itself: resolving it means reworking the PDN stripe topology near that
   specific boundary -- not something to patch blindly without real
   iteration.

   **Iteration 2 (2026-08-22), tried and REJECTED -- made things worse.**
   Theory: `PDN_KEEPOUT_REGION` is independent of `FP_OBSTRUCTIONS` (only
   affects PG routing, not cell placement), so padding Obstruction A's right
   edge a few um wider (`x=1123` instead of `1117.5`) should safely swallow
   the ~3um leftover sliver instead of leaving a too-narrow gap to repair.
   **Wrong**: job 4682 showed this pushed the keepout into territory where
   real standard cells actually get placed (placement is only blocked below
   x=1117.5, not 1123) -- telling PDN to avoid that strip left those real
   cells with **zero power rail access**: ~2460 VDD + ~2454 VSS real
   "Unconnected shape/instance" violations (`PSM-0069`/`PSM-0038`/
   `PSM-0039`), categorically worse than iteration 1's single contained
   channel-repair failure. Reverted `run_librelane_pdn_keepout_check.sh`
   back to the exact `FP_OBSTRUCTIONS` boundary.

   **Operational lesson worth keeping**: job 4682 **exited 0** despite those
   ~4900 real errors -- `--to OpenROAD.GeneratePDN` stops before the checker
   step that would make `PSM-0069` build-fatal. Exit code alone is not
   trustworthy for a PDN check; the log has to be grepped for
   `PSM-0069`/`ERROR` explicitly, every time, the way this investigation
   did by chance rather than by process. Worth remembering for any future
   PDN run, not just this one.

   **Iteration 3 (2026-08-22): RESOLVED by legal-coordinate alignment, not
   stripe re-phasing.** The exact 1117.5um keepout edge falls between
   OpenROAD's legal PDN coordinates, creating the 2.99um Metal3 channel
   (1117.78--1120.77) that caused `PDN-0179`. Insetting only the PG keepout's
   right edge by 0.28um to `1117.22` eliminates that channel while leaving
   the real `FP_OBSTRUCTIONS` placement boundary unchanged at 1117.5. The
   first standard-cell/endcap origin to its right is 1117.76, so the inset
   does not suppress rail access for any cell. A focused LibreLane run
   (`runs/pdn_keepout_inset_1117p22`, `--to OpenROAD.GeneratePDN`) completed
   with no `PDN-0178`, `PDN-0179`, `PSM-0038`, `PSM-0039`, or `PSM-0069`
   diagnostics; OpenROAD reported `All shapes on net VDD are connected.` and
   `All shapes on net VSS are connected.` The remaining three `PDN-0110`
   missing-via warnings are non-fatal and the connectivity reports are empty.
   `run_librelane_pdn_keepout_check.sh` now makes this aligned region its
   default and explicitly fails if channel-repair or real connectivity
   diagnostics appear, so an exit code alone can no longer mask regression.
6. ~~Flow-format mismatch between the two projects.~~ **RESOLVED
   2026-08-22, was never a real blocker**: Trouper's JSON-style keys
   (`FP_OBSTRUCTIONS`, `IO_PIN_ORDER_CFG`, etc.) and Grouper's
   `meta: {version: 3, flow: Classic}` YAML are both just LibreLane config
   dialects over the same underlying variable schema -- JSON is the legacy
   OpenLane2 format LibreLane still reads for back-compat, YAML is the
   native format. Converted `config_landscape_2235.json` -> `.yaml` to match
   Grouper's dialect, since it's the non-legacy format and lets the Open
   Item #5 SRAM placement go in as an inline `MACROS` block (Grouper's own
   convention) instead of translating it into Trouper's separate
   `MACRO_PLACEMENT_CFG` side-file format.
7. **hqsub note carried over from [[hqsub_requires_project_flag]]:** once this
   is run-ready, submit with `--project` set, and per `hlab-sge`/`sge-job`
   skills, use `--snapshot-exclude` on both submodules' large non-PD trees
   (e.g. Trouper's `rtl-test/cocotb_*/`, `fpga-emul/`, `lora-capture/`;
   Grouper's own generated/output dirs) if plain submits hit the 180s client
   timeout.

8. **Portrait east-edge SRAM routing-spine trial (2026-08-22): PDN resolved;
   P&R substantially improved but is not yet complete.** The landscape `E`
   2x2 SRAM block occupied nearly the full lower-right width and left a broad
   routing blockage. A portrait `S` 2x2 array was therefore packed along the
   east edge (`x=1560.35/1919.87`, `y=23.52/599.76`), preserving a roughly
   443um-wide vertical routing spine from the central neck. The array's top
   edge lies close to Obstruction B's lower edge: with the exact PG keepout
   boundary at `y=1117.5`, the focused PDN run reported real `PSM-0038/0039`
   VDD disconnects. Insetting only B's **PDN** lower edge to `y=1117.78`
   (without moving the fixed `FP_OBSTRUCTIONS` edge) fixed that seam. Job
   4698 completed with no `PDN-0178/0179` or `PSM-0038/0039/0069`
   diagnostics; both full-run launchers use this B coordinate.

   Full P&R job 4699 (10 CPUs, 12G, `proxmox-agent`, default NFS storage)
   passed PDN and custom I/O placement, then reached `OpenROAD.RepairDesignPostGPL`
   (stage 32/80). It still failed `DPL-0036`, but improved from 63
   unlegalizable instances in the landscape SRAM layout to **one**
   (`output21`). The remaining problem is repair pressure: 1,229 slew and 789
   fanout violations caused insertion of 4,687 buffers, after which detailed
   placement could not legalize `output21` with `PL_MAX_DISPLACEMENT_Y=100`.
   Next trial: retain this PDN-proven portrait topology and relax the
   vertical detailed-placement displacement (and, if necessary, the inherited
   fanout constraint) without changing fixed die geometry.

9. **`antdiodes` full-run job 4773 (2026-08-23) failed at `OpenROAD.IRDropReport`
   with `PSM-0079 Cannot determine the supply voltage for VDD` -- NOT YET
   ROOT-CAUSED, config itself checks out.** Run
   (`chip_top_landscape_pnr_delay0-ndrnone-antdiodes-leanm3-y1000`) got all
   the way through detailed routing (16 DRC errors, deferred), fill
   insertion, RCX, and post-PNR STA -- died in IR-drop analysis, exit 2,
   42 min runtime.

   Ruled out so far:
   - `vsrc/vdd_estimated_project_downbonds.loc` format is correct per
     OpenROAD's PSM spec (`x_um,y_um,octagonal_edge_um,voltage_V`,
     comma-separated, all four columns required) --
     `2235.00,965.11,70,3.3` matches exactly.
   - `config_landscape_2235.yaml`'s `VSRC_LOC_FILES` wiring into
     `irdrop.tcl`'s `analyze_power_grid -vsrc` call is correct; no missing
     flags.
   - PDN generation (step 21) itself reports healthy: all 4 SRAM macro
     instances matched `PDN_MACRO_CONNECTIONS`, and OpenROAD logs
     `All shapes on net VDD are connected.` / `...VSS are connected.` at
     that stage. Only three isolated non-fatal `PDN-0110` missing-via
     warnings (2 VDD, 1 VSS).

   Leading (unverified) theory: `analyze_power_grid -vsrc` needs the given
   (x, y) to land exactly on routed VDD metal to attach a source node --
   if it doesn't, that's this exact error. The vsrc point itself is the
   same "provisional... 22 equally spaced pad sites" estimate the file's
   own header flags as unverified against real PDN geometry, and the PDN
   strap pitch/offset in `config_landscape_2235.yaml` is *also* still the
   TBD placeholder inherited from Grouper's old portrait-orientation
   derivation (see that file's own comments: "risks the same
   silent-rail-float failure mode"). Only VDD errored because
   `irdrop.tcl` loops nets in order and aborts on first failure -- VSS
   was never reached, so it isn't proven safe either.

   Not yet done: pull the actual routed VDD/VSS stripe geometry from the
   step-21 DEF/ODB near `(2235.00, 965.11)` / `(0.00, 1168.30)` /
   `(2235.00, 1066.70)` to confirm whether metal exists there. If not,
   either snap the vsrc points onto real geometry or fix the underlying
   PDN pitch/offset re-derivation for the rotated macro orientation --
   patching just the point without the grid risks masking the same issue
   next run. `4770`/`4771` (`delay0-ndrnone`) and `4769`
   (`reflected-bl`) failed the same day (exit 1, exit 2) and have not
   been triaged against this same theory yet.

   **`4770`/`4771`/`4769` triaged, 2026-08-23: none of the three actually
   hit `PSM-0079`, so they add no evidence either way.** `4769`
   (`reflected-bl-leanm3-y1000`) failed earlier, at `OpenROAD.GlobalRouting`
   with `[GRT-0116] Global routing finished with congestion` -- an
   unrelated routing-congestion failure. `4770`
   (`delay0-ndrnone-leanm3-y1000`) failed immediately at config load:
   `InvalidConfig: Path provided for variable 'DESIGN_DIR' is invalid` --
   a `--project` mount-path bug in that day's version of
   `run_librelane_pnr_landscape.sh`, before it gained the dual-mode `cd`
   fallback the file has now; never reached synthesis. `4771` (same
   trial, resubmitted) has completely empty stdout/stderr logs -- it
   never actually started executing in its container. So `4773` remained
   the only real data point on this bug going into the investigation below.

   **RESOLVED 2026-08-23, two independent, stacked bugs -- neither was
   ever about the vsrc coordinate geometry per se.** The "leading theory"
   above (needs to land exactly on routed metal) turned out to be a real
   but secondary constraint -- true root causes were entirely different
   and are documented in full, including the coordinate-derivation dead
   ends, in `integration/pd/vsrc/README.md`. Short version:

   - **Bug 1 (the actual `PSM-0079` cause): LibreLane's `irdrop.tcl` never
     sets an operating voltage when `VSRC_LOC_FILES` is used.**
     `analyze_power_grid -vsrc <file>` only supplies the physical
     current-injection location -- OpenROAD's separate voltage-resolution
     chain (solved analysis -> `set_pdnsim_net_voltage` -> SDC
     `set_voltage` -> PVT/corner voltage) still has to resolve a value
     from somewhere, and none of those ever fire in the `VSRC_LOC_FILES`
     branch of `irdrop.tcl` (confirmed by pulling LibreLane's
     `irdrop.tcl` and OpenROAD's `ir_solver.cpp`/`get_power.cpp` source
     directly). The `LIB_VOLTAGE`-fallback branch (no `VSRC_LOC_FILES`)
     calls `set_pdnsim_net_voltage` correctly; `VSRC_LOC_FILES` was just
     missing the equivalent call -- a real LibreLane gap, not anything
     wrong in our config or vsrc coordinates. This explains why jobs
     4773/4799/4801/4802/4803/4809/4810 all failed identically with the
     exact same `PSM-0040 connected` -> `PSM-0079` sequence despite
     genuinely different, independently geometry-verified vsrc
     coordinates across that whole run of attempts -- the coordinates
     were never the problem.

     Fixed via new `integration/scripts/patch_irdrop_tcl.sh`: copies
     LibreLane's installed package to a writable `$RUN_DIR` location
     (`/usr/local/lib/python3.12/dist-packages` is read-only for the
     container's non-root user -- confirmed by a failed first attempt),
     patches the `VSRC_LOC_FILES` branch to add the missing
     `set_pdnsim_net_voltage` call keyed on net name, and exports a
     `PYTHONPATH` that shadows the system install with the patched copy.
     Wired into both `run_librelane_pnr_landscape.sh` and
     `run_librelane_pnr_landscape_reversed.sh` via `source` (not `bash`,
     so the exported `PYTHONPATH` reaches the caller). Smoke-tested
     standalone (job 4825) before spending a full P&R run on it.

   - **Bug 2 (found only after Bug 1 was fixed): OpenROAD's vsrc-file
     parser has zero comment-line support.** `IRSolver::
     generateSourceNodesFromSourceFile` (`ir_solver.cpp`) naively
     `std::stod`-parses every line via `std::getline`, with no skip logic
     for `#`-prefixed or blank lines. `vsrc/*.loc`'s extensive derivation
     comments (see history below) would have crashed this parser from the
     very first run -- it was simply never reached before, since Bug 1
     always aborted the flow earlier, at voltage resolution, before the
     vsrc file was ever actually read. Job 4828 (Bug 1 fixed, Bug 2 not
     yet) surfaced it as a cryptic `Error: irdrop.tcl, 58 stod` right
     after the `[INFO PSM-0015] Reading location of sources...` log line.
     Fixed by moving all derivation history out of the `.loc` files into
     `vsrc/README.md` and reducing `vdd_estimated_project_downbonds.loc`/
     `vss_estimated_project_downbonds.loc` to pure data -- one
     `x_um,y_um,edge_um,voltage_V` line per source, nothing else.

   **Verified via homelab-sge, both bugs fixed together (jobs 4833/4834,
   full P&R, both fixes applied): job 4834 (reversed-orientation,
   local-sram-bridge topology) completed the entire 80-stage flow with no
   fatal errors and produced a real, plausible IR-drop result** -- neither
   pinned to zero (which would suggest a still-broken analysis) nor
   blowing up (which would suggest a genuinely bad PDN):

   | Net | Supply | Worst-case voltage | Worst-case IR drop | % drop |
   |---|---|---|---|---|
   | VDD | 3.30 V | 3.20 V | 0.0998 V | 3.02% |
   | VSS | 0.00 V | 0.0938 V | 0.0938 V | 2.84% |

   (Total power 0.269 W, nom_tt_025C_3v30 corner.) Both nets passed
   `PSM-0040 All shapes connected` and read their vsrc files cleanly with
   no `PSM-0079` and no `stod` crash. **Accepted as the working number for
   now** -- current sources are still the geometry-derived, via-connected
   estimates in `vsrc/*.loc` (see that file's `README.md` for the full
   coordinate-derivation history), not real padframe/downbond data, so
   this must be revisited before physical sign-off, but it's no longer
   blocked on a broken analysis.

   **Job 4833 (leanm3/antdiodes topology, the original trial 4773 failed
   `PSM-0079` on) also confirmed the fix**, and ran the full 76-stage
   flow to `final` views. IR drop passed cleanly there too:

   | Net | Supply | Worst-case voltage | Worst-case IR drop | % drop |
   |---|---|---|---|---|
   | VDD | 3.30 V | 3.13 V | 0.169 V | 5.13% |
   | VSS | 0.00 V | 0.0675 V | 0.0675 V | 2.05% |

   **Accepted as-is for both topologies** -- 3-5% worst-case drop on VDD,
   ~2-3% on VSS, is a reasonable number to build on for now, not a red
   flag. This is also the number recorded against Trouper's own
   `planning/Open Risks.md` #47 (added 2026-08-23), since Trouper's own
   standalone flow never runs a real-source IR-drop analysis and is being
   physically implemented together with Grouper on this shared die anyway.

   `4833`'s job itself still exited **FAILED overall**, but for a reason
   unrelated to IR-drop: LibreLane's end-of-flow deferred-error check
   caught **16 routing DRC errors** (same count 4773 saw at this stage,
   not new) and **13 LVS errors** (new -- no prior trial had reached LVS
   checking before). `4834` (reversed) reached the exact same final stage
   with **0 DRC errors and 0 LVS errors** -- a real, not marginal,
   difference. Full metrics.json comparison, both topologies:

   | | Original (4833) | Reversed (4834) |
   |---|---|---|
   | Setup WNS (`max_ss_125C_3v00`) | -48.69 ns | -42.86 ns |
   | Setup TNS | -32,921 ns | -31,896 ns |
   | Hold WNS/TNS | 0 / 0 | 0 / 0 |
   | Global-route congestion (total) | 28.22% | 25.47% |
   | Global-route overflow | 0/0/0 | 0/0/0 |
   | Routing DRC errors | 16 | **0** |
   | LVS errors | **13** | **0** |
   | Antenna diodes inserted | 24 | 13 |
   | Total wirelength | 4.55M um | 4.19M um (~8% less) |
   | Max cell displacement | 559.9 um | 60.5 um (~9x less) |

   Neither topology is close to closing the known SS-corner setup wall
   (Open Item #11) -- reversed is a few ns better but both are the same
   class of problem, not a fix. Congestion is comfortable on both with no
   overflow either way. The decisive difference is downstream signoff:
   reversed is clean on DRC/LVS and needed far less placement
   displacement to legalize, consistent with the portrait/original-
   orientation lineage's repeated `DPL-0036` legalization trouble
   (Open Item #8) that reversed has never hit. **Reversed-orientation +
   local-sram-bridge PDN is the stronger candidate on every axis measured
   so far** -- worth preferring it as the default trial going forward.

   **13 LVS errors / 16 DRC errors on the original (4833) topology,
   root-caused 2026-08-23: a real, structural fixed-PDN-vs-cell-pin
   conflict, not a router weakness or a routability problem.**

   Confirmed the two checkers are reporting the *same* 4 physical defects,
   not 29 separate ones. Pulled `70-netgen-lvs/reports/lvs.netgen.json`'s
   `badnets` list -- LVS's "4 fewer nets in the layout" mismatch names
   exactly the same 4 nets the DRC report flags as `Metal2` `Short`
   violations against `VSS` (`u_grouper...u_periph_ss.u_ram.byte_select[3]`,
   `...byte_select_r[3]`, `_00084_`,
   `u_grouper...u_cpu_ss.u_cpu.genblk1.pcpi_mul.pcpi_rs2[24]`), each shorted
   at 2-4 nearby coordinates (hence 16 DRC line-items from 4 real defects).
   All 4 sit in Grouper's RAM/CPU-multiplier logic, clustered around
   y~1300-1700um. (The remaining ~1 LVS-error delta from a clean 4-defect
   count looks like a separate, likely benign, antenna-diode
   instance-naming/class mismatch -- `ANTENNA_100`/`110`/`89`/`98` vs the
   generic `gf180mcu_fd_sc_mcu7t5v0__antenna` class -- not investigated
   further since it's cosmetic, not a real short.)

   Dug into *why* detailed routing never resolved these: the
   `44-openroad-detailedrouting/openroad-detailedrouting.log` shows
   TritonRoute genuinely plateaued, not gave up early -- violation count
   sat frozen at exactly 16 for 10+ consecutive iterations up through its
   full iteration budget (observed reaching the "50th guides tiles
   iteration" and beyond). Root cause: `pdn_cfg.tcl` sets
   `pdn_intermediate_layer = "Metal2"` -- this is the layer Grouper's
   global PDN "bridge" stripe runs on in the leanm3/antdiodes trial's PDN
   mode, inserted as a **fixed obstruction** during
   `OpenROAD.GeneratePDN`, before detailed routing ever runs. TritonRoute
   can route around a fixed obstruction but can't move or delete it. In a
   few spots inside Grouper's dense RAM/CPU-multiplier cells, a cell's
   only legal Metal2 pin-access path runs straight through where that
   fixed stripe already sits -- a genuine placement-vs-PDN geometry
   conflict with no legal alternative path for the router to find, not a
   congestion or ripup-heuristic limitation.

   This is exactly why 4834 (reversed) never hit it: `pdn_cfg.tcl`'s own
   gating logic --
   `if { !$pdn_local_sram_bridge || $pdn_lean_m2_hybrid } { add the M2
   stripe }` -- skips the M2 stripe entirely when
   `PDN_LOCAL_SRAM_BRIDGE=1` (4834's mode) and `PDN_LEAN_M2_HYBRID` is
   unset. No fixed M2 obstruction exists in Grouper's RAM/CPU region for
   that topology at all, so there is nothing for local signal routing to
   collide with -- not luck, a structural difference in which PDN mode
   each topology uses.

   Also connects to a standing risk already flagged in this doc: the M2
   stripe's own strap geometry (`PDN_VWIDTH`/`VPITCH`/`VSPACING`/
   `VOFFSET`) is still the unverified placeholder inherited from
   Grouper's old portrait-orientation derivation, repeatedly flagged
   above as "risks the same silent-rail-float failure mode" for this
   rotated landscape layout -- this is that same un-re-derived geometry
   surfacing as routing shorts instead of a PDN connectivity gap.
   Re-deriving it properly (rather than switching PDN mode) would be the
   fix if the leanm3/global-M2-bridge topology is ever needed instead of
   local-sram-bridge.

   Worth reporting Bug 1 upstream to LibreLane -- it silently breaks
   accurate, real-source IR-drop modeling for anyone using
   `VSRC_LOC_FILES` as intended (the very feature it exists for), not
   just this project.

10. **`reflected-grt0` full-run job 4772 (2026-08-23) manually cancelled after
    detailed-routing progress plateaued -- outcome unknown, not a confirmed
    hang.** Run (`chip_top_landscape_pnr_reflected-grt0-ndrnone-leanm3-y1000`)
    reached `OpenROAD.DetailedRouting` (`drt.tcl`) at 01:34 and was still in
    that same step when cancelled at 03:11 (1h 47m elapsed total, ~1h 37m in
    DRT). No log file (`flow.log`, `44-openroad-detailedrouting/
    openroad-detailedrouting.log`) had a new line after 01:35:17 -- the last
    output was a stream of `DRT-0120` large-net warnings, several nets with
    200-300+ pins (`net429` had 309).

    The process was not deadlocked in the classic sense -- `docker top`
    showed the `openroad` PID's accumulated CPU time still climbing at every
    check (2:20:39 -> 4:50:40 -> 5:50:56 -> 6:03:03 over the session) -- but
    the *rate* plateaued hard: `docker stats` CPU% dropped from an early
    peak of ~1700% (multi-threaded) down to a flat, unmoving ~100% for the
    last ~35+ minutes before cancellation, with zero new log output the
    entire time. Read together (single-core-equivalent work, no progress
    markers, on nets already flagged as routing-performance risks) this
    looks like DRT stuck iterating/ripping-up on one of the large
    high-pin-count nets rather than making forward progress -- but this is
    inferred from CPU/log activity, not confirmed from OpenROAD's internal
    routing state (never attached a debugger or reduced-net repro).

    Not yet done: no root cause established for *why* DRT plateaus here
    (vs. e.g. Open Item #9's IR-drop VDD issue, which is a distinct
    failure in a later step on a different trial). Worth trying a rerun
    with more verbose DRT logging or a per-net progress metric enabled, or
    isolating one of the 200+ pin nets to see if it alone reproduces the
    plateau, before resubmitting `reflected-grt0` as-is.

11. **Post-PNR timing diagnosis / possible AHB pipeline (2026-08-23:
    documented, not implemented).** Baseline job 4775 reached post-PNR STA
    before failing later in IR-drop reporting. Its worst setup path was at
    `max_ss_125C_3v00`: WNS **-48.691 ns**, from internal flip-flop `_82320_`
    to `_82663_`, in the `HCLK16` path group. The path begins at
    `u_grouper.u_grouper_soc_dig_ss.cpu_ss_ahb_s_if_HWDATA[9]` and traverses
    a long combinational AHB/peripheral-data chain before reaching the
    endpoint. Nominal and FF setup WNS were 0 ns; the next notable violation
    was an `IQ_CLK32` path at about -34.34 ns.

    A possible mitigation is a one-cycle pipeline at the Grouper AHB
    interconnect boundary, but **do not register HWDATA alone**. A safe
    implementation would capture the complete transaction bundle
    (`HADDR`, `HTRANS`, `HWRITE`, `HSIZE`, `HPROT`, and `HWDATA`), hold
    `HREADY` low for the added cycle, and then replay the selected peripheral
    request. This changes AHB latency and requires protocol/firmware
    regression. The existing external AHB bridge provides a reference
    capture-and-wait pattern.

    **RTL change made 2026-08-24, NOT HUMAN REVIEWED, NOT SIMULATED, NOT
    RE-RUN THROUGH STA.** `digital_ss.sv` now instantiates `ahb_conn_buff`
    (the existing register-slice module already used for the ROM/RAM slots in
    `ahb_interconnect_ss.sv`) between `u_cpu_ss` and `u_periph_ss`, at exactly
    the `cpu_ss_ahb_s_if_*` net the violating path starts on. This captures
    the full transaction bundle and holds `HREADY` low until `periph_ss`
    responds, same as the mitigation sketch above, but reuses proven in-tree
    logic rather than a hand-written FSM. **Deviates from the sketch above in
    one way worth flagging:** `ahb_conn_buff` registers both the request and
    response direction, so it costs **two** extra HCLK cycles per AHB
    transaction, not the one cycle assumed above. picorv32's native memory
    interface already tolerates wait states (it has to, for the existing
    ROM/RAM buffers), so this is expected to be functionally safe, but the
    CPI/throughput cost is larger than planned and unmeasured.

    **Lint-checked 2026-08-24** via `fusesoc run --target=lint grouper_soc`
    inside `hpretl/iic-osic-tools:chipathon26` (Verilator 5.046,
    `--lint-only`, full 38-module elaboration of the real SoC hierarchy):
    clean, 0 errors, no warnings on `digital_ss.sv`/`ahb_conn_buff`/the new
    pipeline instance. This only confirms it's legal, connects correctly, and
    elaborates - it does not confirm correct behavior.

    **Test P&R run 2026-08-24, job 4862** (`ahb-pipe-fix-reversed-local-sram-
    bridge-y1000`, same reversed-orientation/local-sram-bridge config as
    baseline job 4834, `PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000`), bundled
    together with the second VDD source below since both changes went into
    the same run. **DONE, exit 0, 0 DRC errors, 0 LVS errors** (matches
    4834's clean signoff). Full comparison against 4834:

    | Metric | 4834 (baseline) | 4862 (AHB fix + 2nd VDD source) |
    |---|---|---|
    | Setup WNS (`max_ss_125C_3v00`) | -42.86 ns | -42.92 ns |
    | Setup violator count | 2320 | **2038** (-282) |
    | VDD worst IR drop | 3.02% | **1.04%** |
    | VSS worst IR drop | 2.84% | 2.73% |

    **The pipeline stage worked as designed**: job 4834's worst path started
    at net `_82713_`, a single wide-fanout AHB bus signal violating to dozens
    of endpoints at once (`-42.86`, `-42.43`, `-40.62 ns`, ...) - the exact
    `periph_ss` broadcast-chain signature diagnosed above. In job 4862, that
    startpoint and every `periph_ss`-hierarchy net are **completely absent**
    from the violator list, and total violator count dropped by 282.

    **But top-line WNS did not improve**, because a second, unrelated
    violator was already sitting just below it at nearly identical severity
    and is now exposed as the new worst path: startpoint
    `u_grouper.u_grouper_soc_dig_ss.u_cpu_ss.u_cpu.latched_store` -
    `picorv32.v:1202`, a control flip-flop internal to picorv32's own
    instruction decode/writeback FSM (feeds `next_pc`/`reg_out` muxing for
    store instructions), with the same one-startpoint-fans-out-to-many-
    endpoints shape (`-42.92`, `-42.37`, `-42.31 ns`, ...). Nothing to do
    with the AHB fabric or anything touched by this fix.

    **Root cause of "this hasn't happened for Grouper-only P&R before"
    (2026-08-24): not a clock-rate difference.** `HCLK` is 16 MHz
    (`CLOCK_PERIOD: 62.5`) in both Grouper's own standalone
    `librelane/classic/config.yaml` and in `chip_top`'s
    `config_landscape_2235.yaml` - unchanged. The real reason:
    Grouper's standalone `STA_CORNERS` has `max_ss_125C_3v00` **commented
    out** - it has never once run SS-corner STA against picorv32. `chip_top`
    is the first flow to ever check this corner against this CPU, so the
    `latched_store` violation is not a regression the integration
    introduced; it is a pre-existing picorv32 SS-corner timing problem that
    was simply never measured before now. (`gf180mcu_fd_sc_mcu7t5v0` is
    5V-characterized cells run at 3.0-3.3V core, so SS timing is chronically
    tight across this whole project - see the `pnr-results` skill's standing
    note on this; Grouper had just never turned the corner on to see it.)

    **Decision (2026-08-24): do not modify picorv32 RTL** - `ip/picorv32` is
    a vendored fork and a change there needs its own real verification
    effort, out of proportion to what's been spent chasing this so far.
    Options that don't touch picorv32 RTL, not yet tried:
    - **Multicycle path exception (SDC-only)** on the `latched_store` fanout,
      if picorv32's own multi-cycle FSM genuinely doesn't need the result
      in one HCLK edge (picorv32 is a multi-cycle, not single-cycle, core -
      plausible but unconfirmed; needs reading the FSM around
      `latched_store`/`reg_out`/`current_pc` in `picorv32.v` before applying,
      since an unjustified MCP just hides a real bug rather than fixing one).
    - **AS cell library** (`gf180mcu_as_sc_mcu7t3v3`, native 3.3V) - already
      explored and documented (see `pnr-run` skill / AGENTS.md): closes SS
      timing correctly but is an unproven, community-maintained library, not
      the current tapeout plan.
    - Current flow policy already tolerates this: `TIMING_VIOLATION_CORNERS:
      []` in `config_landscape_2235.yaml` means P&R does not abort on open
      timing at any corner - this is explicitly an exploration policy "remove
      only for a timing-signoff run," so nothing is blocked today.

    **Second VDD source added 2026-08-24 (job 4862), confirmed working.**
    Grouper only ever had one modelled VDD downbond (Trouper's), unlike VSS
    which always had two - see `vsrc/README.md` for the full via4_5-based
    derivation of the new Grouper-west point `(140.30, 1466.70)`. This was
    diagnosed from job 4834's own per-node `net-VDD.csv` (143,611 nodes):
    voltage fell off smoothly and monotonically with distance from the single
    VDD source, from 3.259V near it to 3.201V at the far diagonal corner
    (~2.8mm away) - a mesh-distribution effect, not a last-mile/pin-access
    one. Adding the second source **cut worst-case VDD drop from 3.02% to
    1.04%** in job 4862 - confirms the diagnosis and is worth keeping
    regardless of the AHB fix's outcome. Still built on the same estimated/
    placeholder downbond model flagged throughout this section - must be
    replaced with real padframe data before signoff (Open Item #9/#47).

    Still needed before trusting the AHB pipeline change specifically: run
    `grouper_soc_tb`/`grouper_soc_directed` simulation (still not done - only
    lint and this P&R run have exercised it).

    **Root-caused why picorv32's `latched_store` net was never buffered
    (2026-08-24), then fixed it, config-only.** Two negative results first,
    both real data not guesswork:
    - Job 4869 (`MAX_FANOUT_CONSTRAINT` 10->4): **byte-identical** `max.rpt`
      to job 4862. `_82265_`'s (the `latched_store` flop) fanout stayed 37,
      untouched. Ruled out fanout count as the driver.
    - Job 4882 (`PL_RESIZER_SETUP_MAX_BUFFER_PCT`/`_HOLD_` 50->100 - note:
      the first attempt at this, job 4878, used
      `GRT_RESIZER_SETUP_MAX_BUFFER_PCT` instead, a **different, silently
      no-op variable for this flow** - no `*-repairdesign*grt*` stage exists
      here at all, confirmed against `librelane/flows/classic.py`; cancelled
      before completion once caught): still byte-identical to job 4862.
      Ruled out the resizer's area budget as the driver.

    Pulled real placement coordinates for `_82265_` and all 37 fanout
    destinations from job 4862's routed DEF to check a "scattered across the
    die" theory floated mid-investigation: **wrong** - all 38 instances sit
    within a 283x161 um box (12.7% x 7.2% of the die), tightly clustered, not
    scattered. The real mechanism, found in the post-CTS resizer's own log
    (`37-openroad-resizertimingpostcts`): `repair_timing -setup` ranks
    endpoints by *setup slack* using pre-route delay estimates, and
    `_82265_`'s path was never close enough to the top of that ranking to get
    touched, at any budget - `latched_store`/`_82265__`/`_81566_` never
    appear anywhere in that log. Its true delay (17.1 ns slew, 400 fF load
    driving 37 sinks directly off a minimum-strength `dffq_1`, no buffer
    tree) only becomes visible after real parasitic extraction (RCX, stage
    54) - a genuine estimation-accuracy gap between optimization-time and
    signoff-time STA, not a resource or fanout problem.

    **Fix: enabled `OpenROAD.RepairDesignPostGRT`** (`RUN_POST_GRT_DESIGN_REPAIR`,
    default `false` - LibreLane's own docstring: "experimental and may
    result in hangs and/or extended run times"; settings mirror
    `rtl-test/ol_picorv32/config_16mhz.json`, which already runs it
    successfully on this same CPU standalone). This step runs *after* global
    routing, using real routed-topology delay/slew estimates instead of
    pre-route Elmore estimates, and is **slew/cap-margin-driven** rather
    than setup-slack-ranked - a fundamentally different selection mechanism
    than the two passes that failed above. Job 4885, same base as 4862
    (AHB pipe fix + 2nd VDD source) plus this: inserted 721 real buffers
    across 411 nets. No hang, no extended runtime (27m52s, in line with the
    ~25-28min baseline). **Clean signoff: exit 0, 0 DRC errors, 0 LVS
    errors.**

    | Metric | 4862 (baseline) | 4885 (+ RepairDesignPostGRT) |
    |---|---|---|
    | Setup WNS (`max_ss_125C_3v00`) | -42.92 ns | **-31.71 ns** |
    | Setup TNS | -29,833 | **-16,051** |
    | Violator count | 2038 | **1122** |
    | `latched_store` (`_82265_`) violator | present | **gone** |
    | TT / FF corners | clean | clean (unchanged) |
    | Hold, all corners | clean | clean (unchanged) |

    **The worst path moved domains entirely** - no longer `HCLK16`
    (Grouper) at all. New worst: `IQ_CLK32` (Trouper), startpoint `_86838_`
    -> endpoint `_80220_`. This matches the very first baseline scan (job
    4775, Open Item #11's opening paragraph): *"the next notable violation
    was an `IQ_CLK32` path at about -34.34 ns"* - the #2-ranked violator
    back then, now exposed as #1 after the AHB and picorv32 violators are
    both cleared. Not yet investigated - a Trouper-side problem, out of
    scope for this item.

    Reusable runner-script additions from this investigation (all in
    `integration/scripts/run_librelane_pnr_landscape_reversed.sh`, following
    the existing `_OVERRIDE` env-var pattern): `MAX_FANOUT_CONSTRAINT_OVERRIDE`
    (pre-existing), `PL_RESIZER_SETUP_MAX_BUFFER_PCT_OVERRIDE`,
    `PL_RESIZER_HOLD_MAX_BUFFER_PCT_OVERRIDE`, `RUN_POST_GRT_DESIGN_REPAIR_OVERRIDE`,
    `GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH_OVERRIDE`,
    `GRT_DESIGN_REPAIR_MAX_SLEW_PCT_OVERRIDE`,
    `GRT_DESIGN_REPAIR_MAX_CAP_PCT_OVERRIDE`, `GRT_DESIGN_REPAIR_RUN_GRT_OVERRIDE`.
    The `GRT_RESIZER_SETUP_MAX_BUFFER_PCT_OVERRIDE` hook added first is a
    known no-op for this flow (see above) - left in place with a comment
    rather than removed, since it's still a real, correctly-spelled
    LibreLane variable that could matter for a flow that *does* run
    `RepairDesignPostGRT`'s sibling GRT-based steps.

    **Still not done: `RUN_POST_GRT_DESIGN_REPAIR=true` is not yet the
    default in `config_landscape_2235.yaml`** - job 4885 proved it via
    per-job override only. Worth promoting to the checked-in default once
    the `IQ_CLK32` path (and a few more full-flow confirmations, given
    LibreLane's own hang warning) have been looked at, so the win isn't
    dependent on remembering the override every time.

12. **Hybrid PDN trial (2026-08-23):** retain a sparse M2 rail for
    standard-cell repair, while using the localized SRAM M3/M4/M5 grid.

13. **PDN/PnR progress (2026-08-23):**
    - Job 4788 validated the original localized-bridge PDN: all VDD/VSS
      shapes connected; four non-fatal PDN-0110 via warnings remained.
    - Job 4795 showed that explicit local M4/M5 stripes on the rotated SRAM
      macro grids disconnect all SRAM VDD/VSS pins. Those stripes were removed;
      the proven SRAM Metal3-to-Metal4 grid is retained.
    - Job 4796 validated the corrected hybrid PDN: sparse global M2/M3 for
      standard-cell repair plus the existing SRAM grid. VDD/VSS connectivity
      passed with only the four PDN-0110 warnings.
    - Full PnR job 4797 still failed at `RepairDesignPostGPL`/`DPL-0036`,
      with two floating VDD/VSS nets and 63 unlegalizable instances.
    - Job 4798 retried with `GPL_CELL_PADDING=1` and
      `MAX_FANOUT_CONSTRAINT=32`; the same DPL-0036 failure and 63-instance
      cluster remained. The blocker is concentrated post-GPL repair pressure,
      not initial PDN connectivity.
    - Reversed-orientation checks (4790-4792) failed before PDN because the
      temporary configuration lost relative integration paths. No reversed
      PDN result is available yet.

14. **Porting Trouper's IQ_CLK32 MCP exceptions into `chip_top_dual_clock.sdc`
    (2026-08-25/26), to close the `u_dec` violator from item 11:** the
    `-31.71 ns` worst path (startpoint `_86838_` -> endpoint `_80220_`,
    `u_trouper.u_dec.hb1_stream[1]`, the decimator's `sd_decimator_poly_hb1_mac`
    -- a fully combinational 4-tap MAC never intended to close single-cycle at
    the SS corner) is exactly what Trouper's own standalone SDC
    (`ip/trouper/src/config/pnr_32m_scoped_v25_b6.sdc`) already relaxes via a
    scoped, honest `set_multicycle_path 3 -setup -through {u_dec.* u_sc.*
    u_tacc.* u_comb.*}` (that file's own history names this exact failure
    mode: "the decimator HB2 MAC surfaced at SS WNS -39.97 ns", job 2156).
    `chip_top_dual_clock.sdc` was a from-scratch 20-line skeleton that never
    inherited any of Trouper's MCP work.

    Ported all of `pnr_32m_scoped_v25_b6.sdc`'s scoped exceptions (u_dec/
    u_sc/u_tacc/u_comb paced-DSP MCP, the five narrower quasi-static
    `rb_*`-sourced cones, the psram barrel-shift MCP, the reg_bank CE-domain
    MCP, the psram debug-readback false-path) into `chip_top_dual_clock.sdc`,
    re-anchored one hierarchy level deeper under the `u_trouper.` prefix
    chip_top.v's `trouper_top u_trouper (...)` instantiation uses. Kept
    Trouper's own clock/uncertainty/I/O-delay statements and its
    `RESETB`/`HOST_CS`/`SPI_SCK` false-paths out of scope (chip_top.v's reset
    port is `HRESETn`, not `RESETB`; chip-level I/O timing is deliberately
    still unconstrained pending the package pin budget).

    **Verification job history** (all re-running job 4885's exact
    `grtrepair-reversed-local-sram-bridge-y1000` trial config against the
    updated SDC, `PNR_TRIAL_TAG` suffixed per attempt to avoid clobbering):
    - **Job 5038:** failed in 11s at config-load -- `--snapshot-exclude
      'ip/**'` (meant to skip large unrelated IP trees per the `sge-job`
      skill's general guidance) also excluded `ip/picorv32/picorv32.v`,
      which this config genuinely needs. Fixed by excluding only the actually-
      unused top-level `ip/` subtrees (`ws-run1`, `gf180mcu_ocd_ip_sram`,
      `sscs-chipathon-2026`, `gf180mcu_osu_sc`, `gf180mcu_fd_ip_sram` --
      confirmed unreferenced by `config_landscape_2235.yaml` via grep), not
      `ip/**` wholesale.
    - **Job 5039:** completed the full flow, but its `max_ss_125C_3v00`
      WNS/TNS/violator-count and worst-path Startpoint/Endpoint came back
      **byte-identical** to job 4885 (`-31.70556529282855`, TNS
      `-16050.69928620429`, 1122 violators, same `_86838_`/`_80220_` path) --
      not a silent SDC no-op (no STA-0361/STA-0472 in the log), but a
      genuinely stale test: `hqsub --snapshot` stages from the **persistent
      NFS mirror** (`/srv/eda/designs/timothyn-dev/lora-mimo`), not the local
      working tree, and the edited `chip_top_dual_clock.sdc` had never been
      `rsync`'d there (same class of gotcha item 13's own doc references
      elsewhere in this repo for `integration/`). Confirmed post-hoc: the
      job's snapshot copy of the SDC had zero `u_trouper.u_dec` occurrences.
    - **Job 5040:** `rsync`'d the fix to the NFS mirror first, verified via
      md5sum + grep that the snapshot actually contained it, then resubmitted.
      Ran clean through synthesis/floorplan/CTS/global-routing, then failed
      at 14m09s with **`DPL-0036` (detailed placement failed on instance
      `_71880_`, a `nand4_1`) inside `OpenROAD.RepairDesignPostGRT`** (step
      41/71) -- the same experimental step (job 4885's own commit message:
      LibreLane's docstring calls it "experimental and may result in hangs
      and/or extended run times") that item 11 added specifically to fix the
      unrelated picorv32 `latched_store` violator, nothing to do with this
      SDC change.
    - **Job 5041:** identical retry (to rule out a scheduler-level flake).
      Failed byte-identically -- same instance, same iteration (13000, 37108
      nets remaining), same wirelength (4,169,331 um), same routed-net count
      (49,633). Deterministic, not a flake.
    - **Root-caused `_71880_`'s location:** DEF coords `(3339840, 4194400)`
      at 2000 DBU/um -> `(1669.9, 2097.2) um`, ~6.3 um outside Obstruction B's
      left edge (`1676.25,1117.5 -> 2235,2235`), y deep inside its range --
      i.e. sitting right against the PDN-keepout boundary. Cross-checked
      against `resolved.json`: `DPL_CELL_PADDING`/`GPL_CELL_PADDING` were both
      **0** -- no legalization slack anywhere in this flow, at ~67% placement
      density (see item 15 below) concentrated against a hard obstruction
      edge.
    - **Job 5042:** added `DPL_CELL_PADDING: 1` to `config_landscape_2235.yaml`
      (matching `ip/trouper/rtl-test/ol_trouper_top/config_current_signoff.json`
      -- the config paired with this exact SDC, running `DPL_CELL_PADDING: 1`
      successfully at `PL_TARGET_DENSITY_PCT: 88`, a much tighter floorplan
      than this one's ~67%) and a `DPL_CELL_PADDING_OVERRIDE` runner hook.
      `rsync`'d + verified before submitting. **Failed byte-identically to
      5040/5041 again** -- the padding value had zero effect.
    - **Root-caused the zero-effect, two independent bugs:**
      (1) *Ordering*: `repair_design_postgrt.tcl` calls OpenROAD's
      `repair_design` (which does its own internal incremental legalization
      -- confirmed this is what's actually emitting DPL-0034/0035/0036,
      immediately after `repair_design`'s own iteration-progress table, before
      the script ever reaches its later `dpl.tcl` source) *before* sourcing
      `common/dpl_cell_pad.tcl`, which is the only place `DPL_CELL_PADDING`
      gets applied (`set_placement_padding`). Padding is a per-OpenROAD-
      session runtime setting, not persisted in the `.odb` -- each pipeline
      step is a fresh process, so it's simply unset for `repair_design`'s own
      call.
      (2) *Truncation*: `common/dpl_cell_pad.tcl` computes
      `cell_pad_side = $DPL_CELL_PADDING / 2` via Tcl integer division, so
      `DPL_CELL_PADDING=1` truncates to **0** effective per-side padding even
      when applied in time. Trouper's own `config_current_signoff.json` never
      noticed because its problems were timing, not placement legality.
      Wrote `integration/scripts/patch_dpl_padding_postgrt.sh` (same
      writable-copy-of-librelane mechanism as the pre-existing
      `patch_irdrop_tcl.sh`, which it shares the copy with) to source
      `dpl_cell_pad.tcl` before the `repair_design` call; wired it into
      `run_librelane_pnr_landscape_reversed.sh` alongside the irdrop patch;
      bumped `DPL_CELL_PADDING` to `2` (-> 1 site/side, now that it's
      non-zero and applied in time).
    - **Job 5044:** both fixes `rsync`'d + verified present in the submitted
      snapshot; log confirmed both patches actually fired (`patch_irdrop_tcl.sh:
      patched ...` and `patch_dpl_padding_postgrt.sh: patched ...`). **Failed
      again at the same instance/iteration** (12m49s) -- but not a no-op this
      time: the error's line number shifted (`repair_design_postgrt.tcl, 51`
      vs the unpatched `45`, matching the patch's inserted lines) and the
      resizer's net-repair counts shifted slightly (50113 vs 50108 total
      nets, 44 vs 43 buffers) -- padding genuinely was live and changed
      behavior, just not enough to legalize `_71880_`. Read as evidence this
      is a **local capacity problem at the obstruction edge**, not a "no
      padding at all" problem: padding makes each cell need *more* room, so
      if the row segment at `_71880_`'s location is already saturated against
      Obstruction B's hard boundary, more padding can fail to help (or even
      hurt) that specific spot while helping everywhere else. Consistent with
      item 13's independent `DPL-0036` history above (job 4798: `GPL_CELL_PADDING=1`
      also didn't clear a DPL-0036/63-instance cluster there either --
      "concentrated post-GPL repair pressure, not initial PDN connectivity")
      -- this design appears to hit real, recurring legalization capacity
      limits right at its obstruction edges, not a simple padding-value gap.
    - **Job 5048 (in progress):** rather than keep tuning padding against an
      experimental, admittedly-fragile repair step that has nothing to do
      with the SDC fix under test, isolate the two concerns --
      `RUN_POST_GRT_DESIGN_REPAIR_OVERRIDE=0` (disabling the step that's
      actually failing) on top of the same MCP SDC, to get a clean
      unblocked STA read on whether the ported MCP exceptions alone close
      the `u_dec` `-31.71 ns` violator. (The picorv32 `latched_store`
      violator this step was added for in item 11 will reasonably reappear
      in this run's numbers -- expected, not a regression, since it's simply
      not being fixed by this trial.) Result pending.

    **Open, unresolved as of this writing:** whether the MCP exceptions
    actually close `u_dec` (blocked on job 5048), and separately, a real
    fix for the `DPL-0036`/obstruction-edge legalization capacity issue --
    padding tuning has not worked twice now (jobs 4798 and 5042/5044), across
    two different root causes in this design's history. Worth investigating
    the row/site capacity directly at Obstruction B's edge (row length vs.
    cell count needing placement there) rather than another padding-value
    guess, if `RUN_POST_GRT_DESIGN_REPAIR` is wanted back for the picorv32
    fix.

15. **Effective vs. actually-placeable utilization on this floorplan
    (2026-08-26):** `IFP-0104`'s "Effective utilization: 0.411" divides
    placed-cell area by the full core bbox (`4,894,097 um^2`), which
    includes the two `FP_OBSTRUCTIONS` PDN keepouts -- nothing can be placed
    there. The floorplan log shows those obstructions cut the real
    placement-site count from 2,229,454 to 1,392,900 (37.5% of sites
    unusable). Against the actually-placeable ~62.5% of the core bbox
    (~3,058,800 um^2), effective utilization is really **~65.8%**, matching
    OpenROAD's own obstruction-aware `GPL-0019 Utilization: 66.748%` / target
    density auto-tuned to ~67.5% (`GPL-0063`) -- `IFP-0104`'s number just
    isn't obstruction-aware. Real headline: **~66-67% of usable area**, not
    41% of the die. Density itself is a normal, closeable value for
    `gf180mcu_fd_sc_mcu7t5v0` (routability risk usually starts past ~75-80%);
    the risk is concentration at the obstruction edges specifically -- see
    item 14's `DPL-0036`/`_71880_` history above, and the high-fanout clock/
    reset nets (`HRESETn` 5,210 terminals, `IQ_CLK` 5,126, `HCLK` 2,803,
    `u_grouper.u_rst_resync_sync.data_r[1]` 1,406 -- pre-CTS `GRT-0281`
    warnings, job 5041's global-placement log) that have less free routing
    volume to work with right at those same edges.

16. **Three parallel `DPL-0036`/`_71880_` fix strategies, run on
    `proxmox-agent` and checked 2026-08-26 -- Strategy A (obstruction
    extension) wins outright.** All three ran on top of the ported Trouper
    MCP SDC exceptions (item 14).

    | Job | Strategy | Outcome |
    |---|---|---|
    | 5052 | Halo shrink `FP_MACRO_HORIZONTAL_HALO` 12->6um (widen, not eliminate, the sliver) | **Regression, dead.** Fails *earlier* than before, in `OpenROAD.GeneratePDN`: `[PDN-0178] Remaining channel ... on Metal1 for nets: VDD, VSS` x3, then `[PDN-0179] Unable to repair all channels.` Shrinking the halo exposed Metal1 power-rail routing channels around the SRAM macros that the PDN grid can no longer repair -- never even reaches placement. |
    | 5049 | MCP SDC fix alone, `RUN_POST_GRT_DESIGN_REPAIR=0` (isolation baseline/control) | Full 80-stage flow completes clean (no `DPL-0036`, since the repair step that trips it never runs). `max_ss_125C_3v00` WNS = **-28.67ns**, but on a *different* violator: `_82265_ -> _81556_`, `HCLK16` path group -- nothing IQ_CLK32/`sd_decimator_poly_hb1_mac`-related in the top path. |
    | 5053 | Obstruction B extended (`FP_OBSTRUCTIONS` 2nd entry x1 1676.25->1665, baked into `config_landscape_2235.yaml`) + `DPL_CELL_PADDING=2` + ordering patch, repair step **on** | **Full 80-stage flow completes clean.** `41-openroad-repairdesignpostgrt` (the step that killed 5040/5041/5042/5044 with `DPL-0036` on `_71880_`) now succeeds -- empty `error.log`, real routed DEF out. Zero DRC (`route__drc_errors: 0`, `magic__drc_error__count: 0`). `max_ss_125C_3v00` WNS = **-14.32ns**, `_81501_ -> _85417_`, `IQ_CLK32` path group. |

    **Conclusions:**
    - Strategy A actually fixes the `DPL-0036` placement-legality failure --
      confirms the DEF-geometry root cause (item 14: the ~10um/18-site
      structural sliver between the last SRAM macro's halo and Obstruction
      B's edge) was correct, and that swallowing it into the obstruction
      (rather than tuning padding/halo around it) was the right fix class.
    - **The original `-31.71ns` `u_dec`/`sd_decimator_poly_hb1_mac` violator
      this whole investigation started from (item 14) is closed** -- neither
      5049's nor 5053's worst path traces through that MAC any more. The
      ported Trouper MCP exceptions did their job on the violator they were
      written to fix.
    - Two *new*, previously-masked setup violators are now the worst paths:
      an `IQ_CLK32` one (5053, `-14.32ns`, near an SRAM-adjacent
      `grp_we`-driven register cluster with heavy fanout/load-slew
      buffering) and an `HCLK16` one (5049, `-28.67ns`, `_82265_ ->
      _81556_`). Both are new discoveries, not yet diagnosed -- out of
      scope for this investigation, worth a fresh pass.
    - **Recommendation, adopted:** promote Strategy A as the permanent
      config -- it is already the checked-in state of
      `config_landscape_2235.yaml`/`run_librelane_pnr_landscape_reversed.sh`
      (job 5053 ran the real checked-in config, not a one-off override).
      Strategy B (`FP_MACRO_HORIZONTAL_HALO_OVERRIDE`) should not be used
      for this floorplan -- do not resurrect it without also re-deriving
      the PDN Metal1 channel geometry it broke.

17. **HCLK16 violator investigation (2026-08-26): fanout confirmed, but the
    `-max_fanout` tool-level fix doesn't exist; Strategy A also shown to be
    non-deterministic under identical inputs.**

    Traced the `-28.67ns` `HCLK16` violator (job 5049's baseline, item 16)
    to `u_grouper.u_grouper_soc_dig_ss.u_cpu_ss.u_cpu.latched_store`
    (PicoRV32 core, 39 fanout) -> ~15 gates of decode/mux logic ->
    `u_grouper.u_grouper_soc_dig_ss.periph_ahb_s_if_HADDR[16]`. Confirmed
    `MAX_FANOUT_CONSTRAINT: 10` (`set_max_fanout` in `base.sdc`) never
    actually shrinks this net -- fanout is 39 identically at synthesis, in
    job 5049 (repair off), and in job 5053 (repair on): no stage in the flow
    ever buffer-splits it.

    Root cause, tried to fix via a new `patch_max_fanout_repair.sh`
    (patching `-max_fanout` into `repair_design`'s arg list, same pattern as
    the other two patch scripts) -- **wrong fix, reverted.** This OpenROAD
    build (`26Q2-254-g61932e897`) genuinely has no `-max_fanout` flag on
    `repair_design` at all (`help repair_design`: only `-max_wire_length/
    -max_utilization/-slew_margin/-cap_margin/-buffer_gain/
    -pre_placement/-match_cell_footprint/-verbose`; the patched flag
    crashed with `STA-0562`, job 5056). Confirmed via web research this
    isn't specific to this pinned image -- current upstream OpenROAD docs
    list the identical argument set with no `-max_fanout`, so a newer
    `hpretl/iic-osic-tools` tag would not restore this capability; not worth
    the risk of destabilizing a proven pinned image for a feature that was
    never really there. `patch_max_fanout_repair.sh` deleted, unhooked from
    `run_librelane_pnr_landscape_reversed.sh`.

    Pivoted (2026-08-26, explicitly NOT an RTL change, per direction) to the
    real remaining tool-level lever: `PL_RESIZER_SETUP_MAX_BUFFER_PCT`
    (default 50, raised to 80) + `PL_RESIZER_SETUP_REPAIR_TNS_PCT=100` (new
    override hook added), both legitimate, already-wired `repair_timing`
    args in `rsz_timing_postcts.tcl` (step 37) -- more buffering/gate-cloning
    budget against the worst setup path, not a fanout-count-specific repair.

    **Job 5064 (first verification attempt): FAILED, but at a NEW,
    unrelated point -- `DPL-0036` at step 32 (`RepairDesignPostGPL`), on
    `output13`/`input1` (I/O-adjacent instances), never even reaching step
    37 where the buffer-budget change takes effect.** Diffed against job
    5053 (the Strategy-A baseline that passed cleanly): step 32's resizer
    output is byte-for-byte identical between the two runs (287 slew
    violations, 96 cap violations, 285 resized, 532 buffers/295 nets, same
    2-floating-net warning) -- the *only* difference is that legalization
    then succeeds in 5053 and fails in 5064, on different instances than the
    original `_71880_` failure. Since `PL_RESIZER_SETUP_MAX_BUFFER_PCT`/
    `PL_RESIZER_SETUP_REPAIR_TNS_PCT` don't execute until step 37 (never
    reached), they cannot be the cause. **Initial (WRONG) conclusion:**
    Strategy A's fix isn't fully deterministic -- see correction below.

    **Job 5068 (retry, same script): FAILED identically to 5064** -- same
    `output13`/`input1` instances, same resizer stats. Two independent runs
    failing byte-for-byte identically is the opposite of what the
    non-determinism theory predicts (a coin flip landing the same way twice
    is not evidence of a coin flip). Diffed the two jobs' full `resolved.json`
    against 5053's instead of trusting which variables "should" matter, and
    found the real cause: **a bug in the scratch job script itself, not in
    the tool.** The scratchpad had been wiped between sessions, so
    `rerun_stratA_bufferbudget.sh` was rebuilt from memory of the trial-tag
    naming convention (`...-y1000-...`) without actually re-setting the
    override env vars that name refers to. Confirmed missing/wrong in both
    5064 and 5068 vs. 5053: `PL_MAX_DISPLACEMENT_Y` (1000 in 5053, silently
    fell back to LibreLane's default 100 in both retries) and
    `GRT_DESIGN_REPAIR_MAX_SLEW_PCT`/`GRT_DESIGN_REPAIR_MAX_CAP_PCT` (75 in
    5053, fell back to default 10 in both retries). A tighter
    `PL_MAX_DISPLACEMENT_Y=100` gives detailed-placement far less room to
    legalize the post-resizer buffer placement than the `1000` Strategy A
    was actually proven under -- a real, deterministic, self-inflicted
    regression, reproducing identically run to run exactly because it *is*
    deterministic. **The item-16/17 "Strategy A is non-deterministic"
    conclusion above is retracted** -- not supported by this evidence.
    Resubmitted as **job 5069** (`rerun_stratA_bufferbudget_fixed.sh`) with
    `PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000` and both
    `GRT_DESIGN_REPAIR_MAX_SLEW_PCT_OVERRIDE`/`MAX_CAP_PCT_OVERRIDE=75`
    restored alongside the buffer-budget change, matching 5053's actual
    resolved config exactly plus the intended additions.

    **Process lesson:** when a scratchpad gets wiped between sessions and a
    job script has to be reconstructed from a trial-tag string or memory
    rather than re-read from a prior working copy, diff the new job's
    `resolved.json` against the last known-good run's *before* trusting a
    "which variables matter" assumption -- would have caught this
    immediately instead of after two wasted full P&R runs and one wrong
    documented conclusion.

    **Job 5069 (corrected config): SUCCEEDED -- conclusive result, buffer
    budget is confirmed a dead end.** `resolved.json` diff vs. 5053 showed
    only the 2 intended keys differ (`PL_RESIZER_SETUP_MAX_BUFFER_PCT`
    50->80, `PL_RESIZER_SETUP_REPAIR_TNS_PCT` unset->100). Every measured
    result came back **byte-identical to job 5053**: IQ_CLK32 worst path
    `-14.324463798346189ns` (same `_81501_`->`_85417_`, matching to 15
    decimal places), `latched_store` fanout still 39, 0 DRC/LVS errors.
    Raising the resizer's buffer budget changed nothing -- it wasn't
    budget-constrained at 50% to begin with, so more headroom converges to
    the identical local optimum. A genuinely clean negative result, not a
    wasted run.

    **Good news found along the way: the -28.67ns HCLK16 violator (item 16)
    was already being compared against the wrong baseline.** Job 5049 (that
    number's source) had `RUN_POST_GRT_DESIGN_REPAIR` disabled -- a
    deliberately crippled isolation run. Checking job 5053's own HCLK16
    path directly (not previously done, since IQ_CLK32's -14.32ns dominated
    as the reported worst-case) shows **Strategy A + repair enabled
    already closes HCLK16 down to -5.811309ns** -- both 5053 and 5069 agree
    on this exactly. So the already-checked-in config (Strategy A,
    `DPL_CELL_PADDING=2`, `RUN_POST_GRT_DESIGN_REPAIR=1`) was already doing
    most of the real work; no further HCLK16-specific tuning is needed.

    **Net conclusion, HCLK16/fanout investigation closed:** with the
    checked-in Strategy A config, IQ_CLK32 (`-14.32ns`) is the true
    remaining worst violator, not HCLK16. No further tool-level lever is
    available for it -- `repair_design -max_fanout` doesn't exist in this
    OpenROAD build (or in current upstream OpenROAD at all), and the
    resizer buffer-budget increase is now proven a no-op. Closing this
    without an RTL change (register duplication of `latched_store`, or
    restructuring the AHB address-decode cone) would require reopening the
    no-RTL constraint set for this investigation.

18. **Indicative-only SS/4.5V standalone OpenSTA check (2026-08-26): both
    remaining setup violators fully close with real positive margin.**
    Motivation: `-14.32ns` (IQ_CLK32, item 17) roughly matches Trouper's
    own standalone block-level signoff number, a good validation point, but
    the user asked for a cheap indicative check of how much margin a higher
    supply voltage would buy, explicitly caveated as not physically valid
    (`gf180mcu_fd_sc_mcu7t5v0` is 3.3V-rated).

    No `ss_025C`/4.0V corner exists in the PDK's characterized lib set at
    all -- confirmed by listing the full `gf180mcu_fd_sc_mcu7t5v0` lib
    directory: SS/FF are only characterized at the hot/cold extremes
    (125C/-40C), never at 25C (only `tt` is); voltage steps are fixed at
    1.62V/3.00V/4.50V, no 4.0V point. OpenSTA doesn't interpolate between
    `.lib` corners. So a literal "SS, 4V, 25C" run isn't possible without
    fabricating timing data -- used the closest real, fully-characterized
    corner instead: `ss_125C_4v50`. Discussed with the user that this
    proxy is pessimistic on temperature (125C vs. a real 25C target) and
    slightly optimistic on voltage (4.5V vs. a real ~4V target) relative to
    what a real overdriven-at-room-temperature scenario would show -- a
    rough two-sided proxy, not a clean substitute.

    **Method: standalone OpenSTA-only check (no full P&R re-run)** --
    reused job 5069's saved `final/odb/chip_top.odb` (bundles tech +
    physical + logical, avoiding a separate LEF-path dependency that a
    first attempt via `read_verilog`/`link_design` hit --
    `[ERROR ORD-2010] no technology has been read`, since OpenROAD's
    unified app requires the tech DB even for a logical-only link), plus
    `final/sdc/chip_top.sdc` and `final/spef/max/chip_top.max.spef` (all
    real materialized files, not symlinks -- avoids depending on job
    5069's own snapshot still existing). Only the standard-cell liberty was
    swapped, from `ss_125C_3v00.lib` to `ss_125C_4v50.lib`; the SRAM macro
    (`gf180mcu_ocd_ip_sram__sram1024x8m8wm1`) liberty stayed at its real
    `ss_125C_3v00.lib` -- no 4.50V corner is characterized for the SRAM
    macro either, so this run measures "logic overdriven to 4.5V, SRAM at
    its real 3.3V corner", a further approximation on top of the
    already-not-physically-valid premise.

    Reading job 5069's outputs from a *different* job's container required
    discovering `/foss/history` -- a read-only NFS mount of the user's
    entire `runs` tree (`/srv/eda/runs/timothyn-dev`), distinct from the
    per-job `/foss/runs` (that job's own output dir only) and
    `/foss/designs` (the design snapshot/live mirror). `--run-dir <existing
    id>` does NOT let a new job attach read-only to another job's
    directory -- it errors `run_dir '<id>' already exists` on collision (a
    first attempt silently landed the new job's `/foss/runs` somewhere
    else instead, per `hqsub`'s auto-generated-uuid fallback, and failed to
    find the staged tcl script there). `/foss/history/<project>/<job id>/<trial
    dir>/...` is the reusable pattern for reading a *completed* job's
    outputs from a fresh job -- worth remembering for any future
    cross-job-reuse case instead of re-discovering this each time.

    **Result (job 5074): WNS = 0.00ns, TNS = 0.00ns -- every setup path in
    the design passes.**

    | Path | `ss_125C_3v00` (real, job 5069/5053) | `ss_125C_4v50` std cells / SRAM held at real `ss_125C_3v00` (indicative) |
    |---|---|---|
    | IQ_CLK32 (`_81501_`->`_85417_`) | **-14.324464ns VIOLATED** | **+1.99ns MET** |
    | HCLK16 (`_82218_`->`_81766_`) | **-5.811309ns VIOLATED** | **+19.16ns MET** |

    The top-5 worst-path report is now dominated by recovery/removal
    checks against the async reset (all comfortably met, ~53ns margin) --
    confirming setup is no longer the binding constraint at this corner at
    all, not just marginally better. The magnitude (closing a -14ns gap to
    +2-19ns of margin off a ~1.2V bump on the logic alone) is consistent
    with item 17's finding that the IQ_CLK32/HCLK16 violators run through a
    genuinely deep (15+ gate-level) combinational decode chain -- exactly
    the kind of path whose delay is most voltage-sensitive. Read as a
    rough, two-sided-uncertain indication (see proxy caveat above) that a
    real, achievable overdrive (e.g. ~4V at room temperature, still within
    reason for margin exploration even though still above the 3.3V rating)
    would very plausibly land in comfortably-positive territory too -- not
    a quantified claim of exactly how much margin, and not usable as a
    signoff number.

19. **Job 5069 full signoff summary (2026-08-27): current best chip_top
    result -- timing, pins, utilization, DRC/LVS, all checked directly
    against real outputs, not assumed.** This is the config to treat as the
    reference baseline going forward: Strategy A obstruction fix (item 16,
    baked into `config_landscape_2235.yaml`) + `DPL_CELL_PADDING=2` +
    ordering patch + `RUN_POST_GRT_DESIGN_REPAIR=1`, plus the (confirmed
    no-op, item 17) buffer-budget tuning left in place harmlessly.

    **Timing** (`final/metrics.json`):

    | Corner | Setup WNS | Setup TNS | Setup violations | Hold WNS | Hold TNS |
    |---|---|---|---|---|---|
    | `nom_tt_025C_3v30` | 0ns | 0 | 0 | 0ns | 0 |
    | `min_ff_n40C_3v60` | 0ns | 0 | 0 | 0ns | 0 |
    | `max_ss_125C_3v00` | **-14.32ns** | **-2039.12ns** | **402** | 0ns | 0 |

    Hold is fully clean on every corner. Setup only violates at the SS
    corner -- nom/ff both have healthy positive margin (worst-slack +9.2ns
    and +18.8ns respectively). **402 setup violations at SS**, not just the
    single worst path (`_81501_`->`_85417_`, IQ_CLK32) tracked in items
    16-18 -- a real population of paths in the same danger zone, worth
    knowing before calling this closed. One open, not-yet-root-caused flag:
    `timing__drv__floating__nets: 2` (matches the `RSZ-0020` warning seen
    repeatedly in logs across jobs) -- likely benign (tie-cell/unused-pin
    artifact, consistent with this project's prior findings elsewhere) but
    unverified.

    **Pin placement: verified correct and complete against the DEF
    directly** (not just the io_placement cfg intent). All 24 `chip_top`
    ports (the full Trouper pad-level list -- Grouper has no exposed
    external pins yet, so `io_placement_landscape.cfg`'s `#S`/`#W` being
    empty is correct, not a gap) landed exactly where specified: North =
    `HCLK`/`HRESETn`/`IRQ_OUT`/`HOST_CS` (4/4), East = `IQ_CLK`/
    `IQ_DATA_I/Q[0:3]`/`PSRAM_*`/`SPI_*`/`REMOD_A_I/Q` (20/20). No pins
    off-boundary or unplaced.

    **DRC/LVS: both clean.** `magic__drc_error__count: 0`,
    `route__drc_errors: 0` (routing DRC converged from 271 real errors at
    iteration 0 down to 0 by the final iteration -- normal ripup-reroute
    convergence, not a suppressed check). LVS: 0 across
    `lvs_error__count`/`lvs_device_difference__count`/
    `lvs_net_difference__count`/`lvs_property_fail__count`/
    `lvs_unmatched_device__count`/`lvs_unmatched_net__count`/
    `lvs_unmatched_pin__count`.

    **Utilization: naive metric is misleading, real figure already
    excludes macros+obstructions and is 67.08%.**
    `design__instance__utilization` (46.7%) divides placed area by the
    raw core bbox, obstruction/macro-unaware -- same flaw item 15 already
    flagged for an earlier job. Verified the real number directly from
    `28-openroad-globalplacement`'s own arithmetic:

    | Quantity | Area (um^2) |
    |---|---|
    | Core area (die minus margins) | 4,894,097 |
    | - Fixed instances (SRAM macros + tap/endcap + obstruction-blocked area) | 2,607,834 |
    | = Area actually eligible for standard-cell placement | 2,286,263 |
    | Movable (std-cell) instances placed | 1,533,670 |
    | **Utilization = 1,533,670 / 2,286,263** | **67.08%** (matches `GPL-0019` exactly) |

    Breakdown of the 2,607,834 um^2 "fixed" figure: ~621,654 um^2 SRAM
    macros (4 x 301.3x515.81, matches the cell-type report exactly),
    ~72,020 um^2 tap/endcap cells, ~1,885,781 um^2 the two
    `FP_OBSTRUCTIONS` keepouts (matches `1117.5x1117.5 + 570x1117.5`
    closely), ~28,000 um^2 residual (IO-ring/halo rounding). **The 67.08%
    figure already has macros and obstructions carved out of the
    denominator -- there is no larger "excluding macros" number still
    hiding behind it; 67% already is that number.**

    **SRAM macro spacing (asked about, 2026-08-27): already tight, not
    much slack to reclaim.** Macro size `301.3 x 515.81um`, instance pitch
    `321.3um` (four instances at x=388.65/709.95/1031.25/1352.55, same
    y=1695.67, orientation N) -> real gap between adjacent macros is only
    **~20um** (~6.6% of macro width), confirmed both from the LEF/config
    math and by measuring the rendered GDS pixel-for-pixel (~29px gaps at
    the 3200px/2235um render scale = ~20.2um, matching exactly).
    `FP_MACRO_HORIZONTAL_HALO` (12um default per edge) already consumes
    most of that gap as PDN/routing keepout. The large black regions
    visible in the render are NOT SRAM spacing -- they're the two
    `FP_OBSTRUCTIONS` boxes (fixed Trouper/Grouper die-partition geometry,
    items 1-8), a much bigger decision than macro pitch. Already tried
    tightening clearance in this exact area once (Strategy B,
    `FP_MACRO_HORIZONTAL_HALO` 12->6um, item 16) -- it broke PDN generation
    outright (`PDN-0178/0179`, unrepairable Metal1 channels). Not
    attempted again since -- left as a live option if the user wants to
    accept that risk with a smaller cut (e.g. 8-10um) instead of 6um.

    **GDS render published**: `reports/chip_top_5069_final.png`
    (3200x3200, metal/via layers + cell-footprint wash, via the `gds-plot`
    skill's `raster_gds.sh`), synced to the NFS mirror alongside this
    doc.

20. **Combined-pinout + Grouper-pads P&R, and HCLK frequency sweep
    (2026-08-28): first full flow with Grouper's external padframe wired
    out; 25 MHz Grouper clock judged feasible for the test chip.**

    Two changes vs the job 5069 baseline (item 19), same recipe otherwise
    (reversed SRAM orientation, local SRAM PDN bridge, same override set):
    - `chip_top.v` now exposes Grouper's padframe -- `UART_TX`/`UART_RX` and
      `GPIO_0..15`. GPIO are `inout` for interface shape but driven
      always-on with no top-level tri-state (same P&R model as `PSRAM_SIO`;
      a `1'bz` synthesises to unmappable `$_TBUF_` cells -- job 5126, 16
      unmapped -> fixed in job 5127). `VSS`/`VDD` are not RTL ports
      (core-only design). Pad-ring integration must restore GPIO OE off
      `gpio_oe` (GPIO/QSPI mux -- see Pinout.md).
    - `io_placement_landscape.cfg` rewritten to the real combined pinout
      (Open Item #2 table): Trouper radio datapath on `#S`, PSRAM/IRQ_OUT
      on `#E`; Grouper UART+`gpio_0..4` on `#W`, `gpio_5..15` + the
      <=10 MHz host SPI slave on `#N`. First rewrite had `#`-prefixed
      comments -> `Odb.CustomIOPlacement` parse failure ("identifier/regex
      '#' requires a direction to be set first", job 5128); the parser
      treats every `#` line as a direction marker. Comments moved to
      `io_placement_landscape.README.md`; `VSS`/`VDD` dropped from the cfg
      (held as `$` reserve slots) since they are not netlist ports.

    Infra note: job 5130 (first attempt of the 16 MHz run) **stalled ~25 min
    at stage 54** (`Odb.CellFrequencyTables`) on `gaming-pc` -- the user
    happened to be running something big on that box at the time (it
    doubles as a workstation), so the job was starved of CPU/IO. Not memory
    (job 5131's per-stage `process_stats.json` peaks at ~4 GiB for the whole
    flow, so `--mem 24G` is ~6x the real footprint) and not a design/config
    fault. Killed and resubmitted (5132/5133) pinned `--node proxmox-agent`.
    `gaming-pc` is normally the fastest node and the default choice; only
    pin away from it if the user is mid-way through heavy local work.

    **Job 5131 -- HCLK retimed 16 MHz -> 25 MHz** (SDC `create_clock`
    `-period 62.5 -> 40.0` on HCLK only; IQ_CLK32 untouched at 31.25 ns;
    variant runner `run_librelane_pnr_landscape_reversed_hclk25.sh`).
    Full flow, clean:

    | Check | Result |
    |---|---|
    | Routing DRC | 0 (converged 28 -> 4 -> 3 -> 0) |
    | Magic DRC | 0 |
    | LVS | 0 (all `lvs_*` counters) |
    | Unmapped cells | 0 |
    | Macros placed | 4 SRAMs |
    | Hold, all corners | clean (WNS 0; worst slack +0.03 ns min_ff) |
    | Setup `nom_tt_025C_3v30` | **+9.48 ns MET** (worst path IQ_CLK32) |
    | Setup `min_ff_n40C_3v60` | **+18.94 ns MET** |
    | Setup `max_ss_125C_3v00` | **-15.19 ns**, TNS -4362 ns, 751 viol paths |

    stdcell count 68,131; `design__instance__area` ~1.41 Mum^2.

    **The SS worst path moves onto Grouper at 25 MHz.** At 16 MHz (job
    5069) the SS WNS violator was a Trouper IQ_CLK32 decimator cone
    (-14.32 ns). At 25 MHz it is:

        _87905_ (u_grouper...u_cpu_ss.ram_sel_r, HCLK16)
          -> gen_sram[3].u_wrapper.u_sram_macro/GWEN      -15.19 ns

    -- the CPU -> SRAM write-enable / chip-enable decode cone, a ~15-gate
    combinational chain (`ram_sel_r` fanning to all 4 SRAMs' `GWEN`/`CEN`
    plus nearby CPU regs dominates the top ~25 of the 751 violators). This
    path is **period-limited**: ~+7 ns SS slack at 16 MHz (62.5 ns) ->
    -15 ns at 25 MHz (40 ns), so its SS ceiling is ~18 MHz. It is **not**
    touched by the CPU->periph pipeline slice (Open Risks #1) -- RAM is
    wired straight to the CPU on Grouper `dev`, off the AHB fabric.

    **25 MHz feasibility for the test chip (design decision, 2026-08-28).**
    Held to be feasible on this argument:
    - At `nom_tt_025C_3v30` (25 C, 3.3 V, typical process) the whole chip
      MEETS at 25 MHz with +9.48 ns slack -- Grouper HCLK paths are
      nowhere near the worst path there.
    - The only failing corner, `ss_125C_3v00`, stacks two pessimisms the
      test-chip bench will not see: **125 C** temperature derating and a
      **3.0 V undervolt of cells designed for 5 V** (`gf180mcu_fd_sc_mcu7t5v0`
      -- see AGENTS.md; this is the same corner that fails at 16 MHz too).
    - The intended bench operating point is **~25 C and a 3.5 V rail**
      (0.2 V over nominal, 0.5 V over the SS-corner voltage), i.e. cooler
      **and** higher-voltage than `ss_125C_3v00` on both axes.
    - Item 18 already showed the direction and rough magnitude: a voltage
      bump alone (the `ss_125C_4v50` proxy) flipped the SS setup violators
      from -14.3 ns / -5.8 ns to +2 ns / +19 ns MET.

    **Caveat -- not a measured result.** There is no `ss_025C_3v50` Liberty
    corner (the PDK `.lib` set is fixed at tt_025C_3v30 / ss_125C_3v00 /
    ff_n40C_3v60; OpenSTA does not interpolate between corners -- item 18).
    The feasibility call is an engineering argument from the nominal-corner
    margin plus the temperature/voltage character of the SS failure, not a
    signed-off STA number. To quantify it, run a proxy STA (item 18 method:
    reuse the routed `.odb`, swap only the std-cell Liberty) at the closest
    available lower-temperature / higher-voltage corner, or have the corner
    characterised.

    Also confirmed by this run: the rewritten `io_placement_landscape.cfg`
    and the Grouper `inout` pads **route clean**, including the `#N` Grouper
    nets crossing the SRAM row on Metal4/Metal5 (macro OBS blocks M1-M3
    only) -- no antenna/DRC fallout in that corridor. The SRAM row stays at
    y=1695.67; the "move it down" option (Open Item #5) is not needed.

    **Full HCLK sweep (2026-08-28), all three runs DRC 0 / LVS 0 /
    unmapped 0 / hold clean on every corner:**

    | HCLK | Job | SS setup WNS | SS worst-path domain | SS setup TNS | nom_tt WS | min_ff WS |
    |---|---|---|---|---|---|---|
    | 16 MHz | 5132 | **-13.56 ns** | IQ_CLK32 (Trouper decimator) | -2278 ns | +9.79 ns | +19.25 ns |
    | 25 MHz | 5131 | **-15.19 ns** | HCLK16 (Grouper CPU -> SRAM `GWEN`) | -4362 ns | +9.48 ns | +18.94 ns |
    | 32 MHz | 5133 | **-16.33 ns** | HCLK16 (Grouper CPU-domain) | -7797 ns | +8.06 ns | +17.98 ns |

    Reference job 5069 (16 MHz, Trouper-only pinout, no Grouper pads): SS
    setup WNS -14.32 ns.

    Reading:
    - **The combined pinout + Grouper pads are timing-neutral.** 5132 vs
      5069 at 16 MHz: -13.56 vs -14.32 ns SS WNS -- the 0.76 ns is
      placement-seed noise, not a real improvement or regression. Exposing
      Grouper's padframe and rearranging the pins did not cost timing.
    - **All three HCLK points MEET at nom_tt and min_ff** with healthy
      margin (nom worst slack +9.8 -> +8.1 ns as HCLK tightens 16 -> 32 MHz;
      min_ff ~+18-19 ns throughout). At the typical corner Grouper runs
      fine at 32 MHz.
    - **The SS bottleneck crosses over from Trouper to Grouper between 16
      and 25 MHz.** At 16 MHz the SS WNS path is Trouper's IQ_CLK32
      decimator cone (Grouper not the limiter); at 25 and 32 MHz it is
      Grouper's CPU -> SRAM write/chip-enable decode cone (`ram_sel_r` and
      neighbours). SS TNS grows fast with HCLK (-2.3k -> -4.4k -> -7.8k ns)
      as more HCLK16 paths pile into violation.
    - **25 MHz is the defensible test-chip target:** timing-neutral pinout,
      +9.5 ns nom margin, SS failure explained by 125 C / 3.0 V pessimism
      (see the feasibility argument above). 32 MHz still MEETS at nom
      (+8.1 ns) but with less headroom and a much larger SS TNS -- "works
      at nominal, tight" rather than comfortable.
