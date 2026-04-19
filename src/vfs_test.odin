package main

import "core:testing"
import "core:fmt"

@(test)
test_vfs_basic :: proc(t: ^testing.T) {
	v: VFS
	vfs_init(&v)

	// test mkdir
	ok := vfs_mkdir(&v, "/home")
	testing.expect(t, ok, "should create /home")
	ok = vfs_mkdir(&v, "/home/micu")
	testing.expect(t, ok, "should create /home/micu")

	// test write
	ok = vfs_write(&v, "/home/micu/test.txt", "hello test")
	testing.expect(t, ok, "should write test.txt")

	// test read
	content, found := vfs_read(&v, "/home/micu/test.txt")
	testing.expect(t, found, "should find test.txt")
	testing.expect_value(t, content, "hello test")
	delete(content)

	// test list
	names, list_ok := vfs_list(&v, "/home/micu")
	testing.expect(t, list_ok, "should list /home/micu")
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "test.txt")
	
	for n in names { delete(n) }
	delete(names)
}

@(test)
test_vfs_paths :: proc(t: ^testing.T) {
	p := vfs_resolve_path("/home/user", "test.txt")
	testing.expect_value(t, p, "/home/user/test.txt")
	delete(p)

	p = vfs_resolve_path("/home/user", "../guest/test.txt")
	testing.expect_value(t, p, "/home/guest/test.txt")
	delete(p)
	
	p = vfs_resolve_path("/home/user", "/etc/passwd")
	testing.expect_value(t, p, "/etc/passwd")
	delete(p)
}