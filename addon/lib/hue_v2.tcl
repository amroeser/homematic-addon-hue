#  HomeMatic addon to control Philips Hue Lighting
#  Philips Hue CLIP API v2 support
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
#  The addon keeps its v1 command language (light <id> bri:100 ct:300 ...).
#  This file translates those commands to CLIP v2 requests, keeps a cache of
#  all v2 resources and converts v2 state back to the v1 state model that the
#  CUxD update code understands.
#
#  Runs on Tcl 8.2 (CCU3 firmware) up to 8.6: no dict, {*}, lassign, eq/in.
#
#  CLIP v2 docs: https://developers.meethue.com/develop/hue-api-v2/

namespace eval ::hue::v2 {
	# R(<bridge>|<rid>|<path>) -> value of a cached resource (see json.tcl for paths)
	variable R
	array set R {}
	# T(<bridge>|<type>) -> list of resource ids of that type
	variable T
	array set T {}
	# idx(<bridge>,<key>) -> lookup tables, see rebuild_index
	variable idx
	array set idx {}
	# loaded(<bridge>) -> clock seconds of the last full load
	variable loaded
	array set loaded {}
	# support(<bridge>) -> {supported(0|1) checked_at}
	variable support
	array set support {}
	# Full reload of all resources at least every n seconds
	variable full_reload_interval 900
	namespace export jstr jobj
}

# ---------------------------------------------------------------------------
# Small helpers (Tcl 8.2 compatible)
# ---------------------------------------------------------------------------

proc ::hue::v2::jstr {s} { return [::hue::json::str $s] }
proc ::hue::v2::jobj {args} { return [::hue::json::objl $args] }

proc ::hue::v2::num {v {dec 2}} {
	set s [format "%.${dec}f" $v]
	if {[string first "." $s] >= 0} {
		set s [string trimright [string trimright $s 0] .]
	}
	if {[string equal $s "-0"]} { set s 0 }
	return $s
}

proc ::hue::v2::clamp {v lo hi} {
	if {$v < $lo} { return $lo }
	if {$v > $hi} { return $hi }
	return $v
}

proc ::hue::v2::maxn {a b} { if {$a > $b} { return $a }; return $b }
proc ::hue::v2::minn {a b} { if {$a < $b} { return $a }; return $b }

proc ::hue::v2::luniq {l} {
	set out [list]
	foreach x $l {
		if {[lsearch -exact $out $x] < 0} { lappend out $x }
	}
	return $out
}

# Remove array elements matching a glob pattern (array unset is Tcl 8.3+)
proc ::hue::v2::aunset {arrName pattern} {
	upvar 1 $arrName A
	foreach k [array names A $pattern] {
		unset A($k)
	}
}

proc ::hue::v2::is_uuid {s} {
	return [regexp {^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$} $s]
}

proc ::hue::v2::isnum {v} {
	return [string is double -strict $v]
}

# Strip JSON quoting from a v1 parameter value ("select" -> select)
proc ::hue::v2::plain {v} {
	set v [string trim $v]
	set n [string length $v]
	if {$n >= 2 && [string index $v 0] == "\"" && [string index $v [expr {$n - 1}]] == "\""} {
		set v [string range $v 1 [expr {$n - 2}]]
	}
	return $v
}

# exec decodes program output with the system encoding, the bridge sends UTF-8
proc ::hue::v2::utf8 {s} {
	set sys [encoding system]
	if {[string equal $sys "utf-8"]} { return $s }
	return [encoding convertfrom utf-8 [encoding convertto $sys $s]]
}

# Quote one word for /bin/sh
proc ::hue::v2::shq {s} {
	return "'[string map {' '\\''} $s]'"
}

# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

proc ::hue::v2::bridge_info {bridge_id} {
	array set bridge [::hue::get_bridge $bridge_id]
	if {$bridge(id) == ""} {
		error "Hue bridge ${bridge_id} not configured"
	}
	if {![info exists bridge(ip)] || $bridge(ip) == ""} {
		error "Hue bridge ${bridge_id} ip address not configured"
	}
	if {![info exists bridge(username)] || $bridge(username) == ""} {
		error "Hue bridge ${bridge_id} username not configured"
	}
	# CLIP v2 is HTTPS only. The v1 'port' setting is not used here.
	if {![info exists bridge(https_port)] || ![string is integer -strict $bridge(https_port)]} {
		set bridge(https_port) 443
	}
	if {![info exists bridge(tls_pubkey_sha256)]} {
		set bridge(tls_pubkey_sha256) ""
	}
	return [array get bridge]
}

proc ::hue::v2::strict_ca {} {
	set ca [file join $::hue::addon_dir etc hue-ca.pem]
	if {[string equal [string tolower $::hue::https_verify] "strict"] && [file exists $ca]} {
		return $ca
	}
	return ""
}

# TLS options for curl, depending on the global https_verify policy
#   none        : no verification
#   fingerprint : pin the bridge public key (trust on first use)
#   strict      : verify with the CA file etc/hue-ca.pem (bridge id as host name)
proc ::hue::v2::tls_args {bridge_var} {
	upvar 1 $bridge_var bridge
	set policy [string tolower $::hue::https_verify]
	set ca [strict_ca]
	if {$ca != ""} {
		return [list --cacert $ca --resolve "[string tolower $bridge(id)]:$bridge(https_port):$bridge(ip)"]
	}
	if {[string equal $policy "strict"]} {
		::hue::write_log 2 "https_verify=strict but etc/hue-ca.pem is missing, falling back to fingerprint"
		set policy "fingerprint"
	}
	if {[string equal $policy "fingerprint"]} {
		if {$bridge(tls_pubkey_sha256) == ""} {
			set bridge(tls_pubkey_sha256) [fetch_pin $bridge(id) $bridge(ip) $bridge(https_port)]
		}
		if {$bridge(tls_pubkey_sha256) != ""} {
			# The bridge certificate is self signed, pinning replaces the CA check
			return [list --insecure --pinnedpubkey "sha256//$bridge(tls_pubkey_sha256)"]
		}
		::hue::write_log 2 "Could not read TLS public key of bridge $bridge(id), connecting without verification"
	}
	return [list --insecure]
}

proc ::hue::v2::base_url {bridge_var} {
	upvar 1 $bridge_var bridge
	if {[strict_ca] != ""} {
		return "https://[string tolower $bridge(id)]:$bridge(https_port)"
	}
	return "https://$bridge(ip):$bridge(https_port)"
}

proc ::hue::v2::openssl_bin {} {
	foreach f [list /usr/bin/openssl /bin/openssl /usr/local/bin/openssl /opt/homebrew/bin/openssl] {
		if {[file executable $f]} { return $f }
	}
	return ""
}

