// vx:rt, the user runtime for first-party programs: the entry point, the
// syscalls, the spawn message and console output. A program imports it and
// defines vx_main (start.odin says how).
//
// The wrappers return values first and a Status last, Odin's way; those that
// create something return HANDLE_NONE alongside a failure.
package rt

import vx "abi:vx"

foreign _ {
	vx_syscall :: proc "c" (nr: vx.Syscall, a0: u64 = 0, a1: u64 = 0, a2: u64 = 0, a3: u64 = 0, a4: u64 = 0, a5: u64 = 0) -> i64 ---
}

// A syscall's result as a Status: negative values are statuses, the rest OK.
@(private)
status :: #force_inline proc "contextless" (r: i64) -> vx.Status {
	return r < 0 ? vx.Status(r) : .Ok
}

@(private)
addr :: #force_inline proc "contextless" (p: rawptr) -> u64 {
	return u64(uintptr(p))
}

@(require_results)
debug_write :: proc "contextless" (s: string) -> vx.Status {
	return status(vx_syscall(.Debug_Write, addr(raw_data(s)), u64(len(s))))
}

clock_read :: proc "contextless" () -> vx.Instant {
	return vx.Instant(vx_syscall(.Clock_Read))
}

// The cycle counter the clock is made from (/sys/clock/info), and the wall
// clock's offset.
@(require_results)
clock_info :: proc "contextless" () -> (vx.Clock_Info, vx.Status) {
	info: vx.Clock_Info
	st := status(vx_syscall(.Clock_Read, addr(&info)))
	return info, st
}

// UTC, in ns since 1970: the monotonic clock until there is a wall clock.
clock_utc :: proc "contextless" () -> i64 {
	info: vx.Clock_Info
	now := vx_syscall(.Clock_Read, addr(&info))
	return now < 0 ? i64(clock_read()) : now + info.utc_offset
}

// The wall clock set to utc (ns since 1970), with the root Resource.
@(require_results)
clock_set :: proc "contextless" (resource: vx.Handle, utc: i64) -> vx.Status {
	return status(vx_syscall(.Clock_Set, u64(resource), u64(utc)))
}

@(require_results)
task_create :: proc "contextless" (name: string) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Task_Create, addr(raw_data(name)), u64(len(name)), addr(&h)))
	return h, st
}

// The caller takes scratch's address space and goes on as the program in
// it (ADR-0012), with bootstrap as its only handle. Returns only on a
// failure.
@(require_results)
task_exec :: proc "contextless" (scratch, bootstrap: vx.Handle, entry, sp: u64) -> vx.Status {
	return status(vx_syscall(.Task_Exec, u64(scratch), u64(bootstrap), entry, sp))
}

// A copy of the caller, with no threads yet (task_create's .Fork).
@(require_results)
task_fork :: proc "contextless" (name: string) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Task_Create, addr(raw_data(name)), u64(len(name)), addr(&h), u64(transmute(u32)vx.Task_Options{.Fork})))
	return h, st
}

// Ends the task, or with an id that task in task's tree, with msg as its
// exit string: empty for success (ADR-0010).
@(require_results)
task_kill :: proc "contextless" (task: vx.Handle, msg: string, id: u64 = 0) -> vx.Status {
	return status(vx_syscall(.Task_Kill, u64(task), addr(raw_data(msg)), u64(len(msg)), id))
}

// The task itself; or with an id, that task in task's tree; or with
// {.Next}, the next one after `id`.
@(require_results)
task_info :: proc "contextless" (task: vx.Handle, id: u64 = 0, flags: vx.Task_Info_Options = {}) -> (vx.Task_Summary, vx.Status) {
	info: vx.Task_Summary
	st := status(vx_syscall(.Task_Info, u64(task), addr(&info), id, u64(transmute(u32)flags)))
	return info, st
}

@(require_results)
thread_create :: proc "contextless" (task: vx.Handle) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Thread_Create, u64(task), addr(&h)))
	return h, st
}

