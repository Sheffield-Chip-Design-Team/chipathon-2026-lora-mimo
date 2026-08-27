#!/bin/bash
set -euo pipefail
cd /foss/designs/lora-mimo/integration/fpga-emul

GROUPER=../ip/grouper/hw/rtl
TROUPER=../ip/trouper/src

iverilog -g2012 -I fw -DPROG_FILE_VMEM=\"code_fpga_gt.vmem\" \
    -o tb_fpga_top.vvp \
    $GROUPER/ahb3lite/ahb3lite_pkg.sv \
    $GROUPER/ahb3lite/ahb3lite_intf.sv \
    $GROUPER/rom/ahb_rom.sv \
    ../../ip/picorv32/picorv32.v \
    ../rtl/cpu_ss_emc.sv \
    rtl/ahb_gpio_dbg.v \
    rtl/fpga_top.v \
    tb/tb_fpga_top.v \
    $TROUPER/top/trouper_top.v \
    $TROUPER/control/ahb_lite_slave_adapter.v \
    $TROUPER/decimator/sd_decimator_poly.v \
    $TROUPER/frontend/dc_removal.v \
    $TROUPER/frontend/sc_detector.v \
    $TROUPER/combiner/training_acc.v \
    $TROUPER/control/packet_ctrl_fsm.v \
    $TROUPER/control/psram_buf_ctrl.v \
    $TROUPER/combiner/mrc_combiner.v \
    $TROUPER/remod/sd_remod.v \
    $TROUPER/control/spi_slave.v \
    $TROUPER/control/reg_bank.v

vvp tb_fpga_top.vvp
