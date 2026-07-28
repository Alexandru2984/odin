package main

import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// Unit tests
//
// `make deploy` runs these before restarting the service, so they are the last
// gate before a change reaches production. They cover the pure logic — parsing,
// validation, escaping — where a mistake is silent rather than obvious, and
// where an error is a security bug rather than a cosmetic one.
//
// Anything needing a live socket is covered by the integration tests instead;
// this file deliberately touches no global state.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Path validation
// ---------------------------------------------------------------------------

@(test)
test_path_validation_rejects_bad_shapes :: proc(t: ^testing.T) {
	testing.expect(t, vfs_validate_path("/") == .None, "root is valid")
	testing.expect(t, vfs_validate_path("/tmp/a.txt") == .None, "ordinary path is valid")

	testing.expect(t, vfs_validate_path("") == .Invalid_Path, "empty path rejected")
	testing.expect(t, vfs_validate_path("relative") == .Invalid_Path, "relative path rejected")

	// A control character in a path would be re-emitted into other terminals
	// by `ls`, so it must never reach the filesystem.
	testing.expect(t, vfs_validate_path("/tmp/a\x1b[31mb") == .Invalid_Path, "escape rejected")
	testing.expect(t, vfs_validate_path("/tmp/a\nb") == .Invalid_Path, "newline rejected")

	long := strings.repeat("a", VFS_MAX_PATH_LEN + 10, context.temp_allocator)
	deep := strings.concatenate({"/", long}, context.temp_allocator)
	testing.expect(t, vfs_validate_path(deep) != .None, "over-long path rejected")
}

@(test)
test_resolve_path_cannot_escape_root :: proc(t: ^testing.T) {
	// "/.." resolves to "/", so no amount of parent references escapes.
	cases := [?]string{"..", "../..", "../../../../etc/passwd", "a/../..", "./../.."}

	for target in cases {
		got := vfs_resolve_path("/tmp", target, context.temp_allocator)
		testing.expect(
			t,
			strings.has_prefix(got, "/"),
			"resolved path stays absolute",
		)
		testing.expect(
			t,
			!strings.contains(got, ".."),
			"resolved path has no parent references left",
		)
	}

	testing.expect_value(t, vfs_resolve_path("/tmp", "..", context.temp_allocator), "/")
	testing.expect_value(t, vfs_resolve_path("/tmp", "a/b", context.temp_allocator), "/tmp/a/b")
	testing.expect_value(t, vfs_resolve_path("/tmp", "/etc", context.temp_allocator), "/etc")
}

// ---------------------------------------------------------------------------
// Untrusted text
// ---------------------------------------------------------------------------

@(test)
test_sanitize_strips_control_sequences :: proc(t: ^testing.T) {
	// This is the boundary that stops one user painting arbitrary output into
	// everyone else's terminal.
	got := sanitize_text("\x1b[2Jhello\x07", 100, context.temp_allocator)
	testing.expect(t, !strings.contains(got, "\x1b"), "escape removed")
	testing.expect(t, !strings.contains(got, "\x07"), "bell removed")
	testing.expect(t, strings.contains(got, "hello"), "ordinary text kept")

	// C1 controls are treated as controls by some terminals too.
	testing.expect(
		t,
		len(sanitize_text("", 100, context.temp_allocator)) == 0,
		"C1 range removed",
	)

	// The cap counts runes, not bytes, so multi-byte text is not cut mid-rune.
	truncated := sanitize_text("ăăăăăă", 3, context.temp_allocator)
	testing.expect_value(t, truncated, "ăăă")
}

@(test)
test_username_validation :: proc(t: ^testing.T) {
	ok_names := [?]string{"alice", "bob99", "a_b", "x-y", "Zed"}
	for name in ok_names {
		valid, _ := validate_username(name)
		testing.expect(t, valid, "ordinary name accepted")
	}

	// Reserved names would let a user impersonate the server in broadcasts.
	bad_names := [?]string {
		"a", // too short
		"root",
		"System", // reserved, case-insensitively
		"admin",
		"has space",
		"has/slash", // would escape its own home directory
		"has.dot",
		"-lead",
		"_lead",
	}
	for name in bad_names {
		valid, _ := validate_username(name)
		testing.expect(t, !valid, "unacceptable name rejected")
	}
}

