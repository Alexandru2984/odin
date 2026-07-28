package main

import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// Fuzzing
//
// Every parser in this program reads bytes an anonymous peer chose. The unit
// tests next door check that each one handles the inputs its author thought
// of; this file checks what happens for the ones nobody thought of.
//
// Two things are being looked for. A crash is the obvious one — bounds
// checking stays on in release builds precisely so an out-of-range read is a
// panic the test runner catches rather than a silent misread. The other is an
// invariant: a parser can return perfectly calmly and still hand back a path
// that escapes the document root, or a length that overruns its own buffer.
// Those are asserted per target below, and they are the reason this is worth
// more than throwing random bytes at the thing.
//
// The generator is a fixed-seed PRNG written out in full rather than
// core:math/rand, so a failure reproduces exactly: the seed and the iteration
// count are the whole state. Runs are bounded so this stays part of
// `make test` — a fuzzer that only runs when someone remembers to run it is a
// fuzzer that finds things after the deploy rather than before it.
// ---------------------------------------------------------------------------

FUZZ_SEED :: 0x5EED_1234_ABCD_0001
FUZZ_ITERATIONS :: 3000

// ---------------------------------------------------------------------------
// Generator
// ---------------------------------------------------------------------------

@(private = "file")
Rng :: struct {
	state: u64,
}

@(private = "file")
rng_make :: proc(seed: u64) -> Rng {
	// xorshift64 stalls forever on zero, so a seed of zero is not allowed to
	// silently produce a constant stream.
	return Rng{state = seed == 0 ? 1 : seed}
}

@(private = "file")
rng_next :: proc(r: ^Rng) -> u64 {
	x := r.state
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	r.state = x
	return x
}

@(private = "file")
rng_below :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

@(private = "file")
rng_byte :: proc(r: ^Rng) -> byte {
	return byte(rng_next(r) & 0xFF)
}

// Values that sit on a boundary somewhere: terminators, sign bits, length
// markers. Random bytes reach these rarely; most parser bugs live on them.
@(private = "file")
@(rodata)
INTERESTING := [?]byte {
	0x00,
	0x01,
	0x09,
	0x0A,
	0x0D,
	0x1B,
	0x20,
	0x25,
	0x2E,
	0x2F,
	0x3A,
	0x5C,
	0x7E,
	0x7F,
	0x80,
	0x81,
	0xC0,
	0xFE,
	0xFF,
}

// Produces a variant of `seed`. Mutation from a valid starting point rather
// than pure noise: a random buffer almost never survives the first length
// check, so pure noise would only ever test the rejection path.
@(private = "file")
mutate :: proc(r: ^Rng, seed: []byte, allocator := context.temp_allocator) -> []byte {
	MAX_LEN :: 4096

	buf := make([dynamic]byte, allocator)
	append(&buf, ..seed)

	rounds := 1 + rng_below(r, 4)
	for _ in 0 ..< rounds {
		switch rng_below(r, 7) {
		case 0:
			// Flip one bit.
			if len(buf) > 0 {
				i := rng_below(r, len(buf))
				buf[i] ~= byte(1) << u8(rng_below(r, 8))
			}

		case 1:
			// Replace a byte with noise.
			if len(buf) > 0 {
				buf[rng_below(r, len(buf))] = rng_byte(r)
			}

		case 2:
			// Replace a byte with a boundary value.
			if len(buf) > 0 {
				buf[rng_below(r, len(buf))] = INTERESTING[rng_below(r, len(INTERESTING))]
			}

		case 3:
			// Truncate. Catches every "read past the end of a short buffer".
			if len(buf) > 1 {
				resize(&buf, rng_below(r, len(buf)))
			}

		case 4:
			// Insert a byte somewhere, shifting everything after it.
			if len(buf) < MAX_LEN {
				at := rng_below(r, len(buf) + 1)
				inject_at(&buf, at, rng_byte(r))
			}

		case 5:
			// Delete a byte.
			if len(buf) > 0 {
				ordered_remove(&buf, rng_below(r, len(buf)))
			}

		case 6:
			// Repeat a chunk, which is how a length field and the bytes behind
			// it get out of step.
			if len(buf) > 2 && len(buf) * 2 < MAX_LEN {
				start := rng_below(r, len(buf))
				n := 1 + rng_below(r, min(64, len(buf) - start))
				chunk := make([]byte, n, allocator)
				copy(chunk, buf[start:start + n])
				append(&buf, ..chunk)
			}
		}
	}

	return buf[:]
}

// ---------------------------------------------------------------------------
// WebSocket framing
// ---------------------------------------------------------------------------

