package main

import "core:strings"

// ---------------------------------------------------------------------------
// Conditions
//
// Scripts branch on the exit status of a command, so a script language needs
// something whose whole purpose is to produce one. Without `test` the only
// usable conditions are side effects of other commands — `grep -c` and the
// like — which works but reads terribly.
//
// `[` is the same command under the name everyone writes, which is why the
// closing `]` is an argument rather than syntax: `[ -f x ]` is `[` called with
// three arguments, the last of which it checks and discards.
// ---------------------------------------------------------------------------

cmd_true :: proc(ctx: ^Cmd_Ctx, args: []string) {
	ctx.status = 0
}

cmd_false :: proc(ctx: ^Cmd_Ctx, args: []string) {
	ctx.status = 1
}

cmd_bracket :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 || args[len(args) - 1] != "]" {
		errf(ctx, "[: missing closing ']'\n")
		return
	}
	cmd_test(ctx, args[:len(args) - 1])
}

cmd_test :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// A status, not a message: this is a predicate, and printing anything
	// would make `if test ...` chatty and break it inside a pipeline.
	ctx.status = test_evaluate(ctx, args) ? 0 : 1
}

@(private = "file")
test_evaluate :: proc(ctx: ^Cmd_Ctx, args: []string) -> bool {
	// Negation first, so it composes with everything below.
	if len(args) > 0 && args[0] == "!" {
		return !test_evaluate(ctx, args[1:])
	}

	switch len(args) {
	case 0:
		return false

	case 1:
		// A bare word is true when it is not empty, which is what makes
		// `test "$VAR"` work.
		return len(args[0]) > 0

	case 2:
		return test_unary(ctx, args[0], args[1])

	case 3:
		return test_binary(ctx, args[0], args[1], args[2])
	}

	return false
}

@(private = "file")
test_unary :: proc(ctx: ^Cmd_Ctx, op: string, operand: string) -> bool {
	switch op {
	case "-z":
		return len(operand) == 0
	case "-n":
		return len(operand) > 0
	}

	// The filesystem predicates all resolve against the directory the command
	// is running in, like every other path argument.
	abs := resolve_arg(ctx, operand)
	switch op {
	case "-e":
		return vfs_exists(&g_vfs, abs)
	case "-f":
		return vfs_exists(&g_vfs, abs) && !vfs_is_dir(&g_vfs, abs)
	case "-d":
		return vfs_is_dir(&g_vfs, abs)
	case "-s":
		content, ok := vfs_read(&g_vfs, abs, ctx.user, context.temp_allocator)
		return ok && len(content) > 0
	case "-r":
		// Readability is the only permission a reader can observe, and it is
		// exactly what vfs_read already decides.
		_, ok := vfs_read(&g_vfs, abs, ctx.user, context.temp_allocator)
		return ok
	}

	return false
}

@(private = "file")
test_binary :: proc(ctx: ^Cmd_Ctx, left: string, op: string, right: string) -> bool {
	switch op {
	case "=", "==":
		return left == right
	case "!=":
		return left != right
	}

	// Numeric comparisons. A non-number is false rather than an error: a
	// predicate that prints is a predicate nobody can use in a condition.
	a, a_ok := parse_int_signed(left)
	b, b_ok := parse_int_signed(right)
	if !a_ok || !b_ok {
		return false
	}

	switch op {
	case "-eq":
		return a == b
	case "-ne":
		return a != b
	case "-lt":
		return a < b
	case "-le":
		return a <= b
	case "-gt":
		return a > b
	case "-ge":
		return a >= b
	}

	return false
}

// Parses an optionally negative integer.
//
// parse_positive_int refuses a leading '-', which is right for a count but
// wrong for a comparison: `test -1 -lt 0` has to work.
parse_int_signed :: proc(s: string) -> (val: int, ok: bool) {
	text := strings.trim_space(s)
	if len(text) == 0 {
		return 0, false
	}

	negative := false
	if text[0] == '-' || text[0] == '+' {
		negative = text[0] == '-'
		text = text[1:]
	}
	if len(text) == 0 {
		return 0, false
	}

	n := 0
	for i in 0 ..< len(text) {
		if text[i] < '0' || text[i] > '9' {
			return 0, false
		}
		digit := int(text[i] - '0')
		// Bail before overflowing rather than wrapping into a value that would
		// compare as something absurd.
		if n > (max(int) - digit) / 10 {
			return 0, false
		}
		n = n * 10 + digit
	}

	return negative ? -n : n, true
}
