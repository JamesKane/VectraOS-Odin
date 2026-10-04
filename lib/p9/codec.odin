// 9P2000 and 9Px (upstream 02 §3): the codec for messages, stat entries and
// 9Px version strings; the server framework (server.odin), which keeps a
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

MAXWELEM :: 16 // names in one walk
NOTAG :: u16(0xffff) // Tversion's tag
NOFID :: u32(0xffff_ffff) // no fid (Tattach's afid without auth)
IOHDRSZ :: 24 // the Rread and Twrite overhead: a read or write carries msize - 24 bytes
MIN_MSIZE :: 256
MAX_MSIZE :: 1 << 20

// qid.type, and the top byte of a stat's mode.
QTDIR :: u8(0x80)
QTAPPEND :: u8(0x40)
QTEXCL :: u8(0x20)
QTAUTH :: u8(0x08)
QTFILE :: u8(0x00)

DMDIR :: u32(0x8000_0000) // a stat's mode: a directory

// Topen and Tcreate modes.
OREAD :: u8(0)
OWRITE :: u8(1)
ORDWR :: u8(2)
OEXEC :: u8(3)
OTRUNC :: u8(0x10)
ORCLOSE :: u8(0x40)

Qid :: struct {
	type:    u8,
	version: u32,
	path:    u64,
}

Msg :: struct {
	type:   Type,
	tag:    u16,
	fid:    u32,
	newfid: u32,
	afid:   u32,
	msize:  u32,
	iounit: u32,
	perm:   u32,
	count:  u32,
	offset: u64,
	mode:   u8,
	oldtag: u16,
	version, uname, aname, ename, name: string,
	qid:    Qid,
	nwname: u16,
	nwqid:  u16,
	wname:  [MAXWELEM]string,
	wqid:   [MAXWELEM]Qid,
	data:   []u8, // Rread, Twrite; its length is count
	stat:   []u8, // Rstat, Twstat: one stat entry, its own size[2] included
}

// --- Encoding ---

@(private="file")
Out :: struct {
	buf:    []u8,
	len:    int,
	failed: bool,
}

@(private="file")
put :: proc "contextless" (o: ^Out, v: u64, bytes: int) {
	if o.failed || len(o.buf) - o.len < bytes {
		o.failed = true
		return
	}
	for i in 0 ..< bytes {
		o.buf[o.len] = u8(v >> (8 * uint(i)))
		o.len += 1
	}
}

@(private="file")
put_bytes :: proc "contextless" (o: ^Out, p: []u8) {
	if o.failed || len(o.buf) - o.len < len(p) {
		o.failed = true
		return
	}
	// Rread's data may already sit where it is going (server.odin reads it
	// there), and copy is a memmove, so that is a no-op, not a corruption.
	copy(o.buf[o.len:], p)
	o.len += len(p)
}

@(private="file")
put_str :: proc "contextless" (o: ^Out, s: string) {
	if len(s) > 0xffff {
		o.failed = true
	}
	put(o, u64(len(s)), 2)
	put_bytes(o, transmute([]u8)s)
}

@(private="file")
put_qid :: proc "contextless" (o: ^Out, q: Qid) {
	put(o, u64(q.type), 1)
	put(o, u64(q.version), 4)
	put(o, q.path, 8)
}

