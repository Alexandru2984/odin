package main

import path "core:path/slashpath"
import "core:strings"
import "core:sync"

// ---------------------------------------------------------------------------
// In-memory virtual file system
//
// This is a shared, writable, anonymously reachable data structure, so every
// dimension of it needs a ceiling. The original had none: entry count, file
// size, total memory, path length and nesting depth were all unbounded, which
// made `mkdir` in a loop a way to exhaust the host's RAM. It also leaked the
// key string on every delete_key and never freed file contents on overwrite.
// ---------------------------------------------------------------------------

VFS_Entry_Type :: enum {
	File,
	Directory,
}

// Simplified permission model. Rendered as rwx-ish strings by `ls -l`, but the
// semantics are deliberately simple enough to reason about.
VFS_Perm :: enum {
	Public,     // anyone may read and write
	Owner_Only, // owner may write, anyone may read
	Private,    // only the owner may read or write
}

VFS_Entry :: struct {
	type:     VFS_Entry_Type,
	content:  string, // owned; files only
	owner:    string, // owned; "" means system-owned
	perm:     VFS_Perm,
	created:  i64, // unix seconds
	modified: i64,
}

VFS :: struct {
	lock:        sync.Mutex,
	entries:     map[string]VFS_Entry, // keys are owned
	total_bytes: int,
	per_user:    map[string]int, // owned keys; entries attributed per owner
	dirty:       bool,           // set on mutation, cleared by the snapshotter
}

VFS_Error :: enum {
	None,
	Not_Found,
	Not_A_Directory,
	Is_A_Directory,
	Already_Exists,
	Not_Empty,
	Permission_Denied,
	Invalid_Path,
	Path_Too_Long,
	Too_Deep,
	Name_Too_Long,
	File_Too_Large,
	Quota_Entries,
	Quota_Bytes,
	Quota_User,
	Read_Only,
}

