// threadtest: vx:rt's threads (upstream's M6 step 6d1), run in the threads
// scenario (tests/qemu/m6/threads.ndb). Each thread's thread-local storage
// starts as the image has it (initialised, zeroed, at its alignment) and
// stays its own over sleeps and switches; each knows its stack's bounds; an
// rt.Mutex keeps a shared count whole; threads joined are unmapped, and more
// can be made. Each check prints a line only when it fails; the last line
// counts them. The checks are upstream's, some of several conditions, so the
// count is too.
//
// Odin's @(thread_local) variables take no initial value, so they are all
// .tbss: the initialised one (.tdata) is assembly's, arch/*/tdata.S.
package threadtest

import "base:intrinsics"
import vx "abi:vx"
import "vx:rt"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	intrinsics.atomic_add(&checks, 1)
	if !ok {
		intrinsics.atomic_add(&failures, 1)
		rt.print("threadtest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

foreign _ {
	vx_tl_init :: proc "c" () -> ^u64 --- // tdata.S: the calling thread's copy of its 0x1234_5678
}

Aligned :: struct #align(64) {
	v: u64,
}

@(thread_local)
tl_zero: [100]u8 // .tbss
@(thread_local)
tl_aligned: Aligned

THREADS :: 8
ROUNDS :: 5000

lock: rt.Mutex
count: u64 // under lock
never: u32

tls_fresh :: proc "contextless" () -> bool {
	zero := true
	for b in tl_zero {
		zero = zero && b == 0
	}
	return vx_tl_init()^ == 0x1234_5678 && zero && uintptr(&tl_aligned) & 63 == 0 && tl_aligned.v == 0
}

worker :: proc(arg: rawptr) {
	me := u64(uintptr(arg))
	check(tls_fresh()) // its own copy, from the image
	vx_tl_init()^, tl_zero[me], tl_aligned.v = me, u8(me), me * 3
	here: int
	lo, hi, ok := rt.thread_stack()
	at := u64(uintptr(&here))
	check(ok && at >= lo && at < hi && hi - lo == 64 * 1024)
	for i in 0 ..< ROUNDS {
		rt.mutex_lock(&lock)
		count += 1
		rt.mutex_unlock(&lock)
		if i % 1000 == 0 {
			_ = rt.futex_wait(&never, 0, rt.clock_read() + 1_000_000) // a sleep: another thread runs, perhaps here
		}
	}
	check(vx_tl_init()^ == me && tl_zero[me] == u8(me) && tl_aligned.v == me * 3) // still its own
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	check(tls_fresh())
	vx_tl_init()^ = 0x5555
	here: int
	lo, hi, ok := rt.thread_stack()
	at := u64(uintptr(&here))
	check(ok && at >= lo && at < hi) // the first thread's too
	t: [THREADS]rt.Thread
	for _ in 0 ..< 2 { // joined threads are let go of, and more can be made
		count = 0
		for i in 0 ..< THREADS {
			st: vx.Status
			t[i], st = rt.thread_spawn(worker, rawptr(uintptr(i + 1)), 64 * 1024)
			check(st == .Ok)
		}
		for &th in t {
			rt.thread_join(&th)
		}
		check(count == THREADS * ROUNDS)
	}
	check(vx_tl_init()^ == 0x5555) // the first thread's own, untouched by the others
	rt.print("threadtest: ", u64(intrinsics.atomic_load(&checks)), " checks, ", u64(intrinsics.atomic_load(&failures)), " failed\n")
	if intrinsics.atomic_load(&failures) != 0 {
		rt.exits("failed")
	}
	return 0
}
