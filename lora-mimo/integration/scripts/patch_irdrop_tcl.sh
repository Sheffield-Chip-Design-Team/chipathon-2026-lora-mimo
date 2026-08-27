#!/bin/bash
# Patches LibreLane's installed irdrop.tcl to fix a real upstream gap: when
# VSRC_LOC_FILES is set (our case, for realistic downbond-location IR-drop
# modeling instead of the optimistic all-BTerms default), the tcl script
# never calls `set_pdnsim_net_voltage`, so OpenROAD's operating-voltage
# resolution chain (solved-analysis -> user_voltages_ -> SDC -> PVT) always
# comes up empty and OpenROAD.IRDropReport fails with
# [ERROR PSM-0079] Cannot determine the supply voltage for VDD -- regardless
# of what coordinates are in the vsrc file (confirmed against jobs
# 4773/4799/4801/4802/4803/4809/4810, every one of which failed identically
# despite genuinely different, geometry-verified vsrc coordinates).
#
# The LIB_VOLTAGE fallback branch (no VSRC_LOC_FILES) already calls
# set_pdnsim_net_voltage correctly -- this patch just adds the same call to
# the VSRC_LOC_FILES branch, keyed on net name matching this design's
# VDD_NETS/GND_NETS ([VDD]/[VSS]).
#
# The installed package lives under /usr/local/lib/python3.12/dist-packages,
# which is read-only for the container's non-root user (confirmed job 4823:
# PermissionError). So this copies the whole (small, ~3.5M) librelane
# package to a writable dir under $RUN_DIR, patches the copy, and exports a
# PYTHONPATH that shadows the system install with it. MUST be sourced (not
# executed as a subshell) so the exported PYTHONPATH reaches the caller:
#   source patch_irdrop_tcl.sh
#
# Idempotent: skips the copy+patch if already done for this $RUN_DIR.
set -euo pipefail

_orig_pkg_dir=$(python3 -c "import librelane, os; print(os.path.dirname(librelane.__file__))")
_writable_root="${RUN_DIR:-/foss/runs}/patched-librelane"
_patched_pkg_dir="$_writable_root/librelane"
_irdrop_tcl="$_patched_pkg_dir/scripts/openroad/irdrop.tcl"

if [ ! -f "$_irdrop_tcl" ]; then
    mkdir -p "$_writable_root"
    cp -r "$_orig_pkg_dir" "$_patched_pkg_dir"

    python3 - "$_irdrop_tcl" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    content = f.read()

marker = "        lappend arg_list -vsrc $vsrc_file\n"
if marker not in content:
    print(f"ERROR: expected marker not found in {path} -- irdrop.tcl may have "
          "changed upstream, patch needs updating", file=sys.stderr)
    sys.exit(1)

patch = (
    marker
    + "        # VSRC_LOC_FILES_VOLTAGE_PATCH: upstream never sets the "
      "operating\n"
    + "        # voltage in this branch (PSM-0079) -- patched locally, see "
      "patch_irdrop_tcl.sh.\n"
    + "        if { $net eq \"VDD\" } {\n"
    + "            set_pdnsim_net_voltage -net $net -voltage $::env(LIB_VOLTAGE)\n"
    + "        } else {\n"
    + "            set_pdnsim_net_voltage -net $net -voltage 0\n"
    + "        }\n"
)
content = content.replace(marker, patch, 1)

with open(path, "w") as f:
    f.write(content)

print(f"patch_irdrop_tcl.sh: patched {path}")
PYEOF
else
    echo "patch_irdrop_tcl.sh: $_irdrop_tcl already exists, skipping copy+patch"
fi

export PYTHONPATH="$_writable_root${PYTHONPATH:+:$PYTHONPATH}"
echo "patch_irdrop_tcl.sh: PYTHONPATH now shadows librelane with $_patched_pkg_dir"