// Encodes m into buf. Returns its length, or 0 if it does not fit or is not a
// message 9P2000 has.
encode :: proc "contextless" (m: ^Msg, buf: []u8) -> int {
	if !known(m.type) {
		return 0
	}
	o := Out{buf = buf}
	put(&o, 0, 4) // the size, filled in below
	put(&o, u64(m.type), 1)
	put(&o, u64(m.tag), 2)
	for f in MESSAGES[u8(m.type)].fields {
		switch f {
		case .Fid:
			put(&o, u64(m.fid), 4)
		case .Newfid:
			put(&o, u64(m.newfid), 4)
		case .Afid:
			put(&o, u64(m.afid), 4)
		case .Msize:
			put(&o, u64(m.msize), 4)
		case .Iounit:
			put(&o, u64(m.iounit), 4)
		case .Perm:
			put(&o, u64(m.perm), 4)
		case .Count:
			put(&o, u64(m.count), 4)
		case .Offset:
			put(&o, m.offset, 8)
		case .Mode:
			put(&o, u64(m.mode), 1)
		case .Oldtag:
			put(&o, u64(m.oldtag), 2)
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
			}
			put(&o, u64(m.nwname), 2)
			for i in 0 ..< int(m.nwname) {
				if o.failed {
					break
				}
				put_str(&o, m.wname[i])
			}
		case .Wqids:
			if m.nwqid > MAXWELEM {
				o.failed = true
			}
			put(&o, u64(m.nwqid), 2)
			for i in 0 ..< int(m.nwqid) {
				if o.failed {
					break
				}
				put_qid(&o, m.wqid[i])
			}
		case .Data:
			if u64(len(m.data)) > u64(max(u32)) {
				o.failed = true
			}
			put(&o, u64(len(m.data)), 4)
			put_bytes(&o, m.data)
		case .Stat:
			if len(m.stat) > 0xffff {
				o.failed = true
			}
			put(&o, u64(len(m.stat)), 2)
			put_bytes(&o, m.stat)
		}
	}
	if o.failed || u64(o.len) > u64(max(u32)) {
		return 0
	}
	for i in 0 ..< 4 {
		buf[i] = u8(o.len >> (8 * uint(i)))
	}
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

@(private="file")
get :: proc "contextless" (in_: ^In, bytes: int) -> u64 {
	if in_.failed || remaining(in_) < u64(bytes) {
		in_.failed = true
		return 0
	}
	v: u64
	for i in 0 ..< bytes {
		v |= u64(in_.buf[in_.pos + i]) << (8 * uint(i))
	}
	in_.pos += bytes
	return v
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
	p := get_bytes(in_, get(in_, 2))
	for c in p {
		if c == 0 {
			in_.failed = true // 9P strings never hold NUL
		}
	}
	return string(p)
}

@(private="file")
get_qid :: proc "contextless" (in_: ^In) -> (q: Qid) {
	q.type = u8(get(in_, 1))
	q.version = u32(get(in_, 4))
	q.path = get(in_, 8)
	return
}

