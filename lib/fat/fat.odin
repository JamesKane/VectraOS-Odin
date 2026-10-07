// FAT12, FAT16 and FAT32 (upstream docs/11 §11), for dosfs: the boot
// sector's BPB, the FAT's cluster chains, directories with long names, and
// files' bytes; and writing them (upstream M5 step 8b), and formatting a
// FAT32 volume (step 9c: install's ESP). After 9front's dossrv, as upstream's
// lib/vx-fat is. Pure code over a device's callbacks, so it builds for the
// host's tests as well as for dosfs.
//
// The volume is untrusted: every field of the boot sector is checked before
// it is used, every chain is bounded by the volume's cluster count, and every
// cluster, sector and slot index is checked before it is read.
//
// Writes go through to the device as they are made (the cache is
// write-through), in an order that leaves a volume a crash cuts short with,
// at worst, lost clusters, never one file's clusters in another: a file's
// clusters are taken in the FAT before its data is written and before its
// directory entry names them or its new size; a removed entry is marked
// free before its clusters are. Both FATs are written, and FAT32's FSInfo
// (its free count and next free cluster) at flush.
//
// A node is a directory entry's place: the first cluster of the directory
// it is in (0 for FAT12's and FAT16's fixed root) and the index of its short
// entry there. That is unique and lasts as long as the entry does, and is
// enough to find the entry's long name (the slots before it) and its parent
// (the directory's ".." entry, then the entry in the grandparent naming the
// directory). The root has no entry: it is ROOT.
//
// Names: a long name (UTF-16 in the format) is given as UTF-8; an entry with
// none gets its 8.3 name, lower-cased where Windows NT's flags say. Short
// names' bytes past ASCII are in a DOS code page that the volume does not
// name, and come out as U+FFFD. Lookups ignore ASCII case, as FAT does, and
// match an entry's long name or its 8.3 alias. Times are FAT's local time,
// taken as UTC: there are no time zones yet.
//
// Imports only the ABI and lib/utf, and allocates nothing.
package fat

import "base:intrinsics"
import vx "abi:vx"
import "vx:utf"

CACHE :: 32 // sectors cached
MAX_SECTOR :: 4096
// The longest name dir_next gives, as upstream's buffer holds it (255 runes
// of 3 bytes, and its NUL): 20 long-name slots hold 260 units, so a name
// past it is cut on a whole rune (upstream f24356f).
NAME_MAX :: 255 * 3 + 1
ALIAS_MAX :: 12 // "ALONGD~1.TXT"

// A device's callbacks. off and len(buf) are multiples of 512 (the boot
// sector), else of the volume's sector size.
Dev :: struct {
	ctx:   rawptr,
	read:  proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool,
	write: proc "contextless" (ctx: rawptr, off: u64, data: []u8) -> bool, // nil: read-only
	flush: proc "contextless" (ctx: rawptr) -> bool, // what was written is durable; nil: nothing to do
}

// A directory entry's attributes; on the disk, the byte whose bit i is the
// member with value i. Bits 6 and 7, which FAT does not define, are kept.
Attr :: enum u8 {
	Read_Only = 0,
	Hidden    = 1,
	System    = 2,
	Label     = 3,
	Directory = 4,
	Archive   = 5,
}
Attrs :: bit_set[Attr;u8]

// Read-only, hidden, system and label: a long name's slot.
LONG_NAME :: Attrs{.Read_Only, .Hidden, .System, .Label}
#assert(u8(Attr.Directory) == 4)

// Which FAT, by its entries' width in bits.
Kind :: enum u32 {
	Fat12 = 12,
	Fat16 = 16,
	Fat32 = 32,
}

// A directory entry's place (see above), or ROOT.
Node :: distinct u64
ROOT :: Node(1)

// --- The on-disk layout ---

// The BIOS parameter block, common to every FAT (offset 0 of the boot sector).
Bpb :: struct #packed {
	jump:                [3]u8,
	oem:                 [8]u8,
	bytes_per_sector:    u16le,
	sectors_per_cluster: u8,
	reserved:            u16le,
	fats:                u8,
	root_entries:        u16le,
	total16:             u16le,
	media:               u8,
	fat16:               u16le, // sectors per FAT, FAT12 and FAT16
	sectors_per_track:   u16le,
	heads:               u16le,
	hidden:              u32le,
	total32:             u32le,
}
#assert(size_of(Bpb) == 36)
#assert(offset_of(Bpb, bytes_per_sector) == 11)
#assert(offset_of(Bpb, root_entries) == 17)
#assert(offset_of(Bpb, fat16) == 22)
#assert(offset_of(Bpb, total32) == 32)

// The extended boot record: its signature says the serial, label and type are there.
Ebr :: struct #packed {
	drive:     u8,
	reserved:  u8,
	signature: u8, // EBR_SIGNATURE
	serial:    u32le,
	label:     [11]u8,
	fs_type:   [8]u8,
}
#assert(size_of(Ebr) == 26)
EBR_SIGNATURE :: 0x29

// The boot sector of FAT12 and FAT16.
Boot16 :: struct #packed {
	using bpb: Bpb,
	ebr:       Ebr,
	code:      [448]u8,
	signature: [2]u8, // 0x55 0xaa
}
#assert(size_of(Boot16) == 512)
#assert(offset_of(Boot16, ebr) + offset_of(Ebr, signature) == 38)
#assert(offset_of(Boot16, ebr) + offset_of(Ebr, label) == 43)

// The boot sector of FAT32.
Boot32 :: struct #packed {
	using bpb:    Bpb,
	fat32:        u32le, // sectors per FAT
	flags:        u16le,
	version:      u16le, // 0
	root_cluster: u32le,
	fsinfo:       u16le, // its sector
	backup:       u16le, // the boot sector's backup's sector
	reserved2:    [12]u8,
	ebr:          Ebr,
	code:         [420]u8,
	signature:    [2]u8,
}
#assert(size_of(Boot32) == 512)
#assert(offset_of(Boot32, version) == 42)
#assert(offset_of(Boot32, root_cluster) == 44)
#assert(offset_of(Boot32, fsinfo) == 48)
#assert(offset_of(Boot32, ebr) == 64)
#assert(offset_of(Boot32, ebr) + offset_of(Ebr, label) == 71)
#assert(offset_of(Boot32, signature) == 510)

// FAT32's FSInfo sector.
Fsinfo :: struct #packed {
	lead:      u32le, // FSINFO_LEAD
	reserved:  [480]u8,
	signature: u32le, // FSINFO_SIGNATURE
	free:      u32le, // free clusters, a hint
	next:      u32le, // where to look for one, a hint
	reserved2: [12]u8,
	trail:     u32le, // 0xaa550000
}
#assert(size_of(Fsinfo) == 512)
#assert(offset_of(Fsinfo, signature) == 484)
#assert(offset_of(Fsinfo, free) == 488)
FSINFO_LEAD :: 0x41615252
FSINFO_SIGNATURE :: 0x61417272

// A short entry: an 8.3 name, and the file's cluster, size and times.
Dir_Entry :: struct #packed {
	name:       [11]u8, // 8 and 3, padded with spaces
	attr:       Attrs,
	nt:         u8, // Windows NT's case flags: NT_LOWER_BASE, NT_LOWER_EXT
	ctime_ms:   u8,
	ctime:      u16le,
	cdate:      u16le,
	adate:      u16le,
	cluster_hi: u16le, // FAT32 only
	mtime:      u16le,
	mdate:      u16le,
	cluster_lo: u16le,
	size:       u32le,
}
#assert(size_of(Dir_Entry) == 32)
#assert(offset_of(Dir_Entry, attr) == 11)
#assert(offset_of(Dir_Entry, ctime) == 14)
#assert(offset_of(Dir_Entry, cluster_hi) == 20)
#assert(offset_of(Dir_Entry, mtime) == 22)
#assert(offset_of(Dir_Entry, cluster_lo) == 26)
#assert(offset_of(Dir_Entry, size) == 28)
NT_LOWER_BASE :: 0x08
NT_LOWER_EXT :: 0x10

// A long name's slot: 13 UTF-16 units of the name, in three runs.
Lfn_Entry :: struct #packed {
	seq:     u8, // 1 to 20, LFN_LAST on the name's last part (its first slot)
	name1:   [5]u16le,
	attr:    Attrs, // LONG_NAME
	type:    u8,
	sum:     u8, // the short name's checksum
	name2:   [6]u16le,
	cluster: u16le, // 0
	name3:   [2]u16le,
}
#assert(size_of(Lfn_Entry) == 32)
#assert(offset_of(Lfn_Entry, name1) == 1)
#assert(offset_of(Lfn_Entry, sum) == 13)
#assert(offset_of(Lfn_Entry, name2) == 14)
#assert(offset_of(Lfn_Entry, name3) == 28)
LFN_LAST :: 0x40
LFN_MAX_SLOTS :: 20

