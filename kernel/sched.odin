package kernel

import "base:intrinsics"
import vx "abi:vx"

// The v1 scheduler. Every CPU serves one shared ready queue, one band of it
// for each intent, highest first, round robin within a band; each CPU keeps
// the threads that blocked on it, with a deadline, in its own sleep queue,
// and runs a user thread for at most a 10 ms slice while others of its band
// wait. One lock covers all of it. Per-CPU ready queues come when
// measurements show the lock contended.
//
// Scheduling contexts (upstream's M6 step 6d6c, ADR-0016): a thread bound to
// one runs with its intent; a realtime one is a constant-bandwidth server,
// its budget charged for the time its threads run and, spent, its threads
// not run again until its next period fills it. Contexts are admitted or
// refused, at most 80% of the CPUs between them. A context's reserved CPUs
// run its threads bound to them and nothing else; one CPU, the first, is
// never reserved. A thread made ready in a band above one running preempts it.
//
// Donation (6d6c2, upstream's 01 §4.5): a thread in channel_call lends its
// scheduling, its intent and its context, to the thread serving the call, as
// seL4 MCS does and as Zircon's channel calls make the port waiter they wake
// the owner of the caller's wait (object/channel_dispatcher.rs,
// write_self_locked's queue_to_own). The loan goes first to the port waiter
// the request wakes, then to the thread that reads it, and ends with the
// call; a thread runs on a loan only if it is above its own. The thread woken
// goes on the caller's CPU, which the caller is about to leave, and the
// reply's caller on the replier's: each switches straight to the other.
// Answered, the server keeps the loan until it next blocks, or its slice
// ends, so that it gets back to its wait for the next call: seL4's reply and
// receive are one call, ours two, and between them a server of a lower band
// would wait behind every thread above it.
//
// The kernel runs with interrupts off. They are on only in user mode and in
// an idle thread's wait. A CPU with nothing to run sleeps with no timer armed
// unless a sleeper or a spent context needs one; a thread made ready while it
// sleeps reaches it as a reschedule interrupt (arch_send_resched).
//
// The lock is held across a context switch and released by whichever thread
// runs next, so a thread queued by one CPU cannot be picked up by another
// before its registers are saved.

TIME_SLICE :: Instant(10_000_000)
// CPU time is sampled as 9front's is (ADR-0041): while a CPU runs a thread,
// not its idle one, a tick every 10 ms charges the thread a tick of user or
// system time, by where it found it. An idle CPU stays tickless.
TICK :: Instant(10_000_000)

// Where a tick found the thread it charges.
Cpu_Time :: enum u8 {
	User,
	Sys,
}
INFINITE :: Instant(vx.INFINITE) // a deadline that never comes

Cpu_Set :: bit_set[0 ..< MAX_CPUS; u64] // by index

Cpu :: struct {
	index:      u32, // 0 is the boot CPU
	arch_id:    u64, // local APIC ID, or MPIDR affinity
	current:    ^Thread,
	idle:       Thread, // runs when nothing else can; the boot context on CPU 0
	sleepers:   ^Thread, // blocked here with a deadline, earliest first
	slice_end:  Instant,
	run_start:  Instant, // when current began running, for charging its context
	tick_at:    Instant, // the next CPU-time tick, while it runs a thread (ADR-0041)
	reserved:   ^Sched_Ctx, // the context that reserved this CPU, or none
	resched:    bool, // call schedule before returning to user mode
	lending:    ^Thread, // a channel_call delivering its request: the port waiter it wakes is lent to
	reap:       ^Thread, // a thread that died here, for whoever runs next to free
	idle_stack: u64, // the idle stack's lowest byte
	// Which task tables this CPU has loaded (0: none), and how many times it
	// has loaded tables: a shootdown waits only for CPUs that may cache the
	// pages. Atomic: other CPUs read them.
	user_root:  Paddr,
	root_loads: u64,
	tlb_asked:  u64, // x86_64's shootdowns (arch_amd64.odin)
	tlb_done:   u64,
}

// A scheduling context (ADR-0016): an intent, and a realtime one's budget in
// each period, which the threads bound to it share.
Sched_Ctx :: struct {
	using obj:      Object,
	intent:         vx.Intent,
	period, budget: Instant, // realtime's
	ppm:            u64, // its admitted share, in millionths of a CPU
	// Under the scheduler's lock:
	left:           Instant, // of its budget, this period
	period_end:     Instant, // when it is filled again
	throttled:      bool, // spent: its threads wait for period_end
	exhausted:      u64, // periods it ran out of budget in
	reserved:       Cpu_Set, // the CPUs it reserved
	th_next:        ^Sched_Ctx, // on the list of throttled contexts
}

#assert(offset_of(Sched_Ctx, obj) == 0) // objects are cast from ^Object

