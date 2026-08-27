#!/bin/bash
# Baseline P&R: DELAY 0, CTS NDR disabled, mixed jumper/diode antenna repair.
set -euo pipefail

export PNR_TRIAL_TAG=delay0-ndrnone-antdiodes-leanm3-y1000
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000
export PDN_M3_RUNG_PITCH=598.08

runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
if [ -z "$runner" ]; then
    echo "Could not find landscape P&R runner below /foss/designs" >&2
    exit 1
fi
exec bash "$runner"
