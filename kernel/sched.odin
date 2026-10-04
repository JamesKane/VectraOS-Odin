package kernel

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
}

@(private="file")
sched: struct {
	lock:      Spinlock,
	run_head:  ^Thread,
	run_tail:  ^Thread,
	idle_mask: u64, // bit i: CPU i is running its idle thread
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
	t.next = nil
	if sched.run_tail != nil {
		sched.run_tail.next = t
	} else {
		sched.run_head = t
	}
	sched.run_tail = t
}

@(private="file")
run_dequeue :: proc "contextless" () -> ^Thread {
	t := sched.run_head
	if t != nil {
		sched.run_head = t.next
		if sched.run_head == nil {
			sched.run_tail = nil
		}
		t.next = nil
	}
	return t
}

@(private="file")
sleep_remove :: proc "contextless" (t: ^Thread) {
	if t.sleep_cpu == nil {
		return
	}
	for link := &t.sleep_cpu.sleepers; link^ != nil; link = &link^.sleep_next {
		if link^ == t {
			link^ = t.sleep_next
			break
		}
	}
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
	if sched.idle_mask & (1 << self.index) != 0 {
		self.resched = true
		return
	}
	for i in 0 ..< cpu_total {
		if sched.idle_mask & (1 << i) != 0 {
			sched.idle_mask &~= 1 << i // one interrupt per wake is enough
			arch_send_resched(&cpus[i])
			return
		}
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
	next := run_dequeue()
	if next == nil {
		next = &c.idle
	}
	c.resched = false
	if next == &c.idle {
		sched.idle_mask |= 1 << c.index
	} else {
		sched.idle_mask &~= 1 << c.index
		c.slice_end = clock_now() + TIME_SLICE
	}
	if next != prev {
		next.state = .Running
		next.cpu = c
		c.current = next
		if next.task != nil {
			arch_set_kernel_stack(thread_kstack_top(next))
		}
		// Leave a task's address space even for the idle thread, so a dead
		// task's tables are on no CPU by the time its last thread is reaped.
		if prev.task != next.task {
			arch_switch_user_root(next.task != nil ? next.task.root : 0)
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
thread_wake_token :: proc "contextless" (t: ^Thread, token: rawptr, result: i64) -> bool {
	spin_lock(&sched.lock)
	defer spin_unlock(&sched.lock)
	if token == nil || t.wait_token != token {
		return false
	}
	t.wait_token = nil
	t.wait_result = result
	if t.state == .Blocked {
		make_ready(t)
	} else {
		t.wake_pending = true
	}
	return true
}

// Blocks the current thread until it is woken, or until the deadline (plus
// up to `leeway`, which lets one timer interrupt serve several waits).
// Returns the wait's result: .Err_Timed_Out if the deadline passed.
thread_block :: proc "contextless" (deadline: Instant, leeway: Instant) -> i64 {
	c := this_cpu()
	t := c.current
	spin_lock(&sched.lock)
	if t.wake_pending { // woken before it got here
		t.wake_pending = false
		spin_unlock(&sched.lock)
		return t.wait_result
	}
	t.state = .Blocked
	if deadline != Instant(vx.INFINITE) {
		t.wake_at = deadline
		t.wake_late = leeway > 0 && deadline <= Instant(vx.INFINITE) - leeway ? deadline + leeway : deadline
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
	next := Instant(vx.INFINITE)
	for t := c.sleepers; t != nil; t = t.sleep_next {
		next = min(next, t.wake_late)
	}
	if c.current != &c.idle {
		next = min(next, c.slice_end)
	}
	if next != Instant(vx.INFINITE) {
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
		t.wait_result = i64(vx.Status.Err_Timed_Out)
		make_ready(t)
	}
	if now >= c.slice_end {
		// The slice is over: switch if someone is waiting, else give the
		// running thread another one. (Re-arming the old, expired end would
		// fire at once, for ever, and the thread would never get back to user
		// mode.)
		if sched.run_head != nil {
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
@(export, link_name="thread_entry")
thread_entry :: proc "c" (t: ^Thread) -> ! {
	reap_after_switch()
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

// Gets a thread of a task being killed to notice (process.odin): a blocked
// thread wakes with ERR_KILLED, wherever it waits; one running user code on
// another CPU gets an interrupt, and checks on its way back to user mode.
sched_kick_for_kill :: proc "contextless" (t: ^Thread) {
	spin_lock(&sched.lock)
	defer spin_unlock(&sched.lock)
	if t.state == .Blocked {
		t.wait_token = nil
		t.wait_result = i64(vx.Status.Err_Killed)
		make_ready(t)
	} else if t.state != .Dead {
		// Ready, or running here or elsewhere: if it is about to block, the
		// block returns at once; if it is in user mode on another CPU,
		// interrupt it.
		t.wake_pending = true
		t.wait_result = i64(vx.Status.Err_Killed)
		if t.state == .Running && t.cpu != nil && t.cpu != this_cpu() {
			arch_send_resched(t.cpu)
		}
	}
}
