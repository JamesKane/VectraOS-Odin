// Upstream's fuzzers, tests/fuzz/debug_fuzz.c and eval_fuzz.c, as host
// tests: their corpora (tests/fuzz/corpus/debug and eval) through their
// drivers, and mutated images and indexes through the same queries. Every
// digest here is of upstream's C library run over the same inputs with the
// same mutations (splitmix64, seeded by the mutation's number): the port
// answers as upstream does on hostile input, not only on good input.
package debug_test

import "core:testing"
import "vx:debug"

DEBUG_CORPUS := #load_directory("corpus/debug")
EVAL_CORPUS := #load_directory("corpus/eval")

FNV_START :: 0xcbf2_9ce4_8422_2325

fnv :: proc(h: u64, b: []u8) -> u64 {
	h := h
	for x in b {
		h = (h ~ u64(x)) * 0x100_0000_01b3
	}
	return h
}

fnv_u64 :: proc(h: u64, v: u64) -> u64 {
	b := transmute([8]u8)u64le(v)
	return fnv(h, b[:])
}

fnv_str :: proc(h: u64, s: string) -> u64 {
	return fnv(fnv(h, transmute([]u8)s), {0})
}

Rng :: struct {
	state: u64,
}

next_rand :: proc(r: ^Rng) -> u64 {
	r.state += 0x9e37_79b9_7f4a_7c15
	z := r.state
	z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
	z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
	return z ~ (z >> 31)
}

// Mutates buf from `from` on, as seed says: up to 8 bytes changed, and one
// time in 16 a cut. Returns the length left.
mutate :: proc(buf: []u8, seed: u64, from := 0) -> int {
	n := len(buf)
	r := Rng {
		state = seed * 0x2545_f491_4f6c_dd1d + 1,
	}
	k := 1 + next_rand(&r) % 8
	for i: u64 = 0; i < k && n > from; i += 1 {
		at := from + int(next_rand(&r) % u64(n - from))
		switch next_rand(&r) % 6 {
		case 0:
			buf[at] = u8(next_rand(&r))
		case 1:
			buf[at] ~= u8(1) << (next_rand(&r) % 8)
		case 2:
			buf[at] = 0
		case 3:
			buf[at] = 0xff
		case 4:
			buf[at] += 1
		case:
			buf[at] -= 1
		}
	}
	if next_rand(&r) % 16 == 0 && n > from {
		n = from + int(next_rand(&r) % u64(n - from))
	}
	return n
}

NONE :: ~u64(0)

// An entry's number in its table, or NONE.
number :: proc(table: []$T, p: ^T, ok: bool) -> u64 {
	if !ok {
		return NONE
	}
	return u64((uintptr(p) - uintptr(raw_data(table))) / size_of(T))
}

// debug_fuzz.c's queries over an opened index, and a few more, digested.
queries :: proc(ix: ^debug.Index) -> u64 {
	h: u64 = FNV_START
	for &f in ix.funcs {
		g, g_ok := debug.func_at(ix, f.low)
		h = fnv_u64(h, number(ix.funcs, g, g_ok))
		l, l_ok := debug.line_at(ix, f.body)
		h = fnv_u64(h, number(ix.lines, l, l_ok))
		s, s_ok := debug.sym_at(ix, f.low)
		h = fnv_u64(h, number(ix.syms, s, s_ok))
		h = fnv_str(h, debug.str(ix, f.name))
		h = fnv_str(h, debug.file(ix, f.file))
		for k: u32 = 0; k < f.var_count && u64(f.first_var + k) < u64(len(ix.vars)); k += 1 {
			v := &ix.vars[f.first_var + k]
			expr, ok := debug.var_location(ix, v, f.body)
			h = fnv_u64(h, u64(ok))
			if ok {
				h = fnv(h, expr)
			}
			ty, n := debug.resolve(ix, v.type)
			h = fnv_u64(h, u64(n))
			h = fnv_u64(h, u64(ty.kind))
			w, w_ok := debug.local_named(ix, &f, f.body, debug.str(ix, v.name))
			h = fnv_u64(h, number(ix.vars, w, w_ok))
		}
	}
	a, _ := debug.line_addr(ix, "a.c", 1)
	h = fnv_u64(h, a)
	a, _ = debug.line_addr(ix, "fixture.c", 27)
	h = fnv_u64(h, a)
	t, _ := debug.type_named(ix, "p")
	h = fnv_u64(h, u64(t))
	t, _ = debug.type_named(ix, "int")
	h = fnv_u64(h, u64(t))
	m, m_ok := debug.func_named(ix, "main")
	h = fnv_u64(h, number(ix.funcs, m, m_ok))
	g, g_ok := debug.global_named(ix, "origin")
	h = fnv_u64(h, number(ix.vars, g, g_ok))
	for pc: u64 = 0x400000; pc < 0x400200; pc += 3 {
		f, f_ok := debug.func_at(ix, pc)
		h = fnv_u64(h, number(ix.funcs, f, f_ok))
		l, l_ok := debug.line_at(ix, pc)
		h = fnv_u64(h, number(ix.lines, l, l_ok))
	}
	return h
}

