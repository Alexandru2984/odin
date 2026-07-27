package main

import "core:fmt"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Command dispatch
//
// Commands write through a Cmd_Ctx rather than straight to the socket. That
// indirection is what makes output redirection (`>` and `>>`) work uniformly
// for every command instead of being special-cased inside `echo`, and it is
// where the per-command output cap is enforced.
// ---------------------------------------------------------------------------

Cmd_Ctx :: struct {
	client:  ^Client,
	capture: ^strings.Builder, // non-nil while redirecting to a file
	lines:   int,
	truncated: bool,
}

// Writes command output. Newlines are normalised to CRLF for the terminal but
// left alone when captured to a file.
out :: proc(ctx: ^Cmd_Ctx, s: string) {
	if ctx.truncated {
		return
	}

	ctx.lines += strings.count(s, "\n")
	if ctx.lines > MAX_OUTPUT_LINES {
		ctx.truncated = true
		if ctx.capture == nil {
			client_send(ctx.client, "\r\n\x1b[31m[output truncated]\x1b[0m\r\n")
		}
		return
	}

	if ctx.capture != nil {
		strings.write_string(ctx.capture, s)
		return
	}

	// The terminal needs CRLF; commands are written with plain \n.
	crlf, _ := strings.replace_all(s, "\n", "\r\n", context.temp_allocator)
	client_send(ctx.client, crlf)
}

outf :: proc(ctx: ^Cmd_Ctx, format: string, args: ..any) {
	out(ctx, fmt.tprintf(format, ..args))
}

// Error output, coloured red for the terminal.
errf :: proc(ctx: ^Cmd_Ctx, format: string, args: ..any) {
	if ctx.capture != nil {
		out(ctx, fmt.tprintf(format, ..args))
		return
	}
	out(ctx, fmt.tprintf("\x1b[31m%s\x1b[0m", fmt.tprintf(format, ..args)))
}

