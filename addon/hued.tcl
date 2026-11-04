#!/bin/tclsh

#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2020  Jan Schneider <oss@janschneider.net>
#  Copyright (C) 2025-2026  Alexander Maximilian Röser (CLIP v2, event stream)
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

set addon_dir "/usr/local/addons/hue"
if {[info exists ::env(HUE_ADDON_DIR)]} { set addon_dir $::env(HUE_ADDON_DIR) }
source [file join $addon_dir lib hue.tcl]

# Last state sent to CUxD, per "<bridge>_<type>_<id>"
variable object_states
array set object_states {}
# CUxD address -> "<bridge>_<type>_<id>"
variable cuxd_device_map
array set cuxd_device_map {}
variable set_sysvars_reachable 1
variable scheduled_update_time 0
variable scheduled_update_cuxd_device_map_time 0
variable update_cuxd_device_map_interval 30
variable forced_updates
array set forced_updates {}
# Last value written per system variable
variable sysvar_values
array set sysvar_values {}
# Event streams: stream(<bridge>,chan|buf|connected|events|retry|next_try|error)
variable stream
array set stream {}
# Bridges with pending event stream changes
variable dirty_bridges [list]
variable dirty_after_id ""

proc same_array {array1 array2} {
	array set a1 $array1
	array set a2 $array2
	foreach key [hue::v2::luniq [concat [array names a1] [array names a2]]] {
		if {![info exists a1($key)] || ![info exists a2($key)]} {
			return 0
		}
		if {$a1($key) != $a2($key)} {
			return 0
		}
	}
	return 1
}

proc bgerror message {
	hue::write_log 1 "Unhandled error: ${message} - $::errorInfo"
}

# ---------------------------------------------------------------------------
# System variables
# ---------------------------------------------------------------------------

proc sysvar_exists {name} {
	return [hue::sysvar_exists $name]
}

# Write a value (rega syntax: true, 12.5, "text") if the variable exists and the value changed
proc update_sysvar_value {name value} {
	variable sysvar_values
	if {[info exists sysvar_values($name)] && [string equal $sysvar_values($name) $value]} {
		return
	}
	set sysvar_values($name) $value
	if {[sysvar_exists $name]} {
		hue::write_log 3 "Setting sysvar ${name} to ${value}"
		rega_script "var s = dom.GetObject(\"${name}\"); if (s) { s.State(${value}); }"
	} else {
		hue::write_log 4 "Sysvar ${name} does not exist"
	}
}

proc update_sysvars_reachable {name reachable} {
	set val [expr {$reachable == 1 || $reachable == "true" ? "true" : "false"}]
	update_sysvar_value $name $val
}

# ---------------------------------------------------------------------------
# CUxD device map
# ---------------------------------------------------------------------------

