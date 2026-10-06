package fs

import vx "abi:vx"

// Files (upstream docs/11 §4): directories, files and symbolic links as keys
// in a branch's tree, for fsd and tools/vxfs alike.
//
// An entry is Kent(pqid, name), its value a Dir; the root's is Kent(0, "").
// Every entry has Kup(qid), naming its own Kent key, whose pqid is its parent
// (gefs has one for directories; fsd names files by qid, so it needs one for
// every entry, which with no hard links is one to one). Renaming an entry
// changes its Kup and no other, so its children's stay right. A file's data
// is Kdat(qid, off) for each block-aligned offset that holds any: a block
// pointer (.Ref) to a block of it, or the block's first bytes inline
// (.Inline), the rest zeros. A missing key reads as zeros. A file of no more
// than INLINE bytes is kept inline whole; a longer one in blocks. A symbolic
// link is a file whose qid type has QTSYMLINK, its target its data.
//
// Every change is one batch of upserts where it can be, so it is atomic: a
// create with its parent's new mtime, a rename across directories with a
// moved directory's Kup. A write or truncation that spans more blocks than
// one batch holds is several, each whole. Semantics are tmpfs's, so the two
// servers agree: a directory is removed only when empty (EXISTS if not), a
// rename replaces a file by a file or an empty directory by a directory, and
// a directory cannot be moved inside itself.
//
// Names are strings as upstream's C has them: they end at a NUL, if there is
// one.

// 9P's qid type bits and mode bits, as a Dir holds them.
QTDIR :: 0x80
QTSYMLINK :: 0x02
DMDIR :: 0x8000_0000
DMAPPEND :: 0x4000_0000 // Plan 9's: its qid type has 0x40 (QTAPPEND)
DMEXCL :: 0x2000_0000 // and 0x20 (QTEXCL)
DMSYMLINK :: 0x0200_0000

NAMEMAX :: KEYMAX - 9
INLINE :: INLMAX - 1 // a whole file kept inline, at most
MAXFILE :: u64(1) << 62 // a file's length, at most: rounded up to a block, it never wraps

// An entry, and the key it is found by. Holds its key itself, so it may be
// copied and returned by value.
File :: struct {
	d:    Dir,
	key:  [KEYMAX]u8,
	nkey: int,
}

file_key :: #force_inline proc "contextless" (f: ^File) -> []u8 {
	return f.key[:f.nkey]
}

// Kent(pqid, name), in k (9 + len(name) bytes).
key_ent :: proc "contextless" (k: []u8, pqid: u64, name: string) -> []u8 {
	key_id(k, .Ent, pqid)
	copy(k[9:], name)
	return k[:9 + len(name)]
}

// Kdat(qid, off): block `off` of file qid, in k (17 bytes).
key_dat :: proc "contextless" (k: []u8, qid, off: u64) -> []u8 {
	store(k, Key_Dat{kind = u8(Key_Kind.Dat), qid = u64be(qid), off = u64be(off)})
	return k[:size_of(Key_Dat)]
}

is_dir :: proc "contextless" (f: ^File) -> bool {
	return f.d.mode & DMDIR != 0
}

// The bytes of s before its first NUL: a C string's.
@(private = "file")
cstring_of :: proc "contextless" (s: string) -> string {
	for i in 0 ..< len(s) {
		if s[i] == 0 {
			return s[:i]
		}
	}
	return s
}

@(private = "file")
vol_bad :: proc "contextless" (v: ^Vol) -> vx.Status {
	fail(&v.fs, .Err_Invalid)
	return .Err_Invalid
}

@(private = "file", require_results)
file_at :: proc "contextless" (v: ^Vol, t: ^Tree, k: []u8) -> (f: File, st: vx.Status) {
	buf: [INLMAX]u8
	val: []u8
	val, st = lookup(&v.fs, t, k, &buf)
	if st != .Ok {
		return
	}
	if len(val) != DIRSZ {
		return {}, vol_bad(v)
	}
	f.d = unpack_dir(val)
	f.nkey = copy(f.key[:], k)
	return f, .Ok
}

// A name a directory may hold: not empty, ".", "..", or with a '/' or NUL.
@(private = "file")
name_ok :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > NAMEMAX || name == "." || name == ".." {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] == 0 {
			return false
		}
	}
	return true
}

// --- Batches ---

@(private = "file")
Fbatch :: struct {
	m:       [96]Msg,
	bytes:   [96 * (KEYMAX + 64)]u8,
	n:       int,
	used:    int,
	size:    u32,
	freeing: bool, // the operation frees: it may use half the reserve (room)
}

