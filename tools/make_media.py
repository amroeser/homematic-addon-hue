#!/usr/bin/env python3
"""Screenshots and demo videos for the README.

Runs the real web UI against the simulated bridge in demo mode:
    python3 test/dev_server.py --demo &
    python3 tools/make_media.py            (needs: pip install playwright; ffmpeg)

Output: docs/media/*.png, *.mp4, *.gif
Parts that need a real CCU (bridge search, pairing, creating CUxD devices and
system variables) are answered with fixed demo data, so no real device appears.
"""
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "media"
URL = "http://127.0.0.1:18888/index.html?sid=@demo000000@"
DEMO_IP = "192.168.178.20"
BRIDGE = "001788fffe000000"

# Visible pointer for the videos (headless recordings have no cursor). A popover lives in
# the top layer like the dialogs; re-showing it keeps it above every open dialog.
CURSOR_JS = """
(() => {
  const c = document.createElement('div');
  c.setAttribute('popover', 'manual');
  c.style.cssText = 'position:fixed;inset:auto;left:-40px;top:-40px;margin:-11px 0 0 -11px;padding:0;width:22px;height:22px;border-radius:50%;' +
    'background:rgba(30,30,30,.25);border:2px solid rgba(255,255,255,.95);box-shadow:0 1px 6px rgba(0,0,0,.35);pointer-events:none;overflow:visible;' +
    'transition:transform 120ms ease-out;';
  const raise = () => { try { c.hidePopover(); } catch (e) {} try { c.showPopover(); } catch (e) {} };
  document.addEventListener('DOMContentLoaded', () => {
    document.body.appendChild(c);
    raise();
    new MutationObserver(raise).observe(document.body, { subtree: true, attributes: true, attributeFilter: ['open'] });
  });
  document.addEventListener('mousemove', e => { c.style.left = e.clientX + 'px'; c.style.top = e.clientY + 'px'; }, true);
  document.addEventListener('mousedown', () => { c.style.transform = 'scale(.72)'; }, true);
  document.addEventListener('mouseup', () => { c.style.transform = ''; }, true);
})();
"""


def initial_map():
    return [
        {"bridge_id": BRIDGE, "type": "light", "id": "1", "cuxd_device": "CUX2801001"},
        {"bridge_id": BRIDGE, "type": "group", "id": "1", "cuxd_device": "CUX2801002"},
        {"bridge_id": BRIDGE, "type": "light", "id": "6", "cuxd_device": "CUX2802001"},
    ]


def demo_routes(page, state):
    """Answer the CCU-only endpoints with demo data."""
    state.setdefault("map", initial_map())

    def handle(route):
        url = route.request.url
        m = re.search(r"path=([^&]+)", url)
        path = m.group(1).replace("%2F", "/") if m else ""
        if path == "discover-bridges":
            return route.fulfill(json=[{"ip": DEMO_IP, "port": 80}] if state.get("onboarding") else [])
        if path == "config" and state.get("onboarding") and not state.get("paired"):
            resp = route.fetch()
            data = resp.json()
            data["bridges"] = []
            return route.fulfill(response=resp, json=data)
        if path == "establish-link":
            state["tries"] = state.get("tries", 0) + 1
            page.wait_for_timeout(500)
            if state["tries"] < 4:
                return route.fulfill(status=500, json={"error": "link button not pressed"})
            return route.fulfill(json={"username": "demo", "clientkey": "", "name": "Hue Bridge", "bridgeid": BRIDGE, "port": 80})
        if path.startswith("config/bridge/") and route.request.method == "PUT":
            state["paired"] = True
            return route.fulfill(json="Bridge saved")
        if path == "get-cuxd-device-map":
            return route.fulfill(json=state["map"])
        if path == "create-cuxd-device":
            body = json.loads(route.request.post_data or "{}")
            dev = f"CUX2801{len(state['map']) + 1:03d}"
            state["map"].append({"bridge_id": BRIDGE, "type": body["obj_type"], "id": body["obj_id"], "cuxd_device": dev})
            page.wait_for_timeout(350)
            return route.fulfill(json={"device": dev, "created": True})
        if path == "create-sysvars":
            state["sysvars"] = True
            return route.fulfill(json={"created": 3})
        if path == "update/check":
            return route.fulfill(json={"installed": "4.1.1", "latest": "4.1.1", "available": False, "url": ""})
        if path.startswith("bridges/") and path.endswith("/objects") and state.get("sysvars"):
            resp = route.fetch()
            data = resp.json()
            for s in data.get("sensors", []):
                s["exists"] = True
            return route.fulfill(response=resp, json=data)
        return route.continue_()
    page.route(re.compile(r".*rest\.cgi.*"), handle)


def tidy(page):
    """Show a LAN address instead of the local test address."""
    page.evaluate(f"""() => {{
      const walk = n => {{ for (const c of n.childNodes) {{
        if (c.nodeType === 3) c.textContent = c.textContent.split('127.0.0.1').join('{DEMO_IP}');
        else walk(c); }} }};
      walk(document.body);
    }}""")


