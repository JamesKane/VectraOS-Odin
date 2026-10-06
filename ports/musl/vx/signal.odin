package backend

import "base:intrinsics"
import vx "abi:vx"
import "linux"
import "vx:memory"
import "vx:ndb"
import "vx:note"
import "vx:ns"
import "vx:p9"
import "vx:rt"
import "vx:signal"
import "vx:str"

// POSIX signals (upstream docs/01 §9).
//
// Signals are built on notes (ADR-0010). The dispositions, the mask and the
// pending set live here, in the process. A signal from another process is a
// note ("posix: SIGTERM pid=12", or Plan 9's "interrupt" and the like) that
// procfs posts when it is written to /proc (kill, below); sig_note, this
// process's note handler (vx:rt's notify), maps it to its signal through
// vx:signal's table. So does any fault, which becomes SIGSEGV, SIGBUS,
// SIGILL, SIGFPE or SIGTRAP. A note that is no signal ends the process with
// it, as in Plan 9. A signal to itself (raise, abort, kill of its own pid) is
// made pending here.
//
// A handler never runs inside the back end, which is not reentrant and may
// be in the middle of a ring submission: a signal that arrives there is made
// pending, the call it interrupted returns .Err_Interrupted, and
// __vx_syscall delivers it on its way out. Then the call returns EINTR if a
// handler that is not SA_RESTART ran, and is made again otherwise. A signal
// that arrives in the program's own code is delivered at once, on its stack.
//
// A stopping signal's default stops the process through its ctl ("stop
// SIG", so its parent's wait learns which); SIGSTOP, SIGKILL and SIGCONT
// from another process, procfs carries out itself (ADR-0011). kill writes
// notes to /proc, as 9front's APE does: note for a process, notepg for a
// group.
//
// A handler's ucontext carries the registers and FP/SIMD state a fault or
// a note interrupted, and the thread goes on with what the handler leaves
// there; sigaltstack is the thread's note stack (ADR-0036), and an
// SA_ONSTACK handler runs on it. A process's signal that the thread it came
// to blocks is passed to one that does not (threads.odin's be_forward).

SIG_MAX :: linux.NSIG_MAX

@(private="file")
Action :: struct {
	handler: uintptr, // SIG_DFL, SIG_IGN, or a function
	flags:   linux.Sa_Flags,
	mask:    linux.Sig_Set,
}

@(private="file")
actions: [SIG_MAX + 1]Action

// A thread's mask, its depth inside __vx_syscall (delivery waits for its
// return), the signals aimed at it alone and its call's deadline are its
// own (threads.odin's Be_Thread, be_me()); a new thread's mask is its
// creator's.
//
// Pending: atomic, as a note handler may set a bit between the load and the
// store of a change made in the program's code.
sig_pending: linux.Sig_Set
@(private="file")
sender_of: [SIG_MAX + 1]i64 // who sent each pending one
// Changed by sig_note for each signal that comes while the back end runs: a
// sleep waits on it, so one that comes just before the sleep ends it too.
sig_seq: u32

UNBLOCKABLE :: linux.Sig_Set{linux.SIGKILL, linux.SIGSTOP}

pending_load :: proc "contextless" () -> linux.Sig_Set {
	return transmute(linux.Sig_Set)intrinsics.atomic_load((^u64)(&sig_pending))
}

@(private="file")
pending_add :: proc "contextless" (sig: int) {
	intrinsics.atomic_or((^u64)(&sig_pending), transmute(u64)linux.Sig_Set{sig})
}

pending_remove :: proc "contextless" (which: linux.Sig_Set) {
	intrinsics.atomic_and((^u64)(&sig_pending), ~transmute(u64)which)
}

@(private="file")
regs_pc :: proc "contextless" (e: ^vx.Exception) -> u64 {
	when ODIN_ARCH == .amd64 {
		return e.regs.rip
	} else {
		return e.regs.pc
	}
}

