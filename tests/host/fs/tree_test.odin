// Upstream's vxfs_tree_test.c: lib/fs's Bε tree against a model. Random
// batches of messages (inserts, deletes, clobbers, wstats, data blocks set
// and cleared) go to the tree and to a sorted array. After each, lookups and
// scans must agree with the array. The tree's structure is walked: every
// block checks, the height is the same everywhere, each key is in its node's
// range, the fills are right. Space must add up: the arena's used blocks are
// exactly the tree's, the data blocks the values name, and the log's. The
// tree is grown to three levels and emptied back to a leaf; malformed batches
// are refused; damaged messages make errors, not faults. And what each run
// leaves on its device is what upstream's leaves.
package fs_test

import "core:fmt"
import "core:log"
import "core:testing"
import vx "abi:vx"
import "vx:fs"

TREE_ARENA_BLOCKS :: 2048

Entry :: struct {
	k:  [fs.KEYMAX]u8,
	v:  [fs.INLMAX]u8,
	nk: int,
	nv: int,
}

entry_key :: proc(e: ^Entry) -> []u8 {
	return e.k[:e.nk]
}

entry_val :: proc(e: ^Entry) -> []u8 {
	return e.v[:e.nv]
}

Tree_World :: struct {
	dev:   ^Memdev,
	f:     fs.Fs,
	t:     fs.Tree,
	rng:   Rng,
	model: [dynamic]Entry, // sorted by key
}

tw_open :: proc(t: ^testing.T, w: ^Tree_World) {
	w.dev = memdev_new(2 * (TREE_ARENA_BLOCKS + 2))
	testing.expect(t, fs.open(&w.f, dev_of(w.dev), mem(), 512))
	testing.expect(t, fs.alloc_arenas(&w.f, 2))
	for &a, i in w.f.arenas {
		testing.expect(t, fs.arena_init(&w.f, &a, fs.Addr(u64(i) * (TREE_ARENA_BLOCKS + 2) * B), TREE_ARENA_BLOCKS))
	}
	w.t = {}
	testing.expect(t, fs.tree_init(&w.f, &w.t))
	testing.expect(t, fs.end_op(&w.f))
}

tw_close :: proc(w: ^Tree_World) {
	fs.close(&w.f)
	memdev_free(w.dev)
	delete(w.model)
	w.model = nil
}

used_blocks :: proc(f: ^fs.Fs) -> u64 {
	n: u64
	for &a in f.arenas {
		n += a.used / B - a.nlog
	}
	return n
}

// --- The model: sorted keys and their values ---

