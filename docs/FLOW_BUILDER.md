# Ablauf-Editor: Datenmodell

Der Editor auf der Seite *Abläufe* zeigt ein CCU-Programm als Auslöser → Bedingung → Ja/Nein → Aktionen und schreibt es zurück. Umsetzung: `addon/lib/flows.tcl` (Lesen, Modell, Schreiben), `addon/www/rest.cgi` (API), `addon/www/index.html` (`FE`, `openFlow`). Tests: `test_62_flow_designer`, `test_63_flow_editor`.

## Grundsätze

1. **Das CCU-Programm ist die einzige Quelle.** Das Addon speichert keine Abläufe, keine Entwürfe und keine Positionen. Ein Entwurf ist ein pausiertes Programm.
2. **Das Modell spiegelt die CCU, es normalisiert nicht.** Jede Bedingung und Aktion behält ihre Rohfelder. Öffnen und Speichern ohne Änderung schreibt dasselbe Programm. Ein Zweig wird erst umgebaut, wenn er im Editor geändert wurde.
3. **Der Canvas ist eine Ansicht.** Knoten, Linien und Layout werden aus dem Flow berechnet.

```
CCU-Programm (ReGa)  ⇄  Flow (JSON)  →  Canvas
     dump / save         model           FE.view / FE.rebuild
```

## Aufbau eines CCU-Programms

```
Program  (Name, Active, Visible)
└─ Rule  (Ebene 0 = WENN, ElseIfFlag true)
   ├─ RuleConditions[]          Gruppen; CndOperatorType: 1 = und, 2 = oder (alle Gruppen gleich)
   │  └─ CndSingleCondition[]   OperatorType: Verknüpfung mit der vorigen (in einer Gruppe einheitlich)
   ├─ RuleDestination           BreakOnRestart = „laufende Verzögerungen beenden“
   │  └─ DestSingleDestination[]
   └─ RuleSubRule               ElseIfFlag true = SONST WENN, false = SONST
```

Leere Unterregeln mit `ElseIfFlag true` ohne Bedingungen und Aktionen legt die WebUI als Platzhalter an; der Editor ignoriert sie.

`ConditionType2` (eq-3 `WebUI/www/rega/esp/sico.fn`): 1 Tastendruck, 4 bei Änderung, 13 bei Aktualisierung bzw. zu Zeitpunkten, 15 nur prüfen. Alles außer 15 ist ein Auslöser.

`ConditionType`: 1 gleich (setzt die WebUI bei jeder Auswahl), 3 Zeit, 5 gleich (Zahl), 6/12 ungleich, 7 Bereich, 8 >, 9 ≥, 10 <, 11 ≤.

## Flow (JSON)

`GET flows/<id>` liefert `{"flow": …, "rev": …}`:

```json
{
  "id": "18777", "name": "Wohnzimmer Lampe", "active": true, "last": "…", "editable": true, "reason": "",
  "branches": [{
    "when": { "op": "and", "groups": [
      [ { "kind": "key", "lvt": "18", "dp": "9346", "ch": "9344", "ct": "1", "ct2": "1", "rv1": "true", "rv2": "false", "rt1": "2", "rt2": "2", "op": "2", "press": "SHORT" },
        { "kind": "key", "lvt": "18", "dp": "9347", "ch": "9344", "ct": "1", "ct2": "1", "rv1": "true", "rv2": "false", "rt1": "2", "rt2": "2", "op": "2", "press": "LONG_START" } ],
      [ { "kind": "value", "lvt": "18", "dp": "3105", "ch": "3101", "ct": "1", "ct2": "15", "rv1": "false", "rv2": "false", "rt1": "2", "rt2": "2", "op": "2" } ]
    ] },
    "then": [ { "param": "18", "dp": "3105", "ch": "3101", "vt": "2", "value": "true", "delay": "" } ],
    "stop_delays": true
  }],
  "else": { "then": [ { "param": "18", "dp": "3105", "ch": "3101", "vt": "2", "value": "false", "delay": "" } ], "stop_delays": true }
}
```

Jede Einzelbedingung und Aktion trägt zusätzlich `name` und `channel_name` für die Anzeige.

