#!/bin/bash
# LibreLane synthesis-only check for chip_top (Open Item #1) -- see
# integration/pd/synth_only_chip_top.yaml's header for why this goes through
# LibreLane/slang rather than plain yosys.
set -euo pipefail
cd /foss/designs/integration

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD

# /foss/designs is read-only -- LibreLane's default runs/<tag> dir (which it
# would otherwise create next to the config file) fails there. --force-run-dir
# redirects output to $RUN_DIR, but the target must already exist (LibreLane
# won't mkdir -p it for us). See sge-job skill, "/foss/designs is read-only".
OUT=${RUN_DIR:-/foss/runs}/chip_top_synth
mkdir -p "$OUT"

librelane pd/synth_only_chip_top.yaml --to Yosys.Synthesis \
    --pdk "$PDK" --pdk-root "$PDK_ROOT" --manual-pdk \
    --force-run-dir "$OUT"

echo "chip_top: LibreLane synth done, see $OUT"
