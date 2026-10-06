// musl's VectraOS back end (ADR-0007, upstream docs/01 §9), linked into
// libc.a as one object.
//
// musl asks for kernel services by Linux system-call number, through
// __vx_syscall (arch/generic/syscall_arch.h). This package answers each one
// with VectraOS's own calls and servers: files through the process's
// namespace (vx:ns, over 9Px rings), standard input and output through the
// console or the pipes a spawn message names, memory through VMOs, processes
// through /proc, signals through notes, sockets through /net. The file
// descriptor table lives here, in the process (as Fuchsia's fdio). What
// VectraOS does not do yet answers ENOSYS, and is reported to the kernel log
// once per number.
//
// Numbers, structures and results are Linux's, as musl's headers give them
// (the linux package): that is the POSIX personality, and it stays inside
// the C library. Every procedure answering a call returns what Linux's
// would: a count or value, or a negated errno.
//
// It shares a link with C: every procedure is "contextless" or "c", with no
// Odin runtime, allocator or init, and one thread-local record, in musl's
// TLS (threads.odin); build makes every symbol local but __vx_syscall,
// __vx_start, posix_spawn, __clone, __unmapself and the cancellation
// point's (arch/*/syscall_cp.S). musl's thread pointer is musl's.
package backend

import "base:intrinsics"
import vx "abi:vx"
import "linux"
import "vx:rt"
import "vx:str"

Errno :: linux.Errno

fail :: #force_inline proc "contextless" (e: Errno) -> int {
	return -int(e)
}

// A vx.Status as a negated errno (0 for .Ok). Statuses from 9P servers
// arrive already mapped from their error texts (vx:p9).
errno_of :: proc "contextless" (st: vx.Status) -> int {
	#partial switch st {
	case .Ok:
		return 0
	case .Err_Bad_Handle:
		return fail(.EBADF)
	case .Err_Access:
		return fail(.EACCES)
	case .Err_Invalid:
		return fail(.EINVAL)
	case .Err_Range, .Err_Too_Small:
		return fail(.ERANGE)
	case .Err_No_Memory:
		return fail(.ENOMEM)
	case .Err_Should_Wait:
		return fail(.EAGAIN)
	case .Err_Timed_Out:
		return fail(.ETIMEDOUT)
	case .Err_Peer_Closed:
		return fail(.EPIPE)
	case .Err_Refused:
		return fail(.EPERM)
	case .Err_Unsupported:
		return fail(.EOPNOTSUPP)
	case .Err_Killed, .Err_Interrupted:
		return fail(.EINTR)
	case .Err_No_Child:
		return fail(.ECHILD)
	case .Err_Io:
		return fail(.EIO)
	case .Err_No_Space:
		return fail(.ENOSPC)
	case .Err_Not_Found:
		return fail(.ENOENT)
	case .Err_Exists:
		return fail(.EEXIST)
	}
	return fail(.EIO)
}

// The calls VectraOS does not do yet: ENOSYS, and one line in the kernel
// log the first time each is asked for, so a port that needs one says so.
@(private="file")
told: [8]bit_set[0 ..< 64;u64] // 512 numbers

@(private="file")
unimplemented :: proc "contextless" (n: int) -> int {
	if n >= 0 && n < 512 && n % 64 not_in told[n / 64] {
		told[n / 64] += {n % 64}
		line: [64]u8
		b := str.Buf {
			buf = line[:],
		}
		str.write_string(&b, "vx-musl: system call ")
		str.write_u64(&b, u64(n))
		str.write_string(&b, " is not implemented\n")
		_ = rt.debug_write(str.to_string(&b))
	}
	return fail(.ENOSYS)
}

// Arguments as what they are.
@(private="file")
ptr :: #force_inline proc "contextless" (a: int) -> rawptr {
	return rawptr(uintptr(a))
}

@(private="file")
cs :: #force_inline proc "contextless" (a: int) -> string {
	return cstr(cstring(ptr(a)))
}

@(private="file")
bytes :: #force_inline proc "contextless" (a, n: int) -> []u8 {
	return ([^]u8)(ptr(a))[:max(n, 0)]
}

@(private="file")
oflags :: #force_inline proc "contextless" (a: int) -> linux.Open_Flags {
	return transmute(linux.Open_Flags)i32(a)
}

@(private="file")
mflags :: #force_inline proc "contextless" (a: int) -> linux.Msg_Flags {
	return transmute(linux.Msg_Flags)i32(a)
}

@(private="file")
pollfds :: #force_inline proc "contextless" (a, n: int) -> []linux.Pollfd {
	return ([^]linux.Pollfd)(ptr(a))[:max(n, 0)]
}

