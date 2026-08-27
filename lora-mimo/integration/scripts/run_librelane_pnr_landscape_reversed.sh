#!/bin/bash
# Full P&R with SRAM orientations flipped S->N, using the localized SRAM
# PDN bridge. Same reversed-config staging as
# run_librelane_pdn_local_sram_bridge_reversed.sh (fixed ip/ symlink,
# validated clean by job 4800 -- PSM-0040 all VDD/VSS shapes connected),
# but runs the full flow instead of stopping at OpenROAD.GeneratePDN.
set -euo pipefail

export PDN_LOCAL_SRAM_BRIDGE=1
export PDN_KEEPOUT_REGION_A="0 0 1117.22 1117.5"
export PDN_KEEPOUT_REGION_B="1676.25 1117.78 2235 2235"

TRIAL_TAG="${PNR_TRIAL_TAG:-reversed-local-sram-bridge}"
export RUN_DIR="${RUN_DIR:-/foss/runs}/chip_top_landscape_pnr_${TRIAL_TAG}"

config_path=$(find /foss/designs -path '*/integration/pd/config_landscape_2235.yaml' -print -quit)
test -n "$config_path"
integration_dir=$(dirname "$(dirname "$config_path")")
cd "$integration_dir"
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$RUN_DIR"
config_root="$RUN_DIR/reversed-config-root"
mkdir -p "$config_root/pd"
ln -sfn "$integration_dir/ip" "$config_root/ip"
ln -sfn "$integration_dir/hw" "$config_root/hw"
ln -sfn "$integration_dir/fw" "$config_root/fw"
# See run_librelane_pdn_local_sram_bridge_reversed.sh for why this symlink
# targets lora-mimo/ip (one level above integration_dir), not
# integration_dir/ip -- config_landscape_2235.yaml's picorv32.v entry uses
# a two-level-up dir:: path that resolves to a *different* ip/ directory
# than the one-level-up grouper/trouper submodule paths.
repo_root=$(dirname "$integration_dir")
ln -sfn "$repo_root/ip" "$RUN_DIR/ip"
ln -sfn "$integration_dir/rtl" "$config_root/rtl"
ln -sfn "$integration_dir/pd/pdn_cfg.tcl" "$config_root/pd/pdn_cfg.tcl"
ln -sfn "$integration_dir/pd/chip_top_dual_clock.sdc" "$config_root/pd/chip_top_dual_clock.sdc"
ln -sfn "$integration_dir/pd/io_placement_landscape.cfg" "$config_root/pd/io_placement_landscape.cfg"
ln -sfn "$integration_dir/pd/vsrc" "$config_root/pd/vsrc"
reversed_config="$config_root/pd/config_landscape_2235_reversed.yaml"
cp "$config_path" "$reversed_config"
sed -i '/^[[:space:]]*orientation: S[[:space:]]*$/s/orientation: S/orientation: N/' "$reversed_config"