SLOT_FREE :: 0xe5 // a deleted entry's first byte
SLOT_END :: 0x00 // the directory's end

// A packed on-disk struct over the start of b: bounds-checked by the slice.
@(private="file")
view :: #force_inline proc "contextless" (b: []u8, $T: typeid) -> ^T where align_of(T) == 1 {
	return (^T)(raw_data(b[:size_of(T)]))
}

// A little-endian field at the start of b, which need not be aligned.
@(private="file")
load :: #force_inline proc "contextless" (b: []u8, $T: typeid) -> T where T == u16le || T == u32le {
	return intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))
}

@(private="file")
store_field :: #force_inline proc "contextless" (b: []u8, v: $T) where T == u16le || T == u32le {
	intrinsics.unaligned_store((^T)(raw_data(b[:size_of(T)])), v)
}

// --- The volume ---

@(private="file")
Cached :: struct {
	sector, last: u64,
	valid:        bool,
	data:         [MAX_SECTOR]u8,
}

Vol :: struct {
	dev:                 Dev,
	kind:                Kind,
	sector_size:         u32, // bytes
	sectors_per_cluster: u32,
	cluster_bytes:       u32,
	fat_start:           u32,
	fat_sectors:         u32,
	nfats:               u32,
	root_start:          u32, // FAT12's and FAT16's fixed root
	root_entries:        u32,
	root_cluster:        u32, // FAT32's root directory
	data_start:          u32, // cluster 2's first sector
	clusters:            u32, // valid clusters are 2 .. clusters + 1
	sectors:             u64,
	label:               [dynamic; 11]u8, // the BPB's, trailing spaces cut; empty if NO NAME
	now:                 i64, // the time writes stamp, seconds since 1970: the caller's to set
	free_hint:           u32, // where to look for a free cluster
	free_count:          u32, // how many (FSInfo's on FAT32); FREE_UNKNOWN until counted
	fsinfo_sector:       u32, // FAT32's FSInfo, or 0
	fsinfo_dirty:        bool,
	cache:               [CACHE]Cached,
	tick:                u64,
}

FREE_UNKNOWN :: max(u32)

volume_label :: proc "contextless" (v: ^Vol) -> string {
	return string(v.label[:])
}

// A directory entry, or the root's. It holds its names itself, so it may be
// copied and returned by value.
Entry :: struct {
	node:                 Node,
	attr:                 Attrs,
	cluster:              u32, // the first; 0 for an empty file
	size:                 u32, // bytes; 0 for a directory
	mtime, atime, ctime:  i64, // seconds since 1970, as UTC
	name:                 [dynamic; NAME_MAX]u8, // UTF-8
	alias:                [dynamic; ALIAS_MAX]u8, // the 8.3 name, as stored
	// read's place in the chain, kept between reads of the same entry so a
	// file read in order is not walked from its start each time: the
	// at_index-th cluster is at_cluster (0: none yet).
	at_cluster:           u32,
	at_index:             u64,
}

// A name and an alias end at a NUL, as upstream's C strings do: a short name
// on a damaged volume may hold one (found by tests/host/mount, M6 step 6d10).
entry_name :: proc "contextless" (e: ^Entry) -> string {
	return before_nul(e.name[:])
}

