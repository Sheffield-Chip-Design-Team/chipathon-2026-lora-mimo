#!/bin/bash
# run_tb_chip_top.sh
# Build the chip_top end-to-end connectivity testbench firmware and run
# integration/tb/tb_chip_top.v under Verilator, all inside
# hpretl/iic-osic-tools (grouper dev RTL needs `case () inside`, which iverilog
# rejects -- see check_chip_top.sh; Verilator 5 is the gate now).
#
# Usage (from anywhere):
#   lora-mimo/integration/scripts/run_tb_chip_top.sh
#
# Requires the grouper + trouper submodules checked out under
# lora-mimo/integration/ip/ (git submodule update --init) AND grouper's local
# ext_ahb_m_if exposure patch applied to hw/rtl/{digital_ss,grouper_soc_top}.sv
# -- the same not-yet-upstream patch chip_top.v already depends on (see its
# header and integration/planning/Open Risks.md #1).
#
# Overridable for out-of-tree submodule checkouts:
#   GROUPER_ROOT   default: <integration>/ip/grouper
#   TROUPER_ROOT   default: <integration>/ip/trouper
#   PICORV32_V     default: $GROUPER_ROOT/ip/picorv32/picorv32.v
#   DOCKER_IMAGE   default: hpretl/iic-osic-tools:chipathon26
#   TB_DUMP=1      build with --trace and emit tb_chip_top.vcd
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INTEG="$(cd "$HERE/.." && pwd)"                     # lora-mimo/integration
REPO="$(cd "$INTEG/../.." && pwd)"                  # repo root

GROUPER_ROOT="${GROUPER_ROOT:-$INTEG/ip/grouper}"
TROUPER_ROOT="${TROUPER_ROOT:-$INTEG/ip/trouper}"
PICORV32_V="${PICORV32_V:-$GROUPER_ROOT/ip/picorv32/picorv32.v}"
DOCKER_IMAGE="${DOCKER_IMAGE:-hpretl/iic-osic-tools:chipathon26}"
RUN_DIR="${RUN_DIR:-$INTEG/runs/tb_chip_top}"

for p in "$GROUPER_ROOT/hw/rtl/grouper_soc_top.sv" "$TROUPER_ROOT/src/top/trouper_top.v" "$PICORV32_V"; do
    [ -f "$p" ] || { echo "ERROR: missing $p (submodules not initialised?)"; exit 1; }
done

mkdir -p "$RUN_DIR"

# Mounts: repo at /repo, submodule roots at /grouper and /trouper (they may be
# outside the repo tree when overridden), the run/output dir at /work.
docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$REPO":/repo:ro \
    -v "$GROUPER_ROOT":/grouper:ro \
    -v "$TROUPER_ROOT":/trouper:ro \
    -v "$(dirname "$PICORV32_V")":/pico_dir:ro \
    -v "$RUN_DIR":/work \
    -e TB_DUMP="${TB_DUMP:-0}" \
    --entrypoint bash "$DOCKER_IMAGE" -lc '
set -euo pipefail
set -x
G=/grouper/hw
T=/trouper/src
I=/repo/lora-mimo/integration
cd /work

# ---- 1. firmware: chip_top_smoke.S -> code.hex -------------------------------
cp "$I/fw/chip_top_smoke.S" .
riscv64-unknown-elf-gcc -march=rv32emc -mabi=ilp32e -nostdlib -nostartfiles -static \
    -Wl,-Ttext=0x0 -Wl,--no-warn-rwx-segments -o chip_top_smoke.elf chip_top_smoke.S
riscv64-unknown-elf-objdump -d chip_top_smoke.elf
riscv64-unknown-elf-objcopy -O binary --only-section=.text.init --only-section=.text \
    chip_top_smoke.elf chip_top_smoke.bin
python3 - <<"PY"
import struct, pathlib
b = pathlib.Path("chip_top_smoke.bin").read_bytes()
if len(b) % 4: b += b"\x00" * (4 - len(b) % 4)
w = struct.unpack("<%dI" % (len(b)//4), b)
pathlib.Path("code.hex").write_text("".join("%08x\n" % x for x in w))
print("code.hex words:", len(w), [hex(x) for x in w])
PY

# ---- 2. verilate + build --------------------------------------------------
TRACE=""
[ "${TB_DUMP:-0}" = "1" ] && TRACE="--trace -DDUMP"

verilator --binary --timing -j 0 -Wno-fatal --timescale 1ns/1ps \
    -Wno-UNOPTFLAT -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNUSEDSIGNAL \
    -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-LATCH -Wno-PINMISSING -Wno-TIMESCALEMOD \
    --top-module tb_chip_top -o tb_chip_top $TRACE \
    "$G/rtl/verilator_waivers.vlt" \
    "$G/rtl/ahb3lite/ahb3lite_pkg.sv" \
    "$G/rtl/ahb3lite/ahb3lite_intf.sv" \
    $G/rtl/common/*.sv \
    /pico_dir/picorv32.v \
    $G/rtl/gpio/*.sv \
    $G/rtl/spi_s/*.sv \
    $G/rtl/spi_m/*.sv \
    $G/rtl/qspi/*.sv \
    $G/rtl/uart/*.sv \
    $G/rtl/interconnect/*.sv \
    "$G/rtl/interconnect_ss.sv" \
    "$G/rtl/rom_ss.sv" \
    "$G/rtl/ram_ss.sv" \
    "$G/pd/wrappers/gf180mcu_ocd_sram_1024x8m8wm1_wrapper.sv" \
    "$G/rtl/ram/gf180mcu_ocd_sram_1024x8m8wm1_rtl_model.v" \
    "$G/rtl/io_ss.sv" \
    "$G/rtl/cpu_ss.sv" \
    "$G/rtl/periph_ss.sv" \
    "$G/rtl/digital_ss.sv" \
    "$G/rtl/grouper_soc_top.sv" \
    $T/decimator/*.v $T/frontend/*.v $T/combiner/*.v $T/remod/*.v $T/control/*.v \
    "$T/top/trouper_top.v" \
    "$I/rtl/ahb_to_grp_bridge.v" \
    "$I/rtl/chip_top.v" \
    "$I/tb/tb_chip_top.v"

# ---- 3. run --------------------------------------------------------------
./obj_dir/tb_chip_top
'
echo "run_tb_chip_top.sh: artifacts in $RUN_DIR"
