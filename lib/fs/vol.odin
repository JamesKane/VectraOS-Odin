package fs

import vx "abi:vx"

// Volumes (upstream docs/11 §5, §6): the superblocks, arenas' headers and
// footers, the snapshot tree, branches, deadlists, and the commit, after
// gefs's snap.c, load.c, ream.c and sync.
//
// A volume is two superblocks (its first block and its last), arenas, and in
// them the snapshot tree. That tree holds the snapshots (Ksnap), the labels
// naming them (Klabel), and their deadlists (Kdlist). A branch is a label that
// moves: at each commit its tree becomes a new snapshot, and the label names
// that. A snapshot left with no label and no fork is deleted at once, which is
// what reclaims space as a branch moves on.
//
// Deadlists, as gefs's: every block pointer carries its birth generation. A
// block a branch kills (born before the generation being built, so still in
// the last snapshot) goes on the deadlist keyed by the snapshot being built
// and the block's birth. Deleting snapshot S, followed by T and preceded by
// P: S's lists born at or before P still hold blocks P has, and become T's;
// the rest, and T's lists born after P, held blocks only S had, and are
// freed. Unlike gefs's, a deadlist is a chain written once, and Kdlist's key
// has a sequence number: merging lists re-keys them, and never writes a block
// a commit can see.
//
// The commit (11 §6): the data written so far made durable by a barrier; the
// branches' new snapshots put in the snapshot tree, their kills in deadlists;
// the blocks the commit frees written as a chain the superblock names; each
// arena's log written, and its header (saying how much of the log the commit
// covers); a barrier; the superblock; a barrier; the backup and the footers;
// a barrier. Then what the commit freed is free. A crash before the
// superblock lands leaves the last commit; mounting frees again what the
// commit it finds freed, whose frees were logged past what it covers.
//
// Names (labels, branches) are strings as upstream's C has them: they end at
// a NUL, if there is one.

MAXBRANCH :: 16
DLPER :: LOGSPC / 8 // addresses in a deadlist block

Branch :: struct {
	name:  [LABELMAX]u8,
	nname: int,
	open:  bool,
	t:     Tree, // as changed
	at:    Snap, // the snapshot it was at, at the last commit
}

branch_name :: proc "contextless" (br: ^Branch) -> string {
	return string(br.name[:br.nname])
}

// A volume: the library's state, the last commit's superblock, the snapshot
// tree and the open branches. Large (it holds its superblock buffers): keep
// it in static storage or the caller's memory, and never copy it.
Vol :: struct {
	fs:         Fs,
	sb:         Sb, // as of the last commit
	snap:       Tree,
	nextgen:    Gen,
	nextqid:    u64,
	nextdl:     u64,
	arenahash:  []u64, // each arena's header hash, as the next superblock records it
	freedchain: Vec(Addr), // the last commit's freed chain: deferred at the next
	hdr:        []^Blk, // the headers a commit writes, held until their footers are
	br:         [MAXBRANCH]Branch,
	sbuf:       [2][BLKSZ]u8, // the superblocks, as mount reads them and commit writes them
	repair:     [2][BLKSZ]u8, // an arena's two copies, as mount compares them
	blk:        [BLKSZ]u8, // a file's block, as read and write piece it together
}

// A name's length, as upstream's C reads one: up to its first NUL, and max + 1
// if it is longer than max.
namelen :: proc "contextless" (s: string, max_len: int) -> int {
	n := 0
	for n <= max_len && n < len(s) && s[n] != 0 {
		n += 1
	}
	return n
}

@(private = "file")
vol_bad :: proc "contextless" (v: ^Vol) -> vx.Status {
	fail(&v.fs, .Err_Invalid)
	return .Err_Invalid
}

// --- Keys ---

key_id :: proc "contextless" (k: []u8, kind: Key_Kind, id: u64) -> []u8 {
	store(k, Key_Id{kind = u8(kind), id = u64be(id)})
	return k[:size_of(Key_Id)]
}

@(private = "file")
key_label :: proc "contextless" (k: []u8, name: []u8) -> []u8 {
	k[0] = u8(Key_Kind.Label)
	copy(k[1:], name)
	return k[:1 + len(name)]
}

@(private = "file")
key_dlist :: proc "contextless" (k: []u8, snap, birth: Gen, seq: u64) -> []u8 {
	store(k, Key_Dlist{kind = u8(Key_Kind.Dlist), snap = u64be(snap), birth = u64be(birth), seq = u64be(seq)})
	return k[:size_of(Key_Dlist)]
}

// --- The snapshot tree ---

// A batch of messages for the snapshot tree, their bytes kept with them.
// Allocated (batch_new), never copied: its messages point into it.
Sbatch :: struct {
	m:     [64]Msg,
	bytes: [64 * (26 + SNAPSZ)]u8,
	n:     int,
	used:  int,
	size:  u32,
}

batch_new :: proc "contextless" (v: ^Vol) -> ^Sbatch {
	b, ok := mem_new(Sbatch, &v.fs, 1)
	return ok ? &b[0] : nil
}

batch_free :: proc "contextless" (v: ^Vol, b: ^Sbatch) {
	if b != nil {
		mem_release(&v.fs, ([^]Sbatch)(b)[:1])
	}
}

@(require_results)
snap_flush :: proc "contextless" (v: ^Vol, b: ^Sbatch) -> bool {
	st := upsert(&v.fs, &v.snap, b.m[:b.n])
	b.n, b.used, b.size = 0, 0, 0
	return st == .Ok && end_op(&v.fs)
}

@(private = "file", require_results)
snap_msg :: proc "contextless" (v: ^Vol, b: ^Sbatch, op: Op, k, val: []u8) -> bool {
	sz := u32(2 + 1 + 2 + len(k) + 2 + len(val))
	if (b.n == len(b.m) || b.size + sz > BUFSPC || b.used + len(k) + len(val) > len(b.bytes)) && !snap_flush(v, b) {
		return false
	}
	p := b.bytes[b.used:]
	copy(p, k)
	copy(p[len(k):], val)
	b.m[b.n] = {op = op, key = p[:len(k)], val = len(val) > 0 ? p[len(k):][:len(val)] : nil}
	b.n += 1
	b.used += len(k) + len(val)
	b.size += sz
	return true
}