// Builds a well-formed client frame to mutate from.
@(private = "file")
make_frame :: proc(
	opcode: byte,
	payload: []byte,
	masked: bool,
	allocator := context.temp_allocator,
) -> []byte {
	buf := make([dynamic]byte, allocator)
	append(&buf, 0x80 | opcode)

	n := len(payload)
	mask_bit: byte = masked ? 0x80 : 0
	switch {
	case n < 126:
		append(&buf, mask_bit | byte(n))
	case n < 65536:
		append(&buf, mask_bit | 126)
		append(&buf, byte(n >> 8), byte(n))
	case:
		append(&buf, mask_bit | 127)
		for shift := 56; shift >= 0; shift -= 8 {
			append(&buf, byte(n >> u8(shift)))
		}
	}

	key := [4]byte{0xA1, 0xB2, 0xC3, 0xD4}
	if masked {
		append(&buf, ..key[:])
	}
	for b, i in payload {
		append(&buf, masked ? b ~ key[i & 3] : b)
	}
	return buf[:]
}

// Valid opcodes and reserved ones, so the refusal path is exercised too.
@(private = "file")
@(rodata)
FUZZ_OPCODES := [?]byte{0x0, 0x1, 0x2, 0x8, 0x9, 0xA, 0x3, 0xB, 0xF}

// Lengths chosen around the points where the encoding changes shape: 125 is
// the last one-byte length, 126 switches to the 16-bit field.
@(private = "file")
@(rodata)
FUZZ_LENGTHS := [?]int{0, 1, 125, 126, 127, 128, 255, 256, 1000}

// Builds a frame from randomised *fields* rather than randomised bytes.
//
// Byte-level mutation alone turned out to be nearly useless here: measured
// over 3000 iterations it produced a frame the parser accepted 15 times. Bit
// flips land on the reserved bits or the mask bit, both of which are rejected
// in the first few lines, so the interesting code — extended lengths,
// unmasking, payload extraction — was almost never reached. Generating a
// well-formed frame and then corrupting a little gets past the front door.
@(private = "file")
random_frame :: proc(r: ^Rng, allocator := context.temp_allocator) -> []byte {
	opcode := FUZZ_OPCODES[rng_below(r, len(FUZZ_OPCODES))]
	n := FUZZ_LENGTHS[rng_below(r, len(FUZZ_LENGTHS))]

	payload := make([]byte, n, allocator)
	for i in 0 ..< n {
		payload[i] = rng_byte(r)
	}

	// Mostly masked, because that is what a conforming client sends and what
	// the unmasking path needs; sometimes not, to keep testing the refusal.
	frame := make_frame(opcode, payload, rng_below(r, 8) != 0, allocator)

	// A light corruption on top, so this still explores rather than only
	// confirming that well-formed frames parse.
	if rng_below(r, 3) == 0 && len(frame) > 0 {
		buf := make([dynamic]byte, allocator)
		append(&buf, ..frame)
		buf[rng_below(r, len(buf))] = rng_byte(r)
		return buf[:]
	}
	return frame
}

