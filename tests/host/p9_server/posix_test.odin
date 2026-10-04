// lib/p9's posix and xattr extensions (upstream M4 steps 4a and 4b, docs/
// proto/posix.md): open files the server keeps, with their offsets and
// O_APPEND, shared between connections by token; POSIX byte-range locks;
// Tgetattr, Tsetattr, Trenameat, Tsymlink and Treadlink. Upstream tests them
// only through its POSIX scenarios, so this suite is checked against
// upstream's server instead: a script of requests on three connections to
// one server (two with posix and xattr, one without), and every reply must be
// the bytes upstream's p9_serve gives for the same requests on the same file
// system (upstream.txt, from a harness built with clang against M4's
// server.c: the P4 cross-check). Build with -define:P9_POSIX_DUMP=PATH to
// write the script's requests for that harness.
//
//   /     (node 1)
//   /f    (node 2)  "0123456789"
//   /g    (node 3)  "ab"
//   /d/   (node 4)
package p9_server_test

import vx "abi:vx"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "vx:drbg"
import "vx:p9"

P9_POSIX_DUMP :: #config(P9_POSIX_DUMP, "")

Px_Node :: struct {
	parent: p9.Node,
	name:   [dynamic; 16]u8,
	dir:    bool,
	link:   bool,
	perm:   u32,
	data:   [64]u8,
	len:    u32,
}

Px :: struct {
	nodes:     [16]Px_Node,
	count:     p9.Node,
	joins:     int, // opens fs.open was told were a Tjoin's
	now:       i64,
}

// The clock the shared table reads: the one Px under test (one test uses it).
px_clock: ^Px

px_now :: proc "contextless" () -> i64 {
	return px_clock.now
}

px_add :: proc(x: ^Px, parent: p9.Node, name: string, dir: bool, data: string) {
	n := &x.nodes[x.count]
	n^ = {parent = parent, dir = dir, perm = dir ? 0o755 : 0o644, len = u32(len(data))}
	_ = append(&n.name, name)
	copy(n.data[:], data)
	x.count += 1
}

px_init :: proc(x: ^Px) {
	x^ = {count = 1, now = 1_000_000_000}
	px_add(x, 0, "/", true, "")
	px_add(x, 1, "f", false, "0123456789")
	px_add(x, 1, "g", false, "ab")
	px_add(x, 1, "d", true, "")
}

px_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	return aname == "" ? 1 : 0, aname == "" ? .Ok : .Err_Not_Found
}

px_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	x := (^Px)(ctx)
	for i in 1 ..< x.count {
		if x.nodes[i].parent == dir && string(x.nodes[i].name[:]) == name {
			return i, .Ok
		}
	}
	return 0, .Err_Not_Found
}

px_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	x := (^Px)(ctx)
	if x.nodes[node].parent == 0 {
		return 0, .Err_Not_Found
	}
	return x.nodes[node].parent, .Ok
}

px_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	x := (^Px)(ctx)
	if node == 0 || node >= x.count {
		return .Err_Not_Found
	}
	n := &x.nodes[node]
	mode := n.perm
	if n.dir {
		mode |= p9.DMDIR
	} else if n.link {
		mode |= p9.DMSYMLINK
	}
	out^ = {
		qid = {n.dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = mode,
		atime = 7,
		mtime = 9,
		length = n.dir ? 0 : u64(n.len),
		name = string(n.name[:]),
		uid = "u",
		gid = "u",
		muid = "",
	}
	return .Ok
}

px_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	x := (^Px)(ctx)
	if mode.join {
		x.joins += 1
	}
	if mode.trunc {
		x.nodes[node].len = 0
	}
	return .Ok
}

px_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	n := &(^Px)(ctx).nodes[node]
	if offset >= u64(n.len) {
		return 0, .Ok
	}
	return u32(copy(buf, n.data[offset:n.len])), .Ok
}

px_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	x := (^Px)(ctx)
	k := index
	for i in 2 ..< x.count {
		if x.nodes[i].parent != dir {
			continue
		}
		if k == 0 {
			return i, .Ok
		}
		k -= 1
	}
	return 0, .Err_Not_Found
}

px_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	n := &(^Px)(ctx).nodes[node]
	if offset >= len(n.data) {
		return 0, .Err_Range
	}
	count = u32(copy(n.data[offset:], data))
	n.len = max(n.len, u32(offset) + count)
	return count, .Ok
}

