// Upstream's vxfs_fuzz.c over its corpus (tests/fuzz/corpus/vxfs), and over
// inputs a mutator makes from it: arbitrary bytes for lib/fs. The first byte
// picks what they are. As messages, they go to a tree in batches: whatever
// the tree accepts, a scan must give keys in order whose lookups agree, and no
// batch may fault. As a block, the first byte picks a pivot, a leaf or a log.
// The next bytes, up to 64 of them, are the header and the front of the
// block, and the rest go at its end, where a table's entries are. A tree block
// that parse_block accepts must have every entry inside the block. A log (its
// own hash made to match) is replayed as an arena's whole log, and an arena
// it accepts must have sane free space.
//
// Each input's outcome goes into a transcript (a tree block parsed or not and
// its header; a log's load and the arena it left; each batch's status, the
// scan's count and digest), and the transcript's digest is upstream's: its
// fuzzer, built with clang with the same lines printed, over the same inputs.
package fs_test

import "core:fmt"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:fs"

CORPUS := #load_directory("corpus")

FUZZ_ARENA_BLOCKS :: 192
FUZZ_MUTATED :: 3000

// What upstream's fuzzer keeps in statics: its disk (not cleared between
// inputs but by a log), its block, and its batch's arrays.
Fuzz :: struct {
	t:    ^testing.T,
	name: string,
	disk: []u8,
	b:    ^fs.Blk,
	keys: [1024][8]u8,
	vals: [1024][fs.INLMAX]u8,
	m:    [1024]fs.Msg,
	out:  strings.Builder,
}

fuzz_dev :: proc(fz: ^Fuzz) -> fs.Dev {
	rd :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
		copy(buf[:], (^Fuzz)(ctx).disk[addr:][:B])
		return .Ok
	}
	wr :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
		copy((^Fuzz)(ctx).disk[addr:][:B], buf[:])
		return .Ok
	}
	br :: proc "contextless" (_: rawptr) -> vx.Status {
		return .Ok
	}
	return {ctx = fz, read = rd, write = wr, barrier = br, size = u64(len(fz.disk))}
}

// Every entry of a table that check_table accepted, read to its end.
fuzz_walk :: proc(fz: ^Fuzz, d: []u8, n: u16, msgs: bool) {
	for i in 0 ..< int(n) {
		at := int(fs.get16(d[2 * i:])) + (msgs ? 1 : 0)
		nk := int(fs.get16(d[at:]))
		nv := int(fs.get16(d[at + 2 + nk:]))
		testing.expectf(fz.t, at + 4 + nk + nv <= len(d), "%s: entry %d runs off its table", fz.name, i)
	}
}

// Messages from bytes: op, key length (1-8), key bytes from a small alphabet,
// value length; the value is the length's byte repeated, times 8.
fuzz_messages :: proc(fz: ^Fuzz, data: []u8) {
	t := fz.t
	f := new(fs.Fs)
	defer free(f)
	if !fs.open(f, fuzz_dev(fz), mem(), 0) || !fs.alloc_arenas(f, 1) || !fs.arena_init(f, &f.arenas[0], 0, FUZZ_ARENA_BLOCKS) {
		testing.expectf(t, false, "%s: no arena", fz.name)
		return
	}
	defer fs.close(f)
	tr: fs.Tree
	if !testing.expect(t, fs.tree_init(f, &tr)) {
		return
	}
	n, bytes := 0, 0
	cnt, dig := u32(0), u64(0)
	for at := 0; at + 3 <= len(data) && f.err == .Ok; {
		op := fs.Op(1 + data[at] % 4) // insert, delete, clearb, clobber; wstat needs entries
		nk, nv := 1 + int(data[at + 1] % 8), int(data[at + 2] % 65) * 8
		at += 3
		if at + nk > len(data) {
			break
		}
		if op != .Insert {
			nv = 0
		}
		sz := 2 + 1 + 2 + nk + 2 + nv
		if bytes + sz > fs.BUFSPC || n == len(fz.m) { // a batch: the tree takes it, or calls it damaged and stops
			st := fs.upsert(f, &tr, fz.m[:n])
			testing.expectf(t, st == .Ok || st == .Err_Invalid, "%s: a batch: %v", fz.name, st)
			fmt.sbprintf(&fz.out, "batch %d\n", i32(st))
			if st != .Ok || !fs.end_op(f) {
				break
			}
			n, bytes = 0, 0
		}
		k := fz.keys[n][:nk]
		for &c, i in k {
			c = data[at + i] % 6
		}
		at += nk
		v := fz.vals[n][:nv]
		for &c in v {
			c = u8(nv)
		}
		fz.m[n] = {op = op, key = k, val = nv > 0 ? v : nil}
		n += 1
		bytes += sz
	}
	if f.err == .Ok && n > 0 && fs.upsert(f, &tr, fz.m[:n]) == .Ok {
		_ = fs.end_op(f)
	}
	if f.err == .Ok {
		s: fs.Scan
		fs.scan_start(&s, &tr, nil)
		prev: [fs.KEYMAX]u8
		nprev := 0
		got: [fs.INLMAX]u8
		first := true
		for kv in fs.scan_next(f, &s) {
			testing.expectf(t, first || fs.keycmp(prev[:nprev], kv.key) < 0, "%s: a scan out of order", fz.name)
			val, st := fs.lookup(f, &tr, kv.key, &got)
			testing.expectf(t, st == .Ok && bytes_eq(val, kv.val), "%s: a lookup disagrees with the scan", fz.name)
			cnt += 1
			dig = fs.xxh64(kv.key, dig)
			dig = fs.xxh64(kv.val, dig)
			nprev = copy(prev[:], kv.key)
			first = false
		}
		testing.expectf(t, f.err == .Ok, "%s: a scan failed: %v", fz.name, f.err)
		fs.scan_end(f, &s)
	}
	fmt.sbprintf(&fz.out, "msg %d %d %016x\n", i32(f.err), cnt, dig)
}

