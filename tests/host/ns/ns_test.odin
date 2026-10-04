// lib/ns against two in-memory 9P servers: lexical path cleaning, mount and
// bind with each flag, union directories (walks and reads), longest-prefix
// matching at component boundaries, unmount, and ns output that replays.
// Ported from upstream's tests/host/ns_test.c.
//
//   boot server:  /bin/  /boot/bin/ls  /boot/bin/cat  /dev/  /readme
//   dev server:   /cons  /null
package ns_test

import "abi:vx"
import "core:testing"
import "vx:ns"
import "vx:p9"

Tnode :: struct {
	parent: u64,
	name:   string,
	dir:    bool,
	data:   string,
}

BOOT := [?]Tnode {
	{},
	{0, "/", true, ""},
	{1, "bin", true, ""},
	{1, "boot", true, ""},
	{3, "bin", true, ""},
	{4, "ls", false, "ls!"},
	{4, "cat", false, "cat!"},
	{1, "dev", true, ""},
	{1, "readme", false, "hello"},
}
DEV := [?]Tnode{{}, {0, "/", true, ""}, {1, "cons", false, "console"}, {1, "null", false, ""}}

t_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: u64, st: vx.Status) {
	if len(aname) > 0 {
		return 0, .Err_Not_Found
	}
	return 1, .Ok
}

t_walk :: proc "contextless" (ctx: rawptr, dir: u64, name: string) -> (child: u64, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	for i in 2 ..< len(t) {
		if t[i].parent == dir && t[i].name == name {
			return u64(i), .Ok
		}
	}
	return 0, .Err_Not_Found
}

t_parent :: proc "contextless" (ctx: rawptr, node: u64) -> (parent: u64, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	return t[node].parent != 0 ? t[node].parent : 1, .Ok
}

t_stat :: proc "contextless" (ctx: rawptr, node: u64, out: ^p9.Stat) -> vx.Status {
	t := (^[]Tnode)(ctx)^
	n := &t[node]
	out^ = {
		qid = {n.dir ? p9.QTDIR : p9.QTFILE, 0, node},
		mode = n.dir ? p9.DMDIR | 0o555 : 0o444,
		length = u64(len(n.data)),
		name = n.name,
	}
	return .Ok
}

t_open :: proc "contextless" (ctx: rawptr, node: u64, mode: u8) -> vx.Status {
	return mode & 3 == p9.OREAD ? .Ok : .Err_Access
}

t_read :: proc "contextless" (ctx: rawptr, node: u64, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	data := t[node].data
	n := offset >= u64(len(data)) ? 0 : len(data) - int(offset)
	n = min(n, len(buf))
	copy(buf, data[n > 0 ? int(offset) : 0:][:n])
	return u32(n), .Ok
}

t_readdir :: proc "contextless" (ctx: rawptr, dir: u64, index: u32) -> (child: u64, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	index := index
	for i in 2 ..< len(t) {
		if t[i].parent == dir {
			if index == 0 {
				return u64(i), .Ok
			}
			index -= 1
		}
	}
	return 0, .Err_Not_Found
}

make_server :: proc(s: ^p9.Server, t: ^[]Tnode) {
	s^ = {
		fs = {
			ctx = t,
			attach = t_attach,
			walk = t_walk,
			parent = t_parent,
			stat = t_stat,
			open = t_open,
			read = t_read,
			readdir = t_readdir,
		},
		max_msize = 8192,
	}
}

loopback :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int {
	return p9.serve((^p9.Server)(ctx), req, resp)
}

// A client of s whose buffers are tbuf and rbuf.
connect :: proc(t: ^testing.T, c: ^p9.Client, s: ^p9.Server, tbuf, rbuf: []u8) {
	c^ = {
		rpc  = loopback,
		ctx  = s,
		tbuf = tbuf,
		rbuf = rbuf,
	}
	testing.expect(t, p9.client_version(c, 8192, {}) == .Ok)
}

exists :: proc(space: ^ns.Namespace, path: string) -> bool {
	c, fid, e := ns.walk(space, path)
	if e != .Ok {
		return false
	}
	_ = p9.client_clunk(c, fid)
	return true
}

// The names in a directory, as "a b c", reading through the namespace.
list :: proc(space: ^ns.Namespace, path: string, out: []u8) -> string {
	n := 0
	f: ns.File
	if ns.open(space, path, p9.OREAD, &f) != .Ok {
		return "(cannot open)"
	}
	buf: [2048]u8
	got: int
	e: vx.Status
	for {
		got, e = ns.read(&f, buf[:])
		if e != .Ok || got == 0 {
			break
		}
		for off := 0; off + 2 <= got; {
			size := int(buf[off]) | int(buf[off + 1]) << 8
			st: p9.Stat
			if p9.stat_decode(buf[off:][:size + 2], &st) != .Ok {
				return "(bad stat)"
			}
			if n > 0 {
				out[n] = ' '
				n += 1
			}
			copy(out[n:], st.name)
			n += len(st.name)
			off += size + 2
		}
	}
	ns.close(&f)
	return e != .Ok ? "(read failed)" : string(out[:n])
}

clean_is :: proc(in_: string, want: string) -> bool {
	out: [64]u8
	got := ns.clean(in_, out[:])
	return len(got) > 0 && got == want
}

