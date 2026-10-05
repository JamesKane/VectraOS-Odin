// The cross-check against upstream's lib/vx-guide (025911e), built with
// clang and driven exactly as transcript drives lib/guide: every page is
// rendered whole at four widths and node by node, then walked block by
// block, each block's spans and each row's cells listed, and every value,
// result and error folded with FNV-1a. The digests are upstream's.
//
// It is also upstream's guide_fuzz.c, as a host test: arbitrary text never
// reads outside the page (bounds checks and ASan), never loops (each loop is
// bounded), and gives UTF-8 whenever the page was accepted.
//
// The inputs: upstream's fuzz corpus (corpus/), the manual's pages as
// upstream had them at 025911e (pages/, fixed here so the digests are), and
// inputs the mutator below makes from them, which upstream's C was run on
// with the same mutator.
package guide_test

import "base:runtime"
import "core:testing"
import "vx:guide"
import "vx:utf"

CORPUS := #load_directory("corpus")
PAGES := #load_directory("pages")

FNV_OFFSET :: u64(0xcbf29ce484222325)
FNV_PRIME :: u64(0x100000001b3)

Transcript :: struct {
	h:       u64,
	utf_ok:  bool,
	bad_utf: int, // accepted pages whose rendering was not UTF-8
}

emit :: proc "contextless" (x: ^Transcript, s: string) {
	for i in 0 ..< len(s) {
		x.h = (x.h ~ u64(s[i])) * FNV_PRIME
	}
}

// A value, then a separator.
emitv :: proc "contextless" (x: ^Transcript, s: string) {
	emit(x, s)
	emit(x, "\x1f")
}

// A number in decimal, then a comma.
emitu :: proc "contextless" (x: ^Transcript, v: u64) {
	buf: [21]u8
	i := len(buf) - 1
	buf[i] = ','
	v := v
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	emit(x, string(buf[i:]))
}

out_write :: proc "contextless" (ctx: rawptr, s: string) {
	x := (^Transcript)(ctx)
	emit(x, s)
	x.utf_ok = x.utf_ok && utf.valid(s)
}

render_t :: proc(x: ^Transcript, page: string, width: u32, node := "") {
	emit(x, "R")
	emitu(x, u64(width))
	emitv(x, node)
	o := guide.Out{write = out_write, ctx = x, width = width}
	x.utf_ok = true
	err, ok := guide.render(page, &o, node)
	if ok && !x.utf_ok {
		x.bad_utf += 1
	}
	emit(x, "E")
	emitv(x, err.msg)
	emitu(x, u64(err.line))
}

LOOP_MAX :: 1_000_000 // more spans, blocks or cells than this is a loop

spans :: proc(t: ^testing.T, x: ^Transcript, s: string) {
	it := guide.Inline{s = s}
	for _ in 0 ..< LOOP_MAX {
		sp, ok := guide.span_next(&it)
		if !ok {
			if it.error != "" {
				emit(x, "s!")
				emitv(x, it.error)
			} else {
				emit(x, "s.")
			}
			return
		}
		emit(x, "s")
		emitu(x, u64(sp.kind))
		emitv(x, sp.text)
		emitv(x, sp.name)
		emitv(x, sp.label)
		emitv(x, sp.target)
		emitu(x, u64(sp.sect))
	}
	testing.fail_now(t, "span_next loops")
}

