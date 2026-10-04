package fs

import "base:intrinsics"
import vx "abi:vx"

// Memory from the caller's Mem, and the growable arrays the library keeps
// in it. Nothing is allocated any other way.

// The first error is the volume's, and sticks: nothing more is written after
// it. Returns false, so a failing path can say `return fail(fs, ...)`.
fail :: proc "contextless" (fs: ^Fs, st: vx.Status) -> bool {
	if fs.err == .Ok {
		fs.err = st
	}
	return false
}

// n zeroed Ts from the caller's memory; NO_MEMORY (sticky) if there is none.
// n == 0 gives an empty slice, which is not an error.
mem_new :: proc "contextless" ($T: typeid, fs: ^Fs, n: int) -> (s: []T, ok: bool) {
	if n <= 0 {
		return nil, n == 0
	}
	size, overflow := intrinsics.overflow_mul(n, size_of(T))
	p: rawptr
	if !overflow && fs.mem.alloc != nil {
		p = fs.mem.alloc(fs.mem.ctx, size)
	}
	if p == nil {
		fail(fs, .Err_No_Memory)
		return nil, false
	}
	intrinsics.mem_zero(p, size)
	return ([^]T)(p)[:n], true
}

mem_release :: proc "contextless" (fs: ^Fs, s: []$T) {
	if s != nil && fs.mem.free != nil {
		fs.mem.free(fs.mem.ctx, raw_data(s), len(s) * size_of(T))
	}
}

// An array and its count, in the caller's memory, grown by doubling.
Vec :: struct($T: typeid) {
	buf: []T, // its capacity
	n:   int,
}

items :: #force_inline proc "contextless" (v: ^Vec($T)) -> []T {
	return v.buf[:v.n]
}

// Room for one more; false (NO_MEMORY) if there is none.
vec_grow :: proc "contextless" (fs: ^Fs, v: ^Vec($T)) -> bool {
	if v.n < len(v.buf) {
		return true
	}
	if len(v.buf) > int(max(u32) / 2) { // doubling would pass upstream's 32-bit count (M5 step 10)
		return fail(fs, .Err_No_Memory)
	}
	more := mem_new(T, fs, len(v.buf) == 0 ? 16 : 2 * len(v.buf)) or_return
	copy(more, v.buf[:v.n])
	mem_release(fs, v.buf)
	v.buf = more
	return true
}

vec_push :: proc "contextless" (fs: ^Fs, v: ^Vec($T), x: T) -> bool {
	vec_grow(fs, v) or_return
	v.buf[v.n] = x
	v.n += 1
	return true
}

// x at index i, the rest moved up.
vec_insert :: proc "contextless" (fs: ^Fs, v: ^Vec($T), i: int, x: T) -> bool {
	vec_grow(fs, v) or_return
	copy(v.buf[i + 1:v.n + 1], v.buf[i:v.n])
	v.buf[i] = x
	v.n += 1
	return true
}

vec_remove :: proc "contextless" (v: ^Vec($T), i: int) {
	copy(v.buf[i:v.n - 1], v.buf[i + 1:v.n])
	v.n -= 1
}

vec_free :: proc "contextless" (fs: ^Fs, v: ^Vec($T)) {
	mem_release(fs, v.buf)
	v^ = {}
}