@(require_results)
snap_set :: proc "contextless" (v: ^Vol, b: ^Sbatch, s: Snap) -> bool {
	k: [9]u8
	val: [SNAPSZ]u8
	pack_snap(val[:], s)
	return snap_msg(v, b, .Insert, key_id(k[:], .Snap, u64(s.gen)), val[:])
}

@(private = "file", require_results)
label_set :: proc "contextless" (v: ^Vol, b: ^Sbatch, name: []u8, gen: Gen, flags: Label_Flags) -> bool {
	k: [KEYMAX]u8
	val: [size_of(Label_Disk)]u8
	store(val[:], Label_Disk{gen = u64le(gen), flags = u32le(transmute(u32)flags)})
	return snap_msg(v, b, .Insert, key_label(k[:], name), val[:])
}

@(require_results)
snap_get :: proc "contextless" (v: ^Vol, gen: Gen) -> (s: Snap, st: vx.Status) {
	k: [9]u8
	buf: [INLMAX]u8
	val: []u8
	val, st = lookup(&v.fs, &v.snap, key_id(k[:], .Snap, u64(gen)), &buf)
	if st != .Ok {
		return
	}
	if len(val) != SNAPSZ {
		return {}, vol_bad(v)
	}
	s = unpack_snap(val)
	if s.height < 1 || s.height > MAXHEIGHT {
		return {}, vol_bad(v) // a write would recurse that deep
	}
	if s.gen != gen {
		return {}, vol_bad(v)
	}
	return s, .Ok
}

// What label `name` names: its snapshot, and whether it is a branch.
@(require_results)
label_get :: proc "contextless" (v: ^Vol, name: string) -> (gen: Gen, flags: Label_Flags, st: vx.Status) {
	n := namelen(name, LABELMAX)
	if n == 0 || n > LABELMAX {
		return 0, {}, .Err_Invalid
	}
	k: [KEYMAX]u8
	buf: [INLMAX]u8
	val: []u8
	val, st = lookup(&v.fs, &v.snap, key_label(k[:], transmute([]u8)name[:n]), &buf)
	if st != .Ok {
		return
	}
	if len(val) != size_of(Label_Disk) {
		return 0, {}, vol_bad(v)
	}
	l := load(Label_Disk, val)
	return Gen(l.gen), transmute(Label_Flags)u32(l.flags), .Ok
}

// --- Deadlists and other chains ---

// Writes addresses as a chain of deadlist blocks, the last written first; its
// head, or 0 for none. The chain's own blocks are added to `blocks` if it is
// given.
@(private = "file")
chain_write :: proc "contextless" (v: ^Vol, a: []Addr, blocks: ^Vec(Addr)) -> Addr {
	fs := &v.fs
	tree_enter(fs, &v.snap)
	next: Addr
	for at := 0; at < len(a); {
		b := new_block(fs, .Dlist)
		if b == nil {
			return 0
		}
		k := min(len(a) - at, DLPER)
		for i in 0 ..< k {
			put64(data(b)[8 * i:], u64(a[at + i]))
		}
		b.logsz = u16(8 * k)
		b.logp = {addr = next}
		next = b.bp.addr
		ok := write_block(fs, b)
		drop(fs, b)
		if blocks != nil {
			ok = ok && vec_push(fs, blocks, next)
		}
		if !ok {
			return 0
		}
		at += k
	}
	return next
}

Chain_Fn :: proc "contextless" (v: ^Vol, addr: Addr, ctx: rawptr) -> bool

// Each address in the chain at hd (if `listed`), then each of the chain's own
// blocks (if `own`), to fn. False on damage: a loop, or a block that is not a
// deadlist's.
@(require_results)
chain_each :: proc "contextless" (v: ^Vol, hd: Addr, fn: Chain_Fn, ctx: rawptr, listed, own: bool) -> bool {
	fs := &v.fs
	hd := hd
	for chain := u64(0); hd != 0; chain += 1 {
		if chain > fs.dev.size / BLKSZ {
			return fail(fs, .Err_Invalid)
		}
		b := get(fs, {addr = hd}, {.Dlist})
		if b == nil {
			return false
		}
		ok := true
		for i := 0; listed && ok && i < int(b.logsz); i += 8 {
			ok = fn(v, Addr(get64(data(b)[i:])), ctx)
		}
		self := hd
		hd = b.logp.addr
		drop(fs, b)
		if ok && own {
			ok = fn(v, self, ctx)
		}
		if !ok {
			return false
		}
	}
	return true
}

@(private = "file")
defer_one :: proc "contextless" (v: ^Vol, addr: Addr, _: rawptr) -> bool {
	return defer_free(&v.fs, addr)
}

@(private = "file")
free_one :: proc "contextless" (v: ^Vol, addr: Addr, _: rawptr) -> bool {
	return block_dealloc(&v.fs, addr)
}

@(private = "file")
Dlent :: struct {
	birth: Gen,
	seq:   u64,
	hd:    Addr,
	count: u64,
}

// The deadlists of snapshot gen, read out of the snapshot tree.
@(private = "file", require_results)
dlists_of :: proc "contextless" (v: ^Vol, gen: Gen, out: ^Vec(Dlent)) -> bool {
	pfx: [9]u8
	s: Scan
	scan_start(&s, &v.snap, key_id(pfx[:], .Dlist, u64(gen)))
	defer scan_end(&v.fs, &s)
	ok := true
	for kv in scan_next(&v.fs, &s) {
		if len(kv.key) != size_of(Key_Dlist) || len(kv.val) != size_of(Dlist_Disk) {
			ok = fail(&v.fs, .Err_Invalid)
			break
		}
		k, d := load(Key_Dlist, kv.key), load(Dlist_Disk, kv.val)
		ok = vec_push(&v.fs, out, Dlent{Gen(k.birth), u64(k.seq), Addr(d.head), u64(d.count)})
		if !ok {
			break
		}
	}
	return ok && v.fs.err == .Ok
}

