# Test replacements for the CCU extensions tclrega.so and tclrpc.so.
# Loaded by lib/hue.tcl when HUE_TEST is set. State lives in $HUE_TEST_DIR.

set ::hue_test_dir $::env(HUE_TEST_DIR)

proc ::hue_test_append {file line} {
	set fd [open [file join $::hue_test_dir $file] a]
	puts $fd $line
	close $fd
}

proc ::hue_test_read {file} {
	set f [file join $::hue_test_dir $file]
	if {![file exists $f]} { return "" }
	set fd [open $f r]
	set d [read $fd]
	close $fd
	return $d
}

# ReGa script: logged, system variables listed in sysvars.txt exist
proc rega_script {script} {
	::hue_test_append rega.log [string map {"\n" " " "\t" " "} $script]
	set out ""
	if {[regexp {dom\.GetObject\(\"([^\"]+)\"\); if \(s\) \{ Write\('1'\);} $script -> name]} {
		set out [expr {[lsearch -exact [split [::hue_test_read sysvars.txt] "\n"] $name] >= 0 ? "1" : "0"}]
	} elseif {[string match "*HssType()*" $script]} {
		set out "VIR-LG-RGBW-DIM"
	}
	return [list STDOUT $out]
}

# XML-RPC to CUxD: devices from cuxd_devices.txt, one per line: <address> <command>
proc xmlrpc {url method args} {
	set devices [list]
	foreach line [split [::hue_test_read cuxd_devices.txt] "\n"] {
		set line [string trim $line]
		if {$line == ""} { continue }
		set addr [lindex [split $line " "] 0]
		set cmd [string range $line [expr {[string length $addr] + 1}] end]
		lappend devices $addr $cmd
	}
	switch -- $method {
		listDevices {
			set out [list]
			foreach {addr cmd} $devices { lappend out [list ADDRESS $addr] }
			return $out
		}
		getParamset {
			set addr [lindex [lindex $args 0] 1]
			foreach {a cmd} $devices {
				if {[string equal $a $addr]} {
					return [list CMD_LONG $cmd CMD_EXEC $cmd]
				}
			}
			return [list]
		}
		default {
			::hue_test_append xmlrpc.log "$method $args"
			return ""
		}
	}
}