// debug_fuzz.c's driver: an image (its own copy) into an index built in the
// fuzzer's arena, opened, and its queries; the digest of the index and the
// answers, or 1 (not an ELF image), 2 (no index) or 3 (an index that does
// not open).
fuzz_image :: proc(image: []u8, arena: []u8) -> u64 {
	elf, ok := debug.elf_open(image)
	if !ok {
		return 1
	}
	a := debug.Arena {
		buf = arena,
	}
	index, built := debug.build_index(&elf, &a)
	if !built {
		return 2
	}
	ix, opened := debug.open(index)
	if !opened {
		return 3
	}
	// The fuzzer's invariant: sorted, so every function is found at its start.
	for &f in ix.funcs {
		_, found := debug.func_at(&ix, f.low)
		if !found && f.low < f.high {
			return 4
		}
	}
	return fnv(queries(&ix), index)
}

@(test)
test_debug_corpus :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		digest: u64,
	}
	cases := []Case {
		{"tiny-object", 0xd99e_6b16_6416_2335}, // a small object with DWARF 5, unrelocated
	}
	testing.expect_value(t, len(DEBUG_CORPUS), len(cases))
	arena := make([]u8, FUZZ_ARENA_SIZE)
	defer delete(arena)
	for c in cases {
		data: []u8
		for file in DEBUG_CORPUS {
			if file.name == c.name {
				data = file.data
			}
		}
		if !testing.expectf(t, data != nil, "corpus file %s is missing", c.name) {
			continue
		}
		image := make([]u8, len(data))
		defer delete(image)
		copy(image, data)
		d := fuzz_image(image, arena)
		testing.expectf(t, d == c.digest, "%s: digest %x, upstream's %x", c.name, d, c.digest)
	}
}

// Mutated images (anywhere, then only in their DWARF), and mutated indexes,
// N of each: the digest of every result, upstream's.
@(test)
test_mutations :: proc(t: ^testing.T) {
	N :: 1000
	Case :: struct {
		name:                 string,
		image:                []u8,
		dwarf_from:           int, // the first .debug_ section's offset
		whole, dwarf, index: u64,
	}
	tiny: []u8
	for file in DEBUG_CORPUS {
		if file.name == "tiny-object" {
			tiny = file.data
		}
	}
	cases := []Case {
		{"c-x86_64", C_X86_64, 0x3080, 0xada8_3020_b92b_bba2, 0x888f_7b66_10fe_f92f, 0x1e0d_df61_3945_375f},
		{"c-aarch64", C_AARCH64, 0x3080, 0xb1f6_8d4f_56dd_dfac, 0x4940_c9f9_0a1d_90cf, 0xeb3a_f399_6962_3f82},
		// Mutated anywhere: upstream's at 5c1bbc9, whose func_bodies passes over an
		// End row at a function's first address (fe3cdde419929620 before).
		{"tiny-object", tiny, 0x64, 0x3026_1dde_e577_4e28, 0x48ae_a430_b951_1a73, 0x1fe2_5050_2355_0ecb},
	}
	arena := make([]u8, FUZZ_ARENA_SIZE)
	defer delete(arena)
	big := make([]u8, ARENA_SIZE)
	defer delete(big)
	for c in cases {
		buf := make([]u8, len(c.image))
		defer delete(buf)
		for from, pass in ([2]int{0, c.dwarf_from}) {
			all: u64 = FNV_START
			for i in 0 ..< N {
				copy(buf, c.image)
				m := mutate(buf, u64(i), from)
				image := make([]u8, m) // its own allocation, so ASan sees a read past its end
				copy(image, buf[:m])
				all = fnv_u64(all, fuzz_image(image, arena))
				delete(image)
			}
			want := pass == 0 ? c.whole : c.dwarf
			testing.expectf(t, all == want, "%s, mutated %s: digest %x, upstream's %x", c.name, pass == 0 ? "anywhere" : "in its DWARF", all, want)
		}

		// The index of the good image, mutated, opened and queried.
		elf, _ := debug.elf_open(c.image)
		a := debug.Arena {
			buf = big,
		}
		index, built := debug.build_index(&elf, &a)
		if !testing.expect(t, built) {
			continue
		}
		ibuf := make([]u8, len(index))
		defer delete(ibuf)
		all: u64 = FNV_START
		for i in 0 ..< N {
			copy(ibuf, index)
			m := mutate(ibuf, u64(i) + 1_000_000)
			d: u64 = 1
			if ix, opened := debug.open(ibuf[:m]); opened {
				d = queries(&ix)
			}
			all = fnv_u64(all, d)
		}
		testing.expectf(t, all == c.index, "%s, index mutated: digest %x, upstream's %x", c.name, all, c.index)
	}
}

