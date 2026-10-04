// lib/memory: byte views and page rounding.
package memory_test

import "core:testing"
import "vx:memory"

@(test)
test_ptr_to_bytes :: proc(t: ^testing.T) {
	Header :: struct {
		a: u32le,
		b: u16le,
		c: u8,
		d: u8,
	}
	#assert(size_of(Header) == 8)
	h := Header{a = 0x0403_0201, b = 0x0605, c = 7, d = 8}
	b := memory.ptr_to_bytes(&h)
	testing.expect_value(t, len(b), 8)
	for v, i in b {
		testing.expect_value(t, v, u8(i + 1))
	}
	b[6] = 70 // a view, not a copy
	testing.expect_value(t, h.c, 70)
}

@(test)
test_page_round :: proc(t: ^testing.T) {
	Case :: struct {
		n, want: u64,
		ok:      bool,
	}
	cases := []Case {
		{0, 0, true},
		{1, 4096, true},
		{4095, 4096, true},
		{4096, 4096, true},
		{4097, 8192, true},
		{max(u64) - 4095, max(u64) - 4095, true}, // the last page-aligned value
		{max(u64) - 4094, 0, false}, // rounding up would wrap
		{max(u64), 0, false},
	}
	for c in cases {
		got, ok := memory.page_round(c.n)
		testing.expect_value(t, ok, c.ok)
		if c.ok {
			testing.expect_value(t, got, c.want)
		}
	}
	testing.expect_value(t, memory.page_trunc(0x1fff), 0x1000)
	testing.expect_value(t, memory.page_trunc(0x2000), 0x2000)
}
