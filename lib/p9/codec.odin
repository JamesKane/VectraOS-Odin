// 9P2000 and 9Px (upstream 02 §3), with the 9P2000.L messages of 9Px's
// posix and xattr extensions (upstream docs/proto/posix.md): the codec for
// messages, stat entries and 9Px version strings; the server framework (server.odin), which keeps a
// hostile client inside its attach root; and a client (client.odin). Neither
// side has a transport of its own: the server turns one request into one
// reply, and the client sends through a procedure it is given.
//
// A message is one flat Msg holding every field any message has; MESSAGES
// (tables.odin, from messages.def) lists which fields each type carries, in
// wire order, and one encoder and one decoder walk that list. Decoding is
// strict, because the bytes may come from a hostile peer: the size field must
// match the message exactly, every field must fit, nothing may follow the
// last field, a walk has at most 16 names, and strings may not hold NUL.
// Decoded strings and data point into the message buffer; nothing is copied.
//
// No allocation: every buffer is the caller's.
package p9

import "base:intrinsics"
import "abi:vx"
import "vx:str"

MAXWELEM :: 16 // names in one walk
NOTAG :: u16(0xffff) // Tversion's tag
NOFID :: Fid(0xffff_ffff) // no fid (Tattach's afid without auth)
IOHDRSZ :: 24 // the Rread and Twrite overhead: a read or write carries msize - 24 bytes
MIN_MSIZE :: 256
MAX_MSIZE :: 1 << 20

// A fid: the client's name for a file on one connection. Its own type, so a
// tag or a count cannot be passed for one.
Fid :: distinct u32

// qid.type, and the top byte of a stat's mode: one bit each. Bits a peer
// sends that are not named here survive a decode and an encode unchanged.
Qid_Type_Bit :: enum u8 {
	Tmp    = 2,
	Auth   = 3,
	Mount  = 4,
	Excl   = 5,
	Append = 6,
	Dir    = 7,
}
Qid_Type :: bit_set[Qid_Type_Bit;u8]
#assert(size_of(Qid_Type) == 1)

QTDIR :: Qid_Type{.Dir}
QTAPPEND :: Qid_Type{.Append}
QTEXCL :: Qid_Type{.Excl}
QTAUTH :: Qid_Type{.Auth}
QTFILE :: Qid_Type{}

// A stat's mode: a directory; and 9P2000.u's link and device (a terminal, to
// the musl back end). Beside the permission bits, so plain u32s.
DMDIR :: u32(0x8000_0000)
DMSYMLINK :: u32(0x0200_0000)
DMDEVICE :: u32(0x0080_0000)

// Tread's and Twrite's offset that means the open file's own, which the
// server keeps and moves on (posix).
OFFSET_CURRENT :: max(u64)

// Topen's and Tcreate's mode: the access in its low two bits, and flags.
Access :: enum u8 {
	Read,
	Write,
	Rdwr,
	Exec,
}

Open_Mode :: bit_field u8 {
	access: Access | 2,
	_:      u8     | 2,
	trunc:  bool   | 1, // OTRUNC, 0x10
	// fs.open's, never a client's (the server takes it out of theirs): a
	// Tjoin's open, another fid for a file already open, which may have been
	// removed since. 0x20.
	join:   bool   | 1,
	rclose: bool   | 1, // ORCLOSE, 0x40
	// Topen's (posix): the open file's writes at OFFSET_CURRENT go to its end.
	// 0x80.
	append: bool   | 1,
}
#assert(size_of(Open_Mode) == 1)

OREAD :: Open_Mode{access = .Read}
OWRITE :: Open_Mode{access = .Write}
ORDWR :: Open_Mode{access = .Rdwr}
OEXEC :: Open_Mode{access = .Exec}

// Whether a fid opened in this mode may write.
writes :: proc "contextless" (m: Open_Mode) -> bool {
	return m.access == .Write || m.access == .Rdwr
}

Qid :: struct {
	type:    Qid_Type,
	version: u32,
	path:    u64,
}

