#!/bin/tclsh

#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2020  Jan Schneider <oss@janschneider.net>
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
#  Runs on Tcl 8.2 (CCU3 firmware) up to 8.6.

set addon_dir "/usr/local/addons/hue"
if {[info exists ::env(HUE_ADDON_DIR)]} { set addon_dir $::env(HUE_ADDON_DIR) }
source [file join $addon_dir lib hue.tcl]
source [file join $addon_dir lib update.tcl]
package require http

namespace import ::hue::v2::jstr ::hue::v2::jobj

proc urldecode {s} {
	set s [string map {+ " " "\\" "\\\\" "\[" "\\\[" "\]" "\\\]" "\$" "\\\$"} $s]
	regsub -all {%([0-9a-fA-F][0-9a-fA-F])} $s {\\u00\1} s
	return [encoding convertfrom utf-8 [subst -novariables -nocommands $s]]
}

proc jbool {v} { return [::hue::json::bool $v] }

proc jarr {items} { return [::hue::json::arr $items] }

# Value from the request body (array B, see json.tcl), with default
proc arg {key {default ""}} {
	global B
	if {[info exists B($key)] && $B($key) != ""} {
		return $B($key)
	}
	return $default
}

proc has_arg {key} {
	global B
	return [expr {[info exists B($key)] || [info exists B($key/#)] || [info exists B($key/%)]}]
}

proc is_true {v} {
	return [expr {[lsearch -exact {true 1} $v] >= 0}]
}

proc get_http_header {request header_name} {
	upvar $request req
	set header_name [string toupper $header_name]
	array set meta $req(meta)
	foreach header [array names meta] {
		if {[string equal $header_name [string toupper $header]]} {
			return $meta($header)
		}
	}
	return ""
}

proc get_session {sid} {
	if {[regexp {@([0-9a-zA-Z]{10})@} $sid match sidnr]} {
		return [lindex [rega_script "Write(system.GetSessionVarStr('$sidnr'));"] 1]
	}
	return ""
}

proc check_session {sid} {
	if {[info exists ::env(HUE_TEST)]} {
		return 1
	}
	if {[get_session $sid] != ""} {
		# check and renew session
		set url "http://127.0.0.1/pages/index.htm?sid=$sid"
		set request [::http::geturl $url]
		set code [::http::code $request]
		::http::cleanup $request
		if {[lindex $code 1] == 200} {
			return 1
		}
	}
	return 0
}

proc login {username password} {
	set request [::http::geturl "http://127.0.0.1/login.htm" -query [::http::formatQuery tbUsername $username tbPassword $password]]
	set location [get_http_header $request "location"]
	::http::cleanup $request
	if {[string first "error" $location] != -1} {
		error "Invalid username oder password" "Unauthorized" 401
	}
	if {![regexp {sid=@([0-9a-zA-Z]{10})@} $location match sid]} {
		error "Too many sessions" "Service Unavailable" 503
	}
	return $sid
}

proc hued_running {} {
	foreach cmd {{pidof hued.tcl} {pidof -x hued.tcl} {pgrep -f hued.tcl}} {
		if {![catch {eval exec $cmd} pid] && [string trim $pid] != ""} {
			return [lindex [string trim $pid] 0]
		}
	}
	return ""
}

# Run hue.tcl with the given arguments (a Tcl list, no shell involved)
proc run_hue_command {args_list language} {
	set ::env(LANGUAGE) $language
	set cmd [concat [list [info nameofexecutable] [file join $::hue::addon_dir hue.tcl]] $args_list]
	# stderr is collected by sh, 2>@1 needs Tcl 8.4
	set sh "exec"
	foreach a $cmd { append sh " [hue::v2::shq $a]" }
	append sh " 2>&1"
	set exitcode [catch {exec /bin/sh -c $sh} output]
	regsub "\nchild process exited abnormally$" $output "" output
	return [jobj exitcode $exitcode output [jstr $output]]
}

proc bridge_json {bridge_id} {
	array set b [hue::get_bridge $bridge_id]
	set parts [list id [jstr $bridge_id]]
	foreach k [lsort [array names b]] {
		if {[string equal $k "id"] || [string equal $k "key"]} { continue }
		lappend parts $k [jstr $b($k)]
	}
	set api "v1"
	if {![catch {hue::v2::supported $bridge_id 1} ok] && $ok} { set api "v2" }
	lappend parts api_available [jstr $api]
	return [::hue::json::objl $parts]
}

# Rooms and scenes with more lamps, with names and current state
proc extras_json {b {with_state 1}} {
	set rooms [list]
	set scenes [list]
	set channels [list]
	set follow [list]
	foreach e [hue::extras::all] {
		foreach {kind eb rid entries} $e break
		if {![string equal $eb $b]} { continue }
		if {[string equal $kind "follow"]} { lappend follow $rid [jstr $entries]; continue }
		foreach x $entries {
			if {[lsearch -exact $channels [lindex $x 0]] < 0} { lappend channels [lindex $x 0] }
		}
		if {[string equal $kind "room"]} { lappend rooms $rid $entries } else { lappend scenes $rid $entries }
	}
	array set names {}
	array set states {}
	if {[llength $channels] > 0} {
		array set names [hue::extras::names $channels]
		if {$with_state} { array set states [hue::extras::states $channels] }
	}
	set ro [list]
	foreach {rid entries} $rooms {
		set items [list]
		foreach x $entries {
			set ch [lindex $x 0]
			set name $ch
			if {[info exists names($ch)]} { set name $names($ch) }
			set st "null"
			if {[info exists states($ch)] && $states($ch) != ""} { set st [jbool [is_true $states($ch)]] }
			lappend items [jobj channel [jstr $ch] mode [jstr [lindex $x 1]] name [jstr $name] on $st]
		}
		lappend ro $rid [jarr $items]
	}
	set so [list]
	foreach {rid entries} $scenes {
		set items [list]
		foreach x $entries {
			lappend items [jobj channel [jstr [lindex $x 0]] value [jstr [lindex $x 1]]]
		}
		lappend so $rid [jarr $items]
	}
	return [jobj rooms [::hue::json::objl $ro] scenes [::hue::json::objl $so] follow [::hue::json::objl $follow]]
}

proc process {} {
	global env B
	set path [list]
	set sid ""
	set live 0
	if {[info exists env(QUERY_STRING)]} {
		foreach pair [split $env(QUERY_STRING) "&"] {
			if {[regexp {^([^=]+)=(.*)$} $pair -> name value]} {
				set value [urldecode $value]
				if {[string equal $name "sid"]} {
					set sid $value
				} elseif {[string equal $name "path"]} {
					set path [split [string trim $value "/"] "/"]
				} elseif {[string equal $name "live"]} {
					set live [is_true $value]
				}
			}
		}
	}
	set method "GET"
	if {[info exists env(REQUEST_METHOD)]} { set method $env(REQUEST_METHOD) }

	set raw ""
	if {[info exists env(CONTENT_LENGTH)] && [string is integer -strict $env(CONTENT_LENGTH)] && $env(CONTENT_LENGTH) > 0} {
		fconfigure stdin -translation binary -encoding utf-8
		set raw [read stdin $env(CONTENT_LENGTH)]
	}
	array set B {}
	set trimmed [string trim $raw]
	if {$trimmed != "" && ![string equal $trimmed "null"]} {
		if {[catch {::hue::json::parse $raw B}]} {
			error "Invalid JSON in request" "Bad Request" 400
		}
	}

	set p0 [lindex $path 0]
	set plen [llength $path]

	if {[string equal $p0 "login"]} {
		return [jstr [login [arg username] [arg password]]]
	}
	if {![check_session $sid]} {
		error "Invalid session" "Unauthorized" 401
	}

	switch -- $p0 {
		get_session {
			return [jstr [get_session $sid]]
		}
		version {
			return [jstr [hue::version]]
		}
		test-command {
			# {"args": [...]} or a command line {"command": "/usr/local/addons/hue/hue.tcl ..."}
			set language [arg language "en"]
			if {[info exists B(args/#)]} {
				set cmd_args [list]
				for {set i 0} {$i < $B(args/#)} {incr i} {
					lappend cmd_args [arg args/$i]
				}
			} else {
				set command [string trim [arg command]]
				if {[catch {llength $command}] || ![regexp {^[^ ]*hue\.tcl$} [lindex $command 0]]} {
					return [jobj exitcode 1 output [jstr "Invalid command: ${command}"]]
				}
				set cmd_args [lrange $command 1 end]
			}
			return [run_hue_command $cmd_args $language]
		}
		discover-bridges {
			set items [list]
			foreach b [hue::discover_bridges] {
				lappend items [jobj ip [jstr [lindex $b 0]] port [lindex $b 1]]
			}
			return [jarr $items]
		}
		establish-link {
			set ip [arg ip]
			set port [arg port 80]
			if {$ip == "" || ![string is integer -strict $port]} { error "IP address or port missing" "Bad Request" 400 }
			set link [hue::api_establish_link $ip $port]
			set username [lindex $link 0]
			set clientkey [lindex $link 1]
			::hue::json::parse [hue::api_request "info" $ip $port $username "GET" "config"] C
			set name [::hue::json::get C name]
			set bridgeid [string tolower [::hue::json::get C bridgeid]]
			catch { hue::api_request "command" $ip $port $username "PUT" "groups/0/action" "\{\"alert\":\"select\"\}" }
			return [jobj username [jstr $username] clientkey [jstr $clientkey] name [jstr $name] bridgeid [jstr $bridgeid] port $port \
				apiversion [jstr [::hue::json::get C apiversion]] modelid [jstr [::hue::json::get C modelid]]]
		}
		rgb-to-xybri {
			set r [hue::rgb_to_xybri [arg red 0] [arg green 0] [arg blue 0] [arg color_gamut]]
			return [jobj x [lindex $r 0] y [lindex $r 1] bri [lindex $r 2]]
		}
		get-cuxd-device-map {
			set details [hue::get_cuxd_device_details]
			# Names as shown in the CCU, one ReGa call for all devices
			set chs [list]
			foreach d $details {
				set a [lindex $d 0]
				if {[string first ":" $a] < 0} { append a ":1" }
				lappend chs "CUxD.${a}"
			}
			array set names {}
			catch { array set names [hue::extras::names $chs] }
			set items [list]
			foreach d $details {
				foreach {cuxd_device bridge_id type id scene} $d break
				set a $cuxd_device
				if {[string first ":" $a] < 0} { append a ":1" }
				set name ""
				if {[info exists names(CUxD.$a)]} { regsub {:[0-9]+$} $names(CUxD.$a) "" name }
				lappend items [jobj bridge_id [jstr $bridge_id] type [jstr $type] id [jstr $id] cuxd_device [jstr $cuxd_device] scene [jstr $scene] name [jstr $name]]
			}
			return [jarr $items]
		}
		get-used-cuxd-device-serials {
			return [jarr [hue::get_used_cuxd_device_serials [arg dtype 28] [arg dtype2 0]]]
		}
		create-cuxd-device {
			set type [arg type]
			set serial [arg serial 0]
			set name [arg name]
			set bridge_id [arg bridge_id]
			set obj_type [arg obj_type]
			set obj_id [arg obj_id]
			set transitiontime [arg transitiontime]
			set scene [arg scene]
			if {[string equal $type "scene"] && ($scene == "" || ![string equal $obj_type "group"] || [regexp {["'\\;\n\r]} $scene])} {
				error "Invalid scene" "Bad Request" 400
			}
			if {[lsearch -exact {switch rgbw dimmer scene} $type] < 0 || [lsearch -exact {light group} $obj_type] < 0 \
					|| ![regexp {^[0-9a-fA-F\-]+$} $obj_id] || ![regexp {^[0-9a-zA-Z]+$} $bridge_id]} {
				error "Invalid device type or object" "Bad Request" 400
			}
			if {![string is integer -strict $serial] || ($transitiontime != "" && ![string is integer -strict $transitiontime])} {
				error "Invalid serial or transition time" "Bad Request" 400
			}
			if {[regexp {['"\\]} $name]} {
				error "The name must not contain quotes or backslashes" "Bad Request" 400
			}
			# Bulk creation: never create a second device for the same light or group
			if {[is_true [arg skip_existing false]]} {
				set existing [hue::find_cuxd_devices $bridge_id $obj_type $obj_id]
				if {[llength $existing] > 0} {
					return [jobj device [jstr [lindex $existing 0]] created false]
				}
			}
			if {[string equal $type "dimmer"]} {
				set color [is_true [arg color false]]
				set res [hue::create_cuxd_dimmer_device $sid $serial $name $bridge_id $obj_type $obj_id [arg ct_min 153] [arg ct_max 500] $color $transitiontime]
			} else {
				set res [hue::create_cuxd_device $sid $type $serial $name $bridge_id $obj_type $obj_id $transitiontime $scene]
			}
			catch { hue::hued_command "reload" }
			return [jobj device [jstr $res] created true]
		}
		create-sysvars {
			# Create system variables for all sensors of a bridge
			set bridge_id [string tolower [arg bridge_id]]
			if {![regexp {^[0-9a-z]+$} $bridge_id]} { error "Invalid bridge id" "Bad Request" 400 }
			hue::v2::load $bridge_id
			set created 0
			foreach s [hue::v2::sensor_list $bridge_id] {
				if {[string equal [hue::create_sysvar [lindex $s 0] [lindex $s 2] "Hue [lindex $s 3]"] "created"]} { incr created }
			}
			catch { hue::hued_command "reload" }
			return [jobj created $created]
		}
		config {
			if {$plen == 1 && [string equal $method "GET"]} {
				return [hue::get_config_json]
			}
			if {[string equal [lindex $path 1] "global"] && [string equal $method "PUT"]} {
				set settings [list]
				foreach {k spec} [hue::global_config_keys] {
					if {[info exists B($k)]} {
						lappend settings $k $B($k)
					}
				}
				if {[catch {hue::update_global_config $settings} err]} {
					error $err "Bad Request" 400
				}
				catch { hue::hued_command "reload" }
				return [jstr "Global config successfully updated"]
			}
			if {$plen == 3 && [string equal [lindex $path 1] "bridge"]} {
				set id [string tolower [lindex $path 2]]
				if {![regexp {^[0-9a-z]+$} $id]} { error "Invalid bridge id" "Bad Request" 400 }
				if {[string equal $method "PUT"]} {
					foreach k {name ip username} {
						if {[regexp "\[\n\r\]" [arg $k]]} { error "Invalid ${k}" "Bad Request" 400 }
					}
					set port [arg port 80]
					if {![string is integer -strict $port]} { error "Invalid port" "Bad Request" 400 }
					hue::create_bridge $id [arg name] [arg ip] [arg username] $port
					foreach k {clientkey https_port} {
						if {[regexp {^[0-9a-zA-Z]+$} [arg $k]]} { hue::set_bridge_param $id $k [arg $k] }
					}
					catch { hue::hued_command "reload" }
					return [jstr "Bridge ${id} successfully saved"]
				} elseif {[string equal $method "DELETE"]} {
					hue::delete_bridge $id
					catch { hue::hued_command "reload" }
					return [jstr "Bridge ${id} successfully deleted"]
				}
			}
		}
		bridges {
			set id [string tolower [lindex $path 1]]
			set action [lindex $path 2]
			if {$plen != 3 || ![regexp {^[0-9a-z]+$} $id]} { error "invalid request" "Not found" 404 }
			switch -- $action {
				info {
					return [bridge_json $id]
				}
				objects {
					# live=1: quick answer from hued's cache (polled by the UI), else a fresh load
					if {$live} {
						if {![catch {hue::hued_command "objects" [list $id]} r] && [string index [string trim $r] 0] == "\{"} {
							return [string trim $r]
						}
					}
					return [hue::objects_json $id]
				}
				scene {
					# New scene in a room or zone from a template of the web UI
					if {![string equal $method "POST"]} { error "POST required" "Method Not Allowed" 405 }
					if {![hue::v2::active $id]} { error "Needs the Hue API v2" "Bad Request" 400 }
					set colors [list]
					foreach c [split [arg colors] ","] { if {[string trim $c] != ""} { lappend colors [string trim $c] } }
					if {[catch {hue::v2::create_scene $id [arg group] [arg name] [arg bri 100] [arg ct] $colors} res]} {
						if {[string match "Scene * exists" $res]} { error $res "Conflict" 409 }
						error $res "Bad Request" 400
					}
					return [jobj ok true rid [jstr $res]]
				}
				system {
					# Cloud, Hue account, firmware updates, apps with access
					return [hue::system::status_json $id]
				}
				swupdate {
					if {![string equal $method "POST"]} { error "POST required" "Method Not Allowed" 405 }
					if {[catch {hue::system::swupdate $id [arg action] [arg on] [arg time]} err]} {
						error $err "Bad Request" 400
					}
					return [jstr "OK"]
				}
				repin {
					# Read the TLS key again, e.g. after replacing the bridge
					hue::set_bridge_param $id "tls_pubkey_sha256" ""
					array set b [hue::v2::bridge_info $id]
					set pin [hue::v2::fetch_pin $id $b(ip) $b(https_port)]
					catch { hue::hued_command "reload" }
					return [jobj pin [jstr $pin]]
				}
				request {
					# Raw API request from the UI. data is a JSON document as string.
					set rmethod [string toupper [arg method GET]]
					set rpath [string trim [arg path]]
					set data [arg data]
					if {[lsearch -exact {GET PUT POST DELETE} $rmethod] < 0} { error "Invalid method" "Bad Request" 400 }
					if {[regexp {^/?(clip/v2/)?resource(/|$)} $rpath]} {
						regsub {^/?(clip/v2/)?} $rpath "" rpath
						return [hue::v2::request_raw "command" $id $rmethod $rpath $data]
					}
					set resp [hue::request "command" $id $rmethod $rpath $data]
					if {[regexp {^[ \t\r\n]*<} $resp]} {
						error "Bridge response is not JSON: [string range $resp 0 200]" "Bad Gateway" 502
					}
					return $resp
				}
			}
		}
		flows {
			# Flow designer: the CCU programs as trigger -> program -> target
			set a1 [lindex $path 1]
			set a2 [lindex $path 2]
			if {$plen == 1 && [string equal $method "GET"]} {
				return [hue::flows::programs_json]
			}
			if {[string equal $a1 "catalog"]} {
				return [hue::flows::catalog_json]
			}
			if {[string equal $a1 "links"]} {
				return [hue::flows::links_json]
			}
			# Editor: one program as flow, save a flow, values for the preview, run
			if {$plen == 2 && [regexp {^[0-9]+$} $a1] && [string equal $method "GET"]} {
				if {[catch {hue::flows::flow_json $a1} res]} { error $res "Not Found" 404 }
				return $res
			}
			if {[regexp {^[0-9]+$} $a1] && [string equal $a2 "backups"] && [string equal $method "GET"]} {
				if {$plen == 4} {
					if {[catch {hue::flows::backup_flow_json $a1 [lindex $path 3]} res]} { error $res "Not Found" 404 }
					return $res
				}
				return [hue::flows::backups_json $a1]
			}
			if {![string equal $method "POST"]} { error "POST required" "Method Not Allowed" 405 }
			if {[string equal $a1 "save"]} {
				if {[catch {hue::flows::save B [arg id] [arg rev]} res]} {
					if {[string equal $::errorCode "409"]} { error $res "Conflict" 409 }
					error $res "Bad Request" 400
				}
				return [jobj id [jstr [lindex $res 0]] rev [jstr [lindex $res 1]]]
			}
			if {[string equal $a1 "values"]} {
				set dps [list]
				for {set i 0} {$i < [::hue::json::len B dps]} {incr i} { lappend dps [arg dps/$i] }
				if {[catch {hue::flows::values_json $dps} res]} { error $res "Bad Request" 400 }
				return $res
			}
			if {[regexp {^[0-9]+$} $a1] && [string equal $a2 "run"]} {
				if {[catch {hue::flows::run $a1} res]} { error $res "Bad Request" 400 }
				return [jobj id [jstr $res]]
			}
			set triggers [list]
			for {set i 0} {$i < [::hue::json::len B triggers]} {incr i} { lappend triggers [arg triggers/$i] }
			set actions [list]
			for {set i 0} {$i < [::hue::json::len B actions]} {incr i} { lappend actions [list [arg actions/$i/dp] [arg actions/$i/value]] }
			set active [expr {![has_arg active] || [is_true [arg active]]}]
			if {[catch {
				if {[string equal $a1 "create"]} {
					set id [hue::flows::create [arg name] $triggers $actions $active]
				} elseif {[regexp {^[0-9]+$} $a1] && [string equal $a2 "update"]} {
					set id [hue::flows::update $a1 [arg name] $triggers $actions $active]
				} elseif {[regexp {^[0-9]+$} $a1] && [string equal $a2 "active"]} {
					hue::flows::set_active $a1 [is_true [arg on]]
					set id $a1
				} elseif {[regexp {^[0-9]+$} $a1] && [string equal $a2 "delete"]} {
					hue::flows::delete $a1
					set id $a1
				} else {
					error "invalid request"
				}
			} err]} {
				error $err "Bad Request" 400
			}
			return [jobj id [jstr $id]]
		}
		extras {
			# More lamps in a room: switch actuators of the CCU
			set b [string tolower [lindex $path 1]]
			set action [lindex $path 2]
			if {![regexp {^[0-9a-z]+$} $b]} { error "Invalid bridge id" "Bad Request" 400 }
			if {$plen == 2 && [string equal $method "GET"]} {
				return [extras_json $b]
			}
			switch -- $action {
				candidates {
					set items [list]
					foreach c [hue::extras::candidates] {
						foreach {ch name rooms dtype state} $c break
						set rl [list]
						foreach r $rooms { lappend rl [jstr $r] }
						lappend items [jobj channel [jstr $ch] name [jstr $name] rooms [jarr $rl] type [jstr $dtype] on [jbool [is_true $state]]]
					}
					return [jarr $items]
				}
				room - scene {
					if {![string equal $method "POST"]} { error "POST required" "Method Not Allowed" 405 }
					set rid [arg $action]
					set ch [arg channel]
					set mode [arg mode]
					if {![hue::extras::valid_channel $ch] || ![hue::extras::valid_rid $rid]} { error "Invalid channel or ${action}" "Bad Request" 400 }
					if {[string equal $action "room"]} { set ok {both on off none} } else { set ok {on off} }
					if {$mode != "" && [lsearch -exact $ok $mode] < 0} { error "Invalid mode" "Bad Request" 400 }
					hue::extras::set_entry $action $b $rid $ch $mode
					catch { hue::hued_command "reload_extras" }
					return [extras_json $b 0]
				}
				follow {
					if {![string equal $method "POST"]} { error "POST required" "Method Not Allowed" 405 }
					if {[catch {hue::extras::set_follow $b [arg room] [arg mode]} err]} { error $err "Bad Request" 400 }
					catch { hue::hued_command "reload_extras" }
					return [extras_json $b 0]
				}
				switch {
					if {![string equal $method "POST"]} { error "POST required" "Method Not Allowed" 405 }
					set ch [arg channel]
					if {![hue::extras::valid_channel $ch]} { error "Invalid channel" "Bad Request" 400 }
					hue::extras::set_states [list $ch [is_true [arg on false]]]
					return [jobj channel [jstr $ch] on [jbool [is_true [arg on false]]]]
				}
			}
		}
		hued {
			switch -- [lindex $path 1] {
				pid {
					return [jstr [hued_running]]
				}
				status {
					set st ""
					catch { set st [hue::hued_command "status"] }
					return [jstr $st]
				}
				restart {
					exec [file join $::hue::addon_dir hued.tcl]
					after 500
					return [jstr "OK"]
				}
			}
		}
		truncate-log {
			hue::truncate_log
			return [jstr "OK"]
		}
		update {
			switch -- [lindex $path 1] {
				check {
					set u [hue::update::check]
					return [jobj installed [jstr [lindex $u 0]] latest [jstr [lindex $u 1]] available [jbool [lindex $u 2]] \
						url [jstr "https://github.com/${::hue::update_repo}/releases/latest"]]
				}
				install {
					if {![string equal $method "POST"]} { error "POST required" "Method Not Allowed" 405 }
					return [jobj installing [jstr [hue::update::install]]]
				}
			}
		}
	}
	error "invalid request" "Not found" 404
}

fconfigure stdout -translation binary -encoding utf-8
array set http_status {"Bad Request" 400 "Unauthorized" 401 "Not found" 404 "Method Not Allowed" 405 "Bad Gateway" 502 "Service Unavailable" 503}
if {[catch {process} result]} {
	set status 500
	if {[regexp {^[0-9]+$} $errorCode]} {
		set status $errorCode
	} elseif {[info exists http_status($errorCode)]} {
		set status $http_status($errorCode)
	}
	puts -nonewline "Content-Type: application/json\r\nStatus: ${status}\r\n\r\n"
	puts -nonewline [jobj error [jstr $result]]
} else {
	puts -nonewline "Content-Type: application/json\r\nStatus: 200 OK\r\n\r\n"
	puts -nonewline $result
}
