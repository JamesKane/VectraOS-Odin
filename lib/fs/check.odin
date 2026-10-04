package fs

import vx "abi:vx"

// The checker (upstream docs/11 §6, §14): a mounted volume walked whole, as
// `fsd -c` and the host's tools and tests run it.
//
// Every block a structure reaches is checked: its hash, its structure, and
// for trees the order of keys across nodes, one height everywhere, and each
// child's fill as its parent records it. Snapshots and labels must agree:
// each label names a snapshot, each snapshot's label and fork counts are
// right, chains link both ways, a branch names the end of its chain, a
// deadlist lists only blocks its snapshot's predecessor holds. And space must
// add up: the blocks the arenas have in use are exactly those reached, each
// reached block in use, and nothing but snapshots' trees sharing a block.

Check :: struct {
	used:        u64, // blocks the arenas have in use
	trees:       u64, // distinct blocks of trees and the data they name (shared by snapshots)
	other:       u64, // logs, deadlists, the freed chain, deferred blocks
	leaked:      u64, // in use, reached by nothing
	unallocated: u64, // reached, but free (or outside every arena)
	shared:      u64, // reached by a log, deadlist or chain and something else too
	damaged:     u64, // unreadable, failing their hash, or malformed
	bad_snaps:   u64, // snapshots and labels that disagree
	bad_lists:   u64, // deadlists that do not fit their snapshot
	snapshots:   u32,
	labels:      u32,
	dlists:      u32,
}

@(private = "file")
addrs_add :: proc "contextless" (fs: ^Fs, s: ^Vec(Addr), addr: Addr) {
	_ = vec_push(fs, s, addr)
}

@(private = "file")
sift :: proc "contextless" (a: []Addr, root, n: int) {
	root := root
	for {
		child := 2 * root + 1
		if child >= n {
			return
		}
		if child + 1 < n && a[child] < a[child + 1] {
			child += 1
		}
		if a[root] >= a[child] {
			return
		}
		a[root], a[child] = a[child], a[root]
		root = child
	}
}

// A heap sort: in place, and no worse than n log n.
@(private = "file")
addrs_sort :: proc "contextless" (s: ^Vec(Addr)) {
	a := items(s)
	for i := len(a) / 2; i > 0; {
		i -= 1
		sift(a, i, len(a))
	}
	for end := len(a); end > 1; end -= 1 {
		a[0], a[end - 1] = a[end - 1], a[0]
		sift(a, 0, end - 1)
	}
}

