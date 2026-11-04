#!/usr/bin/env python3
"""Software bill of materials (CycloneDX 1.5, JSON) of the addon package.

    python3 tools/make_sbom.py [output]      default: dist/hm-hue.cdx.json

Lists what the package contains (own code and bundled third-party files, with
SHA-256 hashes) and what it needs on the CCU at runtime. Standard library only.
The timestamp is the date of the last commit, so the file is reproducible.
"""
import hashlib
import json
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ADDON = ROOT / "addon"
REPO = "https://github.com/amroeser/homematic-addon-hue"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def commit_time():
    try:
        out = subprocess.run(["git", "log", "-1", "--format=%cI"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
        return out or None
    except (OSError, subprocess.CalledProcessError):
        return None


def file_component(path, name, version, license_id, supplier, purl=None, copyright_=None, description=None):
    c = {
        "type": "library",
        "bom-ref": f"{name}@{version}",
        "name": name,
        "version": version,
        "supplier": {"name": supplier},
        "licenses": [{"license": {"id": license_id}}],
        "hashes": [{"alg": "SHA-256", "content": sha256(path)}],
        "properties": [{"name": "hm-hue:bundled", "value": "true"},
                       {"name": "hm-hue:path", "value": str(path.relative_to(ROOT))}],
    }
    if purl:
        c["purl"] = purl
    if copyright_:
        c["copyright"] = copyright_
    if description:
        c["description"] = description
    return c


def runtime(name, version, supplier, description, license_id=None, license_name=None, url=None):
    c = {
        "type": "application" if name not in ("Tcl",) else "framework",
        "bom-ref": f"runtime:{name}",
        "name": name,
        "version": version,
        "scope": "required",
        "supplier": {"name": supplier},
        "description": description,
        "properties": [{"name": "hm-hue:bundled", "value": "false"}],
    }
    if license_id:
        c["licenses"] = [{"license": {"id": license_id}}]
    elif license_name:
        c["licenses"] = [{"license": {"name": license_name}}]
    if url:
        c["externalReferences"] = [{"type": "website", "url": url}]
    return c


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist" / "hm-hue.cdx.json"
    version = (ROOT / "VERSION").read_text().strip()

    own_files = [{"type": "file", "bom-ref": "file:" + str(f.relative_to(ROOT)), "name": str(f.relative_to(ROOT)),
                  "hashes": [{"alg": "SHA-256", "content": sha256(f)}]}
                 for f in sorted(ADDON.rglob("*")) if f.is_file() and f.suffix in (".tcl", ".cgi", ".html") and f.name != "ini.tcl"]

    bundled = [
        file_component(ADDON / "lib" / "ini.tcl", "tcllib-inifile", "0.3", "TCL", "Tcllib",
                       purl="pkg:generic/tcllib/inifile@0.3",
                       copyright_="Copyright (c) 2003-2007 Aaron Faupell, (c) 2008-2012 Andreas Kupries",
                       description="Reading and writing of the addon settings (hue.conf)"),
        file_component(ADDON / "www" / "fonts" / "instrument-sans.woff2", "Instrument Sans", "1.000", "OFL-1.1",
                       "The Instrument Sans Project Authors", purl="pkg:github/Instrument/instrument-sans",
                       copyright_="Copyright 2022 The Instrument Sans Project Authors",
                       description="Typeface of the web interface"),
    ]
    needed = [
        runtime("Tcl", "8.2 or newer", "Tcl Core Team", "Interpreter of the CCU (CCU3: 8.2, OpenCCU: 8.6)", license_id="TCL", url="https://www.tcl-lang.org"),
        runtime("tclrega / tclrpc", "CCU firmware", "eQ-3 AG", "Tcl extensions of the CCU firmware for ReGa scripts and XML-RPC",
                license_name="eQ-3 license (part of the CCU firmware)", url="https://github.com/eq-3/occu"),
        runtime("CUxD", "2.x", "Uwe Langhammer", "Virtual devices that run the addon's commands from programs",
                license_name="CUxD license (freeware)", url="https://homematic-forum.de/forum/viewforum.php?f=37"),
        runtime("curl", "any", "Daniel Stenberg and contributors", "HTTPS to the Hue bridge, event stream, Shelly status",
                license_id="curl", url="https://curl.se"),
        runtime("OpenSSL", "any", "OpenSSL Software Foundation", "Reads the bridge key for TLS pinning",
                license_id="Apache-2.0", url="https://www.openssl.org"),
    ]

    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(uuid.NAMESPACE_URL, f"{REPO}/releases/v{version}")),
        "version": 1,
        "metadata": {
            "tools": {"components": [{"type": "application", "name": "make_sbom.py", "version": version}]},
            "authors": [{"name": "Jan Schneider", "email": "oss@janschneider.net"}, {"name": "Alexander Maximilian Röser"}],
            "component": {
                "type": "application",
                "bom-ref": f"hm-hue@{version}",
                "name": "hm-hue",
                "version": version,
                "description": "Philips Hue for HomeMatic (CCU3, OpenCCU, RaspberryMatic)",
                "licenses": [{"license": {"id": "GPL-3.0-or-later"}}],
                "author": "Jan Schneider (versions 1.0 to 3.2.5), Alexander Maximilian Röser (versions 3.3 and 4)",
                "purl": f"pkg:github/amroeser/homematic-addon-hue@v{version}",
                "externalReferences": [{"type": "vcs", "url": REPO}],
            },
        },
        "components": bundled + needed + own_files,
        "dependencies": [{"ref": f"hm-hue@{version}", "dependsOn": [c["bom-ref"] for c in bundled + needed]}],
    }
    ts = commit_time()
    if ts:
        bom["metadata"]["timestamp"] = ts
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(bom, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