px_create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	x := (^Px)(ctx)
	if _, e := px_walk(ctx, dir, name); e == .Ok {
		return 0, .Err_Exists
	}
	if x.count == len(x.nodes) || len(name) > 16 {
		return 0, .Err_No_Memory
	}
	n := &x.nodes[x.count]
	n^ = {parent = dir, dir = perm & p9.DMDIR != 0, perm = perm & 0o777}
	_ = append(&n.name, name)
	x.count += 1
	return x.count - 1, .Ok
}

px_setattr :: proc "contextless" (ctx: rawptr, node: p9.Node, a: ^p9.Setattr) -> vx.Status {
	n := &(^Px)(ctx).nodes[node]
	if .Mode in a.valid {
		n.perm = a.mode & 0o777
	}
	if .Size in a.valid {
		n.len = u32(min(a.size, len(n.data)))
	}
	return .Ok
}

px_rename :: proc "contextless" (ctx: rawptr, olddir: p9.Node, oldname: string, newdir: p9.Node, newname: string) -> vx.Status {
	x := (^Px)(ctx)
	node := px_walk(ctx, olddir, oldname) or_return
	if _, e := px_walk(ctx, newdir, newname); e == .Ok {
		return .Err_Exists
	}
	if len(newname) > 16 {
		return .Err_No_Memory
	}
	n := &x.nodes[node]
	n.parent = newdir
	clear(&n.name)
	_ = append(&n.name, newname)
	return .Ok
}

px_symlink :: proc "contextless" (ctx: rawptr, dir: p9.Node, name, target: string) -> (node: p9.Node, st: vx.Status) {
	x := (^Px)(ctx)
	node = px_create(ctx, dir, name, 0o777, p9.OREAD) or_return
	n := &x.nodes[node]
	n.link = true
	n.len = u32(copy(n.data[:], target))
	return node, .Ok
}

px_readlink :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (target: string, st: vx.Status) {
	n := &(^Px)(ctx).nodes[node]
	if !n.link {
		return "", .Err_Invalid
	}
	return string(n.data[:n.len]), .Ok
}

px_fs :: proc(x: ^Px) -> p9.Fs {
	return {
		ctx = x,
		attach = px_attach,
		walk = px_walk,
		parent = px_parent,
		stat = px_stat,
		open = px_open,
		read = px_read,
		readdir = px_readdir,
		write = px_write,
		create = px_create,
		setattr = px_setattr,
		rename = px_rename,
		symlink = px_symlink,
		readlink = px_readlink,
	}
}

// One step of the script: a request on a connection, or the clock moving on.
Step :: struct {
	conn:    int, // 1, 2 or 3
	msg:     p9.Msg,
	advance: i64, // with conn 0: nanoseconds the clock moves on
}

POSIX :: "9P2000.x/1 +posix +xattr"
TOKEN_SLOT :: 99 // a Tjoin with this token's first byte joins with the last token a Tshare gave

