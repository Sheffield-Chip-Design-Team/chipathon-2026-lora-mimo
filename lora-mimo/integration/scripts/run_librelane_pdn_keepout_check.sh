#!/bin/bash
# Real PDN-generation check WITH the die-level obstruction keepout active --
# same as run_librelane_pdn_check.sh, but exports PDN_KEEPOUT_REGION_A/_B
# (Obstruction A/B from config_landscape_2235.yaml's FP_OBSTRUCTIONS) so
# pdn_cfg.tcl's create_obstruction guard actually fires. Confirmed 2026-08-22
# that PDN_KEEPOUT_REGION as a config key is a silent no-op -- it must be a
# real shell env var, which is what this script is for.
set -euo pipefail

# Snapshot submissions preserve the design-root directory beneath
# /foss/designs, while older direct-NFS jobs mounted integration/ at its
# root. Resolve the staged configuration instead of assuming either layout.
if [ -f /foss/designs/integration/pd/config_landscape_2235.yaml ]; then
    cd /foss/designs/integration
else
    config_path=$(find /foss/designs -path '*/integration/pd/config_landscape_2235.yaml' -print -quit)
    if [ -z "$config_path" ]; then
        echo "chip_top: cannot locate staged integration/pd/config_landscape_2235.yaml" >&2
        exit 1
    fi
    cd "$(dirname "$(dirname "$config_path")")"
fi

export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD

# Obstruction A: [0, 0, 1117.5, 1117.5] -- bottom-left quadrant, full square.
# Obstruction B: [1676.25, 1117.5, 2235, 2235] -- top-right, right half only.
# See planning/grouper-trouper-landscape-floorplan-2026-08.md's Geometry table.
#
# ITERATION 1 (2026-08-22): job 4681 (exact FP_OBSTRUCTIONS boundary) failed
# with PDN-0179 "Unable to repair all channels" -- a ~3um-wide leftover sliver
# at Obstruction A's right edge (x=1117.78-1120.77) was too narrow for
# OpenROAD to legally place a repair stripe in.
#
# ITERATION 2 (2026-08-22, REJECTED): tried padding PDN_KEEPOUT_REGION_A's
# right edge to x=1123 (a few um past the FP_OBSTRUCTIONS boundary) on the
# theory that PDN keepout is independent of cell placement so widening it is
# "safe". WRONG -- job 4682 showed this pushed the keepout into territory
# where real cells ARE placed (FP_OBSTRUCTIONS only blocks below x=1117.5),
# so telling PDN to avoid x=1117.5-1123 left those real cells with zero power
# rail access: ~2460 VDD + ~2454 VSS "Unconnected shape/instance" violations
# (PSM-0069/PSM-0038/PSM-0039) -- categorically worse than the single
# contained channel-repair failure from iteration 1. Reverted.
#
# The exact geometric boundary (1117.5) falls between OpenROAD's legal PDN
# coordinates.  It creates a 2.99um Metal3 channel (1117.78--1120.77) which
# pdngen cannot repair.  Inset the *PG-only* keepout by one half-track to
# 1117.22: this retains the placement obstruction at 1117.5, leaves no
# standard-cell origin in the 0.28um inset (the first one is 1117.76), and
# removes the unrepairable channel.  This alignment was verified by the
# OpenROAD connectivity checker (VDD/VSS both fully connected).
#
# Callers may still override either region for a focused experiment.
: "${PDN_KEEPOUT_REGION_A:=0 0 1117.22 1117.5}"
: "${PDN_KEEPOUT_REGION_B:=1676.25 1117.78 2235 2235}"
export PDN_KEEPOUT_REGION_A PDN_KEEPOUT_REGION_B

OUT=${RUN_DIR:-/foss/runs}/chip_top_pdn_keepout_check
mkdir -p "$OUT"

librelane pd/config_landscape_2235.yaml --to OpenROAD.GeneratePDN \
    --pdk "$PDK" --pdk-root "$PDK_ROOT" --manual-pdk \
    --force-run-dir "$OUT"

if grep -R -nE "\[(ERROR|WARNING) (PDN-017[89]|PSM-00(38|39|69))\]" "$OUT"; then
    echo "chip_top: PDN check found channel-repair or connectivity diagnostics" >&2
    exit 1
fi

echo "chip_top: PDN generation with keepout reached, see $OUT"