@(private = "file", require_results)
fb_flush :: proc "contextless" (v: ^Vol, t: ^Tree, b: ^Fbatch) -> vx.Status {
	// Room for each upsert, not only the first: a long removal flushes many.
	st := room(&v.fs, 0, b.freeing)
	if st != .Ok {
		b.n, b.used, b.size = 0, 0, 0
		return st
	}
	st = upsert(&v.fs, t, b.m[:b.n])
	b.n, b.used, b.size = 0, 0, 0
	if st == .Ok && !end_op(&v.fs) {
		st = v.fs.err
	}
	return st
}

// True if the message fits; flush first when it says not.
@(private = "file")
fb_room :: proc "contextless" (b: ^Fbatch, nk, nv: int) -> bool {
	return b.n < len(b.m) && b.size + 7 + u32(nk + nv) <= BUFSPC && b.used + nk + nv <= len(b.bytes)
}

@(private = "file")
fb_add :: proc "contextless" (b: ^Fbatch, op: Op, k, val: []u8) {
	p := b.bytes[b.used:]
	copy(p, k)
	copy(p[len(k):], val)
	b.m[b.n] = {op = op, key = p[:len(k)], val = len(val) > 0 ? p[len(k):][:len(val)] : nil}
	b.n += 1
	b.used += len(k) + len(val)
	b.size += 7 + u32(len(k) + len(val))
}

@(private = "file", require_results)
fb_put :: proc "contextless" (v: ^Vol, t: ^Tree, b: ^Fbatch, op: Op, k, val: []u8) -> vx.Status {
	if !fb_room(b, len(k), len(val)) {
		if st := fb_flush(v, t, b); st != .Ok {
			return st
		}
	}
	fb_add(b, op, k, val)
	return .Ok
}

// An Owstat for the entry keyed k: the fields `flags` names, from d.
@(private = "file", require_results)
fb_wstat :: proc "contextless" (v: ^Vol, t: ^Tree, b: ^Fbatch, k: []u8, flags: Wstat, d: Dir) -> vx.Status {
	w: [1 + 8 + 4 + 8 + 8 + 4 + 4 + 4 + 8]u8
	w[0] = transmute(u8)flags
	p := 1
	if .Size in flags {
		put64(w[p:], d.length)
		p += 8
	}
	if .Mode in flags {
		put32(w[p:], d.mode)
		p += 4
	}
	if .Mtime in flags {
		put64(w[p:], u64(d.mtime))
		p += 8
	}
	if .Atime in flags {
		put64(w[p:], u64(d.atime))
		p += 8
	}
	if .Uid in flags {
		put32(w[p:], d.uid)
		p += 4
	}
	if .Gid in flags {
		put32(w[p:], d.gid)
		p += 4
	}
	if .Muid in flags {
		put32(w[p:], d.muid)
		p += 4
	}
	if .Ctime in flags {
		put64(w[p:], u64(d.ctime))
		p += 8
	}
	return fb_put(v, t, b, .Wstat, k, w[:p])
}

// A batch for an operation that will take `blocks` data blocks (and an
// upsert's slack): nil, NO_SPACE with nothing changed, if the volume has no
// room for it (11 §6). One that frees may use more of the reserve, so a full
// volume can still be emptied.
@(private = "file", require_results)
fb_new :: proc "contextless" (v: ^Vol, blocks: u64, freeing: bool) -> (^Fbatch, vx.Status) {
	if st := room(&v.fs, blocks, freeing); st != .Ok {
		return nil, st
	}
	b, ok := mem_new(Fbatch, &v.fs, 1)
	if !ok {
		return nil, v.fs.err
	}
	b[0].freeing = freeing
	v.fs.freeing = freeing
	return &b[0], .Ok
}

@(private = "file", require_results)
fb_done :: proc "contextless" (v: ^Vol, t: ^Tree, b: ^Fbatch, st: vx.Status) -> vx.Status {
	st := st
	if st == .Ok && b.n > 0 {
		st = fb_flush(v, t, b)
	}
	v.fs.freeing = false
	mem_release(&v.fs, ([^]Fbatch)(b)[:1])
	return st
}

// --- Finding things ---

// The root of tree t.
@(require_results)
root :: proc "contextless" (v: ^Vol, t: ^Tree) -> (File, vx.Status) {
	k: [9]u8
	return file_at(v, t, key_ent(k[:], 0, ""))
}

