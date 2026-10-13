#==============================================================================
# run_board.tcl -- load bitstream + ELF over JTAG and run MicroBlaze.
#
#   bitstream: vivado/project/*.runs/impl_1/*.bit   (scripts/build.bat -all)
#   firmware:  vitis/elf/df5_app.elf                 (scripts/build_elf.bat)
#
# No XSA needed: the MicroBlaze target is picked by its JTAG name.
#==============================================================================

set script_dir [file normalize [file dirname [info script]]]
set root_dir   [file normalize "$script_dir/.."]

set bit_list [glob -nocomplain "$root_dir/vivado/project/*.runs/impl_1/*.bit"]
if {[llength $bit_list] == 0} {
    puts "ERROR: bitstream not found in vivado/project/*.runs/impl_1"
    puts "       Run scripts/build.bat -all first."
    exit 1
}
set bit [lindex $bit_list 0]

set elf "$root_dir/vitis/elf/df5_app.elf"
if {![file exists $elf]} {
    puts "ERROR: firmware not found: $elf"
    puts "       Run scripts/build_elf.bat first."
    exit 1
}

puts "INFO: bit       = $bit"
puts "INFO: elf       = $elf"
puts "INFO: connecting to hardware server"

connect

targets -set -nocase -filter {name =~ "*xc7*"}
fpga -file $bit
after 1200
catch {rst -system}

targets -set -nocase -filter {name =~ "MicroBlaze #0*"}
if {[catch {rst -processor} rst_err]} {
    puts "WARNING: rst -processor failed: $rst_err"
}

if {[catch {dow $elf} dow_err]} {
    puts "ERROR: dow failed: $dow_err"
    puts "TIP: ensure board reset button is released and JTAG target is visible."
    exit 1
}

con
puts "INFO: Board is running"
