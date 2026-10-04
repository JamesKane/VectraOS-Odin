// ISO 9660 with Rock Ridge and Joliet, read-only (upstream's docs/11 §11,
// its M5 step 8c), for isofs: after 9front's 9660srv, as upstream's
// lib/vx-iso reimplements it. Pure code over one callback, a device that
// reads 2048-byte sectors, so the host's tests share it with isofs.
//
// A volume is read one of three ways, the first it has unless told not to:
//  - Rock Ridge (RRIP 1991A or IEEE 1282, over SUSP, found by the root's SP
//    and ER): the primary tree, with real names (NM), POSIX modes (PX),
//    times (TF), symbolic links (SL), continuation areas (CE), and deep
//    directories relocated (CL, PL, RE). Names are matched exactly.
//  - Joliet (a supplementary descriptor with escape %/@, %/C or %/E): its
//    own tree, names in UCS-2 (read as UTF-16) to UTF-8. Matched ignoring
//    ASCII case.
//  - ISO 9660 alone: the primary tree's names lower-cased, without ";1" or
//    a trailing dot, as 9660srv shows them. Matched ignoring ASCII case.
//
// A node is a directory record's place: the extent (LBA) of the directory
// it is in and its offset there. The root has no record of its own: it is
// ROOT. A directory's parent is found through its ".." record, then the
// record in the grandparent naming its extent.
//
// The image is hostile: every record, entry and continuation is checked
// against the bytes that hold it before it is read, and every offset into a
// directory is counted in 64 bits, so no extent's length can wrap it.
package iso

import "base:intrinsics"
import vx "abi:vx"

SECTOR :: 2048
CACHE :: 16 // sectors kept
NAME_CAP :: 255 * 3 // a name's bytes: 255 UTF-16 units' worth, as upstream's buffer holds
LINK_CAP :: 1023 // a symbolic link's target's bytes, as upstream's buffer holds

// A directory record's place; ROOT for the root, which has none.
Node :: distinct u64
ROOT :: Node(1)

// The device: reads len(buf) bytes from off, both multiples of SECTOR.
Dev :: struct {
	ctx:  rawptr,
	read: proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool,
}

// The ways a volume is read; a mount's avoid is a set of them (Plain cannot
// be avoided). As upstream's mask, bit i is the kind with value i.
Kind :: enum u32 {
	Plain  = 0,
	Joliet = 1,
	Rock   = 2,
}
Kinds :: bit_set[Kind;u32]

// ISO 9660's both-endian fields: little-endian, then big-endian. The
// little-endian half is the one read, as upstream reads it.
Both16 :: struct #packed {
	le: u16le,
	be: u16be,
}
#assert(size_of(Both16) == 4)

Both32 :: struct #packed {
	le: u32le,
	be: u32be,
}
#assert(size_of(Both32) == 8)

// A directory record's flags (ECMA-119 9.1.6).
Record_Flag :: enum u8 {
	Hidden       = 0, // "existence"
	Directory    = 1,
	Associated   = 2,
	Record       = 3,
	Protection   = 4,
	Multi_Extent = 7,
}

// A directory record (ECMA-119 9.1), up to its name, which follows it; then
// padding to an even offset, and the system use area (SUSP).
Dir_Record :: struct #packed {
	length:      u8,
	ext_length:  u8,
	extent:      Both32,
	size:        Both32,
	date:        [7]u8, // since 1900; month, day, hour, minute, second; zone in quarter hours
	flags:       bit_set[Record_Flag;u8],
	unit_size:   u8,
	gap_size:    u8,
	volume_seq:  Both16,
	name_length: u8,
}
#assert(size_of(Dir_Record) == 33)
#assert(offset_of(Dir_Record, extent) == 2)
#assert(offset_of(Dir_Record, size) == 10)
#assert(offset_of(Dir_Record, date) == 18)
#assert(offset_of(Dir_Record, flags) == 25)
#assert(offset_of(Dir_Record, name_length) == 32)

