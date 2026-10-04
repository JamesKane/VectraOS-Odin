// lib/debug's unwinder, locations, expression evaluator and printer
// (upstream 05 §6.2): upstream's tests/host/eval_test.c, case for case, on
// the C fixture. Upstream's test stops in its own inspect, called from
// level3 <- level2 <- level1 <- main, and reads its own memory; here the
// fixture's frames are laid out on a stack as the program lays them out
// (fixtures/fixture.c's level functions are optnone, so their variables live
// in their frames), and the rest of memory is the fixture's loaded segments.
// The outputs are upstream's, from its C library run over the same target.
package debug_test

import "core:fmt"
import "core:testing"
import "vx:debug"

// The x86_64 fixture's frames: level3 <- level2 <- level1 <- main <- _start,
// each record at its frame pointer, the return address after it, and each
// function's variables at their DW_OP_fbreg offsets from it.
FP3 :: 0x7fff_0e00
FP2 :: 0x7fff_0e40
FP1 :: 0x7fff_0e80
FPM :: 0x7fff_0ec0
FPS :: 0x7fff_0ee0
HELLO :: 0x401004 // level1's "hello", in .rodata

c_x86_64_stack :: proc(p: ^Program) {
	put(p, FP3, 8, FP2)
	put(p, FP3 + 8, 8, 0x4000fa) // into level2, after its call to level3
	put(p, FP3 - 4, 4, 11) // c
	put(p, FP2, 8, FP1)
	put(p, FP2 + 8, 8, 0x40008f) // into level1
	put(p, FP2 - 8, 4, 10) // b
	put(p, FP2 - 16, 8, HELLO) // msg
	put(p, FP2 - 4, 4, 11) // local
	put(p, FP1, 8, FPM)
	put(p, FP1 + 8, 8, 0x40003c) // into main
	put(p, FP1 - 8, 4, 5) // a
	put(p, FP1 - 4, 4, 10) // doubled
	put(p, FPM, 8, FPS)
	put(p, FPM + 8, 8, 0x4000a9) // into _start, whose record ends the chain
}

C_LEVEL3_BODY :: 0x40011b

@(test)
test_eval :: proc(t: ^testing.T) {
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, C_X86_64, &f) {
		return
	}
	ix := &f.ix
	p := new(Program)
	defer free(p)
	p.image = f.image
	c_x86_64_stack(p)
	tg := target_of(p, .X86_64) // upstream's: machine 62, no registers
	tg.reg = nil

	// Called from level3, with its frame address: the innermost frame is level3's.
	l3, ok := debug.func_named(ix, "level3")
	if !testing.expect(t, ok) {
		return
	}
	testing.expect_value(t, l3.body, C_LEVEL3_BODY)
	buf: [16]debug.Frame
	frames := debug.unwind(ix, &tg, l3.body, 0, FP3, buf[:])
	names := []string{"level3", "level2", "level1", "main"}
	testing.expect(t, len(frames) >= 4)
	for &fr, i in frames[:min(len(frames), 4)] {
		fn, named := debug.func_at(ix, debug.frame_lookup_pc(&fr))
		testing.expectf(t, named && debug.str(ix, fn.name) == names[i], "frame %d: wanted %s", i, names[i])
		l, l_ok := debug.line_at(ix, debug.frame_lookup_pc(&fr))
		testing.expect(t, l_ok && debug.path_ends(debug.file(ix, l.file), "fixture.c"))
	}
	if len(frames) < 4 {
		return
	}
	expect_frames(t, ix, frames, {
		{C_LEVEL3_BODY, 0, FP3, "level3", 55},
		{0x4000fa, FP3 + 16, FP2, "level2", 61},
		{0x40008f, FP2 + 16, FP1, "level1", 66},
		{0x40003c, FP1 + 16, FPM, "main", 70},
		{0x4000a9, FPM + 16, FPS, "_start", 77},
	})

	// Each frame's variables, through its frame base.
	expect_evals(t, ix, &tg, &frames[0], {{"c", "11"}})
	expect_evals(t, ix, &tg, &frames[1], {{"b", "10"}, {"local", "11"}, {"msg[1]", "101 'e'"}, {"*msg", "104 'h'"}})
	expect_evals(t, ix, &tg, &frames[2], {
		{"a", "5"},
		{"doubled * 2 + a", "25"},
		{"local", "! no such variable"}, // level2's, not level1's
	})
	// Globals, from any frame.
	expect_evals(t, ix, &tg, &frames[0], {
		{"first.value", "1"},
		{"first.next->value", "2"},
		{"first.next->next", "0x0"},
		{"first.next->label", "0x40100a \"two\""},
		{"first", "{value = 1, next = 0x402020, label = 0x401000 \"one\"}"},
		{"(*first.next).value + 40", "42"},
		{"table[2]", "30"},
		{"table", "[10, 20, 30, 40, 50]"},
		{"*(&table[1])", "20"},
		{"&table[3] - &table[1]", "2"},
		{"*(table + 4)", "50"},
		{"sizeof(table)", "20"},
		{"sizeof table[0]", "4"},
		{"sizeof(struct node)", "24"},
		{"&table[0]", "0x402050"},
		{"letter", "120 'x'"},
		{"(char)65", "65 'A'"},
		{"flag", "true"},
		{"ratio", "1.5"},
		{"mode", "ON"},
		{"ON + 1", "2"},
		{"-3 * 4 + 20 / (2 + 3)", "-8"},
		{"7 % 4 == 3", "1"},
		{"1 << 4 | 1", "17"},
		{"!0 && 5 > 3", "1"},
		{"0x10 + 'a'", "113"},
		{"~0 & 0xff", "255"},
		{"(unsigned char)300", "44 ','"},
		{"$fp", fmt.tprint(u64(FP3))},
		// And what it refuses.
		{"nosuch", "! no such variable"},
		{"1 +", "! expected a value"},
		{"first.nope", "! no such member"},
		{"(1 + 2", "! unbalanced brackets"},
		{"1 / 0", "! division by zero"},
		{"9223372036854775808 / -1", "-9223372036854775808"}, // wraps, as C's would; not a trap
		{"9223372036854775808 % -1", "0"},
		{"*table[0]", "! not a pointer"},
		{"ratio + 1", "! floating-point arithmetic is not supported"},
		{"first + 1", "! not a number or pointer"},
		{"$nope", "! no such register"},
	})
}

