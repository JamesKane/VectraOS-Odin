// lib/p9's M5 additions to the server: the map and dref extensions (upstream
// docs/proto/map.md, dref.md), fs.attach_as and fs.fsync. Not upstream's:
// upstream tests them only through its scenarios, so, as for posix_test,
// this suite is checked against upstream's server: a script of requests on
// three connections (one with posix, map and dref, one with map and dref
// only, one with none of them) to posix_test's file system, with map,
// read_ref, write_ref, attach_as and fsync added, and every reply, every
// call the framework makes into the file server, and every handle a reply
// carries must be what upstream's p9_serve gives for the same requests
// (map_upstream.txt, from a harness built with clang against M5's server.c).
// Build with -define:P9_MAP_DUMP=PATH to write the script's requests for
// that harness.
package p9_server_test

import vx "abi:vx"
import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "vx:p9"

P9_MAP_DUMP :: #config(P9_MAP_DUMP, "")

// The handle the transport would have taken from a request's slot.
REQUEST_VMO :: vx.Handle(0x55)

// What the file server was asked, written as the harness writes it.
@(private="file")
calls: strings.Builder

@(private="file")
mx_attach_as :: proc "contextless" (ctx: rawptr, aname, uname: string) -> (root: p9.Node, st: vx.Status) {
	context = runtime.default_context()
	fmt.sbprintf(&calls, "fs attach_as aname=[%s] uname=[%s]\n", aname, uname)
	return px_attach(ctx, aname)
}

@(private="file")
mx_fsync :: proc "contextless" (ctx: rawptr, node: p9.Node) -> vx.Status {
	context = runtime.default_context()
	fmt.sbprintf(&calls, "fs fsync %d\n", node)
	return node == 3 ? .Err_Io : .Ok
}

@(private="file")
mx_map :: proc "contextless" (ctx: rawptr, node: p9.Node, offset, length: u64, prot: p9.Prot) -> (m: p9.Mapped, st: vx.Status) {
	context = runtime.default_context()
	fmt.sbprintf(&calls, "fs map %d %d %d %d\n", node, offset, length, transmute(u32)prot)
	if offset >= 1 << 20 {
		return {}, .Err_Range
	}
	size := u64((^Px)(ctx).nodes[node].len)
	m = {vmo = vx.Handle(0x100 + u32(node)), vmo_offset = offset & 4095}
	if offset < size {
		m.avail = min(length, size - offset)
	}
	return m, .Ok
}

@(private="file")
mx_read_ref :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status) {
	context = runtime.default_context()
	fmt.sbprintf(&calls, "fs read_ref %d %d %d %d %d\n", node, offset, u32(vmo), roffset, count)
	size := u64((^Px)(ctx).nodes[node].len)
	return offset < size ? u32(min(u64(count), size - offset)) : 0, .Ok
}

@(private="file")
mx_write_ref :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status) {
	context = runtime.default_context()
	fmt.sbprintf(&calls, "fs write_ref %d %d %d %d %d\n", node, offset, u32(vmo), roffset, count)
	n := &(^Px)(ctx).nodes[node]
	if offset >= len(n.data) {
		return 0, .Err_No_Space
	}
	done = u32(min(u64(count), len(n.data) - offset))
	n.len = max(n.len, u32(offset) + done)
	return done, .Ok
}

// One step: a request on a connection, carrying a VMO or not.
Map_Step :: struct {
	conn: int, // 1, 2 or 3
	msg:  p9.Msg,
	vmo:  bool, // the transport took a handle with it
}

