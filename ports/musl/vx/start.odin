package backend

import "base:intrinsics"
import vx "abi:vx"
import "linux"
import "vx:drbg"
import "vx:memory"
import "vx:ndb"
import "vx:note"
import "vx:rt"

// The process: its start from the spawn message, its exit, what it is, and
// time.

foreign _ {
	// musl's: builds the C library's state from argc, argv, the environment
	// and the auxiliary vector after them, then calls main, and exits with
	// what it returns.
	__libc_start_main :: proc "c" (main: rawptr, argc: i32, argv: [^]uintptr, init, fini, ldso: rawptr) -> i32 ---
	// arch/*/crt1.S: the program's ELF header, which lld places at the start
	// of the first loaded segment; musl finds the TLS segment through
	// AT_PHDR.
	__vx_ehdr :: proc "c" () -> ^Elf_Header ---
}

Elf_Header :: struct {
	ident:                                                [16]u8,
	type, machine:                                        u16,
	version:                                              u32,
	entry, phoff, shoff:                                  u64,
	flags:                                                u32,
	ehsize, phentsize, phnum, shentsize, shnum, shstrndx: u16,
}
#assert(size_of(Elf_Header) == 64)
ELF_PHDR_SIZE :: 56

// The kernel's id for the task: the pid (ADR-0012: exec keeps it).
task_id: u64

// What Linux puts on a new process's stack, built here instead: argc, the
// arguments, the environment and the auxiliary vector, one array as musl
// reads it, and the strings they point to.
@(private="file")
AUX_PAIRS :: 12

@(private="file")
proc_start: struct {
	words:   [1 + rt.SPAWN_MAX_ARGS + 2 + rt.SPAWN_MAX_ARGS + 1 + 2 * AUX_PAIRS]uintptr,
	strings: [vx.CHANNEL_MAX_BYTES + 2 * rt.SPAWN_MAX_ARGS + 64]u8,
	random:  [16]u8,
}

// A NUL-terminated copy of s in proc_start.strings, from used on.
@(private="file")
start_string :: proc "contextless" (used: ^int, s: string) -> uintptr {
	at := used^
	n := copy(proc_start.strings[at:], s)
	proc_start.strings[at + n] = 0
	used^ += n + 1
	return uintptr(&proc_start.strings[at])
}

// The process's random generator (vx:drbg), seeded with the entropy= its
// parent gave it (svcd, or a POSIX parent: spawn_records). It makes
// AT_RANDOM, which seeds musl's stack protector and malloc, answers
// getrandom, and seeds each child. A process given no seed has an unseeded
// generator: AT_RANDOM then comes from the clock and its layout, not secret,
// and getrandom fails (EAGAIN) rather than pretend.
entropy: drbg.Drbg

@(private="file")
proc_random :: proc "contextless" () {
	rec: ndb.Record
	if rt.spawn_record("entropy", &rec) {
		if seed, ok := ndb.get(&rec, "entropy"); ok && len(seed) >= 16 {
			drbg.mix(&entropy, transmute([]u8)seed, true)
		}
	}
	fallback := [2]u64{u64(rt.clock_read()), u64(uintptr(&proc_start)) ~ task_id << 32}
	if !entropy.seeded {
		drbg.mix(&entropy, memory.ptr_to_bytes(&fallback), false)
	}
	drbg.read(&entropy, proc_start.random[:])
}

proc_getrandom :: proc "contextless" (buf: []u8) -> int {
	if !entropy.seeded {
		return fail(.EAGAIN)
	}
	b := buf[:min(len(buf), 1 << 20)]
	drbg.read(&entropy, b)
	return len(b)
}

@(private="file")
push :: proc "contextless" (n: ^int, v: uintptr) {
	proc_start.words[n^] = v
	n^ += 1
}

