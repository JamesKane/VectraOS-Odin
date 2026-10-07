package kernel

import "base:intrinsics"
import vx "abi:vx"

// Faults and interrupts in user mode, and who handles them (abi.odin
// describes the calls).
//
// A fault goes first to a debugger's port, if one is bound with
// .First_Chance: it may handle it, step the thread, kill it, or pass the
// fault on. Then to the task's in-task handler, if it has one: the kernel
// puts an Exception on the thread's own stack and diverts the thread to the
// handler, which resumes itself with exception_resume. If there is none, or
// the stack cannot take the frame, the fault goes to the task's exception
// port: the thread stops, a packet names it, and it waits until
// exception_resume continues it or kills it. Otherwise the architecture's
// default reports the fault and kills the task.
//
// thread_interrupt is the asynchronous kind: it posts a note (ADR-0010),
// which wakes whatever call the thread is blocked in with .Err_Interrupted,
// and on its way back to user mode the thread is diverted to the in-task
// handler with the note. A task with no handler ends with the note as its
// exit string, as a Plan 9 process that has not called notify does.
//
// The user-mode registers are the frame at the top of the thread's kernel
// stack, which a stopped thread does not touch: thread_state reads and
// writes them there, and the architecture checks what a write may set.

@(private="file")
RED_ZONE :: Uva(128) // x86_64's red zone; on aarch64 merely a margin

THREAD_MAX_INTERRUPTS :: 8

// A note waiting for delivery (thread_interrupt).
Note :: [dynamic; vx.ERRMAX]u8

// Puts e on the current thread's user stack and starts it at the task's
// handler. False if there is no handler, or no room on that stack.
@(private="file")
exception_divert :: proc "contextless" (f: ^Trap_Frame, e: ^vx.Exception) -> bool {
	handler := intrinsics.atomic_load_explicit(&current_task().exc_handler, .Relaxed)
	sp := regs_sp(&e.regs)
	// Its note stack, if it has one and is not on it already (a handler that
	// faults nests below itself there): a fault on an overflowed stack still
	// finds room (ADR-0036).
	th := this_cpu().current
	if lo, hi := th.note_stack, th.note_stack + Uva(th.note_stack_size); th.note_stack_size != 0 && !(sp > lo && sp <= hi) {
		sp = hi
	}
	if handler == 0 || sp < RED_ZONE + size_of(vx.Exception) + 64 || sp > USER_TOP {
		return false
	}
	at := (sp - RED_ZONE - size_of(vx.Exception)) &~ 15
	// The handler runs with key 0 opened, so it can use its stack and data;
	// the rights it interrupted go with the exception, and it writes them
	// back as it leaves (ADR-0035). Opened live, for the copy below, and in
	// the area user mode gets back.
	d := e^
	d.rights = arch_rights_read()
	arch_rights_write(arch_rights_open_key0(d.rights))
	arch_frame_set_rights(f, arch_rights_open_key0(d.rights))
	if copy_out(at, &d) != .Ok || !arch_frame_divert(f, handler, at) {
		arch_rights_write(d.rights)
		arch_frame_set_rights(f, d.rights)
		return false
	}
	return true
}

// Stops the current thread at a port: posts the packet that names it, and
// waits for exception_resume (or a kill). Returns the action; none if the
// packet could not be posted, or the task is being killed.
@(private="file")
exception_stop :: proc "contextless" (p: ^Port, key: u64, first: bool, e: ^vx.Exception) -> Maybe(vx.Resume_Action) {
	th := this_cpu().current
	t := th.task
	// Its thread pointer saved now, before the packet goes: a debugger may
	// read it at once, before this thread has switched out, and what it sets
	// is loaded when the thread goes on. (Its FP/SIMD registers are in its
	// trap frame already: ADR-0004.)
	th.tls = arch_tls_read()
	th.user_held = true
	{
		spin_guard(&t.lock)
		th.exc = e^
		th.exc_stopped = true
		th.exc_first = first
		th.exc_action = nil
		th.wait_token = th
	}
	pk := vx.Packet {
		key       = key,
		value     = u64(th.id),
		timestamp = vx.Instant(clock_now()),
		trigger   = .Exception,
	}
	st := port_post(p, pk)
	action: Maybe(vx.Resume_Action)
	for st == .Ok && !intrinsics.atomic_load(&t.killed) {
		_ = thread_block(INFINITE, 0) // until exception_resume, or a kill; an interrupt waits with it
		spin_lock(&t.lock)
		action = th.exc_action
		if action == nil {
			th.wait_token = th // woken by an interrupt: wait again
		}
		spin_unlock(&t.lock)
		if action != nil {
			break
		}
	}
	{
		spin_guard(&t.lock)
		th.exc_stopped = false
		th.exc_first = false
		th.wait_token = nil
	}
	arch_tls_write(th.tls) // what a debugger set, or what was saved
	th.user_held = false
	if intrinsics.atomic_load(&t.killed) {
		return nil
	}
	return action
}

