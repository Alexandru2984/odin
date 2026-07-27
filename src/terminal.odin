package main

import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Line editor
//
// The old input handling was a 256-byte array with an append-or-backspace
// loop. There was no cursor, so no way to edit anything but the last
// character, and escape sequences were not recognised at all: pressing the up
// arrow inserted the literal bytes 0x1b '[' 'A' into the command buffer.
//
// This is a readline-style editor with cursor movement, word operations,
// history and an escape-sequence state machine that survives being split
// across WebSocket messages.
// ---------------------------------------------------------------------------

// Control characters we act on.
KEY_CTRL_A :: 0x01
KEY_CTRL_B :: 0x02
KEY_CTRL_C :: 0x03
KEY_CTRL_D :: 0x04
KEY_CTRL_E :: 0x05
KEY_CTRL_F :: 0x06
KEY_BACKSPACE_ALT :: 0x08 // Ctrl-H
KEY_TAB :: 0x09
KEY_CTRL_K :: 0x0B
KEY_CTRL_L :: 0x0C
KEY_ENTER :: 0x0D
KEY_CTRL_N :: 0x0E
KEY_CTRL_P :: 0x10
KEY_CTRL_U :: 0x15
KEY_CTRL_W :: 0x17
KEY_ESC :: 0x1B
KEY_BACKSPACE :: 0x7F

handle_input :: proc(c: ^Client, data: string) {
	for i in 0 ..< len(data) {
		ch := data[i]

		// Mid-escape-sequence: keep accumulating.
		if c.esc_len > 0 {
			feed_escape(c, ch)
			continue
		}

		switch ch {
		case KEY_ESC:
			c.esc_buf[0] = ch
			c.esc_len = 1

		case KEY_ENTER, '\n':
			submit_line(c)

		case KEY_BACKSPACE, KEY_BACKSPACE_ALT:
			edit_backspace(c)

		case KEY_TAB:
			handle_autocomplete(c)

		case KEY_CTRL_A:
			edit_move_home(c)

		case KEY_CTRL_E:
			edit_move_end(c)

		case KEY_CTRL_B:
			edit_move_left(c)

		case KEY_CTRL_F:
			edit_move_right(c)

		case KEY_CTRL_C:
			edit_cancel(c)

		case KEY_CTRL_D:
			// Only meaningful on an empty line, where it means "log out".
			if line_len(c) == 0 {
				client_send(c, "logout\r\n")
				ctx := Cmd_Ctx {
					client = c,
				}
				cmd_logout(&ctx, nil)
				client_send_prompt(c)
			} else {
				edit_delete_forward(c)
			}

		case KEY_CTRL_K:
			edit_kill_to_end(c)

		case KEY_CTRL_U:
			edit_kill_to_start(c)

		case KEY_CTRL_W:
			edit_kill_word(c)

		case KEY_CTRL_L:
			client_send(c, "\x1b[2J\x1b[H")
			client_send_prompt(c)

		case KEY_CTRL_P:
			history_prev(c)

		case KEY_CTRL_N:
			history_next(c)

		case:
			if ch >= 0x20 && ch != 0x7F {
				edit_insert(c, ch)
			}
			// Everything else is a control code we do not implement; drop it
			// rather than letting it into the command buffer.
		}
	}
}

// ---------------------------------------------------------------------------
// Escape sequence state machine
// ---------------------------------------------------------------------------

// Accumulates bytes after an ESC until the sequence terminates. Bounded by the
// size of esc_buf so a peer cannot make us buffer indefinitely by sending a
// sequence that never ends.
@(private = "file")
feed_escape :: proc(c: ^Client, ch: byte) {
	if c.esc_len >= len(c.esc_buf) {
		c.esc_len = 0 // malformed or hostile; abandon it
		return
	}

	c.esc_buf[c.esc_len] = ch
	c.esc_len += 1

	seq := string(c.esc_buf[:c.esc_len])

	// "\x1b[" (CSI) and "\x1bO" (SS3) both need at least one more byte.
	if c.esc_len == 2 {
		if ch != '[' && ch != 'O' {
			c.esc_len = 0 // Alt-<key> and friends: ignore
		}
		return
	}

	// A CSI sequence ends at the first byte in 0x40..0x7E.
	if ch >= 0x40 && ch <= 0x7E {
		dispatch_escape(c, seq)
		c.esc_len = 0
	}
}

