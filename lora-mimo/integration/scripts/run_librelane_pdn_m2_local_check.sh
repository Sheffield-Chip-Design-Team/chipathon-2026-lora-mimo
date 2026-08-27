#!/bin/bash
# Focused PDN experiment: restrict the intermediate M2 grid to the SRAM band.
set -euo pipefail
export PDN_M2_LOCAL_ONLY=1
export PDN_KEEPOUT_REGION_A="0 0 1117.22 1117.5"
export PDN_KEEPOUT_REGION_B="1676.25 1117.78 2235 2235"
export RUN_DIR="${RUN_DIR:-/foss/runs}/pdn_m2_local_only"
config_path=$(find /foss/designs -path '*/integration/pd/config_landscape_2235.yaml' -print -quit)
test -n "$config_path"
integration_dir=$(dirname "$(dirname "$config_path")")
cd "$integration_dir"
mkdir -p "$RUN_DIR"
librelane pd/config_landscape_2235.yaml \
  --pdk gf180mcuD --pdk-root /foss/pdks --manual-pdk \
  --to OpenROAD.GeneratePDN --force-run-dir "$RUN_DIR"