script :: proc() -> []Step {
	w :: proc(fid, newfid: p9.Fid, names: ..string) -> p9.Msg {
		return walk_msg(fid, newfid, ..names)
	}
	rdwr_append := p9.ORDWR
	rdwr_append.append = true
	steps := [?]Step {
		{conn = 1, msg = {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = POSIX}},
		{conn = 2, msg = {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = POSIX}},
		{conn = 3, msg = {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = "9P2000.x/1"}},
		{conn = 1, msg = {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}},
		{conn = 2, msg = {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}},
		{conn = 3, msg = {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}},
		// The open file's own offset: reads and writes at OFFSET_CURRENT move it.
		{conn = 1, msg = w(1, 2, "f")},
		{conn = 1, msg = {type = .Topen, tag = 2, fid = 2, mode = p9.ORDWR}},
		{conn = 1, msg = {type = .Tread, tag = 3, fid = 2, offset = p9.OFFSET_CURRENT, count = 4}},
		{conn = 1, msg = {type = .Twrite, tag = 4, fid = 2, offset = p9.OFFSET_CURRENT, data = transmute([]u8)string("AB")}},
		{conn = 1, msg = {type = .Tread, tag = 5, fid = 2, offset = p9.OFFSET_CURRENT, count = 100}},
		{conn = 1, msg = {type = .Tread, tag = 6, fid = 2, offset = 1, count = 3}}, // an explicit offset leaves it
		// Tseek: set, current, end; before the start, or an unknown whence, is refused.
		{conn = 1, msg = {type = .Tseek, tag = 7, fid = 2, offset = 2, whence = .Set}},
		{conn = 1, msg = {type = .Tseek, tag = 8, fid = 2, offset = transmute(u64)i64(-1), whence = .Current}},
		{conn = 1, msg = {type = .Tseek, tag = 9, fid = 2, offset = 3, whence = .End}},
		{conn = 1, msg = {type = .Tseek, tag = 10, fid = 2, offset = transmute(u64)i64(-20), whence = .End}},
		{conn = 1, msg = {type = .Tseek, tag = 11, fid = 2, offset = 0, whence = p9.Whence(3)}},
		{conn = 1, msg = {type = .Tseek, tag = 12, fid = 1, offset = 0, whence = .Set}}, // not open
		// Tdesc's append: writes at OFFSET_CURRENT go to the end, wherever the offset is.
		{conn = 1, msg = {type = .Tdesc, tag = 13, fid = 2, desc_flags = {.Append}}},
		{conn = 1, msg = {type = .Tseek, tag = 14, fid = 2, offset = 0, whence = .Set}},
		{conn = 1, msg = {type = .Twrite, tag = 15, fid = 2, offset = p9.OFFSET_CURRENT, data = transmute([]u8)string("XY")}},
		{conn = 1, msg = {type = .Tseek, tag = 16, fid = 2, offset = 0, whence = .Current}},
		{conn = 1, msg = {type = .Twrite, tag = 17, fid = 2, offset = 0, data = transmute([]u8)string("z")}}, // an explicit offset is not appended
		{conn = 1, msg = {type = .Tdesc, tag = 18, fid = 2, desc_flags = {}}},
		// Tshare: a token for joins; too many holds is refused.
		{conn = 1, msg = {type = .Tshare, tag = 19, fid = 2, holds = 0}},
		{conn = 1, msg = {type = .Tshare, tag = 20, fid = 2, holds = 65}},
		{conn = 1, msg = {type = .Tshare, tag = 21, fid = 2, holds = 2}},
		{conn = 1, msg = {type = .Tshare, tag = 22, fid = 2, holds = 63}},
		{conn = 1, msg = {type = .Tshare, tag = 23, fid = 1, holds = 1}}, // not open
		// Tjoin on another connection: the same open file, offset and all.
		{conn = 2, msg = {type = .Tjoin, tag = 1, newfid = 5, token = {0 = TOKEN_SLOT}}},
		{conn = 2, msg = {type = .Tread, tag = 2, fid = 5, offset = p9.OFFSET_CURRENT, count = 3}},
		{conn = 1, msg = {type = .Tread, tag = 24, fid = 2, offset = p9.OFFSET_CURRENT, count = 3}},
		{conn = 2, msg = {type = .Tjoin, tag = 3, newfid = 6, token = {0 = 1}}}, // a token never given
		{conn = 2, msg = {type = .Tjoin, tag = 4, newfid = 6, token = {0 = TOKEN_SLOT}}},
		{conn = 2, msg = {type = .Tjoin, tag = 5, newfid = 7, token = {0 = TOKEN_SLOT}}}, // the holds are used up
		{conn = 3, msg = {type = .Tjoin, tag = 1, newfid = 7, token = {0 = TOKEN_SLOT}}}, // no posix on this one
		// Locks: write against read, a split by unlocking the middle, and let
		// go when the owner closes any fid on the file.
		{conn = 1, msg = {type = .Tlock, tag = 25, fid = 2, lock_type = .Write, start = 0, length = 10, proc_id = 1}},
		{conn = 2, msg = {type = .Tlock, tag = 6, fid = 5, lock_type = .Read, start = 5, length = 5, proc_id = 2}},
		{conn = 2, msg = {type = .Tgetlock, tag = 7, fid = 5, lock_type = .Write, start = 0, length = 0, proc_id = 2}},
		{conn = 1, msg = {type = .Tlock, tag = 26, fid = 2, lock_type = .Unlock, start = 2, length = 3, proc_id = 1}},
		{conn = 2, msg = {type = .Tgetlock, tag = 8, fid = 5, lock_type = .Write, start = 2, length = 3, proc_id = 2}},
		{conn = 2, msg = {type = .Tgetlock, tag = 9, fid = 5, lock_type = .Read, start = 4, length = 0, proc_id = 2}},
		{conn = 1, msg = {type = .Tlock, tag = 27, fid = 2, lock_type = .Read, start = 0, length = 0, proc_id = 1}}, // its own: replaced
		{conn = 2, msg = {type = .Tlock, tag = 10, fid = 5, lock_type = .Read, start = 0, length = 0, proc_id = 2}},
		{conn = 2, msg = {type = .Tlock, tag = 11, fid = 5, lock_type = .Write, start = 0, length = 1, proc_id = 2}},
		{conn = 2, msg = {type = .Tlock, tag = 12, fid = 5, lock_type = p9.Lock_Type(3), start = 0, length = 1, proc_id = 2}},
		{conn = 2, msg = {type = .Tlock, tag = 13, fid = 5, lock_type = .Read, start = 10, length = max(u64), proc_id = 2}},
		{conn = 1, msg = {type = .Tclunk, tag = 28, fid = 2}},
		{conn = 2, msg = {type = .Tlock, tag = 14, fid = 5, lock_type = .Write, start = 0, length = 0, proc_id = 2}},
		{conn = 1, msg = w(1, 3, "g")},
		{conn = 1, msg = {type = .Topen, tag = 29, fid = 3, mode = p9.OREAD}},
		{conn = 1, msg = {type = .Tlock, tag = 30, fid = 3, lock_type = .Write, start = 0, length = 0, proc_id = 1}}, // opened for reading
		{conn = 1, msg = {type = .Tlock, tag = 31, fid = 1, lock_type = .Read, start = 0, length = 0, proc_id = 1}}, // not open
		// Holds run out: a token not used within the hold time joins nothing.
		{conn = 1, msg = {type = .Tshare, tag = 32, fid = 3, holds = 1}},
		{advance = 11_000_000_000},
		{conn = 2, msg = {type = .Tjoin, tag = 15, newfid = 8, token = {0 = TOKEN_SLOT}}},
		{conn = 1, msg = {type = .Tclunk, tag = 33, fid = 3}},
		// An open with OAPPEND appends from the start.
		{conn = 1, msg = w(1, 4, "g")},
		{conn = 1, msg = {type = .Topen, tag = 34, fid = 4, mode = rdwr_append}},
		{conn = 1, msg = {type = .Twrite, tag = 35, fid = 4, offset = p9.OFFSET_CURRENT, data = transmute([]u8)string("cd")}},
		{conn = 1, msg = {type = .Tread, tag = 36, fid = 4, offset = 0, count = 10}},
		{conn = 3, msg = w(1, 4, "g")},
		{conn = 3, msg = {type = .Topen, tag = 2, fid = 4, mode = p9.OREAD}},
		{conn = 3, msg = {type = .Tread, tag = 3, fid = 4, offset = p9.OFFSET_CURRENT, count = 10}}, // no open file keeps one
		// Tgetattr and Tsetattr (xattr).
		{conn = 1, msg = {type = .Tgetattr, tag = 37, fid = 1, mask = p9.GETATTR_BASIC}},
		{conn = 1, msg = {type = .Tgetattr, tag = 38, fid = 4, mask = p9.GETATTR_BASIC}},
		{conn = 1, msg = {type = .Tsetattr, tag = 39, fid = 4, setattr = {valid = {.Mode, .Size}, mode = 0o600, size = 1}}},
		{conn = 1, msg = {type = .Tgetattr, tag = 40, fid = 4, mask = p9.GETATTR_BASIC}},
		{conn = 3, msg = {type = .Tgetattr, tag = 4, fid = 1, mask = p9.GETATTR_BASIC}},
		// Trenameat, Tsymlink, Treadlink, Tfsync, Tlink.
		{conn = 1, msg = w(1, 5, "d")},
		{conn = 1, msg = {type = .Trenameat, tag = 41, fid = 1, name = "g", newfid = 5, name2 = "h"}},
		{conn = 1, msg = w(1, 6, "d", "h")},
		{conn = 1, msg = {type = .Trenameat, tag = 42, fid = 1, name = "f", newfid = 5, name2 = ".."}},
		{conn = 1, msg = {type = .Trenameat, tag = 43, fid = 1, name = "f", newfid = 6, name2 = "x"}}, // not a directory
		{conn = 1, msg = {type = .Trenameat, tag = 44, fid = 1, name = "nope", newfid = 5, name2 = "x"}},
		{conn = 1, msg = {type = .Tsymlink, tag = 45, fid = 1, name = "l", name2 = "d/h", gid = 0}},
		{conn = 1, msg = {type = .Tsymlink, tag = 46, fid = 1, name = "a\nb", name2 = "x"}},
		{conn = 1, msg = w(1, 7, "l")},
		{conn = 1, msg = {type = .Treadlink, tag = 47, fid = 7}},
		{conn = 1, msg = {type = .Tgetattr, tag = 48, fid = 7, mask = p9.GETATTR_BASIC}},
		{conn = 1, msg = {type = .Treadlink, tag = 49, fid = 6}},
		{conn = 1, msg = {type = .Tfsync, tag = 50, fid = 6}},
		{conn = 1, msg = {type = .Tlink, tag = 51, fid = 1, newfid = 6, name = "k"}},
		{conn = 3, msg = {type = .Tfsync, tag = 5, fid = 1}},
		{conn = 1, msg = {type = .Tgetattr, tag = 52, fid = 77, mask = p9.GETATTR_BASIC}},
	}
	return slice_clone(steps[:])
}

