#!/bin/bash
# Syntax/elaboration check only for chip_top.v (Open Item #1) -- no testbench
# yet, just confirms it parses and elaborates against real RTL from both
# projects. Run on the homelab-sge cluster (no local iverilog -- see
# integration/fpga-emul/Makefile's note on this).
#
# 2026-08-22, rewritten: chip_top.v now instantiates Grouper's real
# grouper_soc_top (whole SoC) instead of hand-picked submodules -- file list
# below matches synth_only_chip_top.yaml's (Grouper's own full
# librelane/classic/config.yaml list, minus its padframe wrapper).
set -euo pipefail
cd /foss/designs/integration

GROUPER=ip/grouper/hw
TROUPER=ip/trouper/src
OUT=${RUN_DIR:-/foss/runs}   # /foss/designs is read-only inside the container

iverilog -g2012 \
    -o "$OUT/chip_top_check.vvp" \
    -DROM_INIT_CONST -DPROG_FILE_VMEM=\"code_grouper_trouper.vmem\" -I fw \
    $GROUPER/rtl/ahb3lite/ahb3lite_pkg.sv \
    $GROUPER/rtl/common/clk_div.sv \
    $GROUPER/rtl/common/clk_gate.sv \
    $GROUPER/rtl/common/clk_out.sv \
    $GROUPER/rtl/common/downcounter.sv \
    $GROUPER/rtl/common/pulse_sync.sv \
    $GROUPER/rtl/common/shift_reg.sv \
    $GROUPER/rtl/common/small_sync_fifo.sv \
    $GROUPER/rtl/common/sync.sv \
    ../ip/picorv32/picorv32.v \
    $GROUPER/rtl/gpio/gpio_ctrl_pkg.sv \
    $GROUPER/rtl/gpio/ahb_gpio_ctrl.sv \
    $GROUPER/rtl/spi_s/ahb_spi_s.sv \
    $GROUPER/rtl/uart/uart_clk_div.sv \
    $GROUPER/rtl/uart/uart_rx.sv \
    $GROUPER/rtl/uart/uart_tx.sv \
    $GROUPER/rtl/uart/uart.sv \
    $GROUPER/rtl/uart/ahb_uart.sv \
    $GROUPER/rtl/interconnect/ahb_debug.sv \
    $GROUPER/rtl/interconnect/ahb_conn_buff.sv \
    $GROUPER/rtl/interconnect/ahb_stub_slave.sv \
    $GROUPER/rtl/ahb_interconnect_ss.sv \
    $GROUPER/rtl/memory/ahb_rom.sv \
    $GROUPER/rtl/memory/ahb_ram.sv \
    $GROUPER/rtl/memory/ram_ss.sv \
    $GROUPER/pd/wrappers/sram1024x8_wrapper.sv \
    $GROUPER/rtl/io_ss.sv \
    $GROUPER/rtl/cpu_ss.sv \
    $GROUPER/rtl/periph_ss.sv \
    $GROUPER/rtl/digital_ss.sv \
    $GROUPER/rtl/grouper_soc_top.sv \
    rtl/ahb_to_grp_bridge.v \
    rtl/chip_top.v \
    $TROUPER/top/trouper_top.v \
    $TROUPER/decimator/sd_decimator_poly.v \
    $TROUPER/frontend/dc_removal.v \
    $TROUPER/frontend/sc_detector.v \
    $TROUPER/combiner/training_acc.v \
    $TROUPER/control/packet_ctrl_fsm.v \
    $TROUPER/control/psram_buf_ctrl.v \
    $TROUPER/combiner/mrc_combiner.v \
    $TROUPER/remod/sd_remod.v \
    $TROUPER/control/spi_slave.v \
    $TROUPER/control/reg_bank.v \
    -s chip_top

echo "chip_top.v: elaborates cleanly"
