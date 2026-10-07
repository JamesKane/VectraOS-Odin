// The back end's Linux declarations (ports/musl/vx/linux) against musl's
// headers (ADR-0007): for each architecture, a C file of _Static_asserts,
// one per size, offset, system-call number, error number and constant, with
// Odin's values in it, compiled by the pinned clang against the vendored
// headers for that target. A declaration that drifts from musl's fails to
// compile, and clang names it.
package musl_layout_test

import "core:fmt"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:testing"
import linux "../../../ports/musl/vx/linux"

when ODIN_OS == .Darwin {
	CLANG :: "/opt/homebrew/opt/llvm@22/bin/clang"
	CLANG_RESOURCE_INCLUDE :: "/opt/homebrew/opt/llvm@22/lib/clang/22/include"
} else {
	CLANG :: "/usr/bin/clang"
	CLANG_RESOURCE_INCLUDE :: "/usr/lib/clang/22/include"
}

HEADERS :: `#define _GNU_SOURCE
#include <dirent.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <spawn.h>
#include <stddef.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/times.h>
#include <sys/uio.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#include "src/process/fdop.h"
#define hidden // musl's internal visibility, for ksigaction.h
`

Arch :: enum {
	X86_64,
	Aarch64,
}

ARCH_NAMES := [Arch]string {
	.X86_64  = "x86_64",
	.Aarch64 = "aarch64",
}

// One assertion: a C expression and the value Odin has for it.
Check :: struct {
	expr:  string,
	value: i64,
}

check :: proc(out: ^[dynamic]Check, expr: string, value: $T) {
	append(out, Check{expr, i64(value)})
}

