package main

import "core:crypto/hash"
import "core:encoding/base64"
import "core:fmt"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// Text filters and shell built-ins
//
// Everything here reads from a file argument or from the pipe, which is what
// makes them composable: `cat notes | tr upper | sort | uniq -c | head`.
// ---------------------------------------------------------------------------

cmd_sort :: proc(ctx: ^Cmd_Ctx, args: []string) {
	reverse := false
	unique := false
	numeric := false

	files := make([dynamic]string, context.temp_allocator)
	for a in args {
		if len(a) > 1 && a[0] == '-' {
			for i in 1 ..< len(a) {
				switch a[i] {
				case 'r':
					reverse = true
				case 'u':
					unique = true
				case 'n':
					numeric = true
				}
			}
			continue
		}
		append(&files, a)
	}

	content, ok := gather_input(ctx, "sort", files[:])
	if !ok {
		return
	}

	lines := slice.clone(input_lines(content), context.temp_allocator)

	if numeric {
		slice.sort_by(lines, proc(a, b: string) -> bool {
			return leading_number(a) < leading_number(b)
		})
	} else {
		slice.sort(lines)
	}

	if reverse {
		slice.reverse(lines)
	}

	previous := ""
	first := true
	for line in lines {
		if unique && !first && line == previous {
			continue
		}
		outf(ctx, "%s\n", sanitize_text(line, 400, context.temp_allocator))
		previous = line
		first = false
	}
}

// Parses the number a line starts with, for `sort -n`. A line with no number
// sorts as zero rather than failing the whole sort.
@(private = "file")
leading_number :: proc(s: string) -> f64 {
	trimmed := strings.trim_left_space(s)
	negative := false
	i := 0

	if i < len(trimmed) && (trimmed[i] == '-' || trimmed[i] == '+') {
		negative = trimmed[i] == '-'
		i += 1
	}

	value := 0.0
	for i < len(trimmed) && trimmed[i] >= '0' && trimmed[i] <= '9' {
		value = value * 10 + f64(trimmed[i] - '0')
		if value > 1e15 {
			break
		}
		i += 1
	}

	return negative ? -value : value
}

cmd_uniq :: proc(ctx: ^Cmd_Ctx, args: []string) {
	show_counts := false
	only_repeated := false

	files := make([dynamic]string, context.temp_allocator)
	for a in args {
		if len(a) > 1 && a[0] == '-' {
			for i in 1 ..< len(a) {
				switch a[i] {
				case 'c':
					show_counts = true
				case 'd':
					only_repeated = true
				}
			}
			continue
		}
		append(&files, a)
	}

	content, ok := gather_input(ctx, "uniq", files[:])
	if !ok {
		return
	}

	lines := input_lines(content)

	// Collapses *adjacent* duplicates, like the real thing — which is why it
	// is nearly always used after sort.
	i := 0
	for i < len(lines) {
		run := 1
		for i + run < len(lines) && lines[i + run] == lines[i] {
			run += 1
		}

		safe := sanitize_text(lines[i], 400, context.temp_allocator)
		if !only_repeated || run > 1 {
			if show_counts {
				outf(ctx, "%s %s\n", pad_int(run, 7), safe)
			} else {
				outf(ctx, "%s\n", safe)
			}
		}
		i += run
	}
}

cmd_nl :: proc(ctx: ^Cmd_Ctx, args: []string) {
	content, ok := gather_input(ctx, "nl", args)
	if !ok {
		return
	}
	for line, i in input_lines(content) {
		outf(ctx, "%s  %s\n", pad_int(i + 1, 6), sanitize_text(line, 400, context.temp_allocator))
	}
}

cmd_tac :: proc(ctx: ^Cmd_Ctx, args: []string) {
	content, ok := gather_input(ctx, "tac", args)
	if !ok {
		return
	}
	lines := input_lines(content)
	for i := len(lines) - 1; i >= 0; i -= 1 {
		outf(ctx, "%s\n", sanitize_text(lines[i], 400, context.temp_allocator))
	}
}

