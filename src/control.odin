package main

import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Control messages from the client
//
// The client reports its terminal size the way a real terminal signals
// SIGWINCH, so output can be laid out for the screen it is going to. Without
// it the server formats every table for an assumed width, and `help` on a
// phone wraps into unreadable ribbon.
//
// This is a deliberately tiny reader for the one message shape the client
// sends, not a general JSON parser. The payload is attacker-controlled: a full
// parser would be a great deal more code to get right, for no benefit, since
// the only thing that ever needs reading is two integers.
// ---------------------------------------------------------------------------

// Bounds on a reported size. A client claiming 100000 columns would otherwise
// have the server allocate padding to match.
MIN_TERM_COLS :: 20
MAX_TERM_COLS :: 500
MIN_TERM_ROWS :: 4
MAX_TERM_ROWS :: 200

DEFAULT_TERM_COLS :: 80
DEFAULT_TERM_ROWS :: 24

handle_client_control :: proc(c: ^Client, payload: []byte) {
	text := string(payload)

	// Anything that is not the one message type we understand is ignored
	// rather than being an error: an older or newer client should not have its
	// session closed for saying something unexpected.
	if !json_has_type(text, "size") {
		return
	}

	cols, cols_ok := json_int_field(text, "cols")
	rows, rows_ok := json_int_field(text, "rows")
	if !cols_ok || !rows_ok {
		return
	}

	client_set_size(c, cols, rows)
}

// True if the message's "t" field equals `want`.
@(private = "file")
json_has_type :: proc(text: string, want: string) -> bool {
	needle := strings.concatenate({"\"t\":\"", want, "\""}, context.temp_allocator)
	if strings.contains(text, needle) {
		return true
	}
	// Tolerate a space after the colon, which is what a pretty-printer emits.
	spaced := strings.concatenate({"\"t\": \"", want, "\""}, context.temp_allocator)
	return strings.contains(text, spaced)
}

// Reads a non-negative integer field. Returns false unless the value is
// entirely digits, so "cols":1e9 or "cols":"80" are both rejected rather than
// partially parsed.
@(private = "file")
json_int_field :: proc(text: string, key: string) -> (value: int, ok: bool) {
	needle := strings.concatenate({"\"", key, "\":"}, context.temp_allocator)

	at := strings.index(text, needle)
	if at < 0 {
		return 0, false
	}

	i := at + len(needle)
	for i < len(text) && (text[i] == ' ' || text[i] == '\t') {
		i += 1
	}

	start := i
	for i < len(text) && text[i] >= '0' && text[i] <= '9' {
		i += 1
		// Far more digits than any legitimate value; stop rather than overflow.
		if i - start > 6 {
			return 0, false
		}
	}
	if i == start {
		return 0, false
	}

	n := 0
	for j in start ..< i {
		n = n * 10 + int(text[j] - '0')
	}
	return n, true
}

// ---------------------------------------------------------------------------
// Terminal size
// ---------------------------------------------------------------------------

client_set_size :: proc(c: ^Client, cols: int, rows: int) {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)

	c.cols = clamp_int(cols, MIN_TERM_COLS, MAX_TERM_COLS)
	c.rows = clamp_int(rows, MIN_TERM_ROWS, MAX_TERM_ROWS)
}

client_cols :: proc(c: ^Client) -> int {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return c.cols
}

client_rows :: proc(c: ^Client) -> int {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return c.rows
}

// The width a command should format for. Output being captured into a file or
// a pipe has no width at all, so it uses a fixed one — otherwise a file's
// contents would depend on the window size of whoever created it.
ctx_width :: proc(ctx: ^Cmd_Ctx) -> int {
	if ctx.capture != nil {
		return DEFAULT_TERM_COLS
	}
	return client_cols(ctx.client)
}

// True when the target is narrow enough that side-by-side columns stop being
// readable and stacked output is better.
ctx_is_narrow :: proc(ctx: ^Cmd_Ctx) -> bool {
	return ctx_width(ctx) < 60
}

clamp_int :: proc(v: int, lo: int, hi: int) -> int {
	return min(hi, max(lo, v))
}
