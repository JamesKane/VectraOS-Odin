package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// The CD image (image --iso, M3's deliverables): ISO 9660 with El Torito,
// for UEFI. Its El Torito boot entry ("no emulation", platform EFI) is a
// small FAT image holding only the loader; the loader then reads its
// configuration, the kernel and the modules from the ISO 9660 tree, as
// Limine does on a CD. An MBR in the system area also names the boot image
// as a partition (type EFI), as xorriso's --efi-boot-part does: that is how
// Limine finds which volume it was booted from. Names are plain ISO 9660
// (upper case, "NAME.EXT;1"), which Limine matches case-insensitively.
// Every date is SOURCE_DATE_EPOCH and everything else follows from the
// inputs, so one commit always gives the same image.
//
// The image is written a piece at a time at its offsets, as the disk image
// is: the descriptors, path tables and directories are a sector each, and
// the files are copied in chunks.

ISO_SECTOR :: 2048
ISO_MAX_DIRS :: 16

// A file in the ISO's tree.
Iso_File :: struct {
	path: string, // in the ISO: "boot/vx/kernel.elf"
	from: string, // where it is on this machine
}

// ISO 9660's both-endian fields: the value little-endian, then big-endian.
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

both16 :: proc(v: u16) -> Both16 {return {u16le(v), u16be(v)}}
both32 :: proc(v: u32) -> Both32 {return {u32le(v), u32be(v)}}

// A directory record's date (ECMA-119 9.1.5).
Iso_Record_Date :: struct #packed {
	year:   u8, // since 1900
	month:  u8,
	day:    u8,
	hour:   u8,
	minute: u8,
	second: u8,
	zone:   i8, // in 15-minute steps from GMT
}
#assert(size_of(Iso_Record_Date) == 7)

// A volume descriptor's date (8.4.26.1): "YYYYMMDDHHMMSScc", and the zone.
Iso_Volume_Date :: struct #packed {
	digits: [16]u8,
	zone:   i8,
}
#assert(size_of(Iso_Volume_Date) == 17)

Iso_File_Flag :: enum u8 {
	Hidden       = 0,
	Directory    = 1,
	Associated   = 2,
	Record       = 3,
	Protection   = 4,
	Multi_Extent = 7,
}

// A directory record (9.1), without its name, which follows it; the record
// is padded to an even length.
Iso_Record :: struct #packed {
	length:     u8,
	ext_length: u8,
	extent:     Both32,
	size:       Both32,
	date:       Iso_Record_Date,
	flags:      bit_set[Iso_File_Flag;u8],
	unit_size:  u8,
	gap:        u8,
	volume_seq: Both16,
	name_len:   u8,
}
#assert(size_of(Iso_Record) == 33)
#assert(offset_of(Iso_Record, flags) == 25)

// The root directory's record in the primary volume descriptor: its name is
// the one byte 0.
Iso_Root_Record :: struct #packed {
	record: Iso_Record,
	name:   u8,
}
#assert(size_of(Iso_Root_Record) == 34)

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
	Boot_Record = 0,
	Primary     = 1,
	Terminator  = 255,
}

// What starts every volume descriptor (8.1).
Iso_Descriptor_Header :: struct #packed {
	type:    Iso_Descriptor_Type,
	id:      [5]u8, // "CD001"
	version: u8,
}
#assert(size_of(Iso_Descriptor_Header) == 7)

ISO_ID :: [5]u8{'C', 'D', '0', '0', '1'}

// The primary volume descriptor (8.4).
Iso_Primary :: struct #packed {
	header:          Iso_Descriptor_Header,
	_:               u8,
	system_id:       [32]u8,
	volume_id:       [32]u8,
	_:               [8]u8,
	space_size:      Both32, // in sectors
	_:               [32]u8,
	set_size:        Both16,
	sequence:        Both16,
	block_size:      Both16,
	path_table_size: Both32,
	path_l:          u32le,
	path_l_opt:      u32le,
	path_m:          u32be,
	path_m_opt:      u32be,
	root:            Iso_Root_Record,
	set_id:          [128]u8,
	publisher:       [128]u8,
	preparer:        [128]u8,
	application:     [128]u8,
	copyright:       [37]u8,
	abstract:        [37]u8,
	bibliography:    [37]u8,
	created:         Iso_Volume_Date,
	modified:        Iso_Volume_Date,
	expires:         Iso_Volume_Date,
	effective:       Iso_Volume_Date,
	fs_version:      u8,
	_:               u8,
	application_use: [512]u8,
	_:               [653]u8,
}
#assert(size_of(Iso_Primary) == ISO_SECTOR)
#assert(offset_of(Iso_Primary, space_size) == 80)
#assert(offset_of(Iso_Primary, path_l) == 140)
#assert(offset_of(Iso_Primary, root) == 156)
#assert(offset_of(Iso_Primary, application) == 574)
#assert(offset_of(Iso_Primary, created) == 813)
#assert(offset_of(Iso_Primary, fs_version) == 881)

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

