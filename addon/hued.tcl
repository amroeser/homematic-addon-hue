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
# CUxD address -> scene of a Hue scene switch
variable cuxd_scene
array set cuxd_scene {}
# Last state written to a scene switch
variable scene_switch_last
array set scene_switch_last {}
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
	variable cuxd_scene
	hue::write_log 4 "Updating cuxd device map"
	if { [catch {
		set details [hue::get_cuxd_device_details]
		hue::v2::aunset cuxd_device_map *
		hue::v2::aunset cuxd_scene *
		foreach d $details {
			foreach {address b t i scene} $d break
			set cuxd_device_map($address) "${b}_${t}_${i}"
			if {$scene != ""} { set cuxd_scene($address) $scene }
		}
	} errmsg] } {
		hue::write_log 1 "Failed to get cuxd device map: ${errmsg} - ${::errorCode} - ${::errorInfo}"
	}
}

# Bridge ids are handled in lower case. CUxD commands of older addon versions
# may contain the id in upper case ("ECB5FAFFFE84F062"), so compare without case.
proc get_cuxd_devices_from_map {bridge_id obj num} {
	variable cuxd_device_map
	set want [string tolower "${bridge_id}_${obj}_${num}"]
	set cuxd_devices [list]
	foreach { d o } [array get cuxd_device_map] {
		if {[string equal [string tolower $o] $want]} {
			lappend cuxd_devices $d
		}
	}
	return $cuxd_devices
}

# Bridge id as written in the CUxD command (used for system variable names)
proc get_bridge_id_as_mapped {bridge_id obj num} {
	variable cuxd_device_map
	set want [string tolower "${bridge_id}_${obj}_${num}"]
	foreach { d o } [array get cuxd_device_map] {
		if {[string equal [string tolower $o] $want]} {
			return [lindex [split $o "_"] 0]
		}
	}
	return $bridge_id
}

