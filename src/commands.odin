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
	capture: ^strings.Builder, // non-nil when output feeds a pipe or a file
	// Output of the previous pipeline stage. Commands that take a file
	// argument read this instead when none is given, which is what makes
	// `cat x | grep y` behave the way anyone would expect.
	stdin:   string,
	lines:   int,
	truncated: bool,
	// 0 means success. `&&` and `||` are built on this, and errf sets it, so
	// any command that reports an error automatically breaks a chain.
	status:  int,

	// Where the command is standing and who it is acting as, resolved once
	// when the stage starts.
	//
	// Commands used to reach into the live session for both. A background job
	// runs on another thread, against a session that can `cd` or `logout` out
	// from under it, so it needs its own copy — and taking the copy at the
	// start of the stage is also what makes `cd x | pwd` behave like a real
	// shell, where each stage is its own subshell.
	cwd:     string, // borrowed, valid for this command only
	user:    string, // borrowed; "" for a guest

	// The process this command belongs to, when there is one. Long-running
	// loops poll it so `kill` and a disconnect can stop them.
	proc_id: int,

	// True when this is running on a background thread, against a snapshot
	// rather than the live session. `sh` needs it to decide whether a script's
	// `cd` should be visible to the lines after it.
	detached: bool,

	// Set while a script is running, so `exit` can unwind it instead of
	// logging the session out. nil otherwise.
	script_stop: ^bool,
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
//
// Also marks the command as failed: every error path in every command already
// goes through here, so `a && b` and `a || b` work without each command having
// to remember to set a status.
errf :: proc(ctx: ^Cmd_Ctx, format: string, args: ..any) {
	ctx.status = 1
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

// Gathers the text a filter should operate on: the contents of the named
// files, or the piped input when no file is named.
//
// This is what makes a command usable on both sides of a pipe. `wc file` and
// `cat file | wc` are the same operation and should not be two code paths.
gather_input :: proc(
	ctx: ^Cmd_Ctx,
	name: string,
	files: []string,
) -> (content: string, ok: bool) {
	if len(files) == 0 {
		if len(ctx.stdin) == 0 {
			errf(ctx, "%s: no input (name a file, or pipe something in)\n", name)
			return "", false
		}
		return ctx.stdin, true
	}

	user := ctx.user
	b := strings.builder_make(context.temp_allocator)
	any_read := false

	for f in files {
		abs := resolve_arg(ctx, f)
		text, read_ok := vfs_read(&g_vfs, abs, user, context.temp_allocator)
		if !read_ok {
			if vfs_is_dir(&g_vfs, abs) {
				errf(ctx, "%s: %s: %s\n", name, f, vfs_error_string(.Is_A_Directory))
			} else {
				errf(ctx, "%s: %s: %s\n", name, f, vfs_error_string(.Not_Found))
			}
			continue
		}
		strings.write_string(&b, text)
		any_read = true
	}

	return strings.to_string(b), any_read
}

// Splits text into lines, dropping the trailing empty element that a final
// newline produces. Every line-oriented command wants this shape.
input_lines :: proc(content: string, allocator := context.temp_allocator) -> []string {
	lines := strings.split_lines(content, allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		return lines[:len(lines) - 1]
	}
	return lines
}

// Resolves a user-supplied path argument against the directory the command is
// running in.
resolve_arg :: proc(ctx: ^Cmd_Ctx, arg: string) -> string {
	return vfs_resolve_path(ctx.cwd, unquote(arg), context.temp_allocator)
}

// The same, for the few places that have a session but no command context:
// tab completion and the editor, both of which only ever run in the
// foreground, on the reader thread.
resolve_arg_client :: proc(c: ^Client, arg: string) -> string {
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
	cwd := ctx.cwd
	outf(ctx, "%s\n", cwd)
}

cmd_cd :: proc(ctx: ^Cmd_Ctx, args: []string) {
	user := ctx.user

	target: string
	if len(args) == 0 {
		// Bare `cd` goes home: the user's home directory if they have one,
		// otherwise the shared scratch space.
		if len(user) > 0 {
			target = fmt.tprintf("/home/%s", user)
		} else {
			target = "/tmp"
		}
	} else {
		target = resolve_arg(ctx, args[0])
	}

	if err := vfs_can_enter(&g_vfs, target, user); err != .None {
		errf(ctx, "cd: %s: %s\n", args[0] if len(args) > 0 else target, vfs_error_string(err))
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
	user := ctx.user

	// More than one target is now the common case, not an exotic one: a glob
	// hands `ls` every match at once, and `ls *.txt` has to list the files
	// rather than complain that the first one is not a directory.
	if len(targets) == 0 {
		cwd := ctx.cwd
		ls_directory(ctx, cwd, user, long, all, false)
		return
	}

	// Files are listed together first and directories expanded after, the way
	// every ls does it.
	files := make([dynamic]VFS_Stat, context.temp_allocator)
	dirs := make([dynamic]string, context.temp_allocator)

	for t in targets {
		abs := resolve_arg(ctx, t)
		if vfs_is_dir(&g_vfs, abs) {
			append(&dirs, abs)
			continue
		}
		st, ok := vfs_stat(&g_vfs, abs, user, context.temp_allocator)
		if !ok {
			errf(ctx, "ls: %s: %s\n", t, vfs_error_string(.Not_Found))
			continue
		}
		// Displayed as written rather than resolved: `ls sub/a.txt` should say
		// `sub/a.txt`, not the absolute path.
		st.name = strings.clone(t, context.temp_allocator)
		append(&files, st)
	}

	if len(files) > 0 {
		ls_render(ctx, files[:], long)
	}

	// A header only earns its place when there is more than one thing to tell
	// apart.
	headers := len(dirs) > 1 || (len(dirs) == 1 && len(files) > 0)
	for d, i in dirs {
		if headers && (i > 0 || len(files) > 0) {
			out(ctx, "\n")
		}
		ls_directory(ctx, d, user, long, all, headers)
	}
}

// Lists one directory, optionally introduced by its own name.
@(private = "file")
ls_directory :: proc(
	ctx: ^Cmd_Ctx,
	dir: string,
	user: string,
	long: bool,
	all: bool,
	header: bool,
) {
	entries, err := vfs_list(&g_vfs, dir, user, context.temp_allocator)
	if err != .None {
		errf(ctx, "ls: %s: %s\n", dir, vfs_error_string(err))
		return
	}

	if header {
		outf(ctx, "%s:\n", dir)
	}

	// Dotfiles are hidden without -a. The flag was parsed and then discarded
	// before, so `ls -a` was documented but did nothing.
	if !all {
		visible := make([dynamic]VFS_Stat, context.temp_allocator)
		for e in entries {
			if !strings.has_prefix(e.name, ".") {
				append(&visible, e)
			}
		}
		entries = visible[:]
	}

	ls_render(ctx, entries, long)
}

@(private = "file")
ls_render :: proc(ctx: ^Cmd_Ctx, entries: []VFS_Stat, long: bool) {

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

	user := ctx.user

	for t in targets {
		abs := resolve_arg(ctx, t)
		err := parents ? vfs_mkdir_all(&g_vfs, abs, user) : vfs_mkdir(&g_vfs, abs, user)
		if err != .None {
			errf(ctx, "mkdir: %s: %s\n", t, vfs_error_string(err))
			continue
		}
		announce_fs(ctx.client, "created directory", abs)
	}
}

cmd_rmdir :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "rmdir: missing operand\n")
		return
	}
	user := ctx.user

	for t in args {
		abs := resolve_arg(ctx, t)
		if err := vfs_rmdir(&g_vfs, abs, user); err != .None {
			errf(ctx, "rmdir: %s: %s\n", t, vfs_error_string(err))
			continue
		}
		announce_fs(ctx.client, "removed directory", abs)
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

	user := ctx.user

	for t in targets {
		abs := resolve_arg(ctx, t)
		if recursive {
			n, err := vfs_rm_recursive(&g_vfs, abs, user)
			if err != .None {
				errf(ctx, "rm: %s: %s\n", t, vfs_error_string(err))
				continue
			}
			announce_fs(ctx.client, fmt.tprintf("removed %d entries under", n), abs)
		} else {
			if err := vfs_rm(&g_vfs, abs, user); err != .None {
				errf(ctx, "rm: %s: %s\n", t, vfs_error_string(err))
				continue
			}
			announce_fs(ctx.client, "removed", abs)
		}
	}
}