fuzz_one :: proc(fz: ^Fuzz, input: []u8) {
	t := fz.t
	b := fz.b
	if len(input) < 1 {
		return
	}
	if input[0] % 4 == 3 {
		fuzz_messages(fz, input[1:]) // every block it reads it wrote first
		return
	}
	types := [3]fs.Block_Type{.Pivot, .Leaf, .Log}
	type := types[input[0] % 4]
	data := input[1:]
	b.buf = {}
	fs.put16(b.buf[:], u16(type))
	front := min(len(data), 64)
	copy(b.buf[2:], data[:front])
	copy(b.buf[B - (len(data) - front):], data[front:])

	if type != .Log {
		ok := fs.parse_block(b, fs.TREE)
		if ok {
			fmt.sbprintf(&fz.out, "tree 1 %d %d %d %d %d\n", u16(b.type), b.nval, b.valsz, b.nbuf, b.bufsz)
		} else {
			fmt.sbprintf(&fz.out, "tree 0 0 0 0 0 0\n")
			return
		}
		if b.type == .Pivot {
			fuzz_walk(fz, fs.pivot_kids(b), b.nval, false)
			fuzz_walk(fz, fs.pivot_msgs(b), b.nbuf, true)
		} else {
			fuzz_walk(fz, fs.vals(b), b.nval, false)
		}
		return
	}

	// A log at the arena's first block, replayed as a header says. As the tail
	// (the first byte's top bit clear): its covered prefix's hash made to
	// match. As a whole block before the tail: its hash made to match (as the
	// log hash was before M5 step 10 put the header in it), and its chain led
	// to an empty tail.
	whole := input[0] & 0x80 != 0
	logsz := fs.get16(b.buf[2:])
	if logsz > fs.LOGSPC {
		return
	}
	h := fs.Arena_Hdr{blocks = FUZZ_ARENA_BLOCKS, loghd = B, logtl = B, tailsz = logsz}
	for &c in fz.disk {
		c = 0
	}
	if whole {
		fs.pack_bptr(b.buf[12:], {addr = 2 * B})
		fs.put64(b.buf[4:], fs.xxh64(b.buf[fs.LOGHDSZ:][:logsz], 0))
		h.logtl, h.tailsz, h.tailhash = 2 * B, 0, fs.xxh64(fz.disk[:0], 0)
	} else {
		h.tailsz &~= 7
		h.tailhash = fs.xxh64(b.buf[fs.LOGHDSZ:][:h.tailsz], 0)
	}
	copy(fz.disk[B:][:B], b.buf[:])
	f := new(fs.Fs)
	defer free(f)
	if !testing.expect(t, fs.open(f, fuzz_dev(fz), mem(), 0) && fs.alloc_arenas(f, 1)) {
		return
	}
	a := &f.arenas[0]
	if fs.arena_load(f, a, h) {
		testing.expectf(t, arena_sane(a), "%s: a log loaded to insane free space", fz.name)
		// It goes on: all it has allocated but two (for the log to chain), then freed.
		got: [FUZZ_ARENA_BLOCKS]fs.Addr
		room := (a.size - a.used) / B
		n := 0
		for u64(n + 2) < room {
			got[n] = fs.block_alloc(f, .Dat)
			if got[n] == 0 {
				break
			}
			n += 1
		}
		for g in got[:n] {
			testing.expectf(t, fs.block_dealloc(f, g), "%s: a block allocated would not free", fz.name)
		}
		testing.expectf(t, f.err == .Ok && arena_sane(a) && !fs.range_has(a, B) && !fs.range_has(a, h.logtl), "%s: the arena went wrong after its load", fz.name)
	}
	fmt.sbprintf(&fz.out, "log %d %d %d %d\n", i32(f.err), a.free.n, a.used, a.nlog)
	fs.close(f)
}

