// The cross-check against upstream's rc.c, built with clang and run with the
// same hosts (tests/host/rctest's, in C: rc_test.c's, and rc_fuzz.c's
// minimal one): each input runs twice in a fresh interpreter with a step
// budget, as upstream's fuzzer runs it, and the digest of the transcript
// (every host callback, with its arguments, every output, and each run's
// result, error and $status) is upstream's.
//
// The inputs: upstream's fuzz corpus; seeds (the corpus, upstream's test
// scripts in cases.rc and blocks.rc, more in xcheck.rc, and
// tests/user/rctest.rc); and inputs the mutator makes from them. Each at
// upstream's heap sizes from 4 MiB down to 64 KiB, where scripts run out of
// memory as they compile or run.
//
// The digests are those of upstream's rc.c at its M6 step 6a6c (f33715d;
// 3cb6968 is the same rc.c). Its host has exists, read_line (its standard
// input rctest's STDIN) and two builtins more: note N calls rc_trap, and
// exportx lists the functions too; each callback is logged as the others
// are, and a pipeline's statuses are joined by rc_concstatus. Two
// differences are kept out of the comparison: the oracle's rc.c is patched
// to call no close as a here document's redirection is undone (upstream
// closes handle 0), and a pipeline stage's here document is not read
// (upstream's text has been freed by then); api_test checks both.
package rc_test

import "core:testing"
import rt "../rctest"

CORPUS := #load_directory("corpus")
CASES :: #load("cases.rc", string)
XCHECK :: #load("xcheck.rc", string)
RCTEST :: #load("../../user/rctest.rc", string)
BLOCKS :: #load("blocks.rc", string)

corpus_file :: proc(name: string) -> string {
	for f in CORPUS {
		if f.name == name {
			return string(f.data)
		}
	}
	return ""
}

mutator :: proc() -> rt.Mutator {
	return rt.mutator_make(corpus_file("script"), corpus_file("words"), CASES, XCHECK, RCTEST, BLOCKS)
}

// Heaps as upstream's: its size, less its interpreter.
BIG_HEAP :: 4 << 20 - rt.C_RC_SIZE
MID_HEAP :: 300_000 - rt.C_RC_SIZE
SMALL_HEAP :: 64 << 10 - rt.C_RC_SIZE
FUZZ_HEAP :: 8 << 20 - rt.C_RC_SIZE // upstream's rc_fuzz.c

@(test)
test_corpus :: proc(t: ^testing.T) {
	Case :: struct {
		name:   string,
		digest: u64,
	}
	// From upstream's rc_fuzz.c driver and host, built with clang, logging.
	cases := []Case {
		{"script", 0xcee067c8e8737338}, // lists, for, if, `{}, switch, ||, |, fn, $*, $"*
		{"words", 0xd6616c534890f036}, // quotes, subscripts, = in a word, globs, >[2=1], <<<, a continued line
	}
	testing.expect_value(t, len(CORPUS), len(cases))
	b := rt.bench_make(FUZZ_HEAP, minimal = true)
	defer rt.bench_destroy(b)
	for c in cases {
		data := corpus_file(c.name)
		if !testing.expectf(t, data != "", "corpus file %s is missing", c.name) {
			continue
		}
		testing.expect(t, rt.transcript(b, data))
		digest := rt.fnv(rt.FNV_OFFSET, b.host.log[:])
		testing.expectf(t, digest == c.digest, "%s: digest %x, upstream's %x", c.name, digest, c.digest)
	}
}

// The fold of every input's transcript, in order.
Fold :: struct {
	heap:    int,
	minimal: bool, // rc_fuzz.c's host
	fold:    u64,
}

@(test)
test_seeds :: proc(t: ^testing.T) {
	m := mutator()
	defer rt.mutator_destroy(&m)
	testing.expect_value(t, len(m.seeds), 209)
	folds := []Fold {
		{BIG_HEAP, false, 0x9ee6b4e90d255fa3},
		{MID_HEAP, false, 0x88a6d41756bba011},
		{SMALL_HEAP, false, 0x9ecfe7440df5cc88},
		{SMALL_HEAP, true, 0xb81f236671177567},
	}
	for f in folds {
		b := rt.bench_make(f.heap, f.minimal)
		defer rt.bench_destroy(b)
		fold := rt.FNV_OFFSET
		for seed in m.seeds {
			testing.expect(t, rt.transcript(b, seed))
			fold = rt.fnv(fold, b.host.log[:])
		}
		testing.expectf(t, fold == f.fold, "heap %d, minimal %v: fold %x, upstream's %x", f.heap, f.minimal, fold, f.fold)
	}
}

MUTATED :: 3000 // inputs at each heap size

@(test)
test_mutated :: proc(t: ^testing.T) {
	m := mutator()
	defer rt.mutator_destroy(&m)
	folds := []Fold {
		{BIG_HEAP, false, 0xcbbb6627171ebd02},
		{MID_HEAP, false, 0x6fe271635936af10},
		{SMALL_HEAP, false, 0x95cbd01cf8b0ed45},
		{FUZZ_HEAP, true, 0xa1ffb2fd140e029d},
		{SMALL_HEAP, true, 0x2e7dff460f2a6e58},
	}
	text: [dynamic]u8
	defer delete(text)
	for f in folds {
		b := rt.bench_make(f.heap, f.minimal)
		defer rt.bench_destroy(b)
		fold := rt.FNV_OFFSET
		for i in 0 ..< u64(MUTATED) {
			rt.mutate(&m, i, &text)
			testing.expect(t, rt.transcript(b, string(text[:])))
			fold = rt.fnv(fold, b.host.log[:])
		}
		testing.expectf(t, fold == f.fold, "heap %d, minimal %v: fold %x, upstream's %x", f.heap, f.minimal, fold, f.fold)
	}
}
