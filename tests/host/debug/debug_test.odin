// lib/debug's index (ADR-0017): upstream's tests/host/debug_test.c, case for
// case, on the C fixture: its DWARF 5 and symbol table become an index, and
// the index says where its functions, lines, variables and types are, which
// the test knows from the fixture (its symbols, its source's lines). A
// damaged index is refused; a damaged image gives an index or none, never a
// crash.
package debug_test

import "core:encoding/endian"
import "core:slice"
import "core:testing"
import "vx:debug"

// The C fixture's facts, from llvm-nm and fixtures/fixture.c.
C_FIXTURE_LINE :: 27 // fixture_add's (upstream: FIXTURE_LINE)
C_MARKER_LINE :: 29 // its `marker_line = __LINE__`
C_FIXTURE_ADD :: 0x400000 // &fixture_add, the executable not being PIE (upstream: the bias is 0)
C_ORIGIN :: 0x402000 // &origin
C_MAIN :: 0x400020 // &main
C_POINT_SIZE :: 24 // sizeof(struct point)

// A function whose line sequence starts where the one before ends: the End
// row the sort puts first is the other's, and its body is past its first
// statement (the Rust port's finding; upstream's 5c1bbc9, debug_test.c's
// first case).
@(test)
test_body_after_end :: proc(t: ^testing.T) {
	lines := []debug.Line {
		{addr = 0x1000, flags = {.End}},
		{addr = 0x1000, flags = {.Stmt}},
		{addr = 0x1008, flags = {.Stmt}},
		{addr = 0x1010, flags = {.End}},
	}
	fns := []debug.Func{{low = 0x1000, high = 0x1010}}
	debug.func_bodies(fns, lines)
	testing.expect_value(t, fns[0].body, 0x1008)
}

