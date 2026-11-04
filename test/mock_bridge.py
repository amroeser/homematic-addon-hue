#!/usr/bin/env python3
"""Simulated Philips Hue bridge for the addon tests.

Serves the v1 API over HTTP and CLIP v2 (incl. event stream) over HTTPS with a
self signed certificate. State is shared, so a v1 or v2 write shows up in both
APIs and is pushed to event stream clients.

Test control endpoints (HTTP port):
  GET  /_log            requests received since the last call (JSON), clears the log
  POST /_set            {"light": "1", "on": true, "bri": 100}  change state like the Hue app would
  POST /_connectivity   {"light": "1", "status": "disconnected"}
  POST /_v2             {"enabled": false}  switch CLIP v2 on/off (round bridge simulation)
  POST /_area_motion    {"motion": true}  MotionAware area "Wohnzimmer" (Bridge Pro) detects motion
"""
import argparse
import json
import queue
import ssl
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

USER = "testuser-0123456789"


def rid(name):
    return str(uuid.uuid5(uuid.NAMESPACE_DNS, name))


class Model:
    def __init__(self):
        self.lock = threading.RLock()
        self.v2_enabled = True
        self.shelly_on = False
        # Bridge system: cloud, account, updates
        self.sw_state = {"1": "ready_to_install"}
        self.swupdate2 = {"checkforupdate": False, "lastchange": "2026-11-01T03:12:00", "state": "anyreadytoinstall",
                          "bridge": {"state": "noupdates", "lastinstall": "2026-10-20T02:10:00"},
                          "autoinstall": {"updatetime": "T14:00:00", "on": False}}
        self.log = []
        self.subscribers = []
        self.lights = {
            "1": dict(name="Stehlampe", on=False, bri=254, ct=366, xy=[0.4573, 0.41], colormode="ct",
                      kind="color", gamut="C", reachable=True),
            "2": dict(name="Decke", on=True, bri=127, ct=250, xy=None, colormode="ct",
                      kind="ct", gamut=None, reachable=True),
            "3": dict(name="Küchenflur", on=False, bri=50, ct=None, xy=None, colormode=None,
                      kind="dim", gamut=None, reachable=True),
        }
        # v1 group id -> (type, name, lights)
        self.groups = {
            "1": ("room", "Wohnzimmer", ["1", "2"]),
            "2": ("zone", "Flurzone", ["3"]),
        }
        self.group_on = {"0": False, "1": True, "2": False}
        self.scenes = {"AbCdEfGhIjKlMnO": ("Abend", "1", {"1": dict(on=True, bri=100, ct=400), "2": dict(on=True, bri=60, ct=450)}),
                       "GutenMorgen0001": ("Guten Morgen", "1", {"1": dict(on=True, bri=254, ct=250)})}
        self.motion = False
        self.area_motion = False
        self.demo = False
        self.active_scene = {}   # group id -> scene id
        self.recalling = False

    def load_demo(self):
        """A realistic home for screenshots and demo videos."""
        self.demo = True
        L = lambda name, on, bri, kind, ct=366, xy=None, gamut=None, mode="ct": dict(
            name=name, on=on, bri=bri, ct=ct if kind != "dim" else None, xy=xy, colormode=mode if kind != "dim" else None,
            kind=kind, gamut=gamut, reachable=True)
        self.lights = {
            "1": L("Stehlampe", True, 200, "color", 370, [0.4573, 0.41], "C"),
            "2": L("Deckenlampe", True, 160, "ct", 300),
            "3": L("Lightstrip TV", True, 120, "color", 250, [0.17, 0.1], "C", "xy"),
            "4": L("Küche Spots", False, 254, "ct", 250),
            "5": L("Esstisch", False, 180, "color", 400, [0.5, 0.41], "C"),
            "6": L("Nachttisch links", False, 60, "color", 450, [0.5, 0.41], "C"),
            "7": L("Nachttisch rechts", False, 60, "color", 450, [0.5, 0.41], "C"),
            "8": L("Flur", False, 100, "dim"),
        }
        self.lights["3"]["gradient"] = True
        self.groups = {
            "1": ("room", "Wohnzimmer", ["1", "2", "3"]),
            "2": ("room", "Küche", ["4", "5"]),
            "3": ("room", "Schlafzimmer", ["6", "7"]),
            "4": ("zone", "Erdgeschoss", ["1", "2", "3", "4", "5", "8"]),
        }
        self.scenes = {
            "Entspannen00001": ("Entspannen", "1", {"1": dict(on=True, bri=120, ct=447), "2": dict(on=True, bri=90, ct=447)}),
            "Konzentrier0001": ("Konzentrieren", "1", {"1": dict(on=True, bri=254, ct=233), "2": dict(on=True, bri=254, ct=233)}),
            "Nachtlicht00001": ("Nachtlicht", "3", {"6": dict(on=True, bri=10, ct=500), "7": dict(on=False)}),
            "Kochen000000001": ("Kochen", "2", {"4": dict(on=True, bri=254, ct=250), "5": dict(on=True, bri=200, ct=300)}),
        }

    # --- ids -------------------------------------------------------------
    def light_rid(self, n): return rid(f"light-{n}")
    def device_rid(self, n): return rid(f"device-{n}")
    def zc_rid(self, n): return rid(f"zc-{n}")
    def group_owner_rid(self, g): return rid(f"group-owner-{g}")
    def gl_rid(self, g): return rid(f"grouped-light-{g}")
    def scene_rid(self, s): return rid(f"scene-{s}")

    def group_lights(self, g):
        if g == "0":
            return list(self.lights)
        return self.groups[g][2]

    # --- v1 views -------------------------------------------------------
    def v1_light(self, n):
        l = self.lights[n]
        st = {"on": l["on"], "reachable": l["reachable"], "alert": "none"}
        typ = "Dimmable light"
        if l["kind"] != "dim":
            st["bri"] = l["bri"]
        else:
            st["bri"] = l["bri"]
        if l["kind"] in ("ct", "color"):
            st["ct"] = l["ct"]
            st["colormode"] = l["colormode"]
            typ = "Color temperature light"
        if l["kind"] == "color":
            st["xy"] = l["xy"]
            st["hue"] = 8000
            st["sat"] = 140
            st["effect"] = "none"
            typ = "Extended color light"
        out = {"state": st, "type": typ, "name": l["name"], "modelid": "LCT015"}
        if l["gamut"]:
            out["capabilities"] = {"control": {"colorgamuttype": l["gamut"]}}
            out["colorgamuttype"] = l["gamut"]
        return out

    def v1_group(self, g):
        lights = self.group_lights(g)
        on = [self.lights[n]["on"] for n in lights]
        name = "Group 0" if g == "0" else self.groups[g][1]
        return {"name": name, "lights": lights, "type": "Room" if g != "2" else "Zone",
                "state": {"all_on": all(on), "any_on": any(on)},
                "action": {"on": any(on), "bri": 200, "ct": 300, "colormode": "ct"}}

    # --- v2 views -------------------------------------------------------
    def v2_resources(self):
        out = []
        for n, l in self.lights.items():
            light = {
                "id": self.light_rid(n), "id_v1": f"/lights/{n}", "type": "light",
                "owner": {"rid": self.device_rid(n), "rtype": "device"},
                "metadata": {"name": l["name"], "archetype": "classic_bulb"},
                "on": {"on": l["on"]},
                "dimming": {"brightness": round(l["bri"] * 100 / 254, 2), "min_dim_level": 0.2},
                "dynamics": {"status": "none", "speed": 0.0},
                "alert": {"action_values": ["breathe"]},
                "mode": "normal",
            }
            if l["kind"] in ("ct", "color"):
                light["color_temperature"] = {"mirek": l["ct"], "mirek_valid": l["colormode"] == "ct",
                                              "mirek_schema": {"mirek_minimum": 153, "mirek_maximum": 454}}
            if l["kind"] == "color":
                light["color"] = {"xy": {"x": l["xy"][0], "y": l["xy"][1]}, "gamut_type": l["gamut"],
                                  "gamut": {"red": {"x": 0.6915, "y": 0.3083}, "green": {"x": 0.17, "y": 0.7}, "blue": {"x": 0.1532, "y": 0.0475}}}
                if l.get("gradient") or (not self.demo and n == "1"):
                    light["gradient"] = {"points": [], "points_capable": 5, "mode": "interpolated_palette", "mode_values": ["interpolated_palette", "random_pixelated"]}
                light["effects"] = {"effect": "no_effect", "status_values": ["no_effect", "candle", "fire"], "status": "no_effect", "effect_values": ["no_effect", "candle", "fire"]}
            out.append(light)
            out.append({"id": self.device_rid(n), "id_v1": f"/lights/{n}", "type": "device",
                        "metadata": {"name": l["name"], "archetype": "classic_bulb"},
                        "product_data": {"model_id": "LCT015", "product_name": "Hue color lamp", "software_version": "1.122.2"},
                        "services": [{"rid": self.light_rid(n), "rtype": "light"},
                                     {"rid": self.zc_rid(n), "rtype": "zigbee_connectivity"}]})
            out.append({"id": rid(f"swu-{n}"), "type": "device_software_update", "owner": {"rid": self.device_rid(n), "rtype": "device"},
                        "state": self.sw_state.get(n, "no_update"), "problems": []})
            out.append({"id": self.zc_rid(n), "id_v1": f"/lights/{n}", "type": "zigbee_connectivity",
                        "owner": {"rid": self.device_rid(n), "rtype": "device"},
                        "status": "connected" if l["reachable"] else "disconnected"})
        for g, (typ, name, lights) in self.groups.items():
            children = ([{"rid": self.device_rid(n), "rtype": "device"} for n in lights] if typ == "room"
                        else [{"rid": self.light_rid(n), "rtype": "light"} for n in lights])
            out.append({"id": self.group_owner_rid(g), "id_v1": f"/groups/{g}", "type": typ,
                        "metadata": {"name": name, "archetype": "living_room"},
                        "children": children, "services": [{"rid": self.gl_rid(g), "rtype": "grouped_light"}]})
        out.append({"id": self.group_owner_rid("0"), "id_v1": "/groups/0", "type": "bridge_home",
                    "children": [{"rid": self.group_owner_rid("1"), "rtype": "room"}],
                    "services": [{"rid": self.gl_rid("0"), "rtype": "grouped_light"}]})
        for g in ["0", *self.groups]:
            owner_type = "bridge_home" if g == "0" else self.groups[g][0]
            lights = self.group_lights(g)
            on_lights = [self.lights[n] for n in lights if self.lights[n]["on"]]
            bri = sum(l["bri"] for l in on_lights) / len(on_lights) * 100 / 254 if on_lights else 0
            out.append({"id": self.gl_rid(g), "id_v1": f"/groups/{g}", "type": "grouped_light",
                        "owner": {"rid": self.group_owner_rid(g), "rtype": owner_type},
                        "on": {"on": bool(on_lights)}, "dimming": {"brightness": round(bri, 2)},
                        "alert": {"action_values": ["breathe"]}})
        for s, (name, g, _) in self.scenes.items():
            out.append({"id": self.scene_rid(s), "id_v1": f"/scenes/{s}", "type": "scene",
                        "metadata": {"name": name}, "group": {"rid": self.group_owner_rid(g), "rtype": "room"},
                        "status": {"active": "static" if self.active_scene.get(g) == s else "inactive"}})
        out.append({"id": rid("bridge"), "id_v1": "", "type": "bridge", "bridge_id": "001788fffe000000",
                    "owner": {"rid": rid("bridge-device"), "rtype": "device"}})
        if self.demo:
            out.append({"id": rid("sensor-dev"), "type": "device", "metadata": {"name": "Bewegungsmelder Flur", "archetype": "unknown_archetype"},
                        "services": [{"rid": rid("motion-1"), "rtype": "motion"}, {"rid": rid("temp-1"), "rtype": "temperature"},
                                     {"rid": rid("lux-1"), "rtype": "light_level"}]})
            out.append({"id": rid("lux-1"), "type": "light_level", "owner": {"rid": rid("sensor-dev"), "rtype": "device"},
                        "light": {"light_level": 18000, "light_level_valid": True, "light_level_report": {"light_level": 18000}}})
            out.append({"id": rid("switch-dev"), "type": "device", "metadata": {"name": "Dimmschalter Wohnzimmer", "archetype": "unknown_archetype"},
                        "services": [{"rid": rid("button-1"), "rtype": "button"}]})
            out.append({"id": rid("button-1"), "type": "button", "owner": {"rid": rid("switch-dev"), "rtype": "device"},
                        "metadata": {"control_id": 1}, "button": {"button_report": {"event": "short_release"}}})
        out.append({"id": rid("motion-1"), "type": "motion", "owner": {"rid": rid("sensor-dev"), "rtype": "device"},
                    "motion": {"motion": self.motion, "motion_valid": True,
                               "motion_report": {"changed": "2026-11-05T10:00:00.000Z", "motion": self.motion}}})
        # MotionAware (Bridge Pro): an area over room 1 with a convenience and a security service.
        # A second area has no "motion" field, as some bridge firmware sends it.
        area_motion = {"motion": self.area_motion, "motion_valid": True,
                       "motion_report": {"changed": "2026-11-05T10:00:00.000Z", "motion": self.area_motion}}
        out.append({"id": rid("area-cfg-1"), "type": "motion_area_configuration", "name": "Wohnzimmer",
                    "group": {"rid": self.group_owner_rid("1"), "rtype": "room"}, "enabled": True, "health": "healthy",
                    "participants": [{"resource": {"rid": rid("light-dev-1"), "rtype": "device"}, "status": {"health": "healthy"}}],
                    "services": [{"rid": rid("area-conv-1"), "rtype": "convenience_area_motion"},
                                 {"rid": rid("area-sec-1"), "rtype": "security_area_motion"}]})
        out.append({"id": rid("area-conv-1"), "type": "convenience_area_motion", "enabled": True,
                    "owner": {"rid": rid("area-cfg-1"), "rtype": "motion_area_configuration"},
                    "motion": area_motion, "sensitivity": {"sensitivity": 2, "sensitivity_max": 4}})
        out.append({"id": rid("area-sec-1"), "type": "security_area_motion", "enabled": True,
                    "owner": {"rid": rid("area-cfg-1"), "rtype": "motion_area_configuration"},
                    "motion": area_motion, "sensitivity": {"sensitivity": 2, "sensitivity_max": 4}})
        out.append({"id": rid("area-sec-2"), "type": "security_area_motion", "enabled": False,
                    "owner": {"rid": rid("area-cfg-gone"), "rtype": "motion_area_configuration"}})
        out.append({"id": rid("temp-1"), "type": "temperature", "owner": {"rid": rid("sensor-dev"), "rtype": "device"},
                    "temperature": {"temperature": 21.37, "temperature_valid": True,
                                    "temperature_report": {"changed": "2026-11-05T10:00:00.000Z", "temperature": 21.37}}})
        return out

    def find_light_by_rid(self, r):
        for n in self.lights:
            if self.light_rid(n) == r:
                return n
        return None

    def find_group_by_gl(self, r):
        for g in ["0", *self.groups]:
            if self.gl_rid(g) == r:
                return g
        return None

    def find_scene(self, r):
        for s in self.scenes:
            if self.scene_rid(s) == r:
                return s
        return None

    # --- changes --------------------------------------------------------
    def set_light(self, n, changes):
        l = self.lights[n]
        before = json.dumps(l, sort_keys=True)
        for k, v in changes.items():
            if k == "on":
                l["on"] = bool(v)
            elif k == "bri":
                l["bri"] = max(1, min(254, int(round(v))))
            elif k == "ct" and l["kind"] in ("ct", "color"):
                l["ct"] = int(v)
                l["colormode"] = "ct"
            elif k == "xy" and l["kind"] == "color":
                l["xy"] = [round(v[0], 4), round(v[1], 4)]
                l["colormode"] = "xy"
        if json.dumps(l, sort_keys=True) != before:
            self.emit_light(n)
            if not self.recalling:
                # A manual change ends the active scene of the rooms of this lamp
                for g, s in list(self.active_scene.items()):
                    if n in self.group_lights(g):
                        del self.active_scene[g]
                        self.emit([{"id": self.scene_rid(s), "type": "scene", "status": {"active": "inactive"}}])

    def emit_light(self, n):
        l = self.lights[n]
        data = {"id": self.light_rid(n), "id_v1": f"/lights/{n}", "type": "light",
                "owner": {"rid": self.device_rid(n), "rtype": "device"},
                "on": {"on": l["on"]}, "dimming": {"brightness": round(l["bri"] * 100 / 254, 2)}}
        if l["colormode"] == "ct" and l["ct"]:
            data["color_temperature"] = {"mirek": l["ct"], "mirek_valid": True}
        if l["colormode"] == "xy" and l["xy"]:
            data["color"] = {"xy": {"x": l["xy"][0], "y": l["xy"][1]}}
            data["color_temperature"] = {"mirek": None, "mirek_valid": False}
        self.emit([data])
        # grouped_light changes as well
        groups = [g for g in ["0", *self.groups] if n in self.group_lights(g)]
        gdata = []
        for g in groups:
            on = any(self.lights[x]["on"] for x in self.group_lights(g))
            gdata.append({"id": self.gl_rid(g), "id_v1": f"/groups/{g}", "type": "grouped_light", "on": {"on": on}})
        self.emit(gdata)

    def emit(self, data, etype="update"):
        if not data or not self.v2_enabled:
            return
        ev = [{"creationtime": time.strftime("%Y-%m-%dT%H:%M:%SZ"), "data": data, "id": str(uuid.uuid4()), "type": etype}]
        for q in list(self.subscribers):
            q.put(ev)