// Name in directory dir: an entry, ".", or "..".
@(require_results)
walk :: proc "contextless" (v: ^Vol, t: ^Tree, dir: ^File, name: string) -> (File, vx.Status) {
	if !is_dir(dir) {
		return {}, .Err_Invalid
	}
	nm := cstring_of(name)
	if nm == "." {
		return dir^, .Ok
	}
	if nm == ".." {
		if dir.nkey == 9 && kget64(dir.key[1:]) == 0 { // the root is its own parent
			return dir^, .Ok
		}
		// The parent is the pqid of dir's own key; its entry is the key its Kup names.
		pqid := kget64(dir.key[1:])
		k: [9]u8
		buf: [INLMAX]u8
		up, st := lookup(&v.fs, t, key_id(k[:], .Up, pqid), &buf)
		if st != .Ok {
			return {}, st == .Err_Not_Found ? vol_bad(v) : st // a directory has a Kup
		}
		if len(up) < 9 || len(up) > KEYMAX || up[0] != u8(Key_Kind.Ent) {
			return {}, vol_bad(v)
		}
		return file_at(v, t, up)
	}
	if !name_ok(nm) {
		return {}, len(nm) > NAMEMAX ? .Err_Range : .Err_Not_Found
	}
	k: [KEYMAX]u8
	return file_at(v, t, key_ent(k[:], dir.d.qid_path, nm))
}

// The entry whose qid is qid, by its Kup: an orphan's too.
@(require_results)
file_by_qid :: proc "contextless" (v: ^Vol, t: ^Tree, qid: u64) -> (f: File, st: vx.Status) {
	k: [9]u8
	buf: [INLMAX]u8
	key: []u8
	key, st = lookup(&v.fs, t, key_id(k[:], .Up, qid), &buf)
	if st != .Ok {
		return
	}
	orphan := len(key) == 9 && key[0] == u8(Key_Kind.Orphan)
	if !orphan && (len(key) < 9 || len(key) > KEYMAX || key[0] != u8(Key_Kind.Ent)) {
		return {}, vol_bad(v)
	}
	f, st = file_at(v, t, key)
	if st == .Ok && f.d.qid_path != qid {
		return {}, vol_bad(v)
	}
	return
}

// A path from the root, '/'-separated.
@(require_results)
walk_path :: proc "contextless" (v: ^Vol, t: ^Tree, path: string) -> (f: File, st: vx.Status) {
	f, st = root(v, t)
	rest := cstring_of(path)
	for st == .Ok && len(rest) > 0 {
		for len(rest) > 0 && rest[0] == '/' {
			rest = rest[1:]
		}
		n := 0
		for n < len(rest) && rest[n] != '/' {
			n += 1
		}
		if n == 0 {
			break
		}
		if n > NAMEMAX {
			return f, .Err_Range
		}
		f, st = walk(v, t, &f, rest[:n])
		rest = rest[n:]
	}
	return
}

// A directory's entries in name order: readdir_start, readdir_next until it
// is false, then readdir_end, which says whether that was the end.
Dir_Iter :: struct {
	v:   ^Vol,
	s:   Scan,
	bad: bool, // an entry was malformed
}

Dir_Entry :: struct {
	name: string, // valid until the next call
	d:    Dir,
}

@(require_results)
readdir_start :: proc "contextless" (it: ^Dir_Iter, v: ^Vol, t: ^Tree, dir: ^File) -> vx.Status {
	it^ = {v = v}
	if !is_dir(dir) {
		it.s.done = true
		return .Err_Invalid
	}
	pfx: [9]u8
	scan_start(&it.s, t, key_ent(pfx[:], dir.d.qid_path, ""))
	return .Ok
}

readdir_next :: proc "contextless" (it: ^Dir_Iter) -> (e: Dir_Entry, ok: bool) {
	if it.bad {
		return
	}
	kv := scan_next(&it.v.fs, &it.s) or_return
	if len(kv.val) != DIRSZ || len(kv.key) <= 9 {
		it.bad = true
		fail(&it.v.fs, .Err_Invalid)
		return
	}
	return {string(kv.key[9:]), unpack_dir(kv.val)}, true
}

@(require_results)
readdir_end :: proc "contextless" (it: ^Dir_Iter) -> vx.Status {
	if it.v == nil {
		return .Err_Invalid
	}
	scan_end(&it.v.fs, &it.s)
	return it.bad ? .Err_Invalid : it.v.fs.err
}

@(private = "file", require_results)
dir_empty :: proc "contextless" (v: ^Vol, t: ^Tree, dir: ^File) -> (empty: bool, st: vx.Status) {
	it: Dir_Iter
	if st = readdir_start(&it, v, t, dir); st != .Ok {
		return true, st
	}
	_, any := readdir_next(&it)
	return !any, readdir_end(&it)
}

// --- Making things ---

