// lib/debug on Odin's own DWARF (docs/PLAN.md P4): an Odin program built as
// ./build builds one (fixtures/odin), whose DWARF is version 4 from LLVM,
// with location lists in .debug_loc, range lists in .debug_ranges, files
// numbered from 1, Odin's names (`pkg::name`, `pkg::[file.odin]::name`,
// polymorphic instances named with their signature) and the out-of-line
// copies of inlined procedures named only through DW_AT_abstract_origin.
// Upstream's library indexes none of it (only the symbol table); these
// expectations are this port's.
package debug_test

import "core:slice"
import "core:testing"
import "vx:debug"

ODIN_FILE :: "tests/host/debug/fixtures/odin/fixture.odin"
ODIN_ADD_LINE :: 35 // add's declaration
ODIN_MARKER_LINE :: 37 // its volatile_store

@(test)
test_odin_index :: proc(t: ^testing.T) {
	Case :: struct {
		name:    string,
		image:   []u8,
		machine: debug.Machine,
		add:     [3]u64, // add's low, body and high
		frame:   u8, // its frame base: DW_OP_reg6 (rbp) or reg29 (x29)
		body:    u32, // the line its body starts on, as LLVM scheduled it
	}
	cases := []Case {
		{"x86_64", ODIN_X86_64, .X86_64, {0x400020, 0x400024, 0x400043}, 0x56, 36},
		{"aarch64", ODIN_AARCH64, .AArch64, {0x400028, 0x400030, 0x40005c}, 0x6d, 37},
	}
	for c in cases {
		f: Fixture
		defer close_fixture(&f)
		if !open_fixture(t, c.image, &f) {
			continue
		}
		ix := &f.ix
		testing.expect_value(t, f.elf.machine, c.machine)
		testing.expectf(t, len(ix.funcs) == 53, "%s: %d functions", c.name, len(ix.funcs))

		// A known procedure (file-private, so named with its file) and its lines.
		fn, ok := debug.func_named(ix, "fixture::[fixture.odin]::add")
		if !testing.expectf(t, ok, "%s: add is indexed", c.name) {
			continue
		}
		testing.expectf(t, fn.low == c.add[0] && fn.body == c.add[1] && fn.high == c.add[2], "%s: add at %x %x %x", c.name, fn.low, fn.body, fn.high)
		testing.expect(t, debug.path_ends(debug.file(ix, fn.file), ODIN_FILE))
		testing.expect_value(t, fn.line, ODIN_ADD_LINE)
		testing.expect(t, slice.equal(ix.exprs[fn.frame_base:][:fn.frame_base_len], []u8{c.frame}))
		l, l_ok := debug.line_at(ix, fn.body)
		testing.expect(t, l_ok && l.line == c.body)
		testing.expect(t, l_ok && .Prologue_End in l.flags)
		addr, addr_ok := debug.line_addr(ix, "fixtures/odin/fixture.odin", ODIN_MARKER_LINE)
		at, at_ok := debug.func_at(ix, addr)
		testing.expect(t, addr_ok && at_ok && at == fn)
		_, addr_ok = debug.line_addr(ix, "fixture.odin", 2)
		testing.expect(t, !addr_ok)

		// Its parameters, in registers, and its local, in a list (.debug_loc).
		a, a_ok := debug.local_named(ix, fn, fn.body, "a")
		testing.expect(t, a_ok && a.kind == .Param)
		sum, sum_ok := debug.local_named(ix, fn, fn.high - 1, "sum")
		testing.expect(t, sum_ok && sum.kind == .Local)
		if a_ok {
			i32_t, _ := debug.resolve(ix, a.type)
			testing.expect_value(t, i32_t.kind, debug.Type_Kind.Base)
			testing.expect_value(t, i32_t.size, 4)
			testing.expect_value(t, i32_t.encoding, debug.Encoding.Signed)
			testing.expect_value(t, debug.str(ix, i32_t.name), "i32")
		}

		// A block's local, in scope by its range only.
		level2, l2_ok := debug.func_named(ix, "fixture::level2")
		if testing.expect(t, l2_ok) {
			testing.expect_value(t, level2.line, 49)
			in_block, _ := debug.line_addr(ix, "fixture.odin", 53)
			inner, inner_ok := debug.local_named(ix, level2, in_block, "inner")
			testing.expect(t, inner_ok && inner.scope_low > level2.low && inner.scope_high <= level2.high)
			_, early := debug.local_named(ix, level2, level2.low, "inner")
			testing.expect(t, !early)
		}

		// Polymorphic instances, named with their signature; a polymorphic
		// instance's declaration is where it was instantiated (Odin's DWARF).
		twice32, t_ok := debug.func_named(ix, "fixture::twice:proc\"contextless\"(x:i32)->(:i32)")
		testing.expect(t, t_ok && twice32.line == 59)
		_, t_ok = debug.func_named(ix, "fixture::twice:proc\"contextless\"(x:i64)->(:i64)")
		testing.expect(t, t_ok)
		_, t_ok = debug.func_named(ix, "_start")
		testing.expect(t, t_ok)

		// Globals at fixed addresses, and their types.
		g, g_ok := debug.global_named(ix, "origin")
		if testing.expect(t, g_ok) {
			st, pt := debug.resolve(ix, g.type)
			testing.expect_value(t, st.kind, debug.Type_Kind.Struct)
			testing.expect_value(t, debug.str(ix, st.name), "fixture::Point")
			testing.expect_value(t, st.size, 24)
			if testing.expect_value(t, st.count, 3) {
				m := ix.members[st.first:][:3]
				testing.expect_value(t, debug.str(ix, m[1].name), "y")
				testing.expect_value(t, m[1].offset, 8)
				arr, _ := debug.resolve(ix, m[2].type)
				testing.expect_value(t, arr.kind, debug.Type_Kind.Array)
				testing.expect_value(t, arr.count, 8)
			}
			named, named_ok := debug.type_named(ix, "fixture::Point")
			testing.expect(t, named_ok && named == pt)
			expr, e_ok := debug.var_location(ix, g, 0)
			testing.expect(t, e_ok && len(expr) == 9 && debug.Dw_Op(expr[0]) == .Addr)
		}
		colour, colour_ok := debug.type_named(ix, "fixture::Colour")
		en := debug.type_of(ix, colour)
		testing.expect(t, colour_ok && en.kind == .Enum && en.size == 1)
		if testing.expect_value(t, en.count, 2) {
			testing.expect_value(t, debug.str(ix, ix.members[en.first + 1].name), "Green")
			testing.expect_value(t, ix.members[en.first + 1].offset, 5)
		}
		str_t, _ := debug.type_named(ix, "string")
		testing.expect_value(t, debug.type_of(ix, str_t).size, 16)

		// Every function has a name: those LLVM also inlined take theirs from
		// DW_AT_abstract_origin.
		for &x in ix.funcs {
			testing.expectf(t, debug.str(ix, x.name) != "", "%s: a function at %x has no name", c.name, x.low)
		}
		// The symbol table agrees.
		s, s_ok := debug.sym_at(ix, fn.low)
		testing.expect(t, s_ok && debug.str(ix, s.name) == "fixture::[fixture.odin]::add")
	}
}

