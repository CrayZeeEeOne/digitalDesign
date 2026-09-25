################################################################
# Create Block Design
# Project: DF5_project
# Part: xc7a35tfgg484-2
# Vivado: 2025.2
################################################################

set design_name design_1

################################################################
# Open project
################################################################

set project_file "../project/DF5_project.xpr"

if {![file exists $project_file]} {
    puts "ERROR: Vivado project not found: $project_file"
    exit 1
}

open_project $project_file

puts ""
puts "=========================================="
puts "Creating Block Design: $design_name"
puts "=========================================="
puts ""

################################################################
# Remove old BD if it exists
################################################################

set old_bd [get_files -quiet "*${design_name}.bd"]

if {$old_bd ne ""} {
    puts "Removing existing Block Design..."
    remove_files $old_bd
}

################################################################
# Create Block Design
################################################################

create_bd_design $design_name
current_bd_design $design_name

################################################################
# External ports
################################################################

# Differential 100 MHz clock
set diff_clock_rtl_0 [create_bd_intf_port \
    -mode Slave \
    -vlnv xilinx.com:interface:diff_clock_rtl:1.0 \
    diff_clock_rtl_0]

set_property -dict [list \
    CONFIG.FREQ_HZ {100000000} \
] $diff_clock_rtl_0

# Active-low reset
set reset_rtl_0 [create_bd_port \
    -dir I \
    -type rst \
    reset_rtl_0]

set_property CONFIG.POLARITY {ACTIVE_LOW} $reset_rtl_0

# LEDs
set led_0 [create_bd_port -dir O led_0]
set led_1 [create_bd_port -dir O led_1]

################################################################
# MicroBlaze
################################################################

set microblaze_0 [create_bd_cell \
    -type ip \
    -vlnv xilinx.com:ip:microblaze:11.0 \
    microblaze_0]

set_property -dict [list \
    CONFIG.C_DEBUG_ENABLED {1} \
    CONFIG.C_D_AXI {1} \
    CONFIG.C_D_LMB {1} \
    CONFIG.C_ENABLE_CONVERSION {0} \
    CONFIG.C_I_LMB {1} \
] $microblaze_0

################################################################
# AXI Interconnect
################################################################

set axi_interconnect_0 [create_bd_cell \
    -type ip \
    -vlnv xilinx.com:ip:axi_interconnect:2.1 \
    axi_interconnect_0]

################################################################
# GPIO 0
################################################################

set block_name top_gpio
set block_cell_name top_gpio_0

if {[catch {
    set top_gpio_0 [create_bd_cell \
        -type module \
        -reference $block_name \
        $block_cell_name]
} errmsg]} {
    puts "ERROR: Unable to create top_gpio_0"
    puts $errmsg
    exit 1
}

################################################################
# GPIO 1
################################################################

set block_name top_gpio
set block_cell_name top_gpio_1

if {[catch {
    set top_gpio_1 [create_bd_cell \
        -type module \
        -reference $block_name \
        $block_cell_name]
} errmsg]} {
    puts "ERROR: Unable to create top_gpio_1"
    puts $errmsg
    exit 1
}

################################################################
# MicroBlaze Local Memory
################################################################