// What both architectures share, then what each has of its own.
common_checks :: proc(out: ^[dynamic]Check) {
	check(out, "sizeof(struct timespec)", size_of(linux.Timespec))
	check(out, "sizeof(struct timeval)", size_of(linux.Timeval))
	check(out, "offsetof(struct dirent, d_name)", linux.DIRENT_NAME)
	check(out, "offsetof(struct dirent, d_type)", offset_of(linux.Dirent, type))
	check(out, "offsetof(struct dirent, d_reclen)", offset_of(linux.Dirent, reclen))
	check(out, "offsetof(struct dirent, d_off)", offset_of(linux.Dirent, off))
	check(out, "sizeof(struct dirent)", linux.DIRENT_SIZE)
	check(out, "sizeof(struct termios)", size_of(linux.Termios))
	check(out, "offsetof(struct termios, c_line)", offset_of(linux.Termios, line))
	check(out, "offsetof(struct termios, c_cc)", offset_of(linux.Termios, cc))
	check(out, "offsetof(struct termios, __c_ispeed)", offset_of(linux.Termios, ispeed))
	check(out, "offsetof(struct termios, __c_ospeed)", offset_of(linux.Termios, ospeed))
	check(out, "NCCS", linux.NCCS)
	check(out, "sizeof(struct winsize)", size_of(linux.Winsize))
	check(out, "offsetof(struct winsize, ws_col)", offset_of(linux.Winsize, col))
	check(out, "sizeof(stack_t)", size_of(linux.Stack))
	check(out, "offsetof(stack_t, ss_flags)", offset_of(linux.Stack, flags))
	check(out, "offsetof(stack_t, ss_size)", offset_of(linux.Stack, size))
	check(out, "sizeof(siginfo_t)", size_of(linux.Siginfo))
	check(out, "offsetof(siginfo_t, si_code)", offset_of(linux.Siginfo, code))
	check(out, "offsetof(siginfo_t, si_addr)", offset_of(linux.Siginfo, fields))
	check(out, "offsetof(siginfo_t, si_pid)", offset_of(linux.Siginfo, fields))
	check(out, "sizeof(struct k_sigaction)", size_of(linux.K_Sigaction))
	check(out, "offsetof(struct k_sigaction, flags)", offset_of(linux.K_Sigaction, flags))
	check(out, "offsetof(struct k_sigaction, restorer)", offset_of(linux.K_Sigaction, restorer))
	check(out, "offsetof(struct k_sigaction, mask)", offset_of(linux.K_Sigaction, mask))
	check(out, "sizeof(struct utsname)", size_of(linux.Utsname))
	check(out, "offsetof(struct utsname, machine)", offset_of(linux.Utsname, machine))
	check(out, "sizeof(struct rlimit)", size_of(linux.Rlimit))
	check(out, "sizeof(struct rusage)", size_of(linux.Rusage))
	check(out, "sizeof(struct tms)", size_of(linux.Tms))
	check(out, "offsetof(struct tms, tms_stime)", offset_of(linux.Tms, stime))
	check(out, "offsetof(struct tms, tms_cutime)", offset_of(linux.Tms, cutime))
	check(out, "offsetof(struct tms, tms_cstime)", offset_of(linux.Tms, cstime))
	check(out, "offsetof(struct rusage, ru_stime)", offset_of(linux.Rusage, stime))
	check(out, "sizeof(struct flock)", size_of(linux.Flock))
	check(out, "offsetof(struct flock, l_whence)", offset_of(linux.Flock, whence))
	check(out, "offsetof(struct flock, l_start)", offset_of(linux.Flock, start))
	check(out, "offsetof(struct flock, l_len)", offset_of(linux.Flock, len))
	check(out, "offsetof(struct flock, l_pid)", offset_of(linux.Flock, pid))
	check(out, "sizeof(struct iovec)", size_of(linux.Iovec))
	check(out, "offsetof(struct iovec, iov_len)", offset_of(linux.Iovec, len))
	check(out, "sizeof(struct msghdr)", size_of(linux.Msghdr))
	check(out, "offsetof(struct msghdr, msg_namelen)", offset_of(linux.Msghdr, namelen))
	check(out, "offsetof(struct msghdr, msg_iov)", offset_of(linux.Msghdr, iov))
	check(out, "offsetof(struct msghdr, msg_iovlen)", offset_of(linux.Msghdr, iovlen))
	check(out, "offsetof(struct msghdr, msg_control)", offset_of(linux.Msghdr, control))
	check(out, "offsetof(struct msghdr, msg_controllen)", offset_of(linux.Msghdr, controllen))
	check(out, "offsetof(struct msghdr, msg_flags)", offset_of(linux.Msghdr, flags))
	check(out, "sizeof(struct sockaddr_in)", size_of(linux.Sockaddr_In))
	check(out, "offsetof(struct sockaddr_in, sin_port)", offset_of(linux.Sockaddr_In, port))
	check(out, "offsetof(struct sockaddr_in, sin_addr)", offset_of(linux.Sockaddr_In, addr))
	check(out, "sizeof(struct pollfd)", size_of(linux.Pollfd))
	check(out, "offsetof(struct pollfd, events)", offset_of(linux.Pollfd, events))
	check(out, "offsetof(struct pollfd, revents)", offset_of(linux.Pollfd, revents))
	check(out, "sizeof(fd_set)", size_of(linux.Fd_Set))
	check(out, "sizeof(posix_spawnattr_t)", size_of(linux.Spawnattr))
	check(out, "offsetof(posix_spawnattr_t, __pgrp)", offset_of(linux.Spawnattr, pgrp))
	check(out, "offsetof(posix_spawnattr_t, __def)", offset_of(linux.Spawnattr, def))
	check(out, "offsetof(posix_spawnattr_t, __mask)", offset_of(linux.Spawnattr, mask))
	check(out, "offsetof(posix_spawnattr_t, __fn)", offset_of(linux.Spawnattr, fn))
	check(out, "sizeof(posix_spawn_file_actions_t)", size_of(linux.Spawn_File_Actions))
	check(out, "offsetof(posix_spawn_file_actions_t, __actions)", offset_of(linux.Spawn_File_Actions, actions))
	check(out, "offsetof(struct fdop, prev)", offset_of(linux.Fdop, prev))
	check(out, "offsetof(struct fdop, cmd)", offset_of(linux.Fdop, cmd))
	check(out, "offsetof(struct fdop, fd)", offset_of(linux.Fdop, fd))
	check(out, "offsetof(struct fdop, srcfd)", offset_of(linux.Fdop, srcfd))
	check(out, "offsetof(struct fdop, oflag)", offset_of(linux.Fdop, oflag))
	check(out, "offsetof(struct fdop, mode)", offset_of(linux.Fdop, mode))
	check(out, "offsetof(struct fdop, path)", linux.FDOP_PATH)

	// Error numbers, every one.
	for f in reflect.enum_fields_zipped(linux.Errno) {
		check(out, f.name, f.value)
	}

	// Flag words: each member's bit, and the constants.
	check(out, "O_WRONLY", 1 << uint(linux.Open_Flag.Wronly))
	check(out, "O_RDWR", 1 << uint(linux.Open_Flag.Rdwr))
	check(out, "O_CREAT", 1 << uint(linux.Open_Flag.Creat))
	check(out, "O_EXCL", 1 << uint(linux.Open_Flag.Excl))
	check(out, "O_TRUNC", 1 << uint(linux.Open_Flag.Trunc))
	check(out, "O_APPEND", 1 << uint(linux.Open_Flag.Append))
	check(out, "O_NONBLOCK", 1 << uint(linux.Open_Flag.Nonblock))
	check(out, "O_CLOEXEC", 1 << uint(linux.Open_Flag.Cloexec))
	check(out, "O_PATH", 1 << uint(linux.Open_Flag.Path))
	check(out, "O_ACCMODE", transmute(i32)linux.O_ACCMODE)
	check(out, "PROT_READ", transmute(i32)linux.Prot_Flags{.Read})
	check(out, "PROT_WRITE", transmute(i32)linux.Prot_Flags{.Write})
	check(out, "PROT_EXEC", transmute(i32)linux.Prot_Flags{.Exec})
	check(out, "WNOHANG", transmute(i32)linux.Wait_Options{.Nohang})
	check(out, "WUNTRACED", transmute(i32)linux.Wait_Options{.Untraced})
	check(out, "WCONTINUED", transmute(i32)linux.Wait_Options{.Continued})
	for f in reflect.enum_fields_zipped(linux.Sa_Flag) {
		check(out, fmt.tprintf("SA_%s", strings.to_upper(f.name, context.temp_allocator)), u64(1) << uint(f.value))
	}
	for f in reflect.enum_fields_zipped(linux.Msg_Flag) {
		check(out, fmt.tprintf("MSG_%s", strings.to_upper(f.name, context.temp_allocator)), 1 << uint(f.value))
	}
	for f in reflect.enum_fields_zipped(linux.Poll_Event) {
		check(out, fmt.tprintf("POLL%s", strings.to_upper(f.name, context.temp_allocator)), 1 << uint(f.value))
	}
	constants := [?]Check {
		{"AT_FDCWD", linux.AT_FDCWD},
		{"AT_SYMLINK_NOFOLLOW", linux.AT_SYMLINK_NOFOLLOW},
		{"AT_REMOVEDIR", linux.AT_REMOVEDIR},
		{"AT_EMPTY_PATH", linux.AT_EMPTY_PATH},
		{"F_OK", linux.F_OK},
		{"X_OK", linux.X_OK},
		{"W_OK", linux.W_OK},
		{"R_OK", linux.R_OK},
		{"LOCK_SH", linux.LOCK_SH},
		{"LOCK_EX", linux.LOCK_EX},
		{"LOCK_NB", linux.LOCK_NB},
		{"LOCK_UN", linux.LOCK_UN},
		{"F_DUPFD", linux.F_DUPFD},
		{"F_GETFD", linux.F_GETFD},
		{"F_SETFD", linux.F_SETFD},
		{"F_GETFL", linux.F_GETFL},
		{"F_SETFL", linux.F_SETFL},
		{"F_GETLK", linux.F_GETLK},
		{"F_SETLK", linux.F_SETLK},
		{"F_SETLKW", linux.F_SETLKW},
		{"F_DUPFD_CLOEXEC", linux.F_DUPFD_CLOEXEC},
		{"FD_CLOEXEC", linux.FD_CLOEXEC},
		{"F_RDLCK", linux.F_RDLCK},
		{"F_WRLCK", linux.F_WRLCK},
		{"F_UNLCK", linux.F_UNLCK},
		{"SEEK_SET", linux.SEEK_SET},
		{"SEEK_CUR", linux.SEEK_CUR},
		{"SEEK_END", linux.SEEK_END},
		{"MAP_SHARED", linux.MAP_SHARED},
		{"MAP_PRIVATE", linux.MAP_PRIVATE},
		{"MAP_SHARED_VALIDATE", linux.MAP_SHARED_VALIDATE},
		{"MAP_TYPE", linux.MAP_TYPE},
		{"MAP_FIXED", linux.MAP_FIXED},
		{"MAP_ANONYMOUS", linux.MAP_ANONYMOUS},
		{"MAP_FIXED_NOREPLACE", linux.MAP_FIXED_NOREPLACE},
		{"MREMAP_MAYMOVE", linux.MREMAP_MAYMOVE},
		{"S_IFMT", linux.S_IFMT},
		{"S_IFIFO", linux.S_IFIFO},
		{"S_IFCHR", linux.S_IFCHR},
		{"S_IFDIR", linux.S_IFDIR},
		{"S_IFREG", linux.S_IFREG},
		{"S_IFLNK", linux.S_IFLNK},
		{"S_IFSOCK", linux.S_IFSOCK},
		{"DT_DIR", linux.DT_DIR},
		{"DT_REG", linux.DT_REG},
		{"DT_LNK", linux.DT_LNK},
		{"TCGETS", linux.TCGETS},
		{"TCSETS", linux.TCSETS},
		{"TCSETSW", linux.TCSETSW},
		{"TCSETSF", linux.TCSETSF},
		{"TCSBRK", linux.TCSBRK},
		{"TCXONC", linux.TCXONC},
		{"TCFLSH", linux.TCFLSH},
		{"TIOCSCTTY", linux.TIOCSCTTY},
		{"TIOCGPGRP", linux.TIOCGPGRP},
		{"TIOCSPGRP", linux.TIOCSPGRP},
		{"TIOCGWINSZ", linux.TIOCGWINSZ},
		{"TIOCSWINSZ", linux.TIOCSWINSZ},
		{"FIONREAD", linux.FIONREAD},
		{"TIOCNOTTY", linux.TIOCNOTTY},
		{"TIOCGSID", linux.TIOCGSID},
		{"TIOCGPTN", linux.TIOCGPTN},
		{"TIOCSPTLCK", linux.TIOCSPTLCK},
		{"TCOFLUSH", linux.TCOFLUSH},
		{"B38400", linux.B38400},
		{"IOV_MAX", linux.IOV_MAX},
		{"UTIME_NOW", linux.UTIME_NOW},
		{"UTIME_OMIT", linux.UTIME_OMIT},
		{"CLOCK_REALTIME", linux.CLOCK_REALTIME},
		{"CLOCK_REALTIME_COARSE", linux.CLOCK_REALTIME_COARSE},
		{"CLOCK_REALTIME_ALARM", linux.CLOCK_REALTIME_ALARM},
		{"CLOCK_BOOTTIME_ALARM", linux.CLOCK_BOOTTIME_ALARM},
		{"CLOCK_TAI", linux.CLOCK_TAI},
		{"CLOCK_PROCESS_CPUTIME_ID", linux.CLOCK_PROCESS_CPUTIME_ID},
		{"CLOCK_THREAD_CPUTIME_ID", linux.CLOCK_THREAD_CPUTIME_ID},
		{"RUSAGE_SELF", linux.RUSAGE_SELF},
		{"RUSAGE_CHILDREN", linux.RUSAGE_CHILDREN},
		{"RUSAGE_THREAD", linux.RUSAGE_THREAD},
		{"PRIO_PROCESS", linux.PRIO_PROCESS},
		{"PRIO_PGRP", linux.PRIO_PGRP},
		{"PRIO_USER", linux.PRIO_USER},
		{"TIMER_ABSTIME", linux.TIMER_ABSTIME},
		{"RWF_NOAPPEND", linux.RWF_NOAPPEND},
		{"SIGHUP", linux.SIGHUP},
		{"SIGINT", linux.SIGINT},
		{"SIGILL", linux.SIGILL},
		{"SIGTRAP", linux.SIGTRAP},
		{"SIGBUS", linux.SIGBUS},
		{"SIGFPE", linux.SIGFPE},
		{"SIGKILL", linux.SIGKILL},
		{"SIGUSR1", linux.SIGUSR1},
		{"SIGSEGV", linux.SIGSEGV},
		{"SIGPIPE", linux.SIGPIPE},
		{"SIGCHLD", linux.SIGCHLD},
		{"SIGSTOP", linux.SIGSTOP},
		{"SIGTSTP", linux.SIGTSTP},
		{"SIGTTIN", linux.SIGTTIN},
		{"SIGTTOU", linux.SIGTTOU},
		{"_NSIG - 1", linux.NSIG_MAX},
		{"SIG_BLOCK", linux.SIG_BLOCK},
		{"SIG_UNBLOCK", linux.SIG_UNBLOCK},
		{"SIG_SETMASK", linux.SIG_SETMASK},
		{"SS_ONSTACK", linux.SS_ONSTACK},
		{"SS_DISABLE", linux.SS_DISABLE},
		{"CLONE_VM", linux.CLONE_VM},
		{"CLONE_THREAD", linux.CLONE_THREAD},
		{"CLONE_SETTLS", linux.CLONE_SETTLS},
		{"CLONE_PARENT_SETTID", linux.CLONE_PARENT_SETTID},
		{"CLONE_CHILD_CLEARTID", linux.CLONE_CHILD_CLEARTID},
		{"SI_USER", linux.SI_USER},
		{"SI_KERNEL", linux.SI_KERNEL},
		{"SEGV_MAPERR", linux.SEGV_MAPERR},
		{"BUS_ADRALN", linux.BUS_ADRALN},
		{"BUS_ADRERR", linux.BUS_ADRERR},
		{"ILL_ILLOPC", linux.ILL_ILLOPC},
		{"FPE_INTDIV", linux.FPE_INTDIV},
		{"TRAP_BRKPT", linux.TRAP_BRKPT},
		{"AF_INET", linux.AF_INET},
		{"SOCK_STREAM", linux.SOCK_STREAM},
		{"SOCK_DGRAM", linux.SOCK_DGRAM},
		{"SOCK_NONBLOCK", linux.SOCK_NONBLOCK},
		{"SOCK_CLOEXEC", linux.SOCK_CLOEXEC},
		{"IPPROTO_TCP", linux.IPPROTO_TCP},
		{"IPPROTO_UDP", linux.IPPROTO_UDP},
		{"INADDR_ANY", i64(linux.INADDR_ANY)},
		{"INADDR_LOOPBACK", i64(linux.INADDR_LOOPBACK)},
		{"SHUT_RD", linux.SHUT_RD},
		{"SHUT_WR", linux.SHUT_WR},
		{"SHUT_RDWR", linux.SHUT_RDWR},
		{"SOL_SOCKET", linux.SOL_SOCKET},
		{"SO_REUSEADDR", linux.SO_REUSEADDR},
		{"SO_TYPE", linux.SO_TYPE},
		{"SO_ERROR", linux.SO_ERROR},
		{"SO_BROADCAST", linux.SO_BROADCAST},
		{"SO_SNDBUF", linux.SO_SNDBUF},
		{"SO_RCVBUF", linux.SO_RCVBUF},
		{"SO_KEEPALIVE", linux.SO_KEEPALIVE},
		{"SO_LINGER", linux.SO_LINGER},
		{"SO_REUSEPORT", linux.SO_REUSEPORT},
		{"SO_RCVTIMEO", linux.SO_RCVTIMEO},
		{"SO_SNDTIMEO", linux.SO_SNDTIMEO},
		{"SO_ACCEPTCONN", linux.SO_ACCEPTCONN},
		{"SO_PROTOCOL", linux.SO_PROTOCOL},
		{"SO_DOMAIN", linux.SO_DOMAIN},
		{"TCP_NODELAY", linux.TCP_NODELAY},
		{"TCP_KEEPIDLE", linux.TCP_KEEPIDLE},
		{"TCP_KEEPINTVL", linux.TCP_KEEPINTVL},
		{"TCP_KEEPCNT", linux.TCP_KEEPCNT},
		{"FD_SETSIZE", linux.FD_SETSIZE},
		{"AT_NULL", linux.AT_NULL},
		{"AT_PHDR", linux.AT_PHDR},
		{"AT_PHENT", linux.AT_PHENT},
		{"AT_PHNUM", linux.AT_PHNUM},
		{"AT_PAGESZ", linux.AT_PAGESZ},
		{"AT_RANDOM", linux.AT_RANDOM},
		{"AT_EXECFN", linux.AT_EXECFN},
		{"POSIX_SPAWN_SETPGROUP", linux.POSIX_SPAWN_SETPGROUP},
		{"POSIX_SPAWN_SETSIGDEF", linux.POSIX_SPAWN_SETSIGDEF},
		{"POSIX_SPAWN_SETSIGMASK", linux.POSIX_SPAWN_SETSIGMASK},
		{"POSIX_SPAWN_SETSID", linux.POSIX_SPAWN_SETSID},
		{"FDOP_CLOSE", linux.FDOP_CLOSE},
		{"FDOP_DUP2", linux.FDOP_DUP2},
		{"FDOP_OPEN", linux.FDOP_OPEN},
		{"FDOP_CHDIR", linux.FDOP_CHDIR},
		{"FDOP_FCHDIR", linux.FDOP_FCHDIR},
	}
	append(out, ..constants[:])
}