// Ends the process as the signal does by default, with an exit string a
// parent's wait reads as that signal (vx:signal): a fault's note, or the
// signal's. A fault is reported first, as the kernel would.
@(private="file")
sig_terminate :: proc "contextless" (sig: int, e: ^vx.Exception, fault: string) -> ! {
	if e != nil {
		line: [160]u8
		b := note.Buf {
			buf = line[:len(line) - 1],
		}
		note.put(&b, "vx-musl: ")
		note.put(&b, rt.spawn.name)
		note.put(&b, " (pid ")
		note.put_dec(&b, u64(posix_pid()))
		note.put(&b, "): fatal signal ")
		note.put_dec(&b, u64(sig))
		note.put(&b, " at pc ")
		note.put_hex(&b, regs_pc(e))
		note.put(&b, ", address ")
		note.put_hex(&b, e.address)
		note.put(&b, "\n")
		_ = console_write(transmute([]u8)note.to_string(&b))
	}
	if e != nil && e.kind != .Interrupt { // a fault: again, uncaught; a crash directory, then its end
		again := e^
		rt.note_crash(&again)
	}
	text: [note.ERRMAX]u8
	proc_exit_str(len(fault) > 0 ? fault : signal.signal_note(signal.Signal(sig), 0, &text))
}

@(private="file")
Handler :: #type proc "c" (sig: i32)
@(private="file")
Info_Handler :: #type proc "c" (sig: i32, info: ^linux.Siginfo, uc: rawptr)

// --- A handler's context (upstream's M6 step 6d2b) ---
//
// What a handler's ucontext carries, and takes back: the registers of the
// program's code a fault or a note diverted the thread from, with the
// FP/SIMD state vx_note_entry saved (in its image, which is Linux's: x86_64's
// FXSAVE leads XSAVE's, aarch64's is fpsimd_context's registers). A signal
// delivered as a call returns has none: its ucontext's registers are zero.
@(private="file")
Sig_Context :: struct {
	e:  ^vx.Exception,
	fp: rawptr, // vx_note_entry's save area
}

@(private="file")
sig_uc_fill :: proc "contextless" (uc: ^linux.Ucontext, c: ^Sig_Context) {
	r := &c.e.regs
	when ODIN_ARCH == .amd64 {
		g := &uc.mcontext.gregs
		g[linux.REG_R8], g[linux.REG_R9], g[linux.REG_R10], g[linux.REG_R11] = i64(r.r8), i64(r.r9), i64(r.r10), i64(r.r11)
		g[linux.REG_R12], g[linux.REG_R13], g[linux.REG_R14], g[linux.REG_R15] = i64(r.r12), i64(r.r13), i64(r.r14), i64(r.r15)
		g[linux.REG_RDI], g[linux.REG_RSI], g[linux.REG_RBP], g[linux.REG_RBX] = i64(r.rdi), i64(r.rsi), i64(r.rbp), i64(r.rbx)
		g[linux.REG_RDX], g[linux.REG_RAX], g[linux.REG_RCX], g[linux.REG_RSP] = i64(r.rdx), i64(r.rax), i64(r.rcx), i64(r.rsp)
		g[linux.REG_RIP], g[linux.REG_EFL] = i64(r.rip), i64(r.rflags)
		if c.e.kind == .Page_Fault || c.e.kind == .Protection_Key {
			// #PF, with its error code as Linux gives it: user, write, fetch, key.
			err := i64(4)
			if c.e.code == 1 {
				err |= 2
			}
			if c.e.code == 2 {
				err |= 16
			}
			if c.e.kind == .Protection_Key {
				err |= 32
			}
			g[linux.REG_TRAPNO], g[linux.REG_ERR], g[linux.REG_CR2] = 14, err, i64(c.e.address)
		}
		uc.mcontext.fpregs = c.fp
	} else {
		m := &uc.mcontext
		m.regs = r.x
		m.sp, m.pc, m.pstate, m.fault_address = r.sp, r.pc, r.pstate, c.e.address
		f := (^vx.Fpregs)(c.fp)
		fs := (^linux.Fpsimd_Context)(&m.reserved) // then a zero header: the end
		fs.head = {
			magic = linux.FPSIMD_MAGIC,
			size  = size_of(linux.Fpsimd_Context),
		}
		fs.fpsr, fs.fpcr = u32(f.fpsr), u32(f.fpcr)
		fs.vregs = f.v
	}
}

