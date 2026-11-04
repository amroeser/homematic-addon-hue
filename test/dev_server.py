#!/usr/bin/env python3
"""Serves the addon web UI like the CCU does (static files + CGI scripts), for local testing.

Needs the mock bridge and a running hued from test_addon.py's environment, or start everything with:
  python3 test/dev_server.py --with-mock     then open http://127.0.0.1:18888/index.html?sid=@test123456@
"""
import argparse
import os
import subprocess
import sys
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import test_addon as T  # noqa: E402

WWW = T.ADDON / "www"


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=str(WWW), **kw)

    def log_message(self, fmt, *args):
        pass

    def cgi(self):
        script, _, query = self.path.lstrip("/").partition("?")
        if script not in ("rest.cgi", "log.cgi", "debug.cgi", "update.cgi"):
            return False
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        env = T.env()
        env.update(QUERY_STRING=query, REQUEST_METHOD=self.command, CONTENT_LENGTH=str(len(body)))
        p = subprocess.run([T.TCLSH, str(WWW / script)], input=body, capture_output=True, env=env, timeout=60)
        head, _, payload = p.stdout.partition(b"\r\n\r\n")
        if not payload and b"\n\n" in p.stdout:
            head, _, payload = p.stdout.partition(b"\n\n")
        status = 200
        headers = []
        for line in head.decode(errors="replace").splitlines():
            k, _, v = line.partition(":")
            if k.lower() == "status":
                status = int(v.strip().split()[0])
            elif k:
                headers.append((k, v.strip()))
        self.send_response(status)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)
        if p.stderr:
            sys.stderr.write(p.stderr.decode(errors="replace"))
        return True

    def do_GET(self):
        if not self.cgi():
            super().do_GET()

    def do_POST(self):
        self.cgi()

    def do_PUT(self):
        self.cgi()

    def do_DELETE(self):
        self.cgi()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18888)
    ap.add_argument("--with-mock", action="store_true")
    ap.add_argument("--demo", action="store_true", help="realistic home (implies --with-mock)")
    a = ap.parse_args()
    if a.demo:
        os.environ["MOCK_DEMO"] = "1"
        a.with_mock = True
    if a.with_mock:
        T.AddonTest.setUpClass()
    if a.demo:
        conf = T.RUN / "hue.conf"
        conf.write_text(conf.read_text().replace("name=Mock", "name=Hue Bridge").replace("log_level=4", "log_level=2"))
        (T.RUN / "cuxd_devices.txt").write_text(
            f"CUX2801001 /usr/local/addons/hue/hue.tcl {T.BRIDGE} light 1\n"
            f"CUX2801002 /usr/local/addons/hue/hue.tcl {T.BRIDGE} group 1\n"
            f"CUX2802001 /usr/local/addons/hue/hue.tcl {T.BRIDGE} light 6\n")
        # More lamps: a Shelly and HomeMatic actuators of the CCU
        import uuid
        owner = lambda g: str(uuid.uuid5(uuid.NAMESPACE_DNS, f"group-owner-{g}"))
        (T.RUN / "ccu_channels.txt").write_text(
            "CUxD.CUX2801600:1|SWITCH|HM-LC-Sw1-FM|true|7|Wohnzimmer_Shelly_Deckenlampe:1|Wohnzimmer;\n"
            "HmIP-RF.0034DF29AEAC31:3|SWITCH_VIRTUAL_RECEIVER|HmIP-PSM-2|false|7|Wohnzimmer Leselampe:3|Wohnzimmer;\n"
            "HmIP-RF.00089D899E0F95:2|SWITCH_VIRTUAL_RECEIVER|HmIP-FSM|false|7|Küche Deckenlampe:2|Küche;\n"
            "HmIP-RF.00089D899E0C76:2|SWITCH_VIRTUAL_RECEIVER|HmIP-FSM|false|7|Küche Wandlampe:2|Küche;\n"
            "HmIP-RF.00089D8992C710:2|SWITCH_VIRTUAL_RECEIVER|HmIP-FSM|false|7|Garten Außenbeleuchtung:2|Garten;\n"
            "CUxD.CUX2801601:1|SWITCH|HM-LC-Sw1-FM|false|7|Schlafzimmer_Shelly_Bett:1|Schlafzimmer;\n")
        (T.RUN / "chan_states.txt").write_text("CUxD.CUX2801600:1 true\nHmIP-RF.00089D899E0F95:2 false\n")
        conf.write_text(conf.read_text() + "[extras]\n"
                        f"room_{T.BRIDGE}_{owner(1)}={{CUxD.CUX2801600:1 both}}\n"
                        f"room_{T.BRIDGE}_{owner(2)}={{HmIP-RF.00089D899E0F95:2 both}}\n")
        # Flow designer: a few programs of a typical home
        (T.RUN / "flows_dump.txt").write_text(
            "P|1001|true|true|2026-11-04 21:12:00|Wohnzimmer Taste 1: Entspannen\n"
            "R|1002|0|2\nC|1003|2\nS|1004|501|18|1|1|true|false|500|HmIP-RF.0001A:1.PRESS_SHORT|Wohnzimmer Taster:1\n"
            "C|1005|2\nS|1006|611|18|1|1|true|false|610|HmIP-RF.0002B:1.PRESS_SHORT|Wohnzimmer Taster Terrasse:1\n"
            "D|1007|9001|19|16|0||1|0|Hue Szene Wohnzimmer|\n"
            "P|1011|true|true|2026-11-04 22:40:00|Wohnzimmer Taste 2: Aus\n"
            "R|1012|0|1\nC|1013|2\nS|1014|503|18|1|1|true|false|502|HmIP-RF.0001A:2.PRESS_SHORT|Wohnzimmer Taster:2\n"
            "D|1015|9001|19|16|0||0|0|Hue Szene Wohnzimmer|\n"
            "D|1016|7490|18|2|0||false|7488|CUxD.CUX2801600:1.STATE|Wohnzimmer Shelly Deckenlampe:1\n"
            "P|1021|true|true|2026-11-05 07:02:00|Küche Taste 1: Licht\n"
            "R|1022|0|2\nC|1023|2\nS|1024|701|18|1|1|true|false|700|HmIP-RF.0003C:1.PRESS_SHORT|Küche Taster:1\n"
            "C|1025|2\nS|1026|709|18|1|1|true|false|700|HmIP-RF.0003C:1.PRESS_LONG|Küche Taster:1\n"
            "D|1027|2770|18|2|0||true|2768|HmIP-RF.00089D899E0F95:2.TOGGLE|Küche Deckenlampe:2\n"
            "P|1031|true|true|2026-11-05 06:30:00|Rollläden morgens hoch\n"
            "R|1032|0|1\nC|1033|2\nS|1034|803|18|1|1|true|false|802|HmIP-RF.0004D:2.PRESS_LONG_START|Flur Taster:2\n"
            "D|1035|7947|18|4|0||1.000000|7945|HmIP-RF.00115D89992437:4.LEVEL|Wohnzimmer Rollladen:4\n"
            "P|1041|true|true|2026-11-05 07:15:00|Flur Bewegung\n"
            "R|1042|0|1\nC|1043|2\nS|1044|901|18|1|4|true|false|900|HmIP-RF.0005E:1.PRESENCE_DETECTION_STATE|Flur Bewegungsmelder:1\n"
            "S|1045|905|18|10|15|45.000000|0.000000|900|HmIP-RF.0005E:1.ILLUMINATION|Flur Bewegungsmelder:1\n"
            "D|1046|9002|19|16|0||1|0|Hue Szene Flur|\n"
            "R|1047|1|0\nD|1048|9002|19|16|0||0|0|Hue Szene Flur|\n", encoding="utf-8")
        (T.RUN / "flows_catalog.txt").write_text(
            "CH|500|MULTI_MODE_INPUT_TRANSMITTER|PRESS_SHORT=501/5/2;PRESS_LONG_START=502/5/2;PRESS_LONG=509/5/2;|Wohnzimmer;|Wohnzimmer Taster:1|Wohnzimmer Taster\n"
            "CH|502|MULTI_MODE_INPUT_TRANSMITTER|PRESS_SHORT=503/5/2;PRESS_LONG_START=504/5/2;|Wohnzimmer;|Wohnzimmer Taster:2|Wohnzimmer Taster\n"
            "CH|610|MULTI_MODE_INPUT_TRANSMITTER|PRESS_SHORT=611/5/2;PRESS_LONG_START=612/5/2;|Wohnzimmer;|Wohnzimmer Taster Terrasse:1|Wohnzimmer Taster Terrasse\n"
            "CH|700|MULTI_MODE_INPUT_TRANSMITTER|PRESS_SHORT=701/5/2;PRESS_LONG_START=708/5/2;PRESS_LONG=709/5/2;|Küche;|Küche Taster:1|Küche Taster\n"
            "CH|802|MULTI_MODE_INPUT_TRANSMITTER|PRESS_SHORT=801/5/2;PRESS_LONG_START=803/5/2;|Flur;|Flur Taster:2|Flur Taster\n"
            "CH|7488|SWITCH|STATE=7490/7/2;TOGGLE=7491/2/2;|Wohnzimmer;|Wohnzimmer Shelly Deckenlampe:1|Wohnzimmer Shelly Deckenlampe\n"
            "CH|2768|SWITCH_VIRTUAL_RECEIVER|STATE=2769/7/2;TOGGLE=2770/2/2;|Küche;|Küche Deckenlampe:2|Küche Deckenlampe\n"
            "CH|7945|BLIND_VIRTUAL_RECEIVER|LEVEL=7947/7/4;|Wohnzimmer;|Wohnzimmer Rollladen:4|Wohnzimmer Rollladen\n"
            "SV|9001|16|Aus;Entspannen;Konzentrieren;Lesen|Hue Szene Wohnzimmer\n"
            "SV|9002|16|Aus;Nachtlicht;Hell|Hue Szene Flur\n", encoding="utf-8")
        T.AddonTest.stop_hued()
        T.AddonTest.start_hued()
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), Handler)
    print(f"http://127.0.0.1:{a.port}/index.html?sid=@test123456@", flush=True)
    try:
        srv.serve_forever()
    finally:
        if a.with_mock:
            T.AddonTest.tearDownClass()


if __name__ == "__main__":
    main()
