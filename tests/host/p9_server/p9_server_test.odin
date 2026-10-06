// lib/p9's server framework and client against a small in-memory tree, then
// the hostile-client conformance test (upstream 02 §2, 04 §7): raw messages
// that try to leave the attach root, misuse fids, and lie about sizes and
// counts; and share tokens, never good again once their holds are gone.
// Ported from upstream's tests/host/p9_server_test.c; each test has a
// tree and a server of its own, since Odin's runner runs them in parallel.
//
//   /           (node 1)
//   /docs/      (node 2)
//   /docs/a.txt (node 3)  "alpha"
//   /b.txt      (node 4)  "bravo"
//   /docs/sub/  (node 5)  attach name "docs" starts at /docs
package p9_server_test

import "abi:vx"
import "core:testing"
import "vx:drbg"
import "vx:p9"
import "../p9test"

Ram_Node :: struct {
	parent:  p9.Node,
	name:    string,
	dir:     bool,
	data:    [64]u8,
	len:     u32,
	removed: bool,
}

Ram :: struct {
	nodes:         [16]Ram_Node,
	count:         p9.Node,
	names:         [16][16]u8, // created nodes' names
	not_yet:       bool, // reads and writes answer Err_Should_Wait, as a console with nothing typed does
	clone_to:      p9.Node, // opening /docs/a.txt moves the fid here, as a clone file does
	opened_clunks: [dynamic; 8]p9.Node, // the nodes clunk was told an open fid let go
}

ram_init :: proc(r: ^Ram) {
	r^ = {}
	r.nodes[1] = {parent = 0, name = "/", dir = true}
	r.nodes[2] = {parent = 1, name = "docs", dir = true}
	r.nodes[3] = {parent = 2, name = "a.txt", len = 5}
	r.nodes[4] = {parent = 1, name = "b.txt", len = 5}
	r.nodes[5] = {parent = 2, name = "sub", dir = true}
	copy(r.nodes[3].data[:], "alpha")
	copy(r.nodes[4].data[:], "bravo")
	r.count = 6
}

ram_live :: proc "contextless" (r: ^Ram, n: p9.Node) -> bool {
	return n != 0 && n < r.count && !r.nodes[n].removed
}

ram_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	switch aname {
	case "":
		return 1, .Ok
	case "docs":
		return 2, .Ok
	}
	return 0, .Err_Not_Found
}

ram_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	r := (^Ram)(ctx)
	for i in 1 ..< r.count {
		if ram_live(r, i) && r.nodes[i].parent == dir && r.nodes[i].name == name {
			return i, .Ok
		}
	}
	return 0, .Err_Not_Found
}

ram_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	r := (^Ram)(ctx)
	if !ram_live(r, node) || r.nodes[node].parent == 0 {
		return 0, .Err_Not_Found
	}
	return r.nodes[node].parent, .Ok
}

ram_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	r := (^Ram)(ctx)
	if !ram_live(r, node) {
		return .Err_Not_Found
	}
	n := &r.nodes[node]
	out^ = {
		qid = {n.dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = n.dir ? p9.DMDIR | 0o755 : 0o644,
		length = n.dir ? 0 : u64(n.len),
		name = n.name,
		uid = "jk",
		gid = "jk",
		muid = "",
	}
	return .Ok
}

ram_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	r := (^Ram)(ctx)
	if mode.trunc {
		r.nodes[node].len = 0
	}
	return .Ok
}

ram_clone :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> (opened: p9.Node, st: vx.Status) {
	r := (^Ram)(ctx)
	if node != 3 || r.clone_to == 0 {
		return 0, .Err_Not_Found
	}
	if r.not_yet {
		return 0, .Err_Should_Wait // a listen file before a call comes
	}
	return r.clone_to, .Ok
}

ram_clunk :: proc "contextless" (ctx: rawptr, node: p9.Node, opened: bool) {
	r := (^Ram)(ctx)
	if opened {
		_ = append(&r.opened_clunks, node)
	}
}

