package main

import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Out-of-band control channel
//
// Screen effects used to be triggered by embedding the literal string
// "___MATRIX_START___" in the terminal stream and having the browser scan for
// it. That is in-band signalling: any user could type
// `wall ___MATRIX_START___` and fire the effect on every connected screen, and
// any file containing that text would do the same when cat'd.
//
// Control messages are now sent as WebSocket *binary* frames while terminal
// output stays text. The two cannot be confused, and no amount of user content
// can forge one.
// ---------------------------------------------------------------------------

client_send_control :: proc(c: ^Client, json: string) {
	framed := ws_encode_frame(.Binary, transmute([]byte)json, context.temp_allocator)
	client_enqueue(c, framed)
}

// ---------------------------------------------------------------------------
// Building control messages
//
// These are assembled by hand rather than with fmt.tprintf, for two reasons.
//
// Odin's fmt treats '{' as the start of a format verb, so a format string
// containing JSON does not produce JSON: `{"t":"stat","users":%d}` came out as
// `%!(MISSING CLOSE BRACE)t":"stat","users":1}`, which the client then failed
// to parse and silently dropped.
//
// And any value that ever comes from a user has to be escaped. Interpolating a
// name straight into JSON is the same class of mistake as building SQL with
// string concatenation.
// ---------------------------------------------------------------------------

@(private = "file")
json_escape_into :: proc(b: ^strings.Builder, s: string) {
	for r in s {
		switch r {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if r < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(r))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
}

@(private = "file")
control_open :: proc(b: ^strings.Builder, type_name: string) {
	strings.write_string(b, "{\"t\":\"")
	json_escape_into(b, type_name)
	strings.write_string(b, "\"")
}

// A control message with no payload, e.g. {"t":"bell"}.
control_msg :: proc(type_name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	control_open(&b, type_name)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

control_msg_int :: proc(type_name: string, key: string, value: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	control_open(&b, type_name)
	strings.write_string(&b, ",\"")
	json_escape_into(&b, key)
	strings.write_string(&b, "\":")
	strings.write_int(&b, value)
	strings.write_string(&b, "}")
	return strings.to_string(b)
}

control_msg_str :: proc(type_name: string, key: string, value: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	control_open(&b, type_name)
	strings.write_string(&b, ",\"")
	json_escape_into(&b, key)
	strings.write_string(&b, "\":\"")
	json_escape_into(&b, value)
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

broadcast_control :: proc(json: string) {
	sync.mutex_lock(&g_clients_lock)
	defer sync.mutex_unlock(&g_clients_lock)
	for c in g_clients {
		client_send_control(c, json)
	}
}

// Tells every client how many sessions are open, for the status bar.
//
// Sent on the control channel rather than printed, so it updates silently
// instead of interrupting whatever someone is in the middle of typing.
broadcast_stat :: proc() {
	count := client_count()
	broadcast_control(control_msg_int("stat", "users", count))
}

// Must match the themes defined in public/style.css. The client ignores any
// name it does not recognise, so this cannot push arbitrary styling into
// someone's browser — the worst a mismatch does is nothing.
@(rodata)
THEMES := [?]string{"dark", "amber", "ocean", "mono", "paper"}

cmd_theme :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		out(ctx, "usage: theme <name>\n")
		outf(ctx, "available: %s\n", strings.join(THEMES[:], ", ", context.temp_allocator))
		out(ctx, "\x1b[90m(the ◐ button in the status bar cycles through them too)\x1b[0m\n")
		return
	}

	requested := strings.to_lower(args[0], context.temp_allocator)
	for name in THEMES {
		if name != requested {
			continue
		}
		client_send_control(ctx.client, control_msg_str("theme", "name", name))
		outf(ctx, "theme set to \x1b[1m%s\x1b[0m\n", name)
		return
	}

	errf(ctx, "theme: no theme called '%s'\n", sanitize_text(args[0], 20, context.temp_allocator))
	outf(ctx, "available: %s\n", strings.join(THEMES[:], ", ", context.temp_allocator))
}

cmd_bell :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		client_send_control(c, control_msg("bell"))
		out(ctx, "\x1b[90mding\x1b[0m\n")
		return
	}

	// Ringing someone else's terminal is an interruption, so it costs from the
	// same budget as any other broadcast.
	if !rate_allow(&c.rl_broadcast) {
		errf(ctx, "bell: too soon, wait %.0fs\n", rate_retry_after(&c.rl_broadcast))
		return
	}

	target := args[0]
	from := client_get_name(c, context.temp_allocator)
	delivered := 0

	sync.mutex_lock(&g_clients_lock)
	for other in g_clients {
		if other.id == c.id {
			continue
		}
		sync.mutex_lock(&other.state_lock)
		matches := strings.equal_fold(other.name, target)
		sync.mutex_unlock(&other.state_lock)

		if matches {
			client_send_control(other, control_msg("bell"))
			client_send_notice(
				other,
				fmt.tprintf("\x1b[33m*\x1b[0m %s is trying to get your attention\r\n", from),
			)
			delivered += 1
		}
	}
	sync.mutex_unlock(&g_clients_lock)

	if delivered == 0 {
		errf(ctx, "bell: %s is not online\n", sanitize_text(target, MAX_NAME_LEN, context.temp_allocator))
		return
	}
	outf(ctx, "\x1b[90mrang %d session(s)\x1b[0m\n", delivered)
}

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

