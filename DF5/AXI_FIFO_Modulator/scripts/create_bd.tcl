#==============================================================================
# create_bd.tcl -- Block Design "microblaze" (MicroBlaze, 64 KB LMB, tft_top,
# system_ctrl_top, AXI Quad SPI for the microSD card, iq_stream_top -> dsp_top:
# I/Q FIFO and the whole DSP in RTL). Згенеровано write_bd_tcl з робочого BD; build.tcl викликає
# його, коли збереженого .bd у vivado/sources/bd/ немає (тобто на чистому клоні).
# Після змін BD у GUI перегенеруй: write_bd_tcl -force -no_project_wrapper.
#==============================================================================

# Proc to create BD microblaze
proc cr_bd_microblaze { parentCell } {
# The design that will be created by this Tcl proc contains the following 
# module references:
# tft_top, system_ctrl_top, iq_stream_top, dsp_top



  # CHANGE DESIGN NAME HERE
  set design_name microblaze

# This script was generated for a remote BD. To create a non-remote design,
# change the variable <run_remote_bd_flow> to <0>.

set run_remote_bd_flow 0
if { $run_remote_bd_flow == 1 } {
  # Set the reference directory for source file relative paths (by default 
  # the value is script directory path)
  set origin_dir ./bd

  # Use origin directory path location variable, if specified in the tcl shell
  if { [info exists ::origin_dir_loc] } {
     set origin_dir $::origin_dir_loc
  }

  set str_bd_folder [file normalize ${origin_dir}]
  set str_bd_filepath ${str_bd_folder}/${design_name}/${design_name}.bd

  # Check if remote design exists on disk
  if { [file exists $str_bd_filepath ] == 1 } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2030 -severity "ERROR" "The remote BD file path <$str_bd_filepath> already exists!"}
     common::send_gid_msg -ssname BD::TCL -id 2031 -severity "INFO" "To create a non-remote BD, change the variable <run_remote_bd_flow> to <0>."
     common::send_gid_msg -ssname BD::TCL -id 2032 -severity "INFO" "Also make sure there is no design <$design_name> existing in your current project."

     return 1
  }

  # Check if design exists in memory
  set list_existing_designs [get_bd_designs -quiet $design_name]
  if { $list_existing_designs ne "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2033 -severity "ERROR" "The design <$design_name> already exists in this project! Will not create the remote BD <$design_name> at the folder <$str_bd_folder>."}

     common::send_gid_msg -ssname BD::TCL -id 2034 -severity "INFO" "To create a non-remote BD, change the variable <run_remote_bd_flow> to <0> or please set a different value to variable <design_name>."

     return 1
  }

  # Check if design exists on disk within project
  set list_existing_designs [get_files -quiet */${design_name}.bd]
  if { $list_existing_designs ne "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2035 -severity "ERROR" "The design <$design_name> already exists in this project at location:
    $list_existing_designs"}
     catch {common::send_gid_msg -ssname BD::TCL -id 2036 -severity "ERROR" "Will not create the remote BD <$design_name> at the folder <$str_bd_folder>."}

     common::send_gid_msg -ssname BD::TCL -id 2037 -severity "INFO" "To create a non-remote BD, change the variable <run_remote_bd_flow> to <0> or please set a different value to variable <design_name>."

     return 1
  }

  # Now can create the remote BD
  # NOTE - usage of <-dir> will create <$str_bd_folder/$design_name/$design_name.bd>
  create_bd_design -dir $str_bd_folder $design_name
} else {

  # Create regular design
  if { [catch {create_bd_design $design_name} errmsg] } {
     common::send_gid_msg -ssname BD::TCL -id 2038 -severity "INFO" "Please set a different value to variable <design_name>."

     return 1
  }
}