@(test)
test_clean :: proc(t: ^testing.T) {
	testing.expect(t, clean_is("/", "/"))
	testing.expect(t, clean_is("//a//b/", "/a/b"))
	testing.expect(t, clean_is("/a/./b/../c", "/a/c"))
	testing.expect(t, clean_is("/../../x", "/x"))
	testing.expect(t, clean_is("/a/..", "/"))
	testing.expect(t, clean_is("/..", "/"))
	out: [8]u8
	testing.expect(t, ns.clean("relative", out[:]) == "")
	testing.expect(t, ns.clean("", out[:]) == "")
	testing.expect(t, ns.clean("/abcdefghij", out[:]) == "") // does not fit
}

@(test)
test_namespace :: proc(t: ^testing.T) {
	space := new(ns.Namespace)
	defer free(space)
	boot_nodes, dev_nodes := BOOT[:], DEV[:]
	boot_srv, dev_srv := new(p9.Server), new(p9.Server)
	defer free(boot_srv)
	defer free(dev_srv)
	make_server(boot_srv, &boot_nodes)
	make_server(dev_srv, &dev_nodes)
	bufs := new([4][8192]u8)
	defer free(bufs)
	boot_c, dev_c: p9.Client
	connect(t, &boot_c, boot_srv, bufs[0][:], bufs[1][:])
	connect(t, &dev_c, dev_srv, bufs[2][:], bufs[3][:])
	names: [256]u8

	testing.expect(t, !exists(space, "/")) // empty
	testing.expect(t, ns.mount(space, &boot_c, vx.HANDLE_NONE, "/srv/bootfs", "", "/bin", {}) == .Err_Not_Found) // nothing at /bin to mount on yet
	testing.expect(t, ns.mount(space, &boot_c, vx.HANDLE_NONE, "/srv/bootfs", "", "/", {}) == .Ok)
	testing.expect(t, list(space, "/", names[:]) == "bin boot dev readme")
	testing.expect(t, exists(space, "/boot/bin/ls") && !exists(space, "/bin/ls"))
	testing.expect(t, exists(space, "/bin/../boot/bin/../../readme")) // lexical ..
	testing.expect(t, exists(space, "/../../../readme"))

	// bind -a: the union of what was at /bin, then /boot/bin.
	testing.expect(t, ns.bind(space, "/boot/bin", "/bin", {.After}) == .Ok)
	testing.expect(t, exists(space, "/bin/ls") && exists(space, "/bin/cat"))
	testing.expect(t, list(space, "/bin", names[:]) == "ls cat") // the old /bin is empty
	testing.expect(t, !exists(space, "/binary") && !exists(space, "/bin/nope"))

	// Reading a file through a bind.
	f: ns.File
	text: [16]u8
	testing.expect(t, ns.open(space, "/bin/cat", p9.OREAD, &f) == .Ok)
	n1, e1 := ns.read(&f, text[:2])
	n2, e2 := ns.read(&f, text[2:12])
	n3, e3 := ns.read(&f, text[:10])
	testing.expect(t, e1 == .Ok && n1 == 2 && e2 == .Ok && n2 == 2 && e3 == .Ok && n3 == 0)
	testing.expect(t, string(text[:4]) == "cat!")
	ns.close(&f)
	testing.expect(t, ns.open(space, "/bin/cat", p9.OWRITE, &f) == .Err_Access)

	// A second server, after what is at /dev; then one before it.
	testing.expect(t, ns.mount(space, &dev_c, vx.HANDLE_NONE, "/srv/cons", "", "/dev", {.After}) == .Ok)
	testing.expect(t, exists(space, "/dev/cons") && list(space, "/dev", names[:]) == "cons null")
	testing.expect(t, ns.bind(space, "/boot", "/dev", {.Before}) == .Ok)
	testing.expect(t, list(space, "/dev", names[:]) == "bin cons null")
	testing.expect(t, exists(space, "/dev/bin/ls"))

	out: [512]u8
	n := ns.print(space, out[:])
	want :=
		"mount /srv/bootfs /\n" +
		"bind /bin /bin\n" +
		"bind -a /boot/bin /bin\n" +
		"bind /boot /dev\n" +
		"bind -a /dev /dev\n" +
		"mount -a /srv/cons /dev\n"
	testing.expect(t, string(out[:n]) == want)
	testing.expect(t, ns.print(space, out[:10]) == 0)

	// unmount one member, then a whole entry; replace with a plain bind.
	testing.expect(t, ns.unmount(space, "/boot/bin", "/bin") == .Ok)
	testing.expect(t, !exists(space, "/bin/ls") && exists(space, "/bin"))
	testing.expect(t, ns.unmount(space, "/nothing", "/bin") == .Err_Not_Found)
	testing.expect(t, ns.unmount(space, "", "/dev") == .Ok)
	testing.expect(t, !exists(space, "/dev/cons") && list(space, "/dev", names[:]) == "")
	testing.expect(t, ns.bind(space, "/boot/bin", "/dev", ns.REPLACE) == .Ok)
	testing.expect(t, list(space, "/dev", names[:]) == "ls cat")
	testing.expect(t, ns.bind(space, "/missing", "/dev", {}) == .Err_Not_Found)
	testing.expect(t, ns.bind(space, "relative", "/dev", {}) == .Err_Invalid)

	// Every fid the namespace dropped was clunked: only the members' own remain.
	live := 0
	for i in 0 ..< p9.MAX_FIDS {
		live += int(boot_srv.fids[i].used) + int(dev_srv.fids[i].used)
	}
	members := 0
	for &e in space.entries {
		if e.path_len > 0 {
			members += int(e.count)
		}
	}
	testing.expect(t, live == members)
}
