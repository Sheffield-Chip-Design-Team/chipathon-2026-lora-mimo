# arty_top.xdc
# Pin constraints for Arty A7-100T -- Grouper picorv32 <-> Trouper AHB bring-up.
# Standalone board bring-up (no daughtercard): board clock/reset/LEDs plus JA PMOD for the
# bit-banged SPI debug passthrough (scope probe points / ILA taps), pin names per Digilent's
# Arty-A7-100-Master.xdc.

# ============================================================================
# Board clock (100 MHz) -> clk_wiz_0 -> 32 MHz HCLK (see arty_top.v)
# ============================================================================
set_property PACKAGE_PIN E3  [get_ports CLK100MHZ]
set_property IOSTANDARD  LVCMOS33 [get_ports CLK100MHZ]
create_clock -add -period 10.000 -name sys_clk_pin [get_ports CLK100MHZ]

# ============================================================================
# Board reset button (ck_rst, active-low) -- same net trouper's own fpga-emul
# xdc calls out as "ChipKit ck_rst, not BTN0".
# ============================================================================
set_property PACKAGE_PIN C2  [get_ports ck_rst]
set_property IOSTANDARD  LVCMOS33 [get_ports ck_rst]

# ============================================================================
# On-board LEDs (LD4-LD7): led[2:0] = {FAIL,PASS,DONE} status, led[3] = MMCM locked
# ============================================================================
set_property PACKAGE_PIN H5  [get_ports {led[0]}]
set_property PACKAGE_PIN J5  [get_ports {led[1]}]
set_property PACKAGE_PIN T9  [get_ports {led[2]}]
set_property PACKAGE_PIN T10 [get_ports {led[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# ============================================================================
# JA PMOD -- bit-banged SPI debug passthrough (scope probe / ILA tap points).
# Not required for the test to pass (loopback is entirely on-chip); useful for
# bring-up debugging with a scope alongside the ILA.
# ============================================================================
set_property PACKAGE_PIN G13 [get_ports pmod_host_cs]
set_property PACKAGE_PIN B11 [get_ports pmod_spi_sck]
set_property PACKAGE_PIN A11 [get_ports pmod_spi_mosi]
set_property PACKAGE_PIN D12 [get_ports pmod_spi_miso]
set_property IOSTANDARD LVCMOS33 [get_ports {pmod_host_cs pmod_spi_sck pmod_spi_mosi pmod_spi_miso}]