model_find :: proc(w: ^Tree_World, k: []u8) -> (i: int, found: bool) {
	lo, hi := 0, len(w.model)
	for lo < hi {
		mid := (lo + hi) / 2
		if fs.keycmp(entry_key(&w.model[mid]), k) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo, lo < len(w.model) && fs.keycmp(entry_key(&w.model[lo]), k) == 0
}

model_set :: proc(w: ^Tree_World, k, v: []u8) {
	i, found := model_find(w, k)
	if !found {
		e: Entry
		e.nk = copy(e.k[:], k)
		inject_at(&w.model, i, e)
	}
	w.model[i].nv = copy(w.model[i].v[:], v)
}

model_del :: proc(w: ^Tree_World, k: []u8) {
	if i, found := model_find(w, k); found {
		ordered_remove(&w.model, i)
	}
}

// --- The tree's structure ---

Walk :: struct {
	blocks: u64, // tree blocks
	refs:   u64, // data blocks named in values and buffered inserts
	ok:     bool,
	disk:   ^fs.Blk,
}

// Node bp at `level`; every key in it, buffered or not, in [lo, hi) (nil:
// unbounded).
walk_node :: proc(f: ^fs.Fs, bp: fs.Bptr, level: u32, lo, hi: []u8, fill: u16, w: ^Walk) {
	b := fs.get(f, bp, {level == 1 ? .Leaf : .Pivot})
	if b == nil {
		w.ok = false
		return
	}
	defer fs.drop(f, b)
	w.blocks += 1
	if fill != 0xffff && fill != fs.blk_fill(b) {
		w.ok = false
	}
	// As the device has it, not only as the cache does: what a remount reads.
	w.disk^ = {}
	if f.dev.read(f.dev.ctx, bp.addr, &w.disk.buf) != .Ok || !fs.parse_block(w.disk, {b.type}) {
		w.ok = false
	}
	for i in 0 ..< int(b.nval) {
		v := fs.tab_get(fs.vals(b), i, false)
		in_range := (lo == nil || fs.keycmp(v.key, lo) >= 0 || (level > 1 && i == 0)) && (hi == nil || fs.keycmp(v.key, hi) < 0)
		if !in_range {
			w.ok = false
		}
		if level == 1 && fs.owns_block(v.key, v.val) {
			w.refs += 1
		}
	}
	for i in 0 ..< int(b.nbuf) {
		m := fs.tab_get(fs.pivot_msgs(b), i, true)
		if (lo != nil && fs.keycmp(m.key, lo) < 0) || (hi != nil && fs.keycmp(m.key, hi) >= 0) {
			w.ok = false
		}
		if m.op == .Insert && fs.owns_block(m.key, m.val) {
			w.refs += 1
		}
	}
	if level > 1 {
		if b.nval == 0 {
			w.ok = false
		}
		for i in 0 ..< int(b.nval) {
			v := fs.tab_get(fs.pivot_kids(b), i, false)
			nlo, nhi := lo, hi
			if i > 0 {
				nlo = v.key
			}
			if i + 1 < int(b.nval) {
				nhi = fs.tab_get(fs.pivot_kids(b), i + 1, false).key
			}
			walk_node(f, fs.unpack_bptr(v.val), level - 1, nlo, nhi, fs.get16(v.val[fs.PTRSZ:]), w)
		}
	}
}

// The tree's structure, and every block accounted for.
tree_sane :: proc(t: ^testing.T, w: ^Tree_World) -> bool {
	wk := Walk{ok = true, disk = new(fs.Blk)}
	defer free(wk.disk)
	walk_node(&w.f, w.t.root, w.t.height, nil, nil, 0xffff, &wk)
	space := used_blocks(&w.f) == wk.blocks + wk.refs
	if !space {
		log.infof("used %d, tree %d, data %d", used_blocks(&w.f), wk.blocks, wk.refs)
	}
	return wk.ok && space && w.f.err == .Ok
}

// Lookups of every key in the model, and of some that are not.
lookups_agree :: proc(w: ^Tree_World) -> bool {
	buf: [fs.INLMAX]u8
	for &e in w.model {
		v, st := fs.lookup(&w.f, &w.t, entry_key(&e), &buf)
		if st != .Ok || !bytes_eq(v, entry_val(&e)) {
			return false
		}
	}
	k := [3]u8{u8(fs.Key_Kind.Orphan), 0xff, 0xfe} // never made
	_, st := fs.lookup(&w.f, &w.t, k[:], &buf)
	return st == .Err_Not_Found
}

model_has_prefix :: proc(w: ^Tree_World, i: int, pfx: []u8) -> bool {
	return i < len(w.model) && w.model[i].nk >= len(pfx) && bytes_eq(entry_key(&w.model[i])[:len(pfx)], pfx)
}

scan_agrees :: proc(w: ^Tree_World, pfx: []u8) -> bool {
	s: fs.Scan
	fs.scan_start(&s, &w.t, pfx)
	i := 0
	ok := true
	for len(pfx) > 0 && i < len(w.model) && fs.keycmp(entry_key(&w.model[i]), pfx) < 0 {
		i += 1
	}
	for kv in fs.scan_next(&w.f, &s) {
		if !model_has_prefix(w, i, pfx) || !bytes_eq(kv.key, entry_key(&w.model[i])) || !bytes_eq(kv.val, entry_val(&w.model[i])) {
			ok = false
			break
		}
		i += 1
	}
	more := model_has_prefix(w, i, pfx)
	fs.scan_end(&w.f, &s)
	return ok && !more && w.f.err == .Ok
}

// --- Random batches ---

Batch :: struct {
	m:     [1024]fs.Msg,
	bytes: [64 * 1024]u8,
	n:     int,
	used:  int,
	size:  int,
}

batch_bytes :: proc(b: ^Batch, n: int) -> []u8 {
	p := b.bytes[b.used:][:n]
	b.used += n
	return p
}

// A key: a Kent in one of a few directories, a Kdat, or a Kup.
random_key :: proc(r: ^Rng, k: []u8) -> int {
	kind := below(r, 10)
	if kind < 6 { // Kent pqid name
		k[0] = u8(fs.Key_Kind.Ent)
		fs.kput64(k[1:], u64(below(r, 4)))
		n := 1 + int(below(r, below(r, 8) == 0 ? 200 : 12))
		for i in 0 ..< n {
			k[9 + i] = u8('a' + below(r, 4))
		}
		return 9 + n
	}
	if kind < 9 { // Kdat qid off
		k[0] = u8(fs.Key_Kind.Dat)
		fs.kput64(k[1:], u64(below(r, 8)))
		fs.kput64(k[9:], u64(below(r, 64)) * B)
		return 17
	}
	k[0] = u8(fs.Key_Kind.Up)
	fs.kput64(k[1:], u64(below(r, 64)))
	return 9
}

add :: proc(b: ^Batch, op: fs.Op, k, v: []u8) -> bool {
	sz := 2 + 1 + 2 + len(k) + 2 + len(v)
	if b.n == len(b.m) || b.size + sz > fs.BUFSPC || b.used + len(k) + len(v) > len(b.bytes) {
		return false
	}
	kp, vp := batch_bytes(b, len(k)), batch_bytes(b, len(v))
	copy(kp, k)
	copy(vp, v)
	b.m[b.n] = {op = op, key = kp, val = len(v) > 0 ? vp : nil}
	b.n += 1
	b.size += sz
	return true
}

// A value for key k: an entry for a Kent, a data block or inline bytes for a
// Kdat, anything for the rest.
random_value :: proc(t: ^testing.T, w: ^Tree_World, k, v: []u8, big: bool) -> int {
	r := &w.rng
	if k[0] == u8(fs.Key_Kind.Ent) {
		d: fs.Dir
		d.qid_path = rnd(r)
		d.mode = 0o644
		d.length = u64(below(r, 1000))
		d.uid = below(r, 5)
		fs.pack_dir(v, d)
		return fs.DIRSZ
	}
	if k[0] == u8(fs.Key_Kind.Dat) && below(r, 2) != 0 {
		b := fs.new_block(&w.f, .Dat)
		if b == nil {
			return 0
		}
		fs.data(b)[0] = u8(rnd(r))
		_ = fs.write_block(&w.f, b)
		v[0] = u8(fs.Value_Kind.Ref)
		fs.pack_bptr(v[1:], b.bp)
		fs.drop(&w.f, b)
		return 1 + fs.PTRSZ
	}
	n := below(r, 4) == 0 ? int(below(r, fs.INLMAX + 1)) : int(below(r, 40))
	if big {
		n = fs.INLMAX
	}
	start := 0
	if k[0] == u8(fs.Key_Kind.Dat) {
		if n > 0 {
			v[0] = u8(fs.Value_Kind.Inline)
		}
		start = 1
	}
	for i in start ..< n {
		v[i] = u8(rnd(r))
	}
	return n
}

// One random batch, to the model and the tree.
run_batch :: proc(t: ^testing.T, w: ^Tree_World, b: ^Batch, max_msgs: u32) -> bool {
	r := &w.rng
	b^ = {}
	want := 1 + below(r, max_msgs)
	k: [fs.KEYMAX]u8
	v: [fs.INLMAX]u8
	for _ in 0 ..< want {
		pick := below(r, 100)
		nk := 0
		found := false
		at := 0
		if len(w.model) > 0 && pick < 45 { // an existing key
			at = int(below(r, u32(len(w.model))))
			nk = copy(k[:], entry_key(&w.model[at]))
			found = true
		} else {
			nk = random_key(r, k[:])
			at, found = model_find(w, k[:nk])
		}
		key := k[:nk]
		op := below(r, 100)
		if op < 55 || !found {
			if op >= 90 && !found { // a clobber or clearb of nothing
				o := fs.Op.Clearb if key[0] == u8(fs.Key_Kind.Dat) else fs.Op.Clobber
				if !add(b, o, key, nil) {
					break
				}
				continue
			}
			nv := random_value(t, w, key, v[:], false)
			if !add(b, .Insert, key, v[:nv]) {
				if fs.owns_block(key, v[:nv]) { // unused: free it
					testing.expect(t, fs.free_block(&w.f, fs.unpack_bptr(v[1:])))
				}
				break
			}
			model_set(w, key, v[:nv])
		} else if op < 75 {
			if !add(b, .Delete, key, nil) {
				break
			}
			model_del(w, key)
		} else if op < 85 {
			o := fs.Op.Clearb if key[0] == u8(fs.Key_Kind.Dat) else fs.Op.Clobber
			if !add(b, o, key, nil) {
				break
			}
			model_del(w, key)
		} else if key[0] == u8(fs.Key_Kind.Ent) && w.model[at].nv == fs.DIRSZ {
			st: [1 + 8 + 4 + 8 + 4]u8
			st[0] = transmute(u8)fs.Wstat{.Size, .Mode, .Mtime, .Muid}
			length := rnd(r)
			mode := u32(rnd(r))
			muid := below(r, 9)
			mtime := i64(rnd(r))
			fs.put64(st[1:], length)
			fs.put32(st[9:], mode)
			fs.put64(st[13:], u64(mtime))
			fs.put32(st[21:], muid)
			if !add(b, .Wstat, key, st[:]) {
				break
			}
			d := fs.unpack_dir(entry_val(&w.model[at]))
			d.qid_vers += 1
			d.length, d.mode, d.qid_type, d.mtime, d.muid = length, mode, u8(mode >> 24), mtime, muid
			fs.pack_dir(v[:], d)
			model_set(w, key, v[:fs.DIRSZ])
		}
	}
	st := fs.upsert(&w.f, &w.t, b.m[:b.n])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, fs.end_op(&w.f))
	return st == .Ok
}

