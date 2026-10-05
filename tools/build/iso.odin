package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import iso9660 "vx:iso"

// The CD image (image --iso, M3's deliverables): ISO 9660 with El Torito,
// for UEFI. Its El Torito boot entry ("no emulation", platform EFI) is a
// small FAT image holding only the loader; the loader then reads its
// configuration, the kernel and the modules from the ISO 9660 tree, as
// Limine does on a CD. An MBR in the system area also names the boot image
// as a partition (type EFI), as xorriso's --efi-boot-part does: that is how
// Limine finds which volume it was booted from.
//
// Names three ways (upstream's M5 step 8c), each tree's directories its
// own, the files' bytes shared:
// - ISO 9660 level 2: upper case, [A-Z0-9_], "NAME.EXT;1", up to 30
//   characters, made unique in a directory with ~N; what Limine matches
//   case-insensitively.
// - Rock Ridge (RRIP 1991A, over SUSP) in the same records: the real name
//   (NM), POSIX mode, links, owner (PX, all root's), the time (TF), symbolic
//   links (SL). What does not fit a record's 255 bytes goes to its
//   directory's continuation area (CE), as the root's ER does.
// - Joliet (UCS-2, escape %/E, so UTF-16 here), in a supplementary volume
//   descriptor's tree: names up to 64 units, no symbolic links.
// Dates are SOURCE_DATE_EPOCH's, so the image is reproducible. El Torito's
// boot record is at sector 17, as its specification requires; the Joliet
// descriptor follows it.
//
// The on-disk layouts lib/iso reads (records, volume descriptors, SUSP
// entries) are lib/iso's; El Torito's, which it does not read, are here.
// The bytes are upstream's write_iso's exactly: tests/host/iso's image was
// written by it, and ./build check compares make_test_iso's with it.

ISO_SECTOR :: iso9660.SECTOR
ISO_MAX_DIRS :: 64
ISO_MAX_KIDS :: 256

// A file in the ISO's tree.
Iso_File :: struct {
	path: string, // in the ISO: "boot/vx/kernel.elf"
	from: string, // where it is on this machine; "" for a symbolic link
	link: string, // a symbolic link's target
}

both16 :: proc(v: u16) -> iso9660.Both16 {return {u16le(v), u16be(v)}}
both32 :: proc(v: u32) -> iso9660.Both32 {return {u32le(v), u32be(v)}}

// A volume descriptor's date (ECMA-119 8.4.26.1): "YYYYMMDDHHMMSScc", and the zone.
Iso_Volume_Date :: struct #packed {
	digits: [16]u8,
	zone:   i8,
}
#assert(size_of(Iso_Volume_Date) == 17)

// The primary and supplementary volume descriptors (8.4, 8.5): lib/iso's
// head, up to the root's record, and the rest.
Iso_Volume :: struct #packed {
	desc:            iso9660.Volume_Descriptor,
	set_id:          [128]u8,
	publisher:       [128]u8,
	preparer:        [128]u8,
	application:     [128]u8,
	// The copyright, abstract and bibliographic file identifiers, 37 bytes
	// each, padded as one field: in Joliet's, UCS-2 pairs run across them.
	file_ids:        [3 * 37]u8,
	created:         Iso_Volume_Date,
	modified:        Iso_Volume_Date,
	expires:         Iso_Volume_Date,
	effective:       Iso_Volume_Date,
	fs_version:      u8,
	_:               u8,
	application_use: [512]u8,
	_:               [653]u8,
}
#assert(size_of(Iso_Volume) == ISO_SECTOR)
#assert(offset_of(Iso_Volume, set_id) == 190)
#assert(offset_of(Iso_Volume, application) == 574)
#assert(offset_of(Iso_Volume, file_ids) == 702)
#assert(offset_of(Iso_Volume, created) == 813)
#assert(offset_of(Iso_Volume, fs_version) == 881)

ISO_ID :: [5]u8{'C', 'D', '0', '0', '1'}

// A path table record (9.4), little-endian (type L) or big-endian (type M),
// without its name, which follows it padded to an even length.
Iso_Path_L :: struct #packed {
	name_len:   u8,
	ext_length: u8,
	extent:     u32le,
	parent:     u16le, // its directory's number: 1 for the root
}
#assert(size_of(Iso_Path_L) == 8)

Iso_Path_M :: struct #packed {
	name_len:   u8,
	ext_length: u8,
	extent:     u32be,
	parent:     u16be,
}
#assert(size_of(Iso_Path_M) == 8)

Iso_Descriptor_Type :: enum u8 {
	Boot_Record   = 0,
	Primary       = 1,
	Supplementary = 2,
	Terminator    = 255,
}