// The same, and the thread's id in its task (exceptions and thread_interrupt
// name it so).
@(require_results)
thread_create_id :: proc "contextless" (task: vx.Handle) -> (vx.Handle, u32, vx.Status) {
	h: vx.Handle
	id: u32
	st := status(vx_syscall(.Thread_Create, u64(task), addr(&h), addr(&id)))
	return h, id, st
}

// The handle, unless HANDLE_NONE, moves to the thread's task, and the thread
// gets its value there as its first argument.
@(require_results)
thread_start :: proc "contextless" (thread: vx.Handle, entry, sp: u64, arg: vx.Handle, arg2: u64) -> vx.Status {
	return status(vx_syscall(.Thread_Start, u64(thread), entry, sp, u64(arg), arg2))
}

// Ends the calling thread. The task's last thread to exit ends it with the
// empty exit string, unless it was killed; to end a program, exits.
thread_exit :: proc "contextless" () -> ! {
	vx_syscall(.Thread_Exit)
	for {}
}

// --- Exceptions, interrupts and debugging (abi.odin describes them) ---

// Where the task's faults go: a port (key in its packets), with
// {.First_Chance} a debugger's port, or with {.In_Task} a handler in the task
// (key its address, 0 to unbind).
@(require_results)
exception_bind :: proc "contextless" (task, port: vx.Handle, key: u64, options: vx.Exception_Options = {}) -> vx.Status {
	return status(vx_syscall(.Exception_Bind, u64(task), u64(port), key, u64(transmute(u32)options)))
}

// Resumes a thread stopped at a port, with regs if given; with thread 0 the
// caller leaves its handler with regs, and this does not return.
@(require_results)
exception_resume :: proc "contextless" (task: vx.Handle, thread: u32, action: vx.Resume_Action, regs: ^vx.Regs = nil) -> vx.Status {
	return status(vx_syscall(.Exception_Resume, u64(task), u64(thread), u64(action), addr(regs)))
}

// Reads or writes a thread's state into or from *buf: an Exception, Regs, a
// u64 thread pointer, Fpregs, a Thread_Info or Watches, as op says. The size
// is buf's type's.
@(require_results)
thread_state :: proc "contextless" (task: vx.Handle, thread: u32, op: vx.Thread_State_Op, buf: ^$T) -> vx.Status {
	return status(vx_syscall(.Thread_State, u64(task), u64(thread), u64(op), addr(buf), size_of(T)))
}

// thread_state with a buffer of bytes, its size the slice's: for
// .Get_Xstate and .Set_Xstate, whose size .Get_Cpu gives.
@(require_results)
thread_state_bytes :: proc "contextless" (task: vx.Handle, thread: u32, op: vx.Thread_State_Op, buf: []u8) -> vx.Status {
	return status(vx_syscall(.Thread_State, u64(task), u64(thread), u64(op), addr(raw_data(buf)), u64(len(buf))))
}

// Counted; with thread 0, every thread of the task. Returns once the thread
// holds still.
@(require_results)
thread_suspend :: proc "contextless" (task: vx.Handle, thread: u32) -> vx.Status {
	return status(vx_syscall(.Thread_Suspend, u64(task), u64(thread)))
}

@(require_results)
thread_resume :: proc "contextless" (task: vx.Handle, thread: u32) -> vx.Status {
	return status(vx_syscall(.Thread_Resume, u64(task), u64(thread)))
}

// Copies between the task's memory and the caller's, one op each; each op's
// status says how it went.
@(require_results)
task_mem_rw :: proc "contextless" (task: vx.Handle, ops: []vx.Mem_Op) -> vx.Status {
	return status(vx_syscall(.Task_Mem_Rw, u64(task), addr(raw_data(ops)), u64(len(ops))))
}

// Posts a note to a thread of the task, or with thread 0 to any (ADR-0010).
@(require_results)
thread_interrupt :: proc "contextless" (task: vx.Handle, thread: u32, note: string) -> vx.Status {
	return status(vx_syscall(.Thread_Interrupt, u64(task), u64(thread), addr(raw_data(note)), u64(len(note))))
}

