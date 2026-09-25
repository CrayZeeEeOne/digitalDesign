set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE Yes [current_design]

# ============================================================
# CLOCK
# ============================================================

set_property PACKAGE_PIN R4 [get_ports diff_clock_rtl_0_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports diff_clock_rtl_0_clk_p]

# TODO: поставити N-пін differential pair для R4
# set_property PACKAGE_PIN <N_PIN> [get_ports diff_clock_rtl_0_clk_n]
# set_property IOSTANDARD DIFF_SSTL15 [get_ports diff_clock_rtl_0_clk_n]

# ============================================================
# RESET
# ============================================================

set_property PACKAGE_PIN R14 [get_ports reset_rtl_0]
set_property IOSTANDARD LVCMOS33 [get_ports reset_rtl_0]

# ============================================================
# LEDs
# ============================================================

set_property PACKAGE_PIN W22 [get_ports led_0]
set_property IOSTANDARD LVCMOS33 [get_ports led_0]

set_property PACKAGE_PIN Y22 [get_ports led_1]
set_property IOSTANDARD LVCMOS33 [get_ports led_1]