Command :: struct {
	name:     string,
	category: string,
	usage:    string,
	help:     string,
	handler:  proc(ctx: ^Cmd_Ctx, args: []string),
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

execute_command :: proc(c: ^Client, line: string) {
	args := split_args(line, context.temp_allocator)
	if len(args) == 0 {
		return
	}

	// Split off a trailing redirection before the command sees its arguments.
	redirect_path := ""
	redirect_append := false
	cmd_args, ok := extract_redirect(args[:], &redirect_path, &redirect_append)
	if !ok {
		client_send(c, "\x1b[31msyntax error: expected a file name after '>'\x1b[0m\r\n")
		return
	}
	if len(cmd_args) == 0 {
		return
	}

	name := strings.to_lower(cmd_args[0], context.temp_allocator)

	command, found := find_command(name)
	if !found {
		client_sendf(
			c,
			"\x1b[31m%s: command not found\x1b[0m%s\r\n",
			sanitize_text(cmd_args[0], 32, context.temp_allocator),
			format_suggestions(name),
		)
		return
	}

	ctx := Cmd_Ctx {
		client = c,
	}

	builder: strings.Builder
	if len(redirect_path) > 0 {
		if !rate_allow(&c.rl_write) {
			client_send(c, "\x1b[31mwriting too fast, slow down\x1b[0m\r\n")
			return
		}
		builder = strings.builder_make(context.temp_allocator)
		ctx.capture = &builder
	}

	command.handler(&ctx, cmd_args[1:])

	if len(redirect_path) > 0 {
		finish_redirect(c, &ctx, redirect_path, redirect_append)
	}
}

// Pulls a trailing `> file` / `>> file` off the argument list.
@(private = "file")
extract_redirect :: proc(
	args: []string,
	out_path: ^string,
	out_append: ^bool,
) -> (remaining: []string, ok: bool) {
	for i in 0 ..< len(args) {
		arg := args[i]
		if len(arg) == 0 || arg[0] != '>' {
			continue
		}

		is_append := strings.has_prefix(arg, ">>")
		marker_len := is_append ? 2 : 1

		target := arg[marker_len:]
		if len(target) == 0 {
			// The filename is the next token.
			if i + 1 >= len(args) {
				return nil, false
			}
			target = args[i + 1]
		}

		out_path^ = target
		out_append^ = is_append
		return args[:i], true
	}
	return args, true
}

@(private = "file")
finish_redirect :: proc(c: ^Client, ctx: ^Cmd_Ctx, target: string, append_mode: bool) {
	cwd := client_get_cwd(c, context.temp_allocator)
	user := client_get_user(c, context.temp_allocator)
	abs := vfs_resolve_path(cwd, unquote(target), context.temp_allocator)

	content := strings.to_string(ctx.capture^)

	err: VFS_Error
	if append_mode {
		err = vfs_append(&g_vfs, abs, content, user)
	} else {
		err = vfs_write(&g_vfs, abs, content, user)
	}

	if err != .None {
		client_sendf(c, "\x1b[31m%s: %s\x1b[0m\r\n", target, vfs_error_string(err))
	}
}

find_command :: proc(name: string) -> (cmd: Command, found: bool) {
	for c in COMMANDS {
		if c.name == name {
			return c, true
		}
	}
	for a in ALIASES {
		if a.from == name {
			return find_command(a.to)
		}
	}
	return {}, false
}

Alias :: struct {
	from: string,
	to:   string,
}

// A flat table rather than a map: a map literal would have to allocate at
// startup through whatever context.allocator happened to be current, and this
// is looked up rarely enough that a linear scan is free.
@(rodata)
ALIASES := [?]Alias {
	{"dir", "ls"},
	{"ll", "ls"},
	{"type", "cat"},
	{"del", "rm"},
	{"md", "mkdir"},
	{"cls", "clear"},
	{"quit", "logout"},
	{"exit", "logout"},
	{"nick", "name"},
	{"users", "who"},
	{"?", "help"},
	{"info", "neofetch"},
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

// Resolves a user-supplied path argument against the client's cwd.
resolve_arg :: proc(c: ^Client, arg: string) -> string {
	cwd := client_get_cwd(c, context.temp_allocator)
	return vfs_resolve_path(cwd, unquote(arg), context.temp_allocator)
}

// Joins arguments back into a single space-separated string.
join_args :: proc(args: []string) -> string {
	return strings.join(args, " ", context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Filesystem commands
// ---------------------------------------------------------------------------

cmd_pwd :: proc(ctx: ^Cmd_Ctx, args: []string) {
	cwd := client_get_cwd(ctx.client, context.temp_allocator)
	outf(ctx, "%s\n", cwd)
}

cmd_cd :: proc(ctx: ^Cmd_Ctx, args: []string) {
	target: string
	if len(args) == 0 {
		// Bare `cd` goes home: the user's home directory if they have one,
		// otherwise the shared scratch space.
		user := client_get_user(ctx.client, context.temp_allocator)
		if len(user) > 0 {
			target = fmt.tprintf("/home/%s", user)
		} else {
			target = "/tmp"
		}
	} else {
		target = resolve_arg(ctx.client, args[0])
	}

	if !vfs_is_dir(&g_vfs, target) {
		errf(ctx, "cd: %s: %s\n", args[0] if len(args) > 0 else target, vfs_error_string(.Not_Found))
		return
	}

	client_set_cwd(ctx.client, target)
}

cmd_ls :: proc(ctx: ^Cmd_Ctx, args: []string) {
	long := false
	all := false
	targets := make([dynamic]string, context.temp_allocator)

	for a in args {
		if len(a) > 1 && a[0] == '-' {
			for i in 1 ..< len(a) {
				switch a[i] {
				case 'l':
					long = true
				case 'a':
					all = true
				}
			}
		} else {
			append(&targets, a)
		}
	}
	_ = all

	dir := client_get_cwd(ctx.client, context.temp_allocator)
	if len(targets) > 0 {
		dir = resolve_arg(ctx.client, targets[0])
	}

	user := client_get_user(ctx.client, context.temp_allocator)

	entries, err := vfs_list(&g_vfs, dir, user, context.temp_allocator)
	if err != .None {
		errf(ctx, "ls: %s: %s\n", dir, vfs_error_string(err))
		return
	}

	slice.sort_by(entries, proc(a, b: VFS_Stat) -> bool {
		// Directories first, then alphabetical.
		if (a.type == .Directory) != (b.type == .Directory) {
			return a.type == .Directory
		}
		return a.name < b.name
	})

	if len(entries) == 0 {
		return
	}

	if long {
		for e in entries {
			kind := e.type == .Directory ? "d" : "-"
			perm := perm_string(e.perm)
			owner := len(e.owner) > 0 ? e.owner : "system"
			size := e.type == .Directory ? "-" : human_size(e.size, context.temp_allocator)
			outf(
				ctx,
				"%s%s %-12s %6s  %s%s\n",
				kind,
				perm,
				owner,
				size,
				colorize_name(ctx, e),
				e.type == .Directory ? "/" : "",
			)
		}
		return
	}

	// Simple column-free listing; the browser terminal wraps it sensibly.
	b := strings.builder_make(context.temp_allocator)
	for e, i in entries {
		if i > 0 {
			strings.write_string(&b, "  ")
		}
		strings.write_string(&b, colorize_name(ctx, e))
		if e.type == .Directory {
			strings.write_string(&b, "/")
		}
	}
	strings.write_string(&b, "\n")
	out(ctx, strings.to_string(b))
}

@(private = "file")
colorize_name :: proc(ctx: ^Cmd_Ctx, e: VFS_Stat) -> string {
	// Captured output goes into a file; escape codes would be stored verbatim.
	if ctx.capture != nil {
		return e.name
	}
	if e.type == .Directory {
		return fmt.tprintf("\x1b[1;34m%s\x1b[0m", e.name)
	}
	if e.perm == .Private {
		return fmt.tprintf("\x1b[33m%s\x1b[0m", e.name)
	}
	return e.name
}

perm_string :: proc(p: VFS_Perm) -> string {
	switch p {
	case .Public:
		return "rw-rw-"
	case .Owner_Only:
		return "rw-r--"
	case .Private:
		return "rw----"
	}
	return "------"
}

cmd_mkdir :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "mkdir: missing operand\n")
		return
	}
	if !rate_allow(&ctx.client.rl_write) {
		errf(ctx, "mkdir: too many writes, slow down\n")
		return
	}

	parents := false
	targets := make([dynamic]string, context.temp_allocator)
	for a in args {
		if a == "-p" {
			parents = true
		} else {
			append(&targets, a)
		}
	}

	user := client_get_user(ctx.client, context.temp_allocator)

	for t in targets {
		abs := resolve_arg(ctx.client, t)
		err := parents ? vfs_mkdir_all(&g_vfs, abs, user) : vfs_mkdir(&g_vfs, abs, user)
		if err != .None {
			errf(ctx, "mkdir: %s: %s\n", t, vfs_error_string(err))
			continue
		}
		announce(ctx.client, fmt.tprintf("created directory %s", abs))
	}
}

cmd_rmdir :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "rmdir: missing operand\n")
		return
	}
	user := client_get_user(ctx.client, context.temp_allocator)

	for t in args {
		abs := resolve_arg(ctx.client, t)
		if err := vfs_rmdir(&g_vfs, abs, user); err != .None {
			errf(ctx, "rmdir: %s: %s\n", t, vfs_error_string(err))
			continue
		}
		announce(ctx.client, fmt.tprintf("removed directory %s", abs))
	}
}