Model_Case :: struct {
	seed:   u64,
	digest: u64,
}

@(test)
test_model :: proc(t: ^testing.T) {
	cases := []Model_Case {
		{1, 0x0d33f4c138b82701},
		{2, 0x2ed1db018fcced35},
		{3, 0x937dbde5eddf0ba3},
		{4, 0x4b68bc79d80cda1b},
		{5, 0xf2533ac1ba46610d},
		{6, 0x815200be81551469},
	}
	b := new(Batch)
	defer free(b)
	for c in cases {
		w := new(Tree_World)
		defer free(w)
		w.rng = {c.seed * 0x9E3779B97F4A7C15}
		batches := u32(300)
		max_msgs := u32(c.seed % 2 != 0 ? 40 : 400)
		tw_open(t, w)
		tall := u32(1)
		ok := true
		for i in 0 ..< batches {
			if !ok {
				break
			}
			ok = run_batch(t, w, b, max_msgs)
			tall = max(tall, w.t.height)
			if i % 16 == 0 || i + 1 == batches {
				sane, looked := tree_sane(t, w), lookups_agree(w)
				testing.expect(t, sane)
				testing.expect(t, looked)
				ok = ok && sane && looked
				pfx: [9]u8
				pfx[0] = u8(fs.Key_Kind.Ent)
				fs.kput64(pfx[1:], u64(below(&w.rng, 4)))
				all, dir, one := scan_agrees(w, nil), scan_agrees(w, pfx[:]), scan_agrees(w, pfx[:1])
				testing.expect(t, all)
				testing.expect(t, dir)
				testing.expect(t, one)
				ok = ok && all && dir && one
				if !ok {
					log.infof("seed %d: wrong after batch %d", c.seed, i)
				}
			}
		}
		testing.expectf(t, tall >= 2, "seed %d: the batches made no pivots", c.seed) // the batches made pivots
		expect_digest(t, fmt.tprintf("model %d", c.seed), w.dev.bytes, c.digest)
		tw_close(w)
	}
}

