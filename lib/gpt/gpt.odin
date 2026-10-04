// The GUID partition table (UEFI 2.10 §5.3), read and checked, and written
// (install, upstream's M5 step 9c). Pure code over read and write callbacks,
// so the host's tests run it as partd (upstream's docs/proto/block.md §6) and
// install do.
//
// The disk is untrusted. The primary header (LBA 1) is used if it and its
// entries pass every check; otherwise the backup (the disk's last LBA). A
// header passes if its signature, revision, size and CRC are right, it says
// it is where it was read, and its usable range and entry array lie inside
// the disk. Entries pass if their CRC matches and every partition in use lies
// in the usable range and overlaps no other. A table that fails both ways is
// refused whole: nothing on it is served.
package gpt

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"

MAX :: 128 // partitions kept
ENTRY_BYTES :: 64 << 10 // the entry array read, at most
NAME_BYTES :: 36 * 3 // a name's 36 UTF-16 units, as UTF-8: a surrogate pair is two units and four bytes

// A GUID as the disk stores it: the first three fields little-endian.
Guid :: [16]u8

Part :: struct {
	type, guid:  Guid,
	first, last: u64, // LBAs, inclusive
	attributes:  u64,
	name:        [dynamic; NAME_BYTES]u8, // UTF-8
}

// A table, read or to be written. Large (the entry buffer): keep one in
// static storage, not on a stack.
Gpt :: struct {
	sector:                    u32, // bytes
	sectors:                   u64, // the disk's
	backup:                    bool, // the backup table was used: the primary is damaged
	disk_guid:                 Guid,
	first_usable, last_usable: u64,
	parts:                     [dynamic; MAX]Part, // the partitions in use, in table order
	buf:                       [ENTRY_BYTES]u8, // where the entries are read
}

// Reads len(buf) bytes, a whole number of sectors, from lba on; false if it cannot.
Read_Proc :: #type proc "contextless" (ctx: rawptr, lba: u64, buf: []u8) -> bool

// Writes buf, a whole number of sectors, at lba on; false if it cannot.
Write_Proc :: #type proc "contextless" (ctx: rawptr, lba: u64, buf: []u8) -> bool

// --- The format ---

@(private="file")
SIGNATURE :: "EFI PART"
@(private="file")
REVISION :: 0x00010000

@(private="file")
Header :: struct #packed {
	signature:     [8]u8,
	revision:      u32le,
	size:          u32le,
	crc:           u32le, // over size bytes, this field zero
	reserved:      u32le,
	my_lba:        u64le,
	alternate_lba: u64le,
	first_usable:  u64le,
	last_usable:   u64le,
	disk_guid:     Guid,
	entries_lba:   u64le,
	entry_count:   u32le,
	entry_size:    u32le,
	entries_crc:   u32le,
}
#assert(size_of(Header) == 92)
#assert(offset_of(Header, crc) == 16)
#assert(offset_of(Header, my_lba) == 24)
#assert(offset_of(Header, first_usable) == 40)
#assert(offset_of(Header, disk_guid) == 56)
#assert(offset_of(Header, entries_lba) == 72)
#assert(offset_of(Header, entries_crc) == 88)

@(private="file")
Entry :: struct #packed {
	type:       Guid, // all zeroes: unused
	guid:       Guid,
	first:      u64le,
	last:       u64le,
	attributes: u64le,
	name:       [36]u16le, // UTF-16LE, NUL-padded
}
#assert(size_of(Entry) == 128)
#assert(offset_of(Entry, first) == 32)
#assert(offset_of(Entry, name) == 56)

// The protective MBR's one partition entry (at byte 446).
@(private="file")
Mbr_Entry :: struct #packed {
	status:    u8,
	chs_first: [3]u8,
	type:      u8,
	chs_last:  [3]u8,
	lba_first: u32le,
	sectors:   u32le,
}
#assert(size_of(Mbr_Entry) == 16)

@(private="file")
load :: #force_inline proc "contextless" (b: []u8, $T: typeid) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))
}