proc create_hier_cell_microblaze_0_local_memory { parentCell nameHier } {

    if {$parentCell eq "" || $nameHier eq ""} {
        puts "ERROR: Empty argument in create_hier_cell_microblaze_0_local_memory"
        return
    }

    set parentObj [get_bd_cells $parentCell]

    if {$parentObj eq ""} {
        puts "ERROR: Unable to find parent cell <$parentCell>"
        return
    }

    set parentType [get_property TYPE $parentObj]

    if {$parentType ne "hier"} {
        puts "ERROR: Parent <$parentObj> is not hierarchical"
        return
    }

    set oldCurInst [current_bd_instance .]

    current_bd_instance $parentObj

    ################################################################
    # Hierarchical cell
    ################################################################

    set hier_obj [create_bd_cell -type hier $nameHier]

    current_bd_instance $hier_obj

    ################################################################
    # Hierarchical interface pins
    ################################################################

    create_bd_intf_pin \
        -mode MirroredMaster \
        -vlnv xilinx.com:interface:lmb_rtl:1.0 \
        DLMB

    create_bd_intf_pin \
        -mode MirroredMaster \
        -vlnv xilinx.com:interface:lmb_rtl:1.0 \
        ILMB

    ################################################################
    # Hierarchical pins
    ################################################################

    create_bd_pin -dir I -type clk LMB_Clk
    create_bd_pin -dir I -type rst SYS_Rst

    ################################################################
    # LMB controllers
    ################################################################

    set dlmb_v10 [create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:lmb_v10:3.0 \
        dlmb_v10]

    set ilmb_v10 [create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:lmb_v10:3.0 \
        ilmb_v10]

    ################################################################
    # LMB BRAM controllers
    ################################################################

    set dlmb_bram_if_cntlr [create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 \
        dlmb_bram_if_cntlr]

    set_property CONFIG.C_ECC {0} $dlmb_bram_if_cntlr

    set ilmb_bram_if_cntlr [create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:lmb_bram_if_cntlr:4.0 \
        ilmb_bram_if_cntlr]

    set_property CONFIG.C_ECC {0} $ilmb_bram_if_cntlr

    ################################################################
    # BRAM
    ################################################################

    set lmb_bram [create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:blk_mem_gen:8.4 \
        lmb_bram]

    set_property -dict [list \
        CONFIG.Memory_Type {True_Dual_Port_RAM} \
        CONFIG.use_bram_block {BRAM_Controller} \
    ] $lmb_bram

    ################################################################
    # LMB interface connections
    ################################################################

    connect_bd_intf_net \
        -intf_net microblaze_0_dlmb \
        [get_bd_intf_pins dlmb_v10/LMB_M] \
        [get_bd_intf_pins DLMB]

    connect_bd_intf_net \
        -intf_net microblaze_0_dlmb_bus \
        [get_bd_intf_pins dlmb_v10/LMB_Sl_0] \
        [get_bd_intf_pins dlmb_bram_if_cntlr/SLMB]

    connect_bd_intf_net \
        -intf_net microblaze_0_dlmb_cntlr \
        [get_bd_intf_pins dlmb_bram_if_cntlr/BRAM_PORT] \
        [get_bd_intf_pins lmb_bram/BRAM_PORTA]

    connect_bd_intf_net \
        -intf_net microblaze_0_ilmb \
        [get_bd_intf_pins ilmb_v10/LMB_M] \
        [get_bd_intf_pins ILMB]

    connect_bd_intf_net \
        -intf_net microblaze_0_ilmb_bus \
        [get_bd_intf_pins ilmb_v10/LMB_Sl_0] \
        [get_bd_intf_pins ilmb_bram_if_cntlr/SLMB]

    connect_bd_intf_net \
        -intf_net microblaze_0_ilmb_cntlr \
        [get_bd_intf_pins ilmb_bram_if_cntlr/BRAM_PORT] \
        [get_bd_intf_pins lmb_bram/BRAM_PORTB]

    ################################################################
    # LMB reset
    ################################################################

    connect_bd_net \
        -net SYS_Rst_1 \
        [get_bd_pins SYS_Rst] \
        [get_bd_pins dlmb_v10/SYS_Rst] \
        [get_bd_pins dlmb_bram_if_cntlr/LMB_Rst] \
        [get_bd_pins ilmb_v10/SYS_Rst] \
        [get_bd_pins ilmb_bram_if_cntlr/LMB_Rst]

    ################################################################
    # LMB clock
    ################################################################

    connect_bd_net \
        -net microblaze_0_Clk \
        [get_bd_pins LMB_Clk] \
        [get_bd_pins dlmb_v10/LMB_Clk] \
        [get_bd_pins dlmb_bram_if_cntlr/LMB_Clk] \
        [get_bd_pins ilmb_v10/LMB_Clk] \
        [get_bd_pins ilmb_bram_if_cntlr/LMB_Clk]

    ################################################################
    # Restore current instance
    ################################################################

    current_bd_instance $oldCurInst
}

create_hier_cell_microblaze_0_local_memory \
    [current_bd_instance .] \
    microblaze_0_local_memory

################################################################
# MDM
################################################################

