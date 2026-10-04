package fs

import vx "abi:vx"

// Blocks (upstream docs/11 §3, §6): the block cache, reading and checking
// blocks, arenas and their allocation logs, after gefs's blk.c.
//
// Every block but the logs is reached through a block pointer whose hash is
// that of the block's whole contents: a read that does not match is INVALID,
// and the volume is read-only from then on. A block's structure is checked
// too (every offset and length inside the block, keys in order), so a damaged
// or hostile disk makes errors, never faults.
//
// Space comes from arenas. Each keeps its free space as sorted ranges in
// memory, and an append-only log of allocations and frees on the disk,
// replayed at load. The log is the one structure written in place, so it
// carries a hash of its own; and its last block is rewritten as it grows, so
// a commit records in the arena's header how much of that block it covers and
// that prefix's hash. A replay reads exactly that much: what was logged after
// the commit is not durable, and a write torn after it cannot touch what came
// before, which only grows.
//
// Freeing depends on the tree a block left (fs.gen, base and snaptree, set by
// the tree being changed). A block born in the generation being built (since
// the last commit) is freed when the current operation ends, the epoch gefs's
// readers need (single-threaded here). One born earlier is still reachable
// from the last commit: a branch's is killed, kept on fs.dead for the
// commit's deadlists, unless it was born before the branch's base, when the
// branch it came from frees it; the snapshot tree's is deferred, freed once
// the next commit is durable (fs.deferred).

Blk_Flag :: enum u8 {
	Dirty, // changed since it was written: never evicted
	Cached, // on the cache's hash chain
	Lru, // on the LRU list, held by nobody
}
Blk_Flags :: bit_set[Blk_Flag; u8]

// A block of the cache, and what its header says. Blocks are reached by
// pointer and never copied (the lists link them).
Blk :: struct {
	hnext:  ^Blk, // the cache's hash chain
	lprev:  ^Blk, // the LRU list, while unreferenced
	lnext:  ^Blk,
	type:   Block_Type,
	nval:   u16, // tree blocks
	valsz:  u16,
	nbuf:   u16,
	bufsz:  u16,
	logsz:  u16, // logs and deadlists
	logp:   Bptr, // logs and deadlists: the next block in the chain
	bp:     Bptr,
	ref:    u32,
	flags:  Blk_Flags,
	buf:    [BLKSZ]u8,
}

// Where each type's data starts, past its header.
@(rodata)
HEADER_SIZE := [Block_Type]int {
	.Dat   = 0,
	.Pivot = PIVHDSZ,
	.Leaf  = LEAFHDSZ,
	.Log   = LOGHDSZ,
	.Dlist = LOGHDSZ,
	.Arena = 2,
}

// The block's data, past its header.
data :: #force_inline proc "contextless" (b: ^Blk) -> []u8 {
	return b.buf[HEADER_SIZE[b.type]:]
}

// A pivot's children (keys, pointers and fills), and its message buffer.
pivot_kids :: #force_inline proc "contextless" (b: ^Blk) -> []u8 {
	return b.buf[PIVHDSZ:][:PIVSPC]
}

pivot_msgs :: #force_inline proc "contextless" (b: ^Blk) -> []u8 {
	return b.buf[PIVHDSZ + PIVSPC:][:BUFSPC]
}

// A tree block's values: a leaf's, or a pivot's children.
vals :: #force_inline proc "contextless" (b: ^Blk) -> []u8 {
	return b.type == .Pivot ? pivot_kids(b) : b.buf[LEAFHDSZ:][:LEAFSPC]
}

Range :: struct {
	off: Addr,
	len: u64,
}

// An arena: a header block at base, its data blocks after it, and a footer
// after them, the header's copy.
Arena :: struct {
	base:     Addr,
	size:     u64, // bytes of data blocks, from base + BLKSZ
	used:     u64,
	reserve:  u64,
	free:     Vec(Range), // sorted, disjoint, never adjacent
	loghd:    Bptr, // the log's first block
	logtl:    ^Blk, // its last, held, open for appending
	nlog:     u64, // its blocks
	lastlog:  u64, // its blocks after the last compression
	retired:  []Addr, // a compressed log's old chain, not yet reusable
}

// A block killed: born in generation `birth`, unreachable from the tree being
// built in `death` (a snapshot id, once committed).
Dead :: struct {
	addr:  Addr,
	birth: Gen,
	death: Gen,
}

