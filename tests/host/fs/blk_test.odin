// Upstream's vxfs_test.c: lib/fs's block layer over a device in memory. XXH64
// against the reference implementation's values; packing; blocks written,
// read back and checked against their pointers' hashes, damage refused and
// sticky; arenas allocating and freeing, their logs replayed to the same free
// space, cut at a sync barrier, chained across blocks, and compressed; blocks
// freed now (this generation's) or kept for the deadlists (older); malformed
// tree blocks refused; a cache with every block held.
package fs_test

import "core:testing"
import vx "abi:vx"
import "vx:fs"

pattern_byte :: proc(i: int) -> u8 {
	return u8((i * 31 + 7) ~ (i >> 8))
}

@(test)
test_xxh64 :: proc(t: ^testing.T) {
	// From the reference implementation (libxxhash 0.8) over pattern_byte's bytes.
	Vector :: struct {
		len:  int,
		seed: u64,
		hash: u64,
	}
	vectors := []Vector {
		{0, 0x0000000000000000, 0xef46db3751d8e999},
		{0, 0x9e3779b97f4a7c15, 0xc4349fc93c010000},
		{1, 0x0000000000000000, 0xa96c7f0ce858bbb7},
		{1, 0x9e3779b97f4a7c15, 0x585882422a6165e7},
		{3, 0x0000000000000000, 0x56e6957632a487f9},
		{3, 0x9e3779b97f4a7c15, 0x5acb303e78133c22},
		{4, 0x0000000000000000, 0xc60d15b1e3ff8f04},
		{4, 0x9e3779b97f4a7c15, 0x7d51d5e2461732b3},
		{7, 0x0000000000000000, 0xafbefc3d6c6f9a8e},
		{7, 0x9e3779b97f4a7c15, 0x2ce9adec2b2c8104},
		{8, 0x0000000000000000, 0x3da5c7aa269683e0},
		{8, 0x9e3779b97f4a7c15, 0x758848f033fa76a2},
		{15, 0x0000000000000000, 0xae2a37eb9357caa7},
		{15, 0x9e3779b97f4a7c15, 0xa18d5c90d722cee3},
		{16, 0x0000000000000000, 0xa19ad429b02bc413},
		{16, 0x9e3779b97f4a7c15, 0xe3594f9058b426e7},
		{31, 0x0000000000000000, 0x4a74f3a1a39ad4a1},
		{31, 0x9e3779b97f4a7c15, 0x8137041f5af88413},
		{32, 0x0000000000000000, 0x8d57d6a4671cc43d},
		{32, 0x9e3779b97f4a7c15, 0x184ebcf3745cd46c},
		{33, 0x0000000000000000, 0x62c9fd21ed857664},
		{33, 0x9e3779b97f4a7c15, 0x52fac3c981f3cc2e},
		{63, 0x0000000000000000, 0x5c320a0d2707057f},
		{63, 0x9e3779b97f4a7c15, 0x64ef99a2e94cc7bd},
		{64, 0x0000000000000000, 0x7bbabbc45729d17e},
		{64, 0x9e3779b97f4a7c15, 0xf7f22435fe1ab128},
		{100, 0x0000000000000000, 0xefa0ad2d3e70c151},
		{100, 0x9e3779b97f4a7c15, 0xbc7ab33be7528c18},
		{1000, 0x0000000000000000, 0x6e487f236c0c63ec},
		{1000, 0x9e3779b97f4a7c15, 0x857708aaa1358a00},
		{16384, 0x0000000000000000, 0x53ed92d52f789284},
		{16384, 0x9e3779b97f4a7c15, 0x1fa3101ec8a4a74e},
	}
	buf := make([]u8, 16384)
	defer delete(buf)
	for &c, i in buf {
		c = pattern_byte(i)
	}
	for v in vectors {
		got := fs.xxh64(buf[:v.len], v.seed)
		testing.expectf(t, got == v.hash, "xxh64 of %d bytes, seed %x: %x, want %x", v.len, v.seed, got, v.hash)
	}
}