arch_checks :: proc(out: ^[dynamic]Check, a: Arch) {
	switch a {
	case .X86_64:
		stat_checks(out, linux.Stat_Amd64)
		check(out, "sizeof(ucontext_t)", size_of(linux.Ucontext_Amd64))
		check(out, "offsetof(ucontext_t, uc_sigmask)", offset_of(linux.Ucontext_Amd64, sigmask))
		check(out, "offsetof(ucontext_t, uc_mcontext.fpregs)", offset_of(linux.Ucontext_Amd64, mcontext) + offset_of(linux.Mcontext_Amd64, fpregs))
		check(out, "MINSIGSTKSZ", 2048)
		regs := [?]struct {
			name:  string,
			value: int,
		} {
			{"REG_R8", linux.REG_R8}, {"REG_R9", linux.REG_R9}, {"REG_R10", linux.REG_R10}, {"REG_R11", linux.REG_R11},
			{"REG_R12", linux.REG_R12}, {"REG_R13", linux.REG_R13}, {"REG_R14", linux.REG_R14}, {"REG_R15", linux.REG_R15},
			{"REG_RDI", linux.REG_RDI}, {"REG_RSI", linux.REG_RSI}, {"REG_RBP", linux.REG_RBP}, {"REG_RBX", linux.REG_RBX},
			{"REG_RDX", linux.REG_RDX}, {"REG_RAX", linux.REG_RAX}, {"REG_RCX", linux.REG_RCX}, {"REG_RSP", linux.REG_RSP},
			{"REG_RIP", linux.REG_RIP}, {"REG_EFL", linux.REG_EFL}, {"REG_ERR", linux.REG_ERR}, {"REG_TRAPNO", linux.REG_TRAPNO},
			{"REG_CR2", linux.REG_CR2},
		}
		for r in regs {
			check(out, r.name, r.value)
		}
		check(out, "O_DIRECTORY", 1 << uint(linux.O_DIRECTORY_AMD64))
		check(out, "O_NOFOLLOW", 1 << uint(linux.O_NOFOLLOW_AMD64))
		for f in reflect.enum_fields_zipped(linux.Sys_Amd64) {
			check(out, fmt.tprintf("SYS_%s", f.name), f.value)
		}
	case .Aarch64:
		stat_checks(out, linux.Stat_Arm64)
		check(out, "sizeof(ucontext_t)", size_of(linux.Ucontext_Arm64))
		check(out, "offsetof(ucontext_t, uc_sigmask)", offset_of(linux.Ucontext_Arm64, sigmask))
		check(out, "offsetof(ucontext_t, uc_mcontext.__reserved)", offset_of(linux.Ucontext_Arm64, mcontext) + offset_of(linux.Mcontext_Arm64, reserved))
		check(out, "offsetof(ucontext_t, uc_mcontext.fault_address)", offset_of(linux.Ucontext_Arm64, mcontext) + offset_of(linux.Mcontext_Arm64, fault_address))
		check(out, "sizeof(struct fpsimd_context)", size_of(linux.Fpsimd_Context))
		check(out, "offsetof(struct fpsimd_context, fpsr)", offset_of(linux.Fpsimd_Context, fpsr))
		check(out, "offsetof(struct fpsimd_context, vregs)", offset_of(linux.Fpsimd_Context, vregs))
		check(out, "FPSIMD_MAGIC", linux.FPSIMD_MAGIC)
		check(out, "MINSIGSTKSZ", 6144)
		check(out, "O_DIRECTORY", 1 << uint(linux.O_DIRECTORY_ARM64))
		check(out, "O_NOFOLLOW", 1 << uint(linux.O_NOFOLLOW_ARM64))
		for f in reflect.enum_fields_zipped(linux.Sys_Arm64) {
			check(out, fmt.tprintf("SYS_%s", f.name), f.value)
		}
	}
}