// Rgetattr's attributes, as 9P2000.L has them: which are set, by Linux's
// numbers.
Getattr_Bit :: enum u64 {
	Mode,
	Nlink,
	Uid,
	Gid,
	Rdev,
	Atime,
	Mtime,
	Ctime,
	Ino,
	Size,
	Blocks,
}
Getattr_Mask :: bit_set[Getattr_Bit;u64]
GETATTR_BASIC :: Getattr_Mask{.Mode, .Nlink, .Uid, .Gid, .Rdev, .Atime, .Mtime, .Ctime, .Ino, .Size, .Blocks} // 0x7ff

// Tsetattr's: which attributes to change.
Setattr_Bit :: enum u32 {
	Mode,
	Uid,
	Gid,
	Size,
	Atime, // to now, without Atime_Set
	Mtime,
	Ctime,
	Atime_Set, // to atime_sec and atime_nsec
	Mtime_Set,
}
Setattr_Mask :: bit_set[Setattr_Bit;u32]

// POSIX's file types in an Attr's mode, which is POSIX's, not 9P2000's.
S_IFMT :: u32(0o170000)
S_IFDIR :: u32(0o040000)
S_IFREG :: u32(0o100000)
S_IFLNK :: u32(0o120000)
S_IFCHR :: u32(0o020000)

Attr :: struct {
	valid:                               Getattr_Mask,
	qid:                                 Qid,
	mode, uid, gid:                      u32,
	nlink, rdev, size, blksize, blocks:  u64,
	atime_sec, atime_nsec:               u64,
	mtime_sec, mtime_nsec:               u64,
	ctime_sec, ctime_nsec:               u64,
	btime_sec, btime_nsec:               u64,
	gen, data_version:                   u64,
}

Setattr :: struct {
	valid:                 Setattr_Mask,
	mode, uid, gid:        u32,
	size:                  u64,
	atime_sec, atime_nsec: u64,
	mtime_sec, mtime_nsec: u64,
}

// Tlock's and Tgetlock's lock types, and Rlock's answer. A peer's byte is
// kept as it came; the server refuses one it does not know.
Lock_Type :: enum u8 {
	Read,
	Write,
	Unlock,
}

Lock_Status :: enum u8 {
	Success,
	Blocked, // the client waits and asks again (F_SETLKW)
	Error,
}

Lock_Flag :: enum u32 {
	Block,
	Reclaim,
}
Lock_Flags :: bit_set[Lock_Flag;u32]

// Tseek's whence.
Whence :: enum u8 {
	Set,
	Current,
	End,
}

// Tdesc's flags: the open file's O_APPEND.
Desc_Flag :: enum u32 {
	Append,
}
Desc_Flags :: bit_set[Desc_Flag;u32]

// Tmap's prot: what the mapping may do with the pages. On the wire, bit i
// is the member of value i (read 1, write 2, exec 4).
Prot_Flag :: enum u32 {
	Read,
	Write,
	Exec,
}
Prot :: bit_set[Prot_Flag;u32]

TOKEN_SIZE :: 16

Msg :: struct {
	type:   Type,
	tag:    u16,
	fid:    Fid,
	newfid: Fid,
	afid:   Fid,
	msize:  u32,
	iounit: u32,
	perm:   u32,
	count:  u32,
	offset: u64,
	mode:   Open_Mode,
	oldtag: u16,
	version, uname, aname, ename, name: string,
	qid:    Qid,
	nwname: u16,
	nwqid:  u16,
	wname:  [MAXWELEM]string,
	wqid:   [MAXWELEM]Qid,
	data:   []u8, // Rread, Twrite; its length is count
	stat:   []u8, // Rstat, Twstat: one stat entry, its own size[2] included
	// 9P2000.L's and 9Px's, for the posix and xattr extensions.
	name2:      string,
	gid:        u32,
	datasync:   u32,
	mask:       Getattr_Mask,
	attr:       Attr,
	setattr:    Setattr,
	lock_type:  Lock_Type,
	status:     Lock_Status,
	whence:     Whence,
	lock_flags: Lock_Flags,
	proc_id:    u32,
	holds:      u32,
	desc_flags: Desc_Flags,
	prot:       Prot, // Tmap's; bits outside the set reach the server as they came
	roffset:    u64, // Treadref's and Twriteref's
	start:      u64,
	length:     u64,
	client_id:  string,
	token:      [TOKEN_SIZE]u8,
}

