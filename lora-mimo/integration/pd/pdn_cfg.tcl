# pdn_cfg.tcl -- Grouper<->Trouper landscape floorplan.
#
# Base: copied near-verbatim from Grouper's own
# integration/ip/grouper/librelane/classic/pdn_cfg.tcl (real, battle-tested --
# its own comments document several real DRC failures this structure fixes:
# Metal2-Metal4 direct-connect producing degenerate vias, off-grid stripe
# phase, SRAM tap-band alignment). Kept here because chip_top.v instantiates
# the exact same sram1024x8m8wm1 macros through the exact same ram_ss/
# sram1024x8_wrapper hierarchy -- see config_landscape_2235.yaml's MACROS
# block.
#
# ADAPTED, 2026-08-22:
#   - Added Trouper's PDN_KEEPOUT_REGION guard at the end (from
#     rtl-test/ol_trouper_top/pdn_cfg.tcl, merged to Trouper main via PR #39)
#     to keep straps out of this die's Obstruction A/B boxes -- Grouper's
#     own die never needed this, Trouper's own die does (two separate
#     source files, genuinely both needed here).
#   - The "Layer stack for picorv32_hello_top" header comment block below is
#     Grouper's own design-rationale prose, left as-is since it still
#     describes the real Metal1-5 stack this script builds -- only the
#     module name in it is stale (was Grouper's old top).
#
# NOT ADAPTED, still TBD -- see config_landscape_2235.yaml's own PDN_V*/H*
# strap-geometry variables and their comments: Grouper's PDN_VPITCH/VOFFSET/
# VSPACING (and the macro x-coordinates that pair with them) were derived
# specifically for the OLD portrait/orientation-S 2x2 SRAM block (a careful
# multi-constraint derivation -- routing-grid alignment, stripe phase, and
# which of the macro's Metal3 VDD/VSS frame bands each stripe lands on).
# Rotating the macros 90 degrees (this design's landscape 2x2, orientation E)
# moves the SRAM's own Metal3 power-frame bands to a different pair of edges,
# which invalidates that derivation -- it needs redoing from the rotated
# macro's own LEF OBS/PIN geometry, not guessed. Deliberately left as a gap
# rather than copying numbers that could silently float an SRAM rail if
# wrong. Until that's done, treat any PDN run against this file as unverified
# for the SRAM's own power connections specifically (the general stdcell
# grid / rail structure below is fine -- it's only the sram_grid tap
# alignment that's unverified).

source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/set_global_connections.tcl
set_global_connections

# ---------------------------------------------------------------------------
# Layer stack (Grouper's own rationale, still accurate for this macro/PDK):
#
# gf180mcu_ocd_ip_sram__sram1024x8m8wm1 obstructs Metal1, Metal2 and Metal3
# across its entire interior and exposes VDD/VSS only on a Metal3 perimeter
# frame. Metal4 is unobstructed, so it is the only layer that can carry
# power over the macro, and Metal3 is the only layer that can receive it.
#
# Structure:
#   Metal5   general mesh horizontal straps (PDN_HORIZONTAL_LAYER)
#   Metal4   vertical straps, full die height, cross the SRAMs
#   Metal3   SPARSE rung stripes, plus the SRAM's own exposed pin tabs
#            (sram_grid connect, hardcoded to Metal3)
#   Metal2   vertical straps, coincident with Metal4, trimmed at the SRAMs
#   Metal1   followpin rails on the std cell VDD/VSS pins
#
# The Metal3 rungs exist because Metal2 and Metal4 are both vertical
# (parallel), so pdngen has no well-defined via intersection between them
# directly -- Metal3 (horizontal) crossing both gives real perpendicular
# intersections pdngen can via-stack reliably. See Grouper's own
# TRIAL_NOTES.md for the PSM-0069 connectivity violations this fixes.
# ---------------------------------------------------------------------------
if { $::env(PDN_VERTICAL_LAYER) != "Metal4" } {
    throw APPLICATION "sram_grid requires Metal4 vertical straps (SRAM obstructs Metal1-Metal3), got $::env(PDN_VERTICAL_LAYER)."
}
if { $::env(PDN_RAIL_LAYER) != "Metal1" } {
    throw APPLICATION "gf180mcu_fd_sc_mcu7t5v0 exposes VDD/VSS on Metal1, got $::env(PDN_RAIL_LAYER)."
}

