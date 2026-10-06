// p9pipetest: the pipelined 9P client and ring server (upstream's M6 step
// 6d4a), run in the p9pipe scenario (tests/qemu/m6/p9pipe.ndb), against
// ptyd, whose slave reads wait for input: requests the server holds. On one
// connection: a held read and a write that ends it, from two threads;
// threads making calls while one is held; a held read flushed by a note,
// and by a timeout, with the connection whole after; and the input that
// came after a flush read by the next read, not lost to the flushed one.
// Each check prints a line only when it fails; the last line counts them.
// The checks are upstream's, some of several conditions, so the count is
// too.
package p9pipetest

import "base:intrinsics"
import vx "abi:vx"
import "vx:p9"
import "vx:rt"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	intrinsics.atomic_add(&checks, 1)
	if !ok {
		intrinsics.atomic_add(&failures, 1)
		rt.print("p9pipetest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

conn: rt.Conn
root, master, slave: p9.Fid
never: u32

nap :: proc "contextless" (ms: i64) {
	_ = rt.futex_wait(&never, 0, rt.clock_read() + vx.Instant(ms * 1_000_000))
}

// A slave read, on a thread of its own.
Reader :: struct {
	t:    rt.Thread,
	buf:  [64]u8,
	n:    int, // what the read returned: a count,
	st:   vx.Status, // or why not
	done: u32, // atomic: set once n and st are
	id:   u32, // atomic: its kernel thread id, for a note
}

read_slave :: proc(arg: rawptr) {
	r := (^Reader)(arg)
	// The newest thread is the one with the highest id: this one, as it starts.
	ti: vx.Thread_Info
	for after := u32(0); rt.thread_state(rt.self, after, .Next_Thread, &ti) == .Ok; {
		after = ti.id
	}
	intrinsics.atomic_store(&r.id, ti.id)
	r.n, r.st = p9.client_read(&conn.c, slave, p9.OFFSET_CURRENT, r.buf[:])
	intrinsics.atomic_store(&r.done, 1)
}

done :: proc "contextless" (r: ^Reader) -> bool {
	return intrinsics.atomic_load(&r.done) != 0
}

type_at_master :: proc "contextless" (text: string) -> bool {
	n, st := p9.client_write(&conn.c, master, p9.OFFSET_CURRENT, transmute([]u8)text)
	return st == .Ok && n == len(text)
}

// Many calls from a thread while a read is held.
busy_ok: u32

busy :: proc(arg: rawptr) {
	ok := true
	for _ in 0 ..< 100 {
		st: p9.Stat
		ok = p9.client_stat(&conn.c, master, &st) == .Ok
		if ok {
			fid, wst := p9.client_walk(&conn.c, root, "pts")
			ok = wst == .Ok && p9.client_clunk(&conn.c, fid) == .Ok
		}
		if !ok {
			break
		}
	}
	if ok {
		intrinsics.atomic_add(&busy_ok, 1)
	}
}

flush_wanted :: proc "contextless" (ctx: rawptr) -> bool {
	return true
}

on_note :: proc "contextless" (e: ^vx.Exception, note: string, fp: rawptr) -> rt.Noted {
	return note == "flush me" ? .Cont : .Dflt
}

wait_done :: proc "contextless" (r: ^Reader, ms: i64) -> bool {
	for _ in 0 ..< ms {
		if done(r) {
			break
		}
		nap(1)
	}
	return done(r)
}

read_is :: proc "contextless" (want: string) -> bool {
	buf: [64]u8
	n, st := p9.client_read(&conn.c, slave, p9.OFFSET_CURRENT, buf[:])
	return st == .Ok && string(buf[:n]) == want
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	connector := rt.spawn_take("srv:ptyd")
	check(connector != vx.HANDLE_NONE)
	if connector == vx.HANDLE_NONE {
		rt.exits("no connector to /srv/ptyd")
	}
	check(rt.p9_connect(connector, &conn) == .Ok)
	ast, wst, ost: vx.Status
	root, ast = p9.client_attach(&conn.c, "")
	check(ast == .Ok)
	master, wst = p9.client_walk(&conn.c, root, "ptmx")
	if wst == .Ok {
		ost = p9.client_open(&conn.c, master, p9.ORDWR)
	}
	check(wst == .Ok && ost == .Ok)
	st: p9.Stat
	names: p9.Stat_Text
	check(p9.client_stat(&conn.c, master, &st, &names) == .Ok && len(st.name) > 0 && len(st.name) < 8)
	path_buf: [16]u8
	n := copy(path_buf[:], "pts/")
	n += copy(path_buf[n:], st.name)
	slave, wst = p9.client_walk(&conn.c, root, string(path_buf[:n]))
	if wst == .Ok {
		ost = p9.client_open(&conn.c, slave, p9.ORDWR)
	}
	check(wst == .Ok && ost == .Ok)

	// A read the server holds, and a write from another thread that ends it,
	// on the same connection; calls from more threads meanwhile.
	@(static) r1: Reader
	tst: vx.Status
	r1.t, tst = rt.thread_spawn(read_slave, &r1)
	check(tst == .Ok)
	nap(30)
	check(!done(&r1)) // held: no input yet
	b: [4]rt.Thread
	for &t in b {
		t, tst = rt.thread_spawn(busy, nil)
		check(tst == .Ok)
	}
	for &t in b {
		rt.thread_join(&t)
	}
	check(intrinsics.atomic_load(&busy_ok) == 4 && !done(&r1))
	check(type_at_master("hello\n"))
	check(wait_done(&r1, 2000) && r1.st == .Ok && string(r1.buf[:r1.n]) == "hello\n")
	rt.thread_join(&r1.t)

	// A held read flushed by a note: .Err_Interrupted; then input reaches the
	// next read, not the flushed one.
	check(rt.notify(on_note) == .Ok)
	conn.interrupted = flush_wanted
	@(static) r2: Reader
	r2.t, tst = rt.thread_spawn(read_slave, &r2)
	check(tst == .Ok)
	nap(30)
	check(!done(&r2) && intrinsics.atomic_load(&r2.id) != 0)
	check(rt.thread_interrupt(rt.self, intrinsics.atomic_load(&r2.id), "flush me") == .Ok)
	check(wait_done(&r2, 2000) && r2.st == .Err_Interrupted)
	rt.thread_join(&r2.t)
	check(!conn.dead && type_at_master("after\n"))
	check(read_is("after\n"))
	conn.interrupted = nil

	// A held read past its timeout: flushed, .Err_Timed_Out, the connection
	// whole.
	conn.timeout = 100_000_000
	t0 := rt.clock_read()
	buf: [64]u8
	_, rst := p9.client_read(&conn.c, slave, p9.OFFSET_CURRENT, buf[:])
	check(rst == .Err_Timed_Out)
	check(rt.clock_read() - t0 < 2_000_000_000)
	conn.timeout = 0
	check(!conn.dead && type_at_master("again\n"))
	check(read_is("again\n"))

	_ = p9.client_clunk(&conn.c, slave)
	_ = p9.client_clunk(&conn.c, master)
	_ = p9.client_clunk(&conn.c, root)
	rt.p9_disconnect(&conn)
	rt.print("p9pipetest: ", u64(intrinsics.atomic_load(&checks)), " checks, ", u64(intrinsics.atomic_load(&failures)), " failed\n")
	return 0
}