@(private="file")
sched_ctx_pool: Pool(Sched_Ctx)

// Loads a task's tables on this CPU (0: none), counted for shootdowns.
load_user_root :: proc "contextless" (c: ^Cpu, root: Paddr) {
	intrinsics.atomic_store_explicit(&c.user_root, root, .Relaxed)
	arch_switch_user_root(root)
	intrinsics.atomic_add_explicit(&c.root_loads, 1, .Release)
}

@(private="file")
sched: struct {
	lock:         Spinlock,
	run:          [vx.Intent]Fifo(Thread), // a band per intent, highest first
	idle:         Cpu_Set, // CPUs running their idle threads
	admitted_ppm: u64, // the realtime budgets admitted, in millionths of a CPU
	throttled:    ^Sched_Ctx, // contexts waiting for their next period
}

this_cpu :: #force_inline proc "contextless" () -> ^Cpu {
	return &cpus[arch_cpu_index()]
}

// Run after every switch, by the thread switched to: free the thread that
// died on this CPU just before. It could not free the stack it was running on.
@(private="file")
reap_after_switch :: proc "contextless" () {
	c := this_cpu()
	dead := c.reap
	c.reap = nil
	spin_unlock(&sched.lock)
	if dead != nil {
		thread_reap(dead)
	}
}

// A thread's own intent: its context's, or its own.
@(private="file")
own_intent :: proc "contextless" (t: ^Thread) -> vx.Intent {
	return t.ctx != nil ? t.ctx.intent : t.intent
}

// The band of an intent; the idle threads' (none) is .Interactive's.
@(private="file")
intent_band :: proc "contextless" (i: vx.Intent) -> vx.Intent {
	return i >= .Realtime && i <= .Background ? i : .Interactive
}

// Loans go at most this deep: a server calling a server calling a server.
@(private="file")
LEND_DEPTH :: 8

// The thread whose scheduling t runs on: itself, or the highest of the
// callers lending to it, along the chain, above its own.
@(private="file")
sched_source :: proc "contextless" (t: ^Thread) -> ^Thread {
	best := t
	o := t.donor
	for i := 0; i < LEND_DEPTH && o != nil; i, o = i + 1, o.donor {
		if intent_band(own_intent(o)) < intent_band(own_intent(best)) {
			best = o
		}
	}
	return best
}

// A thread's intent: its own, or a loan's.
@(private="file")
thread_intent :: proc "contextless" (t: ^Thread) -> vx.Intent {
	return own_intent(sched_source(t))
}

// The context t's time is charged to: its own, or a loan's.
@(private="file")
ctx_of :: proc "contextless" (t: ^Thread) -> ^Sched_Ctx {
	return sched_source(t).ctx
}

// Its band: a smaller value is a higher band.
@(private="file")
band_of :: proc "contextless" (t: ^Thread) -> vx.Intent {
	return intent_band(thread_intent(t))
}

// The intent a channel message from t carries as sender_intent.
sched_thread_intent :: proc "contextless" (t: ^Thread) -> vx.Intent {
	spin_guard(&sched.lock)
	return thread_intent(t)
}

// The CPU a thread is bound to, if its context still reserves it.
@(private="file")
bound_cpu :: proc "contextless" (t: ^Thread) -> Maybe(u32) {
	core, ok := t.core.?
	if ok && t.ctx != nil && int(core) in t.ctx.reserved {
		return core
	}
	return nil
}

// Whether t may run on c now: a reserved CPU runs its context's threads bound
// to it alone, a bound thread runs there alone, and a spent context's
// threads wait for its next period.
@(private="file")
may_run :: proc "contextless" (t: ^Thread, c: ^Cpu) -> bool {
	x := ctx_of(t)
	if x != nil && x.throttled {
		return false
	}
	if b, ok := bound_cpu(t).?; ok {
		return b == c.index
	}
	return c.reserved == nil
}

@(private="file")
run_enqueue :: proc "contextless" (t: ^Thread) {
	t.state = .Ready
	fifo_push(&sched.run[band_of(t)], t)
}

// Queues t first in its band: a hand-off, run next.
@(private="file")
run_push :: proc "contextless" (t: ^Thread) {
	t.state = .Ready
	fifo_push_front(&sched.run[band_of(t)], t)
}

// The first ready thread of the highest band that may run on c, taken off
// the queue. (A thread's band may have changed since it was queued: it is
// taken from the queue it is in.)
@(private="file")
run_dequeue :: proc "contextless" (c: ^Cpu) -> ^Thread {
	for &q in sched.run {
		for t := q.head; t != nil; t = t.next {
			if may_run(t, c) {
				_ = fifo_remove(&q, t)
				return t
			}
		}
	}
	return nil
}