@(private = "file", require_results)
dlist_put :: proc "contextless" (v: ^Vol, b: ^Sbatch, snap, birth: Gen, seq: u64, hd: Addr, count: u64) -> bool {
	k: [25]u8
	val: [size_of(Dlist_Disk)]u8
	store(val[:], Dlist_Disk{head = u64le(hd), count = u64le(count)})
	return snap_msg(v, b, .Insert, key_dlist(k[:], snap, birth, seq), val[:])
}

@(private = "file", require_results)
dlist_del :: proc "contextless" (v: ^Vol, b: ^Sbatch, snap, birth: Gen, seq: u64) -> bool {
	k: [25]u8
	return snap_msg(v, b, .Delete, key_dlist(k[:], snap, birth, seq), nil)
}

// Snapshot s is deleted, followed by succ (0: none) and preceded by pred: its
// deadlists born at or before pred become succ's; the rest are freed, with
// succ's born after pred. With no successor, its lists' blocks are still
// pred's: only the lists themselves go (the tree's own blocks are the
// caller's to sweep).
@(private = "file", require_results)
reclaim :: proc "contextless" (v: ^Vol, b: ^Sbatch, s, succ, pred: Gen) -> bool {
	d: Vec(Dlent)
	defer vec_free(&v.fs, &d)
	ok := dlists_of(v, s, &d)
	for e in items(&d) {
		if !ok {
			break
		}
		ok = dlist_del(v, b, s, e.birth, e.seq)
		if ok && succ != 0 && e.birth <= pred {
			ok = dlist_put(v, b, succ, e.birth, e.seq, e.hd, e.count)
		} else if ok {
			ok = chain_each(v, e.hd, defer_one, nil, succ != 0, true)
		}
	}
	d.n = 0
	if ok && succ != 0 && snap_flush(v, b) {
		ok = dlists_of(v, succ, &d)
	}
	for e in items(&d) {
		if !ok {
			break
		}
		if e.birth > pred {
			ok = dlist_del(v, b, succ, e.birth, e.seq) && chain_each(v, e.hd, defer_one, nil, true, true)
		}
	}
	return ok
}

// Writes the kills of generation `death` born at or before `keep` as
// deadlists of snapshot `death`; the rest are deferred (nothing kept still
// has them).
@(private = "file", require_results)
write_kills :: proc "contextless" (v: ^Vol, b: ^Sbatch, death, keep: Gen) -> bool {
	fs := &v.fs
	// Gathered by birth: one list each (sorted by birth, a few at a time).
	ok := true
	a: Vec(Addr)
	defer vec_free(fs, &a)
	for {
		birth: Gen // the least birth of this death not yet written
		for e in items(&fs.dead) {
			if e.death == death && e.birth != 0 && (birth == 0 || e.birth < birth) {
				birth = e.birth
			}
		}
		if birth == 0 || !ok {
			break
		}
		a.n = 0
		for &e in items(&fs.dead) {
			if !ok {
				break
			}
			if e.death != death || e.birth != birth {
				continue
			}
			if birth > keep {
				ok = defer_free(fs, e.addr)
			} else {
				ok = vec_push(fs, &a, e.addr)
			}
			e.birth = 0 // written
		}
		if ok && a.n > 0 {
			hd := chain_write(v, items(&a), nil)
			ok = hd != 0
			if ok { // the sequence number is taken only for a list written (upstream's v->nextdl++ behind &&)
				ok = dlist_put(v, b, death, birth, v.nextdl, hd, u64(a.n))
				v.nextdl += 1
			}
		}
	}
	return ok
}

// --- Snapshots of branches at a commit ---

// Branch br's tree becomes a new snapshot, which its label names. The one it
// was at is kept if anything else names it, and deleted if not.
@(private = "file", require_results)
branch_update :: proc "contextless" (v: ^Vol, b: ^Sbatch, br: ^Branch) -> bool {
	snap_flush(v, b) or_return // reads below see every change so far
	o, st := snap_get(v, br.at.gen)
	if st != .Ok {
		return fail(&v.fs, .Err_Invalid)
	}
	t := Snap {
		root   = br.t.root,
		height = br.t.height,
		flags  = o.flags,
		gen    = br.t.memgen,
		base   = o.base,
		nlbl   = 1,
	}
	if o.nlbl > 0 {
		o.nlbl -= 1
	}
	del := o.nlbl == 0 && o.nref == 0
	ok := true
	if del {
		t.pred = o.pred
		if o.pred != 0 {
			p: Snap
			p, st = snap_get(v, o.pred)
			ok = st == .Ok
			p.succ = t.gen
			ok = ok && snap_set(v, b, p)
		}
		k: [9]u8
		ok = ok && snap_msg(v, b, .Delete, key_id(k[:], .Snap, u64(o.gen)), nil)
	} else {
		t.pred = o.gen
		o.succ = t.gen
		ok = snap_set(v, b, o)
	}
	ok = ok && snap_set(v, b, t) && label_set(v, b, br.name[:br.nname], t.gen, {.Mutable})
	// Its kills: those still held by what precedes the new snapshot are its
	// deadlists; the rest are free once this commit is.
	ok = ok && write_kills(v, b, t.gen, del ? o.pred : o.gen)
	if ok && del {
		ok = snap_flush(v, b) && reclaim(v, b, o.gen, t.gen, o.pred)
	}
	if ok {
		br.at = t
	}
	return ok
}

// --- Superblocks and headers ---

