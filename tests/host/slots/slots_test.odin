// lib/slots. Upstream has no host test for lib/vx-slots (its scenarios test
// it through install and distd), so this one is a transcript: tables.txt holds
// tables separated by "%%" lines (two slots and a command line; three slots;
// a booting slot not in use; a previous slot not in use, dropped; a hash of
// the wrong length; a slot= naming no slot, read as the boot record, and a
// cmdline flag; a slot with no release; a slot's record repeated, a tree too
// long and a NUL in the command line; text that is not ndb; nothing), and
// upstream.txt what upstream's C makes of each (a clang-built oracle over
// lib/vx-slots/slots.c): the status, the table as print writes it, Limine's
// configuration, whether it fits in exactly as many bytes or one more, and
// the free slot. Added here: a table written, read back and written again.
package slots_test

import "core:fmt"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:ndb"
import "vx:slots"

TABLES :: #load("tables.txt", string)
UPSTREAM :: #load("upstream.txt", string)

// One table's transcript, in the oracle's format.
transcript :: proc(b: ^strings.Builder, text: string) {
	t := new(slots.Table)
	defer free(t)
	scratch := make([]u8, 1 << 16)
	defer delete(scratch)
	out := make([]u8, 1 << 16)
	defer delete(out)
	st := slots.parse(t, text, scratch)
	fmt.sbprintf(b, "status=%d\n", i32(st))
	if st == .Ok {
		w := ndb.Writer {
			buf = out,
		}
		ok := slots.print(t, &w)
		fmt.sbprintf(b, "print=%d\n%s", int(ok), ndb.written(&w))
		conf := make([]u8, 1 << 16)
		defer delete(conf)
		limine, _ := slots.limine(t, conf)
		n := len(limine)
		fmt.sbprintf(b, "limine=%d\n%s", n, limine)
		small, _ := slots.limine(t, conf[:n + 1])
		fits, _ := slots.limine(t, conf[:n + 2])
		fmt.sbprintf(b, "limine cap n+1=%d n+2=%d\n", len(small), len(fits))
		free_slot, has := slots.free_slot(t)
		fmt.sbprintf(b, "free=%d\n", has ? int(free_slot) : -1)
	}
	strings.write_string(b, "%%\n")
}

@(test)
test_upstream_transcript :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	rest := TABLES
	cases := 0
	for {
		end := strings.index(rest, "%%\n")
		if end < 0 {
			break
		}
		transcript(&b, rest[:end])
		rest = rest[end + 3:]
		cases += 1
	}
	testing.expect_value(t, cases, 10)
	got := strings.to_string(b)
	if got != UPSTREAM {
		// The first line that differs says more than two long strings.
		g, u := strings.split_lines(got, context.temp_allocator), strings.split_lines(UPSTREAM, context.temp_allocator)
		for i in 0 ..< min(len(g), len(u)) {
			if g[i] != u[i] {
				testing.expectf(t, false, "line %d: got %q, upstream %q", i + 1, g[i], u[i])
				return
			}
		}
		testing.expectf(t, false, "%d lines, upstream %d", len(g), len(u))
	}
}

// Upstream's slots_test.c (M6 step 6b): a table printed and read back the
// same, and one with a key slots(6) does not name, or no boot slot, refused.
@(test)
test_keys :: proc(t: ^testing.T) {
	s := new(slots.Table)
	defer free(s)
	back := new(slots.Table)
	defer free(back)
	sl := &s.slots[.A]
	sl.used = true
	sl.release = 7
	append(&sl.tree, "b2:ab")
	for &h in sl.hash {
		for _ in 0 ..< slots.HASH_HEX {
			append(&h, 'c')
		}
	}
	s.boot = .A
	append(&s.cmdline, "vx.skip=rc")
	text: [2048]u8
	w := ndb.Writer {
		buf = text[:],
	}
	testing.expect(t, slots.print(s, &w))
	written := ndb.written(&w)
	scratch: [4096]u8
	testing.expect_value(t, slots.parse(back, written, scratch[:]), vx.Status.Ok)
	testing.expect_value(t, back.boot, slots.Name.A)
	testing.expect_value(t, back.previous, nil)
	testing.expect(t, back.slots[.A].used)
	testing.expect_value(t, back.slots[.A].release, 7)
	testing.expect(t, !back.slots[.B].used)
	testing.expect_value(t, string(back.cmdline[:]), "vx.skip=rc")

	// A key slots(6) does not name, on the table's record.
	bad := fmt.tprintf("%s booted=a\n", written[:len(written) - 1])
	testing.expect_value(t, slots.parse(back, bad, scratch[:]), vx.Status.Err_Invalid)
	testing.expect_value(t, slots.parse(back, "boot=b previous=-\n", scratch[:]), vx.Status.Err_Invalid)
}

// Added here: a table made in code, written, read back, written again the same.
@(test)
test_round_trip :: proc(t: ^testing.T) {
	a := new(slots.Table)
	defer free(a)
	back := new(slots.Table)
	defer free(back)
	sl := &a.slots[.B]
	sl.used = true
	sl.release = 42
	append(&sl.tree, "b2:0000000000000000000000000000000000000000000000000000000000000000")
	for &h in sl.hash {
		for _ in 0 ..< slots.HASH_HEX {
			append(&h, 'e')
		}
	}
	a.boot = .B
	append(&a.cmdline, "vx.skip=gsh vx.quiet")
	first, second: [4096]u8
	w := ndb.Writer {
		buf = first[:],
	}
	testing.expect(t, slots.print(a, &w))
	scratch: [4096]u8
	testing.expect_value(t, slots.parse(back, ndb.written(&w), scratch[:]), vx.Status.Ok)
	testing.expect_value(t, back.boot, slots.Name.B)
	testing.expect_value(t, back.previous, nil)
	testing.expect_value(t, back.slots[.B].release, 42)
	testing.expect(t, !back.slots[.A].used)
	w2 := ndb.Writer {
		buf = second[:],
	}
	testing.expect(t, slots.print(back, &w2))
	testing.expect_value(t, ndb.written(&w2), ndb.written(&w))
	n, ok := slots.free_slot(back)
	testing.expect(t, ok)
	testing.expect_value(t, n, slots.Name.A)
	// With nothing booting, print refuses (upstream would write boot=`).
	back.boot = nil
	w3 := ndb.Writer {
		buf = second[:],
	}
	testing.expect(t, !slots.print(back, &w3))
}
