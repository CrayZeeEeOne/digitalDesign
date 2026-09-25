# ============================================================
# build.tcl
#
# Runs:
#   1. Synthesis
#   2. Implementation
#   3. Bitstream
#   4. XSA generation
#
# Run from:
#   scripts/
#
# Requires:
#   ../project/DF5_project.xpr
#   design_1.bd
#   design_1_wrapper.v
# ============================================================


puts "=========================================="
puts "Opening Vivado Project"
puts "=========================================="


# ------------------------------------------------------------
# Open project
# ------------------------------------------------------------

set project_path "../project/DF5_project.xpr"

if {![file exists $project_path]} {
    puts "ERROR: Vivado project does not exist:"
    puts "       [file normalize $project_path]"
    exit 1
}

open_project $project_path


# ------------------------------------------------------------
# Update compile order
# ------------------------------------------------------------

update_compile_order -fileset sources_1


# ============================================================
# SYNTHESIS
# ============================================================

puts ""
puts "=========================================="
puts "Starting Synthesis"
puts "=========================================="


reset_run synth_1

launch_runs synth_1 -jobs 8

wait_on_run synth_1


set synth_status [get_property STATUS [get_runs synth_1]]

puts "Synthesis status: $synth_status"


if {$synth_status ne "synth_design Complete!"} {
    puts "ERROR: Synthesis failed."
    exit 1
}


# ============================================================
# OPEN SYNTHESIZED DESIGN
# ============================================================

puts ""
puts "=========================================="
puts "Opening Synthesized Design"
puts "=========================================="


open_run synth_1


# ============================================================
# SYNTHESIS REPORT
# ============================================================

puts ""
puts "=========================================="
puts "Generating Synthesis Reports"
puts "=========================================="


file mkdir "../reports"


report_utilization \
    -file "../reports/utilization_synth.rpt"


report_timing_summary \
    -file "../reports/timing_synth.rpt"


close_design


# ============================================================
# IMPLEMENTATION
# ============================================================

puts ""
puts "=========================================="
puts "Starting Implementation"
puts "=========================================="


reset_run impl_1

launch_runs impl_1 -to_step write_bitstream -jobs 8

wait_on_run impl_1


set impl_status [get_property STATUS [get_runs impl_1]]

puts "Implementation status: $impl_status"


if {$impl_status ne "write_bitstream Complete!"} {
    puts "ERROR: Implementation / bitstream generation failed."
    exit 1
}


# ============================================================
# OPEN IMPLEMENTED DESIGN
# ============================================================

puts ""
puts "=========================================="
puts "Opening Implemented Design"
puts "=========================================="


open_run impl_1


# ============================================================
# IMPLEMENTATION REPORTS
# ============================================================

puts ""
puts "=========================================="
puts "Generating Implementation Reports"
puts "=========================================="


report_utilization \
    -file "../reports/utilization_impl.rpt"


report_timing_summary \
    -file "../reports/timing_impl.rpt"


report_power \
    -file "../reports/power.rpt"


# ============================================================
# BITSTREAM
# ============================================================

puts ""
puts "=========================================="
puts "Bitstream generated"
puts "=========================================="


set bit_file [get_property BITSTREAM.FILE [current_design]]

puts "Bitstream:"
puts "  $bit_file"


# ============================================================
# XSA
# ============================================================

puts ""
puts "=========================================="
puts "Generating XSA"
puts "=========================================="


set xsa_file "../project/DF5_project.xsa"


write_hw_platform \
    -fixed \
    -include_bit \
    -force \
    -file $xsa_file


puts ""
puts "XSA:"
puts "  [file normalize $xsa_file]"


# ============================================================
# CLOSE
# ============================================================

close_design

close_project


puts ""
puts "=========================================="
puts "BUILD COMPLETED SUCCESSFULLY"
puts "=========================================="