// A volume descriptor (ECMA-119 8.4, and the supplementary one of 8.5), up
// to and including its root directory's record.
Volume_Descriptor :: struct #packed {
	type:            u8, // 1 primary, 2 supplementary, 255 the set's terminator
	id:              [5]u8, // "CD001"
	version:         u8,
	flags:           u8,
	system_id:       [32]u8,
	volume_id:       [32]u8,
	_:               [8]u8,
	space_size:      Both32, // sectors
	escapes:         [32]u8, // Joliet's %/@, %/C or %/E
	set_size:        Both16,
	sequence_number: Both16,
	block_size:      Both16,
	path_table_size: Both32,
	path_l:          [2]u32le,
	path_m:          [2]u32be,
	root:            Dir_Record,
	root_name:       u8,
}
#assert(size_of(Volume_Descriptor) == 190)
#assert(offset_of(Volume_Descriptor, volume_id) == 40)
#assert(offset_of(Volume_Descriptor, space_size) == 80)
#assert(offset_of(Volume_Descriptor, escapes) == 88)
#assert(offset_of(Volume_Descriptor, block_size) == 128)
#assert(offset_of(Volume_Descriptor, root) == 156)

// A SUSP entry's head (SUSP 1.12 §4.1): its signature, length and version.
Su_Head :: struct #packed {
	sig:     [2]u8,
	length:  u8,
	version: u8,
}
#assert(size_of(Su_Head) == 4)

// CE: where the system use goes on.
Su_Ce :: struct #packed {
	head:   Su_Head,
	block:  Both32,
	offset: Both32,
	length: Both32,
}
#assert(size_of(Su_Ce) == 28)

// PX: POSIX attributes (RRIP §4.1.1); its serial number, in 1282, after.
Su_Px :: struct #packed {
	head:  Su_Head,
	mode:  Both32,
	links: Both32,
	uid:   Both32,
	gid:   Both32,
}
#assert(size_of(Su_Px) == 36)

// CL and PL: a relocated directory's child and parent (RRIP §4.1.5).
Su_Location :: struct #packed {
	head:  Su_Head,
	block: Both32,
}
#assert(size_of(Su_Location) == 12)

@(private="file")
Cache_Slot :: struct {
	sector, last: u64,
	valid:        bool,
	data:         [SECTOR]u8,
}

// A record of a directory: its bytes, copied (the cache may move).
@(private)
Rec :: struct {
	b:   [256]u8,
	len: u32,
}

// What a record's Rock Ridge entries say.
@(private)
Rock :: struct {
	name:                                                           [dynamic; NAME_CAP]u8,
	have_name, name_done, have_mode, have_time, relocated, link, link_done: bool,
	mode, child_lba, parent_lba:                                     u32, // PX's; CL's; PL's
	mtime:                                                          i64,
	target:                                                         [dynamic; LINK_CAP]u8,
	target_sep:                                                     bool, // a component was added: the next needs a '/'
}

// A mounted volume. Big (its sector cache): keep one per volume, in static
// storage or the caller's, and never copy it.
Vol :: struct {
	dev:       Dev,
	kind:      Kind,
	root_lba:  u32, // the tree read's root directory
	root_len:  u32,
	susp_skip: u32, // SP's: bytes to skip in each record's system use
	sectors:   u64, // the volume's, as its primary descriptor says
	label_buf: [32]u8, // the primary descriptor's volume identifier, as it is
	label_len: int, // with trailing spaces cut
	cache:     [CACHE]Cache_Slot,
	tick:      u64,
	area:      [SECTOR]u8, // the continuation area being read
	rock:      Rock, // what decode gathers
}

// The volume's label: its identifier, trailing spaces cut, up to any NUL.
label :: proc "contextless" (v: ^Vol) -> string {
	return before_nul(v.label_buf[:v.label_len])
}

