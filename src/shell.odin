package main

import "base:runtime"
import "core:fmt"
import "core:strings"

// Emits the word accumulated so far, if any.
//
// `has_word` is tracked separately from the buffer length so that an explicitly
// empty argument — `grep "" file` — survives as a real, empty token instead of
// vanishing.
@(private = "file")
flush_word :: proc(
	result: ^[dynamic]Token,
	b: ^strings.Builder,
	has_word: ^bool,
	allocator: runtime.Allocator,
) {
	if !has_word^ {
		return
	}
	append(result, Token{kind = .Word, text = strings.clone(strings.to_string(b^), allocator)})
	strings.builder_reset(b)
	has_word^ = false
}

// ---------------------------------------------------------------------------
// The shell language
//
// Until now a command line was `split on spaces, look at the first word, scan
// for a '>' somewhere in the middle`. That meant no quoting (a filename with a
// space was two arguments), no way to combine commands, and a redirection
// operator that was found by position rather than by parsing.
//
// This is a real pipeline: lex into tokens with quoting honoured, parse into
// pipelines joined by ; && ||, expand variables, then execute. Composition is
// what makes a terminal a terminal rather than a menu of commands.
//
// Every stage has a hard limit. The input is a network message from an
// anonymous peer, so "how many stages can one line have" is a resource
// question, not a style question.
// ---------------------------------------------------------------------------

MAX_PIPELINE_STAGES :: 16
MAX_COMMAND_LIST    :: 32
MAX_VARS            :: 64
MAX_VAR_NAME        :: 64
MAX_VAR_VALUE       :: 4096
MAX_EXPANSION       :: 16 * 1024

// ---------------------------------------------------------------------------
// Lexing
// ---------------------------------------------------------------------------

Token_Kind :: enum {
	Word,
	Pipe, // |
	And, // &&
	Or, // ||
	Semi, // ;
	Write, // >
	Append, // >>
}

Token :: struct {
	kind: Token_Kind,
	text: string, // for Word: quoting resolved, expansion still pending
}

Lex_Error :: enum {
	None,
	Unterminated_Quote,
	Too_Many_Tokens,
	Too_Long,
}

lex_error_string :: proc(e: Lex_Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Unterminated_Quote:
		return "unterminated quote"
	case .Too_Many_Tokens:
		return "too many arguments"
	case .Too_Long:
		return "expansion too large"
	}
	return "syntax error"
}

