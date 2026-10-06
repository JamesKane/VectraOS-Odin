// What musl asks of the kernel, in Linux's words, as musl's headers give
// them (third_party/musl, ADR-0007): the system-call numbers, the error
// numbers, the flag words, and the structures musl passes and the back end
// reads or writes. That is the POSIX personality, and it stays inside the C
// library.
//
// Where the two architectures differ, both are declared (Stat_Amd64 and
// Stat_Arm64, O_DIRECTORY_AMD64 and O_DIRECTORY_ARM64), and the plain name is
// the target's; every size and offset is asserted here, and
// tests/host/musl_layout checks each against the C headers for both targets.
// It has no code and imports nothing, so the host test builds it.
package linux

// --- Error numbers (arch/generic/bits/errno.h: the same on both) ---

Errno :: enum i32 {
	EPERM           = 1,
	ENOENT          = 2,
	ESRCH           = 3,
	EINTR           = 4,
	EIO             = 5,
	E2BIG           = 7,
	ENOEXEC         = 8,
	EBADF           = 9,
	ECHILD          = 10,
	EAGAIN          = 11,
	ENOMEM          = 12,
	EACCES          = 13,
	EFAULT          = 14,
	EEXIST          = 17,
	EXDEV           = 18,
	ENODEV          = 19,
	ENOTDIR         = 20,
	EISDIR          = 21,
	EINVAL          = 22,
	ENFILE          = 23,
	EMFILE          = 24,
	ENOTTY          = 25,
	ENOSPC          = 28,
	ESPIPE          = 29,
	EPIPE           = 32,
	EDOM            = 33,
	ERANGE          = 34,
	ENAMETOOLONG    = 36,
	ENOLCK          = 37,
	ENOSYS          = 38,
	ELOOP           = 40,
	EILSEQ          = 84,
	ENOTSOCK        = 88,
	EDESTADDRREQ    = 89,
	EMSGSIZE        = 90,
	ENOPROTOOPT     = 92,
	EPROTONOSUPPORT = 93,
	EOPNOTSUPP      = 95, // ENOTSUP too
	EAFNOSUPPORT    = 97,
	EADDRINUSE      = 98,
	EADDRNOTAVAIL   = 99,
	ENETDOWN        = 100,
	ENETUNREACH     = 101,
	ECONNRESET      = 104,
	ENOBUFS         = 105,
	EISCONN         = 106,
	ENOTCONN        = 107,
	ETIMEDOUT       = 110,
	ECONNREFUSED    = 111,
	EALREADY        = 114,
	EINPROGRESS     = 115,
}

ENOTSUP :: Errno.EOPNOTSUPP

// --- System-call numbers (bits/syscall.h) ---
//
// Only those the back end answers; any other is ENOSYS. x86_64 has the old
// calls (open, stat, poll, fork and the rest) that aarch64 has only as their
// *at and p* forms.