Entry :: struct {
	node:   Node,
	lba:    u32, // the extent: the file's bytes, or the directory's records
	size:   u32,
	dir:    bool,
	link:   bool,
	mode:   u32, // POSIX permissions (Rock Ridge's PX), else 0o444, or 0o555 for a directory
	mtime:  i64, // seconds since 1970, UTC
	name:   [dynamic; NAME_CAP]u8, // UTF-8
	target: [dynamic; LINK_CAP]u8, // a symbolic link's, as stored
}

entry_name :: proc "contextless" (e: ^Entry) -> string {
	return string(e.name[:])
}

// A symbolic link's target, up to any NUL in it, as upstream's C string is.
entry_target :: proc "contextless" (e: ^Entry) -> string {
	return before_nul(e.target[:])
}

@(private="file")
before_nul :: proc "contextless" (b: []u8) -> string {
	for c, i in b {
		if c == 0 {
			return string(b[:i])
		}
	}
	return string(b)
}

@(private="file")
load :: proc "contextless" ($T: typeid, b: []u8) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))
}

// A sector, through the cache: nil if the device fails or it is past the volume.
@(private="file")
sector :: proc "contextless" (v: ^Vol, s: u64) -> []u8 {
	victim := 0
	for &c, i in v.cache {
		if c.valid && c.sector == s {
			v.tick += 1
			c.last = v.tick
			return c.data[:]
		}
		if !c.valid || c.last < v.cache[victim].last {
			victim = i
		}
	}
	c := &v.cache[victim]
	if v.sectors != 0 && s >= v.sectors {
		return nil
	}
	off, overflow := intrinsics.overflow_mul(s, SECTOR)
	if overflow || !v.dev.read(v.dev.ctx, off, c.data[:]) {
		c.valid = false // the read may have left anything there
		return nil
	}
	v.tick += 1
	c.sector, c.valid, c.last = s, true, v.tick
	return c.data[:]
}

// --- Records ---

// The record at offset off of directory [lba, lba + len): Err_Not_Found past
// the end; next is where the one after it is (records never straddle a
// sector: a zero length byte means the rest of the sector is padding).
@(private, require_results)
record_at :: proc "contextless" (v: ^Vol, lba: u32, length: u64, off: u64, r: ^Rec) -> (next: u64, st: vx.Status) {
	off := off
	for off < length {
		s := sector(v, u64(lba) + off / SECTOR)
		if s == nil {
			return 0, .Err_Io
		}
		at := off % SECTOR
		n := u64(s[at])
		if n == 0 { // the sector's padding
			off = (off / SECTOR + 1) * SECTOR
			continue
		}
		if n < 34 || at + n > SECTOR || u64(s[at + 32]) + 33 > n {
			return 0, .Err_Io
		}
		r.len = u32(copy(r.b[:], s[at:at + n]))
		return off + n, .Ok
	}
	return 0, .Err_Not_Found
}

@(private="file")
header :: proc "contextless" (r: ^Rec) -> Dir_Record {
	return load(Dir_Record, r.b[:])
}

// "." or "..".
@(private="file")
is_dot :: proc "contextless" (r: ^Rec) -> bool {
	return r.b[32] == 1 && r.b[33] <= 1
}

// --- System use (SUSP and Rock Ridge) ---

// The SUSP entries of a record, following continuation areas (CE), which
// are not themselves returned. su_next gives each in turn, until the
// terminator (ST) or the end; status then says whether the chain was sound.
@(private)
Su_Iter :: struct {
	v:      ^Vol,
	p:      []u8, // the record's bytes, or the continuation area's
	at:     u32,
	end:    u32,
	hops:   int,
	ce:     Su_Ce, // the last CE seen in the current area; length 0 for none
	done:   bool,
	status: vx.Status,
}

