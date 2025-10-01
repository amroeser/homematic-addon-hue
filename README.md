# HomeMatic addon to control Philips Hue Lighting

## Maintainer Notice (Fork)
- Updated for Hue API v2 and TLS policy by Alexander Maximilian Röser (01.10.2025)
- Adds API v2 write support, TLS fingerprint pinning, and optional v2 sensor polling while maintaining backward compatibility for CCU3/CUxD usage.

## What’s New in 3.3.0
- API v2 HTTPS support with header `hue-application-key` and CLIP v2 endpoints under `/clip/v2`.
- TLS policy (`https_verify`):
  - none: no verification (curl `--insecure`).
  - strict: verify using system CAs.
  - fingerprint: pin bridge public key (`--pinnedpubkey sha256//<pin>`), per-bridge key `tls_pubkey_sha256`.
- Config key `api_version` (auto|v1|v2):
  - auto: try v2 when mapping is available, otherwise fall back to v1.
  - v2: force v2 for writes.
  - v1: legacy behavior only.
- Backward compatible CLI/CCU commands remain unchanged; legacy IDs/params are mapped internally to v2 requests transparently (no CCU3 changes needed).
- Optional v2 sensor polling (motion/light_level/temperature) to HomeMatic system variables.

## Notes about the previous "DISCONTINUED" status
This fork introduces maintenance changes. The original repository status was "DISCONTINUED"; the fork adds updates required for API v2 and security hardening.

## Prerequisites
* This addon depends on CUxD

## Installation / configuration
* Download addon package (hm-hue.tar.gz) from releases or build locally, then install on CCU via system control.
* Install addon package on ccu via system control
* Open Philips Hue addon configuration in system control and add your Hue Bridges (http://ccu-ip/addons/hue/index.html)
* Set a poll interval if you want to frequently update the state of the CUxD devices with the state from your hue bridge.
* Click the bridge info button to see the list of lights, groups and scenes.
* Click on Create `CUxD-Dimmmer` or `Create CUxD-Switch` to create a new device.
* Go to the device inbox in HomeMatic Web-UI to complete the device configuration.

### Global configuration (new keys)
- `api_version` (default `auto`): `auto` | `v1` | `v2`
  - auto: versucht v2-Requests mit Mapping (Lights/Groups/Scenes), sonst Fallback v1.
  - v2: erzwingt v2-Schreibzugriffe, Fehler wenn Mapping nicht möglich.
  - v1: klassisches Verhalten.
- `https_verify` (default `fingerprint`): `none` | `strict` | `fingerprint`
  - none: keine TLS-Prüfung (nur Testbetrieb).
  - strict: System-CAs.
  - fingerprint: Public-Key-Pinning per Bridge über `tls_pubkey_sha256`.

### Per-Bridge option (hue.conf)
In `[bridge_<id>]` kann optional gesetzt werden:
- `tls_pubkey_sha256 = <Base64-SHA256-des-Public-Keys>` (für Policy `fingerprint`)

Hinweis: Mit Policy `fingerprint` fällt das Addon auf `--insecure` zurück, wenn noch kein Fingerprint hinterlegt ist, um die Kompatibilität nicht zu brechen. Hinterlege den Fingerprint zur Härtung.

### TLS Fingerprint ermitteln (Beispiel)
Bitte auf einem System mit OpenSSL:
```
openssl s_client -connect <bridge-ip>:443 </dev/null 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | openssl base64
```
Diesen Wert als `tls_pubkey_sha256` in `hue.conf` beim entsprechenden `bridge_<id>` eintragen.

### Multi-DIM-Device (28)
You can add the parameter `bri_mode:inc` to the command.
This will keep the brightness difference of the lights in the group when using the dimmer.

## API v2 mapping (Backward Compatibility)
- CLI und CCU/CUxD-Befehle bleiben unverändert (z.B. `light 1`, `group 1`, `scene:<id>`).
- Internes Mapping:
  - `lights/<id>/state` → `PUT /clip/v2/resource/light/{rid}`
  - `groups/<id>/action` → `PUT /clip/v2/resource/grouped_light/{rid}` (Gruppe `0` → `bridge_home` grouped_light)
  - `scene:<v1id>` → `PUT /clip/v2/resource/scene/{rid}` mit `{ "recall": { "action": "active" } }`
- Parameter-Übersetzung v1 → v2:
  - `on` → `on.on`
  - `bri` (0..254) → `dimming.brightness` (0..100%)
  - `ct` → `color_temperature.mirek`
  - `xy` → `color.xy.{x,y}`

## Sensoren (optional, v2)
Wenn `api_version` `v2`/`auto`, werden folgende v2-Ressourcen zyklisch gelesen und – falls vorhandene Systemvariablen existieren – aktualisiert:
- `resource/motion` → `Hue_motion_<bridge>_<rid>` (true/false)
- `resource/light_level` → `Hue_lux_<bridge>_<rid>` (Zahl)
- `resource/temperature` → `Hue_temp_<bridge>_<rid>` (Celsius)

Systemvariablen müssen vorhanden sein, sonst wird geloggt und übersprungen.

## hue.tcl usage
`/usr/local/addons/hue/hue.tcl <bridge-id> <command>`

### bridge-id
The bridge-id is displayed on the addon's system control

### Commands

command        | description
---------------| -----------------------------
`request`      | send a request to rest api
`light`        | control a light
`group`        | control a group

The `request` command can be use to send a raw api request.
[Philips Hue API documentation](https://developers.meethue.com/philips-hue-api).

You can add the parameter `sleep:<ms>` to delay light and group command for the given milliseconds.


### Examples
Turn on light 1 and set saturation, hue and brightness:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 on:true hue:1000 sat:200 bri:100`

Increase brightness of light 1 by 20, decrease saturation by 10:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 bri_inc:20 sat_inc:-10`

Turn light 1 off:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 on:false`

Set color temperature of light 1 to 500 with a transition time of 1 second (10 * 1/10s):  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 1 ct:500 transitiontime:10`

Start colorloop effect on light 2:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 2 effect:colorloop`

Stop effect on light 2:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 light 2 effect:none`

Flash group 1 once:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 group 1 alert:select`

Flash group 1 repeatedly:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 group 1 alert:lselect`

Set scene for light group 1:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 group 1 scene:AY-ots9YVHmAE1f`

Get configuration items:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET config`

Get info about connected lights:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET lights`

Get configured groups:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET groups`

Get configured scenes:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request GET scenes`

Turn off light 2:  
`/usr/local/addons/hue/hue.tcl 0234faae189721011 request PUT lights/2/state '{"on":false}'`

