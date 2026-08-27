#!/bin/bash
# Unfenced landscape trial: large vertical detailed-placement relaxation.
set -euo pipefail

export PNR_TRIAL_TAG=y1000
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
if [ -z "$runner" ]; then
    echo "Could not find landscape P&R runner below /foss/designs" >&2
    exit 1
fi
exec bash "$runner"
