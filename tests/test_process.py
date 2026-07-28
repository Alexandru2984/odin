"""Background jobs, the process table, kill and wait."""
import os
import re
import sys
import time

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


w = WS(port=PORT)
w.drain(0.6)


def run(cmd, wait=0.7):
    t, _ = w.cmd(cmd, wait)
    return strip_ansi(t)


def body(cmd, wait=0.7):
    lines = [l for l in run(cmd, wait).splitlines()[1:] if "webos:" not in l]
    while lines and lines[-1] == "":
        lines.pop()
    return lines


# --- the table ---------------------------------------------------------------
out = run("ps")
check("ps has a header", "PID" in out and "COMMAND" in out, out[:200])
check("ps shows the running command itself", "ps" in out, out[:300])

check("no jobs to begin with", "no background jobs" in run("jobs"), run("jobs")[:150])

# --- backgrounding -----------------------------------------------------------
def spawned_pid(out):
    """The pid from '[N] started'. The echoed command line also contains
    digits, so a bare scan for the first number finds the wrong thing."""
    m = re.search(r"\[(\d+)\]\s+started", out)
    return int(m.group(1)) if m else None


out = run("sleep 3 &")
check("& reports a pid", "started" in out, out[:200])
pid = spawned_pid(out)
check("the pid is a number", pid is not None, out[:200])

out = run("jobs")
check("jobs lists the running job", "running" in out and "sleep 3" in out, out[:300])

out = run("ps")
check("ps shows the background job too", "sleep 3" in out, out[:300])

# The session must stay usable while the job runs.
check("the shell is not blocked", "alive" in run("echo alive"))

# --- kill --------------------------------------------------------------------
out = run("sleep 60 &", 0.8)
pid2 = spawned_pid(out)
check("second job started", pid2 is not None, out[:200])

out = run(f"kill {pid2}", 0.8)
check("kill reports success", "killed" in out, out[:200])
time.sleep(0.6)
out = run("jobs")
check("a killed job is marked killed", "killed" in out, out[:300])

out = run("kill 99999")
check("killing an unknown pid is refused", "no such process" in out, out[:200])
out = run("kill notanumber")
check("a non-numeric pid is refused", "not a pid" in out, out[:200])

# --- isolation ---------------------------------------------------------------
# A job runs against a snapshot: it must not move the session it came from.
run("cd /tmp")
run("mkdir -p bgtest")
out = run("cd bgtest &")
check("session commands are refused in the background",
      "background" in out or "started" in out, out[:200])
time.sleep(0.5)
check("the session did not move", body("pwd") == ["/tmp"], str(body("pwd")))

# Work in the background is real work: it must actually reach the filesystem.
run("cd /tmp/bgtest")
run("echo one > src.txt")
run("cat src.txt > copy.txt &", 1.0)
time.sleep(1.2)
check("a background job writes to the VFS", body("cat copy.txt") == ["one"],
      str(body("cat copy.txt")))

# --- wait --------------------------------------------------------------------
out = run("wait")
check("wait with nothing pending says so", "nothing to wait for" in out, out[:200])

run("sleep 2 &", 0.8)
out = run("wait", 4.0)
check("wait blocks until the job finishes", "finished" in out, out[:200])
check("nothing is running after wait", "running" not in run("jobs"), run("jobs")[:250])

# --- limits ------------------------------------------------------------------
for _ in range(5):
    run("sleep 30 &", 0.4)
out = run("sleep 30 &", 0.6)
check("per-session job limit is enforced", "too many background jobs" in out, out[:200])

# Tidy up so the limit does not leak into anything after this.
for line in run("jobs", 0.8).splitlines():
    m = re.match(r"\s*\[(\d+)\]", line)
    if m:
        run(f"kill {m.group(1)}", 0.2)

check("the shell still works at the end", "done" in run("echo done"))

w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all process checks passed")
