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
// Not yet: an alternate signal stack, and the registers in a handler's
// ucontext.

SIG_MAX :: linux.NSIG_MAX

@(private="file")
Action :: struct {
	handler: uintptr, // SIG_DFL, SIG_IGN, or a function
	flags:   linux.Sa_Flags,
	mask:    linux.Sig_Set,
}

@(private="file")
actions: [SIG_MAX + 1]Action

sig_mask: linux.Sig_Set
// Pending: atomic, as a note handler may set a bit between the load and the
// store of a change made in the program's code.
sig_pending: linux.Sig_Set
@(private="file")
sender_of: [SIG_MAX + 1]i64 // who sent each pending one
sig_depth: int // inside __vx_syscall: delivery waits for its return
sig_handlers_ran: u32 // how many handlers have run
sig_eintr_ran: u32 // how many of them were not SA_RESTART (a call they interrupt ends)
sig_restarting: bool // the call is being made again after a signal (its deadline kept)
sig_call_deadline: vx.Instant // a sleep's or poll's
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

// Carries out sig's disposition. Returns whether a call it interrupted
// returns EINTR: a handler ran that is not SA_RESTART.
@(private="file")
sig_act :: proc "contextless" (sig: int, code: i32, sender: i64, address: u64, e: ^vx.Exception, fault: string) -> bool {
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
	old := sig_mask
	sig_mask += actions[sig].mask - UNBLOCKABLE
	if .Nodefer not_in flags {
		sig_mask += {sig}
	}
	if .Resethand in flags {
		actions[sig] = {}
	}
	sig_handlers_ran += 1
	if .Restart not_in flags {
		sig_eintr_ran += 1
	}
	// The handler is the program's own code, even when the back end delivers
	// it (sigsuspend, ppoll, a fault in a call): a signal during it is
	// delivered at once, and a siglongjmp out of it leaves the back end as it
	// is in the program's code.
	depth := sig_depth
	sig_depth = 0
	if .Siginfo in flags {
		info := linux.Siginfo {
			signo = i32(sig),
			code  = code,
		}
		if e != nil {
			info.fields.addr = uintptr(address) // a fault's; a signal's sender shares the union with it
		} else {
			info.fields.pid = i32(sender)
		}
		uc: linux.Ucontext
		mask := old
		copy(uc.sigmask[:], memory.ptr_to_bytes(&mask))
		(Info_Handler)(rawptr(h))(i32(sig), &info, &uc)
	} else {
		(Handler)(rawptr(h))(i32(sig))
	}
	sig_depth = depth
	sig_mask = old
	return .Restart not_in flags
}

// Delivers every pending signal that is not blocked, lowest first.
sig_deliver_pending :: proc "contextless" () -> (eintr: bool) {
	for {
		ready := pending_load() - sig_mask
		if ready == {} {
			return
		}
		sig := lowest(ready)
		pending_remove({sig})
		who := sender_of[sig]
		eintr = sig_act(sig, who != 0 ? linux.SI_USER : linux.SI_KERNEL, who, 0, nil, "") || eintr
	}
}

@(private="file")
lowest :: proc "contextless" (s: linux.Sig_Set) -> int {
	return int(intrinsics.count_trailing_zeros(transmute(u64)s)) + 1
}

// From __vx_syscall, the pending signals not blocked, delivered as from the
// program's code; a sleep's or poll's deadline kept from a handler's own.
sig_run_pending :: proc "contextless" () {
	if pending_load() - sig_mask == {} {
		return
	}
	depth := sig_depth
	kept := sig_call_deadline
	sig_depth = 0
	_ = sig_deliver_pending()
	sig_depth = depth
	sig_call_deadline = kept
}

sig_raise_self :: proc "contextless" (sig: int) {
	pending_add(sig)
	sender_of[sig] = posix_pid()
}

// The note handler: a note from another process, or a fault.
@(private="file")
sig_note :: proc "contextless" (e: ^vx.Exception, text: string) -> rt.Noted {
	if e.kind == .Interrupt {
		s, sender, ok := signal.note_signal(text)
		sig := int(s)
		if !ok || sig < 1 || sig > SIG_MAX {
			return .Dflt // no signal: the note ends the process
		}
		pending_add(sig)
		sender_of[sig] = sender
		if sig_depth == 0 {
			_ = sig_deliver_pending() // in the program's own code
		} else if sig not_in sig_mask {
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
	case .Illegal, .Fp_Disabled:
		sig, code = linux.SIGILL, linux.ILL_ILLOPC
	case .Arithmetic:
		sig, code = linux.SIGFPE, linux.FPE_INTDIV
	case .Breakpoint, .Step:
		sig, code = linux.SIGTRAP, linux.TRAP_BRKPT
	case .General:
		code = linux.SI_KERNEL
	}
	// A fault that is blocked or ignored would only happen again: its default.
	if sig in sig_mask || actions[sig].handler == linux.SIG_IGN {
		sig_terminate(sig, e, text)
	}
	_ = sig_act(sig, code, 0, e.address, e, text) // then the instruction again, unless the handler jumped away
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
			sig_mask = transmute(linux.Sig_Set)mask - UNBLOCKABLE
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
	was := sig_mask
	if set != nil {
		s := sigset_word(set)
		switch how {
		case linux.SIG_BLOCK:
			sig_mask += s
		case linux.SIG_UNBLOCK:
			sig_mask -= s
		case linux.SIG_SETMASK:
			sig_mask = s
		case:
			return fail(.EINVAL)
		}
		sig_mask -= UNBLOCKABLE
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
	was := sig_mask
	sig_mask = mask - UNBLOCKABLE
	ran := sig_handlers_ran
	for {
		seq := intrinsics.atomic_load(&sig_seq) // before the check: a signal after it changes sig_seq
		if pending_load() - sig_mask != {} {
			_ = sig_deliver_pending()
			if sig_handlers_ran != ran {
				break
			}
			continue
		}
		_ = rt.futex_wait(&sig_seq, seq, vx.INFINITE) // an interrupt, or sig_note, ends it
	}
	sig_mask = was
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
	ndb.put_u64(w, "mask", transmute(u64)(ctx.has_mask ? ctx.sig_mask : sig_mask))
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