vfs_error_string :: proc(e: VFS_Error) -> string {
	switch e {
	case .None:
		return "success"
	case .Not_Found:
		return "no such file or directory"
	case .Not_A_Directory:
		return "not a directory"
	case .Is_A_Directory:
		return "is a directory"
	case .Already_Exists:
		return "file exists"
	case .Not_Empty:
		return "directory not empty"
	case .Permission_Denied:
		return "permission denied"
	case .Invalid_Path:
		return "invalid path"
	case .Path_Too_Long:
		return "path too long"
	case .Too_Deep:
		return "directory nesting too deep"
	case .Name_Too_Long:
		return "file name too long"
	case .File_Too_Large:
		return "file too large"
	case .Quota_Entries:
		return "filesystem full (entry limit reached)"
	case .Quota_Bytes:
		return "filesystem full (size limit reached)"
	case .Quota_User:
		return "quota exceeded for this user"
	case .Read_Only:
		return "read-only location"
	}
	return "unknown error"
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

vfs_init :: proc(vfs: ^VFS) {
	vfs.entries = make(map[string]VFS_Entry)
	vfs.per_user = make(map[string]int)
	vfs.total_bytes = 0

	now := unix_now()

	// The base layout is created system-owned. `/tmp` and `/pub` are the only
	// world-writable directories, so an anonymous guest has somewhere to play
	// without being able to clutter or damage the rest of the tree.
	vfs_seed_dir(vfs, "/", .Owner_Only, now)
	vfs_seed_dir(vfs, "/home", .Owner_Only, now)
	vfs_seed_dir(vfs, "/etc", .Owner_Only, now)
	vfs_seed_dir(vfs, "/tmp", .Public, now)
	vfs_seed_dir(vfs, "/pub", .Public, now)

	vfs_seed_file(
		vfs,
		"/etc/motd",
		"Welcome to WebOS.\nEverything here lives in RAM and is shared with everyone online.\nType `help` to get started.\n",
		.Owner_Only,
		now,
	)
	vfs_seed_file(
		vfs,
		"/etc/issue",
		"WebOS " + SERVER_VERSION + " (Odin kernel)\n",
		.Owner_Only,
		now,
	)
}

@(private = "file")
vfs_seed_dir :: proc(vfs: ^VFS, p: string, perm: VFS_Perm, now: i64) {
	vfs.entries[strings.clone(p)] = VFS_Entry {
		type     = .Directory,
		owner    = strings.clone(""),
		perm     = perm,
		created  = now,
		modified = now,
	}
}

@(private = "file")
vfs_seed_file :: proc(vfs: ^VFS, p: string, content: string, perm: VFS_Perm, now: i64) {
	vfs.entries[strings.clone(p)] = VFS_Entry {
		type     = .File,
		content  = strings.clone(content),
		owner    = strings.clone(""),
		perm     = perm,
		created  = now,
		modified = now,
	}
	vfs.total_bytes += len(content)
}

vfs_destroy :: proc(vfs: ^VFS) {
	for key, entry in vfs.entries {
		delete(key)
		delete(entry.content)
		delete(entry.owner)
	}
	delete(vfs.entries)

	for key in vfs.per_user {
		delete(key)
	}
	delete(vfs.per_user)
}

// ---------------------------------------------------------------------------
// Path handling
// ---------------------------------------------------------------------------

// Resolves `target` against `cwd` into a clean absolute path.
//
// path.clean collapses ".." segments, and "/.." resolves to "/", so a path can
// never escape the VFS root. The result is a fresh allocation.
vfs_resolve_path :: proc(cwd: string, target: string, allocator := context.allocator) -> string {
	if len(target) == 0 {
		return strings.clone(cwd, allocator)
	}

	if path.is_abs(target) {
		return path.clean(target, allocator)
	}

	joined := path.join({cwd, target}, context.temp_allocator)
	return path.clean(joined, allocator)
}

// Structural validation, independent of what is actually in the VFS.
vfs_validate_path :: proc(p: string) -> VFS_Error {
	if len(p) == 0 || p[0] != '/' {
		return .Invalid_Path
	}
	if len(p) > VFS_MAX_PATH_LEN {
		return .Path_Too_Long
	}

	// Control characters in a path would be re-emitted by `ls` into every
	// other user's terminal.
	if !is_clean_text(p) {
		return .Invalid_Path
	}

	depth := 0
	seg_start := 1
	for i := 1; i <= len(p); i += 1 {
		if i == len(p) || p[i] == '/' {
			seg_len := i - seg_start
			if seg_len > VFS_MAX_NAME_LEN {
				return .Name_Too_Long
			}
			if seg_len > 0 {
				depth += 1
			}
			seg_start = i + 1
		}
	}
	if depth > VFS_MAX_DEPTH {
		return .Too_Deep
	}

	return .None
}

// ---------------------------------------------------------------------------
// Permissions
// ---------------------------------------------------------------------------

@(private = "file")
can_read_entry :: proc(e: VFS_Entry, user: string) -> bool {
	if e.perm != .Private {
		return true
	}
	return len(user) > 0 && e.owner == user
}

@(private = "file")
can_write_entry :: proc(e: VFS_Entry, user: string) -> bool {
	switch e.perm {
	case .Public:
		return true
	case .Owner_Only, .Private:
		// System-owned entries (owner "") are never writable by a user.
		return len(e.owner) > 0 && e.owner == user
	}
	return false
}

// Whether `user` may create or remove entries inside directory `dir_path`.
@(private = "file")
can_write_dir_locked :: proc(vfs: ^VFS, dir_path: string, user: string) -> bool {
	entry, ok := vfs.entries[dir_path]
	if !ok || entry.type != .Directory {
		return false
	}
	return can_write_entry(entry, user)
}

// ---------------------------------------------------------------------------
// Quota accounting
// ---------------------------------------------------------------------------

@(private = "file")
user_count_add :: proc(vfs: ^VFS, user: string, delta: int) {
	if len(user) == 0 {
		return
	}
	n, ok := vfs.per_user[user]
	if !ok {
		if delta <= 0 {
			return
		}
		vfs.per_user[strings.clone(user)] = delta
		return
	}
	n += delta
	if n <= 0 {
		key, _ := delete_key(&vfs.per_user, user)
		delete(key)
	} else {
		vfs.per_user[user] = n
	}
}

@(private = "file")
check_new_entry_locked :: proc(vfs: ^VFS, user: string) -> VFS_Error {
	if len(vfs.entries) >= VFS_MAX_ENTRIES {
		return .Quota_Entries
	}
	if len(user) > 0 && vfs.per_user[user] >= VFS_MAX_PER_USER_ENTRIES {
		return .Quota_User
	}
	return .None
}

// Removes an entry and releases every allocation it owned, including the map
// key. The old delete_key call leaked both the key and the file contents.
@(private = "file")
remove_entry_locked :: proc(vfs: ^VFS, p: string) {
	entry, ok := vfs.entries[p]
	if !ok {
		return
	}

	if entry.type == .File {
		vfs.total_bytes -= len(entry.content)
	}
	user_count_add(vfs, entry.owner, -1)

	key, val := delete_key(&vfs.entries, p)
	delete(key)
	delete(val.content)
	delete(val.owner)

	vfs.dirty = true
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

vfs_mkdir :: proc(vfs: ^VFS, p: string, user: string) -> VFS_Error {
	if err := vfs_validate_path(p); err != .None {
		return err
	}
	if p == "/" {
		return .Already_Exists
	}

	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if p in vfs.entries {
		return .Already_Exists
	}

	parent := path.dir(p, context.temp_allocator)
	parent_entry, ok := vfs.entries[parent]
	if !ok {
		return .Not_Found
	}
	if parent_entry.type != .Directory {
		return .Not_A_Directory
	}
	if !can_write_entry(parent_entry, user) {
		return .Permission_Denied
	}
	if err := check_new_entry_locked(vfs, user); err != .None {
		return err
	}

	now := unix_now()
	// A directory created inside a public area stays public, so shared spaces
	// keep working; elsewhere it belongs to its creator.
	perm := parent_entry.perm == .Public ? VFS_Perm.Public : VFS_Perm.Owner_Only

	vfs.entries[strings.clone(p)] = VFS_Entry {
		type     = .Directory,
		owner    = strings.clone(user),
		perm     = perm,
		created  = now,
		modified = now,
	}
	user_count_add(vfs, user, 1)
	vfs.dirty = true

	return .None
}

// Creates a directory owned by `user`, bypassing the parent's write check.
//
// Home directories live under /home, which is system-owned and therefore not
// writable by anyone. Account creation still has to be able to place a home
// there, so this is the one privileged path — it is called only by the auth
// commands, never with a user-supplied path.
vfs_mkdir_direct :: proc(p: string, user: string) -> VFS_Error {
	vfs := &g_vfs

	if err := vfs_validate_path(p); err != .None {
		return err
	}

	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if existing, ok := vfs.entries[p]; ok {
		// Already there. Reclaim it if a previous run left it system-owned so
		// the account actually controls its own home.
		if existing.type == .Directory && len(existing.owner) == 0 && len(user) > 0 {
			updated := existing
			delete(updated.owner)
			updated.owner = strings.clone(user)
			vfs.entries[p] = updated
			user_count_add(vfs, user, 1)
			vfs.dirty = true
		}
		return .Already_Exists
	}

	parent := path.dir(p, context.temp_allocator)
	parent_entry, parent_ok := vfs.entries[parent]
	if !parent_ok || parent_entry.type != .Directory {
		return .Not_Found
	}
	if err := check_new_entry_locked(vfs, user); err != .None {
		return err
	}

	now := unix_now()
	vfs.entries[strings.clone(p)] = VFS_Entry {
		type     = .Directory,
		owner    = strings.clone(user),
		perm     = .Owner_Only,
		created  = now,
		modified = now,
	}
	user_count_add(vfs, user, 1)
	vfs.dirty = true

	return .None
}

// Creates a directory and any missing parents, like `mkdir -p`.
vfs_mkdir_all :: proc(vfs: ^VFS, p: string, user: string) -> VFS_Error {
	if err := vfs_validate_path(p); err != .None {
		return err
	}

	// Build each prefix in turn and create the ones that are missing.
	for i := 1; i <= len(p); i += 1 {
		if i == len(p) || p[i] == '/' {
			prefix := p[:i]
			if prefix == "" {
				continue
			}
			err := vfs_mkdir(vfs, prefix, user)
			if err != .None && err != .Already_Exists {
				return err
			}
		}
	}
	return .None
}

vfs_rmdir :: proc(vfs: ^VFS, p: string, user: string) -> VFS_Error {
	if p == "/" {
		return .Permission_Denied
	}

	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	entry, ok := vfs.entries[p]
	if !ok {
		return .Not_Found
	}
	if entry.type != .Directory {
		return .Not_A_Directory
	}
	if !can_write_entry(entry, user) {
		return .Permission_Denied
	}

	parent := path.dir(p, context.temp_allocator)
	if !can_write_dir_locked(vfs, parent, user) {
		return .Permission_Denied
	}

	prefix := strings.concatenate({p, "/"}, context.temp_allocator)
	for key in vfs.entries {
		if strings.has_prefix(key, prefix) {
			return .Not_Empty
		}
	}

	remove_entry_locked(vfs, p)
	return .None
}

// Recursive removal, like `rm -r`. All-or-nothing on permissions: the whole
// subtree is checked before anything is deleted.
vfs_rm_recursive :: proc(vfs: ^VFS, p: string, user: string) -> (removed: int, err: VFS_Error) {
	if p == "/" {
		return 0, .Permission_Denied
	}

	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	entry, ok := vfs.entries[p]
	if !ok {
		return 0, .Not_Found
	}

	parent := path.dir(p, context.temp_allocator)
	if !can_write_dir_locked(vfs, parent, user) {
		return 0, .Permission_Denied
	}
	if !can_write_entry(entry, user) {
		return 0, .Permission_Denied
	}

	prefix := strings.concatenate({p, "/"}, context.temp_allocator)

	victims := make([dynamic]string, context.temp_allocator)
	append(&victims, p)
	for key, e in vfs.entries {
		if strings.has_prefix(key, prefix) {
			if !can_write_entry(e, user) {
				return 0, .Permission_Denied
			}
			append(&victims, key)
		}
	}

	for v in victims {
		remove_entry_locked(vfs, v)
	}
	return len(victims), .None
}

vfs_write :: proc(vfs: ^VFS, p: string, content: string, user: string) -> VFS_Error {
	if err := vfs_validate_path(p); err != .None {
		return err
	}
	if len(content) > VFS_MAX_FILE_SIZE {
		return .File_Too_Large
	}

	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	parent := path.dir(p, context.temp_allocator)
	parent_entry, parent_ok := vfs.entries[parent]
	if !parent_ok {
		return .Not_Found
	}
	if parent_entry.type != .Directory {
		return .Not_A_Directory
	}

	now := unix_now()

	if existing, ok := vfs.entries[p]; ok {
		if existing.type == .Directory {
			return .Is_A_Directory
		}
		if !can_write_entry(existing, user) {
			return .Permission_Denied
		}

		delta := len(content) - len(existing.content)
		if vfs.total_bytes + delta > VFS_MAX_TOTAL_BYTES {
			return .Quota_Bytes
		}

		// Overwrite in place, keeping owner and permissions, and freeing the
		// previous contents.
		updated := existing
		delete(updated.content)
		updated.content = strings.clone(content)
		updated.modified = now

		vfs.entries[p] = updated
		vfs.total_bytes += delta
		vfs.dirty = true
		return .None
	}

	// New file.
	if !can_write_entry(parent_entry, user) {
		return .Permission_Denied
	}
	if err := check_new_entry_locked(vfs, user); err != .None {
		return err
	}
	if vfs.total_bytes + len(content) > VFS_MAX_TOTAL_BYTES {
		return .Quota_Bytes
	}

	perm := parent_entry.perm == .Public ? VFS_Perm.Public : VFS_Perm.Owner_Only
	vfs.entries[strings.clone(p)] = VFS_Entry {
		type     = .File,
		content  = strings.clone(content),
		owner    = strings.clone(user),
		perm     = perm,
		created  = now,
		modified = now,
	}
	vfs.total_bytes += len(content)
	user_count_add(vfs, user, 1)
	vfs.dirty = true

	return .None
}

// Appends to a file, creating it if absent.
vfs_append :: proc(vfs: ^VFS, p: string, extra: string, user: string) -> VFS_Error {
	existing, ok := vfs_read(vfs, p, user)
	defer if ok {delete(existing)}

	combined: string
	if ok {
		combined = strings.concatenate({existing, extra}, context.temp_allocator)
	} else {
		combined = extra
	}
	return vfs_write(vfs, p, combined, user)
}

// Returns a copy of the file contents. The caller owns the result.
vfs_read :: proc(
	vfs: ^VFS,
	p: string,
	user: string,
	allocator := context.allocator,
) -> (content: string, ok: bool) {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	entry, found := vfs.entries[p]
	if !found || entry.type != .File {
		return "", false
	}
	if !can_read_entry(entry, user) {
		return "", false
	}
	return strings.clone(entry.content, allocator), true
}

vfs_rm :: proc(vfs: ^VFS, p: string, user: string) -> VFS_Error {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	entry, ok := vfs.entries[p]
	if !ok {
		return .Not_Found
	}
	if entry.type == .Directory {
		return .Is_A_Directory
	}
	if !can_write_entry(entry, user) {
		return .Permission_Denied
	}

	parent := path.dir(p, context.temp_allocator)
	if !can_write_dir_locked(vfs, parent, user) {
		return .Permission_Denied
	}

	remove_entry_locked(vfs, p)
	return .None
}

vfs_exists :: proc(vfs: ^VFS, p: string) -> bool {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)
	return p in vfs.entries
}

vfs_is_dir :: proc(vfs: ^VFS, p: string) -> bool {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)
	entry, ok := vfs.entries[p]
	return ok && entry.type == .Directory
}

