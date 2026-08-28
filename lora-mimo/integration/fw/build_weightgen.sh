#!/bin/bash
# build_weightgen.sh
# Build Trouper's firmware/picorv32 MRC weight-computation image (crt0.S +
# main.c) for the chip_top integration testbench: RV32EMC, linked flat into the
# 4 KiB RAM at address 0 (== Grouper RAM after the bank switch), with the
# register bank pointed at Grouper's ext-periph window.
#
#   ASIC_REG_BASE = 0x80010000   -> interconnect_ss SLOT_EXT_PERIPH -> bridge -> GRP bus
#
# Outputs (in the run dir): weightgen.bin (raw image, for +LOAD=uart) and
# weightgen.lane{0..3}.hex (per-byte-lane, for +LOAD=backdoor $readmemh into
# ram_ss's four sram1024x8 models). Also weightgen.dump for debugging.
#
# Run inside hpretl/iic-osic-tools (riscv64-unknown-elf-* multilib); invoked by
# scripts/run_tb_chip_top.sh, or directly:
#   docker run --rm -v <trouper>:/trouper -v <outdir>:/work --entrypoint bash \
#     hpretl/iic-osic-tools:chipathon26 -lc '/repo/.../build_weightgen.sh'
set -euo pipefail

FW_SRC="${FW_SRC:?set FW_SRC to trouper/firmware/picorv32}"
OUT="${OUT:-$PWD}"
CROSS="${CROSS:-riscv64-unknown-elf-}"
REG_BASE="${ASIC_REG_BASE:-0x80010000u}"

CFLAGS=(-march=rv32emc -mabi=ilp32e -Os -g -ffreestanding -fno-builtin
        -fdata-sections -ffunction-sections -fno-common -fno-pic
        -fno-stack-protector -Wall -Wextra -msmall-data-limit=0
        "-I$FW_SRC" "-DASIC_REG_BASE=$REG_BASE")

cd "$OUT"
"${CROSS}gcc" "${CFLAGS[@]}" -nostdlib -nostartfiles \
    -Wl,-T,"$FW_SRC/linker.ld",--gc-sections \
    "$FW_SRC/crt0.S" "$FW_SRC/main.c" -o weightgen.elf
"${CROSS}objcopy" -O binary weightgen.elf weightgen.bin
"${CROSS}objdump" -d -S weightgen.elf > weightgen.dump
"${CROSS}size" weightgen.elf

python3 - <<'PY'
import struct, pathlib
img = pathlib.Path("weightgen.bin").read_bytes()
if len(img) % 4:
    img += b"\x00" * (4 - len(img) % 4)
words = struct.unpack("<%dI" % (len(img) // 4), img)
assert len(words) <= 1024, f"image {len(words)} words > 1024 (4 KiB RAM)"
# Per-byte-lane hex for $readmemh into the four sram1024x8 `mem` arrays.
for lane in range(4):
    pathlib.Path(f"weightgen.lane{lane}.hex").write_text(
        "".join("%02x\n" % ((w >> (8 * lane)) & 0xFF) for w in words))
# Flat little-endian byte image for the UART bootloader path.
pathlib.Path("weightgen.bytes.hex").write_text(
    "".join("%02x\n" % b for b in img))
pathlib.Path("weightgen.nwords.txt").write_text(str(len(words)))
print(f"weightgen: {len(words)} words ({len(img)} bytes), lane + byte hex written")
PY
