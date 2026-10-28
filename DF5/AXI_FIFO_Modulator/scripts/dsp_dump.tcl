#==============================================================================
# dsp_dump.tcl -- read the finished capture of dsp_top from the running board
# over JTAG, in the format of tb_dsp_top's dump, and print the DSP counters.
#
#   xsct dsp_dump.tcl [out_file]           (default: dsp_capture_dump.txt)
#   python ..\tools\check_dsp_capture.py ..\vivado\sources\sim_data\sim.iq dsp_capture_dump.txt
#
# The check is bit-exact when the capture replayed sim.iq from the SD card
# (SIM.IQ, the firmware does it when the file is there).
#==============================================================================
set out [expr {[llength $argv] > 0 ? [lindex $argv 0] : "dsp_capture_dump.txt"}]
set B 0x44A40000

connect
targets -set -nocase -filter {name =~ "MicroBlaze #0*"}

proc r {a} { return [mrd -value $a 1] }

puts "SOURCE [expr {[r [expr {$B + 0x200}]] & 1 ? "generator" : "S_AXIS (SD replay)"}]"
puts "DEMOD  packets [r [expr {$B + 0x04C}]], CRC OK [r [expr {$B + 0x050}]], CRC errors [r [expr {$B + 0x054}]]"
set st [r [expr {$B + 0x304}]]
puts [format "CAPTURE state %d, packets %d, waterfall rows %d" [expr {$st & 7}] [expr {($st >> 4) & 3}] [expr {($st >> 8) & 255}]]
if {($st & 7) != 4} { puts "WARNING: the capture is not finished yet" }

set f [open $out w]
puts $f "T0 [r [expr {$B + 0x31C}]]"
puts $f "LEN [r [expr {$B + 0x30C}]]"
puts $f "WF_SHIFT [expr {[r [expr {$B + 0x314}]] & 31}]"
puts $f "BIN0 [expr {[r [expr {$B + 0x348}]] & 255}]"
puts $f [format "STATUS %08x" $st]
for {set p 0} {$p < 2} {incr p} {
    set a [expr {$B + 0x320 + 16 * $p}]
    set line "PKT $p [r $a] [r [expr {$a + 4}]] [r [expr {$a + 8}]] [r [expr {$a + 12}]]"
    foreach w [mrd -value [expr {$B + 0x400 + 64 * $p}] 16] { append line [format " %08x" $w] }
    puts $f $line
}
set k 0
foreach w [mrd -value [expr {$B + 0x800}] 384] { puts $f [format "RAW %d %08x" $k $w]; incr k }
set k 0
foreach w [mrd -value [expr {$B + 0x8000}] 1280] { puts $f [format "WF %d %08x" $k $w]; incr k }
close $f
puts "dump -> $out"