// Big values in key order until the tree is three tall, then every key
// deleted: back to one empty leaf, and the space all returned.
@(test)
test_grow_shrink :: proc(t: ^testing.T) {
	w := new(Tree_World)
	defer free(w)
	w.rng = {1}
	tw_open(t, w)
	defer tw_close(w)
	base := used_blocks(&w.f)
	b := new(Batch)
	defer free(b)
	k: [17]u8
	v: [fs.INLMAX]u8
	for &c in v {
		c = 0x33
	}
	n := u64(0)
	for w.t.height < 3 && n < 40000 {
		b^ = {}
		for ; ; n += 1 {
			fs.key_dat(k[:], 7, n)
			if !add(b, .Insert, k[:], v[:]) {
				break
			}
			model_set(w, k[:], v[:])
		}
		testing.expect_value(t, fs.upsert(&w.f, &w.t, b.m[:b.n]), vx.Status.Ok)
		testing.expect(t, fs.end_op(&w.f))
	}
	testing.expect_value(t, w.t.height, 3)
	testing.expect(t, tree_sane(t, w))
	testing.expect(t, lookups_agree(w))
	testing.expect(t, scan_agrees(w, nil))
	// Deleted in a scattered order.
	for done := u64(0); done < n; {
		b^ = {}
		for ; done < n; done += 1 {
			i := done * 7919 % n
			fs.key_dat(k[:], 7, i)
			if !add(b, .Delete, k[:], nil) {
				break
			}
			model_del(w, k[:])
		}
		testing.expect_value(t, fs.upsert(&w.f, &w.t, b.m[:b.n]), vx.Status.Ok)
		testing.expect(t, fs.end_op(&w.f))
		if done % 2048 < 256 {
			testing.expect(t, tree_sane(t, w))
		}
	}
	// Messages may still be buffered for keys now gone: clear them through with lookups' view.
	testing.expect_value(t, len(w.model), 0)
	testing.expect(t, lookups_agree(w))
	testing.expect(t, scan_agrees(w, nil))
	testing.expect(t, tree_sane(t, w))
	// Flush what is buffered: clobbers enough to push everything down.
	for r := 0; r < 64 && w.t.height > 1; r += 1 {
		b^ = {}
		for {
			fs.key_dat(k[:], 7, u64(below(&w.rng, u32(n))))
			if !add(b, .Clobber, k[:], nil) {
				break
			}
		}
		testing.expect_value(t, fs.upsert(&w.f, &w.t, b.m[:b.n]), vx.Status.Ok)
		testing.expect(t, fs.end_op(&w.f))
	}
	testing.expect_value(t, w.t.height, 1)
	testing.expect(t, tree_sane(t, w))
	testing.expect_value(t, used_blocks(&w.f), base)
	expect_digest(t, "grow_shrink", w.dev.bytes, 0x15c998f7ddf8547d)
}

