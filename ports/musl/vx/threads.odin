package backend

import "base:intrinsics"
import vx "abi:vx"
import "linux"
import "vx:note"
import "vx:rt"
import "vx:signal"

// Threads (upstream's M6 step 6d2a): musl's pthreads on kernel threads of
// the process's task.
//
// The back end's state is the process's, so its threads take turns at it: a
// lock, held through each call, recursive within a thread (the back end
// calls musl, which may call it again), and let go of wherever a call waits
// (a pipe, a sleep, a futex, sigsuspend), so the thread that would end the
// wait can come in. A 9P call holds it through the server's answer: the
// client is one thread's at a time until upstream's 6d4.
//
// A thread's own state is a @(thread_local) record, in musl's TLS. musl
// calls in before its first thread's TLS is set (set_thread_area,
// set_tid_address), and a TLS access then would fault: until then the
// record is a static copy, moved to TLS at set_tid_address, musl's last step
// of it.

Be_Thread :: struct {
	depth:         u32, // holds of be_lock
	sig_depth:     int, // inside __vx_syscall: delivery waits for its return (signal.odin)
	tid:           i64, // gettid's: 0 for the process's id, the first thread's
	ctid:          ^u32, // CLONE_CHILD_CLEARTID's (and set_tid_address's): cleared and woken at its end
	pending:       linux.Sig_Set, // signals aimed at this thread (pthread_kill), delivered on it alone
	mask:          linux.Sig_Set, // its blocked signals: a new thread starts with its creator's
	restarting:    bool, // its call is being made again after a signal, its deadline kept
	call_deadline: vx.Instant, // its sleep's or poll's (start.odin, poll.odin)
}

@(private="file")
be_lock: rt.Mutex
@(private="file")
be_early: Be_Thread
@(private="file", thread_local)
be_tl: Be_Thread
@(private="file")
be_tls: bool // be_tl usable: set_tid_address has come
be_live: u32 = 1 // threads alive, the first among them

be_me :: #force_inline proc "contextless" () -> ^Be_Thread {
	return be_tls ? &be_tl : &be_early
}

be_enter :: proc "contextless" () {
	me := be_me()
	if me.depth == 0 {
		rt.mutex_lock(&be_lock)
	}
	me.depth += 1
}

be_leave :: proc "contextless" () {
	me := be_me()
	me.depth -= 1
	if me.depth == 0 {
		rt.mutex_unlock(&be_lock)
	}
}

// Around a wait: all of this thread's holds let go, then taken back.
@(require_results)
be_wait_begin :: proc "contextless" () -> u32 {
	me := be_me()
	d := me.depth
	if d != 0 {
		me.depth = 0
		rt.mutex_unlock(&be_lock)
	}
	return d
}

be_wait_end :: proc "contextless" (d: u32) {
	if d != 0 {
		rt.mutex_lock(&be_lock)
		be_me().depth = d
	}
}

// set_tid_address: musl's last step setting up the first thread (its TLS is
// there now), and _Fork's in a child. The thread's id is the process's.
be_set_tid_address :: proc "contextless" (ctid: ^u32) -> int {
	if !be_tls {
		be_tl = be_early
		be_tls = true
	}
	be_tl.ctid, be_tl.tid = ctid, posix_pid()
	return int(be_tl.tid)
}

be_gettid :: proc "contextless" () -> int {
	me := be_me()
	return int(me.tid != 0 ? me.tid : posix_pid())
}

// --- pthread_create's thread ---

// A thread's id: the first thread's is the process's; another's, its kernel
// thread id with bit 30 set, so the two never meet.
@(private="file")
TID_THREAD :: i64(1) << 30

@(private="file")
Clone_Fn :: #type proc "c" (arg: rawptr) -> i32

@(private="file")
Clone :: struct {
	fn:   Clone_Fn,
	arg:  rawptr,
	tls:  u64,
	tid:  i64,
	ctid: ^u32,
	mask: linux.Sig_Set,
}

// The new thread's first steps: its thread pointer (musl's TLS) before
// anything, then its own state, then musl's start, which ends in SYS_exit.
@(private="file")
clone_entry :: proc "c" (unused: vx.Handle, at: u64) -> ! {
	c := (^Clone)(uintptr(at))
	_ = rt.tls_set(c.tls)
	be_tl = {
		tid  = c.tid,
		ctid = c.ctid,
		mask = c.mask,
	}
	code := c.fn(c.arg)
	_ = vx_syscall(int(linux.Sys.exit), int(code), 0, 0, 0, 0, 0)
	intrinsics.trap()
}

