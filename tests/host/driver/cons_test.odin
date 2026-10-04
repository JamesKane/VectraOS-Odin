// lib/driver's console line discipline (cons_input) against upstream's
// vx-driver/cons.c at M4, which erases and kills whole runes and never splits
// one when a line fills (ADR-0013). Upstream has no host test of its own for
// it; upstream.txt is what upstream's vx_cons_input leaves for the same
// bytes (what reads get, where pieces end, the line, the echo), from a
// harness built with clang (the P4 cross-check), and each line here must
// match it.
//
// lib/driver imports lib/rt, so this file defines the symbols a program
// would (vx_main, vx_syscall); nothing here makes a system call.
package driver_test

import vx "abi:vx"
import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:driver"

UPSTREAM := #load("upstream.txt", string)

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	return 0
}

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	return i64(vx.Status.Err_Unsupported)
}

@(private="file")
no_room :: proc "contextless" (dev: rawptr) -> u32 {
	return 0
}

@(private="file")
no_byte :: proc "contextless" (dev: rawptr, b: u8) {}

@(private="file")
no_interrupt :: proc "contextless" (dev: rawptr, on: bool) {}

@(private="file")
run :: proc(b: ^strings.Builder, name: string, input: string) {
	c := new(driver.Cons)
	defer free(c)
	c.tx_room, c.tx_byte, c.tx_wanted = no_room, no_byte, no_interrupt
	for x in transmute([]u8)input {
		driver.cons_input(c, x)
	}
	fmt.sbprintf(b, "%s in=", name)
	for i := c.input.head; i != c.input.tail; i += 1 {
		fmt.sbprintf(b, "%02x", c.input.data[i % len(c.input.data)])
	}
	fmt.sbprint(b, " pieces=")
	for i := c.ends_head; i != c.ends_tail; i += 1 {
		fmt.sbprintf(b, "%d,", c.ends[i % len(c.ends)])
	}
	fmt.sbprintf(b, " line=%d out=", c.line_len)
	for i := c.out.head; i != c.out.tail; i += 1 {
		fmt.sbprintf(b, "%02x", c.out.data[i % len(c.out.data)])
	}
	fmt.sbprintln(b)
}

@(test)
test_against_upstream :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	run(&b, "ascii", "ab\b\x7fcd\r")
	run(&b, "rune-erase", "\xc3\xa9\x7f\r") // é, erased: one rune, one "\b \b"
	run(&b, "euro-kill", "x\xe2\x82\xac\xf0\x9f\x98\x80\x15y\r") // ^U takes back x € 😀 rune by rune
	run(&b, "bad-erase", "a\x80\x7f\r") // a stray byte is a rune of its own
	run(&b, "eof", "\x04ab\x04")
	// A full line ends at the last whole rune that fits; a rune it would have
	// split starts the next line.
	run(&b, "full-split", strings.concatenate({strings.repeat("a", 254, context.temp_allocator), "\xc3\xa9z\r"}, context.temp_allocator))
	run(&b, "full-4", strings.concatenate({strings.repeat("a", 253, context.temp_allocator), "\xf0\x9f\x98\x80\r"}, context.temp_allocator))
	run(&b, "full-ascii", strings.concatenate({strings.repeat("b", 300, context.temp_allocator), "\r"}, context.temp_allocator))
	run(&b, "full-bad", strings.concatenate({strings.repeat("a", 254, context.temp_allocator), "\x80q\r"}, context.temp_allocator))
	got, want := strings.to_string(b), UPSTREAM
	line := 0
	for {
		gl, gok := strings.split_lines_iterator(&got)
		wl, wok := strings.split_lines_iterator(&want)
		line += 1
		if !gok && !wok {
			break
		}
		if !testing.expectf(t, gl == wl, "line %d: got %q, upstream has %q", line, gl, wl) {
			break
		}
	}
}