// --- Encoding ---

// A little-endian integer of v's own width; the field's type says how wide
// it is on the wire, so no width is written twice.
@(private="file")
put :: proc "contextless" (o: ^str.Buf, v: $T) where intrinsics.type_is_integer(T) {
	if o.failed || len(o.buf) - o.len < size_of(T) {
		o.failed = true
		return
	}
	for i in 0 ..< size_of(T) {
		o.buf[o.len] = u8(u64(v) >> (8 * uint(i)))
		o.len += 1
	}
}

@(private="file")
put_str :: proc "contextless" (o: ^str.Buf, s: string) {
	if len(s) > 0xffff {
		o.failed = true
	}
	put(o, u16(len(s)))
	str.write_string(o, s)
}

@(private="file")
put_qid :: proc "contextless" (o: ^str.Buf, q: Qid) {
	put(o, transmute(u8)q.type)
	put(o, q.version)
	put(o, q.path)
}

@(private="file")
put_attr :: proc "contextless" (o: ^str.Buf, a: ^Attr) {
	put(o, transmute(u64)a.valid)
	put_qid(o, a.qid)
	put(o, a.mode)
	put(o, a.uid)
	put(o, a.gid)
	rest := [?]u64 {
		a.nlink,
		a.rdev,
		a.size,
		a.blksize,
		a.blocks,
		a.atime_sec,
		a.atime_nsec,
		a.mtime_sec,
		a.mtime_nsec,
		a.ctime_sec,
		a.ctime_nsec,
		a.btime_sec,
		a.btime_nsec,
		a.gen,
		a.data_version,
	}
	for v in rest {
		put(o, v)
	}
}

@(private="file")
put_setattr :: proc "contextless" (o: ^str.Buf, a: ^Setattr) {
	put(o, transmute(u32)a.valid)
	put(o, a.mode)
	put(o, a.uid)
	put(o, a.gid)
	put(o, a.size)
	put(o, a.atime_sec)
	put(o, a.atime_nsec)
	put(o, a.mtime_sec)
	put(o, a.mtime_nsec)
}

// Encodes m into buf. Returns its length, or 0 if it does not fit or is not a
// message the tables have.
encode :: proc "contextless" (m: ^Msg, buf: []u8) -> int {
	if !known(m.type) {
		return 0
	}
	o := str.Buf{buf = buf}
	put(&o, u32(0)) // the size, filled in below
	put(&o, u8(m.type))
	put(&o, m.tag)
	for f in MESSAGES[u8(m.type)].fields {
		switch f {
		case .Fid:
			put(&o, m.fid)
		case .Newfid:
			put(&o, m.newfid)
		case .Afid:
			put(&o, m.afid)
		case .Msize:
			put(&o, m.msize)
		case .Iounit:
			put(&o, m.iounit)
		case .Perm:
			put(&o, m.perm)
		case .Count:
			put(&o, m.count)
		case .Offset:
			put(&o, m.offset)
		case .Mode:
			put(&o, transmute(u8)m.mode)
		case .Oldtag:
			put(&o, m.oldtag)
		case .Version:
			put_str(&o, m.version)
		case .Uname:
			put_str(&o, m.uname)
		case .Aname:
			put_str(&o, m.aname)
		case .Ename:
			put_str(&o, m.ename)
		case .Name:
			put_str(&o, m.name)
		case .Qid:
			put_qid(&o, m.qid)
		case .Wnames:
			if m.nwname > MAXWELEM {
				o.failed = true
				break
			}
			put(&o, m.nwname)
			for name in m.wname[:m.nwname] {
				put_str(&o, name)
			}
		case .Wqids:
			if m.nwqid > MAXWELEM {
				o.failed = true
				break
			}
			put(&o, m.nwqid)
			for q in m.wqid[:m.nwqid] {
				put_qid(&o, q)
			}
		case .Data:
			if u64(len(m.data)) > u64(max(u32)) {
				o.failed = true
			}
			put(&o, u32(len(m.data)))
			// Rread's data may already sit where it is going (server.odin reads it
			// there), and write_bytes copies with a memmove, so that is a no-op,
			// not a corruption.
			str.write_bytes(&o, m.data)
		case .Stat:
			if len(m.stat) > 0xffff {
				o.failed = true
			}
			put(&o, u16(len(m.stat)))
			str.write_bytes(&o, m.stat)
		case .Name2:
			put_str(&o, m.name2)
		case .Gid:
			put(&o, m.gid)
		case .Mask:
			put(&o, transmute(u64)m.mask)
		case .Datasync:
			put(&o, m.datasync)
		case .Attr:
			put_attr(&o, &m.attr)
		case .Setattr:
			put_setattr(&o, &m.setattr)
		case .Locktype:
			put(&o, u8(m.lock_type))
		case .Lockflags:
			put(&o, transmute(u32)m.lock_flags)
		case .Start:
			put(&o, m.start)
		case .Length:
			put(&o, m.length)
		case .Procid:
			put(&o, m.proc_id)
		case .Clientid:
			put_str(&o, m.client_id)
		case .Status:
			put(&o, u8(m.status))
		case .Holds:
			put(&o, m.holds)
		case .Token:
			str.write_bytes(&o, m.token[:])
		case .Whence:
			put(&o, u8(m.whence))
		case .Descflags:
			put(&o, transmute(u32)m.desc_flags)
		case .Prot:
			put(&o, transmute(u32)m.prot)
		case .Roffset:
			put(&o, m.roffset)
		}
	}
	if o.failed || u64(o.len) > u64(max(u32)) {
		return 0
	}
	size := str.Buf{buf = buf[:4]} // the size field, written in place
	put(&size, u32(o.len))
	return o.len
}

