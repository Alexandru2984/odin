package main

import "core:fmt"
import "core:slice"
import "core:strings"

// ---------------------------------------------------------------------------
// The command table
//
// One entry per command, carrying its own usage and help text. `help` and `man`
// are generated from this table rather than from a hand-maintained string, so a
// command can never be added without also being documented.
//
// Ordering inside a category is deliberate (most-used first), because `help`
// prints them in table order.
// ---------------------------------------------------------------------------

CAT_FS     :: "filesystem"
CAT_TEXT   :: "text"
CAT_USER   :: "identity"
CAT_SOCIAL :: "social"
CAT_SYS    :: "system"
CAT_FUN    :: "fun"

@(rodata)
COMMANDS := [?]Command {
	// --- Filesystem ---------------------------------------------------------
	{
		"ls",
		CAT_FS,
		"ls [-l] [-a] [path]",
		"List directory contents. -l shows owner, size and permissions.",
		cmd_ls,
	},
	{"cd", CAT_FS, "cd [path]", "Change directory. Bare `cd` goes to your home.", cmd_cd},
	{"pwd", CAT_FS, "pwd", "Print the working directory.", cmd_pwd},
	{"mkdir", CAT_FS, "mkdir [-p] <dir...>", "Create directories. -p creates parents.", cmd_mkdir},
	{"rmdir", CAT_FS, "rmdir <dir...>", "Remove empty directories.", cmd_rmdir},
	{"rm", CAT_FS, "rm [-r] <path...>", "Remove files. -r removes a whole subtree.", cmd_rm},
	{"touch", CAT_FS, "touch <file...>", "Create empty files.", cmd_touch},
	{"cp", CAT_FS, "cp <source> <dest>", "Copy a file.", cmd_cp},
	{"mv", CAT_FS, "mv <source> <dest>", "Move or rename a file.", cmd_mv},
	{"stat", CAT_FS, "stat <path>", "Show detailed metadata for a path.", cmd_stat},
	{
		"chmod",
		CAT_FS,
		"chmod <public|owner|private> <path>",
		"Change who may read and write a path you own.",
		cmd_chmod,
	},
	{"tree", CAT_FS, "tree [path]", "Draw the directory tree.", cmd_tree},
	{"find", CAT_FS, "find [root] [pattern]", "Find paths whose name contains a pattern.", cmd_find},
	{"du", CAT_FS, "du [path]", "Sum the size of everything under a path.", cmd_du},
	{"df", CAT_FS, "df", "Show filesystem quota usage.", cmd_df},

	// --- Text ---------------------------------------------------------------
	{"cat", CAT_TEXT, "cat <file...>", "Print file contents.", cmd_cat},
	{"edit", CAT_TEXT, "edit <file>", "Open a file in the full-screen editor.", cmd_edit},
	{"less", CAT_TEXT, "less [file...]", "Page through text a screen at a time.", cmd_less},
	{"echo", CAT_TEXT, "echo <text>", "Print text. Combine with > or >> to write a file.", cmd_echo},
	{
		"grep",
		CAT_TEXT,
		"grep [-i] [-v] [-c] [-n] <pattern> [file...]",
		"Print lines matching a pattern. -i ignore case, -v invert, -c count, -n number.",
		cmd_grep,
	},
	{"head", CAT_TEXT, "head [-N] [-n N] [file]", "Print the first N lines (default 10).", cmd_head},
	{"tail", CAT_TEXT, "tail [-N] [-n N] [file]", "Print the last N lines (default 10).", cmd_tail},
	{"wc", CAT_TEXT, "wc [file...]", "Count lines, words and bytes.", cmd_wc},
	{"rev", CAT_TEXT, "rev <text>", "Reverse text.", cmd_rev},
	{"sort", CAT_TEXT, "sort [-r] [-u] [-n] [file...]", "Sort lines. -r reverse, -u unique, -n numeric.", cmd_sort},
	{"uniq", CAT_TEXT, "uniq [-c] [-d] [file...]", "Collapse adjacent duplicate lines. -c counts them.", cmd_uniq},
	{"nl", CAT_TEXT, "nl [file...]", "Number every line.", cmd_nl},
	{"tac", CAT_TEXT, "tac [file...]", "Print lines in reverse order.", cmd_tac},
	{"cut", CAT_TEXT, "cut [-d D] [-f N] [file...]", "Print field N of each line.", cmd_cut},
	{"tr", CAT_TEXT, "tr <upper|lower|squeeze|from to> [file...]", "Transform characters.", cmd_tr},
	{"diff", CAT_TEXT, "diff <file-a> <file-b>", "Show which lines differ between two files.", cmd_diff},
	{"base64", CAT_TEXT, "base64 [-d] <text|file>", "Encode or decode base64.", cmd_base64},
	{"sha256", CAT_TEXT, "sha256 <text|file>", "Print the SHA-256 digest.", cmd_sha256},
	{"md5", CAT_TEXT, "md5 <text|file>", "Print the MD5 digest (not for security).", cmd_md5},

	// --- Identity -----------------------------------------------------------
	{
		"register",
		CAT_USER,
		"register <username> <password>",
		"Create an account and a home directory you own.",
		cmd_register,
	},
	{"login", CAT_USER, "login <username> <password>", "Sign in to an existing account.", cmd_login},
	{"logout", CAT_USER, "logout", "Drop back to being a guest.", cmd_logout},
	{"passwd", CAT_USER, "passwd <old> <new>", "Change your password.", cmd_passwd},
	{"whoami", CAT_USER, "whoami", "Show who you are currently signed in as.", cmd_whoami},
	{"name", CAT_USER, "name <nickname>", "Set a guest nickname (no account required).", cmd_name},
	{"color", CAT_USER, "color <name>", "Set your prompt colour.", cmd_color},
	{"finger", CAT_USER, "finger [user]", "Show a user's public profile.", cmd_finger},

	// --- Social -------------------------------------------------------------
	{"who", CAT_SOCIAL, "who", "List everyone currently connected.", cmd_who},
	{"wall", CAT_SOCIAL, "wall <message>", "Send a message to every connected terminal.", cmd_wall},
	{"msg", CAT_SOCIAL, "msg <user> <message>", "Send a private message to one user.", cmd_msg},
	{"me", CAT_SOCIAL, "me <action>", "Broadcast an action, IRC style.", cmd_me},
	{"bell", CAT_SOCIAL, "bell [user]", "Flash a terminal to get someone's attention.", cmd_bell},
	{"mail", CAT_SOCIAL, "mail [send|read|clear]", "Leave messages for users who are offline.", cmd_mail},

	// --- System -------------------------------------------------------------
	{"help", CAT_SYS, "help [command|category]", "Show this help, or help for one command.", cmd_help},
	{"man", CAT_SYS, "man <command>", "Show the manual entry for a command.", cmd_man},
	{"clear", CAT_SYS, "clear", "Clear your screen and scrollback.", cmd_clear},
	{"history", CAT_SYS, "history", "Show the commands you have run this session.", cmd_history},
	{"uname", CAT_SYS, "uname", "Print system identification.", cmd_uname},
	{"uptime", CAT_SYS, "uptime", "How long the server has been running.", cmd_uptime},
	{"date", CAT_SYS, "date", "Show the current UTC date and time.", cmd_date},
	{"free", CAT_SYS, "free", "Show VFS storage and session usage.", cmd_free},
	{"ps", CAT_SYS, "ps", "List connected sessions as processes.", cmd_ps},
	{"motd", CAT_SYS, "motd", "Print the message of the day.", cmd_motd},
	{"env", CAT_SYS, "env", "List session variables.", cmd_env},
	{"export", CAT_SYS, "export NAME=value", "Set a session variable.", cmd_export},
	{"unset", CAT_SYS, "unset <name...>", "Remove a session variable.", cmd_unset},
	{"dmesg", CAT_SYS, "dmesg", "Show recent request rejections.", cmd_dmesg},
	{"alias", CAT_SYS, "alias name=command", "Give a command a shorter name.", cmd_alias},
	{"unalias", CAT_SYS, "unalias <name...>", "Remove an alias.", cmd_unalias},
	{"cal", CAT_SYS, "cal [month] [year]", "Print a calendar.", cmd_cal},
	{"version", CAT_SYS, "version", "Show version and build information.", cmd_version},
	{"neofetch", CAT_SYS, "neofetch", "Show system information with art.", cmd_neofetch},
	{"theme", CAT_SYS, "theme <name>", "Change your terminal's colour scheme.", cmd_theme},

	// --- Fun ----------------------------------------------------------------
	{"banner", CAT_FUN, "banner [text]", "Print text as large block letters. Reads a pipe too.", cmd_banner},
	{"cowsay", CAT_FUN, "cowsay [text]", "A cow says your text, or whatever you pipe in.", cmd_cowsay},
	{"fortune", CAT_FUN, "fortune", "Print a fortune.", cmd_fortune},
	{"calc", CAT_FUN, "calc <a> <op> <b>", "Evaluate simple arithmetic, e.g. calc 6 * 7.", cmd_calc},
	{"roll", CAT_FUN, "roll [sides]", "Roll a die (default d6).", cmd_roll},
	{"8ball", CAT_FUN, "8ball <question>", "Ask the magic 8-ball.", cmd_8ball},
	{"matrix", CAT_FUN, "matrix", "Digital rain, on everyone's screen.", cmd_matrix},
	{"clearall", CAT_FUN, "clearall", "Clear everyone's screen.", cmd_clearall},
}

