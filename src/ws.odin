package main

import "core:encoding/endian"
import "core:net"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// RFC 6455 WebSocket framing
//
// The previous implementation was not a WebSocket parser in any meaningful
// sense. It looked at one recv() buffer, assumed exactly one frame started at
// byte 0, ignored the opcode entirely (so ping, pong, close and binary frames
// were all fed to the command interpreter as text), computed an offset for the
// 126/127 extended-length forms but then never actually read the extended
// length field, and used the recv() return value as the end of the payload.
//
// The consequences: any message split across TCP segments was corrupted, any
// two messages coalesced into one segment were concatenated, a payload above
// ~4 KiB was silently truncated, and the browser's close and ping frames were
// executed as terminal commands.
//
// This is a real parser: incremental, buffered across reads, opcode-aware,
// with fragmentation support and an explicit limit on every length field.
// ---------------------------------------------------------------------------

WS_Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

// RFC 6455 section 7.4.1 status codes.
WS_Close_Code :: enum u16 {
	Normal           = 1000,
	Going_Away       = 1001,
	Protocol_Error   = 1002,
	Unsupported      = 1003,
	Invalid_Payload  = 1007,
	Policy_Violation = 1008,
	Too_Large        = 1009,
	Internal_Error   = 1011,
}

WS_Error :: enum {
	None,
	Closed,          // peer closed cleanly, or the transport ended
	Timeout,         // recv deadline elapsed; the connection is still healthy
	Protocol,        // malformed frame, must close with 1002
	Too_Large,       // exceeded a configured limit, must close with 1009
	Invalid_Payload, // text frame was not valid UTF-8, must close with 1007
	Transport,       // socket error
}

WS_Message :: struct {
	opcode:  WS_Opcode,
	payload: []byte, // borrowed, valid until the next ws_read_message call
}

WS_Conn :: struct {
	socket: net.TCP_Socket,

	// Bytes received but not yet consumed by the frame parser. Frames are
	// parsed out of here and the remainder compacted to the front, which is
	// what makes reassembly across TCP segment boundaries work.
	rbuf: [dynamic]byte,

	// Reassembly buffer for fragmented messages (FIN=0 plus continuations).
	msg:        [dynamic]byte,
	msg_opcode: WS_Opcode,
	in_message: bool,
}

ws_conn_init :: proc(c: ^WS_Conn, socket: net.TCP_Socket) {
	c.socket = socket
	c.rbuf = make([dynamic]byte, 0, 4096)
	c.msg = make([dynamic]byte, 0, 1024)
}

ws_conn_destroy :: proc(c: ^WS_Conn) {
	delete(c.rbuf)
	delete(c.msg)
}

