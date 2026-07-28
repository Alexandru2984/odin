"""F2: the shell language — quoting, pipes, chaining, variables, redirection."""
import os
import sys

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
fails = []

w = WS(port=PORT)
w.drain(0.6)


def run(cmd, wait=0.7):
    t, _ = w.cmd(cmd, wait)
    body = strip_ansi(t)
    # Drop the echoed command line and the trailing prompt.
    lines = body.splitlines()
    if lines and lines[0].strip() == cmd.strip():
        lines = lines[1:]
    while lines and ("$" in lines[-1] or "%" in lines[-1]) and "webos:" in lines[-1]:
        lines = lines[:-1]
    return "\n".join(lines).strip()


def check(name, got, want):
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print(f"      want: {want!r}")
        print(f"      got : {got!r}")
        fails.append(name)


def check_in(name, needle, haystack):
    ok = needle in haystack
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print(f"      {needle!r} not in {haystack!r}")
        fails.append(name)


run("cd /tmp")

# --- quoting -----------------------------------------------------------------
check("double quotes keep spaces as one argument", run('echo "hello   world"'), "hello   world")
check("single quotes are literal", run("echo 'a $USER b'"), "a $USER b")
check("quoted pipe is text, not an operator", run('echo "a | b"'), "a | b")
check("backslash escapes a space", run("echo one\\ two"), "one two")

# --- variables ---------------------------------------------------------------
run("GREETING=hello")
check("assignment then expansion", run("echo $GREETING"), "hello")
check("braced expansion", run("echo ${GREETING}world"), "helloworld")
check("expansion inside double quotes", run('echo "say $GREETING"'), "say hello")
check("undefined variable expands to nothing", run("echo [$NOPE]"), "[]")
check("built-in PWD", run("echo $PWD"), "/tmp")
run("export TOOL=webos")
check("export sets a variable", run("echo $TOOL"), "webos")
run("unset TOOL")
check("unset removes it", run("echo [$TOOL]"), "[]")

# --- exit status and chaining ------------------------------------------------
check("$? is 0 after success", run("echo hi > /tmp/f2.txt ; echo $?"), "0")
check("$? is non-zero after failure", run("cat /tmp/definitely-missing ; echo $?").splitlines()[-1], "1")
check("&& runs on success", run("echo ok && echo second"), "ok\nsecond")
check("&& stops on failure", run("cat /tmp/definitely-missing && echo NOTREACHED").splitlines()[-1],
      "cat: /tmp/definitely-missing: no such file or directory")
check("|| runs on failure", run("cat /tmp/definitely-missing || echo recovered").splitlines()[-1],
      "recovered")
check("|| skips on success", run("echo fine || echo NOTREACHED"), "fine")
check("; runs both", run("echo a ; echo b"), "a\nb")

# --- pipes -------------------------------------------------------------------
run("rm /tmp/animals.txt")
run("echo pear > /tmp/animals.txt")
run("echo apple >> /tmp/animals.txt")
run("echo pear >> /tmp/animals.txt")
run("echo fig >> /tmp/animals.txt")

check("cat into sort", run("cat /tmp/animals.txt | sort"), "apple\nfig\npear\npear")
check("sort -u through a pipe", run("cat /tmp/animals.txt | sort -u"), "apple\nfig\npear")
check("three-stage pipeline",
      " ".join(run("cat /tmp/animals.txt | sort | uniq -c").split()),
      "1 apple 1 fig 2 pear")
check("grep filters a pipe", run("cat /tmp/animals.txt | grep -h pear"), "pear\npear")
check("grep -c counts", run("cat /tmp/animals.txt | grep -c pear"), "2")
check("wc counts piped lines", run("cat /tmp/animals.txt | wc").split()[0], "4")
check("tac reverses", run("cat /tmp/animals.txt | tac | head -n 1"), "fig")
check("tr upper", run("echo hello | tr upper"), "HELLO")
check("nl numbers piped lines", run("echo solo | nl").strip(), "1  solo")
check("rev works on a pipe", run("echo abc | rev"), "cba")

# --- pipeline into a file ----------------------------------------------------
run("cat /tmp/animals.txt | sort -u > /tmp/sorted.txt")
check("pipeline output redirects to a file", run("cat /tmp/sorted.txt"), "apple\nfig\npear")

# --- grep exit status drives chaining ---------------------------------------
check("grep success chains", run("grep -h pear /tmp/animals.txt && echo FOUND").splitlines()[-1],
      "FOUND")
check("grep failure chains", run("grep -h zebra /tmp/animals.txt || echo ABSENT"), "ABSENT")

# --- digests and encoding ----------------------------------------------------
check("sha256 of a known string", run("sha256 abc"),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("base64 encode", run("base64 hello"), "aGVsbG8=")
check("base64 decode", run("base64 -d aGVsbG8="), "hello")
check("cut selects a field", run("echo 'a:b:c' | cut -d : -f 2"), "b")

# --- limits ------------------------------------------------------------------
check_in("too many pipeline stages is refused",
         "too many pipeline stages", run("echo x" + " | rev" * 20))
check_in("unterminated quote is a syntax error",
         "unterminated quote", run('echo "unclosed'))

# --- redirection still cannot escape permissions -----------------------------
check_in("cannot redirect into a system directory",
         "permission denied", run("echo nope > /etc/passwd"))

w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    sys.exit(1)
print("all F2 checks passed")
