package rt

import vx "abi:vx"

// The thread pointer (x86_64's FS base, aarch64's TPIDR_EL0), which the
// kernel keeps per thread (a C library's TLS), and FP/SIMD probes. The
// assembly is arch/*/thread.S.
foreign _ {
	vx_thread_word :: proc "c" () -> u64 ---
	vx_fp_probe_put :: proc "c" (v: u64, ctl: u32) ---
	vx_fp_probe_get :: proc "c" (ctl: ^u32) -> u64 ---
	vx_cycles :: proc "c" () -> u64 ---
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