@(test)
test_packing :: proc(t: ^testing.T) {
	p: [fs.DIRSZ + 8]u8
	d := fs.Dir {
		flags    = 1,
		qid_path = 0x0102030405060708,
		qid_vers = 9,
		qid_type = 0x80,
		mode     = 0x800001ed,
		atime    = -1,
		mtime    = 2,
		ctime    = 3,
		btime    = 4,
		length   = 1 << 40,
		uid      = 10,
		gid      = 11,
		muid     = 12,
	}
	fs.pack_dir(p[:], d)
	testing.expect_value(t, p[fs.DIRSZ], 0) // nothing past its size
	testing.expect_value(t, fs.unpack_dir(p[:]), d)

	bp := fs.Bptr{0x4000, 0xdeadbeefcafef00d, 7}
	fs.pack_bptr(p[:], bp)
	testing.expect_value(t, fs.unpack_bptr(p[:]), bp)
	testing.expect_value(t, p[0], 0x00) // little-endian in blocks
	testing.expect_value(t, p[1], 0x40)

	// Big-endian in keys: they sort as their numbers do.
	a, b: [8]u8
	fs.kput64(a[:], 255)
	fs.kput64(b[:], 256)
	testing.expect_value(t, fs.keycmp(a[:], b[:]), -1)
	testing.expect_value(t, fs.kget64(b[:]), 256)
	testing.expect_value(t, fs.keycmp(a[:7], a[:]), -1)
	testing.expect_value(t, fs.keycmp(a[:], a[:7]), 1)
	testing.expect_value(t, fs.keycmp(a[:], a[:]), 0)
	testing.expect_value(t, fs.keycmp(a[:0], b[:0]), 0)
}

// --- Free space ---

// The arena's free ranges are sorted, disjoint, never adjacent, inside it,
// and with `used` add up to its size.
arena_sane :: proc(a: ^fs.Arena) -> bool {
	free: u64
	lo := u64(a.base) + B
	hi := lo + a.size
	for r, i in fs.items(&a.free) {
		if r.len == 0 || u64(r.off) < lo || u64(r.off) + r.len > hi || r.off % B != 0 || r.len % B != 0 {
			return false
		}
		if i > 0 && u64(a.free.buf[i - 1].off) + a.free.buf[i - 1].len >= u64(r.off) {
			return false
		}
		free += r.len
	}
	return free + a.used == a.size
}

arenas_equal :: proc(a, b: ^fs.Arena) -> bool {
	if a.free.n != b.free.n || a.used != b.used {
		return false
	}
	for r, i in fs.items(&a.free) {
		if r != b.free.buf[i] {
			return false
		}
	}
	return true
}

is_free :: proc(a: ^fs.Arena, addr: fs.Addr) -> bool {
	for r in fs.items(&a.free) {
		if addr >= r.off && u64(addr) < u64(r.off) + r.len {
			return true
		}
	}
	return false
}

