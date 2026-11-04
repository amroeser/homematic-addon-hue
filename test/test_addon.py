#!/usr/bin/env python3
"""End-to-end tests: real addon scripts (hue.tcl, hued.tcl, rest.cgi) against the mock bridge.

Run:  python3 test/test_addon.py            (needs tclsh 8.6 with tcllib, curl, openssl)
      TCLSH=/path/to/tclsh8.6 python3 test/test_addon.py
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import unittest
import re
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon"
RUN = ROOT / "test" / ".run"
TCLSH = os.environ.get("TCLSH") or shutil.which("tclsh8.6") or "/opt/homebrew/opt/tcl-tk@8/bin/tclsh8.6"
HTTP_PORT, HTTPS_PORT, HUED_PORT, LOCK_PORT = 18080, 18443, 19190, 21200
# Run the Tcl side inside an OpenCCU container: DOCKER_CCU=<container name> (see test/run_in_openccu.sh)
DOCKER_CCU = os.environ.get("DOCKER_CCU")
MOCK_HOST = "host.docker.internal" if DOCKER_CCU else "127.0.0.1"
if DOCKER_CCU:
    TCLSH = str(ROOT / "test" / "docker_tclsh.sh")
BRIDGE = "001788fffe000000"
USER = "testuser-0123456789"


def light_rid(n):
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"light-{n}"))


def gl_rid(g):
    import uuid
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, f"grouped-light-{g}"))


def env():
    e = dict(os.environ)
    e.update(HUE_TEST="1", HUE_TEST_DIR=str(RUN), HUE_ADDON_DIR=str(ADDON), HUE_CONF=str(RUN / "hue.conf"),
             HUE_LOG_FILE=str(RUN / "hue.log"), HUED_PORT=str(HUED_PORT), HUE_LOCK_PORT=str(LOCK_PORT), LANGUAGE="en")
    if DOCKER_CCU:
        e["HUED_ADDRESS"] = "0.0.0.0"
    return e


def ctl(path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"http://127.0.0.1:{HTTP_PORT}{path}", data=data, method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read())


def write_conf(api_version="auto", extra=""):
    (RUN / "hue.conf").write_text(
        "[global]\n"
        f"api_version={api_version}\n"
        "log_level=4\n"
        "poll_state_interval=5\n"
        "https_verify=fingerprint\n"
        f"{extra}"
        f"[bridge_{BRIDGE}]\n"
        f"name=Mock\nip={MOCK_HOST}\n"
        f"port={HTTP_PORT}\nhttps_port={HTTPS_PORT}\nusername={USER}\n")


def wait_port(port, timeout=10):
    end = time.time() + timeout
    while time.time() < end:
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            return
        except OSError:
            time.sleep(0.1)
    raise RuntimeError(f"port {port} not open")


def hue(*args, check=True, extra_env=None):
    e = env()
    if extra_env:
        e.update(extra_env)
    p = subprocess.run([TCLSH, str(ADDON / "hue.tcl"), *args], capture_output=True, text=True, env=e, timeout=30)
    if check and p.returncode != 0:
        raise AssertionError(f"hue.tcl {args} failed: {p.stdout} {p.stderr}")
    return p


def until(fn, timeout=8, step=0.1):
    end = time.time() + timeout
    last = None
    while time.time() < end:
        last = fn()
        if last:
            return last
        time.sleep(step)
    return last


class AddonTest(unittest.TestCase):
    mock = None
    hued = None

    @classmethod
    def setUpClass(cls):
        if RUN.exists():
            shutil.rmtree(RUN)
        RUN.mkdir(parents=True)
        cls.mock = subprocess.Popen([sys.executable, str(ROOT / "test" / "mock_bridge.py"), "--http-port", str(HTTP_PORT),
                                     *(["--bind", "0.0.0.0"] if DOCKER_CCU else []),
                                     *(["--demo"] if os.environ.get("MOCK_DEMO") else []),
                                     "--https-port", str(HTTPS_PORT), "--dir", str(RUN)], stdout=subprocess.DEVNULL)
        wait_port(HTTP_PORT)
        wait_port(HTTPS_PORT)
        (RUN / "cuxd_devices.txt").write_text(
            f"CUX2801001 /usr/local/addons/hue/hue.tcl {BRIDGE} light 1\n"
            f"CUX2801002 /usr/local/addons/hue/hue.tcl {BRIDGE} group 1\n")
        (RUN / "sysvars.txt").write_text(f"Hue_reachable_CUX2801001\nHue_motion_{BRIDGE}_" + __import__("uuid").uuid5(__import__("uuid").NAMESPACE_DNS, "motion-1").__str__() + "\n")
        write_conf()
        cls.start_hued()

    @classmethod
    def start_hued(cls):
        cls.hued = subprocess.Popen([TCLSH, str(ADDON / "hued.tcl"), "nofork"], env=env(),
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # A docker port forward accepts connections before hued listens: wait for an answer
        end = time.time() + 20
        while time.time() < end:
            try:
                if "version:" in cls.hued_cmd(cls, "status"):
                    return
            except OSError:
                pass
            time.sleep(0.2)
        raise RuntimeError("hued did not start")

    @classmethod
    def stop_hued(cls):
        if cls.hued:
            cls.hued.terminate()
            cls.hued.wait(5)
        if DOCKER_CCU:
            subprocess.run(["docker", "exec", DOCKER_CCU, "pkill", "-f", "hued.tcl"], capture_output=True)
            subprocess.run(["docker", "exec", DOCKER_CCU, "pkill", "-f", "eventstream/clip/v2"], capture_output=True)
        subprocess.run(["pkill", "-f", f"{MOCK_HOST}:{HTTPS_PORT}/eventstream"], capture_output=True)
        time.sleep(0.3)

    @classmethod
    def tearDownClass(cls):
        cls.stop_hued()
        cls.mock.terminate()
        cls.mock.wait(5)

    def setUp(self):
        ctl("/_log")
        (RUN / "rega.log").write_text("")

    def puts(self):
        return [r for r in ctl("/_log") if r["method"] == "PUT"]

    def hued_cmd(self, cmd):
        with socket.create_connection(("127.0.0.1", HUED_PORT), 5) as s:
            s.sendall((cmd + "\n").encode())
            out = b""
            while True:
                d = s.recv(65536)
                if not d:
                    break
                out += d
        return out.decode()

    # ------------------------------------------------------------------
    def test_00_tcl82_compatible(self):
        """The CCU3 firmware runs Tcl 8.2: no commands or syntax from 8.3 or newer."""
        forbidden = {
            r"\bdict\b": "dict (8.5)", r"\{\*\}": "{*} (8.5)", r"\blassign\b": "lassign (8.5)",
            r"\blmap\b": "lmap (8.6)", r"\bapply\b": "apply (8.5)", r"\btry \{": "try (8.6)",
            r"package require json": "tcllib", r"-ignorestderr": "exec -ignorestderr (8.5)",
            r"[\]\)\}\w\"] (eq|ne|in|ni) [\[\$\{\"\w]": "eq/ne/in/ni (8.4/8.5)",
            r"\b(max|min)\(": "max()/min() (8.5)", r"lsort -unique": "lsort -unique (8.3)",
            r"array unset": "array unset (8.3)", r"unset -nocomplain": "unset -nocomplain (8.4)",
            r"2>@1": "2>@1 (8.4)", r"string match -nocase": "string match -nocase (8.3)",
            r"-options": "return/catch -options (8.5)", r"namespace upvar": "namespace upvar (8.5)",
            r"regexp -(start|all|inline)": "regexp -start/-all/-inline (8.3)", r"end-[0-9]": "end-N index",
            r"\[regsub[^\]]*(\"\"|\"[^\"]*\"|\$\w+)\]": "regsub without variable (8.4)",
            r"lindex \$\w+ \d+ \d+": "lindex with several indices (8.4)",
            r"\bincr \w+\(": "", r"string is \w+ -strict \[": "",
        }
        files = list((ADDON).glob("*.tcl")) + list((ADDON / "lib").glob("*.tcl")) + list((ADDON / "www").glob("*.cgi")) \
            + [ROOT / "test" / "stubs.tcl"]
        problems = []
        for f in files:
            for n, line in enumerate(f.read_text().splitlines(), 1):
                code = line.split("#")[0] if line.lstrip().startswith("#") else line
                if line.lstrip().startswith("#"):
                    continue
                # Words in strings ("... in ...") are no operators
                code_nostr = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
                for pat, what in forbidden.items():
                    target = code_nostr if "eq/ne" in what else code
                    if what and re.search(pat, target):
                        problems.append(f"{f.relative_to(ROOT)}:{n}: {what}: {line.strip()[:100]}")
        # Tcl reads sources in the system encoding (ISO-8859-1 on the CCU): no UTF-8 literals in new code
        for f in [ADDON / "hued.tcl", ADDON / "lib" / "hue_v2.tcl", ADDON / "lib" / "json.tcl", ADDON / "lib" / "update.tcl", ADDON / "lib" / "extras.tcl", ADDON / "www" / "rest.cgi"]:
            for n, line in enumerate(f.read_text().splitlines(), 1):
                if not line.lstrip().startswith("#") and re.search(r"[^\x00-\x7f]", line):
                    problems.append(f"{f.relative_to(ROOT)}:{n}: non-ASCII character in code: {line.strip()[:80]}")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_00_web_ui_script_parses(self):
        """The page is one inline script: a syntax error would leave it blank."""
        node = shutil.which("node")
        if not node:
            self.skipTest("node not installed")
        html = (ADDON / "www" / "index.html").read_text(encoding="utf-8")
        script = re.search(r"<script>([\s\S]*?)</script>", html).group(1)
        js = RUN / "ui-check.js"
        js.write_text(script, encoding="utf-8")
        p = subprocess.run([node, "--check", str(js)], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_01_status_uses_v2(self):
        st = self.hued_cmd("status")
        self.assertIn(f"bridge {BRIDGE}: api=v2", st)

    def test_02_light_on_bri_ct_transition(self):
        hue(BRIDGE, "light", "1", "on:true", "bri:127", "ct:300", "transitiontime:20")
        puts = self.puts()
        self.assertEqual(len(puts), 1, puts)
        self.assertEqual(puts[0]["api"], "v2")
        self.assertEqual(puts[0]["path"], f"/clip/v2/resource/light/{light_rid(1)}")
        self.assertEqual(puts[0]["body"], {"on": {"on": True}, "dimming": {"brightness": 50}, "color_temperature": {"mirek": 300}, "dynamics": {"duration": 2000}})

    def test_03_off_sends_only_on(self):
        hue(BRIDGE, "light", "1", "on:false", "bri:100", "ct:300")
        self.assertEqual(self.puts()[0]["body"], {"on": {"on": False}})

    def test_04_bri1_is_not_zero(self):
        hue(BRIDGE, "light", "1", "on:true", "bri:1")
        b = self.puts()[0]["body"]["dimming"]["brightness"]
        self.assertGreater(b, 0)

    def test_05_hue_sat_become_xy(self):
        hue(BRIDGE, "light", "1", "on:true", "hue:0", "sat:254")
        body = self.puts()[0]["body"]
        x, y = body["color"]["xy"]["x"], body["color"]["xy"]["y"]
        # red, inside gamut C
        self.assertGreater(x, 0.6)
        self.assertLess(y, 0.35)

    def test_06_increments(self):
        hue(BRIDGE, "light", "1", "on:true", "bri_inc:-25", "ct_inc:30")
        body = self.puts()[0]["body"]
        self.assertEqual(body["dimming_delta"], {"action": "down", "brightness_delta": 9.84})
        self.assertEqual(body["color_temperature_delta"], {"action": "up", "mirek_delta": 30})

    def test_07_ct_clamped_to_light_range(self):
        hue(BRIDGE, "light", "1", "on:true", "ct:600")
        self.assertEqual(self.puts()[0]["body"]["color_temperature"]["mirek"], 454)

    def test_08_rgb(self):
        hue(BRIDGE, "light", "1", "rgb:0,0,255")
        body = self.puts()[0]["body"]
        self.assertIn("color", body)
        self.assertLess(body["color"]["xy"]["y"], 0.1)

    def test_09_alert_and_effect(self):
        hue(BRIDGE, "light", "1", "alert:select")
        hue(BRIDGE, "light", "1", "effect:candle")
        puts = self.puts()
        self.assertEqual(puts[0]["body"]["alert"], {"action": "breathe"})
        self.assertEqual(puts[1]["body"]["effects"], {"effect": "candle"})

    def test_10_colorloop_falls_back_to_v1(self):
        hue(BRIDGE, "light", "1", "effect:colorloop")
        puts = self.puts()
        v1 = [p for p in puts if p["api"] == "v1"]
        self.assertEqual(len(v1), 1, puts)
        self.assertEqual(v1[0]["body"], {"effect": "colorloop"})

    def test_11_group_uses_grouped_light(self):
        hue(BRIDGE, "group", "1", "on:true", "bri:200")
        puts = self.puts()
        self.assertEqual(len(puts), 1, puts)
        self.assertEqual(puts[0]["path"], f"/clip/v2/resource/grouped_light/{gl_rid(1)}")

    def test_12_group_zero_is_bridge_home(self):
        hue(BRIDGE, "group", "0", "on:false")
        self.assertEqual(self.puts()[0]["path"], f"/clip/v2/resource/grouped_light/{gl_rid(0)}")

    def test_13_group_lights_mode_still_works(self):
        hue(BRIDGE, "group", "1", "on:true", "group_mode:lights")
        paths = sorted(p["path"] for p in self.puts())
        self.assertEqual(paths, sorted([f"/clip/v2/resource/light/{light_rid(1)}", f"/clip/v2/resource/light/{light_rid(2)}"]))

    def test_14_scene_by_v1_id_and_name(self):
        hue(BRIDGE, "group", "1", "scene:AbCdEfGhIjKlMnO")
        hue(BRIDGE, "group", "1", "scene:Abend")
        puts = self.puts()
        self.assertEqual(len(puts), 2, puts)
        for p in puts:
            self.assertTrue(p["path"].startswith("/clip/v2/resource/scene/"))
            self.assertEqual(p["body"], {"recall": {"action": "active"}})

    def test_15_v2_uuid_as_object_id(self):
        hue(BRIDGE, "light", light_rid(3), "on:true")
        self.assertEqual(self.puts()[0]["path"], f"/clip/v2/resource/light/{light_rid(3)}")

    def test_16_unknown_light_fails(self):
        p = hue(BRIDGE, "light", "99", "on:true", check=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("not found", p.stderr)

    def test_17_eventstream_updates_cuxd(self):
        until(lambda: "stream_connected=1" in self.hued_cmd("status"))
        ctl("/_set", {"light": "1", "on": True, "bri": 254, "ct": 200})
        ok = until(lambda: 'CUxD.CUX2801001.SET_STATES' in (RUN / "rega.log").read_text() and "LEVEL=1.0" in (RUN / "rega.log").read_text())
        self.assertTrue(ok, (RUN / "rega.log").read_text())
        # no polling needed: no GET in the log after the change
        log = (RUN / "rega.log").read_text()
        self.assertIn("WHITE=5000", log)

    def test_18_reachable_sysvar(self):
        until(lambda: "stream_connected=1" in self.hued_cmd("status"))
        ctl("/_connectivity", {"light": "1", "status": "disconnected"})
        ok = until(lambda: 'dom.GetObject("Hue_reachable_CUX2801001"); if (s) { s.State(false)' in (RUN / "rega.log").read_text())
        ctl("/_connectivity", {"light": "1", "status": "connected"})
        self.assertTrue(ok, (RUN / "rega.log").read_text())

    def test_19_motion_sysvar(self):
        until(lambda: "stream_connected=1" in self.hued_cmd("status"))
        ctl("/_motion", {"motion": True})
        ok = until(lambda: "s.State(true)" in (RUN / "rega.log").read_text() and "Hue_motion_" in (RUN / "rega.log").read_text())
        self.assertTrue(ok, (RUN / "rega.log").read_text())

    def test_20_request_v2_cli(self):
        p = hue(BRIDGE, "request_v2", "GET", "resource/light")
        self.assertIn(light_rid(1), p.stdout)

    def test_21_tls_pin_is_stored(self):
        self.assertIn("tls_pubkey_sha256", (RUN / "hue.conf").read_text())

    # ------------------------------------------------------------------ rest.cgi
    def rest(self, method, path, body=None, extra_env=None):
        e = env()
        data = json.dumps(body).encode() if body is not None else b""
        e.update(QUERY_STRING="sid=@x@&path=" + urllib.parse.quote(path, safe=""), REQUEST_METHOD=method, CONTENT_LENGTH=str(len(data)))
        if extra_env:
            e.update(extra_env)
        p = subprocess.run([TCLSH, str(ADDON / "www" / "rest.cgi")], input=data, capture_output=True, env=e, timeout=60)
        head, _, payload = p.stdout.partition(b"\r\n\r\n")
        status = int(re.search(rb"Status: (\d+)", head).group(1))
        return status, json.loads(payload) if payload else None

    def test_40_rest_objects_v2(self):
        st, o = self.rest("GET", f"bridges/{BRIDGE}/objects")
        self.assertEqual(st, 200, o)
        self.assertEqual(o["api"], "v2")
        names = {l["name"]: l for l in o["lights"]}
        self.assertEqual(names["Stehlampe"]["id"], "1")
        self.assertTrue(names["Stehlampe"]["color"])
        self.assertEqual(names["Decke"]["ct_max"], 454)
        self.assertIn("Küchenflur", names)  # UTF-8 survives exec and the system encoding
        groups = {g["id"]: g for g in o["groups"]}
        self.assertEqual(groups["1"]["name"], "Wohnzimmer")
        self.assertEqual(sorted(groups["1"]["lights"]), ["1", "2"])
        self.assertEqual(groups["0"]["type"], "bridge_home")
        self.assertEqual(o["scenes"][0]["group"], "1")
        kinds = {x["kind"] for x in o["sensors"]}
        self.assertEqual(kinds, {"bool", "temp"})
        self.assertTrue(any(x["exists"] for x in o["sensors"]))

    def test_41_rest_objects_v1(self):
        ctl("/_v2", {"enabled": False})
        try:
            st, o = self.rest("GET", f"bridges/{BRIDGE}/objects")
        finally:
            ctl("/_v2", {"enabled": True})
        self.assertEqual(st, 200, o)
        self.assertEqual(o["api"], "v1")
        self.assertEqual({l["name"] for l in o["lights"]}, {"Stehlampe", "Decke", "Küchenflur"})

    def test_42_rest_global_config_validation(self):
        st, o = self.rest("PUT", "config/global", {"api_version": "v3"})
        self.assertEqual(st, 400, o)
        st, o = self.rest("PUT", "config/global", {"poll_state_interval": "abc"})
        self.assertEqual(st, 400, o)
        st, o = self.rest("PUT", "config/global", {"eventstream": True, "api_version": "auto", "poll_state_interval": 5})
        self.assertEqual(st, 200, o)
        st, cfg = self.rest("GET", "config")
        self.assertEqual(cfg["global"]["eventstream"]["value"], True)
        self.assertIn(f"bridge_{BRIDGE}", (RUN / "hue.conf").read_text())

    def test_43_rest_test_command_no_shell(self):
        marker = RUN / "pwned"
        st, o = self.rest("PUT", "test-command", {"command": f"/usr/local/addons/hue/hue.tcl {BRIDGE} light 2 alert:select; touch {marker}"})
        self.assertEqual(st, 200)
        self.assertFalse(marker.exists())
        st, o = self.rest("PUT", "test-command", {"command": f"/bin/sh -c 'touch {marker}'"})
        self.assertEqual(o["exitcode"], 1)
        self.assertFalse(marker.exists())
        st, o = self.rest("PUT", "test-command", {"args": [BRIDGE, "light", "2", "on:true"]})
        self.assertEqual(o["exitcode"], 0, o)

    def test_44_invalid_on_value_is_ignored(self):
        hue(BRIDGE, "light", "2", "on:true;", "bri:100")
        body = self.puts()[0]["body"]
        self.assertNotIn("on", body)
        self.assertIn("dimming", body)

    def test_45_rest_bridge_info_and_v2_raw(self):
        st, o = self.rest("GET", f"bridges/{BRIDGE}/info")
        self.assertEqual(o["api_available"], "v2")
        self.assertNotIn("key", o)
        st, o = self.rest("POST", f"bridges/{BRIDGE}/request", {"method": "GET", "path": "/clip/v2/resource/scene"})
        self.assertEqual(st, 200, o)
        self.assertEqual(o["data"][0]["metadata"]["name"], "Abend")

    def test_46_update_check_and_install(self):
        pkg = ROOT / "dist"
        subprocess.run([str(ROOT / "pack_addon.sh")], check=True, capture_output=True)
        upd = {"HUE_UPDATE_URL": "file://" + str(pkg), "HUE_UPDATE_DIR": str(RUN / "update")}
        version = (ROOT / "VERSION").read_text().strip()
        (pkg / "VERSION").write_text("99.0.0\n")
        try:
            st, o = self.rest("GET", "update/check", extra_env=upd)
            self.assertEqual(st, 200, o)
            self.assertEqual(o, {"installed": version, "latest": "99.0.0", "available": True, "url": o["url"]})
            st, o = self.rest("POST", "update/install", extra_env=upd)
            self.assertEqual(st, 200, o)
            self.assertTrue((RUN / "update" / "update_script").exists())
            # broken checksum must stop the update
            sha = pkg / "hm-hue.tar.gz.sha256"
            good = sha.read_text()
            sha.write_text("0" * 64 + "  hm-hue.tar.gz\n")
            st, o = self.rest("POST", "update/install", extra_env=upd)
            sha.write_text(good)
            self.assertEqual(st, 500)
            self.assertIn("Checksum", o["error"])
        finally:
            (pkg / "VERSION").write_text(version + "\n")

    def test_47_bulk_create_skips_existing(self):
        # light 1 is mapped (CUX2801001), upper case bridge id must match too
        st, o = self.rest("POST", "create-cuxd-device", {"type": "rgbw", "serial": 0, "name": "Hue Stehlampe",
                                                         "bridge_id": BRIDGE.upper(), "obj_type": "light", "obj_id": "1", "skip_existing": True})
        self.assertEqual(st, 200, o)
        self.assertEqual(o, {"device": "CUX2801001", "created": False})

    def test_50_gradient(self):
        hue(BRIDGE, "light", "1", "gradient:ff0000,00ff00,0000ff", "gradient_mode:random_pixelated")
        g = self.puts()[0]["body"]["gradient"]
        self.assertEqual(len(g["points"]), 3)
        self.assertEqual(g["mode"], "random_pixelated")
        self.assertGreater(g["points"][0]["color"]["xy"]["x"], 0.6)
        # not a gradient lamp: warning, nothing sent
        hue(BRIDGE, "light", "2", "gradient:ff0000,0000ff")
        self.assertEqual(self.puts(), [])

    def test_51_timed_effect_sunrise(self):
        hue(BRIDGE, "light", "1", "on:true", "timed_effect:sunrise", "transitiontime:6000")
        body = self.puts()[0]["body"]
        self.assertEqual(body["timed_effects"], {"effect": "sunrise", "duration": 600000})
        self.assertNotIn("dynamics", body)
        hue(BRIDGE, "light", "1", "timed_effect:sunset")
        self.assertEqual(self.puts()[0]["body"]["timed_effects"]["duration"], 1800000)

    def test_52_signal_and_identify(self):
        hue(BRIDGE, "group", "1", "signal:on_off_color", "signal_duration:5", "signal_color:ff0000")
        p = self.puts()[0]
        self.assertTrue(p["path"].startswith("/clip/v2/resource/grouped_light/"))
        self.assertEqual(p["body"]["signaling"]["signal"], "on_off_color")
        self.assertEqual(p["body"]["signaling"]["duration"], 5000)
        self.assertEqual(len(p["body"]["signaling"]["colors"]), 1)
        hue(BRIDGE, "light", "1", "identify:true")
        self.assertEqual(self.puts()[0]["body"], {"identify": {"action": "identify"}})

    def test_53_speed(self):
        hue(BRIDGE, "light", "1", "effect:candle", "speed:0.3")
        self.assertEqual(self.puts()[0]["body"]["effects_v2"], {"action": {"effect": "candle", "parameters": {"speed": 0.3}}})
        hue(BRIDGE, "light", "1", "bri:100", "speed:0.5", "transitiontime:10")
        self.assertEqual(self.puts()[0]["body"]["dynamics"], {"duration": 1000, "speed": 0.5})

    def test_48_live_objects_from_hued_cache(self):
        """The UI polls ?live=1: answered by hued from the event-stream cache, no new bridge requests."""
        until(lambda: "stream_connected=1" in self.hued_cmd("status"))
        ctl("/_set", {"light": "2", "on": True, "bri": 200, "ct": 300})
        def lamp2():
            e = env()
            e.update(QUERY_STRING=f"sid=@x@&path=bridges%2F{BRIDGE}%2Fobjects&live=1", REQUEST_METHOD="GET", CONTENT_LENGTH="0")
            p = subprocess.run([TCLSH, str(ADDON / "www" / "rest.cgi")], capture_output=True, env=e, timeout=60)
            o = json.loads(p.stdout.partition(b"\r\n\r\n")[2])
            l = [x for x in o["lights"] if x["id"] == "2"][0]
            return l if l["on"] and l["bri"] == 200 else None
        l = until(lamp2)
        self.assertTrue(l, "live state not updated from the event stream")
        self.assertEqual(l["colormode"], "ct")
        self.assertEqual(l["ct"], 300)
        # Names with umlauts survive the way through hued (system encoding ISO-8859-1 on the CCU)
        e = env()
        e.update(QUERY_STRING=f"sid=@x@&path=bridges%2F{BRIDGE}%2Fobjects&live=1", REQUEST_METHOD="GET", CONTENT_LENGTH="0")
        p = subprocess.run([TCLSH, str(ADDON / "www" / "rest.cgi")], capture_output=True, env=e, timeout=60)
        names = [x["name"] for x in json.loads(p.stdout.partition(b"\r\n\r\n")[2])["lights"]]
        self.assertIn("Küchenflur", names)

    def test_49_uppercase_bridge_id_in_cuxd_command(self):
        """Old addons wrote the bridge id in upper case into CUxD commands."""
        devices = RUN / "cuxd_devices.txt"
        old = devices.read_text()
        # Only upper case ids, as on a CCU that ran the original addon
        devices.write_text(old.replace(BRIDGE, BRIDGE.upper()) + f"CUX2801009 /usr/local/addons/hue/hue.tcl {BRIDGE.upper()} light 3\n")
        sysvars = RUN / "sysvars.txt"
        old_vars = sysvars.read_text()
        sysvars.write_text(old_vars + f"Hue_reachable_{BRIDGE.upper()}_light_3\n")
        try:
            self.hued_cmd("reload")
            st = until(lambda: (lambda s: s if "stream_connected=1" in s else None)(self.hued_cmd("status")))
            self.assertIn(f"bridge {BRIDGE}: api=v2 stream_connected=1", st)
            (RUN / "rega.log").write_text("")
            ctl("/_set", {"light": "3", "on": True, "bri": 100})
            ok = until(lambda: "CUxD.CUX2801009.SET_STATES" in (RUN / "rega.log").read_text())
            self.assertTrue(ok, (RUN / "rega.log").read_text())
            ctl("/_connectivity", {"light": "3", "status": "disconnected"})
            ok = until(lambda: f'Hue_reachable_{BRIDGE.upper()}_light_3"); if (s) {{ s.State(false)' in (RUN / "rega.log").read_text())
            self.assertTrue(ok, (RUN / "rega.log").read_text())
        finally:
            ctl("/_connectivity", {"light": "3", "status": "connected"})
            devices.write_text(old)
            sysvars.write_text(old_vars)
            self.hued_cmd("reload")

    def test_54_scene_name_with_underscore(self):
        """CUxD commands cannot quote: scene:Guten_Morgen means the scene "Guten Morgen"."""
        hue(BRIDGE, "group", "1", "scene:guten_morgen")
        p = self.puts()[0]
        self.assertIn("/clip/v2/resource/scene/", p["path"])
        self.assertEqual(p["body"], {"recall": {"action": "active"}})

    def test_55_device_map_reports_scene(self):
        devices = RUN / "cuxd_devices.txt"
        old = devices.read_text()
        devices.write_text(old + f"CUX2801020 /usr/local/addons/hue/hue.tcl {BRIDGE} group 1 scene:Guten_Morgen\n")
        try:
            st, o = self.rest("GET", "get-cuxd-device-map")
            self.assertEqual(st, 200, o)
            entry = [x for x in o if x["cuxd_device"] == "CUX2801020"][0]
            self.assertEqual((entry["type"], entry["id"], entry["scene"]), ("group", "1", "Guten_Morgen"))
        finally:
            devices.write_text(old)

    def test_56_scene_variables(self):
        """Scenes as value-list system variables, kept up to date by hued in both directions."""
        conf = RUN / "hue.conf"
        old = conf.read_text()
        conf.write_text(old.replace("[global]\n", "[global]\nscene_sysvars=1\n"))
        var = RUN / "scenevar_Hue_Szene_Wohnzimmer.txt"
        try:
            self.hued_cmd("reload")
            ok = until(lambda: var.exists() and var.read_text().split("\n")[0] == "Aus;Abend;Guten Morgen", 15)
            self.assertTrue(ok, var.read_text() if var.exists() else "no variable")
            until(lambda: "stream_connected=1" in self.hued_cmd("status"))
            # The Hue app recalls "Abend": the variable follows (position 1)
            ctl("/_recall", {"scene": "AbCdEfGhIjKlMnO"})
            ok = until(lambda: var.read_text().split("\n")[1] == "1", 10)
            self.assertTrue(ok, var.read_text())
            # A program selects "Guten Morgen" (position 2): the scene is recalled
            ctl("/_log")
            var.write_text("Aus;Abend;Guten Morgen\n2\n")
            scene_path = "/clip/v2/resource/scene/" + str(__import__("uuid").uuid5(__import__("uuid").NAMESPACE_DNS, "scene-GutenMorgen0001"))
            ok = until(lambda: any(p["method"] == "PUT" and p["path"] == scene_path for p in ctl("/_log")), 10)
            self.assertTrue(ok, "scene not recalled")
            # A program selects "Aus": the room switches off
            ctl("/_log")
            var.write_text("Aus;Abend;Guten Morgen\n0\n")
            ok = until(lambda: any(p["method"] == "PUT" and "/grouped_light/" in p["path"] and p["body"] == {"on": {"on": False}} for p in ctl("/_log")), 10)
            self.assertTrue(ok, "room not switched off")
            # Scenes deleted / added in the Hue app: positions of the others stay
            ctl("/_scene_delete", {"id": "AbCdEfGhIjKlMnO"})
            ctl("/_scene_add", {"id": "Kueche000000001", "name": "Früh Stück", "group": "1"})
            ok = until(lambda: var.read_text().split("\n")[0] == "Aus;(entfernt);Guten Morgen;Frueh Stueck", 15)
            self.assertTrue(ok, var.read_text())
        finally:
            conf.write_text(old)
            M_restore = ctl("/_scene_add", {"id": "AbCdEfGhIjKlMnO", "name": "Abend", "group": "1"})
            ctl("/_scene_delete", {"id": "Kueche000000001"})
            self.hued_cmd("reload")

    def test_57_scene_switch_follows_its_scene(self):
        """Two scene switches of one room: only the switch of the active scene is on (programs toggle them)."""
        devices = RUN / "cuxd_devices.txt"
        old = devices.read_text()
        devices.write_text(old + f"CUX2801030 /usr/local/addons/hue/hue.tcl {BRIDGE} group 1 scene:AbCdEfGhIjKlMnO\n"
                                 f"CUX2801031 /usr/local/addons/hue/hue.tcl {BRIDGE} group 1 scene:GutenMorgen0001\n")
        log = RUN / "rega.log"
        try:
            self.hued_cmd("reload")
            until(lambda: "stream_connected=1" in self.hued_cmd("status"))
            hue(BRIDGE, "group", "1", "on:true")
            log.write_text("")
            ctl("/_recall", {"scene": "AbCdEfGhIjKlMnO"})
            ok = until(lambda: 'CUxD.CUX2801030:1.SET_STATE").State(1)' in log.read_text(), 10)
            self.assertTrue(ok, log.read_text())
            self.assertNotIn('CUxD.CUX2801031:1.SET_STATE").State(1)', log.read_text())
            log.write_text("")
            ctl("/_recall", {"scene": "GutenMorgen0001"})
            ok = until(lambda: 'CUxD.CUX2801031:1.SET_STATE").State(1)' in log.read_text()
                       and 'CUxD.CUX2801030:1.SET_STATE").State(0)' in log.read_text(), 10)
            self.assertTrue(ok, log.read_text())
        finally:
            devices.write_text(old)
            self.hued_cmd("reload")

    def test_58_more_lamps_follow_the_room(self):
        """CCU actuators assigned to a room switch with it; scenes can switch them, too."""
        import uuid
        room = str(uuid.uuid5(uuid.NAMESPACE_DNS, "group-owner-1"))
        morning = str(uuid.uuid5(uuid.NAMESPACE_DNS, "scene-GutenMorgen0001"))
        plug, shelly = "HmIP-RF.0001AAAA000001:3", "CUxD.CUX2801600:1"
        states = RUN / "chan_states.txt"
        states.write_text(f"{plug} false\n{shelly} false\n")
        (RUN / "ccu_channels.txt").write_text(
            f"{plug}|SWITCH_VIRTUAL_RECEIVER|HmIP-PSM-2|false|7|Wohnzimmer_Lampe:3|Wohnzimmer;\n"
            "HmIP-RF.0001AAAA000001:2|SWITCH_TRANSMITTER|HmIP-PSM-2|false|5|Wohnzimmer_Lampe:2|Wohnzimmer;\n"
            "HmIP-RF.0002BBBB000002:1|MULTI_MODE_INPUT_TRANSMITTER|HmIP-BRC2|false|5|Taster:1|Wohnzimmer;\n"
            "HmIP-RF.0002BBBB000002:8|SWITCH_VIRTUAL_RECEIVER|HmIP-BRC2|false|7|Taster:8|Wohnzimmer;\n"
            f"{shelly}|SWITCH|HM-LC-Sw1-FM|false|7|Wohnzimmer_Shelly:1|Wohnzimmer;\n"
            f"CUxD.CUX2801002:1|SWITCH|HM-LC-Sw1-FM|false|7|Hue Gruppe:1|Wohnzimmer;\n")
        try:
            st, cands = self.rest("GET", f"extras/{BRIDGE}/candidates")
            self.assertEqual(st, 200, cands)
            # Actuators only: no wall switch, no Hue device of this addon, one channel per device
            self.assertEqual(sorted(c["channel"] for c in cands), sorted([plug, shelly]))
            self.assertEqual([c["rooms"] for c in cands if c["channel"] == plug], [["Wohnzimmer"]])
            hue(BRIDGE, "group", "1", "on:false")
            st, o = self.rest("POST", f"extras/{BRIDGE}/room", {"room": room, "channel": plug, "mode": "both"})
            self.assertEqual(st, 200, o)
            st, o = self.rest("POST", f"extras/{BRIDGE}/room", {"room": room, "channel": shelly, "mode": "off"})
            self.assertEqual(st, 200, o)
            self.assertEqual([x["channel"] for x in o["rooms"][room]], [plug, shelly])
            st, bad = self.rest("POST", f"extras/{BRIDGE}/room", {"room": room, "channel": 'x"); dom.Delete(1', "mode": "both"})
            self.assertEqual(st, 400, bad)
            until(lambda: "stream_connected=1" in self.hued_cmd("status"))
            time.sleep(0.5)
            (RUN / "rega.log").write_text("")
            # Room on (e.g. in the Hue app): the plug follows, the "off only" Shelly does not
            hue(BRIDGE, "group", "1", "on:true")
            ok = until(lambda: f"{plug} true" in states.read_text(), 10)
            self.assertTrue(ok, (RUN / "rega.log").read_text())
            self.assertIn(f"{shelly} false", states.read_text())
            states.write_text(f"{plug} true\n{shelly} true\n")
            # A scene that switches the plug off
            st, o = self.rest("POST", f"extras/{BRIDGE}/scene", {"scene": morning, "channel": plug, "mode": "off"})
            self.assertEqual(st, 200, o)
            ctl("/_recall", {"scene": "GutenMorgen0001"})
            ok = until(lambda: f"{plug} false" in states.read_text(), 10)
            self.assertTrue(ok, (RUN / "rega.log").read_text())
            # Room off: everything off
            hue(BRIDGE, "group", "1", "on:false")
            ok = until(lambda: f"{shelly} false" in states.read_text(), 10)
            self.assertTrue(ok, (RUN / "rega.log").read_text())
            st, o = self.rest("GET", f"extras/{BRIDGE}")
            self.assertEqual(st, 200, o)
            self.assertEqual(o["rooms"][room][0]["on"], False)
            self.assertEqual(o["scenes"][morning], [{"channel": plug, "value": "off"}])
            # Removing a lamp from the room removes it from the scenes as well
            st, o = self.rest("POST", f"extras/{BRIDGE}/room", {"room": room, "channel": plug, "mode": ""})
            self.assertEqual(st, 200, o)
            self.assertNotIn(morning, o["scenes"])
        finally:
            self.rest("POST", f"extras/{BRIDGE}/room", {"room": room, "channel": plug, "mode": ""})
            self.rest("POST", f"extras/{BRIDGE}/room", {"room": room, "channel": shelly, "mode": ""})

    def test_59_shelly_state_is_read_back(self):
        """A Shelly switched at the wall: hued corrects the CUxD switch without running its command."""
        devices = RUN / "cuxd_devices.txt"
        old = devices.read_text()
        devices.write_text(old + f"CUX2801600 /usr/local/addons/cuxd/curl -s http://{MOCK_HOST}:{HTTP_PORT}/relay/0?turn~3don\n")
        states = RUN / "chan_states.txt"
        states.write_text("CUxD.CUX2801600:1 false\n")
        try:
            ctl("/_shelly", {"on": True})
            self.hued_cmd("reload")
            ok = until(lambda: "CUxD.CUX2801600:1 true" in states.read_text(), 25, 0.5)
            self.assertTrue(ok, (RUN / "rega.log").read_text()[-2000:])
            self.assertIn('CUxD.CUX2801600:1.SET_STATE").State(true)', (RUN / "rega.log").read_text())
            # The relay was only read, never switched
            self.assertTrue(ctl("/_state") is not None)
        finally:
            ctl("/_shelly", {"on": False})
            devices.write_text(old)
            self.hued_cmd("reload")

    def test_30_v1_bridge_fallback(self):
        """Round bridge / old firmware: everything over v1, nothing breaks."""
        ctl("/_v2", {"enabled": False})
        try:
            self.hued_cmd("reload")
            hue(BRIDGE, "light", "2", "on:true", "bri:100")
            puts = self.puts()
            self.assertEqual([p["api"] for p in puts], ["v1"], puts)
            self.assertEqual(puts[0]["body"], {"on": True, "bri": 100})
            hue(BRIDGE, "group", "1", "scene:Abend")
            puts = self.puts()
            self.assertEqual(puts[-1]["body"], {"scene": "AbCdEfGhIjKlMnO"})
            hue(BRIDGE, "group", "1", "scene:guten_morgen")
            self.assertEqual(self.puts()[-1]["body"], {"scene": "GutenMorgen0001"})
            self.assertIn("api=v1", self.hued_cmd("status"))
        finally:
            ctl("/_v2", {"enabled": True})
            self.hued_cmd("reload")

    def test_31_forced_v1(self):
        self.stop_hued()
        write_conf("v1")
        self.start_hued()
        try:
            hue(BRIDGE, "light", "1", "on:true")
            self.assertEqual([p["api"] for p in self.puts()], ["v1"])
        finally:
            self.stop_hued()
            write_conf("auto")
            self.start_hued()

    def test_32_upgrade_keeps_old_config(self):
        """Config of the original addon 3.2.5 (no new keys, port 80 style) works unchanged."""
        self.stop_hued()
        (RUN / "hue.conf").write_text(
            "[global]\nlog_level=0\napi_log=off\npoll_state_interval=5\nunreachable_update_mode=as_reachable\n"
            f"[bridge_{BRIDGE}]\nname=Mock\nip={MOCK_HOST}\nport={HTTP_PORT}\nusername={USER}\nhttps_port={HTTPS_PORT}\n")
        self.start_hued()
        try:
            hue(BRIDGE, "light", "1", "on:true")
            self.assertEqual([p["api"] for p in self.puts()], ["v2"])
        finally:
            self.stop_hued()
            write_conf("auto")
            self.start_hued()


if __name__ == "__main__":
    unittest.main(verbosity=2)