// What starts every volume descriptor (8.1); the terminator is no more.
Iso_Descriptor_Header :: struct #packed {
	type:    Iso_Descriptor_Type,
	id:      [5]u8, // "CD001"
	version: u8,
}
#assert(size_of(Iso_Descriptor_Header) == 7)

// El Torito's boot record volume descriptor (El Torito 1.0, 2.0).
Iso_Boot_Record :: struct #packed {
	header:    Iso_Descriptor_Header,
	system_id: [32]u8, // "EL TORITO SPECIFICATION", padded with zeros
	boot_id:   [32]u8,
	catalog:   u32le, // the boot catalog's sector
	_:         [1973]u8,
}
#assert(size_of(Iso_Boot_Record) == ISO_SECTOR)
#assert(offset_of(Iso_Boot_Record, catalog) == 71)

// The boot catalog's validation entry (2.1) and default entry (2.2).
Iso_Validation_Entry :: struct #packed {
	header_id: u8, // 1
	platform:  u8, // 0xef: EFI
	_:         u16le,
	id_string: [24]u8,
	checksum:  u16le, // the entry's words sum to 0
	key:       [2]u8, // 0x55, 0xaa
}
#assert(size_of(Iso_Validation_Entry) == 32)

Iso_Default_Entry :: struct #packed {
	indicator:    u8, // 0x88: bootable
	media:        u8, // 0: no emulation
	load_segment: u16le,
	system_type:  u8,
	_:            u8,
	sector_count: u16le, // of 512 bytes
	load_rba:     u32le, // the boot image's sector
	_:            [20]u8,
}
#assert(size_of(Iso_Default_Entry) == 32)

Iso_Catalog :: struct #packed {
	validation: Iso_Validation_Entry,
	initial:    Iso_Default_Entry,
}
#assert(size_of(Iso_Catalog) == 64)

// The fixed sectors: the system area is 0-15, then the descriptors; the
// path tables start after them.
@(private="file")
Iso_Fixed :: enum u32 {
	Primary       = 16,
	Boot_Record   = 17,
	Supplementary = 18,
	Terminator    = 19,
	Paths         = 20,
}

// The two trees: ISO 9660 names with Rock Ridge, and Joliet's.
@(private="file")
Iso_Tree :: enum {
	Rock,
	Joliet,
}

@(private="file")
Iso_Kid_Kind :: enum {
	Dir,
	File,
	Catalog, // the boot catalog, in the root
	Boot_Image, // and El Torito's image
}

// An entry of a directory, its names made three ways.
@(private="file")
Iso_Kid :: struct {
	name:   string, // the real name: Rock Ridge's
	iso:    string, // ISO 9660's, unique in the directory: "LIMINE.CONF;1"
	joliet: []u8, // UTF-16BE, up to 64 units
	kind:   Iso_Kid_Kind,
	index:  int, // the directory's or the file's
}

@(private="file")
Iso_Dir :: struct {
	path:            string, // "" for the root
	parent:          int, // its index, once sorted
	kids:            [dynamic]Iso_Kid,
	lba, size:       [Iso_Tree]u32,
	ce_lba, ce_size: u32, // its continuation area
}

// What each kid's record names: where everything is.
@(private="file")
Iso_Layout :: struct {
	dirs:                       []Iso_Dir,
	files:                      []Iso_File,
	file_sizes:                 []u32,
	file_lbas:                  []u32, // nil while measuring
	catalog, boot_lba, boot_len: u32,
	date:                       [7]u8, // every record's
}

@(private="file")
sectors :: proc(bytes: u64) -> u32 {
	return u32((bytes + ISO_SECTOR - 1) / ISO_SECTOR)
}

@(private="file")
round_sector :: proc(n: int) -> int {
	return (n + ISO_SECTOR - 1) / ISO_SECTOR * ISO_SECTOR
}

// SOURCE_DATE_EPOCH (main sets it), in seconds.
source_date_epoch :: proc() -> (secs: i64, ok: bool) {
	text := os.get_env("SOURCE_DATE_EPOCH", context.temp_allocator)
	secs, ok = strconv.parse_i64(text)
	if !ok {
		fmt.eprintfln("build: SOURCE_DATE_EPOCH=%s is not a number of seconds", text)
	}
	return
}

// A record's 7-byte date (9.1.5): years since 1900, the rest as they are, UTC.
@(private="file")
record_date :: proc(epoch: i64) -> (d: [7]u8) {
	t := time.unix(epoch, 0)
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	return {u8(year - 1900), u8(month), u8(day), u8(hour), u8(minute), u8(second), 0}
}

