#!/usr/bin/env bash
set -euo pipefail

# The FuseSoC hook runs from its work root; build_fw.sh deliberately publishes
# firmware.bin there, then build_bootloader.sh replaces only code.hex there.
grouper_root=/foss/designs/integration/ip/grouper
# The published RV32EMC eigenvector budget is at 16 MHz.  Build both sides of
# the UART boot path for that same clock so the combined measurement is useful.
SYS_CLK_HZ_OVERRIDE=16000000 "$grouper_root/sw/scripts/build_fw.sh" --test trouper_psram_backdoor --link ram --no-disasm
SYS_CLK_HZ_OVERRIDE=16000000 "$grouper_root/sw/scripts/build_bootloader.sh" --baud 19200 --no-disasm