// The first of the task's mappings that ends after `at` (INSPECT).
@(require_results)
as_query :: proc "contextless" (task: vx.Handle, at: u64) -> (vx.Map_Info, vx.Status) {
	info: vx.Map_Info
	st := status(vx_syscall(.As_Query, u64(task), at, addr(&info)))
	return info, st
}

// A new VMO holding a copy of [offset, offset + size) of vmo.
@(require_results)
vmo_clone :: proc "contextless" (vmo: vx.Handle, offset, size: u64) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Vmo_Clone, u64(vmo), offset, size, 0, addr(&h)))
	return h, st
}

@(require_results)
port_create :: proc "contextless" () -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Port_Create, 0, addr(&h)))
	return h, st
}

// A one-shot binding: the port gets one packet with `key` when the source's
// trigger holds (at once, if it already does).
@(require_results)
port_bind :: proc "contextless" (port, source: vx.Handle, trigger: vx.Trigger, key: u64, threshold: u64 = 0) -> vx.Status {
	return status(vx_syscall(.Port_Bind, u64(port), u64(source), u64(trigger), key, threshold))
}

// How many packets it stored (at least 1); .Err_Timed_Out when the deadline
// passed with none.
@(require_results)
port_wait :: proc "contextless" (port: vx.Handle, deadline: vx.Instant, leeway: vx.Duration, out: []vx.Packet) -> (int, vx.Status) {
	r := vx_syscall(.Port_Wait, u64(port), u64(deadline), u64(leeway), addr(raw_data(out)), u64(len(out)))
	return max(int(r), 0), status(r)
}

@(require_results)
port_post :: proc "contextless" (port: vx.Handle, packet: ^vx.Packet) -> vx.Status {
	return status(vx_syscall(.Port_Post, u64(port), addr(packet)))
}

@(require_results)
vmo_create :: proc "contextless" (size: u64) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Vmo_Create, size, 0, addr(&h)))
	return h, st
}

// Maps [offset, offset + size) of a VMO into a task. With at == 0 the
// kernel chooses; the address used comes back.
@(require_results)
as_map :: proc "contextless" (task, vmo: vx.Handle, offset, size: u64, flags: vx.Map_Options, at: u64 = 0, key: u32 = 0) -> (u64, vx.Status) {
	va := at
	st := status(vx_syscall(.As_Map, u64(task), u64(vmo), offset, size, u64(transmute(u32)vx.map_flags(flags, key)), addr(&va)))
	return va, st
}

// Changes the rights and protection key of the pages of [at, at + size),
// every one mapped, within what each mapping's VMO handle gave (ADR-0035).
@(require_results)
as_protect :: proc "contextless" (task: vx.Handle, at, size: u64, flags: vx.Map_Options, key: u32 = 0) -> vx.Status {
	return status(vx_syscall(.As_Protect, u64(task), at, size, u64(transmute(u32)vx.map_flags(flags, key))))
}

// A protection key of the task's, 1 to rt.cpu().keys (ADR-0035).
@(require_results)
as_key_alloc :: proc "contextless" (task: vx.Handle) -> (u32, vx.Status) {
	key: u32
	st := status(vx_syscall(.As_Key_Alloc, u64(task), addr(&key)))
	return key, st
}

// Frees a key, but not while a mapping still has it (.Err_Bad_State).
@(require_results)
as_key_free :: proc "contextless" (task: vx.Handle, key: u32) -> vx.Status {
	return status(vx_syscall(.As_Key_Free, u64(task), u64(key)))
}

// Unmaps the pages of [at, at + size), whole mappings or parts of them; pages
// nothing maps are left alone. Once it returns, no CPU reaches them there.
@(require_results)
as_unmap :: proc "contextless" (task: vx.Handle, at, size: u64) -> vx.Status {
	return status(vx_syscall(.As_Unmap, u64(task), at, size))
}