@(rodata)
CATEGORY_ORDER := [?]string{CAT_FS, CAT_TEXT, CAT_USER, CAT_SOCIAL, CAT_SYS, CAT_FUN}

// ---------------------------------------------------------------------------
// help
// ---------------------------------------------------------------------------

cmd_help :: proc(ctx: ^Cmd_Ctx, args: []string) {
	// `help <something>` is either a command or a category.
	if len(args) > 0 {
		query := strings.to_lower(unquote(args[0]), context.temp_allocator)

		if cmd, found := find_command(query); found {
			print_command_help(ctx, cmd)
			return
		}
		for cat in CATEGORY_ORDER {
			if cat == query {
				print_category(ctx, cat, true)
				return
			}
		}

		errf(ctx, "help: no command or category named '%s'\n",
			sanitize_text(args[0], 32, context.temp_allocator))
		out(ctx, "Try \x1b[36mhelp\x1b[0m on its own for the full list.\n")
		return
	}

	outf(ctx, "\x1b[1mWebOS %s\x1b[0m — %d commands\n", SERVER_VERSION, len(COMMANDS))

	narrow := ctx_is_narrow(ctx)
	if narrow {
		out(ctx, "\x1b[90mhelp <command> for what each one does\x1b[0m\n")
	} else {
		out(ctx, "\x1b[90mhelp <command> for details, help <category> for one section\x1b[0m\n")
	}

	for cat in CATEGORY_ORDER {
		print_category(ctx, cat, false)
	}

	out(ctx, "\n\x1b[1mShell\x1b[0m\n")
	if narrow {
		out(ctx, "  \x1b[36ma | b\x1b[0m    feed a's output into b\n")
		out(ctx, "  \x1b[36ma && b\x1b[0m   run b only if a succeeded\n")
		out(ctx, "  \x1b[36ma || b\x1b[0m   run b only if a failed\n")
		out(ctx, "  \x1b[36m> \x1b[0mfile   write output to a file\n")
		out(ctx, "  \x1b[36m>>\x1b[0mfile   append to a file\n")
		out(ctx, "  \x1b[36m$VAR\x1b[0m     expand a variable\n")
		out(ctx, "  \x1b[36m$?\x1b[0m       status of the last command\n")
	} else {
		out(ctx, "  \x1b[36ma | b\x1b[0m    feed a's output into b        ")
		out(ctx, "\x1b[36m> \x1b[0mfile    write output to a file\n")
		out(ctx, "  \x1b[36ma && b\x1b[0m   run b only if a succeeded     ")
		out(ctx, "\x1b[36m>>\x1b[0mfile    append output to a file\n")
		out(ctx, "  \x1b[36ma || b\x1b[0m   run b only if a failed        ")
		out(ctx, "\x1b[36ma ; b\x1b[0m     run both regardless\n")
		out(ctx, "  \x1b[36m$VAR\x1b[0m     expand a variable             ")
		out(ctx, "\x1b[36m$?\x1b[0m        status of the last command\n")
		out(ctx, "  \x1b[36mN=value\x1b[0m  set a variable                ")
		out(ctx, "\x1b[36m'\x1b[0m \x1b[36m\"\x1b[0m       quote, to keep spaces\n")
	}

	out(ctx, "\n\x1b[1mKeys\x1b[0m\n")
	if narrow {
		// A touch device has the key bar for these, so name them plainly.
		out(ctx, "  \x1b[36mtab\x1b[0m complete   \x1b[36m↑\x1b[0m/\x1b[36m↓\x1b[0m history\n")
		out(ctx, "  \x1b[36mctrl\x1b[0m then a letter for ^C, ^L, ^U\n")
	} else {
		out(ctx, "  \x1b[36mTab\x1b[0m complete    \x1b[36m^A\x1b[0m/\x1b[36m^E\x1b[0m line start/end    ")
		out(ctx, "\x1b[36m^W\x1b[0m delete word\n")
		out(ctx, "  \x1b[36m^C\x1b[0m cancel      \x1b[36m^U\x1b[0m/\x1b[36m^K\x1b[0m kill to start/end  ")
		out(ctx, "\x1b[36m^L\x1b[0m clear\n")
		out(ctx, "  \x1b[36mUp\x1b[0m/\x1b[36mDown\x1b[0m history\n")
	}
}