@(private="file")
dispatch :: proc "contextless" (n, a1, a2, a3, a4, a5, a6: int) -> int {
	when ODIN_ARCH == .amd64 {
		if r, ok := dispatch_amd64(n, a1, a2, a3, a4, a5, a6); ok {
			return r
		}
	}
	#partial switch linux.Sys(n) {
	// Files and descriptors
	case .read:
		return fd_read(a1, bytes(a2, a3))
	case .write:
		return fd_write(a1, bytes(a2, a3))
	case .readv:
		return fd_readv(a1, ([^]linux.Iovec)(ptr(a2)), a3)
	case .writev:
		return fd_writev(a1, ([^]linux.Iovec)(ptr(a2)), a3)
	case .pread64:
		return fd_pread(a1, bytes(a2, a3), i64(a4))
	case .pwrite64:
		return fd_pwrite(a1, bytes(a2, a3), i64(a4))
	case .preadv2:
		return fd_prw2(a1, ([^]linux.Iovec)(ptr(a2)), a3, i64(a4), int(i32(a6)), false)
	case .pwritev2:
		return fd_prw2(a1, ([^]linux.Iovec)(ptr(a2)), a3, i64(a4), int(i32(a6)), true)
	case .lseek:
		return fd_lseek(a1, i64(a2), a3)
	case .close:
		return fd_close(int(i32(a1)))
	case .openat:
		return fd_openat(int(i32(a1)), cs(a2), oflags(a3), u32(a4))
	case .fstat:
		return fd_fstat(int(i32(a1)), (^linux.Stat)(ptr(a2)))
	case .newfstatat:
		return fd_fstatat(int(i32(a1)), cs(a2), (^linux.Stat)(ptr(a3)), a4)
	case .getdents64:
		return fd_getdents(int(i32(a1)), bytes(a2, a3))
	case .ioctl:
		return fd_ioctl(int(i32(a1)), uint(u32(a2)), ptr(a3))
	case .fcntl:
		return fd_fcntl(int(i32(a1)), int(i32(a2)), a3)
	case .dup:
		return fd_dup(int(i32(a1)), -1, {})
	case .dup3: // a target that cannot be one is EBADF, not dup's lowest free
		if i32(a2) < 0 {
			return fail(.EBADF)
		}
		return a1 == a2 ? fail(.EINVAL) : fd_dup(int(i32(a1)), int(i32(a2)), oflags(a3))
	case .faccessat:
		return fd_faccessat(int(i32(a1)), cs(a2))
	case .mkdirat:
		return fd_mkdirat(int(i32(a1)), cs(a2), u32(a3))
	case .unlinkat:
		return fd_unlinkat(int(i32(a1)), cs(a2), a3)
	case .getcwd:
		return fd_getcwd(bytes(a1, a2))
	case .chdir:
		return fd_chdir(cs(a1))
	case .readlinkat:
		return fd_readlinkat(int(i32(a1)), cs(a2), bytes(a3, a4))
	case .renameat:
		return fd_renameat(int(i32(a1)), cs(a2), int(i32(a3)), cs(a4), 0)
	case .renameat2:
		return fd_renameat(int(i32(a1)), cs(a2), int(i32(a3)), cs(a4), uint(u32(a5)))
	case .symlinkat:
		return fd_symlinkat(cs(a1), int(i32(a2)), cs(a3))
	case .linkat:
		return fail(.EPERM) // no server has hard links
	case .fchmod:
		return fd_chmod(int(i32(a1)), linux.AT_FDCWD, "", false, u32(a2))
	case .fchmodat:
		return fd_chmod(-1, int(i32(a1)), cs(a2), true, u32(a3))
	case .fchown:
		return fd_chown(int(i32(a1)), linux.AT_FDCWD, "", false, u32(a2), u32(a3), true)
	case .fchownat:
		return fd_chown(-1, int(i32(a1)), cs(a2), true, u32(a3), u32(a4), a5 & linux.AT_SYMLINK_NOFOLLOW == 0)
	case .truncate:
		return fd_truncate(-1, cs(a1), true, i64(a2))
	case .ftruncate:
		return fd_truncate(int(i32(a1)), "", false, i64(a2))
	case .utimensat:
		return fd_utimens(int(i32(a1)), cs(a2), a2 != 0, (^[2]linux.Timespec)(ptr(a3)), a4)
	case .fsync, .fdatasync:
		return fd_fsync(int(i32(a1)))
	case .umask:
		return 0o022

	// Memory
	case .mmap:
		return mem_map(uintptr(a1), uint(a2), transmute(linux.Prot_Flags)i32(a3), int(i32(a4)), int(i32(a5)), i64(a6))
	case .munmap:
		return mem_unmap(uintptr(a1), uint(a2))
	case .mremap:
		return mem_remap(uintptr(a1), uint(a2), uint(a3), int(i32(a4)))
	case .mprotect:
		return mem_protect()
	// Mapped files' writes reach fsd's page cache at once, and the volume
	// within 10 s or at the file's next fsync: msync has nothing to start,
	// and MS_SYNC does not yet wait (upstream's docs/milestones.md).
	case .msync,
	     .madvise, // advice
	     .brk: // no break: musl's malloc maps instead
		return 0

	// The process
	case .exit: // the thread; the process, if it was the last
		be_thread_exit(a1)
	case .exit_group:
		proc_exit(a1)
	case .getpid:
		return int(posix_pid())
	case .gettid:
		return be_gettid()
	case .set_tid_address: // musl's last step setting up the first thread (its TLS is there now), and _Fork's
		return be_set_tid_address((^u32)(ptr(a1)))
	case .getppid:
		return posix_getppid()
	case .getpgid:
		return posix_getpgid(i64(a1))
	case .getsid:
		return posix_getsid(i64(a1))
	case .setpgid:
		return posix_setpgid(i64(a1), i64(a2))
	case .setsid:
		return posix_setsid()
	case .wait4:
		return posix_wait4(i64(i32(a1)), (^i32)(ptr(a2)), transmute(linux.Wait_Options)i32(a3), (^linux.Rusage)(ptr(a4)))
	case .execve:
		return proc_execve(cstring(ptr(a1)), ([^]cstring)(ptr(a2)), ([^]cstring)(ptr(a3)))
	case .clone: // musl's _Fork and vfork, where there is no SYS_fork; threads come through __clone
		return a1 == linux.SIGCHLD && a2 == 0 ? proc_fork() : fail(.ENOSYS)
	case .pipe2:
		return fd_pipe2((^[2]i32)(ptr(a1)), oflags(a2))
	case .getuid, .geteuid, .getgid, .getegid:
		return 0
	case .uname:
		return proc_uname((^linux.Utsname)(ptr(a1)))
	case .getrandom:
		return proc_getrandom(bytes(a1, a2))

	// Signals
	case .tkill:
		return be_thread_kill(i64(i32(a1)), int(i32(a2)))
	case .tgkill:
		return i64(i32(a1)) == posix_pid() ? be_thread_kill(i64(i32(a2)), int(i32(a3))) : fail(.ESRCH)
	case .kill:
		return sig_kill(i64(i32(a1)), int(i32(a2)))
	case .rt_sigaction:
		return sig_action(int(i32(a1)), (^linux.K_Sigaction)(ptr(a2)), (^linux.K_Sigaction)(ptr(a3)))
	case .rt_sigprocmask:
		return sig_procmask(int(i32(a1)), ptr(a2), (^linux.Sig_Set)(ptr(a3)))
	case .rt_sigpending:
		intrinsics.unaligned_store((^linux.Sig_Set)(ptr(a1)), pending_load())
		return 0
	case .rt_sigsuspend:
		return sig_suspend(sigset_word(ptr(a1)))
	case .sigaltstack: // accepted, and not used: handlers run on the thread's stack
		if a2 != 0 {
			(^linux.Stack)(ptr(a2))^ = {
				flags = linux.SS_DISABLE,
			}
		}
		return 0
	case .prlimit64:
		return proc_prlimit((^linux.Rlimit)(ptr(a4)))

	// Time and waiting
	case .clock_gettime:
		return time_get(int(i32(a1)), (^linux.Timespec)(ptr(a2)))
	case .clock_getres:
		return time_res((^linux.Timespec)(ptr(a2)))
	case .nanosleep:
		return time_sleep(1, 0, (^linux.Timespec)(ptr(a1)), (^linux.Timespec)(ptr(a2))) // CLOCK_MONOTONIC
	case .clock_nanosleep:
		return time_sleep(int(i32(a1)), int(i32(a2)), (^linux.Timespec)(ptr(a3)), (^linux.Timespec)(ptr(a4)))
	case .ppoll: // and pause(), where there is no SYS_pause
		if a1 == 0 && a2 == 0 && a3 == 0 {
			return sig_suspend(a4 != 0 ? sigset_word(ptr(a4)) : be_me().mask)
		}
		return poll_masked(pollfds(a1, a2), (^linux.Timespec)(ptr(a3)), ptr(a4))
	case .pselect6:
		data := (^[2]uintptr)(ptr(a6)) // {sigset, size}, as musl passes it
		mask := data != nil ? rawptr(data[0]) : nil
		return sys_select(int(i32(a1)), (^linux.Fd_Set)(ptr(a2)), (^linux.Fd_Set)(ptr(a3)), (^linux.Fd_Set)(ptr(a4)), (^linux.Timespec)(ptr(a5)), mask)

	// Sockets
	case .socket:
		return sock_socket(int(i32(a1)), int(i32(a2)), int(i32(a3)))
	case .bind:
		return sock_bind(int(i32(a1)), ptr(a2), u32(a3))
	case .listen:
		return sock_listen(int(i32(a1)))
	case .accept:
		return sock_accept(int(i32(a1)), ptr(a2), (^u32)(ptr(a3)), 0)
	case .accept4:
		return sock_accept(int(i32(a1)), ptr(a2), (^u32)(ptr(a3)), int(i32(a4)))
	case .connect:
		return sock_connect(int(i32(a1)), ptr(a2), u32(a3))
	case .getsockname:
		return sock_name(int(i32(a1)), ptr(a2), (^u32)(ptr(a3)), false)
	case .getpeername:
		return sock_name(int(i32(a1)), ptr(a2), (^u32)(ptr(a3)), true)
	case .sendto:
		return sock_sendto(int(i32(a1)), bytes(a2, a3), mflags(a4), ptr(a5), u32(a6))
	case .recvfrom:
		return sock_recvfrom(int(i32(a1)), bytes(a2, a3), mflags(a4), ptr(a5), (^u32)(ptr(a6)))
	case .sendmsg:
		return sock_sendmsg(int(i32(a1)), (^linux.Msghdr)(ptr(a2)), mflags(a3))
	case .recvmsg:
		return sock_recvmsg(int(i32(a1)), (^linux.Msghdr)(ptr(a2)), mflags(a3))
	case .shutdown:
		return sock_shutdown(int(i32(a1)), int(i32(a2)))
	case .setsockopt:
		return sock_setsockopt(int(i32(a1)), int(i32(a2)), int(i32(a3)), ptr(a4), u32(a5))
	case .getsockopt:
		return sock_getsockopt(int(i32(a1)), int(i32(a2)), int(i32(a3)), ptr(a4), (^u32)(ptr(a5)))
	case .socketpair:
		return fail(.EAFNOSUPPORT) // AF_UNIX: not yet

	case .sched_yield:
		return 0
	case .futex:
		return time_futex((^u32)(ptr(a1)), int(i32(a2)), u32(a3), (^linux.Timespec)(ptr(a4)))
	}
	return unimplemented(n)
}