// The library's state over a device. Its zero value is closed. Not to be
// copied once open: its cache and arenas point at each other.
Fs :: struct {
	dev:         Dev,
	mem:         Mem,
	err:         vx.Status, // sticky: the first error, after which nothing more is written
	blocks:      []Blk,
	hash:        []^Blk, // a power of two
	lru_old:     ^Blk, // the unreferenced blocks, least recently used first
	lru_new:     ^Blk,
	arenas:      []Arena,
	rr:          u32, // the round robin over arenas (11 §6)
	rr_writes:   u32,
	gen:         Gen, // the generation blocks are born in now: the changed tree's
	base:        Gen, // that tree's branch's base: blocks born at or before it are another's to free
	snaptree:    bool, // the tree is the snapshot tree
	use_reserve: bool, // the commit may take the arenas' reserves
	freeing:     bool, // the operation frees: it may take half of them (arena_keep)
	compress_at: u64, // a log this long, and twice what it was compressed to, is compressed at a commit
	limbo:       Vec(Bptr),
	dead:        Vec(Dead),
	deferred:    Vec(Addr), // freed once the next commit is durable
	reads:       u64, // blocks, for tests and status
	writes:      u64,
}

// An arena's allocation log entry: an address with the op in its low byte,
// and a length after it for the ranged ops.
Log_Op :: enum u8 {
	Nop,
	Alloc1,
	Free1,
	Alloc,
	Free,
}

// The least cache a volume is opened with: a whole path, its splits and
// siblings, held at once; and what stays held while it is mounted, each
// arena's log tail (64 arenas, as format makes at most) and a few chains'
// tails (M5 step 10: these were not counted).
MINCACHE :: 4 * MAXHEIGHT + 64 + 8

// --- The cache ---

@(private = "file")
cache_slot :: proc "contextless" (fs: ^Fs, addr: Addr) -> int {
	return int(u32((u64(addr) / BLKSZ * 0x9E3779B97F4A7C15) >> 32) & u32(len(fs.hash) - 1))
}

@(private = "file")
lru_unlink :: proc "contextless" (fs: ^Fs, b: ^Blk) {
	if .Lru not_in b.flags {
		return
	}
	if b.lprev != nil {
		b.lprev.lnext = b.lnext
	} else {
		fs.lru_old = b.lnext
	}
	if b.lnext != nil {
		b.lnext.lprev = b.lprev
	} else {
		fs.lru_new = b.lprev
	}
	b.lprev, b.lnext = nil, nil
	b.flags -= {.Lru}
}

// To the most recently used end.
@(private = "file")
lru_push :: proc "contextless" (fs: ^Fs, b: ^Blk) {
	b.lprev = fs.lru_new
	b.lnext = nil
	if fs.lru_new != nil {
		fs.lru_new.lnext = b
	} else {
		fs.lru_old = b
	}
	fs.lru_new = b
	b.flags += {.Lru}
}

cache_find :: proc "contextless" (fs: ^Fs, addr: Addr) -> ^Blk {
	for b := fs.hash[cache_slot(fs, addr)]; b != nil; b = b.hnext {
		if b.bp.addr == addr {
			return b
		}
	}
	return nil
}

@(private = "file")
cache_del :: proc "contextless" (fs: ^Fs, b: ^Blk) {
	if .Cached not_in b.flags {
		return
	}
	for link := &fs.hash[cache_slot(fs, b.bp.addr)]; link^ != nil; link = &link^.hnext {
		if link^ == b {
			link^ = b.hnext
			break
		}
	}
	b.hnext = nil
	b.flags -= {.Cached}
}

@(private = "file")
cache_put :: proc "contextless" (fs: ^Fs, b: ^Blk) {
	s := cache_slot(fs, b.bp.addr)
	b.hnext = fs.hash[s]
	fs.hash[s] = b
	b.flags += {.Cached}
}

// A block of the cache's for a new use, held: the least recently used one
// that nothing holds and that has been written (a dirty block is not evicted,
// whoever dropped it). nil (NO_MEMORY) if there is none.
@(private = "file")
cache_take :: proc "contextless" (fs: ^Fs) -> ^Blk {
	b := fs.lru_old
	for b != nil && (.Dirty in b.flags) {
		b = b.lnext
	}
	if b == nil {
		fail(fs, .Err_No_Memory)
		return nil
	}
	lru_unlink(fs, b)
	cache_del(fs, b)
	b.ref = 1
	b.flags = {}
	return b
}

hold :: proc "contextless" (fs: ^Fs, b: ^Blk) -> ^Blk {
	if b.ref == 0 {
		lru_unlink(fs, b)
	}
	b.ref += 1
	return b
}

drop :: proc "contextless" (fs: ^Fs, b: ^Blk) {
	if b == nil {
		return
	}
	b.ref -= 1
	if b.ref == 0 {
		lru_push(fs, b)
	}
}

// Drops a block from the cache altogether (its address freed for reuse).
cache_forget :: proc "contextless" (fs: ^Fs, addr: Addr) {
	if b := cache_find(fs, addr); b != nil {
		cache_del(fs, b)
	}
}

// A block read but refused, given back unreferenced.
@(private = "file")
cache_return :: proc "contextless" (fs: ^Fs, b: ^Blk) {
	b.ref = 0
	lru_push(fs, b)
}