// ---------------------------------------------------------------------------
// History redaction
// ---------------------------------------------------------------------------

@(test)
test_history_redaction_hides_passwords :: proc(t: ^testing.T) {
	got := redact_for_history("login alice hunter2", context.temp_allocator)
	testing.expect(t, !strings.contains(got, "hunter2"), "password removed")
	testing.expect(t, strings.contains(got, "alice"), "username kept, it is not secret")

	got = redact_for_history("register bob correct horse battery", context.temp_allocator)
	testing.expect(t, !strings.contains(got, "horse"), "multi-word password removed")

	got = redact_for_history("passwd old new", context.temp_allocator)
	testing.expect(t, !strings.contains(got, "new"), "passwd arguments removed")

	// A command that is not a credential command is stored verbatim.
	testing.expect_value(
		t,
		redact_for_history("echo hunter2", context.temp_allocator),
		"echo hunter2",
	)
	// So is a bare credential command, which carries nothing to hide.
	testing.expect_value(t, redact_for_history("login", context.temp_allocator), "login")
}

// ---------------------------------------------------------------------------
// Shell lexing
// ---------------------------------------------------------------------------

@(private = "file")
lex_words :: proc(line: string) -> []string {
	tokens, err := shell_lex(line, context.temp_allocator)
	if err != .None {
		return nil
	}
	words := make([dynamic]string, context.temp_allocator)
	for tok in tokens {
		if tok.kind == .Word {
			append(&words, tok.text)
		}
	}
	return words[:]
}

@(test)
test_lexer_honours_quoting :: proc(t: ^testing.T) {
	words := lex_words(`echo "one two" three`)
	testing.expect_value(t, len(words), 3)
	testing.expect_value(t, words[1], "one two")

	// A quoted operator is text, not syntax. If this regresses, `echo "a | b"`
	// starts trying to run a command called b.
	tokens, _ := shell_lex(`echo "a | b"`, context.temp_allocator)
	for tok in tokens {
		testing.expect(t, tok.kind != .Pipe, "pipe inside quotes is not an operator")
	}

	// An unterminated quote is an error rather than a silently truncated line.
	_, err := shell_lex(`echo "unclosed`, context.temp_allocator)
	testing.expect(t, err == .Unterminated_Quote, "unterminated quote reported")
}

@(test)
test_lexer_defers_expansion :: proc(t: ^testing.T) {
	// The lexer must not expand: `$?` has to be substituted when the pipeline
	// runs, not when the line is read, or it reports a stale status.
	words := lex_words("echo $?")
	testing.expect_value(t, len(words), 2)
	testing.expect_value(t, words[1], "$?")

	// Single quotes escape the dollar so the later pass leaves it alone.
	single := lex_words(`echo '$USER'`)
	testing.expect_value(t, len(single), 2)
	testing.expect(t, strings.contains(single[1], "$USER"), "single-quoted text preserved")
	testing.expect(t, strings.has_prefix(single[1], "\\"), "dollar escaped for the later pass")
}

@(test)
test_lexer_finds_operators :: proc(t: ^testing.T) {
	tokens, err := shell_lex("a | b && c || d ; e > f >> g", context.temp_allocator)
	testing.expect(t, err == .None, "operators lex cleanly")

	kinds: [Token_Kind]int
	for tok in tokens {
		kinds[tok.kind] += 1
	}

	testing.expect_value(t, kinds[.Pipe], 1)
	testing.expect_value(t, kinds[.And], 1)
	testing.expect_value(t, kinds[.Or], 1)
	testing.expect_value(t, kinds[.Semi], 1)
	testing.expect_value(t, kinds[.Write], 1)
	testing.expect_value(t, kinds[.Append], 1)
}