proc update_cuxd_device_map {} {
	variable cuxd_device_map
	hue::write_log 4 "Updating cuxd device map"
	if { [catch {
		set dmap [hue::get_cuxd_device_map]
		hue::v2::aunset cuxd_device_map *
		array set cuxd_device_map $dmap
	} errmsg] } {
		hue::write_log 1 "Failed to get cuxd device map: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
}

proc get_cuxd_devices_from_map {bridge_id obj num} {
	variable cuxd_device_map
	set cuxd_devices [list]
	foreach { d o } [array get cuxd_device_map] {
		if { $o == "${bridge_id}_${obj}_${num}" } {
			lappend cuxd_devices $d
		}
	}
	return $cuxd_devices
}

proc get_bridge_ids_from_map {} {
	variable cuxd_device_map
	set bridge_ids [list]
	foreach { d o } [array get cuxd_device_map] {
		set bridge_id [lindex [split $o "_"] 0]
		if { [lsearch $bridge_ids $bridge_id] < 0 } {
			lappend bridge_ids $bridge_id
		}
	}
	return $bridge_ids
}

# {type id} pairs of all mapped objects of a bridge
proc get_mapped_objects {bridge_id} {
	variable cuxd_device_map
	set objs [list]
	foreach { d o } [array get cuxd_device_map] {
		foreach {b t i} [split $o "_"] break
		if {[string equal $b $bridge_id] && [lsearch -exact $objs [list $t $i]] < 0} {
			lappend objs [list $t $i]
		}
	}
	return $objs
}

# ---------------------------------------------------------------------------
# Pushing state to CUxD
# ---------------------------------------------------------------------------

proc update_cuxd_device {cuxd_device bridge_id obj_type obj_id astate} {
	variable set_sysvars_reachable
	array set state $astate
	hue::update_cuxd_device_state $cuxd_device [array get state]
	hue::write_log 3 "Update of ${bridge_id} ${obj_type} ${obj_id} / ${cuxd_device} successful (reachable=$state(reachable) on=$state(on) colormode=$state(colormode) bri=$state(bri) ct=$state(ct) hue=$state(hue) sat=$state(sat) xy=$state(xy))"
	if {$set_sysvars_reachable == 1} {
		update_sysvars_reachable "Hue_reachable_${cuxd_device}" $state(reachable)
		update_sysvars_reachable "Hue_reachable_${bridge_id}_${obj_type}_${obj_id}" $state(reachable)
	}
}

# Compare with the last state and update CUxD devices if needed
proc process_object_state {bridge_id obj_type obj_id astate} {
	variable object_states
	variable forced_updates
	variable scheduled_update_cuxd_device_map_time
	array set state $astate
	# Fields that are not part of the CUxD state
	foreach k {api rid ct_min ct_max color} { catch {unset state($k)} }
	set full_id "${bridge_id}_${obj_type}_${obj_id}"

	set force_update 0
	if {[info exists forced_updates($full_id)] && $forced_updates($full_id) > 0} {
		set force_update 1
		incr forced_updates($full_id) -1
	}
	if {!$force_update && [info exists object_states($full_id)] && [same_array [array get state] $object_states($full_id)]} {
		hue::write_log 4 "State of ${bridge_id} ${obj_type} ${obj_id} is unchanged"
		return
	}
	hue::write_log 4 "State of ${bridge_id} ${obj_type} ${obj_id} has changed (forced=${force_update})"
	set object_states($full_id) [array get state]

	foreach cuxd_device [get_cuxd_devices_from_map $bridge_id $obj_type $obj_id] {
		if { [catch {
			update_cuxd_device $cuxd_device $bridge_id $obj_type $obj_id [array get state]
		} errmsg] } {
			# CUxD device deleted
			hue::write_log 2 "Failed to update cuxd device ${cuxd_device}: ${errmsg}"
			set scheduled_update_cuxd_device_map_time [clock seconds]
		}
	}
}

# CLIP v2: push all mapped objects and sensors from the cache
proc process_bridge_v2 {bridge_id} {
	foreach o [get_mapped_objects $bridge_id] {
		set obj_type [lindex $o 0]
		set obj_id [lindex $o 1]
		if {[catch {
			process_object_state $bridge_id $obj_type $obj_id [hue::v2::object_state $bridge_id $obj_type $obj_id]
		} err]} {
			hue::write_log 2 "Failed to process ${bridge_id} ${obj_type} ${obj_id}: ${err}"
		}
	}
	foreach {name value} [hue::v2::sensor_values $bridge_id] {
		update_sysvar_value $name $value
	}
}

# v1: poll lights and groups
proc process_bridge_v1 {bridge_id} {
	variable object_states
	foreach obj_type [list "light" "group"] {
		set response [hue::request "status" $bridge_id "GET" "/${obj_type}s"]
		regsub -all {\n} $response "" response
		regsub -all {(\"\d+\":\{)} $response "\n\\1" tmp
		foreach data [split $tmp "\n"] {
			if {[regexp {\"(\d+)\":\{} $data match obj_id]} {
				if {[llength [get_cuxd_devices_from_map $bridge_id $obj_type $obj_id]] == 0} {
					continue
				}
				process_object_state $bridge_id $obj_type $obj_id [hue::get_object_state_from_json $bridge_id $obj_type $obj_id $data [array get object_states]]
			}
		}
	}
}

proc set_scheduled_update {time} {
	variable scheduled_update_time
	if {$scheduled_update_time <= 0 || $time < $scheduled_update_time} {
		set scheduled_update_time $time
	}
}

proc check_update {} {
	variable scheduled_update_time
	variable scheduled_update_cuxd_device_map_time
	variable update_cuxd_device_map_interval

	if {[clock seconds] >= $scheduled_update_cuxd_device_map_time} {
		update_cuxd_device_map
		set scheduled_update_cuxd_device_map_time [expr {[clock seconds] + $update_cuxd_device_map_interval}]
	}

	set bridge_ids [get_bridge_ids_from_map]
	foreach bridge_id $bridge_ids {
		ensure_eventstream $bridge_id
	}

	if {$scheduled_update_time < 0 || [clock seconds] < $scheduled_update_time} {
		return
	}
	hue::write_log 4 "Updating status"
	set scheduled_update_time -1

	foreach bridge_id $bridge_ids {
		if {[catch {
			if {[hue::v2::active $bridge_id]} {
				hue::v2::ensure_loaded $bridge_id
				hue::v2::refresh_state $bridge_id
				process_bridge_v2 $bridge_id
			} else {
				process_bridge_v1 $bridge_id
			}
		} err]} {
			hue::write_log 1 "Status update of bridge ${bridge_id} failed: ${err}"
		}
	}

	if {$hue::poll_state_interval > 0} {
		set interval $hue::poll_state_interval
		# With a running event stream polling is only a safety net
		if {[all_streams_connected $bridge_ids] && $interval < 300} {
			set interval 300
		}
		set_scheduled_update [expr {[clock seconds] + $interval}]
	}
}

proc main_loop {} {
	if { [catch {
		check_update
	} errmsg] } {
		hue::write_log 1 "Error: ${errmsg} - ${::errorCode} - ${::errorInfo}"
		after 30000 main_loop
	} else {
		after 1000 main_loop
	}
}

# ---------------------------------------------------------------------------
# CLIP v2 event stream
# ---------------------------------------------------------------------------

proc stream_get {bridge_id key {default ""}} {
	variable stream
	if {[info exists stream($bridge_id,$key)]} { return $stream($bridge_id,$key) }
	return $default
}

proc all_streams_connected {bridge_ids} {
	if {[llength $bridge_ids] == 0} { return 0 }
	foreach b $bridge_ids {
		if {[stream_get $b connected 0] != 1} { return 0 }
	}
	return 1
}

proc ensure_eventstream {bridge_id} {
	variable stream
	if {!$hue::eventstream} {
		stop_eventstream $bridge_id
		return
	}
	if {[stream_get $bridge_id chan] != ""} { return }
	if {[clock seconds] < [stream_get $bridge_id next_try 0]} { return }
	if {[catch {hue::v2::active $bridge_id} active] || !$active} {
		set stream($bridge_id,next_try) [expr {[clock seconds] + 300}]
		return
	}
	if {[catch {start_eventstream $bridge_id} err]} {
		hue::write_log 2 "Event stream of bridge ${bridge_id} could not be started: ${err}"
		schedule_stream_retry $bridge_id
	}
}

proc start_eventstream {bridge_id} {
	variable stream
	hue::v2::ensure_loaded $bridge_id
	array set bridge [hue::v2::bridge_info $bridge_id]
	set url "[hue::v2::base_url bridge]/eventstream/clip/v2"
	set cmd [list [hue::curl_bin] --silent --show-error --no-buffer --connect-timeout 10 --keepalive-time 30 \
		-H "hue-application-key: $bridge(username)" -H "Accept: text/event-stream"]
	foreach a [hue::v2::tls_args bridge] { lappend cmd $a }
	# --stderr -: curl errors arrive in the stream (2>@1 needs Tcl 8.4)
	lappend cmd --stderr - $url
	set chan [open "|$cmd" r]
	fconfigure $chan -blocking 0 -buffering line -translation auto -encoding utf-8
	set stream($bridge_id,chan) $chan
	set stream($bridge_id,buf) ""
	set stream($bridge_id,connected) 0
	set stream($bridge_id,error) ""
	fileevent $chan readable [list read_eventstream $bridge_id $chan]
	hue::write_log 3 "Event stream of bridge ${bridge_id} started"
}

proc stop_eventstream {bridge_id} {
	variable stream
	set chan [stream_get $bridge_id chan]
	if {$chan != ""} {
		catch { fileevent $chan readable {} }
		catch { eval exec kill [pid $chan] }
		catch { close $chan }
		hue::write_log 3 "Event stream of bridge ${bridge_id} stopped"
	}
	set stream($bridge_id,chan) ""
	set stream($bridge_id,connected) 0
}

proc schedule_stream_retry {bridge_id} {
	variable stream
	set retry [hue::v2::minn 300 [hue::v2::maxn 5 [expr {2 * [stream_get $bridge_id retry 0]}]]]
	set stream($bridge_id,retry) $retry
	set stream($bridge_id,next_try) [expr {[clock seconds] + $retry}]
}

proc read_eventstream {bridge_id chan} {
	variable stream
	while {[gets $chan line] >= 0} {
		if {[string match "data:*" $line]} {
			append stream($bridge_id,buf) [string trim [string range $line 5 end]]
		} elseif {$line == ""} {
			set data $stream($bridge_id,buf)
			set stream($bridge_id,buf) ""
			if {$data != ""} {
				handle_events $bridge_id $data
			}
		} elseif {[string match "id:*" $line] || [string match ":*" $line]} {
			if {[stream_get $bridge_id connected 0] == 0} {
				set stream($bridge_id,connected) 1
				set stream($bridge_id,retry) 0
				hue::write_log 3 "Event stream of bridge ${bridge_id} connected"
			}
		} else {
			# curl error message or HTTP noise
			set stream($bridge_id,error) $line
			hue::write_log 2 "Event stream of bridge ${bridge_id}: ${line}"
		}
	}
	if {[eof $chan]} {
		catch { close $chan }
		set stream($bridge_id,chan) ""
		set stream($bridge_id,connected) 0
		hue::write_log 2 "Event stream of bridge ${bridge_id} closed [stream_get $bridge_id error]"
		schedule_stream_retry $bridge_id
		# Catch up on changes we may have missed
		set_scheduled_update [clock seconds]
	}
}

proc handle_events {bridge_id data} {
	variable stream
	variable dirty_bridges
	variable dirty_after_id
	set stream($bridge_id,connected) 1
	set stream($bridge_id,events) [expr {[stream_get $bridge_id events 0] + 1}]
	hue::write_log 4 "Event from bridge ${bridge_id}: ${data}"
	if {[catch {set structure [hue::v2::apply_events $bridge_id $data]} err]} {
		hue::write_log 2 "Invalid event from bridge ${bridge_id}: ${err}"
		return
	}
	if {$structure} {
		hue::write_log 3 "Resources of bridge ${bridge_id} were added or deleted"
	}
	# Collect events for a moment, a scene change sends one event per lamp
	if {[lsearch -exact $dirty_bridges $bridge_id] < 0} {
		lappend dirty_bridges $bridge_id
	}
	if {$dirty_after_id == ""} {
		set dirty_after_id [after 150 process_dirty_bridges]
	}
}

proc process_dirty_bridges {} {
	variable dirty_bridges
	variable dirty_after_id
	set bridges $dirty_bridges
	set dirty_bridges [list]
	set dirty_after_id ""
	foreach bridge_id $bridges {
		if {[catch {process_bridge_v2 $bridge_id} err]} {
			hue::write_log 1 "Processing events of bridge ${bridge_id} failed: ${err}"
		}
	}
}

# ---------------------------------------------------------------------------
# Commands from hue.tcl and the web UI
# ---------------------------------------------------------------------------

proc v1_object_action {bridge_id obj_type obj_id params} {
	set json "\{"
	foreach {name value} $params {
		# Parameters of the v2 API have no v1 equivalent
		if {[string equal $name "identify"]} {
			set name "alert"
			set value "\"select\""
		} elseif {[lsearch -exact {speed gradient gradient_mode timed_effect signal signal_duration signal_color} $name] >= 0} {
			hue::write_log 2 "${bridge_id} ${obj_type} ${obj_id}: parameter ${name} needs the Hue API v2, ignored"
			continue
		}
		if {[string equal $name "scene"] && ![regexp {^"[a-zA-Z0-9\-]{15,16}"$} $value]} {
			# Scene given by name
			array set scene_map [hue::get_scene_name_id_map $bridge_id]
			set sname [string trim $value "\""]
			if {![info exists scene_map($sname)]} {
				error "Failed to find scene with name ${sname}."
			}
			set value "\"$scene_map($sname)\""
		}
		append json "\"${name}\":${value},"
	}
	set json "[string trimright $json ,]\}"
	set path "lights/${obj_id}/state"
	if {$obj_type == "group"} {
		set path "groups/${obj_id}/action"
	}
	return [hue::request "command" $bridge_id "PUT" $path $json]
}

proc object_state {bridge_id obj_type obj_id} {
	variable object_states
	if {[hue::v2::active $bridge_id]} {
		return [hue::v2::object_state $bridge_id $obj_type $obj_id]
	}
	set full_id "${bridge_id}_${obj_type}_${obj_id}"
	if {![info exists object_states($full_id)] || $hue::poll_state_interval <= 0 || $hue::poll_state_interval > 10} {
		set object_states($full_id) [hue::get_object_state $bridge_id $obj_type $obj_id]
	}
	array set st $object_states($full_id)
	set st(api) "v1"
	return [array get st]
}

proc status_text {} {
	variable scheduled_update_time
	variable cuxd_device_map
	set r ""
	append r "version: [hue::version]\n"
	append r "time: [clock seconds]\n"
	append r "scheduled_update_time: ${scheduled_update_time}\n"
	append r "api_version: ${hue::api_version}\n"
	append r "eventstream: ${hue::eventstream}\n"
	foreach bridge_id [hue::get_config_bridge_ids] {
		set api "v1"
		catch { if {[hue::v2::active $bridge_id]} { set api "v2" } }
		append r "bridge ${bridge_id}: api=${api} stream_connected=[stream_get $bridge_id connected 0] events=[stream_get $bridge_id events 0]"
		set err [stream_get $bridge_id error]
		if {$err != ""} { append r " stream_error=\"${err}\"" }
		append r "\n"
	}
	append r "cuxd_device_map: [join [array get cuxd_device_map] { }]\n"
	return $r
}

proc read_from_channel {channel} {
	variable forced_updates
	variable stream

	if {[gets $channel cmd] < 0} {
		if {[eof $channel]} { close $channel }
		return
	}
	set cmd [string trim $cmd]
	hue::write_log 4 "Received command: $cmd"
	set response ""
	if { [catch {
		if {[regexp "^object_action\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s*(.*)$" $cmd match bridge_id obj_type obj_id params]} {
			if {[hue::v2::active $bridge_id]} {
				set response [hue::v2::object_action $bridge_id $obj_type $obj_id $params]
			} else {
				set response [v1_object_action $bridge_id $obj_type $obj_id $params]
			}
		} elseif {[regexp "^object_state\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)$" $cmd match bridge_id obj_type obj_id]} {
			set response [object_state $bridge_id $obj_type $obj_id]
		} elseif {[regexp "^update_object_state\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)\\s+(\\d+)$" $cmd match bridge_id obj_type obj_id delay_seconds]} {
			set forced_updates(${bridge_id}_${obj_type}_${obj_id}) 2
			# The event stream delivers v2 changes by itself
			if {[stream_get $bridge_id connected 0] != 1} {
				set_scheduled_update [expr {[clock seconds] + $delay_seconds}]
			}
		} elseif {[regexp "^update_object_state\\s+(\\S+)\\s+(\\S+)\\s+(\\S+)$" $cmd match bridge_id obj_type obj_id]} {
			# Channel 1 of a dimmer: refresh now
			set forced_updates(${bridge_id}_${obj_type}_${obj_id}) 2
			set_scheduled_update [clock seconds]
		} elseif {[string equal $cmd "reload"]} {
			hue::write_log 3 "Hue daemon reload"
			hue::read_global_config
			hue::v2::forget_all
			foreach key [array names stream "*,chan"] {
				set b [lindex [split $key ","] 0]
				stop_eventstream $b
				set stream($b,next_try) 0
			}
			update_cuxd_device_map
			set_scheduled_update [clock seconds]
			set response "Reload scheduled"
		} elseif {[regexp "^objects\\s+(\\S+)$" $cmd match bridge_id]} {
			# Overview for the web UI from the cache, kept current by the event stream
			set response [hue::objects_json $bridge_id 0]
		} elseif {[string equal $cmd "status"]} {
			set response [status_text]
		} else {
			set response "ERROR: Invalid command"
		}
	} errmsg] } {
		hue::write_log 1 "${errmsg} - ${::errorCode} - ${::errorInfo}"
		set response "ERROR: ${errmsg}"
	}
	hue::write_log 4 "Sending response: $response"
	catch {
		puts $channel $response
		flush $channel
	}
	catch { close $channel }
}

proc accept_connection {channel address port} {
	hue::write_log 4 "Accepted connection from $address\:$port"
	fconfigure $channel -blocking 0 -buffersize 65536 -encoding utf-8
	fileevent $channel readable [list read_from_channel $channel]
}

proc update_config {} {
	hue::write_log 3 "Update config $hue::ini_file"
	hue::acquire_lock $hue::lock_id_ini_file
	catch {
		set f [open $hue::ini_file r]
		set data [read $f]
		close $f
		# Remove legacy options
		if {[regsub -all {cuxd_device_[^\n]+\n} $data "" data]} {
			set f [open $hue::ini_file w]
			puts -nonewline $f $data
			close $f
		}
	}
	hue::release_lock $hue::lock_id_ini_file
}

proc main {} {
	if { [catch {
		update_config
	} errmsg] } {
		hue::write_log 1 "Error: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
	if {$hue::hued_address == "0.0.0.0"} {
		socket -server accept_connection $hue::hued_port
	} else {
		socket -server accept_connection -myaddr $hue::hued_address $hue::hued_port
	}
	hue::write_log 3 "Hue daemon [hue::version] is listening for connections on ${hue::hued_address}:${hue::hued_port}"
	main_loop
}

if { "[lindex $argv 0 ]" != "daemon" && "[lindex $argv 0 ]" != "nofork" } {
	catch {
		foreach dpid [split [exec pidof [file tail $argv0]] " "] {
			if {[pid] != $dpid} {
				exec kill $dpid
			}
		}
	}
	# Leftover event stream processes of a previous daemon
	catch { exec pkill -f "eventstream/clip/v2" }
	if { "[lindex $argv 0 ]" != "stop" } {
		exec $argv0 daemon &
	}
} else {
	if { "[lindex $argv 0 ]" == "daemon" } {
		cd /
		foreach fd {stdin stdout stderr} {
			close $fd
		}
	} elseif { "[lindex $argv 0 ]" == "nofork" } {
		hue::set_log_stderr 4
	}
	main
	vwait forever
}
exit 0