// The x86_64 fixture stopped in add, called from level3 <- level2 <- level1
// <- _start, with the frame records Odin's code makes: the frame-pointer walk
// names every frame, and variables are read from the innermost frame's
// registers through their location lists.
ODIN_FPA :: 0x7fff_0e00
ODIN_FP3 :: 0x7fff_0e10
ODIN_FP2 :: 0x7fff_0e40
ODIN_FP1 :: 0x7fff_0e60
ODIN_FPS :: 0x7fff_0e80

odin_stack :: proc(p: ^Program, rets: [4]u64) {
	put(p, ODIN_FPA, 8, ODIN_FP3)
	put(p, ODIN_FPA + 8, 8, rets[0]) // into level3
	put(p, ODIN_FP3, 8, ODIN_FP2)
	put(p, ODIN_FP3 + 8, 8, rets[1]) // into level2
	put(p, ODIN_FP2, 8, ODIN_FP1)
	put(p, ODIN_FP2 + 8, 8, rets[2]) // into level1
	put(p, ODIN_FP1, 8, ODIN_FPS)
	put(p, ODIN_FP1 + 8, 8, rets[3]) // into _start
}

@(test)
test_odin_eval :: proc(t: ^testing.T) {
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, ODIN_X86_64, &f) {
		return
	}
	ix := &f.ix
	p := new(Program)
	defer free(p)
	p.image = f.image
	odin_stack(p, {0x400062, 0x400099, 0x4000f0, 0x40013e})
	set_reg(p, 5, 33) // rdi: a
	set_reg(p, 4, 10) // rsi: b
	set_reg(p, 2, 43) // rcx: sum
	set_reg(p, 6, ODIN_FPA)
	set_reg(p, 7, ODIN_FPA)
	tg := target_of(p, .X86_64)
	buf: [16]debug.Frame
	frames := debug.unwind(ix, &tg, 0x400035, ODIN_FPA, ODIN_FPA, buf[:])
	expect_frames(t, ix, frames, {
		{0x400035, ODIN_FPA, ODIN_FPA, "fixture::[fixture.odin]::add", 38},
		{0x400062, ODIN_FP3, ODIN_FP3, "fixture::level3", 46},
		{0x400099, ODIN_FP3 + 16, ODIN_FP2, "fixture::level2", 53},
		{0x4000f0, ODIN_FP2 + 16, ODIN_FP1, "fixture::level1", 60},
		{0x40013e, ODIN_FP1 + 16, ODIN_FPS, "_start", 65},
	})
	if len(frames) != 5 {
		return
	}
	expect_evals(t, ix, &tg, &frames[0], {
		{"a", "33"},
		{"b", "10"},
		{"sum", "43"},
		{"a + b == sum", "1"},
		{"hue", "Green"},
		{"(int)hue", "5"},
		{"origin", "{x = 1, y = 2, name = {...}}"},
		{"origin.x", "1"},
		{"origin.y", "2"},
		{"origin.name", "[111, 0, 0, 0, 0, 0, 0, 0]"}, // u8 is DW_ATE_unsigned, not a character
		{"origin.name[0]", "111"},
		{"table", "[10, 20, 30, 40, 50]"},
		{"table[4]", "50"},
		{"&table[2]", "0x403034"},
		{"greeting", "{data = 0x402128, len = 5}"},
		{"greeting.len", "5"},
		{"greeting.data[1]", "101"},
		{"*greeting.data", "104"},
		{"marker", "cannot read memory"},
		{"sizeof(origin)", "24"},
		{"sizeof(table)", "20"},
		{"sizeof(greeting)", "16"},
		{"sizeof(int)", "8"},
		{"sizeof(i32)", "4"},
		{"(i32)-1", "-1"},
		{"(u8)300", "44"},
		{"(i64)origin.x << 40", "1099511627776"},
		{"ODIN_DEBUG", "true"}, // Odin's constants are DW_AT_const_value globals
		{"ODIN_OS", "Freestanding"},
		{"true", "true"},
		{"Green", "Green"},
		{"fixture::Colour", "! no such variable"}, // ':' is not in C's names
		{"$rip", "4194357"},
		{"$rdi", "33"},
	})
	expect_evals(t, ix, &tg, &frames[1], {{"c", "register not available"}, {"table[0]", "10"}})
	expect_evals(t, ix, &tg, &frames[2], {
		{"b", "! variable not available here"}, // DW_OP_GNU_entry_value
		{"local", "register not available"},
		{"inner", "register not available"},
	})
	expect_evals(t, ix, &tg, &frames[3], {{"a", "! variable not available here"}, {"doubled", "register not available"}})
	l, ok := debug.location(ix, &tg, &frames[0], frames_func(ix, &frames[0]), local(t, ix, &frames[0], "sum"))
	testing.expect(t, ok && l == debug.Reg(2))

	// In add's prologue: at its first instruction, then past push %rbp.
	put(p, ODIN_FPA - 8, 8, 0x400062)
	chain := []Want_Frame {
		{0x400062, ODIN_FPA, ODIN_FP3, "fixture::level3", 46},
		{0x400099, ODIN_FP3 + 16, ODIN_FP2, "fixture::level2", 53},
		{0x4000f0, ODIN_FP2 + 16, ODIN_FP1, "fixture::level1", 60},
		{0x40013e, ODIN_FP1 + 16, ODIN_FPS, "_start", 65},
	}
	want := make([dynamic]Want_Frame, context.temp_allocator)
	append(&want, Want_Frame{0x400020, ODIN_FPA - 8, ODIN_FP3, "fixture::[fixture.odin]::add", 35})
	append(&want, ..chain)
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400020, ODIN_FPA - 8, ODIN_FP3, buf[:]), want[:])
	put(p, ODIN_FPA - 16, 8, ODIN_FP3)
	want[0] = {0x400021, ODIN_FPA - 16, ODIN_FP3, "fixture::[fixture.odin]::add", 35}
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400021, ODIN_FPA - 16, ODIN_FP3, buf[:]), want[:])
	// In a polymorphic instance, called from level1.
	put(p, 0x7fff_0e50, 8, ODIN_FP1)
	put(p, 0x7fff_0e58, 8, 0x4000db)
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400114, 0x7fff_0e50, 0x7fff_0e50, buf[:]), {
		{0x400114, 0x7fff_0e50, 0x7fff_0e50, "fixture::twice:proc\"contextless\"(x:i32)->(:i32)", 42},
		{0x4000db, 0x7fff_0e60, ODIN_FP1, "fixture::level1", 59},
		{0x40013e, ODIN_FP1 + 16, ODIN_FPS, "_start", 65},
	})
}

