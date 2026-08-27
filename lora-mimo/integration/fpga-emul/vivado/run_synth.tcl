# run_synth.tcl
# Runs synthesis, inserts an ILA debug core on the AHB bus + bit-banged SPI signals, then runs
# implementation and bitstream generation. Opens the project created by create_project.tcl.
#
# The ILA is the primary pass/fail + debug tool for this bring-up: it captures the AHB write
# to Trouper's MIMO_CTRL and the firmware's own bit-banged SPI readback live over JTAG in
# Vivado's Hardware Manager, with no UART/host software needed. led[2:0] (see arty_top.v /
# ahb_gpio_dbg.v) gives the same PASS/FAIL/DONE result at a glance without opening Vivado at all.
#
# Usage (from fpga-emul/):
#   /path/to/vivado -mode batch -source vivado/run_synth.tcl

set proj_dir  [file normalize "[file dirname [info script]]/../vivado_proj"]
set proj_name "fpga_gt_bringup"

open_project [file normalize "$proj_dir/${proj_name}.xpr"]

# ============================================================================
# Synthesis
# ============================================================================
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
        error "Synthesis failed — check vivado_synth.log"
    }
}
puts "Synthesis complete."

open_run synth_1 -name synth_1

# ============================================================================
# ILA insertion — mark the AHB bus and bit-banged SPI signals for debug, then
# create and connect a debug core against the synthesized netlist.
# ============================================================================
set debug_nets [list \
    {u_fpga_top/c_HADDR[*]}   \
    {u_fpga_top/c_HWDATA[*]}  \
    {u_fpga_top/c_HWRITE}     \
    {u_fpga_top/trouper_sel}  \
    {u_fpga_top/gpio_sel}     \
    {u_fpga_top/dbg_host_cs}  \
    {u_fpga_top/dbg_spi_sck}  \
    {u_fpga_top/dbg_spi_mosi} \
    {u_fpga_top/dbg_spi_miso} \
    {u_fpga_top/led[*]}       \
]
set_property MARK_DEBUG true [get_nets -hierarchical $debug_nets]

create_debug_core u_ila_0 ila
set_property C_DATA_DEPTH 4096 [get_debug_cores u_ila_0]
set_property C_TRIGIN_EN false [get_debug_cores u_ila_0]
set_property C_TRIGOUT_EN false [get_debug_cores u_ila_0]
set_property C_ADV_TRIGGER false [get_debug_cores u_ila_0]
set_property C_INPUT_PIPE_STAGES 2 [get_debug_cores u_ila_0]
set_property C_EN_STRG_QUAL false [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU true [get_debug_cores u_ila_0]
set_property ALL_PROBE_SAME_MU_CNT 1 [get_debug_cores u_ila_0]

connect_debug_port u_ila_0/clk [get_nets u_clk_wiz/clk_out1]

set probe_idx 0
foreach net_pattern $debug_nets {
    set nets [get_nets -hierarchical $net_pattern]
    if {$probe_idx == 0} {
        set_property port_width [llength $nets] [get_debug_ports u_ila_0/probe0]
        connect_debug_port u_ila_0/probe0 $nets
    } else {
        create_debug_port u_ila_0 probe
        set_property port_width [llength $nets] [get_debug_ports u_ila_0/probe$probe_idx]
        connect_debug_port u_ila_0/probe$probe_idx $nets
    }
    incr probe_idx
}

save_constraints -force
write_debug_probes -force "$proj_dir/${proj_name}.ltx"

# ============================================================================
# Implementation
# ============================================================================
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed — check vivado_synth.log"
}
puts "Implementation complete."

open_run impl_1
report_timing_summary -file "$proj_dir/timing_summary.rpt" -max_paths 10
report_utilization -file "$proj_dir/utilization.rpt"

# Copy bitstream + debug probes file to a known location
set bit_file [glob -nocomplain "$proj_dir/${proj_name}.runs/impl_1/*.bit"]
if {[llength $bit_file] > 0} {
    file copy -force [lindex $bit_file 0] "[file dirname [info script]]/../fpga_gt_bringup.bit"
    puts "Bitstream written to fpga-emul/fpga_gt_bringup.bit"
} else {
    puts "WARNING: no .bit file found"
}
set ltx_file "$proj_dir/${proj_name}.ltx"
if {[file exists $ltx_file]} {
    file copy -force $ltx_file "[file dirname [info script]]/../fpga_gt_bringup.ltx"
    puts "Debug probes written to fpga-emul/fpga_gt_bringup.ltx"
}

puts "Done."