// Whether a call waits for descriptors (poll, select: a handler that runs
// ends them with EINTR), or only for a signal (sigsuspend, pause).
@(private="file")
call_kind :: proc "contextless" (n, a1, a2: int) -> (waits, pauses: bool) {
	#partial switch linux.Sys(n) {
	case .ppoll:
		return true, a1 == 0 && a2 == 0
	case .pselect6:
		return true, false
	case .rt_sigsuspend:
		return false, true
	}
	when ODIN_ARCH == .amd64 {
		#partial switch linux.Sys(n) {
		case .poll, .select:
			return true, false
		case .pause:
			return false, true
		}
	}
	return false, false
}

// Every call musl makes. A signal that arrives during one is delivered as it
// returns (signal.odin). A call that a signal interrupted is made again
// unless a handler that wants EINTR ran: SA_RESTART, an ignored signal, and
// a blocked one (the kernel ends a wait for any note) do not end it. poll
// and select end with EINTR once any handler has run, as Linux's do;
// sigsuspend and pause always do. Each time, a sleep's or poll's deadline is
// the first's. The call holds the back end's lock (threads.odin) throughout,
// but where it waits; SYS_exit ends the thread holding nothing.
@(export, link_name="__vx_syscall")
vx_syscall :: proc "c" (n, a1, a2, a3, a4, a5, a6: int) -> int {
	if linux.Sys(n) == .exit {
		be_thread_exit(a1) // never returns: holds nothing
	}
	be_enter()
	defer be_leave()
	waits, pauses := call_kind(n, a1, a2)
	// The depth stays up until the call is done, made again or not: a signal
	// that comes between is pending, not run before the choice is made.
	ran, cut := sig_handlers_ran, sig_eintr_ran
	outer := be_me().sig_depth == 0
	be_me().sig_depth += 1
	r := dispatch(n, a1, a2, a3, a4, a5, a6)
	for outer {
		sig_run_pending()
		eintr := sig_eintr_ran != cut || (waits && sig_handlers_ran != ran)
		if r != fail(.EINTR) || eintr || pauses {
			break
		}
		be_me().restarting = true
		r = dispatch(n, a1, a2, a3, a4, a5, a6)
		be_me().restarting = false
	}
	be_me().sig_depth -= 1
	if outer {
		sig_run_pending() // one that came after the choice: on the way out
	}
	return r
}
