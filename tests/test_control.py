"""F4: the frontend is served correctly and the control channel works."""
import json
import os
import re
import subprocess
import sys
import urllib.request

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
BASE = f"http://127.0.0.1:{PORT}"
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=5) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


# --- every asset the page references is actually served ----------------------
status, ctype, html = get("/")
check("index.html is served", status == 200 and b"<title>" in html)
check("index.html is text/html", ctype.startswith("text/html"), ctype)

referenced = set(re.findall(rb'(?:href|src)="(/[^"]+)"', html))
print(f"      page references: {sorted(x.decode() for x in referenced)}")

for ref in sorted(referenced):
    path = ref.decode()
    try:
        st, ct, body = get(path)
        check(f"  {path} is served", st == 200 and len(body) > 0, f"status {st}")
    except Exception as exc:  # noqa: BLE001
        check(f"  {path} is served", False, str(exc))

# --- content types the browser actually needs --------------------------------
_, ct_js, _ = get("/app.js")
check("javascript has a js content type", "javascript" in ct_js, ct_js)
_, ct_css, _ = get("/style.css")
check("css has a css content type", "text/css" in ct_css, ct_css)
_, ct_man, _ = get("/manifest.webmanifest")
check("manifest has a manifest content type", "manifest" in ct_man, ct_man)
_, ct_svg, _ = get("/favicon.svg")
check("svg has an svg content type", "image/svg" in ct_svg, ct_svg)
_, ct_png, png = get("/icon-192.png")
check("png has an image content type", ct_png == "image/png", ct_png)
check("png is a real png", png[:8] == b"\x89PNG\r\n\x1a\n")

# --- no external origins, so the CSP cannot break the page -------------------
external = re.findall(rb'(?:href|src)="(https?://[^"]+)"', html)
check("page loads nothing from another origin", len(external) == 0,
      str([x.decode() for x in external]))

_, _, appjs = get("/app.js")
ext_js = re.findall(rb'https?://(?!schemas|www\.w3)[a-z0-9.-]+', appjs)
check("app.js contacts no external host", len(ext_js) == 0, str(ext_js[:3]))

# --- the manifest is valid json ----------------------------------------------
_, _, manifest = get("/manifest.webmanifest")
try:
    parsed = json.loads(manifest)
    check("manifest parses", True)
    check("manifest declares icons", len(parsed.get("icons", [])) >= 2)
    check("manifest has a maskable icon",
          any(i.get("purpose") == "maskable" for i in parsed["icons"]))
except Exception as exc:  # noqa: BLE001
    check("manifest parses", False, str(exc))

# --- the vendored terminal is the real one -----------------------------------
_, _, xterm = get("/vendor/xterm.js")
check("xterm.js is vendored whole", len(xterm) > 200000, f"{len(xterm)} bytes")

# --- javascript is syntactically valid ---------------------------------------
node = subprocess.run(["which", "node"], capture_output=True, text=True)
if node.returncode == 0:
    for f in ["/home/micu/webos/public/app.js", "/home/micu/webos/public/sw.js"]:
        r = subprocess.run(["node", "--check", f], capture_output=True, text=True)
        check(f"{os.path.basename(f)} parses", r.returncode == 0, r.stderr[:200])
else:
    print("SKIP  javascript syntax check (no node)")

# --- control channel ---------------------------------------------------------
w = WS(port=PORT)
_, controls = w.drain(0.8)
check("a stat control frame arrives on connect",
      any('"t":"stat"' in c for c in controls), str(controls))

_, controls = w.cmd("theme amber", 0.7)
check("theme sends a control frame", any('"t":"theme"' in c for c in controls), str(controls))
check("theme names the requested theme", any('"amber"' in c for c in controls), str(controls))

_, controls = w.cmd("theme nonsense", 0.7)
check("an unknown theme sends no control frame",
      not any('"t":"theme"' in c for c in controls), str(controls))

_, controls = w.cmd("bell", 0.7)
check("bell sends a control frame", any('"t":"bell"' in c for c in controls), str(controls))

_, controls = w.cmd("matrix", 0.9)
check("matrix sends a control frame", any('"t":"matrix"' in c for c in controls), str(controls))

# The whole point of the binary channel: user text cannot forge a control
# message, however closely it resembles one.
w.cmd("clear", 0.3)
t, controls = w.cmd('echo {"t":"matrix","ms":6000}', 0.8)
check("user text cannot forge a control frame",
      not any('"t":"matrix"' in c for c in controls), str(controls))
check("the forged text is printed as ordinary output",
      '{"t":"matrix"' in strip_ansi(t), strip_ansi(t)[:160])

# A second session should see the user count rise.
w2 = WS(port=PORT)
w2.drain(0.5)
_, controls = w.drain(0.8)
check("connecting elsewhere updates the user count",
      any('"users":2' in c for c in controls), str(controls))

w2.close()
w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all F4 checks passed")
