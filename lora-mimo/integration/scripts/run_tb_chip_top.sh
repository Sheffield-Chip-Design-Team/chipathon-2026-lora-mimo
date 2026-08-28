#!/bin/bash
# run_tb_chip_top.sh
# Build firmware + run integration/tb/tb_chip_top.v under Verilator, inside
# hpretl/iic-osic-tools (grouper dev RTL needs `case () inside`, which iverilog
# rejects -- see check_chip_top.sh; Verilator 5 is the gate now).
#
# Usage (from anywhere):
#   lora-mimo/integration/scripts/run_tb_chip_top.sh              # FW=smoke
#   FW=weightgen LOAD=backdoor  .../run_tb_chip_top.sh
#   FW=weightgen LOAD=uart      .../run_tb_chip_top.sh
#
#   FW    smoke (default) | weightgen
#         smoke     -- hand-assembled program in ROM (T1..T3, GRP plumbing)
#         weightgen -- Trouper firmware/picorv32 MRC weight compute on the real
#                      Grouper CPU, forced-Z, checked vs eigvec_fw golden (T4)
#   LOAD  uart (default) | backdoor   -- weightgen only, how the RAM image loads
#
# Requires the grouper + trouper submodules under lora-mimo/integration/ip/ and
# the grouper local integration patch (auto-applied below if absent).
#
# Overridable: GROUPER_ROOT TROUPER_ROOT PICORV32_V DOCKER_IMAGE  TB_DUMP=1
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INTEG="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$INTEG/../.." && pwd)"

GROUPER_ROOT="${GROUPER_ROOT:-$INTEG/ip/grouper}"
TROUPER_ROOT="${TROUPER_ROOT:-$INTEG/ip/trouper}"
PICORV32_V="${PICORV32_V:-$GROUPER_ROOT/ip/picorv32/picorv32.v}"
DOCKER_IMAGE="${DOCKER_IMAGE:-hpretl/iic-osic-tools:chipathon26}"
RUN_DIR="${RUN_DIR:-$INTEG/runs/tb_chip_top}"
FW="${FW:-smoke}"
LOAD="${LOAD:-uart}"

case "$FW" in smoke|weightgen) ;; *) echo "FW must be smoke|weightgen"; exit 1 ;; esac
case "$LOAD" in uart|backdoor) ;; *) echo "LOAD must be uart|backdoor"; exit 1 ;; esac

for p in "$GROUPER_ROOT/hw/rtl/grouper_soc_top.sv" "$TROUPER_ROOT/src/top/trouper_top.v" "$PICORV32_V"; do
    [ -f "$p" ] || { echo "ERROR: missing $p (submodules not initialised?)"; exit 1; }
done

PATCH="$INTEG/patches/grouper-local-integration.patch"
if grep -q 'DATA_WIDTH/EXT_DATA_WIDTH){ext_HRDATA}' "$GROUPER_ROOT/hw/rtl/periph_ss.sv" 2>/dev/null \
   && grep -q 'ext_ahb_m_if_HADDR' "$GROUPER_ROOT/hw/rtl/grouper_soc_top.sv" 2>/dev/null; then
    echo "grouper local integration patch: already applied"
elif git -C "$GROUPER_ROOT" apply --check "$PATCH" 2>/dev/null; then
    git -C "$GROUPER_ROOT" apply "$PATCH" && echo "grouper local integration patch: applied"
else
    echo "WARNING: grouper local integration patch neither applied nor cleanly appliable"
    echo "         to $GROUPER_ROOT ($PATCH) -- build will likely fail."
fi

mkdir -p "$RUN_DIR"

docker run --rm \
    -u "$(id -u):$(id -g)" \
    -v "$REPO":/repo:ro \
    -v "$GROUPER_ROOT":/grouper:ro \
    -v "$TROUPER_ROOT":/trouper:ro \
    -v "$(dirname "$PICORV32_V")":/pico_dir:ro \
    -v "$RUN_DIR":/work \
    -e TB_DUMP="${TB_DUMP:-0}" -e FW="$FW" -e LOAD="$LOAD" -e PROBE="${PROBE:-0}" \
    --entrypoint bash "$DOCKER_IMAGE" -lc '
set -euo pipefail
set -x
G=/grouper/hw
T=/trouper/src
I=/repo/lora-mimo/integration
FWDIR=$I/fw
cd /work

SYSCLK=25000000
BAUD=115200

# ---- firmware -----------------------------------------------------------
# (a) smoke hand-asm -> code.hex   (also the ROM stub for weightgen+backdoor)
cp "$FWDIR/chip_top_smoke.S" .
riscv64-unknown-elf-gcc -march=rv32emc -mabi=ilp32e -nostdlib -nostartfiles -static \
    -Wl,-Ttext=0x0 -Wl,--no-warn-rwx-segments -o chip_top_smoke.elf chip_top_smoke.S
riscv64-unknown-elf-objcopy -O binary --only-section=.text.init --only-section=.text \
    chip_top_smoke.elf chip_top_smoke.bin
