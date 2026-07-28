"""F3: the full-screen editor."""
import json
import os
import sys

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
fails = []


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


w = WS(port=PORT)
w.drain(0.6)
# Report a real terminal size so the editor knows how many rows to paint.
w.send(json.dumps({"t": "size", "cols": 80, "rows": 24}), opcode=0x2)
w.drain(0.3)

w.cmd("cd /tmp", 0.4)

# --- opening a new file ------------------------------------------------------
t, _ = w.cmd("edit notes.txt", 0.8)
screen = strip_ansi(t)
check("editor opens", "notes.txt" in screen, screen[:200])
check("shows it is a new file", "new file" in screen, screen[:300])
check("shows the key hints", "^S save" in screen or "new file" in screen, screen[-200:])
check("draws empty-line markers", "~" in screen, screen[:400])

# --- typing ------------------------------------------------------------------
w.send("hello editor")
w.drain(0.4)
w.send("\r")
w.send("second line")
t, _ = w.drain(0.5)
screen = strip_ansi(t)
check("typed text appears", "hello editor" in screen, screen[:300])
check("second line appears", "second line" in screen, screen[:300])
check("buffer is marked modified", "modified" in screen, screen[:200])

# --- saving ------------------------------------------------------------------
w.send("\x13")  # ^S
t, _ = w.drain(0.7)
screen = strip_ansi(t)
check("save reports success", "saved 2 lines" in screen, screen[-250:])
check("modified marker clears after save", "modified" not in screen, screen[:200])

# --- quitting ----------------------------------------------------------------
w.send("\x11")  # ^Q, buffer is clean so it should leave at once
t, _ = w.drain(0.6)
screen = strip_ansi(t)
check("quitting returns to the shell", "webos:" in screen, screen[-200:])

# --- the file really was written ---------------------------------------------
t, _ = w.cmd("cat notes.txt", 0.6)
body = strip_ansi(t)
check("file contains the first line", "hello editor" in body, body[:200])
check("file contains the second line", "second line" in body, body[:200])

t, _ = w.cmd("wc notes.txt", 0.6)
# Output is "<lines> <words> <bytes>  <name>" on the line after the echoed command.
wc_line = [l for l in strip_ansi(t).splitlines() if l.strip().endswith("notes.txt")][-1]
check("file has exactly two lines", wc_line.split()[0] == "2", wc_line)

# --- reopening shows the content ---------------------------------------------
t, _ = w.cmd("edit notes.txt", 0.8)
screen = strip_ansi(t)
check("reopening loads the file", "hello editor" in screen, screen[:300])
check("reports the line count", "2 lines" in screen, screen[:300])

# --- unsaved changes need a confirmation -------------------------------------
w.send("x")
w.drain(0.3)
w.send("\x11")  # first ^Q with changes: should warn, not quit
t, _ = w.drain(0.5)
screen = strip_ansi(t)
check("first quit warns about unsaved changes", "unsaved changes" in screen, screen[-250:])
check("first quit does not leave the editor", "webos:/tmp$" not in screen, screen[-200:])

w.send("\x11")  # second ^Q: discard and leave
t, _ = w.drain(0.6)
screen = strip_ansi(t)
check("second quit leaves the editor", "webos:" in screen, screen[-200:])

t, _ = w.cmd("cat notes.txt", 0.6)
check("discarded change was not written", "xhello editor" not in strip_ansi(t),
      strip_ansi(t)[:150])

# --- editing an existing line ------------------------------------------------
w.cmd("edit notes.txt", 0.8)
w.send("\x05")  # ^E, end of line
w.drain(0.2)
w.send("!")
w.drain(0.2)
w.send("\x13")  # save
t, _ = w.drain(0.7)
check("edit of an existing line saves", "saved" in strip_ansi(t), strip_ansi(t)[-200:])
w.send("\x11")
w.drain(0.5)

t, _ = w.cmd("cat notes.txt", 0.6)
check("the edit is in the file", "hello editor!" in strip_ansi(t), strip_ansi(t)[:200])

# --- permissions are still enforced on save ----------------------------------
t, _ = w.cmd("edit /etc/motd", 0.8)
check("can open a system file", "motd" in strip_ansi(t), strip_ansi(t)[:200])
w.send("z")
w.drain(0.2)
w.send("\x13")
t, _ = w.drain(0.7)
check("cannot save over a system file", "permission denied" in strip_ansi(t),
      strip_ansi(t)[-250:])
w.send("\x11")
w.drain(0.2)
w.send("\x11")
w.drain(0.5)

t, _ = w.cmd("cat /etc/motd", 0.6)
check("system file is unchanged", "zWelcome" not in strip_ansi(t), strip_ansi(t)[:150])

# --- a directory is refused ---------------------------------------------------
t, _ = w.cmd("edit /tmp", 0.6)
check("editing a directory is refused", "is a directory" in strip_ansi(t), strip_ansi(t)[:200])

# --- the shell still works afterwards -----------------------------------------
t, _ = w.cmd("echo still-alive", 0.6)
check("shell works after the editor", "still-alive" in strip_ansi(t), strip_ansi(t)[:150])

w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all editor checks passed")