# Read the SHA-256 pin of the bridge public key and store it (trust on first use)
proc ::hue::v2::fetch_pin {bridge_id ip port} {
	set openssl [openssl_bin]
	if {$openssl == ""} {
		::hue::write_log 3 "openssl not found, TLS key of bridge ${bridge_id} is not pinned"
		return ""
	}
	set o [shq $openssl]
	set cmd "$o s_client -connect [shq ${ip}:${port}] </dev/null 2>/dev/null | $o x509 -pubkey -noout 2>/dev/null | $o pkey -pubin -outform DER 2>/dev/null | $o dgst -sha256 -binary | $o base64"
	if {[catch {set pin [string trim [exec /bin/sh -c $cmd]]} err]} {
		::hue::write_log 2 "Failed to read TLS public key of ${ip}:${port}: ${err}"
		return ""
	}
	# An empty input produces the hash of nothing, ignore it
	if {$pin == "" || [string equal $pin "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="]} {
		return ""
	}
	::hue::write_log 3 "Pinned TLS public key of bridge ${bridge_id}: ${pin}"
	catch {::hue::set_bridge_param $bridge_id "tls_pubkey_sha256" $pin}
	return $pin
}

# Run curl. Returns {http_code body}. curl writes its errors to stdout (--stderr -),
# so Tcl 8.2's exec does not fail on stderr output.
proc ::hue::v2::curl {bridge_var method url {body ""} {timeout 10}} {
	upvar 1 $bridge_var bridge
	set cto 5
	if {$::hue::api_connect_timeout > 0} {
		set cto [maxn 1 [expr {int(ceil($::hue::api_connect_timeout / 1000.0))}]]
	}
	set cmd [list [::hue::curl_bin] --silent --show-error --stderr - --connect-timeout $cto --max-time $timeout \
		-X $method -H "hue-application-key: $bridge(username)" -H "Accept: application/json" \
		-w "\n%{http_code}"]
	foreach a [tls_args bridge] { lappend cmd $a }
	if {$body != ""} {
		lappend cmd -H "Content-Type: application/json" --data-binary $body
	}
	lappend cmd $url
	if {[catch {set out [eval exec $cmd]} err]} {
		set err [utf8 $err]
		if {[string first "public key does not match" $err] >= 0 || [string first "(90)" $err] >= 0} {
			error "TLS public key of bridge $bridge(id) changed. If you replaced or reset the bridge, read the key again in the addon settings. ([string trim $err])"
		}
		error "Request to bridge $bridge(id) failed: [string trim $err]"
	}
	set out [utf8 $out]
	set nl [string last "\n" $out]
	set code [string trim [string range $out [expr {$nl + 1}] end]]
	set data [string range $out 0 [expr {$nl - 1}]]
	return [list $code $data]
}

# Returns {http_code body}
proc ::hue::v2::request_code {type bridge_id method path {body ""}} {
	array set bridge [bridge_info $bridge_id]
	set path [string trimleft $path "/"]
	set url "[base_url bridge]/clip/v2/${path}"
	set log [expr {[string equal $::hue::api_log "all"] || [string equal $::hue::api_log $type]}]
	if {$log} {
		::hue::write_log 0 "api v2 request: ${method} /clip/v2/${path} ${body}"
	}
	set try 0
	while {1} {
		incr try
		::hue::acquire_bridge_lock $bridge_id
		set rc [catch {curl bridge $method $url $body} result]
		set einfo ""
		if {$rc} { set einfo $::errorInfo }
		::hue::release_bridge_lock $bridge_id
		if {$rc} {
			return -code error -errorinfo $einfo $result
		}
		set code [lindex $result 0]
		set data [lindex $result 1]
		# 429 = rate limit, 503 = bridge busy: wait and retry
		if {($code == 429 || $code == 503) && $try < 3} {
			::hue::write_log 3 "Bridge ${bridge_id} answered ${code}, retrying"
			after [expr {250 * $try}]
			continue
		}
		break
	}
	if {$log} {
		::hue::write_log 0 "api v2 response (${code}): ${data}"
	}
	return [list $code $data]
}

# CLIP v2 request, response body as text (for the web UI)
proc ::hue::v2::request_raw {type bridge_id method path {body ""}} {
	return [lindex [request_code $type $bridge_id $method $path $body] 1]
}

# CLIP v2 request. The parsed response is stored in array arrName (see json.tcl).
# Returns the number of entries in "data".
proc ::hue::v2::request {type bridge_id method path {body ""} {arrName ""}} {
	set r [request_code $type $bridge_id $method $path $body]
	set code [lindex $r 0]
	set data [lindex $r 1]
	if {$arrName != ""} {
		upvar 1 $arrName D
	}
	array set D {}
	if {$code == 401 || $code == 403} {
		error "Bridge ${bridge_id} rejected the application key (HTTP ${code}). Pair the bridge again."
	}
	if {$code == 404 && $data == ""} {
		error "CLIP v2 is not available on bridge ${bridge_id} (HTTP 404)"
	}
	if {[catch {::hue::json::parse $data D}]} {
		error "Bridge ${bridge_id} returned no JSON (HTTP ${code}): [string range $data 0 200]"
	}
	set errors [list]
	for {set i 0} {$i < [::hue::json::len D errors]} {incr i} {
		lappend errors [::hue::json::get D errors/$i/description]
	}
	if {$code >= 400 || ([llength $errors] > 0 && [::hue::json::len D data] == 0)} {
		if {[llength $errors] == 0} { lappend errors "HTTP ${code}" }
		error "Bridge ${bridge_id}: [join $errors {; }]"
	}
	if {[llength $errors] > 0} {
		::hue::write_log 2 "Bridge ${bridge_id} warnings for ${method} ${path}: [join $errors {; }]"
	}
	return [::hue::json::len D data]
}

# ---------------------------------------------------------------------------
# API selection
# ---------------------------------------------------------------------------

# Does the bridge speak CLIP v2? (square bridge with firmware 1948086000 or newer)
proc ::hue::v2::supported {bridge_id {force 0}} {
	variable support
	set now [clock seconds]
	if {!$force && [info exists support($bridge_id)]} {
		set ok [lindex $support($bridge_id) 0]
		set at [lindex $support($bridge_id) 1]
		# Positive results are kept for an hour, negative ones for two minutes
		if {($ok && $now - $at < 3600) || (!$ok && $now - $at < 120)} {
			return $ok
		}
	}
	set ok 0
	if {[catch {request "status" $bridge_id GET "resource/bridge"} err]} {
		::hue::write_log 3 "CLIP v2 not usable on bridge ${bridge_id}: ${err}"
	} else {
		set ok 1
	}
	set support($bridge_id) [list $ok $now]
	return $ok
}

