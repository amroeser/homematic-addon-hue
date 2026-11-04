#  HomeMatic addon to control Philips Hue Lighting
#  Update check and one-click update from GitHub releases
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

namespace eval ::hue::update {
	variable base_url "https://github.com/${::hue::update_repo}/releases/latest/download"
	if {[info exists ::env(HUE_UPDATE_URL)]} { set base_url $::env(HUE_UPDATE_URL) }
	variable work_dir "/usr/local/tmp/hue-update"
	if {[info exists ::env(HUE_UPDATE_DIR)]} { set work_dir $::env(HUE_UPDATE_DIR) }
	variable log_file "/tmp/hue-update.log"
}

proc ::hue::update::fetch {url {outfile ""}} {
	set cmd [list [::hue::curl_bin] --silent --show-error --stderr - --fail --location --connect-timeout 10 --max-time 120]
	if {$outfile != ""} {
		lappend cmd -o $outfile
	}
	lappend cmd $url
	return [eval exec $cmd]
}

# -1 / 0 / 1 like a comparison of version strings (4.0.10 > 4.0.9)
proc ::hue::update::compare {a b} {
	regsub -all {[^0-9.]} $a "" a
	regsub -all {[^0-9.]} $b "" b
	set a [split $a .]
	set b [split $b .]
	set n [llength $a]
	if {[llength $b] > $n} { set n [llength $b] }
	for {set i 0} {$i < $n} {incr i} {
		set x [lindex $a $i]
		set y [lindex $b $i]
		if {$x == ""} { set x 0 }
		if {$y == ""} { set y 0 }
		if {$x > $y} { return 1 }
		if {$x < $y} { return -1 }
	}
	return 0
}

proc ::hue::update::latest_version {} {
	variable base_url
	return [string trim [fetch "${base_url}/VERSION"]]
}

proc ::hue::update::package_url {} {
	variable base_url
	return "${base_url}/hm-hue.tar.gz"
}

# {installed latest available}
proc ::hue::update::check {} {
	set installed [::hue::version]
	set latest [latest_version]
	if {![regexp {^[0-9]+(\.[0-9]+)*$} $latest]} {
		error "Unexpected version information: [string range $latest 0 80]"
	}
	return [list $installed $latest [expr {[compare $latest $installed] > 0}]]
}

proc ::hue::update::sha256 {file} {
	foreach cmd [list [list sha256sum $file] [list openssl dgst -sha256 -r $file] [list shasum -a 256 $file]] {
		if {![catch {eval exec $cmd} out]} {
			return [string tolower [lindex [split [string trim $out] " "] 0]]
		}
	}
	error "No SHA-256 tool found"
}

# Download, verify and start the installation in the background.
# The update script restarts hued; settings are kept.
proc ::hue::update::install {} {
	variable base_url
	variable work_dir
	variable log_file
	file delete -force $work_dir
	file mkdir $work_dir
	set pkg [file join $work_dir hm-hue.tar.gz]
	fetch [package_url] $pkg
	set expected [string tolower [lindex [split [string trim [fetch "${base_url}/hm-hue.tar.gz.sha256"]] " "] 0]]
	set actual [sha256 $pkg]
	if {$expected == "" || ![string equal $expected $actual]} {
		file delete -force $work_dir
		error "Checksum of the downloaded package does not match, update aborted"
	}
	exec tar -xzf $pkg -C $work_dir
	if {![file exists [file join $work_dir update_script]]} {
		file delete -force $work_dir
		error "Downloaded package contains no update_script"
	}
	set new_version [string trim [exec cat [file join $work_dir VERSION]]]
	::hue::write_log 3 "Installing update ${new_version}"
	set platform "HM-RASPBERRYMATIC"
	catch {
		if {[regexp {PLATFORM=(\S+)} [exec cat /VERSION] -> p]} { set platform $p }
	}
	if {[info exists ::env(HUE_TEST)]} {
		# Tests only check download, checksum and unpacking
		return $new_version
	}
	# Detach, the update replaces the files of this process
	# Background job without terminal, the CGI request may end before the update
	exec /bin/sh -c "cd [::hue::v2::shq $work_dir] && chmod 755 update_script && (./update_script [::hue::v2::shq $platform] </dev/null >[::hue::v2::shq $log_file] 2>&1 &)"
	return $new_version
}