stat_checks :: proc(out: ^[dynamic]Check, $T: typeid) {
	check(out, "sizeof(struct stat)", size_of(T))
	check(out, "offsetof(struct stat, st_ino)", offset_of(T, ino))
	check(out, "offsetof(struct stat, st_nlink)", offset_of(T, nlink))
	check(out, "sizeof(((struct stat *)0)->st_nlink)", size_of(type_of(T{}.nlink)))
	check(out, "offsetof(struct stat, st_mode)", offset_of(T, mode))
	check(out, "offsetof(struct stat, st_uid)", offset_of(T, uid))
	check(out, "offsetof(struct stat, st_gid)", offset_of(T, gid))
	check(out, "offsetof(struct stat, st_rdev)", offset_of(T, rdev))
	check(out, "offsetof(struct stat, st_size)", offset_of(T, size))
	check(out, "offsetof(struct stat, st_blksize)", offset_of(T, blksize))
	check(out, "sizeof(((struct stat *)0)->st_blksize)", size_of(type_of(T{}.blksize)))
	check(out, "offsetof(struct stat, st_blocks)", offset_of(T, blocks))
	check(out, "offsetof(struct stat, st_atim)", offset_of(T, atim))
	check(out, "offsetof(struct stat, st_mtim)", offset_of(T, mtim))
	check(out, "offsetof(struct stat, st_ctim)", offset_of(T, ctim))
}