cmd_rm :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "rm: missing operand\n")
		return
	}
	if !rate_allow(&ctx.client.rl_write) {
		errf(ctx, "rm: too many writes, slow down\n")
		return
	}

	recursive := false
	targets := make([dynamic]string, context.temp_allocator)
	for a in args {
		if a == "-r" || a == "-rf" || a == "-fr" || a == "-R" {
			recursive = true
		} else if len(a) > 0 && a[0] == '-' {
			continue
		} else {
			append(&targets, a)
		}
	}

	user := client_get_user(ctx.client, context.temp_allocator)

	for t in targets {
		abs := resolve_arg(ctx.client, t)
		if recursive {
			n, err := vfs_rm_recursive(&g_vfs, abs, user)
			if err != .None {
				errf(ctx, "rm: %s: %s\n", t, vfs_error_string(err))
				continue
			}
			announce(ctx.client, fmt.tprintf("removed %s (%d entries)", abs, n))
		} else {
			if err := vfs_rm(&g_vfs, abs, user); err != .None {
				errf(ctx, "rm: %s: %s\n", t, vfs_error_string(err))
				continue
			}
			announce(ctx.client, fmt.tprintf("removed %s", abs))
		}
	}
}

cmd_touch :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "touch: missing operand\n")
		return
	}
	user := client_get_user(ctx.client, context.temp_allocator)

	for t in args {
		abs := resolve_arg(ctx.client, t)
		if vfs_exists(&g_vfs, abs) {
			continue
		}
		if err := vfs_write(&g_vfs, abs, "", user); err != .None {
			errf(ctx, "touch: %s: %s\n", t, vfs_error_string(err))
		}
	}
}