// --- Checking a block read from the disk ---

// The entries of a table d (its length the table's space): n offsets of 2
// bytes, each to an entry inside [2n, len(d)): an op (if `msgs`), a key and a
// value, whose sizes add up to `size`. Keys in order: strictly for values,
// and messages may repeat a key. A pivot's values are each a block pointer
// and a fill.
@(require_results)
check_table :: proc "contextless" (d: []u8, n, size: u16, msgs, pivot: bool) -> bool {
	spc := u32(len(d))
	lo, total := 2 * u32(n), u32(0)
	if lo + u32(size) > spc {
		return false
	}
	prev: []u8
	for i in 0 ..< u32(n) {
		o := u32(get16(d[2 * i:]))
		at := o
		if o < lo || o >= spc {
			return false
		}
		if msgs {
			op := d[at]
			at += 1
			if op == u8(Op.Nop) || op >= NMSG {
				return false
			}
		}
		if at + 2 > spc {
			return false
		}
		nk := u32(get16(d[at:]))
		at += 2
		if nk == 0 || nk > KEYMAX || at + nk + 2 > spc {
			return false
		}
		k := d[at:][:nk]
		at += nk
		nv := u32(get16(d[at:]))
		at += 2
		if nv > INLMAX || at + nv > spc {
			return false
		}
		if pivot && !msgs && nv != PTRSZ + 2 {
			return false
		}
		c := i > 0 ? keycmp(prev, k) : -1
		if c > 0 || (c == 0 && !msgs) {
			return false // values strictly in order; messages may repeat a key
		}
		prev = k
		total += (msgs ? 1 : 0) + 2 + nk + 2 + nv
	}
	return total == u32(size)
}

// A log or deadlist block's own hash: its entries, seeded with the rest of
// its header (type, size and the chain's next pointer), so a damaged header
// is found as a damaged entry is (M5 step 10: the header was left out).
log_hash :: proc "contextless" (buf: []u8, logsz: u16) -> u64 {
	seed := xxh64(buf[:4], 0) ~ xxh64(buf[12:][:PTRSZ], 1)
	return xxh64(buf[LOGHDSZ:][:logsz], seed)
}

CHAINED :: Block_Types{.Log, .Dlist} // blocks a chain links, carrying their own hash

// Reads the header the block's type has, and checks what it says. False if
// the block is not one of the types `want` names, or is malformed.
@(require_results)
parse_block :: proc "contextless" (b: ^Blk, want: Block_Types) -> bool {
	b.nval, b.valsz, b.nbuf, b.bufsz, b.logsz = 0, 0, 0, 0, 0
	b.logp = {}
	if want == {.Dat} {
		b.type = .Dat
		return true
	}
	raw := get16(b.buf[:])
	if raw > u16(max(Block_Type)) {
		return false
	}
	b.type = Block_Type(raw)
	if b.type not_in want {
		return false
	}
	switch b.type {
	case .Pivot:
		h := load(Pivot_Hdr, b.buf[:])
		b.nval, b.valsz, b.nbuf, b.bufsz = u16(h.nval), u16(h.valsz), u16(h.nbuf), u16(h.bufsz)
		return b.nval >= 1 && check_table(pivot_kids(b), b.nval, b.valsz, false, true) && check_table(pivot_msgs(b), b.nbuf, b.bufsz, true, true)
	case .Leaf:
		h := load(Leaf_Hdr, b.buf[:])
		b.nval, b.valsz = u16(h.nval), u16(h.valsz)
		return check_table(vals(b), b.nval, b.valsz, false, false)
	case .Log, .Dlist:
		h := load(Log_Hdr, b.buf[:])
		b.logsz = u16(h.logsz)
		b.logp = bptr_of(h.chain)
		return b.logsz <= LOGSPC && b.logsz % 8 == 0 && u64(h.loghash) == log_hash(b.buf[:], b.logsz)
	case .Arena:
		return true
	case .Dat:
		return false
	}
	return false
}

// Whether addr names a whole block inside the device.
@(private)
on_device :: proc "contextless" (fs: ^Fs, addr: Addr) -> bool {
	return addr % BLKSZ == 0 && u64(addr) < fs.dev.size && fs.dev.size - u64(addr) >= BLKSZ
}

// The block bp points at, of one of the types `want` names, held; nil on
// failure (the volume's error says why). Its hash is checked unless it is a
// log or a deadlist, which carry their own (pointers to them have none).
get :: proc "contextless" (fs: ^Fs, bp: Bptr, want: Block_Types) -> ^Blk {
	if !on_device(fs, bp.addr) {
		fail(fs, .Err_Invalid)
		return nil
	}
	chained := want <= CHAINED
	if b := cache_find(fs, bp.addr); b != nil {
		if b.type not_in want || (!chained && b.bp.hash != bp.hash) {
			fail(fs, .Err_Invalid)
			return nil
		}
		return hold(fs, b)
	}
	b := cache_take(fs)
	if b == nil {
		return nil
	}
	fs.reads += 1
	st := fs.dev.read(fs.dev.ctx, bp.addr, &b.buf)
	ok := st == .Ok && (chained || xxh64(b.buf[:], 0) == bp.hash)
	if ok {
		ok = parse_block(b, want)
	}
	if !ok {
		fail(fs, st != .Ok ? st : .Err_Invalid)
		cache_return(fs, b)
		return nil
	}
	b.bp = bp
	cache_put(fs, b)
	return b
}