// Keys below the first child's key all go to it; when it splits, the
// parent's keys must stay in order (the first part takes the lower key).
@(test)
test_low_split :: proc(t: ^testing.T) {
	w := new(Tree_World)
	defer free(w)
	tw_open(t, w)
	defer tw_close(w)
	b := new(Batch)
	defer free(b)
	k := [4]u8{u8(fs.Key_Kind.Dat), 0, 0, 0}
	v: [500]u8
	for &c in v {
		c = 0x5a
	}
	for pass in 0 ..< 2 { // 'm' keys, a split; then 'a' keys, all below them
		for i := 0; i < 40; i += 10 {
			b^ = {}
			for j in i ..< i + 10 {
				k[1], k[2], k[3] = pass != 0 ? 'a' : 'm', u8(j >> 8), u8(j)
				testing.expect(t, add(b, .Insert, k[:], v[:]))
				model_set(w, k[:], v[:])
			}
			testing.expect_value(t, fs.upsert(&w.f, &w.t, b.m[:b.n]), vx.Status.Ok)
			testing.expect(t, fs.end_op(&w.f))
		}
	}
	testing.expect(t, w.t.height >= 2)
	testing.expect(t, lookups_agree(w))
	testing.expect(t, scan_agrees(w, nil))
	testing.expect(t, tree_sane(t, w))
	expect_digest(t, "low_split", w.dev.bytes, 0x257204e5120560d9)
}