@(private="file")
store :: #force_inline proc "contextless" (b: []u8, v: $T) {
	v := v
	copy(b[:size_of(T)], memory.ptr_to_bytes(&v))
}

// CRC-32 (ISO-HDLC, as zlib's), which GPT uses.
@(private="file")
crc32 :: proc "contextless" (p: []u8) -> u32 {
	c := ~u32(0)
	for b in p {
		c ~= u32(b)
		for _ in 0 ..< 8 {
			c = (c >> 1) ~ (0xedb88320 & -(c & 1))
		}
	}
	return ~c
}

// A sector size GPT is read and written with here: a power of two, 512 to 4096.
@(private="file")
valid_sector :: proc "contextless" (sector: u32) -> bool {
	return sector >= 512 && sector <= 4096 && sector & (sector - 1) == 0
}

// Whether two inclusive ranges share an LBA.
@(private="file")
overlap :: proc "contextless" (a, b: ^Part) -> bool {
	return a.first <= b.last && b.first <= a.last
}

// --- Reading ---

// A UTF-16LE name of up to 36 units, as UTF-8 (lone surrogates become U+FFFD).
@(private="file")
decode_name :: proc "contextless" (units: [36]u16le, out: ^[dynamic; NAME_BYTES]u8) {
	clear(out)
	for i := 0; i < len(units); i += 1 {
		u := u32(units[i])
		if u == 0 {
			break
		}
		switch {
		case u >= 0xd800 && u < 0xdc00 && i + 1 < len(units):
			lo := u32(units[i + 1])
			if lo >= 0xdc00 && lo < 0xe000 {
				u = 0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00)
				i += 1
			} else {
				u = 0xfffd
			}
		case u >= 0xd800 && u < 0xe000:
			u = 0xfffd
		}
		// At most 108 bytes in all, so these always fit.
		switch {
		case u < 0x80:
			append(out, u8(u))
		case u < 0x800:
			append(out, u8(0xc0 | u >> 6), u8(0x80 | (u & 0x3f)))
		case u < 0x10000:
			append(out, u8(0xe0 | u >> 12), u8(0x80 | (u >> 6 & 0x3f)), u8(0x80 | (u & 0x3f)))
		case:
			append(out, u8(0xf0 | u >> 18), u8(0x80 | (u >> 12 & 0x3f)), u8(0x80 | (u >> 6 & 0x3f)), u8(0x80 | (u & 0x3f)))
		}
	}
}

// One table: the header at lba, then its entries. .Ok, or why it fails.
@(private="file")
read_table :: proc "contextless" (g: ^Gpt, lba: u64, read_fn: Read_Proc, ctx: rawptr) -> vx.Status {
	sector := int(g.sector)
	b := g.buf[:] // the header first, then the entries, in the same buffer
	if !read_fn(ctx, lba, b[:sector]) {
		return .Err_Io
	}
	h := load(b, Header)
	if string(h.signature[:]) != SIGNATURE || h.revision != REVISION || h.size < size_of(Header) || u32(h.size) > g.sector {
		return .Err_Invalid
	}
	store(b[offset_of(Header, crc):], u32le(0))
	if crc32(b[:h.size]) != u32(h.crc) {
		return .Err_Invalid
	}
	first, last := u64(h.first_usable), u64(h.last_usable)
	if u64(h.my_lba) != lba || first > last || last >= g.sectors || first < 2 {
		return .Err_Invalid
	}
	count, esize := u64(h.entry_count), u64(h.entry_size)
	if esize < size_of(Entry) || esize % size_of(Entry) != 0 || count == 0 || count * esize > ENTRY_BYTES {
		return .Err_Invalid // count and esize are u32s: their product fits
	}
	bytes := count * esize
	nsect := (bytes + u64(sector) - 1) / u64(sector)
	// The array lies inside the disk, and outside the usable range (it is metadata).
	entries := u64(h.entries_lba)
	if entries < 2 || entries >= g.sectors || nsect > g.sectors - entries {
		return .Err_Invalid
	}
	if !(entries + nsect <= first || entries > last) {
		return .Err_Invalid
	}
	if !read_fn(ctx, entries, b[:nsect * u64(sector)]) {
		return .Err_Io
	}
	if crc32(b[:bytes]) != u32(h.entries_crc) {
		return .Err_Invalid
	}

	clear(&g.parts)
	for i in 0 ..< count {
		e := load(b[i * esize:], Entry)
		if e.type == (Guid{}) {
			continue // unused
		}
		if len(g.parts) == MAX {
			return .Err_Range
		}
		p := Part {
			type       = e.type,
			guid       = e.guid,
			first      = u64(e.first),
			last       = u64(e.last),
			attributes = u64(e.attributes),
		}
		decode_name(e.name, &p.name)
		if p.first > p.last || p.first < first || p.last > last {
			return .Err_Invalid
		}
		for &q in g.parts { // no two overlap
			if overlap(&p, &q) {
				return .Err_Invalid
			}
		}
		append(&g.parts, p)
	}
	g.disk_guid = h.disk_guid
	g.first_usable = first
	g.last_usable = last
	return .Ok
}