// The inline forms below still work — a script has no way to answer a prompt —
// but the password was on screen while it was typed, so say so once.
@(private = "file")
warn_inline_secret :: proc(ctx: ^Cmd_Ctx) {
	out(
		ctx,
		"\x1b[33mnote:\x1b[0m that password was visible on screen. Run the command with no\n" +
		"      password next time and it will be asked for privately.\n",
	)
}

cmd_register :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if client_is_authed(c) {
		errf(ctx, "register: already logged in (use logout first)\n")
		return
	}

	// Interactive: ask for whatever was not supplied, with the password masked.
	switch len(args) {
	case 0:
		ask_begin(c, .Register_User, "Choose a username: ", false)
		return
	case 1:
		if ok, reason := validate_username(args[0]); !ok {
			errf(ctx, "register: %s\n", reason)
			return
		}
		ask_set_user(c, args[0])
		ask_begin(c, .Register_Pass, "Password: ", true)
		return
	}

	warn_inline_secret(ctx)
	finish_register(ctx, args[0], join_args(args[1:]))
}

// Creates the account and adopts it for this session. Shared by the inline and
// interactive forms so they cannot drift apart.
finish_register :: proc(ctx: ^Cmd_Ctx, name: string, password: string) {
	c := ctx.client

	if !rate_allow(&c.rl_auth) {
		errf(ctx, "register: too many attempts, wait %.0fs\n", rate_retry_after(&c.rl_auth))
		return
	}
	if ok, reason := validate_username(name); !ok {
		errf(ctx, "register: %s\n", reason)
		return
	}
	if ok, reason := validate_password(password); !ok {
		errf(ctx, "register: %s\n", reason)
		return
	}

	if err := auth_register(&g_users, name, password); err != .None {
		errf(ctx, "register: %s\n", auth_error_string(err))
		return
	}

	canon := auth_canonical(name, context.temp_allocator)

	// Give the new account a home directory it actually owns.
	home := fmt.tprintf("/home/%s", canon)
	vfs_mkdir_direct(home, canon)

	client_set_user(c, canon)
	client_set_name(c, name)
	client_set_cwd(c, home)

	log_security("register", c, name, true)
	outf(ctx, "\x1b[32mwelcome, %s\x1b[0m — your home is %s\n", name, home)
	announce_login(c, name, "registered")
}

cmd_login :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if client_is_authed(c) {
		errf(ctx, "login: already logged in (use logout first)\n")
		return
	}

	switch len(args) {
	case 0:
		ask_begin(c, .Login_User, "Username: ", false)
		return
	case 1:
		ask_set_user(c, args[0])
		ask_begin(c, .Login_Pass, "Password: ", true)
		return
	}

	warn_inline_secret(ctx)
	finish_login(ctx, args[0], join_args(args[1:]))
}

finish_login :: proc(ctx: ^Cmd_Ctx, name: string, password: string) {
	c := ctx.client

	if !rate_allow(&c.rl_auth) {
		errf(ctx, "login: too many attempts, wait %.0fs\n", rate_retry_after(&c.rl_auth))
		return
	}

	display, err := auth_verify(&g_users, name, password, context.temp_allocator)
	if err != .None {
		// Deliberately does not distinguish "no such user" from "wrong
		// password" — that difference is a username oracle.
		log_security("login", c, name, false)
		errf(ctx, "login: %s\n", auth_error_string(.Bad_Credentials))
		return
	}

	canon := auth_canonical(name, context.temp_allocator)
	home := fmt.tprintf("/home/%s", canon)
	vfs_mkdir_direct(home, canon)

	client_set_user(c, canon)
	client_set_name(c, display)
	client_set_cwd(c, home)

	log_security("login", c, display, true)
	outf(ctx, "\x1b[32mlogged in as %s\x1b[0m\n", display)
	announce_login(c, display, "logged in")
}

