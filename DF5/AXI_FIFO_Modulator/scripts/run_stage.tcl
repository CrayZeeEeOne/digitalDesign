# Wrapper: build/update project, then run selected stage from argv.
set script_dir [file dirname [info script]]
# second argument "bd": rebuild the Block Design from create_bd.tcl first
if {[lindex $argv 1] == "bd"} { set ::force_bd 1 }
source [file join $script_dir build.tcl]

if {[llength $argv] > 0} {
    set ::stage [lindex $argv 0]
} else {
    set ::stage "all"
}
source [file join $script_dir run.tcl]
