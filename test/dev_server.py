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