// Beyond upstream's cases, on the same frames: narrow types, casts, pointer
// arithmetic, the lexer's and parser's refusals, the stacks' limits, a cut
// short output, and locations. The outputs are upstream's C library's.
@(test)
test_eval_more :: proc(t: ^testing.T) {
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, C_X86_64, &f) {
		return
	}
	ix := &f.ix
	p := new(Program)
	defer free(p)
	p.image = f.image
	c_x86_64_stack(p)
	tg := target_of(p, .X86_64)
	buf: [16]debug.Frame
	frames := debug.unwind(ix, &tg, C_LEVEL3_BODY, 0, FP3, buf[:])
	if !testing.expect_value(t, len(frames), 5) {
		return
	}
	expect_evals(t, ix, &tg, &frames[0], {
		{"widths", "{uc = 200, sc = -3, s = -2, us = 65535, f = 0.25, ll = -5}"},
		{"widths.uc", "200"},
		{"widths.sc", "-3"},
		{"widths.s", "-2"},
		{"widths.us", "65535"},
		{"widths.f", "0.25"},
		{"widths.ll", "-5"},
		{"widths.sc + widths.s", "-5"},
		{"widths.uc + widths.us", "65735"},
		{"-widths.us", "-65535"},
		{"-widths.sc", "3"},
		{"~widths.uc", "55 '7'"},
		{"(signed char)200", "-56"},
		{"(short)-1", "-1"},
		{"(unsigned short)-1", "65535"},
		{"(unsigned char)-1", "255"},
		{"(float)1", "0.0"}, // the bits, not the value: casts do not convert
		{"widths.f + 1", "! floating-point arithmetic is not supported"},
		{"sizeof(float)", "4"},
		{"sizeof(widths)", "24"},
		{"&widths.f", "0x402070"},
		{"*(float *)&widths.f", "0.25"},
		{"*(unsigned char *)&widths.s", "254"},
		{"*(signed char *)&widths.s", "-2"},
		{"origin", "{x = 1, y = 2, name = \"o\"}"},
		{"origin.name", "\"o\""},
		{"hue", "GREEN"},
		{"marker_line", "cannot read memory"}, // in .bss: not in the image
		{"&marker_line", "0x402080"},
		{"second.label", "0x40100a \"two\""},
		{"*first.next", "{value = 2, next = 0x0, label = 0x40100a \"two\"}"},
		{"first.next[0].value", "2"},
		{"&first.next->value", "0x402020"},
		{"(long)&table[1] - (long)table", "4"},
		{"-1 >> 1", "-1"},
		{"(unsigned long)-1 >> 60", "15"},
		{"5 - &table[0]", "! cannot subtract a pointer from a number"},
		{"&table[0] + &table[1]", "! cannot add two pointers"},
		{"sizeof(int *)", "8"},
		{"sizeof(unsigned long)", "8"},
		{"sizeof(long long)", "8"},
		{"(struct node *)0", "0x0"},
		{"*(struct node *)0", "{value = {...}, next = {...}, label = {...}}"},
		{"*(int *)0x401004", "1819043176"},
		{"*(char *)0x401004", "104 'h'"},
		{"(char *)0x401004", "0x401004 \"hello\""},
		{"\"x\"", "! unexpected character"},
		{"1 2", "! expected an operator"},
		{")", "! expected a value"},
		{"1 ]", "! unbalanced brackets"},
		{"[1]", "! expected a value"},
		{"table[1", "! unbalanced brackets"},
		{"first->value", "! not a number or pointer"},
		{"table.x", "! not a struct or union"},
		{"&1", "! not in memory: no address"},
		{"0x1g", "! unexpected character"},
		{"12abc", "! expected an operator"},
		{"'a", "! unexpected character"},
		{"$rip", "4194587"},
		{"$pc", "4194587"},
		{"$sp", "0"},
		{"$rbp", "2147421696"},
		{"$rax", "register not available"},
		{"$x1", "! no such register"},
		{"-ratio", "-4609434218613702656"},
		{"!ratio", "0"},
		{"ratio == 1", "! floating-point arithmetic is not supported"},
		{"mode == ON", "1"},
		{"GREEN", "GREEN"},
		{"RED + GREEN * 2", "10"},
		{"letter + 1", "121"},
		{"(char)letter", "120 'x'"},
		{"18446744073709551615 + 2", "1"},
		{"99999999999999999999", "7766279631452241919"},
		{"((((((((((((((((((((((((((((((((1))))))))))))))))))))))))))))))))", "1"},
		{"1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1+1", "34"},
		{"1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1*(1)))))))))))))))))))))))))))))))))", "! too complex"},
		{"----------------------------------------------------------------1", "1"},
		{"- - 1", "1"},
		{"+ 5", "5"},
		{"sizeof sizeof 1", "8"},
		{"sizeof(nosuchtype)", "! no such variable"},
		{"sizeof(first)", "24"},
		{"sizeof first", "24"},
		{"&first.next", "0x402040"},
		{"&&first", "! expected a value"},
		{"*&first", "{value = 1, next = 0x402020, label = 0x401000 \"one\"}"},
		{"(*&first).label", "0x401000 \"one\""},
		{"first\x00.nope", "{value = 1, next = 0x402020, label = 0x401000 \"one\"}"}, // a NUL ends the text, as in C
	})
	expect_evals(t, ix, &tg, &frames[3], {{"r", "! variable not available here"}}) // main's r: a list without this pc
	expect_evals(t, ix, &tg, &frames[4], {{"$fp", "2147421920"}})
	// Output cut short where the buffer ends, keeping its last byte as upstream's NUL.
	expect_evals(t, ix, &tg, &frames[0], {{"first", "{value = 1,"}, {"first.label", "0x401000 \"."}}, cap = 12)
	expect_evals(t, ix, &tg, &frames[0], {{"42", ""}}, cap = 1)
	expect_evals(t, ix, &tg, &frames[0], {{"42", ""}}, cap = 0)

	// Locations.
	Loc_Case :: struct {
		frame: int,
		name:  string,
		want:  debug.Location,
		ok:    bool,
	}
	locs := []Loc_Case {
		{0, "c", debug.Mem(FP3 - 4), true},
		{1, "msg", debug.Mem(FP2 - 16), true},
		{1, "local", debug.Mem(FP2 - 4), true},
		{1, "table", debug.Mem(0x402050), true},
		{1, "ratio", debug.Imm(0x3ff8000000000000), true}, // DW_AT_const_value
		{3, "r", nil, false},
	}
	for c in locs {
		fr := &frames[c.frame]
		pc := debug.frame_lookup_pc(fr)
		fn, _ := debug.func_at(ix, pc)
		v, found := debug.local_named(ix, fn, pc, c.name)
		if !found {
			v, found = debug.global_named(ix, c.name)
		}
		if !testing.expectf(t, found, "%s is a variable", c.name) {
			continue
		}
		l, ok := debug.location(ix, &tg, fr, fn, v)
		testing.expectf(t, ok == c.ok && (!ok || l == c.want), "location of %s: %v %v, want %v", c.name, l, ok, c.want)
	}

	// The session's pointer types: 32, then plain addresses.
	s := debug.begin(ix, &tg, &frames[0])
	for i in 0 ..< debug.MAX_POINTER_TYPES + 2 {
		_, ok := debug.eval(&s, i % 2 == 0 ? "&first" : "&table[0]")
		testing.expect(t, ok)
	}
	testing.expect_value(t, len(s.ptr_target), 2)
}

