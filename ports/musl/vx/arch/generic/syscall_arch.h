/* syscall_arch.h: VectraOS's replacement for musl's arch/<arch>/syscall_arch.h
 * (ADR-0007). tools/build puts this directory first on musl's include path,
 * so musl's tree stays as released.
 *
 * musl asks for every kernel service by Linux system-call number through
 * __syscall0 ... __syscall6. Each is a call to __vx_syscall, the entry of the
 * back end (ports/musl/vx, in Odin), which does the work with VectraOS's own
 * calls and servers. Numbers and results are Linux's: a result in
 * [-4095, -1] is -errno. No logic belongs here.
 *
 * Compiled as part of musl, so it is musl's C99. */

/* 64-bit arguments fit in one register on both architectures. */
#define __SYSCALL_LL_E(x) (x)
#define __SYSCALL_LL_O(x) (x)

hidden long __vx_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6);

static __inline long __syscall0(long n)
{
	return __vx_syscall(n, 0, 0, 0, 0, 0, 0);
}

static __inline long __syscall1(long n, long a1)
{
	return __vx_syscall(n, a1, 0, 0, 0, 0, 0);
}

static __inline long __syscall2(long n, long a1, long a2)
{
	return __vx_syscall(n, a1, a2, 0, 0, 0, 0);
}

static __inline long __syscall3(long n, long a1, long a2, long a3)
{
	return __vx_syscall(n, a1, a2, a3, 0, 0, 0);
}

static __inline long __syscall4(long n, long a1, long a2, long a3, long a4)
{
	return __vx_syscall(n, a1, a2, a3, a4, 0, 0);
}

static __inline long __syscall5(long n, long a1, long a2, long a3, long a4, long a5)
{
	return __vx_syscall(n, a1, a2, a3, a4, a5, 0);
}

static __inline long __syscall6(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
	return __vx_syscall(n, a1, a2, a3, a4, a5, a6);
}

/* No vDSO (VDSO_USEFUL stays undefined): clock_gettime is a call like any
 * other. System V IPC uses the 64-bit structures without the IPC_64 flag, as
 * on both architectures' Linux. */
#define IPC_64 0