| Feld | Bedeutung |
|---|---|
| `when.op` | Verknüpfung der Gruppen (`CndOperatorType`) |
| Einzelbedingung `op` | Rohwert von `OperatorType` |
| `kind` | `key`, `value` (Gerät), `sysvar`, `time` |
| `lvt` | 18 Gerät, 19 Systemvariable, 24 Zeit |
| `rt1`, `rt2` | Werttyp: 2 Logik, 4 Zahl, 16 Ganzzahl, 20 Zeichenkette |
| `tm` | Zeitmodul: `type` (9 täglich, 5 wöchentlich), `sot` (0, 3 tagsüber, 6 nachts), `time` (Sekunden des Tages, -1 = keine Uhrzeit), `dur`, `wd` (Mo = 1 … So = 64), `rep` (alle n Tage/Wochen), `count`, `begin`, `end` (gültig von–bis) |
| Aktion `param` | 18 Gerät, 19 Systemvariable |
| `delay` | `HH:MM:SS` oder leer |
| `editable`, `reason` | nur lesbar bei `script`, `unknown_condition`, `unknown_action`, `mixed_ops` (und/oder gemischt in einer Gruppe), `layout` |

## Schreiben

`POST flows/save` mit `{"id", "rev", "flow"}`, Antwort `{"id", "rev"}`:

- Bestehendes Programm: Dump neu lesen, `rev` vergleichen (sonst 409), nur editierbare Programme (sonst 400), Sicherung nach `hue-flow-backups`, dann Bedingungen, Aktionen, Unterregeln und alte Zeitmodule löschen und neu aufbauen. Die Programm-ID bleibt.
- Neues Programm: `dom.CreateObject(OT_PROGRAM)`.
- Werte werden nach Werttyp geschrieben (`45.0` Zahl, `45` Ganzzahl, `"short_release"` Zeichenkette). Erlaubt sind Logikwerte, Zahlen und Zeichenketten aus `[A-Za-z0-9_ .:-]`; IDs nur numerisch.
- Verzögerung: `DestinationValueParamType(28)`, `DestinationValueParam("HH:MM:SS")`.
- Zeitbedingung: `dom.CreateObject(OT_CALENDARDP)` mit den Eigenschaften, die auch die WebUI setzt (`Time("0")` ohne Uhrzeit, sonst `"2007-01-01 HH:MM:SS"`), Bedingung mit `LeftValType(24)`, `RightVal1ValType(ivtObjectId)`, `RightVal1(<Zeitmodul>)`.

Namen: tclrega übergibt Skripte als UTF-8, ReGa und die WebUI speichern Namen in ISO-8859-1. Programmnamen mit Umlauten werden deshalb mit `ToLatin()` umgewandelt (RaspberryMatic, OpenCCU); fehlt die Methode, schreibt das Addon „ae“, „oe“, „ue“, „ss“.

`rev` ist ein FNV-1a-Hash über den Dump des Programms (reines Tcl, ohne Zusatzprogramme).

## Canvas

`FE.view(branch)` liefert Auslöser, Prüfungen und ob die Darstellung die Bedeutung trifft:

- Gruppen mit „oder“: Jede Gruppe enthält dieselben Auslöser, Auslöser und Prüfungen sind mit „und“ verknüpft. Typisch: `(Taste und A) oder (Taste und B)`, angezeigt als Taste → „A oder B“.
- Gruppen mit „und“: Auslöser stehen allein in einer Gruppe. Typisch: `(Taste kurz oder lang) und Lampe aus`.
- Sonst `layout`: Der Ablauf ist sichtbar, aber nur in der CCU änderbar.

`FE.rebuild` erzeugt nach einer Änderung dieselben Formen. In SONST-WENN-Zweigen gehören Auslöser zur Bedingung und werden mit angezeigt.

Vorschau: `POST flows/values` liefert Uhrzeit, Wochentag, Sonnenauf- und -untergang (`system.SunriseTime`, `system.SunsetTime`) und die Werte der Datenpunkte. Der Browser wertet aus, Tasten gelten als gedrückt; es wird nichts geschaltet. `POST flows/<id>/run` führt das Programm einmal aus (`ProgramExecute`).

## Sicherungen, Rückgängig, Namen

- `GET flows/<id>/backups` listet die Sicherungen eines Programms (neueste zuerst), `GET flows/<id>/backups/<datei>` liefert eine als Flow. Der Editor lädt sie als Entwurf; gespeichert wird erst mit *Speichern* (mit `rev`-Prüfung gegen den aktuellen Stand). Nur Dateinamen `JJJJMMTT-hhmmss-<id>.txt` werden angenommen.
- Rückgängig: Der Editor merkt sich bis zu 50 frühere Stände des Entwurfs.
- Katalog: `label` mit dem Namen aus der Hue-Bridge (Raum, Lampe, Raum · Szene; bei Sensor-Variablen der Sensorname). Die Bridge wird dafür einmal je Katalog gelesen.
- `GET flows/links` wird fünf Minuten in `/tmp/hue-flow-links.json` zwischengespeichert.

