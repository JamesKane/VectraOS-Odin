// lib/ns against two in-memory 9P servers: lexical path cleaning, mount and
// bind with each flag, union directories (walks and reads), longest-prefix
// matching at component boundaries, unmount, ns output that replays in the
// order members were made, connections let go, and creates. Ported from
// upstream's tests/host/ns_test.c; dial_test.odin adds dialing, which
// upstream does not host-test.
//
//   boot server:  /bin/  /boot/bin/ls  /boot/bin/cat  /dev/  /readme
//   dev server:   /cons  /null
package ns_test

import "abi:vx"
import "core:strings"
import "core:sync"
import "core:testing"
import "vx:ns"
import "vx:p9"
import "../p9test"

Tnode :: struct {
	parent: p9.Node,
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

t_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if len(aname) > 0 {
		return 0, .Err_Not_Found
	}
	return 1, .Ok
}

t_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	for i in 2 ..< len(t) {
		if t[i].parent == dir && t[i].name == name {
			return p9.Node(i), .Ok
		}
	}
	return 0, .Err_Not_Found
}

t_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	return t[node].parent != 0 ? t[node].parent : 1, .Ok
}

t_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	t := (^[]Tnode)(ctx)^
	n := &t[node]
	out^ = {
		qid = {n.dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = n.dir ? p9.DMDIR | 0o555 : 0o444,
		length = u64(len(n.data)),
		name = n.name,
	}
	return .Ok
}

t_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	return mode.access == .Read ? .Ok : .Err_Access
}

t_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	data := t[node].data
	n := offset >= u64(len(data)) ? 0 : len(data) - int(offset)
	n = min(n, len(buf))
	copy(buf, data[n > 0 ? int(offset) : 0:][:n])
	return u32(n), .Ok
}

t_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	t := (^[]Tnode)(ctx)^
	index := index
	for i in 2 ..< len(t) {
		if t[i].parent == dir {
			if index == 0 {
				return p9.Node(i), .Ok
			}
			index -= 1
		}
	}
	return 0, .Err_Not_Found
}

make_server :: proc "contextless" (s: ^p9.Server, t: ^[]Tnode) {
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

// A client of s whose buffers are tbuf and rbuf.
connect :: proc(t: ^testing.T, c: ^p9.Client, s: ^p9.Server, tbuf, rbuf: []u8, loc := #caller_location) {
	c^ = {
		rpc  = p9test.loopback,
		ctx  = s,
		tbuf = tbuf,
		rbuf = rbuf,
	}
	testing.expect_value(t, p9.client_version(c, 8192, {}), vx.Status.Ok, loc)
}

// The two servers and a client of each, as every test here uses them.
Fixture :: struct {
	boot_nodes, dev_nodes: []Tnode,
	boot_srv, dev_srv:     p9.Server,
	bufs:                  [4][8192]u8,
	boot_c, dev_c:         p9.Client,
}

// A new fixture, from the heap: it is too big for a test's stack.
fixture :: proc(t: ^testing.T, loc := #caller_location) -> ^Fixture {
	f := new(Fixture)
	f.boot_nodes, f.dev_nodes = BOOT[:], DEV[:]
	make_server(&f.boot_srv, &f.boot_nodes)
	make_server(&f.dev_srv, &f.dev_nodes)
	connect(t, &f.boot_c, &f.boot_srv, f.bufs[0][:], f.bufs[1][:], loc)
	connect(t, &f.dev_c, &f.dev_srv, f.bufs[2][:], f.bufs[3][:], loc)
	return f
}

exists :: proc(space: ^ns.Namespace, path: string) -> bool {
	c, fid, e := ns.walk(space, path)
	if e != .Ok {
		return false
	}
	_ = p9.client_clunk(c, fid)
	return true
}

expect_exists :: proc(t: ^testing.T, space: ^ns.Namespace, path: string, want := true, loc := #caller_location) {
	testing.expectf(t, exists(space, path) == want, "exists(%q) is %v", path, !want, loc = loc)
}

// The names in a directory, as "a b c", reading through the namespace.
// Allocates from the temp allocator.
list :: proc(space: ^ns.Namespace, path: string) -> string {
	f: ns.File
	if ns.open(space, path, p9.OREAD, &f) != .Ok {
		return "(cannot open)"
	}
	defer ns.close(&f)
	b := strings.builder_make(context.temp_allocator)
	buf: [2048]u8
	for {
		got, e := ns.read(&f, buf[:])
		if e != .Ok {
			return "(read failed)"
		}
		if got == 0 {
			break
		}
		chunk, ok := p9test.names(buf[:got])
		if !ok {
			return "(bad stat)"
		}
		if len(chunk) > 0 && strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, chunk)
	}
	return strings.to_string(b)
}