// ---------------------------------------------------------------------------
// Filters
//
// A command with a capture buffer and no client is exactly what a pipeline
// stage is, so these run the real handlers with no server behind them.
// ---------------------------------------------------------------------------

@(private = "file")
run_filter :: proc(
	handler: proc(ctx: ^Cmd_Ctx, args: []string),
	stdin: string,
	args: ..string,
) -> string {
	b := strings.builder_make(context.temp_allocator)
	ctx := Cmd_Ctx {
		capture = &b,
		stdin   = stdin,
	}
	handler(&ctx, args)
	return strings.to_string(b)
}

@(test)
test_head_and_tail_accept_the_short_count :: proc(t: ^testing.T) {
	input :: "one\ntwo\nthree\nfour\n"

	// `head -3` is how anyone actually types it. Without the short form the
	// argument falls through and is looked up as a filename.
	testing.expect_value(t, run_filter(cmd_head, input, "-2"), "one\ntwo\n")
	testing.expect_value(t, run_filter(cmd_tail, input, "-1"), "four\n")

	// The long form still works, and so does the default of ten lines.
	testing.expect_value(t, run_filter(cmd_head, input, "-n", "1"), "one\n")
	testing.expect_value(t, run_filter(cmd_head, input), input)

	// A count larger than the input is not an error, it is just everything.
	testing.expect_value(t, run_filter(cmd_head, input, "-99"), input)

	// An unrecognised flag is still ignored when a file follows it, and is
	// only looked up as a path when it stands alone. Both cases need a client
	// to resolve against the VFS, so they live in the integration suite.
}

@(test)
test_grep_does_not_number_lines_by_default :: proc(t: ^testing.T) {
	input :: "alpha\nbeta\ngamma\n"

	// Numbering used to be on by default, which fed "2: beta" to the next
	// stage of every pipeline instead of "beta".
	testing.expect_value(t, run_filter(cmd_grep, input, "beta"), "beta\n")
	testing.expect_value(t, run_filter(cmd_grep, input, "-n", "beta"), "2: beta\n")

	testing.expect_value(t, run_filter(cmd_grep, input, "-v", "beta"), "alpha\ngamma\n")
	testing.expect_value(t, run_filter(cmd_grep, input, "-c", "a"), "3\n")
	testing.expect_value(t, run_filter(cmd_grep, input, "-i", "BETA"), "beta\n")
}

@(test)
test_cowsay_and_banner_read_a_pipe :: proc(t: ^testing.T) {
	// `fortune | cowsay` is the entire reason cowsay exists.
	testing.expect(
		t,
		strings.contains(run_filter(cmd_cowsay, "hi world\n"), "< hi world >"),
		"piped text is what the cow says",
	)

	// Arguments win over stdin, and the bare command still has something to say.
	testing.expect(
		t,
		strings.contains(run_filter(cmd_cowsay, "piped", "typed"), "< typed >"),
		"arguments take precedence over the pipe",
	)
	testing.expect(t, strings.contains(run_filter(cmd_cowsay, ""), "< moo >"), "default kept")

	// The bar is sized in runes; a byte-sized one runs off the end under
	// non-ASCII text and the bubble stops lining up. The bar line is one
	// shorter than the text line by construction: " ---" against "< x >".
	cow := run_filter(cmd_cowsay, "ăăă\n")
	lines := strings.split_lines(cow, context.temp_allocator)
	testing.expect(t, len(lines) > 2, "cow rendered")
	testing.expect_value(
		t,
		strings.rune_count(lines[0]),
		strings.rune_count(lines[1]) - 1,
	)
	testing.expect_value(t, lines[0], lines[2])

	testing.expect(
		t,
		strings.contains(run_filter(cmd_banner, "hi\n"), "#"),
		"banner renders piped text",
	)
	testing.expect(
		t,
		strings.contains(run_filter(cmd_banner, ""), "usage"),
		"banner with nothing at all still explains itself",
	)
}

