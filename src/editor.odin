package main

import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// A full-screen text editor
//
// "A multi-line text editor" was the first item under Future Ideas in the
// README, and it is the thing the shell most obviously lacked: `echo > file`
// is the only way to put text anywhere, and it cannot revise a line.
//
// This is possible now that the client reports its terminal size — a
// full-screen editor has to know how many rows it is painting into. Everything
// is drawn with ordinary ANSI, so it needs nothing from the browser that the
// rest of the terminal does not already use.
//
// The whole screen is repainted on every keystroke rather than tracked
// incrementally. At a few kilobytes a frame over a local socket that is
// cheaper than the bookkeeping it replaces, and it cannot drift out of sync
// with what the user is actually looking at.
// ---------------------------------------------------------------------------

// Bounds. The buffer is user data heading for the VFS, so it gets the same
// treatment as anything else that arrives from the network.
EDITOR_MAX_LINES     :: 2000
EDITOR_MAX_LINE_LEN  :: 500
EDITOR_MAX_TOTAL     :: VFS_MAX_FILE_SIZE

Editor :: struct {
	active:   bool,
	path:     string, // owned; absolute
	lines:    [dynamic]string, // owned
	cursor_x: int, // byte offset within the current line
	cursor_y: int, // index into lines
	scroll:   int, // first visible line
	modified: bool,
	message:  string, // owned; the status-line notice
	confirm:  bool, // quit was pressed with unsaved changes
	readonly: bool,
}

editor_active :: proc(c: ^Client) -> bool {
	return c.editor.active
}

// ---------------------------------------------------------------------------
// Entering and leaving
// ---------------------------------------------------------------------------

cmd_edit :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		errf(ctx, "edit: usage: edit <file>\n")
		return
	}
	if ctx.capture != nil {
		errf(ctx, "edit: cannot run inside a pipeline\n")
		return
	}

	abs := resolve_arg(c, args[0])
	if err := vfs_validate_path(abs); err != .None {
		errf(ctx, "edit: %s: %s\n", args[0], vfs_error_string(err))
		return
	}
	if vfs_is_dir(&g_vfs, abs) {
		errf(ctx, "edit: %s: %s\n", args[0], vfs_error_string(.Is_A_Directory))
		return
	}

	user := client_get_user(c, context.temp_allocator)

	ed := &c.editor
	ed.active = true
	ed.path = strings.clone(abs)
	ed.lines = make([dynamic]string)
	ed.cursor_x = 0
	ed.cursor_y = 0
	ed.scroll = 0
	ed.modified = false
	ed.confirm = false
	ed.readonly = false

	if content, ok := vfs_read(&g_vfs, abs, user, context.temp_allocator); ok {
		for line in input_lines(content) {
			// Control characters cannot be represented on screen and would let
			// a crafted file drive the cursor while being edited.
			append(&ed.lines, sanitize_text(line, EDITOR_MAX_LINE_LEN))
			if len(ed.lines) >= EDITOR_MAX_LINES {
				break
			}
		}
		ed.message = strings.clone(fmt.tprintf("%d lines", len(ed.lines)))
	} else if vfs_exists(&g_vfs, abs) {
		// It exists but could not be read, which means it is not ours to see.
		ed.readonly = true
		ed.message = strings.clone("permission denied")
	} else {
		ed.message = strings.clone("new file")
	}

	if len(ed.lines) == 0 {
		append(&ed.lines, strings.clone(""))
	}

	editor_render(c)
}

@(private = "file")
editor_close :: proc(c: ^Client) {
	ed := &c.editor

	for line in ed.lines {
		delete(line)
	}
	delete(ed.lines)
	delete(ed.path)
	delete(ed.message)

	ed^ = Editor{}

	// Hand the screen back to the shell.
	client_send(c, "\x1b[2J\x1b[3J\x1b[H")
	client_send_prompt(c)
}

