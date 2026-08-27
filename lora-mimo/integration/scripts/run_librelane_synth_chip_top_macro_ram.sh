#!/bin/bash
# Synth-only check of config_landscape_2235.yaml (the real floorplan config,
# MACRO_RAM enabled) -- confirms the real sram1024x8m8wm1 macro path resolves
# now that integration/ip/grouper/ip/gf180mcu_ocd_ip_sram is initialized
# (2026-08-22). --to Yosys.Synthesis stops before any floorplan/PDN steps, so
# this doesn't attempt the real obstruction/pin-order/MACROS placement flow --
# just confirms synthesis with the real macro (not the earlier synth-only
# config's behavioural-array stand-in).
set -euo pipefail
cd /foss/designs/integration

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD

OUT=${RUN_DIR:-/foss/runs}/chip_top_macro_ram_synth
mkdir -p "$OUT"

librelane pd/config_landscape_2235.yaml --to Yosys.Synthesis \
    --pdk "$PDK" --pdk-root "$PDK_ROOT" --manual-pdk \
    --force-run-dir "$OUT"

echo "chip_top (MACRO_RAM): LibreLane synth done, see $OUT"