@(private = "file")
ws_is_control :: proc(op: WS_Opcode) -> bool {
	return u8(op) & 0x08 != 0
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

// Reads one complete application message, transparently handling
// fragmentation. Control frames are returned to the caller as they arrive,
// because how to answer them is a policy decision.
//
// The returned payload borrows the connection's internal buffer and is valid
// only until the next call.
ws_read_message :: proc(c: ^WS_Conn) -> (msg: WS_Message, err: WS_Error) {
	for {
		// Satisfy the request from what is already buffered before going back
		// to the socket.
		frame, consumed, perr := ws_parse_frame(c.rbuf[:])
		if perr != .None {
			return {}, perr
		}

		if consumed == 0 {
			if rerr := ws_fill(c); rerr != .None {
				return {}, rerr
			}
			continue
		}

		// Control frames may be interleaved inside a fragmented message and
		// are never themselves fragmented, so handle them before reassembly.
		if ws_is_control(frame.opcode) {
			op := frame.opcode
			// Copy out before compacting: compaction moves the bytes that the
			// payload slice points at.
			ctl := make([]byte, len(frame.payload), context.temp_allocator)
			copy(ctl, frame.payload)
			ws_consume(c, consumed)
			return WS_Message{opcode = op, payload = ctl}, .None
		}

		switch frame.opcode {
		case .Continuation:
			if !c.in_message {
				return {}, .Protocol // continuation with nothing to continue
			}
			if len(c.msg) + len(frame.payload) > MAX_WS_MESSAGE {
				return {}, .Too_Large
			}
			append(&c.msg, ..frame.payload)

		case .Text, .Binary:
			if c.in_message {
				return {}, .Protocol // new message before the previous finished
			}
			if len(frame.payload) > MAX_WS_MESSAGE {
				return {}, .Too_Large
			}
			clear(&c.msg)
			append(&c.msg, ..frame.payload)
			c.msg_opcode = frame.opcode
			c.in_message = true

		case .Close, .Ping, .Pong:
			unreachable()
		}

		fin := frame.fin
		ws_consume(c, consumed)

		if fin {
			c.in_message = false
			if c.msg_opcode == .Text && !utf8.valid_string(string(c.msg[:])) {
				return {}, .Invalid_Payload
			}
			return WS_Message{opcode = c.msg_opcode, payload = c.msg[:]}, .None
		}
	}
}

// Reads more bytes from the socket into rbuf.
@(private = "file")
ws_fill :: proc(c: ^WS_Conn) -> WS_Error {
	// A peer must not be able to make us allocate indefinitely by starting a
	// frame it never completes.
	if len(c.rbuf) > MAX_WS_FRAME + 64 {
		return .Too_Large
	}

	tmp: [8192]byte
	n, rerr := net.recv_tcp(c.socket, tmp[:])
	if rerr != nil {
		#partial switch rerr {
		case .Timeout, .Would_Block, .Interrupted:
			// The poll deadline elapsed. This is the normal path: it is how the
			// session loop wakes up to send keepalives.
			return .Timeout
		case .Connection_Closed, .Not_Connected:
			return .Closed
		}
		return .Transport
	}
	if n == 0 {
		return .Closed // graceful close
	}

	append(&c.rbuf, ..tmp[:n])
	return .None
}

// Drops `n` parsed bytes from the front of rbuf.
@(private = "file")
ws_consume :: proc(c: ^WS_Conn, n: int) {
	if n >= len(c.rbuf) {
		clear(&c.rbuf)
		return
	}
	copy(c.rbuf[:], c.rbuf[n:])
	resize(&c.rbuf, len(c.rbuf) - n)
}

WS_Parsed_Frame :: struct {
	fin:     bool,
	opcode:  WS_Opcode,
	payload: []byte, // unmasked in place, borrowed from `data`
}

