// vx:memory, raw views of memory and page arithmetic: the two things from
// core:mem that code without a context still needs. The package is `memory`,
// not `mem`, because package names must be unique and core:mem (which
// core:testing imports) has that one.
//
// Imports nothing beyond the language, so the kernel, user space and host
// tools share it.
//
// Its arch/ARCH/mem.S is upstream's vx-mem (M6 step 6c2): memcpy, memset,
// memmove and memcmp, by words (and the string instructions on x86_64),
// which the build assembles into the kernel and every native program in
// place of the Odin runtime's byte loops (tools/build/kernel.odin). They are
// what Odin's copy and mem_zero, LLVM's calls and the native ports' C reach.
// ktest's test_mem checks them against byte references on the target.
package memory

import "base:intrinsics"

PAGE_SIZE :: 4096

// The bytes of the value p points to, for writing a wire struct into a
// message or reading one out of it. The struct's layout is the wire format,
// so it must be one an #assert pins down.
ptr_to_bytes :: #force_inline proc "contextless" (p: ^$T) -> []u8 {
	return ([^]u8)(p)[:size_of(T)]
}

// n rounded up to a whole number of pages; ok is false if that overflows,
// which a size from another task can make it do.
page_round :: proc "contextless" (n: u64) -> (rounded: u64, ok: bool) {
	up, overflow := intrinsics.overflow_add(n, PAGE_SIZE - 1)
	return up &~ (PAGE_SIZE - 1), !overflow
}

// n rounded down to the start of its page.
page_trunc :: proc "contextless" (n: u64) -> u64 {
	return n &~ (PAGE_SIZE - 1)
}