// A text field: s, padded with spaces; in Joliet's descriptor UCS-2,
// big-endian, each character's byte after a zero.
@(private="file")
iso_text :: proc(field: []u8, s: string, joliet := false) {
	if !joliet {
		slice.fill(field, ' ')
		copy(field, s)
		return
	}
	for i := 0; i + 1 < len(field); i += 2 {
		field[i], field[i + 1] = 0, ' '
	}
	for i := 0; 2 * i + 1 < len(field) && i < len(s); i += 1 {
		field[2 * i + 1] = s[i]
	}
}

// A directory record into p (if it is not nil), with su (system use: Rock
// Ridge) after its name, padded to an even length; its length.
@(private="file")
iso_record :: proc(p: []u8, lba, size: u32, is_dir: bool, name, su: []u8, date: [7]u8) -> (length: int, ok: bool) {
	pad := len(name) & 1 == 0 ? 1 : 0 // the name padded to an even offset
	length = size_of(iso9660.Dir_Record) + len(name) + pad + len(su)
	length += length & 1
	if length > 255 {
		fmt.eprintfln("build: an ISO directory record of %d bytes", length)
		return 0, false
	}
	if p == nil {
		return length, true
	}
	r := iso9660.Dir_Record {
		length      = u8(length),
		extent      = both32(lba),
		size        = both32(size),
		date        = date,
		flags       = is_dir ? {.Directory} : {},
		volume_seq  = both16(1),
		name_length = u8(len(name)),
	}
	slice.zero(p[:length])
	copy(p, slice.bytes_from_ptr(&r, size_of(r)))
	copy(p[size_of(r):], name)
	copy(p[size_of(r) + len(name) + pad:], su)
	return length, true
}

@(private="file")
depth_of :: proc(path: string) -> int {
	return path == "" ? 0 : strings.count(path, "/") + 1
}

@(private="file")
dir_index :: proc(dirs: []Iso_Dir, path: string) -> int {
	for d, i in dirs {
		if d.path == path {
			return i
		}
	}
	return -1
}

// Upper case, and anything but [A-Z0-9] as '_'.
@(private="file")
d_char :: proc(b: u8) -> u8 {
	c := b >= 'a' && b <= 'z' ? b - 32 : b
	return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ? c : '_'
}

// The ISO 9660 name for a real one, unique among kids: at most 30
// characters, then ";1" (32 bytes, as upstream's 33-byte buffer holds them
// since its f24356f; its 32-byte one lost the version's "1").
@(private="file")
iso_mangle :: proc(name: string, is_file: bool, kids: []Iso_Kid) -> string {
	dot := is_file ? strings.last_index_byte(name, '.') : -1
	if dot == 0 {
		dot = -1
	}
	base := strings.builder_make(context.temp_allocator)
	ext := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(name) && i != dot && strings.builder_len(base) < 30; i += 1 {
		strings.write_byte(&base, d_char(name[i]))
	}
	if dot >= 0 {
		for i := dot + 1; i < len(name) && strings.builder_len(ext) < 8; i += 1 {
			strings.write_byte(&ext, d_char(name[i]))
		}
	}
	if strings.builder_len(base) == 0 {
		strings.write_byte(&base, '_')
	}
	b, e := strings.to_string(base), strings.to_string(ext)
	room := is_file ? 30 - 1 - len(e) : 31 // name, dot and extension: 30 at most
	b = b[:min(len(b), room)]
	for k := 0; ; k += 1 {
		tail := k > 0 ? fmt.tprintf("~%d", k) : ""
		keep := len(b) + len(tail) > room ? room - len(tail) : len(b)
		out := is_file ? fmt.tprintf("%s%s.%s;1", b[:keep], tail, e) : fmt.tprintf("%s%s", b[:keep], tail)
		out = out[:min(len(out), 32)]
		taken := false
		for kid in kids {
			taken = taken || kid.iso == out
		}
		if !taken {
			return out
		}
	}
}

// The real name as Joliet's UTF-16BE, cut at 64 units (and never mid-pair).
@(private="file")
iso_joliet :: proc(name: string) -> []u8 {
	out := make([dynamic]u8, 0, 128, context.temp_allocator)
	lead := [4]u32{0x7f, 0x1f, 0x0f, 0x07}
	for i := 0; i < len(name); {
		c := u32(name[i])
		i += 1
		more := int(c >= 0xc0) + int(c >= 0xe0) + int(c >= 0xf0) // continuation bytes after the lead
		c &= lead[more]
		for k := 0; k < more && i < len(name); k += 1 {
			c = c << 6 | u32(name[i] & 0x3f)
			i += 1
		}
		if c >= 0x1_0000 {
			if len(out) + 4 > 128 {
				break
			}
			hi, lo := 0xd800 + ((c - 0x1_0000) >> 10), 0xdc00 + ((c - 0x1_0000) & 0x3ff)
			append(&out, u8(hi >> 8), u8(hi), u8(lo >> 8), u8(lo))
		} else {
			if len(out) + 2 > 128 {
				break
			}
			append(&out, u8(c >> 8), u8(c))
		}
	}
	return out[:]
}