// Called by crt1's _start with the bootstrap channel and the program's main.
// argv[0] is argv0= from a POSIX parent, or else the program's name from the
// spawn message; its arguments follow.
@(export, link_name="__vx_start")
vx_start :: proc "c" (bootstrap: vx.Handle, main: rawptr) -> ! {
	rt.read_spawn(bootstrap)
	fd_init()
	if rt.self != vx.HANDLE_NONE {
		if me, st := rt.task_info(rt.self); st == .Ok {
			task_id = me.id
		}
	}
	posix_init()
	sig_init()
	proc_random()

	used, n := 0, 0
	argc := 1 + len(rt.spawn.args)
	push(&n, uintptr(argc))
	argv0 := rt.spawn.has_argv0 ? rt.spawn.argv0 : rt.spawn.name
	name := start_string(&used, len(argv0) > 0 ? argv0 : "a.out")
	push(&n, name)
	for a in rt.spawn.args {
		push(&n, start_string(&used, a))
	}
	push(&n, 0)
	for e in rt.spawn.envs {
		push(&n, start_string(&used, e))
	}
	push(&n, 0)
	eh := __vx_ehdr()
	aux := [AUX_PAIRS * 2]uintptr {
		linux.AT_PHDR, uintptr(eh) + uintptr(eh.phoff),
		linux.AT_PHENT, ELF_PHDR_SIZE,
		linux.AT_PHNUM, uintptr(eh.phnum),
		linux.AT_PAGESZ, memory.PAGE_SIZE,
		linux.AT_RANDOM, uintptr(&proc_start.random),
		linux.AT_EXECFN, name,
		linux.AT_NULL, 0,
		0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
	}
	copy(proc_start.words[n:], aux[:])
	_ = __libc_start_main(main, i32(argc), ([^]uintptr)(&proc_start.words[1]), nil, nil, nil)
	intrinsics.trap() // it ends in exit, never returning
}

// Ends the process with msg as its exit string (ADR-0010). The back end's
// buffers go out first, and stdout's pipe closes so its reader sees the end
// of the file.
proc_exit_str :: proc "contextless" (msg: string) -> ! {
	fd_exit()
	_ = rt.task_kill(rt.self, msg)
	rt.thread_exit()
}

// exit and exit_group (musl has flushed its own buffers): as APE does, exit
// code 0 is the empty exit string, and any other is its number in decimal.
// The code is the status's low byte, all a parent's wait can see.
proc_exit :: proc "contextless" (status: int) -> ! {
	code: [4]u8
	b := note.Buf {
		buf = code[:],
	}
	if status & 0xff != 0 {
		note.put_dec(&b, u64(status & 0xff))
	}
	proc_exit_str(note.to_string(&b))
}

@(private="file")
put_field :: proc "contextless" (field: ^[65]u8, s: string) {
	copy(field[:], s)
}

proc_uname :: proc "contextless" (u: ^linux.Utsname) -> int {
	u^ = {}
	put_field(&u.sysname, "VectraOS")
	put_field(&u.nodename, "vectra")
	put_field(&u.release, "0.1.0")
	put_field(&u.version, "M4")
	put_field(&u.machine, linux.MACHINE)
	return 0
}

// getrlimit and prlimit: no limits are set.
proc_prlimit :: proc "contextless" (old: ^linux.Rlimit) -> int {
	if old != nil {
		old^ = {linux.RLIM_INFINITY, linux.RLIM_INFINITY}
	}
	return 0
}

// x86_64's FS base (SYS_set_thread_area); aarch64's musl writes TPIDR_EL0
// itself.
proc_set_tls :: proc "contextless" (p: u64) -> int {
	return errno_of(rt.tls_set(p))
}

// --- Time ---
//
// Every clock is the kernel's monotonic one, in nanoseconds since boot; the
// realtime clocks add the kernel's UTC offset (upstream ADR-0031), which is
// 0 until a clock driver has set it (no RTC: 1970, as before). The CPU-time
// clocks are the monotonic clock too.

NS_PER_SEC :: 1_000_000_000