Sys_Amd64 :: enum int {
	read            = 0,
	write           = 1,
	open            = 2,
	close           = 3,
	stat            = 4,
	fstat           = 5,
	lstat           = 6,
	poll            = 7,
	lseek           = 8,
	mmap            = 9,
	mprotect        = 10,
	munmap          = 11,
	brk             = 12,
	rt_sigaction    = 13,
	rt_sigprocmask  = 14,
	ioctl           = 16,
	pread64         = 17,
	pwrite64        = 18,
	readv           = 19,
	writev          = 20,
	access          = 21,
	pipe            = 22,
	select          = 23,
	sched_yield     = 24,
	mremap          = 25,
	msync           = 26,
	madvise         = 28,
	dup             = 32,
	dup2            = 33,
	pause           = 34,
	nanosleep       = 35,
	getpid          = 39,
	socket          = 41,
	connect         = 42,
	accept          = 43,
	sendto          = 44,
	recvfrom        = 45,
	sendmsg         = 46,
	recvmsg         = 47,
	shutdown        = 48,
	bind            = 49,
	listen          = 50,
	getsockname     = 51,
	getpeername     = 52,
	socketpair      = 53,
	setsockopt      = 54,
	getsockopt      = 55,
	clone           = 56,
	fork            = 57,
	vfork           = 58,
	execve          = 59,
	exit            = 60,
	wait4           = 61,
	kill            = 62,
	uname           = 63,
	fcntl           = 72,
	fsync           = 74,
	fdatasync       = 75,
	truncate        = 76,
	ftruncate       = 77,
	getcwd          = 79,
	chdir           = 80,
	rename          = 82,
	mkdir           = 83,
	rmdir           = 84,
	link            = 86,
	unlink          = 87,
	symlink         = 88,
	readlink        = 89,
	chmod           = 90,
	fchmod          = 91,
	chown           = 92,
	fchown          = 93,
	lchown          = 94,
	umask           = 95,
	getuid          = 102,
	getgid          = 104,
	geteuid         = 107,
	getegid         = 108,
	setpgid         = 109,
	getppid         = 110,
	setsid          = 112,
	getpgid         = 121,
	getsid          = 124,
	rt_sigpending   = 127,
	rt_sigsuspend   = 130,
	sigaltstack     = 131,
	gettid          = 186,
	tkill           = 200,
	futex           = 202,
	set_thread_area = 205,
	getdents64      = 217,
	set_tid_address = 218,
	clock_gettime   = 228,
	clock_getres    = 229,
	clock_nanosleep = 230,
	exit_group      = 231,
	tgkill          = 234,
	openat          = 257,
	mkdirat         = 258,
	fchownat        = 260,
	newfstatat      = 262,
	unlinkat        = 263,
	renameat        = 264,
	linkat          = 265,
	symlinkat       = 266,
	readlinkat      = 267,
	fchmodat        = 268,
	faccessat       = 269,
	pselect6        = 270,
	ppoll           = 271,
	utimensat       = 280,
	accept4         = 288,
	dup3            = 292,
	pipe2           = 293,
	prlimit64       = 302,
	renameat2       = 316,
	getrandom       = 318,
	preadv2         = 327,
	pwritev2        = 328,
}

Sys_Arm64 :: enum int {
	getcwd          = 17,
	dup             = 23,
	dup3            = 24,
	fcntl           = 25,
	ioctl           = 29,
	mkdirat         = 34,
	unlinkat        = 35,
	symlinkat       = 36,
	linkat          = 37,
	renameat        = 38,
	truncate        = 45,
	ftruncate       = 46,
	faccessat       = 48,
	chdir           = 49,
	fchmod          = 52,
	fchmodat        = 53,
	fchownat        = 54,
	fchown          = 55,
	openat          = 56,
	close           = 57,
	pipe2           = 59,
	getdents64      = 61,
	lseek           = 62,
	read            = 63,
	write           = 64,
	readv           = 65,
	writev          = 66,
	pread64         = 67,
	pwrite64        = 68,
	pselect6        = 72,
	ppoll           = 73,
	readlinkat      = 78,
	newfstatat      = 79,
	fstat           = 80,
	fsync           = 82,
	fdatasync       = 83,
	utimensat       = 88,
	exit            = 93,
	exit_group      = 94,
	set_tid_address = 96,
	futex           = 98,
	nanosleep       = 101,
	clock_gettime   = 113,
	clock_getres    = 114,
	clock_nanosleep = 115,
	sched_yield     = 124,
	kill            = 129,
	tkill           = 130,
	tgkill          = 131,
	sigaltstack     = 132,
	rt_sigsuspend   = 133,
	rt_sigaction    = 134,
	rt_sigprocmask  = 135,
	rt_sigpending   = 136,
	setpgid         = 154,
	getpgid         = 155,
	getsid          = 156,
	setsid          = 157,
	uname           = 160,
	umask           = 166,
	getpid          = 172,
	getppid         = 173,
	getuid          = 174,
	geteuid         = 175,
	getgid          = 176,
	getegid         = 177,
	gettid          = 178,
	socket          = 198,
	socketpair      = 199,
	bind            = 200,
	listen          = 201,
	accept          = 202,
	connect         = 203,
	getsockname     = 204,
	getpeername     = 205,
	sendto          = 206,
	recvfrom        = 207,
	setsockopt      = 208,
	getsockopt      = 209,
	shutdown        = 210,
	sendmsg         = 211,
	recvmsg         = 212,
	brk             = 214,
	munmap          = 215,
	mremap          = 216,
	clone           = 220,
	execve          = 221,
	mmap            = 222,
	mprotect        = 226,
	msync           = 227,
	madvise         = 233,
	accept4         = 242,
	wait4           = 260,
	prlimit64       = 261,
	renameat2       = 276,
	getrandom       = 278,
	preadv2         = 286,
	pwritev2        = 287,
}

