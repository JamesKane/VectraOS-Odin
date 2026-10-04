// lib/mem, ported from upstream's tests/host/mem_test.c (which renames
// upstream's functions so the host C library keeps its own; nothing here
// has a C name, so nothing needs renaming).
package mem_test

import "core:testing"
import memory "vx:mem"

@(test)
test_mem :: proc(t: ^testing.T) {
	a: [31]u8
	copy(a[:], "0123456789abcdefghijklmnopqrstu")
	memory.move(a[4:], a[:10]) // forwards overlap
	testing.expect(t, string(a[:]) == "01230123456789efghijklmnopqrstu")
	memory.move(a[:], a[4:][:10]) // backwards overlap
	testing.expect(t, string(a[:10]) == "0123456789")

	b: [8]u8
	memory.set(b[:], 'x')
	testing.expect(t, b[0] == 'x' && b[7] == 'x')
	memory.copy_forward(b[:], transmute([]u8)string("hello"))
	testing.expect(t, memory.compare(b[:], transmute([]u8)string("helloxxx")) == 0)
	testing.expect(t, memory.compare({'a'}, {'b'}) < 0 && memory.compare({'b'}, {'a'}) > 0)
	testing.expect(t, memory.compare({0x80}, {0x01}) > 0) // bytes compare unsigned
	testing.expect(t, memory.compare(b[:0], b[:]) == 0)
}
