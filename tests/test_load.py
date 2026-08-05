"""Legitimate concurrent load, up to and past the connection cap.

test_fuzz.py asks whether the server survives traffic that is trying to break
it. This asks the other question, and it has a different answer: what happens
when a lot of people who are all behaving perfectly correctly turn up at once.
The failure modes do not overlap. Thread exhaustion, lock contention, output
delivered to the wrong session, and a cap that only holds when connections
arrive one at a time are all things a well-formed client can cause and a
malformed one cannot.

Each connection carries its own X-Real-IP. From loopback the server honours
that header — it is what nginx sets — so this stands in for many separate
visitors rather than one machine hammering the port, which would be stopped by
the per-IP limit long before the interesting part.
"""
import os
import socket
import sys
import threading
import time
import urllib.request

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))

# Must match MAX_CLIENTS in src/config.odin. Read from the server rather than
# hardcoded, so raising the cap does not silently turn this suite into a test
# of a number nobody uses any more.
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


def metrics():
    """The server's own view of itself. Cheaper and more truthful than guessing."""
    url = f"http://127.0.0.1:{PORT}/metrics"
    txt = urllib.request.urlopen(url, timeout=3).read().decode()
    out = {}
    for line in txt.splitlines():
        if line.startswith("webos_"):
            key, _, value = line.partition(" ")
            try:
                out[key] = int(value)
            except ValueError:
                pass
    return out


def wait_for(fn, want, seconds=10.0):
    """Polls until fn() == want. Teardown is asynchronous; sleeping a guess is not a test."""
    end = time.time() + seconds
    last = None
    while time.time() < end:
        last = fn()
        if last == want:
            return True, last
        time.sleep(0.1)
    return False, last


def server_pid():
    """The PID behind our port, found by matching the data dir the runner set.

    Several webos_server processes can legitimately exist on this machine (the
    live one, a stray dev one), so the port in the environment is the only
    thing that identifies ours.
    """
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/cmdline", "rb") as f:
                if b"webos_server" not in f.read():
                    continue
            with open(f"/proc/{entry}/environ", "rb") as f:
                if f"WEBOS_PORT={PORT}".encode() in f.read():
                    return int(entry)
        except (OSError, IOError):
            continue
    return None


def thread_count(pid):
    try:
        return len(os.listdir(f"/proc/{pid}/task"))
    except OSError:
        return -1


def fd_count(pid):
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except OSError:
        return -1


def open_session(index, wait=0.0):
    """One connection from its own address. Returns the client, or the status that refused it."""
    ip = f"10.{(index >> 16) & 0xFF}.{(index >> 8) & 0xFF}.{index & 0xFF}"
    try:
        w = WS(port=PORT, timeout=10.0, extra_headers=f"X-Real-IP: {ip}\r\n")
    except Exception as exc:
        return None, repr(exc)
    if w.status != 101:
        status = w.status
        w.close()
        return None, status
    if wait:
        w.drain(wait)
    return w, 101


def open_session_thin(index):
    """A peer whose receive window is tiny, so the server has to hold the backlog."""
    ip = f"10.{(index >> 16) & 0xFF}.{(index >> 8) & 0xFF}.{index & 0xFF}"
    try:
        w = WS(port=PORT, timeout=10.0, extra_headers=f"X-Real-IP: {ip}\r\n", rcvbuf=2048)
    except Exception as exc:
        return None, repr(exc)
    return (w, 101) if w.status == 101 else (None, w.status)


base = metrics()
cap = base.get("webos_sessions_max", 128)
check("the server reports a session cap", cap > 0, str(cap))
check("we start from an empty server", base.get("webos_sessions") == 0, str(base.get("webos_sessions")))

pid = server_pid()
check("the server process was located", pid is not None)
threads_idle = thread_count(pid) if pid else -1
fds_idle = fd_count(pid) if pid else -1
print(f"      idle: {threads_idle} threads, {fds_idle} fds")

# --- filling the server ------------------------------------------------------
#
# Sequentially, so the cap is being asked the easy question first: does it hold
# when nothing races it.

sessions = []
refusals = []
for i in range(cap):
    w, status = open_session(i)
    if w:
        sessions.append(w)
    else:
        refusals.append(status)

check("every session up to the cap was accepted", len(sessions) == cap,
      f"{len(sessions)}/{cap} accepted, refusals: {refusals[:3]}")

ok, seen = wait_for(lambda: metrics().get("webos_sessions"), cap, 10.0)
check("the server agrees it is full", ok, f"reported {seen}, expected {cap}")

if pid:
    threads_full = thread_count(pid)
    fds_full = fd_count(pid)
    print(f"      full: {threads_full} threads, {fds_full} fds "
          f"(+{threads_full - threads_idle} threads for {cap} sessions)")

# --- one past the cap --------------------------------------------------------

start = time.time()
extra, status = open_session(9001)
elapsed = time.time() - start
check("a session past the cap is refused", extra is None, f"status {status}")
check("the refusal is immediate, not a hang", elapsed < 2.0, f"{elapsed:.2f}s")
check("the refusal is 503, not a dropped connection", status == 503, str(status))