map_script :: proc() -> []Map_Step {
	w :: proc(fid, newfid: p9.Fid, names: ..string) -> p9.Msg {
		return walk_msg(fid, newfid, ..names)
	}
	rdwr_append := p9.ORDWR
	rdwr_append.append = true
	bad_prot := transmute(p9.Prot)u32(8)
	steps := [?]Map_Step {
		{conn = 1, msg = {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = "9P2000.x/1 +dref +map +xattr +posix"}},
		{conn = 2, msg = {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = "9P2000.x/1 +dref +map"}},
		{conn = 3, msg = {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = "9P2000.x/1 +posix"}},
		// attach_as is told who attaches, in place of attach.
		{conn = 1, msg = {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID, uname = "glenda"}},
		{conn = 2, msg = {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID, uname = "none"}},
		{conn = 3, msg = {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID, uname = ""}},
		{conn = 3, msg = {type = .Tattach, tag = 2, fid = 2, afid = p9.NOFID, uname = "x", aname = "nope"}},
		// Tmap: only on an open fid, read for any mapping, read-write for a
		// writing one; never write and exec; a length; no overflow.
		{conn = 1, msg = w(1, 2, "f")},
		{conn = 1, msg = {type = .Tmap, tag = 2, fid = 2, offset = 0, length = 4096, prot = {.Read}}}, // not open
		{conn = 1, msg = {type = .Topen, tag = 3, fid = 2, mode = p9.OREAD}},
		{conn = 1, msg = {type = .Tmap, tag = 4, fid = 2, offset = 0, length = 4096, prot = {.Read}}},
		{conn = 1, msg = {type = .Tmap, tag = 5, fid = 2, offset = 4, length = 4, prot = {.Read, .Exec}}},
		{conn = 1, msg = {type = .Tmap, tag = 6, fid = 2, offset = 0, length = 4096, prot = {.Read, .Write}}}, // OREAD
		{conn = 1, msg = {type = .Tmap, tag = 7, fid = 2, offset = 0, length = 0, prot = {.Read}}},
		{conn = 1, msg = {type = .Tmap, tag = 8, fid = 2, offset = 0, length = 1, prot = bad_prot}},
		{conn = 1, msg = {type = .Tmap, tag = 9, fid = 2, offset = max(u64), length = 2, prot = {.Read}}},
		{conn = 1, msg = {type = .Tmap, tag = 10, fid = 2, offset = 1 << 20, length = 2, prot = {.Read}}}, // the file server's error: no handle
		{conn = 1, msg = {type = .Tmap, tag = 11, fid = 2, offset = 20, length = 4096, prot = {.Read}}}, // past the end
		{conn = 1, msg = {type = .Tmap, tag = 12, fid = 9, offset = 0, length = 1, prot = {.Read}}},
		{conn = 1, msg = {type = .Tmap, tag = 13, fid = 1, offset = 0, length = 1, prot = {.Read}}}, // a directory, not open
		{conn = 1, msg = w(1, 6)},
		{conn = 1, msg = {type = .Topen, tag = 14, fid = 6, mode = p9.OREAD}},
		{conn = 1, msg = {type = .Tmap, tag = 15, fid = 6, offset = 0, length = 1, prot = {.Read}}}, // a directory
		{conn = 1, msg = w(1, 3, "g")},
		{conn = 1, msg = {type = .Topen, tag = 16, fid = 3, mode = p9.ORDWR}},
		{conn = 1, msg = {type = .Tmap, tag = 17, fid = 3, offset = 0, length = 8192, prot = {.Read, .Write}}},
		{conn = 1, msg = {type = .Tmap, tag = 18, fid = 3, offset = 0, length = 8192, prot = {.Write, .Exec}}},
		{conn = 1, msg = {type = .Tmap, tag = 19, fid = 3, offset = 0, length = 8192, prot = {.Write}}},
		{conn = 1, msg = w(1, 4, "g")},
		{conn = 1, msg = {type = .Topen, tag = 20, fid = 4, mode = p9.OWRITE}},
		{conn = 1, msg = {type = .Tmap, tag = 21, fid = 4, offset = 0, length = 1, prot = {.Read}}}, // OWRITE
		// Treadref and Twriteref: a VMO must come with them; the fid's mode
		// as Tread and Twrite; the open file's offset and appending.
		{conn = 1, msg = {type = .Treadref, tag = 22, fid = 2, offset = 3, count = 5, roffset = 4096}},
		{conn = 1, msg = {type = .Treadref, tag = 23, fid = 2, offset = 3, count = 5, roffset = 4096}, vmo = true},
		{conn = 1, msg = {type = .Treadref, tag = 24, fid = 2, offset = 8, count = 100, roffset = 0}, vmo = true},
		{conn = 1, msg = {type = .Treadref, tag = 25, fid = 2, offset = p9.OFFSET_CURRENT, count = 4, roffset = 0}, vmo = true},
		{conn = 1, msg = {type = .Treadref, tag = 26, fid = 2, offset = p9.OFFSET_CURRENT, count = 4, roffset = 0}, vmo = true},
		{conn = 1, msg = {type = .Twriteref, tag = 27, fid = 2, offset = 0, count = 4, roffset = 0}, vmo = true}, // OREAD
		{conn = 1, msg = {type = .Twriteref, tag = 28, fid = 4, offset = 1, count = 3, roffset = 8}, vmo = true},
		{conn = 1, msg = {type = .Treadref, tag = 29, fid = 4, offset = 0, count = 3, roffset = 8}, vmo = true}, // OWRITE
		{conn = 1, msg = {type = .Twriteref, tag = 30, fid = 4, offset = 100, count = 3, roffset = 8}, vmo = true}, // the file server's error
		{conn = 1, msg = {type = .Treadref, tag = 31, fid = 6, offset = 0, count = 3, roffset = 0}, vmo = true}, // a directory
		{conn = 1, msg = {type = .Treadref, tag = 32, fid = 7, offset = 0, count = 3, roffset = 0}, vmo = true},
		{conn = 1, msg = w(1, 5, "f")},
		{conn = 1, msg = {type = .Topen, tag = 33, fid = 5, mode = rdwr_append}},
		{conn = 1, msg = {type = .Twriteref, tag = 34, fid = 5, offset = p9.OFFSET_CURRENT, count = 2, roffset = 0}, vmo = true},
		{conn = 1, msg = {type = .Twriteref, tag = 35, fid = 5, offset = p9.OFFSET_CURRENT, count = 2, roffset = 0}, vmo = true},
		{conn = 1, msg = {type = .Twriteref, tag = 36, fid = 5, offset = 0, count = 1, roffset = 0}, vmo = true},
		// Tfsync: the file server's, when it has one.
		{conn = 1, msg = {type = .Tfsync, tag = 37, fid = 5}},
		{conn = 1, msg = {type = .Tfsync, tag = 38, fid = 3}},
		// Without posix, no open file keeps an offset.
		{conn = 2, msg = w(1, 2, "f")},
		{conn = 2, msg = {type = .Topen, tag = 2, fid = 2, mode = p9.ORDWR}},
		{conn = 2, msg = {type = .Treadref, tag = 3, fid = 2, offset = p9.OFFSET_CURRENT, count = 4, roffset = 0}, vmo = true},
		{conn = 2, msg = {type = .Treadref, tag = 4, fid = 2, offset = 2, count = 4, roffset = 0}, vmo = true},
		{conn = 2, msg = {type = .Tmap, tag = 5, fid = 2, offset = 0, length = 1, prot = {.Read, .Write}}},
		// Without map and dref, their messages are refused.
		{conn = 3, msg = w(1, 2, "f")},
		{conn = 3, msg = {type = .Topen, tag = 3, fid = 2, mode = p9.ORDWR}},
		{conn = 3, msg = {type = .Tmap, tag = 4, fid = 2, offset = 0, length = 1, prot = {.Read}}},
		{conn = 3, msg = {type = .Treadref, tag = 5, fid = 2, offset = 0, count = 1, roffset = 0}, vmo = true},
		{conn = 3, msg = {type = .Twriteref, tag = 6, fid = 2, offset = 0, count = 1, roffset = 0}, vmo = true},
		{conn = 3, msg = {type = .Tfsync, tag = 7, fid = 2}},
	}
	out := make([]Map_Step, len(steps), context.temp_allocator)
	copy(out, steps[:])
	return out
}

