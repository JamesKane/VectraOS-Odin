// vx:fs, the system volume's file system (upstream docs/11, ADR-0025), after
// 9front's gefs (Ori Bernstein, MIT): copy-on-write Bε trees in fixed-size
// blocks. This file holds the format: block types and sizes, keys, messages,
// the directory entry, the superblock, and how each is laid out on the disk.
// The library is pure code over two callbacks (a device and memory), so it
// builds for the host's tests and tools as well as for fsd.
//
// The format is upstream's byte for byte: a volume either one writes, the
// other mounts (tests/host/fs's cross-format test). Integers in blocks are
// little-endian, as everything else in VectraOS; integers inside keys are
// big-endian, so keys compare as bytes and sort as their numbers do (a file's
// data in offset order, a directory's entries together).
//
// Every layout below is a #packed struct whose size an #assert pins down, read
// from a block by slicing first (so a short or hostile block is a bounds
// failure, never a stray read) and then loading it unaligned.
package fs

import "base:intrinsics"
import vx "abi:vx"

// --- Sizes (11 §3) ---

BLKSZ :: 16384
PTRSZ :: 24 // a block pointer: addr[8] hash[8] gen[8]
KEYMAX :: 256 // the longest key
INLMAX :: 512 // the longest value kept inline
KVMAX :: KEYMAX + INLMAX
KPMAX :: KEYMAX + PTRSZ + 2 // a pivot's key, pointer and fill
MSGMAX :: 1 + max(KVMAX, KPMAX)
MAXHEIGHT :: 32

// Block headers: type[2], then per type.
PIVHDSZ :: 2 + 2 + 2 + 2 + 2 // type nval valsz nbuf bufsz
LEAFHDSZ :: 2 + 2 + 2 // type nval valsz
LOGHDSZ :: 2 + 2 + 8 + PTRSZ // type logsz loghash chain

// A pivot's data: its key/pointer area (offsets from the front, entries from
// the back), then its message buffer, laid out the same way.
BUFSPC :: (BLKSZ - PIVHDSZ) / 2
PIVSPC :: BLKSZ - PIVHDSZ - BUFSPC
LEAFSPC :: BLKSZ - LEAFHDSZ
LOGSPC :: BLKSZ - LOGHDSZ
LOGSLOP :: 16 + 16 + 8 // an entry, a chaining allocation, and its pointer

// A block's kind, the first two bytes of every block but data.
Block_Type :: enum u16 {
	Dat   = 0, // file data: no header, the whole block
	Pivot = 1,
	Leaf  = 2,
	Log   = 3, // an arena's allocation log
	Dlist = 4, // a deadlist, or the chain of a commit's frees
	Arena = 5, // an arena's header or footer
}
Block_Types :: bit_set[Block_Type; u16]

// What get asks for when either kind of tree node will do.
TREE :: Block_Types{.Pivot, .Leaf}

// --- Keys and values (11 §4) ---

// A key's first byte.
Key_Kind :: enum u8 {
	Dat    = 0, // qid[8] off[8] -> a block pointer, or inline data
	Ent    = 1, // pqid[8] name[] -> the entry
	Up     = 2, // qid[8] -> the entry's own Kent key (or Korphan key)
	Label  = 3, // name[] -> snapid[8] flags[4] (snapshot tree)
	Snap   = 4, // snapid[8] -> a snapshot (snapshot tree)
	Dlist  = 5, // snap[8] birth[8] seq[8] -> head[8] count[8] (snapshot tree)
	Orphan = 6, // qid[8] -> the entry: removed while open (ours)
}

// Messages: changes addressed to a key, buffered in pivots on their way to
// the leaves (11 §3).
Op :: enum u8 {
	Nop     = 0,
	Insert  = 1, // the value, replacing any
	Delete  = 2, // the key, if it exists
	Clearb  = 3, // a Kdat key, if it exists, and its block freed
	Clobber = 4, // a key, if it exists
	Wstat   = 5, // an entry's fields, changed in place; its version bumped
}
NMSG :: 6

// Owstat's value: a byte of these flags, then each field it names, in this
// order (Wstat_Width gives their sizes).
Wstat_Field :: enum u8 {
	Size  = 0, // length[8]
	Mode  = 1, // mode[4]
	Mtime = 2, // mtime[8], ns
	Atime = 3, // atime[8], ns
	Uid   = 4, // uid[4]
	Gid   = 5, // gid[4]
	Muid  = 6, // muid[4]
	Ctime = 7, // ctime[8], ns
}
Wstat :: bit_set[Wstat_Field; u8]