// ---------------------------------------------------------------------------
// Globbing
//
// The matcher is pure, so the fiddly parts get tested here rather than through
// a live filesystem.
// ---------------------------------------------------------------------------

@(test)
test_glob_star_and_question :: proc(t: ^testing.T) {
	testing.expect(t, glob_match_segment("*", "anything"), "bare star matches")
	testing.expect(t, glob_match_segment("*", ""), "star matches empty")
	testing.expect(t, glob_match_segment("*.txt", "notes.txt"), "suffix pattern")
	testing.expect(t, !glob_match_segment("*.txt", "notes.md"), "wrong suffix")
	testing.expect(t, glob_match_segment("a*c", "abc"), "star in the middle")
	testing.expect(t, glob_match_segment("a*c", "ac"), "star may match nothing")
	testing.expect(t, glob_match_segment("*b*", "abc"), "two stars")

	testing.expect(t, glob_match_segment("?", "a"), "question matches one")
	testing.expect(t, !glob_match_segment("?", ""), "question needs one")
	testing.expect(t, !glob_match_segment("?", "ab"), "question is exactly one")
	testing.expect(t, glob_match_segment("a?c.txt", "abc.txt"), "question in context")

	// The pathological case the iterative matcher exists for. A recursive
	// implementation takes exponential time on this; this must simply answer.
	testing.expect(
		t,
		!glob_match_segment("a*a*a*a*a*a*a*b", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
		"no catastrophic backtracking",
	)
}

@(test)
test_glob_character_classes :: proc(t: ^testing.T) {
	testing.expect(t, glob_match_segment("[abc]", "b"), "class member")
	testing.expect(t, !glob_match_segment("[abc]", "d"), "non-member")
	testing.expect(t, glob_match_segment("[a-z]", "q"), "range")
	testing.expect(t, !glob_match_segment("[a-z]", "Q"), "range is case sensitive")
	testing.expect(t, glob_match_segment("[!a]", "b"), "negated class")
	testing.expect(t, !glob_match_segment("[!a]", "a"), "negated class excludes")
	testing.expect(t, glob_match_segment("file[0-9].txt", "file7.txt"), "class in context")
	testing.expect(t, !glob_match_segment("file[0-9].txt", "filex.txt"), "class rejects")

	// An unterminated class is a literal '[', as in a real shell.
	testing.expect(t, glob_match_segment("[abc", "[abc"), "unterminated class is literal")
}

@(test)
test_glob_leaves_dotfiles_alone :: proc(t: ^testing.T) {
	// The rule that stops `rm *` taking the dotfiles with it.
	testing.expect(t, !glob_match_segment("*", ".config"), "star skips a leading dot")
	testing.expect(t, !glob_match_segment("?config", ".config"), "question skips it too")
	testing.expect(t, !glob_match_segment("[.]config", ".config"), "a class does not count")

	// Asked for by name, it matches.
	testing.expect(t, glob_match_segment(".*", ".config"), "an explicit dot matches")
	testing.expect(t, glob_match_segment(".config", ".config"), "exact name matches")

	// A dot anywhere else is an ordinary character.
	testing.expect(t, glob_match_segment("*.txt", "notes.txt"), "inner dot is ordinary")
}

@(test)
test_glob_paths_match_segment_by_segment :: proc(t: ^testing.T) {
	testing.expect(t, glob_match_path("/tmp/*.txt", "/tmp/a.txt"), "one level")
	testing.expect(t, !glob_match_path("/tmp/*.txt", "/tmp/sub/a.txt"), "star does not cross /")
	testing.expect(t, glob_match_path("/home/*/mail", "/home/alice/mail"), "middle segment")
	testing.expect(t, !glob_match_path("/home/*/mail", "/home/alice/mail/1"), "depth must agree")
	testing.expect(t, !glob_match_path("/home/*", "/home"), "pattern is longer")
}

@(test)
test_glob_magic_detection :: proc(t: ^testing.T) {
	// Words without magic take the fast path and must never be treated as
	// patterns — every command name goes through this.
	testing.expect(t, !has_glob_magic("ls"), "plain word")
	testing.expect(t, !has_glob_magic("/home/alice/notes.txt"), "plain path")
	testing.expect(t, has_glob_magic("*.txt"), "star")
	testing.expect(t, has_glob_magic("a?b"), "question")
	testing.expect(t, has_glob_magic("[ab]"), "class")
}

// ---------------------------------------------------------------------------
// Command substitution
// ---------------------------------------------------------------------------

@(test)
test_lexer_keeps_substitutions_whole :: proc(t: ^testing.T) {
	// The inner text is a command line of its own. If the lexer tokenised it,
	// the pipe below would split the outer line into two stages.
	words := lex_words(`echo $(cat f | wc -l)`)
	testing.expect_value(t, len(words), 2)
	testing.expect_value(t, words[1], "$(cat f | wc -l)")

	// Nesting, and parentheses inside quotes, both have to be tracked.
	nested := lex_words(`echo $(echo $(date))`)
	testing.expect_value(t, len(nested), 2)
	testing.expect_value(t, nested[1], "$(echo $(date))")

	quoted := lex_words(`echo $(echo "a)b")`)
	testing.expect_value(t, len(quoted), 2)
	testing.expect_value(t, quoted[1], `$(echo "a)b")`)

	// An unclosed substitution is a syntax error, not a silently truncated line.
	_, err := shell_lex(`echo $(cat f`, context.temp_allocator)
	testing.expect(t, err == .Unterminated_Substitution, "unterminated $( reported")

	// A lone dollar followed by something else is still ordinary text.
	plain := lex_words(`echo $ (x)`)
	testing.expect(t, len(plain) >= 2, "bare dollar survives")
}

@(test)
test_lexer_finds_input_redirection :: proc(t: ^testing.T) {
	tokens, err := shell_lex("wc -l < file.txt", context.temp_allocator)
	testing.expect(t, err == .None, "input redirection lexes")

	kinds: [Token_Kind]int
	for tok in tokens {
		kinds[tok.kind] += 1
	}
	testing.expect_value(t, kinds[.Read], 1)
	testing.expect_value(t, kinds[.Word], 3)

	// Quoted, it is text rather than syntax.
	quoted, _ := shell_lex(`echo "a < b"`, context.temp_allocator)
	for tok in quoted {
		testing.expect(t, tok.kind != .Read, "'<' inside quotes is not an operator")
	}
}

// ---------------------------------------------------------------------------
// Client control messages
// ---------------------------------------------------------------------------

@(test)
test_control_size_parsing :: proc(t: ^testing.T) {
	c: Client
	c.cols = DEFAULT_TERM_COLS
	c.rows = DEFAULT_TERM_ROWS

	handle_client_control(&c, transmute([]byte)string(`{"t":"size","cols":100,"rows":40}`))
	testing.expect_value(t, c.cols, 100)
	testing.expect_value(t, c.rows, 40)

	// Out-of-range values are clamped, not trusted: a client claiming 100000
	// columns would otherwise have the server allocate padding to match.
	handle_client_control(&c, transmute([]byte)string(`{"t":"size","cols":99999,"rows":99999}`))
	testing.expect_value(t, c.cols, MAX_TERM_COLS)
	testing.expect_value(t, c.rows, MAX_TERM_ROWS)

	// Anything malformed leaves the previous value alone rather than resetting.
	before := c.cols
	handle_client_control(&c, transmute([]byte)string(`{"t":"size","cols":"80"}`))
	testing.expect_value(t, c.cols, before)
	handle_client_control(&c, transmute([]byte)string(`not json at all`))
	testing.expect_value(t, c.cols, before)
	handle_client_control(&c, transmute([]byte)string(`{"t":"other","cols":30,"rows":10}`))
	testing.expect_value(t, c.cols, before)
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

@(test)
test_numbers_pad_with_spaces :: proc(t: ^testing.T) {
	// Odin's fmt pads numeric widths with zeros, so every aligned column goes
	// through these instead. "%6d" would render 42 as "000042".
	testing.expect_value(t, pad_int(42, 6, context.temp_allocator), "    42")
	testing.expect_value(t, pad_int_left(42, 6, context.temp_allocator), "42    ")
	testing.expect_value(t, pad_int(1234567, 3, context.temp_allocator), "1234567")
}

@(test)
test_human_size :: proc(t: ^testing.T) {
	testing.expect_value(t, human_size(0, context.temp_allocator), "0B")
	testing.expect_value(t, human_size(512, context.temp_allocator), "512B")
	testing.expect_value(t, human_size(1024, context.temp_allocator), "1.0K")
	testing.expect_value(t, human_size(1024 * 1024, context.temp_allocator), "1.0M")
}

@(test)
test_truncate_counts_runes :: proc(t: ^testing.T) {
	testing.expect_value(t, truncate_runes("short", 10, context.temp_allocator), "short")
	testing.expect_value(t, truncate_runes("abcdefgh", 4, context.temp_allocator), "abc…")

	// Multi-byte text must not be cut through the middle of a character, which
	// a byte-based slice would do and render as replacement glyphs.
	got := truncate_runes("ăăăăăă", 4, context.temp_allocator)
	testing.expect_value(t, got, "ăăă…")
	testing.expect_value(t, strings.rune_count(got), 4)
}

@(test)
test_duration_formatting :: proc(t: ^testing.T) {
	testing.expect_value(t, duration_short(0, context.temp_allocator), "0s")
	testing.expect_value(t, duration_short(45, context.temp_allocator), "45s")
	// Zero-padded, because "3m7s" reads as a missing digit in a column.
	testing.expect_value(t, duration_short(187, context.temp_allocator), "3m07s")
	testing.expect_value(t, duration_short(3720, context.temp_allocator), "1h02m")
}

@(test)
test_session_commands_are_refused_in_the_background :: proc(t: ^testing.T) {
	// These mutate state the reader thread owns without a lock, so a detached
	// job must not be allowed to run them.
	session := [?]string{"cd", "export", "login", "logout", "alias", "edit"}
	for name in session {
		testing.expect(t, is_session_command(name), "session command recognised")
	}
	// Everything else is safe to detach: it only touches the VFS, which locks.
	ordinary := [?]string{"ls", "cat", "grep", "sleep", "find", "echo"}
	for name in ordinary {
		testing.expect(t, !is_session_command(name), "ordinary command not restricted")
	}
}

@(test)
test_colour_lookup_never_passes_input_through :: proc(t: ^testing.T) {
	// The colour is interpolated into an escape sequence, so an unknown value
	// must map to "" and be refused rather than reaching the terminal.
	testing.expect_value(t, lookup_color("red"), "31")
	testing.expect_value(t, lookup_color("RED"), "31")
	testing.expect_value(t, lookup_color("31"), "31")
	testing.expect_value(t, lookup_color("0m\x1b[31"), "")
	testing.expect_value(t, lookup_color("nonsense"), "")
}

// ---------------------------------------------------------------------------
// Calendar arithmetic
// ---------------------------------------------------------------------------

@(test)
test_calendar_arithmetic :: proc(t: ^testing.T) {
	// 2024 was a leap year, 2023 and 1900 were not, 2000 was.
	testing.expect_value(t, days_in_month(2024, 2), 29)
	testing.expect_value(t, days_in_month(2023, 2), 28)
	testing.expect_value(t, days_in_month(1900, 2), 28)
	testing.expect_value(t, days_in_month(2000, 2), 29)
	testing.expect_value(t, days_in_month(2024, 4), 30)
}
