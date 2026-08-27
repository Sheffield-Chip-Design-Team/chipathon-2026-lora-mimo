#!/bin/bash
# Full P&R for the original landscape placement using the localized SRAM PDN.
set -euo pipefail
export PDN_LOCAL_SRAM_BRIDGE=1
export PNR_TRIAL_TAG=local-sram-bridge-original
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
test -n "$runner"
exec bash "$runner"