pack_sb :: proc "contextless" (v: ^Vol, p: []u8) {
	for &c in p[:BLKSZ] {
		c = 0
	}
	s := &v.sb
	store(p, Sb_Disk {
		magic    = MAGIC,
		version  = VERSION,
		blksz    = BLKSZ,
		bufspc   = BUFSPC,
		narenas  = u32le(s.narenas),
		snapht   = u32le(s.snapht),
		snaproot = bptr_disk(s.snaproot),
		commit   = u64le(s.commit),
		nextgen  = u64le(s.nextgen),
		nextqid  = u64le(s.nextqid),
		nextdl   = u64le(s.nextdl),
		flags    = u64le(s.flags),
		freed    = u64le(s.freed),
	}) // and a word to spare
	at := SBHDSZ
	for i in 0 ..< int(s.narenas) {
		a := &v.fs.arenas[i]
		store(p[at:], Arena_Entry_Disk{base = u64le(a.base), blocks = u64le(a.size / BLKSZ), hash = u64le(v.arenahash[i])})
		at += size_of(Arena_Entry_Disk)
	}
	put64(p[at:], xxh64(p[:at], 0))
}

// A superblock, if it is one: false if not.
@(require_results)
unpack_sb :: proc "contextless" (p: []u8) -> (s: Sb, ok: bool) {
	h := load(Sb_Disk, p)
	if h.magic != MAGIC || h.version != VERSION || h.blksz != BLKSZ || h.bufspc != BUFSPC {
		return {}, false
	}
	s = {
		narenas  = u32(h.narenas),
		snapht   = u32(h.snapht),
		snaproot = bptr_of(h.snaproot),
		commit   = u64(h.commit),
		nextgen  = Gen(h.nextgen),
		nextqid  = u64(h.nextqid),
		nextdl   = u64(h.nextdl),
		flags    = u64(h.flags),
		freed    = Addr(h.freed),
	}
	if s.narenas == 0 || s.narenas > MAXARENAS || s.snapht == 0 || s.snapht > MAXHEIGHT {
		return {}, false
	}
	at := SBHDSZ + size_of(Arena_Entry_Disk) * int(s.narenas)
	return s, get64(p[at:]) == xxh64(p[:at], 0)
}

@(private = "file")
arena_reserve :: proc "contextless" (size: u64) -> u64 {
	r := size / 1024
	r = max(r, 512 * 1024)
	r = min(r, 8 * 1024 * 1024)
	if r > size / 8 {
		r = size / 8 / BLKSZ * BLKSZ
	}
	return r
}

@(private = "file")
last_block :: proc "contextless" (fs: ^Fs) -> Addr {
	return Addr((fs.dev.size / BLKSZ - 1) * BLKSZ)
}

// --- The commit ---

// Makes everything changed so far durable at once (11 §6). With readers on
// other threads (blk.odin), its caller waits until none is in a read first,
// and lets none in until it returns: what they kept from being given back is
// logged free then, and what the commit frees is free at once.
@(require_results)
commit :: proc "contextless" (v: ^Vol) -> vx.Status {
	fs := &v.fs
	if fs.err != .Ok {
		return fs.err
	}
	if !readers_reclaim(fs) {
		return fs.err
	}
	// 1. What is written so far lands first.
	if fs.dev.barrier(fs.dev.ctx) != .Ok {
		fail(fs, .Err_Io)
		return fs.err
	}
	fs.use_reserve = true
	b := batch_new(v)
	ok := b != nil
	// The branches' new snapshots, and their deadlists.
	for &br in v.br {
		if !ok {
			break
		}
		if br.open && (br.t.root.addr != br.at.root.addr || br.t.height != br.at.height) {
			ok = branch_update(v, b, &br)
		}
	}
	ok = ok && snap_flush(v, b)
	fs.dead.n = 0
	// 2. What the commit frees: the snapshot tree's old blocks, dropped
	// deadlists, compressed logs' old chains, and the last commit's chain of
	// these; written as a chain of its own, which the superblock names.
	for &a in fs.arenas { // long logs compressed, the old chains deferred
		if !ok {
			break
		}
		if a.nlog >= fs.compress_at && a.nlog >= 2 * a.lastlog {
			ok = log_compress(fs, &a)
		}
		ok = ok && log_retire(fs, &a)
	}
	for addr in items(&v.freedchain) {
		if !ok {
			break
		}
		ok = defer_free(fs, addr)
	}
	v.freedchain.n = 0
	freed: Addr
	if ok && fs.deferred.n > 0 {
		freed = chain_write(v, items(&fs.deferred), &v.freedchain)
		ok = freed != 0
	}
	ok = ok && end_op(fs)
	// 3. Each arena's log, and its header; a barrier.
	for &a, i in fs.arenas {
		if !ok {
			break
		}
		h: Arena_Hdr
		h, ok = arena_seal(fs, &a)
		cache_forget(fs, a.base) // the last commit's
		hb: ^Blk
		if ok {
			hb = new_block_at(fs, a.base, .Arena)
		}
		ok = hb != nil
		if ok {
			pack_arena_hdr(data(hb), h)
			ok = write_block(fs, hb)
			v.arenahash[i] = hb.bp.hash
		}
		v.hdr[i] = hb
	}
	ok = ok && fs.dev.barrier(fs.dev.ctx) == .Ok
	// 4. The superblock; a barrier. This is the write that commits. The backup
	// follows with the footers: the two are never in flight together, so a cut
	// cannot tear both (one of them is always whole, the last commit's or this
	// one's).
	was := v.sb
	sbuf := &v.sbuf[0]
	if ok {
		v.sb.narenas, v.sb.snapht, v.sb.snaproot = u32(len(fs.arenas)), v.snap.height, v.snap.root
		v.sb.commit += 1
		v.sb.nextgen, v.sb.nextqid, v.sb.nextdl = v.nextgen, v.nextqid, v.nextdl
		v.sb.freed = freed
		pack_sb(v, sbuf[:])
		ok = fs.dev.write(fs.dev.ctx, 0, sbuf) == .Ok && fs.dev.barrier(fs.dev.ctx) == .Ok
		fs.writes += 1
		if !ok {
			v.sb = was
		}
	}
	// 5. The backup superblock, and the footers: the headers' copies.
	if ok {
		ok = fs.dev.write(fs.dev.ctx, last_block(fs), sbuf) == .Ok
	}
	fs.writes += 1
	for &a, i in fs.arenas {
		hb := v.hdr[i]
		if hb == nil {
			continue
		}
		if ok {
			ok = fs.dev.write(fs.dev.ctx, a.base + BLKSZ + Addr(a.size), &hb.buf) == .Ok
		}
		fs.writes += 1
		drop(fs, hb)
		v.hdr[i] = nil
	}
	// 6. A barrier: the backup and the footers durable before anything this
	// commit freed can be reused, so either superblock is still enough to
	// mount if the next commit's is torn.
	ok = ok && fs.dev.barrier(fs.dev.ctx) == .Ok
	if !ok {
		fail(fs, .Err_Io)
	}
	// 7. What it freed is free; the trees go on in new generations.
	ok = ok && free_deferred(fs)
	for &br in v.br {
		if !ok {
			break
		}
		if br.open {
			br.t.memgen = v.nextgen
			v.nextgen += 1
		}
	}
	v.snap.memgen = v.nextgen
	v.nextgen += 1
	fs.use_reserve = false
	batch_free(v, b)
	if ok {
		return .Ok
	}
	return fs.err != .Ok ? fs.err : .Err_Invalid
}

