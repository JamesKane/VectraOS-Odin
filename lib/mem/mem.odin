// Upstream's vx-mem: memset, memcpy, memmove and memcmp, the four functions a
// C compiler may call even in freestanding code, linked into the kernel and
// vx-rt under those names.
//
// In Odin that role belongs to base:runtime: with -no-crt it defines memset,
// memcpy and memmove (and bzero) itself, with strong linkage, and Odin never
// calls memcmp. So this package exports nothing under a C name, which would
// collide with the runtime's; it keeps upstream's four operations, on slices,
// for code that wants them by name. The package is `memory`, not `mem`,
// because package names must be unique and core:mem (which core:testing
// imports) has that one.
//
// Imports nothing, so the kernel, user space and host tools share it.
package memory

// Sets every byte of dst to c.
set :: proc "contextless" (dst: []u8, c: u8) {
	for &b in dst {
		b = c
	}
}

// Copies src to the start of dst, front to back; dst must be at least as
// long. The two must not overlap; use move if they may.
copy_forward :: proc "contextless" (dst, src: []u8) {
	d := dst[:len(src)]
	for i in 0 ..< len(src) {
		d[i] = src[i]
	}
}

// Copies src to the start of dst, which must be at least as long, whether or
// not they overlap.
move :: proc "contextless" (dst, src: []u8) {
	d := dst[:len(src)]
	if raw_data(d) < raw_data(src) {
		for i in 0 ..< len(src) {
			d[i] = src[i]
		}
	} else {
		for i := len(src); i > 0; i -= 1 {
			d[i - 1] = src[i - 1]
		}
	}
}

// Compares the first len(a) bytes of a and b, which must be at least as
// long, as unsigned bytes: the difference at the first byte that differs, or
// 0 if none does.
compare :: proc "contextless" (a, b: []u8) -> int {
	y := b[:len(a)]
	for i in 0 ..< len(a) {
		if a[i] != y[i] {
			return int(a[i]) - int(y[i])
		}
	}
	return 0
}