// --- Flag words ---

// open's and fcntl's: the access mode is O_WRONLY (bit 0) or O_RDWR (bit 1),
// or neither (O_RDONLY). O_DIRECTORY and O_NOFOLLOW are where each
// architecture puts them.
O_DIRECTORY_AMD64 :: 16 // 0200000
O_NOFOLLOW_AMD64 :: 17 // 0400000
O_DIRECTORY_ARM64 :: 14 // 040000
O_NOFOLLOW_ARM64 :: 15 // 0100000

when ODIN_ARCH == .amd64 {
	@(private="file")
	O_DIRECTORY_BIT :: O_DIRECTORY_AMD64
	@(private="file")
	O_NOFOLLOW_BIT :: O_NOFOLLOW_AMD64
} else {
	@(private="file")
	O_DIRECTORY_BIT :: O_DIRECTORY_ARM64
	@(private="file")
	O_NOFOLLOW_BIT :: O_NOFOLLOW_ARM64
}

Open_Flag :: enum i32 {
	Wronly    = 0,
	Rdwr      = 1,
	Creat     = 6,
	Excl      = 7,
	Trunc     = 9,
	Append    = 10,
	Nonblock  = 11,
	Directory = O_DIRECTORY_BIT,
	Nofollow  = O_NOFOLLOW_BIT,
	Cloexec   = 19,
	Path      = 21, // O_SEARCH, which musl counts in O_ACCMODE
}
Open_Flags :: bit_set[Open_Flag;i32]

O_ACCMODE :: Open_Flags{.Wronly, .Rdwr, .Path}
O_RDONLY :: Open_Flags{}
O_WRONLY :: Open_Flags{.Wronly}
O_RDWR :: Open_Flags{.Rdwr}

AT_FDCWD :: -100
AT_SYMLINK_NOFOLLOW :: 0x100
AT_REMOVEDIR :: 0x200
AT_EMPTY_PATH :: 0x1000

// fcntl's commands.
F_DUPFD :: 0
F_GETFD :: 1
F_SETFD :: 2
F_GETFL :: 3
F_SETFL :: 4
F_GETLK :: 5
F_SETLK :: 6
F_SETLKW :: 7
F_DUPFD_CLOEXEC :: 1030
FD_CLOEXEC :: 1
F_RDLCK :: 0
F_WRLCK :: 1
F_UNLCK :: 2

SEEK_SET :: 0
SEEK_CUR :: 1
SEEK_END :: 2

// mmap's.
Prot :: enum i32 {
	Read,
	Write,
	Exec,
}
Prot_Flags :: bit_set[Prot;i32]
PROT_NONE :: Prot_Flags{}

MAP_SHARED :: 0x01
MAP_PRIVATE :: 0x02
MAP_SHARED_VALIDATE :: 0x03
MAP_TYPE :: 0x0f
MAP_FIXED :: 0x10
MAP_ANONYMOUS :: 0x20
MAP_FIXED_NOREPLACE :: 0x100000
MREMAP_MAYMOVE :: 1

// st_mode's file types.
S_IFMT :: 0o170000
S_IFIFO :: 0o010000
S_IFCHR :: 0o020000
S_IFDIR :: 0o040000
S_IFREG :: 0o100000
S_IFLNK :: 0o120000
S_IFSOCK :: 0o140000