// --- Decoding ---

@(private="file")
In :: struct {
	buf:    []u8,
	pos:    int,
	failed: bool,
}

// Every length read here is checked against what is left before it moves
// pos, so no count from the wire is ever added to anything.
@(private="file")
remaining :: proc "contextless" (in_: ^In) -> u64 {
	return u64(len(in_.buf) - in_.pos)
}

// A little-endian integer of T's width.
@(private="file")
get :: proc "contextless" (in_: ^In, $T: typeid) -> T where intrinsics.type_is_integer(T) {
	if in_.failed || remaining(in_) < size_of(T) {
		in_.failed = true
		return 0
	}
	v: u64
	for i in 0 ..< size_of(T) {
		v |= u64(in_.buf[in_.pos + i]) << (8 * uint(i))
	}
	in_.pos += size_of(T)
	return T(v)
}

@(private="file")
get_bytes :: proc "contextless" (in_: ^In, n: u64) -> []u8 {
	if in_.failed || remaining(in_) < n {
		in_.failed = true
		return nil
	}
	p := in_.buf[in_.pos:][:n]
	in_.pos += int(n)
	return p
}

@(private="file")
get_str :: proc "contextless" (in_: ^In) -> string {
	s := string(get_bytes(in_, u64(get(in_, u16))))
	if str.index_byte(s, 0) >= 0 {
		in_.failed = true // 9P strings never hold NUL
	}
	return s
}

@(private="file")
get_qid :: proc "contextless" (in_: ^In) -> (q: Qid) {
	q.type = transmute(Qid_Type)get(in_, u8)
	q.version = get(in_, u32)
	q.path = get(in_, u64)
	return
}

@(private="file")
get_attr :: proc "contextless" (in_: ^In) -> (a: Attr) {
	a.valid = transmute(Getattr_Mask)get(in_, u64)
	a.qid = get_qid(in_)
	a.mode = get(in_, u32)
	a.uid = get(in_, u32)
	a.gid = get(in_, u32)
	rest := [?]^u64 {
		&a.nlink,
		&a.rdev,
		&a.size,
		&a.blksize,
		&a.blocks,
		&a.atime_sec,
		&a.atime_nsec,
		&a.mtime_sec,
		&a.mtime_nsec,
		&a.ctime_sec,
		&a.ctime_nsec,
		&a.btime_sec,
		&a.btime_nsec,
		&a.gen,
		&a.data_version,
	}
	for v in rest {
		v^ = get(in_, u64)
	}
	return
}