// Metadata snapshot. Strings in the result are freshly allocated.
VFS_Stat :: struct {
	name:     string, // owned
	type:     VFS_Entry_Type,
	size:     int,
	owner:    string, // owned
	perm:     VFS_Perm,
	created:  i64,
	modified: i64,
}

vfs_stat_destroy :: proc(s: VFS_Stat) {
	delete(s.name)
	delete(s.owner)
}

vfs_stat :: proc(
	vfs: ^VFS,
	p: string,
	user: string,
	allocator := context.allocator,
) -> (stat: VFS_Stat, ok: bool) {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	entry, found := vfs.entries[p]
	if !found {
		return {}, false
	}
	if !can_read_entry(entry, user) {
		return {}, false
	}

	return VFS_Stat {
			name = strings.clone(path.base(p), allocator),
			type = entry.type,
			size = len(entry.content),
			owner = strings.clone(entry.owner, allocator),
			perm = entry.perm,
			created = entry.created,
			modified = entry.modified,
		},
		true
}

// Lists the immediate children of a directory. The caller owns every returned
// VFS_Stat and must free them with vfs_stat_destroy.
vfs_list :: proc(
	vfs: ^VFS,
	dir_path: string,
	user: string,
	allocator := context.allocator,
) -> (entries: []VFS_Stat, err: VFS_Error) {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	dir_entry, ok := vfs.entries[dir_path]
	if !ok {
		return nil, .Not_Found
	}
	if dir_entry.type != .Directory {
		return nil, .Not_A_Directory
	}
	if !can_read_entry(dir_entry, user) {
		return nil, .Permission_Denied
	}

	prefix := dir_path
	if dir_path != "/" {
		prefix = strings.concatenate({dir_path, "/"}, context.temp_allocator)
	}

	result := make([dynamic]VFS_Stat, allocator)
	for key, entry in vfs.entries {
		if key == dir_path {
			continue
		}
		if !strings.has_prefix(key, prefix) {
			continue
		}
		rest := key[len(prefix):]
		if len(rest) == 0 || strings.index(rest, "/") >= 0 {
			continue // not an immediate child
		}
		// A private entry is not listed to anyone but its owner.
		if !can_read_entry(entry, user) {
			continue
		}

		append(
			&result,
			VFS_Stat {
				name = strings.clone(rest, allocator),
				type = entry.type,
				size = len(entry.content),
				owner = strings.clone(entry.owner, allocator),
				perm = entry.perm,
				created = entry.created,
				modified = entry.modified,
			},
		)
	}

	return result[:], .None
}