@(private)
su_begin :: proc "contextless" (v: ^Vol, r: ^Rec, skip: u32) -> Su_Iter {
	nlen := u32(r.b[32])
	return Su_Iter{v = v, p = r.b[:r.len], at = 33 + nlen + u32(nlen & 1 == 0) + skip, end = r.len}
}

@(private)
su_next :: proc "contextless" (it: ^Su_Iter) -> (entry: []u8, ok: bool) {
	for !it.done {
		for it.at + 4 <= it.end {
			e := it.p[it.at:it.end]
			n := u32(e[2])
			if n < 4 || n > it.end - it.at {
				break
			}
			e = e[:n]
			if e[0] == 'S' && e[1] == 'T' { // the terminator
				it.done = true
				return nil, false
			}
			it.at += n
			if e[0] == 'C' && e[1] == 'E' && n >= size_of(Su_Ce) {
				it.ce = load(Su_Ce, e)
				continue
			}
			return e, true
		}
		// The area is done: go on to the continuation, if one was named.
		ce := it.ce
		it.ce = {}
		if ce.length.le == 0 {
			it.done = true
			return nil, false
		}
		off, length := u32(ce.offset.le), u32(ce.length.le)
		s: []u8
		if off < SECTOR && length <= SECTOR - off {
			s = sector(it.v, u64(ce.block.le))
		}
		if s == nil {
			it.done, it.status = true, .Err_Io
			return nil, false
		}
		copy(it.v.area[:], s)
		it.p, it.at, it.end = it.v.area[:], off, off + length
		it.hops += 1
		if it.hops == 16 { // a chain of continuations that does not end
			it.done, it.status = true, .Err_Io
			return nil, false
		}
	}
	return nil, false
}

