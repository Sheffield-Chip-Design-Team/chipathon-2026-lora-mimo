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
#
# 2026-08-27: grouper submodule moved to dev -- memory path restructured
# (rom_ss/ram_ss straight to CPU inside digital_ss, ahb_rom/ahb_ram gone,
# ahb_interconnect_ss -> interconnect_ss), gpio_ctrl_pkg removed, SRAM
# wrapper file renamed, and rom_ss.sv hardcodes `include "code.vmem" so the
# include dir is Grouper's own sw/boot (PROG_FILE_VMEM is dead). The SRAM
# macro comes in as a (* blackbox *) stub for this elaboration check.
set -euo pipefail
cd /foss/designs/integration

GROUPER=ip/grouper/hw
GROUPER_SRAM=ip/grouper/ip/gf180mcu_ocd_ip_sram/cells/gf180mcu_ocd_ip_sram__sram1024x8m8wm1
TROUPER=ip/trouper/src
OUT=${RUN_DIR:-/foss/runs}   # /foss/designs is read-only inside the container

iverilog -g2012 \
    -o "$OUT/chip_top_check.vvp" \
    -DROM_INIT_CONST -I ip/grouper/sw/boot \
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
    $GROUPER/rtl/interconnect_ss.sv \
    $GROUPER/rtl/rom_ss.sv \
    $GROUPER/rtl/ram_ss.sv \
    $GROUPER/pd/wrappers/gf180mcu_ocd_sram_1024x8m8wm1_wrapper.sv \
    $GROUPER_SRAM/gf180mcu_ocd_ip_sram__sram1024x8m8wm1__blackbox_pp.v \
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
