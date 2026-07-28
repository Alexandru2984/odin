"""^C during a running command.

The reason this suite exists: until commands moved off the reader thread, a
long command owned the connection and a keystroke sat unread in the socket
until it finished. There was no way to interrupt anything.
"""
import os
import re
import sys
import time

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
CTRL_C = "\x03"
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


w = WS(port=PORT)
w.drain(0.6)


def run(cmd, wait=0.8):
    t, _ = w.cmd(cmd, wait)
    return strip_ansi(t)


def body(cmd, wait=0.8):
    lines = [l for l in run(cmd, wait).splitlines()[1:] if "webos:" not in l]
    while lines and lines[-1] == "":
        lines.pop()
    return lines


def interrupt_after(cmd, delay=0.6, settle=1.2):
    """Starts a command, presses ^C partway through, returns what came back."""
    w.send(cmd + "\r")
    time.sleep(delay)
    w.send(CTRL_C)
    time.sleep(settle)
    return strip_ansi(w.drain(0.6)[0])


# --- the basic case ----------------------------------------------------------
started = time.time()
out = interrupt_after("sleep 20", delay=0.7)
elapsed = time.time() - started

check("^C stops a running command", elapsed < 6, f"took {elapsed:.1f}s")
check("the interrupt is echoed", "^C" in out, out[-200:])
check("the command reports being interrupted", "interrupted" in out, out[-200:])

# The session has to be usable immediately afterwards.
check("the shell works right after an interrupt", "alive" in run("echo alive"))
check("the prompt is back", "webos:" in run("pwd"))

# --- it must not fire when nothing is running --------------------------------
# With no command running, ^C is line editing: it clears what was typed.
w.send("this is a half-typed line")
time.sleep(0.3)
w.send(CTRL_C)
time.sleep(0.4)
w.drain(0.4)
out = run("echo after-cancel")
check("^C at a prompt cancels the line, not the session", "after-cancel" in out, out[:200])
check("the cancelled text does not run", "half-typed" not in out, out[:200])

# --- interrupting a script ---------------------------------------------------
run("cd /tmp")
run("rm -r intr")
run("mkdir intr && cd intr")
run("rm loop.sh", 0.3)
for i, line in enumerate(["while true", "do", "  sleep 1", "done"]):
    run(f"echo '{line}' {'>' if i == 0 else '>>'} loop.sh", 0.3)

started = time.time()
out = interrupt_after("sh loop.sh", delay=1.0)
elapsed = time.time() - started
check("^C stops a runaway script", elapsed < 8, f"took {elapsed:.1f}s")
check("the shell survives an interrupted script", "ok" in run("echo ok", 1.0))

# --- interrupting a wait -----------------------------------------------------
run("sleep 30 &", 0.8)
started = time.time()
out = interrupt_after("wait", delay=0.8)
elapsed = time.time() - started
check("^C gets out of a wait", elapsed < 8, f"took {elapsed:.1f}s")
check("wait says it was interrupted", "interrupted" in out, out[-200:])

# The job itself keeps running: interrupting the wait is not killing the job.
out = run("jobs")
check("the job is still running after the wait was interrupted",
      "running" in out, out[:250])

for line in out.splitlines():
    m = re.match(r"\s*\[(\d+)\]", line)
    if m:
        run(f"kill {m.group(1)}", 0.3)

# --- interrupting does not kill someone else ---------------------------------
w2 = WS(port=PORT)
w2.drain(0.5)
w2.send("sleep 15\r")
time.sleep(0.5)

# The first session interrupting its own idle prompt must not touch the second.
w.send(CTRL_C)
time.sleep(1.0)
w.drain(0.4)

t2 = strip_ansi(w2.drain(0.5)[0])
check("one session's ^C does not interrupt another's command",
      "interrupted" not in t2, t2[-200:])

w2.send(CTRL_C)
time.sleep(1.0)
t2 = strip_ansi(w2.drain(0.6)[0])
check("the other session can interrupt its own", "interrupted" in t2, t2[-200:])
w2.close()

check("the shell still works at the end", "done" in run("echo done"))

w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all interrupt checks passed")
