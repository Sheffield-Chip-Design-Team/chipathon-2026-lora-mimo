# Derived from LibreLane's openroad/gpl.tcl.  The only functional addition is
# sourcing grouper_trouper_fences.tcl immediately after read_current_odb and
# before OpenROAD global_placement.  Do not source the stock script: it reads
# the ODB itself, which would discard regions created before it runs.
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/resizer.tcl

read_current_odb
source [file join [file dirname [info script]] grouper_trouper_fences.tcl]

set_dont_touch_objects

set ::insts [$::block getInsts]
set placement_needed 0
foreach inst $::insts {
    if { ![$inst isFixed] } {
        set placement_needed 1
        break
    }
}

if { !$placement_needed } {
    puts "[INFO] All instances are FIXED/FIRM."
    puts "[INFO] No need to perform global placement."
    puts "[INFO] Skipping…"
    write_views
    exit_unless_gui
}

set arg_list [list]
lappend arg_list -density [expr $::env(PL_TARGET_DENSITY_PCT) / 100.0]

if { [info exists ::env(PL_TIMING_DRIVEN)] && $::env(PL_TIMING_DRIVEN) } {
    source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
    lappend arg_list -timing_driven
}

if { [info exists ::env(PL_ROUTABILITY_DRIVEN)] && $::env(PL_ROUTABILITY_DRIVEN) } {
    source $::env(SCRIPTS_DIR)/openroad/common/set_routing_layers.tcl
    set_macro_extension $::env(GRT_MACRO_EXTENSION)
    source $::env(SCRIPTS_DIR)/openroad/common/set_layer_adjustments.tcl
    lappend arg_list -routability_driven
    if { [info exists ::env(PL_ROUTABILITY_OVERFLOW_THRESHOLD)] } {
        lappend arg_list -routability_check_overflow $::env(PL_ROUTABILITY_OVERFLOW_THRESHOLD)
    }
}

if { $::env(PL_SKIP_INITIAL_PLACEMENT) } {
    lappend arg_list -skip_initial_place
}
if { [info exists ::env(__PL_SKIP_IO)] && $::env(__PL_SKIP_IO) == "1" } {
    lappend arg_list -skip_io
}
if { [info exists ::env(PL_MIN_PHI_COEFFICIENT)] } {
    lappend arg_list -min_phi_coef $::env(PL_MIN_PHI_COEFFICIENT)
}
if { [info exists ::env(PL_MAX_PHI_COEFFICIENT)] } {
    lappend arg_list -max_phi_coef $::env(PL_MAX_PHI_COEFFICIENT)
}

set cell_pad_side [expr $::env(GPL_CELL_PADDING) / 2]
lappend arg_list -pad_right $cell_pad_side
lappend arg_list -pad_left $cell_pad_side
lappend arg_list -init_wirelength_coef $::env(PL_WIRE_LENGTH_COEF)
append_if_exists_argument arg_list PL_KEEP_RESIZE_BELOW_OVERFLOW -keep_resize_below_overflow

log_cmd global_placement {*}$arg_list
unset_dont_touch_objects
source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -placement
write_views
report_design_area_metrics
