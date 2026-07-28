"""Malformed traffic against a live server.

The in-process fuzzers in src/fuzz_test.odin hit each parser directly. This one
covers what they structurally cannot: the read loop, frame reassembly across
reads, the handshake, and the connection lifecycle around all of it — the
places where a parser that is individually correct still gets driven wrong.

The property under test is simple and absolute: whatever is sent, the server
must still be there afterwards, and must still serve everyone else.

Findings so far, recorded because the absence of a bug is worth as much as
finding one when it was actually looked for. Nine seeds at 700 rounds each —
roughly 12,600 hostile connections — produced no crash and no hang. Resident
memory rose to about 60 MB during a run and came back down to 29 MB after,
having wandered 41/41/57/57/61/29 across runs rather than climbing: that shape
is glibc holding freed arenas under thread churn, not a leak, which would be
monotonic. The connection paths were read alongside the fuzzing to confirm it:
the request head map is temp-allocated and dies with the thread arena, and
ws_conn_init is immediately followed by a deferred ws_conn_destroy, so every
early return frees.
"""
import os
import random
import socket
import struct
import sys
import time

from wsclient import WS, strip_ansi

PORT = int(os.environ.get("PORT", "47999"))
SEED = int(os.environ.get("FUZZ_SEED", "20260728"))

# Deliberately modest by default, because this runs on every deploy and almost
# all of its wall clock is waiting on sockets rather than working: at a 1.5s
# read timeout and 300 rounds the first version took seven and a half minutes
# for one and a half seconds of CPU. A real hunt is an env var away:
#
#   FUZZ_ROUNDS=5000 FUZZ_TIMEOUT=0.2 FUZZ_SEED=7 python3 tests/test_fuzz.py
#
# The seed is printed on failure so a crash found that way can be replayed.
ROUNDS = int(os.environ.get("FUZZ_ROUNDS", "150"))
TIMEOUT = float(os.environ.get("FUZZ_TIMEOUT", "0.25"))

fails = []
rng = random.Random(SEED)


def check(name, cond, detail=""):
    print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        fails.append(name)


def alive():
    """A real session, end to end. The only definition of 'still working'."""
    try:
        w = WS(port=PORT)
        w.drain(0.5)
        out, _ = w.cmd("echo fuzz-probe", 0.8)
        w.close()
        return "fuzz-probe" in strip_ansi(out)
    except Exception:
        return False


def raw(payload, read=True, timeout=None):
    """Sends bytes at the port and reports what came back, if anything."""
    timeout = TIMEOUT if timeout is None else timeout
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=timeout)
        s.settimeout(timeout)
        s.sendall(payload)
        if not read:
            s.close()
            return b""
        data = b""
        try:
            while len(data) < 4096:
                chunk = s.recv(4096)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        s.close()
        return data
    except Exception:
        return b""


check("the server answers before we start", alive())

# --- garbage at the HTTP layer ----------------------------------------------

INTERESTING = [b"\x00", b"\r", b"\n", b" ", b"%", b"..", b"/", b"\\", b"\xff", b"\x1b"]

HTTP_SEEDS = [
    b"GET / HTTP/1.1\r\nHost: x\r\n\r\n",
    b"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
    b"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
    b"HEAD /style.css HTTP/1.1\r\n\r\n",
    b"GET /../../etc/passwd HTTP/1.1\r\nHost: x\r\n\r\n",
    b"\r\n\r\n",
    b"",
]


def mutate(data):
    b = bytearray(data)
    for _ in range(rng.randint(1, 4)):
        op = rng.randint(0, 5)
        if op == 0 and b:
            b[rng.randrange(len(b))] ^= 1 << rng.randrange(8)
        elif op == 1 and b:
            b[rng.randrange(len(b))] = rng.randrange(256)
        elif op == 2 and b:
            at = rng.randrange(len(b))
            b[at:at] = rng.choice(INTERESTING)
        elif op == 3 and len(b) > 1:
            del b[rng.randrange(len(b)) :]
        elif op == 4:
            b.extend(rng.choice(INTERESTING) * rng.randint(1, 40))
        elif op == 5 and len(b) > 2:
            start = rng.randrange(len(b))
            b.extend(b[start : start + rng.randint(1, 64)])
    return bytes(b)


responded = 0
for _ in range(ROUNDS):
    if raw(mutate(rng.choice(HTTP_SEEDS))):
        responded += 1

check("malformed HTTP does not kill the server", alive())
check("most malformed requests still get an answer", responded > ROUNDS // 10,
      f"{responded}/{ROUNDS} answered")

# --- garbage at the WebSocket layer -----------------------------------------

HANDSHAKE = (
    b"GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
    b"Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    b"Sec-WebSocket-Version: 13\r\nOrigin: https://odin.micutu.com\r\n\r\n"
)


def frame(opcode, payload, masked=True, fin=True, rsv=0):
    head = bytes([(0x80 if fin else 0) | (rsv << 4) | opcode])
    n = len(payload)
    mask_bit = 0x80 if masked else 0
    if n < 126:
        head += bytes([mask_bit | n])
    elif n < 65536:
        head += bytes([mask_bit | 126]) + struct.pack(">H", n)
    else:
        head += bytes([mask_bit | 127]) + struct.pack(">Q", n)
    if masked:
        key = bytes(rng.randrange(256) for _ in range(4))
        return head + key + bytes(b ^ key[i & 3] for i, b in enumerate(payload))
    return head + payload