// Rock Ridge's entries for a record: built whole, then split between the
// record and the directory's continuation area.
@(private="file")
Iso_Su :: struct {
	buf:  [dynamic]u8,
	ends: [dynamic]int, // each entry's end
}

@(private="file")
SU_MAX :: 2048
@(private="file")
SU_MAX_ENTRIES :: 64

@(private="file")
su_add :: proc(s: ^Iso_Su, sig: string, data: []u8) -> bool {
	if len(s.buf) + 4 + len(data) > SU_MAX || len(s.ends) == SU_MAX_ENTRIES || 4 + len(data) > 255 {
		fmt.eprintln("build: an ISO entry's Rock Ridge is too long")
		return false
	}
	head := iso9660.Su_Head{{sig[0], sig[1]}, u8(4 + len(data)), 1}
	append(&s.buf, ..slice.bytes_from_ptr(&head, size_of(head)))
	append(&s.buf, ..data)
	append(&s.ends, len(s.buf))
	return true
}

// The entries for one record: the root's "." gets SP and ER; every record
// PX and TF; a named one NM (in parts of 250 at most), a link SL.
@(private="file")
su_for :: proc(root_dot: bool, mode, links: u32, name, link: string, date: [7]u8) -> (s: Iso_Su, ok: bool) {
	s.buf = make([dynamic]u8, context.temp_allocator)
	s.ends = make([dynamic]int, context.temp_allocator)
	if root_dot {
		su_add(&s, "SP", {0xbe, 0xef, 0}) or_return
		ID :: "RRIP_1991A"
		DES :: "THE ROCK RIDGE INTERCHANGE PROTOCOL PROVIDES SUPPORT FOR POSIX FILE SYSTEM SEMANTICS"
		SRC :: "PLEASE CONTACT DISC PUBLISHER FOR SPECIFICATION SOURCE.  SEE PUBLISHER IDENTIFIER IN PRIMARY VOLUME DESCRIPTOR FOR CONTACT INFORMATION."
		er := make([dynamic]u8, context.temp_allocator)
		append(&er, len(ID), len(DES), len(SRC), 1)
		append(&er, ID)
		append(&er, DES)
		append(&er, SRC)
		su_add(&s, "ER", er[:]) or_return
	}
	px := iso9660.Su_Px{mode = both32(mode), links = both32(links), uid = both32(0), gid = both32(0)} // all root's
	su_add(&s, "PX", slice.bytes_from_ptr(&px, size_of(px))[size_of(iso9660.Su_Head):]) or_return
	date := date
	tf: [8]u8
	tf[0] = 0x02 // the modification time
	copy(tf[1:], date[:])
	su_add(&s, "TF", tf[:]) or_return
	for at := 0; at < len(name); {
		part := min(len(name) - at, 250)
		nm := make([dynamic]u8, context.temp_allocator)
		append(&nm, at + part < len(name) ? 1 : 0) // CONTINUE
		append(&nm, name[at:][:part])
		su_add(&s, "NM", nm[:]) or_return
		at += part
	}
	if link != "" {
		sl := make([dynamic]u8, context.temp_allocator)
		append(&sl, 0)
		p := link
		if p[0] == '/' {
			append(&sl, 0x08, 0) // ROOT
			p = p[1:]
		}
		for len(p) > 0 {
			c := strings.index_byte(p, '/')
			if c < 0 {
				c = len(p)
			}
			if len(sl) + 2 + c > 251 {
				fmt.eprintln("build: a symbolic link's target is too long for the ISO")
				return s, false
			}
			part := p[:c]
			switch part {
			case ".":
				append(&sl, 0x02, 0) // CURRENT
			case "..":
				append(&sl, 0x04, 0) // PARENT
			case:
				append(&sl, 0, u8(c))
				append(&sl, part)
			}
			p = p[min(c + 1, len(p)):]
		}
		su_add(&s, "SL", sl[:]) or_return
	}
	return s, true
}

