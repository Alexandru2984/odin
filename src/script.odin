package main

import "core:strings"

// ---------------------------------------------------------------------------
// Scripts
//
// `sh <file>` runs a file out of the VFS. The last thing the original README
// listed as a future idea, and the thing that turns a collection of commands
// into somewhere you can actually build something.
//
// Scripts run in the current shell rather than a child, so a script's `cd`
// moves the session — closer to `source` than to running a program. That is a
// deliberate simplification: a child would need its own session state, and the
// only thing it would buy is isolating a `cd`.
//
// Control flow is interpreted over a pre-matched line table rather than parsed
// into a tree. Blocks are line-oriented and cannot nest by more than the
// depth limit, so a jump table is both simpler and easier to bound — and
// bounding matters, because `while true` is one line away from an infinite
// loop on a shared server.
// ---------------------------------------------------------------------------

MAX_SCRIPT_LINES  :: 1000
MAX_SCRIPT_DEPTH  :: 4 // a script running a script
MAX_SCRIPT_STEPS  :: 10_000 // commands executed in one run; bounds every loop
MAX_SCRIPT_NEST   :: 16 // if/while/for nesting within one script
MAX_SCRIPT_ARGS   :: 9 // $1 .. $9

@(private = "file")
Line_Kind :: enum {
	Blank, // empty, or a comment, or a bare `then`/`do`
	Plain,
	If,
	Else,
	Fi,
	While,
	For,
	Done,
}

@(private = "file")
Script_Line :: struct {
	kind:   Line_Kind,
	text:   string, // the command, or the header of a block
	// Where control goes. Its meaning depends on the kind:
	//   If    -> the line to continue at when the condition is false
	//   Else  -> the matching Fi
	//   While -> the line after the matching Done
	//   For   -> the line after the matching Done
	//   Done  -> the header of the loop it closes
	jump:   int,
	// For a Done: whether the loop it closes is a `for`, which needs its
	// iteration state advanced rather than its condition re-run.
	is_for: bool,
}

// State of one running `for` loop, keyed by the header's line number.
@(private = "file")
For_State :: struct {
	items: []string,
	index: int,
}

Script_Error :: enum {
	None,
	Too_Many_Lines,
	Too_Deep,
	Unbalanced,
	Step_Limit,
}

script_error_string :: proc(e: Script_Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Too_Many_Lines:
		return "script is too long"
	case .Too_Deep:
		return "blocks nested too deeply"
	case .Unbalanced:
		return "unbalanced if/while/for — check for a missing fi or done"
	case .Step_Limit:
		return "script ran too long (possible infinite loop)"
	}
	return "script error"
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

// Classifies a line and strips the trailing `; then` / `; do` a shell allows on
// a block header.
@(private = "file")
classify :: proc(raw: string) -> (kind: Line_Kind, text: string) {
	line := strings.trim_space(raw)

	if len(line) == 0 || line[0] == '#' {
		return .Blank, ""
	}

	// `then` and `do` on their own line carry no meaning here: the header
	// already told us a block is opening.
	switch line {
	case "then", "do":
		return .Blank, ""
	case "else":
		return .Else, ""
	case "fi":
		return .Fi, ""
	case "done":
		return .Done, ""
	}

	head, rest := split_first_word(line)
	switch head {
	case "if":
		return .If, strip_block_tail(rest)
	case "while":
		return .While, strip_block_tail(rest)
	case "for":
		return .For, strip_block_tail(rest)
	}

	return .Plain, line
}

// Removes a trailing `; then` or `; do` from a block header.
@(private = "file")
strip_block_tail :: proc(s: string) -> string {
	text := strings.trim_space(s)
	for suffix in ([?]string{"; then", ";then", "; do", ";do"}) {
		if strings.has_suffix(text, suffix) {
			return strings.trim_space(text[:len(text) - len(suffix)])
		}
	}
	// `then` and `do` also appear without the semicolon.
	for suffix in ([?]string{" then", " do"}) {
		if strings.has_suffix(text, suffix) {
			return strings.trim_space(text[:len(text) - len(suffix)])
		}
	}
	return text
}

@(private = "file")
split_first_word :: proc(s: string) -> (head: string, rest: string) {
	i := 0
	for i < len(s) && s[i] != ' ' && s[i] != '\t' {
		i += 1
	}
	return s[:i], strings.trim_space(s[i:])
}

