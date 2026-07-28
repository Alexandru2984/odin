package main

import "base:intrinsics"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// ---------------------------------------------------------------------------
// Client connection state
//
// The single most important change here is that sending is asynchronous.
//
// Previously broadcast_message() called a blocking send_tcp() while holding
// the global client list mutex. One client that stopped reading (a paused tab,
// a phone that lost signal, or an attacker deliberately not draining its
// socket) would fill its kernel send buffer, block that send, and freeze every
// other user's terminal for as long as it stayed connected. A single client
// could take the whole service down with no traffic at all.
//
// Now each connection owns a bounded output queue and a dedicated writer
// thread. Broadcasting only appends bytes to those queues, which never blocks.
// A client that will not drain simply fills its own queue and gets
// disconnected, affecting nobody else.
// ---------------------------------------------------------------------------

Client :: struct {
	id:     int,
	socket: net.TCP_Socket,
	ip:     string, // owned

	// --- Output queue -------------------------------------------------------
	// Guarded by out_lock. Holds fully framed WebSocket bytes ready to write.
	out_lock:    sync.Mutex,
	out_cond:    sync.Cond,
	out:         [dynamic]byte,
	out_closed:  bool, // reader finished, writer should drain and exit
	out_overflow: bool, // queue limit hit, connection must be dropped
	dead:        bool, // transport failed, both threads should unwind

	// --- Session state ------------------------------------------------------
	// Guarded by state_lock. Read by other threads during broadcast, so every
	// field here is owned heap memory with a strictly defined lifetime.
	//
	// The old code stored client.color as a slice into client.input_buffer and
	// commented that it was "a static literal string slice so we don't clone
	// it". It was not: it aliased a buffer that changed on every keystroke and
	// was freed when the client disconnected, while other threads read it
	// concurrently during broadcasts.
	state_lock: sync.Mutex,
	name:       string, // owned
	color:      string, // owned, always an escape parameter from the COLORS table
	cwd:        string, // owned
	user:       string, // owned, "" when not authenticated

	// Current input line, kept under state_lock so an async broadcast can
	// redraw it instead of destroying what the user was typing.
	line:   [dynamic]byte,
	cursor: int,

	// Set while a command is collecting a value rather than a command line.
	// Both are read by the redraw path, so they belong with the line state:
	// a broadcast arriving mid-password must redraw the masked line and the
	// "Password:" label, not the shell prompt and the plain text.
	echo_off:     bool,
	prompt_label: string, // owned; "" means the normal shell prompt

	// The client's terminal size, as it last reported it. Read while
	// formatting output, which can happen on another thread during a
	// broadcast, so it lives under the same lock.
	cols: int,
	rows: int,

	// --- Reader-thread-private state ----------------------------------------
	history:    [dynamic]string,
	hist_pos:   int,
	saved_line: string, // owned, line stashed while browsing history

	// Session variables and the status of the last pipeline. Both are touched
	// only by the reader thread, which is the only thread that runs commands,
	// so they need no lock.
	vars:        map[string]string, // owned keys and values
	aliases:     map[string]string, // owned keys and values
	last_status: int,
	// How many `$( )` levels are currently on the stack. Same thread, same
	// reasoning: only the command runner touches it.
	subst_depth: int,

	// How many things still hold this pointer: the connection itself, plus one
	// for every background job it started. The last one to let go frees it.
	//
	// Without this a job that outlives its session writes into freed memory,
	// and the session's teardown cannot simply wait for it: a job is only
	// guaranteed to stop at its next cancellation check, and a command that
	// never checks would pin the connection thread forever.
	refs:        int,

	// The full-screen editor, when one is open. Reader-thread private: only
	// the thread running commands ever touches it.
	editor: Editor,

	// Which value an interactive prompt is waiting for, and what it has
	// collected so far. Wiped by ask_clear rather than simply freed.
	ask_state: Ask_State,
	ask_user:  string, // owned
	ask_pass:  string, // owned

	// Partial ANSI escape sequence. Terminals emit these as several bytes and
	// a WebSocket message can split them anywhere, so the state machine has to
	// persist across reads.
	esc_buf: [16]byte,
	esc_len: int,

	rl_cmd:       Rate_Bucket,
	rl_write:     Rate_Bucket,
	rl_broadcast: Rate_Bucket,
	rl_auth:      Rate_Bucket,

	connected_at:  time.Time,
	last_activity: time.Time,

	writer_thread: ^thread.Thread,
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

client_init :: proc(c: ^Client, socket: net.TCP_Socket, id: int, ip: string) {
	c.id = id
	c.socket = socket
	c.ip = strings.clone(ip)
	c.refs = 1 // the connection's own reference

	c.out = make([dynamic]byte, 0, 4096)
	c.line = make([dynamic]byte, 0, 128)
	c.history = make([dynamic]string, 0, 16)
	c.hist_pos = -1
	c.vars = make(map[string]string)
	c.aliases = make(map[string]string)

	// Assume a conventional terminal until the client says otherwise, so the
	// welcome banner is laid out sensibly even before the first size report.
	c.cols = DEFAULT_TERM_COLS
	c.rows = DEFAULT_TERM_ROWS

	c.name = fmt.aprintf("guest%d", id)
	c.color = strings.clone("32") // green
	c.cwd = strings.clone("/")
	c.user = strings.clone("")

	rate_init(&c.rl_cmd, RATE_CMD_PER_SEC, RATE_CMD_BURST)
	rate_init(&c.rl_write, RATE_WRITE_PER_SEC, RATE_WRITE_BURST)
	rate_init(&c.rl_broadcast, RATE_BROADCAST_PER_SEC, RATE_BROADCAST_BURST)
	rate_init(&c.rl_auth, RATE_AUTH_PER_SEC, RATE_AUTH_BURST)

	now := time.now()
	c.connected_at = now
	c.last_activity = now
}

// Takes a reference. Every caller must pair it with client_unref.
client_ref :: proc(c: ^Client) {
	intrinsics.atomic_add(&c.refs, 1)
}

// Releases a reference, freeing the client when the last one goes.
client_unref :: proc(c: ^Client) {
	// atomic_sub returns the value before the subtraction, so 1 means this
	// call took the count to zero.
	if intrinsics.atomic_sub(&c.refs, 1) == 1 {
		client_destroy(c)
		free(c)
	}
}

client_destroy :: proc(c: ^Client) {
	editor_destroy(&c.editor)

	// Credentials in flight are wiped, not just released.
	secure_delete(c.ask_user)
	secure_delete(c.ask_pass)

	delete(c.ip)
	delete(c.out)
	delete(c.line)
	delete(c.name)
	delete(c.color)
	delete(c.cwd)
	delete(c.user)
	delete(c.saved_line)
	delete(c.prompt_label)

	for h in c.history {
		delete(h)
	}
	delete(c.history)

	for key, value in c.vars {
		delete(key)
		delete(value)
	}
	delete(c.vars)

	for key, value in c.aliases {
		delete(key)
		delete(value)
	}
	delete(c.aliases)
}

// ---------------------------------------------------------------------------
// Output queue
// ---------------------------------------------------------------------------

// Appends already-framed bytes to the queue. Never blocks on I/O.
//
// Returns false if the queue is full, which marks the client for disconnection.
// Dropping a client that will not read is the entire point: it bounds memory
// per connection and stops a slow peer from becoming everyone else's problem.
client_enqueue :: proc(c: ^Client, framed: []byte) -> bool {
	sync.mutex_lock(&c.out_lock)
	defer sync.mutex_unlock(&c.out_lock)

	if c.out_closed || c.out_overflow || c.dead {
		return false
	}

	if len(c.out) + len(framed) > MAX_OUT_PENDING {
		c.out_overflow = true
		sync.cond_signal(&c.out_cond)
		return false
	}

	append(&c.out, ..framed)
	sync.cond_signal(&c.out_cond)
	return true
}

// Frames `s` as a text message and queues it.
client_send :: proc(c: ^Client, s: string) {
	if len(s) == 0 {
		return
	}
	framed := ws_encode_text(s, context.temp_allocator)
	client_enqueue(c, framed)
}

client_sendf :: proc(c: ^Client, format: string, args: ..any) {
	s := fmt.tprintf(format, ..args)
	client_send(c, s)
}

// Queues a close frame and stops accepting further output.
client_close :: proc(c: ^Client, code: WS_Close_Code, reason: string) {
	framed := ws_encode_close(code, reason, context.temp_allocator)

	sync.mutex_lock(&c.out_lock)
	if !c.out_closed && !c.dead && len(c.out) + len(framed) <= MAX_OUT_PENDING {
		append(&c.out, ..framed)
	}
	c.out_closed = true
	sync.cond_signal(&c.out_cond)
	sync.mutex_unlock(&c.out_lock)
}

client_mark_dead :: proc(c: ^Client) {
	sync.mutex_lock(&c.out_lock)
	c.dead = true
	sync.cond_signal(&c.out_cond)
	sync.mutex_unlock(&c.out_lock)

	// Wake the reader thread, which is otherwise parked in recv() for up to
	// WS_POLL_TIMEOUT, so the connection unwinds promptly.
	net.shutdown(c.socket, .Both)
}

client_is_dead :: proc(c: ^Client) -> bool {
	sync.mutex_lock(&c.out_lock)
	defer sync.mutex_unlock(&c.out_lock)
	return c.dead || c.out_overflow
}

// Writer thread: drains the output queue onto the socket.
client_writer_proc :: proc(t: ^thread.Thread) {
	c := cast(^Client)t.data

	// Scratch buffer swapped with the queue so the socket write happens
	// without holding out_lock.
	scratch := make([dynamic]byte, 0, 4096)
	defer delete(scratch)

	for {
		sync.mutex_lock(&c.out_lock)
		for len(c.out) == 0 && !c.out_closed && !c.out_overflow && !c.dead {
			sync.cond_wait(&c.out_cond, &c.out_lock)
		}

		overflow := c.out_overflow
		dead := c.dead
		closed := c.out_closed

		if overflow || dead {
			sync.mutex_unlock(&c.out_lock)
			break
		}

		if len(c.out) == 0 {
			sync.mutex_unlock(&c.out_lock)
			if closed {
				break // drained everything and the reader is done
			}
			continue
		}

		// O(1) handoff: the queue becomes the (empty) scratch buffer and we
		// take ownership of the pending bytes.
		c.out, scratch = scratch, c.out
		sync.mutex_unlock(&c.out_lock)

		ok := send_all(c.socket, scratch[:])
		clear(&scratch)

		if !ok {
			client_mark_dead(c)
			break
		}
	}

	if c.out_overflow {
		// Nothing polite to say here: the peer is not draining, so a close
		// frame would just queue behind the backlog.
		client_mark_dead(c)
	}
}

// ---------------------------------------------------------------------------
// Session state accessors
//
// These clone under the lock. Callers must free the result. Returning borrowed
// pointers to name/cwd/color is exactly the use-after-free the old code had.
// ---------------------------------------------------------------------------

client_get_name :: proc(c: ^Client, allocator := context.allocator) -> string {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return strings.clone(c.name, allocator)
}

client_get_cwd :: proc(c: ^Client, allocator := context.allocator) -> string {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return strings.clone(c.cwd, allocator)
}

client_get_user :: proc(c: ^Client, allocator := context.allocator) -> string {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return strings.clone(c.user, allocator)
}

client_is_authed :: proc(c: ^Client) -> bool {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return len(c.user) > 0
}

client_set_name :: proc(c: ^Client, name: string) {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	old := c.name
	c.name = strings.clone(name)
	delete(old)
}

client_set_cwd :: proc(c: ^Client, cwd: string) {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	old := c.cwd
	c.cwd = strings.clone(cwd)
	delete(old) // the old code simply leaked this on every cd
}

client_set_color :: proc(c: ^Client, code: string) {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	old := c.color
	c.color = strings.clone(code)
	delete(old)
}

// last_activity is written by the reader thread and read by `who` on another
// thread, so it needs the same lock as the rest of the shared session state.
// An unsynchronised i64 write next to a concurrent read is a data race whatever
// the odds of observing a torn value are.
client_touch :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	c.last_activity = time.now()
}