@(test)
test_index :: proc(t: ^testing.T) {
	// (Upstream first calls fixture_add, which the fixture does in its main.)
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, C_X86_64, &f) {
		return
	}
	ix := &f.ix
	testing.expect_value(t, f.elf.machine, debug.Machine.X86_64)
	testing.expect(t, len(f.elf.sec[.Info]) > 0)
	testing.expect_value(t, len(f.elf.build_id), 20)
	testing.expect(t, slice.equal(ix.header.build_id[:20], f.elf.build_id[:]))
	testing.expect_value(t, ix.header.build_id_len, 20)

	// The function, and the bias the executable was loaded at.
	fn, ok := debug.func_named(ix, "fixture_add")
	if !testing.expect(t, ok, "fixture_add is indexed") {
		return
	}
	testing.expect_value(t, fn.low, C_FIXTURE_ADD)
	at, at_ok := debug.func_at(ix, fn.low)
	testing.expect(t, at_ok && at == fn)
	at, at_ok = debug.func_at(ix, fn.high - 1)
	testing.expect(t, at_ok && at == fn)
	at, at_ok = debug.func_at(ix, fn.high)
	testing.expect(t, !at_ok || at != fn)
	testing.expect(t, fn.body > fn.low) // past the prologue
	testing.expect(t, fn.body < fn.high)
	testing.expect(t, debug.path_ends(debug.file(ix, fn.file), "tests/host/debug/fixtures/fixture.c"))
	testing.expect_value(t, fn.line, C_FIXTURE_LINE)
	l, l_ok := debug.line_at(ix, fn.body)
	if testing.expect(t, l_ok) {
		testing.expect(t, l.line >= C_FIXTURE_LINE && l.line <= C_FIXTURE_LINE + 2)
		testing.expect(t, debug.path_ends(debug.file(ix, l.file), "fixture.c"))
	}
	addr, addr_ok := debug.line_addr(ix, "debug/fixtures/fixture.c", C_MARKER_LINE)
	testing.expect(t, addr_ok)
	testing.expect(t, addr >= fn.low && addr < fn.high)
	_, addr_ok = debug.line_addr(ix, "no_such_file.c", 1)
	testing.expect(t, !addr_ok)

	// Its parameters and local, and their type.
	a, a_ok := debug.local_named(ix, fn, fn.body, "a")
	sum, sum_ok := debug.local_named(ix, fn, fn.body, "sum")
	testing.expect(t, a_ok && a.kind == .Param)
	testing.expect(t, sum_ok && sum.kind == .Local)
	_, zz := debug.local_named(ix, fn, fn.body, "zz")
	testing.expect(t, !zz)
	if a_ok {
		int_t, _ := debug.resolve(ix, a.type)
		testing.expect_value(t, int_t.kind, debug.Type_Kind.Base)
		testing.expect_value(t, int_t.size, 4)
		testing.expect_value(t, debug.str(ix, int_t.name), "int")
	}

	// A global struct: its members, and one an array.
	g, g_ok := debug.global_named(ix, "origin")
	if !testing.expect(t, g_ok) {
		return
	}
	testing.expect_value(t, g.kind, debug.Var_Kind.Global)
	expr, e_ok := debug.var_location(ix, g, 0)
	testing.expect(t, e_ok)
	if testing.expect_value(t, len(expr), 9) {
		testing.expect_value(t, debug.Dw_Op(expr[0]), debug.Dw_Op.Addr) // DW_OP_addrx, rewritten
		testing.expect_value(t, endian.unchecked_get_u64le(expr[1:9]), C_ORIGIN)
	}
	st, pt := debug.resolve(ix, g.type)
	testing.expect_value(t, st.kind, debug.Type_Kind.Struct)
	testing.expect_value(t, st.size, C_POINT_SIZE)
	if testing.expect_value(t, st.count, 3) {
		m := ix.members[st.first:][:3]
		testing.expect_value(t, debug.str(ix, m[0].name), "x")
		testing.expect_value(t, m[0].offset, 0)
		testing.expect_value(t, debug.str(ix, m[1].name), "y")
		testing.expect_value(t, m[1].offset, 8)
		testing.expect_value(t, debug.str(ix, m[2].name), "name")
		testing.expect_value(t, m[2].offset, 16)
		arr, _ := debug.resolve(ix, m[2].type)
		testing.expect_value(t, arr.kind, debug.Type_Kind.Array)
		testing.expect_value(t, arr.count, 8)
		elem, _ := debug.resolve(ix, arr.target)
		testing.expect_value(t, elem.size, 1)
	}
	point, point_ok := debug.type_named(ix, "point")
	testing.expect(t, point_ok)
	testing.expect_value(t, point, pt)

	// An enum, its enumerators and their values.
	color, _ := debug.type_named(ix, "color")
	en := debug.type_of(ix, color)
	testing.expect_value(t, en.kind, debug.Type_Kind.Enum)
	if testing.expect_value(t, en.count, 2) {
		testing.expect_value(t, debug.str(ix, ix.members[en.first].name), "RED")
		testing.expect_value(t, ix.members[en.first].offset, 0)
		testing.expect_value(t, debug.str(ix, ix.members[en.first + 1].name), "GREEN")
		testing.expect_value(t, ix.members[en.first + 1].offset, 5)
	}

	// The symbol table, for code with no DWARF.
	s, s_ok := debug.sym_at(ix, C_MAIN)
	testing.expect(t, s_ok && bool(s.func))
	testing.expect(t, s_ok && debug.str(ix, s.name) == "main")

	// An index from a file that is not one, or is cut short, is refused.
	_, bad := debug.open(f.index[:size_of(debug.Header) - 1])
	testing.expect(t, !bad)
	_, bad = debug.open(f.index[:len(f.index) - 8])
	testing.expect(t, !bad)
	junk := make([]u8, 4096)
	defer delete(junk)
	_, bad = debug.open(junk)
	testing.expect(t, !bad)
	// An ELF that is not one, or is cut short, gives an empty index, never a crash.
	_, bad = debug.elf_open(junk)
	testing.expect(t, !bad)
	if short, short_ok := debug.elf_open(f.image[:4096]); short_ok {
		arena := debug.Arena {
			buf = f.arena,
		}
		_, built := debug.build_index(&short, &arena)
		testing.expect(t, built)
	}
}

