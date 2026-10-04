package fs

import vx "abi:vx"

// Trees (upstream docs/11 §3): copy-on-write Bε trees, after gefs's tree.c.
//
// A leaf holds values, sorted by key. A pivot holds, in its first half, its
// children (a key, a block pointer and the child's fill each) and, in its
// second, a buffer of messages bound for them. A key belongs to the last child
// whose key is at most it, or to the first child if none is. Changes are
// messages: an upsert adds them to the root's buffer. When they do not fit
// there, the messages for the child that has the most of them are pushed into
// it, recursively; at a leaf they are applied. A node that overflows splits
// into as many as it takes. A child left less than a quarter full is merged
// with a neighbor, or the two share their contents if they do not fit in one
// (a rotation). Every change makes new blocks up the path to a new root, and
// frees the old ones (blk.odin).
//
// Where gefs pulls as many of a buffer's messages as fit and splits in two,
// this pushes a child's messages whole and splits as many ways as it needs.
// The format is gefs's (in our byte order).
//
// A lookup applies to the leaf's value the messages for its key buffered on
// the path, the deepest (oldest) first. A scan does the same for one leaf's
// range at a time, entering the tree again from its root for each, so a scan
// sees changes made between its calls and never holds blocks across them.

// A tree, and the context its changes are made in: the generation its new
// blocks are born in, its branch's base, and whether it is the snapshot tree
// (blk.odin's frees depend on all three).
Tree :: struct {
	root:   Bptr,
	height: u32, // 1: the root is a leaf
	memgen: Gen,
	base:   Gen,
	snap:   bool,
}

// A message: a change to a key. Also an entry of a block's table, read in
// place (op is .Nop for a value).
Msg :: struct {
	op:  Op,
	key: []u8,
	val: []u8,
}

// A key and its value, as a scan gives them; valid until its next call.
Kvp :: struct {
	key: []u8,
	val: []u8,
}

// A key's value as the messages for it leave it: there, or not.
Value :: struct {
	key:     []u8,
	val:     []u8,
	present: bool,
}

// A pivot's child, its key copied out of the block it came from.
Kid :: struct {
	bp:   Bptr,
	fill: u16,
	nk:   u16,
	k:    [KEYMAX]u8,
}
Kids :: Vec(Kid)

kid_key :: #force_inline proc "contextless" (k: ^Kid) -> []u8 {
	return k.k[:k.nk]
}

UNDERFULL :: BLKSZ / 4

// Changes to t are made from here on.
@(private)
tree_enter :: proc "contextless" (fs: ^Fs, t: ^Tree) {
	fs.gen, fs.base, fs.snaptree = t.memgen, t.base, t.snap
}

bytes_equal :: proc "contextless" (a, b: []u8) -> bool {
	return len(a) == len(b) && keycmp(a, b) == 0
}

// --- Entries in blocks ---

// Entry i of table d.
tab_get :: proc "contextless" (d: []u8, i: int, msgs: bool) -> (m: Msg) {
	p := int(get16(d[2 * i:]))
	if msgs {
		m.op = Op(d[p])
		p += 1
	}
	nk := int(get16(d[p:]))
	m.key = d[p + 2:][:nk]
	p += 2 + nk
	nv := int(get16(d[p:]))
	m.val = d[p + 2:][:nv]
	return
}

// The bytes an entry takes in a table, its offset included.
ent_size :: proc "contextless" (m: Msg, msgs: bool) -> u32 {
	return 2 + (msgs ? 1 : 0) + 2 + u32(len(m.key)) + 2 + u32(len(m.val))
}

@(private = "file")
kid_size :: proc "contextless" (k: ^Kid) -> u32 {
	return 2 + 2 + u32(k.nk) + 2 + PTRSZ + 2
}

// Packs entries into table d, entries from its end; the bytes they take,
// offsets apart.
tab_pack :: proc "contextless" (d: []u8, e: []Msg, msgs: bool) -> u16 {
	used := 0
	for x, i in e {
		used += int(ent_size(x, msgs)) - 2
		p := len(d) - used
		put16(d[2 * i:], u16(p))
		if msgs {
			d[p] = u8(x.op)
			p += 1
		}
		put16(d[p:], u16(len(x.key)))
		copy(d[p + 2:], x.key)
		p += 2 + len(x.key)
		put16(d[p:], u16(len(x.val)))
		copy(d[p + 2:], x.val)
	}
	return u16(used)
}