@(require_results)
vmo_read :: proc "contextless" (vmo: vx.Handle, offset: u64, buf: []u8) -> vx.Status {
	return status(vx_syscall(.Vmo_Rw, u64(vmo), u64(vx.Vmo_Op.Read), offset, addr(raw_data(buf)), u64(len(buf))))
}

@(require_results)
vmo_write :: proc "contextless" (vmo: vx.Handle, offset: u64, buf: []u8) -> vx.Status {
	return status(vx_syscall(.Vmo_Rw, u64(vmo), u64(vx.Vmo_Op.Write), offset, addr(raw_data(buf)), u64(len(buf))))
}

@(require_results)
handle_dup :: proc "contextless" (h: vx.Handle, rights: vx.Rights) -> (vx.Handle, vx.Status) {
	out: vx.Handle
	st := status(vx_syscall(.Handle_Dup, u64(h), u64(transmute(u32)rights), addr(&out)))
	return out, st
}

@(require_results)
handle_close :: proc "contextless" (h: vx.Handle) -> vx.Status {
	return status(vx_syscall(.Handle_Close, u64(h)))
}

// Closes each handle that is not HANDLE_NONE, in order, and ignores what
// the kernel says: for cleanup, where nothing could be done about a
// failure anyway. `defer rt.close_all(a, b)` reads a and b at the scope's
// end, so a handle given away meanwhile is zeroed and skipped.
close_all :: proc "contextless" (handles: ..vx.Handle) {
	for h in handles {
		if h != vx.HANDLE_NONE {
			_ = handle_close(h)
		}
	}
}

@(require_results)
channel_create :: proc "contextless" () -> (a, b: vx.Handle, st: vx.Status) {
	h: [2]vx.Handle
	st = status(vx_syscall(.Channel_Create, 0, addr(&h)))
	return h[0], h[1], st
}

// The message starts with a vx.Msg_Header. The handles leave the caller's
// table whether or not the write succeeds.
@(require_results)
channel_write :: proc "contextless" (ch: vx.Handle, bytes: []u8, handles: []vx.Handle = nil) -> vx.Status {
	return status(vx_syscall(.Channel_Write, u64(ch), addr(raw_data(bytes)), u64(len(bytes)), addr(raw_data(handles)), u64(len(handles))))
}

// .Err_Should_Wait when nothing is queued; .Err_Too_Small, with the sizes,
// when the next message does not fit.
@(require_results)
channel_read :: proc "contextless" (ch: vx.Handle, bytes: []u8, handles: []vx.Handle = nil) -> (vx.Msg_Size, vx.Status) {
	size: vx.Msg_Size
	st := status(vx_syscall(.Channel_Read, u64(ch), addr(raw_data(bytes)), u64(len(bytes)), addr(raw_data(handles)), u64(len(handles)), addr(&size)))
	return size, st
}

@(require_results)
channel_call :: proc "contextless" (ch: vx.Handle, args: ^vx.Call, deadline: vx.Instant) -> vx.Status {
	return status(vx_syscall(.Channel_Call, u64(ch), addr(args), u64(deadline)))
}

@(require_results)
ring_create :: proc "contextless" (params: ^vx.Ring_Params) -> (vx.Ring_Handles, vx.Status) {
	h: vx.Ring_Handles
	st := status(vx_syscall(.Ring_Create, addr(params), addr(&h)))
	return h, st
}

// Rings the peer's doorbell: call it when the ring says the peer sleeps.
@(require_results)
ring_notify :: proc "contextless" (end: vx.Handle) -> vx.Status {
	return status(vx_syscall(.Ring_Notify, u64(end)))
}

// Puts handles in a slot for the peer, returning the slot to name in an entry.
@(require_results)
ring_put_handles :: proc "contextless" (end: vx.Handle, handles: []vx.Handle) -> (u32, vx.Status) {
	r := vx_syscall(.Ring_Xfer_Handles, u64(end), u64(vx.Ring_Xfer.Put), addr(raw_data(handles)), u64(len(handles)))
	return u32(max(r, 0)), status(r)
}