// A 7-byte record date (and Rock Ridge's short form) as seconds since 1970, UTC.
@(private)
time7 :: proc "contextless" (date: []u8) -> i64 {
	d := date[:7]
	y := 1900 + i64(d[0])
	m, day := u32(d[1]), u32(d[2])
	if m < 1 || m > 12 || day < 1 || day > 31 {
		return 0
	}
	if m <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	yoe := u32(y - era * 400)
	doy := (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + day - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	t := (era * 146097 + i64(doe) - 719468) * 86400 + i64(d[3]) * 3600 + i64(d[4]) * 60 + i64(d[5])
	return t - i64(i8(d[6])) * 15 * 60 // the offset from GMT, in quarter hours
}

// Adds s to the target if all of it fits, as upstream does.
@(private="file")
target_put :: proc "contextless" (rr: ^Rock, s: []u8) {
	if len(rr.target) + len(s) < LINK_CAP + 1 {
		append(&rr.target, ..s)
	}
}

@(private="file")
rock_entry :: proc "contextless" (rr: ^Rock, e: []u8) {
	n := len(e)
	switch {
	case e[0] == 'P' && e[1] == 'X' && n >= size_of(Su_Px):
		rr.mode, rr.have_mode = u32(load(Su_Px, e).mode.le), true
	case e[0] == 'N' && e[1] == 'M' && n >= 5 && !rr.name_done:
		if e[4] & 0x06 != 0 { // CURRENT or PARENT: "." or ".."
			return
		}
		part := e[5:]
		if len(rr.name) + len(part) >= NAME_CAP + 1 {
			part = part[:NAME_CAP - len(rr.name)]
		}
		append(&rr.name, ..part)
		rr.have_name = true
		rr.name_done = e[4] & 0x01 == 0 // CONTINUE
	case e[0] == 'T' && e[1] == 'F' && n >= 5:
		flags := e[4]
		size := flags & 0x80 != 0 ? 17 : 7
		at := 5
		for bit in u8(0) ..< 7 {
			if flags & (1 << bit) == 0 {
				continue
			}
			if at + size > n {
				break
			}
			if bit == 1 && size == 7 { // modification
				rr.mtime, rr.have_time = time7(e[at:]), true
			}
			at += size
		}
	case e[0] == 'S' && e[1] == 'L' && n >= 5 && !rr.link_done:
		rr.link = true
		for at := 5; at + 2 <= n; {
			flags, cn := e[at], int(e[at + 1])
			if at + 2 + cn > n {
				break
			}
			if rr.target_sep {
				target_put(rr, {'/'})
			}
			switch {
			case flags & 0x08 != 0: // ROOT
				target_put(rr, {'/'})
				rr.target_sep = false
			case flags & 0x02 != 0: // CURRENT
				target_put(rr, {'.'})
				rr.target_sep = true
			case flags & 0x04 != 0: // PARENT
				target_put(rr, {'.', '.'})
				rr.target_sep = true
			case:
				target_put(rr, e[at + 2:at + 2 + cn])
				rr.target_sep = flags & 0x01 == 0 // CONTINUE: the same component goes on
			}
			at += 2 + cn
		}
		rr.link_done = e[4] & 0x01 == 0
	case e[0] == 'C' && e[1] == 'L' && n >= size_of(Su_Location):
		rr.child_lba = u32(load(Su_Location, e).block.le)
	case e[0] == 'P' && e[1] == 'L' && n >= size_of(Su_Location):
		rr.parent_lba = u32(load(Su_Location, e).block.le)
	case e[0] == 'R' && e[1] == 'E':
		rr.relocated = true
	}
}

// --- Names ---

@(private="file")
put_utf8 :: proc "contextless" (out: ^[dynamic; NAME_CAP]u8, c: u32) {
	if len(out) + 4 >= NAME_CAP + 1 {
		return
	}
	switch {
	case c < 0x80:
		append(out, u8(c))
	case c < 0x800:
		append(out, u8(0xc0 | c >> 6), u8(0x80 | c & 0x3f))
	case c < 0x1_0000:
		append(out, u8(0xe0 | c >> 12), u8(0x80 | c >> 6 & 0x3f), u8(0x80 | c & 0x3f))
	case:
		append(out, u8(0xf0 | c >> 18), u8(0x80 | c >> 12 & 0x3f), u8(0x80 | c >> 6 & 0x3f), u8(0x80 | c & 0x3f))
	}
}

// A record's identifier as a name: Joliet's UTF-16BE, or ISO 9660's
// d-characters lower-cased; ";N" and a trailing dot dropped from a file's.
@(private="file")
plain_name :: proc "contextless" (r: ^Rec, joliet: bool, out: ^[dynamic; NAME_CAP]u8) {
	id := r.b[33:][:r.b[32]]
	clear(out)
	if joliet {
		for i := 0; i + 1 < len(id); i += 2 {
			c := u32(id[i]) << 8 | u32(id[i + 1])
			if c >= 0xd800 && c < 0xdc00 && i + 3 < len(id) {
				lo := u32(id[i + 2]) << 8 | u32(id[i + 3])
				if lo >= 0xdc00 && lo < 0xe000 {
					c = 0x1_0000 + ((c - 0xd800) << 10) + (lo - 0xdc00)
					i += 2
				} else {
					c = 0xfffd
				}
			} else if c >= 0xd800 && c < 0xe000 {
				c = 0xfffd
			}
			if c == '/' || c == 0 {
				c = 0xfffd
			}
			put_utf8(out, c)
		}
	} else {
		for c in id {
			c := c
			if c >= 0x80 || c == '/' || c == 0 {
				c = '_'
			}
			append(out, c >= 'A' && c <= 'Z' ? c + 32 : c)
		}
	}
	if .Directory not_in header(r).flags { // a file: NAME.EXT;1
		for i := len(out) - 1; i >= 0; i -= 1 {
			if out[i] == ';' {
				resize(out, i)
				break
			}
		}
		if len(out) > 1 && out[len(out) - 1] == '.' {
			resize(out, len(out) - 1)
		}
	}
}

@(private)
node_of :: proc "contextless" (dir_lba: u32, off: u64) -> Node {
	return Node(1 << 62 | u64(dir_lba) << 24 | off)
}

@(private)
node_dir :: proc "contextless" (n: Node) -> u32 {
	return u32(u64(n) >> 24)
}

@(private)
node_off :: proc "contextless" (n: Node) -> u64 {
	return u64(n) & 0xff_ffff
}

// An entry from its record, found at off in directory dir_lba.
// Err_Not_Found for one Rock Ridge hides (a relocated directory, RE, seen
// where it was moved to).
@(private="file", require_results)
decode :: proc "contextless" (v: ^Vol, r: ^Rec, dir_lba: u32, off: u64, e: ^Entry) -> vx.Status {
	h := header(r)
	e^ = Entry {
		node  = node_of(dir_lba, off),
		lba   = u32(h.extent.le),
		size  = u32(h.size.le),
		dir   = .Directory in h.flags,
		mtime = time7(h.date[:]),
	}
	e.mode = e.dir ? 0o555 : 0o444
	if v.kind != .Rock {
		plain_name(r, v.kind == .Joliet, &e.name)
		return .Ok
	}
	rr := &v.rock
	rr^ = {}
	it := su_begin(v, r, v.susp_skip)
	for entry in su_next(&it) {
		rock_entry(rr, entry)
	}
	if it.status != .Ok {
		return it.status
	}
	if rr.relocated {
		return .Err_Not_Found
	}
	if rr.child_lba != 0 { // a directory moved elsewhere: it is here, and its records there
		e.dir, e.lba = true, rr.child_lba
		dot: Rec
		if _, st := record_at(v, rr.child_lba, SECTOR, 0, &dot); st != .Ok {
			return .Err_Io
		}
		e.size = u32(header(&dot).size.le)
	}
	if rr.have_mode {
		e.mode = rr.mode & 0o7777
		switch rr.mode & 0o170000 {
		case 0o040000:
			e.dir = true
		case 0o120000:
			e.link = true
		}
	}
	if rr.have_time {
		e.mtime = rr.mtime
	}
	if rr.have_name {
		for c in rr.name {
			append(&e.name, c == '/' || c == 0 ? '_' : c)
		}
	} else {
		plain_name(r, false, &e.name)
	}
	if rr.link {
		append(&e.target, ..rr.target[:])
		e.link = true
	}
	return .Ok
}

// --- Mounting ---

// Whether a SUSP entry says Rock Ridge: an ER naming RRIP, or RRIP 1.09's
// RR, which some writers still put.
@(private="file")
names_rock :: proc "contextless" (e: []u8) -> bool {
	if e[0] == 'E' && e[1] == 'R' && len(e) >= 8 {
		idl := int(e[4])
		if 8 + idl <= len(e) {
			id := string(e[8:][:idl])
			if id == "RRIP_1991A" || id == "IEEE_P1282" || id == "IEEE_1282" {
				return true
			}
		}
	}
	return e[0] == 'R' && e[1] == 'R'
}

// The volume on dev, read the first way it has of those not in avoid
// (Plain cannot be avoided). Err_Invalid if it is not ISO 9660.
@(require_results)
mount :: proc "contextless" (v: ^Vol, dev: Dev, avoid: Kinds) -> vx.Status {
	v^ = {}
	v.dev = dev
	pvd_lba, pvd_len, joliet_lba, joliet_len: u32
	for s in u64(16) ..< 16 + 64 {
		b := sector(v, s)
		if b == nil {
			return .Err_Io
		}
		d := load(Volume_Descriptor, b)
		if string(d.id[:]) != "CD001" || d.version != 1 {
			return pvd_lba != 0 ? .Err_Io : .Err_Invalid
		}
		if d.type == 255 {
			break
		}
		if d.type == 1 && pvd_lba == 0 {
			if d.block_size.le != SECTOR || d.root.length < 34 {
				return .Err_Unsupported // another block size
			}
			pvd_lba, pvd_len, v.sectors = u32(d.root.extent.le), u32(d.root.size.le), u64(d.space_size.le)
			v.label_buf = d.volume_id
			v.label_len = len(v.label_buf)
			for v.label_len > 0 && v.label_buf[v.label_len - 1] == ' ' {
				v.label_len -= 1
			}
		}
		if d.type == 2 && d.escapes[0] == '%' && d.escapes[1] == '/' && (d.escapes[2] == '@' || d.escapes[2] == 'C' || d.escapes[2] == 'E') && joliet_lba == 0 {
			joliet_lba, joliet_len = u32(d.root.extent.le), u32(d.root.size.le)
		}
	}
	if pvd_lba == 0 {
		return .Err_Invalid
	}
	// Rock Ridge: the root's "." begins with SP, and an ER names RRIP.
	dot: Rec
	_ = record_at(v, pvd_lba, u64(pvd_len), 0, &dot) or_return
	SU :: 34 // after "."'s one-byte name, no padding
	rock := false
	if .Rock not_in avoid && dot.len >= SU + 7 && dot.b[SU] == 'S' && dot.b[SU + 1] == 'P' && dot.b[SU + 4] == 0xbe && dot.b[SU + 5] == 0xef {
		v.susp_skip = u32(dot.b[SU + 6])
		it := su_begin(v, &dot, 0)
		for e in su_next(&it) {
			if names_rock(e) {
				rock = true
				break
			}
		}
		if !rock && it.status != .Ok {
			return it.status
		}
	}
	switch {
	case rock:
		v.kind, v.root_lba, v.root_len = .Rock, pvd_lba, pvd_len
	case joliet_lba != 0 && .Joliet not_in avoid:
		v.kind, v.root_lba, v.root_len, v.susp_skip = .Joliet, joliet_lba, joliet_len, 0
	case:
		v.kind, v.root_lba, v.root_len, v.susp_skip = .Plain, pvd_lba, pvd_len, 0
	}
	return .Ok
}

// --- Directories and files ---

root_entry :: proc "contextless" (v: ^Vol, e: ^Entry) {
	e^ = Entry {
		node = ROOT,
		lba  = v.root_lba,
		size = v.root_len,
		dir  = true,
		mode = 0o555,
	}
	append(&e.name, '/')
}

// A directory being read: dir_next gives its entries.
Iter :: struct {
	lba: u32,
	len: u64,
	off: u64,
}

@(require_results)
open_dir :: proc "contextless" (d: ^Entry) -> (it: Iter, st: vx.Status) {
	if !d.dir {
		return {}, .Err_Invalid
	}
	return Iter{lba = d.lba, len = u64(d.size)}, .Ok
}

// The next entry in the directory: Err_Not_Found at its end. "." and "..",
// and directories Rock Ridge relocated, are skipped.
@(require_results)
dir_next :: proc "contextless" (v: ^Vol, it: ^Iter, e: ^Entry) -> vx.Status {
	for {
		r: Rec
		next := record_at(v, it.lba, it.len, it.off, &r) or_return
		at := next - u64(r.len) // where the record actually was: past any padding record_at skipped
		it.off = next
		if is_dot(&r) {
			continue
		}
		if .Hidden in header(&r).flags && v.kind != .Rock {
			continue
		}
		st := decode(v, &r, it.lba, at, e)
		if st == .Err_Not_Found {
			continue
		}
		return st
	}
}

// Whether a and b are the same name: byte for byte, or ignoring ASCII case.
@(private="file")
same :: proc "contextless" (a, b: string, exact: bool) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if !exact {
			x = x >= 'A' && x <= 'Z' ? x + 32 : x
			y = y >= 'A' && y <= 'Z' ? y + 32 : y
		}
		if x != y {
			return false
		}
	}
	return true
}

