package main

import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

// Current time as whole unix seconds. Timestamps are stored this way so
// snapshots on disk stay stable and human-readable.
unix_now :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

// ---------------------------------------------------------------------------
// Untrusted text handling
//
// Anything a user types can end up rendered in *other* users' terminals via
// wall, the [System] notices, prompts and `ls` output. The original code piped
// that straight through, so a client could inject arbitrary ANSI escape
// sequences into every other session: move the cursor, rewrite the scrollback,
// set the window title via OSC, or forge convincing "[System]" lines.
//
// Everything below is the boundary where that stops.
// ---------------------------------------------------------------------------

// Strips control characters from untrusted text and caps its length.
//
// Removes all C0 controls (including ESC, CR, LF and BEL), DEL, and the C1
// range U+0080..U+009F which some terminals also treat as control codes.
// Invalid UTF-8 is dropped rather than passed through, since a lone
// continuation byte can desynchronise a terminal's decoder.
//
// The result is always a fresh allocation owned by the caller.
sanitize_text :: proc(s: string, max_len: int, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)

	count := 0
	for r in s {
		if count >= max_len {
			break
		}
		if !is_safe_rune(r) {
			continue
		}
		strings.write_rune(&b, r)
		count += 1
	}

	return strings.to_string(b)
}

is_safe_rune :: proc(r: rune) -> bool {
	switch {
	case r == utf8.RUNE_ERROR:
		return false // invalid UTF-8
	case r < 0x20:
		return false // C0 controls, including ESC / CR / LF / BEL / TAB
	case r == 0x7f:
		return false // DEL
	case r >= 0x80 && r <= 0x9f:
		return false // C1 controls
	case r == 0x2028 || r == 0x2029:
		return false // line/paragraph separators
	}
	return true
}

// True if the string contains only characters safe to render.
is_clean_text :: proc(s: string) -> bool {
	for r in s {
		if !is_safe_rune(r) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

// Usernames must be safe as both a display name and a path component, so the
// charset is deliberately narrow. Rejecting '/' and '.' here is what keeps a
// username from escaping its own home directory.
validate_username :: proc(name: string) -> (ok: bool, reason: string) {
	if len(name) < MIN_NAME_LEN {
		return false, "name too short (min 2 characters)"
	}
	if len(name) > MAX_NAME_LEN {
		return false, "name too long (max 20 characters)"
	}

	for i in 0 ..< len(name) {
		c := name[i]
		is_lower := c >= 'a' && c <= 'z'
		is_upper := c >= 'A' && c <= 'Z'
		is_digit := c >= '0' && c <= '9'
		is_sep := c == '_' || c == '-'
		if !(is_lower || is_upper || is_digit || is_sep) {
			return false, "name may only contain letters, digits, '_' and '-'"
		}
	}

	// Leading '-' would be parsed as a flag by anything that later takes
	// options; leading '_' is reserved for internal accounts.
	if name[0] == '-' || name[0] == '_' {
		return false, "name must start with a letter or digit"
	}

	if is_reserved_name(name) {
		return false, "that name is reserved"
	}

	return true, ""
}

// Names that would let a user impersonate the server itself in broadcasts, or
// collide with VFS structure.
is_reserved_name :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	reserved := []string {
		"system",
		"root",
		"admin",
		"administrator",
		"webos",
		"server",
		"kernel",
		"wall",
		"daemon",
		"operator",
		"security",
		"moderator",
		"mod",
		"staff",
		"support",
		"guest",
		"home",
		"etc",
		"tmp",
		"dev",
		"proc",
		"bin",
		"usr",
		"var",
	}
	for r in reserved {
		if lower == r {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// ANSI colours
// ---------------------------------------------------------------------------

// Colour is stored as a validated name and only ever rendered through this
// table. The original code assigned the raw user argument to client.color and
// interpolated it into an escape sequence, which meant the value was both an
// injection vector and a pointer into a buffer that kept changing.
Color_Entry :: struct {
	name: string,
	code: string,
}

@(rodata)
COLORS := [?]Color_Entry {
	{"red", "31"},
	{"green", "32"},
	{"yellow", "33"},
	{"blue", "34"},
	{"magenta", "35"},
	{"cyan", "36"},
	{"white", "37"},
	{"grey", "90"},
	{"gray", "90"},
	{"brightred", "91"},
	{"brightgreen", "92"},
	{"brightyellow", "93"},
	{"brightblue", "94"},
	{"brightmagenta", "95"},
	{"brightcyan", "96"},
}

// Maps a user-supplied colour name (or legacy numeric code) to an escape
// parameter. Returns "" if unknown — callers must treat that as invalid rather
// than passing the input through.
lookup_color :: proc(name: string) -> string {
	lower := strings.to_lower(name, context.temp_allocator)
	for c in COLORS {
		if c.name == lower {
			return c.code
		}
		// Accept the numeric codes the old `color` command used.
		if c.code == lower {
			return c.code
		}
	}
	return ""
}

color_names :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	first := true
	for c in COLORS {
		if c.name == "gray" {
			continue // alias of grey
		}
		if !first {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, c.name)
		first = false
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

// Splits a command line into at most MAX_ARGS fields on runs of whitespace.
// Unlike strings.split this collapses repeated spaces and never returns empty
// fields, so `ls   foo` parses the way a user expects.
split_args :: proc(line: string, allocator := context.allocator) -> [dynamic]string {
	args := make([dynamic]string, allocator)

	start := -1
	for i in 0 ..< len(line) {
		c := line[i]
		is_space := c == ' ' || c == '\t'
		if is_space {
			if start >= 0 {
				append(&args, line[start:i])
				start = -1
				if len(args) >= MAX_ARGS {
					return args
				}
			}
		} else if start < 0 {
			start = i
		}
	}
	if start >= 0 && len(args) < MAX_ARGS {
		append(&args, line[start:])
	}

	return args
}

// Removes one layer of matching single or double quotes.
unquote :: proc(s: string) -> string {
	if len(s) >= 2 {
		if (s[0] == '"' && s[len(s) - 1] == '"') || (s[0] == '\'' && s[len(s) - 1] == '\'') {
			return s[1:len(s) - 1]
		}
	}
	return s
}

// Joins a directory and a file name with a single separator.
concat_path :: proc(dir: string, name: string, allocator := context.allocator) -> string {
	if len(dir) == 0 {
		return strings.clone(name, allocator)
	}
	if strings.has_suffix(dir, "/") {
		return strings.concatenate({dir, name}, allocator)
	}
	return strings.concatenate({dir, "/", name}, allocator)
}

// Renders a byte count the way `ls -h` would.
human_size :: proc(n: int, allocator := context.allocator) -> string {
	units := [?]string{"B", "K", "M", "G"}
	size := f64(n)
	unit := 0
	for size >= 1024 && unit < len(units) - 1 {
		size /= 1024
		unit += 1
	}
	if unit == 0 {
		return fmt.aprintf("%dB", n, allocator = allocator)
	}
	return fmt.aprintf("%.1f%s", size, units[unit], allocator = allocator)
}