@(test)
test_ranges :: proc(t: ^testing.T) {
	f := fs.Fs{mem = mem()}
	a := fs.Arena{base = 0, size = 64 * B}
	lo := fs.Addr(B)
	testing.expect(t, fs.range_free(&f, &a, lo, a.size))
	a.used = 0
	testing.expect_value(t, a.free.n, 1)
	testing.expect(t, arena_sane(&a))
	testing.expect(t, fs.range_grab(&f, &a, lo + 4 * B, 2 * B)) // the middle: two pieces
	a.used += 2 * B
	testing.expect_value(t, a.free.n, 2)
	testing.expect(t, arena_sane(&a))
	testing.expect(t, fs.range_grab(&f, &a, lo, B)) // the front
	testing.expect(t, fs.range_grab(&f, &a, lo + 63 * B, B)) // the end
	a.used += 2 * B
	testing.expect_value(t, a.free.n, 2)
	testing.expect(t, arena_sane(&a))
	testing.expect(t, !fs.range_grab(&f, &a, lo + 4 * B, B)) // not free
	testing.expect_value(t, f.err, vx.Status.Err_Invalid)
	f.err = .Ok
	testing.expect(t, !fs.range_free(&f, &a, lo + 10 * B, B)) // already free
	testing.expect_value(t, f.err, vx.Status.Err_Invalid)
	f.err = .Ok
	testing.expect(t, fs.range_free(&f, &a, lo + 5 * B, B)) // joins the range after it
	testing.expect(t, fs.range_free(&f, &a, lo + 4 * B, B)) // joins both: one range again, but the ends
	a.used -= 2 * B
	testing.expect_value(t, a.free.n, 1)
	testing.expect(t, arena_sane(&a))
	testing.expect(t, fs.range_free(&f, &a, lo, B))
	testing.expect(t, fs.range_free(&f, &a, lo + 63 * B, B))
	a.used -= 2 * B
	testing.expect_value(t, a.free.n, 1)
	testing.expect_value(t, a.free.buf[0], fs.Range{lo, a.size})
	testing.expect(t, arena_sane(&a))
	// Many small pieces, then joined back.
	for i := fs.Addr(0); i < 64; i += 2 {
		testing.expect(t, fs.range_grab(&f, &a, lo + i * B, B))
	}
	testing.expect_value(t, a.free.n, 32)
	for i := fs.Addr(0); i < 64; i += 2 {
		testing.expect(t, fs.range_free(&f, &a, lo + i * B, B))
	}
	testing.expect_value(t, a.free.n, 1)
	testing.expect_value(t, f.err, vx.Status.Ok)
	fs.vec_free(&f, &a.free)
}

// --- Blocks ---

fresh :: proc(t: ^testing.T, f: ^fs.Fs, d: ^Memdev, arenas: u32, blocks_each: u64, cache: u32, loc := #caller_location) {
	testing.expect(t, fs.open(f, dev_of(d), mem(), cache), loc = loc)
	testing.expect(t, fs.alloc_arenas(f, arenas), loc = loc)
	for &a, i in f.arenas {
		testing.expect(t, fs.arena_init(f, &a, fs.Addr(u64(i) * (blocks_each + 2) * B), blocks_each), loc = loc)
	}
}