cmd_touch :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "touch: missing operand\n")
		return
	}
	user := ctx.user

	for t in args {
		abs := resolve_arg(ctx, t)
		if vfs_exists(&g_vfs, abs) {
			continue
		}
		if err := vfs_write(&g_vfs, abs, "", user); err != .None {
			errf(ctx, "touch: %s: %s\n", t, vfs_error_string(err))
		}
	}
}

cmd_cat :: proc(ctx: ^Cmd_Ctx, args: []string) {
	content, ok := gather_input(ctx, "cat", args)
	if !ok {
		return
	}

	// File contents are user data and may contain anything, so they are
	// sanitized before being rendered into a terminal.
	out(ctx, sanitize_file(ctx, content))
	if len(content) > 0 && !strings.has_suffix(content, "\n") {
		out(ctx, "\n")
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
	// Redirection, quoting and variable expansion all happen in the shell
	// before a command ever runs, so echo is now genuinely just echo. The old
	// implementation parsed '>' itself by slicing the raw line at hard-coded
	// offsets.
	outf(ctx, "%s\n", join_args(args))
}

cmd_cp :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) < 2 {
		errf(ctx, "cp: usage: cp <source> <destination>\n")
		return
	}
	user := ctx.user

	src := resolve_arg(ctx, args[0])
	dst := resolve_arg(ctx, args[1])

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
	user := ctx.user

	src := resolve_arg(ctx, args[0])
	dst := resolve_arg(ctx, args[1])

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
	user := ctx.user
	abs := resolve_arg(ctx, args[0])

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

	user := ctx.user
	if len(user) == 0 {
		errf(ctx, "chmod: you must be logged in to own files\n")
		return
	}

	abs := resolve_arg(ctx, args[1])
	if err := vfs_chmod(&g_vfs, abs, perm, user); err != .None {
		errf(ctx, "chmod: %s: %s\n", args[1], vfs_error_string(err))
	}
}