// Releases the editor's memory without touching the socket, for teardown.
editor_destroy :: proc(ed: ^Editor) {
	if !ed.active {
		return
	}
	for line in ed.lines {
		delete(line)
	}
	delete(ed.lines)
	delete(ed.path)
	delete(ed.message)
	ed^ = Editor{}
}

@(private = "file")
editor_set_message :: proc(c: ^Client, text: string) {
	delete(c.editor.message)
	c.editor.message = strings.clone(text)
}

// ---------------------------------------------------------------------------
// Saving
// ---------------------------------------------------------------------------

@(private = "file")
editor_save :: proc(c: ^Client) {
	ed := &c.editor

	if !rate_allow(&c.rl_write) {
		editor_set_message(c, "writing too fast — try again in a moment")
		return
	}

	b := strings.builder_make(context.temp_allocator)
	for line, i in ed.lines {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, line)
	}
	strings.write_byte(&b, '\n')

	content := strings.to_string(b)
	if len(content) > EDITOR_MAX_TOTAL {
		editor_set_message(c, "too large to save")
		return
	}

	user := client_get_user(c, context.temp_allocator)
	if err := vfs_write(&g_vfs, ed.path, content, user); err != .None {
		editor_set_message(c, fmt.tprintf("cannot save: %s", vfs_error_string(err)))
		return
	}

	ed.modified = false
	ed.confirm = false
	editor_set_message(c, fmt.tprintf("saved %d lines, %d bytes", len(ed.lines), len(content)))
}

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

EDITOR_CTRL_Q :: 0x11
EDITOR_CTRL_S :: 0x13
EDITOR_CTRL_X :: 0x18

editor_input :: proc(c: ^Client, data: string) {
	for i in 0 ..< len(data) {
		ch := data[i]

		if c.esc_len > 0 {
			editor_feed_escape(c, ch)
			continue
		}

		switch ch {
		case KEY_ESC:
			c.esc_buf[0] = ch
			c.esc_len = 1

		case KEY_ENTER, '\n':
			editor_newline(c)

		case KEY_BACKSPACE, KEY_BACKSPACE_ALT:
			editor_backspace(c)

		case EDITOR_CTRL_S:
			editor_save(c)

		case EDITOR_CTRL_Q, EDITOR_CTRL_X:
			ed := &c.editor
			if ed.modified && !ed.confirm {
				// One keystroke should not discard work; the second one means it.
				ed.confirm = true
				editor_set_message(c, "unsaved changes — press ^Q again to discard, ^S to save")
				break
			}
			editor_close(c)
			return

		case KEY_CTRL_A:
			c.editor.cursor_x = 0

		case KEY_CTRL_E:
			c.editor.cursor_x = len(c.editor.lines[c.editor.cursor_y])

		case KEY_CTRL_K:
			editor_kill_line(c)

		case KEY_TAB:
			// Tabs cannot be rendered predictably in a fixed grid, so they are
			// spaces. Two of them, because this is mostly used for notes.
			editor_insert(c, ' ')
			editor_insert(c, ' ')

		case:
			if ch >= 0x20 && ch != 0x7F {
				editor_insert(c, ch)
			}
		}

		// Any key other than quit cancels a pending "discard changes?".
		// Clearing it unconditionally would clear the flag the quit key had
		// just set, one statement earlier, and make it impossible ever to
		// leave a modified buffer.
		if ch != EDITOR_CTRL_Q && ch != EDITOR_CTRL_X {
			c.editor.confirm = false
		}
	}

	if c.editor.active {
		editor_render(c)
	}
}

@(private = "file")
editor_feed_escape :: proc(c: ^Client, ch: byte) {
	if c.esc_len >= len(c.esc_buf) {
		c.esc_len = 0
		return
	}

	c.esc_buf[c.esc_len] = ch
	c.esc_len += 1
	seq := string(c.esc_buf[:c.esc_len])

	if c.esc_len == 2 {
		if ch != '[' && ch != 'O' {
			c.esc_len = 0
		}
		return
	}

	if ch >= 0x40 && ch <= 0x7E {
		editor_dispatch_escape(c, seq)
		c.esc_len = 0
	}
}

