# microSD slot J2 in SPI mode and the two user LEDs (bank 14, 3.3 V).
# Pins from the PA-StarLite schematic: FPGA bank 14 sheet, nets SD_* and LED*.
#   SD_CLK   IO_L8P_T1_D11_14   AA20   SPI SCK
#   SD_CMD   IO_L10P_T1_D14_14  AB21   SPI MOSI
#   SD_DATA0 IO_L17N_T2_A13_D29 AB18   SPI MISO
#   SD_DATA3 IO_L8N_T1_D12_14   AA21   SPI CS (active low)
#   SD_DATA1 AA18, SD_DATA2 AB22 -- not used in SPI mode
set_property -dict {PACKAGE_PIN AA20 IOSTANDARD LVCMOS33} [get_ports sd_sck]
set_property -dict {PACKAGE_PIN AB21 IOSTANDARD LVCMOS33} [get_ports sd_mosi]
set_property -dict {PACKAGE_PIN AB18 IOSTANDARD LVCMOS33 PULLUP TRUE} [get_ports sd_miso]
set_property -dict {PACKAGE_PIN AA21 IOSTANDARD LVCMOS33} [get_ports {sd_cs_n[0]}]

set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33} [get_ports led1]
set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVCMOS33} [get_ports led2]

# The SD SPI runs from the AXI clock (axi_quad_spi_0 ext_spi_clk = clk_out1): no extra clock.
