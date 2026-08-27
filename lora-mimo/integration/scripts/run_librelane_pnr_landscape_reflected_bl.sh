#!/bin/bash
# Full P&R: reflected-obstruction experiment.
# The YAML places the rotated SRAM bank along the west edge, directly above
# the shallow BL obstruction; the base runner exports matching PG keepouts.
set -euo pipefail

export PNR_TRIAL_TAG=reflected-bl-leanm3-y1000
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000
export PDN_M3_RUNG_PITCH=598.08

runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
if [ -z "$runner" ]; then
    echo "Could not find landscape P&R runner below /foss/designs" >&2
    exit 1
fi
exec bash "$runner"