@(private = "file")
editor_dispatch_escape :: proc(c: ^Client, seq: string) {
	ed := &c.editor

	switch seq {
	case "\x1b[A", "\x1bOA":
		editor_move_up(c)
	case "\x1b[B", "\x1bOB":
		editor_move_down(c)
	case "\x1b[C", "\x1bOC":
		editor_move_right(c)
	case "\x1b[D", "\x1bOD":
		editor_move_left(c)
	case "\x1b[H", "\x1bOH", "\x1b[1~", "\x1b[7~":
		ed.cursor_x = 0
	case "\x1b[F", "\x1bOF", "\x1b[4~", "\x1b[8~":
		ed.cursor_x = len(ed.lines[ed.cursor_y])
	case "\x1b[3~":
		editor_delete_forward(c)
	case "\x1b[5~":
		for _ in 0 ..< editor_page(c) {
			editor_move_up(c)
		}
	case "\x1b[6~":
		for _ in 0 ..< editor_page(c) {
			editor_move_down(c)
		}
	}
}

@(private = "file")
editor_page :: proc(c: ^Client) -> int {
	return max(1, editor_text_rows(c) - 1)
}

// ---------------------------------------------------------------------------
// Editing
// ---------------------------------------------------------------------------

@(private = "file")
editor_insert :: proc(c: ^Client, ch: byte) {
	ed := &c.editor

	line := ed.lines[ed.cursor_y]
	if len(line) >= EDITOR_MAX_LINE_LEN {
		editor_set_message(c, "line is at its maximum length")
		return
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, line[:ed.cursor_x])
	strings.write_byte(&b, ch)
	strings.write_string(&b, line[ed.cursor_x:])

	delete(line)
	ed.lines[ed.cursor_y] = strings.clone(strings.to_string(b))
	ed.cursor_x += 1
	ed.modified = true
}

@(private = "file")
editor_newline :: proc(c: ^Client) {
	ed := &c.editor

	if len(ed.lines) >= EDITOR_MAX_LINES {
		editor_set_message(c, "file is at its maximum length")
		return
	}

	line := ed.lines[ed.cursor_y]
	left := strings.clone(line[:ed.cursor_x])
	right := strings.clone(line[ed.cursor_x:])

	delete(line)
	ed.lines[ed.cursor_y] = left
	inject_at(&ed.lines, ed.cursor_y + 1, right)

	ed.cursor_y += 1
	ed.cursor_x = 0
	ed.modified = true
}

@(private = "file")
editor_backspace :: proc(c: ^Client) {
	ed := &c.editor

	if ed.cursor_x > 0 {
		line := ed.lines[ed.cursor_y]
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, line[:ed.cursor_x - 1])
		strings.write_string(&b, line[ed.cursor_x:])

		delete(line)
		ed.lines[ed.cursor_y] = strings.clone(strings.to_string(b))
		ed.cursor_x -= 1
		ed.modified = true
		return
	}

	// At the start of a line, join it onto the end of the previous one.
	if ed.cursor_y == 0 {
		return
	}

	previous := ed.lines[ed.cursor_y - 1]
	current := ed.lines[ed.cursor_y]

	joined := strings.concatenate({previous, current})
	if len(joined) > EDITOR_MAX_LINE_LEN {
		delete(joined)
		editor_set_message(c, "joining would exceed the maximum line length")
		return
	}

	ed.cursor_x = len(previous)
	delete(previous)
	delete(current)

	ed.lines[ed.cursor_y - 1] = joined
	ordered_remove(&ed.lines, ed.cursor_y)
	ed.cursor_y -= 1
	ed.modified = true
}

