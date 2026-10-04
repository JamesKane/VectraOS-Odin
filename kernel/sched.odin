package kernel

import "base:intrinsics"
import vx "abi:vx"

// The v1 scheduler. Every CPU serves one shared ready queue round robin; each
// CPU keeps the threads that blocked on it, with a deadline, in its own sleep
// queue, and runs a user thread for at most a 10 ms slice while others wait.
// One lock covers all of it. Per-CPU ready queues, intents, priority bands and
// the realtime class come later.
//
// The kernel runs with interrupts off. They are on only in user mode and in
// an idle thread's wait. A CPU with nothing to run sleeps with no timer armed
// unless a sleeper needs one; a thread made ready while it sleeps reaches it
// as a reschedule interrupt (arch_send_resched).
//
// The lock is held across a context switch and released by whichever thread
// runs next, so a thread queued by one CPU cannot be picked up by another
// before its registers are saved.

TIME_SLICE :: Instant(10_000_000)
INFINITE :: Instant(vx.INFINITE) // a deadline that never comes

Cpu :: struct {
	index:      u32, // 0 is the boot CPU
	arch_id:    u64, // local APIC ID, or MPIDR affinity
	current:    ^Thread,
	idle:       Thread, // runs when nothing else can; the boot context on CPU 0
	sleepers:   ^Thread, // blocked here with a deadline, earliest first
	slice_end:  Instant,
	resched:    bool, // call schedule before returning to user mode
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

// Loads a task's tables on this CPU (0: none), counted for shootdowns.
load_user_root :: proc "contextless" (c: ^Cpu, root: Paddr) {
	intrinsics.atomic_store_explicit(&c.user_root, root, .Relaxed)
	arch_switch_user_root(root)
	intrinsics.atomic_add_explicit(&c.root_loads, 1, .Release)
}

@(private="file")
sched: struct {
	lock:      Spinlock,
	run_queue: Fifo(Thread),
	idle:      bit_set[0 ..< MAX_CPUS; u64], // CPUs running their idle threads
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

@(private="file")
run_enqueue :: proc "contextless" (t: ^Thread) {
	t.state = .Ready
	fifo_push(&sched.run_queue, t)
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

// Makes a blocked thread ready, and gets a CPU to it: this one if it is idle,
// otherwise an idle one, by interrupt. With none idle, the next slice to end
// picks it up. Called with the lock held.
@(private="file")
make_ready :: proc "contextless" (t: ^Thread) {
	sleep_remove(t)
	run_enqueue(t)
	self := this_cpu()
	if int(self.index) in sched.idle {
		self.resched = true
		return
	}
	for i in sched.idle {
		sched.idle -= {i} // one interrupt per wake is enough
		arch_send_resched(&cpus[i])
		return
	}
}

// Switches to the next ready thread, or to this CPU's idle thread. Called with
// the lock held; returns, with it released, when the current thread runs
// again. A running thread goes back on the queue; a blocked or dead one does not.
@(private="file")
schedule_locked :: proc "contextless" () {
	c := this_cpu()
	prev := c.current
	if prev.state == .Running && prev != &c.idle {
		run_enqueue(prev)
	}
	next := fifo_pop(&sched.run_queue)
	if next == nil {
		next = &c.idle
	}
	c.resched = false
	if next == &c.idle {
		sched.idle += {int(c.index)}
	} else {
		sched.idle -= {int(c.index)}
		c.slice_end = clock_now() + TIME_SLICE
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
// threads. (Its vector state is in its trap frame: ADR-0004.) Idle threads
// have none: whoever ran last leaves its thread pointer in place, unused,
// until the next user thread loads its own. A thread stopped at an
// exception has saved its own (user_held): what a debugger set there since
// is not overwritten.
@(private="file")
user_switch :: proc "contextless" (prev, next: ^Thread) {
	if prev.task != nil && !prev.user_held {
		prev.tls = arch_tls_read()
	}
	if next.task != nil {
		arch_tls_write(next.tls)
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
	if t.state == .Blocked {
		t.wait_result = result
		make_ready(t)
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
// sleeper's latest acceptable wake-up, or the end of the running thread's slice.
@(private="file")
sched_arm_timer :: proc "contextless" (c: ^Cpu) {
	next := INFINITE
	for t := c.sleepers; t != nil; t = t.sleep_next {
		next = min(next, t.wake_late)
	}
	if c.current != &c.idle {
		next = min(next, c.slice_end)
	}
	if next != INFINITE {
		timer_arm(next)
	}
}

// This CPU's timer fired (time.odin): wake its sleepers whose deadlines have
// passed, and end the slice if others are waiting.
sched_timer :: proc "contextless" () {
	c := this_cpu()
	if c.current == nil {
		return // before the scheduler runs on this CPU
	}
	spin_lock(&sched.lock)
	now := clock_now()
	for c.sleepers != nil && c.sleepers.wake_at <= now {
		t := c.sleepers
		t.wait_token = nil // a waker that finds it later skips it
		t.wait_result = .Err_Timed_Out
		make_ready(t)
	}
	if now >= c.slice_end {
		// The slice is over: switch if someone is waiting, else give the
		// running thread another one. (Re-arming the old, expired end would
		// fire at once, for ever, and the thread would never get back to user
		// mode.)
		if sched.run_queue.head != nil {
			c.resched = true
		} else {
			c.slice_end = now + TIME_SLICE
		}
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