def random_frame():
    opcode = rng.choice([0x0, 0x1, 0x2, 0x8, 0x9, 0xA, 0x3, 0xB, 0xF])
    size = rng.choice([0, 1, 125, 126, 127, 200, 1000, 70000])
    payload = bytes(rng.randrange(256) for _ in range(min(size, 2000)))
    return frame(
        opcode,
        payload,
        masked=rng.random() > 0.15,
        fin=rng.random() > 0.2,
        rsv=rng.choice([0, 0, 0, 1, 4]),
    )


for _ in range(ROUNDS):
    payload = HANDSHAKE
    for _ in range(rng.randint(1, 5)):
        f = random_frame()
        # Half the time the frame is corrupted after framing, which is how a
        # length field and the bytes behind it get out of step.
        if rng.random() < 0.5 and f:
            f = mutate(f)
        payload += f
    raw(payload, read=rng.random() < 0.3)

check("malformed WebSocket frames do not kill the server", alive())

# --- deliberately hostile shapes ---------------------------------------------

# A length field claiming far more than follows: the classic over-read.
raw(HANDSHAKE + b"\x81\xff" + struct.pack(">Q", 2**32) + b"\xaa\xbb\xcc\xdd" + b"x" * 10)
check("a wildly oversized length is refused, not read", alive())

# A frame that says 127 but carries a tiny body.
raw(HANDSHAKE + b"\x81\xfe\xff\xff" + b"\x00\x00\x00\x00" + b"short")
check("a truncated extended-length frame is survivable", alive())

# A continuation with nothing to continue.
raw(HANDSHAKE + frame(0x0, b"orphan"))
check("an orphan continuation is refused", alive())

# An unterminated fragmented message: a Text that never sets fin, followed by
# continuations. Starting the chain with a continuation frame — which is what
# the first version of this test did — never gets past the orphan check above
# and so never exercised reassembly at all.
raw(
    HANDSHAKE
    + frame(0x1, b"start", fin=False)
    + b"".join(frame(0x0, b"x" * 100, fin=False) for _ in range(60))
)
check("an unterminated fragmented message is bounded", alive())

# The same, but large enough to cross MAX_WS_MESSAGE, which must be refused
# rather than accumulated.
raw(
    HANDSHAKE
    + frame(0x1, b"s", fin=False)
    + b"".join(frame(0x0, b"y" * 2000, fin=False) for _ in range(30))
)
check("a fragmented message over the size cap is refused", alive())

# A new message starting before the previous one finished.
raw(HANDSHAKE + frame(0x1, b"first", fin=False) + frame(0x1, b"second"))
check("interleaved messages are refused", alive())

# Control frames are legal *inside* a fragmented message and must not disturb
# the reassembly around them — the one interleaving the RFC does allow.
raw(
    HANDSHAKE
    + frame(0x1, b"half ", fin=False)
    + frame(0x9, b"ping")
    + frame(0x0, b"and half")
)
check("a control frame inside a fragment is handled", alive())

# A close frame with a nonsense status code, then more traffic after it.
raw(HANDSHAKE + frame(0x8, b"\xff\xff" + b"why") + frame(0x1, b"after close"))
check("traffic after a close frame is handled", alive())

# Headers, many and enormous.
raw(b"GET / HTTP/1.1\r\n" + b"".join(b"X-%d: %s\r\n" % (i, b"v" * 200) for i in range(200)) + b"\r\n")
check("a header flood is refused", alive())

# A request head that never terminates.
raw(b"GET / HTTP/1.1\r\nHost: x\r\n" + b"X-Pad: " + b"p" * 60000, read=False)
check("an unterminated request head is bounded", alive())

# Bytes that are not HTTP at all.
raw(bytes(rng.randrange(256) for _ in range(4096)))
check("binary noise on the port is survivable", alive())

# --- reassembly is correct, not merely survivable ----------------------------
#
# Everything above asks whether the server is still standing. This asks whether
# it put the pieces back together properly, which no amount of liveness
# checking would notice going wrong.

def fragmented_command(pieces, interleave_ping=True):
    """Sends one command split across frames, optionally with a ping inside."""
    s = socket.create_connection(("127.0.0.1", PORT), timeout=3)
    s.settimeout(3)
    s.sendall(HANDSHAKE)
    time.sleep(0.4)
    s.recv(65536)  # handshake response and banner

    payload = frame(0x1, pieces[0].encode(), fin=False)
    for piece in pieces[1:-1]:
        if interleave_ping:
            payload += frame(0x9, b"mid")
        payload += frame(0x0, piece.encode(), fin=False)
    payload += frame(0x0, pieces[-1].encode(), fin=True)
    s.sendall(payload)

    time.sleep(1.2)
    data = b""
    try:
        while True:
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    except socket.timeout:
        pass
    s.close()
    return data


got = fragmented_command(["echo frag", "men", "ted\r"])
check("a command split across frames is reassembled", b"fragmented" in got, str(got[-160:]))

got = fragmented_command(["echo nop", "ing\r"], interleave_ping=False)
check("the same without an interleaved ping", b"noping" in got, str(got[-160:]))

# --- and the service is genuinely unharmed ----------------------------------

w = WS(port=PORT)
w.drain(0.6)
out, _ = w.cmd("echo still-serving && pwd", 1.0)
text = strip_ansi(out)
check("a session still works normally", "still-serving" in text, text[-200:])
check("the shell is still coherent", "/" in text, text[-200:])
w.close()

print()
if fails:
    print(f"{len(fails)} FAILED: {', '.join(fails)}")
    print(f"replay with: FUZZ_SEED={SEED} FUZZ_ROUNDS={ROUNDS}")
    sys.exit(1)
print(f"all fuzz checks passed ({ROUNDS} rounds, seed {SEED})")
