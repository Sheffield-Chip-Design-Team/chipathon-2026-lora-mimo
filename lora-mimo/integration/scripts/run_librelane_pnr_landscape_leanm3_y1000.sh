#!/bin/bash
# Landscape P&R trial: halve the die-spanning Metal3 PDN-rung density.
set -euo pipefail

export PNR_TRIAL_TAG=leanm3-y1000
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000
# 299.04 um is the baseline rung pitch; this preserves M3 connectivity while
# halving its die-spanning PDN occupancy.
export PDN_M3_RUNG_PITCH=598.08

runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
if [ -z "$runner" ]; then
    echo "Could not find landscape P&R runner below /foss/designs" >&2
    exit 1
fi
exec bash "$runner"