@(private="file")
time_is_utc :: proc "contextless" (clock: int) -> bool {
	switch clock {
	case linux.CLOCK_REALTIME, linux.CLOCK_REALTIME_COARSE, linux.CLOCK_REALTIME_ALARM, linux.CLOCK_TAI:
		return true
	}
	return false
}

time_get :: proc "contextless" (clock: int, ts: ^linux.Timespec) -> int {
	if clock < 0 || clock > linux.CLOCK_TAI {
		return fail(.EINVAL)
	}
	now := max(time_is_utc(clock) ? rt.clock_utc() : rt.clock_read(), 0)
	ts^ = {now / NS_PER_SEC, now % NS_PER_SEC}
	return 0
}

time_res :: proc "contextless" (ts: ^linux.Timespec) -> int {
	if ts != nil {
		ts^ = {0, 1}
	}
	return 0
}

// A timespec as a deadline: from now, unless absolute; too far to wait for
// is INFINITE. -EINVAL for a time that is not one.
time_deadline :: proc "contextless" (ts: ^linux.Timespec, absolute: bool) -> (vx.Instant, int) {
	if ts.sec < 0 || ts.nsec < 0 || ts.nsec >= NS_PER_SEC {
		return 0, fail(.EINVAL)
	}
	m, o1 := intrinsics.overflow_mul(ts.sec, i64(NS_PER_SEC))
	d, o2 := intrinsics.overflow_add(m, ts.nsec)
	o3 := false
	if !absolute {
		d, o3 = intrinsics.overflow_add(d, rt.clock_read())
	}
	return o1 || o2 || o3 ? vx.INFINITE : d, 0
}

// A sleep ends early with EINTR when a signal interrupts it, with what was
// left in rem; made again after the signal (signal.odin), it keeps its
// deadline.
time_sleep :: proc "contextless" (clock: int, flags: int, req: ^linux.Timespec, rem: ^linux.Timespec) -> int {
	if clock < 0 || clock > linux.CLOCK_TAI {
		return fail(.EINVAL)
	}
	absolute := flags & linux.TIMER_ABSTIME != 0
	if !be_me().restarting {
		d, e := time_deadline(req, absolute)
		if e < 0 {
			return e
		}
		if absolute && time_is_utc(clock) && d != vx.INFINITE {
			d -= rt.clock_utc() - i64(rt.clock_read()) // a time of day: on the monotonic clock
		}
		be_me().call_deadline = d
	}
	for rt.clock_read() < be_me().call_deadline {
		seq := intrinsics.atomic_load(&sig_seq)
		held := be_wait_begin()
		st := rt.futex_wait(&sig_seq, seq, be_me().call_deadline)
		be_wait_end(held)
		if st != .Err_Interrupted && st != .Err_Bad_State {
			continue // the deadline, or nothing
		}
		left := max(be_me().call_deadline - rt.clock_read(), 0)
		if rem != nil && !absolute {
			rem^ = {left / NS_PER_SEC, left % NS_PER_SEC}
		}
		return fail(.EINTR)
	}
	return 0
}

time_futex :: proc "contextless" (word: ^u32, op: int, value: u32, timeout: ^linux.Timespec) -> int {
	switch op & linux.FUTEX_CMD_MASK {
	case linux.FUTEX_WAIT:
		deadline := vx.INFINITE
		if timeout != nil {
			e: int
			deadline, e = time_deadline(timeout, false)
			if e < 0 {
				return e
			}
		}
		held := be_wait_begin() // a pthread mutex's or condition's: its waker is another thread
		st := rt.futex_wait(word, value, deadline)
		be_wait_end(held)
		return st == .Err_Bad_State ? fail(.EAGAIN) : errno_of(st) // the word had changed
	case linux.FUTEX_WAKE:
		n, st := rt.futex_wake(word, value)
		return st == .Ok ? n : errno_of(st)
	}
	return fail(.ENOSYS)
}
