#!/bin/tclsh

#  HomeMatic addon to control Philips Hue Lighting
#
#  Copyright (C) 2018  Jan Schneider <oss@janschneider.net>
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

#  Used by the CCU (Einstellungen > Zusatzsoftware) to show available updates.
#  The addon's own page offers a one-click installation.

set repo "amroeser/homematic-addon-hue"
set version_url "https://github.com/${repo}/releases/latest/download/VERSION"
set package_url "https://github.com/${repo}/releases/latest/download/hm-hue.tar.gz"

set curl "/usr/bin/curl"
if { ![file exists $curl] } { set curl "/usr/local/addons/cuxd/curl" }

if { [catch {
	set cmd ""
	if {[info exists env(QUERY_STRING)]} {
		regexp {cmd=([^&]+)} $env(QUERY_STRING) match cmd
	}
	if {$cmd == "download"} {
		puts -nonewline "Content-Type: text/html; charset=utf-8\r\n\r\n"
		puts -nonewline "<html><head><meta http-equiv=\"refresh\" content=\"0; url=${package_url}\" /></head><body><a href=\"${package_url}\">${package_url}</a></body></html>"
	} else {
		set latest_version [string trim [exec $curl --silent --show-error --stderr - --fail --location --connect-timeout 10 --max-time 30 $version_url]]
		puts -nonewline "Content-Type: text/plain; charset=utf-8\r\n\r\n"
		puts $latest_version
	}
} errormsg] } {
	puts -nonewline "Content-Type: text/plain; charset=utf-8\r\n\r\n"
	puts "Error: ${errormsg}"
}