override_args=()
if [[ -n "${PL_MAX_DISPLACEMENT_Y_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "PL_MAX_DISPLACEMENT_Y=${PL_MAX_DISPLACEMENT_Y_OVERRIDE}")
fi
if [[ -n "${MAX_FANOUT_CONSTRAINT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "MAX_FANOUT_CONSTRAINT=${MAX_FANOUT_CONSTRAINT_OVERRIDE}")
fi
if [[ -n "${GPL_CELL_PADDING_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "GPL_CELL_PADDING=${GPL_CELL_PADDING_OVERRIDE}")
fi
# Detailed-placement legalization padding -- see config_landscape_2235.yaml's
# own DPL_CELL_PADDING comment for the DPL-0036/_71880_ failure history this
# hook exists to work around. Config now defaults this to 1 (trouper's own
# config_current_signoff.json precedent); this override exists for sweeping
# a different value without editing the checked-in default.
if [[ -n "${DPL_CELL_PADDING_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "DPL_CELL_PADDING=${DPL_CELL_PADDING_OVERRIDE}")
fi
# _71880_'s DPL-0036 root cause (see planning doc item 14/16): the row at
# y~2097 (and every row spanning the SRAM macro column's height) has an
# 18-site/~10 um sliver between the last macro's FP_MACRO_HORIZONTAL_HALO
# and Obstruction B's edge -- a structural capacity trap, not a density/
# padding gap.
#
# Strategy A (swallow the sliver by extending Obstruction B) is NOT an
# --override-config hook -- tried that first (job 5051) and LibreLane's CLI
# override parser rejected it: `FP_OBSTRUCTIONS` is a
# Tuple[Tuple[Decimal,4],...], and passing a JSON-array string
# ('[[0,0,...],[1665,...]]') errored with "FP_OBSTRUCTIONS[0] ... (1/4)
# tuple entries provided" -- the override grammar doesn't accept a nested-
# list value this way (whatever it does expect, this wasn't it, and wasn't
# worth reverse-engineering for a one-off trial). Strategy A is instead a
# direct edit to FP_OBSTRUCTIONS in config_landscape_2235.yaml itself -- see
# that key's own comment there.
#
# Strategy B (softer alternative: widen, don't eliminate, the same channel)
# IS a normal scalar override and works fine below.
if [[ -n "${FP_MACRO_HORIZONTAL_HALO_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "FP_MACRO_HORIZONTAL_HALO=${FP_MACRO_HORIZONTAL_HALO_OVERRIDE}")
fi
if [[ -n "${GRT_RESIZER_SETUP_MAX_BUFFER_PCT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "GRT_RESIZER_SETUP_MAX_BUFFER_PCT=${GRT_RESIZER_SETUP_MAX_BUFFER_PCT_OVERRIDE}")
fi
# NOT the same knob as GRT_RESIZER_SETUP_MAX_BUFFER_PCT above -- that one
# gates a GRT-based design-repair step this flow doesn't even run (confirmed
# 2026-08-24: no *-repairdesign*grt* stage exists in any completed run dir).
# The step that actually matters for post-CTS setup-violation buffering is
# 37-openroad-resizertimingpostcts (rsz_timing_postcts.tcl), which reads
# PL_RESIZER_SETUP_MAX_BUFFER_PCT / PL_RESIZER_HOLD_MAX_BUFFER_PCT instead
# (confirmed against librelane/steps/openroad.py). Both default to 50; job
# 4878 proved the GRT_* override is a silent no-op for this flow.
if [[ -n "${PL_RESIZER_SETUP_MAX_BUFFER_PCT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "PL_RESIZER_SETUP_MAX_BUFFER_PCT=${PL_RESIZER_SETUP_MAX_BUFFER_PCT_OVERRIDE}")
fi
if [[ -n "${PL_RESIZER_HOLD_MAX_BUFFER_PCT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "PL_RESIZER_HOLD_MAX_BUFFER_PCT=${PL_RESIZER_HOLD_MAX_BUFFER_PCT_OVERRIDE}")
fi
# repair_timing's -repair_tns budgets how much of the total negative slack to
# spend effort closing (0-100, LibreLane leaves it unset -> rsz_timing_postcts.tcl's
# append_if_exists_argument only appends -repair_tns when this is explicitly
# set) -- see MAX_FANOUT_CONSTRAINT no-op history below for why this is being
# tried in its place.
if [[ -n "${PL_RESIZER_SETUP_REPAIR_TNS_PCT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "PL_RESIZER_SETUP_REPAIR_TNS_PCT=${PL_RESIZER_SETUP_REPAIR_TNS_PCT_OVERRIDE}")
fi
# OpenROAD.RepairDesignPostGRT (repair using post-global-routing delay
# estimates, closer to real routed parasitics than the post-CTS resizer's
# pre-route Elmore model). Off by default (librelane/flows/classic.py:
# "RUN_POST_GRT_DESIGN_REPAIR", default=False, "experimental and may result
# in hangs and/or extended run times" per LibreLane's own docstring) -- not
# something to leave on without reason. rtl-test/ol_picorv32/config_16mhz.json
# already runs it successfully on the same CPU standalone.
if [[ -n "${RUN_POST_GRT_DESIGN_REPAIR_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "RUN_POST_GRT_DESIGN_REPAIR=${RUN_POST_GRT_DESIGN_REPAIR_OVERRIDE}")
fi
if [[ -n "${GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH=${GRT_DESIGN_REPAIR_MAX_WIRE_LENGTH_OVERRIDE}")
fi
if [[ -n "${GRT_DESIGN_REPAIR_MAX_SLEW_PCT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "GRT_DESIGN_REPAIR_MAX_SLEW_PCT=${GRT_DESIGN_REPAIR_MAX_SLEW_PCT_OVERRIDE}")
fi
if [[ -n "${GRT_DESIGN_REPAIR_MAX_CAP_PCT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "GRT_DESIGN_REPAIR_MAX_CAP_PCT=${GRT_DESIGN_REPAIR_MAX_CAP_PCT_OVERRIDE}")
fi
if [[ -n "${GRT_DESIGN_REPAIR_RUN_GRT_OVERRIDE:-}" ]]; then
    override_args+=(--override-config "GRT_DESIGN_REPAIR_RUN_GRT=${GRT_DESIGN_REPAIR_RUN_GRT_OVERRIDE}")
fi

patch_script=$(find /foss/designs -path '*/integration/scripts/patch_irdrop_tcl.sh' -print -quit)
if [ -n "$patch_script" ]; then
    source "$patch_script"
fi

# See patch_dpl_padding_postgrt.sh's own header: DPL_CELL_PADDING is
# otherwise a no-op against repair_design's own internal legalization
# (the DPL-0036/_71880_ failure in jobs 5040/5041/5042) because it's applied
# too late in repair_design_postgrt.tcl. Shares the same writable
# patched-librelane copy as patch_irdrop_tcl.sh above.
dpl_patch_script=$(find /foss/designs -path '*/integration/scripts/patch_dpl_padding_postgrt.sh' -print -quit)
if [ -n "$dpl_patch_script" ]; then
    source "$dpl_patch_script"
fi

# MAX_FANOUT_CONSTRAINT (set_max_fanout in base.sdc, currently 10) turned out
# to be a dead end for fixing the -28.67ns HCLK16 violator
# (u_cpu.latched_store, 39 fanout) found 2026-08-26: this OpenROAD build
# (26Q2-254-g61932e897)'s `repair_design` genuinely has no -max_fanout flag
# at all (confirmed via `help repair_design`: only -max_wire_length/
# -max_utilization/-slew_margin/-cap_margin/-buffer_gain/-pre_placement/
# -match_cell_footprint/-verbose; a patch script that tried to add one
# crashed with STA-0562 "not a known keyword or flag", job 5056). No
# tool-level fanout-specific repair command exists in this build to swap in
# instead -- fanout mitigation on this path now goes through
# PL_RESIZER_SETUP_MAX_BUFFER_PCT / PL_RESIZER_SETUP_REPAIR_TNS_PCT above
# (legitimate, already-wired repair_timing knobs; increases how much of the
# worst setup path repair_timing is allowed to buffer/resize), not a direct
# fanout-count repair -- deliberately not an RTL-level register-duplication
# fix, per 2026-08-26 direction.

librelane "$reversed_config" \
  --pdk gf180mcuD --pdk-root /foss/pdks --manual-pdk \
  --force-run-dir "$RUN_DIR" "${override_args[@]}"

echo "chip_top: full reversed-orientation landscape P&R complete (${TRIAL_TAG}); results: $RUN_DIR"