// The include path a program against musl compiles with (tools/build's
// posix_flags), and musl's own tree for fdop.h and ksigaction.h.
compile :: proc(t: ^testing.T, a: Arch, tag, source: string) -> (ok: bool, why: string) {
	name := ARCH_NAMES[a]
	path := fmt.tprintf("out/host/musl_layout_%s_%s.c", tag, name) // one per test: they run at once
	if err := os.make_directory_all("out/host"); err != nil && err != .Exist {
		return false, fmt.tprintf("cannot make out/host: %v", err)
	}
	if err := os.write_entire_file(path, transmute([]u8)source); err != nil {
		return false, fmt.tprintf("cannot write %s: %v", path, err)
	}
	// rt_sigaction's argument is in musl's internal ksigaction.h: x86_64's
	// own, or the generic one, after signal.h has defined SA_RESTORER.
	ksig := a == .X86_64 ? "third_party/musl/arch/x86_64" : "third_party/musl/src/internal"
	cmd := []string {
		CLANG,
		fmt.tprintf("--target=%s-linux-musl", name),
		"-nostdinc",
		"-isystem", CLANG_RESOURCE_INCLUDE,
		"-isystem", fmt.tprintf("third_party/musl/arch/%s", name),
		"-isystem", "third_party/musl/arch/generic",
		"-isystem", fmt.tprintf("ports/musl/generated/%s/include", name),
		"-isystem", "third_party/musl/include",
		"-iquote", "third_party/musl",
		"-iquote", ksig,
		"-fsyntax-only",
		path,
	}
	state, _, stderr, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil {
		return false, fmt.tprintf("cannot run %s: %v", CLANG, err)
	}
	if !state.exited || state.exit_code != 0 {
		return false, string(stderr)
	}
	return true, ""
}