// The task's port of one kind (the debugger's, or its own), with a reference.
@(private="file")
exception_port :: proc "contextless" (t: ^Task, first: bool) -> (p: ^Port, key: u64) {
	spin_guard(&t.lock)
	p, key = first ? t.dbg_port : t.exc_port, first ? t.dbg_key : t.exc_key
	if p != nil {
		object_ref(&p.obj)
	}
	return
}

// A fault in user mode: true if the thread may go back to user mode, its
// frame perhaps changed; false for the default, which kills the task. kind
// and address become the exception's as everyone sees it (a pager's late
// page is Pager_Timeout at the page), so the default's exit string says the
// same (upstream ab83fe6, from this tree's finding).
exception_raise :: proc "contextless" (f: ^Trap_Frame, kind: ^vx.Exception_Kind, code: u32, address: ^u64) -> bool {
	th := this_cpu().current
	t := th.task
	if kind^ == .Page_Fault { // a pager's page, perhaps: taken in before anyone sees a fault
		switch pager_fault(address^, code) {
		case .Mapped, .Killed:
			return true // made again; or user_return ends it
		case .Timeout:
			kind^, address^ = .Pager_Timeout, address^ &~ (PAGE_SIZE - 1)
		case .Not_Mine:
			if task_revoked_at(t, address^) {
				kind^ = .Revoked // a revoked lease's page (ADR-0021)
			}
		}
	}
	e_kind, e_address := kind^, address^
	if e_kind == .Step {
		arch_frame_step(f, false) // one instruction, done
	}
	e := vx.Exception {
		kind    = e_kind,
		code    = code,
		address = e_address,
		thread  = th.id,
		regs    = arch_frame_regs(f),
	}
	if e_kind == .Protection_Key {
		e.key = task_key_at(t, e_address)
	}
	if p, key := exception_port(t, true); p != nil { // a debugger first: it may handle it, step, kill, or pass it on
		action := exception_stop(p, key, true, &e)
		object_release(&p.obj)
		if intrinsics.atomic_load(&t.killed) {
			return true // user_return ends it
		}
		switch action {
		case .Step:
			arch_frame_step(f, true)
			return true
		case .Continue:
			return true
		case .Pass:
			e.regs = arch_frame_regs(f) // as the debugger left them
		case .Kill, nil:
			return false
		}
	}
	if e_kind == .Step {
		return true // a step is the debugger's alone
	}
	if exception_divert(f, &e) {
		return true
	}
	p, key := exception_port(t, false)
	if p == nil {
		return false
	}
	action := exception_stop(p, key, false, &e)
	object_release(&p.obj)
	return intrinsics.atomic_load(&t.killed) || action == .Continue
}

// On the way back to user mode (user_return): a suspended thread parks here,
// with its user registers where thread_state can reach them, until it is
// resumed or killed. True if it parked (the caller looks at the kill again).
exception_check_suspend :: proc "contextless" () -> bool {
	th := this_cpu().current
	t := th.task
	if intrinsics.atomic_load_explicit(&th.suspend_count, .Relaxed) == 0 {
		return false
	}
	spin_lock(&t.lock)
	parked := false
	for th.suspend_count > 0 && !t.killed {
		intrinsics.atomic_store_explicit(&th.parked, true, .Release)
		parked = true
		th.wait_token = &th.suspend_count
		spin_unlock(&t.lock)
		_ = thread_block(INFINITE, 0) // thread_resume wakes it, as does a kill
		spin_lock(&t.lock)
	}
	intrinsics.atomic_store_explicit(&th.parked, false, .Release)
	th.wait_token = nil
	spin_unlock(&t.lock)
	return parked
}

// On the way back to user mode (user_return): an interrupt pending on the
// current thread is delivered to its task's handler.
exception_check_interrupt :: proc "contextless" () {
	th := this_cpu().current
	t := th.task
	if !intrinsics.atomic_load_explicit(&th.interrupt_pending, .Relaxed) {
		return
	}
	e := vx.Exception {
		kind   = .Interrupt,
		thread = th.id,
	}
	pending: bool
	{
		spin_guard(&t.lock)
		pending = len(th.notes) > 0
		if pending {
			e.code = u32(copy(e.note[:], th.notes[0][:]))
			copy(th.notes[:], th.notes[1:])
			resize(&th.notes, len(th.notes) - 1)
		}
		// The next goes on the thread's next way back to user mode, though
		// this one's handler may still be running: handlers nest, as POSIX's
		// do. Holding it until exception_resume would strand it when a
		// handler leaves by longjmp, which never resumes.
		intrinsics.atomic_store_explicit(&th.interrupt_pending, len(th.notes) > 0, .Relaxed)
	}
	if !pending {
		return
	}
	sched_drop_interrupt_wake(th) // the wake that brought it here must not end its next wait as well
	f := arch_user_frame(th)
	e.regs = arch_frame_regs(f)
	if !exception_divert(f, &e) { // no handler now, or a stack that cannot take it: the note ends it
		task_exit_with(string(e.note[:e.code]))
	}
}