@(private="file")
get_setattr :: proc "contextless" (in_: ^In) -> (a: Setattr) {
	a.valid = transmute(Setattr_Mask)get(in_, u32)
	a.mode = get(in_, u32)
	a.uid = get(in_, u32)
	a.gid = get(in_, u32)
	a.size = get(in_, u64)
	a.atime_sec = get(in_, u64)
	a.atime_nsec = get(in_, u64)
	a.mtime_sec = get(in_, u64)
	a.mtime_nsec = get(in_, u64)
	return
}

// Decodes one whole message: buf holds exactly its size[4] bytes. Err_Invalid
// for anything malformed; nothing is half-decoded.
@(require_results)
decode :: proc "contextless" (buf: []u8, m: ^Msg) -> vx.Status {
	m^ = {}
	in_ := In{buf = buf}
	if u64(get(&in_, u32)) != u64(len(buf)) || len(buf) < 7 {
		return .Err_Invalid
	}
	m.type = Type(get(&in_, u8))
	m.tag = get(&in_, u16)
	if !known(m.type) {
		return .Err_Invalid
	}
	for f in MESSAGES[u8(m.type)].fields {
		if in_.failed {
			break
		}
		switch f {
		case .Fid:
			m.fid = get(&in_, Fid)
		case .Newfid:
			m.newfid = get(&in_, Fid)
		case .Afid:
			m.afid = get(&in_, Fid)
		case .Msize:
			m.msize = get(&in_, u32)
		case .Iounit:
			m.iounit = get(&in_, u32)
		case .Perm:
			m.perm = get(&in_, u32)
		case .Count:
			m.count = get(&in_, u32)
		case .Offset:
			m.offset = get(&in_, u64)
		case .Mode:
			m.mode = transmute(Open_Mode)get(&in_, u8)
		case .Oldtag:
			m.oldtag = get(&in_, u16)
		case .Version:
			m.version = get_str(&in_)
		case .Uname:
			m.uname = get_str(&in_)
		case .Aname:
			m.aname = get_str(&in_)
		case .Ename:
			m.ename = get_str(&in_)
		case .Name:
			m.name = get_str(&in_)
		case .Qid:
			m.qid = get_qid(&in_)
		case .Wnames:
			m.nwname = get(&in_, u16)
			if m.nwname > MAXWELEM {
				in_.failed = true
				break
			}
			for &name in m.wname[:m.nwname] {
				name = get_str(&in_)
			}
		case .Wqids:
			m.nwqid = get(&in_, u16)
			if m.nwqid > MAXWELEM {
				in_.failed = true
				break
			}
			for &q in m.wqid[:m.nwqid] {
				q = get_qid(&in_)
			}
		case .Data:
			m.count = get(&in_, u32)
			m.data = get_bytes(&in_, u64(m.count))
		case .Stat:
			m.stat = get_bytes(&in_, u64(get(&in_, u16)))
		case .Name2:
			m.name2 = get_str(&in_)
		case .Gid:
			m.gid = get(&in_, u32)
		case .Mask:
			m.mask = transmute(Getattr_Mask)get(&in_, u64)
		case .Datasync:
			m.datasync = get(&in_, u32)
		case .Attr:
			m.attr = get_attr(&in_)
		case .Setattr:
			m.setattr = get_setattr(&in_)
		case .Locktype:
			m.lock_type = Lock_Type(get(&in_, u8))
		case .Lockflags:
			m.lock_flags = transmute(Lock_Flags)get(&in_, u32)
		case .Start:
			m.start = get(&in_, u64)
		case .Length:
			m.length = get(&in_, u64)
		case .Procid:
			m.proc_id = get(&in_, u32)
		case .Clientid:
			m.client_id = get_str(&in_)
		case .Status:
			m.status = Lock_Status(get(&in_, u8))
		case .Holds:
			m.holds = get(&in_, u32)
		case .Token:
			copy(m.token[:], get_bytes(&in_, TOKEN_SIZE))
		case .Whence:
			m.whence = Whence(get(&in_, u8))
		case .Descflags:
			m.desc_flags = transmute(Desc_Flags)get(&in_, u32)
		case .Prot:
			m.prot = transmute(Prot)get(&in_, u32)
		case .Roffset:
			m.roffset = get(&in_, u64)
		}
	}
	if in_.failed || in_.pos != len(buf) {
		return .Err_Invalid
	}
	return .Ok
}

