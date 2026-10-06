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
	alt_base:      u64, // sigaltstack's; alt_size 0: none
	alt_size:      u64,
	slot:          u32, // in be_threads, plus 1; 0: not there
	handlers_ran:  u32, // signal.odin's: the handlers run on it,
	eintr_ran:     u32, // and those of them not SA_RESTART
	robust:        u64, // set_robust_list's head
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
		be_slot_set(0, be_only_thread_id(), &be_tl)
	}
	be_tl.ctid, be_tl.tid = ctid, posix_pid()
	return int(be_tl.tid)
}

// A thread's id: the pid for the first thread, until set_tid_address says so
// too.
be_gettid :: proc "contextless" () -> int {
	me := be_me()
	return int(me.tid != 0 ? me.tid : posix_pid())
}

// --- pthread_create's thread ---

@(private="file")
Clone_Fn :: #type proc "c" (arg: rawptr) -> i32

@(private="file")
Clone :: struct {
	fn:   Clone_Fn,
	arg:  rawptr,
	tls:  u64,
	tid:  i64,
	slot: u32,
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
		slot = c.slot + 1,
	}
	intrinsics.atomic_store(&be_threads[c.slot].t, &be_tl) // __clone gave the slot its kernel id
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
	slot := posix_pid() <= PID_MASK ? be_slot_take() : 0
	if slot == 0 {
		return i32(fail(.EAGAIN)) // 255 threads besides the first, or a pid past 2^22: no id fits (ADR-0015)
	}
	th, id, st := rt.thread_create_id(rt.self)
	if st != .Ok {
		intrinsics.atomic_store(&be_threads[slot].id, 0)
		return i32(errno_of(st))
	}
	c.slot = slot
	c.tid = i64(slot) << TID_SHIFT | posix_pid()
	intrinsics.atomic_store(&be_threads[slot].id, id)
	if flags & linux.CLONE_PARENT_SETTID != 0 {
		ptid^ = i32(c.tid)
	}
	intrinsics.atomic_add(&be_live, 1)
	st = rt.thread_start(th, u64(uintptr(rawptr(clone_entry))), u64(top), vx.HANDLE_NONE, u64(top))
	_ = rt.handle_close(th) // the thread goes on without it
	if st != .Ok {
		intrinsics.atomic_sub(&be_live, 1)
		intrinsics.atomic_store(&be_threads[slot].id, 0)
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
	be_unregister(me)
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
	be_unregister(me)
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

// tkill and tgkill: to this thread, its own, delivered as the call returns;
// to another, a note to its kernel thread (its id's slot says which), whose
// handler keeps it for that thread.
be_thread_kill :: proc "contextless" (tid: i64, sig: int) -> int {
	if sig < 0 || sig > SIG_MAX {
		return fail(.EINVAL)
	}
	pid := posix_pid()
	slot := u64(tid) >> TID_SHIFT
	if tid <= 0 || tid & PID_MASK != pid || slot >= BE_THREADS {
		return fail(.ESRCH)
	}
	id := intrinsics.atomic_load(&be_threads[slot].id)
	if id == 0 || id == SLOT_TAKEN {
		return fail(.ESRCH)
	}
	if sig == 0 {
		return 0
	}
	if be_me().slot == u32(slot) + 1 {
		be_me().pending += {sig}
		sig_set_sender(sig, pid)
		return 0
	}
	buf: [note.ERRMAX]u8
	text := signal.signal_note(signal.Signal(sig), posix_pid(), &buf)
	n := len(text)
	if n + len(BE_DIRECTED) <= len(buf) { // its own: sig_note keeps it for that thread
		n += copy(buf[n:], BE_DIRECTED)
	}
	st := rt.thread_interrupt(rt.self, id, string(buf[:n]))
	return st == .Err_Not_Found ? fail(.ESRCH) : errno_of(st)
}

// --- The process's threads (upstream's M6 step 6d2b) ---
//
// Each live thread in a slot, with its kernel id: slot 0 the first thread's,
// 1 to 255 pthread_create's. A thread's id (gettid, and the owner in musl's
// lock words) is its slot shifted left 22, plus the pid: 30 bits, unique
// across processes while pids stay under 2^22 (ADR-0015, upstream's M6 step
// 6d3). tkill finds the kernel thread through it, and be_forward passes a
// signal from another process, that the thread whose note it came in
// blocks, to one that does not. A reader counts itself in before it looks at
// a thread's record, which be_unregister waits out, so the record (in that
// thread's TLS) is not gone from under it.

BE_THREADS :: 256
@(private="file")
TID_SHIFT :: 22
@(private="file")
PID_MASK :: i64(1) << TID_SHIFT - 1
@(private="file")
SLOT_TAKEN :: max(u32) // reserved by __clone; its thread not made yet

Be_Slot :: struct {
	id:      u32, // its kernel thread id; 0: free
	readers: u32, // be_forwards looking at t
	t:       ^Be_Thread,
}

be_threads: [BE_THREADS]Be_Slot

// A free slot past the first's, reserved; 0 if none.
@(private="file")
be_slot_take :: proc "contextless" () -> u32 {
	for i in 1 ..< BE_THREADS {
		if _, ok := intrinsics.atomic_compare_exchange_strong(&be_threads[i].id, 0, SLOT_TAKEN); ok {
			return u32(i)
		}
	}
	return 0
}

// Slot i is the thread whose record is t, kernel id id.
be_slot_set :: proc "contextless" (i: u32, id: u32, t: ^Be_Thread) {
	intrinsics.atomic_store(&be_threads[i].id, id)
	intrinsics.atomic_store(&be_threads[i].t, t)
	t.slot = i + 1
}

@(private="file")
be_unregister :: proc "contextless" (t: ^Be_Thread) {
	if t.slot == 0 {
		return
	}
	s := &be_threads[t.slot - 1]
	intrinsics.atomic_store(&s.t, nil)
	for intrinsics.atomic_load(&s.readers) != 0 {
		intrinsics.cpu_relax() // a reader with t in hand: done in a few instructions
	}
	intrinsics.atomic_store(&s.id, 0)
	t.slot = 0
}

// The calling thread, as the kernel numbers it: the first of the task's when
// it is the only one (start-up, a forked child).
be_only_thread_id :: proc "contextless" () -> u32 {
	ti: vx.Thread_Info
	return rt.thread_state(rt.self, 0, .Next_Thread, &ti) == .Ok ? ti.id : 0
}

// The process's signal sig, which this thread blocks, posted to a thread
// that does not, marked as its own; false if none does (or none would take
// the note), and it stays the process's, pending.
be_forward :: proc "contextless" (sig: int, text: string) -> bool {
	buf: [note.ERRMAX]u8
	if len(text) + len(BE_DIRECTED) > len(buf) {
		return false
	}
	n := copy(buf[:], text)
	n += copy(buf[n:], BE_DIRECTED)
	me := be_me()
	for &s in be_threads {
		id := intrinsics.atomic_load(&s.id)
		if id == 0 || id == SLOT_TAKEN {
			continue
		}
		intrinsics.atomic_add(&s.readers, 1)
		t := intrinsics.atomic_load(&s.t)
		takes := t != nil && t != me && sig not_in transmute(linux.Sig_Set)intrinsics.atomic_load_explicit((^u64)(&t.mask), .Relaxed)
		intrinsics.atomic_sub(&s.readers, 1)
		if takes && rt.thread_interrupt(rt.self, id, string(buf[:n])) == .Ok {
			return true
		}
	}
	return false
}

// --- The alternate signal stack (upstream's M6 step 6d2b) ---

foreign _ {
	// arch/*/context.S: fn(a0, a1, a2) on the stack whose top is top; back
	// on this one after.
	be_on_stack :: proc "c" (top: u64, fn: uintptr, a0: int, a1, a2: rawptr) ---
}

// Whether the thread runs on its alternate stack now.
be_on_alt :: proc "contextless" (t: ^Be_Thread) -> bool {
	here: u8
	sp := u64(uintptr(&here))
	return t.alt_size != 0 && sp > t.alt_base && sp <= t.alt_base + t.alt_size
}

// sigaltstack's flags for the thread's alternate stack, on it or not.
be_alt_flags :: proc "contextless" (t: ^Be_Thread, on: bool) -> i32 {
	if t.alt_size == 0 {
		return linux.SS_DISABLE
	}
	return on ? linux.SS_ONSTACK : 0
}

// sigaltstack: the stack is the thread's note stack too (ADR-0036), where
// the kernel diverts it for a note or a fault, so an overflow's SIGSEGV has
// room.
be_altstack :: proc "contextless" (ss, old: ^linux.Stack) -> int {
	me := be_me()
	on := be_on_alt(me)
	if old != nil {
		old^ = {
			sp    = uintptr(me.alt_base),
			size  = uint(me.alt_size),
			flags = be_alt_flags(me, on),
		}
	}
	if ss == nil {
		return 0
	}
	if on {
		return fail(.EPERM)
	}
	if ss.flags & ~i32(linux.SS_DISABLE) != 0 {
		return fail(.EINVAL) // SS_AUTODISARM: not yet
	}
	ns: vx.Note_Stack
	if ss.flags & linux.SS_DISABLE == 0 {
		if ss.size < linux.MINSIGSTKSZ {
			return fail(.ENOMEM)
		}
		ns = {
			base = u64(ss.sp),
			size = u64(ss.size),
		}
	}
	if rt.thread_state(rt.self, 0, .Set_Note_Stack, &ns) != .Ok {
		return fail(.EINVAL)
	}
	me.alt_base, me.alt_size = ns.base, ns.size
	return 0
}

// After fork: the child's one thread numbered anew, its alternate stack set
// again (copied with its memory; the kernel's new thread has none).
be_after_fork :: proc "contextless" () {
	intrinsics.atomic_store(&be_live, 1) // the thread that forked, alone
	be_threads = {}
	me := be_me()
	me.robust = 0 // the child's thread is a new one, with no list (musl registers again)
	me.pending = {} // and none of the thread's signals pending
	be_slot_set(0, be_only_thread_id(), me)
	if me.alt_size != 0 {
		ns := vx.Note_Stack {
			base = me.alt_base,
			size = me.alt_size,
		}
		_ = rt.thread_state(rt.self, 0, .Set_Note_Stack, &ns)
	}
}