// The thread of task t with this id, with a reference; or nil.
@(private="file")
task_thread :: proc "contextless" (t: ^Task, id: u64) -> ^Thread {
	spin_guard(&t.lock)
	for th := t.threads; th != nil; th = th.task_next {
		if u64(th.id) == id {
			object_ref(&th.obj)
			return th
		}
	}
	return nil
}

// --- The calls ---

@(require_results)
sys_exception_bind :: proc "contextless" (h, ph: vx.Handle, key, options: u64) -> vx.Status {
	opts, valid := options_of(vx.Exception_Options, options)
	if !valid || opts == {.In_Task, .First_Chance} {
		return .Err_Invalid
	}
	first := .First_Chance in opts
	t := handle_get_as(current_task(), h, Task, first ? {.Debug} : {.Manage}) or_return
	defer object_release(&t.obj)
	if .In_Task in opts {
		if key >= u64(USER_TOP) {
			return .Err_Invalid
		}
		spin_guard(&t.lock)
		intrinsics.atomic_store_explicit(&t.exc_handler, Uva(key), .Relaxed)
		return .Ok
	}
	p: ^Port
	if ph != vx.HANDLE_NONE {
		p = handle_get_as(current_task(), ph, Port, {.Signal}) or_return
	}
	old: ^Port
	st := vx.Status.Ok
	{
		spin_guard(&t.lock)
		if t.root != 0 { // a torn-down task keeps no port
			if first {
				old, t.dbg_port, t.dbg_key = t.dbg_port, p, key
			} else {
				old, t.exc_port, t.exc_key = t.exc_port, p, key
			}
			p = nil
		} else {
			st = .Err_Bad_State
		}
	}
	if old != nil {
		object_release(&old.obj)
	}
	if p != nil {
		object_release(&p.obj)
	}
	return st
}

// exception_resume(task, thread, action, regs). With thread 0 the caller
// leaves its handler, and the result is the value its registers put back in
// the return register, which the dispatcher writes there.
@(require_results)
sys_exception_resume :: proc "contextless" (h: vx.Handle, id, action_arg: u64, regs_ptr: Uva) -> (value: i64, st: vx.Status) {
	if action_arg < u64(min(vx.Resume_Action)) || action_arg > u64(max(vx.Resume_Action)) {
		return 0, .Err_Invalid
	}
	action := vx.Resume_Action(action_arg)
	regs: vx.Regs
	if regs_ptr != 0 {
		copy_in(&regs, regs_ptr) or_return
	}
	// Its own thread leaving its handler needs MANAGE on its own task; another
	// thread's stop is checked below, by whose stop it is.
	t := handle_get_as(current_task(), h, Task, id == 0 ? {.Manage} : {}) or_return
	if id == 0 { // the caller, leaving its handler
		self := this_cpu().current
		own := t == self.task
		object_release(&t.obj)
		if !own || action != .Continue || regs_ptr == 0 {
			return 0, .Err_Invalid
		}
		arch_frame_set_regs(arch_user_frame(self), &regs) or_return
		return i64(regs_result(&regs)), .Ok
	}
	target := task_thread(t, id)
	object_release(&t.obj)
	if target == nil {
		return 0, .Err_Not_Found
	}
	defer object_release(&target.obj)
	tt := target.task
	// A stop at the debugger's port is the debugger's to answer: DEBUG, as
	// binding that port takes; one at the task's exception port, MANAGE, as
	// binding that takes (upstream's M6 step 6b: MANAGE alone answered both).
	spin_lock(&tt.lock)
	first := target.exc_stopped && target.exc_first
	spin_unlock(&tt.lock)
	auth := handle_get_as(current_task(), h, Task, first ? {.Debug} : {.Manage}) or_return
	object_release(&auth.obj)
	{
		spin_guard(&tt.lock)
		debuggers := action == .Pass || action == .Step // from a debugger's port only
		// The stop answered must be the one the rights were checked for.
		if !target.exc_stopped || target.exc_action != nil || target.exc_first != first || (debuggers && !target.exc_first) {
			return 0, .Err_Bad_State
		}
		if regs_ptr != 0 {
			arch_frame_set_regs(arch_user_frame(target), &regs) or_return
		}
		target.exc_action = action
	}
	thread_wake_token(target, target, .Ok)
	return 0, .Ok
}

// A thread's own thread pointer, with a handle to its own task (any rights).
@(private="file", require_results)
thread_tls_self :: proc "contextless" (h: vx.Handle, op: vx.Thread_State_Op, buf: Uva) -> vx.Status {
	t := handle_get_as(current_task(), h, Task, {}) or_return
	own := t == current_task()
	object_release(&t.obj)
	if !own {
		return .Err_Invalid
	}
	value: u64
	if op == .Get_Tls {
		value = arch_tls_read()
		return copy_out(buf, &value)
	}
	copy_in(&value, buf) or_return
	if value >= u64(USER_TOP) {
		return .Err_Range // x86_64's FS base must be canonical
	}
	arch_tls_write(value)
	return .Ok
}

