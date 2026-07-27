package main

import "base:intrinsics"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Interactive credential prompts
//
// `login alice hunter2` types the password into a shared terminal in clear
// text, stores it in the session's command history where `history` will print
// it back, and leaves it in the scrollback of whoever is looking at the screen.
// Every one of those is avoidable.
//
// This is the state machine behind the readline-style prompts: a command can
// ask for one value at a time, optionally with echo suppressed, and the line
// editor routes the next submitted line to the command instead of to the
// interpreter.
//
// The typed form still works — it is what a script would use — but it is
// redacted from history and warns that it was visible.
// ---------------------------------------------------------------------------

Ask_State :: enum {
	None,
	Login_User,
	Login_Pass,
	Register_User,
	Register_Pass,
	Register_Confirm,
	Passwd_Old,
	Passwd_New,
	Passwd_Confirm,
}

ask_active :: proc(c: ^Client) -> bool {
	return c.ask_state != .None
}

// Begins collecting one value. `secret` suppresses echo for what is typed.
ask_begin :: proc(c: ^Client, state: Ask_State, label: string, secret: bool) {
	c.ask_state = state

	sync.mutex_lock(&c.state_lock)
	old := c.prompt_label
	c.prompt_label = strings.clone(label)
	c.echo_off = secret
	delete(old)
	// Anything already typed belongs to the previous line, not to the answer.
	clear(&c.line)
	c.cursor = 0
	sync.mutex_unlock(&c.state_lock)
}

// Ends the prompt sequence and wipes anything sensitive it accumulated.
ask_clear :: proc(c: ^Client) {
	c.ask_state = .None

	secure_delete(c.ask_user)
	secure_delete(c.ask_pass)
	c.ask_user = ""
	c.ask_pass = ""

	sync.mutex_lock(&c.state_lock)
	old := c.prompt_label
	c.prompt_label = ""
	c.echo_off = false
	delete(old)
	clear(&c.line)
	c.cursor = 0
	sync.mutex_unlock(&c.state_lock)
}

// Stores a collected value, wiping whatever was there before.
ask_set_user :: proc(c: ^Client, v: string) {
	secure_delete(c.ask_user)
	c.ask_user = strings.clone(v)
}

ask_set_pass :: proc(c: ^Client, v: string) {
	secure_delete(c.ask_pass)
	c.ask_pass = strings.clone(v)
}

// Overwrites a secret before releasing it, so a password is not left sitting in
// freed heap memory for the lifetime of the process. The volatile form is used
// so the write cannot be optimised away as dead.
secure_delete :: proc(s: string) {
	if len(s) == 0 {
		return
	}
	bytes := transmute([]byte)s
	intrinsics.mem_zero_volatile(raw_data(bytes), len(bytes))
	delete(s)
}

// ---------------------------------------------------------------------------
// Driving the machine
// ---------------------------------------------------------------------------

// Consumes one submitted line as the answer to the current prompt.
ask_feed :: proc(c: ^Client, value: string) {
	ctx := Cmd_Ctx {
		client = c,
	}

	// An empty answer at any step abandons the sequence, which is what someone
	// pressing Enter to escape expects.
	if len(strings.trim_space(value)) == 0 {
		ask_clear(c)
		client_send(c, "\x1b[90mcancelled\x1b[0m\r\n")
		return
	}

	switch c.ask_state {
	case .None:
		return

	case .Login_User:
		ask_set_user(c, value)
		ask_begin(c, .Login_Pass, "Password: ", true)

	case .Login_Pass:
		finish_login(&ctx, c.ask_user, value)
		ask_clear(c)

	case .Register_User:
		if ok, reason := validate_username(value); !ok {
			errf(&ctx, "register: %s\n", reason)
			ask_clear(c)
			return
		}
		if auth_exists(&g_users, value) {
			errf(&ctx, "register: %s\n", auth_error_string(.Exists))
			ask_clear(c)
			return
		}
		ask_set_user(c, value)
		ask_begin(c, .Register_Pass, "Password: ", true)

	case .Register_Pass:
		if ok, reason := validate_password(value); !ok {
			errf(&ctx, "register: %s\n", reason)
			ask_clear(c)
			return
		}
		ask_set_pass(c, value)
		ask_begin(c, .Register_Confirm, "Confirm password: ", true)

	case .Register_Confirm:
		if value != c.ask_pass {
			errf(&ctx, "register: passwords do not match\n")
			ask_clear(c)
			return
		}
		finish_register(&ctx, c.ask_user, c.ask_pass)
		ask_clear(c)

	case .Passwd_Old:
		ask_set_pass(c, value)
		ask_begin(c, .Passwd_New, "New password: ", true)

	case .Passwd_New:
		if ok, reason := validate_password(value); !ok {
			errf(&ctx, "passwd: %s\n", reason)
			ask_clear(c)
			return
		}
		// Reuse ask_user to carry the new password through confirmation; it is
		// wiped by ask_clear either way.
		ask_set_user(c, value)
		ask_begin(c, .Passwd_Confirm, "Confirm new password: ", true)

	case .Passwd_Confirm:
		if value != c.ask_user {
			errf(&ctx, "passwd: passwords do not match\n")
			ask_clear(c)
			return
		}
		finish_passwd(&ctx, c.ask_pass, c.ask_user)
		ask_clear(c)
	}
}

// ---------------------------------------------------------------------------
// History redaction
// ---------------------------------------------------------------------------

// Commands whose arguments are credentials. A line starting with one of these
// is recorded without them.
@(rodata)
SECRET_COMMANDS := [?]string{"login", "register", "passwd", "su"}

// Rewrites a history entry so a password typed inline is never stored.
//
// Returns the text to remember. `history` reads back the session's own lines,
// and a shared screen or a shoulder is enough for that to matter.
redact_for_history :: proc(line: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_space(line)

	space := strings.index_any(trimmed, " \t")
	if space < 0 {
		return strings.clone(trimmed, allocator) // bare command, nothing to hide
	}

	name := strings.to_lower(trimmed[:space], context.temp_allocator)
	for secret in SECRET_COMMANDS {
		if name != secret {
			continue
		}

		rest := strings.trim_space(trimmed[space:])
		// The username is not a secret and is useful in history; anything after
		// it is.
		if user_end := strings.index_any(rest, " \t"); user_end > 0 {
			return strings.concatenate(
				{trimmed[:space], " ", rest[:user_end], " ********"},
				allocator,
			)
		}
		return strings.clone(trimmed, allocator)
	}

	return strings.clone(trimmed, allocator)
}
