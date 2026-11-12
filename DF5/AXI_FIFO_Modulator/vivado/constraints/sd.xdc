# microSD slot J2 on the native SD bus (4-bit) and the two user LEDs (bank 14, 3.3 V).
# Pins from the PA-StarLite schematic: FPGA bank 14 sheet, nets SD_* and LED*.
#   SD_CLK   IO_L8P_T1_D11_14   AA20   CLK  (sd_host: 25 MHz, 400 kHz during identification)
#   SD_CMD   IO_L10P_T1_D14_14  AB21   CMD  (bidirectional)
#   SD_DATA0 IO_L17N_T2_A13_D29 AB18   DAT0
#   SD_DATA1                    AA18   DAT1
#   SD_DATA2                    AB22   DAT2
#   SD_DATA3 IO_L8N_T1_D12_14   AA21   DAT3
# CMD and DAT have pull-ups (the bus idles high; the card drives them open between frames).
set_property -dict {PACKAGE_PIN AA20 IOSTANDARD LVCMOS33 SLEW FAST DRIVE 8} [get_ports sd_clk]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports sd_cmd]
set_property -dict {PACKAGE_PIN AB18 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {sd_dat[0]}]
set_property -dict {PACKAGE_PIN AA18 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {sd_dat[1]}]
set_property -dict {PACKAGE_PIN AB22 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {sd_dat[2]}]
set_property -dict {PACKAGE_PIN AA21 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports {sd_dat[3]}]

set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVCMOS33} [get_ports led2]

# sd_clk is a register output clocked by the AXI clock: no extra clock. The SD bus
# timing is set inside sd_host (inputs sampled SDLY AXI clocks after the CLK edge).
set_false_path -to [get_ports {sd_clk sd_cmd sd_dat[*]}]
set_false_path -from [get_ports {sd_cmd sd_dat[*]}]
