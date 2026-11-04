#!/bin/tclsh

#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2017  Jan Schneider <oss@janschneider.net>
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
package require http

# The log can contain API keys: only for logged in users
proc check_session {sid} {
	if {[info exists ::env(HUE_TEST)]} { return 1 }
	if {![regexp {@([0-9a-zA-Z]{10})@} $sid match sidnr]} { return 0 }
	if {[lindex [rega_script "Write(system.GetSessionVarStr('$sidnr'));"] 1] == ""} { return 0 }
	set request [::http::geturl "http://127.0.0.1/pages/index.htm?sid=$sid"]
	set code [::http::code $request]
	::http::cleanup $request
	return [expr {[lindex $code 1] == 200}]
}

set sid ""
if {[info exists env(QUERY_STRING)]} {
	regexp {sid=([^&]+)} $env(QUERY_STRING) -> sid
	set sid [string map {%40 @} $sid]
}
puts "Content-Type: text/plain; charset=utf-8"
if {![check_session $sid]} {
	puts "Status: 401 Unauthorized"
	puts ""
	puts "Invalid session"
} else {
	puts "Status: 200 OK"
	puts ""
	puts -nonewline [hue::read_log]
}