// The entry named name in directory d, into e.
@(require_results)
lookup :: proc "contextless" (v: ^Vol, d: ^Entry, name: string, e: ^Entry) -> vx.Status {
	it := open_dir(d) or_return
	for {
		dir_next(v, &it, e) or_return
		if same(entry_name(e), name, v.kind == .Rock) {
			return .Ok
		}
	}
}

// The entry for a node, into e.
@(require_results)
get :: proc "contextless" (v: ^Vol, node: Node, e: ^Entry) -> vx.Status {
	if node == ROOT {
		root_entry(v, e)
		return .Ok
	}
	if u64(node) >> 62 == 0 {
		return .Err_Not_Found
	}
	// The directory's own "." record says how long it is.
	r: Rec
	lba := node_dir(node)
	_ = record_at(v, lba, SECTOR, 0, &r) or_return
	off := node_off(node)
	next := record_at(v, lba, u64(header(&r).size.le), off, &r) or_return
	if next - u64(r.len) != off || is_dot(&r) {
		return .Err_Not_Found
	}
	return decode(v, &r, lba, off, e)
}

// The directory node holding a node.
@(require_results)
parent :: proc "contextless" (v: ^Vol, node: Node) -> (p: Node, st: vx.Status) {
	dir := node == ROOT ? v.root_lba : node_dir(node)
	if dir == v.root_lba {
		return ROOT, .Ok
	}
	// The directory's ".." names the grandparent (or Rock Ridge's PL does,
	// for a relocated one); its records, the one naming this directory.
	dot, up: Rec
	next: u64
	next, st = record_at(v, dir, SECTOR, 0, &dot)
	if st == .Ok {
		_, st = record_at(v, dir, u64(header(&dot).size.le), next, &up)
	}
	if st != .Ok {
		return 0, st == .Err_Not_Found ? .Err_Io : st
	}
	grand := u32(header(&up).extent.le)
	if v.kind == .Rock {
		// A broken chain ends the search for PL where it breaks, as upstream's does.
		su := su_begin(v, &up, v.susp_skip)
		for e in su_next(&su) {
			if e[0] == 'P' && e[1] == 'L' && len(e) >= size_of(Su_Location) {
				grand = u32(load(Su_Location, e).block.le)
			}
		}
	}
	it := Iter{lba = grand, len = u64(v.root_len)}
	if grand != v.root_lba {
		gdot: Rec
		_ = record_at(v, grand, SECTOR, 0, &gdot) or_return
		it.len = u64(header(&gdot).size.le)
	}
	e: Entry
	for {
		st = dir_next(v, &it, &e)
		if st != .Ok {
			return 0, st == .Err_Not_Found ? .Err_Io : st
		}
		if e.dir && e.lba == dir {
			return e.node, .Ok
		}
	}
}

// Up to len(buf) bytes of a file from offset into buf; n, what was read.
@(require_results)
read :: proc "contextless" (v: ^Vol, f: ^Entry, offset: u64, buf: []u8) -> (n: int, st: vx.Status) {
	if f.dir || f.link {
		return 0, .Err_Invalid
	}
	if offset >= u64(f.size) {
		return 0, .Ok
	}
	count := min(u64(len(buf)), u64(f.size) - offset)
	for done: u64 = 0; done < count; {
		s := u64(f.lba) + (offset + done) / SECTOR
		at := (offset + done) % SECTOR
		k := min(SECTOR - at, count - done)
		if at == 0 && k == SECTOR { // whole sectors: past the cache
			run := min((count - done) / SECTOR, 64)
			k = run * SECTOR
			if v.sectors != 0 && s + run > v.sectors {
				return 0, .Err_Io
			}
			if !v.dev.read(v.dev.ctx, s * SECTOR, buf[done:][:k]) {
				return 0, .Err_Io
			}
		} else {
			b := sector(v, s)
			if b == nil {
				return 0, .Err_Io
			}
			copy(buf[done:][:k], b[at:][:k])
		}
		done += k
	}
	return int(count), .Ok
}