// .Get_Note_Stack and .Set_Note_Stack: the caller's own (ADR-0036), with a
// handle to its own task (any rights).
@(private="file", require_results)
thread_note_stack :: proc "contextless" (h: vx.Handle, op: vx.Thread_State_Op, buf: Uva) -> vx.Status {
	t := handle_get_as(current_task(), h, Task, {}) or_return
	own := t == current_task()
	object_release(&t.obj)
	if !own {
		return .Err_Invalid
	}
	me := this_cpu().current
	ns := vx.Note_Stack{base = u64(me.note_stack), size = me.note_stack_size}
	if op == .Get_Note_Stack {
		return copy_out(buf, &ns)
	}
	copy_in(&ns, buf) or_return
	if ns.size == 0 {
		ns.base = 0 // none: handlers run on the thread's own stack
	} else if end, o := intrinsics.overflow_add(ns.base, ns.size); ns.size < vx.NOTE_STACK_MIN || o || end > u64(USER_TOP) {
		return .Err_Range
	}
	me.note_stack, me.note_stack_size = Uva(ns.base), ns.size // only this thread changes them
	return .Ok
}

// The task's watchpoints: .Get_Watch and .Set_Watch. A set is checked whole:
// each slot off, or an aligned user address of 1, 2, 4 or 8 bytes, within
// the hardware's count.
@(private="file", require_results)
thread_watch :: proc "contextless" (h: vx.Handle, op: vx.Thread_State_Op, buf: Uva) -> vx.Status {
	w: vx.Watches
	if op == .Set_Watch {
		copy_in(&w, buf) or_return
	}
	count := arch_watch_count()
	any := false
	for s, i in w.slot {
		if op != .Set_Watch || s.kind == .Off {
			continue
		}
		len_ok := s.len == 1 || s.len == 2 || s.len == 4 || s.len == 8
		if u32(i) >= count || s.kind > .Rw || !len_ok || s.address % u64(max(s.len, 1)) != 0 || s.address >= u64(USER_TOP) {
			return .Err_Invalid
		}
		any = true
	}
	t := handle_get_as(current_task(), h, Task, {.Debug}) or_return // both: a debugger's
	{
		spin_guard(&t.lock)
		if op == .Set_Watch {
			t.watches = w.slot
			t.watching = any
		} else {
			w.slot = t.watches
		}
	}
	object_release(&t.obj)
	w.count = count
	return op == .Get_Watch ? copy_out(buf, &w) : .Ok
}

// The live thread of the task with the next id after `after`: .Next_Thread.
@(private="file", require_results)
thread_next :: proc "contextless" (h: vx.Handle, after: u64, buf: Uva) -> vx.Status {
	t := handle_get_as(current_task(), h, Task, {.Manage}) or_return
	info: vx.Thread_Info
	{
		spin_guard(&t.lock)
		for x := t.threads; x != nil; x = x.task_next {
			if u64(x.id) <= after || (info.id != 0 && x.id >= info.id) || x.state == .Dead {
				continue
			}
			state := vx.Thread_Run_State.Running
			switch {
			case x.exc_stopped:
				state = .Stopped
			case x.suspend_count > 0 && x.parked:
				state = .Suspended
			case x.state == .Blocked:
				state = .Blocked
			}
			info = {
				id            = x.id,
				state         = state,
				suspend_count = x.suspend_count,
				first_chance  = b32(x.exc_first),
			}
		}
	}
	object_release(&t.obj)
	if info.id == 0 {
		return .Err_Not_Found
	}
	return copy_out(buf, &info)
}

// .Get_Xstate and .Set_Xstate (ADR-0035): the whole of a stopped thread's
// FP/SIMD state, through a page of the kernel's (the state can be most of
// one), on .Get_Fpregs's terms. A read is the debugger's view
// (arch_frame_get_xstate); a write is checked as XRSTOR would check it.
@(private="file", require_results)
thread_xstate :: proc "contextless" (h: vx.Handle, id: u64, op: vx.Thread_State_Op, buf: Uva) -> vx.Status {
	n := u64(arch_xstate_size())
	pa := phys_alloc(0)
	if pa == 0 {
		return .Err_No_Memory
	}
	defer phys_free(pa, 0)
	area := page_bytes(pa)[:n]
	if op == .Set_Xstate {
		copy_from_user(raw_data(area), buf, n) or_return
	}
	t := handle_get_as(current_task(), h, Task, {.Manage}) or_return
	as_debugger, _ := handle_get_as(current_task(), h, Task, {.Debug})
	debugger := as_debugger != nil
	if as_debugger != nil {
		object_release(&as_debugger.obj)
	}
	target := task_thread(t, id)
	object_release(&t.obj)
	if target == nil {
		return .Err_Not_Found
	}
	defer object_release(&target.obj)
	tt := target.task
	{
		spin_guard(&tt.lock)
		still := target.suspend_count > 0 && (target.parked || intrinsics.volatile_load(&target.state) == .Blocked)
		if !target.exc_stopped && !(still && debugger) {
			return .Err_Bad_State // running: neither read nor changed
		}
		if op == .Set_Xstate {
			arch_frame_set_xstate(arch_user_frame(target), area) or_return // loaded on its way out
			target.rights = arch_frame_rights(arch_user_frame(target)) // and its key rights as it next runs
			return .Ok
		}
		arch_frame_get_xstate(arch_user_frame(target), area) // saved at its entry (ADR-0004)
	}
	return copy_to_user(buf, raw_data(area), n)
}

