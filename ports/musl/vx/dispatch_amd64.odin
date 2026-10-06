package backend

import "linux"

// x86_64's calls that aarch64 has only as their *at and p* forms, and its
// thread pointer (SYS_set_thread_area). ok is false for any other number.
dispatch_amd64 :: proc "contextless" (n, a1, a2, a3, a4, a5, a6: int) -> (r: int, ok: bool) {
	p :: #force_inline proc "contextless" (a: int) -> rawptr {
		return rawptr(uintptr(a))
	}
	s :: #force_inline proc "contextless" (a: int) -> string {
		return cstr(cstring(rawptr(uintptr(a))))
	}
	#partial switch linux.Sys_Amd64(n) {
	case .open:
		return fd_openat(linux.AT_FDCWD, s(a1), transmute(linux.Open_Flags)i32(a2), u32(a3)), true
	case .stat:
		return fd_fstatat(linux.AT_FDCWD, s(a1), (^linux.Stat)(p(a2)), 0), true
	case .lstat:
		return fd_fstatat(linux.AT_FDCWD, s(a1), (^linux.Stat)(p(a2)), linux.AT_SYMLINK_NOFOLLOW), true
	case .access:
		return fd_faccessat(linux.AT_FDCWD, s(a1)), true
	case .mkdir:
		return fd_mkdirat(linux.AT_FDCWD, s(a1), u32(a2)), true
	case .unlink:
		return fd_unlinkat(linux.AT_FDCWD, s(a1), 0), true
	case .rmdir:
		return fd_unlinkat(linux.AT_FDCWD, s(a1), linux.AT_REMOVEDIR), true
	case .dup2:
		return i32(a2) < 0 ? fail(.EBADF) : fd_dup2(int(i32(a1)), int(i32(a2))), true
	case .readlink:
		return fd_readlinkat(linux.AT_FDCWD, s(a1), ([^]u8)(p(a2))[:max(a3, 0)]), true
	case .rename:
		return fd_renameat(linux.AT_FDCWD, s(a1), linux.AT_FDCWD, s(a2), 0), true
	case .symlink:
		return fd_symlinkat(s(a1), linux.AT_FDCWD, s(a2)), true
	case .link:
		return fail(.EPERM), true
	case .chmod:
		return fd_chmod(-1, linux.AT_FDCWD, s(a1), true, u32(a2)), true
	case .chown:
		return fd_chown(-1, linux.AT_FDCWD, s(a1), true, u32(a2), u32(a3), true), true
	case .lchown:
		return fd_chown(-1, linux.AT_FDCWD, s(a1), true, u32(a2), u32(a3), false), true
	case .pause:
		return sig_suspend(be_me().mask), true
	case .poll:
		return sys_poll(([^]linux.Pollfd)(p(a1))[:max(a2, 0)], int(i32(a3))), true
	case .select:
		tv := (^linux.Timeval)(p(a5))
		ts: linux.Timespec
		if tv != nil && (tv.sec < 0 || tv.usec < 0) {
			return fail(.EINVAL), true
		}
		if tv != nil { // microseconds past a second carried into the seconds, as Linux does
			ts = {tv.sec + tv.usec / 1_000_000, tv.usec % 1_000_000 * 1000}
		}
		return sys_select(int(i32(a1)), (^linux.Fd_Set)(p(a2)), (^linux.Fd_Set)(p(a3)), (^linux.Fd_Set)(p(a4)), tv != nil ? &ts : nil, nil), true
	case .fork, .vfork:
		return proc_fork(), true
	case .pipe:
		return fd_pipe2((^[2]i32)(p(a1)), {}), true
	case .set_thread_area:
		return proc_set_tls(u64(a1)), true
	}
	return 0, false
}