// A new block of `type` at addr, held, empty.
new_block_at :: proc "contextless" (fs: ^Fs, addr: Addr, type: Block_Type) -> ^Blk {
	b := cache_take(fs)
	if b == nil {
		return nil
	}
	b.type = type
	b.bp = {addr = addr, gen = fs.gen}
	b.nval, b.valsz, b.nbuf, b.bufsz, b.logsz = 0, 0, 0, 0, 0
	b.logp = {}
	b.buf = {}
	b.flags += {.Dirty}
	cache_put(fs, b)
	return b
}

// Writes the header and the hash: the block is final, and its pointer whole.
finalize :: proc "contextless" (b: ^Blk) {
	switch b.type {
	case .Dat:
	case .Pivot:
		store(b.buf[:], Pivot_Hdr{type = u16le(b.type), nval = u16le(b.nval), valsz = u16le(b.valsz), nbuf = u16le(b.nbuf), bufsz = u16le(b.bufsz)})
	case .Leaf:
		store(b.buf[:], Leaf_Hdr{type = u16le(b.type), nval = u16le(b.nval), valsz = u16le(b.valsz)})
	case .Log, .Dlist:
		put16(b.buf[:], u16(b.type))
		put16(b.buf[2:], b.logsz)
		pack_bptr(b.buf[12:], b.logp)
		put64(b.buf[4:], log_hash(b.buf[:], b.logsz))
	case .Arena:
		put16(b.buf[:], u16(b.type))
	}
	b.bp.hash = xxh64(b.buf[:], 0)
}

// Finalizes the block and writes it. A tree or data block is never changed
// after this; a log's last block is, and is written again.
@(require_results)
write_block :: proc "contextless" (fs: ^Fs, b: ^Blk) -> bool {
	if fs.err != .Ok {
		return false
	}
	finalize(b)
	fs.writes += 1
	if st := fs.dev.write(fs.dev.ctx, b.bp.addr, &b.buf); st != .Ok {
		// The volume has failed, and says so to every caller from now on; the
		// block is let go of rather than kept dirty, which nothing could evict
		// (M5 step 10).
		b.flags -= {.Dirty}
		cache_del(fs, b)
		return fail(fs, st)
	}
	b.flags -= {.Dirty}
	fs.rr_writes += 1
	if fs.rr_writes == 4096 { // every few thousand writes, the next arena
		fs.rr += 1
		fs.rr_writes = 0
	}
	return true
}

// --- Free space: sorted ranges ---