// .Get_Sched: a thread's scheduling (ADR-0016), with INSPECT on its task;
// thread 0, the caller's own.
@(private="file", require_results)
thread_sched_get :: proc "contextless" (h: vx.Handle, id: u64, buf: Uva) -> vx.Status {
	if id == 0 {
		info := sched_info(this_cpu().current)
		return copy_out(buf, &info)
	}
	t := handle_get_as(current_task(), h, Task, {.Inspect}) or_return
	target := task_thread(t, id)
	object_release(&t.obj)
	if target == nil {
		return .Err_Not_Found
	}
	info := sched_info(target)
	object_release(&target.obj)
	return copy_out(buf, &info)
}

// .Get_Times (ADR-0041): a thread's ticks, or with id 0 its task's, those of
// threads reaped and of the rest, as nanoseconds. With INSPECT on the task.
@(private="file", require_results)
thread_times :: proc "contextless" (h: vx.Handle, id: u64, buf: Uva) -> vx.Status {
	t := handle_get_as(current_task(), h, Task, {.Inspect}) or_return
	ticks: [Cpu_Time]u64
	found := id == 0
	spin_lock(&t.lock)
	if id == 0 {
		ticks = t.gone_ticks
	}
	for x := t.threads; x != nil; x = x.task_next {
		if id != 0 && u64(x.id) != id {
			continue
		}
		found = true
		for &n, k in ticks {
			n += intrinsics.atomic_load_explicit(&x.ticks[k], .Relaxed)
		}
	}
	spin_unlock(&t.lock)
	object_release(&t.obj)
	if !found {
		return .Err_Not_Found
	}
	out := vx.Cpu_Times {
		user = vx.Duration(ticks[.User] * u64(TICK)),
		sys  = vx.Duration(ticks[.Sys] * u64(TICK)),
	}
	return copy_out(buf, &out)
}

// How many bytes each operation reads or writes.
@(private="file")
state_size :: proc "contextless" (op: vx.Thread_State_Op) -> u64 {
	switch op {
	case .Get_Exception:
		return size_of(vx.Exception)
	case .Get_Regs, .Set_Regs:
		return size_of(vx.Regs)
	case .Get_Tls, .Set_Tls:
		return size_of(u64)
	case .Get_Fpregs, .Set_Fpregs:
		return size_of(vx.Fpregs)
	case .Next_Thread:
		return size_of(vx.Thread_Info)
	case .Get_Watch, .Set_Watch:
		return size_of(vx.Watches)
	case .Get_Xstate, .Set_Xstate:
		return u64(arch_xstate_size())
	case .Get_Cpu:
		return size_of(vx.Cpu_Info)
	case .Get_Note_Stack, .Set_Note_Stack:
		return size_of(vx.Note_Stack)
	case .Get_Sched:
		return size_of(vx.Sched_Info)
	case .Get_Times:
		return size_of(vx.Cpu_Times)
	}
	return 0
}

