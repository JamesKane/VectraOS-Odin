package kernel

import vx "abi:vx"

// How threads and tasks start, end and are killed.
//
// A task runs while it has live threads. When the last one exits, or the
// task is killed, the task is .Exited: its handles are closed, its mappings
// dropped and its page tables freed, and its EXIT bindings fire with its exit
// status. The task object itself lives on while anything holds a handle to
// it, so its status can still be read.
//
// A thread cannot free the kernel stack it runs on, so a dead thread is
// reaped by the next thread to run on its CPU (sched.odin), and the teardown
// of a task whose last thread died happens there too. By then that CPU has
// left the task's address space, as every CPU that ran its threads already has.
//
// Killing marks the task and kicks its threads (sched_kick_for_kill). Each
// one exits the next time it heads back to user mode (user_return).

EXIT_FAULT :: i64(-1) // the status of a task killed by a fault

@(require_results)
task_bind :: proc "contextless" (t: ^Task, b: ^Binding) -> vx.Status {
	if b.trigger != .Exit {
		return .Err_Invalid
	}
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	if t.state == .Exited {
		binding_fire(b, u64(t.exit_status))
	} else {
		observers_add(&t.obs, b)
	}
	return .Ok
}

// Closes the task's handles, drops its mappings, frees its page tables and
// fires its EXIT bindings. Its threads are all dead and no CPU uses its
// address space.
@(private="file")
task_teardown :: proc "contextless" (t: ^Task) {
	for &e in t.handles { // no one adds to an ending task's table
		obj := e.obj
		e.obj = nil
		if obj != nil {
			object_drop(obj)
		}
	}
	for m in t.maps {
		if m.size != 0 {
			object_drop(&m.vmo.obj)
		}
	}
	free_user_tables(t.root)
	phys_free(virt_to_phys(t.maps), 0)
	phys_free(virt_to_phys(t.handles), 0)
	spin_lock(&t.lock)
	t.root = 0
	t.maps = nil
	t.handles = nil
	t.mapped = 0
	t.state = .Exited // only now: an EXIT binding sees the task fully gone
	observers_fire(&t.obs, .Exit, u64(t.exit_status))
	spin_unlock(&t.lock)
}

// Starts a thread that has not started: user mode at entry, with sp and two
// arguments. The thread holds a reference to itself until it is reaped.
@(require_results)
thread_start :: proc "contextless" (th: ^Thread, entry, sp: Uva, arg, arg2: u64) -> vx.Status {
	t := th.task
	{
		spin_guard(&t.lock)
		if th.state != .New || th.user_entry != 0 || t.ending || t.killed {
			return .Err_Bad_State
		}
		th.user_entry = entry
		th.user_sp = sp
		th.user_arg = arg
		th.user_arg2 = arg2
		t.live_threads += 1
		t.state = .Running
		th.task_next = t.threads
		t.threads = th
		object_ref(&th.obj)
	}
	sched_start_thread(th)
	return .Ok
}

// Ends the current thread with an exit status; the last thread's status, or
// a kill's, becomes the task's.
thread_exit_current :: proc "contextless" (status: i64) -> ! {
	th := this_cpu().current
	t := th.task
	spin_lock(&t.lock)
	if !t.killed && t.live_threads == 1 {
		t.exit_status = status
	}
	t.live_threads -= 1
	th.last_of_task = t.live_threads == 0
	if th.last_of_task {
		t.ending = true
	}
	spin_unlock(&t.lock)
	sched_exit_current()
}

// A dead thread's last rites, run by the next thread on its CPU (sched.odin).
thread_reap :: proc "contextless" (th: ^Thread) {
	kstack_free(th.kstack)
	th.kstack = 0
	t := th.task
	spin_lock(&t.lock)
	for link := &t.threads; link^ != nil; link = &link^.task_next {
		if link^ == th {
			link^ = th.task_next
			break
		}
	}
	spin_unlock(&t.lock)
	if th.last_of_task {
		task_teardown(t)
	}
	object_release(&th.obj) // the reference it held while running
}

// Kills a task: its exit status is `status`, and its threads exit when they
// next head for user mode. A task with no live threads ends at once.
task_kill :: proc "contextless" (t: ^Task, status: i64) {
	spin_lock(&t.lock)
	if t.ending || t.killed {
		spin_unlock(&t.lock)
		return
	}
	t.killed = true
	t.exit_status = status
	idle := t.live_threads == 0
	if idle {
		t.ending = true
	}
	for th := t.threads; th != nil; th = th.task_next {
		sched_kick_for_kill(th)
	}
	spin_unlock(&t.lock)
	if idle {
		task_teardown(t)
	}
}

// Every trap from user mode ends here before returning to it: a killed
// task's thread exits, and a pending reschedule happens.
user_return :: proc "contextless" () {
	object_drain() // what this trap dropped
	for {
		c := this_cpu()
		t := c.current.task
		if t.killed {
			thread_exit_current(t.exit_status)
		}
		if !c.resched {
			return
		}
		schedule() // and look again: a kill may have come meanwhile
	}
}

// A fault in user mode kills the whole task (until exception ports, no one
// else could handle it).
task_fault_exit :: proc "contextless" () -> ! {
	task_kill(this_cpu().current.task, EXIT_FAULT)
	thread_exit_current(EXIT_FAULT)
}

// The last reference is gone. Threads hold references to their task, so it
// either never started a thread or has already ended; one that never started
// still has its address space and handle table to give back.
task_destroy :: proc "contextless" (t: ^Task) {
	if t.root != 0 {
		t.ending = true
		task_teardown(t)
	}
	observers_free(t.obs.head) // none can be left once the task has ended, but be sure
	task_unlist(t)
	pool_free(&task_pool, t)
}

thread_destroy :: proc "contextless" (th: ^Thread) {
	if th.kstack != 0 {
		kstack_free(th.kstack) // never started
	}
	t := th.task
	pool_free(&thread_pool, th)
	object_drop(&t.obj)
}