set pdn_intermediate_layer "Metal2"

set secondary []
foreach vdd $::env(VDD_NETS) gnd $::env(GND_NETS) {
    if { $vdd != $::env(VDD_NET)} {
        lappend secondary $vdd
        set db_net [[ord::get_db_block] findNet $vdd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $vdd]
            $net setSpecial
            $net setSigType "POWER"
        }
    }
    if { $gnd != $::env(GND_NET)} {
        lappend secondary $gnd
        set db_net [[ord::get_db_block] findNet $gnd]
        if {$db_net == "NULL"} {
            set net [odb::dbNet_create [ord::get_db_block] $gnd]
            $net setSpecial
            $net setSigType "GROUND"
        }
    }
}

set_voltage_domain -name CORE -power $::env(VDD_NET) -ground $::env(GND_NET) \
    -secondary_power $secondary

if { $::env(PDN_MULTILAYER) == 1 } {
    set arg_list [list]
    if { $::env(PDN_ENABLE_PINS) } {
        lappend arg_list -pins "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    }

    define_pdn_grid -name stdcell_grid -starts_with POWER -voltage_domain CORE {*}$arg_list

    set arg_list [list]
    append_if_equals arg_list PDN_EXTEND_TO "core_ring" -extend_to_core_ring
    append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_VERTICAL_LAYER) \
        -width $::env(PDN_VWIDTH) -pitch $::env(PDN_VPITCH) \
        -offset $::env(PDN_VOFFSET) -spacing $::env(PDN_VSPACING) \
        -starts_with POWER {*}$arg_list

    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_HORIZONTAL_LAYER) \
        -width $::env(PDN_HWIDTH) -pitch $::env(PDN_HPITCH) \
        -offset $::env(PDN_HOFFSET) -spacing $::env(PDN_HSPACING) \
        -starts_with POWER {*}$arg_list

    # The default uses Grouper's full-die M2/M3 bridge.  The localized
    # experiment removes that bridge from the standard-cell grid; the SRAM
    # macro grid below supplies its own local M3/M4/M5 bridge instead.
    set pdn_local_sram_bridge 0
    if { [info exists ::env(PDN_LOCAL_SRAM_BRIDGE)] && $::env(PDN_LOCAL_SRAM_BRIDGE) } {
        set pdn_local_sram_bridge 1
    }
    set pdn_lean_m2_hybrid 0
    if { [info exists ::env(PDN_LEAN_M2_HYBRID)] && $::env(PDN_LEAN_M2_HYBRID) } {
        set pdn_lean_m2_hybrid 1
    }
    if { $pdn_lean_m2_hybrid } {
        # Keep a sparse M2 rail for post-placement repair, but halve its
        # density relative to Grouper's original grid.  The 0.56um-aligned
        # values preserve legal via/track phases.
        set pdn_m2_width 5.04
        set pdn_m2_pitch 239.68
        set pdn_m2_spacing [expr {$pdn_m2_pitch / 2 - $pdn_m2_width}]
    } else {
        set pdn_m2_width $::env(PDN_VWIDTH)
        set pdn_m2_pitch $::env(PDN_VPITCH)
        set pdn_m2_spacing $::env(PDN_VSPACING)
    }
    if { (!$pdn_local_sram_bridge || $pdn_lean_m2_hybrid) && (![info exists ::env(PDN_M2_LOCAL_ONLY)] || !$::env(PDN_M2_LOCAL_ONLY)) } {
        add_pdn_stripe -grid stdcell_grid -layer $pdn_intermediate_layer \
            -width $pdn_m2_width -pitch $pdn_m2_pitch \
            -offset $::env(PDN_VOFFSET) -spacing $pdn_m2_spacing \
            -starts_with POWER {*}$arg_list
    }

    # Sparse Metal3 rungs -- hardcoded pitch/width/offset (not config
    # variables), same reasoning as Grouper's own file: LibreLane validates
    # config.yaml keys against a fixed schema, and this is an internal
    # implementation detail. NOT re-derived for this design's die/macro
    # coordinates -- see file header. Grouper's own numbers (299.04 pitch,
    # 14.98 offset) are carried over as a placeholder; may not land on-grid
    # for this die's core origin.
    set pdn_rung_layer "Metal3"
    set pdn_rung_width 5.04
    # Default is Grouper's proven topology.  Lean-PDN trials may double the
    # sparse Metal3-rung pitch without changing the required M2-M3-M4/SRAM
    # connection topology.
    set pdn_rung_pitch 299.04
    if { [info exists ::env(PDN_M3_RUNG_PITCH)] } {
        set pdn_rung_pitch $::env(PDN_M3_RUNG_PITCH)
    }
    set pdn_rung_offset 14.98
    set pdn_rung_spacing [expr {$pdn_rung_pitch / 2 - $pdn_rung_width}]

    if { !$pdn_local_sram_bridge || $pdn_lean_m2_hybrid } {
        add_pdn_stripe -grid stdcell_grid -layer $pdn_rung_layer \
            -width $pdn_rung_width -pitch $pdn_rung_pitch \
            -offset $pdn_rung_offset -spacing $pdn_rung_spacing \
            -starts_with POWER
    }

    add_pdn_connect -grid stdcell_grid \
        -layers "$::env(PDN_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
    if { (!$pdn_local_sram_bridge || $pdn_lean_m2_hybrid) && (![info exists ::env(PDN_M2_LOCAL_ONLY)] || !$::env(PDN_M2_LOCAL_ONLY)) } {
        add_pdn_connect -grid stdcell_grid \
            -layers "$pdn_intermediate_layer $pdn_rung_layer"
    }
    if { !$pdn_local_sram_bridge || $pdn_lean_m2_hybrid } {
        add_pdn_connect -grid stdcell_grid \
            -layers "$pdn_rung_layer $::env(PDN_VERTICAL_LAYER)"
    }
} else {
    throw APPLICATION "chip_top requires PDN_MULTILAYER: the SRAM needs a Metal3/Metal4 bridge."
}