cmd_cut :: proc(ctx: ^Cmd_Ctx, args: []string) {
	delimiter := "\t"
	field := 1

	files := make([dynamic]string, context.temp_allocator)

	i := 0
	for i < len(args) {
		switch {
		case args[i] == "-d" && i + 1 < len(args):
			delimiter = args[i + 1]
			if len(delimiter) == 0 {
				delimiter = " "
			}
			i += 2
		case args[i] == "-f" && i + 1 < len(args):
			if n, parsed := parse_positive_int(args[i + 1]); parsed && n > 0 {
				field = n
			}
			i += 2
		case:
			append(&files, args[i])
			i += 1
		}
	}

	content, ok := gather_input(ctx, "cut", files[:])
	if !ok {
		return
	}

	for line in input_lines(content) {
		parts := strings.split(line, delimiter, context.temp_allocator)
		if field > len(parts) {
			continue // no such field on this line; skip it, as cut does
		}
		outf(ctx, "%s\n", sanitize_text(parts[field - 1], 400, context.temp_allocator))
	}
}

cmd_tr :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "tr: usage: tr <upper|lower|squeeze|<from> <to>> [file...]\n")
		return
	}

	mode := strings.to_lower(args[0], context.temp_allocator)

	// The two-set form takes its sets first, so anything after them is a file.
	from, to := "", ""
	rest_index := 1
	if mode != "upper" && mode != "lower" && mode != "squeeze" {
		if len(args) < 2 {
			errf(ctx, "tr: usage: tr <from> <to> [file...]\n")
			return
		}
		from = args[0]
		to = args[1]
		rest_index = 2
	}

	content, ok := gather_input(ctx, "tr", args[rest_index:])
	if !ok {
		return
	}

	switch mode {
	case "upper":
		out(ctx, strings.to_upper(content, context.temp_allocator))
		return
	case "lower":
		out(ctx, strings.to_lower(content, context.temp_allocator))
		return
	case "squeeze":
		b := strings.builder_make(context.temp_allocator)
		previous_space := false
		for r in content {
			is_space := r == ' ' || r == '\t'
			if is_space && previous_space {
				continue
			}
			strings.write_rune(&b, r)
			previous_space = is_space
		}
		out(ctx, strings.to_string(b))
		return
	}

	// Positional character mapping: from[i] becomes to[i].
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(content) {
		ch := content[i]
		mapped := ch
		for j in 0 ..< len(from) {
			if from[j] == ch {
				mapped = j < len(to) ? to[j] : ch
				break
			}
		}
		strings.write_byte(&b, mapped)
	}
	out(ctx, strings.to_string(b))
}

cmd_diff :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) < 2 {
		errf(ctx, "diff: usage: diff <file-a> <file-b>\n")
		return
	}

	user := client_get_user(ctx.client, context.temp_allocator)

	a_path := resolve_arg(ctx.client, args[0])
	b_path := resolve_arg(ctx.client, args[1])

	a_text, a_ok := vfs_read(&g_vfs, a_path, user, context.temp_allocator)
	if !a_ok {
		errf(ctx, "diff: %s: %s\n", args[0], vfs_error_string(.Not_Found))
		return
	}
	b_text, b_ok := vfs_read(&g_vfs, b_path, user, context.temp_allocator)
	if !b_ok {
		errf(ctx, "diff: %s: %s\n", args[1], vfs_error_string(.Not_Found))
		return
	}

	a_lines := input_lines(a_text)
	b_lines := input_lines(b_text)

	// A line-by-line comparison rather than a real longest-common-subsequence
	// diff: enough to answer "did this change and where", without the quadratic
	// memory that an LCS table would need on attacker-supplied files.
	differences := 0
	limit := max(len(a_lines), len(b_lines))

	for i in 0 ..< limit {
		a_line := i < len(a_lines) ? a_lines[i] : ""
		b_line := i < len(b_lines) ? b_lines[i] : ""

		if a_line == b_line {
			continue
		}
		differences += 1

		if i < len(a_lines) {
			outf(ctx, "\x1b[31m-%s %s\x1b[0m\n", pad_int(i + 1, 4), sanitize_text(a_line, 300, context.temp_allocator))
		}
		if i < len(b_lines) {
			outf(ctx, "\x1b[32m+%s %s\x1b[0m\n", pad_int(i + 1, 4), sanitize_text(b_line, 300, context.temp_allocator))
		}
	}

	if differences == 0 {
		out(ctx, "files are identical\n")
		return
	}
	outf(ctx, "\n%d line(s) differ\n", differences)
	ctx.status = 1
}

// ---------------------------------------------------------------------------
// Encoding and digests
// ---------------------------------------------------------------------------