@(require_results)
sys_thread_state :: proc "contextless" (h: vx.Handle, id, op_arg: u64, buf: Uva, size: u64) -> vx.Status {
	if op_arg < u64(min(vx.Thread_State_Op)) || op_arg > u64(max(vx.Thread_State_Op)) {
		return .Err_Invalid
	}
	op := vx.Thread_State_Op(op_arg)
	if size < state_size(op) {
		return .Err_Too_Small
	}
	#partial switch op {
	case .Get_Cpu: // what the kernel saves and lets user code use (ADR-0035)
		if id != 0 {
			return .Err_Invalid
		}
		info := arch_cpu_info()
		return copy_out(buf, &info)
	case .Get_Xstate, .Set_Xstate:
		return thread_xstate(h, id, op, buf)
	case .Next_Thread:
		return thread_next(h, id, buf)
	case .Get_Watch, .Set_Watch:
		return id != 0 ? .Err_Invalid : thread_watch(h, op, buf)
	case .Get_Note_Stack, .Set_Note_Stack:
		return id != 0 ? .Err_Invalid : thread_note_stack(h, op, buf)
	case .Get_Sched:
		return thread_sched_get(h, id, buf)
	case .Get_Times:
		return thread_times(h, id, buf)
	case .Get_Tls, .Set_Tls:
		if id == 0 {
			return thread_tls_self(h, op, buf)
		}
	}
	regs: vx.Regs
	fpr: vx.Fpregs
	tls: u64
	#partial switch op {
	case .Set_Regs:
		copy_in(&regs, buf) or_return
	case .Set_Tls:
		copy_in(&tls, buf) or_return
		if tls >= u64(USER_TOP) {
			return .Err_Range
		}
	case .Set_Fpregs:
		copy_in(&fpr, buf) or_return
	}
	t := handle_get_as(current_task(), h, Task, {.Manage}) or_return
	as_debugger, _ := handle_get_as(current_task(), h, Task, {.Debug})
	debugger := as_debugger != nil
	if as_debugger != nil {
		object_release(&as_debugger.obj)
	}
	target := task_thread(t, id)
	object_release(&t.obj)
	if target == nil {
		return .Err_Not_Found
	}
	defer object_release(&target.obj)
	tt := target.task
	e: vx.Exception
	{
		spin_guard(&tt.lock)
		// A suspended thread's registers hold still once it has parked, or
		// while it is blocked in a call (which will park it on the way out).
		still := target.suspend_count > 0 && (target.parked || intrinsics.volatile_load(&target.state) == .Blocked)
		if !target.exc_stopped && !(still && debugger && op != .Get_Exception) {
			return .Err_Bad_State // running: neither read nor changed
		}
		#partial switch op {
		case .Get_Exception:
			e = target.exc
		case .Get_Regs:
			e.regs = arch_frame_regs(arch_user_frame(target))
		case .Set_Regs:
			return arch_frame_set_regs(arch_user_frame(target), &regs)
		case .Get_Tls:
			tls = target.tls // saved: by exception_stop, or as it switched out
		case .Set_Tls:
			target.tls = tls // loaded when it next runs
			return .Ok
		case .Get_Fpregs:
			fpr = arch_frame_fpregs(arch_user_frame(target)) // saved at its entry (ADR-0004)
		case .Set_Fpregs:
			arch_frame_set_fpregs(arch_user_frame(target), &fpr) // loaded on its way out
			return .Ok
		}
	}
	#partial switch op {
	case .Get_Exception:
		return copy_out(buf, &e)
	case .Get_Tls:
		return copy_out(buf, &tls)
	case .Get_Fpregs:
		return copy_out(buf, &fpr)
	}
	return copy_out(buf, &e.regs)
}

@(require_results)
sys_thread_interrupt :: proc "contextless" (h: vx.Handle, id: u64, note_ptr: Uva, length: u64) -> vx.Status {
	if length == 0 || length > vx.ERRMAX {
		return .Err_Invalid
	}
	text: [vx.ERRMAX]u8
	copy_in_slice(text[:length], note_ptr) or_return
	t := handle_get_as(current_task(), h, Task, {.Manage}) or_return
	defer object_release(&t.obj)
	target: ^Thread
	unhandled: bool
	{
		spin_guard(&t.lock)
		if t.ending || t.killed {
			return .Err_Bad_State // ending already
		}
		unhandled = t.exc_handler == 0
		for x := t.threads; x != nil && !unhandled; x = x.task_next { // a thread that will take it
			if !x.exited && (id != 0 ? u64(x.id) == id : !x.exc_stopped) {
				target = x
				break
			}
		}
		switch {
		case unhandled:
		case target == nil:
			return .Err_Not_Found
		case len(target.notes) == THREAD_MAX_INTERRUPTS:
			return .Err_Should_Wait // its queue is full: the caller may try again
		case:
			note: Note
			_ = append(&note, ..text[:length])
			_ = append(&target.notes, note)
			intrinsics.atomic_store_explicit(&target.interrupt_pending, true, .Relaxed)
			object_ref(&target.obj)
		}
	}
	if unhandled { // no one to take it: it ends the task, as in Plan 9
		task_kill(t, string(text[:length]))
		return .Ok
	}
	sched_kick(target, .Err_Interrupted) // out of a call it is blocked in,
	sched_poke(target) // or into the kernel from user code on another CPU
	object_release(&target.obj)
	return .Ok
}

@(private="file")
SUSPEND_MAX :: 64 // threads taken at once by thread_suspend(0)

// Up to SUSPEND_MAX of task t's threads, each with a reference: the one with
// this id, or with id 0, every one (a process stops as a whole), a batch at
// a time, the lowest ids above `after` in each, in order of id. By id, not by
// place in the list, which threads join and leave between batches: one would
// be missed, or taken twice (the Rust port's finding, upstream's 5c1bbc9).
@(private="file")
task_threads :: proc "contextless" (t: ^Task, id: u64, after: u32, out: ^[dynamic; SUSPEND_MAX]^Thread) {
	clear(out)
	spin_guard(&t.lock)
	for th := t.threads; th != nil; th = th.task_next {
		if (id != 0 && u64(th.id) != id) || th.id <= after {
			continue
		}
		n := len(out)
		if n == SUSPEND_MAX && th.id >= out[n - 1].id {
			continue
		}
		at := n
		if n < SUSPEND_MAX {
			_ = append(out, th)
		} else {
			at = n - 1 // the highest falls off
		}
		for at > 0 && out[at - 1].id > th.id {
			out[at] = out[at - 1]
			at -= 1
		}
		out[at] = th
	}
	for th in out^ {
		object_ref(&th.obj)
	}
}

