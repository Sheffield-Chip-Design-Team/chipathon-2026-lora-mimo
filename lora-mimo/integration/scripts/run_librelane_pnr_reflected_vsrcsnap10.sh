#!/bin/bash
# Reflected floorplan with normal GRT adjustment and snapped PDN sources.
set -euo pipefail
export PNR_TRIAL_TAG=reflected-vsrcsnap-10c
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000
export PDN_M3_RUNG_PITCH=598.08
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
test -n "$runner"
exec bash "$runner"