// Reads the table of a disk of sectors sectors of sector bytes: the primary,
// or the backup if the primary fails. .Ok; .Err_Invalid if neither passes,
// .Err_Io if neither could be read.
@(require_results)
read :: proc "contextless" (g: ^Gpt, sector: u32, sectors: u64, read_fn: Read_Proc, ctx: rawptr) -> vx.Status {
	g.sector = sector
	g.sectors = sectors
	clear(&g.parts)
	g.backup = false
	if !valid_sector(sector) || sectors < 68 {
		return .Err_Invalid
	}
	st := read_table(g, 1, read_fn, ctx)
	if st == .Ok {
		return .Ok
	}
	back := read_table(g, sectors - 1, read_fn, ctx)
	if back != .Ok {
		clear(&g.parts)
		return st == .Err_Io && back == .Err_Io ? .Err_Io : .Err_Invalid
	}
	g.backup = true
	return .Ok
}

@(private="file")
hex_digit :: proc "contextless" (c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// A GUID as text (C12A7328-F81F-11D2-BA4B-00A0C93EC93B), as the disk stores
// it: the first three fields little-endian, the rest as written. ok is false
// if the text is not one.
@(require_results)
guid :: proc "contextless" (text: string) -> (out: Guid, ok: bool) {
	ORDER := [16]u8{3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15}
	if len(text) != 36 {
		return
	}
	bytes: Guid
	n := 0
	for i := 0; i < len(text); i += 1 {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if text[i] != '-' {
				return
			}
			continue
		}
		if n == len(bytes) || i + 1 >= len(text) {
			return
		}
		hi, lo := hex_digit(text[i]), hex_digit(text[i + 1])
		if hi < 0 || lo < 0 {
			return
		}
		bytes[n] = u8(hi << 4 | lo)
		n += 1
		i += 1
	}
	if n != len(bytes) {
		return
	}
	for &b, i in out {
		b = bytes[ORDER[i]]
	}
	return out, true
}

// --- Writing (upstream's M5 step 9c: install) ---

@(private="file")
WRITE_ENTRIES :: 128 // entries written, of 128 bytes each
@(private="file")
WRITE_BYTES :: WRITE_ENTRIES * size_of(Entry)

// A name, UTF-8, as the entry's 36 UTF-16LE units (BMP only; cut at 36).
// Malformed UTF-8 is taken as it comes, as upstream does: a lead byte's
// payload bits, then up to as many continuation bytes' low six bits as it
// asks for.
@(private="file")
encode_name :: proc "contextless" (name: string) -> (units: [36]u16le) {
	LEAD := [4]u32{0x7f, 0x1f, 0x0f, 0x07}
	s, n := 0, 0
	for s < len(name) && name[s] != 0 && n < len(units) {
		c := u32(name[s])
		s += 1
		more := int(c >= 0xc0) + int(c >= 0xe0) + int(c >= 0xf0)
		c &= LEAD[more]
		for _ in 0 ..< more {
			if s == len(name) || name[s] == 0 {
				break
			}
			c = c << 6 | u32(name[s] & 0x3f)
			s += 1
		}
		if c > 0xffff {
			c = 0xfffd
		}
		units[n] = u16le(c)
		n += 1
	}
	return
}

