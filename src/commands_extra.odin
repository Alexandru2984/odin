package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// ---------------------------------------------------------------------------
// Session aliases
//
// Kept per session rather than per account: an alias is a convenience for the
// terminal you are sitting at, and persisting them would mean a stored string
// that gets expanded into a command line on every future login.
// ---------------------------------------------------------------------------

MAX_ALIASES :: 32

cmd_alias :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		if len(c.aliases) == 0 {
			out(ctx, "no aliases set\n")
			out(ctx, "\x1b[90musage: alias name=command\x1b[0m\n")
			return
		}

		names := make([dynamic]string, context.temp_allocator)
		for name in c.aliases {
			append(&names, name)
		}
		slice.sort(names[:])

		for name in names {
			outf(
				ctx,
				"alias %s='%s'\n",
				name,
				sanitize_text(c.aliases[name], 200, context.temp_allocator),
			)
		}
		return
	}

	definition := join_args(args)

	eq := strings.index_byte(definition, '=')
	if eq <= 0 {
		// `alias ll` prints just that one, like a shell.
		if value, ok := c.aliases[definition]; ok {
			outf(ctx, "alias %s='%s'\n", definition,
				sanitize_text(value, 200, context.temp_allocator))
			return
		}
		errf(ctx, "alias: %s: not set\n", sanitize_text(definition, 32, context.temp_allocator))
		return
	}

	name := strings.trim_space(definition[:eq])
	body := strings.trim_space(unquote(strings.trim_space(definition[eq + 1:])))

	if !is_valid_alias_name(name) {
		errf(ctx, "alias: '%s' is not a usable alias name\n",
			sanitize_text(name, 32, context.temp_allocator))
		return
	}
	if len(body) == 0 {
		errf(ctx, "alias: %s: nothing to expand to\n", name)
		return
	}
	if len(body) > 200 {
		errf(ctx, "alias: definition too long\n")
		return
	}
	// An alias that names itself would recurse; expansion happens once, but
	// refusing it outright is clearer than silently not expanding.
	if strings.has_prefix(body, name) &&
	   (len(body) == len(name) || body[len(name)] == ' ') {
		errf(ctx, "alias: %s cannot expand to itself\n", name)
		return
	}

	if _, exists := c.aliases[name]; !exists && len(c.aliases) >= MAX_ALIASES {
		errf(ctx, "alias: limit of %d aliases reached\n", MAX_ALIASES)
		return
	}

	if existing, ok := c.aliases[name]; ok {
		delete(existing)
		c.aliases[name] = strings.clone(body)
	} else {
		c.aliases[strings.clone(name)] = strings.clone(body)
	}
}

cmd_unalias :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		errf(ctx, "unalias: usage: unalias <name...>\n")
		return
	}

	for name in args {
		if name not_in c.aliases {
			errf(ctx, "unalias: %s: not set\n", sanitize_text(name, 32, context.temp_allocator))
			continue
		}
		key, value := delete_key(&c.aliases, name)
		delete(key)
		delete(value)
	}
}

