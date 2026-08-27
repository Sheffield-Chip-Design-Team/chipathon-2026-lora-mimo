# vsrc/*.loc derivation history

OpenROAD's PSM vsrc-file reader (`IRSolver::generateSourceNodesFromSourceFile`
in `ir_solver.cpp`) has **no comment or blank-line support at all** -- every
line is naively parsed as 4-column CSV via `std::stod`, so a `#`-prefixed
line throws and aborts the whole read. The `.loc` files next to this README
must stay pure data (one `x_um,y_um,octagonal_source_edge_um,voltage_V` line
per source, nothing else). This file carries the derivation notes that used
to live in those files' headers, discovered the hard way (job 4828) after a
comment line broke `analyze_power_grid` with a cryptic `stod` exception --
this was previously masked by the separate PSM-0079 bug below, which always
fired first, before the source file was ever actually read.

## VDD (`vdd_estimated_project_downbonds.loc`)

The core-only integration has no pad instances, so a project downbond is
modelled as an explicit voltage source. History of failed attempts, all
initially surfacing as `OpenROAD.IRDropReport` `[ERROR PSM-0079] Cannot
determine the supply voltage for VDD`:

1. `(2235,965.11)` -- original 22-pad-site estimate, didn't land on any
   routed PDN metal at all (job 4773).
2. `(2235,778.36)` -- "snapped" to a real Metal5 VDD stripe, but computed
   with a wrong DEF-units divisor (`/1000` instead of the design's real
   `UNITS DISTANCE MICRONS 2000`), exactly doubling the real y (job 4799).
3. `(2235,389.18)` -- the real y after fixing the units bug, genuinely on
   the Metal5 stripe `NEW Metal5 10800 + SHAPE STRIPE ( 2235360 778360 )
   ( 4470000 778360 )` (raw DEF units, 2000/um) -- STILL failed (jobs
   4802/4803). Root cause: `analyze_power_grid -vsrc` needs a point that is
   actually via-connected down through the stack, not merely any point
   along a Metal5 stripe; x=2235 is that stripe's bare end-of-wire tip at
   the die edge, with no via there.
4. `(2180.06,388.25)` -- re-derived from a real Metal4-Metal5 `via4_5`
   location instead of a bare wire coordinate (grepped job 4799's and job
   4803's own routed DEFs, SPECIALNETS VDD; the same via position exists in
   both the leanm3 and reversed local-sram-bridge PDN topologies). This
   coordinate is geometrically real and via-connected, but jobs
   4809/4810/4827 kept hitting PSM-0079 anyway.

**The real PSM-0079 root cause (found 2026-08-23):** none of the above was
ever the problem. LibreLane's `irdrop.tcl`, when `VSRC_LOC_FILES` is set
(our case), calls `analyze_power_grid -vsrc $vsrc_file` directly and never
calls `set_pdnsim_net_voltage` -- so OpenROAD's operating-voltage
resolution chain (solved-analysis -> user-set voltage -> SDC `set_voltage`
-> PVT/corner voltage) always comes up empty, regardless of vsrc file
content. The `LIB_VOLTAGE`-fallback branch (no `VSRC_LOC_FILES`) already
calls `set_pdnsim_net_voltage` correctly; `VSRC_LOC_FILES` was just missing
the equivalent call. Fixed locally via
`integration/scripts/patch_irdrop_tcl.sh`, which copies LibreLane's
installed package to a writable run-dir location (the system install is
read-only for the container's non-root user) and patches the
`VSRC_LOC_FILES` branch to add the missing call, keyed on net name.

Current value: x=2180.06, y=388.25 (attempt 4 above) -- geometrically real
and via-connected, confirmed end-to-end by jobs 4833/4834 (both bugs fixed,
full IRDropReport ran successfully -- see the percentage-drop numbers in
`planning/grouper-trouper-landscape-floorplan-2026-08.md`).

**Second VDD source added 2026-08-24: Grouper only ever had one modelled VDD
downbond (Trouper's), while VSS always had two (Grouper west + Trouper
east) -- an unintentional asymmetry, not a real design difference (both
dies need their own supply).** Confirmed from job 4834's own per-node
`net-VDD.csv`/`net-VSS.csv` (56-openroad-irdropreport/) that this asymmetry
was measurably driving the result: the worst VDD nodes (~3.200 V, vs. 3.259 V
average within 355 um of the source) sit at the far diagonal corner from the
single VDD source, at (~360, ~2207) -- roughly 2.8 mm away -- and binning
every one of the 143,611 VDD nodes by straight-line distance from the source
shows a smooth, monotonic voltage gradient with distance (no localized
last-mile chokepoint at any specific cell or pin). That's a mesh-distribution
effect, not a thin-track/pin-access effect, and having only one source point
for the whole 2235x2235 um die is what let it get that bad.

Added x=140.30, y=1466.70 as a second VDD source, mirroring VSS's
Grouper-west source. Derived the same way as the other three points (real
via4_5 -- Metal4-Metal5 via -- location, not a bare wire coordinate): grepped
job 4834's own routed DEF (`21-openroad-generatepdn/chip_top.def`,
`SPECIALNETS VDD`) for the via4_5 point nearest the Grouper-west VSS source
coordinate. Since PDN mesh geometry comes from the fixed `PDN_V*/H*` config
values (not from placement), the same coordinate independently reproduced
from a separate local `pdn_keepout_check` trial's own routed DEF -- good
cross-check that this is a real, stable grid point, not an artifact of one
specific run. **Not yet confirmed against a real IRDropReport re-run with
this second source in place** -- expect the far-corner worst-case number to
improve once it is (see Open Item #9/#47 tracking in the planning doc, and
the pending test PnR run for the AHB pipeline fix, which uses this file).

## VSS (`vss_estimated_project_downbonds.loc`)

VSS was never actually reached in any run before job 4827/4828, since
`analyze_power_grid` processes VDD first and `irdrop.tcl` aborts the whole
step on its first error. Preemptively re-derived the same way as VDD's
attempt 4 (real `via4_5` locations from job 4799's routed DEF, nearest each
original edge target, keeping each source's Grouper/Trouper side):

- Grouper: west, x=82.86, y=1288.25 (was x=0, y=1289.18 -- the stripe's
  bare edge tip, same issue as VDD's attempt 3)
- Trouper: east, x=2120.14, y=928.25 (was x=2235, y=929.18 -- same issue)

## Still open

All of the above must be replaced with real padframe data before physical
sign-off. See `planning/grouper-trouper-landscape-floorplan-2026-08.md`
Open Item #9.
