// lib/shared, upstream's <vx/shared.h>, from its tests/host/shared_test.c:
// offsets inside a VMO's bounds and aligned, none whose sum wraps, arrays
// checked whole, and links between VMOs through the table at the head: a
// slot past the table, a position past the message's handles and an offset
// past the VMO it names all refused.
package shared_test

import "core:testing"
import "vx:shared"

Node :: struct {
	next:  u64, // an offset, 0 for none
	value: u32,
	pad:   u32,
}

// Two VMOs as a reader mapped them, aligned as a mapping is.
Views :: struct #align (16) {
	a: [256]u8,
	b: [64]u8,
}

// Whether the bytes are at want.
starts_at :: proc(bytes: []u8, ok: bool, want: ^u8) -> bool {
	return ok && raw_data(bytes) == want
}

@(test)
test_offsets :: proc(t: ^testing.T) {
	@(static) v: Views
	sa := v.a[:]
	testing.expect_value(t, shared.at_as(sa, 0, Node), cast(^Node)&v.a[0])
	testing.expect_value(t, shared.at_as(sa, 240, Node), cast(^Node)&v.a[240])
	testing.expect_value(t, shared.at_as(sa, 248, Node), nil) // runs past the end
	testing.expect_value(t, shared.at_as(sa, 4, Node), nil) // misaligned
	testing.expect_value(t, shared.at_as(sa, max(u64) - 7, Node), nil) // a sum that would wrap
	_, ok := shared.at(sa, 257, 0, 1)
	testing.expect(t, !ok) // past the end
	_, ok = shared.at(sa, 256, 0, 1)
	testing.expect(t, ok) // the end itself, empty
	_, ok = shared.at(nil, 0, 1, 1)
	testing.expect(t, !ok)
	_, ok = shared.array(sa, 0, 16, size_of(Node), align_of(Node))
	testing.expect(t, ok)
	_, ok = shared.array(sa, 0, 17, size_of(Node), 8)
	testing.expect(t, !ok)
	_, ok = shared.array(sa, 0, max(u64) / 2, 4, 4)
	testing.expect(t, !ok) // n * each would wrap
}

@(test)
test_list :: proc(t: ^testing.T) {
	// A list: followed node by node, each link checked; a bad one stops it.
	@(static) v: Views
	sa := v.a[:]
	n0, n1, n2 := cast(^Node)&v.a[0], cast(^Node)&v.a[64], cast(^Node)&v.a[128]
	n0^ = {next = 64, value = 1}
	n1^ = {next = 128, value = 2}
	n2^ = {next = 0, value = 3}
	sum, hops: u32
	for n := shared.at_as(sa, 0, Node); n != nil && hops < 8; hops += 1 {
		sum += n.value
		n = n.next != 0 ? shared.at_as(sa, n.next, Node) : nil
	}
	testing.expect_value(t, sum, 6)
	testing.expect_value(t, hops, 3)
	n1.next = 1000 // out of bounds: refused, not followed
	testing.expect_value(t, shared.at_as(sa, n1.next, Node), nil)
}

@(test)
test_links :: proc(t: ^testing.T) {
	// Links between VMOs: a's table names message positions 1 and 0.
	@(static) v: Views
	sa, sb := v.a[:], v.b[:]
	table := cast(^shared.Table)&v.a[0]
	positions := cast(^[2]u32)&v.a[4]
	table.count, positions[0], positions[1] = 2, 1, 0
	copy(v.b[16:], "hello\x00")
	views := [2][]u8{sa, sb}
	b, ok := shared.follow(sa, views[:], {slot = 0, offset = 16}, 6, 1)
	testing.expect(t, starts_at(b, ok, &v.b[16]))
	b, ok = shared.follow(sa, views[:], {slot = 1, offset = 16}, 6, 1)
	testing.expect(t, starts_at(b, ok, &v.a[16]))
	_, ok = shared.follow(sa, views[:], {slot = 2, offset = 0}, 1, 1)
	testing.expect(t, !ok) // past the table
	_, ok = shared.follow(sa, views[:1], {slot = 0, offset = 0}, 1, 1)
	testing.expect(t, !ok) // past the handles
	_, ok = shared.follow(sa, views[:], {slot = 0, offset = 60}, 6, 1)
	testing.expect(t, !ok) // past b
	_, ok = shared.follow(sa, views[:], {slot = 0, reserved = 1}, 1, 1)
	testing.expect(t, !ok) // not 0
	table.count = 1_000_000 // a table longer than its VMO
	_, ok = shared.follow(sa, views[:], {slot = 0, offset = 16}, 6, 1)
	testing.expect(t, !ok)
}
