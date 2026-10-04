// What the suites share: the fixtures, an index built from one, and a target
// that reads the fixture's loaded segments and a stack laid out by the test.
//
// Upstream's debug_test.c and eval_test.c index themselves through
// /proc/self/exe, which a macOS host cannot do. Here the fixtures stand in:
// fixtures/fixture.c holds those tests' fixtures and is built as upstream
// builds its host tests, and fixtures/odin is an Odin program built as
// ./build builds one (fixtures/make.sh). What upstream's tests know from
// the inside (&fixture_add, __LINE__, a frame's variables) these know from
// the fixture's symbols and lines, which the tables below record.
package debug_test

import "core:testing"
import "vx:debug"

C_X86_64 :: #load("fixtures/c-x86_64.elf")
C_AARCH64 :: #load("fixtures/c-aarch64.elf")
ODIN_X86_64 :: #load("fixtures/odin-x86_64.elf")
ODIN_AARCH64 :: #load("fixtures/odin-aarch64.elf")

// The arena the tests build in (upstream's take 256 MiB, which no fixture
// here needs), and the fuzzer's (8 MiB).
ARENA_SIZE :: 16 << 20
FUZZ_ARENA_SIZE :: 8 << 20

// An index of image, with the arena it lives in.
Fixture :: struct {
	image: []u8,
	elf:   debug.Elf,
	arena: []u8,
	index: []u8,
	ix:    debug.Index,
}

open_fixture :: proc(t: ^testing.T, image: []u8, f: ^Fixture, loc := #caller_location) -> bool {
	f.image = image
	ok: bool
	f.elf, ok = debug.elf_open(image)
	if !testing.expect(t, ok, "the fixture is an ELF image", loc = loc) {
		return false
	}
	f.arena = make([]u8, ARENA_SIZE)
	arena := debug.Arena {
		buf = f.arena,
	}
	f.index, ok = debug.build_index(&f.elf, &arena)
	if !testing.expect(t, ok, "the fixture is indexed", loc = loc) {
		return false
	}
	f.ix, ok = debug.open(f.index)
	return testing.expect(t, ok, "its index opens", loc = loc)
}

close_fixture :: proc(f: ^Fixture) {
	delete(f.arena)
}

// --- The target ---

STACK_BASE :: 0x7fff_0000
STACK_SIZE :: 4096

// The program as a debugger sees it: the fixture's loaded segments (what a
// crash directory leaves to the image, read with debug.image_read), a stack,
// and the innermost frame's registers.
Program :: struct {
	image:    []u8,
	stack:    [STACK_SIZE]u8,
	regs:     [64]u64,
	have_reg: [64]bool,
	reads:    int,
}

program_read :: proc "contextless" (data: rawptr, addr: u64, buf: []u8) -> bool {
	p := (^Program)(data)
	p.reads += 1
	n := u64(len(buf))
	if addr >= STACK_BASE && addr - STACK_BASE <= STACK_SIZE && n <= STACK_SIZE - (addr - STACK_BASE) {
		copy(buf, p.stack[addr - STACK_BASE:][:n])
		return true
	}
	return debug.image_read(p.image, addr, buf)
}

program_reg :: proc "contextless" (data: rawptr, dwarf: u32) -> (u64, bool) {
	p := (^Program)(data)
	if dwarf >= len(p.regs) || !p.have_reg[dwarf] {
		return 0, false
	}
	return p.regs[dwarf], true
}

// n bytes of v, little-endian, at addr on the stack.
put :: proc(p: ^Program, addr: u64, n: int, v: u64) {
	for i in 0 ..< n {
		p.stack[addr - STACK_BASE + u64(i)] = u8(v >> (8 * uint(i)))
	}
}

set_reg :: proc(p: ^Program, r: u32, v: u64) {
	p.regs[r] = v
	p.have_reg[r] = true
}

target_of :: proc(p: ^Program, machine: debug.Machine) -> debug.Target {
	return debug.Target{data = p, machine = machine, read = program_read, reg = program_reg}
}

// A frame as the tests expect it: its pc, sp and fp, and the function and
// line its lookup pc is in.
Want_Frame :: struct {
	pc, sp, fp: u64,
	func:       string,
	line:       u32,
}

expect_frames :: proc(t: ^testing.T, ix: ^debug.Index, got: []debug.Frame, want: []Want_Frame, loc := #caller_location) {
	testing.expect_value(t, len(got), len(want), loc = loc)
	for &f, i in got[:min(len(got), len(want))] {
		w := want[i]
		testing.expectf(t, f.pc == w.pc && f.sp == w.sp && f.fp == w.fp, "frame %d: pc %x sp %x fp %x, want %x %x %x", i, f.pc, f.sp, f.fp, w.pc, w.sp, w.fp, loc = loc)
		testing.expect_value(t, f.inner, i == 0, loc = loc)
		pc := debug.frame_lookup_pc(&f)
		name := "??"
		if fn, ok := debug.func_at(ix, pc); ok {
			name = debug.str(ix, fn.name)
		}
		testing.expectf(t, name == w.func, "frame %d: in %s, want %s", i, name, w.func, loc = loc)
		line: u32
		if l, ok := debug.line_at(ix, pc); ok {
			line = l.line
		}
		testing.expectf(t, line == w.line, "frame %d: line %d, want %d", i, line, w.line, loc = loc)
	}
}

// An expression at a frame, and what it should print, or the reason it
// fails ("! reason").
Eval_Case :: struct {
	text: string,
	want: string,
}

// Evaluates each case at f in one session, as dbg's print does at a frame.
expect_evals :: proc(t: ^testing.T, ix: ^debug.Index, tg: ^debug.Target, f: ^debug.Frame, cases: []Eval_Case, cap := 256, loc := #caller_location) {
	s := debug.begin(ix, tg, f)
	for c in cases {
		out: [1024]u8
		got: string
		if v, ok := debug.eval(&s, c.text); ok {
			got = debug.format(&s, v, out[:min(cap, len(out))])
		} else {
			testing.expectf(t, s.err != "", "eval %q failed without a reason", c.text, loc = loc)
			got = fmt_err(out[:], s.err)
		}
		testing.expectf(t, got == c.want, "eval %q: got %q, want %q", c.text, got, c.want, loc = loc)
	}
}

@(private = "file")
fmt_err :: proc(buf: []u8, err: string) -> string {
	buf[0], buf[1] = '!', ' '
	n := copy(buf[2:], err)
	return string(buf[:2 + n])
}