set mdm_1 [create_bd_cell \
    -type ip \
    -vlnv xilinx.com:ip:mdm:3.2 \
    mdm_1]

################################################################
# Clock Wizard
################################################################

set clk_wiz_1 [create_bd_cell \
    -type ip \
    -vlnv xilinx.com:ip:clk_wiz:6.0 \
    clk_wiz_1]

# IMPORTANT:
# This is the configuration generated by Vivado GUI
# for the differential clock input.
set_property CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} $clk_wiz_1

################################################################
# Processor System Reset
################################################################

set rst_clk_wiz_1_100M [create_bd_cell \
    -type ip \
    -vlnv xilinx.com:ip:proc_sys_reset:5.0 \
    rst_clk_wiz_1_100M]

################################################################
# AXI interface connections
################################################################

connect_bd_intf_net \
    -intf_net axi_interconnect_0_M00_AXI \
    [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
    [get_bd_intf_pins top_gpio_0/s_axi]

connect_bd_intf_net \
    -intf_net axi_interconnect_0_M01_AXI \
    [get_bd_intf_pins axi_interconnect_0/M01_AXI] \
    [get_bd_intf_pins top_gpio_1/s_axi]

################################################################
# Differential clock connection
#
# IMPORTANT:
# Do NOT use clk_in1_p / clk_in1_n here.
# The generated GUI design uses the diff_clock_rtl interface.
################################################################

connect_bd_intf_net \
    -intf_net diff_clock_rtl_0_1 \
    [get_bd_intf_ports diff_clock_rtl_0] \
    [get_bd_intf_pins clk_wiz_1/CLK_IN1_D]

################################################################
# MicroBlaze AXI
################################################################

connect_bd_intf_net \
    -intf_net microblaze_0_M_AXI_DP \
    [get_bd_intf_pins microblaze_0/M_AXI_DP] \
    [get_bd_intf_pins axi_interconnect_0/S00_AXI]

################################################################
# MicroBlaze debug
#
# No BSCAN IP here.
# MDM connects directly to MicroBlaze DEBUG interface.
################################################################

connect_bd_intf_net \
    -intf_net microblaze_0_debug \
    [get_bd_intf_pins mdm_1/MBDEBUG_0] \
    [get_bd_intf_pins microblaze_0/DEBUG]

################################################################
# MicroBlaze local memory
################################################################

connect_bd_intf_net \
    -intf_net microblaze_0_dlmb_1 \
    [get_bd_intf_pins microblaze_0/DLMB] \
    [get_bd_intf_pins microblaze_0_local_memory/DLMB]

connect_bd_intf_net \
    -intf_net microblaze_0_ilmb_1 \
    [get_bd_intf_pins microblaze_0/ILMB] \
    [get_bd_intf_pins microblaze_0_local_memory/ILMB]

################################################################
# Clock Wizard locked -> Processor System Reset
################################################################

connect_bd_net \
    -net clk_wiz_1_locked \
    [get_bd_pins clk_wiz_1/locked] \
    [get_bd_pins rst_clk_wiz_1_100M/dcm_locked]

################################################################
# MDM debug reset
#
# This is exactly the connection generated by the working GUI BD.
################################################################

connect_bd_net \
    -net mdm_1_debug_sys_rst \
    [get_bd_pins mdm_1/Debug_SYS_Rst] \
    [get_bd_pins rst_clk_wiz_1_100M/mb_debug_sys_rst] \
    [get_bd_pins clk_wiz_1/reset]

################################################################
# System clock
################################################################

connect_bd_net \
    -net microblaze_0_Clk \
    [get_bd_pins clk_wiz_1/clk_out1] \
    [get_bd_pins microblaze_0/Clk] \
    [get_bd_pins microblaze_0_local_memory/LMB_Clk] \
    [get_bd_pins rst_clk_wiz_1_100M/slowest_sync_clk] \
    [get_bd_pins axi_interconnect_0/ACLK] \
    [get_bd_pins axi_interconnect_0/S00_ACLK] \
    [get_bd_pins top_gpio_0/s_axi_aclk] \
    [get_bd_pins axi_interconnect_0/M00_ACLK] \
    [get_bd_pins top_gpio_1/s_axi_aclk] \
    [get_bd_pins axi_interconnect_0/M01_ACLK]

################################################################
# External reset
################################################################

connect_bd_net \
    -net reset_rtl_0_1 \
    [get_bd_ports reset_rtl_0] \
    [get_bd_pins rst_clk_wiz_1_100M/ext_reset_in]

################################################################
# MicroBlaze local memory reset
################################################################

connect_bd_net \
    -net rst_clk_wiz_1_100M_bus_struct_reset \
    [get_bd_pins rst_clk_wiz_1_100M/bus_struct_reset] \
    [get_bd_pins microblaze_0_local_memory/SYS_Rst]

################################################################
# MicroBlaze reset
################################################################

connect_bd_net \
    -net rst_clk_wiz_1_100M_mb_reset \
    [get_bd_pins rst_clk_wiz_1_100M/mb_reset] \
    [get_bd_pins microblaze_0/Reset]

################################################################
# AXI peripheral reset
################################################################

connect_bd_net \
    -net rst_clk_wiz_1_100M_peripheral_aresetn \
    [get_bd_pins rst_clk_wiz_1_100M/peripheral_aresetn] \
    [get_bd_pins axi_interconnect_0/ARESETN] \
    [get_bd_pins axi_interconnect_0/S00_ARESETN] \
    [get_bd_pins top_gpio_0/s_axi_aresetn] \
    [get_bd_pins axi_interconnect_0/M00_ARESETN] \
    [get_bd_pins top_gpio_1/s_axi_aresetn] \
    [get_bd_pins axi_interconnect_0/M01_ARESETN]

################################################################
# LED 0
################################################################

connect_bd_net \
    -net top_gpio_0_led \
    [get_bd_pins top_gpio_0/led] \
    [get_bd_ports led_0]

################################################################
# LED 1
################################################################

connect_bd_net \
    -net top_gpio_1_led \
    [get_bd_pins top_gpio_1/led] \
    [get_bd_ports led_1]

################################################################
# Address map
################################################################

# MicroBlaze local data memory
assign_bd_address \
    -offset 0x00000000 \
    -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces microblaze_0/Data] \
    [get_bd_addr_segs microblaze_0_local_memory/dlmb_bram_if_cntlr/SLMB/Mem] \
    -force