@(private = "file")
announce_login :: proc(c: ^Client, name: string, what: string) {
	if !rate_allow(&c.rl_broadcast) {
		return
	}
	broadcast_notice(
		fmt.tprintf(
			"\x1b[33m*\x1b[0m \x1b[1m%s\x1b[0m %s\r\n",
			sanitize_text(name, MAX_NAME_LEN, context.temp_allocator),
			what,
		),
		c.id,
	)
}

cmd_logout :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client
	if !client_is_authed(c) {
		errf(ctx, "logout: not logged in\n")
		return
	}

	client_set_user(c, "")
	client_set_name(c, fmt.tprintf("guest%d", c.id))
	client_set_cwd(c, "/tmp")
	out(ctx, "logged out\n")
}

cmd_passwd :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	user := client_get_user(c, context.temp_allocator)
	if len(user) == 0 {
		errf(ctx, "passwd: not logged in\n")
		return
	}

	if len(args) < 2 {
		ask_begin(c, .Passwd_Old, "Current password: ", true)
		return
	}

	warn_inline_secret(ctx)
	finish_passwd(ctx, args[0], args[1])
}

finish_passwd :: proc(ctx: ^Cmd_Ctx, old_password: string, new_password: string) {
	c := ctx.client

	user := client_get_user(c, context.temp_allocator)
	if len(user) == 0 {
		errf(ctx, "passwd: not logged in\n")
		return
	}
	if !rate_allow(&c.rl_auth) {
		errf(ctx, "passwd: too many attempts, wait %.0fs\n", rate_retry_after(&c.rl_auth))
		return
	}

	if err := auth_change_password(&g_users, user, old_password, new_password); err != .None {
		log_security("passwd", c, user, false)
		errf(ctx, "passwd: %s\n", auth_error_string(err))
		return
	}

	log_security("passwd", c, user, true)
	out(ctx, "\x1b[32mpassword changed\x1b[0m\n")
}

cmd_whoami :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client
	name := client_get_name(c, context.temp_allocator)
	user := client_get_user(c, context.temp_allocator)

	if len(user) == 0 {
		outf(ctx, "%s \x1b[90m(guest — not logged in)\x1b[0m\n", name)
		return
	}
	outf(ctx, "%s \x1b[90m(account: %s)\x1b[0m\n", name, user)

	if info, ok := auth_info(&g_users, user, context.temp_allocator); ok {
		outf(ctx, "  registered: %s\n", format_timestamp(info.created))
		outf(ctx, "  logins:     %d\n", info.login_count)
	}
}

// Sets a display nickname without any account behind it.
cmd_name :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		errf(ctx, "name: usage: name <nickname>\n")
		return
	}
	if client_is_authed(c) {
		errf(ctx, "name: logged-in accounts always show their account name\n")
		return
	}

	requested := args[0]
	if ok, reason := validate_username(requested); !ok {
		errf(ctx, "name: %s\n", reason)
		return
	}
	// A guest must not be able to take the name of a registered account.
	if auth_exists(&g_users, requested) {
		errf(ctx, "name: that name belongs to a registered account\n")
		return
	}

	old := client_get_name(c, context.temp_allocator)
	client_set_name(c, requested)

	outf(ctx, "you are now \x1b[1m%s\x1b[0m\n", requested)

	if rate_allow(&c.rl_broadcast) {
		broadcast_notice(
			fmt.tprintf("\x1b[33m*\x1b[0m %s is now known as \x1b[1m%s\x1b[0m\r\n", old, requested),
			c.id,
		)
	}
}

cmd_color :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		names := color_names(context.temp_allocator)
		outf(ctx, "usage: color <name>\navailable: %s\n", names)
		return
	}

	code := lookup_color(args[0])
	if len(code) == 0 {
		errf(ctx, "color: unknown colour '%s'\n", sanitize_text(args[0], 20, context.temp_allocator))
		outf(ctx, "available: %s\n", color_names(context.temp_allocator))
		return
	}

	client_set_color(ctx.client, code)
	outf(ctx, "prompt colour set to \x1b[%sm%s\x1b[0m\n", code, args[0])
}