// What of s fits a record with name_len bytes of name, and the rest: into
// ce (the directory's continuation area, ce_at bytes used, at ce_lba; nil
// while measuring), with a CE entry pointing at it.
@(private="file")
su_place :: proc(s: ^Iso_Su, name_len: int, ce: []u8, ce_at: ^int, ce_lba: u32) -> (out: []u8, ok: bool) {
	room := 255 - (size_of(iso9660.Dir_Record) + name_len + (name_len & 1 == 0 ? 1 : 0)) - 1
	CE :: size_of(iso9660.Su_Ce)
	o := make([dynamic]u8, context.temp_allocator)
	i, start := 0, 0
	for ; i < len(s.ends); i += 1 {
		entry := s.buf[start:s.ends[i]]
		if len(o) + len(entry) + (i + 1 < len(s.ends) ? CE : 0) > room {
			break
		}
		append(&o, ..entry)
		start = s.ends[i]
	}
	if i == len(s.ends) {
		return o[:], true
	}
	rest := s.buf[start:]
	if len(rest) > ISO_SECTOR {
		fmt.eprintln("build: an ISO entry's continuation is too long")
		return nil, false
	}
	if ce_at^ % ISO_SECTOR + len(rest) > ISO_SECTOR {
		ce_at^ = round_sector(ce_at^)
	}
	if ce != nil {
		copy(ce[ce_at^:], rest)
	}
	c := iso9660.Su_Ce {
		head   = {{'C', 'E'}, CE, 1},
		block  = both32(ce_lba + u32(ce_at^ / ISO_SECTOR)),
		offset = both32(u32(ce_at^ % ISO_SECTOR)),
		length = both32(u32(len(rest))),
	}
	append(&o, ..slice.bytes_from_ptr(&c, size_of(c)))
	ce_at^ += len(rest)
	return o[:], true
}

// Directory i's records for tree t into d (nil: only measured); its size, a
// whole number of sectors. Rock Ridge's overflow goes to ce (nil: measured
// into the directory's ce_size).
@(private="file")
dir_records :: proc(w: ^Iso_Layout, i: int, t: Iso_Tree, d, ce: []u8) -> (size: u32, ok: bool) {
	dir := &w.dirs[i]
	if t == .Rock {
		slice.sort_by(dir.kids[:], proc(a, b: Iso_Kid) -> bool {return a.iso < b.iso})
	} else {
		slice.sort_by(dir.kids[:], proc(a, b: Iso_Kid) -> bool {return string(a.joliet) < string(b.joliet)})
	}
	ce_at, at := 0, 0
	for k := -2; k < len(dir.kids); k += 1 {
		name: []u8
		lba, length: u32
		is_dir: bool
		s: Iso_Su
		if k < 0 { // "." and ".."
			x := k == -2 ? dir : &w.dirs[dir.parent]
			name = k == -2 ? []u8{0} : []u8{1}
			lba, length, is_dir = x.lba[t], x.size[t], true
			if t == .Rock {
				s = su_for(i == 0 && k == -2, 0o040555, 2, "", "", w.date) or_return
			}
		} else {
			kid := &dir.kids[k]
			link := kid.kind == .File ? w.files[kid.index].link : ""
			if t == .Joliet && link != "" {
				continue // Joliet has no links
			}
			name = t == .Joliet ? kid.joliet : transmute([]u8)kid.iso
			is_dir = kid.kind == .Dir
			mode := u32(0o100444)
			switch {
			case kid.kind == .Dir:
				lba, length, mode = w.dirs[kid.index].lba[t], w.dirs[kid.index].size[t], 0o040555
			case kid.kind == .Catalog:
				lba, length = w.catalog, ISO_SECTOR
			case kid.kind == .Boot_Image:
				lba, length = w.boot_lba, w.boot_len
			case link != "":
				mode = 0o120777
			case:
				lba = w.file_lbas != nil ? w.file_lbas[kid.index] : 0
				length = w.file_sizes[kid.index]
			}
			if t == .Rock {
				s = su_for(false, mode, is_dir ? 2 : 1, kid.name, link, w.date) or_return
			}
		}
		su: []u8
		if t == .Rock {
			su = su_place(&s, len(name), ce, &ce_at, dir.ce_lba) or_return
		}
		n := iso_record(nil, lba, length, is_dir, name, su, w.date) or_return
		if at % ISO_SECTOR + n > ISO_SECTOR {
			at = round_sector(at)
		}
		if d != nil {
			_ = iso_record(d[at:], lba, length, is_dir, name, su, w.date) or_return
		}
		at += n
	}
	if t == .Rock && ce == nil {
		dir.ce_size = u32(round_sector(ce_at))
	}
	return u32(round_sector(at)), true
}

// The path table for tree t, little-endian or big-endian, into p (nil:
// only measured); its size.
@(private="file")
path_table :: proc(dirs: []Iso_Dir, t: Iso_Tree, big: bool, p: []u8) -> int {
	size := 0
	for d, i in dirs {
		name: []u8 = {0}
		if i > 0 {
			for &kid in dirs[d.parent].kids {
				if kid.kind == .Dir && kid.index == i {
					name = t == .Joliet ? kid.joliet : transmute([]u8)kid.iso
					break
				}
			}
		}
		if p != nil {
			e := p[size:]
			parent := u16(d.parent + 1)
			if big {
				h := Iso_Path_M{u8(len(name)), 0, u32be(d.lba[t]), u16be(parent)}
				copy(e, slice.bytes_from_ptr(&h, size_of(h)))
			} else {
				h := Iso_Path_L{u8(len(name)), 0, u32le(d.lba[t]), u16le(parent)}
				copy(e, slice.bytes_from_ptr(&h, size_of(h)))
			}
			copy(e[8:], name)
		}
		size += 8 + len(name) + len(name) & 1
	}
	return size
}