// Splits a line into tokens, resolving quotes but *not* expanding variables.
//
// Quoting has to be resolved here, so that a quoted operator is just text:
// `echo "a | b"` prints `a | b` rather than piping into a command called b.
//
// Expansion, though, is deliberately deferred to execution time. Expanding
// during the lex would evaluate the whole line up front, so in
// `false ; echo $?` the `$?` would be substituted before `false` had run and
// would report the status of some earlier command. Anything that must survive
// expansion untouched is backslash-escaped here and unescaped by shell_expand.
shell_lex :: proc(
	line: string,
	allocator := context.temp_allocator,
) -> (tokens: []Token, err: Lex_Error) {
	result := make([dynamic]Token, allocator)

	b := strings.builder_make(allocator)
	has_word := false // distinguishes an empty quoted string from no word

	i := 0
	for i < len(line) {
		ch := line[i]

		switch ch {
		case ' ', '\t':
			flush_word(&result, &b, &has_word, allocator)
			i += 1
			continue

		case '\'':
			// Single quotes are literal: no expansion, no escapes. Anything the
			// deferred expansion pass would otherwise act on is escaped now.
			end := strings.index_byte(line[i + 1:], '\'')
			if end < 0 {
				return nil, .Unterminated_Quote
			}
			for j in i + 1 ..< i + 1 + end {
				if line[j] == '\\' || line[j] == '$' {
					strings.write_byte(&b, '\\')
				}
				strings.write_byte(&b, line[j])
			}
			has_word = true
			i += end + 2
			continue

		case '"':
			// Double quotes group, but variables still expand inside.
			j := i + 1
			closed := false
			for j < len(line) {
				if line[j] == '\\' && j + 1 < len(line) {
					j += 2
					continue
				}
				if line[j] == '"' {
					closed = true
					break
				}
				j += 1
			}
			if !closed {
				return nil, .Unterminated_Quote
			}
			// Copied verbatim: variables inside double quotes do expand, and
			// any backslash escape is resolved by the same later pass.
			strings.write_string(&b, line[i + 1:j])
			has_word = true
			i = j + 1
			continue

		case '\\':
			// Kept escaped so the deferred expansion resolves it, and so an
			// escaped '$' never becomes a variable reference.
			if i + 1 < len(line) {
				strings.write_byte(&b, '\\')
				strings.write_byte(&b, line[i + 1])
				has_word = true
				i += 2
				continue
			}
			i += 1
			continue

		case '|':
			flush_word(&result, &b, &has_word, allocator)
			if i + 1 < len(line) && line[i + 1] == '|' {
				append(&result, Token{kind = .Or})
				i += 2
			} else {
				append(&result, Token{kind = .Pipe})
				i += 1
			}
			continue

		case '&':
			flush_word(&result, &b, &has_word, allocator)
			if i + 1 < len(line) && line[i + 1] == '&' {
				append(&result, Token{kind = .And})
				i += 2
				continue
			}
			// A lone '&' has no meaning here: there is no job control, so
			// treat it as ordinary text rather than silently dropping it.
			strings.write_byte(&b, '&')
			has_word = true
			i += 1
			continue

		case ';':
			flush_word(&result, &b, &has_word, allocator)
			append(&result, Token{kind = .Semi})
			i += 1
			continue

		case '>':
			flush_word(&result, &b, &has_word, allocator)
			if i + 1 < len(line) && line[i + 1] == '>' {
				append(&result, Token{kind = .Append})
				i += 2
			} else {
				append(&result, Token{kind = .Write})
				i += 1
			}
			continue

		case '#':
			// Comment to end of line, but only when it starts a word.
			if !has_word {
				flush_word(&result, &b, &has_word, allocator)
				i = len(line)
				continue
			}
			strings.write_byte(&b, ch)
			has_word = true
			i += 1
			continue
		}

		strings.write_byte(&b, ch)
		has_word = true
		i += 1

		if len(result) > MAX_ARGS {
			return nil, .Too_Many_Tokens
		}
		if strings.builder_len(b) > MAX_EXPANSION {
			return nil, .Too_Long
		}
	}

	flush_word(&result, &b, &has_word, allocator)

	if len(result) > MAX_ARGS {
		return nil, .Too_Many_Tokens
	}
	return result[:], .None
}

// ---------------------------------------------------------------------------
// Variable expansion
// ---------------------------------------------------------------------------

// Expands one lexed word: resolves backslash escapes and substitutes variables.
shell_expand :: proc(
	c: ^Client,
	text: string,
	allocator := context.temp_allocator,
) -> (result: string, err: Lex_Error) {
	b := strings.builder_make(allocator)
	expand_into(c, &b, text) or_return
	return strings.to_string(b), .None
}

// Expands every $VAR in `text` into `b`.
@(private = "file")
expand_into :: proc(c: ^Client, b: ^strings.Builder, text: string) -> Lex_Error {
	i := 0
	for i < len(text) {
		if text[i] == '\\' && i + 1 < len(text) {
			strings.write_byte(b, text[i + 1])
			i += 2
			continue
		}
		if text[i] == '$' {
			consumed := expand_one(c, b, text[i:]) or_return
			i += consumed
			continue
		}
		strings.write_byte(b, text[i])
		i += 1

		if strings.builder_len(b^) > MAX_EXPANSION {
			return .Too_Long
		}
	}
	return .None
}

