#!/bin/bash
# Focused PDN experiment with SRAM orientations flipped S->N.
set -euo pipefail

export PDN_LOCAL_SRAM_BRIDGE=1
export PDN_KEEPOUT_REGION_A="0 0 1117.22 1117.5"
export PDN_KEEPOUT_REGION_B="1676.25 1117.78 2235 2235"
export RUN_DIR="${RUN_DIR:-/foss/runs}/pdn_local_sram_bridge_reversed"

config_path=$(find /foss/designs -path '*/integration/pd/config_landscape_2235.yaml' -print -quit)
test -n "$config_path"
integration_dir=$(dirname "$(dirname "$config_path")")
cd "$integration_dir"
mkdir -p "$RUN_DIR"
config_root="$RUN_DIR/reversed-config-root"
mkdir -p "$config_root/pd"
ln -sfn "$integration_dir/ip" "$config_root/ip"
ln -sfn "$integration_dir/hw" "$config_root/hw"
ln -sfn "$integration_dir/fw" "$config_root/fw"
# config_landscape_2235.yaml's picorv32.v entry uses dir::../../ip (two
# levels up from pd/), which in the real tree resolves to lora-mimo/ip --
# a *different* directory from integration/ip (grouper/trouper submodules,
# what config_root/ip above already covers one level up). Symlinking
# integration_dir/ip here instead of lora-mimo/ip pointed the two-level-up
# path at the wrong ip/ and broke picorv32.v resolution (jobs 4790-4792).
repo_root=$(dirname "$integration_dir")
ln -sfn "$repo_root/ip" "$RUN_DIR/ip"
ln -sfn "$integration_dir/rtl" "$config_root/rtl"
ln -sfn "$integration_dir/pd/pdn_cfg.tcl" "$config_root/pd/pdn_cfg.tcl"
ln -sfn "$integration_dir/pd/chip_top_dual_clock.sdc" "$config_root/pd/chip_top_dual_clock.sdc"
ln -sfn "$integration_dir/pd/io_placement_landscape.cfg" "$config_root/pd/io_placement_landscape.cfg"
ln -sfn "$integration_dir/pd/vsrc" "$config_root/pd/vsrc"
reversed_config="$config_root/pd/config_landscape_2235_reversed.yaml"
cp "$config_path" "$reversed_config"
sed -i '/^[[:space:]]*orientation: S[[:space:]]*$/s/orientation: S/orientation: N/' "$reversed_config"

librelane "$reversed_config" \
  --pdk gf180mcuD --pdk-root /foss/pdks --manual-pdk \
  --to OpenROAD.GeneratePDN --force-run-dir "$RUN_DIR"