@(test)
test_blocks :: proc(t: ^testing.T) {
	d := memdev_new(132)
	defer memdev_free(d)
	f := new(fs.Fs)
	defer free(f)
	fresh(t, f, d, 2, 64, 256)
	testing.expect_value(t, f.err, vx.Status.Ok)
	for &a in f.arenas {
		testing.expect_value(t, a.used, B)
		testing.expect(t, arena_sane(&a))
	}

	// A data block and a leaf, written, then read back by a fresh cache.
	b := fs.new_block(f, .Dat)
	testing.expect(t, b != nil)
	testing.expect_value(t, b.bp.gen, 1)
	for &c, i in fs.data(b) {
		c = pattern_byte(i)
	}
	testing.expect(t, fs.write_block(f, b))
	dat := b.bp
	fs.drop(f, b)

	l := fs.new_block(f, .Leaf)
	testing.expect(t, l != nil)
	// One entry: key "k", value "v", at the end of the leaf's space.
	at := fs.LEAFSPC - 6
	fs.put16(fs.data(l), u16(at))
	ent := [?]u8{1, 0, 'k', 1, 0, 'v'}
	copy(fs.data(l)[at:], ent[:])
	l.nval, l.valsz = 1, size_of(ent)
	testing.expect(t, fs.write_block(f, l))
	leaf := l.bp
	fs.drop(f, l)
	testing.expect(t, dat.addr != leaf.addr)
	testing.expect(t, dat.hash != 0)
	testing.expect(t, leaf.hash != 0)
	for &a in f.arenas {
		testing.expect(t, fs.log_flush(f, &a))
	}

	again := new(fs.Fs)
	defer free(again)
	testing.expect(t, fs.open(again, dev_of(d), mem(), 256))
	b = fs.get(again, dat, {.Dat})
	testing.expect(t, b != nil && fs.data(b)[100] == pattern_byte(100))
	testing.expect_value(t, again.reads, 1)
	fs.drop(again, b)
	b = fs.get(again, dat, {.Dat}) // from the cache
	testing.expect(t, b != nil)
	testing.expect_value(t, again.reads, 1)
	fs.drop(again, b)
	l = fs.get(again, leaf, fs.TREE)
	testing.expect(t, l != nil && l.type == .Leaf && l.nval == 1 && l.valsz == 6)
	fs.drop(again, l)
	testing.expect(t, fs.get(again, leaf, {.Pivot}) == nil) // not what it is
	testing.expect_value(t, again.err, vx.Status.Err_Invalid)
	fs.close(again)

	// Damage: one bit, and the hash refuses it; the error is sticky.
	testing.expect(t, fs.open(again, dev_of(d), mem(), 256))
	d.bytes[u64(dat.addr) + 5000] ~= 0x10
	testing.expect(t, fs.get(again, dat, {.Dat}) == nil)
	testing.expect_value(t, again.err, vx.Status.Err_Invalid)
	d.bytes[u64(dat.addr) + 5000] ~= 0x10
	testing.expect(t, fs.new_block(again, .Dat) == nil) // nothing more after an error
	fs.close(again)

	// The device's errors are passed on.
	testing.expect(t, fs.open(again, dev_of(d), mem(), 256))
	d.fail_reads = true
	testing.expect(t, fs.get(again, dat, {.Dat}) == nil)
	testing.expect_value(t, again.err, vx.Status.Err_Io)
	d.fail_reads = false
	fs.close(again)

	// Pointers outside the device, or not on a block.
	testing.expect(t, fs.open(again, dev_of(d), mem(), 256))
	testing.expect(t, fs.get(again, {addr = fs.Addr(len(d.bytes))}, {.Dat}) == nil)
	testing.expect_value(t, again.err, vx.Status.Err_Invalid)
	again.err = .Ok
	testing.expect(t, fs.get(again, {addr = 100}, {.Dat}) == nil)
	testing.expect_value(t, again.err, vx.Status.Err_Invalid)
	fs.close(again)

	fs.close(f)
	expect_digest(t, "blocks", d.bytes, 0x670ebe624df8d57b)
}

// A leaf of the entries given as {key, value} strings, finalized in place.
make_leaf :: proc(b: ^fs.Blk, kv: []string) {
	b.buf = {}
	b.type = .Leaf
	end := fs.LEAFSPC
	b.nval, b.valsz = u16(len(kv) / 2), 0
	d := fs.data(b)
	for i in 0 ..< len(kv) / 2 {
		k, v := kv[2 * i], kv[2 * i + 1]
		end -= 4 + len(k) + len(v)
		fs.put16(d[2 * i:], u16(end))
		p := d[end:]
		fs.put16(p, u16(len(k)))
		fs.put16(p[2 + len(k):], u16(len(v)))
		copy(p[2:], k) // the bytes alone, not a C string
		copy(p[4 + len(k):], v)
		b.valsz += u16(4 + len(k) + len(v))
	}
	fs.finalize(b)
}

