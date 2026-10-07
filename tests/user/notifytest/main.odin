// notifytest: 9Px notify in a running system (upstream's M6 step 6e1d, its
// docs/proto/notify.md), the notify scenario's (tests/qemu/m6/notify.ndb): a
// watcher on one ring connection to tmpfs, a writer on another. The
// watcher's Tnotify waits, held by the server, until the writer's change on
// the other connection queues an event and wakes it. The writer pings until
// the watcher has heard one (its watch is made by its first Tnotify, which
// the writer cannot see), then creates, writes, renames and removes a file;
// the watcher must hear those in order. Each check prints a line only when
// it fails; the last line counts them. The checks are upstream's, some of
// several conditions, so the count is too.
package notifytest

import "base:intrinsics"
import vx "abi:vx"
import "vx:p9"
import "vx:rt"
import "vx:str"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if !ok {
		failures += 1
		rt.print("notifytest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

watcher, writer: rt.Conn
watched: p9.Fid // the watcher's fid on the directory
heard: [dynamic; 4096]u8 // "kind:name " for each event, in order
heard_any, done: u32

ALL :: p9.Notify_Mask{.Create, .Remove, .Modify, .Attrib, .Moved_From, .Moved_To}

// Appends a batch of events (kind[1] name[s] each) to heard.
note_events :: proc "contextless" (b: []u8) {
	it := p9.Notify_Events{buf = b}
	for kind, name in p9.next_event(&it) {
		if len(heard) + len(name) + 8 >= cap(heard) {
			continue
		}
		digits: [4]u8
		_ = append(&heard, str.format_u64(digits[:], u64(kind))) // a kind, below 256: up to three digits
		_ = append(&heard, ':')
		_ = append(&heard, name)
		_ = append(&heard, ' ')
	}
}

heard_has :: proc "contextless" (s: string) -> bool {
	return str.contains(string(heard[:]), s)
}

// The watcher: asks until it has heard the remove that ends the writer's turn.
watch :: proc(arg: rawptr) {
	@(static) b: [8192]u8
	for !heard_has(" 2:g ") { // a space first: "32:g " holds "2:g " too
		n, e := p9.client_notify(&watcher.c, watched, ALL, b[:])
		if e != .Ok {
			break
		}
		note_events(b[:n])
		intrinsics.atomic_store(&heard_any, 1)
	}
	intrinsics.atomic_store(&done, 1)
	_, _ = rt.futex_wake(&done, 1)
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	connector := rt.spawn_take("srv:tmpfs")
	check(connector != vx.HANDLE_NONE && rt.p9_connect(connector, &watcher) == .Ok && rt.p9_connect(connector, &writer) == .Ok)
	check(.Notify in watcher.c.extensions && .Notify in writer.c.extensions)
	root, dir, f, wroot: p9.Fid
	e1, e2: vx.Status
	root, e1 = p9.client_attach(&writer.c, "")
	dir, e2 = p9.client_walk(&writer.c, root, "")
	check(e1 == .Ok && e2 == .Ok)
	_ = p9.client_create(&writer.c, dir, "notifytest", p9.DMDIR | 0o777, p9.OREAD)
	_ = p9.client_clunk(&writer.c, dir)
	dir, e1 = p9.client_walk(&writer.c, root, "notifytest")
	check(e1 == .Ok)
	wroot, e1 = p9.client_attach(&watcher.c, "")
	watched, e2 = p9.client_walk(&watcher.c, wroot, "notifytest")
	check(e1 == .Ok && e2 == .Ok)
	t, st := rt.thread_spawn(watch, nil, 64 * 1024)
	check(st == .Ok)
	// Pings, until the watcher's watch exists and has heard one.
	never: u32
	for i := 0; i < 500 && intrinsics.atomic_load(&heard_any) == 0; i += 1 {
		if f, e1 = p9.client_walk(&writer.c, dir, ""); e1 == .Ok && p9.client_create(&writer.c, f, "ping", 0o644, p9.OWRITE) == .Ok {
			_ = p9.client_remove(&writer.c, f) // which clunks it
		}
		_ = rt.futex_wait(&never, 0, rt.clock_read() + 10_000_000)
	}
	check(intrinsics.atomic_load(&heard_any) != 0)
	// The change the watcher must hear, in order.
	f, e1 = p9.client_walk(&writer.c, dir, "")
	check(e1 == .Ok && p9.client_create(&writer.c, f, "f", 0o644, p9.OWRITE) == .Ok)
	n, we := p9.client_write(&writer.c, f, 0, transmute([]u8)string("hello"))
	check(we == .Ok && n == 5)
	check(p9.client_renameat(&writer.c, dir, "f", dir, "g") == .Ok)
	check(p9.client_remove(&writer.c, f) == .Ok)
	end := rt.clock_read() + 5_000_000_000
	for intrinsics.atomic_load(&done) == 0 && rt.clock_read() < end {
		_ = rt.futex_wait(&done, 0, rt.clock_read() + 100_000_000)
	}
	check(intrinsics.atomic_load(&done) != 0)
	check(heard_has(" 1:f 4:f 16:f 32:g 2:g "))
	if intrinsics.atomic_load(&done) != 0 {
		rt.thread_join(&t)
	}
	rt.print("notifytest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	if failures != 0 {
		rt.exits("FAILED")
	}
	return 0
}