client_idle :: proc(c: ^Client) -> time.Duration {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return time.diff(c.last_activity, time.now())
}

client_set_user :: proc(c: ^Client, user: string) {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	old := c.user
	c.user = strings.clone(user)
	delete(old)
}

// ---------------------------------------------------------------------------
// Prompt rendering
// ---------------------------------------------------------------------------

// Builds the prompt string. Assumes state_lock is already held.
client_prompt_locked :: proc(c: ^Client, allocator := context.temp_allocator) -> string {
	// A command collecting a value owns the prompt while it does so.
	if len(c.prompt_label) > 0 {
		return strings.clone(c.prompt_label, allocator)
	}

	marker := "$"
	if len(c.user) > 0 {
		marker = "%"
	}
	return fmt.aprintf(
		"\x1b[%sm%s\x1b[0m@\x1b[36m%s\x1b[0m:\x1b[34m%s\x1b[0m%s ",
		c.color,
		c.name,
		SERVER_NAME,
		c.cwd,
		marker,
		allocator = allocator,
	)
}

client_prompt :: proc(c: ^Client, allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&c.state_lock)
	defer sync.mutex_unlock(&c.state_lock)
	return client_prompt_locked(c, allocator)
}

// Sends the prompt followed by whatever the user had typed, restoring the
// cursor to its logical position.
client_send_prompt :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