@(rodata)
WSTAT_WIDTH := [Wstat_Field]u32 {
	.Size  = 8,
	.Mode  = 4,
	.Mtime = 8,
	.Atime = 8,
	.Uid   = 4,
	.Gid   = 4,
	.Muid  = 4,
	.Ctime = 8,
}

// A Kdat value's first byte: a block pointer follows, or the bytes themselves
// (a small file's, up to INLMAX - 1).
Value_Kind :: enum u8 {
	Ref    = 0,
	Inline = 1,
}

// --- Distinct values ---

// A byte address on the device, a multiple of BLKSZ when it names a block.
Addr :: distinct u64

// A generation: what a block was born in. Snapshot ids are generations too
// (a snapshot's id is the generation its newest blocks were born in); 0 is
// none.
Gen :: distinct u64

Bptr :: struct {
	addr: Addr,
	hash: u64,
	gen:  Gen,
}

Bptr_Disk :: struct #packed {
	addr: u64le,
	hash: u64le,
	gen:  u64le,
}
#assert(size_of(Bptr_Disk) == PTRSZ)

// --- The directory entry (11 §4.1) ---

// The entry a Kent key holds; the name is the key's.
Dir :: struct {
	flags:    u64,
	qid_path: u64,
	qid_vers: u32,
	qid_type: u8, // 9P's qid type bits: QTDIR, QTSYMLINK, and whatever a wstat of mode put there
	mode:     u32,
	atime:    i64, // ns
	mtime:    i64,
	ctime:    i64,
	btime:    i64,
	length:   u64,
	uid:      u32,
	gid:      u32,
	muid:     u32,
}

Dir_Disk :: struct #packed {
	flags:    u64le,
	qid_path: u64le,
	qid_vers: u32le,
	qid_type: u8,
	mode:     u32le,
	atime:    i64le,
	mtime:    i64le,
	ctime:    i64le,
	btime:    i64le,
	length:   u64le,
	uid:      u32le,
	gid:      u32le,
	muid:     u32le,
}
DIRSZ :: 8 + 8 + 4 + 1 + 4 + 8 + 8 + 8 + 8 + 8 + 4 + 4 + 4
#assert(size_of(Dir_Disk) == DIRSZ)
#assert(offset_of(Dir_Disk, mode) == 21)
#assert(offset_of(Dir_Disk, length) == 57)

// --- The volume (11 §5, §6) ---

// The superblock, in the volume's first block and its last: this, then a
// table of arenas (Arena_Entry_Disk each), then the XXH64 of everything
// before it.
MAGIC :: 0x73667876 // "vxfs"
VERSION :: 1

Sb_Disk :: struct #packed {
	magic:    u32le,
	version:  u32le,
	blksz:    u32le,
	bufspc:   u32le,
	narenas:  u32le,
	snapht:   u32le,
	snaproot: Bptr_Disk,
	commit:   u64le,
	nextgen:  u64le,
	nextqid:  u64le,
	nextdl:   u64le,
	flags:    u64le,
	freed:    u64le,
	spare:    u64le,
}
SBHDSZ :: 6 * 4 + PTRSZ + 7 * 8
#assert(size_of(Sb_Disk) == SBHDSZ)

Arena_Entry_Disk :: struct #packed {
	base:   u64le,
	blocks: u64le,
	hash:   u64le, // of the arena's header block
}
#assert(size_of(Arena_Entry_Disk) == 24)

MAXARENAS :: (BLKSZ - SBHDSZ - 8) / size_of(Arena_Entry_Disk)

Sb :: struct {
	narenas:  u32,
	snapht:   u32,
	snaproot: Bptr, // the snapshot tree
	commit:   u64, // commits so far: the newer of two good superblocks wins
	nextgen:  Gen,
	nextqid:  u64,
	nextdl:   u64,
	flags:    u64,
	freed:    Addr, // a deadlist-format chain of the blocks the commit freed, or 0
}

// A snapshot: Ksnap's value.
Snap :: struct {
	root:   Bptr,
	height: u32,
	flags:  u32,
	gen:    Gen, // its id: the generation its newest blocks were born in
	pred:   Gen, // the snapshot it follows, on its branch's chain
	succ:   Gen, // the one that follows it
	base:   Gen, // the snapshot its branch was forked from
	nlbl:   u32, // labels naming it
	nref:   u32, // branches forked from it
}

Snap_Disk :: struct #packed {
	root:   Bptr_Disk,
	height: u32le,
	flags:  u32le,
	gen:    u64le,
	pred:   u64le,
	succ:   u64le,
	base:   u64le,
	nlbl:   u32le,
	nref:   u32le,
}
SNAPSZ :: PTRSZ + 4 + 4 + 4 * 8 + 4 + 4
#assert(size_of(Snap_Disk) == SNAPSZ)