if { $::env(PDN_ENABLE_RAILS) == 1 } {
    add_pdn_stripe -grid stdcell_grid -layer $::env(PDN_RAIL_LAYER) \
        -width $::env(PDN_RAIL_WIDTH) -followpins
    if { $pdn_local_sram_bridge && !$pdn_lean_m2_hybrid } {
        # Trouper-style standard-cell connection: the M1 followpin rails
        # connect directly to the unobstructed M4 vertical grid.
        add_pdn_connect -grid stdcell_grid \
            -layers "$::env(PDN_RAIL_LAYER) $::env(PDN_VERTICAL_LAYER)"
    } elseif { ![info exists ::env(PDN_M2_LOCAL_ONLY)] || !$::env(PDN_M2_LOCAL_ONLY) } {
        add_pdn_connect -grid stdcell_grid \
            -layers "$::env(PDN_RAIL_LAYER) $pdn_intermediate_layer"
    }
}

if { $::env(PDN_CORE_RING) == 1 } {
    if { $::env(PDN_MULTILAYER) == 1 } {
        set arg_list [list]
        append_if_flag arg_list PDN_CORE_RING_ALLOW_OUT_OF_DIE -allow_out_of_die
        append_if_flag arg_list PDN_CORE_RING_CONNECT_TO_PADS -connect_to_pads
        append_if_equals arg_list PDN_EXTEND_TO "boundary" -extend_to_boundary

        set pdn_core_vertical_layer $::env(PDN_VERTICAL_LAYER)
        set pdn_core_horizontal_layer $::env(PDN_HORIZONTAL_LAYER)
        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            set pdn_core_vertical_layer $::env(PDN_CORE_VERTICAL_LAYER)
        }
        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            set pdn_core_horizontal_layer $::env(PDN_CORE_HORIZONTAL_LAYER)
        }

        add_pdn_ring -grid stdcell_grid \
            -layers "$pdn_core_vertical_layer $pdn_core_horizontal_layer" \
            -widths "$::env(PDN_CORE_RING_VWIDTH) $::env(PDN_CORE_RING_HWIDTH)" \
            -spacings "$::env(PDN_CORE_RING_VSPACING) $::env(PDN_CORE_RING_HSPACING)" \
            -core_offsets "$::env(PDN_CORE_RING_VOFFSET) $::env(PDN_CORE_RING_HOFFSET)" \
            {*}$arg_list

        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] } {
            add_pdn_connect -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_HORIZONTAL_LAYER)"
        }
        if { [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect -grid stdcell_grid \
                -layers "$::env(PDN_CORE_HORIZONTAL_LAYER) $::env(PDN_VERTICAL_LAYER)"
        }
        if { [info exists ::env(PDN_CORE_VERTICAL_LAYER)] && [info exists ::env(PDN_CORE_HORIZONTAL_LAYER)] } {
            add_pdn_connect -grid stdcell_grid \
                -layers "$::env(PDN_CORE_VERTICAL_LAYER) $::env(PDN_CORE_HORIZONTAL_LAYER)"
        }
    } else {
        throw APPLICATION "PDN_CORE_RING cannot be used when PDN_MULTILAYER is set to false."
    }
}