// The frame-pointer walk at its edges: a pc in its function's prologue, a
// chain that does not go up the stack, an fp misaligned, unreadable or 0, a
// pc no function holds, and fewer frames wanted than there are.
@(test)
test_unwind :: proc(t: ^testing.T) {
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, C_X86_64, &f) {
		return
	}
	ix := &f.ix
	p := new(Program)
	defer free(p)
	p.image = f.image
	c_x86_64_stack(p)
	tg := target_of(p, .X86_64)
	buf: [16]debug.Frame
	CHAIN :: []Want_Frame{{0x4000fa, 0, 0, "level2", 61}, {0x40008f, FP2 + 16, FP1, "level1", 66}, {0x40003c, FP1 + 16, FPM, "main", 70}, {0x4000a9, FPM + 16, FPS, "_start", 77}}

	// At level3's first instruction: sp holds the return address (0 here, so it stops).
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400110, FP3 + 0x10, FP2, buf[:]), {{0x400110, FP3 + 0x10, FP2, "level3", 54}})
	put(p, FP3 + 0x10, 8, 0x4000fa)
	want := [5]Want_Frame{{0x400110, FP3 + 0x10, FP2, "level3", 54}, CHAIN[0], CHAIN[1], CHAIN[2], CHAIN[3]}
	want[1].sp, want[1].fp = FP3 + 0x18, FP2
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400110, FP3 + 0x10, FP2, buf[:]), want[:])
	// Past push %rbp: sp holds the caller's fp, then the return address.
	put(p, FP3 + 0x18, 8, 0x4000fa)
	put(p, FP3 + 0x10, 8, FP2)
	want[0] = {0x400111, FP3 + 0x10, 0x7fff_0e99, "level3", 54}
	want[1].sp = FP3 + 0x20
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400111, FP3 + 0x10, 0x7fff_0e99, buf[:]), want[:])
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400111, FP3 + 0x10, 0x7fff_0e99, buf[:2]), want[:2])
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400111, FP3 + 0x10, 0x7fff_0e99, buf[:1]), want[:1])
	testing.expect_value(t, len(debug.unwind(ix, &tg, 0x400111, 0, 0, buf[:0])), 0)

	// At a function's first instruction with sp unreadable: no caller.
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400130, 0, 0x7fff_0f00, buf[:]), {{0x400130, 0, 0x7fff_0f00, "inspect", 52}})
	// A record whose caller's fp is below it: that frame, then no more.
	put(p, 0x7fff_0f00, 8, FP3)
	put(p, 0x7fff_0f08, 8, 0x400040)
	expect_frames(t, ix, debug.unwind(ix, &tg, C_LEVEL3_BODY, 0, 0x7fff_0f00, buf[:]), {{C_LEVEL3_BODY, 0, 0x7fff_0f00, "level3", 55}, {0x400040, 0x7fff_0f10, FP3, "main", 72}})
	expect_frames(t, ix, debug.unwind(ix, &tg, C_LEVEL3_BODY, 0, FP3 + 1, buf[:]), {{C_LEVEL3_BODY, 0, FP3 + 1, "level3", 55}})
	expect_frames(t, ix, debug.unwind(ix, &tg, C_LEVEL3_BODY, 0, 0x10, buf[:]), {{C_LEVEL3_BODY, 0, 0x10, "level3", 55}})
	expect_frames(t, ix, debug.unwind(ix, &tg, C_LEVEL3_BODY, 0, 0, buf[:]), {{C_LEVEL3_BODY, 0, 0, "level3", 55}})
	far := [5]Want_Frame{{0x500000, 0, FP3, "??", 0}, CHAIN[0], CHAIN[1], CHAIN[2], CHAIN[3]}
	far[1].sp, far[1].fp = FP3 + 16, FP2
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x500000, 0, FP3, buf[:]), far[:])
}

