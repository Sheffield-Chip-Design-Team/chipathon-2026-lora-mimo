#!/usr/bin/env bash
set -euo pipefail

grouper_root=/foss/designs/integration/ip/grouper
cp /foss/designs/integration/ram_backdoor/test_grouper_trouper_nwmrc_e2e.py "$PWD/"
SYS_CLK_HZ_OVERRIDE=16000000 "$grouper_root/sw/scripts/build_fw.sh" --test trouper_nwmrc_e2e --link ram --no-disasm
SYS_CLK_HZ_OVERRIDE=16000000 "$grouper_root/sw/scripts/build_bootloader.sh" --baud 19200 --no-disasm