cmd_who :: proc(ctx: ^Cmd_Ctx, args: []string) {
	Row :: struct {
		name:   string,
		user:   string,
		cwd:    string,
		idle:   f64,
		is_me:  bool,
	}

	rows := make([dynamic]Row, context.temp_allocator)

	sync.mutex_lock(&g_clients_lock)
	for c in g_clients {
		sync.mutex_lock(&c.state_lock)
		append(
			&rows,
			Row {
				name = strings.clone(c.name, context.temp_allocator),
				user = strings.clone(c.user, context.temp_allocator),
				cwd = strings.clone(c.cwd, context.temp_allocator),
				idle = time.duration_seconds(time.diff(c.last_activity, time.now())),
				is_me = c.id == ctx.client.id,
			},
		)
		sync.mutex_unlock(&c.state_lock)
	}
	sync.mutex_unlock(&g_clients_lock)

	slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.name < b.name})

	outf(ctx, "\x1b[1m%-20s %-10s %-24s %s\x1b[0m\n", "USER", "TYPE", "LOCATION", "IDLE")
	for r in rows {
		kind := len(r.user) > 0 ? "account" : "guest"
		marker := r.is_me ? " \x1b[32m<- you\x1b[0m" : ""
		outf(
			ctx,
			"%-20s %-10s %-24s %.0fs%s\n",
			sanitize_text(r.name, MAX_NAME_LEN, context.temp_allocator),
			kind,
			r.cwd,
			r.idle,
			marker,
		)
	}
	outf(ctx, "\n%d connected, %d registered accounts\n", len(rows), auth_count(&g_users))
}

cmd_finger :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		// Dumping every registered name to anonymous callers hands over the
		// account list, which is the first half of a credential-stuffing run.
		// Holding an account is a low bar, but it is not zero, and it makes the
		// enumeration attributable.
		if !client_is_authed(ctx.client) {
			errf(ctx, "finger: log in to list accounts, or name one directly\n")
			out(ctx, "  \x1b[36mfinger <username>\x1b[0m works for anyone.\n")
			return
		}

		names := auth_list(&g_users, context.temp_allocator)
		slice.sort(names)
		outf(ctx, "%d registered account(s):\n", len(names))
		for n in names {
			outf(ctx, "  %s\n", n)
		}
		return
	}

	info, ok := auth_info(&g_users, args[0], context.temp_allocator)
	if !ok {
		errf(ctx, "finger: %s: no such account\n", sanitize_text(args[0], 32, context.temp_allocator))
		return
	}

	outf(ctx, "  Account: %s\n", info.display)
	outf(ctx, "     Home: /home/%s\n", auth_canonical(args[0], context.temp_allocator))
	outf(ctx, "Registered: %s\n", format_timestamp(info.created))
	outf(ctx, "Last login: %s\n", format_timestamp(info.last_login))
	outf(ctx, "   Logins: %d\n", info.login_count)
}

// ---------------------------------------------------------------------------
// Communication
// ---------------------------------------------------------------------------

cmd_wall :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		errf(ctx, "wall: usage: wall <message>\n")
		return
	}
	if !rate_allow(&c.rl_broadcast) {
		errf(ctx, "wall: too soon, wait %.0fs\n", rate_retry_after(&c.rl_broadcast))
		return
	}

	name := client_get_name(c, context.temp_allocator)
	// The message goes into everyone else's terminal, so it is stripped of
	// escape sequences and control characters first.
	msg := sanitize_text(join_args(args), 400, context.temp_allocator)
	if len(msg) == 0 {
		errf(ctx, "wall: nothing to say\n")
		return
	}

	broadcast_notice(
		fmt.tprintf("\x1b[35m[wall]\x1b[0m \x1b[1m%s\x1b[0m: %s\r\n", name, msg),
		c.id,
	)
	outf(ctx, "\x1b[90msent to everyone\x1b[0m\n")
}

cmd_msg :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) < 2 {
		errf(ctx, "msg: usage: msg <user> <message>\n")
		return
	}
	if !rate_allow(&c.rl_broadcast) {
		errf(ctx, "msg: too soon, wait %.0fs\n", rate_retry_after(&c.rl_broadcast))
		return
	}

	target := args[0]
	from := client_get_name(c, context.temp_allocator)
	msg := sanitize_text(join_args(args[1:]), 400, context.temp_allocator)
	if len(msg) == 0 {
		errf(ctx, "msg: nothing to say\n")
		return
	}

	delivered := 0
	notice := fmt.tprintf("\x1b[36m[dm from %s]\x1b[0m %s\r\n", from, msg)

	sync.mutex_lock(&g_clients_lock)
	for other in g_clients {
		if other.id == c.id {
			continue
		}
		sync.mutex_lock(&other.state_lock)
		matches := strings.equal_fold(other.name, target)
		sync.mutex_unlock(&other.state_lock)

		if matches {
			client_send_notice(other, notice)
			delivered += 1
		}
	}
	sync.mutex_unlock(&g_clients_lock)

	if delivered == 0 {
		errf(ctx, "msg: %s is not online\n", sanitize_text(target, MAX_NAME_LEN, context.temp_allocator))
		return
	}
	outf(ctx, "\x1b[90mdelivered to %d session(s)\x1b[0m\n", delivered)
}

