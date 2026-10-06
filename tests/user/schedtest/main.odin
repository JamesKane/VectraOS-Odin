// schedtest: scheduling contexts (upstream's M6 step 6d6c, ADR-0016), in the
// sched scenario (tests/qemu/m6/sched.ndb), on four CPUs. Under 32 busy
// threads, each counting, a thread counts too; what it gets is measured
// against what they get at the same time, so a host that runs the machine
// slower slows both: a thread of the hogs' own band gets what one of them
// does; one bound to a realtime context of 3 ms in each 10 ms gets its 30%,
// about 2.6 times what a hog gets (the other 3.7 CPUs shared by 32), and no
// more, which would be a whole CPU, 10.7 times; one bound to a reserved CPU
// gets nearly that CPU. Admission past 80% of the CPUs, and a reservation of
// the shared CPU, are refused, as are parameters out of range. Each check
// prints a line only when it fails; the last line counts them, and the
// shares measured. The checks are upstream's, some of several conditions, so
// the count is too.
package schedtest

import "base:intrinsics"
import vx "abi:vx"
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

// Counts for d nanoseconds of the clock: how far it got.
count_for :: proc "contextless" (d: vx.Duration) -> u64 {
	end := rt.clock_read() + d
	n: u64
	for {
		k: u32
		for intrinsics.volatile_load(&k) < 4096 {
			intrinsics.volatile_store(&k, intrinsics.volatile_load(&k) + 1)
		}
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
		k: u32
		for intrinsics.volatile_load(&k) < 4096 {
			intrinsics.volatile_store(&k, intrinsics.volatile_load(&k) + 1)
		}
		n^ += 1
	}
}

Counted :: struct {
	ctx:   vx.Handle,
	core:  i32,
	n:     u64,
	bind:  vx.Status,
	bound: bool, // atomic
}

counter :: proc(arg: rawptr) {
	c := (^Counted)(arg)
	c.bind = rt.sched_ctx_bind(c.ctx, vx.HANDLE_NONE, c.core) // checked by the main thread
	intrinsics.atomic_store(&c.bound, true)
	for !intrinsics.atomic_load(&go) {}
	c.n = count_for(MEASURE)
}

hogs: [HOGS]rt.Thread

// One counter's count under the hogs, in hundredths of what a hog counted
// meanwhile, on average.
share :: proc(ctx: vx.Handle, core: i32) -> u64 {
	c := Counted {
		ctx  = ctx,
		core = core,
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
	rt_share := share(rtc, -1)
	say("realtime against a hog (percent)", rt_share)
	check(rt_share >= 180 && rt_share <= 340) // about 260: its 30%, more than a hog's, and capped
	fair := share(vx.HANDLE_NONE, -1)
	say("fair against a hog (percent)", fair)
	check(fair >= 60 && fair <= 150) // about 100

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
	reserved := share(res, 3)
	say("reserved against a hog (percent)", reserved)
	check(reserved >= 600) // about 1070: a CPU of its own, against the 3/32 of one each hog gets
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
	_ = rt.handle_close(rtc)

	rt.print("schedtest: ", u64(intrinsics.atomic_load(&checks)), " checks, ", u64(intrinsics.atomic_load(&failures)), " failed\n")
	return 0
}
