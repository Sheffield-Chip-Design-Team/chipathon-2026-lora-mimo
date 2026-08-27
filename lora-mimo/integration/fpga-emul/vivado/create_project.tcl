# create_project.tcl
# Creates the Vivado project for the Grouper picorv32 <-> Trouper AHB3-Lite bring-up.
# Target: Digilent Arty A7-100T (xc7a100tcsg324-1)
#
# Top-level: arty_top.v (100 MHz board clock -> clk_wiz_0 -> 32 MHz HCLK -> fpga_top.v, which
# instantiates the same cpu_ss_emc / ahb_rom / trouper_top RTL exercised by the simulation-only
# tb_grouper_trouper_top.v, plus the new ahb_gpio_dbg.v bit-banged-SPI/status peripheral).
#
# Usage (from fpga-emul/):
#   vivado -mode batch -source vivado/create_project.tcl
# Then run vivado/run_synth.tcl (inserts ILA probes, synthesizes, implements, writes bitstream).

# ============================================================================
# Paths
# ============================================================================
set proj_name   "fpga_gt_bringup"
set proj_dir    [file normalize "[file dirname [info script]]/../vivado_proj"]
set rtl_dir     [file normalize "[file dirname [info script]]/../rtl"]
set int_rtl_dir [file normalize "[file dirname [info script]]/../../rtl"]
set grouper_dir [file normalize "[file dirname [info script]]/../../ip/grouper"]
set trouper_dir [file normalize "[file dirname [info script]]/../../ip/trouper/src"]
set picorv32_dir [file normalize "[file dirname [info script]]/../../../ip/picorv32"]
set part        "xc7a100tcsg324-1"

# ============================================================================
# Create project
# ============================================================================
create_project $proj_name $proj_dir -part $part -force
set_property board_part digilentinc.com:arty-a7-100:part0:1.1 [current_project]

# ============================================================================
# RTL sources
# ============================================================================
set srcs [list \
    "$grouper_dir/hw/rtl/ahb3lite/ahb3lite_pkg.sv"        \
    "$grouper_dir/hw/rtl/ahb3lite/ahb3lite_intf.sv"        \
    "$grouper_dir/hw/rtl/rom/ahb_rom.sv"                   \
    "$picorv32_dir/picorv32.v"                             \
    "$int_rtl_dir/cpu_ss_emc.sv"                           \
    "$rtl_dir/ahb_gpio_dbg.v"                              \
    "$rtl_dir/fpga_top.v"                                  \
    "$rtl_dir/arty_top.v"                                  \
    "$trouper_dir/top/trouper_top.v"                       \
    "$trouper_dir/control/ahb_lite_slave_adapter.v"        \
    "$trouper_dir/decimator/sd_decimator_poly.v"           \
    "$trouper_dir/frontend/dc_removal.v"                   \
    "$trouper_dir/frontend/sc_detector.v"                  \
    "$trouper_dir/combiner/training_acc.v"                 \
    "$trouper_dir/control/packet_ctrl_fsm.v"                \
    "$trouper_dir/control/psram_buf_ctrl.v"                \
    "$trouper_dir/combiner/mrc_combiner.v"                  \
    "$trouper_dir/remod/sd_remod.v"                         \
    "$trouper_dir/control/spi_slave.v"                      \
    "$trouper_dir/control/reg_bank.v"                       \
]
add_files -norecurse $srcs
set_property top arty_top [current_fileset]

# `FPGA is only defined for the top ahb_rom instance's $readmemh path (see ahb_rom.sv);
# PROG_FILE_HEX selects our hand-assembled bring-up program (see ../fw/code_fpga_gt.hex).
set_property verilog_define [list \
    "FPGA" \
    "PROG_FILE_HEX=\"[file normalize [file dirname [info script]]/../fw/code_fpga_gt.hex]\"" \
] [current_fileset]

# Constraints
add_files -fileset constrs_1 -norecurse \
    "[file dirname [info script]]/arty_top.xdc"

# ============================================================================
# Clocking Wizard IP: 100 MHz -> 32 MHz, active-low reset (matches arty_top.v's
# clk_wiz_0 instantiation and lora-mimo/fpga-emul's clk_wiz_0 configuration style).
# ============================================================================
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
    -module_name clk_wiz_0 -dir "$proj_dir/${proj_name}.srcs/sources_1/ip"
set_property -dict [list \
    CONFIG.PRIM_IN_FREQ               {100.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {32.000}  \
    CONFIG.CLKIN1_JITTER_PS           {100.0}   \
    CONFIG.RESET_TYPE                 {ACTIVE_LOW} \
    CONFIG.RESET_PORT                 {resetn}  \
    CONFIG.USE_LOCKED                 {true}    \
] [get_ips clk_wiz_0]
generate_target {instantiation_template} [get_ips clk_wiz_0]
generate_target all [get_files "$proj_dir/${proj_name}.srcs/sources_1/ip/clk_wiz_0/clk_wiz_0.xci"]

update_compile_order -fileset sources_1

puts "Project created: $proj_dir"
puts "Next: vivado -mode batch -source vivado/run_synth.tcl"
