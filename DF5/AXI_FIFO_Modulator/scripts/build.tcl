set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT_DIR   [file normalize "$SCRIPT_DIR/.."]

set PROJECT_DIR  "$ROOT_DIR/project"
set PROJECT_NAME "DF5_project"
set PROJECT_FILE "$PROJECT_DIR/$PROJECT_NAME.xpr"

set BD_NAME "system"

if {![file exists $PROJECT_FILE]} {
    puts "ERROR: Vivado project does not exist:"
    puts "       $PROJECT_FILE"
    exit 1
}

puts ""
puts "=========================================="
puts "Opening Vivado project"
puts "=========================================="
puts ""

open_project $PROJECT_FILE

# --------------------------------------------------
# OPEN BLOCK DESIGN
# --------------------------------------------------

set BD_FILE "$PROJECT_DIR/$PROJECT_NAME.srcs/sources_1/bd/$BD_NAME/$BD_NAME.bd"

if {![file exists $BD_FILE]} {
    puts "ERROR: Block Design does not exist:"
    puts "       $BD_FILE"
    close_project
    exit 1
}

puts ""
puts "=========================================="
puts "Opening Block Design"
puts "=========================================="
puts ""

open_bd_design $BD_FILE

# --------------------------------------------------
# VALIDATE BLOCK DESIGN
# --------------------------------------------------

puts ""
puts "=========================================="
puts "Validating Block Design"
puts "=========================================="
puts ""

validate_bd_design
save_bd_design

# --------------------------------------------------
# CREATE HDL WRAPPER
# --------------------------------------------------

puts ""
puts "=========================================="
puts "Creating HDL wrapper"
puts "=========================================="
puts ""

set wrapper_file [make_wrapper -files [get_files $BD_FILE] -top]

puts "Wrapper:"
puts "  $wrapper_file"

# Add wrapper to project
add_files -norecurse $wrapper_file

# Get wrapper module name
set wrapper_name [file rootname [file tail $wrapper_file]]

puts ""
puts "Wrapper module:"
puts "  $wrapper_name"

# --------------------------------------------------
# SET TOP
# --------------------------------------------------

puts ""
puts "=========================================="
puts "Setting top module"
puts "=========================================="
puts ""

set_property top $wrapper_name [current_fileset]

puts "Top module:"
puts "  $wrapper_name"

# Update compile order
update_compile_order -fileset sources_1

# --------------------------------------------------
# SYNTHESIS
# --------------------------------------------------

puts ""
puts "=========================================="
puts "Running synthesis"
puts "=========================================="
puts ""

reset_run synth_1
launch_runs synth_1 -jobs 4

wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
puts ""

puts "Synthesis status:"
puts "  $synth_status"
puts ""

if {$synth_status ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed."
    close_project
    exit 1
}
puts ""

open_run synth_1

puts "=========================================="
puts "MDM SYNTHESIS CHECK"
puts "=========================================="

set mdm_cells [get_cells -hier -filter {REF_NAME =~ *mdm*}]

puts "MDM cells:"
foreach c $mdm_cells {
    puts "  $c"
}

puts "All cells containing mdm:"
foreach c [get_cells -hier *mdm*] {
    puts "  $c"
}

puts ""
puts "=========================================="
puts "Running implementation"
puts "=========================================="
puts ""

launch_runs impl_1 -to_step write_bitstream -jobs 4

wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]

puts ""
puts "Implementation status:"
puts "  $impl_status"
puts ""

if {$impl_status ne "write_bitstream Complete!"} {
    puts "ERROR: Implementation / bitstream generation failed."
    close_project
    exit 1
}

# --------------------------------------------------
# BITSTREAM PATH
# --------------------------------------------------

set BITSTREAM "$PROJECT_DIR/$PROJECT_NAME.runs/impl_1/system_wrapper.bit"

puts ""
puts "=========================================="
puts "Bitstream generated"
puts "=========================================="
puts ""

if {![file exists $BITSTREAM]} {
    puts "ERROR: Bitstream file was not found:"
    puts "       $BITSTREAM"
    close_project
    exit 1
}

puts "BITSTREAM:"
puts "  $BITSTREAM"

# --------------------------------------------------
# GENERATE XSA
# --------------------------------------------------

puts ""
puts "=========================================="
puts "Generating XSA"
puts "=========================================="
puts ""

set XSA_FILE "$PROJECT_DIR/$PROJECT_NAME.xsa"

write_hw_platform \
    -fixed \
    -include_bit \
    -force \
    -file $XSA_FILE

puts ""
puts "=========================================="
puts "XSA generated"
puts "=========================================="
puts ""

if {![file exists $XSA_FILE]} {
    puts "ERROR: XSA file was not found:"
    puts "       $XSA_FILE"
    close_project
    exit 1
}

puts "XSA:"
puts "  $XSA_FILE"

# --------------------------------------------------
# FINAL MESSAGE
# --------------------------------------------------

puts ""
puts "=========================================="
puts "BUILD SUCCESSFUL"
puts "=========================================="
puts ""
puts "Project:"
puts "  $PROJECT_FILE"
puts ""
puts "Bitstream:"
puts "  $BITSTREAM"
puts ""
puts "XSA:"
puts "  $XSA_FILE"
puts ""

close_project