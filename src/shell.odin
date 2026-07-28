package main

import "base:intrinsics"
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
	literal_glob: ^bool,
	allocator: runtime.Allocator,
) {
	if !has_word^ {
		return
	}
	append(
		result,
		Token {
			kind = .Word,
			text = strings.clone(strings.to_string(b^), allocator),
			literal_glob = literal_glob^,
		},
	)
	strings.builder_reset(b)
	has_word^ = false
	literal_glob^ = false
}

// Whether a quoted region contains anything the glob pass would act on.
//
// Only quoted *magic* disables globbing for the word, so `"*.txt"` is a
// literal filename while `"notes"*` still expands. Setting the flag for every
// quoted word would make the second case stop working for no reason.
@(private = "file")
region_has_glob_magic :: proc(s: string) -> bool {
	return has_glob_magic(s)
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

// How deep `$( $( ... ) )` may nest. Each level is a live recursion through
// the executor, so this is a stack bound as much as a sanity one — and an
// alias whose body substitutes itself would otherwise recurse until the
// thread died.
MAX_SUBST_DEPTH :: 4

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
	Read, // <
	Background, // &
}

Token :: struct {
	kind: Token_Kind,
	text: string, // for Word: quoting resolved, expansion still pending
	// Set when a quoted part of the word contained a glob metacharacter, which
	// makes the whole word a literal name. Quoting has to survive into the glob
	// pass somehow, and the alternative — escaping the metacharacters and
	// unescaping them afterwards — means the escape has to pass through
	// variable expansion and path resolution intact, which it cannot.
	literal_glob: bool,
}

Lex_Error :: enum {
	None,
	Unterminated_Quote,
	Unterminated_Substitution,
	Too_Many_Tokens,
	Too_Long,
	Too_Deep,
}

lex_error_string :: proc(e: Lex_Error) -> string {
	switch e {
	case .None:
		return "ok"
	case .Unterminated_Quote:
		return "unterminated quote"
	case .Unterminated_Substitution:
		return "unterminated $( )"
	case .Too_Many_Tokens:
		return "too many arguments"
	case .Too_Long:
		return "expansion too large"
	case .Too_Deep:
		return "command substitution nested too deeply"
	}
	return "syntax error"
}

