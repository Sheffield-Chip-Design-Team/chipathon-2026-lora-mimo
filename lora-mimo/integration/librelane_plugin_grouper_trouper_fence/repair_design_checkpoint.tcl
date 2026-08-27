# Diagnostic copy of LibreLane's repair_design.tcl.  It intentionally writes
# an ODB after Resizer insertions and before detailed placement, so a failing
# legalisation can be inspected without changing repair behaviour.
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/resizer.tcl

read_current_odb
unset_propagated_clock [all_clocks]
set_dont_touch_objects
source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -placement

if { $::env(DESIGN_REPAIR_REMOVE_BUFFERS) } {
    remove_buffers
}
if { $::env(DESIGN_REPAIR_BUFFER_INPUT_PORTS) } {
    buffer_ports -inputs
}
if { $::env(DESIGN_REPAIR_BUFFER_OUTPUT_PORTS) } {
    buffer_ports -outputs
}

set arg_list [list]
lappend arg_list -verbose
lappend arg_list -max_wire_length $::env(DESIGN_REPAIR_MAX_WIRE_LENGTH)
lappend arg_list -slew_margin $::env(DESIGN_REPAIR_MAX_SLEW_PCT)
lappend arg_list -cap_margin $::env(DESIGN_REPAIR_MAX_CAP_PCT)
if { [info exists ::env(DESIGN_REPAIR_MAX_UTILIZATION)] } {
    lappend arg_list -max_utilization $::env(DESIGN_REPAIR_MAX_UTILIZATION)
}
if { [info exists ::env(DESIGN_REPAIR_BUFFER_GAIN)] } {
    lappend arg_list -buffer_gain $::env(DESIGN_REPAIR_BUFFER_GAIN)
}
log_cmd repair_design {*}$arg_list

if { $::env(DESIGN_REPAIR_TIE_FANOUT) } {
    repair_tie_fanout -verbose -separation $::env(DESIGN_REPAIR_TIE_SEPARATION) $::env(SYNTH_TIELO_CELL)
    repair_tie_fanout -verbose -separation $::env(DESIGN_REPAIR_TIE_SEPARATION) $::env(SYNTH_TIEHI_CELL)
}
report_floating_nets -verbose

write_db /foss/runs/post_repair_pre_dpl.odb
puts "\[INFO\] Wrote /foss/runs/post_repair_pre_dpl.odb for legalisation diagnosis."

source $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl
unset_dont_touch_objects
source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -placement
write_views