// Beyond upstream's: the index of the C fixture is upstream's, byte for byte
// (the digest is of the C library's index of the same file); and the
// aarch64 build answers the same questions.
@(test)
test_index_bytes :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		image:  []u8,
		size:   int,
		digest: u64,
		funcs:  int,
		lines:  int,
	}
	cases := []Case {
		{"c-x86_64", C_X86_64, 5464, 0xd90a_a274_5a58_e931, 7, 49},
		{"c-aarch64", C_AARCH64, 5672, 0xa388_bb60_5604_f04d, 7, 56},
	}
	for c in cases {
		f: Fixture
		defer close_fixture(&f)
		if !open_fixture(t, c.image, &f) {
			continue
		}
		testing.expectf(t, len(f.index) == c.size, "%s: %d bytes, upstream's %d", c.name, len(f.index), c.size)
		testing.expectf(t, fnv(FNV_START, f.index) == c.digest, "%s: digest %x, upstream's %x", c.name, fnv(FNV_START, f.index), c.digest)
		testing.expectf(t, len(f.ix.funcs) == c.funcs, "%s: %d functions", c.name, len(f.ix.funcs))
		testing.expectf(t, len(f.ix.lines) == c.lines, "%s: %d lines", c.name, len(f.ix.lines))
		fn, ok := debug.func_named(&f.ix, "level2")
		testing.expectf(t, ok && fn.line == 59, "%s: level2 on line 59", c.name)
		addr, _ := debug.line_addr(&f.ix, "fixture.c", 61)
		at, in_fn := debug.func_at(&f.ix, addr)
		testing.expectf(t, in_fn && at == fn, "%s: line 61 is in level2", c.name)
	}
}

// What an index answers when its numbers are wrong: nothing outside it.
@(test)
test_damaged_index :: proc(t: ^testing.T) {
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, C_X86_64, &f) {
		return
	}
	buf := make([]u8, len(f.index))
	defer delete(buf)
	copy(buf, f.index)
	h := (^debug.Header)(raw_data(buf))
	h.tables[.Funcs].off += 1 // misaligned
	_, ok := debug.open(buf)
	testing.expect(t, !ok)
	copy(buf, f.index)
	h.tables[.Types].count = 0 // no void
	_, ok = debug.open(buf)
	testing.expect(t, !ok)
	copy(buf, f.index)
	h.tables[.Strings].count -= 1 // the strings no longer end with a NUL
	_, ok = debug.open(buf)
	testing.expect(t, !ok)
	copy(buf, f.index)
	h.version += 1
	_, ok = debug.open(buf)
	testing.expect(t, !ok)
	_, ok = debug.open(buf[1:]) // not 8-aligned
	testing.expect(t, !ok)

	// Numbers out of range inside a table that opens: queries stay inside.
	copy(buf, f.index)
	ix, opened := debug.open(buf)
	if !testing.expect(t, opened) {
		return
	}
	for &fn in ix.funcs {
		fn.name = max(debug.Name)
		fn.file = max(debug.File_Index)
		fn.first_var = max(u32) - 1
		fn.var_count = 5
		fn.frame_base = max(u32)
		fn.frame_base_len = 4
	}
	for &v in ix.vars {
		v.type = max(debug.Type_Index)
		v.loc = max(u32) - 3
		v.loc_len = 100
	}
	for &ty in ix.types {
		ty.target = max(debug.Type_Index)
		ty.first = max(u32) - 1
		ty.count = 10
	}
	fn := &ix.funcs[0]
	testing.expect_value(t, debug.str(&ix, fn.name), "")
	testing.expect_value(t, debug.file(&ix, fn.file), "")
	_, found := debug.local_named(&ix, fn, fn.low, "a")
	testing.expect(t, !found) // its variables start past the table
	v := &ix.vars[0]
	_, loc_ok := debug.var_location(&ix, v, 0)
	testing.expect(t, !loc_ok)
	ty, n := debug.resolve(&ix, v.type)
	testing.expect_value(t, n, debug.Type_Index(max(u32)))
	testing.expect_value(t, ty.kind, debug.Type_Kind.Void)
}
