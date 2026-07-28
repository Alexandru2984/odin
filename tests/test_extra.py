"""F3: aliases, calendar and mail."""
import os
import sys

import random
import string

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


SUF = "".join(random.choice(string.ascii_lowercase) for _ in range(4))
ALICE = "alice" + SUF
BOB = "bob" + SUF

w = WS(port=PORT)
w.drain(0.6)


def run(sess, cmd, wait=0.7):
    t, _ = sess.cmd(cmd, wait)
    return strip_ansi(t)


# --- aliases -----------------------------------------------------------------
check("no aliases initially", "no aliases set" in run(w, "alias"))

run(w, "alias ll=ls -l")
out = run(w, "alias")
check("alias is listed", "ll='ls -l'" in out, out[:200])

run(w, "cd /tmp")
run(w, "touch alias-probe.txt")
out = run(w, "ll")
check("alias expands to the real command", "alias-probe.txt" in out and "rw-" in out, out[:300])

out = run(w, "ll /etc")
check("alias keeps extra arguments", "motd" in out, out[:300])

out = run(w, "alias rm=echo")
check("an alias cannot shadow a built-in", "not a usable alias name" in out, out[:200])

out = run(w, "alias loop=loop x")
check("a self-referential alias is refused", "cannot expand to itself" in out, out[:200])

# `ll` falls back to the built-in convenience alias once the session one is
# gone, so removal is checked with a name the server does not ship.
run(w, "alias probe=echo probed")
check("custom alias works", "probed" in run(w, "probe"), run(w, "probe")[:150])
run(w, "unalias probe")
out = run(w, "probe")
check("unalias removes it", "command not found" in out, out[:200])

run(w, "unalias ll")
out = run(w, "ll /etc")
check("removing a session alias falls back to the built-in", "motd" in out, out[:200])

# --- calendar ----------------------------------------------------------------
out = run(w, "cal 2 2024")
check("calendar prints a title", "February 2024" in out, out[:200])
check("calendar has weekday headers", "Mo Tu We Th Fr Sa Su" in out, out[:200])
check("february 2024 was a leap year", "29" in out, out[:400])
# 1 Feb 2024 was a Thursday, so the first row starts with three blank slots.
first_row = [l for l in out.splitlines() if l.strip().startswith("1 ")
             or l.rstrip().endswith(" 4")]
check("leap-year month has 29 days and no 30", " 30 " not in out, out[:400])

out = run(w, "cal 2 2023")
check("february 2023 was not a leap year", "29" not in out.split("Mo Tu")[1], out[:400])

# --- mail --------------------------------------------------------------------
check("mail needs an account", "need an account" in run(w, "mail"))

run(w, f"register {ALICE} alicepassword", 2.0)
w2 = WS(port=PORT)
w2.drain(0.5)
run(w2, f"register {BOB} bobpassword123", 2.0)

check("new mailbox is empty", "no mail" in run(w2, "mail"), run(w2, "mail")[:150])

out = run(w, f"mail send {BOB} hello from alice", 1.0)
check("mail sends", f"sent to {BOB}" in out, out[:200])

out = run(w, "mail send nobody hi", 1.0)
check("mail to an unknown account is refused", "no such account" in out, out[:200])

out = run(w2, "mail", 0.8)
check("recipient sees the message", ALICE in out, out[:300])
check("recipient sees a preview", "hello from alice" in out, out[:300])

out = run(w2, "mail read 1", 0.8)
check("message body is readable", "hello from alice" in out, out[:300])
check("message shows the sender", "From:" in out and ALICE in out, out[:300])

# The mailbox belongs to the recipient, not the sender.
# The directory is visible but each message is private, so the sender can see
# that bob has a mailbox and nothing about what is in it.
out = run(w, f"ls /home/{BOB}/mail", 0.8)
listing = [l for l in out.splitlines()
           if l.strip() and not l.startswith("ls ") and "webos:" not in l]
check("sender sees no messages in the recipient's mailbox", listing == [], str(listing))

out = run(w, f"cat /home/{BOB}/mail/*", 0.8)
check("sender cannot read a delivered message",
      "hello from alice" not in out, out[:200])

out = run(w2, "mail clear", 0.8)
check("mail clear empties the box", "removed 1 message" in out, out[:200])
check("mailbox is empty again", "no mail" in run(w2, "mail"))

w2.close()
w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all extra checks passed")