// Expands the single reference at the front of `text`, which starts with '$'.
// Returns how many bytes were consumed.
@(private = "file")
expand_one :: proc(
	c: ^Client,
	b: ^strings.Builder,
	text: string,
) -> (consumed: int, err: Lex_Error) {
	if len(text) < 2 {
		strings.write_byte(b, '$')
		return 1, .None
	}

	// $? is the status of the last command.
	if text[1] == '?' {
		fmt.sbprintf(b, "%d", c.last_status)
		return 2, .None
	}

	name: string
	total: int

	if text[1] == '{' {
		end := strings.index_byte(text, '}')
		if end < 0 {
			strings.write_byte(b, '$')
			return 1, .None
		}
		name = text[2:end]
		total = end + 1
	} else {
		j := 1
		for j < len(text) {
			ch := text[j]
			ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
			if j > 1 {
				ok = ok || (ch >= '0' && ch <= '9')
			}
			if !ok {
				break
			}
			j += 1
		}
		if j == 1 {
			// A bare '$' is just a dollar sign.
			strings.write_byte(b, '$')
			return 1, .None
		}
		name = text[1:j]
		total = j
	}

	value := shell_var_get(c, name)
	// An undefined variable expands to nothing, as in a POSIX shell. Writing
	// the literal text instead would make a typo silently become a filename.
	strings.write_string(b, value)

	if strings.builder_len(b^) > MAX_EXPANSION {
		return total, .Too_Long
	}
	return total, .None
}

// Resolves a variable name to its value.
//
// The dynamic ones are computed rather than stored, so they cannot drift out of
// date with the session they describe.
shell_var_get :: proc(c: ^Client, name: string) -> string {
	switch name {
	case "USER":
		user := client_get_user(c, context.temp_allocator)
		return len(user) > 0 ? user : client_get_name(c, context.temp_allocator)
	case "NAME":
		return client_get_name(c, context.temp_allocator)
	case "HOME":
		user := client_get_user(c, context.temp_allocator)
		return len(user) > 0 ? fmt.tprintf("/home/%s", user) : "/tmp"
	case "PWD":
		return client_get_cwd(c, context.temp_allocator)
	case "HOSTNAME":
		return SERVER_NAME
	case "SHELL":
		return "/bin/wsh"
	case "TERM":
		return "xterm-256color"
	case "VERSION":
		return SERVER_VERSION
	case "SESSION":
		return fmt.tprintf("%d", c.id)
	case "?":
		return fmt.tprintf("%d", c.last_status)
	}

	if v, ok := c.vars[name]; ok {
		return v
	}
	return ""
}

// Stores a session variable. Returns false if the name is unusable or the
// session is already at its limit.
shell_var_set :: proc(c: ^Client, name: string, value: string) -> bool {
	if !is_valid_var_name(name) {
		return false
	}
	if len(value) > MAX_VAR_VALUE {
		return false
	}

	if existing, ok := c.vars[name]; ok {
		delete(existing)
		c.vars[name] = strings.clone(value)
		return true
	}

	if len(c.vars) >= MAX_VARS {
		return false
	}
	c.vars[strings.clone(name)] = strings.clone(value)
	return true
}

shell_var_unset :: proc(c: ^Client, name: string) {
	if name not_in c.vars {
		return
	}
	// The map owns both the key and the value, so both are released here.
	key, value := delete_key(&c.vars, name)
	delete(key)
	delete(value)
}

