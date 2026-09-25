################################################################
# Create Vivado project
#
# Directory structure:
#
# DF5/
# ├── scripts/
# │   └── project.tcl
# ├── sources/
# │   └── rtl/
# │       ├── gpio_logic.sv
# │       └── top_gpio.v
# ├── constraints/
# │   └── Artix-7-XC735T.xdc
# └── project/
#
################################################################

set project_name DF5_project
set project_dir "../project"
set part_name xc7a35tfgg484-2

set rtl_dir "../sources/rtl"
set xdc_dir "../constraints"

################################################################
# Remove old project
################################################################

if {[file exists $project_dir]} {
    puts ""
    puts "Removing existing project directory:"
    puts "  [file normalize $project_dir]"
    puts ""

    file delete -force $project_dir
}

################################################################
# Create project
################################################################

puts ""
puts "=========================================="
puts "Creating Vivado project"
puts "=========================================="
puts ""

create_project \
    $project_name \
    $project_dir \
    -part $part_name

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

################################################################
# Check RTL directory
################################################################

if {![file exists $rtl_dir]} {
    puts "ERROR: RTL directory does not exist:"
    puts "  [file normalize $rtl_dir]"
    exit 1
}

puts ""
puts "RTL directory:"
puts "  [file normalize $rtl_dir]"
puts ""

################################################################
# Add gpio_logic.sv
################################################################

set gpio_logic_file [file join $rtl_dir gpio_logic.sv]

if {[file exists $gpio_logic_file]} {

    puts "Adding source:"
    puts "  [file normalize $gpio_logic_file]"

    add_files -norecurse $gpio_logic_file

} else {

    puts "ERROR: File not found:"
    puts "  [file normalize $gpio_logic_file]"
    exit 1
}

################################################################
# Add top_gpio.v
################################################################

set top_gpio_file [file join $rtl_dir top_gpio.v]

if {[file exists $top_gpio_file]} {

    puts "Adding source:"
    puts "  [file normalize $top_gpio_file]"

    add_files -norecurse $top_gpio_file

} else {

    puts "ERROR: File not found:"
    puts "  [file normalize $top_gpio_file]"
    exit 1
}

################################################################
# Add constraints
################################################################

set xdc_file [file join $xdc_dir Artix-7-XC735T.xdc]

if {[file exists $xdc_file]} {

    puts ""
    puts "Adding constraints:"
    puts "  [file normalize $xdc_file]"

    add_files \
        -fileset constrs_1 \
        -norecurse \
        $xdc_file

} else {

    puts "ERROR: Constraint file not found:"
    puts "  [file normalize $xdc_file]"
    exit 1
}

################################################################
# Update compile order
################################################################

update_compile_order -fileset sources_1

################################################################
# Print sources
################################################################

puts ""
puts "=========================================="
puts "Project sources"
puts "=========================================="
puts ""

set source_files [get_files -quiet -of_objects [get_filesets sources_1]]

foreach f $source_files {
    puts "  [file normalize $f]"
}

################################################################
# Print constraints
################################################################

puts ""
puts "=========================================="
puts "Constraint files"
puts "=========================================="
puts ""

set constraint_files [get_files -quiet -of_objects [get_filesets constrs_1]]

foreach f $constraint_files {
    puts "  [file normalize $f]"
}

################################################################
# Project creation complete
################################################################

puts ""
puts "=========================================="
puts "Project creation complete"
puts "=========================================="
puts ""

puts "Project:"
puts "  [file normalize $project_dir/$project_name.xpr]"
puts ""

puts "Sources:"
puts "  [file normalize $gpio_logic_file]"
puts "  [file normalize $top_gpio_file]"
puts ""

puts "Constraints:"
puts "  [file normalize $xdc_file]"
puts ""

close_project