cmd_me :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		errf(ctx, "me: usage: me <action>\n")
		return
	}
	if !rate_allow(&c.rl_broadcast) {
		errf(ctx, "me: too soon, wait %.0fs\n", rate_retry_after(&c.rl_broadcast))
		return
	}

	name := client_get_name(c, context.temp_allocator)
	action := sanitize_text(join_args(args), 300, context.temp_allocator)

	broadcast_notice(fmt.tprintf("\x1b[35m* %s %s\x1b[0m\r\n", name, action), -1)
}

// ---------------------------------------------------------------------------
// System information
// ---------------------------------------------------------------------------

cmd_uname :: proc(ctx: ^Cmd_Ctx, args: []string) {
	outf(ctx, "WebOS %s odin-kernel x86_64\n", SERVER_VERSION)
}

cmd_version :: proc(ctx: ^Cmd_Ctx, args: []string) {
	outf(ctx, "WebOS %s\n", SERVER_VERSION)
	outf(ctx, "  backend:  Odin, hand-rolled HTTP + RFC 6455 WebSocket\n")
	outf(ctx, "  frontend: xterm.js (self-hosted)\n")
}

cmd_uptime :: proc(ctx: ^Cmd_Ctx, args: []string) {
	d := time.diff(g_started_at, time.now())
	secs := int(time.duration_seconds(d))

	days := secs / 86400
	hours := (secs % 86400) / 3600
	mins := (secs % 3600) / 60

	if days > 0 {
		outf(ctx, "up %dd %dh %dm, %d users online\n", days, hours, mins, client_count())
	} else if hours > 0 {
		outf(ctx, "up %dh %dm, %d users online\n", hours, mins, client_count())
	} else {
		outf(ctx, "up %dm, %d users online\n", mins, client_count())
	}
}

cmd_date :: proc(ctx: ^Cmd_Ctx, args: []string) {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock_from_time(now)
	outf(ctx, "%04d-%02d-%02d %02d:%02d:%02d UTC\n", y, int(mo), d, h, mi, s)
}

cmd_free :: proc(ctx: ^Cmd_Ctx, args: []string) {
	u := vfs_usage(&g_vfs)
	outf(ctx, "VFS storage:  %s used of %s\n",
		human_size(u.total_bytes, context.temp_allocator),
		human_size(u.max_bytes, context.temp_allocator))
	outf(ctx, "VFS entries:  %d of %d\n", u.entries, u.max_entries)
	outf(ctx, "Sessions:     %d of %d\n", client_count(), MAX_CLIENTS)
}

cmd_ps :: proc(ctx: ^Cmd_Ctx, args: []string) {
	outf(ctx, "\x1b[1m%-6s %-20s %s\x1b[0m\n", "PID", "USER", "COMMAND")

	sync.mutex_lock(&g_clients_lock)
	for c in g_clients {
		sync.mutex_lock(&c.state_lock)
		name := strings.clone(c.name, context.temp_allocator)
		sync.mutex_unlock(&c.state_lock)
		outf(ctx, "%s %-20s webos-shell\n", pad_int_left(c.id, 6), name)
	}
	sync.mutex_unlock(&g_clients_lock)
}

cmd_history :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client
	if len(c.history) == 0 {
		out(ctx, "no history yet\n")
		return
	}
	for h, i in c.history {
		outf(ctx, "%s  %s\n", pad_int(i + 1, 5), sanitize_text(h, 200, context.temp_allocator))
	}
}

cmd_clear :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// Erase screen and scrollback, then home the cursor.
	client_send(ctx.client, "\x1b[2J\x1b[3J\x1b[H")
}

cmd_motd :: proc(ctx: ^Cmd_Ctx, args: []string) {
	content, ok := vfs_read(&g_vfs, "/etc/motd", "", context.temp_allocator)
	if !ok {
		errf(ctx, "motd: /etc/motd is missing\n")
		return
	}
	out(ctx, content)
}