// One header, for a table at my whose copy is at other and entries at
// entries, into h (a sector).
@(private="file")
put_header :: proc "contextless" (g: ^Gpt, h: []u8, my, other, entries: u64, ecrc: u32) {
	for &b in h {
		b = 0
	}
	hd := Header {
		revision      = REVISION,
		size          = size_of(Header),
		my_lba        = u64le(my),
		alternate_lba = u64le(other),
		first_usable  = u64le(g.first_usable),
		last_usable   = u64le(g.last_usable),
		disk_guid     = g.disk_guid,
		entries_lba   = u64le(entries),
		entry_count   = WRITE_ENTRIES,
		entry_size    = size_of(Entry),
		entries_crc   = u32le(ecrc),
	}
	copy(hd.signature[:], SIGNATURE)
	store(h, hd)
	hd.crc = u32le(crc32(h[:size_of(Header)]))
	store(h, hd)
}

// Writes the table g holds (sector, sectors, disk_guid and parts) whole: a
// protective MBR, the primary header and 128 entries at LBA 1 and 2, their
// backups at the disk's end. g's usable range is set from the disk's size; a
// part outside it, or two that overlap, is .Err_Invalid and nothing is
// written. g.buf holds the entries, then the sector being written.
@(require_results)
write :: proc "contextless" (g: ^Gpt, write_fn: Write_Proc, ctx: rawptr) -> vx.Status {
	if !valid_sector(g.sector) {
		return .Err_Invalid
	}
	esect := u64(WRITE_BYTES / g.sector)
	if g.sectors < 2 * (2 + esect) + 1 {
		return .Err_Invalid
	}
	g.first_usable = 2 + esect
	g.last_usable = g.sectors - 2 - esect
	for &p, i in g.parts {
		if p.first > p.last || p.first < g.first_usable || p.last > g.last_usable {
			return .Err_Invalid
		}
		for &q in g.parts[:i] {
			if overlap(&p, &q) {
				return .Err_Invalid
			}
		}
	}
	e := g.buf[:WRITE_BYTES]
	for &b in e {
		b = 0
	}
	for &p, i in g.parts {
		store(e[i * size_of(Entry):], Entry {
			type       = p.type,
			guid       = p.guid,
			first      = u64le(p.first),
			last       = u64le(p.last),
			attributes = u64le(p.attributes),
			name       = encode_name(string(p.name[:])),
		})
	}
	ecrc := crc32(e)
	s := g.buf[WRITE_BYTES:][:g.sector]
	// The protective MBR: one partition of type 0xEE over the whole disk (or as much of it as 32 bits hold).
	for &b in s {
		b = 0
	}
	store(s[446:], Mbr_Entry {
		chs_first = {0, 2, 0},
		type      = 0xee,
		chs_last  = {0xff, 0xff, 0xff},
		lba_first = 1,
		sectors   = u32le(min(g.sectors - 1, 0xffffffff)),
	})
	s[510], s[511] = 0x55, 0xaa
	if !write_fn(ctx, 0, s) {
		return .Err_Io
	}
	last := g.sectors - 1
	backup_entries := last - esect
	if !write_fn(ctx, 2, e) || !write_fn(ctx, backup_entries, e) {
		return .Err_Io
	}
	// The backup, then the primary: a torn write leaves one whole.
	put_header(g, s, last, 1, backup_entries, ecrc)
	if !write_fn(ctx, last, s) {
		return .Err_Io
	}
	put_header(g, s, 1, last, 2, ecrc)
	return write_fn(ctx, 1, s) ? .Ok : .Err_Io
}