// The root of a new, empty tree: a directory of `mode`, owned by uid.
@(require_results)
mkroot :: proc "contextless" (v: ^Vol, t: ^Tree, mode, uid, gid: u32, now: i64) -> vx.Status {
	k, uk: [9]u8
	val: [DIRSZ]u8
	d := Dir {
		qid_path = v.nextqid,
		qid_type = QTDIR,
		mode     = (mode & 0o7777) | DMDIR,
		atime    = now,
		mtime    = now,
		ctime    = now,
		btime    = now,
		uid      = uid,
		gid      = gid,
		muid     = uid,
	}
	v.nextqid += 1
	pack_dir(val[:], d)
	key := key_ent(k[:], 0, "")
	m := [2]Msg{{op = .Insert, key = key, val = val[:]}, {op = .Insert, key = key_id(uk[:], .Up, d.qid_path), val = key}}
	st := room(&v.fs, 0, false)
	if st != .Ok {
		return st
	}
	st = upsert(&v.fs, t, m[:])
	if st == .Ok && !end_op(&v.fs) {
		st = v.fs.err
	}
	return st
}

// A new entry `name` in dir: a directory if mode has DMDIR, a symbolic link if
// DMSYMLINK (its target written after), else a file. The directory's mtime
// and ctime become now.
@(require_results)
create :: proc "contextless" (v: ^Vol, t: ^Tree, dir: ^File, name: string, mode, uid, gid: u32, now: i64) -> (f: File, st: vx.Status) {
	if !is_dir(dir) {
		return {}, .Err_Invalid
	}
	nm := cstring_of(name)
	if !name_ok(nm) {
		return {}, len(nm) > NAMEMAX ? .Err_Range : .Err_Invalid
	}
	if mode & DMDIR != 0 && mode & DMSYMLINK != 0 {
		return {}, .Err_Invalid
	}
	if _, st = walk(v, t, dir, nm); st == .Ok {
		return {}, .Err_Exists
	}
	if st != .Err_Not_Found {
		return {}, st
	}
	kept := mode & (DMDIR | DMAPPEND | DMEXCL | DMSYMLINK | 0o7777)
	f.d = Dir {
		qid_path = v.nextqid,
		qid_type = u8(kept >> 24), // the type bits, as Plan 9 has them: QTDIR, QTAPPEND, QTEXCL, QTSYMLINK
		mode     = kept,
		atime    = now,
		mtime    = now,
		ctime    = now,
		btime    = now,
		uid      = uid,
		gid      = gid,
		muid     = uid,
	}
	v.nextqid += 1
	f.nkey = len(key_ent(f.key[:], dir.d.qid_path, nm))
	b: ^Fbatch
	if b, st = fb_new(v, 0, false); b == nil {
		return f, st
	}
	val: [DIRSZ]u8
	pack_dir(val[:], f.d)
	fb_add(b, .Insert, file_key(&f), val[:])
	k: [9]u8
	fb_add(b, .Insert, key_id(k[:], .Up, f.d.qid_path), file_key(&f))
	st = fb_wstat(v, t, b, file_key(dir), {.Mtime, .Ctime}, Dir{mtime = now, ctime = now})
	return f, fb_done(v, t, b, st)
}

// --- Data ---

// Block `off` of file qid (BLKSZ bytes, zeros where it holds none).
@(private = "file", require_results)
read_block :: proc "contextless" (v: ^Vol, t: ^Tree, qid, off: u64, buf: ^[BLKSZ]u8) -> vx.Status {
	k: [17]u8
	vbuf: [INLMAX]u8
	val, st := lookup(&v.fs, t, key_dat(k[:], qid, off), &vbuf)
	buf^ = {}
	if st == .Err_Not_Found {
		return .Ok
	}
	if st != .Ok {
		return st
	}
	if len(val) >= 1 && val[0] == u8(Value_Kind.Inline) {
		copy(buf[:], val[1:])
		return .Ok
	}
	if len(val) != 1 + PTRSZ || val[0] != u8(Value_Kind.Ref) {
		return vol_bad(v)
	}
	b := get(&v.fs, unpack_bptr(val[1:]), {.Dat})
	if b == nil {
		return v.fs.err
	}
	buf^ = b.buf
	drop(&v.fs, b)
	return .Ok
}

// read's block, each reader's own: reads run on several threads at once
// (blk.odin's epochs, upstream's M6 step 6d5b).
@(private = "file", thread_local)
read_blk: [BLKSZ]u8