proc get_bridge_ids_from_map {} {
	variable cuxd_device_map
	set bridge_ids [list]
	foreach { d o } [array get cuxd_device_map] {
		set bridge_id [string tolower [lindex [split $o "_"] 0]]
		if { [lsearch -exact $bridge_ids $bridge_id] < 0 } {
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
		if {[string equal [string tolower $b] [string tolower $bridge_id]] && [lsearch -exact $objs [list $t $i]] < 0} {
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
		# Name as the CUxD command writes the bridge id, like older versions did
		update_sysvars_reachable "Hue_reachable_[get_bridge_id_as_mapped $bridge_id $obj_type $obj_id]_${obj_type}_${obj_id}" $state(reachable)
	}
}

# Compare with the last state and update CUxD devices if needed
proc process_object_state {bridge_id obj_type obj_id astate} {
	variable object_states
	variable forced_updates
	variable scheduled_update_cuxd_device_map_time
	set bridge_id [string tolower $bridge_id]
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

	variable cuxd_scene
	foreach cuxd_device [get_cuxd_devices_from_map $bridge_id $obj_type $obj_id] {
		# Scene switches follow their scene, see process_scene_switches
		if {[info exists cuxd_scene($cuxd_device)] && [string equal $hue::scene_switch_state "scene"]} { continue }
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
	if {[catch {scene_vars_for_bridge $bridge_id} err]} {
		hue::write_log 1 "Scene variables of ${bridge_id}: ${err}"
	}
	if {[catch {process_scene_switches $bridge_id} err]} {
		hue::write_log 1 "Scene switches of ${bridge_id}: ${err}"
	}
	if {[catch {process_extras $bridge_id} err]} {
		hue::write_log 1 "More lamps of ${bridge_id}: ${err}"
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
	if {[catch {process_scene_switches $bridge_id} err]} {
		hue::write_log 1 "Scene switches of ${bridge_id}: ${err}"
	}
}

# A Hue scene switch (CUxD) is on while the room is on and its scene is active.
# Programs toggle these switches; with every switch of a room on, a toggle on
# the second scene would switch the room off instead of recalling the scene.
# The v1 API does not tell the active scene: there the room state is used.
proc process_scene_switches {bridge_id} {
	variable cuxd_scene
	variable cuxd_device_map
	variable object_states
	variable scene_switch_last
	if {![string equal $hue::scene_switch_state "scene"]} { return }
	set b [string tolower $bridge_id]
	set v2 [hue::v2::active $b]
	set script ""
	foreach address [array names cuxd_scene] {
		if {![info exists cuxd_device_map($address)]} { continue }
		set o [string tolower $cuxd_device_map($address)]
		if {![string equal [lindex [split $o "_"] 0] $b]} { continue }
		if {![info exists object_states($o)]} { continue }
		array set st $object_states($o)
		set on [expr {[info exists st(on)] && [lsearch -exact {true 1} $st(on)] >= 0}]
		catch {unset st}
		if {$on && $v2} {
			set rid [hue::v2::scene_rid $b $cuxd_scene($address)]
			set act [hue::v2::rget $b $rid status/active]
			if {$rid == "" || $act == "" || [string equal $act "inactive"]} { set on 0 }
		}
		if {[info exists scene_switch_last($address)] && $scene_switch_last($address) == $on} { continue }
		set scene_switch_last($address) $on
		set ch $address
		if {[string first ":" $ch] < 0} { append ch ":1" }
		hue::write_log 3 "Scene switch ${ch} = ${on}"
		append script "dom.GetObject(\"CUxD.${ch}.SET_STATE\").State(${on});\n"
	}
	if {$script != ""} { rega_script $script }
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
	if {$hue::scene_sysvars} {
		# Scene variables also work for bridges without mapped CUxD devices
		foreach b [hue::get_config_bridge_ids] {
			if {[lsearch -exact $bridge_ids $b] < 0} { lappend bridge_ids $b }
		}
	}
	foreach b [extras_bridges] {
		if {[lsearch -exact $bridge_ids $b] < 0} { lappend bridge_ids $b }
	}
	foreach bridge_id $bridge_ids {
		ensure_eventstream $bridge_id
	}
	if {[catch {poll_scene_vars} err]} {
		hue::write_log 1 "Scene variables: ${err}"
	}
	if {[catch {shelly_poll} err]} {
		hue::write_log 1 "Shelly: ${err}"
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
		catch {unset ::scenevar_synced($bridge_id)}
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
# Scenes as system variables
#
# Every room and zone with scenes gets a value list "Hue Szene <room>":
#   entry 0 "Aus" switches the room off, the other entries recall a scene.
# Programs pick a scene by name; nobody edits CUxD commands. hued keeps the
# list current: new scenes are appended, deleted ones become "(entfernt)" so
# the positions programs refer to never move. A scene chosen in the Hue app
# shows up in the variable as well. Names are plain ASCII (ReGa is ISO-8859-1).
# ---------------------------------------------------------------------------

variable scenevars
array set scenevars {}
variable scenevar_last
array set scenevar_last {}
variable scenevar_synced
array set scenevar_synced {}
variable scenevar_polled 0

proc rega_out {script} {
	array set r [rega_script $script]
	if {[info exists r(STDOUT)]} { return $r(STDOUT) }
	return ""
}

proc scene_owners {b} {
	set owners [list]
	foreach rid [hue::v2::resources $b scene] {
		set o [hue::v2::rget $b $rid group/rid]
		if {$o != "" && [hue::v2::rexists $b $o] && [lsearch -exact $owners $o] < 0} { lappend owners $o }
	}
	return $owners
}

proc scenes_of {b owner} {
	set pairs [list]
	foreach rid [hue::v2::resources $b scene] {
		if {[string equal [hue::v2::rget $b $rid group/rid] $owner]} {
			lappend pairs [list [string tolower [hue::v2::rget $b $rid metadata/name]] $rid]
		}
	}
	set out [list]
	foreach p [lsort -index 0 $pairs] { lappend out [lindex $p 1] }
	return $out
}

proc scene_label {b rid} {
	set l [hue::v2::ascii [hue::v2::rget $b $rid metadata/name]]
	if {$l == ""} { set l "Szene" }
	return $l
}

proc same_name {a b} {
	set fa [hue::v2::fold $a]
	set fb [hue::v2::fold $b]
	return [expr {[string equal [lindex $fa 0] [lindex $fb 0]] || [string equal [lindex $fa 1] [lindex $fb 1]]}]
}

# Index of the label in the entry list, -1 if missing
proc entry_index {entries label} {
	for {set i 1} {$i < [llength $entries]} {incr i} {
		if {[same_name [lindex $entries $i] $label]} { return $i }
	}
	return -1
}

proc sync_scene_vars {b} {
	variable scenevars
	variable scenevar_last
	variable scenevar_synced
	hue::v2::aunset scenevars "$b|*"
	set scenevar_synced($b) [hue::v2::loaded_at $b]
	foreach owner [scene_owners $b] {
		set name "Hue Szene [hue::v2::ascii [hue::v2::rget $b $owner metadata/name]]"
		set labels [list]
		foreach rid [scenes_of $b $owner] {
			set l [scene_label $b $rid]
			set n 2
			set base $l
			while {[lsearch -exact $labels $l] >= 0} { set l "$base $n"; incr n }
			lappend labels $l
		}
		set out [rega_out "!hue:scenevar:get $name
object sv = dom.GetObject(\"$name\");
if (!sv) {
  object svs = dom.GetObject(ID_SYSTEM_VARIABLES);
  sv = dom.CreateObject(OT_VARDP);
  svs.Add(sv.ID());
  sv.Name(\"$name\");
  sv.ValueType(ivtInteger);
  sv.ValueSubType(istEnum);
  sv.ValueList(\"Aus\");
  sv.DPInfo(\"Philips Hue: Szene waehlen\");
  sv.Internal(false);
  sv.Visible(true);
  sv.State(0);
  dom.RTUpdate(0);
}
WriteLine(sv.ValueList());
Write(sv.Value());"]
		set lines [split [string map {"\r" ""} $out] "\n"]
		set entries [split [lindex $lines 0] ";"]
		set value [string trim [lindex $lines 1]]
		if {[llength $entries] == 0} { set entries [list "Aus"] }
		set new [lreplace $entries 0 0 "Aus"]
		# Keep positions: missing scenes become "(entfernt)", new ones are appended
		for {set i 1} {$i < [llength $new]} {incr i} {
			set e [lindex $new $i]
			if {[string equal $e "(entfernt)"]} { continue }
			set keep 0
			foreach l $labels { if {[same_name $e $l]} { set keep 1; break } }
			if {!$keep} { set new [lreplace $new $i $i "(entfernt)"] }
		}
		foreach l $labels {
			if {[entry_index $new $l] < 0} { lappend new $l }
		}
		if {![string equal [join $new ";"] [join $entries ";"]]} {
			hue::write_log 3 "Scene list of ${name}: [join $new {;}]"
			rega_out "!hue:scenevar:list $name
object sv = dom.GetObject(\"$name\");
if (sv) { sv.ValueList(\"[join $new {;}]\"); dom.RTUpdate(0); }"
		}
		set scenevars($b|$owner) [list $name $new]
		if {[string is integer -strict $value]} { set scenevar_last($name) $value }
	}
}

# A program or the WebUI changed a scene variable
proc scene_var_changed {b owner idx} {
	variable scenevars
	set entries [lindex $scenevars($b|$owner) 1]
	if {$idx == 0} {
		set gl [hue::v2::lookup $b "gl_of,$owner"]
		if {$gl != ""} {
			hue::write_log 3 "Scene variable: switching off [hue::v2::rget $b $owner metadata/name]"
			hue::v2::request "command" $b PUT "resource/grouped_light/${gl}" "\{\"on\":\{\"on\":false\}\}"
		}
		return
	}
	set label [lindex $entries $idx]
	foreach rid [scenes_of $b $owner] {
		if {[same_name [scene_label $b $rid] $label]} {
			hue::write_log 3 "Scene variable: recalling ${label}"
			hue::v2::request "command" $b PUT "resource/scene/${rid}" "\{\"recall\":\{\"action\":\"active\"\}\}"
			return
		}
	}
}

# Read all scene variables at once and act on changes
proc poll_scene_vars {} {
	variable scenevars
	variable scenevar_last
	variable scenevar_polled
	if {!$hue::scene_sysvars || [array size scenevars] == 0} { return }
	if {[clock seconds] - $scenevar_polled < 2} { return }
	set scenevar_polled [clock seconds]
	set keys [array names scenevars]
	set script "!hue:scenevar:read\n"
	set i 0
	foreach k $keys {
		set name [lindex $scenevars($k) 0]
		append script "!var $name\nobject o$i = dom.GetObject(\"$name\");\nif (o$i) { WriteLine(o$i.Value()); } else { WriteLine(\"-\"); }\n"
		incr i
	}
	set values [split [string map {"\r" ""} [rega_out $script]] "\n"]
	set i 0
	foreach k $keys {
		set v [string trim [lindex $values $i]]
		incr i
		set name [lindex $scenevars($k) 0]
		if {![string is integer -strict $v]} { continue }
		if {[info exists scenevar_last($name)] && $scenevar_last($name) == $v} { continue }
		set first [expr {![info exists scenevar_last($name)]}]
		set scenevar_last($name) $v
		if {$first} { continue }
		foreach {b owner} [split $k "|"] break
		if {[catch {scene_var_changed $b $owner $v} err]} {
			hue::write_log 1 "Scene variable ${name}: ${err}"
		}
	}
}

# Show the active scene (or "Aus") of each room in its variable
proc update_scene_vars_from_state {b} {
	variable scenevars
	variable scenevar_last
	foreach k [array names scenevars "$b|*"] {
		set owner [lindex [split $k "|"] 1]
		set name [lindex $scenevars($k) 0]
		set entries [lindex $scenevars($k) 1]
		set gl [hue::v2::lookup $b "gl_of,$owner"]
		set target -1
		if {$gl != "" && ![string equal [hue::v2::rget $b $gl on/on] "true"]} {
			set target 0
		} else {
			foreach rid [scenes_of $b $owner] {
				set st [hue::v2::rget $b $rid status/active]
				if {$st != "" && ![string equal $st "inactive"]} {
					set target [entry_index $entries [scene_label $b $rid]]
					break
				}
			}
		}
		if {$target < 0} { continue }
		if {[info exists scenevar_last($name)] && $scenevar_last($name) == $target} { continue }
		set scenevar_last($name) $target
		hue::write_log 3 "Scene variable ${name} = ${target}"
		rega_out "!hue:scenevar:set $name $target
object sv = dom.GetObject(\"$name\");
if (sv) { sv.State($target); }"
	}
}

proc scene_vars_for_bridge {b} {
	variable scenevar_synced
	if {!$hue::scene_sysvars} { return }
	if {![info exists scenevar_synced($b)] || $scenevar_synced($b) != [hue::v2::loaded_at $b]} {
		sync_scene_vars $b
	}
	update_scene_vars_from_state $b
}

# ---------------------------------------------------------------------------
# More lamps in a room
#
# Switch actuators of the CCU that follow a Hue room: on and off with the room,
# whoever switched it (web UI, CUxD, programs, scene variable, Hue app, Hue
# switches). Scenes can switch them on or off as well. Only changes of the
# room are acted on, never the actuators' own state, so nothing can loop.
# ---------------------------------------------------------------------------

variable extras_rooms
array set extras_rooms {}
variable extras_scenes
array set extras_scenes {}
variable extras_last
array set extras_last {}

proc load_extras {} {
	variable extras_rooms
	variable extras_scenes
	hue::v2::aunset extras_rooms *
	hue::v2::aunset extras_scenes *
	if {[catch {hue::extras::all} all]} {
		hue::write_log 1 "More lamps: ${all}"
		return
	}
	foreach e $all {
		foreach {kind b rid entries} $e break
		if {[string equal $kind "room"]} {
			set extras_rooms($b|$rid) $entries
		} else {
			set extras_scenes($b|$rid) $entries
		}
	}
	# New assignments start from the current state of their room
	foreach b [extras_bridges] {
		if {[hue::v2::loaded_at $b] > 0} {
			catch { process_extras $b 1 }
		}
	}
}

proc extras_bridges {} {
	variable extras_rooms
	set out [list]
	foreach k [array names extras_rooms] {
		set b [lindex [split $k "|"] 0]
		if {[lsearch -exact $out $b] < 0} { lappend out $b }
	}
	return $out
}

proc active_scene {b owner} {
	foreach rid [scenes_of $b $owner] {
		set st [hue::v2::rget $b $rid status/active]
		if {$st != "" && ![string equal $st "inactive"]} { return $rid }
	}
	return ""
}

# init 1: only remember the current state (after loading the assignments)
proc process_extras {b {init 0}} {
	variable extras_rooms
	variable extras_scenes
	variable extras_last
	set pairs [list]
	foreach k [array names extras_rooms "$b|*"] {
		set room [lindex [split $k "|"] 1]
		set gl [hue::v2::lookup $b "gl_of,$room"]
		if {$gl == ""} { continue }
		set on [string equal [hue::v2::rget $b $gl on/on] "true"]
		set scene [active_scene $b $room]
		if {![info exists extras_last($k)]} {
			# First look after a start: remember only
			set extras_last($k) [list $on $scene]
			continue
		}
		if {$init} { continue }
		foreach {lon lscene} $extras_last($k) break
		set extras_last($k) [list $on $scene]
		catch {unset want}
		array set want {}
		if {$on != $lon} {
			foreach e $extras_rooms($k) {
				foreach {ch mode} $e break
				if {!$on} {
					set want($ch) 0
				} elseif {[string equal $mode "both"]} {
					set want($ch) 1
				}
			}
		}
		if {$on && $scene != "" && ($on != $lon || ![string equal $scene $lscene]) && [info exists extras_scenes($b|$scene)]} {
			foreach e $extras_scenes($b|$scene) {
				foreach {ch v} $e break
				set want($ch) [string equal $v "on"]
			}
		}
		foreach ch [array names want] {
			lappend pairs $ch $want($ch)
		}
	}
	if {[llength $pairs] > 0} {
		hue::write_log 3 "More lamps: ${pairs}"
		hue::extras::set_states $pairs
	}
}

# Shellys behind CUxD switches: read the relays, correct the CUxD state
variable shelly_list [list]
variable shelly_list_time 0
variable shelly_polled 0
variable shelly_pending 0
variable shelly_buf
array set shelly_buf {}

proc shelly_poll {} {
	variable shelly_list
	variable shelly_list_time
	variable shelly_polled
	variable shelly_pending
	variable shelly_buf
	if {!$hue::shelly_sync} { return }
	set now [clock seconds]
	if {$shelly_pending > 0 && $now - $shelly_polled < 20} { return }
	if {$now - $shelly_polled < 10} { return }
	set shelly_polled $now
	if {$now - $shelly_list_time > 600} {
		set shelly_list_time $now
		if {[catch {set shelly_list [hue::extras::shelly_devices]} err]} {
			hue::write_log 2 "Shelly devices: ${err}"
			set shelly_list [list]
		}
		hue::write_log 4 "Shelly devices: ${shelly_list}"
	}
	hue::v2::aunset shelly_buf *
	set shelly_pending 0
	foreach d $shelly_list {
		foreach {ch url} $d break
		if {[catch {
			set chan [open "|[list [hue::curl_bin] --silent --max-time 3 $url]" r]
			fconfigure $chan -blocking 0 -buffering none
			set shelly_buf($ch) ""
			incr shelly_pending
			fileevent $chan readable [list shelly_read $ch $chan]
		} err]} {
			hue::write_log 2 "Shelly ${url}: ${err}"
		}
	}
}

proc shelly_read {ch chan} {
	variable shelly_pending
	variable shelly_buf
	append shelly_buf($ch) [read $chan]
	if {![eof $chan]} { return }
	catch { close $chan }
	incr shelly_pending -1
	if {$shelly_pending <= 0} {
		set pairs [list]
		foreach c [array names shelly_buf] {
			set v [hue::extras::shelly_parse $shelly_buf($c)]
			if {$v != ""} { lappend pairs $c $v }
		}
		if {[catch {set changed [hue::extras::cuxd_correct $pairs]} err]} {
			hue::write_log 2 "Shelly state: ${err}"
		} elseif {[llength $changed] > 0} {
			hue::write_log 3 "Shelly state corrected: ${changed}"
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
			# Tolerant match: case, spaces ("_"), umlauts and broken encodings do not matter
			set want [hue::v2::fold [string map {"_" " "} $sname]]
			set found ""
			foreach n [array names scene_map] {
				set have [hue::v2::fold $n]
				if {[string equal [lindex $have 0] [lindex $want 0]] || [string equal [lindex $have 1] [lindex $want 1]]} { set found $scene_map($n); break }
			}
			if {$found == ""} {
				error "Failed to find scene with name ${sname}."
			}
			set value "\"$found\""
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
			foreach k [array names ::scenevar_synced] { unset ::scenevar_synced($k) }
			foreach key [array names stream "*,chan"] {
				set b [lindex [split $key ","] 0]
				stop_eventstream $b
				set stream($b,next_try) 0
			}
			update_cuxd_device_map
			load_extras
			set ::shelly_list_time 0
			foreach k [array names ::scene_switch_last] { unset ::scene_switch_last($k) }
			set_scheduled_update [clock seconds]
			set response "Reload scheduled"
		} elseif {[string equal $cmd "reload_extras"]} {
			load_extras
			set response "OK"
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
	load_extras
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