// Whether a thread that may run on c waits in band b or above.
@(private="file")
ready_for :: proc "contextless" (c: ^Cpu, b: vx.Intent) -> bool {
	for &q, band in sched.run {
		if band > b {
			break
		}
		for t := q.head; t != nil; t = t.next {
			if may_run(t, c) {
				return true
			}
		}
	}
	return false
}

// --- Budgets ---

// A realtime context whose period has ended is filled again.
@(private="file")
ctx_refill :: proc "contextless" (x: ^Sched_Ctx, now: Instant) {
	if x.intent != .Realtime || now < x.period_end {
		return
	}
	x.left = x.budget
	next := x.period_end + x.period
	x.period_end = next > now ? next : now + x.period // far behind: from now
	if x.throttled {
		x.throttled = false
		unlink(&sched.throttled, x, "th_next")
		x.th_next = nil
	}
}

// Charges c's running thread's context for the time since it last was; true
// if that spent its budget (the thread must stop).
@(private="file")
charge :: proc "contextless" (c: ^Cpu, now: Instant) -> bool {
	t := c.current
	x := t != nil ? ctx_of(t) : nil
	ran := now - c.run_start
	c.run_start = now
	if x == nil || x.intent != .Realtime || x.throttled {
		return false
	}
	ctx_refill(x, now)
	x.left -= ran
	if x.left > 0 {
		return false
	}
	x.throttled = true
	x.exhausted += 1
	x.th_next = sched.throttled
	sched.throttled = x
	for i in 0 ..< cpu_total { // its threads on other CPUs stop too
		o := &cpus[i]
		if o != c && o.current != nil && ctx_of(o.current) == x {
			arch_send_resched(o)
		}
	}
	return true
}

// Threads that may run again (a context filled), on any CPU that will take
// them: this one looks at once, the idle ones by interrupt.
@(private="file")
kick_idle :: proc "contextless" () {
	self := this_cpu()
	self.resched = true
	for i in sched.idle {
		if i != int(self.index) {
			arch_send_resched(&cpus[i])
		}
	}
}

// Fills the throttled contexts whose periods have ended: their threads may
// run again.
@(private="file")
refill_due :: proc "contextless" (now: Instant) {
	any := false
	for x := sched.throttled; x != nil; {
		next := x.th_next
		if now >= x.period_end {
			ctx_refill(x, now)
			any = true
		}
		x = next
	}
	if any {
		kick_idle()
	}
}

@(private="file")
sleep_remove :: proc "contextless" (t: ^Thread) {
	if t.sleep_cpu == nil {
		return
	}
	unlink(&t.sleep_cpu.sleepers, t, "sleep_next")
	t.sleep_next = nil
	t.sleep_cpu = nil
}

// Makes a blocked thread ready, and gets a CPU to it (kick_for). Called with
// the lock held.
@(private="file")
make_ready :: proc "contextless" (t: ^Thread) {
	sleep_remove(t)
	run_enqueue(t)
	kick_for(t)
}

// Makes t ready to run next here, where the current thread is about to block
// or to fall below it: a hand-off, if this CPU may run it; else as make_ready.
@(private="file")
make_ready_here :: proc "contextless" (t: ^Thread) {
	self := this_cpu()
	if !may_run(t, self) || (self.current != &self.idle && band_of(self.current) < band_of(t)) {
		make_ready(t)
		return
	}
	sleep_remove(t)
	run_push(t)
	self.resched = true
}

// Gets a CPU to a thread just queued: this one if it is idle and may run it,
// else an idle one that may, by interrupt, else the one running the lowest
// band below the thread's that may run it there. With none, the next slice
// to end picks it up.
@(private="file")
kick_for :: proc "contextless" (t: ^Thread) {
	self := this_cpu()
	if int(self.index) in sched.idle && may_run(t, self) {
		self.resched = true
		return
	}
	for i in sched.idle {
		if may_run(t, &cpus[i]) {
			sched.idle -= {i} // one interrupt per wake is enough
			arch_send_resched(&cpus[i])
			return
		}
	}
	// None idle: the CPU running the lowest band below t's, if it may run t there.
	worst := band_of(t)
	victim: ^Cpu
	for i in 0 ..< cpu_total {
		c := &cpus[i]
		if c.current == nil || c.current == &c.idle || !may_run(t, c) {
			continue
		}
		if b := band_of(c.current); b > worst {
			worst = b
			victim = c
		}
	}
	if victim == self {
		self.resched = true
	} else if victim != nil {
		arch_send_resched(victim)
	}
}

// --- Scheduling contexts (ADR-0016) ---

@(private="file")
RT_MIN_PERIOD :: Instant(1_000_000)
@(private="file")
RT_MAX_PERIOD :: Instant(10_000_000_000)
@(private="file")
RT_MIN_BUDGET :: Instant(100_000)
@(private="file")
RT_LIMIT_PPM :: u64(800_000) // of each CPU online