@(private = "file")
editor_delete_forward :: proc(c: ^Client) {
	ed := &c.editor
	line := ed.lines[ed.cursor_y]

	if ed.cursor_x < len(line) {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, line[:ed.cursor_x])
		strings.write_string(&b, line[ed.cursor_x + 1:])
		delete(line)
		ed.lines[ed.cursor_y] = strings.clone(strings.to_string(b))
		ed.modified = true
		return
	}

	// At the end of a line, pull the next one up.
	if ed.cursor_y + 1 >= len(ed.lines) {
		return
	}
	next := ed.lines[ed.cursor_y + 1]
	joined := strings.concatenate({line, next})
	if len(joined) > EDITOR_MAX_LINE_LEN {
		delete(joined)
		return
	}
	delete(line)
	delete(next)
	ed.lines[ed.cursor_y] = joined
	ordered_remove(&ed.lines, ed.cursor_y + 1)
	ed.modified = true
}

@(private = "file")
editor_kill_line :: proc(c: ^Client) {
	ed := &c.editor
	line := ed.lines[ed.cursor_y]

	// First press clears to end of line; on an already-empty tail, remove the
	// line itself. That is what makes repeated ^K delete a block.
	if ed.cursor_x < len(line) {
		truncated := strings.clone(line[:ed.cursor_x])
		delete(line)
		ed.lines[ed.cursor_y] = truncated
		ed.modified = true
		return
	}

	if len(ed.lines) == 1 {
		return
	}

	delete(line)
	ordered_remove(&ed.lines, ed.cursor_y)
	if ed.cursor_y >= len(ed.lines) {
		ed.cursor_y = len(ed.lines) - 1
	}
	ed.cursor_x = min(ed.cursor_x, len(ed.lines[ed.cursor_y]))
	ed.modified = true
}

@(private = "file")
inject_at :: proc(lines: ^[dynamic]string, at: int, value: string) {
	append(lines, value)
	for i := len(lines) - 1; i > at; i -= 1 {
		lines[i] = lines[i - 1]
	}
	lines[at] = value
}

// ---------------------------------------------------------------------------
// Movement
// ---------------------------------------------------------------------------

@(private = "file")
editor_move_up :: proc(c: ^Client) {
	ed := &c.editor
	if ed.cursor_y == 0 {
		ed.cursor_x = 0
		return
	}
	ed.cursor_y -= 1
	ed.cursor_x = min(ed.cursor_x, len(ed.lines[ed.cursor_y]))
}

@(private = "file")
editor_move_down :: proc(c: ^Client) {
	ed := &c.editor
	if ed.cursor_y + 1 >= len(ed.lines) {
		ed.cursor_x = len(ed.lines[ed.cursor_y])
		return
	}
	ed.cursor_y += 1
	ed.cursor_x = min(ed.cursor_x, len(ed.lines[ed.cursor_y]))
}

@(private = "file")
editor_move_left :: proc(c: ^Client) {
	ed := &c.editor
	if ed.cursor_x > 0 {
		ed.cursor_x -= 1
		return
	}
	if ed.cursor_y > 0 {
		ed.cursor_y -= 1
		ed.cursor_x = len(ed.lines[ed.cursor_y])
	}
}