@(private = "file")
print_category :: proc(ctx: ^Cmd_Ctx, category: string, verbose: bool) {
	outf(ctx, "\n\x1b[1;33m%s\x1b[0m\n", strings.to_upper(category, context.temp_allocator))

	// On a phone there is no room for a description beside the name: the
	// second column wraps under the first and the whole list becomes ribbon.
	narrow := ctx_is_narrow(ctx)

	if narrow && !verbose {
		print_names_in_columns(ctx, category)
		return
	}

	for cmd in COMMANDS {
		if cmd.category != category {
			continue
		}

		if narrow {
			// Stacked: the usage line, then its description indented beneath.
			outf(ctx, "  \x1b[36m%s\x1b[0m\n", cmd.usage)
			outf(ctx, "    \x1b[90m%s\x1b[0m\n", cmd.help)
			continue
		}

		if verbose {
			outf(ctx, "  \x1b[36m%-32s\x1b[0m %s\n", cmd.usage, cmd.help)
		} else {
			outf(ctx, "  \x1b[36m%-12s\x1b[0m %s\n", cmd.name, cmd.help)
		}
	}
}

// Lists just the command names, packed into as many columns as fit.
@(private = "file")
print_names_in_columns :: proc(ctx: ^Cmd_Ctx, category: string) {
	COLUMN :: 12

	width := ctx_width(ctx)
	per_row := max(1, (width - 2) / COLUMN)

	b := strings.builder_make(context.temp_allocator)
	count := 0

	for cmd in COMMANDS {
		if cmd.category != category {
			continue
		}
		if count % per_row == 0 {
			strings.write_string(&b, "  ")
		}
		fmt.sbprintf(&b, "\x1b[36m%-*s\x1b[0m", COLUMN - 1, cmd.name)
		count += 1
		if count % per_row == 0 {
			strings.write_string(&b, "\n")
		}
	}
	if count % per_row != 0 {
		strings.write_string(&b, "\n")
	}

	out(ctx, strings.to_string(b))
}