@(test)
test_fuzz_ws_frame_parser :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED)

	corpus := [][]byte {
		make_frame(0x1, transmute([]byte)string("hello"), true),
		make_frame(0x2, transmute([]byte)string("\x00\x01\x02"), true),
		make_frame(0x8, transmute([]byte)string("\x03\xe8bye"), true),
		make_frame(0x9, nil, true),
		make_frame(0xA, nil, true),
		make_frame(0x0, transmute([]byte)string("continued"), true),
		// Long enough to use the 16-bit length field.
		make_frame(0x1, transmute([]byte)strings.repeat("x", 300, context.temp_allocator), true),
		// Unmasked, which a server must refuse from a client.
		make_frame(0x1, transmute([]byte)string("nomask"), false),
	}

	accepted := 0

	for i in 0 ..< FUZZ_ITERATIONS {
		// Half from the structured generator, half from byte-level mutation:
		// the first reaches the payload handling, the second finds the things
		// that only go wrong on a malformed header.
		data: []byte
		if i % 2 == 0 {
			data = random_frame(&r)
		} else {
			data = mutate(&r, corpus[rng_below(&r, len(corpus))])
		}

		// ws_parse_frame unmasks in place, so every call gets its own copy —
		// otherwise the second iteration would be parsing the first one's
		// output rather than what the generator produced.
		scratch := make([]byte, len(data), context.temp_allocator)
		copy(scratch, data)

		frame, consumed, err := ws_parse_frame(scratch)
		if err == .None && consumed > 0 {
			accepted += 1
		}

		testing.expectf(
			t,
			consumed >= 0 && consumed <= len(scratch),
			"consumed %d of a %d byte buffer at iteration %d",
			consumed,
			len(scratch),
			i,
		)

		if err == .None && consumed > 0 {
			// The payload is documented as borrowed from the input. A slice
			// pointing past the end of it would be read by the caller as if it
			// were frame data.
			testing.expectf(
				t,
				len(frame.payload) <= consumed,
				"payload of %d bytes from a %d byte frame at iteration %d",
				len(frame.payload),
				consumed,
				i,
			)
		}

		// A frame that parses must parse the same way twice: anything else
		// means the result depends on something outside the input.
		again := make([]byte, len(data), context.temp_allocator)
		copy(again, data)
		_, consumed2, err2 := ws_parse_frame(again)
		testing.expectf(t, consumed == consumed2 && err == err2, "not deterministic at %d", i)

		free_all(context.temp_allocator)
	}

	// A fuzzer that stops reaching its target stops testing anything, and it
	// does so silently — the run still passes either way. Asserting the
	// acceptance rate turns that from something to remember to check into
	// something that fails the build.
	//
	// The bar sits between two measured numbers. Byte-level mutation alone got
	// 15 of 3000 past the header checks; the generator above gets around 580,
	// the gap between that and a third of the runs being the reserved opcodes
	// and unmasked frames it produces deliberately. A tenth is comfortably
	// under what it achieves and far above what a collapse would leave.
	testing.expectf(
		t,
		accepted > FUZZ_ITERATIONS / 10,
		"only %d of %d inputs parsed — the generator is no longer reaching the parser",
		accepted,
		FUZZ_ITERATIONS,
	)
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

@(test)
test_fuzz_http_request_head :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 1)

	corpus := [][]byte {
		transmute([]byte)string("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"),
		transmute([]byte)string(
			"GET /ws HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n" +
			"Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
			"Sec-WebSocket-Version: 13\r\nOrigin: https://odin.micutu.com\r\n\r\n",
		),
		transmute([]byte)string("HEAD /style.css HTTP/1.1\r\nHost: a\r\nX-Real-IP: 1.2.3.4\r\n\r\n"),
		transmute([]byte)string("POST /metrics HTTP/1.0\r\n\r\n"),
		transmute([]byte)string(""),
	}

	accepted := 0

	for i in 0 ..< FUZZ_ITERATIONS {
		seed := corpus[rng_below(&r, len(corpus))]
		data := mutate(&r, seed)

		req, ok := http_parse_head(string(data))

		if ok {
			accepted += 1
			// A parse that succeeded must not claim more headers than the
			// program is willing to hold; everything downstream indexes this.
			testing.expectf(
				t,
				len(req.headers) <= MAX_HEADER_COUNT,
				"accepted %d headers at iteration %d",
				len(req.headers),
				i,
			)
			// Looking a header up must never fault, whatever the parse made.
			_ = http_header(&req, "host")
			_ = http_header(&req, "sec-websocket-key")
			_ = http_header(&req, "")
		}

		free_all(context.temp_allocator)
	}

	// Same guard as the frame parser: measured at around 2600 of 3000, so a
	// tenth means the generator has stopped producing anything parseable.
	testing.expectf(
		t,
		accepted > FUZZ_ITERATIONS / 10,
		"only %d of %d inputs parsed as a request head",
		accepted,
		FUZZ_ITERATIONS,
	)
}

@(test)
test_fuzz_static_path_cannot_escape :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 2)

	corpus := [][]byte {
		transmute([]byte)string("/"),
		transmute([]byte)string("/index.html"),
		transmute([]byte)string("/vendor/xterm.js"),
		transmute([]byte)string("/style.css?v=2"),
		transmute([]byte)string("/../../etc/passwd"),
		transmute([]byte)string("/%2e%2e%2f%2e%2e%2fetc/passwd"),
		transmute([]byte)string("/a/./b/../c"),
		transmute([]byte)string("/.hidden"),
		transmute([]byte)string("//double"),
		transmute([]byte)string("/a%00b"),
	}

	accepted := 0

	for i in 0 ..< FUZZ_ITERATIONS {
		seed := corpus[rng_below(&r, len(corpus))]
		data := mutate(&r, seed)

		file_path, ok := resolve_static_path(string(data), context.temp_allocator)
		if !ok {
			free_all(context.temp_allocator)
			continue
		}
		accepted += 1

		// The security property, stated directly: anything this returns is
		// opened and sent to whoever asked.
		testing.expectf(
			t,
			strings.has_prefix(file_path, PUBLIC_DIR),
			"escaped the document root: %q at iteration %d",
			file_path,
			i,
		)
		testing.expectf(
			t,
			!strings.contains(file_path, ".."),
			"parent reference survived: %q at iteration %d",
			file_path,
			i,
		)
		testing.expectf(
			t,
			!strings.contains(file_path, "\x00"),
			"NUL survived into a path: %q at iteration %d",
			file_path,
			i,
		)

		free_all(context.temp_allocator)
	}

	// The invariants above only say anything about paths that resolved, so a
	// run where nothing resolves proves nothing. Measured at around 1150.
	testing.expectf(
		t,
		accepted > FUZZ_ITERATIONS / 10,
		"only %d of %d inputs resolved to a servable path",
		accepted,
		FUZZ_ITERATIONS,
	)
}