layout_source :: proc(a: Arch) -> string {
	checks := make([dynamic]Check, context.temp_allocator)
	common_checks(&checks)
	arch_checks(&checks, a)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, HEADERS)
	strings.write_string(&b, "#include \"ksigaction.h\"\n")
	for c in checks {
		fmt.sbprintf(&b, "_Static_assert((long long)(%s) == %dLL, \"%s is %d in ports/musl/vx/linux\");\n", c.expr, c.value, c.expr, c.value)
	}
	return strings.to_string(b)
}

@(test)
layouts_match_musl_x86_64 :: proc(t: ^testing.T) {
	ok, why := compile(t, .X86_64, "layout", layout_source(.X86_64))
	testing.expectf(t, ok, "x86_64: %s", why)
}

@(test)
layouts_match_musl_aarch64 :: proc(t: ^testing.T) {
	ok, why := compile(t, .Aarch64, "layout", layout_source(.Aarch64))
	testing.expectf(t, ok, "aarch64: %s", why)
}

// A drift is caught: a wrong value fails to compile.
@(test)
a_wrong_value_fails :: proc(t: ^testing.T) {
	source := fmt.tprintf("%s_Static_assert(sizeof(struct stat) == 1, \"wrong\");\n", HEADERS)
	ok, _ := compile(t, .Aarch64, "wrong", source)
	testing.expect(t, !ok, "a wrong size compiled")
}