// --- Stat entries ---

Stat :: struct {
	type:   u16,
	dev:    u32,
	qid:    Qid,
	mode:   u32, // permissions, with DMDIR for a directory
	atime:  u32,
	mtime:  u32,
	length: u64,
	name, uid, gid, muid: string,
}

// Encodes one stat entry, its size[2] first. Returns its length, or 0.
stat_encode :: proc "contextless" (s: ^Stat, buf: []u8) -> int {
	o := str.Buf{buf = buf}
	put(&o, u16(0)) // the size, filled in below
	put(&o, s.type)
	put(&o, s.dev)
	put_qid(&o, s.qid)
	put(&o, s.mode)
	put(&o, s.atime)
	put(&o, s.mtime)
	put(&o, s.length)
	put_str(&o, s.name)
	put_str(&o, s.uid)
	put_str(&o, s.gid)
	put_str(&o, s.muid)
	if o.failed || o.len - 2 > 0xffff {
		return 0
	}
	size := str.Buf{buf = buf[:2]} // the size field, written in place
	put(&size, u16(o.len - 2))
	return o.len
}

// Decodes one stat entry that fills buf exactly, size[2] included.
@(require_results)
stat_decode :: proc "contextless" (buf: []u8, s: ^Stat) -> vx.Status {
	s^ = {}
	in_ := In{buf = buf}
	if u64(get(&in_, u16)) + 2 != u64(len(buf)) {
		return .Err_Invalid
	}
	s.type = get(&in_, u16)
	s.dev = get(&in_, u32)
	s.qid = get_qid(&in_)
	s.mode = get(&in_, u32)
	s.atime = get(&in_, u32)
	s.mtime = get(&in_, u32)
	s.length = get(&in_, u64)
	s.name = get_str(&in_)
	s.uid = get_str(&in_)
	s.gid = get_str(&in_)
	s.muid = get_str(&in_)
	return in_.failed || in_.pos != len(buf) ? .Err_Invalid : .Ok
}

// The stat entries of a directory read, one at a time:
//
//	it := p9.Dir_Entries{buf = buf[:n]}
//	for entry in p9.next_entry(&it) { ... }
//	if it.off != n { ... } // a malformed entry stopped it
//
// Each entry's strings point into buf.
Dir_Entries :: struct {
	buf: []u8,
	off: int, // where the next entry starts
}

next_entry :: proc "contextless" (it: ^Dir_Entries) -> (entry: Stat, ok: bool) {
	if len(it.buf) - it.off < 2 {
		return {}, false
	}
	end := it.off + 2 + (int(it.buf[it.off]) | int(it.buf[it.off + 1]) << 8)
	if end > len(it.buf) || stat_decode(it.buf[it.off:end], &entry) != .Ok {
		return {}, false
	}
	it.off = end
	return entry, true
}

// --- Version negotiation (upstream 02 §3.1) ---

Dialect :: enum u8 {
	Unknown = 0,
	P9_2000, // plain 9P2000; also what a 9P2000.L or .u client gets from a VectraOS server
	P9_2000X, // 9Px: "9P2000.x/1" and its extensions
}

// 9Px's extensions, as words after the dialect: "9P2000.x/1 +dref +map". The
// enum's order gives each one's bit.
Extension :: enum u32 {
	Dref,
	Map,
	Lease,
	Notify,
	Xattr,
	Posix,
}

Extensions :: bit_set[Extension;u32]

@(rodata)
EXTENSION_WORDS := [Extension]string {
	.Dref   = "dref",
	.Map    = "map",
	.Lease  = "lease",
	.Notify = "notify",
	.Xattr  = "xattr",
	.Posix  = "posix",
}