// What the handler changed, for the thread to go on with.
@(private="file")
sig_uc_take :: proc "contextless" (uc: ^linux.Ucontext, c: ^Sig_Context) {
	r := &c.e.regs
	when ODIN_ARCH == .amd64 {
		g := &uc.mcontext.gregs
		r.r8, r.r9, r.r10, r.r11 = u64(g[linux.REG_R8]), u64(g[linux.REG_R9]), u64(g[linux.REG_R10]), u64(g[linux.REG_R11])
		r.r12, r.r13, r.r14, r.r15 = u64(g[linux.REG_R12]), u64(g[linux.REG_R13]), u64(g[linux.REG_R14]), u64(g[linux.REG_R15])
		r.rdi, r.rsi, r.rbp, r.rbx = u64(g[linux.REG_RDI]), u64(g[linux.REG_RSI]), u64(g[linux.REG_RBP]), u64(g[linux.REG_RBX])
		r.rdx, r.rax, r.rcx, r.rsp = u64(g[linux.REG_RDX]), u64(g[linux.REG_RAX]), u64(g[linux.REG_RCX]), u64(g[linux.REG_RSP])
		r.rip, r.rflags = u64(g[linux.REG_RIP]), u64(g[linux.REG_EFL])
		// fpregs points at the save area itself: changes there are already made.
	} else {
		m := &uc.mcontext
		r.x = m.regs
		r.sp, r.pc, r.pstate = m.sp, m.pc, m.pstate
		f := (^vx.Fpregs)(c.fp)
		fs := (^linux.Fpsimd_Context)(&m.reserved)
		if fs.head.magic == linux.FPSIMD_MAGIC {
			f.fpsr, f.fpcr = u64(fs.fpsr), u64(fs.fpcr)
			f.v = fs.vregs
		}
	}
}

// A handler called: on the alternate stack for SA_ONSTACK, unless the thread
// is on it already (the kernel diverted it there, or a handler runs there).
@(private="file")
sig_call :: proc "contextless" (flags: linux.Sa_Flags, h: uintptr, sig: int, info: ^linux.Siginfo, uc: ^linux.Ucontext) {
	me := be_me()
	switch {
	case .Onstack in flags && me.alt_size != 0 && !be_on_alt(me):
		be_on_stack(me.alt_base + me.alt_size, h, sig, info, uc)
	case .Siginfo in flags:
		(Info_Handler)(rawptr(h))(i32(sig), info, uc)
	case:
		(Handler)(rawptr(h))(i32(sig))
	}
}

// Carries out sig's disposition. Returns whether a call it interrupted
// returns EINTR: a handler ran that is not SA_RESTART.
@(private="file")
sig_act :: proc "contextless" (sig: int, code: i32, sender: i64, address: u64, e: ^vx.Exception, fault: string, ctx: ^Sig_Context) -> bool {
	h := actions[sig].handler
	flags := actions[sig].flags
	if h == linux.SIG_IGN {
		return false
	}
	if h == linux.SIG_DFL {
		switch sig {
		case linux.SIGSTOP, linux.SIGTSTP, linux.SIGTTIN, linux.SIGTTOU: // stop, until SIGCONT
			cmd: [16]u8
			b := note.Buf {
				buf = cmd[:],
			}
			note.put(&b, "stop ")
			note.put_dec(&b, u64(sig))
			_ = proc_write(posix_pid(), "ctl", note.to_string(&b)) // answered, then stopped on the way out
			return false
		}
		if signal.default_ignored(signal.Signal(sig)) {
			return false
		}
		sig_terminate(sig, e, fault)
	}
	old := be_me().mask
	be_me().mask += actions[sig].mask - UNBLOCKABLE
	if .Nodefer not_in flags {
		be_me().mask += {sig}
	}
	if .Resethand in flags {
		actions[sig] = {}
	}
	be_me().handlers_ran += 1
	if .Restart not_in flags {
		be_me().eintr_ran += 1
	}
	// The handler is the program's own code, even when the back end delivers
	// it (sigsuspend, ppoll, a fault in a call): a signal during it is
	// delivered at once, and a siglongjmp out of it leaves the back end as it
	// is in the program's code.
	depth := be_me().sig_depth
	be_me().sig_depth = 0
	if .Siginfo in flags {
		info := linux.Siginfo {
			signo = i32(sig),
			code  = code,
		}
		if e != nil {
			info.fields.addr = uintptr(address) // a fault's; a signal's sender shares the union with it
			if code == linux.SEGV_PKUERR {
				info.fields.fault.pkey = e.key // the page's protection key (ADR-0035)
			}
		} else {
			info.fields.pid = i32(sender)
		}
		uc: linux.Ucontext
		mask := old
		copy(uc.sigmask[:], memory.ptr_to_bytes(&mask))
		me := be_me()
		uc.stack = {
			sp    = uintptr(me.alt_base),
			size  = uint(me.alt_size),
			flags = be_alt_flags(me, be_on_alt(me)),
		}
		if ctx != nil {
			sig_uc_fill(&uc, ctx)
		}
		sig_call(flags, h, sig, &info, &uc)
		if ctx != nil {
			sig_uc_take(&uc, ctx)
		}
	} else {
		sig_call(flags, h, sig, nil, nil)
	}
	be_me().sig_depth = depth
	be_me().mask = old
	return .Restart not_in flags
}

