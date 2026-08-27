#!/bin/bash
# Baseline P&R with snapped PDN voltage sources, 10-core trial.
set -euo pipefail
export PNR_TRIAL_TAG=vsrcsnap-antdiodes-10c
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000
export PDN_M3_RUNG_PITCH=598.08
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
test -n "$runner"
exec bash "$runner"