@(test)
test_refused :: proc(t: ^testing.T) {
	w := new(Tree_World)
	defer free(w)
	tw_open(t, w)
	before := w.t
	k: [fs.KEYMAX + 1]u8
	k[0] = u8(fs.Key_Kind.Ent)
	v: [fs.INLMAX + 1]u8
	// (Upstream's sixth case, a value of 4 bytes at nullptr, has no Odin
	// form: a slice's length comes with its pointer.)
	bad := []fs.Msg {
		{op = .Nop, key = k[:1]},
		{op = fs.Op(fs.NMSG), key = k[:1]},
		{op = .Insert, key = k[:0]},
		{op = .Insert, key = k[:fs.KEYMAX + 1]},
		{op = .Insert, key = k[:1], val = v[:fs.INLMAX + 1]},
	}
	for m in bad {
		testing.expect_value(t, fs.upsert(&w.f, &w.t, {m}), vx.Status.Err_Invalid)
	}
	// More than a buffer holds.
	many: [64]fs.Msg
	for &m in many {
		m = {op = .Insert, key = k[:1], val = v[:200]}
	}
	testing.expect_value(t, fs.upsert(&w.f, &w.t, many[:]), vx.Status.Err_Invalid)
	testing.expect_value(t, w.f.err, vx.Status.Ok)
	testing.expect_value(t, w.t.root.addr, before.root.addr)

	// A delete of a key that is not there: nothing to do, and the volume is
	// not poisoned (M5 step 10: it once was, when the buffer was flushed).
	testing.expect_value(t, fs.upsert(&w.f, &w.t, {{op = .Delete, key = k[:9]}}), vx.Status.Ok)
	testing.expect_value(t, w.f.err, vx.Status.Ok)
	// A wstat whose fields are not its flags' width: refused when taken, the tree untouched.
	short_uid := [?]u8{transmute(u8)fs.Wstat{.Uid}, 1, 0} // a uid is 4 bytes
	was := w.t
	testing.expect_value(t, fs.upsert(&w.f, &w.t, {{op = .Wstat, key = k[:9], val = short_uid[:]}}), vx.Status.Err_Invalid)
	testing.expect_value(t, w.f.err, vx.Status.Ok)
	testing.expect_value(t, w.t.root.addr, was.root.addr)
	tw_close(w)

	// A message buffered in a pivot that cannot apply: lookups and scans
	// report the damage.
	tw_open(t, w)
	defer tw_close(w)
	testing.expect_value(t, fs.upsert(&w.f, &w.t, {{op = .Insert, key = k[:9], val = v[:3]}}), vx.Status.Ok)
	// A root pivot over that leaf, its buffer holding a wstat the value is too short for.
	r := fs.new_block(&w.f, .Pivot)
	one: fs.Kids
	testing.expect(t, fs.kids_push(&w.f, &one, k[:9], w.t.root, 8))
	r.nval = 1
	r.valsz = fs.kids_pack(fs.pivot_kids(r), fs.items(&one))
	st := [?]u8{transmute(u8)fs.Wstat{.Uid}, 1, 0, 0, 0}
	ws := []fs.Msg{{op = .Wstat, key = k[:9], val = st[:]}}
	r.nbuf = 1
	r.bufsz = fs.tab_pack(fs.pivot_msgs(r), ws, true)
	testing.expect(t, fs.write_block(&w.f, r))
	bad_tree := fs.Tree{root = r.bp, height = 2}
	fs.drop(&w.f, r)
	fs.vec_free(&w.f, &one)
	out: [fs.INLMAX]u8
	_, lst := fs.lookup(&w.f, &bad_tree, k[:9], &out)
	testing.expect_value(t, lst, vx.Status.Err_Invalid)
}

// The planner's parts: each fits, together they hold every entry in order,
// and there are as few as fit allows.
@(test)
test_plan :: proc(t: ^testing.T) {
	f := fs.Fs{mem = mem()}
	size: [200]u32
	for n := 1; n < 200; n += 13 {
		for i in 0 ..< n {
			size[i] = u32(7 + (i * 37 % 770))
		}
		total: u64
		for s in size[:n] {
			total += u64(s)
		}
		cuts, ok := fs.plan(&f, size[:n], fs.LEAFSPC)
		if !testing.expect(t, ok) {
			continue
		}
		parts := u64(len(cuts))
		least := (total + fs.LEAFSPC - 1) / fs.LEAFSPC
		testing.expect(t, parts >= least)
		testing.expect(t, parts <= least + 1)
		at := u32(0)
		for c in cuts {
			sz: u64
			testing.expect(t, c > at)
			for ; at < c; at += 1 {
				sz += u64(size[at])
			}
			testing.expect(t, sz <= fs.LEAFSPC)
		}
		testing.expect_value(t, int(at), n)
		if total > 2 * fs.LEAFSPC {
			testing.expect(t, parts >= 3)
		}
		fs.mem_release(&f, cuts)
	}
}

// A scan given a prefix longer than any key: nothing found, no copy past its
// buffers (M5 step 10).
@(test)
test_scan_bounds :: proc(t: ^testing.T) {
	w := new(Tree_World)
	defer free(w)
	tw_open(t, w)
	defer tw_close(w)
	big: [fs.KEYMAX + 1]u8
	s: fs.Scan
	fs.scan_start(&s, &w.t, big[:])
	_, ok := fs.scan_next(&w.f, &s)
	testing.expect(t, !ok)
	testing.expect_value(t, w.f.err, vx.Status.Ok)
	fs.scan_end(&w.f, &s)
	k := [1]u8{1}
	fs.scan_from(&s, &w.t, k[:], big[:]) // a start past any key: from the prefix's start
	fs.scan_end(&w.f, &s)
}