@(private = "file")
print_command_help :: proc(ctx: ^Cmd_Ctx, cmd: Command) {
	outf(ctx, "\x1b[1m%s\x1b[0m — %s\n\n", cmd.name, cmd.help)
	outf(ctx, "  \x1b[1mUsage:\x1b[0m    %s\n", cmd.usage)
	outf(ctx, "  \x1b[1mCategory:\x1b[0m %s\n", cmd.category)

	// Aliases are stored the other way round, so collect them by scanning.
	aliases := make([dynamic]string, context.temp_allocator)
	for a in ALIASES {
		if a.to == cmd.name {
			append(&aliases, a.from)
		}
	}
	if len(aliases) > 0 {
		slice.sort(aliases[:])
		outf(ctx, "  \x1b[1mAliases:\x1b[0m  %s\n", strings.join(aliases[:], ", ", context.temp_allocator))
	}
}

cmd_man :: proc(ctx: ^Cmd_Ctx, args: []string) {
	if len(args) == 0 {
		errf(ctx, "man: what manual page do you want?\n")
		out(ctx, "Try \x1b[36mman help\x1b[0m, or \x1b[36mhelp\x1b[0m for the command list.\n")
		return
	}

	name := strings.to_lower(unquote(args[0]), context.temp_allocator)
	cmd, found := find_command(name)
	if !found {
		errf(ctx, "man: no manual entry for '%s'\n",
			sanitize_text(args[0], 32, context.temp_allocator))

		// Offer the nearest names rather than a dead end.
		suggestions := suggest_commands(name, context.temp_allocator)
		if len(suggestions) > 0 {
			outf(ctx, "Did you mean: %s?\n", strings.join(suggestions, ", ", context.temp_allocator))
		}
		return
	}

	upper := strings.to_upper(cmd.name, context.temp_allocator)
	outf(ctx, "\x1b[1m%s(1)\x1b[0m%*sWebOS Manual%*s\x1b[1m%s(1)\x1b[0m\n",
		upper, 12, "", 12, "", upper)
	out(ctx, "\n\x1b[1mNAME\x1b[0m\n")
	outf(ctx, "     %s — %s\n", cmd.name, cmd.help)
	out(ctx, "\n\x1b[1mSYNOPSIS\x1b[0m\n")
	outf(ctx, "     %s\n", cmd.usage)
	out(ctx, "\n\x1b[1mDESCRIPTION\x1b[0m\n")
	outf(ctx, "     %s\n", cmd.help)
	outf(ctx, "\n     Part of the \x1b[36m%s\x1b[0m command group; see \x1b[36mhelp %s\x1b[0m.\n",
		cmd.category, cmd.category)
}