// --- Branches and snapshots ---

@(private = "file")
branch_named :: proc "contextless" (v: ^Vol, name: string) -> ^Branch {
	n := namelen(name, LABELMAX)
	for &br in v.br {
		if br.open && br.nname == n && branch_name(&br) == name[:n] {
			return &br
		}
	}
	return nil
}

// Loads branch `name`, as its label says now, into br.
@(private = "file", require_results)
branch_load :: proc "contextless" (v: ^Vol, name: string, br: ^Branch) -> vx.Status {
	n := namelen(name, LABELMAX)
	gen, flags, st := label_get(v, name)
	if st != .Ok {
		return st
	}
	if .Mutable not_in flags {
		return .Err_Access // a snapshot, not a branch
	}
	s: Snap
	if s, st = snap_get(v, gen); st != .Ok {
		return st == .Err_Not_Found ? vol_bad(v) : st // a label naming nothing
	}
	br^ = {nname = n, open = true, at = s}
	copy(br.name[:], name[:n])
	br.t = {root = s.root, height = s.height, memgen = v.nextgen, base = s.base}
	v.nextgen += 1
	return .Ok
}

// Branch `name`, open for changes: valid until the volume is unmounted.
@(require_results)
branch_open :: proc "contextless" (v: ^Vol, name: string) -> (^Branch, vx.Status) {
	if open := branch_named(v, name); open != nil {
		return open, .Ok
	}
	br: ^Branch
	for &b in v.br {
		if !b.open {
			br = &b
			break
		}
	}
	if br == nil {
		return nil, .Err_No_Memory // MAXBRANCH open already
	}
	if st := branch_load(v, name, br); st != .Ok {
		br^ = {}
		return nil, st
	}
	return br, .Ok
}

// The tree a label names, as of the last commit, to read.
@(require_results)
snap_open :: proc "contextless" (v: ^Vol, name: string) -> (Tree, vx.Status) {
	gen, _, st := label_get(v, name)
	s: Snap
	if st == .Ok {
		s, st = snap_get(v, gen)
	}
	if st != .Ok {
		return {}, st
	}
	return {root = s.root, height = s.height, base = s.base}, .Ok
}

// A data block for tree t, held: born in t's generation.
new_data :: proc "contextless" (fs: ^Fs, t: ^Tree) -> ^Blk {
	tree_enter(fs, t)
	return new_block(fs, .Dat)
}

// --- Labels, forks and deleting snapshots ---

// The blocks of a tree born after `keep`, deferred: what a deleted snapshot
// alone held, when nothing follows it (what was born by `keep` is still its
// predecessor's, or its base's). A node is never older than what it points
// at, so a subtree born by `keep` is skipped whole. Recursive as deep as the
// tree is tall.
@(private = "file", require_results)
sweep :: proc "contextless" (v: ^Vol, bp: Bptr, level: u32, keep: Gen) -> bool {
	if bp.gen <= keep {
		return true
	}
	fs := &v.fs
	b := get(fs, bp, {level == 1 ? .Leaf : .Pivot})
	if b == nil {
		return false
	}
	defer drop(fs, b)
	defer_free(fs, bp.addr) or_return
	if level == 1 {
		for i in 0 ..< int(b.nval) {
			e := tab_get(vals(b), i, false)
			if owns_block(e.key, e.val) {
				if d := unpack_bptr(e.val[1:]); d.addr != 0 && d.gen > keep {
					defer_free(fs, d.addr) or_return
				}
			}
		}
		return true
	}
	for i in 0 ..< int(b.nbuf) {
		m := tab_get(pivot_msgs(b), i, true)
		if m.op == .Insert && owns_block(m.key, m.val) {
			if d := unpack_bptr(m.val[1:]); d.addr != 0 && d.gen > keep {
				defer_free(fs, d.addr) or_return
			}
		}
	}
	for i in 0 ..< int(b.nval) {
		sweep(v, unpack_bptr(tab_get(pivot_kids(b), i, false).val), level - 1, keep) or_return
	}
	return true
}

