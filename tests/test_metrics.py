"""The /metrics endpoint and what it will and will not tell you."""
import os
import re
import socket
import sys

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


def http_get(path, headers=None, method="GET"):
    """A bare HTTP request, so the proxy headers can be controlled exactly."""
    s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    req = f"{method} {path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
    for k, v in (headers or {}).items():
        req += f"{k}: {v}\r\n"
    req += "\r\n"
    s.sendall(req.encode())
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    head, _, body = buf.partition(b"\r\n\r\n")
    status = int(head.split()[1])
    return status, head.decode(errors="replace"), body.decode(errors="replace")


def metric(body, name):
    m = re.search(rf"^webos_{name} (\d+)$", body, re.M)
    return int(m.group(1)) if m else None


# --- reachable directly ------------------------------------------------------
status, head, body = http_get("/metrics")
check("a direct scrape is served", status == 200, str(status))
check("the content type is the Prometheus one", "version=0.0.4" in head, head[:200])
check("it has HELP lines", "# HELP webos_" in body, body[:200])
check("it has TYPE lines", "# TYPE webos_" in body, body[:200])

# --- refused through a proxy -------------------------------------------------
# Every public request arrives from nginx carrying these. The endpoint has to
# refuse them even though the peer address is still loopback.
for header in ["X-Forwarded-For", "X-Real-IP", "CF-Connecting-IP"]:
    status, _, _ = http_get("/metrics", {header: "203.0.113.4"})
    check(f"a request carrying {header} is refused", status == 404, str(status))

# 404 rather than 403: a refusal that says "there is something here" is an
# invitation to keep trying.
status, _, body = http_get("/metrics", {"X-Forwarded-For": "203.0.113.4"})
check("the refusal does not admit the endpoint exists", "webos_" not in body, body[:150])

# --- the numbers are real ----------------------------------------------------
_, _, before = http_get("/metrics")
sessions_before = metric(before, "sessions")
commands_before = metric(before, "commands_total")

check("sessions is a gauge that starts sane", sessions_before is not None and sessions_before >= 0,
      str(sessions_before))
check("uptime is present", metric(before, "uptime_seconds") is not None)
check("the quota gauges are there", metric(before, "vfs_bytes_max") is not None)

w = WS(port=PORT)
w.drain(0.6)
for _ in range(3):
    w.cmd("echo counted", 0.4)

_, _, after = http_get("/metrics")
check("connecting moves the session gauge",
      metric(after, "sessions") == sessions_before + 1,
      f"{sessions_before} -> {metric(after, 'sessions')}")
check("running commands moves the command counter",
      metric(after, "commands_total") >= commands_before + 3,
      f"{commands_before} -> {metric(after, 'commands_total')}")
check("connections_total counts the new session",
      metric(after, "connections_total") >= 1, str(metric(after, "connections_total")))

# A failing command has to be distinguishable from a working one.
failed_before = metric(after, "commands_failed_total")
w.cmd("definitely-not-a-command", 0.5)
_, _, after2 = http_get("/metrics")
check("a failed command is counted separately",
      metric(after2, "commands_failed_total") > failed_before,
      f"{failed_before} -> {metric(after2, 'commands_failed_total')}")

# Background jobs and scripts have their own counters.
w.cmd("sleep 1 &", 0.6)
_, _, after3 = http_get("/metrics")
check("background jobs are counted", metric(after3, "jobs_started_total") >= 1,
      str(metric(after3, "jobs_started_total")))
check("running processes are visible", metric(after3, "processes_running") is not None)

# --- it says nothing about who ----------------------------------------------
w.cmd("register metricsuser metricspassword1", 2.0)
_, _, after4 = http_get("/metrics")
check("no usernames appear", "metricsuser" not in after4, after4[-300:])
check("no addresses appear", "127.0.0.1" not in after4, after4[-300:])
check("no paths appear", "/tmp" not in after4 and "/home" not in after4, after4[-300:])
check("accounts are counted, not named", metric(after4, "accounts") >= 1,
      str(metric(after4, "accounts")))

w.close()

# --- traffic -----------------------------------------------------------------
_, _, final = http_get("/metrics")
check("bytes sent is counted", metric(final, "bytes_sent_total") > 0,
      str(metric(final, "bytes_sent_total")))
check("bytes received is counted", metric(final, "bytes_received_total") > 0,
      str(metric(final, "bytes_received_total")))

# --- HEAD --------------------------------------------------------------------
status, head, body = http_get("/metrics", method="HEAD")
check("HEAD is answered", status == 200, str(status))
check("HEAD sends no body", len(body) == 0, body[:100])

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all metrics checks passed")
