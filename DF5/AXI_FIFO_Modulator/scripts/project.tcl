# ============================================================
# project.tcl
#
# Creates Vivado project for AXI_FIFO_Modulator
#
# Run from:
#   AXI_FIFO_Modulator/scripts/
#
# ============================================================


# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT_DIR   [file normalize "$SCRIPT_DIR/.."]

set PROJECT_DIR     "$ROOT_DIR/project"
set SOURCES_DIR     "$ROOT_DIR/sources/rtl"
set CONSTRAINTS_DIR "$ROOT_DIR/constraints"


# ------------------------------------------------------------
# Project settings
# ------------------------------------------------------------

set PROJECT_NAME "DF5_project"
set PART         "xc7a35tfgg484-2"

set PROJECT_FILE "$PROJECT_DIR/$PROJECT_NAME.xpr"


# ------------------------------------------------------------
# Remove existing project
# ------------------------------------------------------------

if {[file exists $PROJECT_DIR]} {
    puts ""
    puts "=========================================="
    puts "Removing existing project"
    puts "=========================================="
    puts "Directory: $PROJECT_DIR"
    puts ""

    file delete -force $PROJECT_DIR
}

file mkdir $PROJECT_DIR


# ------------------------------------------------------------
# Create Vivado project
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Creating Vivado project"
puts "=========================================="
puts "Project : $PROJECT_NAME"
puts "Part    : $PART"
puts "Location: $PROJECT_DIR"
puts ""

create_project $PROJECT_NAME $PROJECT_DIR -part $PART


# ------------------------------------------------------------
# Project properties
# ------------------------------------------------------------

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]


# ------------------------------------------------------------
# Add RTL sources
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Adding RTL sources"
puts "=========================================="

if {![file exists $SOURCES_DIR]} {
    puts "ERROR: RTL sources directory does not exist:"
    puts "       $SOURCES_DIR"
    exit 1
}

set rtl_files {}

foreach pattern {*.v *.sv} {
    foreach file [glob -nocomplain -type f [file join $SOURCES_DIR $pattern]] {
        lappend rtl_files $file
    }
}

if {[llength $rtl_files] == 0} {
    puts "ERROR: No RTL sources found in:"
    puts "       $SOURCES_DIR"
    exit 1
}

foreach file $rtl_files {
    puts "Adding RTL: $file"
    add_files -fileset sources_1 $file
}


# ------------------------------------------------------------
# Add constraints
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Adding constraints"
puts "=========================================="

set XDC_FILE "$CONSTRAINTS_DIR/Artix-7-XC735T.xdc"

if {![file exists $XDC_FILE]} {
    puts "ERROR: Constraint file does not exist:"
    puts "       $XDC_FILE"
    exit 1
}

puts "Adding XDC: $XDC_FILE"

add_files -fileset constrs_1 $XDC_FILE


# ------------------------------------------------------------
# Update compile order
# ------------------------------------------------------------

update_compile_order -fileset sources_1


# ------------------------------------------------------------
# Done
# ------------------------------------------------------------

puts ""
puts "=========================================="
puts "Vivado project created successfully"
puts "=========================================="
puts ""
puts "Project file:"
puts "  $PROJECT_FILE"
puts ""

close_project