@(private = "file")
addrs_has :: proc "contextless" (s: ^Vec(Addr), addr: Addr) -> bool {
	a := items(s)
	lo, hi := 0, len(a)
	for lo < hi {
		mid := (lo + hi) / 2
		if a[mid] < addr {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(a) && a[lo] == addr
}

@(private = "file")
Checking :: struct {
	v:     ^Vol,
	c:     ^Check,
	trees: Vec(Addr),
	other: Vec(Addr),
}

// A tree node and all under it; every key in it, buffered or not, in
// [lo, hi) (nil: unbounded); `fill` its parent's record of it (0xffff: a
// root). Recursive as deep as the tree is tall.
@(private = "file")
check_node :: proc "contextless" (k: ^Checking, bp: Bptr, level: u32, lo, hi: []u8, fill: u16) {
	fs := &k.v.fs
	was := fs.err
	b := get(fs, bp, {level == 1 ? .Leaf : .Pivot})
	if b == nil {
		k.c.damaged += 1
		if was == .Ok {
			fs.err = .Ok // go on: count it all
		}
		return
	}
	defer drop(fs, b)
	addrs_add(fs, &k.trees, bp.addr)
	bad := (fill != 0xffff && fill != blk_fill(b)) || (level > 1 && b.nval == 0)
	for i in 0 ..< int(b.nval) {
		e := tab_get(vals(b), i, false)
		first_pivot := level > 1 && i == 0 // a pivot's first key may be below the range
		if (lo != nil && !first_pivot && keycmp(e.key, lo) < 0) || (hi != nil && keycmp(e.key, hi) >= 0) {
			bad = true
		}
		if level == 1 && owns_block(e.key, e.val) {
			addrs_add(fs, &k.trees, unpack_bptr(e.val[1:]).addr)
		}
	}
	for i in 0 ..< int(b.nbuf) {
		m := tab_get(pivot_msgs(b), i, true)
		if (lo != nil && keycmp(m.key, lo) < 0) || (hi != nil && keycmp(m.key, hi) >= 0) {
			bad = true
		}
		if m.op == .Insert && owns_block(m.key, m.val) {
			addrs_add(fs, &k.trees, unpack_bptr(m.val[1:]).addr)
		}
	}
	if bad {
		k.c.damaged += 1
	}
	if level == 1 {
		return
	}
	for i in 0 ..< int(b.nval) {
		e := tab_get(pivot_kids(b), i, false)
		nlo, nhi := lo, hi
		if i > 0 {
			nlo = e.key
		}
		if i + 1 < int(b.nval) {
			nhi = tab_get(pivot_kids(b), i + 1, false).key
		}
		child := unpack_bptr(e.val)
		if child.gen > bp.gen {
			k.c.damaged += 1 // a node is never older than what it points at
		}
		check_node(k, child, level - 1, nlo, nhi, get16(e.val[PTRSZ:]))
	}
}

@(private = "file")
check_tree :: proc "contextless" (k: ^Checking, root: Bptr, height: u32) {
	if height == 0 || height > MAXHEIGHT {
		k.c.damaged += 1
		return
	}
	check_node(k, root, height, nil, nil, 0xffff)
}

@(private = "file")
add_other :: proc "contextless" (v: ^Vol, addr: Addr, ctx: rawptr) -> bool {
	addrs_add(&v.fs, &(^Checking)(ctx).other, addr)
	return true
}

@(private = "file")
Snaprec :: struct {
	s:      Snap,
	labels: u32,
	forks:  u32,
}

@(private = "file")
find_snap :: proc "contextless" (s: []Snaprec, gen: Gen) -> ^Snaprec {
	for &r in s {
		if r.s.gen == gen {
			return &r
		}
	}
	return nil
}

// Checks the volume: .Ok if it is clean, INVALID if not; c says what was
// found either way. Open branches' uncommitted trees count as reached.
@(require_results)
check_volume :: proc "contextless" (v: ^Vol, c: ^Check) -> vx.Status {
	fs := &v.fs
	c^ = {}
	if fs.err != .Ok {
		return fs.err
	}
	k := Checking{v = v, c = c}
	defer vec_free(fs, &k.trees)
	defer vec_free(fs, &k.other)
	check_tree(&k, v.snap.root, v.snap.height)

	// Snapshots and labels.
	snaps: Vec(Snaprec)
	defer vec_free(fs, &snaps)
	s: Scan
	pfx := [1]u8{u8(Key_Kind.Snap)}
	scan_start(&s, &v.snap, pfx[:])
	for kv in scan_next(fs, &s) {
		if len(kv.key) != size_of(Key_Id) || len(kv.val) != SNAPSZ || unpack_snap(kv.val).gen != Gen(kget64(kv.key[1:])) {
			c.bad_snaps += 1
			continue
		}
		_ = vec_push(fs, &snaps, Snaprec{s = unpack_snap(kv.val)})
	}
	scan_end(fs, &s)
	c.snapshots = u32(snaps.n)
	pfx[0] = u8(Key_Kind.Label)
	scan_start(&s, &v.snap, pfx[:])
	for kv in scan_next(fs, &s) {
		c.labels += 1
		r: ^Snaprec
		if len(kv.val) == size_of(Label_Disk) {
			r = find_snap(items(&snaps), Gen(get64(kv.val)))
		}
		if r == nil || (r.s.succ != 0 && .Mutable in transmute(Label_Flags)get32(kv.val[8:])) {
			c.bad_snaps += 1 // nothing named, or a branch not at its chain's end
			continue
		}
		r.labels += 1
	}
	scan_end(fs, &s)
	for &r in items(&snaps) {
		t := &r.s
		if t.base != 0 && t.pred == 0 { // the first of a fork's chain
			if b := find_snap(items(&snaps), t.base); b != nil {
				b.forks += 1
			} else {
				c.bad_snaps += 1
			}
		}
		p := t.pred != 0 ? find_snap(items(&snaps), t.pred) : nil
		n := t.succ != 0 ? find_snap(items(&snaps), t.succ) : nil
		if (t.pred != 0 && (p == nil || p.s.succ != t.gen)) || (t.succ != 0 && (n == nil || n.s.pred != t.gen)) {
			c.bad_snaps += 1
		}
		if t.pred != 0 && t.pred >= t.gen {
			c.bad_snaps += 1
		}
		check_tree(&k, t.root, t.height)
	}
	for &r in items(&snaps) {
		if r.labels != r.s.nlbl || r.forks != r.s.nref || (r.s.nlbl == 0 && r.s.nref == 0) {
			c.bad_snaps += 1
		}
	}
	for &br in v.br {
		if br.open {
			check_tree(&k, br.t.root, br.t.height)
		}
	}

	// Deadlists: their chains, and what they list, kept for after the sort.
	listed: Vec(Addr)
	defer vec_free(fs, &listed)
	pfx[0] = u8(Key_Kind.Dlist)
	scan_start(&s, &v.snap, pfx[:])
	for kv in scan_next(fs, &s) {
		c.dlists += 1
		r: ^Snaprec
		if len(kv.key) == size_of(Key_Dlist) && len(kv.val) == size_of(Dlist_Disk) {
			r = find_snap(items(&snaps), Gen(kget64(kv.key[1:])))
		}
		if r == nil || r.s.pred == 0 || Gen(kget64(kv.key[9:])) > r.s.pred {
			c.bad_lists += 1
			continue
		}
		before := listed.n
		hd := Addr(get64(kv.val))
		ok := chain_each(v, hd, add_other, &k, false, true)
		// What it lists: the chain again, its entries.
		for at := hd; ok && at != 0; {
			b := get(fs, {addr = at}, {.Dlist})
			if b == nil {
				ok = false
				break
			}
			for j := 0; j < int(b.logsz); j += 8 {
				addrs_add(fs, &listed, Addr(get64(data(b)[j:])))
			}
			at = b.logp.addr
			drop(fs, b)
		}
		if !ok {
			c.damaged += 1
			fs.err = .Ok
		}
		if ok && u64(listed.n - before) != get64(kv.val[8:]) {
			c.bad_lists += 1
		}
	}
	scan_end(fs, &s)

	// Logs, the freed chain, what is deferred.
	for &a in fs.arenas {
		c.used += a.used / BLKSZ
		bp := a.loghd
		for j in 0 ..< a.nlog {
			addrs_add(fs, &k.other, bp.addr)
			if j + 1 == a.nlog {
				break
			}
			b := get(fs, bp, {.Log})
			if b == nil {
				c.damaged += 1
				fs.err = .Ok
				break
			}
			bp = b.logp
			drop(fs, b)
		}
		for addr in a.retired {
			addrs_add(fs, &k.other, addr)
		}
	}
	for addr in items(&v.freedchain) {
		addrs_add(fs, &k.other, addr)
	}
	for addr in items(&fs.deferred) {
		addrs_add(fs, &k.other, addr)
	}

	// Space: distinct trees' blocks, other blocks each once and in nothing else.
	addrs_sort(&k.trees)
	addrs_sort(&k.other)
	nt := 0
	for i in 0 ..< k.trees.n {
		if i == 0 || k.trees.buf[i] != k.trees.buf[i - 1] {
			k.trees.buf[nt] = k.trees.buf[i]
			nt += 1
		}
	}
	k.trees.n = nt
	for i in 0 ..< k.other.n {
		if (i > 0 && k.other.buf[i] == k.other.buf[i - 1]) || addrs_has(&k.trees, k.other.buf[i]) {
			c.shared += 1
		}
	}
	c.trees, c.other = u64(k.trees.n), u64(k.other.n)
	for set in ([2]^Vec(Addr){&k.trees, &k.other}) {
		for addr in items(set) {
			a := arena_of(fs, addr)
			if a == nil || range_has(a, addr) {
				c.unallocated += 1
			}
		}
	}
	for addr in items(&listed) { // a deadlist's blocks are its predecessor's still
		if !addrs_has(&k.trees, addr) {
			c.bad_lists += 1
		}
	}
	reached := c.trees + c.other - c.shared
	if c.used > reached {
		c.leaked = c.used - reached
	}
	if fs.err != .Ok {
		return fs.err // out of memory, say
	}
	clean := c.leaked == 0 && c.unallocated == 0 && c.shared == 0 && c.damaged == 0 && c.bad_snaps == 0 && c.bad_lists == 0 && c.used == reached
	return clean ? .Ok : .Err_Invalid
}