// Takes the handles in the peer's slot, returning how many.
@(require_results)
ring_take_handles :: proc "contextless" (end: vx.Handle, slot: u32, out: []vx.Handle) -> (int, vx.Status) {
	r := vx_syscall(.Ring_Xfer_Handles, u64(end), u64(vx.Ring_Xfer.Take), addr(raw_data(out)), u64(len(out)), u64(slot))
	return max(int(r), 0), status(r)
}

@(require_results)
counter_create :: proc "contextless" (initial: u64) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Counter_Create, initial, addr(&h)))
	return h, st
}

@(require_results)
counter_signal :: proc "contextless" (c: vx.Handle, value: u64) -> vx.Status {
	return status(vx_syscall(.Counter_Signal, u64(c), value))
}

@(require_results)
counter_read :: proc "contextless" (c: vx.Handle) -> (u64, vx.Status) {
	r := vx_syscall(.Counter_Read, u64(c))
	return u64(max(r, 0)), status(r)
}

@(require_results)
futex_wait :: proc "contextless" (word: ^u32, expected: u32, deadline: vx.Instant) -> vx.Status {
	return status(vx_syscall(.Futex_Wait, addr(word), u64(expected), u64(deadline)))
}

@(require_results)
futex_wake :: proc "contextless" (word: ^u32, count: u32) -> (int, vx.Status) {
	r := vx_syscall(.Futex_Wake, addr(word), u64(count))
	return max(int(r), 0), status(r)
}

// The calling thread's robust list (ADR-0037, Linux's layout): head is its
// three words, size 24, owner the value its lock words hold; head nil
// unregisters it.
@(require_results)
thread_set_robust :: proc "contextless" (head: rawptr, size: u64, owner: u32) -> vx.Status {
	return status(vx_syscall(.Thread_Set_Robust, addr(head), size, u64(owner)))
}

// --- Scheduling contexts (ADR-0016, upstream's ADR-0038) ---

@(require_results)
sched_ctx_create :: proc "contextless" (p: ^vx.Sched_Params) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Sched_Ctx_Create, addr(p), addr(&h)))
	return h, st
}

// Binds thread (HANDLE_NONE: the caller) to ctx (HANDLE_NONE: unbinds), on
// core (a CPU of its reservation) or -1.
@(require_results)
sched_ctx_bind :: proc "contextless" (ctx, thread: vx.Handle, core: i32 = -1) -> vx.Status {
	return status(vx_syscall(.Sched_Ctx_Bind, u64(ctx), u64(thread), u64(i64(core))))
}

@(require_results)
sched_ctx_configure :: proc "contextless" (ctx: vx.Handle, p: ^vx.Sched_Params) -> vx.Status {
	return status(vx_syscall(.Sched_Ctx_Configure, u64(ctx), addr(p)))
}

// count whole CPUs for ctx, all or .Err_Refused; 0 gives back its own.
@(require_results)
sched_reserve :: proc "contextless" (ctx: vx.Handle, count: u32, cls := vx.CORE_ANY, domain := vx.DOMAIN_ANY, flags := vx.Reserve_Flags{}) -> (vx.Core_Set, vx.Status) {
	set: vx.Core_Set
	st := status(vx_syscall(.Sched_Reserve, u64(ctx), u64(count), u64(cls), u64(domain), u64(transmute(u32)flags), addr(&set)))
	return set, st
}

// The calling thread's intent, anything but .Realtime, which needs a context
// (upstream's 09 §5.7 vx_intent_set, in vx-rt until libvx).
@(require_results)
intent_set :: proc "contextless" (intent: vx.Intent) -> vx.Status {
	p := vx.Sched_Params{intent = intent}
	return sched_ctx_configure(vx.HANDLE_NONE, &p)
}