@(test)
test_odin_eval_aarch64 :: proc(t: ^testing.T) {
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, ODIN_AARCH64, &f) {
		return
	}
	ix := &f.ix
	p := new(Program)
	defer free(p)
	p.image = f.image
	odin_stack(p, {0x400074, 0x4000b0, 0x40010c, 0x40016c})
	set_reg(p, 0, 33)
	set_reg(p, 1, 10)
	set_reg(p, 29, ODIN_FPA)
	set_reg(p, 31, ODIN_FPA)
	set_reg(p, 30, 0x400074)
	tg := target_of(p, .AArch64)
	buf: [16]debug.Frame
	chain := []Want_Frame {
		{0x400074, ODIN_FP3, ODIN_FP3, "fixture::level3", 46},
		{0x4000b0, ODIN_FP3 + 16, ODIN_FP2, "fixture::level2", 53},
		{0x40010c, ODIN_FP2 + 16, ODIN_FP1, "fixture::level1", 60},
		{0x40016c, ODIN_FP1 + 16, ODIN_FPS, "_start", 65},
	}
	frames := debug.unwind(ix, &tg, 0x400040, ODIN_FPA, ODIN_FPA, buf[:])
	want := make([dynamic]Want_Frame, context.temp_allocator)
	append(&want, Want_Frame{0x400040, ODIN_FPA, ODIN_FPA, "fixture::[fixture.odin]::add", 38})
	append(&want, ..chain)
	expect_frames(t, ix, frames, want[:])
	if len(frames) != 5 {
		return
	}
	expect_evals(t, ix, &tg, &frames[0], {
		{"a", "33"},
		{"b", "10"},
		{"sum", "! variable not available here"},
		{"origin", "{x = 1, y = 2, name = {...}}"},
		{"table[1] + table[2]", "50"},
		{"greeting.len", "5"},
		{"$x0", "33"},
		{"$x30", "4194420"},
	})
	expect_evals(t, ix, &tg, &frames[1], {{"c", "register not available"}})
	expect_evals(t, ix, &tg, &frames[3], {{"a", "! variable not available here"}})
	// In add's prologue, before its stp: the link register.
	want[0] = {0x400028, ODIN_FPA, ODIN_FP3, "fixture::[fixture.odin]::add", 35}
	want[1].sp = ODIN_FPA
	expect_frames(t, ix, debug.unwind(ix, &tg, 0x400028, ODIN_FPA, ODIN_FP3, buf[:]), want[:])
}

@(private = "file")
frames_func :: proc(ix: ^debug.Index, f: ^debug.Frame) -> ^debug.Func {
	fn, _ := debug.func_at(ix, debug.frame_lookup_pc(f))
	return fn
}

@(private = "file")
local :: proc(t: ^testing.T, ix: ^debug.Index, f: ^debug.Frame, name: string, loc := #caller_location) -> ^debug.Var {
	v, ok := debug.local_named(ix, frames_func(ix, f), debug.frame_lookup_pc(f), name)
	testing.expectf(t, ok, "%s is a local", name, loc = loc)
	return v
}
