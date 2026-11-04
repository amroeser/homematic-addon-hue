#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2025-2026  Alexander Maximilian Roeser
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
#  Bridge system: cloud connection, Hue account, firmware updates of the
#  bridge and its devices, apps with access. Runs on Tcl 8.2 up to 8.6.

namespace eval ::hue::system {}

proc ::hue::system::jv {arrName path} {
	upvar 1 $arrName A
	if {![info exists A($path)]} { return "null" }
	set v $A($path)
	if {[lsearch -exact {true false} $v] >= 0 || [string is double -strict $v]} { return $v }
	return [::hue::json::str $v]
}

# Status as JSON for the web UI
proc ::hue::system::status_json {bridge_id} {
	set b [string tolower $bridge_id]
	::hue::json::parse [::hue::request "info" $b "GET" "config"] C
	if {[info exists C(0/error/description)]} {
		error "Bridge ${b}: $C(0/error/description)"
	}
	set j [list]
	lappend j firmware [jv C swversion] apiversion [jv C apiversion] model [jv C modelid]
	lappend j internet [jv C internetservices/internet] remote [jv C internetservices/remoteaccess] \
		time [jv C internetservices/time] swservice [jv C internetservices/swupdate]
	lappend j account [jv C portalstate/signedon] portal [jv C portalconnection]
	set upd [list state [jv C swupdate2/state] bridge [jv C swupdate2/bridge/state] \
		auto [jv C swupdate2/autoinstall/on] time [jv C swupdate2/autoinstall/updatetime] \
		checking [jv C swupdate2/checkforupdate] lastchange [jv C swupdate2/lastchange] \
		lastinstall [jv C swupdate2/bridge/lastinstall]]
	lappend j update [::hue::json::objl $upd]

	# Apps with access, newest use first. Only the start of the key is shown.
	set apps [list]
	foreach key [::hue::json::keys C whitelist] {
		set used [::hue::json::get C "whitelist/${key}/last use date"]
		lappend apps [list $used $key [::hue::json::get C "whitelist/${key}/name"] [::hue::json::get C "whitelist/${key}/create date"]]
	}
	set aj [list]
	set me [::hue::get_bridge_param $b username]
	foreach a [lsort -decreasing -index 0 $apps] {
		foreach {used key name created} $a break
		lappend aj [::hue::json::objl [list name [::hue::json::str $name] used [::hue::json::str $used] \
			created [::hue::json::str $created] key [::hue::json::str "[string range $key 0 5]..."] \
			self [::hue::json::bool [string equal $key $me]]]]
	}
	lappend j apps [::hue::json::arr $aj]

	# Devices with their update state
	set dj [list]
	if {![catch {::hue::v2::active $b} v2] && $v2} {
		::hue::v2::ensure_loaded $b
		set n [::hue::v2::request "info" $b "GET" "resource/device_software_update" "" U]
		for {set i 0} {$i < $n} {incr i} {
			set owner [::hue::json::get U data/$i/owner/rid]
			set name [::hue::v2::rget $b $owner metadata/name]
			if {$name == ""} { set name $owner }
			set pr [list]
			for {set k 0} {$k < [::hue::json::len U data/$i/problems]} {incr k} {
				lappend pr [::hue::json::str [::hue::json::get U data/$i/problems/$k]]
			}
			lappend dj [::hue::json::objl [list name [::hue::json::str $name] \
				model [::hue::json::str [::hue::v2::rget $b $owner product_data/product_name]] \
				version [::hue::json::str [::hue::v2::rget $b $owner product_data/software_version]] \
				state [::hue::json::str [::hue::json::get U data/$i/state]] problems [::hue::json::arr $pr]]]
		}
	} else {
		::hue::json::parse [::hue::request "info" $b "GET" "lights"] L
		foreach id [::hue::json::keys L ""] {
			# v1 names: no_update etc. like v2
			set st [::hue::json::get L $id/swupdate/state]
			set st [string map {noupdates no_update notupdatable no_update transferring update_pending readytoinstall ready_to_install} $st]
			lappend dj [::hue::json::objl [list name [::hue::json::str [::hue::json::get L $id/name]] \
				model [::hue::json::str [::hue::json::get L $id/productname]] \
				version [::hue::json::str [::hue::json::get L $id/swversion]] \
				state [::hue::json::str $st] problems "\[\]"]]
		}
	}
	lappend j devices [::hue::json::arr $dj]
	return [::hue::json::objl $j]
}

# Check for updates, install them, or set automatic updates (time "HH:MM")
proc ::hue::system::swupdate {bridge_id action {on ""} {time ""}} {
	set b [string tolower $bridge_id]
	switch -- $action {
		check { set body "\{\"swupdate2\":\{\"checkforupdate\":true\}\}" }
		install { set body "\{\"swupdate2\":\{\"install\":true\}\}" }
		auto {
			set v "false"
			if {[lsearch -exact {true 1} $on] >= 0} { set v "true" }
			set part "\"on\":${v}"
			if {$time != ""} {
				if {![regexp {^([01][0-9]|2[0-3]):([0-5][0-9])$} $time]} { error "Invalid time" }
				append part ",\"updatetime\":\"T${time}:00\""
			}
			set body "\{\"swupdate2\":\{\"autoinstall\":\{${part}\}\}\}"
		}
		default { error "Invalid action" }
	}
	set resp [::hue::request "command" $b "PUT" "config" $body]
	::hue::json::parse $resp R
	if {[info exists R(0/error/description)]} { error "Bridge ${b}: $R(0/error/description)" }
	return $resp
}
