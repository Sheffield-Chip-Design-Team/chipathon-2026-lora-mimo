#!/bin/bash
# Generate the placed-pin DEF for the landscape IO audit, stopping before GPL.
set -euo pipefail

config_path=$(find /foss/designs -path '*/integration/pd/config_landscape_2235.yaml' -print -quit)
if [ -z "$config_path" ]; then
    echo "Could not find integration/pd/config_landscape_2235.yaml below /foss/designs" >&2
    exit 1
fi
cd "$(dirname "$(dirname "$config_path")")"

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
export STD_CELL_LIBRARY=gf180mcu_fd_sc_mcu7t5v0
export PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}"
export PDN_KEEPOUT_REGION_A="0 0 1117.22 1117.5"
export PDN_KEEPOUT_REGION_B="1676.25 1117.78 2235 2235"

OUT="${RUN_DIR:-/foss/runs}/chip_top_landscape_io_audit"
mkdir -p "$OUT"
librelane pd/config_landscape_2235.yaml \
    --pdk "$PDK" --pdk-root "$PDK_ROOT" --manual-pdk \
    --force-run-dir "$OUT" --to Odb.CustomIOPlacement
