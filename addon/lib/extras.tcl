#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2025-2026  Alexander Maximilian Röser
#
#  This program is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#  More lamps in a room: switch actuators of the CCU (HomeMatic, HomeMatic IP,
#  CUxD switches for Shelly and others) that follow a Hue room.
#
#  Stored in hue.conf, section "extras":
#    room_<bridge>_<room rid>   = {<channel> <mode>} ...   mode: both | off
#    scene_<bridge>_<scene rid> = {<channel> on|off} ...
#  <channel> is "<interface>.<address>:<channel>", e.g. HmIP-RF.00089D899E0F95:2
#
#  Runs on Tcl 8.2 (CCU3 firmware) up to 8.6.

namespace eval ::hue::extras {
	variable section "extras"
	# HomeMatic channel types that switch a load
	variable switch_types {SWITCH SWITCH_VIRTUAL_RECEIVER}
}

proc ::hue::extras::valid_channel {ch} {
	return [regexp {^[A-Za-z0-9\-]+\.[A-Za-z0-9\-]+:[0-9]+$} $ch]
}

proc ::hue::extras::valid_rid {rid} {
	return [regexp {^[0-9a-zA-Z\-]+$} $rid]
}

# All entries: list of {kind bridge rid entries}
proc ::hue::extras::all {} {
	variable section
	set out [list]
	::hue::acquire_lock $::hue::lock_id_ini_file
	set rc [catch {
		set ini [ini::open $::hue::ini_file r]
		if {[ini::exists $ini $section]} {
			foreach key [ini::keys $ini $section] {
				set parts [split $key "_"]
				if {[llength $parts] != 3} { continue }
				set v [ini::value $ini $section $key]
				if {[catch {llength $v}]} { continue }
				lappend out [list [lindex $parts 0] [string tolower [lindex $parts 1]] [lindex $parts 2] $v]
			}
		}
		ini::close $ini
	} err]
	::hue::release_lock $::hue::lock_id_ini_file
	if {$rc} { error $err }
	return $out
}

proc ::hue::extras::get {kind bridge_id rid} {
	foreach e [all] {
		if {[string equal [lindex $e 0] $kind] && [string equal [lindex $e 1] [string tolower $bridge_id]] && [string equal [lindex $e 2] $rid]} {
			return [lindex $e 3]
		}
	}
	return [list]
}

# Replace the entries of a room or scene; an empty list removes the key
proc ::hue::extras::put {kind bridge_id rid entries} {
	variable section
	set bridge_id [string tolower $bridge_id]
	if {[lsearch -exact {room scene} $kind] < 0 || ![regexp {^[0-9a-z]+$} $bridge_id] || ![valid_rid $rid]} {
		error "Invalid room or scene"
	}
	foreach e $entries {
		if {[llength $e] != 2 || ![valid_channel [lindex $e 0]] || [lsearch -exact {both off on} [lindex $e 1]] < 0} {
			error "Invalid entry ${e}"
		}
	}
	::hue::acquire_lock $::hue::lock_id_ini_file
	set rc [catch {
		set ini [ini::open $::hue::ini_file r+]
		set key "${kind}_${bridge_id}_${rid}"
		if {[llength $entries] == 0} {
			if {[ini::exists $ini $section $key]} { ini::delete $ini $section $key }
		} else {
			ini::set $ini $section $key $entries
		}
		ini::commit $ini
		ini::close $ini
	} err]
	::hue::release_lock $::hue::lock_id_ini_file
	if {$rc} { error $err }
}

# When the more lamps of a room follow it: all (every room switch, also Hue app and
# Hue switches), addon (only when switched through HomeMatic: addon page, CUxD,
# programs), none (only scenes). "all" is the default and not stored.
proc ::hue::extras::set_follow {bridge_id rid mode} {
	variable section
	set bridge_id [string tolower $bridge_id]
	if {![regexp {^[0-9a-z]+$} $bridge_id] || ![valid_rid $rid] || [lsearch -exact {all addon none} $mode] < 0} {
		error "Invalid room or mode"
	}
	::hue::acquire_lock $::hue::lock_id_ini_file
	set rc [catch {
		set ini [ini::open $::hue::ini_file r+]
		set key "follow_${bridge_id}_${rid}"
		if {[string equal $mode "all"]} {
			if {[ini::exists $ini $section $key]} { ini::delete $ini $section $key }
		} else {
			ini::set $ini $section $key $mode
		}
		ini::commit $ini
		ini::close $ini
	} err]
	::hue::release_lock $::hue::lock_id_ini_file
	if {$rc} { error $err }
}

