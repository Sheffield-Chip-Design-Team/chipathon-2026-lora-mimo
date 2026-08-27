# fpga-emul/Makefile
# FPGA bring-up of the Grouper picorv32 <-> Trouper AHB3-Lite integration on an Arty A7-100T.
# See ../rtl/grouper_trouper_top.v / ../tb/tb_grouper_trouper_top.v for the proven
# simulation-only version this is built on top of (not modified here).
#
# SGE targets (primary): submit the iverilog job to the homelab SGE cluster.
#   make sge_sim_fpga_top
#
# Local target (inside the chipathon26 container, or any host with iverilog + the RTL sources):
#   make sim_fpga_top
#
# After submitting an SGE job, poll completion with:
#   curl -s http://nas.home:4783/api/jobs/<ID>
# Read output from:
#   /srv/eda/logs/<user>/job-<ID>.o

HLAB_SGE_URL = http://nas.home:4783
NFS_DESIGN   = /srv/eda/designs/timothyjabez/lora-mimo

.PHONY: sge_sim_fpga_top sim_fpga_top vivado_project vivado_synth program clean

# ============================================================================
# SGE simulation (submit to homelab cluster) -- iverilog isn't available locally.
# ============================================================================
sge_sim_fpga_top:
	HLAB_SGE_URL=$(HLAB_SGE_URL) hqsub \
	    --name fpga-sim-fpga-top \
	    --cpus 2 \
	    --mem 4G \
	    $(NFS_DESIGN)/integration/fpga-emul/sge/sim_fpga_top.sh

# ============================================================================
# Local iverilog target (run inside chipathon26 container, or any host with iverilog)
# ============================================================================
sim_fpga_top:
	bash scripts/run.sh

# ============================================================================
# Vivado project (Arty A7-100T) -- run where Vivado + the board are available.
# ============================================================================
VIVADO = vivado

vivado_project:
	$(VIVADO) -mode batch -source vivado/create_project.tcl 2>&1 | tee vivado_create.log

vivado_synth:
	cd vivado_proj && $(VIVADO) -mode batch -source ../vivado/run_synth.tcl 2>&1 | tee ../vivado_synth.log

program:
	$(VIVADO) -mode batch -source vivado/program_fpga.tcl

# ============================================================================
# Clean
# ============================================================================
clean:
	rm -rf tb_fpga_top.vvp *.vcd vivado_create.log vivado_synth.log
