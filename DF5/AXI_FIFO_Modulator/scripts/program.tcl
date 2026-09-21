set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT_DIR   [file normalize "$SCRIPT_DIR/.."]

set PROJECT_DIR "$ROOT_DIR/project"

set BIT_FILE \
    "$PROJECT_DIR/DF5_project.runs/impl_1/system_wrapper.bit"

if {![file exists $BIT_FILE]} {
    puts "ERROR: Bitstream does not exist:"
    puts "       $BIT_FILE"
    exit 1
}

puts ""
puts "=========================================="
puts "Programming FPGA"
puts "=========================================="

puts "Bitstream:"
puts "  $BIT_FILE"

open_hw_manager

connect_hw_server

set targets [get_hw_targets *]

if {[llength $targets] == 0} {
    puts "ERROR: No JTAG targets found."
    exit 1
}

set target [lindex $targets 0]

current_hw_target $target
open_hw_target

set devices [get_hw_devices]

if {[llength $devices] == 0} {
    puts "ERROR: No FPGA device found."
    exit 1
}

set device [lindex $devices 0]

current_hw_device $device

puts ""
puts "Target:"
puts "  $target"

puts ""
puts "Device:"
puts "  $device"

set_property PROGRAM.FILE $BIT_FILE $device

puts ""
puts "Programming FPGA..."

program_hw_devices $device

puts ""
puts "=========================================="
puts "FPGA programmed successfully"
puts "=========================================="
puts ""

close_hw_target
disconnect_hw_server
close_hw_manager