@(private="file", require_results)
params_check :: proc "contextless" (p: ^vx.Sched_Params, own: bool) -> vx.Status {
	if p.flags != 0 || p.intent < .Realtime || p.intent > .Background {
		return .Err_Invalid
	}
	if p.intent != .Realtime {
		return p.period != 0 || p.budget != 0 ? .Err_Invalid : .Ok
	}
	if own {
		return .Err_Invalid // a thread's own intent is never realtime: that needs a context
	}
	period, budget := Instant(p.period), Instant(p.budget)
	if period < RT_MIN_PERIOD || period > RT_MAX_PERIOD || budget < RT_MIN_BUDGET || budget > period {
		return .Err_Invalid
	}
	return .Ok
}

@(private="file")
params_ppm :: proc "contextless" (p: ^vx.Sched_Params) -> u64 {
	if p.intent != .Realtime {
		return 0
	}
	return u64(p.budget) * 1_000_000 / u64(p.period) // at most 1e16: no overflow
}

// Admits a share of `ppm`, given back `old` it had: false if they do not
// fit. Under the scheduler's lock.
@(private="file")
admit :: proc "contextless" (ppm, old: u64) -> bool {
	limit := RT_LIMIT_PPM * u64(intrinsics.atomic_load_explicit(&cpus_online, .Relaxed))
	return sched.admitted_ppm - old + ppm <= limit
}

@(private="file")
ctx_apply :: proc "contextless" (x: ^Sched_Ctx, p: ^vx.Sched_Params, ppm: u64, now: Instant) {
	x.intent = p.intent
	x.period, x.budget = Instant(p.period), Instant(p.budget)
	x.ppm = ppm
	x.left = x.budget
	x.period_end = now + x.period
}

// A new context, a realtime one admitted or .Err_Refused.
@(require_results)
sched_ctx_create :: proc "contextless" (p: ^vx.Sched_Params) -> (x: ^Sched_Ctx, st: vx.Status) {
	params_check(p, false) or_return
	x = pool_alloc(&sched_ctx_pool)
	if x == nil {
		return nil, .Err_No_Memory
	}
	object_init(&x.obj, .Sched_Ctx)
	ppm := params_ppm(p)
	spin_lock(&sched.lock)
	fits := admit(ppm, 0)
	if fits {
		sched.admitted_ppm += ppm
		ctx_apply(x, p, ppm, clock_now())
	}
	spin_unlock(&sched.lock)
	if !fits {
		pool_free(&sched_ctx_pool, x)
		return nil, .Err_Refused
	}
	return x, .Ok
}

// Gives back the CPUs x reserved: what ran there may run anywhere again.
@(private="file")
unreserve_locked :: proc "contextless" (x: ^Sched_Ctx) {
	for i in x.reserved {
		cpus[i].reserved = nil
		if &cpus[i] != this_cpu() {
			arch_send_resched(&cpus[i])
		}
	}
	x.reserved = {}
}

// Its last handle and its last bound thread are gone: its share and its
// CPUs go with it.
sched_ctx_destroy :: proc "contextless" (x: ^Sched_Ctx) {
	spin_lock(&sched.lock)
	sched.admitted_ppm -= x.ppm
	unreserve_locked(x)
	unlink(&sched.throttled, x, "th_next")
	spin_unlock(&sched.lock)
	pool_free(&sched_ctx_pool, x)
}

// Changes x, a realtime one admitted again; refused, it keeps what it had.
@(require_results)
sched_ctx_set :: proc "contextless" (x: ^Sched_Ctx, p: ^vx.Sched_Params) -> vx.Status {
	params_check(p, false) or_return
	ppm := params_ppm(p)
	spin_guard(&sched.lock)
	if !admit(ppm, x.ppm) {
		return .Err_Refused
	}
	sched.admitted_ppm = sched.admitted_ppm - x.ppm + ppm
	ctx_apply(x, p, ppm, clock_now())
	// Filled, whatever its intent now. Spent, it is let go at once: a refill
	// fills only a realtime one, so one reconfigured to another intent would
	// stay throttled for ever (UPSTREAM-FINDINGS; upstream's 6319e48 fixed it
	// so).
	if x.throttled {
		x.throttled = false
		unlink(&sched.throttled, x, "th_next")
		x.th_next = nil
		kick_idle()
	}
	return .Ok
}

// The calling thread's own intent (rt.intent_set): anything but realtime.
@(require_results)
sched_set_own :: proc "contextless" (t: ^Thread, p: ^vx.Sched_Params) -> vx.Status {
	params_check(p, true) or_return
	spin_guard(&sched.lock)
	t.intent = p.intent
	return .Ok
}