cmd_cat :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "cat: missing file name\n")
		return
	}
	user := client_get_user(ctx.client, context.temp_allocator)

	for t in args {
		abs := resolve_arg(ctx.client, t)
		content, ok := vfs_read(&g_vfs, abs, user, context.temp_allocator)
		if !ok {
			if vfs_is_dir(&g_vfs, abs) {
				errf(ctx, "cat: %s: %s\n", t, vfs_error_string(.Is_A_Directory))
			} else {
				errf(ctx, "cat: %s: %s\n", t, vfs_error_string(.Not_Found))
			}
			continue
		}
		// File contents are user data and may contain anything, so they are
		// sanitized before being rendered into a terminal.
		out(ctx, sanitize_file(ctx, content))
		if len(content) > 0 && !strings.has_suffix(content, "\n") {
			out(ctx, "\n")
		}
	}
}

// File contents may hold arbitrary bytes written by any user. Strip control
// characters (but keep newlines) before rendering into someone's terminal.
@(private = "file")
sanitize_file :: proc(ctx: ^Cmd_Ctx, content: string) -> string {
	if ctx.capture != nil {
		return content // going back to a file, not a terminal
	}

	b := strings.builder_make(context.temp_allocator)
	for r in content {
		if r == '\n' || r == '\t' {
			strings.write_rune(&b, r)
			continue
		}
		if is_safe_rune(r) {
			strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

cmd_echo :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// Redirection is handled generically by execute_command, so echo is now
	// just echo. The old implementation parsed '>' by slicing the raw line at
	// hard-coded offsets.
	text := join_args(args)
	outf(ctx, "%s\n", unquote(text))
}

cmd_cp :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) < 2 {
		errf(ctx, "cp: usage: cp <source> <destination>\n")
		return
	}
	user := client_get_user(ctx.client, context.temp_allocator)

	src := resolve_arg(ctx.client, args[0])
	dst := resolve_arg(ctx.client, args[1])

	content, ok := vfs_read(&g_vfs, src, user, context.temp_allocator)
	if !ok {
		errf(ctx, "cp: %s: %s\n", args[0], vfs_error_string(.Not_Found))
		return
	}

	// Copying onto a directory means "into" it, as in a real shell.
	final := dst
	if vfs_is_dir(&g_vfs, dst) {
		final = path.join({dst, path.base(src)}, context.temp_allocator)
	}

	if err := vfs_write(&g_vfs, final, content, user); err != .None {
		errf(ctx, "cp: %s: %s\n", args[1], vfs_error_string(err))
	}
}

cmd_mv :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) < 2 {
		errf(ctx, "mv: usage: mv <source> <destination>\n")
		return
	}
	user := client_get_user(ctx.client, context.temp_allocator)

	src := resolve_arg(ctx.client, args[0])
	dst := resolve_arg(ctx.client, args[1])

	content, ok := vfs_read(&g_vfs, src, user, context.temp_allocator)
	if !ok {
		errf(ctx, "mv: %s: %s\n", args[0], vfs_error_string(.Not_Found))
		return
	}

	final := dst
	if vfs_is_dir(&g_vfs, dst) {
		final = path.join({dst, path.base(src)}, context.temp_allocator)
	}

	if err := vfs_write(&g_vfs, final, content, user); err != .None {
		errf(ctx, "mv: %s: %s\n", args[1], vfs_error_string(err))
		return
	}
	// Only unlink the source once the destination is safely written.
	if err := vfs_rm(&g_vfs, src, user); err != .None {
		errf(ctx, "mv: %s: %s\n", args[0], vfs_error_string(err))
	}
}

cmd_stat :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "stat: missing operand\n")
		return
	}
	user := client_get_user(ctx.client, context.temp_allocator)
	abs := resolve_arg(ctx.client, args[0])

	st, ok := vfs_stat(&g_vfs, abs, user, context.temp_allocator)
	if !ok {
		errf(ctx, "stat: %s: %s\n", args[0], vfs_error_string(.Not_Found))
		return
	}

	outf(ctx, "  File: %s\n", abs)
	outf(ctx, "  Type: %s\n", st.type == .Directory ? "directory" : "file")
	outf(ctx, "  Size: %d bytes\n", st.size)
	outf(ctx, " Owner: %s\n", len(st.owner) > 0 ? st.owner : "system")
	outf(ctx, "Access: %s\n", perm_string(st.perm))
	outf(ctx, "Modify: %s\n", format_timestamp(st.modified))
}