# GPIO 0
assign_bd_address \
    -offset 0x00010000 \
    -range 0x00001000 \
    -target_address_space [get_bd_addr_spaces microblaze_0/Data] \
    [get_bd_addr_segs top_gpio_0/s_axi/reg0] \
    -force

# GPIO 1
assign_bd_address \
    -offset 0x00004000 \
    -range 0x00001000 \
    -target_address_space [get_bd_addr_spaces microblaze_0/Data] \
    [get_bd_addr_segs top_gpio_1/s_axi/reg0] \
    -force

# MicroBlaze instruction memory
assign_bd_address \
    -offset 0x00000000 \
    -range 0x00004000 \
    -target_address_space [get_bd_addr_spaces microblaze_0/Instruction] \
    [get_bd_addr_segs microblaze_0_local_memory/ilmb_bram_if_cntlr/SLMB/Mem] \
    -force

################################################################
# Validate
################################################################

puts ""
puts "=========================================="
puts "Validating Block Design"
puts "=========================================="
puts ""

validate_bd_design

################################################################
# Save
################################################################

save_bd_design

################################################################
# Generate HDL wrapper
################################################################

puts ""
puts "=========================================="
puts "Generating HDL Wrapper"
puts "=========================================="
puts ""

set bd_file [get_files -quiet "*${design_name}.bd"]

if {$bd_file eq ""} {
    puts "ERROR: Block Design file not found"
    exit 1
}

make_wrapper \
    -files [list $bd_file] \
    -top

################################################################
# Add generated wrapper to project
################################################################

set wrapper_file "../project/DF5_project.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v"

if {[file exists $wrapper_file]} {
    add_files -norecurse $wrapper_file
} else {
    puts "WARNING: Generated wrapper was not found at:"
    puts $wrapper_file
}

################################################################
# Set top
################################################################

set_property top design_1_wrapper [current_fileset]

update_compile_order -fileset sources_1


puts ""
puts "=========================================="
puts "Block Design creation complete"
puts "=========================================="
puts ""