// Binds t to x (nil: unbinds it), on a CPU of x's reservation or none (a
// negative core). The thread holds a reference to its context while bound.
@(require_results)
sched_bind :: proc "contextless" (t: ^Thread, x: ^Sched_Ctx, core: i32) -> vx.Status {
	if core >= 0 && (x == nil || u32(core) >= cpu_total) {
		return .Err_Invalid
	}
	if x != nil {
		object_ref(&x.obj)
	}
	spin_lock(&sched.lock)
	if core >= 0 && int(core) not_in x.reserved {
		spin_unlock(&sched.lock)
		object_release(&x.obj)
		return .Err_Invalid // not a CPU it reserved
	}
	old := t.ctx
	t.ctx = x
	t.core = core >= 0 ? u32(core) : nil
	// A thread bound elsewhere moves: on its next switch, or now if it runs here.
	if t.state == .Running && t.cpu != nil && !may_run(t, t.cpu) {
		if t.cpu == this_cpu() {
			t.cpu.resched = true
		} else {
			arch_send_resched(t.cpu)
		}
	}
	spin_unlock(&sched.lock)
	if old != nil {
		object_release(&old.obj)
	}
	return .Ok
}

// A dying thread's context, taken from it: its caller drops the reference
// (object_drop in a destructor, object_release elsewhere).
sched_unbind_dead :: proc "contextless" (t: ^Thread) -> ^Sched_Ctx {
	spin_guard(&sched.lock)
	x := t.ctx
	t.ctx = nil
	t.core = nil
	return x
}

// Reserves `count` whole CPUs for x, or with 0 gives back its own: all or
// .Err_Refused. The first CPU is never reserved; nor is one another context
// has.
@(require_results)
sched_reserve_cpus :: proc "contextless" (x: ^Sched_Ctx, count: u32) -> (set: vx.Core_Set, st: vx.Status) {
	spin_guard(&sched.lock)
	unreserve_locked(x)
	got: Cpu_Set
	n: u32
	online := intrinsics.atomic_load_explicit(&cpus_online, .Relaxed)
	for i := online; i > 1 && n < count; { // from the last, keeping the first shared
		i -= 1
		if cpus[i].reserved == nil {
			got += {int(i)}
			n += 1
		}
	}
	if n < count {
		return {}, .Err_Refused
	}
	x.reserved = got
	for i in got {
		cpus[i].reserved = x
		if &cpus[i] == this_cpu() {
			cpus[i].resched = true
		} else {
			arch_send_resched(&cpus[i]) // what runs there leaves
		}
	}
	return {mask = transmute(u64)got, count = n}, .Ok
}

// What thread_state's .Get_Sched gives, and /proc/N/threads/T/sched shows.
sched_info :: proc "contextless" (t: ^Thread) -> vx.Sched_Info {
	spin_guard(&sched.lock)
	from := sched_source(t)
	x := from.ctx // what it runs on: its own, or a loan's
	info := vx.Sched_Info {
		intent = thread_intent(t),
		core   = -1,
		bound  = t.ctx != nil ? 1 : 0,
	}
	if b, ok := bound_cpu(t).?; ok {
		info.core = i32(b)
	}
	if x != nil {
		info.period, info.budget = vx.Duration(x.period), vx.Duration(x.budget)
		info.exhausted = x.exhausted
		if x.intent == .Realtime && x.left > 0 {
			info.left = vx.Duration(x.left)
		}
	}
	if t.ctx != nil {
		info.reserved = transmute(u64)t.ctx.reserved
		info.reserved_count = u32(card(t.ctx.reserved))
	}
	if from != t {
		info.lent_task = from.task != nil ? from.task.id : 0
		info.lent_thread = u64(from.id)
	}
	return info
}

// --- Donation (6d6c2) ---

// Ends the loan t, a caller, made: its call is over. Under the lock.
@(private="file")
unlend_locked :: proc "contextless" (t: ^Thread) {
	if t.donee == nil {
		return
	}
	if t.donee.donor == t {
		t.donee.donor = nil
		t.donee.lend_tail = false
	}
	t.donee = nil
}

// Ends the loan t runs on, if its call was answered: t has blocked, or used
// its slice, since.
@(private="file")
tail_end :: proc "contextless" (t: ^Thread) {
	if !t.lend_tail {
		return
	}
	t.lend_tail = false
	if t.donor != nil && t.donor.donee == t {
		t.donor.donee = nil
	}
	t.donor = nil
}

// from, in channel_call, lends its scheduling to `to`, which serves its
// call: moved from where it was, and kept from to's loan if that is higher.
// Never in a loop: from lending to a thread lending, along its chain, to from.
@(private="file")
lend_locked :: proc "contextless" (from, to: ^Thread) {
	if from == to || from.donee == to {
		return
	}
	unlend_locked(from)
	o := from.donor
	for i := 0; i < LEND_DEPTH && o != nil; i, o = i + 1, o.donor {
		if o == to {
			return
		}
	}
	if to.donor != nil {
		if band_of(to.donor) <= band_of(from) {
			return // what it has is as high
		}
		to.donor.donee = nil
	}
	to.donor = from
	from.donee = to
	to.lend_tail = false
}