DT_DIR :: 4
DT_REG :: 8
DT_LNK :: 10

// The terminal ioctls (the same on both: aarch64's are the generic ones).
TCGETS :: 0x5401
TCSETS :: 0x5402
TCSETSW :: 0x5403
TCSETSF :: 0x5404
TCSBRK :: 0x5409
TCXONC :: 0x540A
TCFLSH :: 0x540B
TIOCSCTTY :: 0x540E
TIOCGPGRP :: 0x540F
TIOCSPGRP :: 0x5410
TIOCGWINSZ :: 0x5413
TIOCSWINSZ :: 0x5414
FIONREAD :: 0x541B
TIOCNOTTY :: 0x5422
TIOCGSID :: 0x5429
TIOCGPTN :: 0x80045430
TIOCSPTLCK :: 0x40045431
TCOFLUSH :: 1
B38400 :: 0o17
NCCS :: 32

IOV_MAX :: 1024
UTIME_NOW :: 0x3fffffff
UTIME_OMIT :: 0x3ffffffe
CLOCK_REALTIME :: 0
CLOCK_REALTIME_COARSE :: 5
CLOCK_REALTIME_ALARM :: 8
CLOCK_BOOTTIME_ALARM :: 9
CLOCK_TAI :: 11 // the highest clock id
TIMER_ABSTIME :: 1
RLIM_INFINITY :: max(u64)
RWF_NOAPPEND :: 0x20

// wait4's options.
Wait_Option :: enum i32 {
	Nohang     = 0,
	Untraced   = 1,
	Continued  = 3,
}
Wait_Options :: bit_set[Wait_Option;i32]

// Signals (bits/signal.h: the same on both). A set's bit n-1 is signal n,
// as sigset_t's first word has it.
SIGHUP :: 1
SIGINT :: 2
SIGILL :: 4
SIGTRAP :: 5
SIGBUS :: 7
SIGFPE :: 8
SIGKILL :: 9
SIGUSR1 :: 10
SIGSEGV :: 11
SIGPIPE :: 13
SIGCHLD :: 17
SIGSTOP :: 19
SIGTSTP :: 20
SIGTTIN :: 21
SIGTTOU :: 22
NSIG_MAX :: 64

Sig_Set :: bit_set[1 ..= NSIG_MAX;u64]

SIG_DFL :: uintptr(0)
SIG_IGN :: uintptr(1)
SIG_BLOCK :: 0
SIG_UNBLOCK :: 1
SIG_SETMASK :: 2
SS_DISABLE :: 2

// clone's flags, as musl's pthread_create passes them to __clone.
CLONE_VM :: 0x100
CLONE_THREAD :: 0x10000
CLONE_SETTLS :: 0x80000
CLONE_PARENT_SETTID :: 0x100000
CLONE_CHILD_CLEARTID :: 0x200000

Sa_Flag :: enum u64 {
	Nocldstop = 0,
	Nocldwait = 1,
	Siginfo   = 2,
	Restorer  = 26,
	Onstack   = 27,
	Restart   = 28,
	Nodefer   = 30,
	Resethand = 31,
}
Sa_Flags :: bit_set[Sa_Flag;u64]

// si_code's.
SI_USER :: 0
SI_KERNEL :: 128
SEGV_MAPERR :: 1
SEGV_PKUERR :: 4 // a protection key's rights denied it (si_pkey)
BUS_ADRALN :: 1
BUS_ADRERR :: 2
ILL_ILLOPC :: 1
FPE_INTDIV :: 1
TRAP_BRKPT :: 1

// Sockets.
AF_INET :: 2
SOCK_STREAM :: 1
SOCK_DGRAM :: 2
SOCK_TYPE_MASK :: 0xf
SOCK_NONBLOCK :: 0o4000
SOCK_CLOEXEC :: 0o2000000
IPPROTO_TCP :: 6
IPPROTO_UDP :: 17
INADDR_ANY :: u32(0)
INADDR_LOOPBACK :: u32(0x7f000001)

