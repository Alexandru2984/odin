"""Static assets and front-end syntax.

Cheap guards for the two ways a front-end change breaks in production without
breaking anything a socket test would notice: a file that is referenced but not
served, and a script that does not parse. Both leave a blank page.
"""
import os
import re
import shutil
import subprocess
import sys
import urllib.request

PORT = int(os.environ.get("PORT", "47999"))
BASE = f"http://127.0.0.1:{PORT}"
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


def fetch(path):
    try:
        with urllib.request.urlopen(BASE + path, timeout=5) as r:
            return r.status, r.headers.get("Content-Type", ""), r.read()
    except urllib.error.HTTPError as e:
        return e.code, "", b""
    except Exception as e:
        return 0, str(e), b""


# --- everything index.html asks for must actually be served ------------------
index_path = os.path.join(ROOT, "public", "index.html")
with open(index_path, encoding="utf-8") as f:
    index = f.read()

status, ctype, body = fetch("/")
check("index is served", status == 200, str(status))
check("index is html", "text/html" in ctype, ctype)

# Every local src/href in the page, resolved against the running server. A
# reference the server cannot answer is the failure this suite exists for.
refs = set(re.findall(r'(?:src|href)="(/[^"]+)"', index))
check("the page references some assets", len(refs) >= 3, str(refs))

for ref in sorted(refs):
    status, ctype, body = fetch(ref)
    check(f"{ref} is served", status == 200, str(status))
    check(f"{ref} is not empty", len(body) > 0, str(len(body)))

# The scripts the desktop needs, named explicitly: a rename that also updated
# index.html would otherwise pass the loop above while breaking the feature.
for required in ["/app.js", "/desktop.js", "/style.css", "/vendor/xterm.js"]:
    check(f"{required} is referenced by the page", required in index, "missing from index.html")

# --- the service worker has to know about them too ---------------------------
with open(os.path.join(ROOT, "public", "sw.js"), encoding="utf-8") as f:
    sw = f.read()

for cached in ["/app.js", "/desktop.js", "/style.css"]:
    check(f"{cached} is in the service worker shell", f"'{cached}'" in sw,
          "an uncached script comes back stale after a deploy")

# --- syntax ------------------------------------------------------------------
node = shutil.which("node")
if node:
    for name in ["app.js", "desktop.js", "sw.js"]:
        path = os.path.join(ROOT, "public", name)
        r = subprocess.run([node, "--check", path], capture_output=True, text=True)
        check(f"{name} parses", r.returncode == 0, (r.stderr or "").strip()[:200])
else:
    print("SKIP  syntax checks (no node on this host)")

# --- content type ------------------------------------------------------------
status, ctype, _ = fetch("/app.js")
check("scripts are served as javascript", "javascript" in ctype, ctype)
status, ctype, _ = fetch("/style.css")
check("stylesheets are served as css", "text/css" in ctype, ctype)

# A path that does not exist must not fall through to something that does.
status, _, _ = fetch("/definitely-not-here.js")
check("a missing asset is a 404", status == 404, str(status))

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all asset checks passed")
