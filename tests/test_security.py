"""F1 security checks: masked passwords, history redaction, permissions,
per-IP release, HEAD, append atomicity."""
import os
import socket
import struct
import sys
import threading
import time

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


# --- interactive login is masked, and never echoes the password -------------
w = WS(port=PORT)
w.drain(0.5)

t, _ = w.cmd("register", 0.6)
check("register prompts for username", "Choose a username:" in strip_ansi(t), strip_ansi(t)[:120])

t, _ = w.cmd("alice", 0.6)
check("register prompts for password", "Password:" in strip_ansi(t), strip_ansi(t)[:120])

# Type the password one keystroke at a time and watch what is echoed back.
w.send("s")
echo, _ = w.drain(0.3)
check("password keystroke echoes a mask", "*" in echo and "s" not in echo.replace("*", ""),
      repr(echo))

w.send("ecret123")
w.drain(0.3)
w.send("\r")
t, _ = w.drain(0.6)
check("register asks for confirmation", "Confirm password:" in strip_ansi(t), strip_ansi(t)[:150])

t, _ = w.cmd("secret123", 1.5)
out = strip_ansi(t)
check("register completes", "welcome, alice" in out, out[:200])
check("password never echoed in clear", "secret123" not in out, out[:200])

t, _ = w.cmd("history", 0.6)
hist = strip_ansi(t)
check("interactive password absent from history", "secret123" not in hist, hist[:300])

t, _ = w.cmd("whoami", 0.6)
check("session is authenticated", "account: alice" in strip_ansi(t), strip_ansi(t)[:150])

# --- inline form is redacted in history -------------------------------------
w2 = WS(port=PORT)
w2.drain(0.5)
t, _ = w2.cmd("login alice secret123", 2.0)
out = strip_ansi(t)
check("inline login works", "logged in as alice" in out, out[:200])
check("inline login warns password was visible", "visible on screen" in out, out[:250])

t, _ = w2.cmd("history", 0.6)
hist = strip_ansi(t)
check("inline password redacted from history", "secret123" not in hist, hist[:300])
check("inline history keeps the username", "login alice" in hist, hist[:300])

# --- wrong password is rejected and indistinguishable ------------------------
w3 = WS(port=PORT)
w3.drain(0.5)
t, _ = w3.cmd("login alice wrongpassword", 2.0)
check("wrong password rejected", "incorrect username or password" in strip_ansi(t))
t, _ = w3.cmd("login ghostuser somepassword", 2.0)
check("unknown user gives the same message",
      "incorrect username or password" in strip_ansi(t))

# --- private directories are not an existence oracle -------------------------
w.cmd("mkdir /home/alice/secretdir", 0.6)
w.cmd("chmod private /home/alice/secretdir", 0.6)

t, _ = w3.cmd("cd /home/alice/secretdir", 0.6)
check("cd into a private dir is denied", "no such file or directory" in strip_ansi(t),
      strip_ansi(t)[:200])
t, _ = w3.cmd("pwd", 0.6)
check("cd did not move the guest", "/home/alice/secretdir" not in strip_ansi(t))

# --- announcements do not leak private paths ---------------------------------
w3.cmd("clear", 0.3)
w.cmd("mkdir /home/alice/quiet-place", 0.8)
seen, _ = w3.drain(0.8)
check("private mkdir is not broadcast", "quiet-place" not in strip_ansi(seen),
      strip_ansi(seen)[:200])

w3.cmd("clear", 0.3)
w.cmd("mkdir /tmp/loud-place", 0.8)
seen, _ = w3.drain(0.8)
check("shared mkdir is broadcast", "loud-place" in strip_ansi(seen), strip_ansi(seen)[:200])

# --- concurrent appends must not lose writes ---------------------------------
w.cmd("rm /tmp/log.txt", 0.4)
w.cmd("touch /tmp/log.txt", 0.4)

writers = [WS(port=PORT) for _ in range(4)]
for x in writers:
    x.drain(0.4)


def hammer(sess, tag):
    for i in range(5):
        sess.cmd(f"echo {tag}{i} >> /tmp/log.txt", 0.25)


threads = [threading.Thread(target=hammer, args=(x, chr(ord("A") + i)))
           for i, x in enumerate(writers)]
for th in threads:
    th.start()
for th in threads:
    th.join()
time.sleep(0.5)

t, _ = w.cmd("wc /tmp/log.txt", 0.8)
body = strip_ansi(t)
count = 0
for line in body.splitlines():
    parts = line.split()
    if len(parts) >= 4 and parts[3].endswith("log.txt"):
        count = int(parts[0])
check("concurrent appends all survive", count == 20, f"got {count} lines, expected 20")

for x in writers:
    x.close()

# --- per-IP connection slots are released ------------------------------------
# MAX_CONNS_PER_IP is 8. Open and close many more than that in sequence: if
# the release path is broken the address gets permanently locked out.
ok_all = True
for i in range(20):
    try:
        probe = WS(port=PORT)
        if probe.status != 101:
            ok_all = False
            break
        probe.close()
    except Exception as exc:  # noqa: BLE001
        ok_all = False
        print("   connection", i, "failed:", exc)
        break
check("connection slots are released on disconnect", ok_all)

# --- HEAD must not carry a body ----------------------------------------------
s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
s.sendall(b"HEAD / HTTP/1.1\r\nHost: x\r\n\r\n")
time.sleep(0.4)
resp = b""
s.settimeout(1.0)
try:
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        resp += chunk
except socket.timeout:
    pass
s.close()
head, _, body = resp.partition(b"\r\n\r\n")
check("HEAD returns 200", b"200 OK" in head, head[:80].decode(errors="replace"))
check("HEAD sends no body", len(body) == 0, f"{len(body)} bytes: {body[:60]!r}")

# --- a foreign Origin cannot open a socket -----------------------------------
try:
    evil = WS(port=PORT, origin="https://evil.example.com")
    check("cross-origin handshake refused", evil.status == 403, f"status {evil.status}")
    evil.close()
except Exception:
    check("cross-origin handshake refused", True)

# --- spoofed X-Real-IP from a non-loopback peer is ignored --------------------
# The test connects over loopback so the header IS trusted here; what matters is
# that a nonsense value is rejected rather than used as an identity.
try:
    spoof = WS(port=PORT, extra_headers="X-Real-IP: not-an-address\r\n")
    check("bogus X-Real-IP still connects (falls back to peer)", spoof.status == 101,
          f"status {spoof.status}")
    spoof.close()
except Exception as exc:  # noqa: BLE001
    check("bogus X-Real-IP still connects (falls back to peer)", False, str(exc))

for sess in (w, w2, w3):
    sess.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all F1 checks passed")
