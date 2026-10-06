// pooltest: worker threads in the ring server (upstream's M6 step 6d5a),
// against pooltestd (tests/user/pooltestd), in the pool scenario
// (tests/qemu/m6/pool.ndb). While a read waits with the server let go, the
// server answers others, on other connections and on the same one; slow
// reads on three connections wait at once; a Tflush of a busy read waits for
// its reply; a connection that goes while a read of its is busy is closed
// after it, and the server goes on. Each check prints a line only when it
// fails; the last line counts them. The checks are upstream's, some of
// several conditions, so the count is too.
package pooltest

import "base:intrinsics"
import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if !ok {
		failures += 1
		rt.print("pooltest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

space: ns.Namespace
conns: [4]rt.Conn
roots: [4]p9.Fid

// The file read whole on connection k, into buf.
read_file :: proc "contextless" (k: int, name: string, buf: []u8) -> (text: string, st: vx.Status) {
	c := &conns[k].c
	fid := p9.client_walk(c, roots[k], name) or_return
	defer _ = p9.client_clunk(c, fid)
	p9.client_open(c, fid, p9.OREAD) or_return
	n := p9.client_read(c, fid, 0, buf) or_return
	return string(buf[:n]), .Ok
}

reads :: proc "contextless" (k: int, name, want: string) -> bool {
	buf: [16]u8
	text, st := read_file(k, name, buf[:])
	return st == .Ok && text == want
}

open_gate :: proc "contextless" () {
	c := &conns[1].c
	fid, st := p9.client_walk(c, roots[1], "open")
	if st != .Ok {
		return
	}
	if p9.client_open(c, fid, p9.OWRITE) == .Ok {
		_, _ = p9.client_write(c, fid, 0, transmute([]u8)string("x"))
	}
	_ = p9.client_clunk(c, fid)
}

pause_ms :: proc "contextless" (ms: i64) {
	never: u32
	until := rt.clock_read() + vx.Instant(ms * 1_000_000)
	for rt.clock_read() < until {
		_ = rt.futex_wait(&never, 0, until)
	}
}

Job :: struct {
	conn: int,
	file: string,
	done: bool, // atomic
	text: string, // into buf
	st:   vx.Status,
	n:    int,
	buf:  [16]u8,
}

done :: proc "contextless" (j: ^Job) -> bool {
	return intrinsics.atomic_load(&j.done)
}

is :: proc "contextless" (j: ^Job, want: string) -> bool {
	return j.st == .Ok && j.text == want
}

run :: proc(arg: rawptr) {
	j := (^Job)(arg)
	j.text, j.st = read_file(j.conn, j.file, j.buf[:])
	intrinsics.atomic_store(&j.done, true)
}

// A gate read sent and flushed at once: the flush waits for it.
cancel_job :: proc(arg: rawptr) {
	j := (^Job)(arg)
	c := &conns[0].c
	if fid, st := p9.client_walk(c, roots[0], "gate"); st == .Ok {
		if p9.client_open(c, fid, p9.OREAD) == .Ok {
			r := p9.Msg {
				type  = .Tread,
				fid   = fid,
				count = 16,
			}
			if rt.p9_send(&conns[0], &r, vx.HANDLE_NONE, 0) == .Ok {
				pause_ms(50) // served, and let go, before the flush comes
				rt.p9_cancel(&conns[0], r.tag)
				j.n = 1
			}
		}
		_ = p9.client_clunk(c, fid)
	}
	intrinsics.atomic_store(&j.done, true)
}

again: rt.Conn

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	connector := ns.connector(&space, "/n/pool")
	check(connector != vx.HANDLE_NONE)
	for &k, i in conns {
		st := rt.p9_connect(connector, &k)
		if st == .Ok {
			roots[i], st = p9.client_attach(&k.c, "")
		}
		check(st == .Ok)
		k.timeout = 10_000_000_000
	}

	// A gate read let go: the others are answered meanwhile, on its own connection too.
	g := Job {
		conn = 0,
		file = "gate",
	}
	t: rt.Thread
	u: [3]rt.Thread
	st: vx.Status
	t, st = rt.thread_spawn(run, &g)
	check(st == .Ok)
	pause_ms(50)
	fast := true
	for _ in 0 ..< 10 {
		fast = fast && reads(1, "fast", "fast\n")
	}
	check(fast)
	check(reads(0, "fast", "fast\n"))
	check(!done(&g))
	open_gate()
	rt.thread_join(&t)
	check(is(&g, "gate\n"))

	// Three slow reads at once, each let go: all three wait together.
	sl := [3]Job{{conn = 0, file = "slow"}, {conn = 1, file = "slow"}, {conn = 2, file = "slow"}}
	start := rt.clock_read()
	for i in 0 ..< 3 {
		u[i], st = rt.thread_spawn(run, &sl[i])
		check(st == .Ok)
	}
	for i in 0 ..< 3 {
		rt.thread_join(&u[i])
	}
	took := rt.clock_read() - start
	check(is(&sl[0], "slow\n") && is(&sl[1], "slow\n") && is(&sl[2], "slow\n"))
	check(reads(3, "peak", "3\n"))
	check(took < 850_000_000) // not one after another (900 ms)

	// A Tflush of a busy read waits for it: the flusher is not done until the
	// gate opens.
	f: Job
	t, st = rt.thread_spawn(cancel_job, &f)
	check(st == .Ok)
	pause_ms(200)
	check(!done(&f))
	open_gate()
	rt.thread_join(&t)
	check(f.n == 1)
	check(reads(0, "fast", "fast\n"))

	// A connection that goes while a read of its is busy: closed after it.
	c := &conns[2].c
	fid, wst := p9.client_walk(c, roots[2], "gate")
	check(wst == .Ok && p9.client_open(c, fid, p9.OREAD) == .Ok)
	r := p9.Msg {
		type  = .Tread,
		fid   = fid,
		count = 16,
	}
	check(rt.p9_send(&conns[2], &r, vx.HANDLE_NONE, 0) == .Ok)
	pause_ms(50)
	rt.p9_disconnect(&conns[2])
	pause_ms(50)
	check(reads(1, "fast", "fast\n"))
	open_gate()
	pause_ms(50)
	check(reads(1, "fast", "fast\n"))
	check(reads(3, "fast", "fast\n"))
	ast := rt.p9_connect(connector, &again)
	if ast == .Ok {
		_, ast = p9.client_attach(&again.c, "")
	}
	check(ast == .Ok)

	rt.print("pooltest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	return 0
}
