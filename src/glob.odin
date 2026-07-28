package main

import "core:slice"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// Filename globbing
//
// `rm *.txt` did nothing useful before this: the word reached the command
// verbatim, `rm` looked for a file literally named "*.txt", and reported that
// it did not exist. Every shell users have ever touched expands that word
// before the command sees it, so its absence was the loudest missing thing in
// the whole shell.
//
// Two halves live here: a pure matcher, which is where the fiddly logic is and
// therefore where the tests are, and the VFS walk that applies it.
// ---------------------------------------------------------------------------

// A single glob may not expand to more than this many words. The result is
// built in memory and then handed to a command as its argument list, so
// without a ceiling `ls /*` in a full filesystem is an allocation primitive.
MAX_GLOB_RESULTS :: 512

// True when the word contains a character that makes it a pattern rather than
// a plain name. A word without one is never expanded, which is what keeps
// ordinary filenames — and every command name — on the fast path.
has_glob_magic :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		switch s[i] {
		case '*', '?', '[':
			return true
		}
	}
	return false
}

// Matches one path segment against one pattern segment.
//
// Supports `*` (any run, including empty), `?` (exactly one byte) and
// `[abc]` / `[a-z]` / `[!abc]` classes. Neither `*` nor `?` matches a `/`,
// because segments are matched one at a time and no segment contains one.
//
// Iterative with a single backtrack point rather than recursive: the pattern
// arrives from the network, and the obvious recursive formulation gives
// something like `a*a*a*a*a*b` against a long name exponential behaviour. This
// shape is linear in the common case and never recurses at all.
glob_match_segment :: proc(pattern: string, name: string) -> bool {
	// A leading dot has to be asked for by name. Without this rule `rm *` in a
	// home directory quietly takes the dotfiles with it, which is exactly the
	// accident every shell has this rule to prevent.
	if len(name) > 0 && name[0] == '.' && !(len(pattern) > 0 && pattern[0] == '.') {
		return false
	}

	p, n := 0, 0
	star := -1 // index in pattern of the last '*' seen
	resume := 0 // index in name to retry from when we backtrack

	for n < len(name) {
		if p < len(pattern) {
			switch pattern[p] {
			case '*':
				star = p
				resume = n
				p += 1
				continue

			case '?':
				p += 1
				n += 1
				continue

			case '[':
				if matched, width := match_class(pattern[p:], name[n]); width > 0 {
					if matched {
						p += width
						n += 1
						continue
					}
					// An unmatched class is still a consumed class: fall through
					// to backtracking rather than treating '[' as a literal.
				} else {
					// Unterminated '[' is a literal '[', the way a shell treats it.
					if pattern[p] == name[n] {
						p += 1
						n += 1
						continue
					}
				}

			case:
				if pattern[p] == name[n] {
					p += 1
					n += 1
					continue
				}
			}
		}

		// No match at this position. If a '*' came earlier, let it swallow one
		// more byte and try again from there.
		if star >= 0 {
			p = star + 1
			resume += 1
			n = resume
			continue
		}
		return false
	}

	// Name exhausted: any pattern tail must be stars.
	for p < len(pattern) && pattern[p] == '*' {
		p += 1
	}
	return p == len(pattern)
}

// Matches a `[...]` class against one byte.
//
// Returns whether it matched and how many bytes of pattern the class occupied;
// a width of 0 means the class was never closed and is not a class at all.
@(private = "file")
match_class :: proc(pattern: string, ch: byte) -> (matched: bool, width: int) {
	if len(pattern) < 2 || pattern[0] != '[' {
		return false, 0
	}

	i := 1
	negate := false
	if i < len(pattern) && (pattern[i] == '!' || pattern[i] == '^') {
		negate = true
		i += 1
	}

	// A ']' immediately after the opening bracket is a literal ']', not the
	// close. Same rule as every other shell.
	found := false
	first := true

	for i < len(pattern) {
		if pattern[i] == ']' && !first {
			if negate {
				return !found, i + 1
			}
			return found, i + 1
		}
		first = false

		// A range, but only when the '-' is between two characters.
		if i + 2 < len(pattern) && pattern[i + 1] == '-' && pattern[i + 2] != ']' {
			lo, hi := pattern[i], pattern[i + 2]
			if lo <= ch && ch <= hi {
				found = true
			}
			i += 3
			continue
		}

		if pattern[i] == ch {
			found = true
		}
		i += 1
	}

	return false, 0 // never closed
}

// Matches a whole absolute path against a whole absolute pattern, segment by
// segment. `/home/*/mail` matches `/home/alice/mail` but not
// `/home/alice/mail/1`, because the segment counts must agree.
glob_match_path :: proc(pattern: string, path: string) -> bool {
	pseg := strings.split(pattern, "/", context.temp_allocator)
	nseg := strings.split(path, "/", context.temp_allocator)

	if len(pseg) != len(nseg) {
		return false
	}
	for seg, i in pseg {
		if !glob_match_segment(seg, nseg[i]) {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// Applying a pattern to the filesystem
// ---------------------------------------------------------------------------

// Every visible path matching an absolute pattern, sorted.
//
// The VFS is a flat map keyed by absolute path, so this is a scan rather than
// a directory descent — which is also why `/home/*/mail` works without any
// extra machinery. Visibility is decided by exactly the rule `ls` uses, so a
// pattern can never be used to discover the name of a private file.
vfs_glob :: proc(
	vfs: ^VFS,
	pattern: string,
	user: string,
	allocator := context.temp_allocator,
) -> []string {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	result := make([dynamic]string, allocator)

	for key, entry in vfs.entries {
		if key == "/" {
			continue
		}
		if !glob_match_path(pattern, key) {
			continue
		}
		if !vfs_entry_visible(entry, user) {
			continue
		}
		// A match whose parent the user may not enter must not be reported
		// either: the scan sees the whole map, so the walk down is not implied
		// the way it would be with a real directory descent.
		if !glob_parent_visible(vfs, key, user) {
			continue
		}

		append(&result, strings.clone(key, allocator))
		if len(result) >= MAX_GLOB_RESULTS {
			break
		}
	}

	slice.sort(result[:])
	return result[:]
}

// Whether every directory above `path` is readable by `user`.
@(private = "file")
glob_parent_visible :: proc(vfs: ^VFS, path: string, user: string) -> bool {
	// Walk down from the root, checking each ancestor in turn. The caller holds
	// the lock, so this reads the map directly.
	for i in 1 ..< len(path) {
		if path[i] != '/' {
			continue
		}
		if parent, ok := vfs.entries[path[:i]]; ok {
			if !vfs_entry_visible(parent, user) {
				return false
			}
		}
	}
	return true
}