is_valid_alias_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 32 {
		return false
	}
	for i in 0 ..< len(name) {
		ch := name[i]
		ok :=
			(ch >= 'a' && ch <= 'z') ||
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '_' ||
			ch == '-'
		if !ok {
			return false
		}
	}
	// A real command must stay reachable: shadowing `rm` with something
	// surprising and then forgetting is a foot-gun with no upside here.
	//
	// The built-in convenience aliases are a different matter and *can* be
	// replaced — `ll` is the most commonly redefined name there is, and
	// refusing it because the server already ships an `ll` would be obtuse.
	// Session aliases are consulted before the built-in table, so a
	// redefinition simply wins.
	lower := strings.to_lower(name, context.temp_allocator)
	for cmd in COMMANDS {
		if cmd.name == lower {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// cal
// ---------------------------------------------------------------------------

cmd_cal :: proc(ctx: ^Cmd_Ctx, args: []string) {
	now := time.now()
	year, month, day := time.date(now)

	// `cal <month> <year>`, or just `cal <year>` for the whole year.
	if len(args) == 2 {
		if m, ok := parse_positive_int(args[0]); ok && m >= 1 && m <= 12 {
			month = time.Month(m)
		}
		if y, ok := parse_positive_int(args[1]); ok && y >= 1 && y <= 9999 {
			year = y
		}
		day = 0 // no "today" to highlight in another month
	} else if len(args) == 1 {
		if y, ok := parse_positive_int(args[0]); ok && y >= 1 && y <= 9999 {
			year = y
			day = 0
		}
	}

	print_month(ctx, year, int(month), day)
}

@(private = "file")
print_month :: proc(ctx: ^Cmd_Ctx, year: int, month: int, highlight: int) {
	MONTH_NAMES :: [?]string {
		"January",
		"February",
		"March",
		"April",
		"May",
		"June",
		"July",
		"August",
		"September",
		"October",
		"November",
		"December",
	}

	names := MONTH_NAMES
	title := fmt.tprintf("%s %d", names[month - 1], year)

	// Centre the title over the 20-column grid.
	padding := max(0, (20 - len(title)) / 2)
	outf(ctx, "%*s%s\n", padding, "", title)
	out(ctx, "\x1b[1mMo Tu We Th Fr Sa Su\x1b[0m\n")

	first := day_of_week(year, month, 1) // 0 = Monday
	total := days_in_month(year, month)

	b := strings.builder_make(context.temp_allocator)
	for _ in 0 ..< first {
		strings.write_string(&b, "   ")
	}

	column := first
	for d in 1 ..= total {
		if d == highlight {
			fmt.sbprintf(&b, "\x1b[7m%s\x1b[0m ", pad_int(d, 2))
		} else {
			fmt.sbprintf(&b, "%s ", pad_int(d, 2))
		}

		column += 1
		if column == 7 {
			strings.write_string(&b, "\n")
			column = 0
		}
	}
	if column != 0 {
		strings.write_string(&b, "\n")
	}

	out(ctx, strings.to_string(b))
}

// Zeller's congruence, returning 0 for Monday.
@(private = "file")
day_of_week :: proc(year: int, month: int, day: int) -> int {
	y := year
	m := month
	if m < 3 {
		m += 12
		y -= 1
	}

	k := y % 100
	j := y / 100
	h := (day + (13 * (m + 1)) / 5 + k + k / 4 + j / 4 + 5 * j) % 7

	// Zeller gives 0 = Saturday; shift so that 0 = Monday.
	return (h + 5) % 7
}

@(private = "file")
days_in_month :: proc(year: int, month: int) -> int {
	switch month {
	case 1, 3, 5, 7, 8, 10, 12:
		return 31
	case 4, 6, 9, 11:
		return 30
	case 2:
		leap := (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
		return leap ? 29 : 28
	}
	return 30
}

// ---------------------------------------------------------------------------
// Mail
//
// Built on the VFS rather than a second store: a message is a file under
// /home/<user>/mail, so it inherits the quotas, the permissions and the
// snapshotting that already exist. The only thing needed beyond the ordinary
// rules is the ability to write into someone else's mail directory, which is
// what makes it a mailbox rather than a shared folder.
// ---------------------------------------------------------------------------

MAX_MAIL_PER_USER :: 50
MAX_MAIL_LEN      :: 2000

cmd_mail :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	user := client_get_user(c, context.temp_allocator)
	if len(user) == 0 {
		errf(ctx, "mail: you need an account to send or receive mail\n")
		out(ctx, "  \x1b[36mregister\x1b[0m creates one.\n")
		return
	}

	if len(args) == 0 {
		mail_list(ctx, user)
		return
	}

	switch strings.to_lower(args[0], context.temp_allocator) {
	case "send":
		if len(args) < 3 {
			errf(ctx, "mail: usage: mail send <user> <message>\n")
			return
		}
		mail_send(ctx, user, args[1], join_args(args[2:]))

	case "read":
		if len(args) < 2 {
			errf(ctx, "mail: usage: mail read <number>\n")
			return
		}
		mail_read(ctx, user, args[1])

	case "clear":
		mail_clear(ctx, user)

	case:
		errf(ctx, "mail: unknown subcommand '%s'\n",
			sanitize_text(args[0], 20, context.temp_allocator))
		out(ctx, "  \x1b[36mmail\x1b[0m, \x1b[36mmail send <user> <text>\x1b[0m, ")
		out(ctx, "\x1b[36mmail read <n>\x1b[0m, \x1b[36mmail clear\x1b[0m\n")
	}
}

@(private = "file")
mail_dir :: proc(user: string) -> string {
	return fmt.tprintf("/home/%s/mail", user)
}

@(private = "file")
mail_send :: proc(ctx: ^Cmd_Ctx, from: string, to_raw: string, body: string) {
	c := ctx.client

	// Delivering into someone else's home is a broadcast-shaped privilege, so
	// it draws on the same budget.
	if !rate_allow(&c.rl_broadcast) {
		errf(ctx, "mail: too soon, wait %.0fs\n", rate_retry_after(&c.rl_broadcast))
		return
	}

	to := auth_canonical(to_raw, context.temp_allocator)
	if !auth_exists(&g_users, to) {
		errf(ctx, "mail: %s: no such account\n",
			sanitize_text(to_raw, MAX_NAME_LEN, context.temp_allocator))
		return
	}

	message := sanitize_text(body, MAX_MAIL_LEN, context.temp_allocator)
	if len(message) == 0 {
		errf(ctx, "mail: nothing to send\n")
		return
	}

	dir := mail_dir(to)
	vfs_mkdir_direct(dir, to)

	existing := vfs_walk(&g_vfs, dir, to, context.temp_allocator)
	if len(existing) >= MAX_MAIL_PER_USER {
		errf(ctx, "mail: %s's mailbox is full\n", to)
		return
	}

	now := unix_now()
	path := fmt.tprintf("%s/%d-%s.txt", dir, now, from)
	content := fmt.tprintf("From: %s\nDate: %d\n\n%s\n", from, now, message)

	// Written as the recipient so the message belongs to them: the sender
	// cannot later edit or delete what they sent.
	if err := vfs_write_as_owner(path, content, to); err != .None {
		errf(ctx, "mail: could not deliver: %s\n", vfs_error_string(err))
		return
	}

	outf(ctx, "\x1b[90msent to %s\x1b[0m\n", to)

	// If they are online, let them know without interrupting what they type.
	notify_mail(to, from)
}

@(private = "file")
notify_mail :: proc(to: string, from: string) {
	sync.mutex_lock(&g_clients_lock)
	defer sync.mutex_unlock(&g_clients_lock)

	for other in g_clients {
		sync.mutex_lock(&other.state_lock)
		matches := other.user == to
		sync.mutex_unlock(&other.state_lock)

		if matches {
			client_send_notice(
				other,
				fmt.tprintf(
					"\x1b[36m*\x1b[0m you have new mail from \x1b[1m%s\x1b[0m (type \x1b[36mmail\x1b[0m)\r\n",
					sanitize_text(from, MAX_NAME_LEN, context.temp_allocator),
				),
			)
		}
	}
}

@(private = "file")
mail_list :: proc(ctx: ^Cmd_Ctx, user: string) {
	dir := mail_dir(user)
	paths := vfs_walk(&g_vfs, dir, user, context.temp_allocator)

	if len(paths) == 0 {
		out(ctx, "no mail\n")
		out(ctx, "\x1b[90msend some with: mail send <user> <message>\x1b[0m\n")
		return
	}

	slice.sort(paths)

	outf(ctx, "\x1b[1m%d message(s)\x1b[0m\n", len(paths))
	for p, i in paths {
		content, ok := vfs_read(&g_vfs, p, user, context.temp_allocator)
		if !ok {
			continue
		}

		sender := "unknown"
		when_sent := i64(0)
		preview := ""

		lines := input_lines(content)
		for line, index in lines {
			if strings.has_prefix(line, "From: ") {
				sender = line[6:]
			} else if strings.has_prefix(line, "Date: ") {
				if n, parsed := parse_positive_int(line[6:]); parsed {
					when_sent = i64(n)
				}
			} else if len(strings.trim_space(line)) > 0 && index >= 2 && len(preview) == 0 {
				preview = line
			}
		}

		if len(preview) > 40 {
			preview = preview[:40]
		}

		outf(
			ctx,
			"%s  \x1b[1m%-14s\x1b[0m %-42s \x1b[90m%s\x1b[0m\n",
			pad_int(i + 1, 3),
			sanitize_text(sender, MAX_NAME_LEN, context.temp_allocator),
			sanitize_text(preview, 42, context.temp_allocator),
			format_timestamp(when_sent),
		)
	}
	out(ctx, "\n\x1b[90mmail read <number> to open one\x1b[0m\n")
}

@(private = "file")
mail_read :: proc(ctx: ^Cmd_Ctx, user: string, which: string) {
	index, ok := parse_positive_int(which)
	if !ok || index < 1 {
		errf(ctx, "mail: '%s' is not a message number\n",
			sanitize_text(which, 20, context.temp_allocator))
		return
	}

	paths := vfs_walk(&g_vfs, mail_dir(user), user, context.temp_allocator)
	slice.sort(paths)

	if index > len(paths) {
		errf(ctx, "mail: there is no message %d\n", index)
		return
	}

	content, read_ok := vfs_read(&g_vfs, paths[index - 1], user, context.temp_allocator)
	if !read_ok {
		errf(ctx, "mail: could not read message %d\n", index)
		return
	}

	for line in input_lines(content) {
		if strings.has_prefix(line, "From: ") {
			outf(ctx, "\x1b[1mFrom:\x1b[0m %s\n",
				sanitize_text(line[6:], MAX_NAME_LEN, context.temp_allocator))
			continue
		}
		if strings.has_prefix(line, "Date: ") {
			if n, parsed := parse_positive_int(line[6:]); parsed {
				outf(ctx, "\x1b[1mSent:\x1b[0m %s\n", format_timestamp(i64(n)))
			}
			continue
		}
		outf(ctx, "%s\n", sanitize_text(line, 400, context.temp_allocator))
	}
}

@(private = "file")
mail_clear :: proc(ctx: ^Cmd_Ctx, user: string) {
	paths := vfs_walk(&g_vfs, mail_dir(user), user, context.temp_allocator)

	removed := 0
	for p in paths {
		if vfs_rm(&g_vfs, p, user) == .None {
			removed += 1
		}
	}
	outf(ctx, "removed %d message(s)\n", removed)
}