// The index of the range holding off, or of the first after it.
range_at :: proc "contextless" (a: ^Arena, off: Addr) -> int {
	free := items(&a.free)
	lo, hi := 0, len(free)
	for lo < hi {
		mid := (lo + hi) / 2
		if u64(free[mid].off) + free[mid].len <= u64(off) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

range_has :: proc "contextless" (a: ^Arena, addr: Addr) -> bool {
	i := range_at(a, addr)
	return i < a.free.n && a.free.buf[i].off <= addr
}

// [off, off + n) becomes free. False (INVALID) if any of it already was.
@(require_results)
range_free :: proc "contextless" (fs: ^Fs, a: ^Arena, off: Addr, n: u64) -> bool {
	i := range_at(a, off)
	free := items(&a.free)
	end := u64(off) + n
	if i < a.free.n && u64(free[i].off) < end {
		return fail(fs, .Err_Invalid) // freed twice
	}
	before := i > 0 && u64(free[i - 1].off) + free[i - 1].len == u64(off)
	after := i < a.free.n && u64(free[i].off) == end
	switch {
	case before && after:
		free[i - 1].len += n + free[i].len
		vec_remove(&a.free, i)
	case before:
		free[i - 1].len += n
	case after:
		free[i].off = off
		free[i].len += n
	case:
		vec_insert(fs, &a.free, i, Range{off, n}) or_return
	}
	return true
}

// [off, off + n) is taken. False (INVALID) if it was not all free.
@(require_results)
range_grab :: proc "contextless" (fs: ^Fs, a: ^Arena, off: Addr, n: u64) -> bool {
	i := range_at(a, off)
	if i == a.free.n || a.free.buf[i].off > off || n > u64(a.free.buf[i].off) + a.free.buf[i].len - u64(off) {
		return fail(fs, .Err_Invalid)
	}
	r := a.free.buf[i]
	end := u64(r.off) + r.len
	switch {
	case off == r.off && n == r.len:
		vec_remove(&a.free, i)
	case off == r.off:
		a.free.buf[i] = {r.off + Addr(n), r.len - n}
	case u64(off) + n == end:
		a.free.buf[i].len -= n
	case: // the middle: two pieces
		vec_insert(fs, &a.free, i + 1, Range{off + Addr(n), end - u64(off) - n}) or_return
		a.free.buf[i].len = u64(off - r.off)
	}
	return true
}

// What of an arena's reserve the current allocation may not take: all of it
// normally; half for an operation that frees (a full volume can still have
// files removed); none for the commit, or for the log itself, whose next
// block is what lets a free be recorded at all.
@(private = "file")
arena_keep :: proc "contextless" (fs: ^Fs, a: ^Arena, log: bool) -> u64 {
	if fs.use_reserve || log {
		return 0
	}
	return fs.freeing ? a.reserve / 2 : a.reserve
}

// One block from the arena's free space, unlogged: from its start
// (sequential, for logs being rewritten) or its end. 0 if there is no room.
arena_take :: proc "contextless" (fs: ^Fs, a: ^Arena, seq, log: bool) -> Addr {
	if a.free.n == 0 || a.size - a.used <= arena_keep(fs, a, log) {
		return 0
	}
	r := seq ? a.free.buf[0] : a.free.buf[a.free.n - 1]
	b := seq ? r.off : r.off + Addr(r.len) - BLKSZ
	_ = range_grab(fs, a, b, BLKSZ)
	a.used += BLKSZ
	return b
}

// --- The allocation log ---

// Whether addr is one of the arena's data blocks.
in_arena :: proc "contextless" (a: ^Arena, addr: Addr) -> bool {
	return addr % BLKSZ == 0 && addr >= a.base + BLKSZ && u64(addr) < u64(a.base) + BLKSZ + a.size
}

arena_of :: proc "contextless" (fs: ^Fs, addr: Addr) -> ^Arena {
	for &a in fs.arenas {
		if addr >= a.base + BLKSZ && u64(addr) < u64(a.base) + BLKSZ + a.size {
			return &a
		}
	}
	return nil
}

// Appends an entry: an allocation or a free of [off, off + n). A full block
// chains to a new one, taken from the arena and logged in the old one first.
@(require_results)
log_append :: proc "contextless" (fs: ^Fs, a: ^Arena, off: Addr, n: u64, op: Log_Op) -> bool {
	lb := a.logtl
	if lb.logsz >= LOGSPC - LOGSLOP {
		o := arena_take(fs, a, false, true)
		if o == 0 {
			return fail(fs, .Err_No_Space)
		}
		put64(data(lb)[lb.logsz:], u64(o) | u64(Log_Op.Alloc1))
		lb.logsz += 8
		lb.logp = {addr = o}
		next := new_block_at(fs, o, .Log)
		if next == nil || !write_block(fs, next) || !write_block(fs, lb) {
			return false
		}
		drop(fs, lb)
		a.logtl = next
		lb = next
		a.nlog += 1
	}
	op := op
	if op == .Alloc && n == BLKSZ {
		op = .Alloc1
	}
	if op == .Free && n == BLKSZ {
		op = .Free1
	}
	put64(data(lb)[lb.logsz:], u64(off) | u64(op))
	lb.logsz += 8
	if op == .Alloc || op == .Free {
		put64(data(lb)[lb.logsz:], n)
		lb.logsz += 8
	}
	lb.flags += {.Dirty}
	return true
}

// Writes the log's open block, if it has changed.
@(require_results)
log_flush :: proc "contextless" (fs: ^Fs, a: ^Arena) -> bool {
	if .Dirty not_in a.logtl.flags {
		return true
	}
	return write_block(fs, a.logtl)
}

// A new arena over [base, base + BLKSZ * (blocks + 2)): all of its data blocks
// free, but the first, its log, which says so.
@(require_results)
arena_init :: proc "contextless" (fs: ^Fs, a: ^Arena, base: Addr, blocks: u64) -> bool {
	a^ = {base = base, size = blocks * BLKSZ}
	range_free(fs, a, base + BLKSZ, a.size) or_return
	first := arena_take(fs, a, true, true)
	if first == 0 {
		return fail(fs, .Err_No_Memory)
	}
	a.logtl = new_block_at(fs, first, .Log)
	if a.logtl == nil {
		return false
	}
	a.loghd = {addr = first}
	a.nlog = 1
	// Replayed from nothing: all of it free, then the log's block taken.
	return log_append(fs, a, base + BLKSZ, a.size, .Free) && log_append(fs, a, first, BLKSZ, .Alloc) && log_flush(fs, a)
}

// After a replay: every block of the log's chain is one the log says is
// taken. A log that freed its own would have them handed out, and written over.
@(private = "file", require_results)
log_owned :: proc "contextless" (fs: ^Fs, a: ^Arena) -> bool {
	bp := a.loghd
	for i in 0 ..< a.nlog {
		if !in_arena(a, bp.addr) || range_has(a, bp.addr) {
			return fail(fs, .Err_Invalid)
		}
		if i + 1 == a.nlog {
			break
		}
		b := get(fs, bp, {.Log})
		if b == nil {
			return false
		}
		bp = b.logp
		drop(fs, b)
	}
	return true
}

// Writes the log's open block and says what a header would: the log as it
// stands, all of it covered.
@(require_results)
arena_seal :: proc "contextless" (fs: ^Fs, a: ^Arena) -> (h: Arena_Hdr, ok: bool) {
	log_flush(fs, a) or_return
	tl := a.logtl
	h = {
		base     = a.base,
		blocks   = a.size / BLKSZ,
		loghd    = a.loghd.addr,
		logtl    = tl.bp.addr,
		tailsz   = tl.logsz,
		tailhash = xxh64(data(tl)[:tl.logsz], 0),
	}
	return h, true
}

// Replays one block's entries, d.
@(private = "file", require_results)
log_replay :: proc "contextless" (fs: ^Fs, a: ^Arena, d: []u8) -> bool {
	lo := u64(a.base) + BLKSZ
	hi := lo + a.size
	for i := 0; i < len(d); {
		if i + 8 > len(d) {
			return fail(fs, .Err_Invalid)
		}
		ent := get64(d[i:])
		at := ent &~ 0xff
		op := u8(ent)
		w := op >= u8(Log_Op.Alloc) ? 16 : 8
		if i + w > len(d) {
			return fail(fs, .Err_Invalid)
		}
		length := op >= u8(Log_Op.Alloc) ? get64(d[i + 8:]) : BLKSZ
		ok := length != 0 && length % BLKSZ == 0 && at % BLKSZ == 0
		switch op {
		case u8(Log_Op.Alloc), u8(Log_Op.Alloc1):
			ok = ok && range_grab(fs, a, Addr(at), length)
			a.used += length
		case u8(Log_Op.Free), u8(Log_Op.Free1):
			ok = ok && at >= lo && at <= hi && length <= hi - at && range_free(fs, a, Addr(at), length)
			a.used -= length
		case:
			ok = false
		}
		if !ok {
			return fail(fs, .Err_Invalid)
		}
		i += w
	}
	return true
}

// The log's last block, as far as the header covers it: read whole, its own
// hash not checked (a write after the commit may have torn it), the covered
// prefix checked against the header's hash, and the rest cleared.
@(private = "file")
log_tail :: proc "contextless" (fs: ^Fs, h: Arena_Hdr) -> ^Blk {
	if !on_device(fs, h.logtl) || h.tailsz > LOGSPC || h.tailsz % 8 != 0 {
		fail(fs, .Err_Invalid)
		return nil
	}
	cache_forget(fs, h.logtl)
	b := cache_take(fs)
	if b == nil {
		return nil
	}
	fs.reads += 1
	st := fs.dev.read(fs.dev.ctx, h.logtl, &b.buf)
	if st != .Ok || xxh64(b.buf[LOGHDSZ:][:h.tailsz], 0) != h.tailhash {
		fail(fs, st != .Ok ? st : .Err_Invalid)
		cache_return(fs, b)
		return nil
	}
	b.type = .Log
	b.logsz = h.tailsz
	b.logp = {}
	b.bp = {addr = h.logtl}
	for &c in b.buf[LOGHDSZ + int(h.tailsz):] {
		c = 0
	}
	cache_put(fs, b)
	return b
}

// Loads an arena's free space by replaying its log, as its header says: whole
// blocks from loghd, each checked by its own hash, then the covered prefix of
// logtl, which is left open for appending.
@(require_results)
arena_load :: proc "contextless" (fs: ^Fs, a: ^Arena, h: Arena_Hdr) -> bool {
	a^ = {base = h.base, loghd = {addr = h.loghd}}
	if h.blocks > fs.dev.size / BLKSZ || u64(h.base) > max(u64) - (h.blocks + 2) * BLKSZ {
		return fail(fs, .Err_Invalid) // an arena larger than the device, or one past the end of addresses
	}
	a.size = h.blocks * BLKSZ
	a.used = a.size
	if !in_arena(a, h.logtl) {
		return fail(fs, .Err_Invalid)
	}
	bp := a.loghd
	for chain := u64(0); ; chain += 1 {
		if chain > h.blocks || !in_arena(a, bp.addr) {
			return fail(fs, .Err_Invalid) // a loop, the tail never reached, or a log outside its arena
		}
		last := bp.addr == h.logtl
		b := last ? log_tail(fs, h) : get(fs, bp, {.Log})
		if b == nil {
			return false
		}
		a.nlog += 1
		if !log_replay(fs, a, data(b)[:b.logsz]) {
			drop(fs, b)
			return false
		}
		if last {
			a.logtl = b
			return log_owned(fs, a)
		}
		bp = b.logp
		drop(fs, b)
	}
}

// Rewrites the log as the free ranges alone, in new blocks: a long log is
// short again. The old chain's blocks are still taken, in memory and in the
// new log: they are kept (a.retired, deferred by log_retire at the next
// commit) until the commit that points the arena at the new log is durable,
// since a crash before then replays the old one, which must still be on the
// disk. Then they are freed, as anything a commit frees is.
@(require_results)
log_compress :: proc "contextless" (fs: ^Fs, a: ^Arena) -> bool {
	if len(a.retired) != 0 {
		return fail(fs, .Err_Bad_State) // the last compression's commit has not landed
	}
	log_flush(fs, a) or_return
	// Enough blocks for every range at 16 bytes each, taken from the front and
	// unlogged: the old log, which a crash replays, has them free.
	per := (LOGSPC - LOGSLOP) / 16
	need := a.free.n / per + 2
	got := 0
	nold := int(a.nlog)
	blks, ok := mem_new(Addr, fs, need)
	old: []Addr
	if ok {
		old, ok = mem_new(Addr, fs, nold)
	}
	for ; ok && got < need; got += 1 {
		blks[got] = arena_take(fs, a, true, true)
		if blks[got] == 0 {
			// Upstream counts this slot as taken and later frees address 0
			// into the arena's ranges; the volume has failed by then either
			// way, but its free space is left as it was here.
			ok = fail(fs, .Err_No_Memory)
			break
		}
	}
	bp := a.loghd
	for i := 0; ok && i < nold; i += 1 { // the old chain
		old[i] = bp.addr
		b := i + 1 == nold ? hold(fs, a.logtl) : get(fs, bp, {.Log})
		if b == nil {
			ok = false
		} else {
			bp = b.logp
			drop(fs, b)
		}
	}
	used := 0
	b: ^Blk
	if ok {
		b = new_block_at(fs, blks[used], .Log)
		used += 1
	}
	ok = b != nil
	for r := 0; ok && r < a.free.n; r += 1 {
		if b.logsz >= LOGSPC - LOGSLOP {
			b.logp = {addr = blks[used]}
			next := new_block_at(fs, blks[used], .Log)
			used += 1
			ok = next != nil && write_block(fs, b)
			drop(fs, b)
			b = next
		}
		if ok {
			put64(data(b)[b.logsz:], u64(a.free.buf[r].off) | u64(Log_Op.Free))
			put64(data(b)[b.logsz + 8:], a.free.buf[r].len)
			b.logsz += 16
		}
	}
	if ok {
		drop(fs, a.logtl)
		a.loghd = {addr = blks[0]}
		a.logtl = b
		a.nlog, a.lastlog = u64(used), u64(used)
		b.flags += {.Dirty}
		a.retired = old
		old = nil
	} else {
		drop(fs, b)
	}
	// The blocks taken and not used (all of them, if it failed): never written,
	// so free at once, and logged so in the new log. The free is logged before
	// the block is free in memory: logging can take a block for the log, which
	// must not be this one (M5 step 10).
	for i := ok ? used : 0; i < got; i += 1 {
		cache_forget(fs, blks[i])
		if ok {
			ok = log_append(fs, a, blks[i], BLKSZ, .Free)
		}
		_ = range_free(fs, a, blks[i], BLKSZ)
		a.used -= BLKSZ
	}
	ok = ok && log_flush(fs, a)
	mem_release(fs, old)
	mem_release(fs, blks)
	return ok
}

// Defers a block: free once the next commit is durable.
@(require_results)
defer_free :: proc "contextless" (fs: ^Fs, addr: Addr) -> bool {
	return vec_push(fs, &fs.deferred, addr)
}

// At a commit: a compressed log's old chain is deferred.
@(require_results)
log_retire :: proc "contextless" (fs: ^Fs, a: ^Arena) -> bool {
	ok := true
	for addr in a.retired {
		if !ok {
			break
		}
		ok = defer_free(fs, addr)
	}
	mem_release(fs, a.retired)
	a.retired = nil
	return ok
}

// --- Allocating and freeing blocks ---

// A block's address from the arena the round robin picks for its type
// (11 §6), logged; 0 if every arena is full.
block_alloc :: proc "contextless" (fs: ^Fs, type: Block_Type) -> Addr {
	if fs.err != .Ok {
		return 0
	}
	n := u32(len(fs.arenas))
	for tries in 0 ..< n {
		a := &fs.arenas[(fs.rr + u32(type) + tries) % n]
		b := arena_take(fs, a, false, false)
		if b == 0 {
			continue
		}
		if !log_append(fs, a, b, BLKSZ, .Alloc) {
			return 0
		}
		return b
	}
	// Full, though room said there was room: what an operation takes is
	// undercounted somewhere, and what it did so far cannot be undone.
	fail(fs, .Err_No_Space)
	return 0
}

// Blocks an operation may take besides its data: one upsert's path copied and
// split all the way up, with the buffers flushed below it (gefs keeps a
// reserve the same way).
OPSLACK :: 2 * MAXHEIGHT

// Whether an operation needing `blocks` (and OPSLACK) may start: NO_SPACE,
// with nothing changed, if not. One that frees may count half of each arena's
// reserve, so a full volume can be emptied.
@(require_results)
room :: proc "contextless" (fs: ^Fs, blocks: u64, freeing: bool) -> vx.Status {
	if fs.err != .Ok {
		return fs.err
	}
	total: u64
	for &a in fs.arenas {
		keep := freeing ? a.reserve / 2 : a.reserve
		if a.size - a.used > keep {
			total += (a.size - a.used - keep) / BLKSZ
		}
	}
	return total >= blocks + OPSLACK ? .Ok : .Err_No_Space
}

// A new block of `type`, born in this generation, held.
new_block :: proc "contextless" (fs: ^Fs, type: Block_Type) -> ^Blk {
	addr := block_alloc(fs, type)
	return addr != 0 ? new_block_at(fs, addr, type) : nil
}

@(require_results)
block_dealloc :: proc "contextless" (fs: ^Fs, addr: Addr) -> bool {
	a := arena_of(fs, addr)
	if a == nil {
		return fail(fs, .Err_Invalid)
	}
	cache_forget(fs, addr)
	if !log_append(fs, a, addr, BLKSZ, .Free) || !range_free(fs, a, addr, BLKSZ) {
		return false
	}
	a.used -= BLKSZ
	return true
}

// A block the tree being changed no longer points at (see the top).
@(require_results)
free_block :: proc "contextless" (fs: ^Fs, bp: Bptr) -> bool {
	switch {
	case bp.gen >= fs.gen: // born since the last commit
		return vec_push(fs, &fs.limbo, bp)
	case fs.snaptree:
		return defer_free(fs, bp.addr)
	case bp.gen > fs.base:
		return vec_push(fs, &fs.dead, Dead{bp.addr, bp.gen, fs.gen})
	}
	return true
}

// After a commit is durable: what it deferred is free.
@(require_results)
free_deferred :: proc "contextless" (fs: ^Fs) -> bool {
	ok := fs.err == .Ok
	for addr in items(&fs.deferred) {
		if !ok {
			break
		}
		ok = block_dealloc(fs, addr)
	}
	fs.deferred.n = 0
	return ok
}

// The end of an operation: what it freed of this generation's is free. After
// an error nothing is: the tree that failed may still point there.
@(require_results)
end_op :: proc "contextless" (fs: ^Fs) -> bool {
	ok := fs.err == .Ok
	for bp in items(&fs.limbo) {
		if !ok {
			break
		}
		ok = block_dealloc(fs, bp.addr)
	}
	fs.limbo.n = 0
	return ok
}

// The library's state over a device, with a cache of `cache` blocks (at least
// MINCACHE) from mem. Close it with close, whatever this returns.
@(require_results)
open :: proc "contextless" (fs: ^Fs, dev: Dev, mem: Mem, cache: u32) -> bool {
	fs^ = {dev = dev, mem = mem, gen = 1, compress_at = 64}
	n := int(max(cache, MINCACHE))
	nhash := 1
	for nhash < n {
		nhash <<= 1
	}
	ok: bool
	fs.blocks, ok = mem_new(Blk, fs, n)
	if ok {
		fs.hash, ok = mem_new(^Blk, fs, nhash)
	}
	if !ok {
		return false
	}
	for &b in fs.blocks {
		lru_push(fs, &b)
	}
	return true
}

// Room for n arenas, each to be set up by arena_init or arena_load.
@(require_results)
alloc_arenas :: proc "contextless" (fs: ^Fs, n: u32) -> bool {
	// Each arena's log tail stays held: more arenas than the cache has room
	// for beside a path is refused here, not found as NO_MEMORY later.
	if int(n) > len(fs.blocks) - 4 * MAXHEIGHT - 8 {
		return fail(fs, .Err_No_Memory)
	}
	ok: bool
	fs.arenas, ok = mem_new(Arena, fs, int(n))
	return ok
}

close :: proc "contextless" (fs: ^Fs) {
	for &a in fs.arenas {
		vec_free(fs, &a.free)
		mem_release(fs, a.retired)
	}
	mem_release(fs, fs.arenas)
	vec_free(fs, &fs.limbo)
	vec_free(fs, &fs.dead)
	vec_free(fs, &fs.deferred)
	mem_release(fs, fs.hash)
	mem_release(fs, fs.blocks)
	fs^ = {}
}