// musl's __clone (src/thread/clone.c, whose -ENOSYS this replaces), as
// pthread_create calls it: a thread of this task on stack, its TLS tls, its
// id written to *ptid, *ctid cleared and woken at its end. C declares it
// variadic, int __clone(int (*)(void *), void *, int, void *, ...), with
// ptid, tls and ctid after arg; on both targets' C ABIs (SysV x86_64,
// AAPCS64 as Linux has it) variadic integer arguments go where named ones
// would, so they are named here.
@(export, link_name="__clone")
be_clone :: proc "c" (fn: Clone_Fn, stack: rawptr, flags: i32, arg: rawptr, ptid: ^i32, tls: rawptr, ctid: ^u32) -> i32 {
	NEED :: linux.CLONE_VM | linux.CLONE_THREAD | linux.CLONE_SETTLS
	if flags & NEED != NEED {
		return i32(fail(.ENOSYS)) // fork comes through SYS_clone
	}
	// The record on the top of the new thread's own stack, which it reads first.
	top := (uintptr(stack) - size_of(Clone)) &~ 15
	c := (^Clone)(top)
	c^ = {
		fn   = fn,
		arg  = arg,
		tls  = u64(uintptr(tls)),
		ctid = flags & linux.CLONE_CHILD_CLEARTID != 0 ? ctid : nil,
		mask = be_me().mask,
	}
	th, id, st := rt.thread_create_id(rt.self)
	if st != .Ok {
		return i32(errno_of(st))
	}
	c.tid = TID_THREAD | i64(id)
	if flags & linux.CLONE_PARENT_SETTID != 0 {
		ptid^ = i32(c.tid)
	}
	intrinsics.atomic_add(&be_live, 1)
	st = rt.thread_start(th, u64(uintptr(rawptr(clone_entry))), u64(top), vx.HANDLE_NONE, u64(top))
	_ = rt.handle_close(th) // the thread goes on without it
	if st != .Ok {
		intrinsics.atomic_sub(&be_live, 1)
		return i32(errno_of(st))
	}
	return i32(c.tid)
}

// SYS_exit: the thread ends; the last one ends the process, as on Linux. It
// lets go of the back end first, then clears its ctid (musl's thread list
// lock, which a joiner waits on) and ends in registers alone, its stack
// being free to go from then on.
be_thread_exit :: proc "contextless" (code: int) -> ! {
	if intrinsics.atomic_sub(&be_live, 1) == 1 {
		proc_exit(code)
	}
	me := be_me()
	ctid := me.ctid
	if me.depth != 0 {
		me.depth = 0
		rt.mutex_unlock(&be_lock)
	}
	if ctid != nil {
		rt.vx_thread_finish(ctid, u64(vx.Syscall.Futex_Wake), u64(vx.Syscall.Thread_Exit))
	}
	rt.thread_exit()
}

foreign _ {
	// arch/*/context.S: as_unmap(self, base, size), *ctid cleared and woken
	// if ctid is not nil, thread_exit(), in registers alone.
	be_unmap_finish :: proc "c" (self: vx.Handle, base, size: u64, ctid: ^u32, unmap, wake, exit: u64) -> ! ---
}

// musl's __unmapself (whose generic C this replaces): a detached thread's
// end, its stack and TLS unmapped while it runs. Everything that needs them
// first (the lock let go, the count); then, in registers alone: the unmap,
// ctid (musl's thread list lock, which is not on the stack) cleared and
// woken, the thread ended.
@(export, link_name="__unmapself")
be_unmapself :: proc "c" (base: rawptr, size: uint) -> ! {
	if intrinsics.atomic_sub(&be_live, 1) == 1 {
		proc_exit(0)
	}
	me := be_me()
	ctid := me.ctid
	if me.depth != 0 {
		me.depth = 0
		rt.mutex_unlock(&be_lock)
	}
	be_unmap_finish(rt.self, u64(uintptr(base)), (u64(size) + 4095) &~ 4095, ctid, u64(vx.Syscall.As_Unmap), u64(vx.Syscall.Futex_Wake), u64(vx.Syscall.Thread_Exit))
}

// A signal's note, marked for the one thread it is posted to (be_thread_kill):
// kept pending there, not taken as the process's.
BE_DIRECTED :: " thread"

// tkill and tgkill: to this thread, delivered as the call returns; to
// another, a note to its kernel thread, whose handler takes it there.
be_thread_kill :: proc "contextless" (tid: i64, sig: int) -> int {
	if sig < 0 || sig > SIG_MAX {
		return fail(.EINVAL)
	}
	if tid == i64(be_gettid()) || tid == posix_pid() {
		return sig_kill(posix_pid(), sig)
	}
	if tid & TID_THREAD == 0 {
		return fail(.ESRCH)
	}
	if sig == 0 {
		return 0
	}
	buf: [note.ERRMAX]u8
	text := signal.signal_note(signal.Signal(sig), posix_pid(), &buf)
	n := len(text)
	if n + len(BE_DIRECTED) <= len(buf) { // its own: sig_note keeps it for that thread
		n += copy(buf[n:], BE_DIRECTED)
	}
	st := rt.thread_interrupt(rt.self, u32(tid &~ TID_THREAD), string(buf[:n]))
	return st == .Err_Not_Found ? fail(.ESRCH) : errno_of(st)
}