entry_alias :: proc "contextless" (e: ^Entry) -> string {
	return before_nul(e.alias[:])
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

// A sector, through the cache: ok is false if the device fails. The bytes
// are the cache's: change them, then store the sector.
@(private="file")
sector_of :: proc "contextless" (v: ^Vol, sector: u64) -> (s: []u8, ok: bool) {
	victim := 0
	for &c, i in v.cache {
		if c.valid && c.sector == sector {
			v.tick += 1
			c.last = v.tick
			return c.data[:v.sector_size], true
		}
		if !c.valid || c.last < v.cache[victim].last {
			victim = i
		}
	}
	line := &v.cache[victim]
	line.valid = false // until a read fills it: a failed one leaves no stale sector behind
	if sector >= v.sectors || !v.dev.read(v.dev.ctx, sector * u64(v.sector_size), line.data[:v.sector_size]) {
		return nil, false
	}
	v.tick += 1
	line.sector, line.valid, line.last = sector, true, v.tick
	return line.data[:v.sector_size], true
}

// --- Mounting ---

@(private="file")
pow2 :: proc "contextless" (x: u32) -> bool {
	return x != 0 && x & (x - 1) == 0
}

// The volume on dev, from its boot sector. Err_Invalid if it is not FAT.
@(require_results)
mount :: proc "contextless" (v: ^Vol, dev: Dev) -> vx.Status {
	v^ = {}
	v.dev = dev
	boot: [512]u8
	if !dev.read(dev.ctx, 0, boot[:]) {
		return .Err_Io
	}
	b := view(boot[:], Bpb)
	b32 := view(boot[:], Boot32)
	sector_size, spc, reserved, nfats := u32(b.bytes_per_sector), u32(b.sectors_per_cluster), u32(b.reserved), u32(b.fats)
	root_entries := u32(b.root_entries)
	if (boot[0] != 0xeb && boot[0] != 0xe9) || boot[510] != 0x55 || boot[511] != 0xaa {
		return .Err_Invalid
	}
	if sector_size < 512 || sector_size > MAX_SECTOR || !pow2(sector_size) || !pow2(spc) || spc > 128 || reserved == 0 || nfats == 0 {
		return .Err_Invalid
	}
	sectors := b.total16 != 0 ? u64(b.total16) : u64(b.total32)
	fat_sectors := b.fat16 != 0 ? u32(b.fat16) : u32(b32.fat32)
	root_sectors := (root_entries * 32 + sector_size - 1) / sector_size
	data_start := u64(reserved) + u64(nfats) * u64(fat_sectors) + u64(root_sectors)
	if fat_sectors == 0 || sectors == 0 || data_start >= sectors {
		return .Err_Invalid
	}
	clusters := (sectors - data_start) / u64(spc)
	// The type is the cluster count's, as Microsoft's specification has it.
	v.kind = .Fat32
	if clusters < 65525 {
		v.kind = .Fat16
	}
	if clusters < 4085 {
		v.kind = .Fat12
	}
	if (v.kind == .Fat32) != (root_entries == 0) || clusters > 0x0fff_fff5 {
		return .Err_Invalid
	}
	// The FAT must have an entry for every cluster.
	if u64(fat_sectors) * u64(sector_size) * 8 / u64(v.kind) < clusters + 2 {
		return .Err_Invalid
	}
	v.sector_size, v.sectors_per_cluster, v.cluster_bytes = sector_size, spc, sector_size * spc
	v.fat_start, v.fat_sectors, v.nfats = reserved, fat_sectors, nfats
	// Less than data_start, which is less than sectors (at most 2^32 - 1): no overflow.
	v.root_start, v.root_entries = reserved + nfats * fat_sectors, root_entries
	v.data_start, v.clusters, v.sectors = u32(data_start), u32(clusters), sectors
	ebr := &view(boot[:], Boot16).ebr
	if v.kind == .Fat32 {
		v.root_cluster = u32(b32.root_cluster)
		ebr = &b32.ebr
		if b32.version != 0 || v.root_cluster < 2 || v.root_cluster > v.clusters + 1 {
			return .Err_Invalid
		}
	}
	v.free_hint, v.free_count = 2, FREE_UNKNOWN // not known until counted
	if v.kind == .Fat32 && b32.fsinfo != 0 && u32(b32.fsinfo) < reserved {
		v.fsinfo_sector = u32(b32.fsinfo)
	}
	if ebr.signature == EBR_SIGNATURE { // the label is there
		n := len(ebr.label)
		for n > 0 && ebr.label[n - 1] == ' ' {
			n -= 1
		}
		// Upstream compares 8 bytes with "NO NAME" and its NUL: the label as
		// cut is exactly NO NAME.
		if string(ebr.label[:n]) != "NO NAME" {
			append(&v.label, ..ebr.label[:n])
		}
	}
	return .Ok
}

// --- The FAT ---

@(private="file")
cluster_sector :: proc "contextless" (v: ^Vol, c: u32) -> u64 {
	return u64(v.data_start) + u64(c - 2) * u64(v.sectors_per_cluster)
}

@(private="file")
valid :: proc "contextless" (v: ^Vol, c: u32) -> bool {
	return c >= 2 && c <= v.clusters + 1
}

// The FAT's byte at off (from the first FAT's start).
@(private="file")
fat_byte :: proc "contextless" (v: ^Vol, off: u64) -> (b: u32, ok: bool) {
	s := sector_of(v, u64(v.fat_start) + off / u64(v.sector_size)) or_return
	return u32(s[off % u64(v.sector_size)]), true
}

// The first FAT's entry for cluster c, as it is: 0 free, an end or bad
// mark, or the next cluster.
@(require_results)
raw_entry :: proc "contextless" (v: ^Vol, c: u32) -> (e: u32, st: vx.Status) {
	if v.kind == .Fat12 {
		off := u64(c) + u64(c / 2)
		lo, lok := fat_byte(v, off)
		hi, hok := fat_byte(v, off + 1)
		if !lok || !hok {
			return 0, .Err_Io
		}
		e = lo | hi << 8
		return c & 1 != 0 ? e >> 4 : e & 0xfff, .Ok
	}
	off := u64(c) * u64(v.kind) / 8
	s, ok := sector_of(v, u64(v.fat_start) + off / u64(v.sector_size)) // entries never straddle sectors
	if !ok {
		return 0, .Err_Io
	}
	at := off % u64(v.sector_size)
	if v.kind == .Fat16 {
		return u32(load(s[at:], u16le)), .Ok
	}
	return u32(load(s[at:], u32le)) & 0x0fff_ffff, .Ok
}

@(private="file")
end_mark :: proc "contextless" (v: ^Vol) -> u32 {
	switch v.kind {
	case .Fat12:
		return 0xff8
	case .Fat16:
		return 0xfff8
	case .Fat32:
		return 0x0fff_fff8
	}
	return 0
}

// The cluster after c: next is 0 at the chain's end. Err_Io if the FAT is
// broken there (a free or bad cluster, or one out of range, in a chain).
@(require_results)
next_cluster :: proc "contextless" (v: ^Vol, c: u32) -> (next: u32, st: vx.Status) {
	if !valid(v, c) {
		return 0, .Err_Io
	}
	end := end_mark(v)
	e := raw_entry(v, c) or_return
	if e >= end {
		return 0, .Ok
	}
	if e == end - 1 || !valid(v, e) { // a bad cluster's mark, or out of range
		return 0, .Err_Io
	}
	return e, .Ok
}

// The chain's k-th cluster from c (0: c itself); 0 if the chain ends first.
@(private="file", require_results)
walk :: proc "contextless" (v: ^Vol, c: u32, k: u64) -> (out: u32, st: vx.Status) {
	if k > u64(v.clusters) {
		return 0, .Err_Io // longer than the volume: a loop
	}
	c, k := c, k
	for ; k != 0 && c != 0; k -= 1 {
		c = next_cluster(v, c) or_return
	}
	return c, .Ok
}

// --- Directories ---

Iter :: struct {
	dir:     u32, // its first cluster; 0: the fixed root
	cluster: u32, // the one index is in (not the fixed root's)
	index:   u32, // the next slot
	steps:   u32, // clusters followed, against loops
}

// Slots a directory may have: what a node's index field holds.
@(private="file")
MAX_SLOTS :: 1 << 21

@(private="file")
iter_at :: proc "contextless" (v: ^Vol, dir: u32) -> Iter {
	dir := dir
	if v.kind == .Fat32 && dir == 0 {
		dir = v.root_cluster // ".." naming the root
	}
	return Iter{dir = dir, cluster = dir}
}

@(private="file")
dir_of :: proc "contextless" (v: ^Vol, node: Node) -> u32 {
	if node != ROOT {
		return u32(u64(node) >> 21) & 0x0fff_ffff
	}
	return v.kind == .Fat32 ? v.root_cluster : 0
}

@(private="file")
index_of :: proc "contextless" (node: Node) -> u32 {
	return u32(u64(node) & (MAX_SLOTS - 1))
}

@(private="file")
node_at :: proc "contextless" (dir, index: u32) -> Node {
	return Node(1 << 62 | u64(dir) << 21 | u64(index))
}

// The slot at it.index, and the iterator past it. Err_Not_Found past the end.
@(private="file", require_results)
next_slot :: proc "contextless" (v: ^Vol, it: ^Iter) -> (slot: []u8, st: vx.Status) {
	off := u64(it.index) * 32
	sector: u64
	if it.dir == 0 {
		if it.index >= v.root_entries {
			return nil, .Err_Not_Found
		}
		sector = u64(v.root_start) + off / u64(v.sector_size)
	} else {
		if it.index >= MAX_SLOTS {
			return nil, .Err_Not_Found
		}
		if it.index != 0 && off % u64(v.cluster_bytes) == 0 { // into the next cluster
			it.steps += 1
			if it.steps > v.clusters {
				return nil, .Err_Io
			}
			it.cluster = next_cluster(v, it.cluster) or_return
		}
		if it.cluster == 0 {
			return nil, .Err_Not_Found
		}
		sector = cluster_sector(v, it.cluster) + off % u64(v.cluster_bytes) / u64(v.sector_size)
	}
	s, ok := sector_of(v, sector)
	if !ok {
		return nil, .Err_Io
	}
	it.index += 1
	at := off % u64(v.sector_size)
	return s[at:at + 32], .Ok
}

@(private="file")
checksum :: proc "contextless" (short_name: ^[11]u8) -> u8 {
	sum: u8
	for c in short_name {
		sum = (sum & 1) << 7 + sum >> 1 + c
	}
	return sum
}

@(private="file")
put_rune :: proc "contextless" (out: ^[dynamic; NAME_MAX]u8, c: rune) {
	buf: [utf.UTF_MAX]u8
	n := utf.encode(&buf, c)
	_ = append(out, ..buf[:n]) // dir_next stops while 4 bytes are left
}

// FAT's date and time (local, taken as UTC) as seconds since 1970.
@(private="file")
from_stamp :: proc "contextless" (date, time: u16le) -> i64 {
	if date == 0 {
		return 0
	}
	y := 1980 + i64(date >> 9)
	m, d := u32(date >> 5 & 15), u32(date & 31)
	if m < 1 || m > 12 || d < 1 {
		return 0
	}
	if m <= 2 {
		y -= 1
	}
	era := (y >= 0 ? y : y - 399) / 400
	yoe := u32(y - era * 400)
	doy := (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	days := era * 146097 + i64(doe) - 719468
	return days * 86400 + i64(time >> 11) * 3600 + i64(time >> 5 & 63) * 60 + i64(time & 31) * 2
}

// The 8.3 name as a file name, "README.TXT", lower-cased where NT's flags
// say; or, as_alias, its bytes as stored. Into out, which has room.
@(private="file")
short_name :: proc "contextless" (d: ^Dir_Entry, out: []u8, apply_case, as_alias: bool) -> (n: int) {
	for part in 0 ..< 2 {
		from, length := part == 1 ? 8 : 0, part == 1 ? 3 : 8
		for length > 0 && d.name[from + length - 1] == ' ' {
			length -= 1
		}
		if part == 1 && length > 0 {
			out[n] = '.'
			n += 1
		}
		lower := apply_case && d.nt & (part == 1 ? NT_LOWER_EXT : NT_LOWER_BASE) != 0
		for i in 0 ..< length {
			c := d.name[from + i]
			if i == 0 && part == 0 && c == 0x05 {
				c = 0xe5 // a name that starts with 0xe5
			}
			switch {
			case as_alias:
				out[n] = c
				n += 1
			case c >= 0x80:
				buf: [utf.UTF_MAX]u8
				k := utf.encode(&buf, utf.RUNE_ERROR)
				n += copy(out[n:], buf[:k])
			case:
				out[n] = lower && c >= 'A' && c <= 'Z' ? c + 32 : c
				n += 1
			}
		}
	}
	return n
}

@(private="file")
is_long_name :: proc "contextless" (a: Attrs) -> bool {
	return a & {.Read_Only, .Hidden, .System, .Label, .Directory, .Archive} == LONG_NAME
}

// Where a long-name slot keeps its 13 units.
@(private="file", rodata)
LFN_UNITS := [13]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}

@(private="file")
entry_cluster :: proc "contextless" (v: ^Vol, d: ^Dir_Entry) -> u32 {
	hi := v.kind == .Fat32 ? u32(d.cluster_hi) << 16 : 0
	return hi | u32(d.cluster_lo)
}

// The next entry in the directory, its long name assembled: Err_Not_Found
// at its end. Deleted entries, the volume label, "." and ".." are skipped;
// so are long-name slots whose sequence or checksum do not hold.
@(require_results)
dir_next :: proc "contextless" (v: ^Vol, it: ^Iter, e: ^Entry) -> vx.Status {
	units: [LFN_MAX_SLOTS * 13]u16
	expect, count := 0, 0 // the next long-name slot's sequence number; the name's slots
	sum: u8
	for {
		s := next_slot(v, it) or_return
		if s[0] == SLOT_END {
			return .Err_Not_Found
		}
		if s[0] == SLOT_FREE {
			expect = 0
			continue
		}
		d := view(s, Dir_Entry)
		if is_long_name(d.attr) {
			l := view(s, Lfn_Entry)
			seq := int(l.seq & 0x1f)
			if l.seq & LFN_LAST != 0 { // the name's last part, its first slot
				if seq < 1 || seq > LFN_MAX_SLOTS {
					expect = 0
					continue
				}
				count, sum = seq, l.sum
			} else if seq < 1 || seq != expect || l.sum != sum { // 0 would index before units
				expect = 0
				continue
			}
			for at, i in LFN_UNITS {
				units[(seq - 1) * 13 + i] = u16(load(s[at:], u16le))
			}
			expect = seq - 1
			continue
		}
		have_long := expect == 0 && count != 0 && checksum(&d.name) == sum
		expect = 0
		n := count
		count = 0
		if .Label in d.attr && .Directory not_in d.attr {
			continue // the volume label
		}
		if s[0] == '.' && (s[1] == ' ' || (s[1] == '.' && s[2] == ' ')) {
			continue
		}
		e^ = Entry {
			node    = node_at(it.dir, it.index - 1),
			attr    = d.attr,
			cluster = entry_cluster(v, d),
			size    = .Directory in d.attr ? 0 : u32(d.size),
			mtime   = from_stamp(d.mdate, d.mtime),
			atime   = from_stamp(d.adate, 0),
			ctime   = from_stamp(d.cdate, d.ctime),
		}
		alias: [ALIAS_MAX]u8
		_ = append(&e.alias, ..alias[:short_name(d, alias[:], false, true)])
		if have_long {
			for i := 0; i < n * 13 && units[i] != 0 && units[i] != 0xffff; i += 1 {
				c := rune(units[i])
				if c >= 0xd800 && c < 0xdc00 && i + 1 < n * 13 && units[i + 1] >= 0xdc00 && units[i + 1] < 0xe000 {
					i += 1
					c = 0x10000 + (c - 0xd800) << 10 + (rune(units[i]) - 0xdc00)
				} else if c >= 0xd800 && c < 0xe000 {
					c = utf.RUNE_ERROR // a lone surrogate
				}
				if c == '/' || c == 0 {
					c = utf.RUNE_ERROR
				}
				if len(e.name) + 4 >= NAME_MAX {
					break // 20 slots hold 260 units, past a name's 255: cut, as upstream's
				}
				put_rune(&e.name, c)
			}
		}
		if len(e.name) == 0 {
			name: [11 * utf.UTF_MAX + 1]u8
			_ = append(&e.name, ..name[:short_name(d, name[:], true, false)])
		}
		return .Ok
	}
}

// Whether name is a's, ignoring ASCII case.
@(private="file")
same_name :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if x >= 'a' && x <= 'z' {
			x -= 32
		}
		if y >= 'a' && y <= 'z' {
			y -= 32
		}
		if x != y {
			return false
		}
	}
	return true
}