// The reader of a call's request serves it: the caller's scheduling is lent
// to it.
sched_lend :: proc "contextless" (from, to: ^Thread) {
	spin_guard(&sched.lock)
	lend_locked(from, to)
}

// t's call is over. Unanswered, its loan ends; answered, the server keeps it
// as a tail until it blocks (tail_end), which a new call of t's, or t's end,
// cuts short.
sched_unlend :: proc "contextless" (t: ^Thread) {
	spin_guard(&sched.lock)
	if t.donee == nil || t.donee.donor != t || !t.donee.lend_tail {
		unlend_locked(t)
	}
}

// While a channel_call delivers its request: the port waiter it wakes is lent
// to (thread_wake_token). Under the channel's lock, interrupts off.
sched_lending :: proc "contextless" (caller: ^Thread) {
	this_cpu().lending = caller
}

// Wakes a channel_call caller with its reply: its loan ended (the server
// keeps it until it blocks), and run next here, in the replier's place, if
// this CPU may.
thread_wake_reply :: proc "contextless" (t: ^Thread, token: rawptr, result: vx.Status) -> bool {
	spin_guard(&sched.lock)
	if t.donee != nil && t.donee.donor == t {
		t.donee.lend_tail = true // until it blocks
	}
	if token == nil || t.wait_token != token {
		return false
	}
	t.wait_token = nil
	if t.state == .Blocked {
		t.wait_result = result
		make_ready_here(t)
	} else {
		t.pending_result = result
		t.wake_pending = true
	}
	return true
}

// Switches to the next ready thread, or to this CPU's idle thread. Called with
// the lock held; returns, with it released, when the current thread runs
// again. A running thread goes back on the queue; a blocked or dead one does
// not.
@(private="file")
schedule_locked :: proc "contextless" () {
	c := this_cpu()
	prev := c.current
	now := clock_now()
	if prev != &c.idle {
		_ = charge(c, now)
	}
	if prev.state == .Running && prev != &c.idle {
		run_enqueue(prev)
		if !may_run(prev, c) {
			kick_for(prev) // bound elsewhere since, or this CPU reserved: another must take it
		}
	}
	next := run_dequeue(c)
	if next == nil {
		next = &c.idle
	}
	c.run_start = now
	c.resched = false
	if next == &c.idle {
		sched.idle += {int(c.index)}
	} else {
		sched.idle -= {int(c.index)}
		c.slice_end = now + TIME_SLICE
		if c.tick_at <= now {
			c.tick_at = now + TICK // leaving idle: ticks start again
		}
		if x := ctx_of(next); x != nil {
			ctx_refill(x, now)
		}
	}
	if next != prev {
		user_switch(prev, next)
		next.state = .Running
		next.cpu = c
		c.current = next
		if next.task != nil {
			arch_set_kernel_stack(thread_kstack_top(next))
		}
		// Leave a task's address space even for the idle thread, so a dead
		// task's tables are on no CPU by the time its last thread is reaped.
		if prev.task != next.task {
			load_user_root(c, next.task != nil ? next.task.root : 0)
			arch_io_switch(next.task)
		}
	} else {
		prev.state = .Running
	}
	sched_arm_timer(c)
	if next == prev {
		spin_unlock(&sched.lock)
		return
	}
	arch_context_switch(&prev.kernel_sp, next.kernel_sp)
	reap_after_switch()
}

// A user thread's state that traps do not save: the thread pointer (x86_64's
// FS base, aarch64's TPIDR_EL0), saved and loaded with each switch between
// threads; and its protection-key rights (ADR-0035), live in the register
// while the kernel runs for it, so its copies to and from user memory obey
// them. (Its vector state is in its trap frame: ADR-0004.) Idle threads
// have none: whoever ran last leaves its thread pointer in place, unused,
// until the next user thread loads its own. A thread stopped at an
// exception has saved its own (user_held): what a debugger set there since
// is not overwritten.
@(private="file")
user_switch :: proc "contextless" (prev, next: ^Thread) {
	if prev.task != nil && !prev.user_held {
		prev.tls = arch_tls_read()
	}
	if prev.task != nil {
		prev.rights = arch_rights_read()
	}
	if next.task != nil {
		arch_tls_write(next.tls)
		arch_rights_write(next.rights)
		arch_watch_load(next.task)
	}
}

schedule :: proc "contextless" () {
	spin_lock(&sched.lock)
	schedule_locked()
}