@(test)
test_fuzz_percent_decode :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 3)

	corpus := [][]byte {
		transmute([]byte)string("/plain/path"),
		transmute([]byte)string("/a%20b"),
		transmute([]byte)string("%41%42%43"),
		transmute([]byte)string("%"),
		transmute([]byte)string("%zz"),
		transmute([]byte)string("%2"),
	}

	for i in 0 ..< FUZZ_ITERATIONS {
		seed := corpus[rng_below(&r, len(corpus))]
		data := mutate(&r, seed)

		out, ok := percent_decode(string(data), context.temp_allocator)
		if ok {
			// Decoding only ever collapses three bytes into one.
			testing.expectf(
				t,
				len(out) <= len(data),
				"decode grew %d bytes into %d at iteration %d",
				len(data),
				len(out),
				i,
			)
		}

		free_all(context.temp_allocator)
	}
}

// ---------------------------------------------------------------------------
// The shell and the filesystem
// ---------------------------------------------------------------------------

@(test)
test_fuzz_shell_lexer :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 4)

	corpus := [][]byte {
		transmute([]byte)string("echo hello | grep h > out.txt"),
		transmute([]byte)string("a && b || c ; d"),
		transmute([]byte)string(`echo "quoted $VAR" 'single'`),
		transmute([]byte)string("echo $(date) $(echo $(nested))"),
		transmute([]byte)string("ls *.txt file[0-9]? < in.txt &"),
		transmute([]byte)string("export A=1 # a comment"),
		transmute([]byte)string(`echo \" \\ \$`),
	}

	accepted := 0

	for i in 0 ..< FUZZ_ITERATIONS {
		seed := corpus[rng_below(&r, len(corpus))]
		data := mutate(&r, seed)

		tokens, err := shell_lex(string(data), context.temp_allocator)
		if err == .None {
			accepted += 1
			testing.expectf(
				t,
				len(tokens) <= MAX_ARGS + 1,
				"lexed %d tokens at iteration %d",
				len(tokens),
				i,
			)
			for tok in tokens {
				testing.expectf(
					t,
					len(tok.text) <= MAX_EXPANSION,
					"token of %d bytes at iteration %d",
					len(tok.text),
					i,
				)
			}
		}

		free_all(context.temp_allocator)
	}

	// Measured at around 2350 of 3000.
	testing.expectf(
		t,
		accepted > FUZZ_ITERATIONS / 10,
		"only %d of %d inputs lexed cleanly",
		accepted,
		FUZZ_ITERATIONS,
	)
}

@(test)
test_fuzz_path_resolution_stays_rooted :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 5)

	cwds := [?]string{"/", "/tmp", "/home/alice", "/home/alice/mail"}
	corpus := [][]byte {
		transmute([]byte)string("file.txt"),
		transmute([]byte)string("../.."),
		transmute([]byte)string("../../../../etc/passwd"),
		transmute([]byte)string("/absolute/path"),
		transmute([]byte)string("./a/./b/../c"),
		transmute([]byte)string(".."),
		transmute([]byte)string("a//b///c"),
	}

	for i in 0 ..< FUZZ_ITERATIONS {
		seed := corpus[rng_below(&r, len(corpus))]
		data := mutate(&r, seed)
		cwd := cwds[rng_below(&r, len(cwds))]

		got := vfs_resolve_path(cwd, string(data), context.temp_allocator)

		// Whatever went in, what comes out is an absolute path with no parent
		// references left in it. Everything the VFS does is keyed on this.
		testing.expectf(t, len(got) > 0, "empty resolution at iteration %d", i)
		testing.expectf(
			t,
			strings.has_prefix(got, "/"),
			"resolved to a relative path %q at iteration %d",
			got,
			i,
		)
		testing.expectf(
			t,
			!strings.contains(got, "/../") && !strings.has_suffix(got, "/.."),
			"parent reference survived resolution: %q at iteration %d",
			got,
			i,
		)

		// And validation must be able to decide about it without faulting.
		_ = vfs_validate_path(got)

		free_all(context.temp_allocator)
	}
}

