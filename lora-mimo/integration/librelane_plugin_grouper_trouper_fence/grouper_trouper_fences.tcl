# Physical hierarchy split for the landscape experiment.
#
# Grouper (including its fixed SRAM macros) is confined to the usable
# north-west lobe. Trouper is confined to the south-east lobe.  The two
# non-placeable die regions are still provided by FP_OBSTRUCTIONS and remain
# independently honoured by OpenROAD.

set grouper_region GROUPER_NW
set trouper_region TROUPER_SE

set grouper_cells [get_cells -hierarchical "u_grouper*"]
set trouper_cells [get_cells -hierarchical "u_trouper*"]

if {[llength $grouper_cells] == 0} {
    error "Grouper placement fence was not installed: no u_grouper* instances found"
}
if {[llength $trouper_cells] == 0} {
    error "Trouper placement fence was not installed: no u_trouper* instances found"
}

create_region $grouper_region -type fence -rects {0 1117.5 1676.25 2235}
add_to_region $grouper_region $grouper_cells
create_region $trouper_region -type fence -rects {1117.5 0 2235 1117.5}
add_to_region $trouper_region $trouper_cells

puts "[INFO] Installed GROUPER_NW fence (0,1117.5)-(1676.25,2235) for [llength $grouper_cells] instances."
puts "[INFO] Installed TROUPER_SE fence (1117.5,0)-(2235,1117.5) for [llength $trouper_cells] instances."
