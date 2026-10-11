# Wrapper: build/update project, then run selected stage from argv.
set script_dir [file dirname [info script]]
source [file join $script_dir build.tcl]

if {[llength $argv] > 0} {
    set ::stage [lindex $argv 0]
} else {
    set ::stage "all"
}
source [file join $script_dir run.tcl]
