package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

// ---------------------------------------------------------------------------
// Persistence
//
// The VFS and the user database lived only in RAM, so every deploy or crash
// silently destroyed everything anyone had made. Both are now snapshotted to
// disk and restored at boot.
//
// The on-disk format is length-prefixed rather than delimited: file contents
// are arbitrary user bytes, and any delimiter-based format would either need
// escaping or be corruptible by a user writing the delimiter into a file.
// ---------------------------------------------------------------------------

VFS_MAGIC  :: "WEBOSVFS1"
USER_MAGIC :: "WEBOSUSR1"

// ---------------------------------------------------------------------------
// Atomic write
// ---------------------------------------------------------------------------

// Writes via a temporary file and renames into place, so a crash mid-write
// leaves the previous good snapshot intact rather than a truncated one.
//
// The permissions are applied when the temporary file is *created*, not with a
// chmod afterwards. Creating a world-readable file containing password hashes
// and narrowing it a moment later leaves a window in which any local user can
// read it.
@(private = "file")
write_atomic :: proc(file_path: string, data: []byte, perm: os.Permissions) -> bool {
	tmp := strings.concatenate({file_path, ".tmp"}, context.temp_allocator)

	if err := os.write_entire_file(tmp, data, perm); err != nil {
		return false
	}
	if err := os.rename(tmp, file_path); err != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// The VFS snapshot is ordinary data: readable by the owner, nobody else needs
// it either.
SNAPSHOT_PERM :: os.Permissions{.Read_User, .Write_User}

@(private = "file")
ensure_data_dir :: proc() {
	if !os.exists(g_data_dir) {
		os.make_directory(g_data_dir)
	}
}

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

@(private = "file")
write_bytes_field :: proc(b: ^strings.Builder, data: []byte) {
	fmt.sbprintf(b, "%d\n", len(data))
	strings.write_bytes(b, data)
	strings.write_byte(b, '\n')
}

// Cursor over a snapshot buffer.
Reader :: struct {
	data: []byte,
	pos:  int,
}

@(private = "file")
read_line :: proc(r: ^Reader) -> (line: string, ok: bool) {
	if r.pos >= len(r.data) {
		return "", false
	}
	start := r.pos
	for r.pos < len(r.data) && r.data[r.pos] != '\n' {
		r.pos += 1
	}
	line = string(r.data[start:r.pos])
	r.pos += 1 // consume the newline
	return line, true
}

@(private = "file")
read_int :: proc(r: ^Reader) -> (val: int, ok: bool) {
	line := read_line(r) or_return
	return strconv.parse_int(line)
}

// Reads a length-prefixed byte field. The returned slice borrows the snapshot
// buffer.
@(private = "file")
read_bytes_field :: proc(r: ^Reader) -> (data: []byte, ok: bool) {
	n := read_int(r) or_return
	// A corrupt or hostile length must not index out of bounds.
	if n < 0 || r.pos + n > len(r.data) {
		return nil, false
	}
	data = r.data[r.pos:r.pos + n]
	r.pos += n
	if r.pos < len(r.data) && r.data[r.pos] == '\n' {
		r.pos += 1
	}
	return data, true
}

// ---------------------------------------------------------------------------
// VFS snapshot
// ---------------------------------------------------------------------------

persist_save_vfs :: proc() -> bool {
	b := strings.builder_make(context.temp_allocator)

	sync.mutex_lock(&g_vfs.lock)
	fmt.sbprintf(&b, "%s\n%d\n", VFS_MAGIC, len(g_vfs.entries))
	for path_key, entry in g_vfs.entries {
		fmt.sbprintf(
			&b,
			"%d %d %d %d\n",
			int(entry.type),
			int(entry.perm),
			entry.created,
			entry.modified,
		)
		write_bytes_field(&b, transmute([]byte)path_key)
		write_bytes_field(&b, transmute([]byte)entry.owner)
		write_bytes_field(&b, transmute([]byte)entry.content)
	}
	g_vfs.dirty = false
	sync.mutex_unlock(&g_vfs.lock)

	ensure_data_dir()
	return write_atomic(vfs_snapshot_path(), transmute([]byte)strings.to_string(b), SNAPSHOT_PERM)
}

persist_load_vfs :: proc() -> bool {
	data, read_err := os.read_entire_file(vfs_snapshot_path(), context.temp_allocator)
	if read_err != nil {
		return false
	}

	r := Reader {
		data = data,
	}

	magic, magic_ok := read_line(&r)
	if !magic_ok || magic != VFS_MAGIC {
		return false
	}

	count, count_ok := read_int(&r)
	if !count_ok || count < 0 || count > VFS_MAX_ENTRIES {
		return false
	}

	// Build into a fresh map and swap, so a truncated or corrupt snapshot
	// leaves the freshly seeded VFS untouched instead of half-overwritten.
	loaded := make(map[string]VFS_Entry)
	per_user := make(map[string]int)
	total := 0

	ok := true
	for _ in 0 ..< count {
		header, header_ok := read_line(&r)
		if !header_ok {
			ok = false
			break
		}

		fields := strings.fields(header, context.temp_allocator)
		if len(fields) != 4 {
			ok = false
			break
		}

		type_i, _ := strconv.parse_int(fields[0])
		perm_i, _ := strconv.parse_int(fields[1])
		created, _ := strconv.parse_i64(fields[2])
		modified, _ := strconv.parse_i64(fields[3])

		if type_i < 0 || type_i > int(max(VFS_Entry_Type)) {
			ok = false
			break
		}
		if perm_i < 0 || perm_i > int(max(VFS_Perm)) {
			ok = false
			break
		}

		path_bytes, p_ok := read_bytes_field(&r)
		owner_bytes, o_ok := read_bytes_field(&r)
		content_bytes, c_ok := read_bytes_field(&r)
		if !p_ok || !o_ok || !c_ok {
			ok = false
			break
		}

		key := string(path_bytes)
		// Re-validate on the way in. A snapshot is a file on disk; treating it
		// as trusted input would turn any write access to data/ into a way to
		// inject paths that the live quotas would never have allowed.
		if vfs_validate_path(key) != .None {
			continue
		}
		if len(content_bytes) > VFS_MAX_FILE_SIZE {
			continue
		}
		if key in loaded {
			continue
		}

		owner := string(owner_bytes)
		entry := VFS_Entry {
			type     = VFS_Entry_Type(type_i),
			perm     = VFS_Perm(perm_i),
			created  = created,
			modified = modified,
			owner    = strings.clone(owner),
			content  = strings.clone(string(content_bytes)),
		}

		loaded[strings.clone(key)] = entry
		total += len(entry.content)

		if len(owner) > 0 {
			if n, exists := per_user[owner]; exists {
				per_user[owner] = n + 1
			} else {
				per_user[strings.clone(owner)] = 1
			}
		}
	}

	if !ok || len(loaded) == 0 {
		for key, entry in loaded {
			delete(key)
			delete(entry.owner)
			delete(entry.content)
		}
		delete(loaded)
		for key in per_user {
			delete(key)
		}
		delete(per_user)
		return false
	}

	// A snapshot without a root would leave every path unreachable.
	if "/" not_in loaded {
		loaded[strings.clone("/")] = VFS_Entry {
			type     = .Directory,
			owner    = strings.clone(""),
			perm     = .Owner_Only,
			created  = unix_now(),
			modified = unix_now(),
		}
	}

	sync.mutex_lock(&g_vfs.lock)
	old_entries := g_vfs.entries
	old_per_user := g_vfs.per_user
	g_vfs.entries = loaded
	g_vfs.per_user = per_user
	g_vfs.total_bytes = total
	g_vfs.dirty = false
	sync.mutex_unlock(&g_vfs.lock)

	for key, entry in old_entries {
		delete(key)
		delete(entry.owner)
		delete(entry.content)
	}
	delete(old_entries)
	for key in old_per_user {
		delete(key)
	}
	delete(old_per_user)

	return true
}

// ---------------------------------------------------------------------------
// User database snapshot
// ---------------------------------------------------------------------------

persist_save_users :: proc() -> bool {
	b := strings.builder_make(context.temp_allocator)

	sync.mutex_lock(&g_users.lock)
	fmt.sbprintf(&b, "%s\n%d\n", USER_MAGIC, len(g_users.users))
	for _, user in g_users.users {
		fmt.sbprintf(&b, "%d %d %d\n", user.created, user.last_login, user.login_count)
		write_bytes_field(&b, transmute([]byte)user.name)
		write_bytes_field(&b, transmute([]byte)user.display)
		write_bytes_field(&b, user.salt)
		write_bytes_field(&b, user.hash)
	}
	g_users.dirty = false
	sync.mutex_unlock(&g_users.lock)

	ensure_data_dir()

	// Password hashes: readable only by the service user, from the moment the
	// file first exists.
	return write_atomic(user_db_path(), transmute([]byte)strings.to_string(b), SNAPSHOT_PERM)
}

persist_load_users :: proc() -> bool {
	data, read_err := os.read_entire_file(user_db_path(), context.temp_allocator)
	if read_err != nil {
		return false
	}

	r := Reader {
		data = data,
	}

	magic, magic_ok := read_line(&r)
	if !magic_ok || magic != USER_MAGIC {
		return false
	}

	count, count_ok := read_int(&r)
	if !count_ok || count < 0 || count > MAX_USERS {
		return false
	}

	sync.mutex_lock(&g_users.lock)
	defer sync.mutex_unlock(&g_users.lock)

	for _ in 0 ..< count {
		header, header_ok := read_line(&r)
		if !header_ok {
			break
		}
		fields := strings.fields(header, context.temp_allocator)
		if len(fields) != 3 {
			break
		}

		created, _ := strconv.parse_i64(fields[0])
		last_login, _ := strconv.parse_i64(fields[1])
		login_count, _ := strconv.parse_int(fields[2])

		name_b, n_ok := read_bytes_field(&r)
		display_b, d_ok := read_bytes_field(&r)
		salt_b, s_ok := read_bytes_field(&r)
		hash_b, h_ok := read_bytes_field(&r)
		if !n_ok || !d_ok || !s_ok || !h_ok {
			break
		}

		name := string(name_b)
		if ok, _ := validate_username(name); !ok {
			continue
		}
		if len(salt_b) != ARGON2_SALT_BYTES || len(hash_b) != ARGON2_TAG_BYTES {
			continue
		}
		if name in g_users.users {
			continue
		}

		salt := make([]byte, len(salt_b))
		copy(salt, salt_b)
		hash := make([]byte, len(hash_b))
		copy(hash, hash_b)

		g_users.users[strings.clone(name)] = User {
			name        = strings.clone(name),
			display     = strings.clone(string(display_b)),
			salt        = salt,
			hash        = hash,
			created     = created,
			last_login  = last_login,
			login_count = login_count,
		}
	}

	g_users.dirty = false
	return true
}

// ---------------------------------------------------------------------------
// Orchestration
// ---------------------------------------------------------------------------

persist_load :: proc() {
	if persist_load_vfs() {
		usage := vfs_usage(&g_vfs)
		fmt.printfln("restored VFS: %d entries, %d bytes", usage.entries, usage.total_bytes)
	}
	if persist_load_users() {
		fmt.printfln("restored %d user account(s)", auth_count(&g_users))
	}
}

persist_save_if_dirty :: proc() {
	sync.mutex_lock(&g_vfs.lock)
	vfs_dirty := g_vfs.dirty
	sync.mutex_unlock(&g_vfs.lock)

	if vfs_dirty {
		persist_save_vfs()
	}

	sync.mutex_lock(&g_users.lock)
	users_dirty := g_users.dirty
	sync.mutex_unlock(&g_users.lock)

	if users_dirty {
		persist_save_users()
	}
}

// Periodically flushes dirty state.
//
// Polling for a dirty flag rather than snapshotting on a timer means an idle
// server does no disk I/O at all, and a busy one loses at most one interval of
// work to a crash.
persist_worker :: proc() {
	defer runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)

	for {
		time.sleep(SNAPSHOT_INTERVAL)
		free_all(context.temp_allocator)
		persist_save_if_dirty()
	}
}
