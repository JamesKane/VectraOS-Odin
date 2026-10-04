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

@(require_results)
task_create :: proc "contextless" (name: string) -> (vx.Handle, vx.Status) {
	h: vx.Handle
	st := status(vx_syscall(.Task_Create, addr(raw_data(name)), u64(len(name)), addr(&h)))
	return h, st
}

@(require_results)
task_kill :: proc "contextless" (task: vx.Handle, exit_status: i64, id: u64 = 0) -> vx.Status {
	return status(vx_syscall(.Task_Kill, u64(task), u64(exit_status), id))
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

// The handle, unless HANDLE_NONE, moves to the thread's task, and the thread
// gets its value there as its first argument.
@(require_results)
thread_start :: proc "contextless" (thread: vx.Handle, entry, sp: u64, arg: vx.Handle, arg2: u64) -> vx.Status {
	return status(vx_syscall(.Thread_Start, u64(thread), entry, sp, u64(arg), arg2))
}

thread_exit :: proc "contextless" (exit_status: i64) -> ! {
	vx_syscall(.Thread_Exit, u64(exit_status))
	for {}
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
as_map :: proc "contextless" (task, vmo: vx.Handle, offset, size: u64, flags: vx.Map_Options, at: u64 = 0) -> (u64, vx.Status) {
	va := at
	st := status(vx_syscall(.As_Map, u64(task), u64(vmo), offset, size, u64(transmute(u32)flags), addr(&va)))
	return va, st
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