// The aarch64 fixture: frame records at x29, the link register in the
// prologue, $xN registers, and (upstream's limit) SP-relative locals of an
// outer frame, read where its sp would be if it had no locals.
@(test)
test_eval_aarch64 :: proc(t: ^testing.T) {
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, C_AARCH64, &f) {
		return
	}
	ix := &f.ix
	p := new(Program)
	defer free(p)
	p.image = f.image
	put(p, FP3, 8, FP2)
	put(p, FP3 + 8, 8, 0x400104)
	put(p, FP3 - 4, 4, 11) // c
	put(p, FP2, 8, FP1)
	put(p, FP2 + 8, 8, 0x4000ac)
	put(p, FP2 - 4, 4, 10) // b
	put(p, FP2 - 16, 8, HELLO) // msg, at sp + 16 in a frame whose sp is x29 - 32
	put(p, FP2 - 20, 4, 11) // local, at sp + 12
	put(p, FP1, 8, FPM)
	put(p, FP1 + 8, 8, 0x400040)
	put(p, FP1 - 4, 4, 5) // a
	put(p, FP1 - 8, 4, 10) // doubled, at sp + 8
	put(p, FPM, 8, FPS)
	put(p, FPM + 8, 8, 0x4000c4)
	set_reg(p, 31, FP3 - 0x10)
	set_reg(p, 29, FP3)
	set_reg(p, 30, 0x400104)
	set_reg(p, 0, 11)
	tg := target_of(p, .AArch64)
	buf: [16]debug.Frame
	frames := debug.unwind(ix, &tg, 0x40012c, FP3 - 0x10, FP3, buf[:])
	expect_frames(t, ix, frames, {
		{0x40012c, FP3 - 0x10, FP3, "level3", 55},
		{0x400104, FP3 + 16, FP2, "level2", 61},
		{0x4000ac, FP2 + 16, FP1, "level1", 66},
		{0x400040, FP1 + 16, FPM, "main", 70},
		{0x4000c4, FPM + 16, FPS, "_start", 77},
	})
	if len(frames) != 5 {
		return
	}
	expect_evals(t, ix, &tg, &frames[0], {
		{"c", "11"},
		{"$x0", "11"},
		{"$x30", "4194564"},
		{"$x31", "! no such register"},
		{"$x007", "register not available"},
		{"$x4294967296", "11"}, // the number wraps, as upstream's does: x0
		{"$sp", "2147421680"},
		{"$fp", "2147421696"},
		{"$pc", "4194604"},
		{"$rax", "! no such register"},
	})
	expect_evals(t, ix, &tg, &frames[1], {{"b", "10"}, {"msg", "0x0"}, {"local", "0"}, {"$x0", "register not available"}})
	expect_evals(t, ix, &tg, &frames[2], {
		{"a", "5"},
		{"doubled", "0"},
		{"first.next->label", "0x40100a \"two\""},
		{"table", "[10, 20, 30, 40, 50]"},
		{"ratio", "1.5"},
	})
	// In the prologue the link register holds the return address.
	CHAIN :: []Want_Frame{{0x4000ac, FP2 + 16, FP1, "level1", 66}, {0x400040, FP1 + 16, FPM, "main", 70}, {0x4000c4, FPM + 16, FPS, "_start", 77}}
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x40011c, FP3, FP2, buf[:]), {{0x40011c, FP3, FP2, "level3", 54}, {0x400104, FP3, FP2, "level2", 61}, CHAIN[0], CHAIN[1], CHAIN[2]})
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400120, FP3, FP2, buf[:]), {{0x400120, FP3, FP2, "level3", 54}, {0x400104, FP3, FP2, "level2", 61}, CHAIN[0], CHAIN[1], CHAIN[2]})
	tg.reg = nil
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x40011c, FP3, FP2, buf[:]), {{0x40011c, FP3, FP2, "level3", 54}})
	frames = debug.unwind(ix, &tg, 0x40012c, FP3 - 0x10, FP3, buf[:])
	testing.expect_value(t, len(frames), 5)
	expect_evals(t, ix, &tg, &frames[0], {{"c", "11"}, {"$x0", "register not available"}})
}