// Reads a version string: its dialect and, for 9Px, the extensions it names.
// Unknown extension words are ignored, so later clients still talk to us.
version_parse :: proc "contextless" (v: string) -> (d: Dialect, ext: Extensions) {
	words := v
	base, _ := str.split_iterator(&words, ' ')
	if base == "9P2000.x/1" {
		for word in str.split_iterator(&words, ' ') {
			if len(word) < 2 || word[0] != '+' {
				continue
			}
			for w, e in EXTENSION_WORDS {
				if word[1:] == w {
					ext += {e}
				}
			}
		}
		return .P9_2000X, ext
	}
	// 9P2000 itself, and any dialect of it (".L", ".u"), are answered with 9P2000.
	if str.has_prefix(base, "9P2000") {
		return .P9_2000, {}
	}
	return .Unknown, {}
}

// Writes a version string for a dialect and its extensions into buf (96
// bytes always suffice). Returns its length, or 0 if it does not fit.
version_format :: proc "contextless" (d: Dialect, ext: Extensions, buf: []u8) -> int {
	o := str.Buf{buf = buf}
	switch d {
	case .P9_2000X:
		str.write_string(&o, "9P2000.x/1")
		for w, e in EXTENSION_WORDS {
			if e in ext {
				str.write_string(&o, " +")
				str.write_string(&o, w)
			}
		}
	case .P9_2000:
		str.write_string(&o, "9P2000")
	case .Unknown:
		str.write_string(&o, "unknown")
	}
	return o.failed ? 0 : o.len
}

// --- Errors ---
//
// 9P carries errors as text. A server turns a Status into Plan 9's wording
// where Plan 9 has one, and a client turns the text back; text it does not
// know becomes Err_Invalid.

@(private="file")
Error_Text :: struct {
	status: vx.Status,
	text:   string,
}

@(private="file", rodata)
ERRORS := [?]Error_Text {
	{.Err_Not_Found, "file does not exist"},
	{.Err_Exists, "file already exists"},
	{.Err_Access, "permission denied"},
	{.Err_Bad_Handle, "unknown fid"},
	{.Err_Bad_State, "fid already in use"},
	{.Err_Range, "offset out of range"},
	{.Err_No_Memory, "out of memory"},
	{.Err_Unsupported, "operation not supported"},
	{.Err_Too_Small, "message too large for msize"},
	{.Err_Refused, "connection refused"},
	{.Err_Timed_Out, "connection timed out"},
	{.Err_Peer_Closed, "i/o on hungup channel"},
	{.Err_Interrupted, "interrupted"},
	{.Err_No_Child, "no living children"},
	{.Err_Io, "i/o error"},
	{.Err_No_Space, "file system full"},
	{.Err_Invalid, "bad message"},
}

// Other servers' wordings, understood but never sent: Unix's strerror(), as
// u9fs passes it on, and u9fs's own messages (M3's interoperability test).
@(private="file", rodata)
ERRORS_HEARD := [?]Error_Text {
	{.Err_Not_Found, "no such file or directory"},
	{.Err_Not_Found, "not a directory"},
	{.Err_Exists, "file exists"},
	{.Err_Exists, "file or directory already exists"},
	{.Err_Access, "read-only file system"},
	{.Err_Access, "is a directory"},
	{.Err_Access, "operation not permitted"},
	{.Err_Bad_Handle, "fid unknown or out of range"},
	{.Err_No_Space, "no space left on device"},
}

error_text :: proc "contextless" (st: vx.Status) -> string {
	for e in ERRORS {
		if e.status == st {
			return e.text
		}
	}
	return "i/o error"
}

// Whether text is want (all lower case) but for the case of ASCII letters.
@(private="file")
equal_nocase :: proc "contextless" (text, want: string) -> bool {
	if len(text) != len(want) {
		return false
	}
	for i in 0 ..< len(text) {
		c := text[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		if c != want[i] {
			return false
		}
	}
	return true
}

// The Status an Rerror's text stands for: the whole text, in any case, as
// this server words it or as another is known to.
error_status :: proc "contextless" (text: string) -> vx.Status {
	for e in ERRORS {
		if equal_nocase(text, e.text) {
			return e.status
		}
	}
	for e in ERRORS_HEARD {
		if equal_nocase(text, e.text) {
			return e.status
		}
	}
	return .Err_Invalid
}