# Add, change or remove (mode "") one channel of a room or scene
proc ::hue::extras::set_entry {kind bridge_id rid channel mode} {
	set out [list]
	set done 0
	foreach e [get $kind $bridge_id $rid] {
		if {[string equal [lindex $e 0] $channel]} {
			set done 1
			if {$mode != ""} { lappend out [list $channel $mode] }
		} else {
			lappend out $e
		}
	}
	if {!$done && $mode != ""} { lappend out [list $channel $mode] }
	put $kind $bridge_id $rid $out
	# A channel removed from a room is removed from the scenes as well
	if {[string equal $kind "room"] && $mode == ""} {
		foreach e [all] {
			if {[string equal [lindex $e 0] "scene"] && [string equal [lindex $e 1] [string tolower $bridge_id]]} {
				set keep [list]
				foreach s [lindex $e 3] {
					if {![string equal [lindex $s 0] $channel]} { lappend keep $s }
				}
				if {[llength $keep] != [llength [lindex $e 3]]} { put scene $bridge_id [lindex $e 2] $keep }
			}
		}
	}
}

# ---------------------------------------------------------------------------
# CCU side (ReGa)
# ---------------------------------------------------------------------------

proc ::hue::extras::rega {script} {
	array set r [rega_script $script]
	if {[info exists r(STDOUT)]} { return [encoding convertfrom utf-8 $r(STDOUT)] }
	return ""
}