// Deletes snapshot gen, which nothing names: its neighbours linked past it,
// its deadlists merged or dropped, and, at the end of its chain, its tree
// swept. A fork's whole chain gone, its base loses a fork, and is deleted in
// turn if nothing else holds it.
@(private = "file", require_results)
snap_delete :: proc "contextless" (v: ^Vol, b: ^Sbatch, gen: Gen) -> bool {
	gen := gen
	for gen != 0 {
		snap_flush(v, b) or_return
		t, st := snap_get(v, gen)
		if st != .Ok {
			return false
		}
		n: Snap
		ok := true
		if t.pred != 0 {
			n, st = snap_get(v, t.pred)
			ok = st == .Ok
			n.succ = t.succ
			ok = ok && snap_set(v, b, n)
		}
		if ok && t.succ != 0 {
			n, st = snap_get(v, t.succ)
			ok = st == .Ok
			n.pred = t.pred
			ok = ok && snap_set(v, b, n)
		}
		k: [9]u8
		ok = ok && snap_msg(v, b, .Delete, key_id(k[:], .Snap, u64(t.gen)), nil) && snap_flush(v, b)
		ok = ok && reclaim(v, b, t.gen, t.succ, t.pred)
		if ok && t.succ == 0 {
			ok = sweep(v, t.root, t.height, t.pred != 0 ? t.pred : t.base)
		}
		gen = 0
		if ok && t.pred == 0 && t.succ == 0 && t.base != 0 {
			ok = snap_flush(v, b)
			if ok {
				n, st = snap_get(v, t.base)
				ok = st == .Ok && n.nref != 0
			}
			if ok {
				n.nref -= 1
			}
			ok = ok && snap_set(v, b, n)
			if ok && n.nlbl == 0 && n.nref == 0 {
				gen = n.gen
			}
		}
		if !ok {
			return v.fs.err == .Ok ? fail(&v.fs, .Err_Invalid) : false
		}
	}
	return snap_flush(v, b)
}

// A snapshot of `s`, forked as a branch's first: sharing its tree, based on it.
@(private = "file", require_results)
fork_of :: proc "contextless" (v: ^Vol, b: ^Sbatch, s: ^Snap, name: []u8) -> bool {
	f := Snap {
		root   = s.root,
		height = s.height,
		flags  = s.flags,
		gen    = v.nextgen,
		base   = s.gen,
		nlbl   = 1,
	}
	v.nextgen += 1
	s.nref += 1
	return snap_set(v, b, s^) && snap_set(v, b, f) && label_set(v, b, name, f.gen, {.Mutable})
}

@(private = "file", require_results)
vol_status :: proc "contextless" (v: ^Vol, ok: bool) -> vx.Status {
	if ok {
		return .Ok
	}
	return v.fs.err != .Ok ? v.fs.err : .Err_Invalid
}

// Labels the snapshot `from` names (as of the last commit) `name`: a snapshot
// that stays, or, with .Mutable, a new branch forked from it. Durable at the
// next commit.
@(require_results)
label :: proc "contextless" (v: ^Vol, from, name: string, flags: Label_Flags) -> vx.Status {
	n := namelen(name, LABELMAX)
	if n == 0 || n > LABELMAX {
		return .Err_Invalid
	}
	if st := room(&v.fs, 0, false); st != .Ok { // the snapshot tree grows
		return st
	}
	gen, _, st := label_get(v, from)
	if st != .Ok {
		return st
	}
	if _, _, st = label_get(v, name); st != .Err_Not_Found {
		return st == .Ok ? .Err_Exists : st
	}
	s: Snap
	if s, st = snap_get(v, gen); st != .Ok {
		return st
	}
	b := batch_new(v)
	defer batch_free(v, b)
	ok := b != nil
	nm := transmute([]u8)name[:n]
	if ok && .Mutable in flags {
		ok = fork_of(v, b, &s, nm)
	} else if ok {
		s.nlbl += 1
		ok = snap_set(v, b, s) && label_set(v, b, nm, s.gen, {})
	}
	ok = ok && snap_flush(v, b)
	return vol_status(v, ok)
}

// Removes a label. The snapshot it named is deleted if nothing else names it
// or was forked from it. A branch must not be open.
@(require_results)
unlabel :: proc "contextless" (v: ^Vol, name: string) -> vx.Status {
	gen: Gen
	st := room(&v.fs, 0, true) // frees, in the end
	if st == .Ok {
		gen, _, st = label_get(v, name)
	}
	if st != .Ok {
		return st
	}
	if branch_named(v, name) != nil {
		return .Err_Bad_State
	}
	s: Snap
	if s, st = snap_get(v, gen); st != .Ok {
		return st
	}
	b := batch_new(v)
	defer batch_free(v, b)
	ok := b != nil
	k: [KEYMAX]u8
	n := namelen(name, LABELMAX)
	ok = ok && snap_msg(v, b, .Delete, key_label(k[:], transmute([]u8)name[:n]), nil)
	if ok && s.nlbl > 0 {
		s.nlbl -= 1
	}
	ok = ok && snap_set(v, b, s)
	if ok && s.nlbl == 0 && s.nref == 0 {
		ok = snap_delete(v, b, s.gen)
	}
	ok = ok && snap_flush(v, b)
	return vol_status(v, ok)
}

// Rolls branch `name` back to the snapshot `to` names: the branch becomes a
// fork of it (11 §5), and the snapshot it was at is deleted if nothing else
// names it. The branch must not be open.
@(require_results)
rollback :: proc "contextless" (v: ^Vol, name, to: string) -> vx.Status {
	gen, target: Gen
	flags: Label_Flags
	st := room(&v.fs, 0, true)
	if st == .Ok {
		gen, flags, st = label_get(v, name)
	}
	if st == .Ok {
		target, _, st = label_get(v, to)
	}
	if st != .Ok {
		return st
	}
	if .Mutable not_in flags {
		return .Err_Access
	}
	if branch_named(v, name) != nil {
		return .Err_Bad_State
	}
	t: Snap
	if t, st = snap_get(v, target); st != .Ok {
		return st
	}
	b := batch_new(v)
	defer batch_free(v, b)
	o: Snap
	ok := b != nil && fork_of(v, b, &t, transmute([]u8)name[:namelen(name, LABELMAX)]) && snap_flush(v, b)
	if ok {
		o, st = snap_get(v, gen)
		ok = st == .Ok
	}
	if ok && o.nlbl > 0 {
		o.nlbl -= 1
	}
	ok = ok && snap_set(v, b, o)
	if ok && o.nlbl == 0 && o.nref == 0 {
		ok = snap_delete(v, b, o.gen)
	}
	ok = ok && snap_flush(v, b)
	return vol_status(v, ok)
}