// A thread waits on a token: whatever it queued itself on, such as a port, a
// pending channel_call or a futex. It sets its token, joins that thing's list
// of waiters under the thing's own lock, and then blocks.

// Wakes t with `result` if it still waits on `token`, and not if it has
// stopped waiting (its deadline passed first, or it is being killed). A
// thread between joining a list and blocking keeps the wake for thread_block
// to find. Returns whether it woke.
thread_wake_token :: proc "contextless" (t: ^Thread, token: rawptr, result: vx.Status) -> bool {
	spin_lock(&sched.lock)
	defer spin_unlock(&sched.lock)
	if token == nil || t.wait_token != token {
		return false
	}
	t.wait_token = nil
	self := this_cpu()
	caller := self.lending
	if caller != nil { // the first woken serves the call
		lend_locked(caller, t)
		self.lending = nil
	}
	if t.state == .Blocked {
		t.wait_result = result
		if caller != nil && t.donor == caller {
			make_ready_here(t) // the caller is about to block: run the server in its place
		} else {
			make_ready(t)
		}
	} else {
		t.pending_result = result // for its block, which returns at once
		t.wake_pending = true
	}
	return true
}

// Blocks the current thread until it is woken, or until the deadline (plus
// up to `leeway`, which lets one timer interrupt serve several waits).
// Returns the wait's result: .Err_Timed_Out if the deadline passed.
@(require_results)
thread_block :: proc "contextless" (deadline: Instant, leeway: Instant) -> vx.Status {
	c := this_cpu()
	t := c.current
	spin_lock(&sched.lock)
	if t.wake_pending { // woken before it got here
		t.wake_pending = false
		t.wait_result = t.pending_result
		// This wait is over: a waker that comes later (a channel reply before
		// the caller has left the list) must not end the next one, which may
		// use the same token, a record at the same place on this stack.
		t.wait_token = nil
		spin_unlock(&sched.lock)
		return t.wait_result
	}
	tail_end(t) // an answered call's loan ends as its server waits again
	t.state = .Blocked
	if deadline != INFINITE {
		t.wake_at = deadline
		t.wake_late = leeway > 0 && deadline <= INFINITE - leeway ? deadline + leeway : deadline
		t.sleep_cpu = c
		link := &c.sleepers
		for link^ != nil && link^.wake_at <= deadline {
			link = &link^.sleep_next
		}
		t.sleep_next = link^
		link^ = t
	}
	schedule_locked()
	return t.wait_result
}

// Arms this CPU's timer for the next thing that needs it: its earliest
// sleeper's latest acceptable wake-up, the end of the running thread's slice
// or of its context's budget, or the next period of a spent context.
@(private="file")
sched_arm_timer :: proc "contextless" (c: ^Cpu) {
	next := INFINITE
	for t := c.sleepers; t != nil; t = t.sleep_next {
		next = min(next, t.wake_late)
	}
	if c.current != &c.idle {
		next = min(next, c.slice_end)
		next = min(next, c.tick_at)
		if x := ctx_of(c.current); x != nil && x.intent == .Realtime && !x.throttled {
			next = min(next, c.run_start + x.left) // its budget runs out
		}
	}
	for x := sched.throttled; x != nil; x = x.th_next {
		next = min(next, x.period_end) // a spent context fills again
	}
	if next != INFINITE {
		timer_arm(next)
	}
}

// This CPU's timer fired (time.odin): charge the running thread the ticks
// due, to user or system time by where the interrupt came from (from_user),
// wake its sleepers whose deadlines have passed, fill the contexts whose
// periods have come, charge the running thread's, and end the slice if
// others of its band or above are waiting.
sched_timer :: proc "contextless" (from_user: bool) {
	c := this_cpu()
	if c.current == nil {
		return // before the scheduler runs on this CPU
	}
	spin_lock(&sched.lock)
	now := clock_now()
	if c.current != &c.idle && now >= c.tick_at { // the ticks due, all to where it was found
		n := 1 + u64((now - c.tick_at) / TICK)
		intrinsics.atomic_add_explicit(&c.current.ticks[from_user ? .User : .Sys], n, .Relaxed)
		c.tick_at += Instant(n) * TICK
	}
	for c.sleepers != nil && c.sleepers.wake_at <= now {
		t := c.sleepers
		t.wait_token = nil // a waker that finds it later skips it
		t.wait_result = .Err_Timed_Out
		make_ready(t)
	}
	refill_due(now)
	if c.current != &c.idle && charge(c, now) {
		c.resched = true // its context's budget is spent
	}
	if now >= c.slice_end {
		// The slice is over: switch if someone of its band or above is
		// waiting, else give the running thread another one. (Re-arming the
		// old, expired end would fire at once, for ever, and the thread would
		// never get back to user mode.) An answered call's loan ends here too.
		if c.current != &c.idle && c.current.lend_tail {
			tail_end(c.current)
			c.resched = true
		}
		if c.current == &c.idle || ready_for(c, band_of(c.current)) {
			c.resched = true
		} else {
			c.slice_end = now + TIME_SLICE
		}
	}
	// A thread running on a CPU reserved since, or on one it may run on no
	// more, leaves it.
	if c.current != &c.idle && !may_run(c.current, c) {
		c.resched = true
	}
	sched_arm_timer(c)
	spin_unlock(&sched.lock)
}