after_refusal = metrics()
check("the refusal was counted",
      after_refusal.get("webos_connections_refused_total", 0)
      > base.get("webos_connections_refused_total", 0))

# --- the cap under simultaneous arrival --------------------------------------
#
# The sessions above arrived one at a time, which asks the cap only the easy
# question. The interesting one is whether the check and the registration that
# follows it behave as a single decision: a connection is refused on
# client_count(), but it does not *become* one of those clients until after its
# handshake and its threads exist. Bursting into the last few free slots is the
# only way to find out how wide that window is.
#
# A burst against an already-full server would prove nothing — every connection
# would be refused at the first check — so free a few slots first.

FREE_SLOTS = 8
BURST = 48

for w in sessions[:FREE_SLOTS]:
    w.close()
sessions = sessions[FREE_SLOTS:]
ok, seen = wait_for(lambda: metrics().get("webos_sessions"), cap - FREE_SLOTS, 15.0)
check("slots free again when sessions leave", ok, f"reported {seen}")

burst_results = []
burst_lock = threading.Lock()
gate = threading.Barrier(BURST + 1)


def burst_connect(index):
    gate.wait()  # every thread leaves the gate in the same instant
    w, status = open_session(index)
    with burst_lock:
        burst_results.append((w, status))


burst_threads = [threading.Thread(target=burst_connect, args=(20000 + i,)) for i in range(BURST)]
for t in burst_threads:
    t.start()
gate.wait()
for t in burst_threads:
    t.join()

burst_accepted = [w for w, _ in burst_results if w]
peak = metrics().get("webos_sessions", 0)

check(f"{BURST} simultaneous arrivals into {FREE_SLOTS} free slots do not exceed the cap",
      peak <= cap, f"{peak} sessions live, cap is {cap} "
                   f"({len(burst_accepted)} of {BURST} got in)")

# Put the server back at capacity for the work below, using whichever of the
# burst connections were accepted.
sessions.extend(burst_accepted[:FREE_SLOTS])
for w in burst_accepted[FREE_SLOTS:]:
    w.close()

# --- the full server still works ---------------------------------------------
#
# A cap that holds while the server is useless would pass every check above.

results = {}
results_lock = threading.Lock()


def exercise(index, w):
    token = f"tok{index:03d}z"
    try:
        out, _ = w.cmd(f"echo {token}", 2.5)
        with results_lock:
            results[index] = strip_ansi(out)
    except Exception as exc:
        with results_lock:
            results[index] = f"__ERROR__{exc!r}"


workers = [threading.Thread(target=exercise, args=(i, w)) for i, w in enumerate(sessions)]
t0 = time.time()
for t in workers:
    t.start()
for t in workers:
    t.join()
concurrent_elapsed = time.time() - t0

answered = sum(1 for i, out in results.items() if f"tok{i:03d}z" in out)
check("every session at full capacity answered", answered == len(sessions),
      f"{answered}/{len(sessions)} answered in {concurrent_elapsed:.1f}s")

# Cross-talk: one session receiving another's output is the failure that only
# concurrency produces, and liveness checks would never notice it.
crossed = []
for i, out in results.items():
    for j in range(len(sessions)):
        if j != i and f"tok{j:03d}z" in out:
            crossed.append((i, j))
            break
check("no session received another session's output", not crossed, str(crossed[:3]))

# The shared filesystem under real contention, which is a different lock from
# the one the echo above touches.
vfs_results = {}


def exercise_vfs(index, w):
    try:
        out, _ = w.cmd(f"cd /tmp && echo body{index:03d}z > load{index:03d}.txt && cat load{index:03d}.txt", 3.0)
        vfs_results[index] = strip_ansi(out)
    except Exception as exc:
        vfs_results[index] = f"__ERROR__{exc!r}"


workers = [threading.Thread(target=exercise_vfs, args=(i, w)) for i, w in enumerate(sessions[:64])]
for t in workers:
    t.start()
for t in workers:
    t.join()

vfs_ok = sum(1 for i, out in vfs_results.items() if f"body{i:03d}z" in out)
check("concurrent writes to the shared filesystem all read back",
      vfs_ok == len(vfs_results), f"{vfs_ok}/{len(vfs_results)}")

# --- releasing ---------------------------------------------------------------

for w in sessions:
    w.close()
sessions = []

ok, seen = wait_for(lambda: metrics().get("webos_sessions"), 0, 20.0)
check("the server empties again", ok, f"still reporting {seen}")

if pid:
    # Threads are joined during teardown, so this must come back to the idle
    # figure rather than merely stopping its climb.
    ok, seen = wait_for(lambda: thread_count(pid) <= threads_idle + 4, True, 20.0)
    check("the threads are joined, not leaked", ok,
          f"{thread_count(pid)} threads, idle was {threads_idle}")
    ok, seen = wait_for(lambda: fd_count(pid) <= fds_idle + 4, True, 20.0)
    check("the sockets are closed, not leaked", ok,
          f"{fd_count(pid)} fds, idle was {fds_idle}")