cmd_neofetch :: proc(ctx: ^Cmd_Ctx, args: []string) {
	u := vfs_usage(&g_vfs)
	d := time.diff(g_started_at, time.now())
	mins := int(time.duration_seconds(d)) / 60

	name := client_get_name(ctx.client, context.temp_allocator)

	art := []string {
		"\x1b[32m    ______      \x1b[0m",
		"\x1b[32m   / ____ \\     \x1b[0m",
		"\x1b[32m  | |    | |    \x1b[0m",
		"\x1b[32m  | |    | |    \x1b[0m",
		"\x1b[32m  | |____| |    \x1b[0m",
		"\x1b[32m   \\______/     \x1b[0m",
		"\x1b[32m                \x1b[0m",
	}

	info := []string {
		fmt.tprintf("\x1b[1;32m%s\x1b[0m@\x1b[1;32mwebos\x1b[0m", name),
		"---------------",
		fmt.tprintf("\x1b[1mOS\x1b[0m:       WebOS %s", SERVER_VERSION),
		"\x1b[1mKernel\x1b[0m:   odin-native",
		fmt.tprintf("\x1b[1mUptime\x1b[0m:   %dm", mins),
		fmt.tprintf("\x1b[1mUsers\x1b[0m:    %d online / %d registered", client_count(), auth_count(&g_users)),
		fmt.tprintf("\x1b[1mStorage\x1b[0m:  %s / %s",
			human_size(u.total_bytes, context.temp_allocator),
			human_size(u.max_bytes, context.temp_allocator)),
		fmt.tprintf("\x1b[1mEntries\x1b[0m:  %d", u.entries),
	}

	rows := max(len(art), len(info))
	for i in 0 ..< rows {
		left := i < len(art) ? art[i] : "                "
		right := i < len(info) ? info[i] : ""
		outf(ctx, "%s  %s\n", left, right)
	}
}

// ---------------------------------------------------------------------------
// Effects
// ---------------------------------------------------------------------------

cmd_matrix :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client
	if !rate_allow(&c.rl_broadcast) {
		errf(ctx, "matrix: too soon, wait %.0fs\n", rate_retry_after(&c.rl_broadcast))
		return
	}

	name := client_get_name(c, context.temp_allocator)
	broadcast_notice(
		fmt.tprintf("\x1b[32m*\x1b[0m %s started the matrix\r\n", name),
		-1,
	)
	broadcast_control(control_msg_int("matrix", "ms", MATRIX_DURATION_MS))
}

cmd_clearall :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client
	if !rate_allow(&c.rl_broadcast) {
		errf(ctx, "clearall: too soon, wait %.0fs\n", rate_retry_after(&c.rl_broadcast))
		return
	}

	broadcast_raw("\x1b[2J\x1b[3J\x1b[H", -1)

	sync.mutex_lock(&g_clients_lock)
	for other in g_clients {
		client_send_prompt(other)
	}
	sync.mutex_unlock(&g_clients_lock)

	name := client_get_name(c, context.temp_allocator)
	broadcast_notice(fmt.tprintf("\x1b[33m*\x1b[0m %s cleared every screen\r\n", name), c.id)
}

cmd_banner :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// Same rule as cowsay: arguments first, then a pipe. Twenty characters is
	// already wider than most terminals at five rows a letter, so only the
	// first line of piped input is used.
	source := ""
	switch {
	case len(args) > 0:
		source = join_args(args)
	case len(ctx.stdin) > 0:
		if lines := input_lines(ctx.stdin); len(lines) > 0 {
			source = lines[0]
		}
	}

	if len(strings.trim_space(source)) == 0 {
		errf(ctx, "banner: usage: banner <text>\n")
		return
	}

	text := sanitize_text(source, 20, context.temp_allocator)
	upper := strings.to_upper(text, context.temp_allocator)

	// Five-row block font, rendered one row at a time across all characters.
	for row in 0 ..< 5 {
		b := strings.builder_make(context.temp_allocator)
		for ch in upper {
			strings.write_string(&b, banner_row(ch, row))
			strings.write_string(&b, " ")
		}
		outf(ctx, "%s\n", strings.to_string(b))
	}
}