// A CPU's idle loop: run whatever is ready, else sleep until an interrupt.
sched_idle_loop :: proc "contextless" () -> ! {
	c := this_cpu()
	for {
		schedule()
		if !c.resched {
			arch_wait()
		}
	}
}

// Makes the calling context this CPU's idle thread.
sched_enter_cpu :: proc "contextless" () {
	c := this_cpu()
	c.idle.state = .Running
	c.current = &c.idle
}

sched_start_thread :: proc "contextless" (t: ^Thread) {
	spin_lock(&sched.lock)
	make_ready(t)
	spin_unlock(&sched.lock)
}

// The first time a thread runs, the context switch returns into the
// architecture's trampoline, which calls this with the lock still held from
// the switch. It never returns: it enters user mode.
// One suspended before it ever ran parks on its first way back to the
// kernel, its user registers in place (thread_suspend pokes it until it
// does); one whose task was killed meanwhile ends here.
@(export, link_name="thread_entry")
thread_entry :: proc "c" (t: ^Thread) -> ! {
	reap_after_switch()
	if t.task.killed {
		thread_exit_current()
	}
	arch_enter_user(t.user_entry, t.user_sp, t.user_arg, t.user_arg2, thread_kstack_top(t))
}

// Starts the report of a fault that kills the current thread:
// "vx: task 1 (svcd) killed: " and whatever the caller adds.
task_fault_start :: proc "contextless" () {
	t := this_cpu().current.task
	kput("vx: task ")
	kput_u64(t.id)
	kput(" (")
	kput(task_name(t))
	kput(") killed: ")
}

// Ends the current thread: it is never scheduled again, and the next thread
// to run on this CPU reaps it. The caller has already accounted for it in its
// task (process.odin).
sched_exit_current :: proc "contextless" () -> ! {
	spin_lock(&sched.lock)
	c := this_cpu()
	unlend_locked(c.current) // its loans end, both ways
	c.current.lend_tail = true
	tail_end(c.current)
	c.current.state = .Dead
	c.reap = c.current
	schedule_locked()
	kpanic("a dead thread was scheduled")
}

// Gets a thread running user code on another CPU into the kernel, to notice
// something on its way back (a suspension); a thread anywhere else needs
// nothing.
sched_poke :: proc "contextless" (t: ^Thread) {
	spin_guard(&sched.lock)
	if t.state == .Running && t.cpu != nil && t.cpu != this_cpu() {
		arch_send_resched(t.cpu)
	}
}

// Gets a thread to notice a kill (process.odin) or an interrupt
// (exception.odin): a blocked thread wakes with `why`, wherever it waits; one
// running user code on another CPU gets an interrupt, and checks on its way
// back to user mode. A kill is never downgraded to an interrupt.
sched_kick :: proc "contextless" (t: ^Thread, why: vx.Status) {
	spin_guard(&sched.lock)
	why := why
	if t.wake_pending && t.pending_result == .Err_Killed {
		why = .Err_Killed // a kill outranks the rest
	}
	if t.state == .Blocked {
		t.wait_token = nil
		t.wait_result = why
		make_ready(t)
	} else if t.state != .Dead {
		// Ready, or running here or elsewhere: if it is about to block, the
		// block returns at once; if it is in user mode on another CPU,
		// interrupt it. Its next block's result is pending_result, never
		// wait_result: a wait that has already ended (a reply handed to it,
		// say) keeps its own. A wake already pending with a result (a packet
		// taken, a futex woken) stands, but against a kill: the waker counted
		// it as woken, and the interrupt is not lost, as the thread takes it
		// on its way back to user mode.
		if !t.wake_pending || t.pending_result < .Ok || why == .Err_Killed {
			t.pending_result = why
		}
		t.wake_pending = true
		if t.state == .Running && t.cpu != nil && t.cpu != this_cpu() {
			arch_send_resched(t.cpu)
		}
	}
}

// An interrupt is being delivered (exception.odin): the wake it left pending
// must not end the thread's next wait as well.
sched_drop_interrupt_wake :: proc "contextless" (t: ^Thread) {
	spin_guard(&sched.lock)
	if t.wake_pending && t.pending_result == .Err_Interrupted {
		t.wake_pending = false
	}
}