transcript :: proc(t: ^testing.T, x: ^Transcript, page: string) {
	widths := [4]u32{80, 44, 20, len(page) > 0 ? 8 + u32(page[0]) % 120 : 8}
	for w in widths {
		render_t(x, page, w)
	}
	gs: guide.Guide
	g := &gs
	if !guide.open(g, page) {
		emit(x, "O0")
		emitv(x, g.error)
		emitu(x, u64(g.error_line))
		return
	}
	emit(x, "O1")
	emitv(x, g.h.page)
	emitu(x, u64(g.h.sect))
	emitv(x, g.h.summary)
	emitv(x, g.h.names)
	emitv(x, g.h.src)
	emitv(x, g.h.lang)
	emitv(x, g.h.keys)
	emitu(x, g.h.level)
	emitu(x, u64(g.h.host))
	n := 0
	for b in guide.next(g) {
		n += 1
		if n > LOOP_MAX {
			testing.fail_now(t, "next loops")
		}
		emit(x, "B")
		emitu(x, u64(b.kind))
		emitu(x, u64(b.line))
		emitv(x, b.text)
		emitv(x, b.body)
		emitv(x, b.fence)
		emitv(x, b.node)
		emitv(x, b.title)
		emitv(x, b.keys)
		if b.kind == .Node {
			render_t(x, page, 80, b.node)
		}
		spans(t, x, b.text)
		if b.kind == .Def {
			spans(t, x, b.body)
		}
		if b.kind == .Row {
			row := b.text
			for c := 0;; c += 1 {
				cell := guide.cell_next(&row) or_break
				if c > LOOP_MAX {
					testing.fail_now(t, "cell_next loops")
				}
				emit(x, "c")
				emitv(x, cell)
			}
		}
	}
	emit(x, "Z")
	emitv(x, g.error)
	emitu(x, g.error != "" ? u64(g.error_line) : 0)
}

// The seeds, in the oracle's order: the corpus, then the pages.
seeds :: proc() -> []string {
	s := make([dynamic]string, context.temp_allocator)
	for name in ([]string{"cat1", "guide6", "table"}) {
		append(&s, file_in(CORPUS, name))
	}
	for name in ([]string{"1-intro", "1-man", "2-futex", "2-intro", "3-intro", "4-intro", "5-intro", "6-guide", "6-intro", "7-intro", "8-install", "8-intro"}) {
		append(&s, file_in(PAGES, name))
	}
	return s[:]
}

file_in :: proc(files: []runtime.Load_Directory_File, name: string) -> string {
	for f in files {
		if f.name == name {
			return string(f.data)
		}
	}
	return ""
}

@(test)
test_seeds :: proc(t: ^testing.T) {
	// From the oracle: upstream's guide.c, clang, the same transcript.
	want := []u64 {
		0xce5e8ccdf9acf331, // corpus/cat1
		0xee10b7f92db8324e, // corpus/guide6
		0x0905be128e85ae96, // corpus/table
		0xfd8810196c229e35, // pages/1-intro
		0xfe12955109b7f74d, // pages/1-man
		0xe03ca9f8679e2dfd, // pages/2-futex
		0xb6c7bd3bb86823c8, // pages/2-intro
		0x0747f08bdbf79cc3, // pages/3-intro
		0x3bfc5e43169d808b, // pages/4-intro
		0xd60f1598d5ee67b8, // pages/5-intro
		0xee10b7f92db8324e, // pages/6-guide, which is corpus/guide6
		0x657b466daae368bf, // pages/6-intro
		0x18100c04f3ed9d6f, // pages/7-intro
		0x438e1a285ccd8f14, // pages/8-install
		0x112d9d6051987cde, // pages/8-intro
	}
	s := seeds()
	testing.expect_value(t, len(s), len(want))
	fold := FNV_OFFSET
	for page, i in s {
		testing.expectf(t, page != "", "seed %d is missing", i)
		x := Transcript{h = FNV_OFFSET}
		transcript(t, &x, page)
		testing.expectf(t, x.h == want[i], "seed %d: digest %x, upstream's %x", i, x.h, want[i])
		testing.expect_value(t, x.bad_utf, 0)
		fold = (fold ~ x.h) * FNV_PRIME
	}
	testing.expectf(t, fold == 0x97ec51cd985d8337, "seeds: fold %x", fold)
}

// --- The mutator: the oracle has the same ---

Mutator :: struct {
	rng:   u64,
	seeds: []string,
	text:  [dynamic]u8,
}

MAX_INPUT :: 16384

