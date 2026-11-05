# Sicherheit

## Unterstützte Versionen

Sicherheitskorrekturen erscheinen nur für die jeweils neueste Version. Updates werden auf der Addon-Seite mit *Jetzt aktualisieren* installiert.

| Version | Unterstützt |
|---|---|
| neueste 4.x | ja |
| ältere 4.x | nein |
| 3.x und älter | nein |

## Schwachstellen melden

Sicherheitslücken werden nicht über öffentliche Issues gemeldet, sondern:

1. über GitHub: [Schwachstelle privat melden](https://github.com/amroeser/homematic-addon-hue/security/advisories/new) (*Security → Report a vulnerability*), oder
2. per E-Mail an den Maintainer (Adresse in [`debian/control`](debian/control)), Betreff „Security: homematic-addon-hue“.

Eine Meldung enthält idealerweise:

- Version des Addons und Zentrale (CCU3, OpenCCU, RaspberryMatic, debmatic)
- Bridge-Modell und Schnittstelle (API v1 oder v2)
- Schritte zum Nachstellen, gegebenenfalls einen Proof of Concept
- eine Einschätzung der Auswirkung

App-Keys (`username`, `clientkey`) und Session-IDs sind vor dem Senden aus Protokollen und Debug-Daten zu entfernen.

**Ablauf:** Meldungen werden geprüft. Antwortzeiten und Korrekturen werden nicht zugesagt. Behobene Lücken erscheinen in einem Release, bei Bedarf mit einem GitHub Security Advisory, das auf Wunsch den Finder nennt. Ein Bug-Bounty gibt es nicht.

## Haftungsausschluss

Das Addon steht unter der [GPL-3.0](LICENSE) und wird ohne Gewährleistung bereitgestellt, soweit gesetzlich zulässig (Abschnitte 15 und 16 der Lizenz). Dieses Dokument beschreibt den aktuellen Stand. Es ist weder eine zugesicherte Eigenschaft noch eine Verpflichtung zur Behebung von Lücken. Der Einsatz erfolgt auf eigene Verantwortung.

## Geltungsbereich

Erfasst ist der Code in diesem Repository: Addon, Addon-Seite, CGI-Skripte, Installations- und Update-Skripte, Build und Release.

Nicht erfasst sind Lücken in CCU-Firmware, ReGaHss, CUxD, Hue Bridge und Hue-App; sie gehören zum jeweiligen Hersteller. Verschärft das Addon eine solche Lücke oder macht es sie erst ausnutzbar, fällt sie in den Geltungsbereich.

## Sicherheitsmodell

Das Addon läuft auf der Zentrale mit den Rechten des Webservers und der Addons, auf den meisten Systemen als `root`. Es vertraut dem lokalen System und dem Heimnetz im selben Maß wie die Zentrale. Die folgenden Abschnitte beschreiben Schutzmaßnahmen und Grenzen. Das Zusammenspiel der Komponenten beschreibt [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

### Authentifizierung der Addon-Seite

- Alle Endpunkte von `rest.cgi`, `log.cgi` und `debug.cgi` verlangen eine gültige CCU-Session. Geprüft wird bei jeder Anfrage über ReGaHss (`system.GetSessionVarStr`) und einen Abruf von `/pages/index.htm?sid=…` bei der CCU.
- Ausnahme ist `rest.cgi?path=login`: Benutzername und Passwort werden an die Anmeldung der CCU (`/login.htm`) weitergereicht und nicht gespeichert.
- Die Zugriffskontrolle ist die der CCU. Ohne Anmeldung in der CCU gibt es auch keine für das Addon.
- Die Session-ID steht wie in der CCU-WebUI in der URL (`?sid=@…@`) und kann in Browser-Verlauf und Server-Protokollen erscheinen.
- `update.cgi` ist ohne Session erreichbar. Es liefert nur die neueste Versionsnummer von GitHub oder leitet zum Download weiter, damit die Zusatzsoftware-Seite der CCU Updates anzeigen kann.

### Eingaben und Befehle

- Externe Programme werden mit Argumentlisten gestartet. Wo eine Shell nötig ist, wird jedes Argument mit `shq` maskiert.
- `test-command` (Diagnose) führt ausschließlich `hue.tcl` aus.
- Bridge-IDs, Objekt-IDs, Geräte- und Szenennamen sowie Werte werden vor der Verwendung in CUxD-Befehlen, ReGa-Skripten oder der Konfiguration gegen enge Muster geprüft. Abläufe erzeugen ReGa-Skripte nur aus geprüften Namen (`check_name`) und Werten (`check_value`).
- Vor jeder Änderung an einem CCU-Programm wird dessen Stand nach `/usr/local/etc/config/hue-flow-backups` gesichert.
- Angemeldete Nutzer können über die Diagnose beliebige Anfragen an die Bridge senden (`request`, `request_v2`) und CCU-Programme anlegen und ändern. Das entspricht den Rechten eines CCU-Administrators.

### Verbindung zur Hue Bridge

- **API v2** läuft über HTTPS. Da die Bridge ein selbst signiertes Zertifikat nutzt, wird standardmäßig der öffentliche Schlüssel gepinnt (`https_verify=fingerprint`): Beim ersten Kontakt wird sein SHA-256 als `tls_pubkey_sha256` gespeichert, danach lehnt `curl --pinnedpubkey` jeden anderen Schlüssel ab. Der erste Kontakt ist nicht geschützt (Trust on First Use).
- Nach Austausch oder Zurücksetzen der Bridge meldet das Addon „TLS public key … changed“. *Einstellungen → Schlüssel neu einlesen* übernimmt den neuen Schlüssel; das sollte nur bei bekannter Ursache geschehen.
- `https_verify=strict` prüft gegen die CA-Datei `etc/hue-ca.pem` mit der Bridge-ID als Hostname. `https_verify=none` schaltet die Prüfung ab und ist nur zur Fehlersuche vorgesehen.
- Kann `openssl` den Schlüssel nicht lesen, wird ohne Prüfung verbunden und eine Warnung protokolliert.
- **API v1** (Bridge v1, sehr alte Firmware) läuft unverschlüsselt über HTTP; der App-Key wird im Klartext übertragen. Abhilfe ist ein Firmware-Update der Bridge, danach wird API v2 genutzt.
- Bridge-Suche (`discovery.meethue.com`, `phoscon.de/discover`) und Verbindungsaufbau prüfen kein Zertifikat. Die Suche liefert nur Vorschläge für IP-Adressen; die Kopplung wird am Knopf der Bridge bestätigt.

### Gespeicherte Geheimnisse

- App-Keys (`username`, bei API v2 zusätzlich `clientkey`) stehen im Klartext in `/usr/local/addons/hue/etc/hue.conf` und in der Sicherung `/usr/local/etc/config/hue.conf.bak` und damit auch in CCU-Backups. Lesezugriff auf diese Dateien erlaubt die Steuerung der Lampen.
- Angemeldete Nutzer sehen den App-Key einer Bridge in deren Einstellungen. Unter *Apps mit Zugriff* werden nur die ersten sechs Zeichen angezeigt.
- Protokoll (`/tmp/hue-addon-log.txt`) und Debug-Daten können App-Keys enthalten und sind nur mit Session abrufbar. Vor dem Weitergeben sind die Keys zu entfernen.
- Ein kompromittierter Key wird in der Hue-App unter *Einstellungen → Apps mit Zugriff* oder über das Hue-Konto entfernt; anschließend wird die Bridge im Addon neu verbunden.

### Lokaler Dienst

- `hued` lauscht nur auf `127.0.0.1:1919` und nimmt Befehle ohne Authentifizierung an. Jeder lokale Prozess kann darüber Lampen schalten; Codeausführung auf der Zentrale bedeutet ohnehin vollen Zugriff.
- Die Sperren des Addons belegen lokale Ports ab 11200.
- Der Shelly-Abgleich liest Shelly-Relais im Heimnetz per HTTP ohne Anmeldung. Er schaltet nichts und ist in den *Einstellungen* abschaltbar.

### Updates und Lieferkette

- Das Ein-Klick-Update lädt `VERSION`, `hm-hue.tar.gz` und `hm-hue.tar.gz.sha256` per HTTPS aus dem neuesten GitHub-Release und bricht ab, wenn die SHA-256-Prüfsumme nicht passt.
- Paket und Prüfsumme stammen aus derselben Quelle. Die Prüfsumme schützt vor beschädigten oder unvollständigen Downloads, nicht vor einem kompromittierten GitHub-Konto oder Release.
- Releases werden in GitHub Actions aus einem Tag gebaut, der zur Datei `VERSION` passt, und erst nach bestandenen Tests veröffentlicht. Ein manuell angelegtes Release ist technisch nicht ausgeschlossen. Release-Tags sind per Ruleset gegen Verschieben und Löschen geschützt.
- Das Archiv hat festen Besitzer und sortierte Einträge, ist aber nicht bitgleich reproduzierbar.
- Jedes Release enthält eine Software-Stückliste im Format CycloneDX (`hm-hue.cdx.json`). Fremdkomponenten und Lizenzen stehen in [CREDITS.md](CREDITS.md). Die Addon-Seite lädt zur Laufzeit nichts aus dem Internet.
- Ab Version 4.1.3 trägt jedes Release eine signierte Build-Provenance (GitHub Artifact Attestation, Sigstore, SLSA Build Level 2). Sie belegt, dass `hm-hue.tar.gz` und `hm-hue.cdx.json` im Workflow dieses Repositorys aus einem bestimmten Commit gebaut wurden. Das Ein-Klick-Update prüft nur die Prüfsumme, nicht die Provenance.
- Im Workflow haben Jobs nur Leserechte; Schreib- und Signierrechte erhält allein der Release-Job. Fremde Actions sind per Commit-SHA gepinnt, Dependabot schlägt Updates vor.
- Prüfsumme und Herkunft lassen sich manuell prüfen (letzter Schritt mit der [GitHub CLI](https://cli.github.com)):

  ```sh
  curl -LO https://github.com/amroeser/homematic-addon-hue/releases/latest/download/hm-hue.tar.gz
  curl -LO https://github.com/amroeser/homematic-addon-hue/releases/latest/download/hm-hue.tar.gz.sha256
  sha256sum -c hm-hue.tar.gz.sha256
  gh attestation verify hm-hue.tar.gz -R amroeser/homematic-addon-hue
  ```

### Netzwerkverbindungen

| Ziel | Protokoll | Zeitpunkt |
|---|---|---|
| Hue Bridge | HTTPS (API v2, gepinnt) oder HTTP (API v1) | dauerhaft |
| `discovery.meethue.com`, `phoscon.de` | HTTPS | Bridge-Suche |
| `github.com` | HTTPS | Update-Prüfung und Update |
| Shelly-Geräte im Heimnetz | HTTP | alle 10 s, wenn Shelly-Abgleich aktiv und Shellys vorhanden |
| `127.0.0.1` (CCU-Webserver, ReGaHss, CUxD) | HTTP, TclRega, XML-RPC | dauerhaft |

Das Addon sendet keine Telemetrie.

## Empfehlungen für den Betrieb

- CCU-Anmeldung mit Passwort einrichten; WebUI nicht direkt aus dem Internet erreichbar machen, für Fernzugriff ein VPN nutzen.
- `https_verify=fingerprint` beibehalten und die Bridge-Firmware aktuell halten, damit API v2 genutzt wird.
- CCU-Backups vertraulich behandeln, sie enthalten die App-Keys.
- Unter *Diagnose → Apps mit Zugriff* regelmäßig prüfen, welche Apps die Bridge steuern dürfen, insbesondere nach Mieter- oder Besitzerwechsel.