def new_page(browser, scheme="light", mobile=False, video=None, state=None):
    opts = dict(locale="de-DE", color_scheme=scheme, device_scale_factor=2)
    opts["viewport"] = {"width": 390, "height": 844} if mobile else {"width": 1280, "height": 800}
    if video:
        opts["record_video_dir"] = str(video)
        opts["record_video_size"] = opts["viewport"]
        opts["device_scale_factor"] = 1
    ctx = browser.new_context(**opts)
    if not (state or {}).get("guide"):
        # The quick guide opens on the first visit; most shots show the app itself
        ctx.add_init_script("try { localStorage.setItem('hue-guide-1', '1'); } catch (e) {}")
    if video:
        ctx.add_init_script(CURSOR_JS)
    page = ctx.new_page()
    demo_routes(page, state if state is not None else {})
    return ctx, page


def open_app(page, wait=".tile"):
    page.goto(URL)
    page.wait_for_selector(wait, timeout=20000)
    page.wait_for_timeout(700)


def glide(page, locator, steps=20):
    box = locator.bounding_box()
    page.mouse.move(box["x"] + box["width"] / 2, box["y"] + box["height"] / 2, steps=steps)
    page.wait_for_timeout(160)


def click(page, locator, pause=600):
    locator.scroll_into_view_if_needed()
    glide(page, locator)
    locator.click()
    page.wait_for_timeout(pause)


def drag_slider(page, slider, frm, to):
    slider.scroll_into_view_if_needed()
    box = slider.bounding_box()
    y = box["y"] + box["height"] / 2
    page.mouse.move(box["x"] + box["width"] * frm, y, steps=16)
    page.mouse.down()
    page.mouse.move(box["x"] + box["width"] * to, y, steps=45)
    page.mouse.up()
    page.wait_for_timeout(500)


def lamp(page, name):
    return page.locator(".tile-wrap", has_text=name).first


# ---------------------------------------------------------------------------- screenshots

def screenshots(browser):
    for scheme in ("light", "dark"):
        ctx, page = new_page(browser, scheme)
        open_app(page)
        page.screenshot(path=OUT / f"rooms-{scheme}.png")
        click(page, lamp(page, "Stehlampe").locator(".more"), 700)
        page.screenshot(path=OUT / f"control-{scheme}.png")
        page.locator("#sheet .sheet-body").evaluate("e => e.scrollTop = e.scrollHeight")
        page.wait_for_timeout(300)
        if scheme == "light":
            page.screenshot(path=OUT / "control-homematic.png")
        page.keyboard.press("Escape"); page.wait_for_timeout(500)
        if scheme == "light":
            # More lamps of a room: a Shelly on the ceiling, suggestions from the CCU
            click(page, page.locator(".tile-wrap", has_text="Shelly").locator(".more"), 900)
            page.locator("#extras-section .btn", has_text="Lampe hinzufügen").click()
            page.wait_for_selector("#extras-section .pick-list", timeout=20000)
            page.locator("#extras-section").evaluate("e => e.scrollIntoView({ block: 'start' })")
            page.wait_for_timeout(400)
            page.screenshot(path=OUT / "more-lamps.png")
            page.keyboard.press("Escape"); page.wait_for_timeout(500)
        if scheme == "light":
            page.click(".nav-item[data-page=flows]")
            page.wait_for_selector(".flow-node.prog", timeout=20000)
            page.wait_for_timeout(900)
            page.screenshot(path=OUT / "flows.png")
            # The editor: triggers, condition with yes/no, actions
            page.locator(".flow-node.prog", has_text="Flur Bewegung").first.click()
            page.wait_for_selector(".fe-canvas", timeout=20000)
            page.wait_for_timeout(700)
            page.screenshot(path=OUT / "flow-editor.png")
            page.locator("#sheet .sheet-head .icon-btn").first.click()
            page.wait_for_timeout(600)
        for nav in ("sensors", "settings", "diagnose"):
            page.click(f".nav-item[data-page={nav}]")
            page.wait_for_timeout(900)
            tidy(page)
            if scheme == "light" or nav == "settings":
                page.screenshot(path=OUT / (f"{nav}-{scheme}.png" if nav == "settings" else f"{nav}.png"))
        ctx.close()
    ctx, page = new_page(browser, "light", mobile=True)
    open_app(page)
    page.screenshot(path=OUT / "mobile-rooms.png")
    click(page, lamp(page, "Lightstrip").locator(".more"), 800)
    page.screenshot(path=OUT / "mobile-control.png")
    ctx.close()
    ctx, page = new_page(browser, "light", state={"onboarding": True})
    open_app(page, ".onboard .found button")
    page.screenshot(path=OUT / "onboarding.png")
    ctx.close()
    ctx, page = new_page(browser, "light", state={"guide": True})
    open_app(page, "#sheet[open] .tour")
    for i in range(1, 4):
        page.wait_for_timeout(500)
        page.screenshot(path=OUT / f"guide-{i}.png")
        page.locator("#sheet .sheet-foot .btn.primary").click()
    ctx.close()