ram_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	r := (^Ram)(ctx)
	if r.not_yet {
		return 0, .Err_Should_Wait
	}
	n := &r.nodes[node]
	got := offset >= u64(n.len) ? 0 : n.len - u32(offset)
	got = min(got, u32(len(buf)))
	if got > 0 {
		copy(buf, n.data[offset:][:got])
	}
	return got, .Ok
}

ram_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	r := (^Ram)(ctx)
	index := index
	for i in 1 ..< r.count {
		if !ram_live(r, i) || r.nodes[i].parent != dir || i == dir {
			continue
		}
		if index == 0 {
			return i, .Ok
		}
		index -= 1
	}
	return 0, .Err_Not_Found
}

ram_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	r := (^Ram)(ctx)
	if r.not_yet {
		return 0, .Err_Should_Wait
	}
	n := &r.nodes[node]
	if offset >= len(n.data) {
		return 0, .Err_Range
	}
	count = u32(min(len(data), len(n.data) - int(offset))) // perhaps a short write
	copy(n.data[offset:], data[:count])
	n.len = max(n.len, u32(offset) + count)
	return count, .Ok
}

ram_create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	r := (^Ram)(ctx)
	if _, e := ram_walk(ctx, dir, name); e == .Ok {
		return 0, .Err_Exists
	}
	if r.count == 16 || len(name) > 15 {
		return 0, .Err_No_Memory
	}
	copy(r.names[r.count][:], name)
	r.nodes[r.count] = {parent = dir, name = string(r.names[r.count][:len(name)]), dir = perm & p9.DMDIR != 0}
	node = r.count
	r.count += 1
	return node, .Ok
}

ram_remove :: proc "contextless" (ctx: rawptr, node: p9.Node) -> vx.Status {
	r := (^Ram)(ctx)
	if _, e := ram_readdir(ctx, node, 0); r.nodes[node].dir && e == .Ok {
		return .Err_Access // not empty
	}
	r.nodes[node].removed = true
	return .Ok
}

// A server for the tree, before Tversion.
ram_server :: proc(s: ^p9.Server, r: ^Ram) {
	s^ = {
		fs = {
			ctx = r,
			attach = ram_attach,
			walk = ram_walk,
			parent = ram_parent,
			stat = ram_stat,
			open = ram_open,
			read = ram_read,
			readdir = ram_readdir,
			write = ram_write,
			create = ram_create,
			remove = ram_remove,
			clone = ram_clone,
			clunk = ram_clunk,
		},
		max_msize = 8192,
		supported = {.Dref, .Notify},
	}
}

