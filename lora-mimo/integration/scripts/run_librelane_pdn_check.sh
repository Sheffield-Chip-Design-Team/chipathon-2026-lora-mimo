#!/bin/bash
# Real PDN-generation check for the landscape SRAM macro placement -- goes
# past synthesis into floorplan + PDN generation (OpenROAD.GeneratePDN),
# using config_landscape_2235.yaml's current (borrowed, unverified for this
# rotated orientation) PDN_V*/H* strap geometry. Point is to get real tool
# feedback (connectivity/DRC-style) instead of hand-deriving the SRAM
# tap-band alignment from raw LEF geometry -- see
# planning/grouper-trouper-landscape-floorplan-2026-08.md Open Item #5.
set -euo pipefail
cd /foss/designs/integration

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD

OUT=${RUN_DIR:-/foss/runs}/chip_top_pdn_check
mkdir -p "$OUT"

librelane pd/config_landscape_2235.yaml --to OpenROAD.GeneratePDN \
    --pdk "$PDK" --pdk-root "$PDK_ROOT" --manual-pdk \
    --force-run-dir "$OUT"

echo "chip_top: PDN generation reached, see $OUT"
