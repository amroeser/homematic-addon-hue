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

# Scene variables: one file per variable, "value list" and "value" on two lines
proc ::hue_test_var_file {name} {
	return [file join $::hue_test_dir "scenevar_[string map {" " "_"} $name].txt"]
}
proc ::hue_test_var_read {name} {
	set f [::hue_test_var_file $name]
	if {![file exists $f]} { return "" }
	set fd [open $f r]
	set d [read $fd]
	close $fd
	return [split [string trim $d] "\n"]
}
proc ::hue_test_var_write {name list value} {
	set fd [open [::hue_test_var_file $name] w]
	puts $fd $list
	puts $fd $value
	close $fd
}

# CCU channels for "more lamps": STATE values in chan_states.txt ("<channel> true|false" per line),
# the candidate list as the ReGa script prints it in ccu_channels.txt
proc ::hue_test_extras {kind script} {
	array set S [::hue_test_read chan_states.txt]
	set out ""
	foreach line [split $script "\n"] {
		if {![regexp {GetObject\("([^"]+)\.STATE"\)} $line -> ch]} { continue }
		set cur "false"
		if {[info exists S($ch)]} { set cur $S($ch) }
		if {[string equal $kind "states"]} {
			append out "${ch}|${cur}\n"
		} elseif {[string equal $kind "names"]} {
			set name "Lamp ${ch}"
			foreach c [split [::hue_test_read ccu_channels.txt] "\n"] {
				set f [split $c "|"]
				if {[string equal [lindex $f 0] $ch]} { set name [lindex $f 5] }
			}
			append out "${ch}|${name}\n"
		} elseif {[string equal $kind "switch"] && [regexp {State\((true|false)\)} $line -> v]} {
			set S($ch) $v
		} elseif {[string equal $kind "correct"] && [regexp {!= (true|false)} $line -> v]} {
			if {![string equal $cur $v]} { set S($ch) $v; append out "${ch}\n" }
		}
	}
	set fd [open [file join $::hue_test_dir chan_states.txt] w]
	foreach k [array names S] { puts $fd "$k $S($k)" }
	close $fd
	return $out
}

# ReGa script: logged, system variables listed in sysvars.txt exist
proc rega_script {script} {
	::hue_test_append rega.log [string map {"\n" " " "\t" " "} $script]
	set out ""
	# Flow designer: programs from flows_dump.txt (one program per block "P|..."), catalog from flows_catalog.txt
	if {[regexp {^!hue:flows:dump} $script]} {
		set all [::hue_test_read flows_dump.txt]
		if {[regexp {foreach\(pid, "([0-9]+)"\)} $script -> only]} {
			set keep ""
			set on 0
			foreach line [split $all "\n"] {
				if {[string match "P|*" $line]} { set on [string match "P|${only}|*" $line] }
				if {$on} { append keep "$line\n" }
			}
			set all $keep
		}
		return [list STDOUT $all]
	}
	if {[regexp {^!hue:flows:catalog} $script]} { return [list STDOUT [::hue_test_read flows_catalog.txt]] }
	if {[regexp {^!hue:flows:create} $script]} { return [list STDOUT "ID|99001\n"] }
	if {[regexp {^!hue:flows:update} $script] && [regexp {GetObject\(([0-9]+)\)} $script -> id]} { return [list STDOUT "OK|$id\n"] }
	if {[regexp {^!hue:flows:delete} $script]} { return [list STDOUT "DEL|true\n"] }
	# Flow editor: save an existing program (id from the first GetObject) or a new one (99002)
	if {[regexp {^!hue:flows:save} $script]} {
		if {[regexp {object p = dom\.GetObject\(([0-9]+)\);} $script -> id]} { return [list STDOUT "OK|$id\n"] }
		return [list STDOUT "OK|99002\n"]
	}
	# Flow editor preview: fixed clock and sun times, "true" for every requested datapoint
	# except ids listed in flow_values.txt as "<dp> <value>"
	if {[regexp {^!hue:flows:values} $script]} {
		array set V [::hue_test_read flow_values.txt]
		set out "NOW|21:15:00|3\nSUN|07:36|16:52\n"
		# One datapoint per line (no regexp -all, Tcl 8.2)
		foreach line [split $script "\n"] {
			if {![regexp {dom\.GetObject\(([0-9]+)\)} $line -> dp]} { continue }
			if {[info exists V($dp)]} { append out "V|$dp|$V($dp)\n" } else { append out "V|$dp|true\n" }
		}
		return [list STDOUT $out]
	}
	if {[regexp {^!hue:flows:run} $script] && [regexp {GetObject\(([0-9]+)\)} $script -> id]} { return [list STDOUT "RUN|$id\n"] }
	if {[regexp {^!hue:extras:candidates} $script]} {
		return [list STDOUT [::hue_test_read ccu_channels.txt]]
	}
	if {[regexp {^!hue:extras:(states|names|switch|correct)} $script -> kind]} {
		return [list STDOUT [::hue_test_extras $kind $script]]
	}
	if {[regexp {^!hue:scenevar:get ([^\n]+)} $script -> name]} {
		set v [::hue_test_var_read $name]
		if {[llength $v] == 0} { ::hue_test_var_write $name "Aus" 0; set v [list "Aus" 0] }
		return [list STDOUT "[lindex $v 0]\n[lindex $v 1]"]
	}
	if {[regexp {^!hue:scenevar:list ([^\n]+)} $script -> name] && [regexp {ValueList\("([^"]*)"\)} $script -> list]} {
		set v [::hue_test_var_read $name]
		::hue_test_var_write $name $list [lindex $v 1]
		return [list STDOUT ""]
	}
	if {[regexp {^!hue:scenevar:set ([^\n]+) ([0-9]+)\n} $script -> name value]} {
		set v [::hue_test_var_read $name]
		::hue_test_var_write $name [lindex $v 0] $value
		return [list STDOUT ""]
	}
	if {[regexp {^!hue:scenevar:read} $script]} {
		foreach line [split $script "\n"] {
			if {[regexp {^!var (.+)$} $line -> name]} {
				set v [::hue_test_var_read $name]
				if {[llength $v] == 0} { append out "-\n" } else { append out "[lindex $v 1]\n" }
			}
		}
		return [list STDOUT $out]
	}
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