Msg_Flag :: enum i32 {
	Peek      = 1,
	Dontroute = 2,
	Trunc     = 5,
	Dontwait  = 6,
	Waitall   = 8,
	Nosignal  = 14,
}
Msg_Flags :: bit_set[Msg_Flag;i32]

SHUT_RD :: 0
SHUT_WR :: 1
SHUT_RDWR :: 2
SOL_SOCKET :: 1
SO_REUSEADDR :: 2
SO_TYPE :: 3
SO_ERROR :: 4
SO_BROADCAST :: 6
SO_SNDBUF :: 7
SO_RCVBUF :: 8
SO_KEEPALIVE :: 9
SO_LINGER :: 13
SO_REUSEPORT :: 15
SO_RCVTIMEO :: 20
SO_SNDTIMEO :: 21
SO_ACCEPTCONN :: 30
SO_PROTOCOL :: 38
SO_DOMAIN :: 39
TCP_NODELAY :: 1
TCP_KEEPIDLE :: 4
TCP_KEEPINTVL :: 5
TCP_KEEPCNT :: 6

// poll's events.
Poll_Event :: enum i16 {
	In     = 0,
	Pri    = 1,
	Out    = 2,
	Err    = 3,
	Hup    = 4,
	Nval   = 5,
	Rdnorm = 6,
	Wrnorm = 8,
}
Poll_Events :: bit_set[Poll_Event;i16]
FD_SETSIZE :: 1024

// The auxiliary vector's keys (elf.h).
AT_NULL :: 0
AT_PHDR :: 3
AT_PHENT :: 4
AT_PHNUM :: 5
AT_PAGESZ :: 6
AT_RANDOM :: 25
AT_EXECFN :: 31

// posix_spawn's attribute flags (spawn.h) and file actions (musl's
// src/process/fdop.h).
POSIX_SPAWN_SETPGROUP :: 2
POSIX_SPAWN_SETSIGDEF :: 4
POSIX_SPAWN_SETSIGMASK :: 8
POSIX_SPAWN_SETSID :: 128
FDOP_CLOSE :: 1
FDOP_DUP2 :: 2
FDOP_OPEN :: 3
FDOP_CHDIR :: 4
FDOP_FCHDIR :: 5

// The futex operations musl uses; the private and clock flags (128, 256)
// change nothing here.
FUTEX_WAIT :: 0
FUTEX_WAKE :: 1
FUTEX_CMD_MASK :: 127

// --- Structures ---

Timespec :: struct {
	sec:  i64,
	nsec: i64,
}
#assert(size_of(Timespec) == 16)

Timeval :: struct {
	sec:  i64,
	usec: i64,
}
#assert(size_of(Timeval) == 16)

Stat_Amd64 :: struct {
	dev:     u64,
	ino:     u64,
	nlink:   u64,
	mode:    u32,
	uid:     u32,
	gid:     u32,
	_:       u32,
	rdev:    u64,
	size:    i64,
	blksize: i64,
	blocks:  i64,
	atim:    Timespec,
	mtim:    Timespec,
	ctim:    Timespec,
	_:       [3]i64,
}
#assert(size_of(Stat_Amd64) == 144)
#assert(offset_of(Stat_Amd64, nlink) == 16)
#assert(offset_of(Stat_Amd64, mode) == 24)
#assert(offset_of(Stat_Amd64, uid) == 28)
#assert(offset_of(Stat_Amd64, rdev) == 40)
#assert(offset_of(Stat_Amd64, size) == 48)
#assert(offset_of(Stat_Amd64, blksize) == 56)
#assert(offset_of(Stat_Amd64, blocks) == 64)
#assert(offset_of(Stat_Amd64, atim) == 72)
#assert(offset_of(Stat_Amd64, ctim) == 104)