// The index's demand on its arena is upstream's: the same arena fits or not.
@(test)
test_arena_sizes :: proc(t: ^testing.T) {
	Case :: struct {
		size:  int,
		built: bool,
	}
	cases := []Case{{0, false}, {98_303, false}, {628_295, false}, {628_296, true}, {8 << 20, true}}
	buf := make([]u8, 8 << 20)
	defer delete(buf)
	elf, _ := debug.elf_open(C_X86_64)
	for c in cases {
		a := debug.Arena {
			buf = buf[:c.size],
		}
		_, built := debug.build_index(&elf, &a)
		testing.expectf(t, built == c.built, "arena of %d bytes: built %v", c.size, built)
	}
}

// eval_fuzz.c's driver: each corpus text evaluated and printed at a frame in
// the C fixture, with a target whose memory cannot be read and whose
// registers are unknown; every failure says why. Then the same texts where
// the program can be read.
@(test)
test_eval_corpus :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		digest: u64, // eval_fuzz.c's run, digested
		want:   string, // at level3's frame, as eval_test lays it out
	}
	cases := []Case {
		{"expression", 0x3524_a6d8_53e2_adb7, "812"},
		{"operators", 0x50f7_86c8_9d78_9ab4, "0"},
	}
	testing.expect_value(t, len(EVAL_CORPUS), len(cases))
	f: Fixture
	defer close_fixture(&f)
	if !open_fixture(t, C_X86_64, &f) {
		return
	}
	nothing := debug.Target {
		machine = .X86_64,
		read = proc "contextless" (data: rawptr, addr: u64, buf: []u8) -> bool {return false},
	}
	fr := debug.Frame {
		pc    = 0x400000,
		inner = true,
	}
	p := new(Program)
	defer free(p)
	p.image = f.image
	c_x86_64_stack(p)
	tg := target_of(p, .X86_64)
	tg.reg = nil
	buf: [16]debug.Frame
	frames := debug.unwind(&f.ix, &tg, C_LEVEL3_BODY, 0, FP3, buf[:])
	for c in cases {
		data: []u8
		for file in EVAL_CORPUS {
			if file.name == c.name {
				data = file.data
			}
		}
		if !testing.expectf(t, data != nil, "corpus file %s is missing", c.name) {
			continue
		}
		text := string(data)
		for len(text) > 0 && text[len(text) - 1] == '\n' {
			text = text[:len(text) - 1]
		}
		s := debug.begin(&f.ix, &nothing, &fr)
		out: [256]u8
		all: u64 = FNV_START
		if v, ok := debug.eval(&s, text); ok {
			all = fnv_str(fnv_u64(all, 1), debug.format(&s, v, out[:]))
		} else {
			testing.expectf(t, s.err != "", "%s: a failure always says why", c.name)
			all = fnv_str(fnv_u64(all, 0), s.err)
		}
		testing.expectf(t, all == c.digest, "%s: digest %x, upstream's %x", c.name, all, c.digest)
		if len(frames) > 0 {
			expect_evals(t, &f.ix, &tg, &frames[0], {{text, c.want}})
		}
	}
}