@(test)
test_malformed :: proc(t: ^testing.T) {
	b := new(fs.Blk)
	defer free(b)
	good := []string{"a", "1", "b", "2", "c", "3"}
	Case :: struct {
		what:   string,
		kv:     []string,
		at:     int, // where a u16 is written over the finalized block, or -1
		at_ent: bool, // at is the first entry's offset (its key length)
		val:    u16,
		want:   fs.Block_Types,
		ok:     bool,
	}
	cases := []Case {
		{"good", good, -1, false, 0, {.Leaf}, true},
		{"disorder", {"b", "1", "a", "2"}, -1, false, 0, {.Leaf}, false},
		{"twice", {"a", "1", "a", "2"}, -1, false, 0, {.Leaf}, false},
		{"more entries than the space holds", good, 2, false, 4000, {.Leaf}, false},
		{"sizes that do not add up", good, 4, false, 1, {.Leaf}, false},
		{"an offset into the offsets", good, fs.LEAFHDSZ + 2, false, 1, {.Leaf}, false},
		{"an entry running off the end", good, fs.LEAFHDSZ, false, fs.LEAFSPC - 1, {.Leaf}, false},
		{"an empty key", good, 0, true, 0, {.Leaf}, false},
		{"no such type", good, 0, false, 9, fs.TREE, false},
		{"a leaf's entries as a pivot's: values are not pointers", good, 0, false, u16(fs.Block_Type.Pivot), fs.TREE, false},
		{"an empty leaf is a leaf (an empty tree's root)", good[:0], -1, false, 0, {.Leaf}, true},
	}
	for c in cases {
		make_leaf(b, c.kv)
		if c.at_ent {
			fs.put16(b.buf[fs.LEAFHDSZ + int(fs.get16(fs.data(b))):], c.val)
		} else if c.at >= 0 {
			fs.put16(b.buf[c.at:], c.val)
		}
		testing.expectf(t, fs.parse_block(b, c.want) == c.ok, "%s", c.what)
	}

	// A log whose own hash does not match.
	b.buf = {}
	b.type = .Log
	b.logsz = 8
	fs.put64(fs.data(b), B | u64(fs.Log_Op.Alloc1))
	fs.finalize(b)
	testing.expect(t, fs.parse_block(b, {.Log}))
	fs.data(b)[0] ~= 1
	testing.expect(t, !fs.parse_block(b, {.Log}))
}

// --- Arenas and their logs ---

// A fresh library over the same device, its arenas loaded as headers h say.
reload :: proc(t: ^testing.T, r: ^fs.Fs, d: ^Memdev, h: []fs.Arena_Hdr, loc := #caller_location) {
	testing.expect(t, fs.open(r, dev_of(d), mem(), 256), loc = loc)
	testing.expect(t, fs.alloc_arenas(r, u32(len(h))), loc = loc)
	for &a, i in r.arenas {
		testing.expect(t, fs.arena_load(r, &a, h[i]), loc = loc)
	}
}

// Every arena's log written, and what its header would say.
seal :: proc(t: ^testing.T, f: ^fs.Fs, h: []fs.Arena_Hdr, loc := #caller_location) {
	for &a, i in f.arenas {
		ok: bool
		h[i], ok = fs.arena_seal(f, &a)
		testing.expect(t, ok, loc = loc)
	}
}

copy_arena :: proc(a: ^fs.Arena) -> fs.Arena {
	c := a^
	c.free.buf = make([]fs.Range, a.free.n)
	copy(c.free.buf, fs.items(&a.free))
	return c
}

// A block taken from the arena and logged so.
take_logged :: proc(f: ^fs.Fs, a: ^fs.Arena) -> fs.Addr {
	o := fs.arena_take(f, a, false, false)
	return o != 0 && fs.log_append(f, a, o, B, .Alloc) ? o : 0
}