@(test)
test_clean :: proc(t: ^testing.T) {
	Case :: struct {
		in_, want: string,
		room:      int, // the size of the output buffer
	}
	cases := []Case {
		{"/", "/", 64},
		{"//a//b/", "/a/b", 64},
		{"/a/./b/../c", "/a/c", 64},
		{"/../../x", "/x", 64},
		{"/a/..", "/", 64},
		{"/..", "/", 64},
		{"relative", "", 8},
		{"", "", 8},
		{"/abcdefghij", "", 8}, // does not fit
	}
	for c in cases {
		out: [64]u8
		got := ns.clean(c.in_, out[:c.room])
		testing.expectf(t, got == c.want, "clean(%q) is %q, want %q", c.in_, got, c.want)
	}
}

@(test)
test_namespace :: proc(t: ^testing.T) {
	space := new(ns.Namespace)
	defer free(space)
	fx := fixture(t)
	defer free(fx)
	boot_c, dev_c := &fx.boot_c, &fx.dev_c
	boot_srv, dev_srv := &fx.boot_srv, &fx.dev_srv

	expect_exists(t, space, "/", false) // empty
	testing.expect_value(t, ns.mount(space, boot_c, vx.HANDLE_NONE, "/srv/bootfs", "", "/bin", {}), vx.Status.Err_Not_Found) // nothing at /bin to mount on yet
	testing.expect_value(t, ns.mount(space, boot_c, vx.HANDLE_NONE, "/srv/bootfs", "", "/", {}), vx.Status.Ok)
	testing.expect_value(t, list(space, "/"), "bin boot dev readme")
	expect_exists(t, space, "/boot/bin/ls")
	expect_exists(t, space, "/bin/ls", false)
	expect_exists(t, space, "/bin/../boot/bin/../../readme") // lexical ..
	expect_exists(t, space, "/../../../readme")

	// bind -a: the union of what was at /bin, then /boot/bin.
	testing.expect_value(t, ns.bind(space, "/boot/bin", "/bin", {.After}), vx.Status.Ok)
	expect_exists(t, space, "/bin/ls")
	expect_exists(t, space, "/bin/cat")
	testing.expect_value(t, list(space, "/bin"), "ls cat") // the old /bin is empty
	expect_exists(t, space, "/binary", false)
	expect_exists(t, space, "/bin/nope", false)

	// Reading a file through a bind.
	f: ns.File
	text: [16]u8
	testing.expect_value(t, ns.open(space, "/bin/cat", p9.OREAD, &f), vx.Status.Ok)
	n1, e1 := ns.read(&f, text[:2])
	n2, e2 := ns.read(&f, text[2:12])
	n3, e3 := ns.read(&f, text[:10])
	testing.expect_value(t, e1, vx.Status.Ok)
	testing.expect_value(t, n1, 2)
	testing.expect_value(t, e2, vx.Status.Ok)
	testing.expect_value(t, n2, 2)
	testing.expect_value(t, e3, vx.Status.Ok)
	testing.expect_value(t, n3, 0)
	testing.expect_value(t, string(text[:4]), "cat!")
	ns.close(&f)
	testing.expect_value(t, ns.open(space, "/bin/cat", p9.OWRITE, &f), vx.Status.Err_Access)

	// A second server, after what is at /dev; then one before it.
	testing.expect_value(t, ns.mount(space, dev_c, vx.HANDLE_NONE, "/srv/cons", "", "/dev", {.After}), vx.Status.Ok)
	expect_exists(t, space, "/dev/cons")
	testing.expect_value(t, list(space, "/dev"), "cons null")
	testing.expect_value(t, ns.bind(space, "/boot", "/dev", {.Before}), vx.Status.Ok)
	testing.expect_value(t, list(space, "/dev"), "bin cons null")
	expect_exists(t, space, "/dev/bin/ls")

	out: [512]u8
	n := ns.print(space, out[:])
	want :=
		"mount /srv/bootfs /\n" +
		"bind /bin /bin\n" +
		"bind -a /boot/bin /bin\n" +
		"bind /dev /dev\n" +
		"mount -a /srv/cons /dev\n" +
		"bind -b /boot /dev\n" // in the order they were made
	testing.expect_value(t, string(out[:n]), want)
	testing.expect_value(t, ns.print(space, out[:10]), 0)

	// unmount one member, then a whole entry; replace with a plain bind.
	testing.expect_value(t, ns.unmount(space, "/boot/bin", "/bin"), vx.Status.Ok)
	expect_exists(t, space, "/bin/ls", false)
	expect_exists(t, space, "/bin")
	testing.expect_value(t, ns.unmount(space, "/nothing", "/bin"), vx.Status.Err_Not_Found)
	testing.expect_value(t, ns.unmount(space, "", "/dev"), vx.Status.Ok)
	expect_exists(t, space, "/dev/cons", false)
	testing.expect_value(t, list(space, "/dev"), "")
	testing.expect_value(t, ns.bind(space, "/boot/bin", "/dev", ns.REPLACE), vx.Status.Ok)
	testing.expect_value(t, list(space, "/dev"), "ls cat")
	testing.expect_value(t, ns.bind(space, "/missing", "/dev", {}), vx.Status.Err_Not_Found)
	testing.expect_value(t, ns.bind(space, "relative", "/dev", {}), vx.Status.Err_Invalid)

	// Every fid the namespace dropped was clunked: only the members' own remain.
	live := 0
	for i in 0 ..< p9.MAX_FIDS {
		live += int(boot_srv.fids[i].used) + int(dev_srv.fids[i].used)
	}
	members := 0
	for &e in space.entries {
		members += len(e.members)
	}
	testing.expect_value(t, live, members)
}

