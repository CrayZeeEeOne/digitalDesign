# Patch microblaze BD: add system_ctrl_top and expose btn1_n/btn2_n
set bd_name "microblaze"

if {[llength [get_files -quiet "*${bd_name}.bd"]] == 0} {
  puts "ERROR: ${bd_name}.bd not found in project"
  return -code error
}

open_bd_design [get_files "*${bd_name}.bd"]
current_bd_design $bd_name

set changed 0

if {[llength [get_bd_cells -quiet system_ctrl_top_0]] == 0} {
  if {[catch {create_bd_cell -type module -reference system_ctrl_top system_ctrl_top_0} err]} {
    puts "WARNING: cannot create module_ref system_ctrl_top: $err"
    return
  }
  set changed 1
}

if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins system_ctrl_top_0/s_axi]]] == 0} {
  set_property -dict [list CONFIG.NUM_MI {2}] [get_bd_cells axi_interconnect_0]
  connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M01_AXI] [get_bd_intf_pins system_ctrl_top_0/s_axi]
  if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_interconnect_0/M01_ACLK]]] == 0} {
    connect_bd_net [get_bd_pins clk_wiz_1/clk_out1] [get_bd_pins axi_interconnect_0/M01_ACLK]
  }
  if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins axi_interconnect_0/M01_ARESETN]]] == 0} {
    connect_bd_net [get_bd_pins rst_clk_wiz_1_100M/peripheral_aresetn] [get_bd_pins axi_interconnect_0/M01_ARESETN]
  }
  set changed 1
}

if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins system_ctrl_top_0/s_axi_aclk]]] == 0} {
  connect_bd_net [get_bd_pins clk_wiz_1/clk_out1] [get_bd_pins system_ctrl_top_0/s_axi_aclk]
  set changed 1
}

if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins system_ctrl_top_0/s_axi_aresetn]]] == 0} {
  connect_bd_net [get_bd_pins rst_clk_wiz_1_100M/peripheral_aresetn] [get_bd_pins system_ctrl_top_0/s_axi_aresetn]
  set changed 1
}

foreach p {btn1_n btn2_n} {
  if {[llength [get_bd_ports -quiet $p]] == 0} {
    create_bd_port -dir I $p
    set changed 1
  }
  if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins system_ctrl_top_0/$p]]] == 0} {
    connect_bd_net [get_bd_ports $p] [get_bd_pins system_ctrl_top_0/$p]
    set changed 1
  }
}
# Keep MicroBlaze out of permanent reset: tie proc_sys_reset ext_reset_in low.
set rst_ext_pin [get_bd_pins -quiet rst_clk_wiz_1_100M/ext_reset_in]
set const0_pin  [get_bd_pins -quiet xlconstant_0/dout]
if {$rst_ext_pin ne "" && $const0_pin ne ""} {
  set rst_nets [get_bd_nets -quiet -of_objects $rst_ext_pin]
  if {[llength $rst_nets] > 0} {
    foreach net $rst_nets {
      disconnect_bd_net $net $rst_ext_pin
    }
    set changed 1
  }
  if {[llength [get_bd_nets -quiet -of_objects $rst_ext_pin]] == 0} {
    connect_bd_net $const0_pin $rst_ext_pin
    set changed 1
  }
}

# Ensure proc_sys_reset auxiliary reset is deasserted (active-high input).
set rst_aux_pin [get_bd_pins -quiet rst_clk_wiz_1_100M/aux_reset_in]
if {$rst_aux_pin ne "" && $const0_pin ne ""} {
  set aux_nets [get_bd_nets -quiet -of_objects $rst_aux_pin]
  if {[llength $aux_nets] > 0} {
    foreach net $aux_nets {
      disconnect_bd_net $net $rst_aux_pin
    }
    set changed 1
  }
  if {[llength [get_bd_nets -quiet -of_objects $rst_aux_pin]] == 0} {
    connect_bd_net $const0_pin $rst_aux_pin
    set changed 1
  }
}

# Ensure debug reset is deasserted for standalone boot flow.
set rst_dbg_pin [get_bd_pins -quiet rst_clk_wiz_1_100M/mb_debug_sys_rst]
if {$rst_dbg_pin ne "" && $const0_pin ne ""} {
  set dbg_nets [get_bd_nets -quiet -of_objects $rst_dbg_pin]
  if {[llength $dbg_nets] > 0} {
    foreach net $dbg_nets {
      disconnect_bd_net $net $rst_dbg_pin
    }
    set changed 1
  }
  if {[llength [get_bd_nets -quiet -of_objects $rst_dbg_pin]] == 0} {
    connect_bd_net $const0_pin $rst_dbg_pin
    set changed 1
  }
}
# Ensure address assignment exists for MicroBlaze data space.
assign_bd_address

# Optional fixed address for repeatable software base-address.
catch {
  set seg [get_bd_addr_segs microblaze_0/Data/SEG_system_ctrl_top_0_reg0]
  set_property offset 0x44A10000 $seg
  set_property range  64K $seg
}

validate_bd_design
save_bd_design

puts "INFO: patch_microblaze_bd_buttons.tcl done (changed=$changed)"