// Rolls an open branch back to the snapshot `to` names (rollback), in place:
// br stays the branch, at its new state. Nothing in it may be uncommitted.
@(require_results)
branch_rollback :: proc "contextless" (v: ^Vol, br: ^Branch, to: string) -> vx.Status {
	if br.t.root.addr != br.at.root.addr || br.t.height != br.at.height {
		return .Err_Bad_State
	}
	name: [LABELMAX]u8
	n := copy(name[:], branch_name(br))
	was := br^
	br.open = false
	st := rollback(v, string(name[:n]), to)
	again := branch_load(v, string(name[:n]), br) // as it is now, rolled back or not
	if again != .Ok {
		br^ = was // still open, as it was: its caller holds it (M5 step 10)
	}
	return st != .Ok ? st : again
}

// Closes a branch with nothing uncommitted.
@(require_results)
branch_close :: proc "contextless" (br: ^Branch) -> vx.Status {
	if br.t.root.addr != br.at.root.addr || br.t.height != br.at.height {
		return .Err_Bad_State
	}
	br.open = false
	return .Ok
}

// --- Making and mounting volumes ---

@(private = "file", require_results)
vol_alloc :: proc "contextless" (v: ^Vol, narenas: u32) -> bool {
	fs := &v.fs
	ok: bool
	v.arenahash, ok = mem_new(u64, fs, int(narenas))
	if ok {
		v.hdr, ok = mem_new(^Blk, fs, int(narenas))
	}
	return ok && alloc_arenas(fs, narenas)
}

// A new volume over the whole device, with `narenas` arenas (0: as its size
// suggests) and an empty branch for each name, committed; left mounted.
// Unmount it whatever this returns.
@(require_results)
format :: proc "contextless" (v: ^Vol, dev: Dev, mem: Mem, cache: u32, narenas: u32, branches: []string) -> vx.Status {
	v^ = {}
	fs := &v.fs
	blocks := dev.size / BLKSZ
	narenas := narenas
	if narenas == 0 {
		narenas = u32(dev.size / (4 << 30)) + 1
	}
	narenas = min(narenas, 64)
	for narenas > 1 && (blocks - 2) / u64(narenas) < 64 {
		narenas -= 1
	}
	if blocks < 2 + 8 || (blocks - 2) / u64(narenas) < 8 {
		return .Err_Invalid // too small to hold anything
	}
	if !open(fs, dev, mem, cache) || !vol_alloc(v, narenas) {
		return fs.err
	}
	per := (blocks - 2) / u64(narenas)
	for &a, i in fs.arenas {
		if !arena_init(fs, &a, Addr((1 + u64(i) * per) * BLKSZ), per - 2) {
			return fs.err
		}
		a.reserve = arena_reserve(a.size)
	}
	v.nextgen, v.nextqid, v.nextdl = 1, 1, 1
	v.snap = {memgen = v.nextgen, snap = true}
	v.nextgen += 1
	if !tree_init(fs, &v.snap) {
		return fs.err
	}
	b := batch_new(v)
	ok := b != nil
	for name, i in branches { // each name once: a second would label nothing of its own
		for other in branches[:i] {
			ni := namelen(name, LABELMAX)
			if ni == namelen(other, LABELMAX) && name[:min(ni, len(name))] == other[:min(ni, len(other))] {
				ok = false
			}
		}
	}
	for name in branches {
		if !ok {
			break
		}
		n := namelen(name, LABELMAX)
		t := Tree{memgen = v.nextgen}
		v.nextgen += 1
		ok = n != 0 && n <= LABELMAX && tree_init(fs, &t) && end_op(fs)
		s := Snap{root = t.root, height = 1, gen = t.memgen, nlbl = 1}
		ok = ok && snap_set(v, b, s) && label_set(v, b, transmute([]u8)name[:n], s.gen, {.Mutable})
	}
	ok = ok && snap_flush(v, b)
	batch_free(v, b)
	if !ok {
		return fs.err != .Ok ? fs.err : .Err_Invalid
	}
	return commit(v)
}

// The arena a superblock's table describes: its header, or its footer if the
// header does not match (a commit torn while writing headers).
@(private = "file", require_results)
mount_arena :: proc "contextless" (v: ^Vol, i: int, ent: []u8) -> bool {
	fs := &v.fs
	e := load(Arena_Entry_Disk, ent)
	base, blocks, hash := Addr(e.base), u64(e.blocks), u64(e.hash)
	// Between the two superblocks, and clear of every other arena: a table
	// that says otherwise (a hostile image) would have blocks handed out twice.
	last := last_block(fs)
	if base % BLKSZ != 0 || base < BLKSZ || blocks == 0 || blocks > fs.dev.size / BLKSZ || base > last || (blocks + 2) * BLKSZ > u64(last - base) {
		return fail(fs, .Err_Invalid)
	}
	for &o in fs.arenas[:i] {
		if u64(base) < u64(o.base) + o.size + 2 * BLKSZ && u64(o.base) < u64(base) + (blocks + 2) * BLKSZ {
			return fail(fs, .Err_Invalid)
		}
	}
	footer := base + BLKSZ + Addr(blocks * BLKSZ)
	hb: ^Blk
	for at in ([2]Addr{base, footer}) {
		was := fs.err
		hb = get(fs, {addr = at, hash = hash}, {.Arena})
		if hb != nil {
			break
		}
		if was == .Ok {
			fs.err = .Ok // the other copy, then
		}
	}
	if hb == nil {
		return fail(fs, .Err_Invalid)
	}
	h := unpack_arena_hdr(data(hb))
	drop(fs, hb)
	cache_forget(fs, base)
	cache_forget(fs, footer)
	if h.base != base || h.blocks != blocks {
		return fail(fs, .Err_Invalid)
	}
	v.arenahash[i] = hash
	a := &fs.arenas[i]
	arena_load(fs, a, h) or_return
	a.reserve = arena_reserve(a.size)
	return true
}

// What unmount lets go of, the superblock buffers apart.
@(private = "file")
vol_release :: proc "contextless" (v: ^Vol) {
	fs := &v.fs
	for &a in fs.arenas {
		if a.logtl != nil {
			drop(fs, a.logtl)
		}
	}
	mem_release(fs, v.arenahash)
	mem_release(fs, v.hdr)
	vec_free(fs, &v.freedchain)
	close(fs)
	v.sb, v.snap, v.nextgen, v.nextqid, v.nextdl = {}, {}, 0, 0, 0
	v.arenahash, v.hdr, v.br = nil, nil, {}
}

