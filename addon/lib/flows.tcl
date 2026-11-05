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
#  Flows: the CCU programs as a graph (trigger -> program -> target) for the
#  designer in the web UI. The programs themselves are the only copy: they are
#  read live and changed in place, nothing is stored in the addon.
#
#  A program is editable in the designer when it is a "simple flow": one rule
#  without "else", conditions that are key presses combined with "or", and
#  actions without delay or script. Everything else is shown, not changed.
#
#  Runs on Tcl 8.2 up to 8.6. ReGa note: a nested call inside a string
#  concatenation returns nothing, so every object goes into a variable first.

namespace eval ::hue::flows {
	# Outside the addon directory: kept across addon updates and part of the CCU backup
	variable backup_dir "/usr/local/etc/config/hue-flow-backups"
	if {[info exists ::env(HUE_FLOW_BACKUP_DIR)]} { set backup_dir $::env(HUE_FLOW_BACKUP_DIR) }
	variable backup_keep 40
}

proc ::hue::flows::rega {script} {
	array set r [rega_script $script]
	if {[info exists r(STDOUT)]} { return [encoding convertfrom utf-8 $r(STDOUT)] }
	return ""
}

# All programs with rules, conditions and actions, one record per line
proc ::hue::flows::dump_script {{only ""}} {
	set ids "dom.GetObject(ID_PROGRAMS).EnumUsedIDs()"
	if {$only != ""} { set ids "\"$only\"" }
	return "!hue:flows:dump
string pid;
foreach(pid, $ids) {
  object p = dom.GetObject(pid);
  if (p) {
  WriteLine(\"P|\" # pid # \"|\" # p.Active() # \"|\" # p.Visible() # \"|\" # p.ProgramLastExecuteTime() # \"|\" # p.Name());
  object r = p.Rule();
  integer lvl = 0;
  while (r) {
    integer n = r.RuleConditions().Count();
    object rd = r.RuleDestination();
    WriteLine(\"R|\" # r.ID() # \"|\" # lvl # \"|\" # n # \"|\" # r.ElseIfFlag() # \"|\" # rd.BreakOnRestart());
    integer i = 0;
    while (i < n) {
      object c = r.RuleCondition(i);
      WriteLine(\"C|\" # c.ID() # \"|\" # c.CndOperatorType());
      integer j = 0;
      while (j < c.CndSingleCount()) {
        object s = c.CndSingleCondition(j);
        string lv = s.LeftVal();
        if (s.LeftValType() == 24) { lv = \"\"; }
        string ln = \"\";
        object lo = dom.GetObject(lv);
        if (lo) { ln = lo.Name(); }
        string chn = \"\";
        object cho = dom.GetObject(s.ConditionChannel());
        if (cho) { chn = cho.Name(); }
        WriteLine(\"S|\" # s.ID() # \"|\" # lv # \"|\" # s.LeftValType() # \"|\" # s.ConditionType() # \"|\" # s.ConditionType2() # \"|\" # s.RightVal1() # \"|\" # s.RightVal2() # \"|\" # s.ConditionChannel() # \"|\" # ln # \"|\" # chn # \"|\" # s.OperatorType() # \"|\" # s.RightVal1ValType() # \"|\" # s.RightVal2ValType() # \"|\" # s.NegateCondition());
        if (s.LeftValType() == 24) {
          object tm = dom.GetObject(s.RightVal1());
          if (tm) {
            WriteLine(\"T|\" # tm.ID() # \"|\" # tm.TimerType() # \"|\" # tm.SunOffsetType() # \"|\" # tm.TimeSeconds() # \"|\" # tm.CalDuration() # \"|\" # tm.Weekdays() # \"|\" # tm.Period() # \"|\" # tm.CalRepetitionValue() # \"|\" # tm.CalRepetitionCount() # \"|\" # tm.Begin() # \"|\" # tm.End() # \"|\" # tm.Time());
          }
        }
        j = j + 1;
      }
      i = i + 1;
    }
    object d = r.RuleDestination();
    integer k = 0;
    while (k < d.DestSingleCount()) {
      object x = d.DestSingleDestination(k);
      string dp = x.DestinationDP();
      string dn = \"\";
      object o = dom.GetObject(dp);
      if (o) { dn = o.Name(); }
      string dcn = \"\";
      object dco = dom.GetObject(x.DestinationChannel());
      if (dco) { dcn = dco.Name(); }
      integer vt = x.DestinationValueType();
      string val = x.DestinationValue();
      if (vt == 20) { val = \"\"; }
      WriteLine(\"D|\" # x.ID() # \"|\" # dp # \"|\" # x.DestinationParam() # \"|\" # vt # \"|\" # x.DestinationValueParamType() # \"|\" # x.DestinationValueParam() # \"|\" # val # \"|\" # x.DestinationChannel() # \"|\" # dn # \"|\" # dcn);
      k = k + 1;
    }
    r = r.RuleSubRule();
    lvl = lvl + 1;
  }
  }
}"
}

proc ::hue::flows::dump {{only ""}} {
	return [rega [dump_script $only]]
}

# Key press datapoint? Returns SHORT, LONG, LONG_START or ""
proc ::hue::flows::press_kind {dpname} {
	if {[regexp {\.PRESS_(SHORT|LONG_START|LONG)$} $dpname -> k]} { return $k }
	return ""
}

# The dump as JSON for the designer
proc ::hue::flows::programs_json {{text ""}} {
	if {$text == ""} { set text [dump] }
	set programs [list]
	set cur ""
	array set TM {}
	foreach line [split [string map {"\r" ""} $text] "\n"] {
		set f [split $line "|"]
		set kind [lindex $f 0]
		if {[string equal $kind "P"]} {
			if {$cur != ""} { lappend programs [finish_program P R TM] }
			catch {unset P}
			catch {unset R}
			array set P {}
			array set R {}
			set P(id) [lindex $f 1]
			set P(active) [lindex $f 2]
			set P(visible) [lindex $f 3]
			set P(last) [lindex $f 4]
			set P(name) [join [lrange $f 5 end] "|"]
			set P(rules) [list]
			set cur $P(id)
		} elseif {[string equal $kind "R"] && $cur != ""} {
			set rid [lindex $f 1]
			lappend P(rules) $rid
			set R($rid,conds) [list]
			set R($rid,dests) [list]
			set R($rid,eif) [lindex $f 4]
			set R($rid,bor) [lindex $f 5]
			set R(last) $rid
		} elseif {[string equal $kind "C"] && $cur != ""} {
			set rid $R(last)
			lappend R($rid,conds) [list [lindex $f 1] [lindex $f 2] [list]]
		} elseif {[string equal $kind "S"] && $cur != ""} {
			set rid $R(last)
			set conds $R($rid,conds)
			set c [lindex $conds end]
			set singles [lindex $c 2]
			lappend singles [lrange $f 1 end]
			set R($rid,conds) [lreplace $conds end end [list [lindex $c 0] [lindex $c 1] $singles]]
		} elseif {[string equal $kind "D"] && $cur != ""} {
			set rid $R(last)
			lappend R($rid,dests) [lrange $f 1 end]
		} elseif {[string equal $kind "T"]} {
			set TM([lindex $f 1]) [lrange $f 2 end]
		}
	}
	if {$cur != ""} { lappend programs [finish_program P R TM] }
	return "\{\"programs\":[::hue::json::arr $programs]\}"
}

proc ::hue::flows::finish_program {pName rName tName} {
	upvar 1 $pName P $rName R $tName TM
	# Editor: can the whole program be shown and saved as a flow?
	set model [model P R TM]
	set ereason [lindex $model 0]
	set S ::hue::json::str
	set editable 1
	set why ""
	set rules [list]
	set level 0
	foreach rid $P(rules) {
		set cj [list]
		foreach c $R($rid,conds) {
			foreach {cid cop singles} $c break
			set sj [list]
			foreach s $singles {
				foreach {sid lv lvt ct ct2 r1 r2 chid lname chname sop} $s break
				set press [press_kind $lname]
				lappend sj [::hue::json::objl [list id [$S $sid] dp [$S $lv] type [$S $lvt] ct [$S $ct] ct2 [$S $ct2] \
					value [$S $r1] value2 [$S $r2] channel [$S $chid] name [$S $lname] channel_name [$S $chname] press [$S $press] op [$S $sop]]]
				if {$press == "" || [lsearch -exact {1 13} $ct2] < 0} { set editable 0; set why "condition" }
			}
			# Several keys in one condition are fine when they are combined with "or"
			set k 0
			foreach s $singles {
				if {$k > 0 && [lindex $s 10] != 2} { set editable 0; set why "condition" }
				incr k
			}
			if {[llength $singles] == 0 || ([llength $R($rid,conds)] > 1 && $cop != 2)} { set editable 0; set why "condition" }
			lappend cj [::hue::json::objl [list id [$S $cid] op [$S $cop] singles [::hue::json::arr $sj]]]
		}
		set dj [list]
		foreach d $R($rid,dests) {
			foreach {did dp param vt ppt pp val chid dname chname} $d break
			lappend dj [::hue::json::objl [list id [$S $did] dp [$S $dp] param [$S $param] vtype [$S $vt] delay_type [$S $ppt] delay [$S $pp] \
				value [$S $val] channel [$S $chid] name [$S $dname] channel_name [$S $chname]]]
			if {$vt == 20 || ($ppt != "" && $ppt != 0)} { set editable 0; set why "action" }
		}
		if {$level > 0 && ([llength $R($rid,conds)] > 0 || [llength $R($rid,dests)] > 0)} { set editable 0; set why "else" }
		if {$level == 0 && [llength $R($rid,conds)] == 0} { set editable 0; set why "condition" }
		lappend rules [::hue::json::objl [list id [$S $rid] conditions [::hue::json::arr $cj] actions [::hue::json::arr $dj]]]
		incr level
	}
	return [::hue::json::objl [list id [$S $P(id)] name [$S $P(name)] active [::hue::json::bool $P(active)] \
		last [$S $P(last)] editable [::hue::json::bool $editable] reason [$S $why] \
		editor [::hue::json::bool [string equal $ereason ""]] editor_reason [$S $ereason] rules [::hue::json::arr $rules]]]
}

# Everything a flow can start from or switch, as JSON
# Room of a channel; without one the name prefix if it is a known room ("Kueche_Wandlampe")
proc ::hue::flows::room_of {rooms name roomnames} {
	foreach r [split $rooms ";"] { if {$r != ""} { return $r } }
	set key [lindex [::hue::v2::fold [lindex [split [string map {" " "_"} $name] "_"] 0]] 0]
	if {$key == ""} { return "" }
	foreach r $roomnames {
		if {[string equal [lindex [::hue::v2::fold $r] 0] $key]} { return $r }
	}
	return ""
}

# System variables nobody picks in a flow: scene lists without scenes, duty cycle
proc ::hue::flows::junk_sysvar {name vlist} {
	if {[regexp {^Hue Szene( [0-9]+)?$} $name] && [string equal $vlist "Aus"]} { return 1 }
	if {[regexp {^DutyCycle} $name]} { return 1 }
	return 0
}

proc ::hue::flows::catalog_json {} {
	set out [rega "!hue:flows:catalog
string cid;
foreach(cid, dom.GetObject(ID_CHANNELS).EnumUsedIDs()) {
  object ch = dom.GetObject(cid);
  string ht = ch.HssType();
  object dv = dom.GetObject(ch.Device());
  string dn = \"\";
  string dvt = \"\";
  if (dv) { dn = dv.Name(); dvt = dv.HssType(); }
  string rooms = \"\";
  string rid;
  foreach(rid, ch.ChnRoom()) { object ro = dom.GetObject(rid); rooms = rooms # ro.Name() # \";\"; }
  string list = \"\";
  string dpn;
  foreach(dpn, \"PRESS_SHORT\tPRESS_LONG_START\tPRESS_LONG\tSTATE\tTOGGLE\tLEVEL\tMOTION\tPRESENCE_DETECTION_STATE\tILLUMINATION\tCURRENT_ILLUMINATION\tACTUAL_TEMPERATURE\tHUMIDITY\") {
    object dp = ch.DPByHssDP(dpn);
    if (dp) { list = list # dpn # \"=\" # dp.ID() # \"/\" # dp.Operations() # \"/\" # dp.ValueType() # \";\"; }
  }
  if (list != \"\") { WriteLine(\"CH|\" # cid # \"|\" # ht # \"|\" # list # \"|\" # rooms # \"|\" # ch.Name() # \"|\" # dn # \"|\" # ch.Device() # \"|\" # ch.Address() # \"|\" # dvt); }
}
string sid;
foreach(sid, dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs()) {
  object sv = dom.GetObject(sid);
  if (sv) {
    if ((sv.ValueSubType() == istEnum) || (sv.ValueType() == ivtBinary)) {
      WriteLine(\"SV|\" # sid # \"|\" # sv.ValueType() # \"|\" # sv.ValueList() # \"|\" # sv.Name());
    }
    WriteLine(\"SVC|\" # sid # \"|\" # sv.ValueType() # \"|\" # sv.ValueSubType() # \"|\" # sv.ValueList() # \"|\" # sv.Name());
  }
}"]
	set S ::hue::json::str
	set triggers [list]
	set targets [list]
	set conditions [list]
	set lines [split [string map {"\r" ""} $out] "\n"]
	# CUxD devices of this addon (Hue lights, rooms, scene keys) and CUxD switches of Shellys
	array set HUE {}
	catch {
		foreach d [::hue::get_cuxd_device_details] {
			foreach {a b o n sc} $d break
			regsub {:[0-9]+$} $a "" a
			set HUE($a) [list $o $sc]
		}
	}
	array set SHELLY {}
	catch { foreach x [::hue::extras::shelly_devices] { regsub {:[0-9]+$} [lindex $x 0] "" a; set SHELLY($a) 1 } }
	# Known rooms, for channels without a room whose name starts with one
	set roomnames [list]
	foreach line $lines {
		set f [split $line "|"]
		if {[string equal [lindex $f 0] "CH"]} {
			foreach r [split [lindex $f 4] ";"] { if {$r != "" && [lsearch -exact $roomnames $r] < 0} { lappend roomnames $r } }
		}
	}
	# Wall switches (multi mode inputs) also have switch channels for their LEDs: outputs
	set buttons [list]
	set actuators [list]
	set vr [list]
	array set trx {}
	array set trxtype {}
	foreach line $lines {
		set f [split $line "|"]
		if {[regexp {VIRTUAL_RECEIVER} [lindex $f 2]] && [regexp {^(.*):([0-9]+)$} [lindex $f 8] -> d n]} { lappend vr "$d/[lindex $f 2]/$n" }
		if {[regexp {_(TRANSCEIVER|TRANSMITTER)$} [lindex $f 2]] && ![regexp {^(KEY_TRANSCEIVER|MULTI_MODE_INPUT_TRANSMITTER)$} [lindex $f 2]] && [regexp {^(.*):([0-9]+)$} [lindex $f 8] -> d n]} {
			lappend trx($d) $n
			set trxtype($d/$n) [lindex $f 2]
		}
		if {[string equal [lindex $f 2] "MULTI_MODE_INPUT_TRANSMITTER"]} { lappend buttons [lindex $f 7] }
		if {[regexp {(STATE|LEVEL)=[0-9]+/[0-9]*[2367]/} [lindex $f 3]] && ![string match "*PRESS_SHORT*" [lindex $f 3]]} { lappend actuators [lindex $f 7] }
	}
	foreach line $lines {
		set f [split $line "|"]
		if {[string equal [lindex $f 0] "CH"] && [llength $f] >= 7} {
			foreach {x cid ht dps rooms name dname devid addr dvt} $f break
			# Virtual keys of the CCU itself
			if {[string equal $ht "VIRTUAL_KEY"] || [string match "_*" $name] || [regexp {^(BidCoS-RF|HmIP-RCV|BidCoS-Wir)} $addr]} { continue }
			catch {unset D}
			array set D {}
			foreach item [split $dps ";"] {
				if {[regexp {^([A-Z_]+)=([0-9]+)/([0-9]+)/([0-9]+)$} $item -> k id ops vt]} { set D($k) [list $id $ops $vt] }
			}
			set rl [list]
			foreach r [split $rooms ";"] { if {$r != ""} { lappend rl [$S $r] } }
			set room [room_of $rooms $name $roomnames]
			# Values a flow can check or start from (not the LEDs of wall switches,
			# one of the three virtual receivers per output)
			set dupvr 0
			set sub ""
			if {[regexp {^(.*):([0-9]+)$} $addr -> vdev vnum]} {
				if {[regexp {VIRTUAL_RECEIVER} $ht]} {
					set prev [expr {$vnum - 1}]
					set dupvr [expr {[lsearch -exact $vr "$vdev/$ht/$prev"] >= 0 || [info exists trxtype($vdev/$prev)]}]
					while {$prev > 0 && ![info exists trxtype($vdev/$prev)]} { incr prev -1 }
					if {[info exists trx($vdev)] && [llength $trx($vdev)] > 1 && [info exists trxtype($vdev/$prev)]} { set sub "out[expr {[lsearch -exact $trx($vdev) $prev] + 1}]" }
				} elseif {[info exists trx($vdev)] && [llength $trx($vdev)] > 1 && [lsearch -exact $trx($vdev) $vnum] >= 0} {
					set sub "out[expr {[lsearch -exact $trx($vdev) $vnum] + 1}]"
				}
			}
			if {!$dupvr && ![regexp {^(MULTI_MODE_INPUT_TRANSMITTER|KEY_TRANSCEIVER|KEY|MAINTENANCE)$} $ht] && ![string match "*:0" $addr]} {
				foreach k {STATE LEVEL MOTION PRESENCE_DETECTION_STATE ILLUMINATION CURRENT_ILLUMINATION ACTUAL_TEMPERATURE HUMIDITY} {
					if {[info exists D($k)] && ([lindex $D($k) 1] & 5)} {
						set grp "state"
						switch -- $k {
							MOTION { set grp "motion" }
							PRESENCE_DETECTION_STATE { set grp "presence" }
							ILLUMINATION - CURRENT_ILLUMINATION { set grp "lux" }
							ACTUAL_TEMPERATURE - HUMIDITY { set grp "climate" }
							LEVEL { set grp "level" }
						}
						lappend conditions [::hue::json::objl [list kind [$S value] dp [$S [lindex $D($k) 0]] channel [$S $cid] name [$S $name] \
							device [$S $dname] rooms [::hue::json::arr $rl] room [$S $room] group [$S $grp] sub [$S $sub] param [$S $k] vtype [$S [lindex $D($k) 2]] values "\[\]"]]
					}
				}
			}
			# Keys: wall switches and remotes. Keys of actuators and CUxD switches are no triggers.
			if {[info exists D(PRESS_SHORT)] && [regexp {^(MULTI_MODE_INPUT_TRANSMITTER|KEY_TRANSCEIVER|KEY)$} $ht] \
					&& ![string match "CUX*" $addr] && ([string equal $ht "MULTI_MODE_INPUT_TRANSMITTER"] || [lsearch -exact $actuators $devid] < 0)} {
				set long ""
				if {[info exists D(PRESS_LONG_START)]} { set long [lindex $D(PRESS_LONG_START) 0] } elseif {[info exists D(PRESS_LONG)]} { set long [lindex $D(PRESS_LONG) 0] }
				lappend triggers [::hue::json::objl [list channel [$S $cid] name [$S $name] device [$S $dname] rooms [::hue::json::arr $rl] room [$S $room] \
					short [$S [lindex $D(PRESS_SHORT) 0]] long [$S $long]]]
				continue
			}
			# Writable switch, dimmer or blind
			set kind ""
			set dp ""
			set toggle ""
			if {[info exists D(STATE)] && ([lindex $D(STATE) 1] & 2) && [lindex $D(STATE) 2] == 2} {
				set kind "switch"
				set dp [lindex $D(STATE) 0]
				if {[info exists D(TOGGLE)] && ([lindex $D(TOGGLE) 1] & 2)} { set toggle [lindex $D(TOGGLE) 0] }
			} elseif {[info exists D(LEVEL)] && ([lindex $D(LEVEL) 1] & 2)} {
				set kind "level"
				if {[regexp {BLIND|SHUTTER|JALOUSIE} $ht]} { set kind "blind" }
				set dp [lindex $D(LEVEL) 0]
			}
			if {$kind == "" || [regexp {^(MULTI_MODE_INPUT|CLIMATE|HEATING|KEY)} $ht]} { continue }
			# What it is, for grouping and icons in the editor
			regsub {:[0-9]+$} $addr "" dev
			set grp $kind
			if {[info exists HUE($dev)]} {
				if {[lindex $HUE($dev) 1] != ""} { set grp "hue_scene_key" } else { set grp "hue_light" }
			} elseif {[info exists SHELLY($dev)]} {
				set grp "shelly"
			} elseif {$devid != "" && [lsearch -exact $buttons $devid] >= 0} {
				# Output or LED of a wall switch module
				if {![regexp {SWITCH_VIRTUAL_RECEIVER} $ht]} { continue }
				set grp "output"
			} elseif {[string equal $kind "blind"] && [regexp -nocase {markise} $name]} {
				set grp "awning"
			} elseif {[string equal $kind "switch"] && [regexp {^HmIP-(PS|BS|PSM)} $dvt]} {
				set grp "plug"
			} elseif {[string equal $kind "switch"] && [regexp -nocase {lampe|licht|leuchte|light|lamp} $name]} {
				set grp "lamp"
			}
			# Virtual receivers come in threes per output: the first one is enough
			if {[regexp {VIRTUAL_RECEIVER} $ht] && [regexp {:([0-9]+)$} $addr -> num]} {
				if {[lsearch -exact $vr "$dev/$ht/[expr {$num - 1}]"] >= 0} { continue }
			}
			lappend targets [::hue::json::objl [list kind [$S $kind] dp [$S $dp] toggle [$S $toggle] channel [$S $cid] name [$S $name] \
				device [$S $dname] rooms [::hue::json::arr $rl] room [$S $room] group [$S $grp] sub [$S $sub] type [$S $ht]]]
		} elseif {[string equal [lindex $f 0] "SVC"] && [llength $f] >= 6} {
			foreach {x sid vt st vlist} $f break
			set name [join [lrange $f 5 end] "|"]
			if {[junk_sysvar $name $vlist]} { continue }
			set vl [list]
			foreach v [split $vlist ";"] { if {$v != ""} { lappend vl [$S $v] } }
			set grp "sysvar"
			if {[regexp {^Hue_(motion|motionarea|securityarea|lux|temp|button|reachable)_} $name]} { set grp "hue_sensor" }
			if {[string match "Hue Szene *" $name]} { set grp "scene" }
			lappend conditions [::hue::json::objl [list kind [$S sysvar] dp [$S $sid] channel [$S ""] name [$S $name] \
				device [$S ""] rooms "\[\]" room [$S ""] group [$S $grp] param [$S $st] vtype [$S $vt] values [::hue::json::arr $vl]]]
		} elseif {[string equal [lindex $f 0] "SV"] && [llength $f] >= 5} {
			foreach {x sid vt vlist} $f break
			set name [join [lrange $f 4 end] "|"]
			# Junk and values written by the addon itself (sensors) are no targets
			if {[junk_sysvar $name $vlist] || [regexp {^Hue_(motion|motionarea|securityarea|lux|temp|button|reachable)_} $name]} { continue }
			set vl [list]
			foreach v [split $vlist ";"] { lappend vl [$S $v] }
			set kind "sysvar"
			if {[string match "Hue Szene *" $name]} { set kind "scene" }
			lappend targets [::hue::json::objl [list kind [$S $kind] dp [$S $sid] name [$S $name] vtype [$S $vt] values [::hue::json::arr $vl] \
				rooms "\[\]" room [$S ""] group [$S $kind]]]
		}
	}
	return "\{\"triggers\":[::hue::json::arr $triggers],\"targets\":[::hue::json::arr $targets],\"conditions\":[::hue::json::arr $conditions]\}"
}

# ---------------------------------------------------------------------------
# Changing programs
# ---------------------------------------------------------------------------

proc ::hue::flows::backup {pid} {
	variable backup_dir
	variable backup_keep
	if {![regexp {^[0-9]+$} $pid]} { return }
	set text [dump $pid]
	if {$text == ""} { return }
	file mkdir $backup_dir
	set f [file join $backup_dir "[clock format [clock seconds] -format %Y%m%d-%H%M%S]-${pid}.txt"]
	set fd [open $f w]
	fconfigure $fd -encoding utf-8
	puts -nonewline $fd $text
	close $fd
	set files [lsort [glob -nocomplain [file join $backup_dir *.txt]]]
	while {[llength $files] > $backup_keep} {
		catch {file delete [lindex $files 0]}
		set files [lrange $files 1 end]
	}
}

proc ::hue::flows::check_value {v} {
	if {[lsearch -exact {true false} $v] >= 0 || [regexp {^-?[0-9]+(\.[0-9]+)?$} $v]} { return $v }
	error "Invalid value ${v}"
}

proc ::hue::flows::check_name {n} {
	set n [string trim $n]
	if {$n == "" || [string length $n] > 80 || [regexp {["\\\n\r]} $n]} { error "Invalid name" }
	return $n
}

# ReGa statements that add key press conditions and actions to rule r
proc ::hue::flows::fill_script {triggers actions} {
	set s ""
	set i 0
	foreach t $triggers {
		if {![regexp {^[0-9]+$} $t]} { error "Invalid trigger ${t}" }
		append s "object t$i = dom.GetObject($t);
object c$i = r.RuleAddCondition();
c$i.CndOperatorType(2);
object s$i = c$i.CndAddSingle();
s$i.OperatorType(1);
s$i.LeftValType(18);
s$i.LeftVal(t$i.ID());
s$i.ConditionChannel(t$i.Channel());
s$i.ConditionType(1);
s$i.ConditionType2(1);
s$i.RightVal1(true);
s$i.RightVal2(false);
"
		incr i
	}
	set i 0
	foreach a $actions {
		foreach {dp value} $a break
		if {![regexp {^[0-9]+$} $dp]} { error "Invalid target ${dp}" }
		set value [check_value $value]
		append s "object a$i = dom.GetObject($dp);
object d$i = r.RuleDestination().DestAddSingle();
if (a$i.IsTypeOf(OT_VARDP)) {
  d$i.DestinationParam(19);
} else {
  d$i.DestinationParam(18);
  d$i.DestinationChannel(a$i.Channel());
}
d$i.DestinationDP(a$i.ID());
d$i.DestinationValueType(a$i.ValueType());
d$i.DestinationValue($value);
d$i.DestinationValueParamType(0);
"
		incr i
	}
	return $s
}

# New program; returns its id
proc ::hue::flows::create {name triggers actions {active 1}} {
	set name [check_name $name]
	if {[llength $triggers] == 0 || [llength $actions] == 0} { error "A flow needs a trigger and an action" }
	set a "false"
	if {$active} { set a "true" }
	set out [rega "!hue:flows:create
object p = dom.CreateObject(OT_PROGRAM);
p.Name(\"$name\");
dom.GetObject(ID_PROGRAMS).Add(p.ID());
p.Active($a);
p.Visible(true);
object r = p.Rule();
[fill_script $triggers $actions]
system.Save();
WriteLine(\"ID|\" # p.ID());"]
	if {![regexp {ID\|([0-9]+)} $out -> id]} { error "Program not created: $out" }
	return $id
}

# Replace triggers and actions of a simple flow (backup first)
proc ::hue::flows::update {pid name triggers actions active} {
	if {![regexp {^[0-9]+$} $pid]} { error "Invalid program" }
	set name [check_name $name]
	if {[llength $triggers] == 0 || [llength $actions] == 0} { error "A flow needs a trigger and an action" }
	::hue::json::parse [programs_json [dump $pid]] J
	if {[::hue::json::len J programs] != 1} { error "Program ${pid} not found" }
	if {![string equal [::hue::json::get J programs/0/editable] "true"]} { error "This program can only be changed in the CCU" }
	backup $pid
	set a "false"
	if {$active} { set a "true" }
	set out [rega "!hue:flows:update
object p = dom.GetObject($pid);
p.Name(\"$name\");
p.Active($a);
object r = p.Rule();
string ids = \"\";
integer i = 0;
while (i < r.RuleConditions().Count()) { object co = r.RuleCondition(i); ids = ids # co.ID() # \"\t\"; i = i + 1; }
string x;
foreach(x, ids) { r.RuleDelCondition(x); }
object dd = r.RuleDestination();
ids = \"\";
i = 0;
while (i < dd.DestSingleCount()) { object so = dd.DestSingleDestination(i); ids = ids # so.ID() # \"\t\"; i = i + 1; }
foreach(x, ids) { dd.DestDelSingle(x); }
[fill_script $triggers $actions]
system.Save();
WriteLine(\"OK|\" # p.ID());"]
	if {![regexp {OK\|} $out]} { error "Program not changed: $out" }
	return $pid
}

proc ::hue::flows::set_active {pid on} {
	if {![regexp {^[0-9]+$} $pid]} { error "Invalid program" }
	set a "false"
	if {$on} { set a "true" }
	backup $pid
	rega "!hue:flows:active\nobject p = dom.GetObject($pid);\nif (p) { p.Active($a); system.Save(); }"
}

proc ::hue::flows::delete {pid} {
	if {![regexp {^[0-9]+$} $pid]} { error "Invalid program" }
	backup $pid
	set out [rega "!hue:flows:delete
object p = dom.GetObject($pid);
if (p) { if (p.IsTypeOf(OT_PROGRAM)) { if (!p.Unerasable()) { WriteLine(\"DEL|\" # dom.DeleteObject(p.ID())); system.Save(); } } }"]
	if {![regexp {DEL\|true} $out]} { error "Program not deleted: $out" }
}

# ---------------------------------------------------------------------------
# Flow model for the editor (docs/FLOW_BUILDER.md)
#
# The model mirrors the CCU program 1:1: branches (if / else if) with their
# condition groups and actions, plus an optional else. Every condition and
# action keeps the raw CCU fields, so saving an unchanged flow writes the same
# program again. model returns {reason flowjson}; reason "" means editable.
# ---------------------------------------------------------------------------

# ConditionType2: 1 key press, 4 on change, 13 on update, 15 check only
# ConditionType: 1 equal (logic), 3 time, 5 equal, 6/12 not equal, 7 range, 8-11 compare
proc ::hue::flows::cond_known {ct ct2} {
	return [expr {[lsearch -exact {1 4 13 15} $ct2] >= 0 && [lsearch -exact {1 3 5 6 7 8 9 10 11 12} $ct] >= 0}]
}

proc ::hue::flows::value_ok {v {vt ""}} {
	return [expr {![catch {literal $v $vt}]}]
}

proc ::hue::flows::model {pName rName tName} {
	upvar 1 $pName P $rName R $tName TM
	set S ::hue::json::str
	set reason ""
	set branches [list]
	set else "null"
	set seen_else 0
	set i 0
	foreach rid $P(rules) {
		set conds $R($rid,conds)
		set dests $R($rid,dests)
		set eif ""
		if {[info exists R($rid,eif)]} { set eif $R($rid,eif) }
		set bor "true"
		if {[info exists R($rid,bor)] && [string equal $R($rid,bor) "false"]} { set bor "false" }
		# Older dumps without the flag: a sub rule without conditions is the else
		if {$eif == ""} {
			if {$i > 0 && [llength $conds] == 0} { set eif "false" } else { set eif "true" }
		}
		set acts [actions_json $dests reason]
		if {$seen_else} {
			if {[llength $conds] > 0 || [llength $dests] > 0} { set reason "layout" }
		} elseif {$i == 0} {
			if {[string equal $eif "false"]} { set reason "layout" }
			lappend branches [::hue::json::objl [list when [when_json $conds TM reason] then $acts stop_delays $bor]]
		} elseif {[string equal $eif "false"]} {
			if {[llength $conds] > 0} { set reason "layout" }
			set else [::hue::json::objl [list then $acts stop_delays $bor]]
			set seen_else 1
		} elseif {[llength $conds] == 0} {
			# Empty "else if" placeholder of the WebUI: ignored, unless it has actions
			if {[llength $dests] > 0} { set reason "layout" }
		} else {
			lappend branches [::hue::json::objl [list when [when_json $conds TM reason] then $acts stop_delays $bor]]
		}
		incr i
	}
	set json [::hue::json::objl [list id [$S $P(id)] name [$S $P(name)] active [::hue::json::bool $P(active)] \
		last [$S $P(last)] editable [::hue::json::bool [string equal $reason ""]] reason [$S $reason] \
		branches [::hue::json::arr $branches] else $else]]
	return [list $reason $json]
}

proc ::hue::flows::set_reason {var r} {
	upvar 1 $var reason
	if {$reason == ""} { set reason $r }
}

proc ::hue::flows::when_json {conds tName reasonVar} {
	upvar 1 $tName TM $reasonVar reason
	set S ::hue::json::str
	set op ""
	set groups [list]
	foreach c $conds {
		foreach {cid cop singles} $c break
		if {$op == ""} { set op $cop }
		if {![string equal $op $cop] || [lsearch -exact {1 2} $cop] < 0} { set_reason reason "mixed_ops" }
		set items [list]
		set k 0
		set gop ""
		foreach s $singles {
			foreach {sid lv lvt ct ct2 r1 r2 chid lname chname sop rt1 rt2 neg} $s break
			# Inside a group one operator (the WebUI evaluates left to right)
			if {$k > 0} {
				if {$gop == ""} { set gop $sop }
				if {![string equal $gop $sop] || [lsearch -exact {1 2} $sop] < 0} { set_reason reason "mixed_ops" }
			}
			incr k
			if {![cond_known $ct $ct2] || [string equal $neg "true"]} { set_reason reason "unknown_condition" }
			set kind ""
			set press ""
			set tm ""
			if {$lvt == 18} {
				set press [press_kind $lname]
				if {$press != ""} { set kind "key" } else { set kind "value" }
			} elseif {$lvt == 19} {
				set kind "sysvar"
			} elseif {$lvt == 24} {
				set kind "time"
				set lv ""
				if {![info exists TM($r1)]} {
					set_reason reason "unknown_condition"
				} else {
					foreach {type sot secs dur wd period rep count begin end ttime} $TM($r1) break
					foreach v {type sot secs dur wd period rep count} { if {![string is integer -strict [set $v]]} { set $v 0 } }
					# Time of day in seconds, -1 = none (the WebUI writes Time(0) for all day, day and night)
					if {$secs == 0} {
						set secs -1
					} elseif {[regexp {([0-9][0-9]):([0-9][0-9]):([0-9][0-9])$} $ttime -> hh mm ss]} {
						scan "$hh $mm $ss" "%d %d %d" h m sec
						set secs [expr {$h * 3600 + $m * 60 + $sec}]
					} elseif {$secs >= 86400} {
						set_reason reason "unknown_condition"
					}
					if {[lsearch -exact {5 9} $type] < 0 || $period != 0} { set_reason reason "unknown_condition" }
					set tm [::hue::json::objl [list type $type sot $sot time [expr {$secs + 0}] dur [expr {$dur + 0}] wd [expr {$wd + 0}] \
						rep [expr {$rep + 0}] count [expr {$count + 0}] begin [$S $begin] end [$S $end]]]
				}
			} else {
				set_reason reason "unknown_condition"
			}
			if {$lvt != 24 && (![value_ok $r1 $rt1] || ![value_ok $r2 $rt2])} { set_reason reason "unknown_condition" }
			set fields [list kind [$S $kind] lvt [$S $lvt] dp [$S $lv] ch [$S $chid] ct [$S $ct] ct2 [$S $ct2] \
				rv1 [$S $r1] rv2 [$S $r2] rt1 [$S $rt1] rt2 [$S $rt2] op [$S $sop] name [$S $lname] channel_name [$S $chname] press [$S $press]]
			if {$tm != ""} { lappend fields tm $tm }
			lappend items [::hue::json::objl $fields]
		}
		if {[llength $items] == 0} { set_reason reason "unknown_condition" }
		lappend groups [::hue::json::arr $items]
	}
	set o "or"
	if {$op == 1} { set o "and" }
	return [::hue::json::objl [list op [$S $o] groups [::hue::json::arr $groups]]]
}

proc ::hue::flows::actions_json {dests reasonVar} {
	upvar 1 $reasonVar reason
	set S ::hue::json::str
	set out [list]
	foreach d $dests {
		foreach {did dp param vt ppt pp val chid dname chname} $d break
		if {[lsearch -exact {18 19} $param] < 0 || $vt == 20} { set_reason reason "script" }
		if {$ppt == ""} { set ppt 0 }
		set delay ""
		if {$ppt == 28} {
			if {[regexp {([0-9][0-9]):([0-9][0-9]):([0-9][0-9])$} $pp -> hh mm ss]} { set delay "$hh:$mm:$ss" } else { set_reason reason "unknown_action" }
		} elseif {$ppt != 0} {
			set_reason reason "unknown_action"
		}
		if {$vt != 20 && ![value_ok $val]} { set_reason reason "unknown_action" }
		lappend out [::hue::json::objl [list param [$S $param] dp [$S $dp] ch [$S $chid] vt [$S $vt] value [$S $val] \
			delay [$S $delay] name [$S $dname] channel_name [$S $chname]]]
	}
	return [::hue::json::arr $out]
}

# Checksum of a program dump: detects changes made in the CCU meanwhile.
# FNV-1a, pure Tcl (no exec), same result on Tcl 8.2 and 8.6.
proc ::hue::flows::rev {text} {
	set h 2166136261
	foreach ch [split [encoding convertto utf-8 $text] ""] {
		scan $ch %c c
		set h [expr {(($h ^ $c) * 16777619) & 0xFFFFFFFF}]
	}
	return [format %08x $h][format %04x [string length $text]]
}

# One program as flow for the editor: {"flow":{...},"rev":"..."}
proc ::hue::flows::flow_json {pid} {
	if {![regexp {^[0-9]+$} $pid]} { error "Invalid program" }
	set text [dump $pid]
	set m [single_model $text]
	if {$m == ""} { error "Program ${pid} not found" }
	return "\{\"flow\":[lindex $m 1],\"rev\":[::hue::json::str [rev $text]]\}"
}

# Model of the first program in a dump, "" if there is none
proc ::hue::flows::single_model {text} {
	array set P {}
	array set R {}
	array set TM {}
	set cur ""
	foreach line [split [string map {"\r" ""} $text] "\n"] {
		set f [split $line "|"]
		set kind [lindex $f 0]
		if {[string equal $kind "P"]} {
			if {$cur != ""} { break }
			set P(id) [lindex $f 1]
			set P(active) [lindex $f 2]
			set P(last) [lindex $f 4]
			set P(name) [join [lrange $f 5 end] "|"]
			set P(rules) [list]
			set cur $P(id)
		} elseif {[string equal $kind "R"] && $cur != ""} {
			set rid [lindex $f 1]
			lappend P(rules) $rid
			set R($rid,conds) [list]
			set R($rid,dests) [list]
			set R($rid,eif) [lindex $f 4]
			set R($rid,bor) [lindex $f 5]
			set R(last) $rid
		} elseif {[string equal $kind "C"] && $cur != ""} {
			lappend R($R(last),conds) [list [lindex $f 1] [lindex $f 2] [list]]
		} elseif {[string equal $kind "S"] && $cur != ""} {
			set rid $R(last)
			set conds $R($rid,conds)
			set c [lindex $conds end]
			set singles [lindex $c 2]
			lappend singles [lrange $f 1 end]
			set R($rid,conds) [lreplace $conds end end [list [lindex $c 0] [lindex $c 1] $singles]]
		} elseif {[string equal $kind "D"] && $cur != ""} {
			lappend R($R(last),dests) [lrange $f 1 end]
		} elseif {[string equal $kind "T"]} {
			set TM([lindex $f 1]) [lrange $f 2 end]
		}
	}
	if {$cur == ""} { return "" }
	return [model P R TM]
}

# Time module ids used by the conditions of a program dump
proc ::hue::flows::time_modules {text} {
	set ids [list]
	foreach line [split [string map {"\r" ""} $text] "\n"] {
		if {[regexp {^T\|([0-9]+)\|} $line -> id]} { lappend ids $id }
	}
	return $ids
}

# Value for RightVal / DestinationValue, formatted for its value type
# (ReGa takes the type from the literal: 45.0 is a number, 45 an integer,
# strings like "short_release" need quotes)
proc ::hue::flows::literal {v vt} {
	if {$vt == 20} {
		if {![regexp {^[A-Za-z0-9_ .:-]{0,60}$} $v]} { error "Invalid value ${v}" }
		return "\"$v\""
	}
	set v [check_value $v]
	if {$vt == 4 && [regexp {^-?[0-9]+$} $v]} { append v ".0" }
	return $v
}

proc ::hue::flows::int {v {min 0} {max 2147483647}} {
	if {![regexp {^-?[0-9]+$} $v] || $v < $min || $v > $max} { error "Invalid number ${v}" }
	return [expr {$v + 0}]
}

proc ::hue::flows::id {v} {
	if {![regexp {^[0-9]+$} $v]} { error "Invalid id ${v}" }
	return $v
}

proc ::hue::flows::hms {secs} {
	return [format "%02d:%02d:%02d" [expr {$secs / 3600}] [expr {($secs % 3600) / 60}] [expr {$secs % 60}]]
}

# ReGa statements for the conditions of one branch (rule variable rv)
proc ::hue::flows::conds_script {arrName path rv} {
	upvar 1 $arrName B
	set op [::hue::json::get B $path/when/op "or"]
	if {[lsearch -exact {or and} $op] < 0} { error "Invalid operator" }
	set cop [expr {[string equal $op "and"] ? 1 : 2}]
	set inv [expr {$cop == 1 ? 2 : 1}]
	set s ""
	set triggers 0
	set ng [::hue::json::len B $path/when/groups]
	for {set g 0} {$g < $ng} {incr g} {
		set nitems [::hue::json::len B $path/when/groups/$g]
		if {$nitems == 0} { error "Empty condition group" }
		append s "c = ${rv}.RuleAddCondition();\nc.CndOperatorType($cop);\n"
		for {set i 0} {$i < $nitems} {incr i} {
			set ip $path/when/groups/$g/$i
			set lvt [::hue::json::get B $ip/lvt]
			set ct [::hue::json::get B $ip/ct]
			set ct2 [::hue::json::get B $ip/ct2]
			if {![cond_known $ct $ct2]} { error "Invalid condition type" }
			if {$ct2 != 15} { incr triggers }
			set iop [::hue::json::get B $ip/op $inv]
			if {[lsearch -exact {1 2} $iop] < 0} { set iop $inv }
			append s "s = c.CndAddSingle();\ns.OperatorType($iop);\n"
			if {$lvt == 18 || $lvt == 19} {
				set dp [id [::hue::json::get B $ip/dp]]
				set rt1 [::hue::json::get B $ip/rt1 2]
				set rt2 [::hue::json::get B $ip/rt2 $rt1]
				set rv1 [literal [::hue::json::get B $ip/rv1] $rt1]
				set rv2 [literal [::hue::json::get B $ip/rv2 "false"] $rt2]
				append s "o = dom.GetObject($dp);\ns.LeftValType($lvt);\ns.LeftVal(o.ID());\n"
				if {$lvt == 18} { append s "s.ConditionChannel(o.Channel());\n" }
				append s "s.ConditionType($ct);\ns.ConditionType2($ct2);\ns.RightVal1($rv1);\ns.RightVal2($rv2);\n"
			} elseif {$lvt == 24} {
				if {[lsearch -exact {13 15} $ct2] < 0} { error "Invalid trigger for a time condition" }
				set type [int [::hue::json::get B $ip/tm/type]]
				if {[lsearch -exact {5 9} $type] < 0} { error "Invalid time type" }
				set sot [int [::hue::json::get B $ip/tm/sot 0]]
				if {[lsearch -exact {0 3 6} $sot] < 0} { error "Invalid day/night" }
				set secs [int [::hue::json::get B $ip/tm/time -1] -1 86399]
				set dur [int [::hue::json::get B $ip/tm/dur 0] 0 86400]
				set wd [int [::hue::json::get B $ip/tm/wd 0] 0 127]
				set rep [int [::hue::json::get B $ip/tm/rep 0] 0 1000]
				set count [int [::hue::json::get B $ip/tm/count 0] 0 100000]
				set begin [::hue::json::get B $ip/tm/begin]
				if {![regexp {^(20[0-9][0-9]-[01][0-9]-[0-3][0-9])} $begin -> begin]} { set begin [clock format [clock seconds] -format %Y-%m-%d] }
				set end [::hue::json::get B $ip/tm/end]
				append s "tm = dom.CreateObject(OT_CALENDARDP, \"Zeitmodul\");\ndom.GetObject(ID_CALENDARDPS).Add(tm);\n"
				set ttime "0"
				if {$secs >= 0} { set ttime "2007-01-01 [hms $secs]" }
				append s "tm.TimerType($type);\ntm.Time(\"$ttime\");\ntm.CalDuration($dur);\ntm.Weekdays($wd);\ntm.Period(0);\n"
				append s "tm.CalRepetitionValue($rep);\ntm.Begin(\"$begin\");\ntm.CalRepetitionCount($count);\n"
				if {[regexp {^(20[0-9][0-9]-[01][0-9]-[0-3][0-9])} $end -> end]} { append s "tm.End(\"$end\");\n" }
				append s "tm.SunOffsetType($sot);\n"
				append s "s.LeftValType(24);\ns.RightVal1ValType(ivtObjectId);\ns.RightVal1(tm.ID());\ns.ConditionType($ct);\ns.ConditionType2($ct2);\n"
			} else {
				error "Invalid condition"
			}
		}
	}
	return [list $s $triggers $ng]
}

# ReGa statements for the actions of one branch
proc ::hue::flows::acts_script {arrName path rv} {
	upvar 1 $arrName B
	set s ""
	set n [::hue::json::len B $path]
	for {set i 0} {$i < $n} {incr i} {
		set ap $path/$i
		set dp [id [::hue::json::get B $ap/dp]]
		set param [::hue::json::get B $ap/param 18]
		if {[lsearch -exact {18 19} $param] < 0} { error "Invalid action" }
		set vt [::hue::json::get B $ap/vt 2]
		if {$vt == 20} { error "Script actions are not supported" }
		set value [literal [::hue::json::get B $ap/value] $vt]
		set delay [::hue::json::get B $ap/delay]
		append s "o = dom.GetObject($dp);\nd = ${rv}.RuleDestination().DestAddSingle();\nd.DestinationParam($param);\n"
		if {$param == 18} { append s "d.DestinationChannel(o.Channel());\n" }
		append s "d.DestinationDP(o.ID());\nd.DestinationValueType(o.ValueType());\nd.DestinationValue($value);\n"
		if {$delay != ""} {
			if {![regexp {^([0-9][0-9]):([0-5][0-9]):([0-5][0-9])$} $delay]} { error "Invalid delay ${delay}" }
			append s "d.DestinationValueParamType(28);\nd.DestinationValueParam(\"$delay\");\n"
		} else {
			append s "d.DestinationValueParamType(0);\n"
		}
	}
	return [list $s $n]
}

# Create or replace a program from a flow (request body in array B, flow under "flow")
# Returns {id rev}
proc ::hue::flows::save {arrName pid rev} {
	upvar 1 $arrName B
	set name [check_name [::hue::json::get B flow/name]]
	set a "false"
	if {[lsearch -exact {true 1} [::hue::json::get B flow/active "true"]] >= 0} { set a "true" }
	set nb [::hue::json::len B flow/branches]
	if {$nb < 1} { error "A flow needs a condition" }
	set old_tms [list]
	if {$pid != ""} {
		set pid [id $pid]
		set text [dump $pid]
		set m [single_model $text]
		if {$m == ""} { error "Program ${pid} not found" }
		if {![string equal $rev [rev $text]]} { error "The program was changed in the CCU meanwhile" "" 409 }
		if {[lindex $m 0] != ""} { error "This program can only be changed in the CCU" }
		set old_tms [time_modules $text]
	}
	set body ""
	set actions 0
	for {set b 0} {$b < $nb} {incr b} {
		set path flow/branches/$b
		set rv "r$b"
		if {$b > 0} {
			append body "object $rv = r[expr {$b - 1}].RuleCreateSubRule();\n"
		}
		append body "${rv}.ElseIfFlag(true);\n"
		set bor [expr {[string equal [::hue::json::get B $path/stop_delays "true"] "false"] ? "false" : "true"}]
		append body "rd = ${rv}.RuleDestination();\nrd.BreakOnRestart($bor);\n"
		set c [conds_script B $path $rv]
		if {[lindex $c 2] == 0} { error "Every branch needs a condition" }
		if {$b == 0 && [lindex $c 1] == 0} { error "A flow needs a trigger" }
		append body [lindex $c 0]
		set t [acts_script B $path/then $rv]
		incr actions [lindex $t 1]
		append body [lindex $t 0]
	}
	if {[info exists B(flow/else/%)]} {
		set rv "re"
		append body "object re = r[expr {$nb - 1}].RuleCreateSubRule();\nre.ElseIfFlag(false);\n"
		set bor [expr {[string equal [::hue::json::get B flow/else/stop_delays "true"] "false"] ? "false" : "true"}]
		append body "rd = re.RuleDestination();\nrd.BreakOnRestart($bor);\n"
		set t [acts_script B flow/else/then re]
		incr actions [lindex $t 1]
		append body [lindex $t 0]
	}
	if {$actions == 0} { error "A flow needs an action" }
	set head "!hue:flows:save\nobject c;\nobject s;\nobject o;\nobject d;\nobject rd;\nobject tm;\n"
	if {$pid != ""} {
		backup $pid
		append head "object p = dom.GetObject($pid);\nobject r0 = p.Rule();\n"
		# Remove conditions, actions and sub rules; the program keeps its id
		append head "string ids = \"\";\ninteger i = 0;\nwhile (i < r0.RuleConditions().Count()) { c = r0.RuleCondition(i); ids = ids # c.ID() # \"\\t\"; i = i + 1; }\n"
		append head "string x;\nforeach(x, ids) { r0.RuleDelCondition(x); }\n"
		append head "rd = r0.RuleDestination();\nids = \"\";\ni = 0;\nwhile (i < rd.DestSingleCount()) { d = rd.DestSingleDestination(i); ids = ids # d.ID() # \"\\t\"; i = i + 1; }\n"
		append head "foreach(x, ids) { rd.DestDelSingle(x); }\n"
		append head "object sr = r0.RuleSubRule();\nif (sr) { r0.RuleDelSubRule(); }\n"
		# Old time modules go before new ones are created: ReGa reuses freed ids
		foreach t $old_tms {
			append head "o = dom.GetObject($t);\nif (o) { if (o.IsTypeOf(OT_CALENDARDP)) { dom.DeleteObject($t); } }\n"
		}
	} else {
		append head "object p = dom.CreateObject(OT_PROGRAM);\ndom.GetObject(ID_PROGRAMS).Add(p.ID());\np.Visible(true);\nobject r0 = p.Rule();\n"
	}
	append head "p.Name(\"$name\");\np.Active($a);\n"
	set tail "system.Save();\nWriteLine(\"OK|\" # p.ID());"
	set out [rega "$head$body$tail"]
	if {![regexp {OK\|([0-9]+)} $out -> id]} { error "Program not saved: $out" }
	return [list $id [rev [dump $id]]]
}

# Current values for the preview: {now weekday sunrise sunset values}
proc ::hue::flows::values_json {dps} {
	set s "!hue:flows:values\nWriteLine(\"NOW|\" # system.Date(\"%H:%M:%S\") # \"|\" # system.Date(\"%w\"));\n"
	append s "WriteLine(\"SUN|\" # system.SunriseTime(\"%H:%M\") # \"|\" # system.SunsetTime(\"%H:%M\"));\nobject o;\n"
	foreach dp $dps {
		set dp [id $dp]
		append s "o = dom.GetObject($dp);\nif (o) { WriteLine(\"V|$dp|\" # o.Value()); }\n"
	}
	set out [rega $s]
	set S ::hue::json::str
	set now ""
	set wd 0
	set rise ""
	set sunset ""
	set vals [list]
	foreach line [split [string map {"\r" ""} $out] "\n"] {
		set f [split $line "|"]
		switch -- [lindex $f 0] {
			NOW { set now [lindex $f 1]; set wd [lindex $f 2] }
			SUN { set rise [lindex $f 1]; set sunset [lindex $f 2] }
			V { lappend vals [lindex $f 1] [$S [join [lrange $f 2 end] "|"]] }
		}
	}
	if {![string is integer -strict $wd]} { set wd 0 }
	return [::hue::json::objl [list now [$S $now] weekday $wd sunrise [$S $rise] sunset [$S $sunset] values [::hue::json::objl $vals]]]
}

proc ::hue::flows::run {pid} {
	set pid [id $pid]
	set out [rega "!hue:flows:run\nobject p = dom.GetObject($pid);\nif (p) { if (p.IsTypeOf(OT_PROGRAM)) { p.ProgramExecute(); WriteLine(\"RUN|\" # p.ID()); } }"]
	if {![regexp {RUN\|} $out]} { error "Program not started: $out" }
	return $pid
}
