"""head/tail short counts, grep numbering, cowsay/banner as pipeline filters."""
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


def run(cmd, wait=0.7):
    t, _ = w.cmd(cmd, wait)
    return strip_ansi(t)


def body(cmd, wait=0.7):
    """Output with the echoed command and the trailing prompt removed."""
    out = run(cmd, wait).splitlines()
    lines = [l for l in out[1:] if "webos:" not in l]
    while lines and lines[-1] == "":
        lines.pop()
    return lines


run("cd /tmp")
run("rm -r filt")
run("mkdir filt && cd filt")
for n in ["one", "two", "three", "four"]:
    run(f"echo {n} >> nums.txt")

check("head defaults to everything short of ten", body("head nums.txt") ==
      ["one", "two", "three", "four"], str(body("head nums.txt")))
check("head -2 takes a short count", body("head -2 nums.txt") == ["one", "two"],
      str(body("head -2 nums.txt")))
check("tail -1 takes a short count", body("tail -1 nums.txt") == ["four"],
      str(body("tail -1 nums.txt")))
check("head -n 3 still works", body("head -n 3 nums.txt") == ["one", "two", "three"],
      str(body("head -n 3 nums.txt")))
check("head -2 works through a pipe", body("cat nums.txt | head -2") == ["one", "two"],
      str(body("cat nums.txt | head -2")))

# An unrecognised flag is ignored when a real file follows it, and is only
# treated as a path when it is the only thing there. Both need a client to
# resolve against the VFS, so neither is covered by the unit tests.
check("an unknown flag next to a file is ignored",
      body("head -x nums.txt") == ["one", "two", "three", "four"],
      str(body("head -x nums.txt")))
out = run("head -x")
check("an unknown flag on its own is a path lookup, not a crash",
      "no such file" in out, out[:200])
check("the server is still alive afterwards", "one" in run("cat nums.txt"))

# --- grep --------------------------------------------------------------------
check("grep does not number by default", body("grep two nums.txt") == ["two"],
      str(body("grep two nums.txt")))
check("grep -n numbers", body("grep -n two nums.txt") == ["2: two"],
      str(body("grep -n two nums.txt")))
check("grep in the middle of a pipe stays clean",
      body("cat nums.txt | grep o | sort") == ["four", "one", "two"],
      str(body("cat nums.txt | grep o | sort")))
check("grep -v inverts", body("grep -v o nums.txt") == ["three"],
      str(body("grep -v o nums.txt")))
check("grep -c counts", body("grep -c o nums.txt") == ["3"], str(body("grep -c o nums.txt")))
check("no match is a failing status", "gone" in run("grep zzz nums.txt || echo gone"))

# --- cowsay / banner ---------------------------------------------------------
out = run("echo hello there | cowsay")
check("cowsay says what it is piped", "< hello there >" in out, out[:200])
check("cowsay still draws the cow", "^__^" in out, out[:200])

out = run("cowsay typed words")
check("cowsay still takes arguments", "< typed words >" in out, out[:200])

out = run("cowsay")
check("bare cowsay still moos", "< moo >" in out, out[:200])

out = run("fortune | cowsay")
check("fortune | cowsay is not a moo", "< moo >" not in out and "^__^" in out, out[:200])

out = run("echo hi | banner")
check("banner renders piped text", "#" in out, out[:200])

out = run("banner")
check("bare banner explains itself", "usage" in out, out[:200])

w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all filter checks passed")