## Warnungen und Tipps

`flowAnalysis` (Browser) prüft alle aktiven Programme gemeinsam; im Editor ersetzt der Entwurf sein Programm, sodass Hinweise schon vor dem Speichern erscheinen.

| Art | Erkennung |
|---|---|
| Taste doppelt belegt | Dieselbe Taste (Datenpunkt) als Auslöser in mehreren aktiven Programmen, alle Zweige |
| Widersprüchliche Aktionen | Gleiche Taste, gleiches Ziel (Kanal), anderer Wert im ersten Zweig; oder beide schalten dasselbe Ziel um (heben sich auf); oder ein Zweig schaltet ein Ziel gleichzeitig unterschiedlich |
| Taste auch direkt verknüpft | Kanal der Taste ist Sender einer Direktverknüpfung (`GET flows/links`, XML-RPC `getLinks` auf HmIP-RF und BidCos-RF, ohne Gruppenverknüpfungen von Thermostaten) |
| Kein Auslöser | Im WENN ist alles „nur prüfen“ |
| Lange Taste wiederholt | `PRESS_LONG` statt `PRESS_LONG_START` |
| Tipp: umschalten | „Wert aus → an, sonst aus“ auf ein Ziel mit `TOGGLE` |
| Tipp: Bedingung löst aus | Taste plus auslösender Gerätewert bei vorhandenem „Sonst“ |
| Tipp: Schleife | Auslösender Gerätewert, dessen Kanal das Programm selbst schaltet |
| Tipp: Raum statt Lampen | Drei oder mehr Hue-Lampen eines Raums in einem Zweig |
| Tipp: Verzögerungen | Verzögerte Aktion ohne „laufende Verzögerungen beenden“ |
| Tipp: Gerät ohne Raum | Ziel einer Aktion ohne Raum in der CCU |

Tipps mit Korrektur ändern nur den Entwurf; gespeichert wird wie immer erst mit *Speichern*. Tests: `test/fe_view_test.js`, `test/fe_analysis_test.js` (über `test_64`), `test_65_flow_direct_links`.

## Katalog

`GET flows/catalog` liefert `triggers`, `targets` und `conditions`, jeweils mit `room` (Raum, sonst das Namenspräfix, wenn es ein bekannter Raum ist) und `group`:

| `group` (Aktionen) | Erkennung |
|---|---|
| `hue_scene_key`, `hue_light` | CUxD-Gerät mit `hue.tcl`-Befehl, mit bzw. ohne `scene:` |
| `shelly` | CUxD-Befehl mit `/relay/` oder `/rpc/Switch.Set` |
| `output` | Schaltkanal eines Wandtaster-Moduls (z. B. HmIPW-FIO6), je Ausgang der erste virtuelle Empfänger |
| `plug`, `lamp`, `blind`, `awning`, `switch`, `level` | Gerätetyp `HmIP-PS*`/`BS*`, Name, Kanaltyp |
| `scene`, `sysvar` | Systemvariablen |

Nicht als Aktion angeboten: vom Addon geschriebene Sensorwerte (`Hue_motion_*`, `Hue_lux_*` …), leere Szenenlisten (`Hue Szene`, `Hue Szene 1` …), `DutyCycle*`. Sensorwerte stehen bei den Bedingungen in der Gruppe `hue_sensor`.

## Auf einer echten CCU geprüft

Am 2026-11-05 auf RaspberryMatic mit pausierten Testprogrammen, die danach wieder gelöscht wurden:

- Alle 23 vorhandenen Programme: lesen → Modell → als Kopie schreiben → lesen → Modell identisch.
- Zeitbedingungen (nachts, 18:30–22:00 Mo–Fr), SONST WENN, SONST, Verzögerung und Aktualisieren über `rev`: identisch, alte Zeitmodule entfernt.
- Ein im Browser angelegter Ablauf, genau so, wie der Editor ihn sendet.

Dabei gefunden und berücksichtigt:

- `TimeSeconds()` ist eine Epoch-Zeit, keine Tageszeit. Ohne Uhrzeit schreibt die WebUI `Time("0")`.
- `LeftVal` einer Zeitbedingung liefert die aktuelle Uhrzeit. Der Dump lässt ihn weg, sonst ändert sich `rev` jede Sekunde.
- ReGa vergibt freigewordene IDs sofort neu. Alte Zeitmodule werden deshalb gelöscht, bevor neue entstehen.
