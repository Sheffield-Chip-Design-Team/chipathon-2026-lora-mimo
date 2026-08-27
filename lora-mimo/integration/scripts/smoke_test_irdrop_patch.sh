#!/bin/bash
set -euo pipefail
export PDK_ROOT=/foss/pdks
export PDK=gf180mcuD
patch_script=$(find /foss/designs -path '*/integration/scripts/patch_irdrop_tcl.sh' -print -quit)
test -n "$patch_script"
source "$patch_script"
echo "--- PYTHONPATH ---"
echo "$PYTHONPATH"
IRDROP_TCL=$(python3 -c "import librelane, os; print(os.path.join(os.path.dirname(librelane.__file__), 'scripts', 'openroad', 'irdrop.tcl'))")
echo "--- resolved irdrop.tcl path (should be under \$RUN_DIR now) ---"
echo "$IRDROP_TCL"
echo "--- patched file ---"
cat "$IRDROP_TCL"
echo "--- tclsh syntax check ---"
tclsh <<EOF
set fh [open "$IRDROP_TCL" r]
set script [read \$fh]
close \$fh
# just parse-check via 'info complete', not a full source (missing deps)
if {[info complete \$script]} {
    puts "SYNTAX OK: script is a complete Tcl script"
} else {
    puts "SYNTAX ERROR: incomplete script"
    exit 1
}
EOF
