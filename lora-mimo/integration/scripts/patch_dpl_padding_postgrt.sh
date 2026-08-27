#!/bin/bash
# Patches LibreLane's installed repair_design_postgrt.tcl to fix a real
# ordering gap: DPL_CELL_PADDING is only applied inside common/dpl.tcl,
# which repair_design_postgrt.tcl sources in its "Re-DPL and GRT" section --
# AFTER its own `repair_design` call. But `repair_design` does its own
# internal incremental legalization (that's what's emitting DPL-0034/0035/
# 0036 on failure, confirmed against jobs 5040/5041/5042: the error appears
# immediately after repair_design's own iteration-progress table, and the
# script never reaches the later `log_cmd detailed_placement` call in
# dpl.tcl before erroring out) with WHATEVER padding is already set in this
# fresh OpenROAD session -- which is none, since dpl_cell_pad.tcl hasn't
# been sourced yet. So DPL_CELL_PADDING has zero effect on the exact
# legalization pass that's failing, regardless of its value (confirmed: job
# 5042 set DPL_CELL_PADDING=1 and failed byte-identically to jobs 5040/5041,
# which had it at 0 -- same instance _71880_, same iteration 13000, same
# wirelength).
#
# Fix: source common/dpl_cell_pad.tcl (pure `set_placement_padding` calls,
# no side effects beyond that) right before the "# Repair Design" section,
# so padding is live for `repair_design`'s own internal legalization too.
#
# Separately: common/dpl_cell_pad.tcl computes `cell_pad_side = $DPL_CELL_PADDING
# / 2` using Tcl integer division, so DPL_CELL_PADDING=1 truncates to 0
# effective padding per side either way -- config_landscape_2235.yaml must
# use DPL_CELL_PADDING=2 (or higher) for this patch to do anything.
#
# Shares the same writable-copy-of-librelane mechanism as patch_irdrop_tcl.sh
# (both patch scripts operate on the same $RUN_DIR/patched-librelane copy;
# whichever sources first creates it, the other reuses it) -- MUST be sourced
# (not executed as a subshell) so the exported PYTHONPATH reaches the caller:
#   source patch_dpl_padding_postgrt.sh
#
# Idempotent: skips the patch if the marker is already present.
set -euo pipefail

_orig_pkg_dir=$(python3 -c "import librelane, os; print(os.path.dirname(librelane.__file__))")
_writable_root="${RUN_DIR:-/foss/runs}/patched-librelane"
_patched_pkg_dir="$_writable_root/librelane"
_repair_tcl="$_patched_pkg_dir/scripts/openroad/repair_design_postgrt.tcl"

if [ ! -d "$_patched_pkg_dir" ]; then
    mkdir -p "$_writable_root"
    cp -r "$_orig_pkg_dir" "$_patched_pkg_dir"
fi

if ! grep -q "DPL_PADDING_ORDERING_PATCH" "$_repair_tcl" 2>/dev/null; then

    python3 - "$_repair_tcl" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

marker = "# Repair Design\n"
if marker not in content:
    print(f"ERROR: expected marker not found in {path} -- "
          "repair_design_postgrt.tcl may have changed upstream, patch needs "
          "updating", file=sys.stderr)
    sys.exit(1)

patch = (
    "# DPL_PADDING_ORDERING_PATCH: upstream only applies DPL_CELL_PADDING in\n"
    "# the later dpl.tcl source, after repair_design's own internal\n"
    "# legalization has already run (and can fail, DPL-0036) -- patched\n"
    "# locally, see patch_dpl_padding_postgrt.sh.\n"
    "source $::env(SCRIPTS_DIR)/openroad/common/dpl_cell_pad.tcl\n\n"
    + marker
)
content = content.replace(marker, patch, 1)

with open(path, "w") as f:
    f.write(content)

print(f"patch_dpl_padding_postgrt.sh: patched {path}")
PYEOF
else
    echo "patch_dpl_padding_postgrt.sh: $_repair_tcl already patched, skipping"
fi

export PYTHONPATH="$_writable_root${PYTHONPATH:+:$PYTHONPATH}"
echo "patch_dpl_padding_postgrt.sh: PYTHONPATH now shadows librelane with $_patched_pkg_dir"