// The root, as an entry.
root_entry :: proc "contextless" (v: ^Vol) -> (e: Entry) {
	e = Entry {
		node    = ROOT,
		attr    = {.Directory},
		cluster = v.kind == .Fat32 ? v.root_cluster : 0,
	}
	_ = append(&e.name, '/')
	return e
}

// An iterator over directory d's entries, for dir_next.
@(require_results)
open_dir :: proc "contextless" (v: ^Vol, d: ^Entry) -> (it: Iter, st: vx.Status) {
	if .Directory not_in d.attr {
		return {}, .Err_Invalid
	}
	it = iter_at(v, d.node == ROOT ? dir_of(v, ROOT) : d.cluster)
	if it.dir == 0 && d.node != ROOT {
		return it, .Err_Io // a directory with no cluster
	}
	return it, .Ok
}

// The entry named name in directory d (an entry with .Directory, or the root's).
@(require_results)
lookup :: proc "contextless" (v: ^Vol, d: ^Entry, name: string, e: ^Entry) -> vx.Status {
	it := open_dir(v, d) or_return
	for {
		dir_next(v, &it, e) or_return
		if same_name(entry_name(e), name) || same_name(entry_alias(e), name) {
			return .Ok
		}
	}
}

// The entry for a node.
@(require_results)
get :: proc "contextless" (v: ^Vol, node: Node, e: ^Entry) -> vx.Status {
	if node == ROOT {
		e^ = root_entry(v)
		return .Ok
	}
	if u64(node) >> 62 == 0 {
		return .Err_Not_Found
	}
	dir := dir_of(v, node)
	it := Iter{dir = dir, cluster = dir}
	for {
		#partial switch st := dir_next(v, &it, e); st {
		case .Ok:
			if e.node == node {
				return .Ok
			}
			if e.node > node {
				return .Err_Not_Found // past it: the entry is gone
			}
		case .Err_Not_Found:
			return .Err_Not_Found
		case:
			return st
		}
	}
}

// The directory node holding a node: the root, or the entry, in its own
// parent, naming the directory the node is in.
@(require_results)
parent :: proc "contextless" (v: ^Vol, node: Node) -> (up: Node, st: vx.Status) {
	dir := dir_of(v, node)
	if node == ROOT || dir == dir_of(v, ROOT) {
		return ROOT, .Ok
	}
	// The directory's ".." (its second slot) names the grandparent's cluster.
	it := Iter{dir = dir, cluster = dir, index = 1}
	s, sst := next_slot(v, &it)
	if sst != .Ok {
		return 0, sst == .Err_Not_Found ? .Err_Io : sst
	}
	if s[0] != '.' || s[1] != '.' {
		return 0, .Err_Io
	}
	g := iter_at(v, entry_cluster(v, view(s, Dir_Entry)))
	e: Entry
	for {
		if st = dir_next(v, &g, &e); st != .Ok {
			return 0, st == .Err_Not_Found ? .Err_Io : st
		}
		if .Directory in e.attr && e.cluster == dir {
			return e.node, .Ok
		}
	}
}

// --- Files ---

// Up to len(buf) bytes of a file from offset into buf; n, what was read (0
// at or past the end). f's place in its chain is kept, for the next read.
@(require_results)
read :: proc "contextless" (v: ^Vol, f: ^Entry, offset: u64, buf: []u8) -> (n: u32, st: vx.Status) {
	if .Directory in f.attr {
		return 0, .Err_Invalid
	}
	if offset >= u64(f.size) {
		return 0, .Ok
	}
	count := u32(min(u64(len(buf)), u64(f.size) - offset))
	offset := offset
	index := offset / u64(v.cluster_bytes)
	ahead := f.at_cluster != 0 && f.at_index <= index
	c: u32
	c, st = walk(v, ahead ? f.at_cluster : f.cluster, ahead ? index - f.at_index : index)
	for done: u32 = 0; st == .Ok && done < count; {
		if c == 0 {
			return 0, .Err_Io // the chain is shorter than the file
		}
		inside := u32(offset % u64(v.cluster_bytes))
		sector := cluster_sector(v, c) + u64(inside / v.sector_size)
		at := inside % v.sector_size
		k := min(v.sector_size - at, count - done)
		if at == 0 && k == v.sector_size { // whole sectors, as many as the cluster has: past the cache
			run := min((v.cluster_bytes - inside) / v.sector_size, (count - done) / v.sector_size)
			k = run * v.sector_size
			if !v.dev.read(v.dev.ctx, sector * u64(v.sector_size), buf[done:][:k]) {
				return 0, .Err_Io
			}
		} else {
			s, ok := sector_of(v, sector)
			if !ok {
				return 0, .Err_Io
			}
			copy(buf[done:][:k], s[at:])
		}
		f.at_cluster, f.at_index = c, index
		done += k
		offset += u64(k)
		if offset % u64(v.cluster_bytes) == 0 && done < count {
			c, st = next_cluster(v, c)
			index += 1
		}
	}
	return count, st
}

// --- Writing ---

// Zeros, for gaps, new clusters and formatting.
@(private="file", rodata)
ZEROS := [64 * 512]u8{}
#assert(len(ZEROS) >= MAX_SECTOR)