// The layout's fixed sectors: the system area is 0-15; then the descriptors
// and the path tables; the directories follow, a sector each.
@(private="file")
Iso_Fixed :: enum u32 {
	Primary     = 16,
	Boot_Record = 17,
	Terminator  = 18,
	Path_L      = 19,
	Path_M      = 20,
	Dirs        = 21,
}

@(private="file")
Iso_Dir :: struct {
	path:   string, // "" for the root
	name:   string, // as ISO 9660 names it
	parent: int, // its index in path table order
	lba:    u32,
}

// An entry in a directory: a subdirectory or a file.
@(private="file")
Iso_Entry :: struct {
	name:   string,
	lba:    u32,
	size:   u32,
	is_dir: bool,
}

// A path component as ISO 9660 names it: upper case; a file gets ".EXT;1".
@(private="file")
iso_name :: proc(name: string, is_file: bool) -> (out: string, ok: bool) {
	if len(name) > 30 { // 8.5.1: with ".;1", at most 31 characters
		fmt.eprintfln("build: %s is too long for an ISO 9660 name", name)
		return "", false
	}
	b := strings.builder_make(context.temp_allocator)
	dot := false
	for i in 0 ..< len(name) {
		c := name[i]
		if c >= 'a' && c <= 'z' {
			c -= 'a' - 'A'
		}
		valid := (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || (c == '.' && is_file && !dot)
		if !valid {
			fmt.eprintfln("build: %s cannot be an ISO 9660 name", name)
			return "", false
		}
		dot = dot || c == '.'
		strings.write_byte(&b, c)
	}
	if is_file {
		strings.write_string(&b, dot ? ";1" : ".;1")
	}
	return strings.to_string(b), true
}

@(private="file")
dir_of :: proc(path: string) -> string {
	slash := strings.last_index_byte(path, '/')
	return slash < 0 ? "" : path[:slash]
}

@(private="file")
base_of :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
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

// SOURCE_DATE_EPOCH (main sets it), as both kinds of ISO 9660 date, in GMT.
@(private="file")
iso_dates :: proc() -> (rec: Iso_Record_Date, vol: Iso_Volume_Date, ok: bool) {
	text := os.get_env("SOURCE_DATE_EPOCH", context.temp_allocator)
	secs, parsed := strconv.parse_i64(text)
	if !parsed {
		fmt.eprintfln("build: SOURCE_DATE_EPOCH=%s is not a number of seconds", text)
		return rec, vol, false
	}
	t := time.unix(secs, 0)
	year, month, day := time.date(t)
	hour, minute, second := time.clock(t)
	if year < 1900 || year > 1900 + 255 {
		fmt.eprintfln("build: SOURCE_DATE_EPOCH=%s is outside ISO 9660's years", text)
		return rec, vol, false
	}
	rec = {u8(year - 1900), u8(month), u8(day), u8(hour), u8(minute), u8(second), 0}
	digits := fmt.tprintf("%04d%02d%02d%02d%02d%02d00", year, int(month), day, hour, minute, second)
	copy(vol.digits[:], digits)
	return rec, vol, true
}

// A date that is not set (8.4.26.1): sixteen '0' digits.
@(private="file")
ISO_NO_DATE :: Iso_Volume_Date {
	digits = {0 ..< 16 = '0'},
}

// Fills a text field with s, padded with spaces (a- and d-characters).
@(private="file")
iso_text :: proc(field: []u8, s: string) {
	slice.fill(field, ' ')
	copy(field, s)
}

// Appends a directory record to the sector d at at; the new end.
@(private="file")
put_record :: proc(d: ^[ISO_SECTOR]u8, at: int, e: Iso_Entry, date: Iso_Record_Date) -> (end: int, ok: bool) {
	length := size_of(Iso_Record) + len(e.name) + (len(e.name) & 1 == 0 ? 1 : 0)
	if at + length > ISO_SECTOR {
		fmt.eprintln("build: an ISO directory does not fit a sector")
		return at, false
	}
	r := Iso_Record {
		length     = u8(length),
		extent     = both32(e.lba),
		size       = both32(e.size),
		date       = date,
		flags      = e.is_dir ? {.Directory} : {},
		volume_seq = both16(1),
		name_len   = u8(len(e.name)),
	}
	copy(d[at:], slice.bytes_from_ptr(&r, size_of(r)))
	copy(d[at + size_of(Iso_Record):], e.name)
	return at + length, true
}

@(private="file")
sectors :: proc(bytes: i64) -> u32 {
	return u32((bytes + ISO_SECTOR - 1) / ISO_SECTOR)
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

// Writes the ISO at path: boot_image is El Torito's entry, files the tree.
write_iso :: proc(path, boot_image: string, files: []Iso_File, disk_id: u32) -> bool {
	rec_date, vol_date := iso_dates() or_return

	// The directories, each file's and theirs, in path table order: by
	// depth, then by parent, then by name (9.4.3).
	all_dirs := make([dynamic]string, context.temp_allocator)
	for f in files {
		for d := dir_of(f.path); d != "" && !slice.contains(all_dirs[:], d); d = dir_of(d) {
			append(&all_dirs, d)
		}
	}
	dirs := make([dynamic]Iso_Dir, context.temp_allocator)
	append(&dirs, Iso_Dir{name = "\x00"})
	for depth := 1; len(dirs) < len(all_dirs) + 1; depth += 1 {
		first := len(dirs)
		for d in all_dirs {
			if depth_of(d) == depth {
				name := iso_name(base_of(d), false) or_return
				append(&dirs, Iso_Dir{path = d, name = name, parent = dir_index(dirs[:first], dir_of(d))})
			}
		}
		slice.sort_by(dirs[first:], proc(a, b: Iso_Dir) -> bool {
			return a.parent < b.parent || (a.parent == b.parent && a.name < b.name)
		})
	}
	if len(dirs) > ISO_MAX_DIRS {
		fmt.eprintln("build: too many directories for the ISO")
		return false
	}

	// The layout: the fixed sectors, a sector per directory, the boot
	// catalog, the boot image, then the files.
	lba := u32(Iso_Fixed.Dirs)
	for &d in dirs {
		d.lba = lba
		lba += 1
	}
	catalog_lba := lba
	lba += 1
	boot_size := file_size(boot_image) or_return
	boot_lba := lba
	lba += sectors(boot_size)
	file_lbas := make([]u32, len(files), context.temp_allocator)
	file_sizes := make([]u32, len(files), context.temp_allocator)
	for f, i in files {
		size := file_size(f.from) or_return
		if size > i64(max(u32)) {
			fmt.eprintfln("build: %s is too big for ISO 9660", f.from)
			return false
		}
		file_lbas[i], file_sizes[i] = lba, u32(size)
		lba += sectors(size)
	}
	total := lba

	iso := create_sized(path, i64(total) * ISO_SECTOR) or_return
	defer os.close(iso)
	sector_at :: proc(lba: u32) -> i64 {return i64(lba) * ISO_SECTOR}

	// The path tables, little-endian and big-endian.
	path_l, path_m: [ISO_SECTOR]u8
	pt_size := 0
	for d in dirs {
		length := size_of(Iso_Path_L) + len(d.name) + len(d.name) & 1
		if pt_size + length > ISO_SECTOR {
			fmt.eprintln("build: the ISO's path table does not fit a sector")
			return false
		}
		l := Iso_Path_L{u8(len(d.name)), 0, u32le(d.lba), u16le(d.parent + 1)}
		m := Iso_Path_M{u8(len(d.name)), 0, u32be(d.lba), u16be(d.parent + 1)}
		copy(path_l[pt_size:], slice.bytes_from_ptr(&l, size_of(l)))
		copy(path_m[pt_size:], slice.bytes_from_ptr(&m, size_of(m)))
		copy(path_l[pt_size + size_of(l):], d.name)
		copy(path_m[pt_size + size_of(m):], d.name)
		pt_size += length
	}
	write_at(iso, path, path_l[:], sector_at(u32(Iso_Fixed.Path_L))) or_return
	write_at(iso, path, path_m[:], sector_at(u32(Iso_Fixed.Path_M))) or_return

	// Each directory: ".", "..", then its children sorted by name.
	for d, i in dirs {
		entries := make([dynamic]Iso_Entry, context.temp_allocator)
		for sub in dirs[1:] {
			if sub.parent == i {
				append(&entries, Iso_Entry{sub.name, sub.lba, ISO_SECTOR, true})
			}
		}
		for f, k in files {
			if dir_of(f.path) == d.path {
				name := iso_name(base_of(f.path), true) or_return
				append(&entries, Iso_Entry{name, file_lbas[k], file_sizes[k], false})
			}
		}
		if i == 0 { // the boot pieces, in the root
			append(&entries, Iso_Entry{"BOOT.CAT;1", catalog_lba, ISO_SECTOR, false})
			append(&entries, Iso_Entry{"EFIBOOT.IMG;1", boot_lba, u32(boot_size), false})
		}
		slice.sort_by(entries[:], proc(a, b: Iso_Entry) -> bool {return a.name < b.name})
		sector: [ISO_SECTOR]u8
		at := put_record(&sector, 0, {"\x00", d.lba, ISO_SECTOR, true}, rec_date) or_return
		at = put_record(&sector, at, {"\x01", dirs[d.parent].lba, ISO_SECTOR, true}, rec_date) or_return
		for e in entries {
			at = put_record(&sector, at, e, rec_date) or_return
		}
		write_at(iso, path, sector[:], sector_at(d.lba)) or_return
	}

	pvd := Iso_Primary {
		header = {.Primary, ISO_ID, 1},
		space_size = both32(total),
		set_size = both16(1),
		sequence = both16(1),
		block_size = both16(ISO_SECTOR),
		path_table_size = both32(u32(pt_size)),
		path_l = u32le(Iso_Fixed.Path_L),
		path_m = u32be(Iso_Fixed.Path_M),
		root = {
			record = {
				length = size_of(Iso_Root_Record),
				extent = both32(dirs[0].lba),
				size = both32(ISO_SECTOR),
				date = rec_date,
				flags = {.Directory},
				volume_seq = both16(1),
				name_len = 1,
			},
		},
		created = vol_date,
		modified = vol_date,
		expires = ISO_NO_DATE,
		effective = ISO_NO_DATE,
		fs_version = 1,
	}
	iso_text(pvd.system_id[:], "")
	iso_text(pvd.volume_id[:], "VECTRAOS")
	iso_text(pvd.set_id[:], "")
	iso_text(pvd.publisher[:], "")
	iso_text(pvd.preparer[:], "")
	iso_text(pvd.application[:], "VECTRAOS BUILD")
	iso_text(pvd.copyright[:], "")
	iso_text(pvd.abstract[:], "")
	iso_text(pvd.bibliography[:], "")
	write_at(iso, path, slice.bytes_from_ptr(&pvd, size_of(pvd)), sector_at(u32(Iso_Fixed.Primary))) or_return

	br := Iso_Boot_Record {
		header  = {.Boot_Record, ISO_ID, 1},
		catalog = u32le(catalog_lba),
	}
	copy(br.system_id[:], "EL TORITO SPECIFICATION")
	write_at(iso, path, slice.bytes_from_ptr(&br, size_of(br)), sector_at(u32(Iso_Fixed.Boot_Record))) or_return

	term := Iso_Descriptor_Header{.Terminator, ISO_ID, 1}
	write_at(iso, path, slice.bytes_from_ptr(&term, size_of(term)), sector_at(u32(Iso_Fixed.Terminator))) or_return

	count512 := (boot_size + 511) / 512
	if count512 > i64(max(u16)) {
		fmt.eprintln("build: the ISO's boot image is too big for its catalog entry")
		return false
	}
	cat := Iso_Catalog {
		validation = {header_id = 1, platform = 0xef, key = {0x55, 0xaa}},
		initial = {indicator = 0x88, sector_count = u16le(count512), load_rba = u32le(boot_lba)},
	}
	sum: u16
	v := slice.bytes_from_ptr(&cat.validation, size_of(cat.validation))
	for i := 0; i < len(v); i += 2 {
		sum += u16(v[i]) | u16(v[i + 1]) << 8
	}
	cat.validation.checksum = u16le(~sum + 1)
	write_at(iso, path, slice.bytes_from_ptr(&cat, size_of(cat)), sector_at(catalog_lba)) or_return

	// The MBR: one partition, the boot image, in 512-byte sectors.
	mbr := Mbr {
		disk_id    = u32le(disk_id),
		partitions = {0 = {type = 0xef, first_lba = u32le(boot_lba * (ISO_SECTOR / SECTOR)), sectors = u32le(count512)}},
		signature  = {0x55, 0xaa},
	}
	write_at(iso, path, slice.bytes_from_ptr(&mbr, size_of(mbr)), 0) or_return

	copy_into(iso, path, boot_image, sector_at(boot_lba)) or_return
	for f, i in files {
		copy_into(iso, path, f.from, sector_at(file_lbas[i])) or_return
	}
	return true
}