# ---------------------------------------------------------------------------
# SRAM macro grid -- matched by -cells (Yosys escapes generate-block indices
# in instance names, e.g. gen_sram\[0\]; these are the only block masters in
# the design, so matching on the master is equally precise).
#
# No add_pdn_stripe here on purpose: the Metal4 straps from stdcell_grid
# already run the full die height and cross every macro. This grid tells pdn
# to drop a via wherever a Metal4 stripe of net N overlaps a Metal3 power pin
# of the same net N -- see the "NOT ADAPTED" note in the file header for why
# this alignment is unverified for this design's rotated macro orientation.
# ---------------------------------------------------------------------------
define_pdn_grid \
    -macro \
    -name sram_grid \
    -cells "gf180mcu_ocd_ip_sram__sram1024x8m8wm1" \
    -starts_with POWER \
    -halo "$::env(PDN_HORIZONTAL_HALO) $::env(PDN_VERTICAL_HALO)"

add_pdn_connect \
    -grid sram_grid \
    -layers "Metal3 $::env(PDN_VERTICAL_LAYER)"


# ---------------------------------------------------------------------------
# Die-level obstruction keepout (Obstruction A / B) -- from Trouper's own
# pdn_cfg.tcl pattern (rtl-test/ol_trouper_top/pdn_cfg.tcl, PR #39, merged to
# Trouper main). Grouper's own die never needed this (no die-level notch);
# this design does, for the two boxes carved out of the shared 2235x2235 die
# -- see config_landscape_2235.yaml's FP_OBSTRUCTIONS. create_obstruction
# blocks PG routing too unless -except_pg is passed, which is exactly what we
# want here.
#
# Extended from Trouper's single-region pattern to TWO env vars
# (PDN_KEEPOUT_REGION_A / _B) since this die has two obstruction boxes, not
# one -- Trouper's own L-shape only ever needed one. Both must be exported as
# real shell env vars when this runs (NOT config keys -- confirmed a silent
# no-op there, see run_librelane_pdn_keepout_check.sh, 2026-08-22).
# ---------------------------------------------------------------------------
foreach pdn_keepout_var {PDN_KEEPOUT_REGION_A PDN_KEEPOUT_REGION_B} {
    if { [info exists ::env($pdn_keepout_var)] } {
        set pdn_keepout_region $::env($pdn_keepout_var)
        foreach pdn_keepout_layer {Metal1 Metal2 Metal3 Metal4 Metal5} {
            create_obstruction -region $pdn_keepout_region -layer $pdn_keepout_layer
        }
    }
}
