#==============================================================================
# sim.tcl -- запуск симуляції тестбенча в xsim.
#
# Топ симуляції береться з першого .sv у vivado/sources/tb, або з
# змінної ::sim_top, якщо вона задана.
#==============================================================================

set script_dir [file normalize [file dirname [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set tb_dir     "$root_dir/vivado/sources/tb"

if {![info exists ::sim_top]} {
    set tbs [glob -nocomplain "$tb_dir/*.sv"]
    if {[llength $tbs] == 0} {
        puts "ERROR: у $tb_dir немає тестбенчів"
        exit 1
    }
    set ::sim_top [file rootname [file tail [lindex $tbs 0]]]
}

puts "INFO: симуляція, топ = $::sim_top"
set_property top $::sim_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation
run all

puts "INFO: симуляція завершена"
