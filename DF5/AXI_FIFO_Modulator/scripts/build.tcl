#==============================================================================
# build.tcl -- створює (або перевідкриває) проєкт Vivado і додає всі джерела.
#
# Нічого не прописано вручну: скрипт сканує каталоги, тож новий .sv, .mem
# або .xdc підхоплюється автоматично, без правок тут.
#
# Block Design теж будується скриптом (create_bd.tcl), якщо збереженого
# .bd у vivado/sources/bd/ ще немає. Збережений .bd має пріоритет -- так
# ручні правки в GUI не губляться; щоб перегенерувати, запусти
# build.bat -bd.
#
# Викликається з build.bat, не напряму.
#==============================================================================

#------------------------------------------------------------------ параметри
set proj_name   "DF5_project"
set part_name   "xc7a35tfgg484-2"
set bd_name     "microblaze"
set top_module  "${bd_name}_wrapper"

#------------------------------------------- шляхи відносно кореня проєкту ---
set script_dir  [file normalize [file dirname [info script]]]
set root_dir    [file normalize "$script_dir/.."]
set vivado_dir  "$root_dir/vivado"
set rtl_dir     "$vivado_dir/sources/rtl"
set tb_dir      "$vivado_dir/sources/tb"
set bd_dir      "$vivado_dir/sources/bd"
set mem_dir     "$vivado_dir/sources/mem"
set xdc_dir     "$vivado_dir/constraints"
set proj_dir    "$vivado_dir/project"

# build.bat -bd -> перебудувати BD з нуля
if {![info exists ::force_bd]} { set ::force_bd 0 }

#------------------------------------------------- створення / відкриття -----
if {[file exists "$proj_dir/$proj_name.xpr"]} {
    puts "INFO: відкриваю наявний проєкт"
    open_project "$proj_dir/$proj_name.xpr"
} else {
    puts "INFO: створюю новий проєкт у $proj_dir"
    create_project $proj_name $proj_dir -part $part_name -force
    set_property target_language Verilog [current_project]
    set_property simulator_language Mixed [current_project]
}

#------------------------------------------------------------- RTL -----------
# Спершу прибираємо старі посилання, щоб видалені файли не висіли в проєкті.
# .bd і згенеровані обгортки не чіпаємо -- їх додає Vivado сам.
foreach f [get_files -quiet -of_objects [get_filesets sources_1]] {
    set ext [file extension $f]
    if {$ext in {.sv .v .vhd .mem}} {
        if {[string first "/bd/" $f] < 0 && [string first ".gen/" $f] < 0} {
            remove_files -quiet -fileset sources_1 $f
        }
    }
}

set rtl_files [concat \
    [glob -nocomplain "$rtl_dir/*.sv"] \
    [glob -nocomplain "$rtl_dir/*.v"]  \
    [glob -nocomplain "$rtl_dir/*.vhd"]]

if {[llength $rtl_files] > 0} {
    add_files -norecurse -fileset sources_1 $rtl_files
    puts "INFO: додано [llength $rtl_files] RTL-файлів"
} else {
    puts "WARNING: у $rtl_dir немає RTL-файлів"
}

# Тип файлу задаємо явно -- інакше Vivado парсить .sv як Verilog-2001
# і спотикається на always_ff, logic та інтерфейсах.
foreach f [glob -nocomplain "$rtl_dir/*.sv"] {
    set_property file_type SystemVerilog [get_files [file tail $f]]
}

#------------------------------------------------------------- .mem ----------
# Таблиці для $readmemh (NCO). Vivado шукає їх за іменем серед джерел
# проєкту -- і в синтезі, і в симуляції.
set mem_files [glob -nocomplain "$mem_dir/*.mem"]
if {[llength $mem_files] > 0} {
    add_files -norecurse -fileset sources_1 $mem_files
    puts "INFO: додано [llength $mem_files] .mem файлів"
}

update_compile_order -fileset sources_1

#------------------------------------------------------------- Block Design --
set saved_bd "$bd_dir/$bd_name/$bd_name.bd"

if {$::force_bd} {
    puts "INFO: -bd: перебудовую Block Design з нуля"
    foreach f [get_files -quiet "*$bd_name.bd"] { remove_files -quiet $f }
    foreach f [get_files -quiet "${bd_name}_wrapper.v"] { remove_files -quiet $f }
    if {[file exists "$bd_dir/$bd_name"]} { file delete -force "$bd_dir/$bd_name" }
}

if {[llength [get_files -quiet "*$bd_name.bd"]] == 0} {
    if {[file exists $saved_bd]} {
        puts "INFO: додаю збережений BD $saved_bd"
        add_files -norecurse -fileset sources_1 $saved_bd
    } else {
        puts "INFO: збереженого BD немає -- генерую скриптом create_bd.tcl"
        source "$script_dir/create_bd.tcl"
    }
}

# Обгортка генерується автоматично, якщо її ще немає
if {[llength [get_files -quiet "*$bd_name.bd"]] > 0} {
    set bd_file [get_files "*$bd_name.bd"]
    if {[file exists "$script_dir/patch_microblaze_bd_buttons.tcl"]} {
        source "$script_dir/patch_microblaze_bd_buttons.tcl"
    }
    if {[llength [get_files -quiet "${bd_name}_wrapper.v"]] == 0} {
        puts "INFO: генерую HDL-обгортку для $bd_name"
        set wrapper [make_wrapper -files $bd_file -top]
        add_files -norecurse $wrapper
    }
}

#------------------------------------------------------------- тестбенчі -----
foreach f [get_files -quiet -of_objects [get_filesets sim_1]] {
    if {[string first "/tb/" $f] >= 0} { remove_files -quiet -fileset sim_1 $f }
}
set tb_files [concat \
    [glob -nocomplain "$tb_dir/*.sv"] \
    [glob -nocomplain "$tb_dir/*.v"]]

if {[llength $tb_files] > 0} {
    add_files -norecurse -fileset sim_1 $tb_files
    foreach f [glob -nocomplain "$tb_dir/*.sv"] {
        set_property file_type SystemVerilog \
            [get_files -of_objects [get_filesets sim_1] [file tail $f]]
    }
    puts "INFO: додано [llength $tb_files] тестбенчів"
}

#------------------------------------------------------------- констрейнти ---
foreach f [get_files -quiet -of_objects [get_filesets constrs_1]] {
    remove_files -quiet -fileset constrs_1 $f
}

set xdc_files [glob -nocomplain "$xdc_dir/*.xdc"]
if {[llength $xdc_files] > 0} {
    add_files -norecurse -fileset constrs_1 $xdc_files
    puts "INFO: додано [llength $xdc_files] файлів констрейнтів"
} else {
    puts "WARNING: у $xdc_dir немає .xdc -- implementation впаде на DRC"
}

#------------------------------------------------------------- топ-модуль ----
if {[llength [get_files -quiet "${top_module}.v"]] > 0} {
    set_property top $top_module [get_filesets sources_1]
    puts "INFO: топ-модуль = $top_module"
} else {
    puts "WARNING: $top_module не знайдено, топ визначається автоматично"
}
update_compile_order -fileset sources_1

puts "INFO: build.tcl завершено"

