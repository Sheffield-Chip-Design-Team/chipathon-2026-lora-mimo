#!/bin/bash
# Portrait SRAM trial: y=500 legalization limit plus lower repair-buffer pressure.
set -euo pipefail

export PNR_TRIAL_TAG=y500_fanout32
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=500
export MAX_FANOUT_CONSTRAINT_OVERRIDE=32

cd /foss/designs/integration
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
export PDN_KEEPOUT_REGION_A="0 0 1117.22 1117.5"
export PDN_KEEPOUT_REGION_B="1676.25 1117.78 2235 2235"

OUT="${RUN_DIR:-/foss/runs}/chip_top_landscape_pnr_${PNR_TRIAL_TAG}"
mkdir -p "$OUT"
exec librelane pd/config_landscape_2235.yaml \
    --pdk "$PDK" --pdk-root "$PDK_ROOT" --manual-pdk \
    --force-run-dir "$OUT" \
    --override-config "PL_MAX_DISPLACEMENT_Y=${PL_MAX_DISPLACEMENT_Y_OVERRIDE}" \
    --override-config "MAX_FANOUT_CONSTRAINT=${MAX_FANOUT_CONSTRAINT_OVERRIDE}"