LABELMAX :: KEYMAX - 1

Label_Flag :: enum u32 {
	Mutable = 0, // a label that is a branch: it moves at every commit
}
Label_Flags :: bit_set[Label_Flag; u32]

// Klabel's value.
Label_Disk :: struct #packed {
	gen:   u64le,
	flags: u32le,
}
#assert(size_of(Label_Disk) == 12)

// Kdlist's value.
Dlist_Disk :: struct #packed {
	head:  u64le,
	count: u64le,
}
#assert(size_of(Dlist_Disk) == 16)

// Block headers.
Pivot_Hdr :: struct #packed {
	type:  u16le,
	nval:  u16le,
	valsz: u16le,
	nbuf:  u16le,
	bufsz: u16le,
}
#assert(size_of(Pivot_Hdr) == PIVHDSZ)

Leaf_Hdr :: struct #packed {
	type:  u16le,
	nval:  u16le,
	valsz: u16le,
}
#assert(size_of(Leaf_Hdr) == LEAFHDSZ)

// A log or deadlist block: its entries' size, their hash (log_hash), and
// the next block of its chain.
Log_Hdr :: struct #packed {
	type:    u16le,
	logsz:   u16le,
	loghash: u64le,
	chain:   Bptr_Disk,
}
#assert(size_of(Log_Hdr) == LOGHDSZ)
#assert(offset_of(Log_Hdr, chain) == 12)

// An arena's header (and its footer, the same bytes): where it is, and how
// much of its log a commit covers.
Arena_Hdr :: struct {
	base:     Addr,
	blocks:   u64,
	loghd:    Addr, // the log's first block
	logtl:    Addr, // its last
	tailsz:   u16, // the bytes of the last block's entries the commit covers
	tailhash: u64, // their hash
}

Arena_Hdr_Disk :: struct #packed {
	base:     u64le,
	blocks:   u64le,
	loghd:    u64le,
	logtl:    u64le,
	tailsz:   u16le,
	tailhash: u64le,
}
ARENA_HDRSZ :: 8 + 8 + 8 + 8 + 2 + 8
#assert(size_of(Arena_Hdr_Disk) == ARENA_HDRSZ)

// Keys whose integers are big-endian, so they sort as their numbers do.
Key_Id :: struct #packed {
	kind: u8,
	id:   u64be,
}
#assert(size_of(Key_Id) == 9)

Key_Dat :: struct #packed {
	kind: u8,
	qid:  u64be,
	off:  u64be,
}
#assert(size_of(Key_Dat) == 17)

Key_Dlist :: struct #packed {
	kind:  u8,
	snap:  u64be,
	birth: u64be,
	seq:   u64be,
}
#assert(size_of(Key_Dlist) == 25)

// --- Reading and writing layouts ---

// The T at the front of b: a bounds failure if b is shorter.
load :: #force_inline proc "contextless" ($T: typeid, b: []u8) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))
}

// v at the front of b.
store :: #force_inline proc "contextless" (b: []u8, v: $T) {
	intrinsics.unaligned_store((^T)(raw_data(b[:size_of(T)])), v)
}

get16 :: #force_inline proc "contextless" (b: []u8) -> u16 {
	return u16(load(u16le, b))
}

get32 :: #force_inline proc "contextless" (b: []u8) -> u32 {
	return u32(load(u32le, b))
}

get64 :: #force_inline proc "contextless" (b: []u8) -> u64 {
	return u64(load(u64le, b))
}

put16 :: #force_inline proc "contextless" (b: []u8, v: u16) {
	store(b, u16le(v))
}

put32 :: #force_inline proc "contextless" (b: []u8, v: u32) {
	store(b, u32le(v))
}

put64 :: #force_inline proc "contextless" (b: []u8, v: u64) {
	store(b, u64le(v))
}

// A big-endian integer inside a key.
kget64 :: #force_inline proc "contextless" (b: []u8) -> u64 {
	return u64(load(u64be, b))
}

kput64 :: #force_inline proc "contextless" (b: []u8, v: u64) {
	store(b, u64be(v))
}

bptr_disk :: proc "contextless" (bp: Bptr) -> Bptr_Disk {
	return {addr = u64le(bp.addr), hash = u64le(bp.hash), gen = u64le(bp.gen)}
}

bptr_of :: proc "contextless" (d: Bptr_Disk) -> Bptr {
	return {addr = Addr(d.addr), hash = u64(d.hash), gen = Gen(d.gen)}
}