@(private = "file")
banner_row :: proc(ch: rune, row: int) -> string {
	GLYPHS :: [?]struct {
		ch:   rune,
		rows: [5]string,
	} {
		{'A', {" ## ", "#  #", "####", "#  #", "#  #"}},
		{'B', {"### ", "#  #", "### ", "#  #", "### "}},
		{'C', {" ###", "#   ", "#   ", "#   ", " ###"}},
		{'D', {"### ", "#  #", "#  #", "#  #", "### "}},
		{'E', {"####", "#   ", "### ", "#   ", "####"}},
		{'F', {"####", "#   ", "### ", "#   ", "#   "}},
		{'G', {" ###", "#   ", "# ##", "#  #", " ###"}},
		{'H', {"#  #", "#  #", "####", "#  #", "#  #"}},
		{'I', {"###", " # ", " # ", " # ", "###"}},
		{'J', {"  ##", "   #", "   #", "#  #", " ## "}},
		{'K', {"#  #", "# # ", "##  ", "# # ", "#  #"}},
		{'L', {"#   ", "#   ", "#   ", "#   ", "####"}},
		{'M', {"#   #", "## ##", "# # #", "#   #", "#   #"}},
		{'N', {"#  #", "## #", "# ##", "#  #", "#  #"}},
		{'O', {" ## ", "#  #", "#  #", "#  #", " ## "}},
		{'P', {"### ", "#  #", "### ", "#   ", "#   "}},
		{'Q', {" ## ", "#  #", "#  #", "# ##", " ###"}},
		{'R', {"### ", "#  #", "### ", "# # ", "#  #"}},
		{'S', {" ###", "#   ", " ## ", "   #", "### "}},
		{'T', {"#####", "  #  ", "  #  ", "  #  ", "  #  "}},
		{'U', {"#  #", "#  #", "#  #", "#  #", " ## "}},
		{'V', {"#   #", "#   #", "#   #", " # # ", "  #  "}},
		{'W', {"#   #", "#   #", "# # #", "## ##", "#   #"}},
		{'X', {"#  #", " ## ", " ## ", " ## ", "#  #"}},
		{'Y', {"#   #", " # # ", "  #  ", "  #  ", "  #  "}},
		{'Z', {"####", "   #", "  # ", " #  ", "####"}},
		{'0', {" ## ", "#  #", "#  #", "#  #", " ## "}},
		{'1', {" # ", "## ", " # ", " # ", "###"}},
		{'2', {"### ", "   #", " ## ", "#   ", "####"}},
		{'3', {"### ", "   #", " ## ", "   #", "### "}},
		{'4', {"#  #", "#  #", "####", "   #", "   #"}},
		{'5', {"####", "#   ", "### ", "   #", "### "}},
		{'6', {" ###", "#   ", "### ", "#  #", " ## "}},
		{'7', {"####", "   #", "  # ", " #  ", " #  "}},
		{'8', {" ## ", "#  #", " ## ", "#  #", " ## "}},
		{'9', {" ## ", "#  #", " ###", "   #", "### "}},
		{'!', {" # ", " # ", " # ", "   ", " # "}},
		{'?', {"### ", "   #", " ## ", "    ", " #  "}},
		{'.', {"   ", "   ", "   ", "   ", " # "}},
	}

	for g in GLYPHS {
		if g.ch == ch {
			return g.rows[row]
		}
	}
	return "   " // space and anything unmapped
}

cmd_cowsay :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// A filter as well as a command: `fortune | cowsay` is the whole reason
	// anyone has ever run cowsay, so piped input counts as the message.
	// Arguments win over stdin, and "moo" is only for the bare invocation.
	text := "moo"
	switch {
	case len(args) > 0:
		text = join_args(args)
	case len(ctx.stdin) > 0:
		// The bubble is one line, so a multi-line pipe folds into one.
		text = strings.join(input_lines(ctx.stdin), " ", context.temp_allocator)
	}

	msg := sanitize_text(text, 200, context.temp_allocator)
	if len(msg) == 0 {
		msg = "..."
	}

	// Rune count, not byte length: a byte-sized bar is too long under any
	// non-ASCII text and the bubble stops lining up.
	bar := strings.repeat("-", utf8.rune_count_in_string(msg) + 2, context.temp_allocator)
	outf(ctx, " %s\n", bar)
	outf(ctx, "< %s >\n", msg)
	outf(ctx, " %s\n", bar)
	out(ctx, "        \\   ^__^\n")
	out(ctx, "         \\  (oo)\\_______\n")
	out(ctx, "            (__)\\       )\\/\\\n")
	out(ctx, "                ||----w |\n")
	out(ctx, "                ||     ||\n")
}

cmd_fortune :: proc(ctx: ^Cmd_Ctx, args: []string) {
	FORTUNES :: []string {
		"Everything in here lives in RAM. So does everything else, eventually.",
		"A shared filesystem is just a group chat with worse manners.",
		"There are two hard problems in computing, and off-by-one of them is naming.",
		"The fastest code is the code you deleted.",
		"Any sufficiently advanced bug is indistinguishable from a feature.",
		"Someone else is probably reading your files right now. Say hi.",
		"rm -rf is a lifestyle, not a command.",
		"The `matrix` command does nothing useful. That is the point.",
		"Manual memory management builds character, then leaks it.",
		"It worked on my machine, and my machine is this one.",
		"Never trust a filesystem you can fit in a browser tab.",
		"Write drunk, deploy sober, revert either way.",
	}
	outf(ctx, "%s\n", rand.choice(FORTUNES))
}