// Delivers every pending signal that is not blocked, lowest first; ctx, if
// the thread was diverted from the program's code, the handlers' registers.
@(private="file")
sig_deliver_in :: proc "contextless" (ctx: ^Sig_Context) -> (eintr: bool) {
	me := be_me()
	for {
		ready := (pending_load() + me.pending) - me.mask
		if ready == {} {
			return
		}
		sig := lowest(ready)
		if sig in me.pending { // the thread's own first (pthread_kill), then the process's
			me.pending -= {sig}
		} else {
			pending_remove({sig})
		}
		who := sender_of[sig]
		eintr = sig_act(sig, who != 0 ? linux.SI_USER : linux.SI_KERNEL, who, 0, nil, "", ctx) || eintr
	}
}

sig_deliver_pending :: proc "contextless" () -> bool {
	return sig_deliver_in(nil)
}

@(private="file")
lowest :: proc "contextless" (s: linux.Sig_Set) -> int {
	return int(intrinsics.count_trailing_zeros(transmute(u64)s)) + 1
}

// From __vx_syscall, the pending signals not blocked, delivered as from the
// program's code; a sleep's or poll's deadline kept from a handler's own.
sig_run_pending :: proc "contextless" () {
	if (pending_load() + be_me().pending) - be_me().mask == {} {
		return
	}
	depth := be_me().sig_depth
	kept := be_me().call_deadline
	be_me().sig_depth = 0
	_ = sig_deliver_pending()
	be_me().sig_depth = depth
	be_me().call_deadline = kept
}

// Who sent sig, for its siginfo when it is delivered.
sig_set_sender :: proc "contextless" (sig: int, who: i64) {
	sender_of[sig] = who
}

sig_raise_self :: proc "contextless" (sig: int) {
	pending_add(sig)
	sender_of[sig] = posix_pid()
}

