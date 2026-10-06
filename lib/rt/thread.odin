package rt

import "base:intrinsics"
import "base:runtime"
import vx "abi:vx"
import "vx:memory"

// The thread pointer (x86_64's FS base, aarch64's TPIDR_EL0), which the
// kernel keeps per thread (a C library's TLS), and FP/SIMD probes. The
// assembly is arch/*/thread.S.
foreign _ {
	vx_thread_word :: proc "c" () -> u64 ---
	vx_fp_probe_put :: proc "c" (v: u64, ctl: u32) ---
	vx_fp_probe_get :: proc "c" (ctl: ^u32) -> u64 ---
	vx_cycles :: proc "c" () -> u64 ---
	vx_thread_finish :: proc "c" (word: ^u32, wake, exit: u64) -> ! ---
	@(link_name = "__ehdr_start")
	ehdr_start :: proc "c" () --- // the program's own ELF header, mapped with its first segment (lld): an address only
}

// The cycle counter, read in user mode: no syscall (clock_info says its rate).
cycles :: proc "contextless" () -> u64 {
	return vx_cycles()
}

// The calling thread's thread pointer.
@(require_results)
tls_get :: proc "contextless" () -> (u64, vx.Status) {
	v: u64
	st := thread_state(self, 0, .Get_Tls, &v)
	return v, st
}

// Sets the calling thread's thread pointer: a user address.
@(require_results)
tls_set :: proc "contextless" (value: u64) -> vx.Status {
	v := value
	return thread_state(self, 0, .Set_Tls, &v)
}

// The word the thread pointer points at, read through it as a C library
// does (%fs:0 on x86_64). The thread pointer must be set.
thread_word :: proc "contextless" () -> u64 {
	return vx_thread_word()
}

// A vector register (all of ymm7, with lanes of its own beside v; v7) and the
// FP control register (MXCSR, FPCR), put and read back: how ktest checks that
// the kernel keeps each thread's FP/SIMD state across its sleeps and
// switches. On x86_64 a get of a register whose lanes do not agree returns
// 0xbad0bad0bad0bad0 (thread.S).
fp_probe_put :: proc "contextless" (v: u64, ctl: u32) {
	vx_fp_probe_put(v, ctl)
}

fp_probe_get :: proc "contextless" () -> (v: u64, ctl: u32) {
	v = vx_fp_probe_get(&ctl)
	return
}

// --- A lock between a task's threads (upstream's M6 step 6d1) ---

// A futex word: 0 free, 1 held, 2 held with waiters (Drepper's "Futexes are
// tricky", mutex 3). Not recursive. The zero value is unlocked.
Mutex :: struct {
	state: u32,
}

mutex_lock :: proc "contextless" (m: ^Mutex) {
	_ = mutex_lock_until(m, vx.INFINITE)
}

mutex_unlock :: proc "contextless" (m: ^Mutex) {
	if intrinsics.atomic_sub(&m.state, 1) != 1 {
		intrinsics.atomic_store(&m.state, 0)
		_, _ = futex_wake(&m.state, 1)
	}
}

// The same as mutex_lock, giving up at deadline: false if it is still held
// then.
@(require_results)
mutex_lock_until :: proc "contextless" (m: ^Mutex, deadline: vx.Instant) -> bool {
	c, ok := intrinsics.atomic_compare_exchange_strong(&m.state, 0, 1)
	if ok {
		return true
	}
	if c != 2 {
		c = intrinsics.atomic_exchange(&m.state, 2)
	}
	for c != 0 {
		if futex_wait(&m.state, 2, deadline) == .Err_Timed_Out {
			return false
		}
		c = intrinsics.atomic_exchange(&m.state, 2)
	}
	return true
}