// count sectors written from data: to the device, and to their cached copies.
@(private="file")
store :: proc "contextless" (v: ^Vol, sector: u64, count: u32, data: []u8) -> bool {
	if v.dev.write == nil || sector + u64(count) > v.sectors {
		return false
	}
	bytes := count * v.sector_size
	if !v.dev.write(v.dev.ctx, sector * u64(v.sector_size), data[:bytes]) {
		return false
	}
	for &c in v.cache {
		if c.valid && c.sector >= sector && c.sector < sector + u64(count) {
			from := (c.sector - sector) * u64(v.sector_size)
			copy(c.data[:v.sector_size], data[from:][:v.sector_size])
		}
	}
	return true
}

// A byte of FAT copy f, changed: its sector stored.
@(private="file")
set_byte :: proc "contextless" (v: ^Vol, f: u32, off: u64, keep, value: u8) -> bool {
	sector := u64(v.fat_start) + u64(f) * u64(v.fat_sectors) + off / u64(v.sector_size)
	s := sector_of(v, sector) or_return
	at := off % u64(v.sector_size)
	s[at] = s[at] & keep | value
	return store(v, sector, 1, s)
}

// Cluster c's entry set to value, in every FAT.
@(private="file", require_results)
set_entry :: proc "contextless" (v: ^Vol, c: u32, value: u32) -> vx.Status {
	if !valid(v, c) {
		return .Err_Io
	}
	for f in 0 ..< v.nfats {
		ok: bool
		if v.kind == .Fat12 {
			off := u64(c) + u64(c / 2)
			if c & 1 != 0 {
				ok = set_byte(v, f, off, 0x0f, u8(value << 4 & 0xff)) && set_byte(v, f, off + 1, 0, u8(value >> 4 & 0xff))
			} else {
				ok = set_byte(v, f, off, 0, u8(value & 0xff)) && set_byte(v, f, off + 1, 0xf0, u8(value >> 8 & 15))
			}
		} else {
			off := u64(c) * u64(v.kind) / 8
			sector := u64(v.fat_start) + u64(f) * u64(v.fat_sectors) + off / u64(v.sector_size)
			s, read_ok := sector_of(v, sector)
			if !read_ok {
				return .Err_Io
			}
			at := off % u64(v.sector_size)
			if v.kind == .Fat16 {
				store_field(s[at:], u16le(value & 0xffff))
			} else {
				store_field(s[at:], load(s[at:], u32le) & 0xf000_0000 | u32le(value & 0x0fff_ffff))
			}
			ok = store(v, sector, 1, s)
		}
		if !ok {
			return .Err_Io
		}
	}
	return .Ok
}

// The free clusters, counted once (FAT32's FSInfo may say, but is only a hint).
@(private="file", require_results)
count_free :: proc "contextless" (v: ^Vol) -> vx.Status {
	if v.free_count != FREE_UNKNOWN {
		return .Ok
	}
	n: u32
	for c: u32 = 2; c <= v.clusters + 1; c += 1 {
		e := raw_entry(v, c) or_return
		if e == 0 {
			n += 1
		}
	}
	v.free_count = n
	return .Ok
}

// Zeros over a cluster's sectors.
@(private="file", require_results)
zero_cluster :: proc "contextless" (v: ^Vol, c: u32) -> vx.Status {
	for i in 0 ..< v.sectors_per_cluster {
		if !store(v, cluster_sector(v, c) + u64(i), 1, ZEROS[:]) {
			return .Err_Io
		}
	}
	return .Ok
}

// A free cluster, marked as a chain's end, and linked after prev (0: none).
@(private="file", require_results)
alloc :: proc "contextless" (v: ^Vol, prev: u32) -> (out: u32, st: vx.Status) {
	count_free(v) or_return
	if v.free_count == 0 {
		return 0, .Err_No_Space
	}
	c := valid(v, v.free_hint) ? v.free_hint : 2
	for tried: u32 = 0; tried < v.clusters; tried += 1 {
		e := raw_entry(v, c) or_return
		if e == 0 {
			set_entry(v, c, 0x0fff_ffff) or_return // masked to the FAT's width
			if prev != 0 {
				set_entry(v, prev, c) or_return
			}
			v.free_count -= 1
			v.free_hint = c == v.clusters + 1 ? 2 : c + 1
			v.fsinfo_dirty = true
			return c, .Ok
		}
		c = c == v.clusters + 1 ? 2 : c + 1
	}
	return 0, .Err_No_Space // the count was wrong
}

// The chain from c freed.
@(private="file", require_results)
free_chain :: proc "contextless" (v: ^Vol, c: u32) -> vx.Status {
	c := c
	for steps: u32 = 0; c != 0; steps += 1 {
		if steps > v.clusters {
			return .Err_Io
		}
		next := next_cluster(v, c) or_return
		set_entry(v, c, 0) or_return
		if v.free_count != FREE_UNKNOWN {
			v.free_count += 1
		}
		v.fsinfo_dirty = true
		c = next
	}
	return .Ok
}

// FAT's date and time for seconds since 1970 (as UTC).
@(private="file")
to_stamp :: proc "contextless" (seconds: i64) -> (date, time: u16le) {
	t := max(seconds, 315_532_800) // FAT's epoch, 1980-01-01
	days, secs := t / 86400 + 719468, t % 86400
	era := days / 146097
	doe := u32(days - era * 146097)
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := mp < 10 ? mp + 3 : mp - 9
	y := min(i64(yoe) + era * 400 + (m <= 2 ? 1 : 0), 2107)
	date = u16le(u32(y - 1980) << 9 | m << 5 | d)
	time = u16le(secs / 3600 << 11 | secs % 3600 / 60 << 5 | secs % 60 / 2)
	return
}

// The slot index of directory dir (0: the fixed root): its sector, and its offset there.
@(private="file", require_results)
slot_place :: proc "contextless" (v: ^Vol, dir, index: u32) -> (sector: u64, at: u64, st: vx.Status) {
	off := u64(index) * 32
	if dir == 0 {
		if index >= v.root_entries {
			return 0, 0, .Err_Not_Found
		}
		sector = u64(v.root_start) + off / u64(v.sector_size)
	} else {
		c, wst := walk(v, dir, off / u64(v.cluster_bytes))
		if wst != .Ok {
			return 0, 0, wst
		}
		if c == 0 {
			return 0, 0, .Err_Not_Found
		}
		sector = cluster_sector(v, c) + off % u64(v.cluster_bytes) / u64(v.sector_size)
	}
	return sector, off % u64(v.sector_size), .Ok
}

// A slot's 32 bytes written.
@(private="file", require_results)
put_slot :: proc "contextless" (v: ^Vol, dir, index: u32, slot: ^[32]u8) -> vx.Status {
	sector, at := slot_place(v, dir, index) or_return
	s, ok := sector_of(v, sector)
	if !ok {
		return .Err_Io
	}
	copy(s[at:at + 32], slot[:])
	return store(v, sector, 1, s) ? .Ok : .Err_Io
}

@(private="file", require_results)
get_slot :: proc "contextless" (v: ^Vol, dir, index: u32, slot: ^[32]u8) -> vx.Status {
	sector, at := slot_place(v, dir, index) or_return
	s, ok := sector_of(v, sector)
	if !ok {
		return .Err_Io
	}
	copy(slot[:], s[at:at + 32])
	return .Ok
}

@(private="file")
set_cluster :: proc "contextless" (v: ^Vol, d: ^Dir_Entry, c: u32) {
	d.cluster_hi = v.kind == .Fat32 ? u16le(c >> 16) : 0
	d.cluster_lo = u16le(c & 0xffff)
}

// An entry's cluster, size, attributes and times, written to its short slot
// (dosfs's chmod and utimes change them in an Entry, then put it).
@(require_results)
put_entry :: proc "contextless" (v: ^Vol, e: ^Entry) -> vx.Status {
	if e.node == ROOT {
		return .Ok // the root has no entry
	}
	dir, index := dir_of(v, e.node), index_of(e.node)
	s: [32]u8
	get_slot(v, dir, index, &s) or_return
	d := view(s[:], Dir_Entry)
	d.attr = e.attr
	set_cluster(v, d, e.cluster)
	d.size = .Directory in e.attr ? 0 : u32le(e.size)
	d.mdate, d.mtime = to_stamp(e.mtime)
	d.adate, _ = to_stamp(e.atime != 0 ? e.atime : e.mtime)
	return put_slot(v, dir, index, &s)
}

// The cluster count a file of size bytes has.
@(private="file")
clusters_for :: proc "contextless" (v: ^Vol, size: u64) -> u64 {
	return (size + u64(v.cluster_bytes) - 1) / u64(v.cluster_bytes)
}