// Builds "erase the current line, draw prompt + input, position cursor".
// Assumes state_lock is held.
client_redraw_string_locked :: proc(c: ^Client, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)

	strings.write_string(&b, "\r\x1b[2K") // column 0, erase whole line
	strings.write_string(&b, client_prompt_locked(c, allocator))

	if c.echo_off {
		// A password is echoed as its own length and nothing more. Rendering it
		// here rather than at the point of entry means the masking survives a
		// redraw triggered by someone else's broadcast.
		for _ in 0 ..< len(c.line) {
			strings.write_byte(&b, '*')
		}
	} else {
		strings.write_string(&b, string(c.line[:]))
	}

	// Move the cursor back to where the user actually is.
	if back := len(c.line) - c.cursor; back > 0 {
		fmt.sbprintf(&b, "\x1b[%dD", back)
	}

	return strings.to_string(b)
}

// Delivers an out-of-band message (a broadcast, a DM, a system notice) without
// destroying the line the recipient is in the middle of typing.
//
// The old broadcast wrote the message straight into the stream and then
// re-emitted a bare prompt, so anything already typed was visually lost while
// still being in the input buffer.
client_send_notice :: proc(c: ^Client, msg: string) {
	sync.mutex_lock(&c.state_lock)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\r\x1b[2K") // wipe the line in place
	strings.write_string(&b, msg)
	strings.write_string(&b, client_redraw_string_locked(c, context.temp_allocator))
	s := strings.to_string(b)
	sync.mutex_unlock(&c.state_lock)

	client_send(c, s)
}