@(private = "file")
dispatch_escape :: proc(c: ^Client, seq: string) {
	switch seq {
	case "\x1b[A", "\x1bOA":
		history_prev(c)
	case "\x1b[B", "\x1bOB":
		history_next(c)
	case "\x1b[C", "\x1bOC":
		edit_move_right(c)
	case "\x1b[D", "\x1bOD":
		edit_move_left(c)
	case "\x1b[H", "\x1bOH", "\x1b[1~", "\x1b[7~":
		edit_move_home(c)
	case "\x1b[F", "\x1bOF", "\x1b[4~", "\x1b[8~":
		edit_move_end(c)
	case "\x1b[3~":
		edit_delete_forward(c)
	case "\x1b[1;5C", "\x1b[1;5D":
		// Ctrl-arrow: word movement.
		if strings.has_suffix(seq, "C") {
			edit_move_word_right(c)
		} else {
			edit_move_word_left(c)
		}
	}
	// Unrecognised sequences are silently dropped, which is the whole point:
	// they must never reach the command buffer.
}

// ---------------------------------------------------------------------------
// Editing primitives
//
// Each locks state_lock, mutates, builds the redraw, unlocks, then sends.
// state_lock is never held across a command execution or a broadcast, which is
// what keeps the lock ordering (g_clients_lock -> state_lock -> out_lock)
// acyclic.
// ---------------------------------------------------------------------------

line_len :: proc(c: ^Client) -> int {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return len(c.line)
}

@(private = "file")
redraw :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
edit_insert :: proc(c: ^Client, ch: byte) {
	sync.mutex_lock(&c.state_lock)

	if len(c.line) >= MAX_LINE_LEN {
		sync.mutex_unlock(&c.state_lock)
		return
	}

	at_end := c.cursor == len(c.line)
	secret := c.echo_off
	inject(&c.line, c.cursor, ch)
	c.cursor += 1

	if at_end {
		// Fast path: appending only needs the character echoed, which keeps
		// typing responsive on a slow link instead of repainting every key.
		// While collecting a secret the echo is a mask, never the character.
		sync.mutex_unlock(&c.state_lock)
		client_send(c, secret ? "*" : string([]byte{ch}))
		return
	}

	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
inject :: proc(buf: ^[dynamic]byte, at: int, ch: byte) {
	append(buf, 0)
	copy(buf[at + 1:], buf[at:len(buf) - 1])
	buf[at] = ch
}

@(private = "file")
edit_backspace :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	if c.cursor > 0 {
		copy(c.line[c.cursor - 1:], c.line[c.cursor:])
		resize(&c.line, len(c.line) - 1)
		c.cursor -= 1
	}
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
edit_delete_forward :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	if c.cursor < len(c.line) {
		copy(c.line[c.cursor:], c.line[c.cursor + 1:])
		resize(&c.line, len(c.line) - 1)
	}
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
edit_move_left :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	moved := false
	if c.cursor > 0 {
		c.cursor -= 1
		moved = true
	}
	sync.mutex_unlock(&c.state_lock)
	if moved {
		client_send(c, "\x1b[D")
	}
}

@(private = "file")
edit_move_right :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	moved := false
	if c.cursor < len(c.line) {
		c.cursor += 1
		moved = true
	}
	sync.mutex_unlock(&c.state_lock)
	if moved {
		client_send(c, "\x1b[C")
	}
}

@(private = "file")
edit_move_home :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	c.cursor = 0
	sync.mutex_unlock(&c.state_lock)
	redraw(c)
}

@(private = "file")
edit_move_end :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	c.cursor = len(c.line)
	sync.mutex_unlock(&c.state_lock)
	redraw(c)
}

@(private = "file")
edit_move_word_left :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	for c.cursor > 0 && c.line[c.cursor - 1] == ' ' {
		c.cursor -= 1
	}
	for c.cursor > 0 && c.line[c.cursor - 1] != ' ' {
		c.cursor -= 1
	}
	sync.mutex_unlock(&c.state_lock)
	redraw(c)
}

@(private = "file")
edit_move_word_right :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	for c.cursor < len(c.line) && c.line[c.cursor] == ' ' {
		c.cursor += 1
	}
	for c.cursor < len(c.line) && c.line[c.cursor] != ' ' {
		c.cursor += 1
	}
	sync.mutex_unlock(&c.state_lock)
	redraw(c)
}

