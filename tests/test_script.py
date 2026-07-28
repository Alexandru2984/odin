"""Scripts from the VFS: arguments, conditions, loops and limits."""
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


def run(cmd, wait=0.8):
    t, _ = w.cmd(cmd, wait)
    return strip_ansi(t)


def body(cmd, wait=0.8):
    lines = [l for l in run(cmd, wait).splitlines()[1:] if "webos:" not in l]
    while lines and lines[-1] == "":
        lines.pop()
    return lines


def write_script(name, lines):
    """Builds a script one line at a time; there is no heredoc."""
    run(f"rm {name}", 0.3)
    for i, line in enumerate(lines):
        op = ">" if i == 0 else ">>"
        # Single quotes keep $ and * away from the interactive shell so the
        # text lands in the file exactly as written.
        run(f"echo '{line}' {op} {name}", 0.3)


run("cd /tmp")
run("rm -r sc")
run("mkdir sc && cd sc")

# --- the basics --------------------------------------------------------------
write_script("hello.sh", ["#!/bin/sh", "# a comment", "echo hello", "echo world"])
check("a script runs its lines", body("sh hello.sh") == ["hello", "world"],
      str(body("sh hello.sh")))
check("comments and shebang are skipped", "#" not in " ".join(body("sh hello.sh")),
      str(body("sh hello.sh")))

out = run("sh missing.sh")
check("a missing script is reported", "no such file" in out, out[:200])

# --- arguments ---------------------------------------------------------------
write_script("args.sh", ["echo name=$0", "echo one=$1 two=$2", "echo count=$#", "echo all=$@"])
got = body("sh args.sh alpha beta")
check("$0 is the script name", "name=args.sh" in " ".join(got), str(got))
check("positional parameters expand", "one=alpha two=beta" in " ".join(got), str(got))
check("$# counts arguments", "count=2" in " ".join(got), str(got))
check("$@ is every argument", "all=alpha beta" in " ".join(got), str(got))

got = body("sh args.sh")
check("missing parameters expand to nothing", "one= two=" in " ".join(got), str(got))
check("$# is zero with no arguments", "count=0" in " ".join(got), str(got))

# --- conditions --------------------------------------------------------------
check("test on an existing file", body("test -f hello.sh && echo yes") == ["yes"],
      str(body("test -f hello.sh && echo yes")))
check("test on a missing file", body("test -f nope.sh || echo no") == ["no"],
      str(body("test -f nope.sh || echo no")))
check("bracket form works", body("[ -d /tmp ] && echo dir") == ["dir"],
      str(body("[ -d /tmp ] && echo dir")))
out = run("[ -d /tmp")
check("an unclosed bracket is refused", "missing closing" in out, out[:200])
check("string equality", body("[ a = a ] && echo eq") == ["eq"], str(body("[ a = a ] && echo eq")))
check("string inequality", body("[ a != b ] && echo ne") == ["ne"], str(body("[ a != b ] && echo ne")))
check("numeric comparison", body("[ 5 -gt 3 ] && echo gt") == ["gt"], str(body("[ 5 -gt 3 ] && echo gt")))
check("negative numbers compare", body("[ -1 -lt 0 ] && echo lt") == ["lt"],
      str(body("[ -1 -lt 0 ] && echo lt")))
check("empty string test", body("[ -z '' ] && echo empty") == ["empty"],
      str(body("[ -z '' ] && echo empty")))
check("true succeeds", body("true && echo t") == ["t"], str(body("true && echo t")))
check("false fails", body("false || echo f") == ["f"], str(body("false || echo f")))

# --- if ----------------------------------------------------------------------
write_script("if.sh", [
    "if test -f hello.sh",
    "then",
    "  echo found",
    "else",
    "  echo missing",
    "fi",
    "if false; then",
    "  echo wrong",
    "else",
    "  echo right",
    "fi",
])
check("if/else picks the right branch", body("sh if.sh") == ["found", "right"],
      str(body("sh if.sh")))

write_script("noelse.sh", ["if false", "then", "echo never", "fi", "echo after"])
check("a false if with no else skips to the end", body("sh noelse.sh") == ["after"],
      str(body("sh noelse.sh")))

# --- while -------------------------------------------------------------------
write_script("while.sh", [
    "export N=0",
    "while [ $N -lt 3 ]",
    "do",
    "  echo n=$N",
    "  export N=$(calc $N + 1)",
    "done",
    "echo end",
])
check("while loops the right number of times",
      body("sh while.sh", 1.5) == ["n=0", "n=1", "n=2", "end"], str(body("sh while.sh", 1.5)))

# --- for ---------------------------------------------------------------------
write_script("for.sh", ["for x in a b c", "do", "  echo item=$x", "done"])
check("for iterates a word list",
      body("sh for.sh", 1.2) == ["item=a", "item=b", "item=c"], str(body("sh for.sh", 1.2)))

run("echo 1 > one.txt")
run("echo 2 > two.txt")
write_script("forglob.sh", ["for f in *.txt", "do", "  echo file=$f", "done"])
got = body("sh forglob.sh", 1.2)
check("for expands a glob", got == ["file=one.txt", "file=two.txt"], str(got))

# --- nesting -----------------------------------------------------------------
write_script("nest.sh", [
    "for x in a b",
    "do",
    "  if [ $x = a ]",
    "  then",
    "    echo first",
    "  else",
    "    echo second",
    "  fi",
    "done",
])
check("blocks nest", body("sh nest.sh", 1.2) == ["first", "second"], str(body("sh nest.sh", 1.2)))

# --- exit --------------------------------------------------------------------
write_script("exit.sh", ["echo before", "exit 3", "echo after"])
got = body("sh exit.sh")
check("exit stops the script", got == ["before"], str(got))
check("exit sets the status", body("sh exit.sh ; echo status=$?")[-1] == "status=3",
      str(body("sh exit.sh ; echo status=$?")))

# The session must survive `exit` in a script — it is not a logout.
check("exit in a script is not a logout", "alive" in run("echo alive"))

# --- safety ------------------------------------------------------------------
write_script("bad.sh", ["if true", "echo unbalanced"])
out = run("sh bad.sh")
check("unbalanced blocks are refused", "unbalanced" in out, out[:200])

write_script("loop.sh", ["while true", "do", "  echo spin", "done"])
out = run("sh loop.sh", 6.0)
check("an infinite loop is stopped", "too long" in out or "infinite" in out, out[-300:])
check("the shell survives an infinite loop", "ok" in run("echo ok", 1.5))

write_script("self.sh", ["sh self.sh"])
out = run("sh self.sh", 2.0)
check("runaway recursion is stopped", "nested too deeply" in out, out[:300])

# --- composition -------------------------------------------------------------
write_script("out.sh", ["echo alpha", "echo beta"])
check("a script's output can be piped", body("sh out.sh | sort -r") == ["beta", "alpha"],
      str(body("sh out.sh | sort -r")))
run("sh out.sh > captured.txt", 1.0)
check("a script's output can be redirected", body("cat captured.txt") == ["alpha", "beta"],
      str(body("cat captured.txt")))

check("the shell still works at the end", "done" in run("echo done"))

w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all script checks passed")
