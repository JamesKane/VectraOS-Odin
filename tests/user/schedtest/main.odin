// schedtest: scheduling contexts (upstream's M6 step 6d6c, ADR-0016), in the
// sched scenario (tests/qemu/m6/sched.ndb), on four CPUs. Under 32 busy
// threads, each counting, a thread counts too; what it gets is measured
// against what they get at the same time, so a host that runs the machine
// slower slows both: a thread of the hogs' own band gets what one of them
// does; one bound to a realtime context of 3 ms in each 10 ms gets its 30%,
// about 2.6 times what a hog gets (the other 3.7 CPUs shared by 32), and no
// more, which would be a whole CPU, 10.7 times; one bound to a reserved CPU
// gets nearly that CPU. Donation (6d6c2): the realtime thread's calls to a
// background server, which the hogs would starve, are answered: one in each
// of its periods, each within its budget; back to back, on its budget, which
// they spend, the server running for them as realtime, on the caller's loan,
// and background after. Admission past 80% of the CPUs, and a reservation of
// the shared CPU, are refused, as are parameters out of range. Each check
// prints a line only when it fails; the last line counts them, and the
// shares measured. The checks are upstream's, some of several conditions, so
// the count is too.
package schedtest

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:rt"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	intrinsics.atomic_add(&checks, 1)
	if !ok {
		intrinsics.atomic_add(&failures, 1)
		rt.print("schedtest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

HOGS :: 32
MEASURE :: vx.Duration(1_000_000_000)
stop, go: bool // atomic

// The unit of work every thread counts, one procedure for all of them: two
// loops of their own would compare their code's layout, too.
burn :: #force_no_inline proc "contextless" () {
	k: u32
	for intrinsics.volatile_load(&k) < 4096 {
		intrinsics.volatile_store(&k, intrinsics.volatile_load(&k) + 1)
	}
}

// Counts for d nanoseconds of the clock: how far it got.
count_for :: proc "contextless" (d: vx.Duration) -> u64 {
	end := rt.clock_read() + d
	n: u64
	for {
		burn()
		n += 1
		if n & 15 == 0 && rt.clock_read() >= end {
			return n
		}
	}
}

hog_counts: [HOGS]u64

hog :: proc(arg: rawptr) {
	n := (^u64)(arg)
	for !intrinsics.atomic_load(&go) {}
	for !intrinsics.atomic_load(&stop) {
		burn()
		n^ += 1
	}
}

// --- A background server, and calls to it ---

CALLS :: 40
WORK :: vx.Duration(500_000) // the server's, for each call
server_end, client_end: vx.Handle
after_reply: vx.Sched_Info // the server's, once it has blocked after its last reply
server_waiting: bool // atomic

Reply_Msg :: struct {
	h:  vx.Msg_Header,
	si: vx.Sched_Info, // the server's, as it served the call
}

server :: proc(arg: rawptr) {
	own := rt.intent_set(.Background)
	port, st := rt.port_create()
	if own != .Ok || st != .Ok {
		return
	}
	for quit := false; !quit; {
		req: vx.Msg_Header
		_, rst := rt.channel_read(server_end, memory.ptr_to_bytes(&req))
		if rst == .Err_Should_Wait {
			if rt.port_bind(port, server_end, .Readable, 0) != .Ok {
				break
			}
			intrinsics.atomic_store(&server_waiting, true)
			pkt: [1]vx.Packet
			_, _ = rt.port_wait(port, vx.INFINITE, 0, pkt[:])
			continue
		}
		if rst != .Ok {
			break
		}
		quit = req.ordinal == 1
		_ = count_for(WORK)
		rep := Reply_Msg {
			h = {txid = req.txid},
		}
		_ = rt.thread_state(rt.self, 0, .Get_Sched, &rep.si)
		_ = rt.channel_write(server_end, memory.ptr_to_bytes(&rep))
	}
	none: [1]vx.Packet // answered, it keeps the loan until it next blocks
	_, _ = rt.port_wait(port, rt.clock_read() + 1_000_000, 0, none[:])
	_ = rt.thread_state(rt.self, 0, .Get_Sched, &after_reply)
	_ = rt.handle_close(port)
}

Called :: struct {
	periodic:  bool, // one call in each 10 ms, rather than back to back
	ok, lent:  u32, // calls answered; answered by the server on this thread's loan
	longest:   vx.Duration, // from call to answer
	exhausted: u64, // periods this thread's context ran out in, during the calls
}

make_calls :: proc(out: ^Called) {
	before, after: vx.Sched_Info
	_ = rt.thread_state(rt.self, 0, .Get_Sched, &before)
	nap, _ := rt.port_create()
	start := rt.clock_read()
	for i in 0 ..< CALLS {
		if out.periodic { // the next period: a fresh budget, whatever waiting for the hogs spent
			none: [1]vx.Packet
			_, _ = rt.port_wait(nap, start + vx.Instant(i + 1) * 10_000_000, 0, none[:])
		}
		req: vx.Msg_Header
		rep: Reply_Msg
		call := vx.Call {
			wr_bytes = &req,
			wr_len   = size_of(req),
			rd_bytes = &rep,
			rd_cap   = size_of(rep),
		}
		t0 := rt.clock_read()
		st := rt.channel_call(client_end, &call, t0 + 1_000_000_000)
		took := rt.clock_read() - t0
		if st != .Ok {
			continue
		}
		out.ok += 1
		out.longest = max(out.longest, took)
		if rep.si.intent == .Realtime && rep.si.lent_task != 0 && rep.si.lent_thread == u64(rt.thread_self_id()) {
			out.lent += 1
		}
	}
	_ = rt.handle_close(nap)
	_ = rt.thread_state(rt.self, 0, .Get_Sched, &after)
	out.exhausted = after.exhausted - before.exhausted
}

Counted :: struct {
	ctx:   vx.Handle,
	core:  i32,
	n:     u64,
	calls: ^Called, // makes calls rather than count
	bind:  vx.Status,
	bound: bool, // atomic
}

counter :: proc(arg: rawptr) {
	c := (^Counted)(arg)
	c.bind = rt.sched_ctx_bind(c.ctx, vx.HANDLE_NONE, c.core) // checked by the main thread
	intrinsics.atomic_store(&c.bound, true)
	for !intrinsics.atomic_load(&go) {}
	if c.calls != nil {
		make_calls(c.calls)
	} else {
		c.n = count_for(MEASURE)
	}
}

hogs: [HOGS]rt.Thread

// One counter's count under the hogs, in hundredths of what a hog counted
// meanwhile, on average.
share :: proc(ctx: vx.Handle, core: i32, calls: ^Called) -> u64 {
	c := Counted {
		ctx   = ctx,
		core  = core,
		calls = calls,
	}
	intrinsics.atomic_store(&stop, false)
	intrinsics.atomic_store(&go, false)
	t, st := rt.thread_spawn(counter, &c)
	check(st == .Ok)
	for !intrinsics.atomic_load(&c.bound) {}
	check(c.bind == .Ok)
	for i in 0 ..< HOGS {
		hog_counts[i] = 0
		hst: vx.Status
		hogs[i], hst = rt.thread_spawn(hog, &hog_counts[i], 16 * 1024)
		check(hst == .Ok)
	}
	intrinsics.atomic_store(&go, true)
	rt.thread_join(&t)
	intrinsics.atomic_store(&stop, true)
	all: u64
	for i in 0 ..< HOGS {
		rt.thread_join(&hogs[i])
		all += hog_counts[i]
	}
	mean := all / HOGS
	return mean != 0 ? c.n * 100 / mean : 0
}

say :: proc "contextless" (what: string, v: u64) {
	rt.print("schedtest: ", what, " ", v, "\n")
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	// A realtime context: 3 ms in each 10 ms.
	p := vx.Sched_Params {
		intent = .Realtime,
		period = 10_000_000,
		budget = 3_000_000,
	}
	rtc, st := rt.sched_ctx_create(&p)
	check(st == .Ok)
	rt_share := share(rtc, -1, nil)
	say("realtime against a hog (percent)", rt_share)
	check(rt_share >= 200 && rt_share <= 320) // about 260: its 30%, more than a hog's, and capped
	fair := share(vx.HANDLE_NONE, -1, nil)
	say("fair against a hog (percent)", fair)
	check(fair >= 70 && fair <= 130) // about 100

	// Admission: 80% of four CPUs is 3.2; with 0.3 admitted, two whole CPUs fit, a third not.
	cpu := vx.Sched_Params {
		intent = .Realtime,
		period = 10_000_000,
		budget = 10_000_000,
	}
	one, one_st := rt.sched_ctx_create(&cpu)
	two, two_st := rt.sched_ctx_create(&cpu)
	check(one_st == .Ok && two_st == .Ok)
	three, three_st := rt.sched_ctx_create(&cpu)
	check(three_st == .Err_Refused)
	_ = rt.handle_close(two)
	three, three_st = rt.sched_ctx_create(&cpu)
	check(three_st == .Ok) // the closed one's share given back
	_ = rt.handle_close(one)
	_ = rt.handle_close(three)
	bad := vx.Sched_Params {
		intent = .Realtime,
		period = 10_000_000,
		budget = 20_000_000,
	}
	_, bad_st := rt.sched_ctx_create(&bad)
	check(bad_st == .Err_Invalid) // more than one CPU
	check(rt.intent_set(.Realtime) == .Err_Invalid) // that needs a context
	check(rt.intent_set(.Background) == .Ok)
	si: vx.Sched_Info
	check(rt.thread_state(rt.self, 0, .Get_Sched, &si) == .Ok && si.intent == .Background && si.bound == 0)
	check(rt.intent_set(.Interactive) == .Ok)

	// A reservation: one CPU, the last; a thread bound to it keeps it.
	inter := vx.Sched_Params {
		intent = .Interactive,
	}
	res, res_st := rt.sched_ctx_create(&inter)
	check(res_st == .Ok)
	set, set_st := rt.sched_reserve(res, 1)
	check(set_st == .Ok && set.count == 1 && set.mask == 1 << 3)
	reserved := share(res, 3, nil)
	say("reserved against a hog (percent)", reserved)
	check(reserved >= 800) // about 1070: a CPU of its own, against the 3/32 of one each hog gets
	other, other_st := rt.sched_ctx_create(&inter)
	check(other_st == .Ok)
	set, set_st = rt.sched_reserve(other, 3)
	check(set_st == .Err_Refused) // the first stays shared
	set, set_st = rt.sched_reserve(other, 2)
	check(set_st == .Ok && set.mask == 0b0110)
	set, set_st = rt.sched_reserve(other, 0)
	check(set_st == .Ok && set.count == 0)
	set, set_st = rt.sched_reserve(res, 1, vx.core_tier(1))
	check(set_st == .Err_Refused) // no such tier
	_ = rt.handle_close(other)
	_ = rt.handle_close(res)

	// Donation: the realtime thread calls a background server under the hogs.
	ch_st: vx.Status
	server_end, client_end, ch_st = rt.channel_create()
	check(ch_st == .Ok)
	srv, srv_st := rt.thread_spawn(server, nil)
	check(srv_st == .Ok)
	for !intrinsics.atomic_load(&server_waiting) {}
	if nap, nap_st := rt.port_create(); nap_st == .Ok { // and blocked there, as a server waits for its calls
		none: [1]vx.Packet
		_, _ = rt.port_wait(nap, rt.clock_read() + 50_000_000, 0, none[:])
		_ = rt.handle_close(nap)
	}
	calls := Called {
		periodic = true,
	}
	_ = share(rtc, -1, &calls)
	say("donated calls answered", u64(calls.ok))
	say("longest donated call (us)", u64(calls.longest) / 1000)
	check(calls.ok == CALLS && calls.lent == CALLS)
	check(calls.longest < 3_000_000) // each within the caller's budget, a period's 3 ms
	calls = {}
	_ = share(rtc, -1, &calls)
	say("back-to-back calls answered", u64(calls.ok))
	say("back-to-back periods exhausted", calls.exhausted)
	check(calls.ok == CALLS && calls.lent == CALLS)
	check(calls.exhausted >= 3) // 20 ms of the server's work, on the caller's 3 ms in each 10
	quit := vx.Msg_Header {
		ordinal = 1,
	}
	ack: Reply_Msg
	call := vx.Call {
		wr_bytes = &quit,
		wr_len   = size_of(quit),
		rd_bytes = &ack,
		rd_cap   = size_of(ack),
	}
	check(rt.channel_call(client_end, &call, rt.clock_read() + 5_000_000_000) == .Ok)
	rt.thread_join(&srv)
	check(after_reply.intent == .Background && after_reply.lent_task == 0) // its own again
	_ = rt.handle_close(server_end)
	_ = rt.handle_close(client_end)
	_ = rt.handle_close(rtc)

	rt.print("schedtest: ", u64(intrinsics.atomic_load(&checks)), " checks, ", u64(intrinsics.atomic_load(&failures)), " failed\n")
	return 0
}
