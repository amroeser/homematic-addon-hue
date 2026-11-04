# Credits

## Autoren

| | Versionen | Zeitraum |
|---|---|---|
| **Jan Schneider** ([j-a-n](https://github.com/j-a-n)) | 1.0 bis 3.2.5: das ursprüngliche Addon, Hue API v1, CUxD-Geräte, Hue-Dienst | 2017 bis 2021 |
| **Alexander Maximilian Röser** ([amroeser](https://github.com/amroeser)) | 3.3 und 4.x: Hue API v2 mit Echtzeit, neue Oberfläche, CCU3-Unterstützung, Szenen, Lampen ohne Hue, Updates mit einem Klick | 2025 bis 2026 |

Mit einem Beitrag von **Uwe Langhammer**, dem Autor von CUxD (Kompatibilität mit neueren CUxD-Versionen, 2021).

Danke an alle, die Fehler gemeldet und Versionen getestet haben.

## Im Paket enthalten

| Komponente | Version | Lizenz | Urheber | Wofür |
|---|---|---|---|---|
| [tcllib inifile](https://core.tcl-lang.org/tcllib) (`addon/lib/ini.tcl`) | 0.3 | Tcl/Tk-Lizenz (BSD-artig) | Aaron Faupell, Andreas Kupries | Einstellungen in `hue.conf` lesen und schreiben |
| [Instrument Sans](https://github.com/Instrument/instrument-sans) (`addon/www/fonts`) | 1.000 | SIL Open Font License 1.1 | The Instrument Sans Project Authors | Schrift der Oberfläche |

Alles Übrige ist eigener Code unter GPL-3.0: JSON-Parser, Hue API v1 und v2, Hue-Dienst, Weboberfläche ohne fremde JavaScript-Bibliotheken, Icons und Logo.

## Auf der Zentrale vorausgesetzt (nicht im Paket)

| Komponente | Lizenz | Herkunft | Wofür |
|---|---|---|---|
| Tcl 8.2 bis 8.6 | Tcl/Tk-Lizenz | Teil der CCU-Firmware | Laufzeit des Addons |
| tclrega, tclrpc | eQ-3 | Teil der CCU-Firmware ([OCCU](https://github.com/eq-3/occu)) | ReGa-Skripte und XML-RPC |
| [CUxD](https://homematic-forum.de/forum/viewforum.php?f=37) | CUxD-Lizenz (Freeware) | Uwe Langhammer | Geräte, die Hue-Befehle aus Programmen ausführen |
| [curl](https://curl.se) | curl-Lizenz | Daniel Stenberg und Mitwirkende | HTTPS zur Bridge, Event-Stream, Shelly-Status |
| [OpenSSL](https://www.openssl.org) | Apache-2.0 | OpenSSL-Projekt | Schlüssel der Bridge für die TLS-Prüfung |

## Nur für Entwicklung und Tests (nicht im Paket)

Python 3, [Playwright](https://playwright.dev) (Screenshots und Demo-Videos), [FFmpeg](https://ffmpeg.org) (Videos und GIFs), Docker mit dem [OpenCCU](https://github.com/OpenCCU/OpenCCU)-Image und den CCU3-Laufzeitdateien aus [eq-3/occu](https://github.com/eq-3/occu) für Tests mit Tcl 8.6 und Tcl 8.2, GitHub Actions für Tests und Releases.

## SBOM

Jedes Release enthält eine Software-Stückliste im Format CycloneDX 1.5: `hm-hue.cdx.json` als Download am Release und im Paket. Sie listet alle Dateien des Addons und die eingebundenen Fremdkomponenten mit SHA-256-Prüfsummen sowie alles, was das Addon auf der Zentrale benötigt. Erzeugt wird sie mit `tools/make_sbom.py`.

## Marken

Philips Hue und Hue sind Marken von Signify. HomeMatic und HomeMatic IP sind Marken der eQ-3 AG. Shelly ist eine Marke von Shelly Group. Dieses Projekt ist mit keinem dieser Unternehmen verbunden.
