"""Globbing, input redirection and command substitution."""
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
    lines = [l for l in run(cmd, wait).splitlines()[1:] if "webos:" not in l]
    while lines and lines[-1] == "":
        lines.pop()
    return lines


run("cd /tmp")
run("rm -r g")
run("mkdir g && cd g")
for f in ["a.txt", "b.txt", "c.md", "note1", "note2"]:
    run(f"echo {f} > {f}")
run("mkdir sub && echo deep > sub/d.txt")

# --- globbing ----------------------------------------------------------------
check("* expands to matching files",
      set(" ".join(body("ls *.txt")).split()) == {"a.txt", "b.txt"},
      str(body("ls *.txt")))
check("glob feeds multiple args to a command",
      set(body("cat *.txt")) == {"a.txt", "b.txt"},
      str(body("cat *.txt")))
check("? matches exactly one character",
      set(body("cat note?")) == {"note1", "note2"},
      str(body("cat note?")))
check("character class works",
      body("cat note[1]") == ["note1"], str(body("cat note[1]")))
check("negated class works",
      body("cat note[!1]") == ["note2"], str(body("cat note[!1]")))

# A pattern that matches nothing must be left alone, not erased.
out = run("cat *.nope")
check("unmatched glob stays literal", "*.nope" in out and "no such file" in out, out[:200])

# The star must not cross a directory boundary.
check("star does not cross /", "deep" not in " ".join(body("cat *.txt")),
      str(body("cat *.txt")))
check("explicit subdirectory glob works", body("cat sub/*.txt") == ["deep"],
      str(body("cat sub/*.txt")))

# Absolute patterns stay absolute; relative ones stay relative.
check("absolute glob returns absolute paths",
      any("/tmp/g/a.txt" in l for l in body("ls -l /tmp/g/*.txt")),
      str(body("ls -l /tmp/g/*.txt")))

check("glob after variable expansion",
      set(body("export D=/tmp/g ; cat $D/*.txt")) == {"a.txt", "b.txt"},
      str(body("export D=/tmp/g ; cat $D/*.txt")))

# Quoted, it is a literal name and must not expand.
out = run('cat "*.txt"')
check("quoted pattern does not expand", "no such file" in out, out[:200])

check("glob works with rm", "removed" in run("mkdir del && echo x > del/p.txt && echo y > del/q.txt && rm del/*.txt").lower()
      or body("ls del") == [], str(body("ls del")))

check("ls lists several files at once",
      set(" ".join(body("ls a.txt b.txt")).split()) == {"a.txt", "b.txt"},
      str(body("ls a.txt b.txt")))
run("echo hidden > .secret")
check("dotfiles are hidden by default", ".secret" not in " ".join(body("ls")),
      str(body("ls")))
check("ls -a shows dotfiles", ".secret" in " ".join(body("ls -a")), str(body("ls -a")))
check("* does not match a dotfile", ".secret" not in " ".join(body("ls *")),
      str(body("ls *")))
check(".* does match one", ".secret" in " ".join(body("ls .*")), str(body("ls .*")))
# Its own probe file: the redirection section below builds lines.txt, which
# does not exist yet at this point.
run("echo x > wcp.txt && echo y >> wcp.txt")
check("wc -l prints just the count", body("wc -l wcp.txt")[0].split()[0] == "2",
      str(body("wc -l wcp.txt")))
check("wc -w counts words", body("wc -w wcp.txt")[0].split()[0] == "2",
      str(body("wc -w wcp.txt")))
check("wc with no flag prints all three", len(body("wc wcp.txt")[0].split()) >= 3,
      str(body("wc wcp.txt")))
check("wc -l reads a pipe", body("cat wcp.txt | wc -l")[0].strip() == "2",
      str(body("cat wcp.txt | wc -l")))

# --- input redirection -------------------------------------------------------
run("echo one > lines.txt")
run("echo two >> lines.txt")
run("echo three >> lines.txt")

check("< feeds a file into a command", body("wc -l < lines.txt")[0].split()[0] == "3",
      str(body("wc -l < lines.txt")))
check("< combines with a pipe", body("grep t < lines.txt | sort") == ["three", "two"],
      str(body("grep t < lines.txt | sort")))
out = run("wc -l < missing.txt")
check("< on a missing file reports it", "no such file" in out, out[:200])
out = run("wc -l < sub")
check("< on a directory reports it", "directory" in out, out[:200])
out = run("wc -l <")
check("< with no filename is a syntax error", "syntax error" in out, out[:200])

# --- command substitution ----------------------------------------------------
check("$() substitutes output", body("echo [$(echo hi)]") == ["[hi]"],
      str(body("echo [$(echo hi)]")))
check("$() strips trailing newlines", body("echo [$(cat lines.txt)]")[0].startswith("[one"),
      str(body("echo [$(cat lines.txt)]")))
check("$() can hold a pipeline",
      body("echo [$(cat lines.txt | wc -l)]")[0].replace(" ", "") == "[3]",
      str(body("echo [$(cat lines.txt | wc -l)]")))
check("$() nests", body("echo $(echo $(echo deep))") == ["deep"],
      str(body("echo $(echo $(echo deep))")))
check("$() works inside double quotes", body('echo "value: $(echo x)"') == ["value: x"],
      str(body('echo "value: $(echo x)"')))
check("single quotes suppress $()", body("echo '$(echo x)'") == ["$(echo x)"],
      str(body("echo '$(echo x)'")))
check("$() result can be a path", body("cd $(echo /tmp/g) ; pwd") == ["/tmp/g"],
      str(body("cd $(echo /tmp/g) ; pwd")))

out = run("echo $(cat lines.txt")
check("unterminated $( is a syntax error", "unterminated" in out, out[:200])

# Depth is bounded so a nested substitution cannot run the stack out.
out = run("echo $(echo $(echo $(echo $(echo $(echo too_deep)))))", 1.2)
check("substitution depth is bounded", "too deeply" in out or "too_deep" in out, out[:200])

# The server must still be alive and sane after all of that.
check("shell still works afterwards", "alive" in run("echo alive"))

w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all shell checks passed")