cmd_tree :: proc(ctx: ^Cmd_Ctx, args: []string) {
	root := ctx.cwd
	if len(args) > 0 {
		root = resolve_arg(ctx, args[0])
	}
	if !vfs_is_dir(&g_vfs, root) {
		errf(ctx, "tree: %s: %s\n", root, vfs_error_string(.Not_A_Directory))
		return
	}

	user := ctx.user
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
	root := ctx.cwd
	pattern := ""

	for a in args {
		if len(a) > 0 && a[0] == '/' {
			root = vfs_resolve_path("/", a, context.temp_allocator)
		} else {
			pattern = a
		}
	}

	user := ctx.user
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
	ignore_case := false
	invert := false
	count_only := false

	// Off by default, like the real grep. It used to be on, which meant every
	// use of grep in the middle of a pipe fed line numbers to the next stage:
	// `ls | grep foo | sort` sorted "1: foo" rather than "foo".
	numbered := false

	rest := make([dynamic]string, context.temp_allocator)
	for a in args {
		if len(a) > 1 && a[0] == '-' {
			for i in 1 ..< len(a) {
				switch a[i] {
				case 'i':
					ignore_case = true
				case 'v':
					invert = true
				case 'c':
					count_only = true
				case 'n':
					numbered = true
				case 'h':
					numbered = false
				}
			}
			continue
		}
		append(&rest, a)
	}

	if len(rest) == 0 {
		errf(ctx, "grep: usage: grep [-i] [-v] [-c] [-n] <pattern> [file...]\n")
		return
	}

	pattern := rest[0]
	if ignore_case {
		pattern = strings.to_lower(pattern, context.temp_allocator)
	}

	content, ok := gather_input(ctx, "grep", rest[1:])
	if !ok {
		return
	}

	matches := 0
	for line, i in input_lines(content) {
		haystack := ignore_case ? strings.to_lower(line, context.temp_allocator) : line
		hit := strings.contains(haystack, pattern)
		if hit == invert {
			continue
		}
		matches += 1
		if count_only {
			continue
		}
		safe := sanitize_text(line, 400, context.temp_allocator)
		if numbered {
			outf(ctx, "%d: %s\n", i + 1, safe)
		} else {
			outf(ctx, "%s\n", safe)
		}
	}

	if count_only {
		outf(ctx, "%d\n", matches)
	}
	// No match is a failure status, which is what makes
	// `grep x file && echo found` work.
	if matches == 0 {
		ctx.status = 1
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

		// `head -3`, the short form everyone actually types. Without this the
		// argument falls through to `target` and is looked up as a filename.
		if len(args[i]) > 1 && args[i][0] == '-' {
			if n, ok := parse_positive_int(args[i][1:]); ok {
				count = min(n, MAX_OUTPUT_LINES)
				i += 1
				continue
			}
		}

		target = args[i]
		i += 1
	}

	files := make([dynamic]string, context.temp_allocator)
	if len(target) > 0 {
		append(&files, target)
	}

	content, ok := gather_input(ctx, name, files[:])
	if !ok {
		return
	}

	lines := input_lines(content)
	selected := lines
	if len(lines) > count {
		selected = from_start ? lines[:count] : lines[len(lines) - count:]
	}

	for line in selected {
		outf(ctx, "%s\n", sanitize_text(line, 400, context.temp_allocator))
	}
}