pack_bptr :: proc "contextless" (b: []u8, bp: Bptr) {
	store(b, bptr_disk(bp))
}

unpack_bptr :: proc "contextless" (b: []u8) -> Bptr {
	return bptr_of(load(Bptr_Disk, b))
}

pack_dir :: proc "contextless" (b: []u8, d: Dir) {
	store(b, Dir_Disk {
		flags = u64le(d.flags),
		qid_path = u64le(d.qid_path),
		qid_vers = u32le(d.qid_vers),
		qid_type = d.qid_type,
		mode = u32le(d.mode),
		atime = i64le(d.atime),
		mtime = i64le(d.mtime),
		ctime = i64le(d.ctime),
		btime = i64le(d.btime),
		length = u64le(d.length),
		uid = u32le(d.uid),
		gid = u32le(d.gid),
		muid = u32le(d.muid),
	})
}

unpack_dir :: proc "contextless" (b: []u8) -> Dir {
	p := load(Dir_Disk, b)
	return {
		flags = u64(p.flags),
		qid_path = u64(p.qid_path),
		qid_vers = u32(p.qid_vers),
		qid_type = p.qid_type,
		mode = u32(p.mode),
		atime = i64(p.atime),
		mtime = i64(p.mtime),
		ctime = i64(p.ctime),
		btime = i64(p.btime),
		length = u64(p.length),
		uid = u32(p.uid),
		gid = u32(p.gid),
		muid = u32(p.muid),
	}
}

pack_snap :: proc "contextless" (b: []u8, s: Snap) {
	store(b, Snap_Disk {
		root = bptr_disk(s.root),
		height = u32le(s.height),
		flags = u32le(s.flags),
		gen = u64le(s.gen),
		pred = u64le(s.pred),
		succ = u64le(s.succ),
		base = u64le(s.base),
		nlbl = u32le(s.nlbl),
		nref = u32le(s.nref),
	})
}

unpack_snap :: proc "contextless" (b: []u8) -> Snap {
	p := load(Snap_Disk, b)
	return {
		root = bptr_of(p.root),
		height = u32(p.height),
		flags = u32(p.flags),
		gen = Gen(p.gen),
		pred = Gen(p.pred),
		succ = Gen(p.succ),
		base = Gen(p.base),
		nlbl = u32(p.nlbl),
		nref = u32(p.nref),
	}
}

pack_arena_hdr :: proc "contextless" (b: []u8, h: Arena_Hdr) {
	store(b, Arena_Hdr_Disk {
		base = u64le(h.base),
		blocks = u64le(h.blocks),
		loghd = u64le(h.loghd),
		logtl = u64le(h.logtl),
		tailsz = u16le(h.tailsz),
		tailhash = u64le(h.tailhash),
	})
}

unpack_arena_hdr :: proc "contextless" (b: []u8) -> Arena_Hdr {
	p := load(Arena_Hdr_Disk, b)
	return {
		base = Addr(p.base),
		blocks = u64(p.blocks),
		loghd = Addr(p.loghd),
		logtl = Addr(p.logtl),
		tailsz = u16(p.tailsz),
		tailhash = u64(p.tailhash),
	}
}

// Keys compare as bytes, then by length: a key sorts before every longer
// key it begins.
keycmp :: proc "contextless" (a, b: []u8) -> int {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return a[i] < b[i] ? -1 : 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return len(a) < len(b) ? -1 : 1
}

// --- The host's side: a device of blocks, and memory ---

// One block (BLKSZ bytes) at a byte address that is a multiple of it.
// barrier: everything written before it is durable once it returns .Ok (the
// block class's FLUSH, docs/proto/block.md §3). The callbacks are the
// caller's: fsd's block session, a host tool's image file, a test's memory.
Dev :: struct {
	ctx:     rawptr,
	read:    proc "contextless" (ctx: rawptr, addr: Addr, buf: ^[BLKSZ]u8) -> vx.Status,
	write:   proc "contextless" (ctx: rawptr, addr: Addr, buf: ^[BLKSZ]u8) -> vx.Status,
	barrier: proc "contextless" (ctx: rawptr) -> vx.Status,
	size:    u64, // bytes
}

// Memory, the caller's: the block cache, the arenas' free ranges and the
// working arrays of each operation come from here, and nothing else does.
// alloc returns size bytes, aligned for any value (16 bytes), or nil when
// there is none; free gets back exactly what alloc gave.
Mem :: struct {
	ctx:   rawptr,
	alloc: proc "contextless" (ctx: rawptr, size: int) -> rawptr,
	free:  proc "contextless" (ctx: rawptr, p: rawptr, size: int),
}