// --- Threads (upstream's M6 step 6d1) ---
//
// A native program's threads, each with its own stack and its own copy of
// the program's thread-local storage (Odin's @(thread_local)), as the ELF ABI
// lays it out, and its stack's bounds known.
//
// The TLS image is the program's PT_TLS segment, found through __ehdr_start:
// filesz bytes copied, the rest of memsz zeroed, at its alignment. The
// thread pointer (x86_64's FS base, aarch64's TPIDR_EL0) points at it as each
// ABI has it, and as ld.lld resolves the program's TLS offsets (Odin's
// @(thread_local) is the initial-exec model in a static executable, which
// lld turns into local-exec):
//   - x86_64, variant II: the block ends at the thread pointer, rounded to
//     its alignment, and the word there points to itself (%fs:0, which the
//     compiler reads for the thread pointer). vx:rt's record of the thread
//     (Tcb) begins there, that word first.
//   - aarch64, variant I: two words at the thread pointer, then the block, at
//     its alignment past them. The first of the two points to the Tcb, which
//     sits just below.
// A thread's stack, TLS and record are one VMO, mapped with the unmapped page
// as_map leaves below each mapping as its guard. thread_join waits on a word
// the thread clears as it ends, then unmaps it all; the thread's last steps
// after that word use registers alone (vx_thread_finish, arch/*/thread.S),
// so the unmapping cannot pull its stack from under it.
//
// The threads share a program's 9P connections, with several calls in
// flight on each (p9conn.odin, upstream's 6d4a).

// What a thread runs, with a default context, as vx_main has.
Thread_Proc :: #type proc(arg: rawptr)

// vx:rt's record of a thread.
@(private)
Tcb :: struct {
	self:               ^Tcb, // x86_64: %fs:0, the thread pointer itself
	fn:                 Thread_Proc,
	arg:                rawptr,
	stack_lo, stack_hi: u64,
	running:            u32, // 1 until fn returns: thread_join waits on it
}

// A thread thread_spawn made, for thread_join. The zero value is none.
Thread :: struct {
	handle:     vx.Handle,
	base, size: u64, // its mapping
	tcb:        ^Tcb,
}

@(private="file")
tls_image: struct {
	init:                 [^]u8,
	filesz, memsz, align: u64,
}

@(private="file")
round_up :: proc "contextless" (v, a: u64) -> u64 {
	return (v + a - 1) & ~(a - 1)
}

@(private="file")
tls_find :: proc "contextless" () {
	eh := (^Elf_Header)(rawptr(ehdr_start))
	// The program's own headers, as lld wrote them: no foreign input.
	phdrs := ([^]Elf_Phdr)(rawptr(uintptr(rawptr(ehdr_start)) + uintptr(eh.phoff)))[:eh.phnum]
	tls_image.align = 16
	for ph in phdrs {
		if ph.type != PT_TLS {
			continue
		}
		tls_image.init = ([^]u8)(uintptr(ph.vaddr))
		tls_image.filesz, tls_image.memsz = ph.filesz, ph.memsz
		tls_image.align = max(tls_image.align, ph.align)
	}
}

// The bytes a thread's TLS and record need, at most: alignment slack included.
@(private="file")
tls_extent :: proc "contextless" () -> u64 {
	a := tls_image.align
	return round_up(tls_image.memsz, a) + a + size_of(Tcb) + 16 + a
}

// Lays out a thread's TLS and record at mem, tls_extent() bytes of zeroed
// memory: the block initialised, the record placed. Returns the thread
// pointer.
@(private="file")
tls_layout :: proc "contextless" (mem: u64) -> (tp: u64, tcb: ^Tcb) {
	a := tls_image.align
	block: u64
	when ODIN_ARCH == .amd64 {
		size := round_up(tls_image.memsz, a)
		tp = round_up(mem + size, a)
		block = tp - size
		tcb = (^Tcb)(uintptr(tp))
		tcb.self = tcb
	} else {
		tp = round_up(mem + size_of(Tcb), max(a, 16))
		block = tp + round_up(16, a)
		tcb = (^Tcb)(uintptr(tp - size_of(Tcb)))
		tcb.self = tcb
		(^^Tcb)(uintptr(tp))^ = tcb
	}
	if n := tls_image.filesz; n != 0 {
		copy(([^]u8)(uintptr(block))[:n], tls_image.init[:n])
	}
	return
}