# ---------------------------------------------------------------------------- videos

def video_onboarding(browser, tmp):
    state = {"onboarding": True, "map": []}
    ctx, page = new_page(browser, "light", video=tmp, state=state)
    open_app(page, ".onboard .found button")
    page.mouse.move(640, 300)
    page.wait_for_timeout(900)
    click(page, page.locator(".found button").first, 300)
    page.wait_for_selector("text=Verbunden mit Hue Bridge", timeout=30000)
    page.wait_for_timeout(1300)
    click(page, page.locator("button", has_text="Alle zu HomeMatic hinzufügen"), 300)
    page.wait_for_selector(".tile", timeout=20000)
    page.wait_for_timeout(5200)
    tidy(page)
    page.wait_for_timeout(1500)
    path = page.video.path()
    ctx.close()
    return path


def video_guide(browser, tmp):
    ctx, page = new_page(browser, "light", video=tmp, state={"guide": True})
    open_app(page, "#sheet[open] .tour")
    page.mouse.move(640, 400)
    page.wait_for_timeout(1800)
    for i in range(4):
        click(page, page.locator("#sheet .sheet-foot .btn.primary"), 2300 if i != 1 else 900)
        if i == 1:
            click(page, page.locator("#sheet .tour .switch"), 1800)
    click(page, page.locator("#sheet .sheet-foot .btn.primary"), 1000)
    path = page.video.path()
    ctx.close()
    return path


def video_control(browser, tmp):
    ctx, page = new_page(browser, "light", video=tmp)
    open_app(page)
    page.mouse.move(640, 420)
    page.wait_for_timeout(700)
    click(page, lamp(page, "Küche Spots").locator(".tile"), 1300)
    click(page, page.locator(".chip", has_text="Entspannen"), 1500)
    click(page, lamp(page, "Lightstrip").locator(".more"), 900)
    sheet = page.locator("#sheet")
    drag_slider(page, sheet.locator("input[type=range]").first, 0.47, 0.95)
    click(page, sheet.locator(".swatch[aria-label='#ff2d92']"), 900)
    click(page, sheet.locator(".swatch[aria-label='#00c7be']"), 900)
    click(page, sheet.locator(".chip", has_text="Kerze"), 1100)
    click(page, sheet.locator("button[aria-label=Schließen]"), 1200)
    path = page.video.path()
    ctx.close()
    return path


def video_mobile(browser, tmp):
    ctx, page = new_page(browser, "dark", mobile=True, video=tmp)
    open_app(page)
    page.wait_for_timeout(600)
    click(page, lamp(page, "Esstisch").locator(".tile"), 1200)
    click(page, lamp(page, "Esstisch").locator(".more"), 1000)
    drag_slider(page, page.locator("#sheet input[type=range]").first, 0.7, 0.25)
    click(page, page.locator("#sheet .swatch[aria-label='#ff9500']"), 900)
    click(page, page.locator("#sheet button[aria-label=Schließen]"), 900)
    click(page, page.locator(".nav-item[data-page=sensors]"), 1500)
    path = page.video.path()
    ctx.close()
    return path


def convert(src, name, width):
    mp4 = OUT / f"{name}.mp4"
    gif = OUT / f"{name}.gif"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf", f"scale={width}:-2",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "26", "-movflags", "+faststart", "-an", str(mp4)], check=True)
    palette = OUT / f"{name}-palette.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"fps=12,scale={width}:-1:flags=lanczos,palettegen=stats_mode=diff", str(palette)], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-i", str(palette), "-lavfi",
                    f"fps=12,scale={width}:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
                    str(gif)], check=True)
    palette.unlink()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Replace only generated files, keep hand-made ones like logo.svg
    for f in OUT.iterdir():
        if f.suffix in (".png", ".gif", ".mp4"):
            f.unlink()
    tmp = OUT / ".video-tmp"
    with sync_playwright() as p:
        # HUE_MEDIA_CHANNEL=chrome uses an installed Chrome instead of Playwright's Chromium
        browser = p.chromium.launch(channel=os.environ.get("HUE_MEDIA_CHANNEL") or None)
        screenshots(browser)
        videos = {"demo-onboarding": (video_onboarding(browser, tmp), 960),
                  "demo-guide": (video_guide(browser, tmp), 960),
                  "demo-control": (video_control(browser, tmp), 960),
                  "demo-mobile": (video_mobile(browser, tmp), 390)}
        browser.close()
    for name, (src, width) in videos.items():
        convert(src, name, width)
    shutil.rmtree(tmp, ignore_errors=True)
    for f in sorted(OUT.iterdir()):
        print(f"{f.name:28s} {f.stat().st_size // 1024:6d} KB")


if __name__ == "__main__":
    sys.exit(main())