w, status = open_session(9002, wait=0.5)
check("a fresh session is accepted once the server empties", w is not None, str(status))
if w:
    out, _ = w.cmd("echo recovered", 2.0)
    check("and it works", "recovered" in strip_ansi(out))
    w.close()

# --- churn -------------------------------------------------------------------
#
# Connect-and-leave is the common shape of real traffic and the one that
# accumulates: a leak of one thread or one descriptor per session is invisible
# at any single moment and fatal over a week.

CHURN = 200
churn_failures = 0
for i in range(CHURN):
    w, status = open_session(30000 + i)
    if w:
        w.close()
    else:
        churn_failures += 1

check("churn is served without refusals", churn_failures == 0, f"{churn_failures}/{CHURN} refused")

ok, _ = wait_for(lambda: metrics().get("webos_sessions"), 0, 20.0)
check("the server is empty after the churn", ok, str(metrics().get("webos_sessions")))

if pid:
    ok, _ = wait_for(lambda: thread_count(pid) <= threads_idle + 4, True, 20.0)
    check(f"no thread accumulates across {CHURN} sessions", ok,
          f"{thread_count(pid)} threads, idle was {threads_idle}")
    ok, _ = wait_for(lambda: fd_count(pid) <= fds_idle + 4, True, 20.0)
    check(f"no descriptor accumulates across {CHURN} sessions", ok,
          f"{fd_count(pid)} fds, idle was {fds_idle}")

# --- a peer that stops reading -----------------------------------------------
#
# The one client behaviour that costs the *server* memory rather than its own:
# ask for a lot of output and then never drain it. MAX_OUT_PENDING exists for
# this, and the point of the check is that the cost lands on the session that
# caused it and on nobody else.

before_dropped = metrics().get("webos_output_dropped_total", 0)

# The file is built through a normally-buffered session: the sulker's window is
# too small to get the setup done comfortably, and the setup is not the point.
# It doubles until the per-file quota stops it, so this does not depend on
# knowing VFS_MAX_FILE_SIZE.
builder, _ = open_session(9099, wait=0.5)
flood_bytes = 0
if builder:
    builder.cmd("mkdir -p /tmp/load && cd /tmp/load", 2.0)
    builder.cmd("echo " + "x" * 900 + " > pad.txt", 2.0)
    for _ in range(8):
        builder.cmd("cat pad.txt pad.txt >> pad2.txt && cp pad2.txt pad.txt", 2.0)
    out, _ = builder.cmd("wc -c pad.txt", 2.0)
    for line in strip_ansi(out).splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1] == "pad.txt":
            flood_bytes = int(parts[0])
    check("the flood file was built", flood_bytes > 8000, f"{flood_bytes} bytes")

sulker, status = open_session_thin(9100)
bystander, _ = open_session(9101, wait=0.5)
if sulker and bystander:
    # One command per burst rather than one file per command: each of these
    # emits REPEATS * flood_bytes at once, which clears the kernel send buffer
    # and the queue behind it by a wide margin instead of by a hair. Few enough
    # commands that the per-session command rate limiter never comes into it.
    REPEATS = 12
    line = "cat" + " /tmp/load/pad.txt" * REPEATS
    print(f"      flood: {flood_bytes} bytes x {REPEATS} x 4 commands")
    for _ in range(4):
        try:
            sulker.send(line + "\r")
        except (BrokenPipeError, ConnectionResetError, OSError):
            # Being disconnected mid-flood is the outcome under test, not a
            # failure of it: the server closed the connection while we were
            # still asking for more.
            break
        time.sleep(0.2)

    # The writer blocks on a peer that is not reading, so the queue fills over
    # a few seconds rather than instantly.
    ok, _ = wait_for(lambda: metrics().get("webos_output_dropped_total", 0) > before_dropped,
                     True, 25.0)

    after_dropped = metrics().get("webos_output_dropped_total", 0)
    check("a session that will not drain its output is dropped, not buffered without limit",
          after_dropped > before_dropped,
          f"output_dropped_total {before_dropped} -> {after_dropped}")

    out, _ = bystander.cmd("echo bystander-ok", 3.0)
    check("and it never stalled the sessions around it",
          "bystander-ok" in strip_ansi(out), strip_ansi(out)[-160:])

    sulker.close()
    bystander.close()
else:
    check("the slow-reader sessions opened", False, f"{status}")
if builder:
    builder.close()

# --- and the service is genuinely unharmed -----------------------------------

ok, _ = wait_for(lambda: metrics().get("webos_sessions"), 0, 20.0)
check("the server is empty at the end", ok, str(metrics().get("webos_sessions")))

w, status = open_session(9200, wait=0.6)
check("a session still works after all of it", w is not None, str(status))
if w:
    out, _ = w.cmd("echo still-serving && pwd", 2.0)
    text = strip_ansi(out)
    check("the shell is still coherent", "still-serving" in text and "/" in text, text[-200:])
    w.close()

if pid:
    print(f"      end:  {thread_count(pid)} threads, {fd_count(pid)} fds")

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print(f"all load checks passed (cap {cap}, {CHURN} churned sessions)")