current_bd_design $design_name

  set bCheckIPsPassed 1
  ##################################################################
  # CHECK IPs
  ##################################################################
  set bCheckIPs 1
  if { $bCheckIPs == 1 } {
     set list_check_ips "\ 
  xilinx.com:ip:microblaze:11.0\
  xilinx.com:ip:mdm:3.2\
  xilinx.com:ip:clk_wiz:6.0\
  xilinx.com:ip:axi_quad_spi:3.2\
  xilinx.com:ip:proc_sys_reset:5.0\
  xilinx.com:ip:xlconstant:1.1\
  xilinx.com:ip:lmb_v10:3.0\
  xilinx.com:ip:lmb_bram_if_cntlr:4.0\
  xilinx.com:ip:blk_mem_gen:8.4\
  "

   set list_ips_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2011 -severity "INFO" "Checking if the following IPs exist in the project's IP catalog: $list_check_ips ."

   foreach ip_vlnv $list_check_ips {
      set ip_obj [get_ipdefs -all $ip_vlnv]
      if { $ip_obj eq "" } {
         lappend list_ips_missing $ip_vlnv
      }
   }

   if { $list_ips_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2012 -severity "ERROR" "The following IPs are not found in the IP Catalog:\n  $list_ips_missing\n\nResolution: Please add the repository containing the IP(s) to the project." }
      set bCheckIPsPassed 0
   }

  }

  ##################################################################
  # CHECK Modules
  ##################################################################
  set bCheckModules 1
  if { $bCheckModules == 1 } {
     set list_check_mods "\ 
  tft_top\
  system_ctrl_top\
  "

   set list_mods_missing ""
   common::send_gid_msg -ssname BD::TCL -id 2020 -severity "INFO" "Checking if the following modules exist in the project's sources: $list_check_mods ."

   foreach mod_vlnv $list_check_mods {
      if { [can_resolve_reference $mod_vlnv] == 0 } {
         lappend list_mods_missing $mod_vlnv
      }
   }

   if { $list_mods_missing ne "" } {
      catch {common::send_gid_msg -ssname BD::TCL -id 2021 -severity "ERROR" "The following module(s) are not found in the project: $list_mods_missing" }
      common::send_gid_msg -ssname BD::TCL -id 2022 -severity "INFO" "Please add source files for the missing module(s) above."
      set bCheckIPsPassed 0
   }
}

  if { $bCheckIPsPassed != 1 } {
    common::send_gid_msg -ssname BD::TCL -id 2023 -severity "WARNING" "Will not continue with creation of design due to the error(s) above."
    return 3
  }

  
