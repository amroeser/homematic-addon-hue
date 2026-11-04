# Changelog

## 4.0.5

- Credits: Jan Schneider als ursprünglicher Autor (Versionen 1.0 bis 3.2.5), Alexander Maximilian Röser für Version 4. Alle eingebundenen und vorausgesetzten Komponenten mit Lizenzen in `CREDITS.md`.
- Software-Stückliste (SBOM) im Format CycloneDX 1.5: am Release als `hm-hue.cdx.json`, im Paket und unter Einstellungen → „Über dieses Addon“ zum Herunterladen.

## 4.0.4

- Bridge und Hue-Konto in der Diagnose: Internet, Hue-Konto, Zugriff von unterwegs und Uhrzeit auf einen Blick.
- Updates der Bridge und aller Lampen und Zubehörteile: Status je Gerät, „Nach Updates suchen“, „Jetzt installieren“ und automatische Updates mit Uhrzeit.
- Apps mit Zugriff auf die Bridge mit „zuletzt benutzt“, damit alte Zugänge auffallen. Verwalten lassen sie sich im Hue-Konto.
- Anleitung für einen Mieter- oder Besitzerwechsel.

## 4.0.3

- Lampen ohne Hue: Shellys hinter CUxD-Schaltern und HomeMatic-Aktoren ordnest du in den Raumdetails einem Hue-Raum zu. Sie schalten mit dem Raum an und aus, egal ob über die Addon-Seite, ein Programm, die Szenen-Auswahlliste, die Hue-App oder einen Hue-Schalter. Wahlweise nur aus. Je Szene einstellbar: an, aus oder unverändert. Das Addon schlägt passende Geräte aus der CCU vor und zeigt sie als Kacheln im Raum.
- Shelly-Zustand: Für CUxD-Schalter, die einen Shelly per URL schalten, liest das Addon das Relais und korrigiert den Zustand in HomeMatic, ohne erneut zu schalten. Damit stimmt „Umschalten“ in Programmen auch nach dem Wandschalter.
- Szenen-Tasten stehen nur auf „an“, solange ihre Szene aktiv ist. Bisher standen alle Tasten eines Raums auf „an“; ein Programm, das die zweite Szene per „Umschalten“ aufrufen sollte, schaltete den Raum stattdessen aus.
- Schneller: Der Gerätetyp der CUxD-Geräte wird nur noch einmal abgefragt, nicht bei jeder Zustandsänderung.
- Kurzanleitung um den Schritt „Lampen ohne Hue“ erweitert.
- Räume zeigen beim HomeMatic-Hinweis, was verbunden ist, etwa „Szenen-Tasten: Hell, Gedimmt“, mit den Gerätenamen der CCU statt CUxD-Adressen.
- Sensoren übersichtlicher: kompakter Hinweis zur Systemvariable, Tastenereignisse verständlich („Kurz gedrückt“ statt `short_release`).

## 4.0.2

- Szenen als Auswahlliste: Auf Wunsch legt das Addon je Raum und Zone eine Systemvariable „Hue Szene <Raum>“ an und hält sie automatisch aktuell. In Programmen wählst du die Szene einfach aus, „Aus“ schaltet den Raum aus. Wählst du in der Hue-App eine Szene, steht sie auch in HomeMatic. Neue Szenen werden angehängt, gelöschte als „(entfernt)“ markiert, damit sich die Positionen in Programmen nie verschieben. Keine CUxD-Befehle nötig.
- Kurzanleitung: Beim ersten Öffnen erklärt eine interaktive Anleitung in fünf Schritten, wie Hue-App, Addon und HomeMatic zusammenspielen, mit Räumen, Zonen, Szenen, Sensoren und Programm-Beispielen. Jederzeit erneut aufrufbar.
- Szenen-Tasten speichern die Szenen-ID statt des Namens: robust gegen Umlaute, Sonderzeichen und Umbenennen.
- Szenen per Name werden tolerant gefunden: Groß- und Kleinschreibung, Leerzeichen (`_`), Umlaute und falsch kodierte Zeichen spielen keine Rolle.
- Namen von Systemvariablen und Listeneinträgen nur in ASCII (`Kueche`), weil die CCU intern ISO-8859-1 nutzt.
- Behoben: Nach einer Unterbrechung des Event-Streams wurde der Status der Szenen nicht nachgeladen.

## 4.0.1

- Szenen als Tasten: In den Raumdetails legst du für jede Szene eine CUxD-Taste an. Lang drücken ruft die Szene per Name auf, kurz drücken schaltet den Raum aus. Vorhandene Szenen-Tasten werden erkannt, auch solche mit Szenen-ID.
- Szenen per Name funktionieren ohne Anführungszeichen: `scene:Guten_Morgen` ruft „Guten Morgen“ auf, Groß- und Kleinschreibung egal.
- „Alle hinzufügen“ bezieht Zonen ein. Räume mit HomeMatic-Gerät sind markiert, Lampen in solchen Räumen gelten als abgedeckt.
- Behoben: Umlaute in Namen wurden auf der CCU falsch angezeigt.
- Behoben: CUxD-Befehle mit großgeschriebener Bridge-ID (aus älteren Versionen) führten zu einer doppelt geführten Bridge, die Diagnose zeigte „Echtzeit nicht verbunden“.

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