// The file's chain made at least want clusters long.
@(private="file", require_results)
grow :: proc "contextless" (v: ^Vol, f: ^Entry, want: u64) -> vx.Status {
	have := clusters_for(v, u64(f.size))
	last: u32
	if have != 0 {
		ahead := f.at_cluster != 0 && f.at_index < have
		last = walk(v, ahead ? f.at_cluster : f.cluster, ahead ? have - 1 - f.at_index : have - 1) or_return
		if last == 0 {
			return .Err_Io // shorter than its size
		}
	}
	for ; have < want; have += 1 {
		c := alloc(v, last) or_return
		if f.cluster == 0 {
			f.cluster = c
		}
		f.at_cluster, f.at_index = c, have
		last = c
	}
	return .Ok
}

// Bytes written into the file's clusters at offset (which it has).
@(private="file", require_results)
put_bytes :: proc "contextless" (v: ^Vol, f: ^Entry, offset: u64, data: []u8) -> vx.Status {
	count := u32(len(data))
	offset := offset
	index := offset / u64(v.cluster_bytes)
	ahead := f.at_cluster != 0 && f.at_index <= index
	c, st := walk(v, ahead ? f.at_cluster : f.cluster, ahead ? index - f.at_index : index)
	for done: u32 = 0; st == .Ok && done < count; {
		if c == 0 {
			return .Err_Io
		}
		inside := u32(offset % u64(v.cluster_bytes))
		sector := cluster_sector(v, c) + u64(inside / v.sector_size)
		at := inside % v.sector_size
		n := min(v.sector_size - at, count - done)
		if at == 0 && n == v.sector_size { // whole sectors, to the cluster's end at most
			run := min((v.cluster_bytes - inside) / v.sector_size, (count - done) / v.sector_size)
			if !store(v, sector, run, data[done:]) {
				return .Err_Io
			}
			n = run * v.sector_size
		} else {
			s, ok := sector_of(v, sector)
			if !ok {
				return .Err_Io
			}
			copy(s[at:], data[done:][:n])
			if !store(v, sector, 1, s) {
				return .Err_Io
			}
		}
		f.at_cluster, f.at_index = c, index
		done += n
		offset += u64(n)
		if offset % u64(v.cluster_bytes) == 0 && done < count {
			c, st = next_cluster(v, c)
			index += 1
		}
	}
	return st
}

// data written at offset, the file grown (with zeros between its end and
// offset) as it must be; its entry's size and time then.
@(require_results)
write :: proc "contextless" (v: ^Vol, f: ^Entry, offset: u64, data: []u8) -> vx.Status {
	if .Directory in f.attr {
		return .Err_Invalid
	}
	if v.dev.write == nil {
		return .Err_Access
	}
	end, overflow := intrinsics.overflow_add(offset, u64(len(data)))
	if overflow || end > u64(max(u32)) {
		return .Err_No_Space // FAT's files end at 4 GiB
	}
	st := grow(v, f, clusters_for(v, max(end, u64(f.size))))
	for at := u64(f.size); st == .Ok && at < offset; { // the gap
		n := min(offset - at, u64(MAX_SECTOR))
		st = put_bytes(v, f, at, ZEROS[:n])
		at += n
	}
	if st == .Ok {
		st = put_bytes(v, f, offset, data)
	}
	if st != .Ok && st != .Err_No_Space {
		return st
	}
	// What was written is the file's even if the volume filled part way: the
	// clusters were taken first, so its size can only cover written bytes.
	if st == .Ok && end > u64(f.size) {
		f.size = u32(end)
	}
	f.mtime = v.now
	f.attr += {.Archive}
	put := put_entry(v, f)
	return st != .Ok ? st : put
}

// The file cut, or grown with zeros, to size.
@(require_results)
truncate :: proc "contextless" (v: ^Vol, f: ^Entry, size: u64) -> vx.Status {
	if .Directory in f.attr {
		return .Err_Invalid
	}
	if v.dev.write == nil {
		return .Err_Access
	}
	if size > u64(max(u32)) {
		return .Err_No_Space
	}
	if size > u64(f.size) {
		st := vx.Status.Ok
		for st == .Ok && u64(f.size) < size {
			n := min(size - u64(f.size), u64(MAX_SECTOR))
			st = write(v, f, u64(f.size), ZEROS[:n])
		}
		return st
	}
	keep := clusters_for(v, size)
	cut: u32 // the first cluster to free
	st := vx.Status.Ok
	if keep == 0 {
		cut = f.cluster
		f.cluster = 0
	} else if f.cluster != 0 {
		last: u32
		last, st = walk(v, f.cluster, keep - 1)
		if st == .Ok && last != 0 {
			cut, st = next_cluster(v, last)
		}
		if st == .Ok && last != 0 && cut != 0 {
			st = set_entry(v, last, 0x0fff_ffff)
		}
	}
	f.size, f.mtime = u32(size), v.now
	f.attr += {.Archive}
	f.at_cluster, f.at_index = 0, 0
	if st == .Ok {
		st = put_entry(v, f) // the entry before the clusters go
	}
	if st == .Ok && cut != 0 {
		st = free_chain(v, cut)
	}
	return st
}

// --- Names for new entries ---

@(private="file")
in_set :: proc "contextless" (set: string, c: u32) -> bool {
	for i in 0 ..< len(set) {
		if u32(set[i]) == c {
			return true
		}
	}
	return false
}

@(private="file")
short_char :: proc "contextless" (c: u32) -> bool {
	if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
		return true
	}
	return c < 0x80 && in_set("!#$%&'()-@^_`{}~", c)
}

// A name's UTF-16 units: at most 255.
@(private="file")
Units :: [dynamic; 255]u16

// The name's UTF-16 units; false if it cannot be a FAT name: control
// characters, "*/:<>?\|, or a trailing dot or space (Windows would drop
// them). The UTF-8 is decoded as upstream decodes it, overlong forms
// included, so the same names are taken.
@(private="file")
to_utf16 :: proc "contextless" (name: string, units: ^Units) -> bool {
	clear(units)
	if len(name) == 0 || name[len(name) - 1] == '.' || name[len(name) - 1] == ' ' || name == "." || name == ".." {
		return false
	}
	for i := 0; i < len(name); {
		b := u32(name[i])
		c, more: u32
		switch {
		case b < 0x80:
			c, more = b, 0
		case b & 0xe0 == 0xc0:
			c, more = b & 0x1f, 1
		case b & 0xf0 == 0xe0:
			c, more = b & 0x0f, 2
		case b & 0xf8 == 0xf0:
			c, more = b & 0x07, 3
		case:
			return false
		}
		if i + 1 + int(more) > len(name) {
			return false
		}
		for k in 1 ..= int(more) {
			if name[i + k] & 0xc0 != 0x80 {
				return false
			}
			c = c << 6 | u32(name[i + k] & 0x3f)
		}
		i += 1 + int(more)
		if c < 0x20 || (c < 0x80 && in_set("\"*/:<>?\\|", c)) || (c >= 0xd800 && c < 0xe000) || c > 0x10_ffff {
			return false
		}
		if c >= 0x10000 {
			pair := [2]u16{u16(0xd800 + (c - 0x10000) >> 10), u16(0xdc00 + (c - 0x10000) & 0x3ff)}
			if append(units, ..pair[:]) != 2 {
				return false
			}
		} else if append(units, u16(c)) != 1 {
			return false
		}
	}
	return true
}

// The name as an 8.3 name with no long name, if it is one: upper case, or
// each part all lower case (NT's flags in nt). False if it needs a long name.
@(private="file")
fits_short :: proc "contextless" (name: string, out: ^[11]u8) -> (nt: u8, ok: bool) {
	out^ = ' '
	dot := len(name)
	for i in 0 ..< len(name) {
		if name[i] == '.' {
			if dot != len(name) {
				return 0, false // two dots
			}
			dot = i
		}
	}
	base := dot
	ext := dot == len(name) ? 0 : len(name) - dot - 1
	if base == 0 || base > 8 || ext > 3 || (dot != len(name) && ext == 0) {
		return 0, false
	}
	for part in 0 ..< 2 {
		p := name[:base]
		if part == 1 {
			p = name[len(name) - ext:]
		}
		upper, lower := false, false
		for i in 0 ..< len(p) {
			c := p[i]
			if c >= 'a' && c <= 'z' {
				lower = true
				c -= 32
			} else if c >= 'A' && c <= 'Z' {
				upper = true
			}
			if !short_char(u32(c)) {
				return 0, false
			}
			out[(part == 1 ? 8 : 0) + i] = c
		}
		if upper && lower {
			return 0, false
		}
		if lower {
			nt |= part == 1 ? NT_LOWER_EXT : NT_LOWER_BASE
		}
	}
	if out[0] == 0xe5 {
		out[0] = 0x05
	}
	return nt, true
}