// The note handler: a note from another process, or a fault.
@(private="file")
sig_note :: proc "contextless" (e: ^vx.Exception, text: string, fp: rawptr) -> rt.Noted {
	ctx := Sig_Context{e, fp}
	if e.kind == .Interrupt {
		// be_thread_kill's mark: this thread's alone. Without it, the process's:
		// taken here, or by a thread that does not block it (be_forward).
		directed := str.has_suffix(text, BE_DIRECTED) && len(text) > len(BE_DIRECTED)
		s, sender, ok := signal.note_signal(directed ? text[:len(text) - len(BE_DIRECTED)] : text)
		sig := int(s)
		if !ok || sig < 1 || sig > SIG_MAX {
			return .Dflt // no signal: the note ends the process
		}
		if !directed && sig in be_me().mask && be_forward(sig, text) {
			return .Cont
		}
		sender_of[sig] = sender
		if directed {
			be_me().pending += {sig}
		} else {
			pending_add(sig)
		}
		if be_me().sig_depth == 0 {
			_ = sig_deliver_in(&ctx) // in the program's own code
		} else if sig not_in be_me().mask {
			// In the back end, maybe just before it waits: the kernel had
			// this note interrupt nothing (it came in user mode), so the wait
			// is woken here, whichever it is: fd_port's (fd_wait), or
			// sig_seq's.
			intrinsics.atomic_add(&sig_seq, 1)
			_, _ = rt.futex_wake(&sig_seq, max(u32))
			pk := vx.Packet {
				key = KEY_SIGNAL,
			}
			_ = rt.port_post(fd_port, &pk)
		}
		return .Cont
	}
	sig, code := linux.SIGSEGV, i32(linux.SEGV_MAPERR)
	#partial switch e.kind {
	case .Alignment:
		sig, code = linux.SIGBUS, linux.BUS_ADRALN
	case .Pager_Timeout: // a mapped file's page that did not come
		sig, code = linux.SIGBUS, linux.BUS_ADRERR
	case .Illegal, .Fp_Disabled:
		sig, code = linux.SIGILL, linux.ILL_ILLOPC
	case .Arithmetic:
		sig, code = linux.SIGFPE, linux.FPE_INTDIV
	case .Breakpoint, .Step:
		sig, code = linux.SIGTRAP, linux.TRAP_BRKPT
	case .General:
		code = linux.SI_KERNEL
	case .Protection_Key: // SIGSEGV, si_pkey the key (ADR-0035)
		code = linux.SEGV_PKUERR
	}
	// A fault that is blocked or ignored would only happen again: its default.
	if sig in be_me().mask || actions[sig].handler == linux.SIG_IGN {
		sig_terminate(sig, e, text)
	}
	_ = sig_act(sig, code, 0, e.address, e, text, &ctx) // then the instruction again, unless the handler jumped away
	return .Cont
}

sig_init :: proc "contextless" () {
	rt.note_exit = proc_exit_str // a note that is no signal ends the process with it
	rec: ndb.Record
	if rt.spawn_record("signals", &rec) {
		ignored, iok := ndb.get_u64(&rec, "signals")
		mask, mok := ndb.get_u64(&rec, "mask")
		if iok && mok { // from a POSIX parent: what exec and posix_spawn keep
			for sig in transmute(linux.Sig_Set)ignored - UNBLOCKABLE {
				actions[sig].handler = linux.SIG_IGN
			}
			be_me().mask = transmute(linux.Sig_Set)mask - UNBLOCKABLE
		}
	}
	_ = rt.notify(sig_note)
}

// --- The calls ---

// The first word of a sigset_t, as the kernel's calls take it (8 bytes).
sigset_word :: proc "contextless" (p: rawptr) -> linux.Sig_Set {
	return intrinsics.unaligned_load((^linux.Sig_Set)(p))
}

sig_action :: proc "contextless" (sig: int, act, old: ^linux.K_Sigaction) -> int {
	if sig < 1 || sig > SIG_MAX || ((sig == linux.SIGKILL || sig == linux.SIGSTOP) && act != nil) {
		return fail(.EINVAL)
	}
	if old != nil {
		a := actions[sig]
		old^ = {
			handler = a.handler,
			flags   = a.flags,
		}
		w := transmute(u64)a.mask
		old.mask = {u32(w), u32(w >> 32)}
	}
	if act != nil {
		actions[sig] = {
			handler = act.handler,
			flags   = act.flags,
			mask    = transmute(linux.Sig_Set)(u64(act.mask[0]) | u64(act.mask[1]) << 32),
		}
		if act.handler == linux.SIG_IGN {
			pending_remove({sig}) // discarded, as POSIX has it
		}
	}
	return 0
}

// The pending signals now unblocked are delivered as the call returns.
sig_procmask :: proc "contextless" (how: int, set: rawptr, old: ^linux.Sig_Set) -> int {
	was := be_me().mask
	if set != nil {
		s := sigset_word(set)
		switch how {
		case linux.SIG_BLOCK:
			be_me().mask += s
		case linux.SIG_UNBLOCK:
			be_me().mask -= s
		case linux.SIG_SETMASK:
			be_me().mask = s
		case:
			return fail(.EINVAL)
		}
		be_me().mask -= UNBLOCKABLE
	}
	if old != nil {
		intrinsics.unaligned_store(old, was)
	}
	return 0
}

