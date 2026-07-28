# WebOS

A multi-user, collaborative fake operating system that lives in a browser tab.
Everyone who connects shares one in-memory filesystem, sees each other in `who`,
and can talk to each other from the shell. The backend is a single
[Odin](https://odin-lang.org/) binary with no dependencies — its own HTTP/1.1
parser, its own RFC 6455 WebSocket implementation, its own shell.

Live at **https://odin.micutu.com**

The name is the point: it is meant to feel like a terminal, not like a website
with a terminal theme. Pipes work. `&&` works. Quoting works. `$?` is the exit
status of the last command, not of the last command that happened to be parsed.

```
webos:/$ cd /tmp && echo "hello there" > note.txt && cat note.txt | wc
       1        2       12
webos:/tmp$ ls /home | grep -v guest | sort | head -3
webos:/tmp$ export WHO=world ; echo "hi $WHO" | cowsay
 ----------
< hi world >
 ----------
        \   ^__^
         \  (oo)\_______
webos:/tmp$ cat missing || echo "exit was $?"
cat: missing: no such file or directory
exit was 1
```

## Running it

```sh
make build             # release binary -> bin/webos_server
make check             # type-check only, no binary
make test              # unit tests
make test-integration  # real client against a private server instance
make run               # build and run in the foreground
make deploy            # build + both test layers, then restart the service
```

Odin `dev-2026-07` or newer. Nothing else — no package manager, no node_modules,
no build step for the frontend.

`make deploy` runs both test layers first and refuses to restart the service if
either fails, so the tests are the last gate before production.

### Configuration

Everything has a safe default; the environment only exists so a development
instance can run beside the live one.

| Variable | Default | Meaning |
| --- | --- | --- |
| `WEBOS_PORT` | `47271` | Listen port |
| `WEBOS_BIND` | `127.0.0.1` | Bind address. Loopback by default — nginx is the only ingress |
| `WEBOS_DATA_DIR` | `data` | Where `vfs.db` and `users.db` live |
| `WEBOS_ALLOWED_ORIGINS` | `https://odin.micutu.com` | Comma-separated `Origin` allowlist for the WebSocket upgrade |

### Metrics

`/metrics` serves a Prometheus exposition — sessions, commands, background
jobs, interrupts, auth outcomes, rate-limit refusals, filesystem quota, traffic.

It is **not** reachable from the internet, and by two independent means. nginx
denies the location, and the backend itself refuses any request carrying
`X-Forwarded-For`, `X-Real-IP` or `CF-Connecting-IP`. The second rule is the
one that matters: nginx also connects from loopback, so the peer address
cannot tell a scrape from a proxied request — but a scrape talking to the
backend directly has no proxy headers. That makes the refusal self-enforcing
if the nginx block is ever lost. It answers 404 rather than 403, because a
refusal that admits something is there is an invitation to keep trying.

Point a scraper at the backend directly:

```yaml
  - job_name: webos
    static_configs:
      - targets: ["127.0.0.1:47271"]
```

Nothing in the exposition identifies anyone. Counts and totals answer "is it
healthy and how busy is it"; names, addresses and paths would answer "who is
on it and what are they doing", which is not a monitoring question — and
session counts are already enough to tell an attacker whether their flood is
working, which is why the endpoint is closed in the first place.

### Deployment

`deploy/` holds the real production configuration: the systemd unit, the nginx
vhost, the rate-limit zone and the security-header snippet. `make install-service`
copies them into place, validates the nginx config and reloads.

The unit is sandboxed — `ProtectSystem=strict`, `PrivateTmp`, `NoNewPrivileges`,
a seccomp filter, and `MemoryMax=512M`. The data directory is the only writable
path. nginx terminates TLS, sets the CSP (`script-src 'self'` — every asset is
self-hosted, including xterm.js), and proxies to loopback.

## What is in it

### The shell

Not a command dispatcher. A small but real shell language, in `src/shell.odin`:

- **pipelines** — `cat file | grep x | sort | uniq -c | head`
- **operators** — `a && b`, `a || b`, `a ; b`
- **redirection** — `> file`, `>> file`, `< file`
- **globbing** — `*.txt`, `note?`, `file[0-9]`, `/home/*/mail`
- **command substitution** — `cd $(pwd)`, `echo "today is $(date)"`
- **quoting** — single quotes are literal, double quotes group and expand
- **variables** — `export NAME=value`, `$NAME`, `${NAME}`, `$?`, `$USER`, `$PWD`
- **aliases** — `alias ll='ls -l'`, `unalias ll`
- **background jobs** — `sleep 30 &`, then `jobs`, `kill`, `wait`
- **scripts** — `sh build.sh arg`, with `if`, `while`, `for` and `$1`..`$9`

Expansion happens at execution time, not at lex time. That is a deliberate
design decision rather than an implementation detail: expanding during the lex
would evaluate the whole line up front, so in `false ; echo $?` the `$?` would
be substituted before `false` had ever run.

Globbing runs after variable expansion, so `ls $DIR/*` works. A pattern that
matches nothing is left alone rather than erased — `rm *.bak` with no backups
must fail with "no such file", not quietly become a bare `rm`. Quoting suppresses
it, `*` never crosses a `/`, and a leading dot has to be asked for by name, so
`rm *` cannot take the dotfiles with it.

Every dimension is bounded — 16 pipeline stages, 32 commands in a list, 64
variables, 4 KiB per value, 16 KiB of total expansion, 4 levels of `$( )`
nesting, 512 results from one glob. A shell that grows a buffer on user input
is a denial-of-service primitive.

### Processes

`ps` used to list connections and call them processes. Nothing was tracked: a
command ran to completion and left no trace, so there was nothing to see, wait
for or kill.

A process is now one pipeline running for one session, and every pipeline gets
an entry — foreground or not — so `ps` shows what the machine is doing rather
than who is connected. `ps -a` shows everyone's.

```
webos:/$ sleep 30 &
[7] started
webos:/$ jobs
[7]  running  sleep 30
webos:/$ kill 7
[7] killed
```

`cmd &` runs the pipeline on its own thread against a **snapshot** of the
session — its directory and its user, taken at spawn time. That is a safety
requirement and correct semantics at once: the reader thread owns the session's
cwd, variables and aliases without a lock, and a subshell's `cd` has never
moved its parent. Commands that exist to change the session (`cd`, `export`,
`login`, `edit`, …) are refused in the background rather than racing or
silently doing nothing.

Cancellation is cooperative. `kill` sets a flag, and long-running work checks
it between pipeline stages and inside its own loops, so nothing is preempted
mid-write. Disconnecting cancels everything the session started — but the
client is reference-counted, so a job that has not noticed yet cannot write
into freed memory.

**`^C` interrupts whatever is running.** That took an architectural change:
commands used to run on the thread reading the socket, so a long command owned
the connection and the keystroke sat unread until it finished. There was
nothing to press. Each connection now has three threads — a reader, an
executor, a writer — and the reader resolves `^C` itself, because the executor
is inside the very command the interrupt is meant to stop. Anything else in the
same frame still reaches the queue.

With no command running, `^C` is line editing again and simply clears what was
typed.

### Scripts

`sh <file>` runs a file out of the filesystem. Write one with `edit`, make it
say something, run it.

```sh
# count.sh — usage: sh count.sh 5
export N=0
while [ $N -lt $1 ]
do
  echo counting $N
  export N=$(calc $N + 1)
done

for f in *.txt
do
  if [ -s $f ]
  then
    echo "$f has something in it"
  fi
done
```

`if`/`else`/`fi`, `while`/`do`/`done`, `for x in ...`/`do`/`done`, `exit`, and
`test` in both spellings — `test -f x` and `[ -f x ]` are the same command, which
is why the closing bracket is an argument rather than syntax. Arguments arrive
as `$0`..`$9`, with `$#` and `$@`. A `#!` line is a comment, so a script can
carry one harmlessly.

Scripts run in the current shell rather than a child, so a script's `cd` moves
the session — closer to `source` than to running a program. A child would need
its own session state and the only thing it would buy is isolating that `cd`.

Control flow is interpreted over a pre-matched line table rather than parsed
into a tree: blocks are line-oriented, and a jump table is both simpler and
easier to *bound*. Bounding is the point. On a shared server `while true` is
one line away, so a run is capped at 10,000 commands, nesting at 16 levels,
`sh` calling `sh` at 4 deep, and a script is checked for cancellation between
every line — which means a runaway one can be backgrounded and killed like
anything else.

Blocks that do not balance are refused before anything runs. Executing half a
script whose author forgot a `fi` is worse than executing none of it.

### 86 commands

Filesystem
: `ls` `cd` `pwd` `mkdir` `rmdir` `rm` `touch` `cp` `mv` `stat` `chmod` `tree` `find` `du` `df`

Text
: `cat` `edit` `less` `echo` `grep` `head` `tail` `wc` `sort` `uniq` `cut` `tr` `nl` `rev` `tac` `diff` `base64` `md5` `sha256`

Identity
: `register` `login` `logout` `passwd` `whoami` `name` `color` `finger`

Social
: `who` `wall` `msg` `mail` `me` `bell`

System
: `help` `man` `uname` `uptime` `date` `cal` `free` `dmesg` `version` `motd` `neofetch` `clear` `theme` `history` `alias` `unalias` `export` `unset` `env` `ps` `jobs` `kill` `wait` `sleep` `sh` `test` `[` `true` `false` `exit`

Fun
: `fortune` `cowsay` `matrix` `banner` `roll` `8ball` `calc` `clearall`

`help` and `man` are generated from the command table itself, so a command
cannot be added without also being documented. Unknown commands get a
suggestion based on edit distance.

Familiar aliases are built in: `dir` `ll` `type` `del` `md` `cls` `quit` `exit`
`nick` `users` `?` `info`.

### The editor

`edit <file>` opens a full-screen ANSI editor in the terminal — arrows,
Home/End, PgUp/PgDn, `^S` to save, `^Q` or `^X` to quit with an unsaved-changes
confirmation. 2000 lines, 500 columns. It is drawn with ordinary ANSI, so it
needs nothing from the browser that the rest of the terminal does not already
use.

The screen is repainted whole on every keystroke rather than tracked
incrementally. At a few kilobytes a frame that is cheaper than the bookkeeping
it replaces, and it cannot drift out of sync with what the user is looking at.

### Mail

`mail send <user> <text>`, `mail`, `mail read <n>`, `mail clear`. Messages are
delivered into the recipient's `~/mail` as private files: the sender can see
that a mailbox exists but cannot read anything inside it, which is exactly what
the permission model already guaranteed for any other file.

### The filesystem

In-memory, shared, and persisted to `data/vfs.db` every 60 seconds and on
shutdown. Three permission levels per node — public, owner-writable, private —
plus per-user and global quotas on entry count, file size and total bytes.

### The desktop

A window manager over the terminal, toggled from the status bar and remembered
between visits.

Each window holds **its own shell**, not another view of the same one — a second
window is a second session on the server, with its own directory, variables and
history, exactly as opening a second terminal on a real machine gives you a
second shell. They share the filesystem and see each other in `who`.

Windows drag by their title bar, resize from the corner, minimise, maximise and
close; the taskbar switches between them and opens new ones. A window titles
itself with the directory its shell is standing in, which is what makes several
of them tellable apart without reading their contents — the server reports it on
the control channel whenever `cd` moves.

Only geometry is remembered across a reload. The shells themselves live on the
server and are gone the moment the socket closes, so a reload restores the same
arrangement of windows with fresh sessions in them rather than pretending to
restore something it cannot.

Below 720px there is no room for two windows side by side and dragging fights
the scroll, so windows fill the surface and the taskbar becomes the way to
switch — which is what a phone does anyway.

Six windows is the limit. Each one is a connection and a shell; past that it
stops being useful and starts being a way to spend the server's session slots.

### The frontend

`public/` is served straight from disk: `index.html`, one stylesheet, two
scripts, a vendored xterm.js, and a service worker. No framework, no bundler.

`app.js` owns sessions — a terminal plus a socket — and everything shared by
all of them: theme, font size, the matrix overlay, the touch key bar.
`desktop.js` owns windows and never touches a socket. The split is why a
session had to become an object: with a desktop there is no longer "the"
terminal or "the" socket to keep in module scope.

It is a PWA — installable, with an offline page. The layout is a CSS grid using
`dvh` and `env(safe-area-inset-*)`, so it fills a phone screen correctly around
the notch and the on-screen keyboard. Below 60 columns the server itself adapts:
`help` reflows, tables drop columns, the prompt shortens. Touch targets follow
`(hover: none) and (pointer: coarse)`.

A binary WebSocket frame carries an out-of-band control channel in both
directions — terminal size, connected-user count, theme, the matrix overlay —
so control traffic can never be confused with terminal output, in either
direction.

## Security

The whole tree was rewritten with a network-facing threat model: every byte
from a client is attacker-controlled, and any user can be hostile to any other
user.

**Memory safety.** Bounds checking and asserts stay *on* in release builds. For
a server parsing attacker-controlled frames, a bounds panic is a crash; an
unchecked overflow is a memory-corruption bug. `-vet -strict-style` on every
build.

**Everything is bounded.** Request head, header count, frame size, reassembled
message size, per-client queued output, line length, argument count, output
lines, history, pipeline depth, connection count, connections per IP. The
original code read straight into a fixed stack buffer with no limit at all.

**Credentials never appear.** Passwords are entered through a masked prompt
rather than as command arguments, so they are not in the terminal, not in
`history`, and not in anything another user can see. History entries for
credential commands are redacted at the point of storage. The buffers holding a
password are zeroed with a volatile memset before being freed.

**Password storage.** Argon2id, 64 MiB × 3 passes, unique 16-byte salt,
constant-time verification. Concurrent hashes are capped at 2 — memory-hard
hashing is a memory-exhaustion primitive if you let N clients trigger N × 64 MiB
at once.

**Untrusted text has one boundary.** Any string that came from a client and is
going anywhere another user will see — a filename in `ls`, a nickname, a
broadcast, a log line — passes through `sanitize_text`, which strips C0 and C1
control ranges and caps length in *runes*, not bytes. Without it, `wall` is an
arbitrary-escape-sequence injection into every connected terminal.

**Proxy headers are only trusted from the proxy.** `X-Real-IP` and
`X-Forwarded-For` are read only when the peer is loopback, and the value is
still restricted in shape and length. Otherwise every rate limit and every
per-IP cap is bypassable by setting a header.

**Rate limits.** Token buckets on commands, VFS writes, broadcasts and auth
attempts, plus a per-IP connection cap. Broadcasts are the obvious griefing
primitive and are limited to one per five seconds sustained.

**Concurrency.** Three threads per connection — reader, executor, writer — with
bounded queues in both directions — a peer that stops reading gets dropped rather than
pinning a writer. Lock ordering is fixed and documented (`g_clients_lock →
state_lock → out_lock`) so it cannot deadlock.

**Logs are for defenders.** Security-relevant events are logged with abusive
events aggregated over a 60-second window, so a flood produces one summary line
rather than filling the disk on request.

Fixed along the way, among others: a use-after-free that leaked a connection
slot on every disconnect, a TOCTOU on append, a data race on the client table,
three information leaks through error messages and `/healthz`, and an
unauthenticated public bind.

## Layout

```
src/
  main.odin            accept loop, connection lifecycle, broadcast
  http.odin            HTTP/1.1 parsing, static files, origin checks
  ws.odin              RFC 6455 framing, masking, ping/pong
  client.odin          per-connection state and the output queue
  terminal.odin        line editing, history, tab completion
  shell.odin           lexer, pipelines, operators, expansion
  commands*.odin       the command table and its implementations
  editor.odin          full-screen editor
  auth.odin            Argon2id, sessions, the user database
  auth_prompt.odin     masked credential entry and history redaction
  vfs.odin             the in-memory filesystem, permissions, quotas
  persist.odin         snapshot format, atomic replace
  ratelimit.odin       token buckets and per-IP tracking
  control.odin         the binary control channel
  config.odin          every limit, in one place
  log.odin             structured logging and abuse aggregation
  metrics.odin         the Prometheus exposition
  text.odin            sanitisation and formatting helpers
  glob.odin            pattern matching and the glob scan
  process.odin         the process table and background jobs
  script.odin          the script interpreter
  commands_proc.odin   ps, jobs, kill, wait, sleep
  commands_test.odin   test, [, true, false
public/
  app.js               sessions, theme, font, matrix, key bar, mode switching
  desktop.js           the window manager
  style.css, index.html, sw.js, vendor/
tests/                 integration suites and their runner
  browser/             optional Playwright checks for the front end
deploy/                systemd unit, nginx vhost, security headers
data/                  snapshots (created at runtime, 0600)
```

`config.odin` is worth reading first. Every limit in the program is there, with
a comment explaining what goes wrong without it.

## Testing

Two layers, both gating `make deploy`.

`make test` runs the unit tests in `src/webos_test.odin` — path validation and
path-escape resistance, control-character sanitisation, username rules, history
redaction, shell lexing (quoting, deferred expansion, operators, substitutions),
glob matching, control-frame parsing with clamping, formatting, calendar
arithmetic. They cover the pure logic where a mistake is silent rather than
obvious, and where a bug is a security bug rather than a cosmetic one.

`make test-integration` runs the suites in `tests/`, which drive a real
WebSocket client against a private server instance on its own port and data
directory. That is where the framing, the connection lifecycle, the VFS as
several sessions see it at once, and every command end to end are covered.
`./tests/run.sh shell` runs one suite. Each suite gets a freshly started
server, because they create accounts and files under fixed names and a second
run against the same state would collide with the first.

`tests/browser/` holds Playwright checks for the desktop, on a desktop and a
phone viewport. They are deliberately **not** part of `make deploy`: they need
a browser the deployment host is not required to have. Run them by hand when
the front end changes — they are also how the layout screenshots get taken.

## Status

- [x] HTTP/1.1 and WebSocket server, written from scratch
- [x] In-memory VFS with permissions, quotas and disk snapshots
- [x] Accounts: Argon2id, sessions, masked credential entry
- [x] A real shell: pipes, `&&`/`||`/`;`, redirection both ways, quoting,
      variables, aliases, globbing, command substitution
- [x] 86 commands with generated help and man pages
- [x] Full-screen editor
- [x] Mail between accounts
- [x] Responsive frontend, PWA, mobile layout, server-side narrow-terminal support
- [x] Binary control channel
- [x] Security audit and remediation; bounded resources throughout
- [x] Unit tests gating deployment
- [x] Integration suites in the repo, gating deployment
- [x] A process model: background jobs, `jobs`/`kill`/`wait`, a real `ps`
- [x] Scripts stored in the VFS, with arguments and control flow
- [x] Interrupting a foreground command with `^C`
- [ ] Per-user persistent settings beyond the VFS
- [x] `/metrics` for Prometheus, closed to the internet
- [x] A desktop: draggable windows, a taskbar, one shell per window
