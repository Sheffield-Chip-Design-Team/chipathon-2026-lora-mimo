#!/bin/bash
# Full P&R for the reversed-orientation (S->N) SRAM layout with the
# localized SRAM PDN bridge, relieved detailed-placement Y displacement.
set -euo pipefail
export PNR_TRIAL_TAG=reversed-local-sram-bridge-y1000
export PL_MAX_DISPLACEMENT_Y_OVERRIDE=1000
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape_reversed.sh' -print -quit)
test -n "$runner"
exec bash "$runner"