cmd_base64 :: proc(ctx: ^Cmd_Ctx, args: []string) {
	decode := false

	rest := make([dynamic]string, context.temp_allocator)
	for a in args {
		if a == "-d" || a == "--decode" {
			decode = true
			continue
		}
		append(&rest, a)
	}

	// Text given directly on the command line is more useful here than
	// requiring a file, so fall back to treating the arguments as the input.
	content: string
	if len(rest) > 0 && !vfs_exists(&g_vfs, resolve_arg(ctx.client, rest[0])) {
		content = join_args(rest[:])
	} else {
		ok: bool
		content, ok = gather_input(ctx, "base64", rest[:])
		if !ok {
			return
		}
	}

	if decode {
		decoded, err := base64.decode(strings.trim_space(content), allocator = context.temp_allocator)
		if err != nil {
			errf(ctx, "base64: input is not valid base64\n")
			return
		}
		// Decoded bytes are arbitrary and are about to be written into a
		// terminal, so they go through the same filter as any file.
		out(ctx, sanitize_text(string(decoded), 4096, context.temp_allocator))
		out(ctx, "\n")
		return
	}

	encoded := base64.encode(transmute([]byte)content, allocator = context.temp_allocator)
	outf(ctx, "%s\n", encoded)
}

cmd_sha256 :: proc(ctx: ^Cmd_Ctx, args: []string) {
	digest_command(ctx, "sha256", .SHA256, args)
}

cmd_md5 :: proc(ctx: ^Cmd_Ctx, args: []string) {
	digest_command(ctx, "md5", .Insecure_MD5, args)
}

@(private = "file")
digest_command :: proc(
	ctx: ^Cmd_Ctx,
	name: string,
	algorithm: hash.Algorithm,
	args: []string,
) {
	content: string
	if len(args) > 0 && !vfs_exists(&g_vfs, resolve_arg(ctx.client, args[0])) {
		content = join_args(args)
	} else {
		ok: bool
		content, ok = gather_input(ctx, name, args)
		if !ok {
			return
		}
	}

	digest := hash.hash_string(algorithm, content, context.temp_allocator)

	b := strings.builder_make(context.temp_allocator)
	for byte_value in digest {
		fmt.sbprintf(&b, "%02x", byte_value)
	}
	outf(ctx, "%s\n", strings.to_string(b))
}

// ---------------------------------------------------------------------------
// Shell built-ins
// ---------------------------------------------------------------------------

cmd_env :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	// The computed ones first: they describe the session and are what someone
	// is usually looking for.
	for name in ([?]string{"USER", "NAME", "HOME", "PWD", "HOSTNAME", "SHELL", "TERM", "VERSION", "SESSION"}) {
		outf(ctx, "%s=%s\n", name, shell_var_get(c, name))
	}
	outf(ctx, "?=%d\n", c.last_status)

	if len(c.vars) == 0 {
		return
	}

	names := make([dynamic]string, context.temp_allocator)
	for name in c.vars {
		append(&names, name)
	}
	slice.sort(names[:])

	out(ctx, "\n")
	for name in names {
		outf(ctx, "%s=%s\n", name, sanitize_text(c.vars[name], 400, context.temp_allocator))
	}
}

cmd_export :: proc(ctx: ^Cmd_Ctx, args: []string) {
	c := ctx.client

	if len(args) == 0 {
		cmd_env(ctx, nil)
		return
	}

	for a in args {
		eq := strings.index_byte(a, '=')
		if eq <= 0 {
			errf(ctx, "export: expected NAME=value, got '%s'\n",
				sanitize_text(a, 40, context.temp_allocator))
			continue
		}

		name := a[:eq]
		if !is_valid_var_name(name) {
			errf(ctx, "export: '%s' is not a usable variable name\n",
				sanitize_text(name, 40, context.temp_allocator))
			continue
		}
		if !shell_var_set(c, name, a[eq + 1:]) {
			errf(ctx, "export: cannot set %s (limit of %d variables reached)\n", name, MAX_VARS)
		}
	}
}

cmd_unset :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "unset: usage: unset <name...>\n")
		return
	}
	for a in args {
		shell_var_unset(ctx.client, a)
	}
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

cmd_dmesg :: proc(ctx: ^Cmd_Ctx, args: []string) {
	outf(ctx, "\x1b[1mWebOS %s\x1b[0m — request rejections\n\n", SERVER_VERSION)
	out(ctx, abuse_summary(context.temp_allocator))
	out(ctx, "\n\x1b[90mAuthentication events are recorded in the server journal,\x1b[0m\n")
	out(ctx, "\x1b[90mnot here: they name accounts and do not belong on a shared screen.\x1b[0m\n")
}