// Commands whose name is close to `name`, for "did you mean" hints.
suggest_commands :: proc(name: string, allocator := context.allocator) -> []string {
	out_names := make([dynamic]string, allocator)

	for cmd in COMMANDS {
		// Cheap and good enough: a shared prefix, or one edit apart.
		if strings.has_prefix(cmd.name, name) || strings.has_prefix(name, cmd.name) {
			append(&out_names, cmd.name)
			continue
		}
		if edit_distance_within(name, cmd.name, 1) {
			append(&out_names, cmd.name)
		}
	}

	if len(out_names) > 5 {
		return out_names[:5]
	}
	return out_names[:]
}

// True if `a` and `b` are at most `limit` single-character edits apart.
@(private = "file")
edit_distance_within :: proc(a: string, b: string, limit: int) -> bool {
	if abs(len(a) - len(b)) > limit {
		return false
	}

	// Walk both strings together, allowing `limit` divergences.
	i, j, edits := 0, 0, 0
	for i < len(a) && j < len(b) {
		if a[i] == b[j] {
			i += 1
			j += 1
			continue
		}

		edits += 1
		if edits > limit {
			return false
		}

		switch {
		case len(a) > len(b):
			i += 1 // deletion from a
		case len(a) < len(b):
			j += 1 // insertion into a
		case:
			i += 1 // substitution
			j += 1
		}
	}

	edits += (len(a) - i) + (len(b) - j)
	return edits <= limit
}

// Used by the "command not found" path to nudge toward the right name.
format_suggestions :: proc(name: string) -> string {
	suggestions := suggest_commands(name, context.temp_allocator)
	if len(suggestions) == 0 {
		return " (try \x1b[36mhelp\x1b[0m)"
	}
	return fmt.tprintf(
		" — did you mean \x1b[36m%s\x1b[0m?",
		strings.join(suggestions, "\x1b[0m or \x1b[36m", context.temp_allocator),
	)
}