cmd_chmod :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) < 2 {
		errf(ctx, "chmod: usage: chmod <public|owner|private> <path>\n")
		return
	}

	perm: VFS_Perm
	switch strings.to_lower(args[0], context.temp_allocator) {
	case "public":
		perm = .Public
	case "owner":
		perm = .Owner_Only
	case "private":
		perm = .Private
	case:
		errf(ctx, "chmod: unknown mode '%s' (use public, owner or private)\n", args[0])
		return
	}

	user := client_get_user(ctx.client, context.temp_allocator)
	if len(user) == 0 {
		errf(ctx, "chmod: you must be logged in to own files\n")
		return
	}

	abs := resolve_arg(ctx.client, args[1])
	if err := vfs_chmod(&g_vfs, abs, perm, user); err != .None {
		errf(ctx, "chmod: %s: %s\n", args[1], vfs_error_string(err))
	}
}

cmd_tree :: proc(ctx: ^Cmd_Ctx, args: []string) {
	root := client_get_cwd(ctx.client, context.temp_allocator)
	if len(args) > 0 {
		root = resolve_arg(ctx.client, args[0])
	}
	if !vfs_is_dir(&g_vfs, root) {
		errf(ctx, "tree: %s: %s\n", root, vfs_error_string(.Not_A_Directory))
		return
	}

	user := client_get_user(ctx.client, context.temp_allocator)
	paths := vfs_walk(&g_vfs, root, user, context.temp_allocator)
	slice.sort(paths)

	outf(ctx, "%s\n", root)

	prefix_len := root == "/" ? 1 : len(root) + 1
	dirs, files := 0, 0

	for p in paths {
		rel := p[prefix_len:]
		depth := strings.count(rel, "/")

		indent := strings.repeat("  ", depth, context.temp_allocator)
		name := path.base(p)

		if vfs_is_dir(&g_vfs, p) {
			outf(ctx, "%s|- \x1b[1;34m%s\x1b[0m/\n", indent, name)
			dirs += 1
		} else {
			outf(ctx, "%s|- %s\n", indent, name)
			files += 1
		}
	}

	outf(ctx, "\n%d directories, %d files\n", dirs, files)
}

cmd_find :: proc(ctx: ^Cmd_Ctx, args: []string) {
	root := client_get_cwd(ctx.client, context.temp_allocator)
	pattern := ""

	for a in args {
		if len(a) > 0 && a[0] == '/' {
			root = vfs_resolve_path("/", a, context.temp_allocator)
		} else {
			pattern = a
		}
	}

	user := client_get_user(ctx.client, context.temp_allocator)
	paths := vfs_walk(&g_vfs, root, user, context.temp_allocator)
	slice.sort(paths)

	found := 0
	for p in paths {
		if len(pattern) == 0 || strings.contains(path.base(p), pattern) {
			outf(ctx, "%s\n", p)
			found += 1
		}
	}
	if found == 0 {
		outf(ctx, "no matches\n")
	}
}

cmd_grep :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) < 2 {
		errf(ctx, "grep: usage: grep <pattern> <file...>\n")
		return
	}

	pattern := unquote(args[0])
	user := client_get_user(ctx.client, context.temp_allocator)
	multiple := len(args) > 2

	for t in args[1:] {
		abs := resolve_arg(ctx.client, t)
		content, ok := vfs_read(&g_vfs, abs, user, context.temp_allocator)
		if !ok {
			errf(ctx, "grep: %s: %s\n", t, vfs_error_string(.Not_Found))
			continue
		}

		for line, i in strings.split_lines(content, context.temp_allocator) {
			if !strings.contains(line, pattern) {
				continue
			}
			safe := sanitize_text(line, 400, context.temp_allocator)
			if multiple {
				outf(ctx, "%s:%d: %s\n", t, i + 1, safe)
			} else {
				outf(ctx, "%d: %s\n", i + 1, safe)
			}
		}
	}
}

cmd_head :: proc(ctx: ^Cmd_Ctx, args: []string) {
	head_tail(ctx, args, true)
}