@(private="file")
volume :: proc(v: []u8, type: Iso_Descriptor_Type, total: u32, pt_size: int, path_l, path_m: u32, top: ^Iso_Dir, t: Iso_Tree, date: [7]u8) {
	joliet := t == .Joliet
	d := Iso_Volume {
		desc = {
			type = u8(type),
			id = ISO_ID,
			version = 1,
			space_size = both32(total),
			set_size = both16(1),
			sequence_number = both16(1),
			block_size = both16(ISO_SECTOR),
			path_table_size = both32(u32(pt_size)),
			path_l = {u32le(path_l), 0},
			path_m = {u32be(path_m), 0},
			root = {
				length = 34,
				extent = both32(top.lba[t]),
				size = both32(top.size[t]),
				date = date,
				flags = {.Directory},
				volume_seq = both16(1),
				name_length = 1,
			},
		},
		fs_version = 1,
	}
	iso_text(d.desc.system_id[:], "", joliet)
	iso_text(d.desc.volume_id[:], "VECTRAOS", joliet)
	if joliet {
		d.desc.escapes[0], d.desc.escapes[1], d.desc.escapes[2] = '%', '/', 'E' // UCS-2 level 3
	}
	iso_text(d.set_id[:], "", joliet)
	iso_text(d.publisher[:], "", joliet)
	iso_text(d.preparer[:], "", joliet)
	iso_text(d.application[:], "VECTRAOS BUILD", joliet)
	iso_text(d.file_ids[:], "", joliet)
	NO_DATE :: Iso_Volume_Date {
		digits = {0 ..< 16 = '0'},
	}
	d.created, d.modified, d.expires, d.effective = NO_DATE, NO_DATE, NO_DATE, NO_DATE
	copy(v, slice.bytes_from_ptr(&d, size_of(d)))
}