cmd_wc :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// Selecting a single count is most of what wc is used for — `wc -l` is how
	// anyone counts lines, and without the flags it was being read as a
	// filename and reported as missing.
	want_lines, want_words, want_bytes := false, false, false

	files := make([dynamic]string, context.temp_allocator)
	for a in args {
		if len(a) > 1 && a[0] == '-' {
			for i in 1 ..< len(a) {
				switch a[i] {
				case 'l':
					want_lines = true
				case 'w':
					want_words = true
				case 'c', 'm':
					want_bytes = true
				}
			}
			continue
		}
		append(&files, a)
	}

	// No selection means all three, as in the real thing.
	if !want_lines && !want_words && !want_bytes {
		want_lines, want_words, want_bytes = true, true, true
	}

	content, ok := gather_input(ctx, "wc", files[:])
	if !ok {
		return
	}

	lines := len(input_lines(content))
	words := len(strings.fields(content, context.temp_allocator))
	label := len(files) == 1 ? files[0] : ""

	// A single count prints bare, so it can be used as a number. Anything else
	// stays in the aligned columns.
	selected := 0
	if want_lines {selected += 1}
	if want_words {selected += 1}
	if want_bytes {selected += 1}

	if selected == 1 {
		n := want_lines ? lines : (want_words ? words : len(content))
		if len(label) > 0 {
			outf(ctx, "%d %s\n", n, label)
		} else {
			outf(ctx, "%d\n", n)
		}
		return
	}

	b := strings.builder_make(context.temp_allocator)
	if want_lines {
		strings.write_string(&b, pad_int(lines, 8))
	}
	if want_words {
		strings.write_string(&b, pad_int(words, 8))
	}
	if want_bytes {
		strings.write_string(&b, pad_int(len(content), 8))
	}
	outf(ctx, "%s  %s\n", strings.to_string(b), label)
}

cmd_du :: proc(ctx: ^Cmd_Ctx, args: []string) {
	root := ctx.cwd
	if len(args) > 0 {
		root = resolve_arg(ctx, args[0])
	}

	user := ctx.user
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
		"entries      %s   %s   %s%%\n",
		pad_int(u.entries, 7),
		pad_int(u.max_entries - u.entries, 8),
		pad_percent(pct_entries),
	)
	outf(
		ctx,
		"storage      %7s   %8s   %s%%\n",
		human_size(u.total_bytes, context.temp_allocator),
		human_size(u.max_bytes - u.total_bytes, context.temp_allocator),
		pad_percent(pct_bytes),
	)
}

// A percentage right-aligned in five columns.
//
// "%5.1f" zero-pads exactly as the integer verbs do, so 0.0% rendered as
// "000.0%".
@(private = "file")
pad_percent :: proc(value: f64) -> string {
	return fmt.aprintf(
		"%*s",
		5,
		fmt.tprintf("%.1f", value),
		allocator = context.temp_allocator,
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
// Two separate limits apply. The old code broadcast one of these for every
// mkdir/rm/echo with no rate limit at all, so a loop of `mkdir` was a way to
// spam every connected terminal; it is now bounded by the same broadcast budget
// as `wall`, and silently skipped rather than refused when the budget is gone.
//
// More importantly, it broadcast the *absolute path*. Creating
// /home/alice/private-notes told every connected session that the path existed,
// which defeats the entire point of the permission model — the listing was
// hidden but the announcement was not. Only the shared areas are announced now.
announce_fs :: proc(c: ^Client, verb: string, abs_path: string) {
	if !is_shared_path(abs_path) {
		return
	}
	if !rate_allow(&c.rl_broadcast) {
		return
	}

	name := client_get_name(c, context.temp_allocator)
	safe := sanitize_text(abs_path, 200, context.temp_allocator)

	broadcast_notice(
		fmt.tprintf("\x1b[33m[system]\x1b[0m %s %s %s\r\n", name, verb, safe),
		c.id,
	)
}

// The world-writable areas, which are the only paths whose existence is not
// information about a particular user.
is_shared_path :: proc(p: string) -> bool {
	for root in ([?]string{"/tmp", "/pub"}) {
		if p == root {
			return true
		}
		if strings.has_prefix(p, root) && len(p) > len(root) && p[len(root)] == '/' {
			return true
		}
	}
	return false
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

		dir := len(dir_part) > 0 ? resolve_arg_client(c, dir_part) : client_get_cwd(c, context.temp_allocator)
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