// Packs children into a pivot's table d.
kids_pack :: proc "contextless" (d: []u8, ks: []Kid) -> u16 {
	used := 0
	for &k, i in ks {
		used += int(kid_size(&k)) - 2
		p := len(d) - used
		put16(d[2 * i:], u16(p))
		put16(d[p:], k.nk)
		copy(d[p + 2:], kid_key(&k))
		p += 2 + int(k.nk)
		put16(d[p:], PTRSZ + 2)
		pack_bptr(d[p + 2:], k.bp)
		put16(d[p + 2 + PTRSZ:], k.fill)
	}
	return u16(used)
}

blk_fill :: proc "contextless" (b: ^Blk) -> u16 {
	return u16(2 * int(b.nval) + int(b.valsz) + 2 * int(b.nbuf) + int(b.bufsz))
}

@(require_results)
kids_push :: proc "contextless" (fs: ^Fs, ks: ^Kids, k: []u8, bp: Bptr, fill: u16) -> bool {
	vec_grow(fs, ks) or_return
	d := &ks.buf[ks.n]
	ks.n += 1
	d.bp, d.fill, d.nk = bp, fill, u16(len(k))
	copy(d.k[:], k)
	return true
}

// Replaces ks[at, at + n) with the entries of `with`.
@(private = "file", require_results)
kids_splice :: proc "contextless" (fs: ^Fs, ks: ^Kids, at, n: int, with: ^Kids) -> bool {
	total := ks.n - n + with.n
	if total > len(ks.buf) {
		more := mem_new(Kid, fs, total) or_return
		copy(more, ks.buf[:ks.n])
		mem_release(fs, ks.buf)
		ks.buf = more
	}
	copy(ks.buf[at + with.n:total], ks.buf[at + n:ks.n])
	copy(ks.buf[at:], items(with))
	ks.n = total
	return true
}