cmd_tail :: proc(ctx: ^Cmd_Ctx, args: []string) {
	head_tail(ctx, args, false)
}

@(private = "file")
head_tail :: proc(ctx: ^Cmd_Ctx, args: []string, from_start: bool) {
	name := from_start ? "head" : "tail"
	count := 10
	target := ""

	i := 0
	for i < len(args) {
		if args[i] == "-n" && i + 1 < len(args) {
			if n, ok := parse_positive_int(args[i + 1]); ok {
				count = min(n, MAX_OUTPUT_LINES)
			}
			i += 2
			continue
		}
		target = args[i]
		i += 1
	}

	if len(target) == 0 {
		errf(ctx, "%s: missing file name\n", name)
		return
	}

	user := client_get_user(ctx.client, context.temp_allocator)
	abs := resolve_arg(ctx.client, target)
	content, ok := vfs_read(&g_vfs, abs, user, context.temp_allocator)
	if !ok {
		errf(ctx, "%s: %s: %s\n", name, target, vfs_error_string(.Not_Found))
		return
	}

	lines := strings.split_lines(content, context.temp_allocator)
	// split_lines yields a trailing empty element for content ending in \n.
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}

	selected := lines
	if len(lines) > count {
		selected = from_start ? lines[:count] : lines[len(lines) - count:]
	}

	for line in selected {
		outf(ctx, "%s\n", sanitize_text(line, 400, context.temp_allocator))
	}
}

cmd_wc :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "wc: missing file name\n")
		return
	}
	user := client_get_user(ctx.client, context.temp_allocator)

	for t in args {
		abs := resolve_arg(ctx.client, t)
		content, ok := vfs_read(&g_vfs, abs, user, context.temp_allocator)
		if !ok {
			errf(ctx, "wc: %s: %s\n", t, vfs_error_string(.Not_Found))
			continue
		}
		lines := strings.count(content, "\n")
		words := len(strings.fields(content, context.temp_allocator))
		outf(ctx, "%8d %8d %8d  %s\n", lines, words, len(content), t)
	}
}

cmd_du :: proc(ctx: ^Cmd_Ctx, args: []string) {
	root := client_get_cwd(ctx.client, context.temp_allocator)
	if len(args) > 0 {
		root = resolve_arg(ctx.client, args[0])
	}

	user := client_get_user(ctx.client, context.temp_allocator)
	paths := vfs_walk(&g_vfs, root, user, context.temp_allocator)

	total := 0
	count := 0
	for p in paths {
		if st, ok := vfs_stat(&g_vfs, p, user, context.temp_allocator); ok {
			total += st.size
			count += 1
		}
	}

	outf(ctx, "%s  %s (%d entries)\n", human_size(total, context.temp_allocator), root, count)
}

cmd_df :: proc(ctx: ^Cmd_Ctx, args: []string) {
	u := vfs_usage(&g_vfs)

	pct_entries := f64(u.entries) / f64(u.max_entries) * 100
	pct_bytes := f64(u.total_bytes) / f64(u.max_bytes) * 100

	outf(ctx, "Filesystem      Used      Avail     Use%%\n")
	outf(
		ctx,
		"entries      %7d   %8d   %5.1f%%\n",
		u.entries,
		u.max_entries - u.entries,
		pct_entries,
	)
	outf(
		ctx,
		"storage      %7s   %8s   %5.1f%%\n",
		human_size(u.total_bytes, context.temp_allocator),
		human_size(u.max_bytes - u.total_bytes, context.temp_allocator),
		pct_bytes,
	)
}

parse_positive_int :: proc(s: string) -> (val: int, ok: bool) {
	n := 0
	if len(s) == 0 {
		return 0, false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n * 10 + int(c - '0')
		if n > 1_000_000 {
			return 1_000_000, true // clamp rather than overflow
		}
	}
	return n, true
}

// ---------------------------------------------------------------------------
// System notices
// ---------------------------------------------------------------------------

