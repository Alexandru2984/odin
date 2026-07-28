"""Minimal RFC 6455 client used to drive the WebOS terminal in tests.

Deliberately hand-rolled: the point is to exercise the server's own framing,
including fragmentation, control frames and oversized payloads, which a
high-level library would hide.
"""
import base64
import os
import socket
import struct
import time


class WS:
    def __init__(self, host="127.0.0.1", port=47999, origin="https://odin.micutu.com",
                 path="/ws", timeout=5.0, extra_headers=""):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
        )
        if origin:
            req += f"Origin: {origin}\r\n"
        req += extra_headers
        req += "\r\n"
        self.sock.sendall(req.encode())

        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("closed during handshake")
            self.buf += chunk
        head, _, rest = self.buf.partition(b"\r\n\r\n")
        self.handshake = head.decode(errors="replace")
        self.status = int(self.handshake.split()[1])
        self.buf = rest

    def send(self, data, opcode=0x1):
        if isinstance(data, str):
            data = data.encode()
        header = bytes([0x80 | opcode])
        mask = os.urandom(4)
        n = len(data)
        if n <= 125:
            header += bytes([0x80 | n])
        elif n <= 0xFFFF:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i & 3] for i, b in enumerate(data))
        self.sock.sendall(header + mask + masked)

    def send_raw(self, raw):
        self.sock.sendall(raw)

    def _fill(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError("peer closed")
        self.buf += chunk

    def recv_frame(self):
        """Returns (opcode, payload) for one frame, or None on timeout."""
        while True:
            if len(self.buf) >= 2:
                b0, b1 = self.buf[0], self.buf[1]
                fin = b0 & 0x80
                opcode = b0 & 0x0F
                ln = b1 & 0x7F
                off = 2
                if ln == 126:
                    if len(self.buf) < 4:
                        pass
                    else:
                        ln = struct.unpack(">H", self.buf[2:4])[0]
                        off = 4
                elif ln == 127:
                    if len(self.buf) < 10:
                        pass
                    else:
                        ln = struct.unpack(">Q", self.buf[2:10])[0]
                        off = 10
                if len(self.buf) >= off + ln and not (
                    (b1 & 0x7F) == 126 and len(self.buf) < 4
                ) and not ((b1 & 0x7F) == 127 and len(self.buf) < 10):
                    payload = self.buf[off:off + ln]
                    self.buf = self.buf[off + ln:]
                    return fin, opcode, payload
            try:
                self._fill()
            except socket.timeout:
                return None

    def drain(self, seconds=0.6):
        """Collects text output for a while; returns (text, control_msgs)."""
        text, controls = b"", []
        end = time.time() + seconds
        old = self.sock.gettimeout()
        while time.time() < end:
            self.sock.settimeout(max(0.05, end - time.time()))
            f = self.recv_frame()
            if f is None:
                break
            _, opcode, payload = f
            if opcode == 0x1:
                text += payload
            elif opcode == 0x2:
                controls.append(payload.decode(errors="replace"))
            elif opcode == 0x9:
                self.send(payload, opcode=0xA)
            elif opcode == 0x8:
                code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else None
                controls.append(f"__CLOSE__{code}:{payload[2:].decode(errors='replace')}")
                break
        self.sock.settimeout(old)
        return text.decode(errors="replace"), controls

    def cmd(self, line, wait=0.6):
        """Types a line, presses enter, returns what came back."""
        self.send(line + "\r")
        return self.drain(wait)

    def close(self):
        try:
            self.send(struct.pack(">H", 1000), opcode=0x8)
            self.sock.close()
        except Exception:
            pass


def strip_ansi(s):
    import re
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07", "", s)
