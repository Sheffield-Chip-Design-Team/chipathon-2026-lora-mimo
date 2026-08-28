#!/bin/bash
# build_chip_top_smoke.sh
# Assemble integration/tb firmware chip_top_smoke.S into code.hex, the word-wise
# hex image rom_ss.sv loads with $readmemh("code.hex", memory) in simulation
# (grouper hw/rtl/rom_ss.sv, non-ROM_INIT_CONST branch).
#
# rom_ss.sv memory is `logic [31:0] memory [0:MEM_WORDS-1]` and rom_addr is a
# word index (cpu_ss.sv: rom_addr = mem_la_addr[2 +: ROM_ADDR_WIDTH]), so
# code.hex must be ONE 32-bit little-endian word per line, no address tags.
#
# Runs inside hpretl/iic-osic-tools (riscv64-unknown-elf-* is multilib and
# builds rv32emc/ilp32e). Invoke via scripts/run_tb_chip_top.sh, or directly:
#   docker run --rm -v "$PWD/../../..":/foss/designs -w /foss/designs/lora-mimo/integration/fw \
#     --entrypoint bash hpretl/iic-osic-tools:chipathon26 build_chip_top_smoke.sh
set -euo pipefail
cd "$(dirname "$0")"

CC=${RISCV_CC:-riscv64-unknown-elf-gcc}
OC=${RISCV_OBJCOPY:-riscv64-unknown-elf-objcopy}
OD=${RISCV_OBJDUMP:-riscv64-unknown-elf-objdump}

"$CC" -march=rv32emc -mabi=ilp32e -nostdlib -nostartfiles -static \
      -Wl,-Ttext=0x0 -Wl,--no-warn-rwx-segments \
      -o chip_top_smoke.elf chip_top_smoke.S

"$OD" -d chip_top_smoke.elf

# .text -> raw little-endian bytes -> one 32-bit word (8 hex nibbles) per line.
"$OC" -O binary --only-section=.text.init --only-section=.text chip_top_smoke.elf chip_top_smoke.bin

python3 - <<'PY'
import struct, pathlib
b = pathlib.Path("chip_top_smoke.bin").read_bytes()
if len(b) % 4:
    b += b"\x00" * (4 - len(b) % 4)
words = struct.unpack("<%dI" % (len(b) // 4), b)
pathlib.Path("code.hex").write_text("".join("%08x\n" % w for w in words))
print("code.hex: %d words" % len(words))
for i, w in enumerate(words):
    print("  [%02x] %08x" % (i, w))
PY

echo "build_chip_top_smoke.sh: wrote $(pwd)/code.hex"