// Replays ns output into a fresh namespace, as a child replays its spawn
// records: mount SRC OLD [ANAME] and bind [-abc] NEW OLD lines, the sources
// being /srv/bootfs and /srv/cons here.
replay :: proc(space: ^ns.Namespace, fx: ^Fixture, script: string) -> vx.Status {
	lines := script
	for line in strings.split_lines_iterator(&lines) {
		w := strings.fields(line, context.temp_allocator)
		if len(w) < 3 {
			return .Err_Invalid
		}
		i := 1
		flags: ns.Flags
		if w[1][0] == '-' {
			if strings.contains_rune(w[1], 'a') {
				flags = {.After}
			} else if strings.contains_rune(w[1], 'b') {
				flags = {.Before}
			}
			i = 2
		}
		st: vx.Status
		if w[0] == "mount" {
			c := w[i] == "/srv/bootfs" ? &fx.boot_c : &fx.dev_c
			aname := len(w) > i + 2 ? w[i + 2] : ""
			st = ns.mount(space, c, vx.HANDLE_NONE, w[i], aname, w[i + 1], flags)
		} else {
			st = ns.bind(space, w[i], w[i + 1], flags)
		}
		if st != .Ok {
			return st
		}
	}
	return .Ok
}

released: int // how many times count_release ran: test_replay_and_release's alone

count_release :: proc "contextless" (c: ^p9.Client, connector: vx.Handle) {
	sync.atomic_add(&released, 1)
}

used_fids :: proc(s: ^p9.Server) -> (n: int) {
	for f in s.fids {
		n += int(f.used)
	}
	return
}

// Review fixes (M3): ns output, and so a child's namespace, replays members in
// the order they were made, even after a replace or an unmount reused a slot;
// and an unmount that leaves a connection unused lets it go.
@(test)
test_replay_and_release :: proc(t: ^testing.T) {
	parent, child := new(ns.Namespace), new(ns.Namespace)
	defer free(parent)
	defer free(child)
	fx := fixture(t)
	defer free(fx)
	parent.release = count_release
	testing.expect_value(t, ns.mount(parent, &fx.boot_c, vx.HANDLE_NONE, "/srv/bootfs", "", "/", {}), vx.Status.Ok)
	testing.expect_value(t, ns.bind(parent, "/boot", "/bin", {}), vx.Status.Ok) // /bin's entry, made first
	testing.expect_value(t, ns.mount(parent, &fx.dev_c, vx.HANDLE_NONE, "/srv/cons", "", "/dev", {}), vx.Status.Ok)
	testing.expect_value(t, ns.bind(parent, "/dev", "/bin", {}), vx.Status.Ok) // replaced: now needs /dev's mount
	testing.expect_value(t, list(parent, "/bin"), "cons null")
	script: [512]u8
	n := ns.print(parent, script[:])
	testing.expect(t, n > 0)
	testing.expect_value(t, replay(child, fx, string(script[:n])), vx.Status.Ok)
	testing.expect_value(t, list(child, "/bin"), "cons null") // the same, not bootfs's empty /dev

	testing.expect_value(t, ns.unmount(parent, "", "/bin"), vx.Status.Ok)
	testing.expect_value(t, sync.atomic_load(&released), 0) // /dev still uses the cons connection
	testing.expect_value(t, ns.unmount(parent, "", "/dev"), vx.Status.Ok)
	testing.expect_value(t, sync.atomic_load(&released), 1) // its last member is gone
	testing.expect_value(t, ns.mount(parent, &fx.dev_c, vx.HANDLE_NONE, "/srv/cons", "", "/dev", {}), vx.Status.Ok)

	// Creating: in the directory the path names, which these servers refuse.
	before := used_fids(&fx.dev_srv)
	f: ns.File
	testing.expect_value(t, ns.create(parent, "/dev/new", 0o644, p9.OWRITE, &f), vx.Status.Err_Access)
	testing.expect_value(t, ns.create(parent, "/nowhere/new", 0o644, p9.OWRITE, &f), vx.Status.Err_Not_Found)
	testing.expect_value(t, ns.create(parent, "/", 0o644, p9.OWRITE, &f), vx.Status.Err_Invalid)
	testing.expect_value(t, used_fids(&fx.dev_srv), before) // the failed creates clunked what they walked to
}