M = Model()


def v1_params_to_changes(p):
    ch = {}
    for k in ("on", "bri", "ct", "xy"):
        if k in p:
            ch[k] = p[k]
    if "bri_inc" in p:
        ch["bri_inc"] = p["bri_inc"]
    return ch


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    https = False

    def log_message(self, fmt, *args):
        pass

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        return raw.decode() if raw else ""

    def send_json(self, obj, code=200):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def record(self, method, body):
        with M.lock:
            M.log.append({"api": "v2" if self.https else "v1", "method": method, "path": self.path,
                          "body": json.loads(body) if body.strip().startswith(("{", "[")) else body})

    # ------------------------------------------------------------------
    def do_GET(self):
        self.route("GET", "")

    def do_PUT(self):
        self.route("PUT", self.body())

    def do_POST(self):
        self.route("POST", self.body())

    def route(self, method, body):
        p = self.path.split("?")[0].rstrip("/")
        if not self.https and p.startswith("/_"):
            return self.control(p, body)
        if p == "/api" and method == "POST":
            self.record(method, body)
            out = {"username": USER}
            if self.https:
                out["clientkey"] = "0123456789ABCDEF0123456789ABCDEF"
            return self.send_json([{"success": out}])
        if self.https:
            if p.startswith("/clip/v2") or p.startswith("/eventstream"):
                if not M.v2_enabled:
                    return self.send_json({"error": "not found"}, 404)
                if self.headers.get("hue-application-key") != USER:
                    return self.send_json({"errors": [{"description": "unauthorized user"}], "data": []}, 403)
                if p == "/eventstream/clip/v2":
                    return self.eventstream()
                return self.v2(method, p[len("/clip/v2/"):], body)
        if p.startswith(f"/api/{USER}"):
            return self.v1(method, p[len(f"/api/{USER}"):].strip("/"), body)
        if not self.https and p == "/relay/0":
            # A Shelly (Gen1 API) behind a CUxD switch
            q = self.path.partition("?")[2]
            if "turn=on" in q:
                M.shelly_on = True
            elif "turn=off" in q:
                M.shelly_on = False
            return self.send_json({"ison": M.shelly_on, "has_timer": False, "source": "http"})
        if p in ("/api/config", "/api/0/config"):
            return self.send_json({"name": "Mock", "bridgeid": "001788FFFE000000", "apiversion": "1.68.0", "modelid": "BSB002"})
        self.send_json([{"error": {"type": 1, "description": "unauthorized user"}}])

    # ------------------------------------------------------------------
    def control(self, p, body):
        req = json.loads(body) if body else {}
        with M.lock:
            if p == "/_log":
                out = M.log
                M.log = []
                return self.send_json(out)
            if p == "/_set":
                n = req.pop("light")
                M.set_light(n, req)
                return self.send_json({"ok": True})
            if p == "/_connectivity":
                n = req["light"]
                M.lights[n]["reachable"] = req["status"] == "connected"
                M.emit([{"id": M.zc_rid(n), "type": "zigbee_connectivity", "status": req["status"]}])
                return self.send_json({"ok": True})
            if p == "/_v2":
                M.v2_enabled = bool(req["enabled"])
                return self.send_json({"ok": True})
            if p == "/_motion":
                M.motion = bool(req["motion"])
                M.emit([{"id": rid("motion-1"), "type": "motion", "motion": {"motion": M.motion, "motion_report": {"motion": M.motion}}}])
                return self.send_json({"ok": True})
            if p == "/_area_motion":
                M.area_motion = bool(req["motion"])
                m = {"motion": M.area_motion, "motion_report": {"motion": M.area_motion}}
                M.emit([{"id": rid("area-conv-1"), "type": "convenience_area_motion", "motion": m},
                        {"id": rid("area-sec-1"), "type": "security_area_motion", "motion": m}])
                return self.send_json({"ok": True})
            if p == "/_scene_add":
                M.scenes[req["id"]] = (req["name"], req["group"], {})
                res = [r for r in M.v2_resources() if r["id"] == M.scene_rid(req["id"])]
                M.emit(res, "add")
                return self.send_json({"ok": True})
            if p == "/_scene_delete":
                del M.scenes[req["id"]]
                M.emit([{"id": M.scene_rid(req["id"]), "type": "scene"}], "delete")
                return self.send_json({"ok": True})
            if p == "/_recall":
                Handler.recall(self, req["scene"])
                return self.send_json({"ok": True})
            if p == "/_shelly":
                M.shelly_on = bool(req["on"])
                return self.send_json({"ok": True})
            if p == "/_state":
                return self.send_json({"lights": M.lights})
        self.send_json({"error": "unknown"}, 404)

    # ------------------------------------------------------------------
    def v1(self, method, path, body):
        parts = path.split("/") if path else []
        with M.lock:
            if method == "GET":
                if parts == ["lights"]:
                    return self.send_json({n: M.v1_light(n) for n in M.lights})
                if parts == ["groups"]:
                    return self.send_json({g: M.v1_group(g) for g in M.groups})
                if len(parts) == 2 and parts[0] == "lights":
                    return self.send_json(M.v1_light(parts[1]))
                if len(parts) == 2 and parts[0] == "groups":
                    return self.send_json(M.v1_group(parts[1]))
                if parts == ["scenes"]:
                    return self.send_json({s: {"name": v[0], "group": v[1], "type": "GroupScene", "lights": list(v[2])} for s, v in M.scenes.items()})
                if parts == ["config"]:
                    return self.send_json({"name": "Mock", "bridgeid": "001788FFFE000000", "apiversion": "1.68.0", "modelid": "BSB002", "swversion": "1968096020",
                                           "internetservices": {"internet": "connected", "remoteaccess": "connected", "time": "connected", "swupdate": "connected"},
                                           "portalstate": {"signedon": True, "incoming": False, "outgoing": True, "communication": "disconnected"},
                                           "portalconnection": "connected", "swupdate2": M.swupdate2,
                                           "whitelist": {USER: {"last use date": "2026-11-05T11:00:00", "create date": "2026-11-04T22:00:00", "name": "homematic-addon-hue#ccu"},
                                                         "oldtenantkey00000000": {"last use date": "2025-03-01T08:00:00", "create date": "2023-01-01T10:00:00", "name": "Hue#iPhone von Mieter"}}})
            if method == "PUT":
                self.record(method, body)
                p = json.loads(body)
                if parts == ["config"] and "swupdate2" in p:
                    u = p["swupdate2"]
                    if u.get("install"):
                        M.swupdate2["state"] = "installing"
                    if u.get("checkforupdate"):
                        M.swupdate2["checkforupdate"] = True
                    if "autoinstall" in u:
                        M.swupdate2["autoinstall"].update(u["autoinstall"])
                    return self.send_json([{"success": {f"/config/swupdate2/{k}": v}} for k, v in u.items()])
                if len(parts) == 3 and parts[0] == "lights":
                    self.apply_v1(parts[1], p)
                    return self.send_json([{"success": {f"/lights/{parts[1]}/state/{k}": v}} for k, v in p.items()])
                if len(parts) == 3 and parts[0] == "groups":
                    if "scene" in p:
                        self.recall(p["scene"])
                    for n in M.group_lights(parts[1]):
                        self.apply_v1(n, p)
                    return self.send_json([{"success": {f"/groups/{parts[1]}/action/{k}": v}} for k, v in p.items()])
        self.send_json([{"error": {"type": 3, "description": f"resource, /{path}, not available"}}])

    def apply_v1(self, n, p):
        ch = v1_params_to_changes(p)
        if "bri_inc" in ch:
            ch["bri"] = M.lights[n]["bri"] + ch.pop("bri_inc")
        M.set_light(n, ch)

    def recall(self, s):
        M.recalling = True
        try:
            for n, st in M.scenes[s][2].items():
                M.set_light(n, st)
        finally:
            M.recalling = False
        g = M.scenes[s][1]
        old = M.active_scene.get(g)
        M.active_scene[g] = s
        if old and old != s:
            M.emit([{"id": M.scene_rid(old), "type": "scene", "status": {"active": "inactive"}}])
        M.emit([{"id": M.scene_rid(s), "type": "scene", "status": {"active": "static"}}])

    # ------------------------------------------------------------------
    def v2(self, method, path, body):
        parts = path.split("/")
        with M.lock:
            res = M.v2_resources()
            if method == "GET":
                if parts == ["resource"]:
                    return self.send_json({"errors": [], "data": res})
                if len(parts) == 2:
                    return self.send_json({"errors": [], "data": [r for r in res if r["type"] == parts[1]]})
                if len(parts) == 3:
                    found = [r for r in res if r["type"] == parts[1] and r["id"] == parts[2]]
                    if found:
                        return self.send_json({"errors": [], "data": found})
                    return self.send_json({"errors": [{"description": "Not Found"}], "data": []}, 404)
            if method == "PUT" and len(parts) == 3:
                self.record(method, body)
                try:
                    p = json.loads(body)
                except ValueError:
                    return self.send_json({"errors": [{"description": "Bad body"}], "data": []}, 400)
                err = self.apply_v2(parts[1], parts[2], p)
                if err:
                    return self.send_json({"errors": [{"description": err}], "data": []}, 400)
                return self.send_json({"errors": [], "data": [{"rid": parts[2], "rtype": parts[1]}]})
        self.send_json({"errors": [{"description": "method not allowed"}], "data": []}, 405)

    def apply_v2(self, rtype, r, p):
        def changes(p, n=None):
            ch = {}
            if "on" in p:
                ch["on"] = p["on"]["on"]
            if "dimming" in p:
                b = p["dimming"]["brightness"]
                if not (0 < b <= 100):
                    raise ValueError("brightness out of range")
                ch["bri"] = b * 254 / 100
            if "dimming_delta" in p and n:
                d = p["dimming_delta"]["brightness_delta"] * 254 / 100
                ch["bri"] = M.lights[n]["bri"] + (d if p["dimming_delta"]["action"] == "up" else -d)
            if "color_temperature" in p:
                ch["ct"] = p["color_temperature"]["mirek"]
            if "color_temperature_delta" in p and n and M.lights[n]["ct"]:
                d = p["color_temperature_delta"]["mirek_delta"]
                ch["ct"] = M.lights[n]["ct"] + (d if p["color_temperature_delta"]["action"] == "up" else -d)
            if "color" in p:
                ch["xy"] = [p["color"]["xy"]["x"], p["color"]["xy"]["y"]]
            return ch
        allowed = {"light": {"on", "dimming", "dimming_delta", "color_temperature", "color_temperature_delta", "color", "dynamics", "alert", "effects", "effects_v2",
                             "identify", "gradient", "timed_effects", "signaling"},
                   "grouped_light": {"on", "dimming", "dimming_delta", "color_temperature", "color_temperature_delta", "color", "dynamics", "alert", "signaling"},
                   "scene": {"recall"}}
        if rtype not in allowed:
            return f"unknown type {rtype}"
        bad = set(p) - allowed[rtype]
        if bad:
            return f"unsupported properties {sorted(bad)}"
        try:
            if rtype == "light":
                n = M.find_light_by_rid(r)
                if n is None:
                    return "light not found"
                if "effects" in p and M.lights[n]["kind"] != "color":
                    return "effects not supported"
                M.set_light(n, changes(p, n))
            elif rtype == "grouped_light":
                g = M.find_group_by_gl(r)
                if g is None:
                    return "grouped_light not found"
                for n in M.group_lights(g):
                    M.set_light(n, changes(p, n))
            elif rtype == "scene":
                s = M.find_scene(r)
                if s is None:
                    return "scene not found"
                self.recall(s)
        except ValueError as e:
            return str(e)
        return None

    def eventstream(self):
        q = queue.Queue()
        M.subscribers.append(q)
        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(b": hi\n\n")
            self.wfile.flush()
            while True:
                try:
                    ev = q.get(timeout=1)
                except queue.Empty:
                    if not M.v2_enabled:
                        return
                    continue
                msg = f"id: {int(time.time())}:0\ndata: {json.dumps(ev)}\n\n".encode()
                self.wfile.write(msg)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            pass
        finally:
            M.subscribers.remove(q)
            self.close_connection = True


