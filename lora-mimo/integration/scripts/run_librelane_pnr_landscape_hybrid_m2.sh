#!/bin/bash
# Full P&R for the original placement using the validated hybrid PDN.
set -euo pipefail
export PDN_LEAN_M2_HYBRID=1
export PNR_TRIAL_TAG=hybrid-m2-original
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
test -n "$runner"
exec bash "$runner"