@(test)
test_logs :: proc(t: ^testing.T) {
	d := memdev_new(2052)
	defer memdev_free(d)
	f := new(fs.Fs)
	defer free(f)
	fresh(t, f, d, 2, 1024, 256)
	h: [2]fs.Arena_Hdr
	r := new(fs.Fs)
	defer free(r)

	// Allocations spread over both arenas, some freed: a reload sees the same.
	addr: [600]fs.Addr
	for i in 0 ..< 600 {
		if i == 300 {
			f.rr += 1 // as after a few thousand writes: the next arena
		}
		b := fs.new_block(f, .Dat)
		if !testing.expect(t, b != nil) {
			return
		}
		addr[i] = b.bp.addr
		testing.expect(t, fs.write_block(f, b))
		fs.drop(f, b)
	}
	testing.expect(t, f.arenas[0].used > B)
	testing.expect(t, f.arenas[1].used > B)
	for i := 0; i < 600; i += 3 {
		testing.expect(t, fs.block_dealloc(f, addr[i]))
	}
	for &a in f.arenas {
		testing.expect(t, arena_sane(&a))
	}
	seal(t, f, h[:])
	reload(t, r, d, h[:])
	testing.expect_value(t, r.err, vx.Status.Ok)
	for i in 0 ..< 2 {
		testing.expect(t, arenas_equal(&f.arenas[i], &r.arenas[i]))
	}
	fs.close(r)

	// A commit's header, then more logged and written: a reload by that header
	// sees the log as it was, even with the tail block written over since
	// (torn, here: its own header and hash garbage).
	a := &f.arenas[0]
	seal(t, f, h[:])
	before := copy_arena(a)
	for _ in 0 ..< 40 {
		testing.expect(t, take_logged(f, a) != 0)
	}
	testing.expect(t, fs.log_flush(f, a))
	for &c in d.bytes[h[0].logtl:][:12] { // type, size and hash
		c = 0xa5
	}
	reload(t, r, d, h[:])
	testing.expect_value(t, r.err, vx.Status.Ok)
	testing.expect(t, arenas_equal(&before, &r.arenas[0]))
	testing.expect_value(t, r.arenas[0].logtl.logsz, h[0].tailsz)
	fs.close(r)
	delete(before.free.buf)
	// A covered entry damaged: refused.
	d.bytes[u64(h[0].logtl) + fs.LOGHDSZ + 8] ~= 0x40
	bad := new(fs.Fs)
	defer free(bad)
	testing.expect(t, fs.open(bad, dev_of(d), mem(), 256) && fs.alloc_arenas(bad, 1))
	testing.expect(t, !fs.arena_load(bad, &bad.arenas[0], h[0]))
	testing.expect_value(t, bad.err, vx.Status.Err_Invalid)
	fs.close(bad)
	d.bytes[u64(h[0].logtl) + fs.LOGHDSZ + 8] ~= 0x40
	seal(t, f, h[:])
	reload(t, r, d, h[:])
	testing.expect_value(t, r.err, vx.Status.Ok)
	testing.expect(t, arenas_equal(a, &r.arenas[0]))
	fs.close(r)

	// Enough to chain the log across blocks.
	nlog := a.nlog
	for _ in 0 ..< 6 {
		got: [300]fs.Addr
		n := 0
		for ; n < 300; n += 1 {
			got[n] = take_logged(f, a)
			if got[n] == 0 {
				break
			}
		}
		for g in got[:n] {
			testing.expect(t, fs.block_dealloc(f, g))
		}
	}
	testing.expect(t, a.nlog > nlog)
	testing.expect(t, arena_sane(a))
	seal(t, f, h[:])
	reload(t, r, d, h[:])
	testing.expect_value(t, r.err, vx.Status.Ok)
	testing.expect(t, arenas_equal(a, &r.arenas[0]))
	testing.expect_value(t, r.arenas[0].nlog, a.nlog)
	fs.close(r)
	// A header whose tail is not on the chain: refused.
	wrong := h[0]
	wrong.logtl = wrong.base + 900 * B
	testing.expect(t, fs.open(bad, dev_of(d), mem(), 256) && fs.alloc_arenas(bad, 1))
	testing.expect(t, !fs.arena_load(bad, &bad.arenas[0], wrong))
	testing.expect_value(t, bad.err, vx.Status.Err_Invalid)
	fs.close(bad)

	// Compressed: the free ranges alone, in fewer blocks. The old chain stays
	// taken until it is retired (deferred) and the deferred blocks freed, after
	// the commit; only then do the logs say it is free.
	old_head, longer := a.loghd.addr, a.nlog
	testing.expect(t, fs.log_compress(f, a))
	testing.expect(t, a.nlog < longer)
	testing.expect(t, a.loghd.addr != old_head)
	testing.expect_value(t, u64(len(a.retired)), longer)
	testing.expect(t, arena_sane(a))
	testing.expect(t, !is_free(a, old_head))
	testing.expect(t, !fs.log_compress(f, a)) // not again before the commit
	testing.expect_value(t, f.err, vx.Status.Err_Bad_State)
	f.err = .Ok
	seal(t, f, h[:])
	reload(t, r, d, h[:])
	testing.expect_value(t, r.err, vx.Status.Ok)
	testing.expect(t, !is_free(&r.arenas[0], old_head))
	testing.expect(t, arena_sane(&r.arenas[0]))
	testing.expect(t, arenas_equal(a, &r.arenas[0]))
	fs.close(r)
	testing.expect(t, fs.log_retire(f, a))
	testing.expect_value(t, u64(f.deferred.n), longer)
	testing.expect(t, !is_free(a, old_head))
	testing.expect(t, fs.free_deferred(f))
	testing.expect(t, is_free(a, old_head))
	testing.expect(t, arena_sane(a))
	testing.expect_value(t, f.deferred.n, 0)
	seal(t, f, h[:])
	reload(t, r, d, h[:])
	testing.expect_value(t, r.err, vx.Status.Ok)
	testing.expect(t, is_free(&r.arenas[0], old_head))
	testing.expect(t, arenas_equal(a, &r.arenas[0]))
	fs.close(r)

	// A loop in a log's chain is refused, not followed for ever.
	tl := a.logtl
	tl.logp = a.loghd
	testing.expect(t, fs.write_block(f, tl))
	wrong = h[0]
	wrong.logtl = wrong.base + 1000 * B // not on the chain, which loops
	testing.expect(t, fs.open(bad, dev_of(d), mem(), 256) && fs.alloc_arenas(bad, 1))
	testing.expect(t, !fs.arena_load(bad, &bad.arenas[0], wrong))
	testing.expect_value(t, bad.err, vx.Status.Err_Invalid)
	fs.close(bad)

	fs.close(f)
	expect_digest(t, "logs", d.bytes, 0xecb37cc300a239b7)
}

