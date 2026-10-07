// lib/note against upstream's vx-note. Upstream has no host test of its own
// for it; upstream.txt is what upstream's vx_trap_note and vx_note_buf print
// for the same inputs, from a harness built with clang against M5's headers
// (the P4 cross-check; the trap lines made again at M5, for .Pager_Timeout,
// and at upstream's f9c14e9, for .Protection_Key), and each line here must
// match it. At f9c14e9 upstream's protection-key words are cut to "sys: tr"
// (VX_STR of a conditional: the size of a pointer; UPSTREAM-FINDINGS): the
// oracle was built with that one line mended, so these lines are its words
// as meant, and as upstream's fix (6319e48) gives them.
package note_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:note"

UPSTREAM := #load("upstream.txt", string)

expect_lines :: proc(t: ^testing.T, got: string, want: string, loc := #caller_location) {
	g, w := got, want
	line := 0
	for {
		gl, gok := strings.split_lines_iterator(&g)
		wl, wok := strings.split_lines_iterator(&w)
		line += 1
		if !gok && !wok {
			return
		}
		if !testing.expectf(t, gl == wl, "line %d: got %q, upstream has %q", line, gl, wl, loc = loc) {
			return
		}
	}
}

@(test)
test_against_upstream :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	// Trap notes: every kind, each fault code.
	for kind in u32(0) ..= 12 {
		for code in u32(0) ..= 3 {
			out: [note.ERRMAX]u8
			pc := kind != 0 ? 0x401000 * u64(kind) : 0
			s := note.trap_note(note.Trap(kind), code, 0xdeadbeef000 + u64(code), pc, &out)
			fmt.sbprintf(&b, "trap %d %d %s\n", kind, code, s)
		}
	}
	// A cut note: nothing after the cut is kept, and runes stay whole.
	for c in 0 ..= 12 {
		small: [16]u8
		nb := note.Buf {
			buf = small[:c],
		}
		note.put(&nb, "ab\xc3\xa9")
		note.put_dec(&nb, 42)
		note.put(&nb, "\xe2\x82\xac")
		note.put_hex(&nb, 0xff)
		fmt.sbprintf(&b, "cut %d %d [%s]\n", c, nb.len, note.to_string(&nb))
	}
	expect_lines(t, strings.to_string(b), UPSTREAM)
}

@(test)
test_trap_note :: proc(t: ^testing.T) {
	out: [note.ERRMAX]u8
	testing.expect_value(t, note.trap_note(.Page_Fault, 0, 0, 0x401000, &out), "sys: trap: fault read addr=0x0 pc=0x401000")
	testing.expect_value(t, note.trap_note(.Illegal, 0, 0, 0x401000, &out), "sys: trap: illegal instruction pc=0x401000")
	testing.expect_value(t, note.trap_note(.Breakpoint, 0, 0, 0x10, &out), "sys: breakpoint pc=0x10")
}

// Upstream's note_test.c: a trap's note for the kinds whose words depend on
// the code: a protection key's read and write (ADR-0035), once cut to
// "sys: tr" (VX_STR of a conditional, the Odin port's finding), and a page
// fault's.
@(test)
test_code_words :: proc(t: ^testing.T) {
	Case :: struct {
		kind: note.Trap,
		code: u32,
		want: string,
	}
	cases := []Case {
		{.Protection_Key, 1, "sys: trap: protection key write addr=0x1000"},
		{.Protection_Key, 0, "sys: trap: protection key read addr=0x1000"},
		{.Page_Fault, 1, "sys: trap: fault write addr=0x1000"},
	}
	for c in cases {
		out: [note.ERRMAX]u8
		got := note.trap_note(c.kind, c.code, 0x1000, 0x2000, &out)
		testing.expectf(t, strings.has_prefix(got, c.want), "%v %d: got %q, want %q first", c.kind, c.code, got, c.want)
	}
}