slice_clone :: proc(s: []Step) -> []Step {
	out := make([]Step, len(s), context.temp_allocator)
	copy(out, s)
	return out
}

@(test)
test_posix :: proc(t: ^testing.T) {
	x := new(Px, context.temp_allocator)
	px_init(x)
	px_clock = x
	defer px_clock = nil
	shared := new(p9.Shared, context.temp_allocator)
	shared.now = px_now
	drbg.mix(&shared.random, transmute([]u8)string("a seed of twenty bytes"), true)
	servers := new([4]p9.Server, context.temp_allocator)
	for &s in servers[1:] {
		s = {fs = px_fs(x), max_msize = 8192, supported = {.Posix, .Xattr}, shared = shared}
	}
	b := strings.builder_make(context.temp_allocator)
	dump := strings.builder_make(context.temp_allocator)
	req, resp: [8192]u8
	m: p9.Msg
	token: [p9.TOKEN_SIZE]u8
	for &step in script() {
		if step.conn == 0 {
			x.now += step.advance
			fmt.sbprintf(&b, "advance %d\n", step.advance)
			fmt.sbprintf(&dump, "advance %d\n", step.advance)
			continue
		}
		if step.msg.type == .Tjoin && step.msg.token[0] == TOKEN_SLOT {
			step.msg.token = token
		}
		n := p9.encode(&step.msg, req[:])
		if !testing.expectf(t, n > 0, "a %v does not encode", step.msg.type) {
			return
		}
		fmt.sbprintf(&dump, "%d %s\n", step.conn, hex.encode(req[:n], context.temp_allocator))
		reply_len, res := p9.serve(&servers[step.conn], req[:n], resp[:])
		fmt.sbprintf(&b, "%d > %s\n", step.conn, hex.encode(req[:n], context.temp_allocator))
		fmt.sbprintf(&b, "%d < %s\n", step.conn, res == .Reply ? string(hex.encode(resp[:reply_len], context.temp_allocator)) : fmt.tprint(res))
		if res == .Reply && p9.decode(resp[:reply_len], &m) == .Ok && m.type == .Rshare {
			token = m.token
		}
	}
	if P9_POSIX_DUMP != "" {
		_ = os.write_entire_file(P9_POSIX_DUMP, transmute([]u8)strings.to_string(dump))
	}
	got, want := strings.to_string(b), #load("upstream.txt", string)
	line := 0
	for {
		gl, gok := strings.split_lines_iterator(&got)
		wl, wok := strings.split_lines_iterator(&want)
		line += 1
		if !gok && !wok {
			break
		}
		if !testing.expectf(t, gl == wl, "line %d: got %q, upstream has %q", line, gl, wl) {
			break
		}
	}
	// Each join opened the file again, with fs.open told so.
	testing.expect_value(t, x.joins, 2)
}