is_valid_var_name :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_VAR_NAME {
		return false
	}
	for i in 0 ..< len(name) {
		ch := name[i]
		ok := (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
		if i > 0 {
			ok = ok || (ch >= '0' && ch <= '9')
		}
		if !ok {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Parsing and execution
// ---------------------------------------------------------------------------

// One stage of a pipeline.
Stage :: struct {
	args: []string,
}

// A pipeline, plus how its output is disposed of and how it joins to the next.
Pipeline :: struct {
	stages:          []Stage,
	redirect:        string, // "" when the output goes to the terminal
	redirect_append: bool,
}

Join :: enum {
	Always, // ;
	On_Success, // &&
	On_Failure, // ||
}

// Runs a whole command line.
shell_run :: proc(c: ^Client, line: string) {
	tokens, lex_err := shell_lex(line)
	if lex_err != .None {
		client_sendf(c, "\x1b[31msyntax error: %s\x1b[0m\r\n", lex_error_string(lex_err))
		c.last_status = 2
		return
	}
	if len(tokens) == 0 {
		return
	}

	// Walk the token stream, executing each pipeline as its separator is
	// resolved. There is no separate AST: the grammar is flat enough that
	// building one would be ceremony.
	join := Join.Always
	start := 0
	executed := 0

	for i := 0; i <= len(tokens); i += 1 {
		is_end := i == len(tokens)
		if !is_end && tokens[i].kind != .Semi && tokens[i].kind != .And && tokens[i].kind != .Or {
			continue
		}

		segment := tokens[start:i]
		if len(segment) > 0 {
			should_run :=
				join == .Always ||
				(join == .On_Success && c.last_status == 0) ||
				(join == .On_Failure && c.last_status != 0)

			if should_run {
				run_pipeline(c, segment)
			}

			executed += 1
			if executed >= MAX_COMMAND_LIST {
				client_send(c, "\x1b[31mtoo many commands on one line\x1b[0m\r\n")
				return
			}
		}

		if is_end {
			break
		}

		switch tokens[i].kind {
		case .And:
			join = .On_Success
		case .Or:
			join = .On_Failure
		case .Semi:
			join = .Always
		case .Word, .Pipe, .Write, .Append:
			unreachable()
		}
		start = i + 1
	}
}

// Executes one pipeline: a series of stages separated by '|', with an optional
// redirection on the end.
@(private = "file")
run_pipeline :: proc(c: ^Client, tokens: []Token) {
	stages := make([dynamic]Stage, context.temp_allocator)
	current := make([dynamic]string, context.temp_allocator)

	redirect := ""
	redirect_append := false

	i := 0
	for i < len(tokens) {
		switch tokens[i].kind {
		case .Word:
			// Expanded here, immediately before this pipeline runs, so that
			// `$?` and any variable a previous command set are current.
			word, xerr := shell_expand(c, tokens[i].text)
			if xerr != .None {
				client_sendf(c, "\x1b[31m%s\x1b[0m\r\n", lex_error_string(xerr))
				c.last_status = 2
				return
			}
			append(&current, word)
			i += 1

		case .Pipe:
			if len(current) == 0 {
				client_send(c, "\x1b[31msyntax error near '|'\x1b[0m\r\n")
				c.last_status = 2
				return
			}
			append(&stages, Stage{args = current[:]})
			current = make([dynamic]string, context.temp_allocator)
			i += 1

		case .Write, .Append:
			if i + 1 >= len(tokens) || tokens[i + 1].kind != .Word {
				client_send(c, "\x1b[31msyntax error: expected a file name after '>'\x1b[0m\r\n")
				c.last_status = 2
				return
			}
			target, xerr := shell_expand(c, tokens[i + 1].text)
			if xerr != .None {
				client_sendf(c, "\x1b[31m%s\x1b[0m\r\n", lex_error_string(xerr))
				c.last_status = 2
				return
			}
			redirect = target
			redirect_append = tokens[i].kind == .Append
			i += 2

		case .Semi, .And, .Or:
			unreachable() // consumed by shell_run
		}
	}

	if len(current) > 0 {
		append(&stages, Stage{args = current[:]})
	}
	if len(stages) == 0 {
		return
	}
	if len(stages) > MAX_PIPELINE_STAGES {
		client_send(c, "\x1b[31mtoo many pipeline stages\x1b[0m\r\n")
		c.last_status = 2
		return
	}

	// A leading NAME=value with nothing after it is an assignment, not a
	// command, which is how a shell behaves and how anyone will expect to be
	// able to set a variable.
	if len(stages) == 1 && len(redirect) == 0 && try_assignment(c, stages[0].args) {
		return
	}

	piped_input := ""
	status := 0

	for stage, index in stages {
		is_last := index == len(stages) - 1
		capture_output := !is_last || len(redirect) > 0

		ctx := Cmd_Ctx {
			client = c,
			stdin  = piped_input,
		}

		builder: strings.Builder
		if capture_output {
			builder = strings.builder_make(context.temp_allocator)
			ctx.capture = &builder
		}

		if !run_stage(c, &ctx, stage.args) {
			c.last_status = 127
			return
		}

		status = ctx.status
		if capture_output {
			piped_input = strings.to_string(builder)
		}

		// A failing stage stops the pipeline rather than feeding an error
		// message into the next command as if it were data.
		if status != 0 && !is_last {
			break
		}
	}

	c.last_status = status

	if len(redirect) > 0 && status == 0 {
		write_redirect(c, redirect, piped_input, redirect_append)
	} else if len(redirect) > 0 {
		// The command failed; its message already went to the terminal via the
		// capture, so surface it rather than silently writing it to a file.
		crlf, _ := strings.replace_all(piped_input, "\n", "\r\n", context.temp_allocator)
		client_send(c, crlf)
	}
}

// Looks up and invokes one command. Returns false if there is no such command.
@(private = "file")
run_stage :: proc(c: ^Client, ctx: ^Cmd_Ctx, args: []string) -> bool {
	if len(args) == 0 {
		return true
	}

	effective := args

	// Session aliases are expanded exactly once, and only in the command
	// position. Expanding repeatedly would let `alias a=b` and `alias b=a` loop
	// forever, and expanding arguments would mean a variable holding an alias
	// name silently became a different command.
	if body, aliased := c.aliases[args[0]]; aliased {
		expanded := make([dynamic]string, context.temp_allocator)

		for word in split_args(body, context.temp_allocator) {
			append(&expanded, word)
		}
		for extra in args[1:] {
			append(&expanded, extra)
		}

		if len(expanded) == 0 {
			return true
		}
		effective = expanded[:]
	}

	name := strings.to_lower(effective[0], context.temp_allocator)

	// An alias can never shadow a built-in — cmd_alias refuses those names — so
	// a user cannot redefine `rm` into something surprising and then forget.
	command, found := find_command(name)
	if !found {
		client_sendf(
			c,
			"\x1b[31m%s: command not found\x1b[0m%s\r\n",
			sanitize_text(effective[0], 32, context.temp_allocator),
			format_suggestions(name),
		)
		return false
	}

	command.handler(ctx, effective[1:])
	return true
}

// Handles `NAME=value` as a statement.
@(private = "file")
try_assignment :: proc(c: ^Client, args: []string) -> bool {
	if len(args) != 1 {
		return false
	}

	eq := strings.index_byte(args[0], '=')
	if eq <= 0 {
		return false
	}

	name := args[0][:eq]
	if !is_valid_var_name(name) {
		return false
	}

	if !shell_var_set(c, name, args[0][eq + 1:]) {
		client_sendf(c, "\x1b[31mcannot set %s (limit reached)\x1b[0m\r\n", name)
		c.last_status = 1
		return true
	}

	c.last_status = 0
	return true
}

@(private = "file")
write_redirect :: proc(c: ^Client, target: string, content: string, append_mode: bool) {
	if !rate_allow(&c.rl_write) {
		client_send(c, "\x1b[31mwriting too fast, slow down\x1b[0m\r\n")
		c.last_status = 1
		return
	}

	cwd := client_get_cwd(c, context.temp_allocator)
	user := client_get_user(c, context.temp_allocator)
	abs := vfs_resolve_path(cwd, target, context.temp_allocator)

	err: VFS_Error
	if append_mode {
		err = vfs_append(&g_vfs, abs, content, user)
	} else {
		err = vfs_write(&g_vfs, abs, content, user)
	}

	if err != .None {
		client_sendf(
			c,
			"\x1b[31m%s: %s\x1b[0m\r\n",
			sanitize_text(target, 64, context.temp_allocator),
			vfs_error_string(err),
		)
		c.last_status = 1
	}
}