// The calling thread's record; nil on a thread vx:rt did not set up.
@(private="file")
tcb_get :: proc "contextless" () -> ^Tcb {
	tp, st := tls_get()
	if st != .Ok || tp == 0 {
		return nil
	}
	return (^^Tcb)(uintptr(tp))^
}

// The first thread's TLS and record, at start-up (start, before anything may
// use a @(thread_local)): a VMO of its own; its stack is the mapping its
// stack pointer is in.
@(private)
thread_main_init :: proc "contextless" () {
	tls_find()
	size := round_up(tls_extent(), memory.PAGE_SIZE)
	v, st := vmo_create(size)
	if st != .Ok {
		return
	}
	at: u64
	at, st = as_map(self, v, 0, size, {.Write})
	_ = handle_close(v)
	if st != .Ok {
		return
	}
	tp, tcb := tls_layout(at)
	here: u8
	sp := u64(uintptr(&here))
	if mi, qst := as_query(self, sp); qst == .Ok && mi.base <= sp {
		tcb.stack_lo, tcb.stack_hi = mi.base, mi.base + mi.size
	}
	intrinsics.atomic_store(&tcb.running, 1)
	_ = tls_set(tp)
}

@(private="file")
thread_entry :: proc "c" (unused: vx.Handle, tp: u64) -> ! {
	_ = tls_set(tp) // first: nothing before it may touch a @(thread_local)
	t := tcb_get()
	context = runtime.default_context()
	t.fn(t.arg)
	vx_thread_finish(&t.running, u64(vx.Syscall.Futex_Wake), u64(vx.Syscall.Thread_Exit))
}

// Starts fn(arg) on a new thread of the program's own task, with a stack of
// stack_size bytes (0: 256 KiB) and its own TLS; the Thread is for
// thread_join.
@(require_results)
thread_spawn :: proc "contextless" (fn: Thread_Proc, arg: rawptr, stack_size: u64 = 0) -> (Thread, vx.Status) {
	stack := round_up(stack_size != 0 ? stack_size : 256 * 1024, memory.PAGE_SIZE)
	size := stack + round_up(tls_extent(), memory.PAGE_SIZE)
	v, st := vmo_create(size)
	if st != .Ok {
		return {}, st
	}
	at: u64
	at, st = as_map(self, v, 0, size, {.Write})
	_ = handle_close(v)
	if st != .Ok {
		return {}, st
	}
	tp, tcb := tls_layout(at + stack)
	tcb.fn, tcb.arg, tcb.stack_lo, tcb.stack_hi = fn, arg, at, at + stack
	intrinsics.atomic_store(&tcb.running, 1)
	th: vx.Handle
	th, st = thread_create(self)
	if st == .Ok {
		st = thread_start(th, u64(uintptr(rawptr(thread_entry))), at + stack, vx.HANDLE_NONE, tp)
	}
	if st != .Ok {
		_ = handle_close(th)
		_ = as_unmap(self, at, size)
		return {}, st
	}
	return {handle = th, base = at, size = size, tcb = tcb}, .Ok
}

// Waits for t's function to return, then lets go of its stack and TLS.
thread_join :: proc "contextless" (t: ^Thread) {
	if t.tcb == nil {
		return
	}
	for intrinsics.atomic_load(&t.tcb.running) != 0 {
		_ = futex_wait(&t.tcb.running, 1, vx.INFINITE)
	}
	_ = handle_close(t.handle)
	_ = as_unmap(self, t.base, t.size)
	t^ = {}
}

// The calling thread's stack: [lo, hi). ok is false on a thread vx:rt did
// not set up.
thread_stack :: proc "contextless" () -> (lo, hi: u64, ok: bool) {
	t := tcb_get()
	if t == nil || t.stack_hi == 0 {
		return
	}
	return t.stack_lo, t.stack_hi, true
}