@(test)
test_client :: proc(t: ^testing.T) {
	ram: Ram
	server: p9.Server
	ram_init(&ram)
	ram_server(&server, &ram)
	tbuf, rbuf: [16384]u8
	c := p9.Client{rpc = p9test.loopback, ctx = &server, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 16384, {.Dref, .Map}), vx.Status.Ok)
	testing.expect_value(t, c.msize, 8192)
	testing.expect_value(t, c.dialect, p9.Dialect.P9_2000X)
	testing.expect_value(t, c.extensions, p9.Extensions{.Dref}) // the intersection

	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)
	f: p9.Fid
	n: int
	f, e = p9.client_walk(&c, root, "docs/a.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
	buf: [64]u8
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, string(buf[:5]), "alpha")
	n, e = p9.client_read(&c, f, 2, buf[:2])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, string(buf[:2]), "ph")
	n, e = p9.client_read(&c, f, 5, buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 0)
	_, e = p9.client_write(&c, f, 0, transmute([]u8)string("x"))
	testing.expect_value(t, e, vx.Status.Err_Access) // opened for reading
	testing.expect_value(t, p9.client_clunk(&c, f), vx.Status.Ok)
	testing.expect_value(t, p9.client_clunk(&c, f), vx.Status.Err_Bad_Handle)

	// A directory reads as whole stat entries.
	f, e = p9.client_walk(&c, root, "")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
	dir: [512]u8
	n, e = p9.client_read(&c, f, 0, dir[:])
	testing.expect_value(t, e, vx.Status.Ok)
	entries := 0
	it := p9.Dir_Entries{buf = dir[:n]}
	for _ in p9.next_entry(&it) {
		entries += 1
	}
	testing.expectf(t, it.off == n, "the entry at %d of %d bytes did not decode", it.off, n)
	testing.expect_value(t, entries, 2) // docs and b.txt
	last: int
	last, e = p9.client_read(&c, f, u64(n), dir[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, last, 0)
	_, e = p9.client_read(&c, f, 1, dir[:])
	testing.expect_value(t, e, vx.Status.Err_Range) // not where the last read ended
	_ = p9.client_clunk(&c, f)

	// Create, write, read back, stat, remove.
	f, e = p9.client_walk(&c, root, "docs")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_create(&c, f, "new.txt", 0o644, p9.ORDWR), vx.Status.Ok)
	n, e = p9.client_write(&c, f, 0, transmute([]u8)string("hello"))
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 5)
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 5)
	testing.expect_value(t, string(buf[:5]), "hello")
	st: p9.Stat
	names: p9.Stat_Text
	testing.expect_value(t, p9.client_stat(&c, f, &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.length, 5)
	testing.expect_value(t, len(st.name), 7)
	testing.expect_value(t, p9.client_remove(&c, f), vx.Status.Ok)
	_, e = p9.client_walk(&c, root, "docs/new.txt")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	f, e = p9.client_walk(&c, root, "docs/a.txt/../../b.txt")
	testing.expect_value(t, e, vx.Status.Ok) // .. inside the root is fine
	testing.expect_value(t, p9.client_stat(&c, f, &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.qid.path, 4)
	_ = p9.client_clunk(&c, f)
}

// --- The hostile client: raw messages, straight to serve ---

Hostile :: struct {
	server: ^p9.Server,
	resp:   [16384]u8,
	reply:  p9.Msg,
}

raw :: proc(h: ^Hostile, t: p9.Msg) -> vx.Status {
	t := t
	req: [2048]u8
	n := p9.encode(&t, req[:])
	if n == 0 {
		return .Err_Too_Small
	}
	reply_len, res := p9.serve(h.server, req[:n], h.resp[:])
	if res != .Reply {
		return .Err_Peer_Closed // the server would hang up
	}
	if p9.decode(h.resp[:reply_len], &h.reply) != .Ok || h.reply.tag != t.tag {
		return .Err_Invalid
	}
	return h.reply.type == .Rerror ? p9.error_status(h.reply.ename) : .Ok
}

walk_msg :: proc(fid, newfid: p9.Fid, names: ..string) -> p9.Msg {
	t := p9.Msg{type = .Twalk, tag = 1, fid = fid, newfid = newfid, nwname = u16(len(names))}
	copy(t.wname[:], names)
	return t
}

@(test)
test_hostile_client :: proc(t: ^testing.T) {
	ram: Ram
	server: p9.Server
	ram_init(&ram)
	ram_server(&server, &ram)
	h := new(Hostile, context.temp_allocator)
	h.server = &server
	ok := vx.Status.Ok

	// A fresh session: nothing works before Tversion, and a tiny msize is refused.
	server.msize = 0
	testing.expect_value(t, raw(h, {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}), vx.Status.Err_Bad_State)
	testing.expect(t, raw(h, {type = .Tversion, tag = p9.NOTAG, msize = 100, version = "9P2000"}) != ok)
	testing.expect_value(t, raw(h, {type = .Tversion, tag = p9.NOTAG, msize = 4096, version = "9P2000.L"}), ok)
	testing.expect_value(t, h.reply.msize, 4096)
	testing.expect_value(t, h.reply.version, "9P2000") // .L is answered with plain 9P2000

	// Attached at "docs": no walk may leave /docs.
	testing.expect_value(t, raw(h, {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID, aname = "docs"}), ok)
	testing.expect_value(t, raw(h, {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}), vx.Status.Err_Bad_State) // fid in use
	testing.expect_value(t, raw(h, {type = .Tattach, tag = 1, fid = 9, afid = 3}), vx.Status.Err_Unsupported) // no auth yet
	testing.expect_value(t, raw(h, walk_msg(1, 2, "..", "..", "..", "..", "..")), ok)
	testing.expect_value(t, h.reply.nwqid, 5)
	testing.expect_value(t, h.reply.wqid[4].path, 2) // still /docs
	testing.expect_value(t, raw(h, walk_msg(1, 3, "sub", "..", "..", "..", "b.txt")), ok)
	testing.expect_value(t, h.reply.nwqid, 4) // b.txt is outside: not found
	testing.expect_value(t, raw(h, {type = .Tstat, tag = 1, fid = 3}), vx.Status.Err_Bad_Handle) // the partial walk made no fid
	testing.expect_value(t, raw(h, walk_msg(1, 3, "sub/../../b.txt")), vx.Status.Err_Invalid)
	testing.expect_value(t, raw(h, walk_msg(1, 3, ".")), vx.Status.Err_Invalid)
	testing.expect_value(t, raw(h, walk_msg(1, 3, "")), vx.Status.Err_Invalid)
	// Names are UTF-8 with no control characters (ADR-0013).
	testing.expect_value(t, raw(h, walk_msg(1, 3, "a\nb")), vx.Status.Err_Invalid)
	testing.expect_value(t, raw(h, walk_msg(1, 3, "\xc3")), vx.Status.Err_Invalid)
	testing.expect_value(t, raw(h, walk_msg(1, 3, "\xc0\xae")), vx.Status.Err_Invalid)

	// Fids: unknown, taken, reserved, open, too many.
	testing.expect_value(t, raw(h, walk_msg(77, 3, "a.txt")), vx.Status.Err_Bad_Handle)
	testing.expect_value(t, raw(h, walk_msg(1, 2, "a.txt")), vx.Status.Err_Bad_State) // newfid 2 is taken
	testing.expect_value(t, raw(h, walk_msg(1, p9.NOFID, "a.txt")), vx.Status.Err_Bad_State)
	testing.expect_value(t, raw(h, walk_msg(1, 3, "a.txt")), ok)
	testing.expect_value(t, raw(h, {type = .Tread, tag = 1, fid = 3, count = 10}), vx.Status.Err_Access) // not open
	testing.expect_value(t, raw(h, {type = .Topen, tag = 1, fid = 3, mode = p9.OREAD}), ok)
	testing.expect_value(t, raw(h, {type = .Topen, tag = 1, fid = 3, mode = p9.OREAD}), vx.Status.Err_Bad_State) // twice
	testing.expect_value(t, raw(h, walk_msg(3, 4)), vx.Status.Err_Bad_State) // an open fid
	testing.expect_value(t, raw(h, {type = .Twrite, tag = 1, fid = 3, data = transmute([]u8)string("x")}), vx.Status.Err_Access)
	testing.expect_value(t, raw(h, {type = .Tread, tag = 1, fid = 3, count = 0xffff_ffff}), ok)
	testing.expect_value(t, h.reply.count, 5) // clamped: the read cannot run past msize or the file
	testing.expect_value(t, raw(h, {type = .Topen, tag = 1, fid = 2, mode = p9.OWRITE}), vx.Status.Err_Access) // a directory
	testing.expect_value(t, raw(h, {type = .Tcreate, tag = 1, fid = 2, name = "..", mode = p9.OREAD}), vx.Status.Err_Invalid)
	testing.expect_value(t, raw(h, {type = .Tcreate, tag = 1, fid = 2, name = "a/b", mode = p9.OREAD}), vx.Status.Err_Invalid)
	testing.expect_value(t, raw(h, {type = .Tcreate, tag = 1, fid = 2, name = "tab\there", mode = p9.OREAD}), vx.Status.Err_Invalid)
	held, made := 0, 0
	for f in server.fids {
		held += int(f.used)
	}
	for fid in p9.Fid(100) ..< 100 + p9.MAX_FIDS {
		if raw(h, walk_msg(1, fid)) == ok {
			made += 1
		}
	}
	testing.expect(t, held > 0)
	testing.expect_value(t, made, p9.MAX_FIDS - held) // exactly the room there was, and no more
	testing.expect_value(t, raw(h, walk_msg(1, 999)), vx.Status.Err_No_Memory)

	// Messages that are not requests, or not messages at all, end the connection.
	testing.expect_value(t, raw(h, {type = .Rclunk, tag = 1}), vx.Status.Err_Peer_Closed)
	junk := [16]u8{16, 0, 0, 0, 120, 1, 0, 1, 2, 3, 0, 0, 0, 0, 0, 0}
	_, junk_res := p9.serve(&server, junk[:], h.resp[:])
	testing.expect_value(t, junk_res, p9.Serve_Result.Hang_Up)
	testing.expect_value(t, raw(h, {type = .Twstat, tag = 1, fid = 1, stat = junk[:4]}), vx.Status.Err_Unsupported)
}

// A read or write the file system cannot do yet is deferred, without a reply,
// and the same request served again later completes.
@(test)
test_deferral :: proc(t: ^testing.T) {
	ram: Ram
	server: p9.Server
	ram_init(&ram)
	ram_server(&server, &ram)
	server.supported = {}
	req: [256]u8
	resp: [16384]u8
	n: int
	serve := proc(s: ^p9.Server, req, resp: []u8, n: ^int, m: p9.Msg) -> p9.Serve_Result {
		m := m
		n^ = p9.encode(&m, req)
		_, res := p9.serve(s, req[:n^], resp)
		return res
	}
	m: p9.Msg
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = "9P2000"}), p9.Serve_Result.Reply)
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}), p9.Serve_Result.Reply)
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Twalk, tag = 1, fid = 1, newfid = 2, nwname = 1, wname = {0 = "b.txt"}}), p9.Serve_Result.Reply)
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Topen, tag = 1, fid = 2, mode = p9.ORDWR}), p9.Serve_Result.Reply)
	ram.not_yet = true
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Tread, tag = 9, fid = 2, count = 100}), p9.Serve_Result.Defer)
	held: [256]u8
	held_len := n
	copy(held[:], req[:n])
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Twrite, tag = 10, fid = 2, data = transmute([]u8)string("zz")}), p9.Serve_Result.Defer)
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Tstat, tag = 11, fid = 2}), p9.Serve_Result.Reply) // everything else still completes
	ram.not_yet = false
	reply_len, res := p9.serve(&server, held[:held_len], resp[:])
	testing.expect_value(t, res, p9.Serve_Result.Reply)
	testing.expect_value(t, p9.decode(resp[:reply_len], &m), vx.Status.Ok)
	testing.expect_value(t, m.type, p9.Type.Rread)
	testing.expect_value(t, m.tag, 9)
	testing.expect_value(t, m.count, 5)

	// An open that must wait (a listen file) is held too, and the fid is not
	// open until it is made again and succeeds.
	ram.clone_to = 4
	ram.not_yet = true
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Twalk, tag = 1, fid = 1, newfid = 3, nwname = 2, wname = {0 = "docs", 1 = "a.txt"}}), p9.Serve_Result.Reply)
	testing.expect_value(t, serve(&server, req[:], resp[:], &n, {type = .Topen, tag = 13, fid = 3, mode = p9.OREAD}), p9.Serve_Result.Defer)
	held_len = n
	copy(held[:], req[:n])
	not_open := p9.Msg{type = .Tread, tag = 14, fid = 3, count = 10} // not open: an error, not a wait
	n = p9.encode(&not_open, req[:])
	reply_len, res = p9.serve(&server, req[:n], resp[:])
	testing.expect_value(t, res, p9.Serve_Result.Reply)
	testing.expect_value(t, p9.decode(resp[:reply_len], &m), vx.Status.Ok)
	testing.expect_value(t, m.type, p9.Type.Rerror)
	ram.not_yet = false
	reply_len, res = p9.serve(&server, held[:held_len], resp[:])
	testing.expect_value(t, res, p9.Serve_Result.Reply)
	testing.expect_value(t, p9.decode(resp[:reply_len], &m), vx.Status.Ok)
	testing.expect_value(t, m.type, p9.Type.Ropen)
	testing.expect_value(t, m.tag, 13)
	testing.expect_value(t, m.qid.path, 4)
	ram.clone_to = 0

	// An unknown fid is an error, not a wait.
	unknown := p9.Msg{type = .Tread, tag = 12, fid = 77, count = 1}
	n = p9.encode(&unknown, req[:])
	reply_len, res = p9.serve(&server, req[:n], resp[:])
	testing.expect_value(t, res, p9.Serve_Result.Reply)
	testing.expect_value(t, p9.decode(resp[:reply_len], &m), vx.Status.Ok)
	testing.expect_value(t, m.type, p9.Type.Rerror)
}

