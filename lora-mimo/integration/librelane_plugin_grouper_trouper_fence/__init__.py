"""LibreLane flow plugin for the Grouper/Trouper split floorplan.

This package name deliberately follows LibreLane's ``librelane_plugin_*``
discovery convention.  Keeping the flow override in the design means an SGE
snapshot is self-contained and avoids modifying the shared tool container.
"""

from pathlib import Path

from librelane.flows.classic import Classic
from librelane.flows.flow import Flow
from librelane.steps import OpenROAD


_PLUGIN_DIR = Path(__file__).resolve().parent


class _FencedGlobalPlacement:
    """Mixin selecting the design-local GPL Tcl script."""

    def get_script_path(self):
        return str(_PLUGIN_DIR / "gpl_with_grouper_trouper_fences.tcl")


class FencedGlobalPlacementSkipIO(_FencedGlobalPlacement, OpenROAD.GlobalPlacementSkipIO):
    id = "GrouperTrouper.FencedGlobalPlacementSkipIO"
    name = "Fenced Global Placement Skip IO"


class FencedGlobalPlacement(_FencedGlobalPlacement, OpenROAD.GlobalPlacement):
    id = "GrouperTrouper.FencedGlobalPlacement"
    name = "Fenced Global Placement"


class RepairDesignPostGPLCheckpoint(OpenROAD.RepairDesignPostGPL):
    """Normal post-GPL repair with a pre-legalisation ODB checkpoint."""

    id = "GrouperTrouper.RepairDesignPostGPLCheckpoint"
    name = "Repair Design Post-GPL (Checkpoint)"

    def get_script_path(self):
        return str(_PLUGIN_DIR / "repair_design_checkpoint.tcl")


@Flow.factory.register()
class GrouperTrouperFenced(Classic):
    """Classic flow with mandatory NW Grouper and SE Trouper placement fences."""

    Steps = [
        FencedGlobalPlacementSkipIO
        if step is OpenROAD.GlobalPlacementSkipIO
        else FencedGlobalPlacement
        if step is OpenROAD.GlobalPlacement
        else step
        for step in Classic.Steps
    ]


@Flow.factory.register()
class GrouperTrouperRepairCheckpoint(Classic):
    """Classic flow which retains the post-repair ODB for legalisation debug."""

    Steps = [
        RepairDesignPostGPLCheckpoint
        if step is OpenROAD.RepairDesignPostGPL
        else step
        for step in Classic.Steps
    ]