@(private = "file")
edit_kill_to_end :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	resize(&c.line, c.cursor)
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
edit_kill_to_start :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	if c.cursor > 0 {
		copy(c.line[:], c.line[c.cursor:])
		resize(&c.line, len(c.line) - c.cursor)
		c.cursor = 0
	}
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
edit_kill_word :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	end := c.cursor
	for c.cursor > 0 && c.line[c.cursor - 1] == ' ' {
		c.cursor -= 1
	}
	for c.cursor > 0 && c.line[c.cursor - 1] != ' ' {
		c.cursor -= 1
	}
	if end > c.cursor {
		copy(c.line[c.cursor:], c.line[end:])
		resize(&c.line, len(c.line) - (end - c.cursor))
	}
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
edit_cancel :: proc(c: ^Client) {
	// Ctrl-C during a password prompt abandons the whole sequence rather than
	// just clearing the line, otherwise the session is left masked with no
	// obvious way out.
	if ask_active(c) {
		ask_clear(c)
		client_send(c, "^C\r\n")
		client_send_prompt(c)
		return
	}

	sync.mutex_lock(&c.state_lock)
	clear(&c.line)
	c.cursor = 0
	sync.mutex_unlock(&c.state_lock)

	client_send(c, "^C\r\n")
	c.hist_pos = -1
	client_send_prompt(c)
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

@(private = "file")
set_line :: proc(c: ^Client, text: string) {
	sync.mutex_lock(&c.state_lock)
	clear(&c.line)
	append(&c.line, ..transmute([]byte)text)
	c.cursor = len(c.line)
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
history_prev :: proc(c: ^Client) {
	if len(c.history) == 0 {
		return
	}

	if c.hist_pos == -1 {
		// Stash whatever was being typed so Down can bring it back.
		delete(c.saved_line)
		sync.mutex_lock(&c.state_lock)
		c.saved_line = strings.clone(string(c.line[:]))
		sync.mutex_unlock(&c.state_lock)
		c.hist_pos = len(c.history)
	}

	if c.hist_pos > 0 {
		c.hist_pos -= 1
		set_line(c, c.history[c.hist_pos])
	}
}

@(private = "file")
history_next :: proc(c: ^Client) {
	if c.hist_pos == -1 {
		return
	}

	c.hist_pos += 1
	if c.hist_pos >= len(c.history) {
		c.hist_pos = -1
		set_line(c, c.saved_line)
		return
	}
	set_line(c, c.history[c.hist_pos])
}

@(private = "file")
history_add :: proc(c: ^Client, line: string) {
	if len(strings.trim_space(line)) == 0 {
		return
	}

	// `login alice hunter2` must not be recallable with the Up arrow, nor
	// printable by `history`. What gets stored is the command and the username
	// with the credential replaced.
	entry := redact_for_history(line)

	// Skip consecutive duplicates, like a shell's HISTCONTROL=ignoredups.
	if len(c.history) > 0 && c.history[len(c.history) - 1] == entry {
		delete(entry)
		return
	}

	append(&c.history, entry)

	if len(c.history) > MAX_HISTORY {
		delete(c.history[0])
		ordered_remove(&c.history, 0)
	}
}

// ---------------------------------------------------------------------------
// Submission
// ---------------------------------------------------------------------------

@(private = "file")
submit_line :: proc(c: ^Client) {
	// Take the line out under the lock, then run the command with no locks
	// held. Executing a command can broadcast, which takes g_clients_lock, and
	// doing that while holding state_lock would invert the lock order.
	sync.mutex_lock(&c.state_lock)
	line := strings.clone(string(c.line[:]), context.temp_allocator)
	clear(&c.line)
	c.cursor = 0
	sync.mutex_unlock(&c.state_lock)

	// A masked line must not be echoed back by the newline, and the answer to a
	// prompt is not a command: it goes to whoever asked, never to history or to
	// the interpreter.
	if ask_active(c) {
		client_send(c, "\r\n")
		ask_feed(c, line)
		if !client_is_dead(c) {
			client_send_prompt(c)
		}
		return
	}

	client_send(c, "\r\n")

	c.hist_pos = -1
	history_add(c, line)

	trimmed := strings.trim_space(line)
	if len(trimmed) > 0 {
		if !rate_allow(&c.rl_cmd) {
			client_sendf(
				c,
				"\x1b[31mslow down\x1b[0m (try again in %.1fs)\r\n",
				rate_retry_after(&c.rl_cmd),
			)
		} else {
			execute_command(c, trimmed)
		}
	}

	if !client_is_dead(c) {
		client_send_prompt(c)
	}
}
