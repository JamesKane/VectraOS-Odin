// vx9pserve's file server (tools/vx9pserve/hostfs) on a temporary directory,
// through lib/p9's client. Files read, written, created and removed; and
// nothing outside the directory reached: symbolic links, in the directory or
// swapped in under a path already walked, are neither followed nor listed.
// Ported from upstream's tests/host/vx9pserve_test.c.
package vx9pserve_test

import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "abi:vx"
import "vx:p9"
import "../p9test"
import "../../../tools/vx9pserve/hostfs"

// rel in the temporary directory dir.
at :: proc(dir, rel: string) -> string {
	return strings.concatenate({dir, "/", rel}, context.temp_allocator)
}

put_file :: proc(dir, rel, text: string) {
	_ = os.write_entire_file(at(dir, rel), text)
}

// Whether the file at rel holds exactly text.
host_has :: proc(dir, rel, text: string) -> bool {
	got, err := os.read_entire_file(at(dir, rel), context.temp_allocator)
	return err == nil && string(got) == text
}

link :: proc(target, dir, rel: string) -> bool {
	path := strings.clone_to_cstring(at(dir, rel), context.temp_allocator)
	return posix.symlink(strings.clone_to_cstring(target, context.temp_allocator), path) == .OK
}

@(test)
test_hostfs :: proc(t: ^testing.T) {
	template := [?]u8{'/', 't', 'm', 'p', '/', 'v', 'x', '9', 'p', 's', 'e', 'r', 'v', 'e', '-', 't', 'e', 's', 't', '-', 'X', 'X', 'X', 'X', 'X', 'X', 0}
	if !testing.expect(t, posix.mkdtemp(raw_data(template[:])) != nil) {
		return
	}
	dir := string(template[:len(template) - 1])
	put_file(dir, "hello.txt", "hello from the host\n")
	testing.expect_value(t, os.make_directory(at(dir, "sub")), nil)
	put_file(dir, "sub/inner.txt", "inner")
	testing.expect(t, link("/etc", dir, "escape"))
	testing.expect(t, link("../..", dir, "sub/up"))
	testing.expect(t, link("/etc/passwd", dir, "passwd"))

	h: hostfs.Hostfs
	server := new(p9.Server)
	defer free(server)
	if !testing.expect(t, hostfs.init(&h, server, dir, 8192)) {
		return
	}
	defer hostfs.destroy(&h)
	tbuf, rbuf: [8192]u8
	c := p9.Client{rpc = p9test.loopback, ctx = server, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {}), vx.Status.Ok)
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)

	// Reading.
	buf: [256]u8
	n: int
	f: p9.Fid
	f, e = p9.client_walk(&c, root, "hello.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, string(buf[:n]), "hello from the host\n")
	st: p9.Stat
	names: p9.Stat_Text
	testing.expect_value(t, p9.client_stat(&c, f, &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.length, 20)
	testing.expect_value(t, st.name, "hello.txt")
	testing.expect(t, .Dir not_in st.qid.type)
	_ = p9.client_clunk(&c, f)
	f, e = p9.client_walk(&c, root, "sub/inner.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect_value(t, n, 5)
	_ = p9.client_clunk(&c, f)

	// Symbolic links: not walked to, wherever they point.
	for path in ([]string{"escape", "escape/passwd", "passwd", "sub/up/etc", "../../etc"}) { // the last: .. stops at the root
		_, e = p9.client_walk(&c, root, path)
		testing.expectf(t, e == .Err_Not_Found, "walk(%q) is %v", path, e)
	}

	// Listing: the file and the directory; no links.
	f, e = p9.client_walk(&c, root, "")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
	listing: [4096]u8
	n, e = p9.client_read(&c, f, 0, listing[:])
	testing.expect_value(t, e, vx.Status.Ok)
	entries, links := 0, 0
	it := p9.Dir_Entries{buf = listing[:n]}
	for entry in p9.next_entry(&it) {
		entries += 1
		links += int(entry.name == "escape" || entry.name == "passwd")
	}
	testing.expect_value(t, entries, 2)
	testing.expect_value(t, links, 0)
	_ = p9.client_clunk(&c, f)

	// A directory walked to, then swapped for a link out: the next open is refused.
	sub: p9.Fid
	sub, e = p9.client_walk(&c, root, "sub/inner.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	from := at(dir, "sub")
	to := at(dir, "sub-moved")
	testing.expect_value(t, os.rename(from, to), nil)
	testing.expect(t, link("/etc", dir, "sub"))
	testing.expect_value(t, p9.client_open(&c, sub, p9.OREAD), vx.Status.Err_Not_Found)
	_ = p9.client_clunk(&c, sub)
	_ = os.remove(from)
	testing.expect_value(t, os.rename(to, from), nil)

	// Writing, creating and removing.
	f, e = p9.client_walk(&c, root, "")
	testing.expect_value(t, p9.client_create(&c, f, "out.txt", 0o644, p9.OWRITE), vx.Status.Ok)
	n, e = p9.client_write(&c, f, 0, transmute([]u8)string("hi\n"))
	testing.expect_value(t, n, 3)
	_ = p9.client_clunk(&c, f)
	testing.expect(t, host_has(dir, "out.txt", "hi\n"))
	f, e = p9.client_walk(&c, root, "out.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, {access = .Write, trunc = true}), vx.Status.Ok)
	n, e = p9.client_write(&c, f, 0, transmute([]u8)string("again"))
	testing.expect_value(t, n, 5)
	_ = p9.client_clunk(&c, f)
	testing.expect(t, host_has(dir, "out.txt", "again"))
	f, e = p9.client_walk(&c, root, "")
	testing.expect_value(t, p9.client_create(&c, f, "out.txt", 0o644, p9.OWRITE), vx.Status.Err_Exists)
	_ = p9.client_clunk(&c, f)
	f, e = p9.client_walk(&c, root, "")
	testing.expect_value(t, p9.client_create(&c, f, "newdir", p9.DMDIR | 0o755, p9.OREAD), vx.Status.Ok)
	_ = p9.client_clunk(&c, f)
	f, e = p9.client_walk(&c, root, "newdir")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_remove(&c, f), vx.Status.Ok)
	f, e = p9.client_walk(&c, root, "out.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_remove(&c, f), vx.Status.Ok)
	testing.expect(t, !host_has(dir, "out.txt", "again"))
	f, e = p9.client_walk(&c, root, "")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_remove(&c, f), vx.Status.Err_Access) // not the root

	// Clean up: exactly what was made.
	for rel in ([]string{"hello.txt", "sub/inner.txt", "sub/up", "escape", "passwd", "sub"}) {
		_ = os.remove(at(dir, rel))
	}
	testing.expect_value(t, os.remove(dir), nil) // nothing else was left behind
}