# 1 if commands and state for this bridge go through CLIP v2
proc ::hue::v2::active {bridge_id} {
	switch -- [string tolower $::hue::api_version] {
		v1 { return 0 }
		v2 { return 1 }
		default { return [supported $bridge_id] }
	}
}

# Forget cached API support and resources (after a config change)
proc ::hue::v2::forget_all {} {
	variable support
	variable loaded
	aunset support *
	aunset loaded *
}

# ---------------------------------------------------------------------------
# Resource cache
# ---------------------------------------------------------------------------

# Value of a cached resource field
proc ::hue::v2::rget {bridge_id rid path {default ""}} {
	variable R
	if {[info exists R($bridge_id|$rid|$path)]} { return $R($bridge_id|$rid|$path) }
	return $default
}

proc ::hue::v2::rexists {bridge_id rid} {
	variable R
	return [info exists R($bridge_id|$rid|type)]
}

proc ::hue::v2::rhas {bridge_id rid path} {
	variable R
	return [info exists R($bridge_id|$rid|$path)]
}

# Copy the resources of a parsed response (array P with data/<i>/...) into the cache
proc ::hue::v2::store_parsed {bridge_id arrName} {
	variable R
	upvar 1 $arrName P
	set n [::hue::json::len P data]
	for {set i 0} {$i < $n} {incr i} {
		set rid [::hue::json::get P data/$i/id]
		set rids($i) $rid
		if {$rid != ""} {
			aunset R "$bridge_id|$rid|*"
		}
	}
	foreach key [array names P "data/*"] {
		if {[regexp {^data/([0-9]+)/(.+)$} $key -> i sub] && $rids($i) != ""} {
			set R($bridge_id|$rids($i)|$sub) $P($key)
		}
	}
}

proc ::hue::v2::rebuild_types {bridge_id} {
	variable R
	variable T
	aunset T "$bridge_id|*"
	foreach key [array names R "$bridge_id|*|type"] {
		set rid [lindex [split $key "|"] 1]
		lappend T($bridge_id|$R($key)) $rid
	}
}

proc ::hue::v2::resources {bridge_id type} {
	variable T
	if {[info exists T($bridge_id|$type)]} { return $T($bridge_id|$type) }
	return [list]
}

proc ::hue::v2::load {bridge_id} {
	variable R
	variable loaded
	request "status" $bridge_id GET "resource" "" P
	aunset R "$bridge_id|*"
	store_parsed $bridge_id P
	rebuild_types $bridge_id
	rebuild_index $bridge_id
	set loaded($bridge_id) [clock seconds]
	return [::hue::json::len P data]
}

# Load the cache if it is missing or old
proc ::hue::v2::ensure_loaded {bridge_id} {
	variable loaded
	variable full_reload_interval
	if {![info exists loaded($bridge_id)] || [clock seconds] - $loaded($bridge_id) > $full_reload_interval} {
		load $bridge_id
	}
}

# Re-read only the resource types that carry light state
proc ::hue::v2::refresh_state {bridge_id} {
	variable loaded
	if {![info exists loaded($bridge_id)]} {
		load $bridge_id
		return
	}
	foreach t {light grouped_light zigbee_connectivity} {
		catch {unset P}
		request "status" $bridge_id GET "resource/${t}" "" P
		store_parsed $bridge_id P
	}
}