// The mutator upstream's driver has too: a corpus file, changed one to eight
// times (a bit flipped, a byte set, cut short, a byte inserted).
Mutator :: struct {
	corp: [4][]u8,
	buf:  [1100]u8,
}

mutate :: proc(m: ^Mutator, i: u64) -> []u8 {
	r := Rng{(i + 1) * 0x9E3779B97F4A7C15}
	base := m.corp[i % 4]
	n := copy(m.buf[:], base)
	times := 1 + rnd(&r) % 8
	for _ in 0 ..< times {
		switch rnd(&r) % 4 {
		case 0:
			if n > 0 {
				pos := int(rnd(&r) % u64(n))
				m.buf[pos] ~= u8(1) << (rnd(&r) % 8)
			}
		case 1:
			if n > 0 {
				pos := int(rnd(&r) % u64(n))
				m.buf[pos] = u8(rnd(&r))
			}
		case 2:
			n = int(rnd(&r) % u64(n + 1))
		case 3:
			if n < 1024 {
				pos := int(rnd(&r) % u64(n + 1))
				copy(m.buf[pos + 1:n + 1], m.buf[pos:n])
				m.buf[pos] = u8(rnd(&r))
				n += 1
			}
		}
	}
	return m.buf[:n]
}

@(test)
test_fuzz :: proc(t: ^testing.T) {
	fz := new(Fuzz)
	defer free(fz)
	fz.t = t
	fz.disk = make([]u8, (FUZZ_ARENA_BLOCKS + 2) * B)
	defer delete(fz.disk)
	fz.b = new(fs.Blk)
	defer free(fz.b)
	fz.out = strings.builder_make()
	defer strings.builder_destroy(&fz.out)
	Case :: struct {
		name:   string,
		digest: u64,
	}
	// The transcripts' digests from upstream's fuzzer, as above.
	cases := []Case {
		{"leaf", 0xa035047134d837ea}, // a leaf of two entries
		{"log", 0x262c7438a139beae}, // a log's covered tail
		{"log-zero-free", 0x262c7438a139beae}, // a free of length 0 in it
		{"messages", 0x3ad9118fc0b5dc47}, // inserts, deletes, clearbs and clobbers over a small alphabet
	}
	testing.expect_value(t, len(CORPUS), len(cases))
	m: Mutator
	for c, i in cases {
		data: []u8
		for f in CORPUS {
			if f.name == c.name {
				data = f.data
			}
		}
		if !testing.expectf(t, data != nil, "corpus file %s is missing", c.name) {
			continue
		}
		m.corp[i] = data
		strings.builder_reset(&fz.out)
		fz.name = c.name
		fuzz_one(fz, data)
		got := fs.xxh64(fz.out.buf[:], 0)
		testing.expectf(t, got == c.digest, "%s: transcript %016x, upstream's %016x:\n%s", c.name, got, c.digest, strings.to_string(fz.out))
	}
	strings.builder_reset(&fz.out)
	for i in 0 ..< u64(FUZZ_MUTATED) {
		fz.name = fmt.tprintf("mutated %d", i)
		fuzz_one(fz, mutate(&m, i))
	}
	got := fs.xxh64(fz.out.buf[:], 0)
	testing.expectf(t, got == 0xa7c5efa87e26be8a, "mutated: transcript %016x, upstream's a7c5efa87e26be8a", got)
	testing.expect_value(t, len(fz.out.buf), 58416)
}