unmount :: proc "contextless" (v: ^Vol) {
	vol_release(v)
	v^ = {}
}

// The volume as one superblock describes it: its arenas loaded.
@(private = "file", require_results)
mount_from :: proc "contextless" (v: ^Vol, sbuf: []u8, sb: Sb) -> vx.Status {
	fs := &v.fs
	v.sb = sb
	if v.sb.snapht < 1 || v.sb.snapht > MAXHEIGHT {
		return vol_bad(v)
	}
	if !vol_alloc(v, v.sb.narenas) {
		return fs.err
	}
	for i in 0 ..< int(v.sb.narenas) {
		if !mount_arena(v, i, sbuf[SBHDSZ + size_of(Arena_Entry_Disk) * i:]) {
			return fs.err != .Ok ? fs.err : .Err_Invalid
		}
	}
	return .Ok
}

// After a crash the copies may differ: the backup superblock a commit behind,
// or a footer (or header) the old one. Each is made the mounted one's again,
// and durable, before anything is allocated, so that a cut in the next commit
// still finds a whole copy that names what is on the disk.
@(private = "file", require_results)
mount_repair :: proc "contextless" (v: ^Vol, good_sb: ^[BLKSZ]u8, other_sb: Addr, other_same: bool) -> bool {
	fs := &v.fs
	wrote := false
	for &a, i in fs.arenas {
		at := [2]Addr{a.base, a.base + BLKSZ + Addr(a.size)}
		same: [2]bool
		for c in 0 ..< 2 {
			same[c] = fs.dev.read(fs.dev.ctx, at[c], &v.repair[c]) == .Ok && xxh64(v.repair[c][:], 0) == v.arenahash[i]
			fs.reads += 1
		}
		for c in 0 ..< 2 {
			if !same[c] && same[1 - c] { // the copy that matches, over the one that does not
				if fs.dev.write(fs.dev.ctx, at[c], &v.repair[1 - c]) != .Ok {
					return fail(fs, .Err_Io)
				}
				fs.writes += 1
				wrote = true
			}
		}
	}
	if wrote && fs.dev.barrier(fs.dev.ctx) != .Ok {
		return fail(fs, .Err_Io)
	}
	if other_same {
		return true
	}
	fs.writes += 1
	return (fs.dev.write(fs.dev.ctx, other_sb, good_sb) == .Ok && fs.dev.barrier(fs.dev.ctx) == .Ok) || fail(fs, .Err_Io)
}

// Mounts the volume on the device: the newer of its two good superblocks, or
// the older if the newer's arenas will not load; the other copies made its
// again; and the frees of the commit it describes done again.
@(private = "file", require_results)
mount_volume :: proc "contextless" (v: ^Vol, dev: Dev, mem: Mem, cache: u32) -> vx.Status {
	v^ = {}
	fs := &v.fs
	if dev.size < 10 * BLKSZ {
		return .Err_Invalid
	}
	if !open(fs, dev, mem, cache) {
		return fs.err
	}
	sb: [2]Sb
	good: [2]bool
	at := [2]Addr{0, Addr((dev.size / BLKSZ - 1) * BLKSZ)}
	for i in 0 ..< 2 {
		good[i] = dev.read(dev.ctx, at[i], &v.sbuf[i]) == .Ok
		if good[i] {
			sb[i], good[i] = unpack_sb(v.sbuf[i][:])
		}
		fs.reads += 1
	}
	if !good[0] && !good[1] {
		return vol_bad(v)
	}
	first := (!good[0] || (good[1] && sb[1].commit > sb[0].commit)) ? 1 : 0
	use := -1
	st := vx.Status.Err_Invalid
	for c in 0 ..< 2 {
		try := c == 0 ? first : 1 - first
		if !good[try] {
			continue
		}
		if c == 1 { // the newer would not do: everything it loaded let go, and the older tried
			vol_release(v)
			if !open(fs, dev, mem, cache) {
				return fs.err
			}
		}
		if st = mount_from(v, v.sbuf[try][:], sb[try]); st == .Ok {
			use = try
			break
		}
	}
	if use < 0 {
		return st
	}
	same := good[1 - use] && bytes_equal(v.sbuf[0][:], v.sbuf[1][:])
	if !mount_repair(v, &v.sbuf[use], at[1 - use], same) {
		return fs.err
	}
	v.nextgen, v.nextqid, v.nextdl = v.sb.nextgen, v.sb.nextqid, v.sb.nextdl
	v.snap = {root = v.sb.snaproot, height = v.sb.snapht, memgen = v.nextgen, snap = true}
	v.nextgen += 1
	// What the commit freed: free now (those frees, logged after it, were not
	// replayed); its chain, which the superblock names, at the next commit.
	if v.sb.freed != 0 {
		if !chain_each(v, v.sb.freed, free_one, nil, true, false) || !chain_each(v, v.sb.freed, defer_one, nil, false, true) {
			return fs.err != .Ok ? fs.err : .Err_Invalid
		}
		// Deferred: kept as the chain to free at the next commit.
		for addr in items(&fs.deferred) {
			if !vec_push(fs, &v.freedchain, addr) {
				return fs.err
			}
		}
		fs.deferred.n = 0
	}
	return .Ok
}

// mount_volume, and on a failure everything it took let go (found by
// upstream's M6 step 6d10 mount_fuzz: callers, fsd and host/vxfs among them,
// give up on a volume that will not mount, and leaked what the attempt
// allocated). A volume that failed to mount is left zero; unmounting it
// again is harmless.
@(require_results)
mount :: proc "contextless" (v: ^Vol, dev: Dev, mem: Mem, cache: u32) -> vx.Status {
	st := mount_volume(v, dev, mem, cache)
	if st != .Ok {
		unmount(v)
	}
	return st
}
