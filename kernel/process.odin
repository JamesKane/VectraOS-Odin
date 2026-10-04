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
EXIT_NO_MEMORY :: i64(-2) // a fork the kernel could not finish

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
	// The tables leave the task under its lock, so a handle_add or task_map on
	// another CPU (through a handle to this task) sees them gone, never freed.
	spin_lock(&t.lock)
	handles, maps, root := t.handles, t.maps, t.root
	t.handles = nil
	t.maps = nil
	t.root = 0
	t.mapped = 0
	exc_port, dbg_port := t.exc_port, t.dbg_port
	t.exc_port, t.dbg_port = nil, nil
	t.exc_handler = 0
	spin_unlock(&t.lock)
	if exc_port != nil {
		object_drop(&exc_port.obj)
	}
	if dbg_port != nil {
		object_drop(&dbg_port.obj)
	}
	for e in handles[1:] {
		if e.obj != nil {
			object_drop(e.obj)
		}
	}
	for m in maps {
		if m.size != 0 {
			object_drop(&m.vmo.obj)
		}
	}
	free_user_tables(root)
	phys_free(virt_to_phys(maps), 0)
	phys_free(virt_to_phys(handles), 0)
	spin_lock(&t.lock)
	t.state = .Exited // only now: an EXIT binding sees the task fully gone
	observers_fire(&t.obs, .Exit, u64(t.exit_status))
	spin_unlock(&t.lock)
}

// Starts a thread that has not started: user mode at entry, with sp and two
// arguments. The thread holds a reference to itself until it is reaped.
@(require_results)
thread_start :: proc "contextless" (th: ^Thread, entry, sp: Uva, arg, arg2: u64) -> vx.Status {
	// Both in the lower half: a non-canonical address would fault on the way
	// to user mode, in the kernel (x86_64's iretq), not in the task.
	if entry >= USER_TOP || sp > USER_TOP {
		return .Err_Invalid
	}
	t := th.task
	{
		spin_guard(&t.lock)
		if th.state != .New || th.started || t.ending || t.killed {
			return .Err_Bad_State
		}
		th.started = true // under the task's lock: one start, even with entry 0
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
	th.exited = true
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
	t := th.task
	spin_lock(&t.lock) // off the task's list first: nothing that walks it finds a freed stack
	unlink(&t.threads, th, "task_next")
	spin_unlock(&t.lock)
	kstack_free(th.kstack)
	th.kstack = 0
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
		sched_kick(th, .Err_Killed)
	}
	spin_unlock(&t.lock)
	if idle {
		task_teardown(t)
	}
}

// Every trap from user mode ends here before returning to it: a killed
// task's thread exits, a suspended one parks, a pending reschedule happens,
// and a note goes to the task's handler.
user_return :: proc "contextless" () {
	object_drain() // what this trap dropped
	for {
		c := this_cpu()
		t := c.current.task
		if t.killed {
			thread_exit_current(t.exit_status)
		}
		if exception_check_suspend() {
			continue // parked until resumed: look at the kill again
		}
		if !c.resched {
			break
		}
		schedule() // and look again: a kill may have come meanwhile
	}
	exception_check_interrupt() // a thread_interrupt, to its handler
}

// Ends the current thread's task with this exit status.
task_exit_with :: proc "contextless" (status: i64) -> ! {
	task_kill(this_cpu().current.task, status)
	thread_exit_current(status)
}

// A fault in user mode that no one handled kills the whole task.
task_fault_exit :: proc "contextless" (kind: vx.Exception_Kind, code: u32, address, pc: u64) -> ! {
	task_exit_with(EXIT_FAULT)
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