python3 - <<"PY"
import struct, pathlib
b = pathlib.Path("chip_top_smoke.bin").read_bytes()
if len(b) % 4: b += b"\x00" * (4 - len(b) % 4)
w = struct.unpack("<%dI" % (len(b)//4), b)
pathlib.Path("code.hex").write_text("".join("%08x\n" % x for x in w))
PY

# (b) weightgen stimulus + golden  (always -- tb `include`s weightgen_z.vh)
DESIGN_ROOT=/trouper OUT=/work python3 "$FWDIR/weightgen_stimulus.py"

if [ "$FW" = "weightgen" ]; then
    FW_SRC=/trouper/firmware/picorv32 OUT=/work ASIC_REG_BASE=0x80010000u \
        bash "$FWDIR/build_weightgen.sh"
    if [ "$LOAD" = "uart" ]; then
        # Real ROM bootloader. Same recipe as grouper sw/scripts/build_
        # bootloader.sh (start_rv32e.S + bootloader.c, boot.ld, no IRQ vector),
        # replicated here so it needs no writable repo copy. SYS_CLK_HZ is
        # passed explicitly (config.h is #ifndef-guarded by the integration
        # patch); at 25 MHz, --baud 3125000 -> clk_div=0 -> bit period
        # (clk_div+1)*8/SYS_CLK_HZ = 8/25e6 = 320 ns (tb UART_BIT_NS matches).
        BL=/grouper/sw/boot
        riscv64-unknown-elf-gcc -march=rv32emc -mabi=ilp32e -Os -g -ffreestanding \
            -fno-builtin -ffunction-sections -fdata-sections -fomit-frame-pointer \
            -ffixed-s0 -ffixed-s1 \
            -I/grouper/sw/src -I/grouper/sw/src/debug -I/grouper/sw/src/drivers/uart \
            "-DSYS_CLK_HZ=$SYSCLK" -DUART_BAUD_RATE=3125000 \
            -nostdlib -Wl,--gc-sections -Wl,--build-id=none -Wl,-T,"$BL/boot.ld" \
            "$BL/start_rv32e.S" "$BL/bootloader.c" -o bootloader.elf
        riscv64-unknown-elf-objcopy -O binary bootloader.elf bootloader.bin
        python3 - <<"PY"
import struct, pathlib
b = pathlib.Path("bootloader.bin").read_bytes()
if len(b) % 4: b += b"\x00" * (4 - len(b) % 4)
w = struct.unpack("<%dI" % (len(b)//4), b)
assert len(w) <= 0xb6, f"bootloader {len(w)} words > ROM 0xb6 -- shrink or raise MEM_WORDS"
pathlib.Path("code.hex").write_text("".join("%08x\n" % x for x in w))
print("bootloader:", len(w), "words")
PY
    fi
fi

# ---- verilate + build ------------------------------------------------
TRACE=""
[ "${TB_DUMP:-0}" = "1" ] && TRACE="--trace -DDUMP"
[ "${PROBE:-0}" = "1" ] && TRACE="$TRACE -DPROBE"

verilator --binary --timing -j 0 -Wno-fatal --timescale 1ns/1ps -I/work \
    -Wno-UNOPTFLAT -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-UNUSEDSIGNAL \
    -Wno-BLKANDNBLK -Wno-MULTIDRIVEN -Wno-LATCH -Wno-PINMISSING -Wno-TIMESCALEMOD \
    --top-module tb_chip_top -o tb_chip_top $TRACE \
    "$G/rtl/verilator_waivers.vlt" \
    "$G/rtl/ahb3lite/ahb3lite_pkg.sv" \
    "$G/rtl/ahb3lite/ahb3lite_intf.sv" \
    $G/rtl/common/*.sv \
    /pico_dir/picorv32.v \
    $G/rtl/gpio/*.sv $G/rtl/spi_s/*.sv $G/rtl/spi_m/*.sv $G/rtl/qspi/*.sv $G/rtl/uart/*.sv \
    $G/rtl/interconnect/*.sv \
    "$G/rtl/interconnect_ss.sv" "$G/rtl/rom_ss.sv" "$G/rtl/ram_ss.sv" \
    "$G/pd/wrappers/gf180mcu_ocd_sram_1024x8m8wm1_wrapper.sv" \
    "$G/rtl/ram/gf180mcu_ocd_sram_1024x8m8wm1_rtl_model.v" \
    "$G/rtl/io_ss.sv" "$G/rtl/cpu_ss.sv" "$G/rtl/periph_ss.sv" \
    "$G/rtl/digital_ss.sv" "$G/rtl/grouper_soc_top.sv" \
    $T/decimator/*.v $T/frontend/*.v $T/combiner/*.v $T/remod/*.v $T/control/*.v \
    "$T/top/trouper_top.v" \
    "$I/rtl/ahb_to_grp_bridge.v" "$I/rtl/chip_top.v" "$I/tb/tb_chip_top.v"

# ---- run --------------------------------------------------------------
./obj_dir/tb_chip_top +FW=$FW +LOAD=$LOAD
'
echo "run_tb_chip_top.sh: FW=$FW LOAD=$LOAD -- artifacts in $RUN_DIR"
