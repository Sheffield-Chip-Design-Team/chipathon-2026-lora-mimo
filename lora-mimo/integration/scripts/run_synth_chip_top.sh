#!/bin/bash
# Trial Yosys synthesis of the combined Grouper<->Trouper chip_top -- run on the
# homelab-sge cluster. See synth_chip_top.ys for what this actually does; this
# wrapper just substitutes the writable output dir ($RUN_DIR is read-only-safe,
# /foss/designs is NOT -- see planning/grouper-trouper-landscape-floorplan-2026-08.md
# Open Item #1 for why) into the .ys template and invokes yosys.
set -euo pipefail
cd /foss/designs/integration

OUT=${RUN_DIR:-/foss/runs}
mkdir -p "$OUT"

sed "s|@@OUT@@|$OUT|g" scripts/synth_chip_top.ys > "$OUT/synth_chip_top.generated.ys"

yosys -s "$OUT/synth_chip_top.generated.ys"

echo "chip_top: synthesis complete, see $OUT/stat_chip_top.txt"
