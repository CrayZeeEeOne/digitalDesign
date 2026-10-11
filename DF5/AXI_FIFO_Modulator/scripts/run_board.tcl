#==============================================================================
# run_board.tcl -- load bitstream + ELF to board and run MicroBlaze.
#==============================================================================

set script_dir [file normalize [file dirname [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set vitis_dir  "$root_dir/vitis"
set ws_dir     "$vitis_dir/workspace_cli"
set app_name   "df5_app"

set xsa_list [glob -nocomplain "$vitis_dir/platform/*.xsa"]
if {[llength $xsa_list] == 0} {
    puts "ERROR: XSA not found in $vitis_dir/platform"
    puts "       Run scripts/build.bat -all first."
    exit 1
}
set xsa [lindex $xsa_list 0]

set bit_list [glob -nocomplain "$root_dir/vivado/project/*.runs/impl_1/*.bit"]
if {[llength $bit_list] == 0} {
    puts "ERROR: bitstream not found in vivado/project/*runs/impl_1"
    puts "       Run scripts/build.bat -impl (or -all) first."
    exit 1
}
set bit [lindex $bit_list 0]

puts "INFO: workspace = $ws_dir"
puts "INFO: xsa       = $xsa"
puts "INFO: bit       = $bit"

set proc_list_raw [string trim [getprocessors $xsa]]
if {$proc_list_raw eq ""} {
    puts "ERROR: no processor found in XSA"
    exit 1
}
set proc_list [split $proc_list_raw]
set proc_name ""
foreach p $proc_list {
    if {[string match -nocase "*microblaze*" $p]} {
        set proc_name $p
        break
    }
}
if {$proc_name eq ""} {
    set proc_name [lindex $proc_list 0]
}
puts "INFO: processor = $proc_name"

set elf ""
set elf_candidates [list \
    "$vitis_dir/elf/$app_name.elf" \
    "$vitis_dir/elf/*.elf" \
    "$ws_dir/$app_name/Debug/$app_name.elf" \
    "$root_dir/vivado/project/*.gen/sources_1/bd/*/ip/*/data/mb_bootloop_le.elf" \
]
foreach pattern $elf_candidates {
    set found [glob -nocomplain $pattern]
    if {[llength $found] > 0} {
        set elf [lindex $found 0]
        break
    }
}
if {$elf eq ""} {
    puts "ERROR: ELF not found."
    puts "       Place app ELF into $vitis_dir/elf/$app_name.elf"
    puts "       or generate it in Vitis workspace."
    exit 1
}
if {[string match "*mb_bootloop_le.elf" $elf]} {
    puts "WARNING: using fallback bootloop ELF (no DF5 app ELF found)."
    puts "         Put app ELF at $vitis_dir/elf/$app_name.elf for full firmware run."
}
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