cmd_rev :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// Reverses the text given, or every line arriving on the pipe.
	if len(args) == 0 {
		if len(ctx.stdin) == 0 {
			errf(ctx, "rev: usage: rev <text>   (or pipe something in)\n")
			return
		}
		for line in input_lines(ctx.stdin) {
			outf(ctx, "%s\n", reverse_runes(sanitize_text(line, 400, context.temp_allocator)))
		}
		return
	}

	text := sanitize_text(join_args(args), 400, context.temp_allocator)
	outf(ctx, "%s\n", reverse_runes(text))
}

// Reverses by rune so multi-byte characters survive intact.
@(private = "file")
reverse_runes :: proc(text: string) -> string {
	runes := utf8_runes(text)
	b := strings.builder_make(context.temp_allocator)
	for i := len(runes) - 1; i >= 0; i -= 1 {
		strings.write_rune(&b, runes[i])
	}
	return strings.to_string(b)
}

@(private = "file")
utf8_runes :: proc(s: string) -> []rune {
	out_runes := make([dynamic]rune, context.temp_allocator)
	for r in s {
		append(&out_runes, r)
	}
	return out_runes[:]
}

cmd_roll :: proc(ctx: ^Cmd_Ctx, args: []string) {
	sides := 6
	if len(args) > 0 {
		if n, ok := parse_positive_int(args[0]); ok && n >= 2 {
			sides = min(n, 1_000_000)
		}
	}
	outf(ctx, "rolled \x1b[1m%d\x1b[0m (d%d)\n", rand.int_max(sides) + 1, sides)
}

cmd_8ball :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "8ball: ask a question\n")
		return
	}
	ANSWERS :: []string {
		"It is certain.",
		"Reply hazy, try again.",
		"Don't count on it.",
		"Yes, definitely.",
		"Ask again after a coffee.",
		"My sources say no.",
		"Signs point to yes.",
		"Absolutely not.",
		"Outlook good.",
		"That depends on the build flags.",
	}
	outf(ctx, "\x1b[35m%s\x1b[0m\n", rand.choice(ANSWERS))
}

cmd_calc :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "calc: usage: calc <a> <op> <b>   (e.g. calc 6 * 7)\n")
		return
	}

	expr := join_args(args)
	result, ok := eval_simple(expr)
	if !ok {
		errf(ctx, "calc: could not parse '%s'\n", sanitize_text(expr, 60, context.temp_allocator))
		return
	}
	outf(ctx, "%g\n", result)
}

// Deliberately a three-token evaluator rather than a real parser: there is no
// reason to accept arbitrary expressions from the network.
@(private = "file")
eval_simple :: proc(expr: string) -> (result: f64, ok: bool) {
	fields := strings.fields(expr, context.temp_allocator)
	if len(fields) != 3 {
		return 0, false
	}

	a := parse_f64(fields[0]) or_return
	b := parse_f64(fields[2]) or_return

	switch fields[1] {
	case "+":
		return a + b, true
	case "-":
		return a - b, true
	case "*", "x":
		return a * b, true
	case "/":
		if b == 0 {
			return 0, false
		}
		return a / b, true
	case "%":
		if b == 0 {
			return 0, false
		}
		return f64(int(a) % int(b)), true
	}
	return 0, false
}

@(private = "file")
parse_f64 :: proc(s: string) -> (val: f64, ok: bool) {
	negative := false
	body := s
	if len(body) > 0 && (body[0] == '-' || body[0] == '+') {
		negative = body[0] == '-'
		body = body[1:]
	}
	if len(body) == 0 {
		return 0, false
	}

	whole := 0.0
	frac := 0.0
	scale := 0.1
	seen_dot := false

	for i in 0 ..< len(body) {
		c := body[i]
		if c == '.' {
			if seen_dot {
				return 0, false
			}
			seen_dot = true
			continue
		}
		if c < '0' || c > '9' {
			return 0, false
		}
		if seen_dot {
			frac += f64(c - '0') * scale
			scale *= 0.1
		} else {
			whole = whole * 10 + f64(c - '0')
			if whole > 1e15 {
				return 0, false
			}
		}
	}

	v := whole + frac
	return negative ? -v : v, true
}
