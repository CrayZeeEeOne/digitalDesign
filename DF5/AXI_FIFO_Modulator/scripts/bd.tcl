set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT_DIR   [file normalize "$SCRIPT_DIR/.."]

set PROJECT_DIR  "$ROOT_DIR/project"
set PROJECT_NAME "DF5_project"
set PROJECT_FILE "$PROJECT_DIR/$PROJECT_NAME.xpr"

if {![file exists $PROJECT_FILE]} {
    puts "ERROR: Vivado project does not exist:"
    puts "       $PROJECT_FILE"
    exit 1
}

open_project $PROJECT_FILE

set BD_NAME "system"

puts ""
puts "=========================================="
puts "Creating Block Design"
puts "=========================================="

if {[llength [get_bd_designs -quiet $BD_NAME]] > 0} {
    open_bd_design \
        "$PROJECT_DIR/$PROJECT_NAME.srcs/sources_1/bd/$BD_NAME/$BD_NAME.bd"
} else {
    create_bd_design $BD_NAME
}

# ============================================================
# CLOCK
# ============================================================

if {[llength [get_bd_ports -quiet clk]] == 0} {
    create_bd_port -dir I -type clk -freq_hz 100000000 clk
}

# ============================================================
# RESET INPUT
# ============================================================

if {[llength [get_bd_ports -quiet resetn]] == 0} {
    create_bd_port -dir I -type rst resetn
    set_property CONFIG.POLARITY ACTIVE_LOW [get_bd_ports resetn]
}

# ============================================================
# RESET CONTROLLER
# ============================================================

if {[llength [get_bd_cells -quiet rst_clk]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:proc_sys_reset \
        rst_clk
}

# IMPORTANT:
# C_EXT_RESET_HIGH is read-only in this Vivado version.
# proc_sys_reset expects active-high ext_reset_in here.
# Therefore resetn is inverted before entering proc_sys_reset.

if {[llength [get_bd_cells -quiet reset_inv]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:util_vector_logic \
        reset_inv
}

set_property -dict [list \
    CONFIG.C_OPERATION {not} \
    CONFIG.C_SIZE {1} \
] [get_bd_cells reset_inv]

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins rst_clk/slowest_sync_clk]

connect_bd_net \
    [get_bd_ports resetn] \
    [get_bd_pins reset_inv/Op1]

connect_bd_net \
    [get_bd_pins reset_inv/Res] \
    [get_bd_pins rst_clk/ext_reset_in]

# ============================================================
# MICROBLAZE
# ============================================================

if {[llength [get_bd_cells -quiet microblaze_0]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:microblaze \
        microblaze_0
}

set_property -dict [list \
    CONFIG.C_I_LMB {1} \
    CONFIG.C_D_LMB {1} \
    CONFIG.C_I_AXI {0} \
    CONFIG.C_D_AXI {1} \
    CONFIG.C_USE_ICACHE {0} \
    CONFIG.C_USE_DCACHE {0} \
    CONFIG.C_USE_INTERRUPT {0} \
    CONFIG.C_DEBUG_ENABLED {1} \
    CONFIG.C_DEBUG_INTERFACE {0} \
] [get_bd_cells microblaze_0]

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins microblaze_0/Clk]

connect_bd_net \
    [get_bd_pins rst_clk/mb_reset] \
    [get_bd_pins microblaze_0/Reset]

# ============================================================
# MDM - MICROBLAZE DEBUG MODULE
# ============================================================

if {[llength [get_bd_cells -quiet mdm_0]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:mdm:3.2 \
        mdm_0
}

set_property -dict [list \
    CONFIG.C_USE_BSCAN {0} \
    CONFIG.C_MB_DBG_PORTS {1} \
    CONFIG.C_DEBUG_INTERFACE {0} \
] [get_bd_cells mdm_0]

connect_bd_intf_net \
    [get_bd_intf_pins microblaze_0/DEBUG] \
    [get_bd_intf_pins mdm_0/MBDEBUG_0]


# MDM SYSTEM RESET
connect_bd_net \
    [get_bd_pins mdm_0/Debug_SYS_Rst] \
    [get_bd_pins rst_clk/mb_debug_sys_rst]

# ============================================================
# AXI INTERCONNECT
# ============================================================

if {[llength [get_bd_cells -quiet axi_interconnect_0]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:axi_interconnect \
        axi_interconnect_0
}

set_property -dict [list \
    CONFIG.NUM_SI {1} \
    CONFIG.NUM_MI {2} \
] [get_bd_cells axi_interconnect_0]

# ============================================================
# GPIO 0
# ============================================================

if {[llength [get_bd_cells -quiet top_gpio_0]] == 0} {
    create_bd_cell \
        -type module \
        -reference top_gpio \
        top_gpio_0
}

# ============================================================
# GPIO 1
# ============================================================

if {[llength [get_bd_cells -quiet top_gpio_1]] == 0} {
    create_bd_cell \
        -type module \
        -reference top_gpio \
        top_gpio_1
}

# ============================================================
# AXI CONNECTIONS
# ============================================================

connect_bd_intf_net \
    [get_bd_intf_pins microblaze_0/M_AXI_DP] \
    [get_bd_intf_pins axi_interconnect_0/S00_AXI]

connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
    [get_bd_intf_pins top_gpio_0/s_axi]

connect_bd_intf_net \
    [get_bd_intf_pins axi_interconnect_0/M01_AXI] \
    [get_bd_intf_pins top_gpio_1/s_axi]

# ============================================================
# AXI CLOCKS
# ============================================================

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins axi_interconnect_0/ACLK]

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins axi_interconnect_0/S00_ACLK]

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins axi_interconnect_0/M00_ACLK]

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins axi_interconnect_0/M01_ACLK]