// Finds the ')' closing the '(' at `open`, counting nested pairs and skipping
// quoted regions so that `$(echo "a)b")` and `$(echo $(date))` both survive.
@(private = "file")
find_subst_end :: proc(line: string, open: int) -> (end: int, ok: bool) {
	depth := 0
	i := open

	for i < len(line) {
		switch line[i] {
		case '\\':
			i += 2
			continue
		case '\'', '"':
			quote := line[i]
			i += 1
			for i < len(line) && line[i] != quote {
				// A backslash escape inside double quotes; single quotes have
				// none, but skipping one there only ever skips a literal
				// backslash, which cannot be the closing quote anyway.
				if line[i] == '\\' && quote == '"' {
					i += 1
				}
				i += 1
			}
			if i >= len(line) {
				return 0, false
			}
		case '(':
			depth += 1
		case ')':
			depth -= 1
			if depth == 0 {
				return i, true
			}
		}
		i += 1
	}
	return 0, false
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
	literal_glob := false // a quoted '*' is a filename, not a pattern

	i := 0
	for i < len(line) {
		ch := line[i]

		switch ch {
		case ' ', '\t':
			flush_word(&result, &b, &has_word, &literal_glob, allocator)
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
			if region_has_glob_magic(line[i + 1:i + 1 + end]) {
				literal_glob = true
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
			if region_has_glob_magic(line[i + 1:j]) {
				literal_glob = true
			}
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
			flush_word(&result, &b, &has_word, &literal_glob, allocator)
			if i + 1 < len(line) && line[i + 1] == '|' {
				append(&result, Token{kind = .Or})
				i += 2
			} else {
				append(&result, Token{kind = .Pipe})
				i += 1
			}
			continue

		case '&':
			flush_word(&result, &b, &has_word, &literal_glob, allocator)
			if i + 1 < len(line) && line[i + 1] == '&' {
				append(&result, Token{kind = .And})
				i += 2
				continue
			}
			append(&result, Token{kind = .Background})
			i += 1
			continue

		case ';':
			flush_word(&result, &b, &has_word, &literal_glob, allocator)
			append(&result, Token{kind = .Semi})
			i += 1
			continue

		case '>':
			flush_word(&result, &b, &has_word, &literal_glob, allocator)
			if i + 1 < len(line) && line[i + 1] == '>' {
				append(&result, Token{kind = .Append})
				i += 2
			} else {
				append(&result, Token{kind = .Write})
				i += 1
			}
			continue

		case '<':
			flush_word(&result, &b, &has_word, &literal_glob, allocator)
			append(&result, Token{kind = .Read})
			i += 1
			continue

		case '$':
			// `$(...)` is copied through as one opaque unit. It cannot be
			// tokenised here: the text inside is a command line of its own, and
			// letting the lexer see its pipes and semicolons would tear it into
			// pieces of the outer line. Expansion runs it later, when there is a
			// client to run it against.
			if i + 1 < len(line) && line[i + 1] == '(' {
				end, ok := find_subst_end(line, i + 1)
				if !ok {
					return nil, .Unterminated_Substitution
				}
				strings.write_string(&b, line[i:end + 1])
				has_word = true
				i = end + 1
				continue
			}
			strings.write_byte(&b, ch)
			has_word = true
			i += 1
			continue

		case '#':
			// Comment to end of line, but only when it starts a word.
			if !has_word {
				flush_word(&result, &b, &has_word, &literal_glob, allocator)
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

	flush_word(&result, &b, &has_word, &literal_glob, allocator)

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
	ex: Exec,
	allocator := context.temp_allocator,
) -> (result: string, err: Lex_Error) {
	b := strings.builder_make(allocator)
	expand_into(c, &b, text, ex) or_return
	return strings.to_string(b), .None
}

// Expands every $VAR in `text` into `b`.
@(private = "file")
expand_into :: proc(c: ^Client, b: ^strings.Builder, text: string, ex: Exec) -> Lex_Error {
	i := 0
	for i < len(text) {
		if text[i] == '\\' && i + 1 < len(text) {
			strings.write_byte(b, text[i + 1])
			i += 2
			continue
		}
		if text[i] == '$' {
			consumed := expand_one(c, b, text[i:], ex) or_return
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
	ex: Exec,
) -> (consumed: int, err: Lex_Error) {
	if len(text) < 2 {
		strings.write_byte(b, '$')
		return 1, .None
	}

	// $? is the status of the last command.
	if text[1] == '?' {
		fmt.sbprintf(b, "%d", ex.status^)
		return 2, .None
	}

	// $1 .. $9, $0, $# and $@ come from the running script.
	if text[1] >= '0' && text[1] <= '9' {
		index := int(text[1] - '0')
		if index < len(ex.args) {
			strings.write_string(b, ex.args[index])
		}
		return 2, .None
	}
	if text[1] == '#' {
		// $0 is the script's own name and is not one of the arguments.
		count := len(ex.args) > 0 ? len(ex.args) - 1 : 0
		fmt.sbprintf(b, "%d", count)
		return 2, .None
	}
	if text[1] == '@' || text[1] == '*' {
		if len(ex.args) > 1 {
			strings.write_string(
				b,
				strings.join(ex.args[1:], " ", context.temp_allocator),
			)
		}
		return 2, .None
	}

	// $(command) runs the command and substitutes its output.
	if text[1] == '(' {
		end, ok := find_subst_end(text, 1)
		if !ok {
			return 0, .Unterminated_Substitution
		}
		out := shell_capture(c, text[2:end], ex) or_return
		strings.write_string(b, out)
		if strings.builder_len(b^) > MAX_EXPANSION {
			return end + 1, .Too_Long
		}
		return end + 1, .None
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

	// A trailing '&' sends the line to the background.
	//
	// Only trailing: backgrounding one command in the middle of a list means
	// splitting the line by source position and running the halves
	// differently, and `sleep 5 &` is what people actually type. Anything else
	// says so rather than quietly running in the foreground.
	for tok, i in tokens {
		if tok.kind != .Background {
			continue
		}
		if i != len(tokens) - 1 {
			client_send(
				c,
				"\x1b[31m'&' is only understood at the end of a line\x1b[0m\r\n",
			)
			c.last_status = 2
			return
		}

		// The '&' is the last token, so it is also the last non-space byte of
		// the line: the body is everything before it.
		body := strings.trim_right_space(line)
		body = body[:len(body) - 1]
		if len(strings.trim_space(body)) == 0 {
			client_send(c, "\x1b[31msyntax error near '&'\x1b[0m\r\n")
			c.last_status = 2
			return
		}

		pid, spawn_err := proc_spawn(c, body)
		if len(spawn_err) > 0 {
			client_sendf(c, "\x1b[31m%s\x1b[0m\r\n", spawn_err)
			c.last_status = 1
			return
		}
		client_sendf(c, "\x1b[90m[%d] started\x1b[0m\r\n", pid)
		c.last_status = 0
		return
	}

	// A foreground line is a process too, so `ps` shows what the machine is
	// doing and a disconnect can stop work that is still running.
	pid := proc_begin(
		c.id,
		client_get_name(c, context.temp_allocator),
		sanitize_text(line, 80, context.temp_allocator),
		false,
	)

	// Published so the reader thread knows what a `^C` should interrupt, and
	// cleared before proc_end so an interrupt can never land on a pid that has
	// already finished and been reused.
	intrinsics.atomic_store(&c.current_pid, pid)
	run_token_list(c, tokens, Exec{pid = pid, status = &c.last_status})
	intrinsics.atomic_store(&c.current_pid, 0)

	proc_end(pid, c.last_status)
}

// Runs a line on a background thread, against a snapshot of the session rather
// than the session itself. Returns the status of the last pipeline.
shell_run_detached :: proc(c: ^Client, line: string, detached: ^Detached) -> int {
	tokens, lex_err := shell_lex(line)
	if lex_err != .None {
		client_sendf(c, "\x1b[31msyntax error: %s\x1b[0m\r\n", lex_error_string(lex_err))
		return 2
	}

	// A detached run keeps its own status: c.last_status belongs to the reader
	// thread and writing to it from here would be a race, and a visible one —
	// `$?` would start reporting whatever a background job did last.
	status := 0
	run_token_list(
		c,
		tokens,
		Exec{detached = detached, pid = detached.pid, status = &status},
	)
	return status
}

// Runs a command line and returns what it printed instead of showing it.
//
// This is `$(...)`. Errors still reach the terminal — a substitution that fails
// should say so rather than silently expanding to nothing — but ordinary output
// becomes the value of the expansion.
shell_capture :: proc(
	c: ^Client,
	line: string,
	ex: Exec,
	allocator := context.temp_allocator,
) -> (out: string, err: Lex_Error) {
	if c.subst_depth >= MAX_SUBST_DEPTH {
		return "", .Too_Deep
	}
	c.subst_depth += 1
	defer c.subst_depth -= 1

	tokens := shell_lex(line, context.temp_allocator) or_return

	b := strings.builder_make(allocator)
	// The substitution inherits everything but the output destination: it must
	// run in the same directory, as the same user, under the same process.
	inner := ex
	inner.sink = &b
	run_token_list(c, tokens, inner)

	// Trailing newlines are dropped, as in every shell: `cd $(pwd)` has to
	// produce a path, not a path with a line break welded onto the end.
	text := strings.to_string(b)
	for len(text) > 0 && (text[len(text) - 1] == '\n' || text[len(text) - 1] == '\r') {
		text = text[:len(text) - 1]
	}
	return text, .None
}

// What a running line needs to know beyond the client: where its output goes,
// whose session state it stands in, and which status variable `&&` and `$?`
// read.
//
// It travels as one struct rather than four parameters because every one of
// them has to reach the expansion pass as well — `$(pwd)` inside a background
// job has to see the job's directory, not the session's.
Exec :: struct {
	sink:     ^strings.Builder, // nil: output goes to the terminal
	detached: ^Detached,        // nil: use the live session
	pid:      int,              // owning process, 0 when untracked
	status:   ^int,             // never &c.last_status from another thread

	// A running script's positional parameters, $0 first. Empty elsewhere,
	// which is what makes `$1` expand to nothing at an interactive prompt
	// rather than to whatever the last script was passed.
	args:     []string,
	// Set by `exit` to unwind the script. nil when no script is running.
	stop:     ^bool,
}

// Where the shell's own cwd and user come from, honouring a detached snapshot.
exec_cwd :: proc(c: ^Client, ex: Exec) -> string {
	if ex.detached != nil {
		return ex.detached.cwd
	}
	return client_get_cwd(c, context.temp_allocator)
}

exec_user :: proc(c: ^Client, ex: Exec) -> string {
	if ex.detached != nil {
		return ex.detached.user
	}
	return client_get_user(c, context.temp_allocator)
}

// Lexes and runs one line under an existing execution context.
//
// This is what a script line goes through. It is deliberately not shell_run:
// that one owns process registration and the `&` handling, both of which
// belong to a whole interactive line rather than to each line of a file.
shell_run_line :: proc(c: ^Client, line: string, ex: Exec) {
	tokens, lex_err := shell_lex(line)
	if lex_err != .None {
		client_sendf(c, "\x1b[31msyntax error: %s\x1b[0m\r\n", lex_error_string(lex_err))
		ex.status^ = 2
		return
	}
	run_token_list(c, tokens, ex)
}

@(private = "file")
run_token_list :: proc(c: ^Client, tokens: []Token, ex: Exec) {
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
				(join == .On_Success && ex.status^ == 0) ||
				(join == .On_Failure && ex.status^ != 0)

			if should_run {
				run_pipeline(c, segment, ex)
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
		case .Word, .Pipe, .Write, .Append, .Read, .Background:
			unreachable()
		}
		start = i + 1
	}
}

// Executes one pipeline: a series of stages separated by '|', with an optional
// redirection on the end.
@(private = "file")
run_pipeline :: proc(c: ^Client, tokens: []Token, ex: Exec) {
	stages := make([dynamic]Stage, context.temp_allocator)
	current := make([dynamic]string, context.temp_allocator)

	redirect := ""
	redirect_append := false
	read_from := ""

	i := 0
	for i < len(tokens) {
		switch tokens[i].kind {
		case .Word:
			// Expanded here, immediately before this pipeline runs, so that
			// `$?` and any variable a previous command set are current.
			word, xerr := shell_expand(c, tokens[i].text, ex)
			if xerr != .None {
				client_sendf(c, "\x1b[31m%s\x1b[0m\r\n", lex_error_string(xerr))
				c.last_status = 2
				return
			}

			// Globbing comes after expansion, so `ls $DIR/*` works, and only
			// for words that actually look like patterns. A quoted pattern is
			// a filename and is left exactly as written.
			if matches := tokens[i].literal_glob \
			? nil \
			: shell_glob_word(c, word, ex); matches != nil {
				for m in matches {
					append(&current, m)
				}
			} else {
				append(&current, word)
			}
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
			target, xerr := shell_expand(c, tokens[i + 1].text, ex)
			if xerr != .None {
				client_sendf(c, "\x1b[31m%s\x1b[0m\r\n", lex_error_string(xerr))
				c.last_status = 2
				return
			}
			redirect = target
			redirect_append = tokens[i].kind == .Append
			i += 2

		case .Read:
			if i + 1 >= len(tokens) || tokens[i + 1].kind != .Word {
				client_send(c, "\x1b[31msyntax error: expected a file name after '<'\x1b[0m\r\n")
				c.last_status = 2
				return
			}
			source, xerr := shell_expand(c, tokens[i + 1].text, ex)
			if xerr != .None {
				client_sendf(c, "\x1b[31m%s\x1b[0m\r\n", lex_error_string(xerr))
				c.last_status = 2
				return
			}
			read_from = source
			i += 2

		case .Semi, .And, .Or, .Background:
			// Separators are consumed by run_token_list, and a '&' that reached
			// this far would have been rejected by shell_run.
			unreachable()
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

	// `< file` seeds the first stage's input, exactly as if the file had been
	// cat'd into it.
	piped_input := ""
	if len(read_from) > 0 {
		content, ok := read_redirect(c, read_from)
		if !ok {
			c.last_status = 1
			return
		}
		piped_input = content
	}

	status := 0

	for stage, index in stages {
		is_last := index == len(stages) - 1
		capture_output := !is_last || len(redirect) > 0 || ex.sink != nil

		// Resolved per stage rather than once per line: `cd /tmp ; ls` has to
		// see the new directory, and a stage that changes it must not change
		// the one its neighbours already captured.
		ctx := Cmd_Ctx {
			client  = c,
			stdin   = piped_input,
			cwd     = ex.detached != nil \
			? ex.detached.cwd \
			: client_get_cwd(c, context.temp_allocator),
			user    = ex.detached != nil \
			? ex.detached.user \
			: client_get_user(c, context.temp_allocator),
			proc_id = ex.pid,
			detached = ex.detached != nil,
			script_stop = ex.stop,
		}

		builder: strings.Builder
		if capture_output {
			builder = strings.builder_make(context.temp_allocator)
			ctx.capture = &builder
		}

		if !run_stage(c, &ctx, stage.args, ex) {
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

	ex.status^ = status

	// Inside a substitution the output is the value, not something to print.
	// A redirection still wins over it: `$(echo hi > f)` writes the file and
	// expands to nothing, which is what a shell does.
	if ex.sink != nil && len(redirect) == 0 {
		strings.write_string(ex.sink, piped_input)
		return
	}

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
run_stage :: proc(c: ^Client, ctx: ^Cmd_Ctx, args: []string, ex: Exec) -> bool {
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

	// A detached job may not touch session state. See SESSION_COMMANDS for why
	// refusing beats either racing on it or silently doing nothing.
	if ex.detached != nil && is_session_command(name) {
		errf(
			ctx,
			"%s: cannot run in the background — it changes the session\n",
			name,
		)
		return true
	}

	// A cancelled process stops between stages even when the command it is
	// running never checks for itself.
	if proc_cancelled(ex.pid) {
		return true
	}

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

// Expands one word as a glob, or returns nil when it is not a pattern or
// matches nothing.
//
// A pattern that matches nothing is left alone rather than erased, which is
// what a shell does by default and the only safe choice: `rm *.bak` in a
// directory with no backups must fail with "no such file", not expand to
// nothing and become a bare `rm`.
//
// Matches inside the working directory come back relative, so `ls *.txt`
// prints `notes.txt` rather than `/home/alice/notes.txt`.
shell_glob_word :: proc(c: ^Client, word: string, ex: Exec) -> []string {
	if !has_glob_magic(word) {
		return nil
	}

	cwd := exec_cwd(c, ex)
	user := exec_user(c, ex)
	pattern := vfs_resolve_path(cwd, word, context.temp_allocator)

	matches := vfs_glob(&g_vfs, pattern, user, context.temp_allocator)
	if len(matches) == 0 {
		return nil
	}

	// Only strip the prefix when the word was itself relative; an absolute
	// pattern should keep producing absolute paths.
	if strings.has_prefix(word, "/") {
		return matches
	}

	prefix := cwd == "/" ? "/" : strings.concatenate({cwd, "/"}, context.temp_allocator)
	out := make([dynamic]string, context.temp_allocator)
	for m in matches {
		append(&out, strings.has_prefix(m, prefix) ? m[len(prefix):] : m)
	}
	return out[:]
}

// Reads the file behind `< target`.
@(private = "file")
read_redirect :: proc(c: ^Client, target: string) -> (content: string, ok: bool) {
	cwd := client_get_cwd(c, context.temp_allocator)
	user := client_get_user(c, context.temp_allocator)
	abs := vfs_resolve_path(cwd, target, context.temp_allocator)

	data, read_ok := vfs_read(&g_vfs, abs, user, context.temp_allocator)
	if !read_ok {
		// Same distinction the file-reading commands make, so `< somedir` and
		// `cat somedir` do not explain themselves differently.
		reason := vfs_is_dir(&g_vfs, abs) ? VFS_Error.Is_A_Directory : VFS_Error.Not_Found
		client_sendf(
			c,
			"\x1b[31m%s: %s\x1b[0m\r\n",
			sanitize_text(target, 64, context.temp_allocator),
			vfs_error_string(reason),
		)
		return "", false
	}
	return data, true
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
