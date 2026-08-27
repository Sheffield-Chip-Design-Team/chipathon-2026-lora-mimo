#!/bin/bash
# Minimal SGE smoke test for the project-scoped LibreLane environment.
set -euo pipefail

echo "job_id=${JOB_ID:-unset}"
echo "hostname=$(hostname)"
echo "run_dir=${RUN_DIR:-unset}"
test -f /foss/designs/integration/pd/config_landscape_2235.yaml
test -f /foss/designs/integration/scripts/run_librelane_pnr_landscape.sh
mkdir -p "${RUN_DIR:-/foss/runs}/sge_smoke_test"
echo "SGE_SMOKE_TEST_PASS"