// Whether directory dir has an entry whose 8.3 name is short_name.
@(private="file", require_results)
alias_taken :: proc "contextless" (v: ^Vol, dir: u32, short_name: ^[11]u8) -> (taken: bool, st: vx.Status) {
	it := iter_at(v, dir)
	for {
		s, sst := next_slot(v, &it)
		if sst == .Err_Not_Found || (sst == .Ok && s[0] == SLOT_END) {
			return false, .Ok
		}
		if sst != .Ok {
			return false, sst
		}
		d := view(s, Dir_Entry)
		if s[0] != SLOT_FREE && !is_long_name(d.attr) && d.name == short_name^ {
			return true, .Ok
		}
	}
}

// An 8.3 alias for a long name, unique in the directory: Windows' basis
// name (upper case, characters 8.3 cannot hold as '_', spaces and dots but
// the last dropped), the first six of it with ~N.
@(private="file", require_results)
make_alias :: proc "contextless" (v: ^Vol, dir: u32, units: []u16, out: ^[11]u8) -> vx.Status {
	dot := -1
	for u, i in units {
		if u == '.' {
			dot = i
		}
	}
	base: [dynamic; 8]u8
	ext: [dynamic; 3]u8
	for u, i in units {
		if len(base) == 8 || i == dot {
			break
		}
		c := u32(u)
		if c == ' ' || c == '.' {
			continue
		}
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		_ = append(&base, short_char(c) ? u8(c) : '_')
	}
	if dot >= 0 {
		for u in units[dot + 1:] {
			if len(ext) == 3 {
				break
			}
			c := u32(u)
			if c == ' ' {
				continue
			}
			if c >= 'a' && c <= 'z' {
				c -= 32
			}
			_ = append(&ext, short_char(c) ? u8(c) : '_')
		}
	}
	if len(base) == 0 {
		_ = append(&base, '_')
	}
	for k: u32 = 1; k < 1_000_000; k += 1 {
		tail: [dynamic; 7]u8 // k's digits, least significant first
		for x := k; x != 0; x /= 10 {
			_ = append(&tail, u8('0' + x % 10))
		}
		keep := min(len(base), 7 - len(tail))
		out^ = ' '
		copy(out[:], base[:keep])
		out[keep] = '~'
		for i in 0 ..< len(tail) {
			out[keep + 1 + i] = tail[len(tail) - 1 - i]
		}
		copy(out[8:], ext[:])
		taken := alias_taken(v, dir, out) or_return
		if !taken {
			return .Ok
		}
	}
	return .Err_Exists
}

// count free slots in a row in directory dir: the first's index. The
// directory is grown by a zeroed cluster when it has no such run (the fixed
// root cannot be: Err_No_Space).
@(private="file", require_results)
find_slots :: proc "contextless" (v: ^Vol, dir, count: u32) -> (first: u32, st: vx.Status) {
	it := iter_at(v, dir)
	run, start, last := u32(0), u32(0), dir
	for {
		s, sst := next_slot(v, &it)
		if sst == .Err_Not_Found {
			break
		}
		if sst != .Ok {
			return 0, sst
		}
		if it.cluster != 0 {
			last = it.cluster
		}
		if s[0] == SLOT_END || s[0] == SLOT_FREE {
			if run == 0 {
				start = it.index - 1
			}
			run += 1
			if run == count {
				return start, .Ok
			}
		} else {
			run = 0
		}
	}
	if dir == 0 || u64(it.index) + u64(count) > MAX_SLOTS {
		return 0, .Err_No_Space
	}
	c := alloc(v, 0) or_return // a cluster more, zeroed before the chain reaches it
	zero_cluster(v, c) or_return
	set_entry(v, last, c) or_return
	if run == 0 {
		start = it.index
	}
	if run + v.cluster_bytes / 32 < count {
		return 0, .Err_No_Space // a name longer than a cluster's slots
	}
	return start, .Ok
}

// A new entry in directory d named name: a file, or with .Directory a
// directory, given its first cluster (with "." and ".."); or, with like, a
// copy of like's cluster, size, attributes and times (a rename). out is
// the new entry. Err_Exists if the name is taken.
@(private="file", require_results)
add :: proc "contextless" (v: ^Vol, d: ^Entry, name: string, attr: Attrs, like: ^Entry, out: ^Entry) -> vx.Status {
	if .Directory not_in d.attr {
		return .Err_Invalid
	}
	if v.dev.write == nil {
		return .Err_Access
	}
	units: Units
	if !to_utf16(name, &units) {
		return .Err_Invalid
	}
	e: Entry
	#partial switch st := lookup(v, d, name, &e); st {
	case .Ok:
		return .Err_Exists
	case .Err_Not_Found:
	case:
		return st
	}
	dir := d.node == ROOT ? dir_of(v, ROOT) : d.cluster
	short: [11]u8
	nt, fits := fits_short(name, &short)
	lfn := !fits
	if !lfn {
		// Its 8.3 form is another entry's alias: give it a long name and an alias of its own.
		lfn = alias_taken(v, dir, &short) or_return
	}
	if lfn {
		make_alias(v, dir, units[:], &short) or_return
		nt = 0
	}
	slots := lfn ? (u32(len(units)) + 12) / 13 : 0
	first := find_slots(v, dir, slots + 1) or_return
	// A new directory's cluster, with "." and "..", before any entry names it.
	cluster := like != nil ? like.cluster : 0
	if like == nil && .Directory in attr {
		cluster = alloc(v, 0) or_return
		zero_cluster(v, cluster) or_return
		dot: [32]u8
		de := view(dot[:], Dir_Entry)
		de.name = ' '
		de.name[0] = '.'
		de.attr = {.Directory}
		date, time := to_stamp(v.now)
		de.ctime, de.cdate, de.adate, de.mtime, de.mdate = time, date, date, time, date
		for k in u32(0) ..< 2 {
			parent_cluster := d.node == ROOT ? 0 : d.cluster // ".." of a root child is 0
			if k == 1 {
				de.name[1] = '.'
			}
			set_cluster(v, de, k == 1 ? parent_cluster : cluster)
			put_slot(v, cluster, k, &dot) or_return
		}
	}
	sum := checksum(&short)
	for k in 0 ..< slots { // the long name, its last part first
		seq := slots - k
		s: [32]u8
		l := view(s[:], Lfn_Entry)
		l.seq = u8(seq) | (k == 0 ? LFN_LAST : 0)
		l.attr = LONG_NAME
		l.sum = sum
		for at, i in LFN_UNITS {
			u := int(seq - 1) * 13 + i
			unit: u16 = u == len(units) ? 0 : 0xffff // a NUL after the name, then padding
			store_field(s[at:], u16le(u < len(units) ? units[u] : unit))
		}
		put_slot(v, dir, first + k, &s) or_return
	}
	s: [32]u8
	de := view(s[:], Dir_Entry)
	de.name = short
	switch {
	case like != nil:
		de.attr = like.attr
	case .Directory in attr:
		de.attr = attr
	case:
		de.attr = attr + {.Archive}
	}
	de.nt = nt
	de.cdate, de.ctime = to_stamp(like != nil ? like.ctime : v.now)
	de.mdate, de.mtime = to_stamp(like != nil ? like.mtime : v.now)
	de.adate = de.mdate
	set_cluster(v, de, cluster)
	de.size = like != nil && .Directory not_in like.attr ? u32le(like.size) : 0
	put_slot(v, dir, first + slots, &s) or_return
	return get(v, node_at(dir, first + slots), out)
}

// A new entry in directory d named name: a file, or with .Directory a
// directory. out is the new entry. Err_Exists if the name is taken.
@(require_results)
create :: proc "contextless" (v: ^Vol, d: ^Entry, name: string, attr: Attrs, out: ^Entry) -> vx.Status {
	return add(v, d, name, attr, nil, out)
}

// The entry's slots, its long name's and its own, marked free.
@(private="file", require_results)
unlink :: proc "contextless" (v: ^Vol, e: ^Entry) -> vx.Status {
	dir, index := dir_of(v, e.node), index_of(e.node)
	s: [32]u8
	get_slot(v, dir, index, &s) or_return
	sum := checksum(&view(s[:], Dir_Entry).name)
	s[0] = SLOT_FREE
	put_slot(v, dir, index, &s) or_return
	i := index
	for k := 0; i > 0 && k < LFN_MAX_SLOTS; k += 1 { // its long name, just before it
		i -= 1
		l: [32]u8
		get_slot(v, dir, i, &l) or_return
		le := view(l[:], Lfn_Entry)
		if !is_long_name(le.attr) || l[0] == SLOT_FREE || le.sum != sum {
			break
		}
		first := l[0] & LFN_LAST != 0 // the name's last part: its first slot
		l[0] = SLOT_FREE
		put_slot(v, dir, i, &l) or_return
		if first {
			break
		}
	}
	return .Ok
}