// An open may move its fid to another node (a clone file); the fid then reads,
// stats and clunks as that node, and clunk says which fids were open.
@(test)
test_open_moves :: proc(t: ^testing.T) {
	ram: Ram
	server: p9.Server
	ram_init(&ram)
	ram_server(&server, &ram)
	tbuf, rbuf: [16384]u8
	c := p9.Client{rpc = p9test.loopback, ctx = &server, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {}), vx.Status.Ok)
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)
	ram.clone_to = 4
	f, g: p9.Fid
	f, e = p9.client_walk(&c, root, "docs/a.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
	buf: [16]u8
	n: int
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, string(buf[:n]), "bravo")
	st: p9.Stat
	names: p9.Stat_Text
	testing.expect_value(t, p9.client_stat(&c, f, &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.qid.path, 4)
	g, e = p9.client_walk(&c, root, "b.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_clunk(&c, g), vx.Status.Ok)
	testing.expect_value(t, len(ram.opened_clunks), 0) // never opened
	testing.expect_value(t, p9.client_clunk(&c, f), vx.Status.Ok)
	testing.expect_value(t, len(ram.opened_clunks), 1)
	testing.expect_value(t, ram.opened_clunks[0], 4)
}

// Tshare and Tjoin (posix): a token joins as many times as its holds; once
// they are used or run out, it joins no more, and the next Tshare gives a new
// token, so whoever kept the old one cannot come back with it.
@(private="file")
share_clock: i64 // only test_share_tokens reads it

@(private="file")
share_now :: proc "contextless" () -> i64 {
	return share_clock
}

@(test)
test_share_tokens :: proc(t: ^testing.T) {
	ram: Ram
	server: p9.Server
	ram_init(&ram)
	ram_server(&server, &ram)
	sh := new(p9.Shared, context.temp_allocator)
	sh.now = share_now
	drbg.mix(&sh.random, transmute([]u8)string("seed"), true)
	server.supported, server.shared = {.Posix}, sh
	tbuf, rbuf: [16384]u8
	c := p9.Client{rpc = p9test.loopback, ctx = &server, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {.Posix}), vx.Status.Ok)
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)
	f, g: p9.Fid
	f, e = p9.client_walk(&c, root, "b.txt")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)

	first, second, third, again: [p9.TOKEN_SIZE]u8
	first, e = p9.client_share(&c, f, 1)
	testing.expect_value(t, e, vx.Status.Ok)
	g, e = p9.client_join(&c, first)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_clunk(&c, g), vx.Status.Ok)
	_, e = p9.client_join(&c, first)
	testing.expect_value(t, e, vx.Status.Err_Not_Found) // its one hold used

	second, e = p9.client_share(&c, f, 1)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect(t, first != second, "a new token")
	_, e = p9.client_join(&c, first)
	testing.expect_value(t, e, vx.Status.Err_Not_Found) // the old one is no good

	share_clock += p9.HOLD_TIME // second's hold runs out unused
	_, e = p9.client_join(&c, second)
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	third, e = p9.client_share(&c, f, 2)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect(t, second != third, "a new token once the holds ran out")
	_, e = p9.client_join(&c, second)
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	g, e = p9.client_join(&c, third)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, p9.client_clunk(&c, g), vx.Status.Ok)
	// Holds outstanding: a Tshare adds to them, and keeps the token.
	again, e = p9.client_share(&c, f, 1)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect(t, third == again, "the same token while holds are outstanding")
	testing.expect_value(t, p9.client_clunk(&c, f), vx.Status.Ok)
}