# ============================================================
# AXI RESETS
# ============================================================

connect_bd_net \
    [get_bd_pins rst_clk/interconnect_aresetn] \
    [get_bd_pins axi_interconnect_0/ARESETN]

connect_bd_net \
    [get_bd_pins rst_clk/interconnect_aresetn] \
    [get_bd_pins axi_interconnect_0/S00_ARESETN]

connect_bd_net \
    [get_bd_pins rst_clk/peripheral_aresetn] \
    [get_bd_pins axi_interconnect_0/M00_ARESETN]

connect_bd_net \
    [get_bd_pins rst_clk/peripheral_aresetn] \
    [get_bd_pins axi_interconnect_0/M01_ARESETN]

# ============================================================
# GPIO CLOCKS
# ============================================================

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins top_gpio_0/s_axi_aclk]

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins top_gpio_1/s_axi_aclk]

# ============================================================
# GPIO RESETS
# ============================================================

connect_bd_net \
    [get_bd_pins rst_clk/peripheral_aresetn] \
    [get_bd_pins top_gpio_0/s_axi_aresetn]

connect_bd_net \
    [get_bd_pins rst_clk/peripheral_aresetn] \
    [get_bd_pins top_gpio_1/s_axi_aresetn]

# ============================================================
# ILMB BRAM CONTROLLER
# ============================================================