// Builds the line table and resolves every jump.
@(private = "file")
script_parse :: proc(
	source: string,
	allocator := context.temp_allocator,
) -> (lines: []Script_Line, err: Script_Error) {
	raw := strings.split_lines(source, allocator)
	if len(raw) > MAX_SCRIPT_LINES {
		return nil, .Too_Many_Lines
	}

	table := make([dynamic]Script_Line, allocator)
	for text in raw {
		kind, body := classify(text)
		append(&table, Script_Line{kind = kind, text = body})
	}

	// Match openers to closers with a stack. Every unmatched one at either end
	// is an error rather than something to guess at: a script whose blocks do
	// not balance is a script whose author has a typo, and running half of it
	// is worse than refusing.
	stack := make([dynamic]int, allocator)
	// The `else` of each open `if`, so `fi` can resolve it.
	else_of := make(map[int]int, allocator)

	for i in 0 ..< len(table) {
		switch table[i].kind {
		case .If, .While, .For:
			if len(stack) >= MAX_SCRIPT_NEST {
				return nil, .Too_Deep
			}
			append(&stack, i)

		case .Else:
			if len(stack) == 0 || table[stack[len(stack) - 1]].kind != .If {
				return nil, .Unbalanced
			}
			else_of[stack[len(stack) - 1]] = i

		case .Fi:
			if len(stack) == 0 {
				return nil, .Unbalanced
			}
			opener := pop(&stack)
			if table[opener].kind != .If {
				return nil, .Unbalanced
			}
			if else_index, has_else := else_of[opener]; has_else {
				// False condition resumes just past the `else`.
				table[opener].jump = else_index + 1
				// The then-branch falls into `else` and skips to `fi`.
				table[else_index].jump = i
			} else {
				table[opener].jump = i
			}

		case .Done:
			if len(stack) == 0 {
				return nil, .Unbalanced
			}
			opener := pop(&stack)
			if table[opener].kind != .While && table[opener].kind != .For {
				return nil, .Unbalanced
			}
			table[opener].jump = i + 1
			table[i].jump = opener
			table[i].is_for = table[opener].kind == .For

		case .Blank, .Plain:
		// nothing to match
		}
	}

	if len(stack) > 0 {
		return nil, .Unbalanced
	}
	return table[:], .None
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

// Runs a parsed script. `ex` carries the positional parameters and where output
// goes; the caller owns both.
@(private = "file")
script_execute :: proc(
	c: ^Client,
	ctx: ^Cmd_Ctx,
	lines: []Script_Line,
	ex: Exec,
) -> Script_Error {
	loops := make(map[int]For_State, context.temp_allocator)

	pc := 0
	steps := 0

	for pc < len(lines) {
		// Two ways out that are not the script's own doing: it was killed, or
		// it has run long enough that it is probably not going to stop.
		if proc_cancelled(ex.pid) {
			return .None
		}
		if ex.stop^ {
			return .None
		}
		steps += 1
		if steps > MAX_SCRIPT_STEPS {
			return .Step_Limit
		}

		line := lines[pc]
		switch line.kind {
		case .Blank:
			pc += 1

		case .Plain:
			shell_run_line(c, line.text, ex)
			pc += 1

		case .If:
			shell_run_line(c, line.text, ex)
			pc = ex.status^ == 0 ? pc + 1 : line.jump

		case .Else:
			// Reached only by falling out of a taken then-branch.
			pc = line.jump

		case .Fi:
			pc += 1

		case .While:
			shell_run_line(c, line.text, ex)
			pc = ex.status^ == 0 ? pc + 1 : line.jump

		case .For:
			state, running := loops[pc]
			if !running {
				state = For_State {
					items = for_items(c, line.text, ex),
					index = 0,
				}
			}
			if state.index >= len(state.items) {
				delete_key(&loops, pc)
				pc = line.jump
				continue
			}
			// The loop variable is an ordinary session variable, so the body
			// reads it with `$name` like anything else.
			if name, _ := for_variable(line.text); len(name) > 0 {
				shell_var_set(c, name, state.items[state.index])
			}
			state.index += 1
			loops[pc] = state
			pc += 1

		case .Done:
			pc = line.jump
		}
	}

	return .None
}

// The variable a `for` header binds: `for x in a b c` -> "x".
@(private = "file")
for_variable :: proc(header: string) -> (name: string, rest: string) {
	head, tail := split_first_word(header)
	if !is_valid_var_name(head) {
		return "", tail
	}
	// Drop the `in`, which is punctuation rather than a word to iterate.
	word, after := split_first_word(tail)
	if word == "in" {
		return head, after
	}
	return head, tail
}

// The words a `for` header iterates, expanded and split.
//
// Splitting happens after expansion so `for f in $LIST` and `for f in *.txt`
// both iterate several items rather than one long string.
@(private = "file")
for_items :: proc(c: ^Client, header: string, ex: Exec) -> []string {
	_, rest := for_variable(header)

	tokens, err := shell_lex(rest, context.temp_allocator)
	if err != .None {
		return nil
	}

	items := make([dynamic]string, context.temp_allocator)
	for tok in tokens {
		if tok.kind != .Word {
			continue
		}
		word, xerr := shell_expand(c, tok.text, ex)
		if xerr != .None {
			continue
		}
		if matches := tok.literal_glob ? nil : shell_glob_word(c, word, ex); matches != nil {
			for m in matches {
				append(&items, m)
			}
			continue
		}
		// One expansion can still carry several words — `$@`, or a variable
		// holding a list — so what came back is split again.
		for field in strings.fields(word, context.temp_allocator) {
			append(&items, field)
		}
	}
	return items[:]
}

// ---------------------------------------------------------------------------
// The command
// ---------------------------------------------------------------------------

cmd_sh :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "sh: usage: sh <script> [arguments...]\n")
		out(ctx, "  a script is an ordinary file: write it with \x1b[36medit\x1b[0m\n")
		return
	}

	c := ctx.client

	if c.script_depth >= MAX_SCRIPT_DEPTH {
		errf(ctx, "sh: scripts nested too deeply\n")
		return
	}

	path := resolve_arg(ctx, args[0])
	source, ok := vfs_read(&g_vfs, path, ctx.user, context.temp_allocator)
	if !ok {
		reason := vfs_is_dir(&g_vfs, path) ? VFS_Error.Is_A_Directory : VFS_Error.Not_Found
		errf(ctx, "sh: %s: %s\n", args[0], vfs_error_string(reason))
		return
	}

	lines, parse_err := script_parse(source, context.temp_allocator)
	if parse_err != .None {
		errf(ctx, "sh: %s: %s\n", args[0], script_error_string(parse_err))
		return
	}

	// Positional parameters. $0 is the script as it was named, so a script can
	// report itself the way it was invoked.
	params := make([dynamic]string, context.temp_allocator)
	append(&params, args[0])
	for a in args[1:] {
		if len(params) > MAX_SCRIPT_ARGS {
			break
		}
		append(&params, a)
	}

	stop := false
	status := ctx.status

	ex := Exec {
		sink   = ctx.capture,
		pid    = ctx.proc_id,
		status = &status,
		args   = params[:],
		stop   = &stop,
	}

	// A detached script keeps the snapshot it was given; an interactive one
	// reads the live session, so a `cd` on one line is visible on the next.
	detached: Detached
	if ctx.detached {
		detached = Detached {
			pid  = ctx.proc_id,
			cwd  = ctx.cwd,
			user = ctx.user,
		}
		ex.detached = &detached
	}

	c.script_depth += 1
	run_err := script_execute(c, ctx, lines, ex)
	c.script_depth -= 1

	if run_err != .None {
		errf(ctx, "sh: %s: %s\n", args[0], script_error_string(run_err))
		return
	}

	// The script's status becomes the command's, so `sh a.sh && sh b.sh` works.
	ctx.status = status
}

// `exit` ends a script. Outside one it means what it has always meant here,
// which is to drop back to being a guest — the same thing `quit` does.
cmd_exit :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if ctx.script_stop == nil {
		cmd_logout(ctx, args)
		return
	}

	ctx.script_stop^ = true
	if len(args) > 0 {
		if code, ok := parse_positive_int(unquote(args[0])); ok {
			ctx.status = code
			return
		}
	}
	ctx.status = 0
}