// Parses a single frame from the front of `data`.
//
// consumed == 0 with err == .None means the buffer does not yet hold a
// complete frame; the caller reads more and retries.
//
// Unmasking happens in place, so `data` must be mutable and the returned
// payload aliases it.
ws_parse_frame :: proc(data: []byte) -> (frame: WS_Parsed_Frame, consumed: int, err: WS_Error) {
	if len(data) < 2 {
		return {}, 0, .None
	}

	b0 := data[0]
	b1 := data[1]

	fin := (b0 & 0x80) != 0
	rsv := b0 & 0x70
	opcode_bits := b0 & 0x0F
	masked := (b1 & 0x80) != 0
	len_bits := int(b1 & 0x7F)

	// No extensions are negotiated during the handshake, so a set reserved bit
	// is a protocol violation rather than something to skip over.
	if rsv != 0 {
		return {}, 0, .Protocol
	}

	opcode: WS_Opcode
	switch opcode_bits {
	case 0x0:
		opcode = .Continuation
	case 0x1:
		opcode = .Text
	case 0x2:
		opcode = .Binary
	case 0x8:
		opcode = .Close
	case 0x9:
		opcode = .Ping
	case 0xA:
		opcode = .Pong
	case:
		return {}, 0, .Protocol // reserved opcode
	}

	// RFC 6455 section 5.5: control frames are never fragmented and carry at
	// most 125 bytes.
	if opcode_bits & 0x08 != 0 {
		if !fin || len_bits > 125 {
			return {}, 0, .Protocol
		}
	}

	offset := 2
	payload_len := 0

	switch len_bits {
	case 126:
		if len(data) < offset + 2 {
			return {}, 0, .None
		}
		v, _ := endian.get_u16(data[offset:offset + 2], .Big)
		// The spec requires the shortest possible length encoding.
		if v < 126 {
			return {}, 0, .Protocol
		}
		payload_len = int(v)
		offset += 2

	case 127:
		if len(data) < offset + 8 {
			return {}, 0, .None
		}
		v, _ := endian.get_u64(data[offset:offset + 8], .Big)
		// The high bit must be clear (section 5.2). Check the value before
		// narrowing it to int so the conversion cannot wrap.
		if v & 0x8000_0000_0000_0000 != 0 {
			return {}, 0, .Protocol
		}
		if v <= 0xFFFF {
			return {}, 0, .Protocol // non-minimal encoding
		}
		if v > u64(MAX_WS_FRAME) {
			return {}, 0, .Too_Large
		}
		payload_len = int(v)
		offset += 8

	case:
		payload_len = len_bits
	}

	if payload_len > MAX_WS_FRAME {
		return {}, 0, .Too_Large
	}

	// RFC 6455 section 5.1: every frame sent by a client must be masked.
	if !masked {
		return {}, 0, .Protocol
	}

	if len(data) < offset + 4 {
		return {}, 0, .None
	}
	mask_key := data[offset:offset + 4]
	offset += 4

	if len(data) < offset + payload_len {
		return {}, 0, .None // payload still in flight
	}

	payload := data[offset:offset + payload_len]
	for i in 0 ..< len(payload) {
		payload[i] ~= mask_key[i & 3]
	}

	return WS_Parsed_Frame{fin = fin, opcode = opcode, payload = payload},
		offset + payload_len,
		.None
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// Encodes a server to client frame. Server frames are never masked
// (section 5.1). The result is a fresh allocation owned by the caller.
ws_encode_frame :: proc(
	opcode: WS_Opcode,
	payload: []byte,
	allocator := context.allocator,
) -> []byte {
	header_len: int
	switch {
	case len(payload) <= 125:
		header_len = 2
	case len(payload) <= 0xFFFF:
		header_len = 4
	case:
		header_len = 10
	}

	out := make([]byte, header_len + len(payload), allocator)
	out[0] = 0x80 | u8(opcode) // FIN set; outbound messages are never fragmented

	switch header_len {
	case 2:
		out[1] = u8(len(payload))
	case 4:
		out[1] = 126
		endian.put_u16(out[2:4], .Big, u16(len(payload)))
	case 10:
		out[1] = 127
		endian.put_u64(out[2:10], .Big, u64(len(payload)))
	}

	copy(out[header_len:], payload)
	return out
}

ws_encode_text :: proc(s: string, allocator := context.allocator) -> []byte {
	return ws_encode_frame(.Text, transmute([]byte)s, allocator)
}

ws_encode_close :: proc(
	code: WS_Close_Code,
	reason: string,
	allocator := context.allocator,
) -> []byte {
	// Close payload: a 2-byte big-endian status code followed by an optional
	// UTF-8 reason, all within the 125-byte control frame limit.
	reason_bytes := transmute([]byte)reason
	if len(reason_bytes) > 123 {
		reason_bytes = reason_bytes[:123]
	}

	buf := make([]byte, 2 + len(reason_bytes), context.temp_allocator)
	endian.put_u16(buf[0:2], .Big, u16(code))
	copy(buf[2:], reason_bytes)

	return ws_encode_frame(.Close, buf, allocator)
}

// Writes all of `data`, resuming across partial writes.
//
// net.send_tcp loops internally, but with a send timeout configured it can
// still return early having written some bytes. Resuming from that offset is
// mandatory: restarting the write would duplicate part of a frame and
// desynchronise the peer's parser.
send_all :: proc(socket: net.TCP_Socket, data: []byte) -> bool {
	sent := 0
	stalls := 0

	for sent < len(data) {
		n, err := net.send_tcp(socket, data[sent:])
		sent += n

		if err != nil {
			if n > 0 {
				stalls = 0 // progress was made, keep going
				continue
			}
			#partial switch err {
			case .Timeout, .Would_Block, .Interrupted:
				stalls += 1
				// A peer that accepts nothing across several consecutive write
				// timeouts is not reading. Drop it instead of letting it pin a
				// writer thread indefinitely.
				if stalls >= 3 {
					return false
				}
				continue
			}
			return false
		}
	}
	return true
}