Stat_Arm64 :: struct {
	dev:     u64,
	ino:     u64,
	mode:    u32,
	nlink:   u32,
	uid:     u32,
	gid:     u32,
	rdev:    u64,
	_:       u64,
	size:    i64,
	blksize: i32,
	_:       i32,
	blocks:  i64,
	atim:    Timespec,
	mtim:    Timespec,
	ctim:    Timespec,
	_:       [2]u32,
}
#assert(size_of(Stat_Arm64) == 128)
#assert(offset_of(Stat_Arm64, nlink) == 20)
#assert(offset_of(Stat_Arm64, mode) == 16)
#assert(offset_of(Stat_Arm64, uid) == 24)
#assert(offset_of(Stat_Arm64, rdev) == 32)
#assert(offset_of(Stat_Arm64, size) == 48)
#assert(offset_of(Stat_Arm64, blksize) == 56)
#assert(offset_of(Stat_Arm64, blocks) == 64)
#assert(offset_of(Stat_Arm64, atim) == 72)
#assert(offset_of(Stat_Arm64, ctim) == 104)

// struct dirent (dirent64): a record of reclen bytes, its name NUL-terminated
// after the header.
Dirent :: struct {
	ino:    u64,
	off:    i64,
	reclen: u16,
	type:   u8,
	// d_name follows: char[256]
}
DIRENT_NAME :: 19 // d_name's offset
DIRENT_SIZE :: 280
#assert(offset_of(Dirent, type) == 18)

// struct termios, musl's (the TCGETS ioctl fills it as it is).
Termios :: struct {
	iflag, oflag, cflag, lflag: u32,
	line:                       u8,
	cc:                         [NCCS]u8,
	ispeed, ospeed:             u32,
}
#assert(size_of(Termios) == 60)
#assert(offset_of(Termios, cc) == 17)
#assert(offset_of(Termios, ispeed) == 52)

Winsize :: struct {
	row, col, xpixel, ypixel: u16,
}
#assert(size_of(Winsize) == 8)

Stack :: struct {
	sp:    uintptr,
	flags: i32,
	size:  uint,
}
#assert(size_of(Stack) == 24)
#assert(offset_of(Stack, flags) == 8)

// siginfo_t: the sender's pid and a fault's address share the union.
Siginfo :: struct {
	signo, errno, code: i32,
	fields:             struct #raw_union {
		addr:  uintptr,
		pid:   i32,
		fault: Sigfault,
		_:     [112]u8,
	},
}
#assert(size_of(Siginfo) == 128)
#assert(offset_of(Siginfo, code) == 8)
#assert(offset_of(Siginfo, fields) == 16)

// A fault's fields: si_addr, si_addr_lsb, then si_pkey where si_lower would be.
Sigfault :: struct {
	addr:     uintptr,
	addr_lsb: i16,
	_:        [6]u8,
	pkey:     u32,
}
#assert(offset_of(Siginfo, fields) + offset_of(Sigfault, pkey) == 32) // musl's si_pkey

// ucontext_t: only its signal mask is filled in (with the mask a handler
// interrupted); the registers wait (upstream's signal.c says so).
Ucontext_Amd64 :: struct {
	flags:   u64,
	link:    uintptr,
	stack:   Stack,
	mcontext: [256]u8, // gregs, fpregs, __reserved1
	sigmask: [128]u8,
	_:       [64]u64, // __fpregs_mem
}
#assert(size_of(Ucontext_Amd64) == 936)
#assert(offset_of(Ucontext_Amd64, sigmask) == 296)

Mcontext_Arm64 :: struct #align (16) {
	fault_address:  u64,
	regs:           [31]u64,
	sp, pc, pstate: u64,
	_:              [4096 + 8]u8, // __reserved, 16-byte aligned
}

Ucontext_Arm64 :: struct {
	flags:    u64,
	link:     uintptr,
	stack:    Stack,
	sigmask:  [128]u8,
	mcontext: Mcontext_Arm64,
}
#assert(size_of(Ucontext_Arm64) == 4560)
#assert(offset_of(Ucontext_Arm64, sigmask) == 40)

