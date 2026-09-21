set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ROOT_DIR   [file normalize "$SCRIPT_DIR/.."]

set ELF_FILE \
    "$ROOT_DIR/vitis/app_component/build/app_component.elf"

if {![file exists $ELF_FILE]} {
    puts "ERROR: ELF does not exist:"
    puts "       $ELF_FILE"
    exit 1
}

puts ""
puts "=========================================="
puts "Loading MicroBlaze ELF"
puts "=========================================="

puts "ELF:"
puts "  $ELF_FILE"

puts ""
puts "Connecting to hardware..."

connect

puts ""
puts "Available targets:"
targets

puts ""
puts "Selecting MicroBlaze..."

# Select the actual MicroBlaze CPU, not the MicroBlaze Debug Module.
targets -set -filter {name =~ "MicroBlaze #0*"}

puts ""
puts "MicroBlaze status:"
targets

puts ""
puts "Resetting MicroBlaze..."

rst

puts ""
puts "Downloading ELF..."

dow $ELF_FILE

puts ""
puts "Starting MicroBlaze..."

con

rst

dow $ELF_FILE