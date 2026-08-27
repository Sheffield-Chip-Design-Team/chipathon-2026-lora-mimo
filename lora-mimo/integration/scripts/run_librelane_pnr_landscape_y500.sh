#!/bin/bash
# Unfenced landscape trial: moderate vertical detailed-placement relaxation.
set -euo pipefail

export PNR_TRIAL_TAG=y500
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=500
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
if [ -z "$runner" ]; then
    echo "Could not find landscape P&R runner below /foss/designs" >&2
    exit 1
fi
exec bash "$runner"