// sigsuspend and pause: wait with this mask until a signal is delivered, and
// return EINTR; the old mask comes back after the handler. Only a handler
// ends the wait: a signal that is ignored, by its disposition or by default,
// leaves it waiting.
sig_suspend :: proc "contextless" (mask: linux.Sig_Set) -> int {
	was := be_me().mask
	be_me().mask = mask - UNBLOCKABLE
	ran := be_me().handlers_ran
	for {
		seq := intrinsics.atomic_load(&sig_seq) // before the check: a signal after it changes sig_seq
		if (pending_load() + be_me().pending) - be_me().mask != {} {
			_ = sig_deliver_pending()
			if be_me().handlers_ran != ran {
				break
			}
			continue
		}
		held := be_wait_begin()
		_ = rt.futex_wait(&sig_seq, seq, vx.INFINITE) // an interrupt, or sig_note, ends it
		be_wait_end(held)
	}
	be_me().mask = was
	return fail(.EINTR)
}

sig_forget_pending :: proc "contextless" (which: linux.Sig_Set) {
	pending_remove(which)
	for sig in which {
		sender_of[sig] = 0
	}
}

// What a child keeps of this process's signals (Spawn_Ctx), as a record for
// sig_init's: the ignored ones, and the mask.
sig_records :: proc "contextless" (w: ^ndb.Writer, ctx: ^Spawn_Ctx) {
	ignored: linux.Sig_Set
	for &a, sig in actions {
		if sig > 0 && a.handler == linux.SIG_IGN {
			ignored += {sig}
		}
	}
	ndb.put_u64(w, "signals", transmute(u64)(ignored - ctx.sig_default))
	ndb.put_u64(w, "mask", transmute(u64)(ctx.has_mask ? ctx.blocked : be_me().mask))
	_ = ndb.end(w)
}

// The number a /proc entry's name starts with.
@(private="file")
leading_number :: proc "contextless" (s: string) -> (v: i64) {
	for c in transmute([]u8)s[:min(len(s), 23)] {
		if c < '0' || c > '9' {
			break
		}
		v = v * 10 + i64(c - '0')
	}
	return
}

// kill(-1): every process but this one and svcd (pid 1), through /proc's
// list.
@(private="file")
sig_kill_all :: proc "contextless" (text: string) -> int {
	dir: ns.File
	if ns.open(namespace(), "/proc", p9.OREAD, &dir) != .Ok {
		return fail(.ESRCH)
	}
	@(static) buf: [4096]u8
	sent := 0
	for {
		n, st := ns.read(&dir, buf[:])
		if st != .Ok || n <= 0 {
			break
		}
		it := p9.Dir_Entries {
			buf = buf[:n],
		}
		for entry in p9.next_entry(&it) {
			pid := leading_number(entry.name)
			if pid > 1 && pid != posix_pid() && proc_write(pid, "note", text) == 0 {
				sent += 1
			}
		}
	}
	ns.close(&dir)
	return sent > 0 ? 0 : fail(.ESRCH)
}

sig_kill :: proc "contextless" (pid: i64, sig: int) -> int {
	if sig < 0 || sig > SIG_MAX {
		return fail(.EINVAL)
	}
	if pid == posix_pid() { // delivered as this call returns
		if sig != 0 {
			sig_raise_self(sig)
		}
		return 0
	}
	if !proc_mounted {
		return fail(.ESRCH) // alone: no other process to reach
	}
	buf: [note.ERRMAX]u8
	text := signal.signal_note(signal.Signal(sig), posix_pid(), &buf)
	if sig == 0 { // only whether it is there: the process, or the group's leader
		who := posix_pid()
		if pid > 0 {
			who = pid
		} else if pid < -1 {
			who = -pid
		}
		status: [512]u8
		_, r := proc_read(who, "status", status[:])
		return r < 0 ? r : 0
	}
	switch {
	case pid > 0:
		return proc_write(pid, "note", text)
	case pid == 0:
		return proc_write(posix_pid(), "notepg", text) // which reaches this process too
	case pid < -1:
		return proc_write(-pid, "notepg", text) // the group of its leader, -pid
	}
	return sig_kill_all(text)
}