// Every path in the tree under `root` that the user may see, for `tree` and
// `find`. Caller owns the strings.
vfs_walk :: proc(
	vfs: ^VFS,
	root: string,
	user: string,
	allocator := context.allocator,
) -> []string {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	prefix := root
	if root != "/" {
		prefix = strings.concatenate({root, "/"}, context.temp_allocator)
	}

	result := make([dynamic]string, allocator)
	for key, entry in vfs.entries {
		if key == root || !strings.has_prefix(key, prefix) {
			continue
		}
		if !can_read_entry(entry, user) {
			continue
		}
		append(&result, strings.clone(key, allocator))
	}
	return result[:]
}

vfs_chmod :: proc(vfs: ^VFS, p: string, perm: VFS_Perm, user: string) -> VFS_Error {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	entry, ok := vfs.entries[p]
	if !ok {
		return .Not_Found
	}
	// Only a real owner may change permissions; system entries are fixed.
	if len(entry.owner) == 0 || entry.owner != user {
		return .Permission_Denied
	}

	updated := entry
	updated.perm = perm
	updated.modified = unix_now()
	vfs.entries[p] = updated
	vfs.dirty = true

	return .None
}

VFS_Usage :: struct {
	entries:     int,
	total_bytes: int,
	max_entries: int,
	max_bytes:   int,
}

vfs_usage :: proc(vfs: ^VFS) -> VFS_Usage {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)
	return VFS_Usage {
		entries = len(vfs.entries),
		total_bytes = vfs.total_bytes,
		max_entries = VFS_MAX_ENTRIES,
		max_bytes = VFS_MAX_TOTAL_BYTES,
	}
}