// Up to len(buf) bytes of f from off; the count read (0 at or past the end).
@(require_results)
read :: proc "contextless" (v: ^Vol, t: ^Tree, f: ^File, off: u64, buf: []u8) -> (got: u64, st: vx.Status) {
	if is_dir(f) {
		return 0, .Err_Invalid
	}
	if off >= f.d.length {
		return 0, .Ok
	}
	n := min(u64(len(buf)), f.d.length - off)
	blk := &read_blk
	for got < n {
		at := off + got
		base := at / BLKSZ * BLKSZ
		in_blk := at - base
		take := min(BLKSZ - in_blk, n - got)
		if st = read_block(v, t, f.d.qid_path, base, blk); st != .Ok {
			return
		}
		copy(buf[got:][:take], blk[in_blk:][:take])
		got += take
	}
	return got, .Ok
}

// Block `off` of f as `data`: a new data block, or inline if f is small.
@(private = "file", require_results)
put_block :: proc "contextless" (v: ^Vol, t: ^Tree, b: ^Fbatch, f: ^File, off: u64, data: ^[BLKSZ]u8, n: u64) -> vx.Status {
	k: [17]u8
	val: [INLMAX]u8
	key := key_dat(k[:], f.d.qid_path, off)
	if n <= INLINE { // the whole file
		val[0] = u8(Value_Kind.Inline)
		copy(val[1:], data[:n])
		return fb_put(v, t, b, .Insert, key, val[:1 + n])
	}
	d := new_data(&v.fs, t)
	if d == nil {
		return v.fs.err
	}
	d.buf = data^
	ok := write_block(&v.fs, d)
	val[0] = u8(Value_Kind.Ref)
	pack_bptr(val[1:], d.bp)
	drop(&v.fs, d)
	if !ok {
		return v.fs.err
	}
	return fb_put(v, t, b, .Insert, key, val[:1 + PTRSZ])
}

// Writes data at off to f (and f's entry, in memory too): its length if it
// grows, mtime and ctime now, muid.
@(require_results)
write :: proc "contextless" (v: ^Vol, t: ^Tree, f: ^File, off: u64, data: []u8, now: i64, muid: u32) -> vx.Status {
	if is_dir(f) {
		return .Err_Invalid
	}
	n := u64(len(data))
	if off + n < off || off + n > MAXFILE {
		return .Err_Range
	}
	if n == 0 {
		return .Ok // nothing written: the file is not extended, as POSIX has it (M5 step 10)
	}
	was := f.d.length
	length := max(off + n, was)
	b, st := fb_new(v, n / BLKSZ + 2, false) // the blocks it touches, and a converted block 0
	if b == nil {
		return st
	}
	blk := &v.blk
	if length <= INLINE { // small: kept inline, whole
		st = read_block(v, t, f.d.qid_path, 0, blk)
		if st == .Ok {
			copy(blk[off:], data)
			st = put_block(v, t, b, f, 0, blk, length)
		}
	} else {
		// A file that was inline is in blocks from now: its block 0 is written as
		// one even if this write does not touch it.
		convert := was != 0 && was <= INLINE && off >= BLKSZ
		if convert {
			if st = read_block(v, t, f.d.qid_path, 0, blk); st == .Ok {
				st = put_block(v, t, b, f, 0, blk, BLKSZ)
			}
		}
		for at := off; st == .Ok && at < off + n; {
			base := at / BLKSZ * BLKSZ
			in_blk := at - base
			take := min(BLKSZ - in_blk, off + n - at)
			if take < BLKSZ {
				st = read_block(v, t, f.d.qid_path, base, blk) // part of a block: the rest kept
			}
			if st != .Ok {
				break
			}
			copy(blk[in_blk:][:take], data[at - off:][:take])
			st = put_block(v, t, b, f, base, blk, BLKSZ)
			at += take
		}
	}
	f.d.length = length
	f.d.mtime, f.d.ctime = now, now
	f.d.muid = muid
	f.d.qid_vers += 1
	if st == .Ok {
		st = fb_wstat(v, t, b, file_key(f), {.Size, .Mtime, .Ctime, .Muid}, f.d)
	}
	return fb_done(v, t, b, st)
}