@(private = "file")
editor_move_right :: proc(c: ^Client) {
	ed := &c.editor
	if ed.cursor_x < len(ed.lines[ed.cursor_y]) {
		ed.cursor_x += 1
		return
	}
	if ed.cursor_y + 1 < len(ed.lines) {
		ed.cursor_y += 1
		ed.cursor_x = 0
	}
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

// Rows available for text: everything except the title and status lines.
@(private = "file")
editor_text_rows :: proc(c: ^Client) -> int {
	return max(1, client_rows(c) - 2)
}

@(private = "file")
editor_render :: proc(c: ^Client) {
	ed := &c.editor

	cols := client_cols(c)
	text_rows := editor_text_rows(c)

	// Keep the cursor on screen.
	if ed.cursor_y < ed.scroll {
		ed.scroll = ed.cursor_y
	}
	if ed.cursor_y >= ed.scroll + text_rows {
		ed.scroll = ed.cursor_y - text_rows + 1
	}
	if ed.scroll < 0 {
		ed.scroll = 0
	}

	// Line numbers take a fixed gutter, sized to the largest number shown.
	gutter := 4
	if len(ed.lines) >= 1000 {
		gutter = 5
	}
	text_width := max(8, cols - gutter - 1)

	b := strings.builder_make(context.temp_allocator)

	strings.write_string(&b, "\x1b[H\x1b[2J") // home, clear

	// Title line.
	name := ed.path
	if len(name) > cols - 18 && cols > 24 {
		name = name[len(name) - (cols - 18):]
	}
	fmt.sbprintf(
		&b,
		"\x1b[7m %-*s%s \x1b[0m\r\n",
		max(1, cols - 12),
		name,
		ed.modified ? "  modified" : "          ",
	)

	// Text area.
	cursor_screen_row := 0
	cursor_screen_col := 0

	for row in 0 ..< text_rows {
		index := ed.scroll + row

		if index >= len(ed.lines) {
			strings.write_string(&b, "\x1b[90m   ~\x1b[0m\r\n")
			continue
		}

		line := ed.lines[index]

		// Horizontal scroll, so a long line does not wrap and confuse the
		// row arithmetic.
		start := 0
		if index == ed.cursor_y && ed.cursor_x >= text_width {
			start = ed.cursor_x - text_width + 1
		}
		visible := line[start:]
		if len(visible) > text_width {
			visible = visible[:text_width]
		}

		fmt.sbprintf(&b, "\x1b[90m%s\x1b[0m ", pad_int(index + 1, gutter))
		strings.write_string(&b, visible)
		strings.write_string(&b, "\r\n")

		if index == ed.cursor_y {
			cursor_screen_row = row + 2 // 1-based, and the title takes row 1
			cursor_screen_col = gutter + 2 + (ed.cursor_x - start)
		}
	}

	// Status line.
	status := ed.message
	if len(status) == 0 {
		status = "^S save   ^Q quit   ^K cut line"
	}
	position := fmt.tprintf("%d:%d", ed.cursor_y + 1, ed.cursor_x + 1)

	room := max(1, cols - len(position) - 2)
	if len(status) > room {
		status = status[:room]
	}
	fmt.sbprintf(&b, "\x1b[7m %-*s%s \x1b[0m", room, status, position)

	// Put the terminal's cursor where the editing cursor is.
	fmt.sbprintf(&b, "\x1b[%d;%dH", cursor_screen_row, cursor_screen_col)

	client_send(c, strings.to_string(b))
}

// ---------------------------------------------------------------------------
// A read-only pager, which shares the editor's idea of the screen.
// ---------------------------------------------------------------------------

cmd_less :: proc(ctx: ^Cmd_Ctx, args: []string) {
	content, ok := gather_input(ctx, "less", args)
	if !ok {
		return
	}

	// Without a screen to page into — inside a pipeline — this is just cat.
	if ctx.capture != nil {
		out(ctx, content)
		return
	}

	rows := client_rows(ctx.client)
	lines := input_lines(content)

	if len(lines) <= rows - 2 {
		for line in lines {
			outf(ctx, "%s\n", sanitize_text(line, 500, context.temp_allocator))
		}
		return
	}

	// Anything longer opens in the editor, which already knows how to scroll.
	// A read-only mode would be a separate code path; letting it be editable
	// is more useful, and the permission check on save is the same either way.
	if len(args) > 0 {
		cmd_edit(ctx, args)
		return
	}

	// Piped input has no file behind it, so there is nothing to open: print it
	// and let the terminal's own scrollback do the paging.
	for line in lines {
		outf(ctx, "%s\n", sanitize_text(line, 500, context.temp_allocator))
	}
}