// One thread's suspension: counted; returns once it holds still (parked on
// its way to user mode, or blocked in a call), or after a second.
@(private="file", require_results)
thread_suspend_one :: proc "contextless" (target: ^Thread) -> vx.Status {
	tt := target.task
	{
		spin_guard(&tt.lock)
		target.suspend_count += 1
	}
	if target == this_cpu().current {
		return .Ok // the caller suspends itself on its own way out
	}
	give_up := clock_now() + 1_000_000_000
	for {
		state := intrinsics.volatile_load(&target.state)
		if intrinsics.atomic_load_explicit(&target.parked, .Acquire) || state == .Blocked || state == .Dead {
			return .Ok
		}
		if clock_now() >= give_up {
			return .Err_Timed_Out // still counted: thread_resume undoes it
		}
		// In user mode elsewhere: into the kernel, to park. Each time round, as
		// a thread that was ready, not running, at first (one just started)
		// may be in user mode now, where nothing else would stop it.
		sched_poke(target)
		_ = thread_block(clock_now() + 100_000, 0) // a tenth of a millisecond
	}
}

@(private="file", require_results)
thread_resume_one :: proc "contextless" (target: ^Thread) -> vx.Status {
	tt := target.task
	wake: bool
	{
		spin_guard(&tt.lock)
		if target.suspend_count == 0 {
			return .Err_Bad_State
		}
		target.suspend_count -= 1
		wake = target.suspend_count == 0
	}
	if wake {
		thread_wake_token(target, &target.suspend_count, .Ok)
	}
	return .Ok
}

// thread_suspend(task, thread) and thread_resume: the thread with that id, or
// with 0, every thread the task has, a batch at a time.
@(require_results)
sys_thread_suspend :: proc "contextless" (h: vx.Handle, id: u64, resume: bool) -> vx.Status {
	t := handle_get_as(current_task(), h, Task, {.Debug}) or_return
	defer object_release(&t.obj)
	st := vx.Status.Err_Not_Found
	targets: [dynamic; SUSPEND_MAX]^Thread
	done: u32 // the last batch's highest id: the next starts above it
	for {
		task_threads(t, id, done, &targets)
		if len(targets) > 0 { // before they are let go
			done = targets[len(targets) - 1].id
		}
		if len(targets) > 0 && st == .Err_Not_Found {
			st = .Ok
		}
		for th in targets {
			one := resume ? thread_resume_one(th) : thread_suspend_one(th)
			if st == .Ok {
				st = one
			}
			object_release(&th.obj)
		}
		if len(targets) < SUSPEND_MAX {
			return st
		}
	}
}

// Gives a mapping a private copy of its VMO's range, so that a write to it
// (a breakpoint in code) reaches nobody else and needs no writable mapping:
// the pages are mapped again from the copy, with the same permissions. Under
// the task's lock; the old VMO is returned for the caller to release once the
// old translations are shot down.
@(private="file", require_results)
mapping_privatize :: proc "contextless" (t: ^Task, m: ^Mapping) -> (old: ^Vmo, st: vx.Status) {
	if m.vmo.lease_of != nil {
		return nil, .Err_Unsupported // a copy would outlive a revoke (ADR-0021)
	}
	dup := vmo_create(m.size) or_return
	mf := user_map_flags(m.flags, false)
	v := m.vmo
	if v.resizable {
		spin_lock(&v.lock)
	}
	for off := u64(0); off < m.size; off += PAGE_SIZE {
		pa := vmo_page_in(v, (m.offset + off) / PAGE_SIZE)
		if pa != 0 {
			page_copy(vmo_page(dup, off / PAGE_SIZE), pa)
		}
		unmap_page(t.root, u64(m.va) + off)
		shown := .No_Access not_in m.flags && pa != 0 // a no-access page stays unmapped (ADR-0020)
		if shown && !map_range(t.root, u64(m.va) + off, vmo_page(dup, off / PAGE_SIZE), PAGE_SIZE, mf, m.key) {
			st = .Err_No_Memory
		}
	}
	if v.resizable {
		spin_unlock(&v.lock)
	}
	old = m.vmo
	m.vmo = dup
	m.offset = 0
	m.privatized = true // written in place from now on: copied once, not for each page
	return
}

@(private="file")
MEM_OPS_MAX :: 16