# Apply one event stream message (JSON list of events). Returns 1 if resources
# were added or deleted.
proc ::hue::v2::apply_events {bridge_id data} {
	variable R
	::hue::json::parse $data E
	set structure 0
	set n [::hue::json::len E ""]
	for {set i 0} {$i < $n} {incr i} {
		set etype [::hue::json::get E $i/type]
		set m [::hue::json::len E $i/data]
		for {set j 0} {$j < $m} {incr j} {
			set rid [::hue::json::get E $i/data/$j/id]
			if {$rid == ""} { continue }
			set prefix "$i/data/$j/"
			set plen [string length $prefix]
			if {[string equal $etype "delete"]} {
				aunset R "$bridge_id|$rid|*"
				set structure 1
				continue
			}
			if {[string equal $etype "update"] && ![rexists $bridge_id $rid]} {
				continue
			}
			if {[string equal $etype "add"]} {
				aunset R "$bridge_id|$rid|*"
				set structure 1
			}
			set subs [list]
			foreach key [array names E "${prefix}*"] {
				lappend subs [string range $key $plen end]
			}
			# Lists in an update replace the old list
			foreach sub $subs {
				if {[regexp {^(.*)/#$} $sub -> lpath]} {
					aunset R "$bridge_id|$rid|$lpath/*"
				}
			}
			foreach sub $subs {
				# Partial objects must not shrink the key lists
				if {[string equal $etype "update"] && [regexp {(^|/)%$} $sub]} { continue }
				set R($bridge_id|$rid|$sub) $E($prefix$sub)
			}
		}
	}
	if {$structure} {
		rebuild_types $bridge_id
		rebuild_index $bridge_id
	}
	return $structure
}

# Lookup tables:
#   light,<v1>      -> light rid             v1_light,<rid>   -> v1 light id
#   group,<v1>      -> grouped_light rid     v1_group,<rid>   -> v1 group id
#   gl_of,<owner>   -> grouped_light rid of a room / zone / bridge_home
#   owner_of,<gl>   -> room / zone / bridge_home rid of a grouped_light
#   scene,<v1>      -> scene rid             scene_name,<lowercase name> -> scene rid
#   dev_of,<rid>    -> device rid of a service (light, sensor, ...)
#   zc_of,<device>  -> zigbee_connectivity rid of a device
proc ::hue::v2::rebuild_index {bridge_id} {
	variable idx
	aunset idx "$bridge_id,*"
	set b $bridge_id
	set home_gl ""
	foreach rid [resources $b light] {
		if {[regexp {^/lights/([0-9]+)$} [rget $b $rid id_v1] -> n]} {
			set idx($b,light,$n) $rid
			set idx($b,v1_light,$rid) $n
		}
	}
	foreach rid [resources $b grouped_light] {
		if {[regexp {^/groups/([0-9]+)$} [rget $b $rid id_v1] -> n]} {
			set idx($b,group,$n) $rid
			set idx($b,v1_group,$rid) $n
		}
		set owner [rget $b $rid owner/rid]
		if {$owner != ""} {
			set idx($b,gl_of,$owner) $rid
			set idx($b,owner_of,$rid) $owner
		}
	}
	foreach type {room zone bridge_home} {
		foreach rid [resources $b $type] {
			set n ""
			regexp {^/groups/([0-9]+)$} [rget $b $rid id_v1] -> n
			for {set i 0} {$i < [rget $b $rid services/# 0]} {incr i} {
				if {![string equal [rget $b $rid services/$i/rtype] "grouped_light"]} { continue }
				set gl [rget $b $rid services/$i/rid]
				set idx($b,gl_of,$rid) $gl
				set idx($b,owner_of,$gl) $rid
				if {$n != "" && ![info exists idx($b,group,$n)]} {
					set idx($b,group,$n) $gl
					set idx($b,v1_group,$gl) $n
				}
				if {[string equal $type "bridge_home"]} {
					set home_gl $gl
				}
			}
		}
	}
	foreach rid [resources $b scene] {
		if {[regexp {^/scenes/(.+)$} [rget $b $rid id_v1] -> n]} {
			set idx($b,scene,$n) $rid
		}
		set name [string tolower [rget $b $rid metadata/name]]
		if {$name != ""} {
			set idx($b,scene_name,$name) $rid
			# CUxD commands write spaces as "_" (scene:Abend_Essen)
			set idx($b,scene_name,[string map {" " "_"} $name]) $rid
		}
	}
	foreach rid [resources $b device] {
		for {set i 0} {$i < [rget $b $rid services/# 0]} {incr i} {
			set srid [rget $b $rid services/$i/rid]
			set idx($b,dev_of,$srid) $rid
			if {[string equal [rget $b $rid services/$i/rtype] "zigbee_connectivity"]} {
				set idx($b,zc_of,$rid) $srid
			}
		}
	}
	# v1 group 0 = all lights = bridge_home
	if {$home_gl != "" && ![info exists idx($b,group,0)]} {
		set idx($b,group,0) $home_gl
		set idx($b,v1_group,$home_gl) 0
	}
}

proc ::hue::v2::lookup {bridge_id key} {
	variable idx
	if {[info exists idx($bridge_id,$key)]} {
		return $idx($bridge_id,$key)
	}
	return ""
}

# v1 light id or light / device rid -> light rid
proc ::hue::v2::light_rid {bridge_id obj_id} {
	if {[is_uuid $obj_id]} {
		if {[string equal [rget $bridge_id $obj_id type] "light"]} { return $obj_id }
		# A device id was given: use its first light service
		for {set i 0} {$i < [rget $bridge_id $obj_id services/# 0]} {incr i} {
			if {[string equal [rget $bridge_id $obj_id services/$i/rtype] "light"]} {
				return [rget $bridge_id $obj_id services/$i/rid]
			}
		}
		return ""
	}
	return [lookup $bridge_id "light,$obj_id"]
}

# v1 group id, grouped_light rid or room / zone rid -> grouped_light rid
proc ::hue::v2::group_rid {bridge_id obj_id} {
	if {[is_uuid $obj_id]} {
		if {[string equal [rget $bridge_id $obj_id type] "grouped_light"]} { return $obj_id }
		return [lookup $bridge_id "gl_of,$obj_id"]
	}
	return [lookup $bridge_id "group,$obj_id"]
}

proc ::hue::v2::scene_rid {bridge_id scene} {
	if {[is_uuid $scene] && [string equal [rget $bridge_id $scene type] "scene"]} {
		return $scene
	}
	set rid [lookup $bridge_id "scene,$scene"]
	if {$rid == ""} {
		set rid [lookup $bridge_id "scene_name,[string tolower $scene]"]
	}
	return $rid
}

# Light rids that belong to a grouped_light
proc ::hue::v2::group_light_rids {bridge_id gl_rid} {
	set b $bridge_id
	set owner [lookup $b "owner_of,$gl_rid"]
	if {[string equal [rget $b $owner type] "bridge_home"]} {
		return [resources $b light]
	}
	set lights [list]
	for {set i 0} {$i < [rget $b $owner children/# 0]} {incr i} {
		set crid [rget $b $owner children/$i/rid]
		switch -- [rget $b $owner children/$i/rtype] {
			light { lappend lights $crid }
			device {
				for {set k 0} {$k < [rget $b $crid services/# 0]} {incr k} {
					if {[string equal [rget $b $crid services/$k/rtype] "light"]} {
						lappend lights [rget $b $crid services/$k/rid]
					}
				}
			}
		}
	}
	return [luniq $lights]
}

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------

# v1 hue (0..65535) / sat (0..254) -> xy in the gamut of the lamp
proc ::hue::v2::huesat_to_xy {hue sat gamut} {
	set h [expr {fmod(double($hue) / 65536.0 * 6.0, 6.0)}]
	set s [expr {[clamp [expr {double($sat)}] 0.0 254.0] / 254.0}]
	set i [expr {int(floor($h))}]
	set f [expr {$h - $i}]
	set p [expr {1.0 - $s}]
	set q [expr {1.0 - $s * $f}]
	set t [expr {1.0 - $s * (1.0 - $f)}]
	switch -- $i {
		0 { set r 1.0; set g $t; set b $p }
		1 { set r $q; set g 1.0; set b $p }
		2 { set r $p; set g 1.0; set b $t }
		3 { set r $p; set g $q; set b 1.0 }
		4 { set r $t; set g $p; set b 1.0 }
		default { set r 1.0; set g $p; set b $q }
	}
	set xyb [::hue::rgb_to_xybri [expr {round($r*255)}] [expr {round($g*255)}] [expr {round($b*255)}] $gamut]
	return [lrange $xyb 0 1]
}

# xy -> v1 hue (0..65535) / sat (0..254)
proc ::hue::v2::xy_to_huesat {x y gamut} {
	set rgb [::hue::xybri_to_rgb $x $y 254 $gamut]
	set r [expr {[lindex $rgb 0] / 255.0}]
	set g [expr {[lindex $rgb 1] / 255.0}]
	set b [expr {[lindex $rgb 2] / 255.0}]
	set mx [maxn [maxn $r $g] $b]
	set mn [minn [minn $r $g] $b]
	set d [expr {$mx - $mn}]
	set h 0.0
	if {$d > 0} {
		if {$mx == $r} {
			set h [expr {fmod(($g - $b) / $d + 6.0, 6.0)}]
		} elseif {$mx == $g} {
			set h [expr {($b - $r) / $d + 2.0}]
		} else {
			set h [expr {($r - $g) / $d + 4.0}]
		}
	}
	if {$mx > 0} { set s [expr {$d / $mx}] } else { set s 0.0 }
	return [list [expr {round($h / 6.0 * 65535)}] [expr {round($s * 254)}]]
}

# Colour lists: "ff0000,00ff00" and "255,0,0;0,255,0" -> items separated by ";"
proc ::hue::v2::regsub_hexlist {s} {
	if {[regexp {^[#0-9a-fA-F,; ]+$} $s] && ![regexp {[0-9]+,[0-9]+,[0-9]+} $s]} {
		return [string map {"," ";"} $s]
	}
	return $s
}

# "ff8800" or "255,136,0" -> xy in the gamut of the lamp, "" if invalid
proc ::hue::v2::color_to_xy {color gamut} {
	set color [string trimleft [string trim $color] "#"]
	if {[regexp {^([0-9a-fA-F][0-9a-fA-F])([0-9a-fA-F][0-9a-fA-F])([0-9a-fA-F][0-9a-fA-F])$} $color -> r g b]} {
		scan $r %x r
		scan $g %x g
		scan $b %x b
	} elseif {![regexp {^([0-9]+),([0-9]+),([0-9]+)$} $color -> r g b]} {
		return ""
	}
	if {$r > 255 || $g > 255 || $b > 255} { return "" }
	set xyb [::hue::rgb_to_xybri $r $g $b $gamut]
	return [jobj x [num [lindex $xyb 0] 4] y [num [lindex $xyb 1] 4]]
}

proc ::hue::v2::gamut_of {bridge_id rid} {
	set g [rget $bridge_id $rid color/gamut_type]
	if {$g == "A" || $g == "B" || $g == "C"} { return $g }
	return ""
}

# Brightness in percent -> v1 bri (1..254)
proc ::hue::v2::bri254 {pct} {
	if {$pct == ""} { return "" }
	set bri [expr {round($pct * 254.0 / 100.0)}]
	if {$pct > 0 && $bri < 1} { set bri 1 }
	return $bri
}

# ---------------------------------------------------------------------------
# State: v2 -> v1 model
# ---------------------------------------------------------------------------

proc ::hue::v2::light_reachable {bridge_id rid} {
	set dev [lookup $bridge_id "dev_of,$rid"]
	set zc [lookup $bridge_id "zc_of,$dev"]
	if {$zc == "" || ![rexists $bridge_id $zc]} {
		return "true"
	}
	if {[string equal [rget $bridge_id $zc status] "disconnected"]} {
		return "false"
	}
	return "true"
}

proc ::hue::v2::light_state {bridge_id rid} {
	set b $bridge_id
	set st(reachable) [light_reachable $b $rid]
	set st(on) [::hue::json::bool [rget $b $rid on/on]]
	set st(bri) [bri254 [rget $b $rid dimming/brightness]]
	set st(ct) [rget $b $rid color_temperature/mirek]
	set st(color_gamut_type) [gamut_of $b $rid]
	set x [rget $b $rid color/xy/x]
	set y [rget $b $rid color/xy/y]
	set st(xy) ""
	set st(hue) ""
	set st(sat) ""
	if {$x != "" && $y != ""} {
		set st(xy) [list [expr {round($x*1000.0)/1000.0}] [expr {round($y*1000.0)/1000.0}]]
		set hs [xy_to_huesat $x $y $st(color_gamut_type)]
		set st(hue) [lindex $hs 0]
		set st(sat) [lindex $hs 1]
	}
	set st(colormode) ""
	if {$st(ct) != "" && [string equal [rget $b $rid color_temperature/mirek_valid] "true"]} {
		set st(colormode) "ct"
	} elseif {$st(xy) != ""} {
		set st(colormode) "xy"
	} elseif {$st(ct) != ""} {
		set st(colormode) "ct"
	}
	set has_color [rhas $b $rid color/%]
	set has_ct [rhas $b $rid color_temperature/%]
	if {$has_color} {
		set st(type) "Extended color light"
	} elseif {$has_ct} {
		set st(type) "Color temperature light"
	} else {
		set st(type) "Dimmable light"
	}
	set st(color) [::hue::json::bool $has_color]
	set st(ct_min) [rget $b $rid color_temperature/mirek_schema/mirek_minimum]
	set st(ct_max) [rget $b $rid color_temperature/mirek_schema/mirek_maximum]
	set st(lights) [list]
	set st(api) "v2"
	set st(rid) $rid
	return [array get st]
}

proc ::hue::v2::group_state {bridge_id gl_rid} {
	set b $bridge_id
	set members [group_light_rids $b $gl_rid]
	set st(lights) [list]
	set any_reachable 0
	set src ""
	set src_on 0
	set bri_sum 0
	set bri_n 0
	set gamut ""
	set color 0
	foreach lrid $members {
		if {![rexists $b $lrid]} { continue }
		set v1 [lookup $b "v1_light,$lrid"]
		if {$v1 != ""} { lappend st(lights) $v1 } else { lappend st(lights) $lrid }
		catch {unset ls}
		array set ls [light_state $b $lrid]
		if {[string equal $ls(reachable) "true"]} { set any_reachable 1 }
		set on [string equal $ls(on) "true"]
		if {$src == "" || ($on && !$src_on)} {
			set src [array get ls]
			set src_on $on
		}
		if {$on && $ls(bri) != ""} {
			incr bri_sum $ls(bri)
			incr bri_n
		}
		if {$gamut == "" && $ls(color_gamut_type) != ""} { set gamut $ls(color_gamut_type) }
		if {[string equal $ls(color) "true"]} { set color 1 }
	}
	if {$any_reachable || [llength $members] == 0} { set st(reachable) "true" } else { set st(reachable) "false" }
	set st(on) [::hue::json::bool [rget $b $gl_rid on/on]]
	set st(bri) [bri254 [rget $b $gl_rid dimming/brightness]]
	if {$st(bri) == "" && $bri_n > 0} {
		set st(bri) [expr {$bri_sum / $bri_n}]
	}
	foreach k {ct xy hue sat colormode} { set st($k) "" }
	if {$src != ""} {
		array set cs $src
		foreach k {ct xy hue sat colormode} { set st($k) $cs($k) }
	}
	set st(color_gamut_type) $gamut
	set st(color) [::hue::json::bool $color]
	if {$color} { set st(type) "Extended color light group" } else { set st(type) "LightGroup" }
	set st(ct_min) ""
	set st(ct_max) ""
	set st(api) "v2"
	set st(rid) $gl_rid
	return [array get st]
}

# v1 style state of a light or group, from the cache
proc ::hue::v2::object_state {bridge_id obj_type obj_id} {
	ensure_loaded $bridge_id
	if {[string equal $obj_type "light"]} {
		set rid [light_rid $bridge_id $obj_id]
		if {$rid == ""} { error "Light ${obj_id} not found on bridge ${bridge_id}" }
		return [light_state $bridge_id $rid]
	}
	set rid [group_rid $bridge_id $obj_id]
	if {$rid == ""} { error "Group ${obj_id} not found on bridge ${bridge_id}" }
	return [group_state $bridge_id $rid]
}

# ---------------------------------------------------------------------------
# Commands: v1 parameters -> v2 request body
# ---------------------------------------------------------------------------

# Translate v1 parameters. Returns {body v1_params warnings}.
#   kind   : light | grouped_light
#   rid    : target resource (for current state, mirek limits, gamut)
proc ::hue::v2::translate {bridge_id kind rid plist} {
	set b $bridge_id
	foreach {k v} $plist { set p($k) [plain $v] }
	set parts [list]
	set v1 [list]
	set warnings [list]

	set duration ""
	if {[info exists p(transitiontime)] && [string is integer -strict $p(transitiontime)]} {
		set duration [expr {[maxn 0 $p(transitiontime)] * 100}]
	}
	set speed ""
	if {[info exists p(speed)]} {
		if {[isnum $p(speed)] && $p(speed) >= 0 && $p(speed) <= 1} {
			set speed [num $p(speed) 3]
		} else {
			lappend warnings "speed must be between 0 and 1"
		}
	}
	# A timed effect uses transitiontime as its own duration
	set dynparts [list]
	if {$duration != "" && ![info exists p(timed_effect)]} { lappend dynparts duration $duration }
	if {$speed != "" && ![info exists p(effect)]} { lappend dynparts speed $speed }
	set dyn ""
	if {[llength $dynparts] > 0} { set dyn [::hue::json::objl $dynparts] }

	if {[info exists p(on)] && [lsearch -exact {true false 1 0} $p(on)] < 0} {
		lappend warnings "invalid value on:$p(on), ignored"
		unset p(on)
	}
	if {[info exists p(on)]} {
		set on [::hue::json::bool $p(on)]
		lappend parts on [jobj on $on]
		if {[string equal $on "false"]} {
			# Switching off: brightness and colour would only fade before off
			if {$dyn != ""} { lappend parts dynamics $dyn }
			return [list [::hue::json::objl $parts] $v1 $warnings]
		}
	}

	# Reference light for current colour, gamut and mirek limits
	set ref $rid
	if {[string equal $kind "grouped_light"]} {
		set ref ""
		set ref_on 0
		foreach lrid [group_light_rids $b $rid] {
			if {![rexists $b $lrid]} { continue }
			set lon [string equal [rget $b $lrid on/on] "true"]
			if {$ref == "" || ($lon && !$ref_on)} {
				set ref $lrid
				set ref_on $lon
			}
		}
	}
	set gamut [gamut_of $b $ref]

	if {[info exists p(bri)] && [isnum $p(bri)] && $p(bri) > 0} {
		set pct [expr {[clamp [expr {double($p(bri))}] 1.0 254.0] * 100.0 / 254.0}]
		lappend parts dimming [jobj brightness [num $pct]]
	} elseif {[info exists p(bri_inc)] && [isnum $p(bri_inc)] && $p(bri_inc) != 0} {
		set delta [expr {[clamp [expr {abs(double($p(bri_inc)))}] 0.0 254.0] * 100.0 / 254.0}]
		if {$p(bri_inc) > 0} { set action "up" } else { set action "down" }
		lappend parts dimming_delta [jobj action [jstr $action] brightness_delta [num $delta]]
	}

	set mmin [rget $b $ref color_temperature/mirek_schema/mirek_minimum 153]
	set mmax [rget $b $ref color_temperature/mirek_schema/mirek_maximum 500]
	if {[info exists p(ct)] && [isnum $p(ct)]} {
		set ct [expr {round([clamp [expr {double($p(ct))}] $mmin $mmax])}]
		lappend parts color_temperature [jobj mirek $ct]
	} elseif {[info exists p(ct_inc)] && [isnum $p(ct_inc)] && $p(ct_inc) != 0} {
		if {$p(ct_inc) > 0} { set action "up" } else { set action "down" }
		set delta [minn 347 [expr {round(abs(double($p(ct_inc))))}]]
		lappend parts color_temperature_delta [jobj action [jstr $action] mirek_delta $delta]
	}

	if {[info exists p(xy)]} {
		set xy [string map {"\[" "" "\]" "" "," " "} $p(xy)]
		if {[llength $xy] == 2 && [isnum [lindex $xy 0]] && [isnum [lindex $xy 1]]} {
			lappend parts color [jobj xy [jobj x [num [lindex $xy 0] 4] y [num [lindex $xy 1] 4]]]
		} else {
			lappend warnings "invalid xy value: $p(xy)"
		}
	} elseif {[info exists p(hue)] || [info exists p(sat)] || [info exists p(hue_inc)] || [info exists p(sat_inc)]} {
		# v2 knows no hue / saturation: compute from current colour and convert to xy
		set cur_hue 0
		set cur_sat 254
		set cx [rget $b $ref color/xy/x]
		set cy [rget $b $ref color/xy/y]
		if {$cx != "" && $cy != ""} {
			set hs [xy_to_huesat $cx $cy $gamut]
			set cur_hue [lindex $hs 0]
			set cur_sat [lindex $hs 1]
		}
		set h $cur_hue
		set s $cur_sat
		if {[info exists p(hue)] && [isnum $p(hue)]} { set h $p(hue) }
		if {[info exists p(sat)] && [isnum $p(sat)]} { set s $p(sat) }
		if {[info exists p(hue_inc)] && [isnum $p(hue_inc)]} { set h [expr {$h + $p(hue_inc)}] }
		if {[info exists p(sat_inc)] && [isnum $p(sat_inc)]} { set s [expr {$s + $p(sat_inc)}] }
		set h [expr {int(round($h)) % 65536}]
		if {$h < 0} { incr h 65536 }
		set s [clamp [expr {round($s)}] 0 254]
		set xy [huesat_to_xy $h $s $gamut]
		lappend parts color [jobj xy [jobj x [num [lindex $xy 0] 4] y [num [lindex $xy 1] 4]]]
	}

	if {$dyn != ""} {
		lappend parts dynamics $dyn
	}

	if {[info exists p(alert)]} {
		switch -- $p(alert) {
			select - lselect - breathe { lappend parts alert [jobj action [jstr breathe]] }
			none {}
			default { lappend warnings "unsupported alert: $p(alert)" }
		}
	}

	if {[info exists p(effect)]} {
		set effect [string tolower $p(effect)]
		if {[string equal $effect "colorloop"]} {
			# No colour loop in CLIP v2, keep it for the v1 API
			lappend v1 effect "\"colorloop\""
		} elseif {[string equal $kind "light"] && $speed != "" && ![string equal $effect "none"]} {
			# Effect with speed: effects_v2
			lappend parts effects_v2 [jobj action [jobj effect [jstr $effect] parameters [jobj speed $speed]]]
		} elseif {[string equal $kind "light"]} {
			if {[string equal $effect "none"]} { set effect "no_effect" }
			lappend parts effects [jobj effect [jstr $effect]]
		} elseif {[string equal $effect "none"]} {
			lappend v1 effect "\"none\""
		} else {
			lappend warnings "effect ${effect} is only available for lights"
		}
	}

	# Colour gradient (gradient lamps): gradient:ff0000,00ff00,0000ff
	if {[info exists p(gradient)]} {
		if {![string equal $kind "light"] || ![rhas $b $rid gradient/%]} {
			lappend warnings "gradient is only available for gradient lights"
		} else {
			set points [list]
			set ok 1
			foreach c [split [regsub_hexlist $p(gradient)] ";"] {
				if {$c == ""} { continue }
				set xy [color_to_xy $c $gamut]
				if {$xy == ""} { set ok 0; break }
				lappend points [jobj color [jobj xy $xy]]
			}
			set maxp [rget $b $rid gradient/points_capable 5]
			if {!$ok || [llength $points] < 2 || [llength $points] > $maxp} {
				lappend warnings "gradient needs 2 to $maxp colours like ff0000,0000ff"
			} else {
				set g [list points [::hue::json::arr $points]]
				if {[info exists p(gradient_mode)]} { lappend g mode [jstr $p(gradient_mode)] }
				lappend parts gradient [::hue::json::objl $g]
			}
		}
	}

	# Sunrise / sunset over transitiontime (default 30 minutes)
	if {[info exists p(timed_effect)]} {
		set te [string tolower $p(timed_effect)]
		if {![string equal $kind "light"]} {
			lappend warnings "timed_effect is only available for lights"
		} elseif {[lsearch -exact {sunrise sunset no_effect none} $te] < 0} {
			lappend warnings "timed_effect must be sunrise, sunset or none"
		} else {
			if {[string equal $te "none"]} { set te "no_effect" }
			if {$duration == ""} { set duration 1800000 }
			lappend parts timed_effects [jobj effect [jstr $te] duration $duration]
		}
	}

	# Signal: signal:on_off|on_off_color|alternating|no_signal signal_duration:<s> signal_color:ff0000,0000ff
	if {[info exists p(signal)]} {
		set sig [string tolower $p(signal)]
		if {[lsearch -exact {on_off on_off_color alternating no_signal} $sig] < 0} {
			lappend warnings "signal must be on_off, on_off_color, alternating or no_signal"
		} else {
			set sd 10
			if {[info exists p(signal_duration)] && [isnum $p(signal_duration)]} { set sd $p(signal_duration) }
			set sg [list signal [jstr $sig] duration [expr {round([clamp $sd 1 65534] * 1000)}]]
			if {[info exists p(signal_color)]} {
				set cols [list]
				foreach c [split [regsub_hexlist $p(signal_color)] ";"] {
					if {$c == ""} { continue }
					set xy [color_to_xy $c $gamut]
					if {$xy != ""} { lappend cols [jobj xy $xy] }
				}
				if {[llength $cols] > 0} { lappend sg colors [::hue::json::arr $cols] }
			}
			lappend parts signaling [::hue::json::objl $sg]
		}
	}

	# Identify: the lamp blinks once
	if {[info exists p(identify)] && [lsearch -exact {true 1} $p(identify)] >= 0} {
		if {[string equal $kind "light"]} {
			lappend parts identify [jobj action [jstr identify]]
		} else {
			lappend parts alert [jobj action [jstr breathe]]
		}
	}

	foreach k [array names p] {
		if {[lsearch -exact {on bri bri_inc ct ct_inc xy hue sat hue_inc sat_inc transitiontime alert effect scene speed gradient gradient_mode timed_effect signal signal_duration signal_color identify} $k] < 0} {
			lappend warnings "parameter ${k} is not supported by CLIP v2, ignored"
		}
	}
	return [list [::hue::json::objl $parts] $v1 $warnings]
}

# Execute a v1 style command via CLIP v2. Returns a short JSON result.
#   plist: name value pairs as built by hue.tcl (values JSON encoded)
proc ::hue::v2::object_action {bridge_id obj_type obj_id plist} {
	ensure_loaded $bridge_id
	array set p $plist

	if {[info exists p(scene)]} {
		set scene [plain $p(scene)]
		set rid [scene_rid $bridge_id $scene]
		if {$rid == ""} {
			# The scene may be new: reload once
			load $bridge_id
			set rid [scene_rid $bridge_id $scene]
		}
		if {$rid == ""} {
			error "Scene ${scene} not found on bridge ${bridge_id}"
		}
		set recall [list action [jstr active]]
		if {[info exists p(transitiontime)] && [string is integer -strict [plain $p(transitiontime)]]} {
			lappend recall duration [expr {[plain $p(transitiontime)] * 100}]
		}
		if {[info exists p(bri)] && [isnum [plain $p(bri)]] && [plain $p(bri)] > 0} {
			set pct [expr {[clamp [expr {double([plain $p(bri)])}] 1.0 254.0] * 100.0 / 254.0}]
			lappend recall dimming [jobj brightness [num $pct]]
		}
		request "command" $bridge_id PUT "resource/scene/${rid}" [jobj recall [::hue::json::objl $recall]]
		return [jobj ok true api [jstr v2] scene [jstr $rid]]
	}

	if {[string equal $obj_type "light"]} {
		set kind "light"
		set rid [light_rid $bridge_id $obj_id]
	} else {
		set kind "grouped_light"
		set rid [group_rid $bridge_id $obj_id]
	}
	if {$rid == ""} {
		# Unknown id: maybe added recently
		load $bridge_id
		if {[string equal $kind "light"]} {
			set rid [light_rid $bridge_id $obj_id]
		} else {
			set rid [group_rid $bridge_id $obj_id]
		}
	}
	if {$rid == ""} {
		error "${obj_type} ${obj_id} not found on bridge ${bridge_id}"
	}
	set tr [translate $bridge_id $kind $rid $plist]
	set body [lindex $tr 0]
	set v1 [lindex $tr 1]
	foreach w [lindex $tr 2] {
		::hue::write_log 2 "${bridge_id} ${obj_type} ${obj_id}: ${w}"
	}
	if {![string equal $body "\{\}"]} {
		request "command" $bridge_id PUT "resource/${kind}/${rid}" $body
	}
	if {[llength $v1] > 0 && ![is_uuid $obj_id]} {
		# Features without v2 equivalent (colour loop) go to the v1 API
		if {[string equal $obj_type "light"]} {
			set path "lights/${obj_id}/state"
		} else {
			set path "groups/${obj_id}/action"
		}
		if {[catch {::hue::request "command" $bridge_id PUT $path [::hue::json::objl $v1]} err]} {
			::hue::write_log 2 "v1 fallback for ${obj_type} ${obj_id} failed: ${err}"
		}
	}
	return [jobj ok true api [jstr v2] rid [jstr $rid] body $body]
}

# ---------------------------------------------------------------------------
# Sensors and buttons -> system variables
# ---------------------------------------------------------------------------

proc ::hue::v2::device_name {bridge_id rid} {
	set name [rget $bridge_id $rid metadata/name]
	if {$name == ""} {
		set name [rget $bridge_id [lookup $bridge_id "dev_of,$rid"] metadata/name]
	}
	return $name
}

# Sensors as list of {sysvar value kind label}
#   kind: bool | lux | temp | button ; value in ReGa syntax
proc ::hue::v2::sensor_list {bridge_id} {
	set b $bridge_id
	set out [list]
	foreach rid [resources $b motion] {
		set v [rget $b $rid motion/motion_report/motion]
		if {$v == ""} { set v [rget $b $rid motion/motion false] }
		lappend out [list "Hue_motion_${b}_${rid}" $v bool [device_name $b $rid]]
	}
	foreach rid [resources $b light_level] {
		set v [rget $b $rid light/light_level_report/light_level]
		if {$v == ""} { set v [rget $b $rid light/light_level 1] }
		# light_level is 10000*log10(lux)+1
		set lux [expr {round(pow(10, ($v - 1) / 10000.0))}]
		lappend out [list "Hue_lux_${b}_${rid}" $lux lux [device_name $b $rid]]
	}
	foreach rid [resources $b temperature] {
		set v [rget $b $rid temperature/temperature_report/temperature]
		if {$v == ""} { set v [rget $b $rid temperature/temperature] }
		if {$v == ""} { continue }
		lappend out [list "Hue_temp_${b}_${rid}" [num $v 1] temp [device_name $b $rid]]
	}
	foreach rid [resources $b button] {
		set v [rget $b $rid button/button_report/event]
		if {$v == ""} { set v [rget $b $rid button/last_event] }
		set label [string trim "[device_name $b $rid] [rget $b $rid metadata/control_id]"]
		lappend out [list "Hue_button_${b}_${rid}" "\"${v}\"" button $label]
	}
	return $out
}

# name value pairs for system variables
proc ::hue::v2::sensor_values {bridge_id} {
	set out [list]
	foreach s [sensor_list $bridge_id] {
		lappend out [lindex $s 0] [lindex $s 1]
	}
	return $out
}

# ---------------------------------------------------------------------------
# Overview for the web UI
# ---------------------------------------------------------------------------

# JSON with lights, groups, scenes and sensors in a v1 compatible shape.
# reload 0: answer from the cache (hued keeps it current via the event stream)
proc ::hue::v2::xyjson {xy} {
	if {[llength $xy] != 2} { return "null" }
	return "\[[lindex $xy 0],[lindex $xy 1]\]"
}

proc ::hue::v2::objects_json {bridge_id {reload 1}} {
	set b $bridge_id
	if {$reload} { load $b } else { ensure_loaded $b }
	set N ::hue::json::numornull
	set lights [list]
	foreach rid [resources $b light] {
		catch {unset st}
		array set st [light_state $b $rid]
		set id [lookup $b "v1_light,$rid"]
		if {$id == ""} { set id $rid }
		lappend lights [jobj id [jstr $id] rid [jstr $rid] name [jstr [device_name $b $rid]] \
			type [jstr $st(type)] color $st(color) ct_min [$N $st(ct_min)] ct_max [$N $st(ct_max)] \
			reachable $st(reachable) on $st(on) bri [$N $st(bri)] gamut [jstr $st(color_gamut_type)] \
			colormode [jstr $st(colormode)] ct [$N $st(ct)] xy [xyjson $st(xy)] gradient [::hue::json::bool [rhas $b $rid gradient/%]]]
	}
	set groups [list]
	foreach rid [resources $b grouped_light] {
		set owner [lookup $b "owner_of,$rid"]
		catch {unset st}
		array set st [group_state $b $rid]
		set id [lookup $b "v1_group,$rid"]
		if {$id == ""} { set id $rid }
		set otype [rget $b $owner type]
		set name [rget $b $owner metadata/name]
		if {[string equal $otype "bridge_home"]} { set name "All lights" }
		set lj [list]
		foreach x $st(lights) { lappend lj [jstr $x] }
		lappend groups [jobj id [jstr $id] rid [jstr $rid] name [jstr $name] \
			type [jstr $otype] class [jstr [rget $b $owner metadata/archetype]] lights [::hue::json::arr $lj] \
			color $st(color) reachable $st(reachable) on $st(on) bri [$N $st(bri)]]
	}
	set scenes [list]
	foreach rid [resources $b scene] {
		set id ""
		regexp {^/scenes/(.+)$} [rget $b $rid id_v1] -> id
		if {$id == ""} { set id $rid }
		set grp [rget $b $rid group/rid]
		set gv1 [lookup $b "v1_group,[lookup $b gl_of,$grp]"]
		lappend scenes [jobj id [jstr $id] rid [jstr $rid] name [jstr [rget $b $rid metadata/name]] \
			group [jstr $gv1] group_name [jstr [rget $b $grp metadata/name]]]
	}
	set sensors [list]
	foreach s [sensor_list $b] {
		set name [lindex $s 0]
		set value [lindex $s 1]
		if {[string index $value 0] != "\""} { set value [jstr $value] }
		lappend sensors [jobj sysvar [jstr $name] value $value kind [jstr [lindex $s 2]] name [jstr [lindex $s 3]] \
			exists [::hue::json::bool [::hue::sysvar_exists $name]]]
	}
	return [jobj api [jstr v2] lights [::hue::json::arr $lights] groups [::hue::json::arr $groups] \
		scenes [::hue::json::arr $scenes] sensors [::hue::json::arr $sensors]]
}