// The child of `ks` that key k belongs to.
@(private = "file")
kids_route :: proc "contextless" (ks: []Kid, k: []u8) -> int {
	lo, hi := 1, len(ks) // the first child takes every key below the second's
	for lo < hi {
		mid := (lo + hi) / 2
		if keycmp(kid_key(&ks[mid]), k) <= 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

@(private = "file", require_results)
block_kids :: proc "contextless" (fs: ^Fs, b: ^Blk, ks: ^Kids) -> bool {
	for i in 0 ..< int(b.nval) {
		v := tab_get(pivot_kids(b), i, false)
		kids_push(fs, ks, v.key, unpack_bptr(v.val), get16(v.val[PTRSZ:])) or_return
	}
	return true
}

// --- Messages applied to a value ---

// The Kdat value names a block of its own: one that a change to it frees.
owns_block :: proc "contextless" (key, val: []u8) -> bool {
	return len(key) > 0 && key[0] == u8(Key_Kind.Dat) && len(val) == 1 + PTRSZ && val[0] == u8(Value_Kind.Ref)
}

// Whether an Owstat's payload is one: its flags byte, then exactly the fields
// those flags name. Checked when the message is taken, so one that cannot
// apply never reaches a buffer (M5 step 10).
wstat_well_formed :: proc "contextless" (m: Msg) -> bool {
	if len(m.val) == 0 {
		return false
	}
	flags := transmute(Wstat)m.val[0]
	need: u32
	for width, f in WSTAT_WIDTH {
		if f in flags {
			need += width
		}
	}
	return u32(len(m.val) - 1) == need
}

// Owstat on a packed entry, in place.
@(private = "file", require_results)
wstat :: proc "contextless" (v: []u8, m: Msg) -> bool {
	if !wstat_well_formed(m) {
		return false
	}
	d := unpack_dir(v)
	f := transmute(Wstat)m.val[0]
	p := m.val[1:]
	d.qid_vers += 1
	if .Size in f {
		d.length = get64(p)
		p = p[8:]
	}
	if .Mode in f {
		d.mode = get32(p)
		d.qid_type = u8(d.mode >> 24)
		p = p[4:]
	}
	if .Mtime in f {
		d.mtime = i64(get64(p))
		p = p[8:]
	}
	if .Atime in f {
		d.atime = i64(get64(p))
		p = p[8:]
	}
	if .Uid in f {
		d.uid = get32(p)
		p = p[4:]
	}
	if .Gid in f {
		d.gid = get32(p)
		p = p[4:]
	}
	if .Muid in f {
		d.muid = get32(p)
		p = p[4:]
	}
	if .Ctime in f {
		d.ctime = i64(get64(p))
	}
	pack_dir(v, d)
	return true
}

// Applies m to the value kv. `scratch` is DIRSZ bytes the value may be copied
// to, to be changed. False if the message cannot apply: the tree is damaged.
@(require_results)
apply :: proc "contextless" (kv: ^Value, m: Msg, scratch: []u8) -> bool {
	#partial switch m.op {
	case .Insert:
		kv.val, kv.present = m.val, true
		return true
	case .Delete, .Clearb, .Clobber: // a delete of a key that is not there too: nothing to do (it cannot be told at upsert)
		kv.val, kv.present = nil, false
		return true
	case .Wstat:
		if !kv.present || len(kv.val) != DIRSZ {
			return false
		}
		if raw_data(kv.val) != raw_data(scratch) {
			copy(scratch[:DIRSZ], kv.val)
		}
		kv.val = scratch[:DIRSZ]
		return wstat(scratch, m)
	}
	return false
}

// --- Writing nodes ---

// Cuts entries of the given sizes into parts that each fit `spc`, as even as
// it can: cuts[p] is the first entry after part p. One cut a part.
@(require_results)
plan :: proc "contextless" (fs: ^Fs, size: []u32, spc: u32) -> (cuts: []u32, ok: bool) {
	n := u32(len(size))
	total: u64
	for s in size {
		total += u64(s)
	}
	for parts := u32((total + u64(spc) - 1) / u64(spc)); ; parts += 1 {
		if parts == 0 {
			parts = 1
		}
		c := mem_new(u32, fs, int(parts)) or_return
		left := total
		i := u32(0)
		fits := true
		for p in 0 ..< parts {
			if !fits {
				break
			}
			target, sz := left / u64(parts - p), u64(0)
			if p + 1 == parts {
				target = left
			}
			for i < n && (sz < target || p + 1 == parts) && sz + u64(size[i]) <= u64(spc) {
				sz += u64(size[i])
				i += 1
			}
			left -= sz
			c[p] = i
			if p + 1 == parts && i < n {
				fits = false
			}
		}
		if fits {
			return c, true
		}
		mem_release(fs, c)
	}
}

// The key a part is filed under in its parent: its first entry's, or `low`
// for the first part if it has one at or below that.
@(private = "file")
part_key :: proc "contextless" (p: u32, low, first: []u8) -> []u8 {
	return p == 0 && len(low) > 0 && keycmp(low, first) <= 0 ? low : first
}

// Writes leaves holding the values e, and adds them to `out`; the first keyed
// `low` if it has one.
@(private = "file", require_results)
write_leaves :: proc "contextless" (fs: ^Fs, e: []Msg, low: []u8, out: ^Kids) -> bool {
	if len(e) == 0 {
		return true
	}
	size := mem_new(u32, fs, len(e)) or_return
	defer mem_release(fs, size)
	for x, i in e {
		size[i] = ent_size(x, false)
	}
	cuts := plan(fs, size, LEAFSPC) or_return
	defer mem_release(fs, cuts)
	at := u32(0)
	for p in 0 ..< u32(len(cuts)) {
		b := new_block(fs, .Leaf)
		if b == nil {
			return false
		}
		b.nval = u16(cuts[p] - at)
		b.valsz = tab_pack(vals(b), e[at:cuts[p]], false)
		ok := write_block(fs, b)
		ok = ok && kids_push(fs, out, part_key(p, low, e[at].key), b.bp, blk_fill(b))
		drop(fs, b)
		if !ok {
			return false
		}
		at = cuts[p]
	}
	return true
}

// Writes pivots holding the children ks and the messages m bound for them
// (which fit one buffer), and adds them to `out`.
@(private = "file", require_results)
write_pivots :: proc "contextless" (fs: ^Fs, ks: ^Kids, m: []Msg, low: []u8, out: ^Kids) -> bool {
	if ks.n == 0 {
		return len(m) == 0 || fail(fs, .Err_Invalid)
	}
	kids := items(ks)
	size := mem_new(u32, fs, len(kids)) or_return
	defer mem_release(fs, size)
	for &k, i in kids {
		size[i] = kid_size(&k)
	}
	cuts := plan(fs, size, PIVSPC) or_return
	defer mem_release(fs, cuts)
	mi, at := 0, u32(0)
	for p in 0 ..< u32(len(cuts)) {
		// Its messages: those below the next part's first key.
		mend := mi
		if int(cuts[p]) == len(kids) {
			mend = len(m)
		} else {
			for mend < len(m) && keycmp(m[mend].key, kid_key(&kids[cuts[p]])) < 0 {
				mend += 1
			}
		}
		bufsz: u32
		for x in m[mi:mend] {
			bufsz += ent_size(x, true)
		}
		if bufsz > BUFSPC {
			return fail(fs, .Err_Invalid)
		}
		b := new_block(fs, .Pivot)
		if b == nil {
			return false
		}
		b.nval = u16(cuts[p] - at)
		b.valsz = kids_pack(pivot_kids(b), kids[at:cuts[p]])
		b.nbuf = u16(mend - mi)
		b.bufsz = tab_pack(pivot_msgs(b), m[mi:mend], true)
		mi = mend
		ok := write_block(fs, b)
		ok = ok && kids_push(fs, out, part_key(p, low, kid_key(&kids[at])), b.bp, blk_fill(b))
		drop(fs, b)
		if !ok {
			return false
		}
		at = cuts[p]
	}
	return true
}

// --- Upserting ---

// A leaf with messages applied: its new values, written as leaves.
@(private = "file", require_results)
put_leaf :: proc "contextless" (fs: ^Fs, b: ^Blk, low: []u8, msgs: []Msg, out: ^Kids) -> bool {
	nwstat := 0
	for m in msgs {
		if m.op == .Wstat {
			nwstat += 1
		}
	}
	nval := int(b.nval)
	res, ok := mem_new(Msg, fs, nval + len(msgs) + 1)
	scratch: []u8
	if ok {
		scratch, ok = mem_new(u8, fs, (nwstat + 1) * DIRSZ)
	}
	defer mem_release(fs, res)
	defer mem_release(fs, scratch)
	nres, i, j, used := 0, 0, 0, 0
	for ok && (i < nval || j < len(msgs)) {
		c := 0
		if i == nval {
			c = 1
		} else if j == len(msgs) {
			c = -1
		}
		v: Msg
		if i < nval {
			v = tab_get(vals(b), i, false)
		}
		if c == 0 {
			c = keycmp(v.key, msgs[j].key)
		}
		if c < 0 { // a value no message changes
			res[nres] = v
			nres += 1
			i += 1
			continue
		}
		kv: Value
		if c == 0 {
			kv = {v.key, v.val, true}
			i += 1
		} else {
			kv = {key = msgs[j].key}
		}
		slot := scratch[used * DIRSZ:][:DIRSZ]
		wrote := false
		for ; ok && j < len(msgs) && keycmp(msgs[j].key, kv.key) == 0; j += 1 {
			// A data block the value names is the tree's to free once the value goes.
			was := kv
			if kv.present && owns_block(kv.key, kv.val) && msgs[j].op != .Clobber && msgs[j].op != .Wstat {
				ok = free_block(fs, unpack_bptr(kv.val[1:]))
			}
			ok = ok && apply(&kv, msgs[j], slot)
			if !ok && fs.err == .Ok {
				fail(fs, .Err_Invalid)
			}
			wrote = wrote || (raw_data(kv.val) == raw_data(slot) && raw_data(was.val) != raw_data(slot))
		}
		if wrote {
			used += 1
		}
		if kv.present {
			res[nres] = {key = kv.key, val = kv.val}
			nres += 1
		}
	}
	return ok && free_block(fs, b.bp) && write_leaves(fs, res[:nres], low, out)
}

// Merges the children ks[l] and ks[l + 1], both at `level`, into one, or
// shares their contents between two. Pivots are left as they are if their
// buffers together do not fit one.
@(private = "file", require_results)
merge_pair :: proc "contextless" (fs: ^Fs, ks: ^Kids, l: int, level: u32) -> bool {
	type := level == 1 ? Block_Type.Leaf : Block_Type.Pivot
	a := get(fs, ks.buf[l].bp, {type})
	defer drop(fs, a)
	b := a != nil ? get(fs, ks.buf[l + 1].bp, {type}) : nil
	defer drop(fs, b)
	if b == nil {
		return false
	}
	made, inner: Kids
	defer vec_free(fs, &made)
	defer vec_free(fs, &inner)
	low := kid_key(&ks.buf[l])
	if level == 1 {
		e := mem_new(Msg, fs, int(a.nval) + int(b.nval) + 1) or_return
		defer mem_release(fs, e)
		ne := 0
		for i in 0 ..< int(a.nval) {
			e[ne] = tab_get(vals(a), i, false)
			ne += 1
		}
		for i in 0 ..< int(b.nval) {
			e[ne] = tab_get(vals(b), i, false)
			ne += 1
		}
		write_leaves(fs, e[:ne], low, &made) or_return
	} else {
		if 2 * u32(a.nbuf) + u32(a.bufsz) + 2 * u32(b.nbuf) + u32(b.bufsz) > BUFSPC {
			return true // not without a flush
		}
		e := mem_new(Msg, fs, int(a.nbuf) + int(b.nbuf) + 1) or_return
		defer mem_release(fs, e)
		block_kids(fs, a, &inner) or_return
		first := inner.n
		block_kids(fs, b, &inner) or_return
		// b's first child keyed as b is, so b's keys below its first key still route to it.
		inner.buf[first].nk = ks.buf[l + 1].nk
		copy(inner.buf[first].k[:], kid_key(&ks.buf[l + 1]))
		ne := 0
		for i in 0 ..< int(a.nbuf) {
			e[ne] = tab_get(pivot_msgs(a), i, true)
			ne += 1
		}
		for i in 0 ..< int(b.nbuf) {
			e[ne] = tab_get(pivot_msgs(b), i, true)
			ne += 1
		}
		write_pivots(fs, &inner, e[:ne], low, &made) or_return
	}
	return free_block(fs, a.bp) && free_block(fs, b.bp) && kids_splice(fs, ks, l, 2, &made)
}

// Messages ordered by key, a's before b's for the same key: b's are newer.
@(private = "file")
merge_msgs :: proc "contextless" (to, a, b: []Msg) {
	i, j, n := 0, 0, 0
	for i < len(a) || j < len(b) {
		if j == len(b) || (i < len(a) && keycmp(a[i].key, b[j].key) <= 0) {
			to[n] = a[i]
			i += 1
		} else {
			to[n] = b[j]
			j += 1
		}
		n += 1
	}
}

@(private = "file")
msgs_size :: proc "contextless" (m: []Msg) -> u32 {
	sz: u32
	for x in m {
		sz += ent_size(x, true)
	}
	return sz
}

// A pivot with messages added: those that fit stay in its buffer; for as long
// as they do not, the messages for the child with the most are pushed into it.
// Recursive as deep as the tree is tall, MAXHEIGHT at most.
@(private = "file", require_results)
put_pivot :: proc "contextless" (fs: ^Fs, b: ^Blk, level: u32, low: []u8, msgs: []Msg, out: ^Kids) -> bool {
	ks: Kids
	defer vec_free(fs, &ks)
	nm := int(b.nbuf) + len(msgs)
	own := mem_new(Msg, fs, nm + 1) or_return
	defer mem_release(fs, own)
	m := mem_new(Msg, fs, nm + 1) or_return
	defer mem_release(fs, m)
	bytes: []u32
	defer mem_release(fs, bytes)
	block_kids(fs, b, &ks) or_return
	if ks.n == 0 {
		return fail(fs, .Err_Invalid)
	}
	for i in 0 ..< int(b.nbuf) {
		own[i] = tab_get(pivot_msgs(b), i, true)
	}
	merge_msgs(m, own[:b.nbuf], msgs)
	for msgs_size(m[:nm]) > BUFSPC {
		// The bytes bound for each child, and the child with the most.
		if len(bytes) < ks.n {
			mem_release(fs, bytes)
			bytes = nil
			bytes = mem_new(u32, fs, ks.n) or_return
		}
		for &x in bytes[:ks.n] {
			x = 0
		}
		for x in m[:nm] {
			bytes[kids_route(items(&ks), x.key)] += ent_size(x, true)
		}
		c := 0
		for i in 1 ..< ks.n {
			if bytes[i] > bytes[c] {
				c = i
			}
		}
		lo := 0
		for kids_route(items(&ks), m[lo].key) != c {
			lo += 1
		}
		hi := lo
		for hi < nm && kids_route(items(&ks), m[hi].key) == c {
			hi += 1
		}
		made: Kids
		child := ks.buf[c]
		ok := put(fs, child.bp, level - 1, kid_key(&child), m[lo:hi], &made) && kids_splice(fs, &ks, c, 1, &made)
		copy(m[lo:], m[hi:nm])
		nm -= hi - lo
		// A lone child left underfull joins a neighbor.
		if ok && made.n == 1 && ks.n > 1 && ks.buf[c].fill < UNDERFULL {
			ok = merge_pair(fs, &ks, c + 1 < ks.n ? c : c - 1, level - 1)
		}
		vec_free(fs, &made)
		if !ok {
			return false
		}
	}
	return free_block(fs, b.bp) && write_pivots(fs, &ks, m[:nm], low, out)
}

// The node at bp, `level` above the leaves (1: a leaf), with messages added,
// written anew as the nodes it takes (none if it is left empty), and those
// added to `out`.
@(private = "file", require_results)
put :: proc "contextless" (fs: ^Fs, bp: Bptr, level: u32, low: []u8, msgs: []Msg, out: ^Kids) -> bool {
	b := get(fs, bp, {level == 1 ? .Leaf : .Pivot})
	if b == nil {
		return false
	}
	defer drop(fs, b)
	return level == 1 ? put_leaf(fs, b, low, msgs, out) : put_pivot(fs, b, level, low, msgs, out)
}

// An empty tree, a leaf with nothing in it, born in the context t names
// (fs.gen's if it names none).
@(require_results)
tree_init :: proc "contextless" (fs: ^Fs, t: ^Tree) -> bool {
	if t.memgen == 0 {
		t.memgen = fs.gen
	}
	tree_enter(fs, t)
	b := new_block(fs, .Leaf)
	if b == nil {
		return false
	}
	ok := write_block(fs, b)
	t.root, t.height = b.bp, 1
	drop(fs, b)
	return ok
}

// Applies messages to the tree, as one change: a new root, the old path
// freed. They are taken in key order, those for the same key in the order
// given; together they must fit a pivot's buffer. INVALID if they are not
// messages (the tree untouched), or the volume's error.
@(require_results)
upsert :: proc "contextless" (fs: ^Fs, t: ^Tree, msgs: []Msg) -> vx.Status {
	if fs.err != .Ok {
		return fs.err
	}
	if len(msgs) == 0 {
		return .Ok
	}
	if t.height < 1 || t.height > MAXHEIGHT { // put recurses on it: a damaged snapshot's
		fail(fs, .Err_Invalid)
		return .Err_Invalid
	}
	tree_enter(fs, t)
	total: u32
	for m in msgs {
		if m.op == .Nop || u8(m.op) >= NMSG || len(m.key) == 0 || len(m.key) > KEYMAX || len(m.val) > INLMAX || (m.op == .Wstat && !wstat_well_formed(m)) {
			return .Err_Invalid // refused here, the tree untouched: a buffered message that cannot apply poisons it
		}
		total += ent_size(m, true)
	}
	if total > BUFSPC {
		return .Err_Invalid
	}
	// Sorted, stably: a merge sort, bottom up.
	n := len(msgs)
	a, aok := mem_new(Msg, fs, n)
	if !aok {
		return fs.err
	}
	s, sok := mem_new(Msg, fs, n)
	if !sok {
		mem_release(fs, a)
		return fs.err
	}
	copy(a, msgs)
	for w := 1; w < n; w *= 2 {
		for lo := 0; lo < n; lo += 2 * w {
			mid, hi := min(lo + w, n), min(lo + 2 * w, n)
			merge_msgs(s[lo:hi], a[lo:mid], a[mid:hi])
		}
		a, s = s, a
	}
	defer mem_release(fs, a)
	defer mem_release(fs, s)

	out: Kids
	defer vec_free(fs, &out)
	ok := put(fs, t.root, t.height, nil, a, &out)
	height := t.height
	// Grown: pivots above, until there is one root.
	for ok && out.n > 1 {
		up: Kids
		ok = write_pivots(fs, &out, nil, nil, &up)
		vec_free(fs, &out)
		out = up
		height += 1
		if height > MAXHEIGHT {
			ok = fail(fs, .Err_No_Memory)
		}
	}
	nt := t^
	if ok && out.n == 0 {
		ok = tree_init(fs, &nt) // emptied
	} else if ok {
		nt.root, nt.height = out.buf[0].bp, height
	}
	// Shrunk: a root pivot with one child and nothing buffered gives way to it.
	for ok && nt.height > 1 {
		r := get(fs, nt.root, {.Pivot})
		if r == nil {
			ok = false
			break
		}
		lone := r.nval == 1 && r.nbuf == 0
		child: Bptr
		if lone {
			child = unpack_bptr(tab_get(pivot_kids(r), 0, false).val)
		}
		drop(fs, r)
		if !lone {
			break
		}
		ok = free_block(fs, nt.root)
		nt.root = child
		nt.height -= 1
	}
	if !ok {
		return fs.err != .Ok ? fs.err : .Err_Invalid
	}
	t^ = nt
	return .Ok
}

// --- Looking up ---

// The first entry of table d (n entries) whose key is at least k.
@(private = "file")
tab_search :: proc "contextless" (d: []u8, n: int, msgs: bool, k: []u8) -> int {
	lo, hi := 0, n
	for lo < hi {
		mid := (lo + hi) / 2
		if keycmp(tab_get(d, mid, msgs).key, k) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The path from the root to the leaf that key k belongs to, held: b[0] the
// root. Also the least key above the leaf's range, if there is one.
@(private = "file")
Path :: struct {
	b:      [MAXHEIGHT]^Blk,
	n:      int,
	hi:     []u8, // into one of the blocks
	has_hi: bool,
}

@(private = "file")
path_drop :: proc "contextless" (fs: ^Fs, p: ^Path) {
	for b in p.b[:p.n] {
		drop(fs, b)
	}
	p.n = 0
}

@(private = "file", require_results)
descend :: proc "contextless" (fs: ^Fs, t: ^Tree, k: []u8, p: ^Path) -> bool {
	p^ = {}
	if t.height < 1 || t.height > MAXHEIGHT {
		return fail(fs, .Err_Invalid)
	}
	bp := t.root
	for level := t.height; level >= 1; level -= 1 {
		b := get(fs, bp, {level == 1 ? .Leaf : .Pivot})
		if b == nil {
			path_drop(fs, p)
			return false
		}
		p.b[p.n] = b
		p.n += 1
		if level == 1 {
			break
		}
		d, n := pivot_kids(b), int(b.nval)
		i := tab_search(d, n, false, k)
		// The child: the last whose key is at most k, else the first.
		if i == n || keycmp(tab_get(d, i, false).key, k) > 0 {
			i = i > 0 ? i - 1 : 0
		}
		if i + 1 < n {
			p.hi, p.has_hi = tab_get(d, i + 1, false).key, true // deeper bounds are tighter
		}
		bp = unpack_bptr(tab_get(d, i, false).val)
	}
	return true
}

// The value of key k, copied to buf: its bytes there and .Ok, NOT_FOUND, or
// the volume's error.
@(require_results)
lookup :: proc "contextless" (fs: ^Fs, t: ^Tree, k: []u8, buf: ^[INLMAX]u8) -> ([]u8, vx.Status) {
	if fs.err != .Ok {
		return nil, fs.err
	}
	p: Path
	if !descend(fs, t, k, &p) {
		return nil, fs.err
	}
	if p.n == 0 {
		return nil, .Err_Invalid // descend holds the root at least
	}
	defer path_drop(fs, &p)
	leaf := p.b[p.n - 1]
	kv := Value{key = k}
	if i := tab_search(vals(leaf), int(leaf.nval), false, k); i < int(leaf.nval) {
		if v := tab_get(vals(leaf), i, false); keycmp(v.key, k) == 0 {
			kv = {v.key, v.val, true}
		}
	}
	scratch: [DIRSZ]u8
	ok := true
	for level := p.n - 1; ok && level > 0; { // the deepest buffer first
		level -= 1
		b := p.b[level]
		msgs := pivot_msgs(b)
		for j := tab_search(msgs, int(b.nbuf), true, k); ok && j < int(b.nbuf); j += 1 {
			m := tab_get(msgs, j, true)
			if keycmp(m.key, k) != 0 {
				break
			}
			ok = apply(&kv, m, scratch[:])
		}
	}
	if !ok {
		fail(fs, .Err_Invalid)
		return nil, fs.err
	}
	if !kv.present {
		return nil, .Err_Not_Found
	}
	n := copy(buf[:], kv.val)
	return buf[:n], .Ok
}

// --- Scanning ---

// The keys with a prefix, in order: scan_start, then scan_next until it is
// false (fs.err says whether that was the end), then scan_end. A leaf's range
// at a time, entered from the tree's root, so the tree t points at may change
// between calls.
Scan :: struct {
	t:      ^Tree,
	pfx:    [KEYMAX]u8,
	lo:     [KEYMAX]u8,
	npfx:   int,
	nlo:    int,
	done:   bool, // the batch held is the last
	bytes:  []u8,
	nbytes: int,
	ents:   []Kvp,
	nents:  int,
	at:     int,
}

scan_start :: proc "contextless" (s: ^Scan, t: ^Tree, pfx: []u8) {
	s^ = {t = t, npfx = len(pfx), nlo = len(pfx)}
	if len(pfx) > KEYMAX { // no key has a longer prefix: nothing to scan (M5 step 10)
		s.npfx, s.nlo, s.done, s.t = 0, 0, true, nil
		return
	}
	copy(s.pfx[:], pfx)
	copy(s.lo[:], pfx)
}

// As scan_start, but from key `from` on (within the prefix): a scan taken up
// again where an earlier one stopped.
scan_from :: proc "contextless" (s: ^Scan, t: ^Tree, pfx, from: []u8) {
	scan_start(s, t, pfx)
	if s.done || len(from) > KEYMAX {
		return // past any key: from the prefix's start instead
	}
	if len(from) > 0 && keycmp(from, pfx) > 0 {
		copy(s.lo[:], from)
		s.nlo = len(from)
	}
}

scan_end :: proc "contextless" (fs: ^Fs, s: ^Scan) {
	mem_release(fs, s.bytes)
	mem_release(fs, s.ents)
	s^ = {}
}

@(private = "file")
has_prefix :: proc "contextless" (s: ^Scan, k: []u8) -> bool {
	return len(k) >= s.npfx && bytes_equal(k[:s.npfx], s.pfx[:s.npfx])
}

@(private = "file")
scan_emit :: proc "contextless" (s: ^Scan, kv: Value) {
	k := s.bytes[s.nbytes:][:len(kv.key)]
	copy(k, kv.key)
	v := s.bytes[s.nbytes + len(kv.key):][:len(kv.val)]
	copy(v, kv.val)
	s.ents[s.nents] = {k, v}
	s.nents += 1
	s.nbytes += len(kv.key) + len(kv.val)
}

// The next batch: the effective values in [lo, hi) of the leaf lo belongs to.
@(private = "file", require_results)
scan_fill :: proc "contextless" (fs: ^Fs, s: ^Scan) -> bool {
	p: Path
	descend(fs, s.t, s.lo[:s.nlo], &p) or_return
	if p.n == 0 {
		return fail(fs, .Err_Invalid) // descend holds the root at least
	}
	defer path_drop(fs, &p)
	// Room for every source entry.
	need := p.n * BLKSZ
	nneed := need / 5
	ok := true
	if len(s.bytes) < need {
		mem_release(fs, s.bytes)
		s.bytes, ok = mem_new(u8, fs, need)
	}
	if ok && len(s.ents) < nneed {
		mem_release(fs, s.ents)
		s.ents, ok = mem_new(Kvp, fs, nneed)
	}
	s.nbytes, s.nents, s.at = 0, 0, 0
	if !ok {
		return false
	}
	// Cursors: the leaf's values from lo, and each pivot's messages in [lo, hi).
	leaf := p.b[p.n - 1]
	lv, nval := vals(leaf), int(leaf.nval)
	lo := s.lo[:s.nlo]
	vi := tab_search(lv, nval, false, lo)
	mi, mend: [MAXHEIGHT]int
	for l in 0 ..< p.n - 1 {
		msgs := pivot_msgs(p.b[l])
		mi[l] = tab_search(msgs, int(p.b[l].nbuf), true, lo)
		mend[l] = p.has_hi ? tab_search(msgs, int(p.b[l].nbuf), true, p.hi) : int(p.b[l].nbuf)
	}
	scratch: [DIRSZ]u8
	past := false // beyond the prefix
	for ok {
		// The least key among the sources.
		k: []u8
		have := false
		if vi < nval {
			k, have = tab_get(lv, vi, false).key, true
		}
		for l in 0 ..< p.n - 1 {
			if mi[l] < mend[l] {
				m := tab_get(pivot_msgs(p.b[l]), mi[l], true)
				if !have || keycmp(m.key, k) < 0 {
					k, have = m.key, true
				}
			}
		}
		if !have {
			break
		}
		if !has_prefix(s, k) { // keys start at the prefix: one without it is past them
			past = true
			break
		}
		kv := Value{key = k}
		if vi < nval {
			if v := tab_get(lv, vi, false); keycmp(v.key, k) == 0 {
				kv = {v.key, v.val, true}
				vi += 1
			}
		}
		for l := p.n - 1; ok && l > 0; { // the deepest first
			l -= 1
			for ; ok && mi[l] < mend[l]; mi[l] += 1 {
				m := tab_get(pivot_msgs(p.b[l]), mi[l], true)
				if keycmp(m.key, k) != 0 {
					break
				}
				ok = apply(&kv, m, scratch[:])
			}
		}
		if !ok {
			fail(fs, .Err_Invalid)
		} else if kv.present {
			scan_emit(s, kv)
		}
	}
	// The next batch starts at hi.
	s.done = past || !p.has_hi || !has_prefix(s, p.hi)
	if !s.done {
		copy(s.lo[:], p.hi)
		s.nlo = len(p.hi)
	}
	return ok
}

// The next key and value: false at the end, or on an error (fs.err). They are
// valid until the next call.
scan_next :: proc "contextless" (fs: ^Fs, s: ^Scan) -> (kv: Kvp, ok: bool) {
	for s.at == s.nents {
		if fs.err != .Ok || s.done || !scan_fill(fs, s) {
			return {}, false
		}
	}
	kv = s.ents[s.at]
	s.at += 1
	return kv, true
}