// One op of task_mem_rw, a page at a time, under the task's lock so no page
// can go while it is copied.
@(private="file", require_results)
mem_op :: proc "contextless" (t: ^Task, op: ^vx.Mem_Op, shoot: ^bool, released: ^[dynamic; MEM_OPS_MAX]^Vmo) -> vx.Status {
	end, overflow := intrinsics.overflow_add(op.address, op.size)
	if overflow || end > u64(USER_TOP) || op.size > 1 << 20 {
		return .Err_Range
	}
	for done := u64(0); done < op.size; {
		at := op.address + done
		n := min(PAGE_SIZE - at % PAGE_SIZE, op.size - done)
		spin_guard(&t.lock)
		m: ^Mapping
		if t.maps != nil {
			for &x in t.maps {
				if x.size != 0 && Uva(at) >= x.va && Uva(at) < x.va + Uva(x.size) {
					m = &x
					break
				}
			}
		}
		switch {
		case m == nil:
			return .Err_Invalid // nothing there
		case m.vmo.physical:
			return .Err_Unsupported // device memory
		case m.vmo.pager != nil && bool(op.write):
			return .Err_Unsupported // a pager's pages: read only those it supplied
		case m.vmo.pager != nil && vmo_page(m.vmo, (m.offset + u64(Uva(at) - m.va)) / PAGE_SIZE) == 0:
			return .Err_Should_Wait
		case bool(op.write) && .Write not_in m.flags && !m.privatized:
			if len(released) == MEM_OPS_MAX {
				return .Err_No_Memory // too many copies at once: the caller may try again
			}
			old := mapping_privatize(t, m) or_return
			_ = append(released, old)
			shoot^ = true
		}
		v := m.vmo
		if v.resizable {
			spin_lock(&v.lock) // its pages can go with a shrink
		}
		pa := vmo_page_in(v, (m.offset + u64(Uva(at) - m.va)) / PAGE_SIZE)
		st := vx.Status.Ok
		if vmo_revoked(v) {
			st = .Err_Revoked
		} else if pa == 0 {
			st = .Err_Invalid // past its end
		} else {
			page := page_bytes(pa)[at % PAGE_SIZE:][:n]
			user := Uva(op.buffer + done)
			if op.write {
				st = copy_from_user(raw_data(page), user, n)
				if st == .Ok && .Exec in m.flags {
					arch_sync_icache(page)
				}
			} else {
				st = copy_to_user(user, raw_data(page), n)
			}
		}
		if v.resizable {
			spin_unlock(&v.lock)
		}
		st or_return
		done += n
	}
	return .Ok
}

@(require_results)
sys_task_mem_rw :: proc "contextless" (h: vx.Handle, ops_ptr: Uva, count: u64) -> vx.Status {
	if count == 0 || count > MEM_OPS_MAX {
		return .Err_Invalid
	}
	ops: [MEM_OPS_MAX]vx.Mem_Op
	copy_in_slice(ops[:count], ops_ptr) or_return
	t := handle_get_as(current_task(), h, Task, {.Debug}) or_return
	shoot: bool
	released: [dynamic; MEM_OPS_MAX]^Vmo
	for &op in ops[:count] {
		op.status = mem_op(t, &op, &shoot, &released)
	}
	root := t.root
	object_release(&t.obj)
	if shoot && root != 0 {
		arch_tlb_shootdown(root, 0, u64(USER_TOP)) // the old pages are cached nowhere now
	}
	for v in released {
		object_release(&v.obj)
	}
	return copy_out_slice(ops_ptr, ops[:count])
}

// vmo_clone: a copy, made now and charged in full (commit, not overcommit).
// Pages shared until written is an optimization for later, behind the same
// call.
@(require_results)
sys_vmo_clone :: proc "contextless" (h: vx.Handle, offset, size, options: u64, out: Uva) -> vx.Status {
	if options != 0 {
		return .Err_Invalid
	}
	src := handle_get_as(current_task(), h, Vmo, {.Read}) or_return
	defer object_release(&src.obj)
	end, overflow := intrinsics.overflow_add(offset, size)
	switch {
	case src.physical || src.pager != nil: // device memory, or pages a pager has not all supplied
		return .Err_Unsupported
	case vmo_revoked(src):
		return .Err_Revoked
	case size == 0 || (offset | size) & (PAGE_SIZE - 1) != 0 || overflow || end > src.size:
		return .Err_Range
	}
	dup := vmo_create(size) or_return
	if src.resizable {
		spin_lock(&src.lock) // a shrink frees pages (ADR-0020)
	}
	shrunk := end > src.size // since the check above
	if !shrunk {
		for i in 0 ..< size / PAGE_SIZE {
			page_copy(vmo_page(dup, i), vmo_page(src, offset / PAGE_SIZE + i))
		}
	}
	if src.resizable {
		spin_unlock(&src.lock)
	}
	if shrunk {
		object_release(&dup.obj)
		return .Err_Range
	}
	return return_handle(&dup.obj, vx.ALL_RIGHTS - {.Debug}, out) // as vmo_create
}

// as_query(task, address, &info): the first mapping ending after address.
@(require_results)
sys_as_query :: proc "contextless" (h: vx.Handle, addr: Uva, out: Uva) -> vx.Status {
	t := handle_get_as(current_task(), h, Task, {.Inspect}) or_return
	info, st := task_query(t, addr)
	object_release(&t.obj)
	if st != .Ok {
		return st
	}
	return copy_out(out, &info)
}