@(test)
test_map_dref :: proc(t: ^testing.T) {
	x := new(Px, context.temp_allocator)
	px_init(x)
	shared := new(p9.Shared, context.temp_allocator)
	fs := px_fs(x)
	fs.attach_as = mx_attach_as
	fs.fsync = mx_fsync
	fs.map_range = mx_map
	fs.read_ref = mx_read_ref
	fs.write_ref = mx_write_ref
	servers := new([4]p9.Server, context.temp_allocator)
	for &s in servers[1:] {
		s = {fs = fs, max_msize = 8192, supported = {.Posix, .Xattr, .Map, .Dref}, shared = shared}
	}
	calls = strings.builder_make(context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	dump := strings.builder_make(context.temp_allocator)
	req, resp: [8192]u8
	for &step in map_script() {
		n := p9.encode(&step.msg, req[:])
		if !testing.expectf(t, n > 0, "a %v does not encode", step.msg.type) {
			return
		}
		h := hex.encode(req[:n], context.temp_allocator)
		fmt.sbprintf(&dump, "%d %s %s\n", step.conn, step.vmo ? "H" : "-", h)
		s := &servers[step.conn]
		s.request_handle = step.vmo ? REQUEST_VMO : vx.HANDLE_NONE
		strings.builder_reset(&calls)
		reply_len, res := p9.serve(s, req[:n], resp[:])
		fmt.sbprintf(&b, "%d > %s %s\n", step.conn, step.vmo ? "H" : "-", h)
		strings.write_string(&b, strings.to_string(calls))
		fmt.sbprintf(&b, "%d < %s", step.conn, res == .Reply ? string(hex.encode(resp[:reply_len], context.temp_allocator)) : fmt.tprint(res))
		if s.reply_handle != vx.HANDLE_NONE {
			fmt.sbprintf(&b, " handle=%d", u32(s.reply_handle))
		}
		strings.write_string(&b, "\n")
		s.reply_handle, s.request_handle = vx.HANDLE_NONE, vx.HANDLE_NONE // the transport's
	}
	if P9_MAP_DUMP != "" {
		_ = os.write_entire_file(P9_MAP_DUMP, transmute([]u8)strings.to_string(dump))
	}
	got, want := strings.to_string(b), #load("map_upstream.txt", string)
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
}