// rt_sigaction's argument, as musl lays it out (src/internal/ksigaction.h,
// and arch/x86_64/ksigaction.h, which is the same).
K_Sigaction :: struct {
	handler:  uintptr,
	flags:    Sa_Flags,
	restorer: uintptr,
	mask:     [2]u32,
}
#assert(size_of(K_Sigaction) == 32)

Utsname :: struct {
	sysname, nodename, release, version, machine, domainname: [65]u8,
}
#assert(size_of(Utsname) == 390)
#assert(offset_of(Utsname, machine) == 260)

Rlimit :: struct {
	cur, max: u64,
}
#assert(size_of(Rlimit) == 16)

Rusage :: struct {
	utime, stime: Timeval,
	fields:       [14]i64, // ru_maxrss to ru_nivcsw
	_:            [16]i64,
}
#assert(size_of(Rusage) == 272)

Flock :: struct {
	type, whence: i16,
	start, len:   i64,
	pid:          i32,
}
#assert(size_of(Flock) == 32)
#assert(offset_of(Flock, start) == 8)
#assert(offset_of(Flock, pid) == 24)

Iovec :: struct {
	base: rawptr,
	len:  uint,
}
#assert(size_of(Iovec) == 16)

Msghdr :: struct {
	name:       rawptr,
	namelen:    u32,
	iov:        [^]Iovec,
	iovlen:     i32,
	_:          i32,
	control:    rawptr,
	controllen: u32,
	_:          i32,
	flags:      i32,
}
#assert(size_of(Msghdr) == 56)
#assert(offset_of(Msghdr, iov) == 16)
#assert(offset_of(Msghdr, iovlen) == 24)
#assert(offset_of(Msghdr, control) == 32)
#assert(offset_of(Msghdr, controllen) == 40)
#assert(offset_of(Msghdr, flags) == 48)

// struct sockaddr_in: the port and address in network order.
Sockaddr_In :: struct {
	family: u16,
	port:   u16be,
	addr:   u32be,
	_:      [8]u8,
}
#assert(size_of(Sockaddr_In) == 16)

Pollfd :: struct {
	fd:      i32,
	events:  Poll_Events,
	revents: Poll_Events,
}
#assert(size_of(Pollfd) == 8)

Fd_Set :: struct {
	bits: [FD_SETSIZE / 64]u64,
}
#assert(size_of(Fd_Set) == 128)

// posix_spawnattr_t and posix_spawn_file_actions_t (spawn.h), and a file
// action (musl's struct fdop, src/process/fdop.h): a list, newest first.
Spawnattr :: struct {
	flags:    i32,
	pgrp:     i32,
	def:      [128]u8, // sigset_t: the first word is the signals
	mask:     [128]u8,
	prio:     i32,
	pol:      i32,
	fn:       rawptr, // posix_spawnp sets it
	_:        [56]u8,
}
#assert(size_of(Spawnattr) == 336)
#assert(offset_of(Spawnattr, pgrp) == 4)
#assert(offset_of(Spawnattr, def) == 8)
#assert(offset_of(Spawnattr, mask) == 136)
#assert(offset_of(Spawnattr, fn) == 272)

Spawn_File_Actions :: struct {
	_:       [2]i32,
	actions: ^Fdop,
	_:       [16]i32,
}
#assert(size_of(Spawn_File_Actions) == 80)
#assert(offset_of(Spawn_File_Actions, actions) == 8)

Fdop :: struct {
	next, prev:              ^Fdop,
	cmd, fd, srcfd, oflag:   i32,
	mode:                    u32,
	// path follows: a C string
}
FDOP_PATH :: 36 // path's offset
#assert(offset_of(Fdop, cmd) == 16)
#assert(offset_of(Fdop, mode) == 32)

// The target's.
when ODIN_ARCH == .amd64 {
	Sys :: Sys_Amd64
	Stat :: Stat_Amd64
	Ucontext :: Ucontext_Amd64
	MACHINE :: "x86_64"
} else {
	Sys :: Sys_Arm64
	Stat :: Stat_Arm64
	Ucontext :: Ucontext_Arm64
	MACHINE :: "aarch64"
}