// Announces a filesystem change to everyone else.
//
// The old code broadcast one of these for every mkdir/rm/echo with no rate
// limit at all, so a loop of `mkdir` was also a way to spam every connected
// terminal. Now it is bounded by the same broadcast budget as `wall`, and
// silently skipped rather than refused when the budget is gone.
announce :: proc(c: ^Client, action: string) {
	if !rate_allow(&c.rl_broadcast) {
		return
	}

	name := client_get_name(c, context.temp_allocator)
	safe := sanitize_text(action, 200, context.temp_allocator)

	broadcast_notice(
		fmt.tprintf("\x1b[33m[system]\x1b[0m %s %s\r\n", name, safe),
		c.id,
	)
}

format_timestamp :: proc(unix_seconds: i64) -> string {
	// Rendered as an age rather than a wall-clock date: there is no timezone
	// context here, and "3m ago" is more useful in a shared session anyway.
	delta := unix_now() - unix_seconds
	switch {
	case delta < 60:
		return fmt.tprintf("%ds ago", delta)
	case delta < 3600:
		return fmt.tprintf("%dm ago", delta / 60)
	case delta < 86400:
		return fmt.tprintf("%dh ago", delta / 3600)
	}
	return fmt.tprintf("%dd ago", delta / 86400)
}

// ---------------------------------------------------------------------------
// Autocomplete
// ---------------------------------------------------------------------------

handle_autocomplete :: proc(c: ^Client) {
	sync.mutex_lock(&c.state_lock)
	line := strings.clone(string(c.line[:c.cursor]), context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)

	last_space := strings.last_index_any(line, " \t")
	is_command := last_space < 0
	prefix := last_space < 0 ? line : line[last_space + 1:]

	matches := make([dynamic]string, context.temp_allocator)

	if is_command {
		for cmd in COMMANDS {
			if strings.has_prefix(cmd.name, prefix) {
				append(&matches, cmd.name)
			}
		}
	} else {
		// Complete a path. Split off the directory part so completion works
		// inside nested directories, not just the cwd.
		dir_part := ""
		base_part := prefix
		if slash := strings.last_index_byte(prefix, '/'); slash >= 0 {
			dir_part = prefix[:slash]
			if len(dir_part) == 0 {
				dir_part = "/"
			}
			base_part = prefix[slash + 1:]
		}

		dir := len(dir_part) > 0 ? resolve_arg(c, dir_part) : client_get_cwd(c, context.temp_allocator)
		user := client_get_user(c, context.temp_allocator)

		entries, err := vfs_list(&g_vfs, dir, user, context.temp_allocator)
		if err == .None {
			for e in entries {
				if !strings.has_prefix(e.name, base_part) {
					continue
				}
				suffix := e.type == .Directory ? "/" : ""
				append(&matches, fmt.tprintf("%s%s", e.name, suffix))
			}
		}
		prefix = base_part
	}

	if len(matches) == 0 {
		return
	}

	slice.sort(matches[:])

	if len(matches) == 1 {
		completion := matches[0][len(prefix):]
		// A directory completion continues with '/', so no trailing space.
		if !strings.has_suffix(matches[0], "/") {
			completion = fmt.tprintf("%s ", completion)
		}
		insert_text(c, completion)
		return
	}

	// Several candidates: extend by the longest shared prefix, then list them.
	common := longest_common_prefix(matches[:])
	if len(common) > len(prefix) {
		insert_text(c, common[len(prefix):])
	}

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\r\n")
	for m, i in matches {
		if i > 0 {
			strings.write_string(&b, "  ")
		}
		strings.write_string(&b, m)
	}
	strings.write_string(&b, "\r\n")
	client_send(c, strings.to_string(b))
	client_send_prompt(c)
}

@(private = "file")
insert_text :: proc(c: ^Client, text: string) {
	sync.mutex_lock(&c.state_lock)
	for i in 0 ..< len(text) {
		if len(c.line) >= MAX_LINE_LEN {
			break
		}
		append(&c.line, 0)
		copy(c.line[c.cursor + 1:], c.line[c.cursor:len(c.line) - 1])
		c.line[c.cursor] = text[i]
		c.cursor += 1
	}
	s := client_redraw_string_locked(c, context.temp_allocator)
	sync.mutex_unlock(&c.state_lock)
	client_send(c, s)
}

@(private = "file")
longest_common_prefix :: proc(items: []string) -> string {
	if len(items) == 0 {
		return ""
	}
	prefix := items[0]
	for item in items[1:] {
		n := min(len(prefix), len(item))
		i := 0
		for i < n && prefix[i] == item[i] {
			i += 1
		}
		prefix = prefix[:i]
	}
	return prefix
}