@(test)
test_fuzz_sanitize_never_emits_controls :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 6)

	corpus := [][]byte {
		transmute([]byte)string("ordinary text"),
		transmute([]byte)string("\x1b[2J\x1b[1;31mred\x1b[0m"),
		transmute([]byte)string("bell\x07 and a \x00 nul"),
		transmute([]byte)string("ăîșțâ multi-byte"),
		transmute([]byte)string("\xc2\x9b csi"),
	}

	for i in 0 ..< FUZZ_ITERATIONS {
		seed := corpus[rng_below(&r, len(corpus))]
		data := mutate(&r, seed)
		limit := 1 + rng_below(&r, 200)

		out := sanitize_text(string(data), limit, context.temp_allocator)

		// This is the boundary that stops one user painting into everyone
		// else's terminal, so nothing below 0x20 may survive it.
		for j in 0 ..< len(out) {
			testing.expectf(
				t,
				out[j] >= 0x20 || out[j] == 0x0A,
				"control byte 0x%02x survived at iteration %d",
				out[j],
				i,
			)
		}

		// The cap counts runes, and an over-long result would be a way to push
		// a wide line into a table that assumed it fit.
		testing.expectf(
			t,
			strings.rune_count(out) <= limit,
			"produced %d runes for a limit of %d at iteration %d",
			strings.rune_count(out),
			limit,
			i,
		)

		free_all(context.temp_allocator)
	}
}

@(test)
test_fuzz_glob_matcher_terminates :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 7)

	patterns := [][]byte {
		transmute([]byte)string("*"),
		transmute([]byte)string("*.txt"),
		transmute([]byte)string("a*b*c*d"),
		transmute([]byte)string("[a-z]*[0-9]"),
		transmute([]byte)string("[!abc]?"),
		transmute([]byte)string("a*a*a*a*a*a*b"),
		transmute([]byte)string("[unterminated"),
	}
	names := [][]byte {
		transmute([]byte)string("notes.txt"),
		transmute([]byte)string("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
		transmute([]byte)string(".hidden"),
		transmute([]byte)string(""),
	}

	// Reaching this line at all is most of the test: the matcher is iterative
	// with one backtrack point precisely so a pattern like `a*a*a*a*b` cannot
	// take exponential time, and a regression there would hang here rather
	// than fail.
	for i in 0 ..< FUZZ_ITERATIONS {
		pattern := mutate(&r, patterns[rng_below(&r, len(patterns))])
		name := mutate(&r, names[rng_below(&r, len(names))])

		_ = glob_match_segment(string(pattern), string(name))

		// A pattern with no magic in it matches only itself.
		if !has_glob_magic(string(pattern)) {
			testing.expectf(
				t,
				glob_match_segment(string(pattern), string(pattern)),
				"a literal pattern failed to match itself at iteration %d",
				i,
			)
		}

		free_all(context.temp_allocator)
	}
}

// ---------------------------------------------------------------------------
// The client control channel
// ---------------------------------------------------------------------------

@(test)
test_fuzz_control_messages_stay_clamped :: proc(t: ^testing.T) {
	r := rng_make(FUZZ_SEED + 8)

	corpus := [][]byte {
		transmute([]byte)string(`{"t":"size","cols":80,"rows":24}`),
		transmute([]byte)string(`{"t":"size","cols":100000,"rows":-5}`),
		transmute([]byte)string(`{"t":"unknown"}`),
		transmute([]byte)string(`{"t":`),
		transmute([]byte)string(`not json`),
		transmute([]byte)string(``),
	}

	c: Client
	c.cols = DEFAULT_TERM_COLS
	c.rows = DEFAULT_TERM_ROWS

	for i in 0 ..< FUZZ_ITERATIONS {
		seed := corpus[rng_below(&r, len(corpus))]
		data := mutate(&r, seed)

		handle_client_control(&c, data)

		// Whatever arrives, the size the server formats against has to stay
		// inside the range every table layout assumes.
		testing.expectf(
			t,
			c.cols >= MIN_TERM_COLS && c.cols <= MAX_TERM_COLS,
			"cols left the clamp: %d at iteration %d",
			c.cols,
			i,
		)
		testing.expectf(
			t,
			c.rows >= MIN_TERM_ROWS && c.rows <= MAX_TERM_ROWS,
			"rows left the clamp: %d at iteration %d",
			c.rows,
			i,
		)

		free_all(context.temp_allocator)
	}
}
