#!/bin/bash
# Full LibreLane P&R for the combined Grouper/Trouper landscape floorplan.
# Submit through homelab-sge with --project lora-mimo so /foss/designs is the
# project root and $RUN_DIR is writable.
set -euo pipefail

if [ -f /foss/designs/integration/pd/config_landscape_2235.yaml ]; then
    cd /foss/designs/integration
else
    config_path=$(find /foss/designs -path '*/integration/pd/config_landscape_2235.yaml' -print -quit)
    if [ -z "$config_path" ]; then
        echo "Could not find integration/pd/config_landscape_2235.yaml below /foss/designs" >&2
        exit 1
    fi
    cd "$(dirname "$(dirname "$config_path")")"
fi

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
# LibreLane discovers design-local ``librelane_plugin_*`` packages through
# Python's module path.  Snapshot jobs execute the runner from /job, so the
# current working directory alone is not a reliable import root.
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"

# Keep PG out of the two non-placeable baseline die regions.  A's right edge
# is aligned to OpenROAD's legal PDN grid.
export PDN_KEEPOUT_REGION_A="0 0 1117.22 1117.5"
export PDN_KEEPOUT_REGION_B="1676.25 1117.78 2235 2235"

TRIAL_TAG="${PNR_TRIAL_TAG:-baseline}"
OUT="${RUN_DIR:-/foss/runs}/chip_top_landscape_pnr_${TRIAL_TAG}"
mkdir -p "$OUT"

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

patch_script=$(find /foss/designs -path '*/integration/scripts/patch_irdrop_tcl.sh' -print -quit)
if [ -n "$patch_script" ]; then
    source "$patch_script"
fi

librelane pd/config_landscape_2235.yaml \
    --pdk "$PDK" --pdk-root "$PDK_ROOT" --manual-pdk \
    --force-run-dir "$OUT" "${override_args[@]}"

echo "chip_top: full landscape P&R complete (${TRIAL_TAG}); results: $OUT"
