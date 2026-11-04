#  HomeMatic addon to control Philips Hue Lighting
#  Minimal JSON reader / writer for Tcl 8.2 (CCU3 firmware) up to 8.6 / 9.0
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
#  The CCU3 firmware ships Tcl 8.2 without dict, {*}, lassign, "in"/"eq"
#  operators and without tcllib. This file only uses commands available in 8.2.
#
#  A JSON document is flattened into a Tcl array. Keys are paths joined by "/":
#     {"data":[{"id":"x","on":{"on":true}}]}
#  becomes
#     A(data/#) = 1             number of list elements
#     A(data/0/%) = {id on}     keys of an object
#     A(data/0/id) = x
#     A(data/0/on/%) = on
#     A(data/0/on/on) = true
#  The root object's keys are in A(%), a root list's length in A(#).
#  Strings are decoded, true/false stay as words, null becomes "".

namespace eval ::hue::json {}

# Join a path and a key
proc ::hue::json::jp {path key} {
	if {$path == ""} { return $key }
	return "${path}/${key}"
}

# Split JSON text into tokens: list of type value pairs
#   p : punctuation  < > ( )  for { } [ ]
#   s : string (decoded)
#   l : literal (number, true, false, null)
proc ::hue::json::tokenize {text} {
	set toks [list]
	set instr 0
	set pending 0
	set cur ""
	foreach part [split $text "\""] {
		if {!$instr} {
			set part [string map {"\{" " < " "\}" " > " "\[" " ( " "\]" " ) " ":" " " "," " " "\t" " " "\n" " " "\r" " "} $part]
			foreach w [split $part " "] {
				if {$w == ""} { continue }
				if {$w == "<" || $w == ">" || $w == "(" || $w == ")"} {
					lappend toks p $w
				} else {
					lappend toks l $w
				}
			}
			set instr 1
			set cur ""
		} else {
			append cur $part
			# A quote after an odd number of backslashes belongs to the string
			if {[regexp {(\\+)$} $cur -> bs] && [string length $bs] % 2 == 1} {
				append cur "\""
				set pending 1
				continue
			}
			set pending 0
			if {[string first "\\" $cur] >= 0} {
				set cur [subst -nocommands -novariables $cur]
			}
			lappend toks s $cur
			set instr 0
		}
	}
	# Valid JSON ends with a structural part (an even number of real quotes)
	if {!$instr || $pending} {
		error "Invalid JSON: unterminated string"
	}
	return $toks
}

# Parse JSON text into array arrName below path root
proc ::hue::json::parse {text arrName {root ""}} {
	upvar 1 $arrName A
	set toks [tokenize $text]
	# Stack of open containers: each frame is {kind path count}
	set stack [list]
	set kind ""
	set path $root
	set count 0
	set expect_key 0
	set key ""
	set done 0
	foreach {t v} $toks {
		if {$done} {
			error "Invalid JSON: data after the end"
		}
		if {$kind == "o" && $expect_key} {
			if {$t == "s"} {
				set key $v
				set expect_key 0
				continue
			}
			if {$t == "p" && $v == ">"} {
				set closed 1
			} else {
				error "Invalid JSON: object key expected"
			}
		} elseif {$t == "p" && ($v == ">" || $v == ")")} {
			if {$v == ">"} {
				# kind o without expect_key: a key is waiting for its value
				error "Invalid JSON: unexpected $v"
			}
			if {$kind != "a"} {
				error "Invalid JSON: unexpected $v"
			}
			set closed 1
		} else {
			set closed 0
		}

		if {$closed} {
			# Finish the current container, continue in the parent
			if {$kind == "a"} { set A([jp $path #]) $count }
			set top [lindex $stack end]
			set stack [lreplace $stack end end]
			if {[llength $top] == 0} {
				set done 1
				set kind ""
				continue
			}
			set kind [lindex $top 0]
			set path [lindex $top 1]
			set count [lindex $top 2]
			set key [lindex $top 3]
			if {$kind == ""} {
				# The root container is complete
				set done 1
				continue
			}
			# The closed container was a value of the parent
		} else {
			# A value: compute its path
			if {$kind == "o"} {
				set vpath [jp $path $key]
				lappend A([jp $path %]) $key
			} elseif {$kind == "a"} {
				set vpath [jp $path $count]
			} else {
				set vpath $path
			}
			if {$t == "p" && $v == "<"} {
				lappend stack [list $kind $path $count $key]
				set kind "o"
				set path $vpath
				set A([jp $path %]) [list]
				set count 0
				set expect_key 1
				continue
			}
			if {$t == "p" && $v == "("} {
				lappend stack [list $kind $path $count $key]
				set kind "a"
				set path $vpath
				set count 0
				set A([jp $path #]) 0
				continue
			}
			if {$t == "p"} {
				error "Invalid JSON: unexpected $v"
			}
			if {$t == "l" && $v == "null"} { set v "" }
			set A($vpath) $v
			if {$kind == ""} {
				set done 1
				continue
			}
		}
		# A value of the current container is complete
		if {$kind == "o"} {
			set expect_key 1
		} elseif {$kind == "a"} {
			incr count
		}
	}
	if {[llength $stack] > 0 || (!$done && $kind != "")} {
		error "Invalid JSON: unexpected end"
	}
}

# Value at path or default
proc ::hue::json::get {arrName path {default ""}} {
	upvar 1 $arrName A
	if {[info exists A($path)]} { return $A($path) }
	return $default
}

# Number of elements of the list at path (0 if none)
proc ::hue::json::len {arrName path} {
	upvar 1 $arrName A
	if {[info exists A([jp $path #])]} { return $A([jp $path #]) }
	return 0
}

# Keys of the object at path
proc ::hue::json::keys {arrName path} {
	upvar 1 $arrName A
	if {[info exists A([jp $path %])]} { return $A([jp $path %]) }
	return [list]
}

# --- writing --------------------------------------------------------------

proc ::hue::json::str {s} {
	return "\"[string map {"\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t" "\b" "\\b" "\f" "\\f"} $s]\""
}

# Object from a list of key / raw JSON value pairs
proc ::hue::json::objl {pairs} {
	set parts [list]
	foreach {k v} $pairs {
		lappend parts "[str $k]:${v}"
	}
	return "\{[join $parts ,]\}"
}

proc ::hue::json::obj {args} {
	return [objl $args]
}

# Array from raw JSON values
proc ::hue::json::arr {items} {
	return "\[[join $items ,]\]"
}

proc ::hue::json::bool {v} {
	if {$v == "true" || $v == "1"} { return "true" }
	return "false"
}

# Number or null
proc ::hue::json::numornull {v} {
	if {$v == ""} { return "null" }
	return $v
}

# Rebuild JSON for the subtree at path (used to pass parts of a request on)
proc ::hue::json::dump {arrName path} {
	upvar 1 $arrName A
	if {[info exists A([jp $path %])]} {
		set pairs [list]
		foreach k $A([jp $path %]) {
			lappend pairs $k [dump A [jp $path $k]]
		}
		return [objl $pairs]
	}
	if {[info exists A([jp $path #])]} {
		set items [list]
		for {set i 0} {$i < $A([jp $path #])} {incr i} {
			lappend items [dump A [jp $path $i]]
		}
		return [arr $items]
	}
	if {![info exists A($path)]} { return "null" }
	set v $A($path)
	if {$v == "true" || $v == "false" || [string is double -strict $v]} { return $v }
	return [str $v]
}