# Hierarchical cell: microblaze_0_local_memory
proc create_hier_cell_microblaze_0_local_memory { parentCell nameHier } {

  variable script_folder

  if { $parentCell eq "" || $nameHier eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2092 -severity "ERROR" "create_hier_cell_microblaze_0_local_memory() - Empty argument(s)!"}
     return
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

  # Create cell and set as current instance
  set hier_obj [create_bd_cell -type hier $nameHier]
  current_bd_instance $hier_obj

  # Create interface pins
  create_bd_intf_pin -mode MirroredMaster -vlnv xilinx.com:interface:lmb_rtl:1.0 DLMB

  create_bd_intf_pin -mode MirroredMaster -vlnv xilinx.com:interface:lmb_rtl:1.0 ILMB


  # Create pins
  create_bd_pin -dir I -type clk LMB_Clk
  create_bd_pin -dir I -type rst SYS_Rst

  # Create instance: dlmb_v10, and set properties
  set dlmb_v10 [ create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 dlmb_v10 ]

  # Create instance: ilmb_v10, and set properties
  set ilmb_v10 [ create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_v10:3.0 ilmb_v10 ]

  # Create instance: dlmb_bram_if_cntlr, and set properties
  set dlmb_bram_if_cntlr [ create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 dlmb_bram_if_cntlr ]
  set_property CONFIG.C_ECC {0} $dlmb_bram_if_cntlr


  # Create instance: ilmb_bram_if_cntlr, and set properties
  set ilmb_bram_if_cntlr [ create_bd_cell -type ip -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 ilmb_bram_if_cntlr ]
  set_property CONFIG.C_ECC {0} $ilmb_bram_if_cntlr


  # Create instance: lmb_bram, and set properties
  set lmb_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 lmb_bram ]
  set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.use_bram_block {BRAM_Controller} \
  ] $lmb_bram


  # Create interface connections
  connect_bd_intf_net -intf_net microblaze_0_dlmb [get_bd_intf_pins dlmb_v10/LMB_M] [get_bd_intf_pins DLMB]
  connect_bd_intf_net -intf_net microblaze_0_dlmb_bus [get_bd_intf_pins dlmb_v10/LMB_Sl_0] [get_bd_intf_pins dlmb_bram_if_cntlr/SLMB]
  connect_bd_intf_net -intf_net microblaze_0_dlmb_cntlr [get_bd_intf_pins dlmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTA]
  connect_bd_intf_net -intf_net microblaze_0_ilmb [get_bd_intf_pins ilmb_v10/LMB_M] [get_bd_intf_pins ILMB]
  connect_bd_intf_net -intf_net microblaze_0_ilmb_bus [get_bd_intf_pins ilmb_v10/LMB_Sl_0] [get_bd_intf_pins ilmb_bram_if_cntlr/SLMB]
  connect_bd_intf_net -intf_net microblaze_0_ilmb_cntlr [get_bd_intf_pins ilmb_bram_if_cntlr/BRAM_PORT] [get_bd_intf_pins lmb_bram/BRAM_PORTB]

  # Create port connections
  connect_bd_net -net SYS_Rst_1  [get_bd_pins SYS_Rst] \
  [get_bd_pins dlmb_v10/SYS_Rst] \
  [get_bd_pins dlmb_bram_if_cntlr/LMB_Rst] \
  [get_bd_pins ilmb_v10/SYS_Rst] \
  [get_bd_pins ilmb_bram_if_cntlr/LMB_Rst]
  connect_bd_net -net microblaze_0_Clk  [get_bd_pins LMB_Clk] \
  [get_bd_pins dlmb_v10/LMB_Clk] \
  [get_bd_pins dlmb_bram_if_cntlr/LMB_Clk] \
  [get_bd_pins ilmb_v10/LMB_Clk] \
  [get_bd_pins ilmb_bram_if_cntlr/LMB_Clk]

  # Restore current instance
  current_bd_instance $oldCurInst
}
  variable script_folder

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2090 -severity "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2091 -severity "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj


  # Create interface ports
  set clk_200_p [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 clk_200_p ]
  set_property -dict [ list \
   CONFIG.FREQ_HZ {200000000} \
   ] $clk_200_p


  # Create ports
  set lcd_cs [ create_bd_port -dir O lcd_cs ]
  set lcd_scl [ create_bd_port -dir O lcd_scl ]
  set lcd_sda [ create_bd_port -dir O lcd_sda ]
  set lcd_dc [ create_bd_port -dir O lcd_dc ]
  set lcd_blk [ create_bd_port -dir O -from 0 -to 0 lcd_blk ]
  set lcd_res [ create_bd_port -dir O -type rst lcd_res ]
  set ext_reset_in_0 [ create_bd_port -dir I -type rst ext_reset_in_0 ]
  set btn1_n [ create_bd_port -dir I btn1_n ]
  set btn2_n [ create_bd_port -dir I btn2_n ]
  # microSD in SPI mode: SD_CLK, SD_CMD (MOSI), SD_DATA0 (MISO), SD_DATA3 (CS)
  set sd_sck [ create_bd_port -dir O sd_sck ]
  set sd_mosi [ create_bd_port -dir O sd_mosi ]
  set sd_miso [ create_bd_port -dir I sd_miso ]
  set sd_cs_n [ create_bd_port -dir O -from 0 -to 0 sd_cs_n ]
  set led1 [ create_bd_port -dir O led1 ]
  set led2 [ create_bd_port -dir O led2 ]

  # Create instance: microblaze_0, and set properties
  set microblaze_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:microblaze:11.0 microblaze_0 ]
  set_property -dict [list \
    CONFIG.C_DEBUG_ENABLED {1} \
    CONFIG.C_D_AXI {1} \
    CONFIG.C_D_LMB {1} \
    CONFIG.C_ENABLE_CONVERSION {0} \
    CONFIG.C_I_LMB {1} \
  ] $microblaze_0


  # Create instance: microblaze_0_local_memory
  create_hier_cell_microblaze_0_local_memory [current_bd_instance .] microblaze_0_local_memory

  # Create instance: mdm_1, and set properties
  set mdm_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:mdm:3.2 mdm_1 ]

  # Create instance: clk_wiz_1, and set properties
  set clk_wiz_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_1 ]
  set_property -dict [list \
    CONFIG.CLKIN1_JITTER_PS {50.0} \
    CONFIG.CLKOUT1_JITTER {112.316} \
    CONFIG.CLKOUT1_PHASE_ERROR {89.971} \
    CONFIG.MMCM_CLKFBOUT_MULT_F {5.000} \
    CONFIG.MMCM_CLKIN1_PERIOD {5.000} \
    CONFIG.MMCM_CLKIN2_PERIOD {10.0} \
    CONFIG.PRIM_IN_FREQ {200.000} \
    CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
    CONFIG.RESET_PORT {resetn} \
    CONFIG.RESET_TYPE {ACTIVE_LOW} \
  ] $clk_wiz_1


  # Create instance: rst_clk_wiz_1_100M, and set properties
  set rst_clk_wiz_1_100M [ create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_clk_wiz_1_100M ]

  # Create instance: tft_top_0, and set properties
  set block_name tft_top
  set block_cell_name tft_top_0
  if { [catch {set tft_top_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $tft_top_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: axi_interconnect_0, and set properties
  set axi_interconnect_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0 ]
  set_property CONFIG.NUM_MI {5} $axi_interconnect_0

  # Create instance: iq_stream_top_0 (I/Q FIFO: MicroBlaze writes samples, M_AXIS -> dsp_top)
  set block_name iq_stream_top
  set block_cell_name iq_stream_top_0
  if { [catch {set iq_stream_top_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $iq_stream_top_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: dsp_top_0 (test generator, demodulator, FFT/waterfall, capture)
  set block_name dsp_top
  set block_cell_name dsp_top_0
  if { [catch {set dsp_top_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $dsp_top_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }

  # Create instance: axi_quad_spi_0 (SD card). Standard SPI, ext_spi_clk = AXI clock
  # (PG153: in standard mode ext_spi_clk must not be slower than the AXI clock),
  # SCK = 100 MHz / 16 = 6.25 MHz (16 is the largest ratio the core allows; the card
  # identification is specified at <= 400 kHz but cards accept it at this rate).
  set axi_quad_spi_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_quad_spi:3.2 axi_quad_spi_0 ]
  set_property -dict [list \
    CONFIG.C_SPI_MODE {0} \
    CONFIG.C_USE_STARTUP {0} \
    CONFIG.C_SCK_RATIO {16} \
    CONFIG.C_NUM_SS_BITS {1} \
    CONFIG.C_FIFO_DEPTH {16} \
  ] $axi_quad_spi_0


  # Create instance: xlconstant_0, and set properties
  set xlconstant_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_0 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0} \
    CONFIG.CONST_WIDTH {1} \
  ] $xlconstant_0


  # Create instance: system_ctrl_top_0, and set properties
  set block_name system_ctrl_top
  set block_cell_name system_ctrl_top_0
  if { [catch {set system_ctrl_top_0 [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2095 -severity "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   } elseif { $system_ctrl_top_0 eq "" } {
     catch {common::send_gid_msg -ssname BD::TCL -id 2096 -severity "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
   }
  
  # Create instance: xlconstant_1, and set properties
  set xlconstant_1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_1 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {1} \
    CONFIG.CONST_WIDTH {1} \
  ] $xlconstant_1


  # Create instance: xlconstant_rst0, and set properties
  set xlconstant_rst0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_rst0 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {0} \
    CONFIG.CONST_WIDTH {1} \
  ] $xlconstant_rst0


  # Create instance: xlconstant_rst1, and set properties
  set xlconstant_rst1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 xlconstant_rst1 ]
  set_property -dict [list \
    CONFIG.CONST_VAL {1} \
    CONFIG.CONST_WIDTH {1} \
  ] $xlconstant_rst1


  # Create interface connections
  connect_bd_intf_net -intf_net axi_interconnect_0_M00_AXI [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins tft_top_0/s_axi]
  connect_bd_intf_net -intf_net axi_interconnect_0_M01_AXI [get_bd_intf_pins axi_interconnect_0/M01_AXI] [get_bd_intf_pins system_ctrl_top_0/s_axi]
  connect_bd_intf_net -intf_net axi_interconnect_0_M02_AXI [get_bd_intf_pins axi_interconnect_0/M02_AXI] [get_bd_intf_pins axi_quad_spi_0/AXI_LITE]
  connect_bd_intf_net -intf_net axi_interconnect_0_M03_AXI [get_bd_intf_pins axi_interconnect_0/M03_AXI] [get_bd_intf_pins iq_stream_top_0/s_axi]
  connect_bd_intf_net -intf_net axi_interconnect_0_M04_AXI [get_bd_intf_pins axi_interconnect_0/M04_AXI] [get_bd_intf_pins dsp_top_0/s_axi]
  connect_bd_intf_net -intf_net iq_stream_top_0_M_AXIS [get_bd_intf_pins iq_stream_top_0/M_AXIS] [get_bd_intf_pins dsp_top_0/S_AXIS]
  connect_bd_intf_net -intf_net diff_clock_rtl_0_1 [get_bd_intf_ports clk_200_p] [get_bd_intf_pins clk_wiz_1/CLK_IN1_D]
  connect_bd_intf_net -intf_net microblaze_0_M_AXI_DP [get_bd_intf_pins microblaze_0/M_AXI_DP] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
  connect_bd_intf_net -intf_net microblaze_0_debug [get_bd_intf_pins mdm_1/MBDEBUG_0] [get_bd_intf_pins microblaze_0/DEBUG]
  connect_bd_intf_net -intf_net microblaze_0_dlmb_1 [get_bd_intf_pins microblaze_0/DLMB] [get_bd_intf_pins microblaze_0_local_memory/DLMB]
  connect_bd_intf_net -intf_net microblaze_0_ilmb_1 [get_bd_intf_pins microblaze_0/ILMB] [get_bd_intf_pins microblaze_0_local_memory/ILMB]

  # Create port connections
  connect_bd_net -net btn1_n_1  [get_bd_ports btn1_n] \
  [get_bd_pins system_ctrl_top_0/btn1_n]
  connect_bd_net -net btn2_n_1  [get_bd_ports btn2_n] \
  [get_bd_pins system_ctrl_top_0/btn2_n]
  connect_bd_net -net clk_wiz_1_locked  [get_bd_pins clk_wiz_1/locked]
  connect_bd_net -net ext_reset_in_0_1  [get_bd_ports ext_reset_in_0]
  connect_bd_net -net mdm_1_debug_sys_rst  [get_bd_pins mdm_1/Debug_SYS_Rst]
  connect_bd_net -net microblaze_0_Clk  [get_bd_pins clk_wiz_1/clk_out1] \
  [get_bd_pins microblaze_0/Clk] \
  [get_bd_pins microblaze_0_local_memory/LMB_Clk] \
  [get_bd_pins rst_clk_wiz_1_100M/slowest_sync_clk] \
  [get_bd_pins axi_interconnect_0/ACLK] \
  [get_bd_pins axi_interconnect_0/S00_ACLK] \
  [get_bd_pins tft_top_0/s_axi_aclk] \
  [get_bd_pins axi_interconnect_0/M00_ACLK] \
  [get_bd_pins axi_interconnect_0/M01_ACLK] \
  [get_bd_pins axi_interconnect_0/M02_ACLK]   [get_bd_pins axi_interconnect_0/M03_ACLK]   [get_bd_pins axi_interconnect_0/M04_ACLK]   [get_bd_pins iq_stream_top_0/s_axi_aclk]   [get_bd_pins dsp_top_0/s_axi_aclk] \
  [get_bd_pins axi_quad_spi_0/s_axi_aclk] \
  [get_bd_pins axi_quad_spi_0/ext_spi_clk] \
  [get_bd_pins system_ctrl_top_0/s_axi_aclk]
  connect_bd_net -net axi_quad_spi_0_sck_o  [get_bd_pins axi_quad_spi_0/sck_o] [get_bd_ports sd_sck]
  connect_bd_net -net axi_quad_spi_0_io0_o  [get_bd_pins axi_quad_spi_0/io0_o] [get_bd_ports sd_mosi]
  connect_bd_net -net sd_miso_1  [get_bd_ports sd_miso] [get_bd_pins axi_quad_spi_0/io1_i]
  connect_bd_net -net axi_quad_spi_0_ss_o  [get_bd_pins axi_quad_spi_0/ss_o] [get_bd_ports sd_cs_n]
  connect_bd_net -net system_ctrl_top_0_led1  [get_bd_pins system_ctrl_top_0/led1] [get_bd_ports led1]
  connect_bd_net -net system_ctrl_top_0_led2  [get_bd_pins system_ctrl_top_0/led2] [get_bd_ports led2]
  connect_bd_net -net rst_clk_wiz_1_100M_bus_struct_reset  [get_bd_pins rst_clk_wiz_1_100M/bus_struct_reset]
  connect_bd_net -net rst_clk_wiz_1_100M_mb_reset  [get_bd_pins rst_clk_wiz_1_100M/mb_reset]
  connect_bd_net -net rst_clk_wiz_1_100M_peripheral_aresetn  [get_bd_pins rst_clk_wiz_1_100M/peripheral_aresetn]
  connect_bd_net -net tft_top_0_tft_blk  [get_bd_pins tft_top_0/tft_blk] \
  [get_bd_ports lcd_blk]
  connect_bd_net -net tft_top_0_tft_cs_n  [get_bd_pins tft_top_0/tft_cs_n] \
  [get_bd_ports lcd_cs]
  connect_bd_net -net tft_top_0_tft_dc  [get_bd_pins tft_top_0/tft_dc] \
  [get_bd_ports lcd_dc]
  connect_bd_net -net tft_top_0_tft_mosi  [get_bd_pins tft_top_0/tft_mosi] \
  [get_bd_ports lcd_sda]
  connect_bd_net -net tft_top_0_tft_rst_n  [get_bd_pins tft_top_0/tft_rst_n] \
  [get_bd_ports lcd_res]
  connect_bd_net -net tft_top_0_tft_sclk  [get_bd_pins tft_top_0/tft_sclk] \
  [get_bd_ports lcd_scl]
  connect_bd_net -net xlconstant_0_dout  [get_bd_pins xlconstant_0/dout] \
  [get_bd_pins tft_top_0/tft_miso] \
  [get_bd_pins rst_clk_wiz_1_100M/ext_reset_in] \
  [get_bd_pins rst_clk_wiz_1_100M/aux_reset_in] \
  [get_bd_pins rst_clk_wiz_1_100M/mb_debug_sys_rst] \
  [get_bd_pins microblaze_0/Reset] \
  [get_bd_pins microblaze_0_local_memory/SYS_Rst]
  connect_bd_net -net xlconstant_1_dout  [get_bd_pins xlconstant_1/dout] \
  [get_bd_pins axi_interconnect_0/ARESETN] \
  [get_bd_pins axi_interconnect_0/S00_ARESETN] \
  [get_bd_pins axi_interconnect_0/M00_ARESETN] \
  [get_bd_pins axi_interconnect_0/M01_ARESETN] \
  [get_bd_pins axi_interconnect_0/M02_ARESETN]   [get_bd_pins axi_interconnect_0/M03_ARESETN]   [get_bd_pins axi_interconnect_0/M04_ARESETN]   [get_bd_pins iq_stream_top_0/s_axi_aresetn]   [get_bd_pins dsp_top_0/s_axi_aresetn] \
  [get_bd_pins axi_quad_spi_0/s_axi_aresetn] \
  [get_bd_pins tft_top_0/s_axi_aresetn] \
  [get_bd_pins system_ctrl_top_0/s_axi_aresetn]
  connect_bd_net -net xlconstant_rst0_dout  [get_bd_pins xlconstant_rst0/dout]
  connect_bd_net -net xlconstant_rst1_dout  [get_bd_pins xlconstant_rst1/dout] \
  [get_bd_pins rst_clk_wiz_1_100M/dcm_locked] \
  [get_bd_pins clk_wiz_1/resetn]

  # Create address segments
  assign_bd_address -offset 0x00000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs microblaze_0_local_memory/dlmb_bram_if_cntlr/SLMB/Mem] -force
  assign_bd_address -offset 0x44A20000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs axi_quad_spi_0/AXI_LITE/Reg] -force
  assign_bd_address -offset 0x44A10000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs system_ctrl_top_0/s_axi/reg0] -force
  assign_bd_address -offset 0x44A30000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs iq_stream_top_0/s_axi/reg0] -force
  assign_bd_address -offset 0x44A40000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs dsp_top_0/s_axi/reg0] -force
  assign_bd_address -offset 0x00010000 -range 0x00001000 -target_address_space [get_bd_addr_spaces microblaze_0/Data] [get_bd_addr_segs tft_top_0/s_axi/reg0] -force
  assign_bd_address -offset 0x00000000 -range 0x00010000 -target_address_space [get_bd_addr_spaces microblaze_0/Instruction] [get_bd_addr_segs microblaze_0_local_memory/ilmb_bram_if_cntlr/SLMB/Mem] -force


  # Restore current instance
  current_bd_instance $oldCurInst

  validate_bd_design
  save_bd_design
  close_bd_design $design_name 
}
# End of cr_bd_microblaze()

cr_bd_microblaze ""
