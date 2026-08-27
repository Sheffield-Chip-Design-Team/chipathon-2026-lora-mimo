#!/bin/bash
# Persistent-NFS SGE wrapper for the Grouper-NW 4x1 SRAM PDN trial.
set -euo pipefail

cd /foss/designs/timothyn-dev/lora-mimo/integration
exec ./scripts/run_librelane_pdn_keepout_check.sh