if {[llength [get_bd_cells -quiet ilmb_bram_if_cntlr]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:lmb_bram_if_cntlr \
        ilmb_bram_if_cntlr
}

# ============================================================
# DLMB BRAM CONTROLLER
# ============================================================

if {[llength [get_bd_cells -quiet dlmb_bram_if_cntlr]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:lmb_bram_if_cntlr \
        dlmb_bram_if_cntlr
}

# ============================================================
# BRAM
# ============================================================

if {[llength [get_bd_cells -quiet lmb_bram]] == 0} {
    create_bd_cell \
        -type ip \
        -vlnv xilinx.com:ip:blk_mem_gen \
        lmb_bram
}

set_property -dict [list \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Write_Depth_A {16384} \
] [get_bd_cells lmb_bram]

# ============================================================
# LMB CONNECTIONS
# ============================================================

connect_bd_intf_net \
    [get_bd_intf_pins microblaze_0/ILMB] \
    [get_bd_intf_pins ilmb_bram_if_cntlr/SLMB]

connect_bd_intf_net \
    [get_bd_intf_pins microblaze_0/DLMB] \
    [get_bd_intf_pins dlmb_bram_if_cntlr/SLMB]

# ============================================================
# LMB CLOCKS
# ============================================================

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins ilmb_bram_if_cntlr/LMB_Clk]

connect_bd_net \
    [get_bd_ports clk] \
    [get_bd_pins dlmb_bram_if_cntlr/LMB_Clk]

# ============================================================
# LMB RESETS
# ============================================================

connect_bd_net \
    [get_bd_pins rst_clk/mb_reset] \
    [get_bd_pins ilmb_bram_if_cntlr/LMB_Rst]

connect_bd_net \
    [get_bd_pins rst_clk/mb_reset] \
    [get_bd_pins dlmb_bram_if_cntlr/LMB_Rst]

# ============================================================
# BRAM PORTS
# ============================================================

connect_bd_intf_net \
    [get_bd_intf_pins ilmb_bram_if_cntlr/BRAM_PORT] \
    [get_bd_intf_pins lmb_bram/BRAM_PORTA]

connect_bd_intf_net \
    [get_bd_intf_pins dlmb_bram_if_cntlr/BRAM_PORT] \
    [get_bd_intf_pins lmb_bram/BRAM_PORTB]

# ============================================================
# LED OUTPUTS
# ============================================================

if {[llength [get_bd_ports -quiet led1]] == 0} {
    create_bd_port -dir O led1
}

if {[llength [get_bd_ports -quiet led2]] == 0} {
    create_bd_port -dir O led2
}

connect_bd_net \
    [get_bd_pins top_gpio_0/led] \
    [get_bd_ports led1]

connect_bd_net \
    [get_bd_pins top_gpio_1/led] \
    [get_bd_ports led2]

# ============================================================
# ADDRESS ASSIGNMENT
# ============================================================

assign_bd_address

# ============================================================
# DEBUG CHECK
# ============================================================

puts ""
puts "=========================================="
puts "DEBUG CHECK"
puts "=========================================="

puts "MicroBlaze:"
puts "  [get_bd_cells microblaze_0]"

puts "MDM:"
puts "  [get_bd_cells mdm_0]"

puts "MicroBlaze DEBUG interface:"
puts "  [get_bd_intf_pins microblaze_0/DEBUG]"

puts "MDM MBDEBUG interface:"
puts "  [get_bd_intf_pins mdm_0/MBDEBUG_0]"

puts "DEBUG connection:"
puts "  [get_bd_intf_nets -of_objects [get_bd_intf_pins microblaze_0/DEBUG]]"

# ============================================================
# RESET CHECK
# ============================================================

puts ""
puts "=========================================="
puts "RESET CHECK"
puts "=========================================="

puts "C_EXT_RESET_HIGH:"
puts "  [get_property CONFIG.C_EXT_RESET_HIGH [get_bd_cells rst_clk]]"

puts "Reset port polarity:"
puts "  [get_property CONFIG.POLARITY [get_bd_ports resetn]]"

puts "Reset inverter:"
puts "  [get_bd_cells reset_inv]"

puts "Reset inverter operation:"
puts "  [get_property CONFIG.C_OPERATION [get_bd_cells reset_inv]]"

puts ""
puts "Reset path:"
puts "  resetn -> reset_inv -> rst_clk/ext_reset_in"

# ============================================================
# VALIDATE
# ============================================================

validate_bd_design

save_bd_design

puts ""
puts "=========================================="
puts "Block Design created successfully"
puts "=========================================="
puts ""

close_project