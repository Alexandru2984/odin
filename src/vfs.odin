package main

import "core:strings"
import "core:sync"

File :: struct {
	name: string,
	content: string,
}

VFS :: struct {
	files: [dynamic]File,
	lock: sync.Mutex,
}

vfs_init :: proc(vfs: ^VFS) {
	vfs.files = make([dynamic]File)
}

vfs_write :: proc(vfs: ^VFS, name: string, content: string) {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	for &f in vfs.files {
		if f.name == name {
			delete(f.content)
			f.content = strings.clone(content)
			return
		}
	}

	append(&vfs.files, File{
		name = strings.clone(name),
		content = strings.clone(content),
	})
}

vfs_read :: proc(vfs: ^VFS, name: string) -> (string, bool) {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	for f in vfs.files {
		if f.name == name {
			return strings.clone(f.content), true
		}
	}
	return "", false
}

vfs_list :: proc(vfs: ^VFS) -> []string {
	sync.mutex_lock(&vfs.lock)
	defer sync.mutex_unlock(&vfs.lock)

	names := make([]string, len(vfs.files))
	for f, i in vfs.files {
		names[i] = strings.clone(f.name)
	}
	return names
}