#!/bin/bash
# Hybrid PDN with reduced GPL padding and relaxed fanout for DPL repair.
set -euo pipefail
export PDN_LEAN_M2_HYBRID=1
export GPL_CELL_PADDING_OVERRIDE=1
export MAX_FANOUT_CONSTRAINT_OVERRIDE=32
export PNR_TRIAL_TAG=hybrid-m2-pad1-fanout32
runner=$(find /foss/designs -path '*/integration/scripts/run_librelane_pnr_landscape.sh' -print -quit)
test -n "$runner"
exec bash "$runner"