# Switchable channels of the CCU: list of {channel name rooms type state device_type}
# A device with several switch channels (HmIP virtual channels) is offered with its
# first one. Push buttons and Hue CUxD devices of this addon are left out.
proc ::hue::extras::candidates {} {
	variable switch_types
	set out [rega "!hue:extras:candidates
string cid;
foreach(cid, dom.GetObject(ID_CHANNELS).EnumUsedIDs()) {
  object ch = dom.GetObject(cid);
  object dp = ch.DPByHssDP(\"STATE\");
  if (dp) {
    if (dp.ValueType() == 2) {
      string rooms = \"\";
      string rid;
      foreach(rid, ch.ChnRoom()) { object ro = dom.GetObject(rid); rooms = rooms # ro.Name() # \";\"; }
      object dev = dom.GetObject(ch.Device());
      object ifo = dom.GetObject(ch.Interface());
      string iface = ifo.Name();
      WriteLine(iface # \".\" # ch.Address() # \"|\" # ch.HssType() # \"|\" # dev.HssType() # \"|\" # dp.Value() # \"|\" # dp.Operations() # \"|\" # ch.Name() # \"|\" # rooms);
    }
  }
}"]
	set hue_devices [list]
	foreach d [::hue::get_cuxd_device_details] {
		lappend hue_devices [lindex [split [lindex $d 0] ":"] 0]
	}
	set rows [list]
	# Devices with push button inputs are wall switches, not actuators
	set buttons [list]
	foreach line [split [string map {"\r" ""} $out] "\n"] {
		set f [split $line "|"]
		if {[llength $f] < 7} { continue }
		lappend rows $f
		if {[string equal [lindex $f 1] "MULTI_MODE_INPUT_TRANSMITTER"]} {
			lappend buttons [lindex [split [lindex $f 0] ":"] 0]
		}
	}
	set seen [list]
	set result [list]
	foreach f $rows {
		foreach {channel type dtype state ops name rooms} $f break
		if {[lsearch -exact $switch_types $type] < 0} { continue }
		# Writable only
		if {![string is integer -strict $ops] || !($ops & 2)} { continue }
		set dev [lindex [split $channel ":"] 0]
		set addr [lindex [split $dev "."] end]
		if {[lsearch -exact $hue_devices $addr] >= 0 || [lsearch -exact $buttons $dev] >= 0} { continue }
		if {[regexp {^VIR-LG} $dtype]} { continue }
		if {[lsearch -exact $seen $dev] >= 0} { continue }
		lappend seen $dev
		set rl [list]
		foreach r [split $rooms ";"] { if {$r != ""} { lappend rl $r } }
		lappend result [list $channel $name $rl $dtype $state]
	}
	return $result
}

# Current STATE of channels: list of channel value (true/false/"")
proc ::hue::extras::states {channels} {
	if {[llength $channels] == 0} { return [list] }
	set s "!hue:extras:states\n"
	set i 0
	foreach ch $channels {
		if {![valid_channel $ch]} { continue }
		append s "object o$i = dom.GetObject(\"${ch}.STATE\"); if (o$i) { WriteLine(\"${ch}|\" # o$i.Value()); }\n"
		incr i
	}
	set result [list]
	foreach line [split [string map {"\r" ""} [rega $s]] "\n"] {
		set f [split $line "|"]
		if {[llength $f] == 2} { lappend result [lindex $f 0] [lindex $f 1] }
	}
	return $result
}

# Channel names: list of channel name
proc ::hue::extras::names {channels} {
	if {[llength $channels] == 0} { return [list] }
	set s "!hue:extras:names\n"
	set i 0
	foreach ch $channels {
		if {![valid_channel $ch]} { continue }
		append s "object d$i = dom.GetObject(\"${ch}.STATE\"); if (d$i) { object n$i = dom.GetObject(d$i.Channel()); WriteLine(\"${ch}|\" # n$i.Name()); }\n"
		incr i
	}
	set result [list]
	foreach line [split [string map {"\r" ""} [rega $s]] "\n"] {
		set f [split $line "|"]
		if {[llength $f] == 2} { lappend result [lindex $f 0] [lindex $f 1] }
	}
	return $result
}

# Switch channels: list of channel 0|1
proc ::hue::extras::set_states {pairs} {
	set s "!hue:extras:switch\n"
	set n 0
	foreach {ch on} $pairs {
		if {![valid_channel $ch]} { continue }
		set v "false"
		if {$on} { set v "true" }
		append s "dom.GetObject(\"${ch}.STATE\").State(${v});\n"
		incr n
	}
	if {$n > 0} { rega $s }
	return $n
}

# ---------------------------------------------------------------------------
# Shelly behind CUxD switches
#
# CUxD switches that call a Shelly by URL never learn about the wall switch or
# the Shelly app. hued asks the Shelly for its relay and corrects the CUxD
# state with SET_STATE, which does not run the command again.
# ---------------------------------------------------------------------------

# Status URL for a CUxD command, "" if it does not switch a Shelly
proc ::hue::extras::shelly_status_url {command} {
	set command [string map {"~3d" "=" "~26" "&" "%3D" "=" "%26" "&"} $command]
	if {[regexp {(https?://[^/ "']+)/relay/([0-9]+)} $command -> base relay]} {
		return "${base}/relay/${relay}"
	}
	if {[regexp {(https?://[^/ "']+)/rpc/Switch\.Set\?id=([0-9]+)} $command -> base relay]} {
		return "${base}/rpc/Switch.GetStatus?id=${relay}"
	}
	return ""
}

# CUxD switches with a Shelly: list of {channel status_url}
proc ::hue::extras::shelly_devices {} {
	set out [list]
	set seen [list]
	foreach device [xmlrpc $::hue::cuxd_xmlrpc_url listDevices] {
		set address [lindex $device 1]
		if {![regexp {^(CUX2801[0-9][0-9][0-9])(:[0-9]+)?$} $address -> dev ch]} { continue }
		if {$ch == ""} { set ch ":1" }
		if {[lsearch -exact $seen "${dev}${ch}"] >= 0} { continue }
		array set P [xmlrpc $::hue::cuxd_xmlrpc_url getParamset [list string $address] [list string "MASTER"]]
		set cmd ""
		foreach k {CMD_LONG CMD_SHORT} {
			if {[info exists P($k)]} { append cmd " $P($k)" }
		}
		catch {unset P}
		set url [shelly_status_url $cmd]
		if {$url == ""} { continue }
		lappend seen "${dev}${ch}"
		lappend out [list "CUxD.${dev}${ch}" $url]
	}
	return $out
}

# Relay state from a Shelly answer: 1, 0 or "" (unknown)
proc ::hue::extras::shelly_parse {body} {
	if {[regexp {"(ison|output)"[ ]*:[ ]*(true|false)} $body -> k v]} {
		return [expr {[string equal $v "true"] ? 1 : 0}]
	}
	return ""
}

# Correct CUxD states: list of channel 0|1. Returns the channels that changed.
proc ::hue::extras::cuxd_correct {pairs} {
	if {[llength $pairs] == 0} { return [list] }
	set s "!hue:extras:correct\n"
	set i 0
	foreach {ch on} $pairs {
		if {![valid_channel $ch]} { continue }
		set v "false"
		if {$on} { set v "true" }
		append s "object c$i = dom.GetObject(\"${ch}.STATE\"); if (c$i) { if (c$i.Value() != ${v}) { dom.GetObject(\"${ch}.SET_STATE\").State(${v}); WriteLine(\"${ch}\"); } }\n"
		incr i
	}
	set changed [list]
	foreach line [split [string map {"\r" ""} [rega $s]] "\n"] {
		set line [string trim $line]
		if {$line != ""} { lappend changed $line }
	}
	return $changed
}
