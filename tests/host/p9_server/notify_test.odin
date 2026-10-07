// notify (upstream's docs/proto/notify.md, its M6 step 6e1d), ported from
// upstream's test_notify: a watcher and a writer, two connections over one
// Shared. The watcher's Tnotify is held while nothing is queued; the
// writer's create, write, rename and remove are queued for it in order; a
// file's own watch; a mask that leaves events out; an overflow's LOST; the
// watch gone with its fid.
package p9_server_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:p9"

// One connection's buffers, and the last reply decoded.
Notify_Bench :: struct {
	req:  [512]u8,
	resp: [16384]u8,
	rep:  p9.Msg,
}

// Serves m on s: .Reply with the reply in b.rep, .Defer, or .Hang_Up (for a
// request that would not encode or a reply that would not decode too).
on :: proc(b: ^Notify_Bench, s: ^p9.Server, m: p9.Msg) -> p9.Serve_Result {
	m := m
	n := p9.encode(&m, b.req[:])
	if n == 0 {
		return .Hang_Up
	}
	reply_len, res := p9.serve(s, b.req[:n], b.resp[:])
	if res == .Reply && p9.decode(b.resp[:reply_len], &b.rep) != .Ok {
		return .Hang_Up
	}
	return res
}

// The events in b.rep's data, as "kind:name kind:name ...".
events :: proc(b: ^Notify_Bench) -> string {
	sb := strings.builder_make(context.temp_allocator)
	it := p9.Notify_Events{buf = b.rep.data}
	for kind, name in p9.next_event(&it) {
		if strings.builder_len(sb) > 0 {
			strings.write_byte(&sb, ' ')
		}
		fmt.sbprintf(&sb, "%d:%s", kind, name)
	}
	return strings.to_string(sb)
}

@(test)
test_notify :: proc(t: ^testing.T) {
	ram: Ram
	watcher, writer, plain: p9.Server
	ram_init(&ram)
	ram_server(&watcher, &ram)
	sh := new(p9.Shared, context.temp_allocator)
	watcher.supported, watcher.shared = {.Notify, .Posix}, sh
	writer = watcher
	b := new(Notify_Bench, context.temp_allocator)
	for s in ([]^p9.Server{&watcher, &writer}) {
		testing.expect_value(t, on(b, s, {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = "9P2000.x/1 +notify +posix"}), p9.Serve_Result.Reply)
		testing.expect(t, .Notify in s.extensions)
		testing.expect_value(t, on(b, s, {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}), p9.Serve_Result.Reply)
		testing.expect_value(t, b.rep.type, p9.Type.Rattach)
	}
	all := p9.Notify_Mask{.Create, .Remove, .Modify, .Attrib, .Moved_From, .Moved_To} // 0x3f
	watch :: proc(fid: p9.Fid, tag: u16, mask: p9.Notify_Mask) -> (m: p9.Msg) {
		m = {type = .Tnotify, tag = tag, fid = fid}
		p9.set_notify_mask(&m, mask)
		return
	}
	testing.expect_value(t, on(b, &watcher, watch(1, 2, all)), p9.Serve_Result.Defer) // nothing yet: held
	testing.expect_value(t, sh.nwatches, 1)
	// The writer: a create in /, a write to it, a rename, a remove.
	testing.expect_value(t, on(b, &writer, {type = .Twalk, tag = 1, fid = 1, newfid = 2}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &writer, {type = .Tcreate, tag = 1, fid = 2, name = "n", perm = 0o644, mode = p9.ORDWR}), p9.Serve_Result.Reply)
	testing.expect_value(t, b.rep.type, p9.Type.Rcreate)
	testing.expect(t, sh.again)
	testing.expect_value(t, on(b, &writer, {type = .Twrite, tag = 1, fid = 2, data = transmute([]u8)string("hi"), count = 2}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &writer, {type = .Trenameat, tag = 1, fid = 1, name = "n", newfid = 1, name2 = "m"}), p9.Serve_Result.Reply)
	testing.expect_value(t, b.rep.type, p9.Type.Rrenameat)
	testing.expect_value(t, on(b, &writer, {type = .Tremove, tag = 1, fid = 2}), p9.Serve_Result.Reply)
	testing.expect_value(t, b.rep.type, p9.Type.Rremove)
	testing.expect_value(t, on(b, &watcher, watch(1, 2, all)), p9.Serve_Result.Reply)
	testing.expect_value(t, b.rep.type, p9.Type.Rnotify)
	testing.expect_value(t, events(b), "1:n 4:n 16:n 32:m 2:m")
	testing.expect_value(t, on(b, &watcher, watch(1, 3, all)), p9.Serve_Result.Defer) // all taken
	// A file's own watch: its writes, with no name; the directory's names it.
	testing.expect_value(t, on(b, &watcher, {type = .Twalk, tag = 1, fid = 1, newfid = 3, nwname = 1, wname = {0 = "b.txt"}}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &watcher, watch(3, 4, {.Modify})), p9.Serve_Result.Defer)
	testing.expect_value(t, on(b, &writer, {type = .Twalk, tag = 1, fid = 1, newfid = 4, nwname = 1, wname = {0 = "b.txt"}}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &writer, {type = .Topen, tag = 1, fid = 4, mode = p9.OWRITE}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &writer, {type = .Twrite, tag = 1, fid = 4, data = transmute([]u8)string("x"), count = 1}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &watcher, watch(3, 4, {.Modify})), p9.Serve_Result.Reply)
	testing.expect_value(t, events(b), "4:")
	testing.expect_value(t, on(b, &watcher, watch(1, 5, {.Create})), p9.Serve_Result.Reply)
	testing.expect_value(t, events(b), "4:b.txt") // queued before the mask changed
	// The mask leaves writes out now; then an overflow.
	testing.expect_value(t, on(b, &writer, {type = .Twrite, tag = 1, fid = 4, data = transmute([]u8)string("y"), count = 1}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &watcher, watch(1, 5, {.Modify})), p9.Serve_Result.Defer)
	for _ in 0 ..< 40 {
		_ = on(b, &writer, {type = .Twrite, tag = 1, fid = 4, data = transmute([]u8)string("z"), count = 1})
	}
	testing.expect_value(t, on(b, &watcher, watch(1, 6, {.Modify})), p9.Serve_Result.Reply)
	testing.expect(t, strings.has_prefix(events(b), "128: 4:b.txt"))
	testing.expect_value(t, b.rep.count, 3 + 32 * 8)
	// A clunk ends the fid's watch.
	testing.expect_value(t, on(b, &watcher, {type = .Tclunk, tag = 1, fid = 3}), p9.Serve_Result.Reply)
	testing.expect_value(t, sh.nwatches, 1)
	testing.expect_value(t, on(b, &watcher, watch(3, 7, all)), p9.Serve_Result.Reply)
	testing.expect_value(t, b.rep.type, p9.Type.Rerror)
	// Not negotiated: refused.
	plain = {fs = watcher.fs, max_msize = 8192, shared = sh}
	testing.expect_value(t, on(b, &plain, {type = .Tversion, tag = p9.NOTAG, msize = 8192, version = "9P2000"}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &plain, {type = .Tattach, tag = 1, fid = 1, afid = p9.NOFID}), p9.Serve_Result.Reply)
	testing.expect_value(t, on(b, &plain, watch(1, 1, all)), p9.Serve_Result.Reply)
	testing.expect_value(t, b.rep.type, p9.Type.Rerror)
}
