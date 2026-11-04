# Changelog

## 4.0.0

- Hue API v2 neu geschrieben: echter JSON-Parser, zuverlässige Zuordnung von v1-IDs zu v2-IDs, HTTPS immer auf Port 443. Bisher lief v2 über den v1-Port und fiel deshalb meist still auf v1 zurück.
- Alle v1-Befehle werden übersetzt, auch `transitiontime`, `hue`/`sat`, `*_inc`, `alert`, `effect` und Szenen per Name. `effect:colorloop` geht über v1.
- Echtzeit-Updates über den v2-Event-Stream. Das Abfrage-Intervall dient nur noch als Sicherheitsnetz.
- Räume und Zonen werden über `grouped_light` gesteuert: ein Befehl statt einer pro Lampe.
- Sensoren und Tasten (Bewegung, Lux, Temperatur, Tastenereignisse) in Echtzeit in Systemvariablen.
- v2-IDs (UUID) als Objekt-ID in Befehlen möglich.
- Neue v2-Befehle: `gradient`, `timed_effect` (Sonnenaufgang/-untergang), `speed`, `signal`, `identify`.
- Neue Addon-Seite ohne jQuery und Semantic UI: Räume mit Lampenkacheln in der echten Farbe und Helligkeit der Lampe, live aktualisiert. Antippen schaltet, die Detailansicht bündelt Helligkeit, Weißton, Farbe, Effekte und das HomeMatic-Gerät. Deutsch und Englisch, hell und dunkel, fürs Handy, Bedienungshilfen.
- Geführte Ersteinrichtung in drei Schritten, Diagnose mit Statusprüfungen, Einstellungen in verständlichen Gruppen.
- Live-Abfrage der Addon-Seite aus dem Cache des Hue-Dienstes, ohne zusätzliche Anfragen an die Bridge.
- „Alle übernehmen“ legt CUxD-Geräte für alle Lampen und Räume an. „Systemvariablen anlegen“ legt sie für Sensoren an.
- Ein-Klick-Update aus der Addon-Seite mit SHA-256-Prüfung. Die Update-Prüfung in der CCU zeigt auf dieses Repository.
- Umstieg von 3.2.x und 3.3.0 ohne Änderungen: Einstellungen bleiben erhalten, zusätzlich gesichert in `/usr/local/etc/config/hue.conf.bak`.
- Läuft auf der CCU3 mit Original-Firmware (Tcl 8.2) und auf OpenCCU / RaspberryMatic (Tcl 8.6): eigener JSON-Parser, keine Abhängigkeit von tcllib.
- Sicherheit: „Befehl testen“ läuft ohne Shell, `log.cgi` braucht eine Anmeldung, Eingaben werden geprüft.
- Pairing mit `generateclientkey`, über HTTPS, wenn die Bridge es kann.
- Build-Artefakte und Sicherungsdateien aus dem Repository entfernt. Releases kommen über GitHub Actions.

## 3.3.0

- Erste Version mit Hue API v2 und TLS-Pinning (unzuverlässig, siehe 4.0.0).

## 3.2.5 und älter

Siehe [j-a-n/homematic-addon-hue](https://github.com/j-a-n/homematic-addon-hue).