// Decodes one whole message: buf holds exactly its size[4] bytes. Err_Invalid
// for anything malformed; nothing is half-decoded.
@(require_results)
decode :: proc "contextless" (buf: []u8, m: ^Msg) -> vx.Status {
	m^ = {}
	in_ := In{buf = buf}
	if get(&in_, 4) != u64(len(buf)) || len(buf) < 7 {
		return .Err_Invalid
	}
	m.type = Type(get(&in_, 1))
	m.tag = u16(get(&in_, 2))
	if !known(m.type) {
		return .Err_Invalid
	}
	for f in MESSAGES[u8(m.type)].fields {
		if in_.failed {
			break
		}
		switch f {
		case .Fid:
			m.fid = u32(get(&in_, 4))
		case .Newfid:
			m.newfid = u32(get(&in_, 4))
		case .Afid:
			m.afid = u32(get(&in_, 4))
		case .Msize:
			m.msize = u32(get(&in_, 4))
		case .Iounit:
			m.iounit = u32(get(&in_, 4))
		case .Perm:
			m.perm = u32(get(&in_, 4))
		case .Count:
			m.count = u32(get(&in_, 4))
		case .Offset:
			m.offset = get(&in_, 8)
		case .Mode:
			m.mode = u8(get(&in_, 1))
		case .Oldtag:
			m.oldtag = u16(get(&in_, 2))
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
			m.nwname = u16(get(&in_, 2))
			if m.nwname > MAXWELEM {
				in_.failed = true
			}
			for i in 0 ..< int(m.nwname) {
				if in_.failed {
					break
				}
				m.wname[i] = get_str(&in_)
			}
		case .Wqids:
			m.nwqid = u16(get(&in_, 2))
			if m.nwqid > MAXWELEM {
				in_.failed = true
			}
			for i in 0 ..< int(m.nwqid) {
				if in_.failed {
					break
				}
				m.wqid[i] = get_qid(&in_)
			}
		case .Data:
			m.count = u32(get(&in_, 4))
			m.data = get_bytes(&in_, u64(m.count))
		case .Stat:
			m.stat = get_bytes(&in_, get(&in_, 2))
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
	o := Out{buf = buf}
	put(&o, 0, 2)
	put(&o, u64(s.type), 2)
	put(&o, u64(s.dev), 4)
	put_qid(&o, s.qid)
	put(&o, u64(s.mode), 4)
	put(&o, u64(s.atime), 4)
	put(&o, u64(s.mtime), 4)
	put(&o, s.length, 8)
	put_str(&o, s.name)
	put_str(&o, s.uid)
	put_str(&o, s.gid)
	put_str(&o, s.muid)
	if o.failed || o.len - 2 > 0xffff {
		return 0
	}
	buf[0] = u8(o.len - 2)
	buf[1] = u8((o.len - 2) >> 8)
	return o.len
}

// Decodes one stat entry that fills buf exactly, size[2] included.
@(require_results)
stat_decode :: proc "contextless" (buf: []u8, s: ^Stat) -> vx.Status {
	s^ = {}
	in_ := In{buf = buf}
	size, overflow := intrinsics.overflow_add(get(&in_, 2), 2)
	if overflow || size != u64(len(buf)) {
		return .Err_Invalid
	}
	s.type = u16(get(&in_, 2))
	s.dev = u32(get(&in_, 4))
	s.qid = get_qid(&in_)
	s.mode = u32(get(&in_, 4))
	s.atime = u32(get(&in_, 4))
	s.mtime = u32(get(&in_, 4))
	s.length = get(&in_, 8)
	s.name = get_str(&in_)
	s.uid = get_str(&in_)
	s.gid = get_str(&in_)
	s.muid = get_str(&in_)
	return in_.failed || in_.pos != len(buf) ? .Err_Invalid : .Ok
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
	i := 0
	for i < len(v) && v[i] != ' ' {
		i += 1
	}
	base := v[:i]
	if base == "9P2000.x/1" {
		for i < len(v) {
			for i < len(v) && v[i] == ' ' {
				i += 1
			}
			start := i
			for i < len(v) && v[i] != ' ' {
				i += 1
			}
			word := v[start:i]
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
	if len(base) >= 6 && base[:6] == "9P2000" {
		return .P9_2000, {}
	}
	return .Unknown, {}
}

// Writes a version string for a dialect and its extensions into buf (96
// bytes always suffice). Returns its length, or 0 if it does not fit.
version_format :: proc "contextless" (d: Dialect, ext: Extensions, buf: []u8) -> int {
	o := Out{buf = buf}
	switch d {
	case .P9_2000X:
		put_bytes(&o, transmute([]u8)string("9P2000.x/1"))
		for w, e in EXTENSION_WORDS {
			if e in ext {
				put_bytes(&o, transmute([]u8)string(" +"))
				put_bytes(&o, transmute([]u8)w)
			}
		}
	case .P9_2000:
		put_bytes(&o, transmute([]u8)string("9P2000"))
	case .Unknown:
		put_bytes(&o, transmute([]u8)string("unknown"))
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
	{.Err_Invalid, "bad message"},
}

error_text :: proc "contextless" (st: vx.Status) -> string {
	for e in ERRORS {
		if e.status == st {
			return e.text
		}
	}
	return "i/o error"
}

error_status :: proc "contextless" (text: string) -> vx.Status {
	for e in ERRORS {
		if e.text == text {
			return e.status
		}
	}
	return .Err_Invalid
}
