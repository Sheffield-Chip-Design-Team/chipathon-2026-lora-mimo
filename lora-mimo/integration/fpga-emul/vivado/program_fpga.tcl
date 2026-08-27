# program_fpga.tcl
# Programs the Arty A7-100T via USB-JTAG using Vivado hw_server, and opens the debug probes
# file so the ILA inserted by run_synth.tcl (AHB bus + bit-banged SPI signals) is immediately
# available in Vivado's Hardware Manager -- no separate probe-file step needed.
set bit_file [file normalize "[file dirname [info script]]/../fpga_gt_bringup.bit"]
set ltx_file [file normalize "[file dirname [info script]]/../fpga_gt_bringup.ltx"]

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices] 0]
puts "Device: [get_property NAME $dev]"
current_hw_device $dev
refresh_hw_device $dev
set_property PROGRAM.FILE $bit_file $dev
if {[file exists $ltx_file]} {
    set_property PROBES.FILE $ltx_file $dev
}
program_hw_devices $dev
refresh_hw_device $dev
puts "Programming complete. DONE=[get_property REGISTER.IR.BIT5_DONE $dev]"
puts "ILA cores available in Hardware Manager: [get_hw_ilas]"
close_hw_target
disconnect_hw_server
close_hw_manager