// Writes the ISO at path: boot_image is El Torito's entry, files the tree;
// every date is epoch's.
write_iso :: proc(path, boot_image: string, files: []Iso_File, disk_id: u32, epoch: i64) -> bool {
	// The directories: each file's, and theirs, by depth then path, so a
	// parent comes before its children (the path tables' order).
	dirs := make([dynamic]Iso_Dir, context.temp_allocator)
	append(&dirs, Iso_Dir{})
	for f in files {
		for i in 0 ..< len(f.path) {
			if f.path[i] != '/' || dir_index(dirs[:], f.path[:i]) >= 0 {
				continue
			}
			if len(dirs) == ISO_MAX_DIRS {
				fmt.eprintln("build: too many directories for the ISO")
				return false
			}
			append(&dirs, Iso_Dir{path = f.path[:i]})
		}
	}
	slice.stable_sort_by(dirs[1:], proc(a, b: Iso_Dir) -> bool {
		da, db := depth_of(a.path), depth_of(b.path)
		return da < db || (da == db && a.path < b.path)
	})
	for &d in dirs[1:] {
		slash := strings.last_index_byte(d.path, '/')
		d.parent = slash < 0 ? 0 : dir_index(dirs[:], d.path[:slash])
	}

	// Each directory's kids, their names made three ways: its directories,
	// its files, and in the root the boot pieces.
	for &d, i in dirs {
		d.kids = make([dynamic]Iso_Kid, context.temp_allocator)
		add :: proc(d: ^Iso_Dir, name: string, kind: Iso_Kid_Kind, index: int) -> bool {
			if len(d.kids) == ISO_MAX_KIDS {
				fmt.eprintln("build: too many entries in an ISO directory")
				return false
			}
			iso := iso_mangle(name, kind != .Dir, d.kids[:])
			append(&d.kids, Iso_Kid{name = name, iso = iso, joliet = iso_joliet(name), kind = kind, index = index})
			return true
		}
		prefix := len(d.path) > 0 ? len(d.path) + 1 : 0
		for sub, k in dirs[1:] {
			if sub.parent == i {
				add(&d, sub.path[prefix:], .Dir, k + 1) or_return
			}
		}
		for f, k in files {
			slash := strings.last_index_byte(f.path, '/')
			if (slash < 0 ? "" : f.path[:slash]) == d.path {
				add(&d, f.path[slash + 1:], .File, k) or_return
			}
		}
		if i == 0 {
			add(&d, "boot.catalog", .Catalog, 0) or_return
			add(&d, "efiboot.img", .Boot_Image, 0) or_return
		}
	}

	// Sizes, then the layout: descriptors (El Torito's at 17), path tables,
	// directories, continuation areas, the boot catalog, the boot image, the files.
	w := Iso_Layout {
		dirs       = dirs[:],
		files      = files,
		file_sizes = make([]u32, len(files), context.temp_allocator),
		date       = record_date(epoch),
	}
	boot_len := file_size(boot_image) or_return
	w.boot_len = u32(boot_len)
	for f, i in files {
		if f.link != "" {
			continue
		}
		size := file_size(f.from) or_return
		if size > i64(max(u32)) {
			fmt.eprintfln("build: %s is too big for ISO 9660", f.from)
			return false
		}
		w.file_sizes[i] = u32(size)
	}
	for t in Iso_Tree {
		for i in 0 ..< len(dirs) {
			dirs[i].size[t] = dir_records(&w, i, t, nil, nil) or_return
		}
	}
	pt_size := [Iso_Tree]int {
		.Rock   = path_table(dirs[:], .Rock, false, nil),
		.Joliet = path_table(dirs[:], .Joliet, false, nil),
	}
	lba := u32(Iso_Fixed.Paths)
	path_lba: [Iso_Tree][2]u32 // little-endian, big-endian
	for t in Iso_Tree {
		for &p in path_lba[t] {
			p = lba
			lba += sectors(u64(pt_size[t]))
		}
	}
	for t in Iso_Tree {
		for &d in dirs {
			d.lba[t] = lba
			lba += d.size[t] / ISO_SECTOR
		}
	}
	for &d in dirs {
		d.ce_lba = lba
		lba += d.ce_size / ISO_SECTOR
	}
	w.catalog = lba
	lba += 1
	w.boot_lba = lba
	lba += sectors(u64(boot_len))
	w.file_lbas = make([]u32, len(files), context.temp_allocator)
	for f, i in files {
		if f.link == "" {
			w.file_lbas[i] = lba
			lba += sectors(u64(w.file_sizes[i]))
		}
	}
	total := lba

	// The metadata, everything before the boot image; the rest is copied in place.
	img := make([]u8, int(w.boot_lba) * ISO_SECTOR, context.temp_allocator)
	at :: proc(img: []u8, lba: u32) -> []u8 {return img[int(lba) * ISO_SECTOR:]}
	for t in Iso_Tree {
		path_table(dirs[:], t, false, at(img, path_lba[t][0]))
		path_table(dirs[:], t, true, at(img, path_lba[t][1]))
		for d, i in dirs {
			_ = dir_records(&w, i, t, at(img, d.lba[t]), t == .Rock ? at(img, d.ce_lba) : nil) or_return
		}
	}
	volume(at(img, u32(Iso_Fixed.Primary)), .Primary, total, pt_size[.Rock], path_lba[.Rock][0], path_lba[.Rock][1], &dirs[0], .Rock, w.date)
	volume(at(img, u32(Iso_Fixed.Supplementary)), .Supplementary, total, pt_size[.Joliet], path_lba[.Joliet][0], path_lba[.Joliet][1], &dirs[0], .Joliet, w.date)

	br := Iso_Boot_Record {
		header  = {.Boot_Record, ISO_ID, 1},
		catalog = u32le(w.catalog),
	}
	copy(br.system_id[:], "EL TORITO SPECIFICATION")
	copy(at(img, u32(Iso_Fixed.Boot_Record)), slice.bytes_from_ptr(&br, size_of(br)))

	term := Iso_Descriptor_Header{.Terminator, ISO_ID, 1}
	copy(at(img, u32(Iso_Fixed.Terminator)), slice.bytes_from_ptr(&term, size_of(term)))

	count512 := (boot_len + 511) / 512
	if count512 > i64(max(u16)) {
		fmt.eprintln("build: the ISO's boot image is too big for its catalog entry")
		return false
	}
	cat := Iso_Catalog {
		validation = {header_id = 1, platform = 0xef, key = {0x55, 0xaa}},
		initial = {indicator = 0x88, sector_count = u16le(count512), load_rba = u32le(w.boot_lba)},
	}
	sum: u16
	v := slice.bytes_from_ptr(&cat.validation, size_of(cat.validation))
	for i := 0; i < len(v); i += 2 {
		sum += u16(v[i]) | u16(v[i + 1]) << 8
	}
	cat.validation.checksum = u16le(~sum + 1)
	copy(at(img, w.catalog), slice.bytes_from_ptr(&cat, size_of(cat)))

	// The MBR: one partition, the boot image, in 512-byte sectors.
	mbr := Mbr {
		disk_id    = u32le(disk_id),
		partitions = {0 = {type = 0xef, first_lba = u32le(w.boot_lba * (ISO_SECTOR / SECTOR)), sectors = u32le(count512)}},
		signature  = {0x55, 0xaa},
	}
	copy(img, slice.bytes_from_ptr(&mbr, size_of(mbr)))

	f := create_sized(path, i64(total) * ISO_SECTOR) or_return
	defer os.close(f)
	write_at(f, path, img, 0) or_return
	copy_into(f, path, boot_image, i64(w.boot_lba) * ISO_SECTOR) or_return
	for file, i in files {
		if file.link == "" {
			copy_into(f, path, file.from, i64(w.file_lbas[i]) * ISO_SECTOR) or_return
		}
	}
	return true
}

