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
    WriteLine(\"R|\" # r.ID() # \"|\" # lvl # \"|\" # n);
    integer i = 0;
    while (i < n) {
      object c = r.RuleCondition(i);
      WriteLine(\"C|\" # c.ID() # \"|\" # c.CndOperatorType());
      integer j = 0;
      while (j < c.CndSingleCount()) {
        object s = c.CndSingleCondition(j);
        string lv = s.LeftVal();
        string ln = \"\";
        object lo = dom.GetObject(lv);
        if (lo) { ln = lo.Name(); }
        string chn = \"\";
        object cho = dom.GetObject(s.ConditionChannel());
        if (cho) { chn = cho.Name(); }
        WriteLine(\"S|\" # s.ID() # \"|\" # lv # \"|\" # s.LeftValType() # \"|\" # s.ConditionType() # \"|\" # s.ConditionType2() # \"|\" # s.RightVal1() # \"|\" # s.RightVal2() # \"|\" # s.ConditionChannel() # \"|\" # ln # \"|\" # chn # \"|\" # s.OperatorType());
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
	foreach line [split [string map {"\r" ""} $text] "\n"] {
		set f [split $line "|"]
		set kind [lindex $f 0]
		if {[string equal $kind "P"]} {
			if {$cur != ""} { lappend programs [finish_program P R] }
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
		}
	}
	if {$cur != ""} { lappend programs [finish_program P R] }
	return "\{\"programs\":[::hue::json::arr $programs]\}"
}

proc ::hue::flows::finish_program {pName rName} {
	upvar 1 $pName P $rName R
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
					value [$S $r1] value2 [$S $r2] channel [$S $chid] name [$S $lname] channel_name [$S $chname] press [$S $press]]]
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
		last [$S $P(last)] editable [::hue::json::bool $editable] reason [$S $why] rules [::hue::json::arr $rules]]]
}

# Everything a flow can start from or switch, as JSON
proc ::hue::flows::catalog_json {} {
	set out [rega "!hue:flows:catalog
string cid;
foreach(cid, dom.GetObject(ID_CHANNELS).EnumUsedIDs()) {
  object ch = dom.GetObject(cid);
  string ht = ch.HssType();
  object dv = dom.GetObject(ch.Device());
  string dn = \"\";
  if (dv) { dn = dv.Name(); }
  string rooms = \"\";
  string rid;
  foreach(rid, ch.ChnRoom()) { object ro = dom.GetObject(rid); rooms = rooms # ro.Name() # \";\"; }
  string list = \"\";
  string dpn;
  foreach(dpn, \"PRESS_SHORT\tPRESS_LONG_START\tPRESS_LONG\tSTATE\tTOGGLE\tLEVEL\") {
    object dp = ch.DPByHssDP(dpn);
    if (dp) { list = list # dpn # \"=\" # dp.ID() # \"/\" # dp.Operations() # \"/\" # dp.ValueType() # \";\"; }
  }
  if (list != \"\") { WriteLine(\"CH|\" # cid # \"|\" # ht # \"|\" # list # \"|\" # rooms # \"|\" # ch.Name() # \"|\" # dn # \"|\" # ch.Device() # \"|\" # ch.Address()); }
}
string sid;
foreach(sid, dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs()) {
  object sv = dom.GetObject(sid);
  if (sv) {
    if ((sv.ValueSubType() == istEnum) || (sv.ValueType() == ivtBinary)) {
      WriteLine(\"SV|\" # sid # \"|\" # sv.ValueType() # \"|\" # sv.ValueList() # \"|\" # sv.Name());
    }
  }
}"]
	set S ::hue::json::str
	set triggers [list]
	set targets [list]
	set lines [split [string map {"\r" ""} $out] "\n"]
	# Wall switches (multi mode inputs) also have switch channels for their LEDs: no targets
	set buttons [list]
	set actuators [list]
	foreach line $lines {
		set f [split $line "|"]
		if {[string equal [lindex $f 2] "MULTI_MODE_INPUT_TRANSMITTER"]} { lappend buttons [lindex $f 7] }
		if {[regexp {(STATE|LEVEL)=[0-9]+/[0-9]*[2367]/} [lindex $f 3]] && ![string match "*PRESS_SHORT*" [lindex $f 3]]} { lappend actuators [lindex $f 7] }
	}
	set seen [list]
	foreach line $lines {
		set f [split $line "|"]
		if {[string equal [lindex $f 0] "CH"] && [llength $f] >= 7} {
			foreach {x cid ht dps rooms name dname devid addr} $f break
			# Virtual keys of the CCU itself
			if {[string equal $ht "VIRTUAL_KEY"] || [string match "_*" $name] || [regexp {^(BidCoS-RF|HmIP-RCV|BidCoS-Wir)} $addr]} { continue }
			catch {unset D}
			array set D {}
			foreach item [split $dps ";"] {
				if {[regexp {^([A-Z_]+)=([0-9]+)/([0-9]+)/([0-9]+)$} $item -> k id ops vt]} { set D($k) [list $id $ops $vt] }
			}
			set rl [list]
			foreach r [split $rooms ";"] { if {$r != ""} { lappend rl [$S $r] } }
			# Keys: wall switches and remotes. Keys of actuators and CUxD switches are no triggers.
			if {[info exists D(PRESS_SHORT)] && [regexp {^(MULTI_MODE_INPUT_TRANSMITTER|KEY_TRANSCEIVER|KEY)$} $ht] \
					&& ![string match "CUX*" $addr] && ([string equal $ht "MULTI_MODE_INPUT_TRANSMITTER"] || [lsearch -exact $actuators $devid] < 0)} {
				set long ""
				if {[info exists D(PRESS_LONG_START)]} { set long [lindex $D(PRESS_LONG_START) 0] } elseif {[info exists D(PRESS_LONG)]} { set long [lindex $D(PRESS_LONG) 0] }
				lappend triggers [::hue::json::objl [list channel [$S $cid] name [$S $name] device [$S $dname] rooms [::hue::json::arr $rl] \
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
			if {$devid != "" && [lsearch -exact $buttons $devid] >= 0} { continue }
			# Virtual receivers come in threes: the first one of a device is enough
			if {[regexp {VIRTUAL_RECEIVER} $ht]} {
				if {[lsearch -exact $seen "$devid/$ht"] >= 0} { continue }
				lappend seen "$devid/$ht"
			}
			lappend targets [::hue::json::objl [list kind [$S $kind] dp [$S $dp] toggle [$S $toggle] channel [$S $cid] name [$S $name] \
				device [$S $dname] rooms [::hue::json::arr $rl] type [$S $ht]]]
		} elseif {[string equal [lindex $f 0] "SV"] && [llength $f] >= 5} {
			foreach {x sid vt vlist} $f break
			set name [join [lrange $f 4 end] "|"]
			set vl [list]
			foreach v [split $vlist ";"] { lappend vl [$S $v] }
			set kind "sysvar"
			if {[string match "Hue Szene *" $name]} { set kind "scene" }
			lappend targets [::hue::json::objl [list kind [$S $kind] dp [$S $sid] name [$S $name] vtype [$S $vt] values [::hue::json::arr $vl] rooms "\[\]"]]
		}
	}
	return "\{\"triggers\":[::hue::json::arr $triggers],\"targets\":[::hue::json::arr $targets]\}"
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
