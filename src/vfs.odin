package main

import "core:strings"
import "core:sync"
import path "core:path/slashpath"

VFS_Entry_Type :: enum { File, Directory }

VFS_Entry :: struct {
	type:    VFS_Entry_Type,
	content: string, // for files only
}

VFS :: struct {
	entries: map[string]VFS_Entry,
	lock:    sync.Mutex,
}

vfs_init :: proc(vfs: ^VFS) {
	vfs.entries = make(map[string]VFS_Entry)
	vfs.entries["/"] = VFS_Entry{type = .Directory}
}

// Absolute path resolution based on cwd
vfs_resolve_path :: proc(cwd: string, target: string) -> string {
	res := target
	if !path.is_abs(target) {
		res = path.join({cwd, target})
	} else {
		res = path.clean(target)
	}
	return res
}

// Create a directory
vfs_mkdir :: proc(vfs: ^VFS, p: string) -> bool {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if p in vfs.entries { return false } // already exists
	
	parent := path.dir(p)
	if parent_entry, ok := vfs.entries[parent]; !ok || parent_entry.type != .Directory {
		return false // parent not directory or does not exist
	}

	vfs.entries[p] = VFS_Entry{type = .Directory}
	return true
}

vfs_rmdir :: proc(vfs: ^VFS, p: string) -> bool {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if p == "/" { return false } // cannot remove root

	if entry, ok := vfs.entries[p]; ok {
		if entry.type != .Directory { return false } // not a directory
		
		// check if empty
		prefix := p
		if !strings.has_suffix(prefix, "/") { prefix = strings.concatenate({prefix, "/"}) }
		defer if prefix != p { delete(prefix) }

		for key in vfs.entries {
			if key != p && strings.has_prefix(key, prefix) {
				return false // not empty
			}
		}

		delete_key(&vfs.entries, p)
		return true
	}
	return false
}

vfs_write :: proc(vfs: ^VFS, p: string, content: string) -> bool {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	parent := path.dir(p)
	if parent_entry, ok := vfs.entries[parent]; !ok || parent_entry.type != .Directory {
		return false
	}

	if entry, ok := vfs.entries[p]; ok {
		if entry.type == .Directory { return false }
		delete(entry.content) // free old content
	}

	vfs.entries[p] = VFS_Entry{type = .File, content = strings.clone(content)}
	return true
}

vfs_read :: proc(vfs: ^VFS, p: string) -> (string, bool) {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if entry, ok := vfs.entries[p]; ok {
		if entry.type == .File {
			return strings.clone(entry.content), true
		}
	}
	return "", false
}

vfs_rm :: proc(vfs: ^VFS, p: string) -> bool {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if entry, ok := vfs.entries[p]; ok {
		if entry.type == .Directory { return false }
		delete(entry.content)
		delete_key(&vfs.entries, p)
		return true
	}
	return false
}

vfs_is_dir :: proc(vfs: ^VFS, p: string) -> bool {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if entry, ok := vfs.entries[p]; ok {
		return entry.type == .Directory
	}
	return false
}

vfs_list :: proc(vfs: ^VFS, dir_path: string) -> ([]string, bool) {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	if entry, ok := vfs.entries[dir_path]; !ok || entry.type != .Directory {
		return nil, false
	}

	names := make([dynamic]string)
	
	prefix := dir_path
	if dir_path != "/" {
		prefix = strings.concatenate({prefix, "/"})
	}
	defer if prefix != dir_path { delete(prefix) }
	
	for key in vfs.entries {
		if key == dir_path { continue }
		if strings.has_prefix(key, prefix) {
			rest := key[len(prefix):]
			if strings.index(rest, "/") == -1 {
				// Immediate child
				append(&names, strings.clone(rest))
			}
		}
	}
	return names[:], true
}