@(private="file")
file_size :: proc(path: string) -> (size: i64, ok: bool) {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot stat %s: %v", path, err)
		return 0, false
	}
	return fi.size, true
}

// Copies the file at from into f at offset at, a chunk at a time.
@(private="file")
copy_into :: proc(f: ^os.File, path, from: string, at: i64) -> bool {
	in_file, err := os.open(from)
	if err != nil {
		fmt.eprintfln("build: cannot read %s: %v", from, err)
		return false
	}
	defer os.close(in_file)
	buf: [64 * 1024]u8
	off := at
	for {
		n, rerr := os.read(in_file, buf[:])
		if rerr == .EOF || (rerr == nil && n == 0) {
			return true
		}
		if rerr != nil {
			fmt.eprintfln("build: cannot read %s: %v", from, rerr)
			return false
		}
		write_at(f, path, buf[:n], off) or_return
		off += i64(n)
	}
}

// --- The isofs tests' image ---

// The ISO the isofs tests read (tests/host/iso, tests/qemu/m5/isofs.ndb),
// as upstream's make_test_iso makes it, with Rock Ridge and Joliet: a long
// name (past one record: a continuation area), UTF-8 (past the BMP: a
// surrogate pair in Joliet), two names differing only in case (one ISO 9660
// name gets ~1), a deep directory, symbolic links (relative, absolute, up a
// level), and a file of many sectors.
ISO_LONG_NAME :: "A Long Mixed-Case Name That Goes On And On, Past What One Directory Record Can Hold, So Its Rock " + "Ridge NM Entry Has To Continue In The Directory's Continuation Area, Which Is The Point Of It.txt"

// The big file's byte i, here, in tests/host/iso and in the FAT fixtures.
big_byte :: proc(i: int) -> u8 {
	return u8((i * 7 + i / 251) & 0xff)
}

// The SOURCE_DATE_EPOCH tests/host/iso's image was written at (by upstream's
// write_iso), which ./build check makes this one at, to compare them.
TEST_ISO_EPOCH :: 1759536000

make_test_iso :: proc(path: string, epoch: i64) -> bool {
	src := fmt.tprintf("%s.src", path)
	for d in ([]string{"deep/er/still/deeper", "dir with spaces"}) {
		make_dirs(fmt.tprintf("%s/%s", src, d)) or_return
	}
	Entry :: struct {
		path, text, link: string,
	}
	ENTRIES :: [?]Entry {
		{"README.txt", "readme\n", ""},
		{ISO_LONG_NAME, "long\n", ""},
		{"\xc3\x9cn\xc3\xaf" + "code file.txt", "unicode\n", ""},
		{"\xf0\x9f\x98\x80 smile.txt", "smile\n", ""},
		{"deep/er/still/deeper/file.txt", "deep\n", ""},
		{"dir with spaces/same name.txt", "lower\n", ""},
		{"dir with spaces/Same Name.txt", "upper\n", ""},
		{"link-to-readme", "", "README.txt"},
		{"abs-link", "", "/boot/limine/limine.conf"},
		{"deep/er/up-link", "", "../../dir with spaces/./same name.txt"},
	}
	files := make([dynamic]Iso_File, context.temp_allocator)
	for e, i in ENTRIES {
		f := Iso_File{path = e.path, link = e.link}
		if e.text != "" {
			f.from = fmt.tprintf("%s/f%d", src, i)
			write_file(f.from, e.text) or_return
		}
		append(&files, f)
	}
	big := make([]u8, 300_000, context.temp_allocator)
	for &b, i in big {
		b = big_byte(i)
	}
	append(&files, Iso_File{path = "big.bin", from = fmt.tprintf("%s/big", src)})
	write_file(files[len(files) - 1].from, string(big)) or_return
	boot := fmt.tprintf("%s/boot.img", src) // El Torito needs one; nothing boots it
	write_file(boot, string(make([]u8, 4096, context.temp_allocator))) or_return
	return write_iso(path, boot, files[:], 0x1234_5678, epoch)
}