// An entry removed, and its clusters freed after. A directory must be empty
// (Err_Exists if not).
@(require_results)
remove :: proc "contextless" (v: ^Vol, e: ^Entry) -> vx.Status {
	if e.node == ROOT || v.dev.write == nil {
		return .Err_Access
	}
	if .Directory in e.attr {
		it, st := open_dir(v, e)
		child: Entry
		if st == .Ok {
			st = dir_next(v, &it, &child)
		}
		if st == .Ok {
			return .Err_Exists
		}
		if st != .Err_Not_Found {
			return st
		}
	}
	unlink(v, e) or_return
	return e.cluster != 0 ? free_chain(v, e.cluster) : .Ok
}

// An entry moved to directory to, named name: a new entry made like it, the
// old one's slots freed; a directory's ".." then names its new parent. What
// the name had is replaced, as POSIX's rename does, if it is a file (and so
// is e) or an empty directory (and so is e). out is the new entry.
@(require_results)
rename :: proc "contextless" (v: ^Vol, e: ^Entry, to: ^Entry, name: string, out: ^Entry) -> vx.Status {
	if e.node == ROOT || .Directory not_in to.attr {
		return .Err_Invalid
	}
	if v.dev.write == nil {
		return .Err_Access
	}
	is_dir := .Directory in e.attr
	if is_dir { // not into itself or below it
		up := to.node
		for steps := 0; up != ROOT; steps += 1 {
			if up == e.node || steps > 4096 {
				return .Err_Invalid
			}
			up = parent(v, up) or_return
		}
	}
	old: Entry
	#partial switch st := lookup(v, to, name, &old); st {
	case .Ok:
		if old.node == e.node { // the same entry: only its case changes, or nothing
			keep := e^
			unlink(v, e) or_return
			return add(v, to, name, {}, &keep, out)
		}
		if is_dir != (.Directory in old.attr) {
			return .Err_Exists
		}
		remove(v, &old) or_return
	case .Err_Not_Found:
	case:
		return st
	}
	add(v, to, name, {}, e, out) or_return
	unlink(v, e) or_return
	if is_dir && dir_of(v, e.node) != (to.node == ROOT ? dir_of(v, ROOT) : to.cluster) {
		s: [32]u8
		get_slot(v, e.cluster, 1, &s) or_return
		set_cluster(v, view(s[:], Dir_Entry), to.node == ROOT ? 0 : to.cluster)
		put_slot(v, e.cluster, 1, &s) or_return
	}
	return .Ok
}

// FAT32's FSInfo brought up to date, and the device flushed.
@(require_results)
flush :: proc "contextless" (v: ^Vol) -> vx.Status {
	if v.dev.write == nil {
		return .Ok
	}
	if v.fsinfo_sector != 0 && v.fsinfo_dirty {
		s, ok := sector_of(v, u64(v.fsinfo_sector))
		if !ok {
			return .Err_Io
		}
		fi := view(s, Fsinfo)
		if fi.lead == FSINFO_LEAD && fi.signature == FSINFO_SIGNATURE {
			fi.free = u32le(v.free_count)
			fi.next = u32le(v.free_hint)
			if !store(v, u64(v.fsinfo_sector), 1, s) {
				return .Err_Io
			}
		}
		v.fsinfo_dirty = false
	}
	return v.dev.flush == nil || v.dev.flush(v.dev.ctx) ? .Ok : .Err_Io
}

// --- Formatting ---

// A new FAT32 volume of `sectors` 512-byte sectors on dev (which must write),
// labelled label (up to 11 characters, upper case; more are cut), with
// serial; hidden is the sectors before it on its disk (its partition's first
// LBA). Laid out as Microsoft's specification has it: 32 reserved sectors
// (FSInfo at 1, the boot sector's backup at 6), two FATs, the root directory
// at cluster 2, clusters of 512 bytes up to 260 MiB, 4 KiB to 8 GiB, larger
// beyond. Err_Invalid if the volume is too small for FAT32's 65525 clusters
// (about 33 MiB).
@(require_results)
format :: proc "contextless" (dev: Dev, sectors: u64, hidden: u64, label: string, serial: u32) -> vx.Status {
	if dev.write == nil || sectors > 0xffff_ffff {
		return .Err_Invalid
	}
	spc: u32 = 1
	if sectors > 532_480 {
		spc = 8 // 260 MiB
	}
	if sectors > 16_777_216 {
		spc = 16 // 8 GiB
	}
	if sectors > 33_554_432 {
		spc = 32 // 16 GiB
	}
	if sectors > 67_108_864 {
		spc = 64 // 32 GiB
	}
	reserved, nfats: u32 = 32, 2
	if sectors < u64(reserved) {
		return .Err_Invalid // (upstream's sum wraps instead, and fails the cluster check)
	}
	tmp1, tmp2 := sectors - u64(reserved), (256 * u64(spc) + u64(nfats)) / 2
	fatsz := u32((tmp1 + tmp2 - 1) / tmp2)
	used := u64(reserved) + u64(nfats) * u64(fatsz)
	if used > sectors {
		return .Err_Invalid
	}
	clusters := (sectors - used) / u64(spc)
	if clusters < 65525 || clusters > 0x0fff_fff5 {
		return .Err_Invalid
	}
	// The label as its 11 bytes: up to its first NUL, as upstream reads a C string.
	label_bytes: [11]u8 = ' '
	for i in 0 ..< min(len(label), 11) {
		if label[i] == 0 {
			break
		}
		label_bytes[i] = label[i]
	}

	// The boot sector.
	s: [512]u8
	b := view(s[:], Boot32)
	b.jump = {0xeb, 0x58, 0x90}
	copy(b.oem[:], "VECTRAOS")
	b.bytes_per_sector = 512
	b.sectors_per_cluster = u8(spc)
	b.reserved = u16le(reserved)
	b.fats = u8(nfats)
	b.media = 0xf8 // a fixed disk
	b.sectors_per_track, b.heads = 63, 255 // geometry no one uses
	b.hidden = u32le(hidden) // (cut to 32 bits, as upstream's)
	b.total32 = u32le(sectors)
	b.fat32 = u32le(fatsz)
	b.root_cluster = 2
	b.fsinfo = 1
	b.backup = 6
	b.ebr.drive = 0x80
	b.ebr.signature = EBR_SIGNATURE
	b.ebr.serial = u32le(serial)
	b.ebr.label = label_bytes
	copy(b.ebr.fs_type[:], "FAT32   ")
	b.signature = {0x55, 0xaa}
	if !dev.write(dev.ctx, 0, s[:]) || !dev.write(dev.ctx, 6 * 512, s[:]) {
		return .Err_Io
	}
	// FSInfo, and its backup.
	s = {}
	fi := view(s[:], Fsinfo)
	fi.lead = FSINFO_LEAD
	fi.signature = FSINFO_SIGNATURE
	fi.free = u32le(clusters) - 1 // all free but the root's
	fi.next = 3
	fi.trail = 0xaa55_0000
	if !dev.write(dev.ctx, 512, s[:]) || !dev.write(dev.ctx, 7 * 512, s[:]) {
		return .Err_Io
	}
	// The other reserved sectors, the FATs and the root's cluster: zeros, with
	// the FATs' first three entries (the media byte, the end marker, the root's
	// chain's end).
	end := used + u64(spc)
	for at: u64 = 2; at < end; {
		if at == 6 {
			at = 8
			continue
		}
		n := min(end - at, 64)
		if at < 6 && at + n > 6 {
			n = 6 - at
		}
		if !dev.write(dev.ctx, at * 512, ZEROS[:n * 512]) {
			return .Err_Io
		}
		at += n
	}
	s = {}
	fat := [3]u32le{0x0fff_fff8, 0x0fff_ffff, 0x0fff_ffff}
	for e, i in fat {
		store_field(s[4 * i:], e)
	}
	for f in 0 ..< nfats {
		if !dev.write(dev.ctx, (u64(reserved) + u64(f) * u64(fatsz)) * 512, s[:]) {
			return .Err_Io
		}
	}
	// The label again, as the root directory's first entry: fsck.fat and
	// Windows read it from there.
	s = {}
	de := view(s[:], Dir_Entry)
	de.name = label_bytes
	de.attr = {.Label}
	return dev.write(dev.ctx, used * 512, s[:]) ? .Ok : .Err_Io
}