// Every Kdat key of qid at or past `from`, cleared: the blocks they name
// freed. A chunk at a time, each flushed before the next is looked for, so a
// file of any size needs no more memory than one chunk.
@(private = "file", require_results)
clear_data :: proc "contextless" (v: ^Vol, t: ^Tree, b: ^Fbatch, qid, from: u64) -> vx.Status {
	pfx: [9]u8
	key_id(pfx[:], .Dat, qid)
	next := from
	for {
		offs: [256]u64
		n := 0
		lo: [17]u8
		s: Scan
		scan_from(&s, t, pfx[:], key_dat(lo[:], qid, next))
		for n < len(offs) {
			kv := scan_next(&v.fs, &s) or_break
			if len(kv.key) == 17 && kget64(kv.key[9:]) >= next {
				offs[n] = kget64(kv.key[9:])
				n += 1
			}
		}
		scan_end(&v.fs, &s)
		st := v.fs.err
		for off in offs[:n] {
			if st != .Ok {
				break
			}
			k: [17]u8
			st = fb_put(v, t, b, .Clearb, key_dat(k[:], qid, off), nil)
		}
		if st != .Ok || n < len(offs) {
			return st
		}
		if st = fb_flush(v, t, b); st != .Ok {
			return st // the tree must lose them before the next look
		}
		next = offs[n - 1] + 1
	}
}

// --- Changing entries ---

Attr :: struct {
	valid:  Wstat, // the fields below to set
	length: u64,
	mode:   u32,
	uid:    u32,
	gid:    u32,
	atime:  i64,
	mtime:  i64,
}

// Sets f's attributes as a says; ctime becomes now. A new length truncates or
// extends (with zeros); a directory or link has none to set.
@(require_results)
setattr :: proc "contextless" (v: ^Vol, t: ^Tree, f: ^File, a: Attr, now: i64) -> vx.Status {
	if .Size in a.valid && (is_dir(f) || f.d.mode & DMSYMLINK != 0) {
		return .Err_Invalid
	}
	if .Size in a.valid && a.length > MAXFILE {
		return .Err_Range // rounding up must not wrap
	}
	shrinks := .Size in a.valid && a.length < f.d.length
	// Growing an inline file past INLINE puts its bytes in a block of their own
	// (11 §3: a file is inline whole, or in blocks): M5 step 10.
	converts := .Size in a.valid && f.d.length != 0 && f.d.length <= INLINE && a.length > INLINE
	b, st := fb_new(v, shrinks || converts ? 1 : 0, shrinks) // a shrink frees, and rewrites its last block
	if b == nil {
		return st
	}
	blk := &v.blk
	if shrinks {
		keep := (a.length + BLKSZ - 1) / BLKSZ * BLKSZ // blocks wholly past the end go
		if a.length <= INLINE {
			keep = 0 // inline from now: block 0 goes too, and comes back inline
		}
		if a.length <= INLINE && a.length != 0 {
			st = read_block(v, t, f.d.qid_path, 0, blk)
		}
		if st == .Ok {
			st = clear_data(v, t, b, f.d.qid_path, keep)
		}
		base := a.length / BLKSZ * BLKSZ
		in_blk := a.length - base
		if st == .Ok && a.length <= INLINE && a.length != 0 {
			for &c in blk[a.length:] {
				c = 0
			}
			st = put_block(v, t, b, f, 0, blk, a.length)
		} else if st == .Ok && in_blk != 0 { // the last block's tail zeroed
			if st = read_block(v, t, f.d.qid_path, base, blk); st == .Ok {
				for &c in blk[in_blk:] {
					c = 0
				}
				st = put_block(v, t, b, f, base, blk, BLKSZ)
			}
		}
	} else if converts {
		if st = read_block(v, t, f.d.qid_path, 0, blk); st == .Ok { // the inline bytes, the rest zeros
			st = put_block(v, t, b, f, 0, blk, BLKSZ)
		}
	}
	if .Size in a.valid {
		f.d.length = a.length
	}
	if .Mode in a.valid {
		f.d.mode = (f.d.mode & (DMDIR | DMAPPEND | DMEXCL | DMSYMLINK)) | (a.mode & 0o7777)
	}
	if .Uid in a.valid {
		f.d.uid = a.uid
	}
	if .Gid in a.valid {
		f.d.gid = a.gid
	}
	if .Atime in a.valid {
		f.d.atime = a.atime
	}
	if .Mtime in a.valid {
		f.d.mtime = a.mtime
	}
	f.d.ctime = now
	f.d.qid_vers += 1
	flags := (a.valid & {.Size, .Mode, .Uid, .Gid, .Atime, .Mtime}) + {.Ctime}
	if st == .Ok {
		st = fb_wstat(v, t, b, file_key(f), flags, f.d)
	}
	return fb_done(v, t, b, st)
}

