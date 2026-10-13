#==============================================================================
# run.tcl -- етапи потоку: синтез, implementation, bitstream, експорт XSA.
#
# Який етап виконувати, задає змінна ::stage, яку встановлює build.bat:
#   syn | impl | bit | xsa | all
#
# Викликається з build.bat, не напряму.
#==============================================================================

set script_dir [file normalize [file dirname [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set vivado_dir "$root_dir/vivado"
set vitis_dir  "$root_dir/vitis"
set proj_name  "DF5_project"
set proj_dir   "$vivado_dir/project"

if {![info exists ::stage]} { set ::stage "all" }

if {[current_project -quiet] eq ""} {
    open_project "$proj_dir/$proj_name.xpr"
}

set top_module [get_property top [get_filesets sources_1]]
puts "INFO: етап = $::stage, топ = $top_module"

#------------------------------------------------------------------ helpers --
proc wait_run {run_name} {
    wait_on_run $run_name
    set st [get_property STATUS [get_runs $run_name]]
    set pr [get_property PROGRESS [get_runs $run_name]]
    if {$pr != "100%"} {
        puts "ERROR: $run_name не завершився: $st ($pr)"
        puts "       лог: [get_property DIRECTORY [get_runs $run_name]]"
        exit 1
    }
    puts "INFO: $run_name OK"
}

proc do_synth {} {
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_run synth_1
}

proc do_impl {} {
    # Генерація бітстріму вмикається тут, а не окремим кроком:
    # так implementation і write_bitstream ідуть одним запуском.
    reset_run synth_1
    reset_run impl_1
    launch_runs impl_1 -to_step write_bitstream -jobs 4
    wait_run impl_1
}

proc do_xsa {} {
    global proj_dir proj_name vitis_dir top_module
    set impl_dir "$proj_dir/$proj_name.runs/impl_1"
    set bit "$impl_dir/${top_module}.bit"

    if {![file exists $bit]} {
        puts "ERROR: бітстрім не знайдено ($bit). Спершу -impl."
        exit 1
    }
    open_run impl_1
    file mkdir "$vitis_dir/platform"
    set xsa "$vitis_dir/platform/${top_module}.xsa"
    # -fixed -include_bit: XSA несе реальний бітстрім, тому Vitis
    # може прошити плату, а не лише згенерувати софт.
    write_hw_platform -fixed -include_bit -force $xsa
    puts "INFO: XSA -> $xsa"
}

#------------------------------------------------------------------ потік ----
switch -- $::stage {
    syn  { do_synth }
    impl { do_impl }
    bit  { do_impl }
    xsa  { do_xsa }
    all  { do_synth; do_impl; do_xsa }
    default {
        puts "ERROR: невідомий етап '$::stage'"
        exit 1
    }
}

puts "INFO: run.tcl завершено"