// Freeing, by the tree a block left: this generation's at the operation's
// end; a branch's older ones killed, or left to the branch they came from; the
// snapshot tree's deferred.
@(test)
test_free :: proc(t: ^testing.T) {
	d := memdev_new(66)
	defer memdev_free(d)
	f := new(fs.Fs)
	defer free(f)
	fresh(t, f, d, 1, 64, 256)
	a := &f.arenas[0]
	bp: [4]fs.Bptr
	for &p in bp {
		b := fs.new_block(f, .Dat)
		p = b.bp
		fs.drop(f, b)
	}
	testing.expect_value(t, bp[0].gen, 1)
	f.gen = 2 // committed since: they are the last commit's
	b := fs.new_block(f, .Dat)
	now := b.bp
	fs.drop(f, b)
	testing.expect(t, fs.free_block(f, now))
	testing.expect(t, fs.free_block(f, bp[0]))
	testing.expect_value(t, f.limbo.n, 1)
	testing.expect_value(t, f.dead.n, 1)
	testing.expect(t, !is_free(a, now.addr))
	testing.expect_value(t, f.dead.buf[0], fs.Dead{bp[0].addr, 1, 2})
	testing.expect(t, fs.end_op(f))
	testing.expect_value(t, f.limbo.n, 0)
	testing.expect(t, is_free(a, now.addr))
	testing.expect(t, arena_sane(a))
	f.base = 1 // a branch forked at 1: its blocks born then are the other branch's
	testing.expect(t, fs.free_block(f, bp[1]))
	testing.expect_value(t, f.dead.n, 1)
	testing.expect_value(t, f.deferred.n, 0)
	f.base, f.snaptree = 0, true
	testing.expect(t, fs.free_block(f, bp[2]))
	testing.expect_value(t, f.deferred.n, 1)
	testing.expect(t, !is_free(a, bp[2].addr))
	testing.expect(t, fs.free_deferred(f))
	testing.expect(t, is_free(a, bp[2].addr))
	testing.expect(t, arena_sane(a))
	f.snaptree = false

	// Full: every block taken, then NO_SPACE (room says so first, with nothing
	// changed); the reserve is the commit's.
	n := 0
	a.reserve = 4 * B
	for fs.new_block(f, .Dat) != nil {
		n += 1
	}
	testing.expect_value(t, f.err, vx.Status.Err_No_Space)
	testing.expect_value(t, fs.room(f, 0, false), vx.Status.Err_No_Space)
	f.err = .Ok
	testing.expect_value(t, fs.room(f, 0, false), vx.Status.Err_No_Space) // a refusal, not a failure
	testing.expect_value(t, f.err, vx.Status.Ok)
	f.use_reserve = true
	more := 0
	for fs.new_block(f, .Dat) != nil {
		more += 1
	}
	testing.expect_value(t, f.err, vx.Status.Err_No_Space)
	testing.expect_value(t, more, 4)
	testing.expect_value(t, n + more, 64 - 4) // the log, bp[0], bp[1] and bp[3] held
	fs.close(f)
	expect_digest(t, "free", d.bytes, 0x717bc4d3566062b3)
}