// Removes name from dir: a directory only if empty; a file's data cleared.
@(require_results)
remove :: proc "contextless" (v: ^Vol, t: ^Tree, dir: ^File, name: string, now: i64) -> vx.Status {
	if cname := cstring_of(name); cname == "." || cname == ".." {
		return .Err_Invalid // never removed (".." was EXISTS, its parent not being empty)
	}
	f, st := walk(v, t, dir, name)
	if st != .Ok {
		return st
	}
	if bytes_equal(file_key(&f), file_key(dir)) {
		return .Err_Invalid // "." or ".."
	}
	empty := true
	if is_dir(&f) {
		if empty, st = dir_empty(v, t, &f); st != .Ok {
			return st
		}
	}
	if !empty {
		return .Err_Exists
	}
	b: ^Fbatch
	if b, st = fb_new(v, 0, true); b == nil {
		return st
	}
	if !is_dir(&f) {
		st = clear_data(v, t, b, f.d.qid_path, 0)
	}
	k: [9]u8
	if st == .Ok {
		st = fb_put(v, t, b, .Delete, key_id(k[:], .Up, f.d.qid_path), nil)
	}
	if st == .Ok {
		st = fb_put(v, t, b, .Delete, file_key(&f), nil)
	}
	if st == .Ok {
		st = fb_wstat(v, t, b, file_key(dir), {.Mtime, .Ctime}, Dir{mtime = now, ctime = now})
	}
	return fb_done(v, t, b, st)
}

// --- Orphans: files removed while open (11 §4) ---

is_orphan :: proc "contextless" (f: ^File) -> bool {
	return f.nkey == 9 && f.key[0] == u8(Key_Kind.Orphan)
}

// Removes name, a file, from dir but keeps it: its entry moves to
// Korphan(qid), which its Kup names, so it is found by its qid still, and its
// data stays until reap. One batch.
@(require_results)
orphan :: proc "contextless" (v: ^Vol, t: ^Tree, dir: ^File, name: string, now: i64) -> vx.Status {
	f, st := walk(v, t, dir, name)
	if st != .Ok {
		return st
	}
	if is_dir(&f) {
		return .Err_Invalid // a directory is removed, empty, or not at all
	}
	b: ^Fbatch
	if b, st = fb_new(v, 0, true); b == nil {
		return st
	}
	ok, uk: [9]u8
	val: [DIRSZ]u8
	okey := key_id(ok[:], .Orphan, f.d.qid_path)
	pack_dir(val[:], f.d)
	fb_add(b, .Delete, file_key(&f), nil)
	fb_add(b, .Insert, okey, val[:])
	fb_add(b, .Insert, key_id(uk[:], .Up, f.d.qid_path), okey)
	st = fb_wstat(v, t, b, file_key(dir), {.Mtime, .Ctime}, Dir{mtime = now, ctime = now})
	return fb_done(v, t, b, st)
}

// An orphan's end: its data cleared, its Korphan and Kup gone.
@(require_results)
reap :: proc "contextless" (v: ^Vol, t: ^Tree, qid: u64) -> vx.Status {
	ok: [9]u8
	buf: [INLMAX]u8
	_, st := lookup(&v.fs, t, key_id(ok[:], .Orphan, qid), &buf)
	if st != .Ok {
		return st == .Err_Not_Found ? .Err_Invalid : st // only an orphan's data is reaped
	}
	b: ^Fbatch
	if b, st = fb_new(v, 0, true); b == nil {
		return st
	}
	st = clear_data(v, t, b, qid, 0)
	k: [9]u8
	if st == .Ok {
		st = fb_put(v, t, b, .Delete, key_id(k[:], .Orphan, qid), nil)
	}
	if st == .Ok {
		st = fb_put(v, t, b, .Delete, key_id(k[:], .Up, qid), nil)
	}
	return fb_done(v, t, b, st)
}

// Every orphan in tree t reaped: what a crash left of files removed while
// open, when the tree is first opened again. How many.
@(require_results)
reap_all :: proc "contextless" (v: ^Vol, t: ^Tree) -> (n: u32, st: vx.Status) {
	for { // a few at a time: the tree changes as each goes
		qid: [32]u64
		got := 0
		pfx := [1]u8{u8(Key_Kind.Orphan)}
		s: Scan
		scan_start(&s, t, pfx[:])
		for got < len(qid) {
			kv := scan_next(&v.fs, &s) or_break
			if len(kv.key) == 9 {
				qid[got] = kget64(kv.key[1:])
				got += 1
			}
		}
		scan_end(&v.fs, &s)
		if v.fs.err != .Ok {
			return n, v.fs.err
		}
		if got == 0 {
			return n, .Ok
		}
		for q in qid[:got] {
			if st = reap(v, t, q); st != .Ok {
				return
			}
		}
		n += u32(got)
	}
}

// Whether a file replaced by a rename is still open: kept as an orphan then.
Keep_Open :: proc "contextless" (ctx: rawptr, qid: u64) -> bool