class HttpsHandler(Handler):
    https = True


def make_cert(d):
    d = Path(d)
    cert, key = d / "bridge.crt", d / "bridge.key"
    if not cert.exists():
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
                        "-nodes", "-keyout", str(key), "-out", str(cert), "-days", "30",
                        "-subj", "/CN=001788fffe000000"], check=True, capture_output=True)
    return cert, key


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--http-port", type=int, default=18080)
    ap.add_argument("--https-port", type=int, default=18443)
    ap.add_argument("--dir", default=".")
    ap.add_argument("--no-v2", action="store_true")
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--demo", action="store_true", help="realistic home for screenshots")
    a = ap.parse_args()
    M.v2_enabled = not a.no_v2
    if a.demo:
        M.load_demo()
    cert, key = make_cert(a.dir)
    h1 = ThreadingHTTPServer((a.bind, a.http_port), Handler)
    h2 = ThreadingHTTPServer((a.bind, a.https_port), HttpsHandler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    h2.socket = ctx.wrap_socket(h2.socket, server_side=True)
    h1.daemon_threads = h2.daemon_threads = True
    threading.Thread(target=h2.serve_forever, daemon=True).start()
    print(f"mock bridge http={a.http_port} https={a.https_port}", flush=True)
    try:
        h1.serve_forever()
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
