# Sicherheit

## Unterstützte Versionen

Korrekturen, falls es welche gibt, erscheinen nur für die jeweils neueste Version. Aktualisiere am einfachsten direkt auf der Addon-Seite mit *Jetzt aktualisieren*.

| Version | Unterstützt |
|---|---|
| neueste 4.x | ✓ |
| ältere 4.x | nein, bitte aktualisieren |
| 3.x und älter (Jan Schneider) | nein |

## Eine Schwachstelle melden

**Bitte melde Sicherheitslücken nicht über öffentliche Issues.**

1. Bevorzugt: [Schwachstelle privat melden](https://github.com/amroeser/homematic-addon-hue/security/advisories/new) über GitHub (*Security → Report a vulnerability*).
2. Alternativ per E-Mail an den Maintainer (Adresse in [`debian/control`](debian/control)), Betreff „Security: homematic-addon-hue“.

Hilfreich sind:

- betroffene Version des Addons und Zentrale (CCU3, OpenCCU, RaspberryMatic, debmatic)
- Bridge-Modell und genutzte Schnittstelle (API v1 oder v2)
- Schritte zum Nachstellen, gern mit einem Proof of Concept
- deine Einschätzung der Auswirkung

Entferne vor dem Senden App-Keys (`username`, `clientkey`) und Session-IDs aus Protokollen und Debug-Daten.

**Ablauf:** Dies ist ein Freizeitprojekt. Meldungen werden nach bestem Bemühen gelesen und bewertet, es gibt aber keine zugesagten Antwortzeiten und keinen Anspruch auf eine Korrektur. Wird eine Lücke behoben, erscheint die Korrektur in einem Release und, wo sinnvoll, ein GitHub Security Advisory. Auf Wunsch wirst du dort als Finder genannt. Ein Bug-Bounty gibt es nicht.

## Haftungsausschluss

Das Addon steht unter der [GPL-3.0](LICENSE) und wird ohne jede Gewährleistung bereitgestellt, so weit das gesetzlich zulässig ist (Abschnitte 15 und 16 der Lizenz). Die Hinweise in diesem Dokument beschreiben den aktuellen Stand nach bestem Wissen. Sie sind keine zugesicherte Eigenschaft und keine Verpflichtung, Lücken zu beheben. Den Einsatz verantwortest du selbst.

## Geltungsbereich

Im Geltungsbereich ist der Code in diesem Repository: Addon, Addon-Seite, CGI-Skripte, Installations- und Update-Skripte, Build und Release.

Nicht im Geltungsbereich sind Lücken in der CCU-Firmware, ReGaHss, CUxD, der Hue Bridge oder der Hue-App. Melde sie bitte beim jeweiligen Hersteller. Wenn das Addon eine solche Lücke verschärft oder erst ausnutzbar macht, gehört es wieder hierher.

## Sicherheitsmodell

Das Addon läuft auf der Zentrale mit den Rechten des Webservers und der Addons, auf den meisten Systemen als `root`. Es vertraut dem lokalen System und dem Heimnetz in dem Maß, in dem die Zentrale selbst es tut. Die folgenden Abschnitte beschreiben, was das Addon schützt und wo die Grenzen liegen. Wie die Teile zusammenspielen, steht in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Authentifizierung der Addon-Seite

- Alle Endpunkte von `rest.cgi`, `log.cgi` und `debug.cgi` verlangen eine gültige Session der CCU. Das Addon prüft sie bei jeder Anfrage über ReGaHss (`system.GetSessionVarStr`) und einen Abruf von `/pages/index.htm?sid=…` bei der CCU selbst.
- Einzige Ausnahme in `rest.cgi` ist `login`: Er reicht Benutzername und Passwort an die Anmeldung der CCU (`/login.htm`) weiter und speichert nichts.
- Ist in der CCU keine Anmeldung eingerichtet, gibt es auch für das Addon keine. Die Zugriffskontrolle ist die der CCU.
- Die Session-ID steht wie in der WebUI der CCU in der URL (`?sid=@…@`) und kann damit in Browser-Verlauf und Server-Protokollen landen.
- `update.cgi` ist ohne Session erreichbar. Es liefert nur die neueste Versionsnummer von GitHub oder leitet zum Download weiter, damit die Zusatzsoftware-Seite der CCU Updates anzeigen kann.

### Eingaben und Befehle

- Externe Programme startet das Addon mit Argumentlisten. Wo eine Shell nötig ist, wird jedes Argument mit `shq` maskiert.
- `test-command` (Diagnose) führt nur `hue.tcl` aus, nie beliebige Programme.
- Bridge-IDs, Objekt-IDs, Gerätenamen, Szenennamen und Werte werden vor der Verwendung in CUxD-Befehlen, ReGa-Skripten oder der Konfiguration gegen enge Muster geprüft. Abläufe erzeugen ReGa-Skripte nur aus geprüften Namen (`check_name`) und Werten (`check_value`).
- Vor jeder Änderung an einem CCU-Programm sichert das Addon dessen Stand nach `/usr/local/etc/config/hue-flow-backups`.
- Wer angemeldet ist, kann über die Diagnose beliebige Anfragen an die Bridge senden (`request`, `request_v2`) und CCU-Programme anlegen und ändern. Das ist gewollt und entspricht den Rechten eines CCU-Administrators.

### Verbindung zur Hue Bridge

- **API v2** läuft über HTTPS. Die Bridge hat ein selbst signiertes Zertifikat, deshalb pinnt das Addon standardmäßig den öffentlichen Schlüssel (`https_verify=fingerprint`): Beim ersten Kontakt speichert es den SHA-256 des Schlüssels als `tls_pubkey_sha256`, danach lehnt `curl --pinnedpubkey` jeden anderen Schlüssel ab. Der erste Kontakt selbst ist nicht geschützt (Trust on First Use).
- Wurde die Bridge ersetzt oder zurückgesetzt, meldet das Addon „TLS public key … changed“. Den neuen Schlüssel liest *Einstellungen → Schlüssel neu einlesen* ein. Tu das nur, wenn du den Grund kennst.
- `https_verify=strict` prüft gegen eine CA-Datei `etc/hue-ca.pem` mit der Bridge-ID als Hostname. `https_verify=none` schaltet die Prüfung ab und ist nur zur Fehlersuche gedacht.
- Kann `openssl` den Schlüssel nicht lesen, verbindet sich das Addon ohne Prüfung und schreibt eine Warnung ins Protokoll.
- **API v1** (Bridge v1, sehr alte Firmware) läuft unverschlüsselt über HTTP. Der App-Key geht dabei im Klartext durchs Heimnetz. Das ist eine Grenze der Bridge, nicht des Addons; aktualisiere die Firmware, um auf API v2 zu wechseln.
- Die Bridge-Suche über `discovery.meethue.com` und `phoscon.de/discover` sowie der Verbindungsaufbau prüfen kein Zertifikat. Die Suche liefert nur Vorschläge für IP-Adressen; die Kopplung bestätigt der Knopf auf der Bridge.

### Gespeicherte Geheimnisse

- Die App-Keys der Bridges (`username`, bei API v2 auch `clientkey`) stehen im Klartext in `/usr/local/addons/hue/etc/hue.conf` und in der Sicherung `/usr/local/etc/config/hue.conf.bak`. Damit sind sie auch in CCU-Backups enthalten. Wer diese Dateien oder ein Backup lesen kann, kann die Lampen steuern.
- Angemeldete Nutzer sehen den App-Key einer Bridge in deren Einstellungen, um ihn bei Bedarf eintragen zu können. Unter *Apps mit Zugriff* erscheinen von allen Keys nur die ersten sechs Zeichen.
- Protokoll (`/tmp/hue-addon-log.txt`) und Debug-Daten können App-Keys enthalten. Beide sind nur mit Session abrufbar. Entferne Keys, bevor du sie teilst.
- Einen Key, der in falsche Hände geraten ist, entfernst du in der Hue-App unter *Einstellungen → Apps mit Zugriff* bzw. über das Hue-Konto. Danach die Bridge im Addon neu verbinden.

### Lokaler Dienst

- `hued` lauscht nur auf `127.0.0.1:1919` und nimmt Befehle ohne weitere Authentifizierung an. Jeder Prozess auf der Zentrale kann darüber Lampen schalten. Wer Code auf der Zentrale ausführen kann, hat ohnehin vollen Zugriff.
- Die Sperren des Addons belegen lokale Ports ab 11200.
- Der Shelly-Abgleich liest Shelly-Relais im Heimnetz per HTTP ohne Anmeldung. Er schaltet nichts und lässt sich in den *Einstellungen* abschalten.

### Updates und Lieferkette

- Das Ein-Klick-Update lädt `VERSION`, `hm-hue.tar.gz` und `hm-hue.tar.gz.sha256` per HTTPS aus dem neuesten GitHub-Release. Vor der Installation vergleicht es die SHA-256-Prüfsumme und bricht bei einer Abweichung ab.
- Paket und Prüfsumme kommen aus derselben Quelle. Die Prüfsumme schützt vor beschädigten oder unvollständigen Downloads, nicht vor einem kompromittierten GitHub-Konto oder Release.
- Releases werden in GitHub Actions aus einem Tag gebaut, der zur Datei `VERSION` passt, und erst nach bestandenen Tests veröffentlicht. Technisch erzwungen ist das nicht: Wer Schreibrechte am Repo hat, könnte ein Release auch von Hand anlegen. Das Archiv hat festen Besitzer und sortierte Einträge, ist aber nicht bitgleich reproduzierbar.
- Jedes Release enthält eine Software-Stückliste im Format CycloneDX (`hm-hue.cdx.json`). Fremdkomponenten und Lizenzen stehen in [CREDITS.md](CREDITS.md). Zur Laufzeit lädt die Addon-Seite nichts aus dem Internet; Schrift und Code liegen im Paket.
- Ab Version 4.1.3 trägt jedes Release eine signierte Build-Provenance (GitHub Artifact Attestation, Sigstore, SLSA Build Level 2). Sie belegt, dass `hm-hue.tar.gz` und `hm-hue.cdx.json` im Workflow dieses Repos aus einem bestimmten Commit gebaut wurden. Das Ein-Klick-Update auf der Zentrale kann sie nicht prüfen, nur die Prüfsumme.
- Im Workflow haben Jobs nur Leserechte, Schreib- und Signierrechte bekommt allein der Release-Job. Fremde Actions sind per Commit-SHA gepinnt, Dependabot schlägt Updates vor.
- Wer Prüfsumme und Herkunft selbst kontrollieren möchte (zweiter Schritt mit der [GitHub CLI](https://cli.github.com)):

  ```sh
  curl -LO https://github.com/amroeser/homematic-addon-hue/releases/latest/download/hm-hue.tar.gz
  curl -LO https://github.com/amroeser/homematic-addon-hue/releases/latest/download/hm-hue.tar.gz.sha256
  sha256sum -c hm-hue.tar.gz.sha256
  gh attestation verify hm-hue.tar.gz -R amroeser/homematic-addon-hue
  ```

### Netzwerkverbindungen im Überblick

| Ziel | Protokoll | Wann |
|---|---|---|
| Hue Bridge | HTTPS (API v2, gepinnt) oder HTTP (API v1) | dauerhaft |
| `discovery.meethue.com`, `phoscon.de` | HTTPS | nur bei der Bridge-Suche |
| `github.com` | HTTPS | Update-Prüfung und Update |
| Shelly-Geräte im Heimnetz | HTTP | alle 10 s, wenn Shelly-Abgleich an und Shelly-Geräte vorhanden |
| `127.0.0.1` (CCU-Webserver, ReGaHss, CUxD) | HTTP, TclRega, XML-RPC | dauerhaft |

Das Addon sendet keine Telemetrie.

## Empfehlungen für den Betrieb

- Richte in der CCU eine Anmeldung mit Passwort ein und mache die WebUI nicht direkt aus dem Internet erreichbar. Für den Zugriff von unterwegs eignet sich ein VPN.
- Lass `https_verify` auf `fingerprint` und aktualisiere die Bridge-Firmware, damit API v2 genutzt wird.
- Behandle CCU-Backups als vertraulich, sie enthalten die App-Keys.
- Prüfe unter *Diagnose → Apps mit Zugriff* gelegentlich, welche Apps die Bridge steuern dürfen, besonders nach einem Mieter- oder Besitzerwechsel.