// Renames from/name to to/newname, replacing as POSIX does (see the top). A
// file replaced while it is open is kept as an orphan if keep_open says so
// (its qid), for reap when its last user goes, as POSIX keeps it.
@(require_results)
rename :: proc "contextless" (v: ^Vol, t: ^Tree, from: ^File, name: string, to: ^File, newname: string, now: i64, keep_open: Keep_Open, ctx: rawptr) -> vx.Status {
	if !is_dir(to) {
		return .Err_Invalid
	}
	newnm := cstring_of(newname)
	if !name_ok(newnm) {
		return len(newnm) > NAMEMAX ? .Err_Range : .Err_Invalid
	}
	f, st := walk(v, t, from, name)
	if st != .Ok {
		return st
	}
	if !name_ok(cstring_of(name)) {
		return .Err_Invalid
	}
	// Not into itself: no directory from `to` up to the root is f. As deep as
	// the tree is: a refusal past that, not a verdict on the volume (a user can
	// make a tree that deep).
	up := to^
	for depth := u32(0); ; depth += 1 {
		if up.d.qid_path == f.d.qid_path {
			return .Err_Invalid
		}
		if up.nkey == 9 && kget64(up.key[1:]) == 0 {
			break // the root
		}
		if depth > 1 << 16 {
			return .Err_Range
		}
		if up, st = walk(v, t, &up, ".."); st != .Ok {
			return st
		}
	}
	there: File
	there, st = walk(v, t, to, newnm)
	if st == .Ok {
		if there.d.qid_path == f.d.qid_path {
			return .Ok
		}
		if is_dir(&there) != is_dir(&f) {
			return is_dir(&there) ? .Err_Exists : .Err_Invalid
		}
		if is_dir(&there) {
			empty: bool
			if empty, st = dir_empty(v, t, &there); st != .Ok || !empty {
				return st != .Ok ? st : .Err_Exists
			}
		}
		keep := !is_dir(&there) && keep_open != nil && keep_open(ctx, there.d.qid_path)
		st = keep ? orphan(v, t, to, newnm, now) : remove(v, t, to, newnm, now)
		if st != .Ok {
			return st
		}
	} else if st != .Err_Not_Found {
		return st
	}
	// One batch: the entry moved, its Kup, both directories' times.
	b: ^Fbatch
	if b, st = fb_new(v, 0, false); b == nil {
		return st
	}
	k: [KEYMAX]u8
	val: [DIRSZ]u8
	key := key_ent(k[:], to.d.qid_path, newnm)
	f.d.ctime = now
	pack_dir(val[:], f.d)
	fb_add(b, .Delete, file_key(&f), nil)
	fb_add(b, .Insert, key, val[:])
	uk: [9]u8
	fb_add(b, .Insert, key_id(uk[:], .Up, f.d.qid_path), key)
	pd := Dir{mtime = now, ctime = now}
	st = fb_wstat(v, t, b, file_key(from), {.Mtime, .Ctime}, pd)
	if st == .Ok && to.d.qid_path != from.d.qid_path {
		st = fb_wstat(v, t, b, file_key(to), {.Mtime, .Ctime}, pd)
	}
	return fb_done(v, t, b, st)
}

// A symbolic link `name` in dir to target.
@(require_results)
symlink :: proc "contextless" (v: ^Vol, t: ^Tree, dir: ^File, name, target: string, uid, gid: u32, now: i64) -> (f: File, st: vx.Status) {
	tgt := cstring_of(target)
	if len(tgt) == 0 {
		return {}, .Err_Invalid
	}
	if len(tgt) > INLINE {
		return {}, .Err_Range // a tgt is inline data (11 §3), never blocks: M5 step 10
	}
	if f, st = create(v, t, dir, name, DMSYMLINK | 0o777, uid, gid, now); st != .Ok {
		return
	}
	return f, write(v, t, &f, 0, transmute([]u8)tgt, now, uid)
}

// Formats a volume as format does, each branch given a root directory of
// `mode` owned by uid and gid; committed, left mounted. Unmount it whatever
// this returns.
@(require_results)
mkfs :: proc "contextless" (v: ^Vol, dev: Dev, mem: Mem, cache, narenas: u32, branches: []string, mode, uid, gid: u32, now: i64) -> vx.Status {
	st := format(v, dev, mem, cache, narenas, branches)
	for name in branches {
		if st != .Ok {
			break
		}
		br: ^Branch
		if br, st = branch_open(v, name); st == .Ok {
			st = mkroot(v, &br.t, mode, uid, gid, now)
		}
	}
	if st == .Ok {
		st = commit(v)
	}
	return st
}