// M5 step 10's close-out of the block layer: a log block's header is in its
// hash (its chain pointer damaged is found), and a failed write leaves the
// volume failed and the block not dirty.
@(test)
test_close_out :: proc(t: ^testing.T) {
	d := memdev_new(1026)
	defer memdev_free(d)
	f := new(fs.Fs)
	defer free(f)
	fresh(t, f, d, 1, 1024, 8)
	a := &f.arenas[0]
	took := true
	for i := 0; i < 1200 && took; i += 1 { // a log block holds about 2000 one-block entries: two each here
		at := take_logged(f, a)
		took = at != 0 && fs.block_dealloc(f, at)
	}
	testing.expect(t, took)
	testing.expect(t, fs.log_flush(f, a))
	testing.expect(t, a.nlog >= 2)
	head := a.loghd
	b := fs.get(f, head, {.Log})
	testing.expect(t, b != nil)
	fs.drop(f, b)
	fs.cache_forget(f, head.addr)
	d.bytes[u64(head.addr) + 12] ~= 1 // the chain's next pointer
	testing.expect(t, fs.get(f, head, {.Log}) == nil)
	testing.expect(t, f.err != .Ok)
	fs.close(f)

	fresh(t, f, d, 1, 1024, 8)
	w := fs.new_block(f, .Dat)
	d.fail_writes = true
	testing.expect(t, !fs.write_block(f, w))
	testing.expect_value(t, f.err, vx.Status.Err_Io)
	testing.expect(t, .Dirty not_in w.flags)
	fs.drop(f, w)
	d.fail_writes = false
	fs.close(f)
	expect_digest(t, "close_out", d.bytes, 0x3f68fbf5a9523088)
}

// Every block in the cache held, and one more wanted.
@(test)
test_cache :: proc(t: ^testing.T) {
	d := memdev_new(1026)
	defer memdev_free(d)
	f := new(fs.Fs)
	defer free(f)
	fresh(t, f, d, 1, 1024, 8) // raised to the least it takes
	testing.expect_value(t, len(f.blocks), fs.MINCACHE)
	n := 0
	for ; n < len(f.blocks); n += 1 {
		if fs.new_block(f, .Dat) == nil {
			break
		}
	}
	testing.expect_value(t, n, len(f.blocks) - 1) // the log's open block is held too
	testing.expect_value(t, f.err, vx.Status.Err_No_Memory)
	fs.close(f)

	// A dirty block dropped is not evicted: its contents would be lost.
	fresh(t, f, d, 1, 1024, 8)
	dirty := fs.new_block(f, .Dat)
	fs.data(dirty)[0] = 0x5a
	fs.drop(f, dirty)
	for _ in 0 ..< 200 {
		b := fs.new_block(f, .Dat)
		if !testing.expect(t, b != nil && b != dirty) {
			break
		}
		testing.expect(t, fs.write_block(f, b))
		fs.drop(f, b)
	}
	testing.expect_value(t, fs.data(dirty)[0], 0x5a)
	testing.expect(t, .Cached in dirty.flags)
	fs.close(f)
	expect_digest(t, "cache", d.bytes, 0xd0ad7b18a1d72438)
}