TOKENS := [?]string {
	"`", "``", "{", "}", "|", "<", ">", "<file>",
	"(1)", "(9)", "rc(1)", "\n", "\n\n", "  ", "# ", "## ",
	"- ", ": ", "```", "```c\n", "@node=", "@node=x title=\"T\"\n", "@guide=1\n", " keys=a,b",
	"é", "€", "#", " ", "x", "\t", "\"", "=",
	",", "\x01", "\xff", "https://x", "{a|b(2)#c}", "SEE ALSO", "page=", "sect=",
	"summary=", "host", "level=2", "lang=c", "names=a,b", "src=a.c", "| a | b |\n", "\xc3",
}

next_rand :: proc(m: ^Mutator) -> u64 {
	m.rng += 0x9e3779b97f4a7c15
	z := m.rng
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

insert :: proc(m: ^Mutator, at: int, s: string) {
	s := s
	if len(m.text) + len(s) > MAX_INPUT {
		s = s[:MAX_INPUT - len(m.text)]
	}
	inject_at(&m.text, at, ..transmute([]u8)s)
}

mutate :: proc(m: ^Mutator, i: u64) -> string {
	m.rng = i * 0x9e3779b97f4a7c15 + 1
	clear(&m.text)
	append(&m.text, m.seeds[next_rand(m) % u64(len(m.seeds))])
	edits := 1 + next_rand(m) % 8
	for _ in 0 ..< edits {
		op := next_rand(m) % 6
		pos := int(next_rand(m) % u64(len(m.text) + 1))
		switch op {
		case 0:
			insert(m, pos, TOKENS[next_rand(m) % len(TOKENS)])
		case 1:
			n := min(int(next_rand(m) % 16), len(m.text) - pos)
			remove_range(&m.text, pos, pos + n)
		case 2:
			if pos < len(m.text) {
				m.text[pos] = u8(next_rand(m) % 256)
			}
		case 3:
			n := min(int(next_rand(m) % 64), len(m.text) - pos)
			to := int(next_rand(m) % u64(len(m.text) + 1))
			tmp: [64]u8
			copy(tmp[:], m.text[pos:pos + n])
			insert(m, to, string(tmp[:n]))
		case 4:
			o := m.seeds[next_rand(m) % u64(len(m.seeds))]
			a := int(next_rand(m) % u64(len(o) + 1))
			n := min(int(next_rand(m) % 128), len(o) - a)
			insert(m, pos, o[a:a + n])
		case:
			insert(m, pos, "\n")
		}
	}
	return string(m.text[:])
}

// Inputs the check runs; -define:GUIDE_MUTATED=N for more (the oracle's
// folds for the counts below are known; 1,000,000 was run once, 2026-10-05).
MUTATED :: #config(GUIDE_MUTATED, 5000)

@(test)
test_mutated :: proc(t: ^testing.T) {
	Fold :: struct {
		count: u64,
		fold:  u64,
	}
	folds := []Fold{{5000, 0x91d07e5ae368cc5f}, {20000, 0xa42ded177580a836}, {1_000_000, 0xcfd3f243cb598af1}}
	m := Mutator{seeds = seeds(), text = make([dynamic]u8, 0, MAX_INPUT + 1024)}
	defer delete(m.text)
	fold := FNV_OFFSET
	bad_utf := 0
	for i in 0 ..< u64(MUTATED) {
		page := mutate(&m, i)
		x := Transcript{h = FNV_OFFSET}
		transcript(t, &x, page)
		bad_utf += x.bad_utf
		fold = (fold ~ x.h) * FNV_PRIME
	}
	known := false
	for f in folds {
		if f.count == MUTATED {
			testing.expectf(t, fold == f.fold, "%d mutated: fold %x, upstream's %x", f.count, fold, f.fold)
			known = true
		}
	}
	testing.expectf(t, known, "%d mutated: fold %x, which the oracle has not been run for", MUTATED, fold)
	testing.expect_value(t, bad_utf, 0)
}
