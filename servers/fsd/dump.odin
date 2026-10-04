package fsd

// Read-only snapshots, and the dump view (upstream docs/11 §5). An attach
// name that labels a snapshot, not a branch, is that snapshot, read-only.
// `dump` is the dump view: /YYYY/MMDD/BRANCH for every label named
// BRANCH@YYYY-MM-DD, each BRANCH that snapshot, read-only. Up to RO_SLOTS
// snapshots are open at once; deleting a label closes its snapshot, and fids
// on it find nothing from then on.

import vx "abi:vx"
import "vx:fs"

Snapshot :: struct {
	used:       bool,
	name:       [dynamic; fs.LABELMAX]u8,
	t:          fs.Tree,
	root:       u64, // its root's qid
	year, mmdd: u32, // a dated label's: its place in the dump view; else 0
}

ro: [RO_SLOTS]Snapshot

@(private="file")
digits :: proc "contextless" (s: string) -> (v: u32, ok: bool) {
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return v, false
		}
		v = v * 10 + u32(c - '0')
	}
	return v, true
}

// A label named BRANCH@YYYY-MM-DD: its date, and the branch's length.
@(private="file")
dated :: proc "contextless" (label: string) -> (year, mmdd: u32, nbranch: int, ok: bool) {
	n := len(label)
	if n < 12 || label[n - 11] != '@' || label[n - 6] != '-' || label[n - 3] != '-' {
		return
	}
	y, y_ok := digits(label[n - 10:][:4])
	mm, mm_ok := digits(label[n - 5:][:2])
	dd, dd_ok := digits(label[n - 2:])
	if !y_ok || !mm_ok || !dd_ok || mm == 0 || mm > 12 || dd == 0 || dd > 31 || y == 0 {
		return
	}
	return y, mm * 100 + dd, n - 11, true
}

// Snapshot `name` open read-only: its slot in ro.
@(require_results)
ro_open :: proc "contextless" (name: string) -> (slot: u32, st: vx.Status) {
	free := u32(RO_SLOTS)
	for &r, i in ro {
		if r.used && string(r.name[:]) == name {
			return u32(i), .Ok
		}
		if !r.used && free == RO_SLOTS {
			free = u32(i)
		}
	}
	if free == RO_SLOTS {
		return 0, .Err_No_Memory
	}
	r := &ro[free]
	r^ = {}
	_ = append(&r.name, name)
	r.t = fs.snap_open(&vol, name) or_return
	root := fs.root(&vol, &r.t) or_return
	r.year, r.mmdd, _, _ = dated(name)
	r.root = root.d.qid_path
	r.used = true
	return free, .Ok
}

// A label going: its snapshot, if open, closed first.
ro_drop :: proc "contextless" (name: string) {
	for &r, i in ro {
		if r.used && string(r.name[:]) == name {
			r = {}
			pcache_forget(RO_FIRST + u32(i), true) // its slot may be another snapshot's next
		}
	}
}

// The snapshot node is in, if it is a dated one; else nil.
dated_snapshot :: proc "contextless" (node: Id) -> ^Snapshot {
	if !is_readonly(node) || node.slot >= RO_FIRST + RO_SLOTS {
		return nil
	}
	r := &ro[node.slot - RO_FIRST]
	return r.used && r.year != 0 ? r : nil
}

is_dump :: proc "contextless" (node: Id) -> bool {
	return node.slot == DUMP_SLOT
}

// A dump view directory's qid: the root (level 0), a year (1), or a day (2).
@(private="file")
Dump_Qid :: bit_field u64 {
	mmdd:  u32 | 16,
	year:  u32 | 24,
	level: u32 | 8,
}

dump_node :: proc "contextless" (from: Id, level, year, mmdd: u32) -> Id {
	q := Dump_Qid{mmdd = mmdd, year = year, level = level}
	return node_of(DUMP_SLOT, from.user, transmute(u64)q, from.permissive)
}

dump_level :: proc "contextless" (node: Id) -> u32 {
	return (transmute(Dump_Qid)node.qid).level
}

dump_year :: proc "contextless" (node: Id) -> u32 {
	return (transmute(Dump_Qid)node.qid).year & 0xffff
}

@(private="file")
dump_mmdd :: proc "contextless" (node: Id) -> u32 {
	return (transmute(Dump_Qid)node.qid).mmdd
}

// The dated labels, sorted by date then branch: what the dump view lists.
@(private="file")
Dumped :: struct {
	year, mmdd: u32,
	branch:     [dynamic; fs.LABELMAX]u8,
}

@(private="file")
dumps: [dynamic; 256]Dumped

@(private="file")
dump_less :: proc "contextless" (a, b: ^Dumped) -> bool {
	if a.year != b.year {
		return a.year < b.year
	}
	if a.mmdd != b.mmdd {
		return a.mmdd < b.mmdd
	}
	return fs.keycmp(a.branch[:], b.branch[:]) < 0
}

@(private="file")
scan_dumps :: proc "contextless" () {
	clear(&dumps)
	pfx := [1]u8{u8(fs.Key_Kind.Label)}
	s: fs.Scan
	fs.scan_start(&s, &vol.snap, pfx[:])
	for len(dumps) < cap(dumps) {
		kv := fs.scan_next(&vol.fs, &s) or_break
		if len(kv.val) != size_of(fs.Label_Disk) {
			continue
		}
		if .Mutable in transmute(fs.Label_Flags)u32(fs.load(fs.Label_Disk, kv.val).flags) {
			continue
		}
		d: Dumped
		label := string(kv.key[1:])
		nbranch: int
		ok: bool
		if d.year, d.mmdd, nbranch, ok = dated(label); !ok {
			continue
		}
		_ = append(&d.branch, label[:nbranch])
		// Kept sorted as they come: inserted after every one not greater.
		at := len(dumps)
		_ = append(&dumps, d)
		for at > 0 && dump_less(&d, &dumps[at - 1]) {
			dumps[at] = dumps[at - 1]
			at -= 1
		}
		dumps[at] = d
	}
	fs.scan_end(&vol.fs, &s)
}

// The four digits of v.
@(private="file")
put4 :: proc "contextless" (b: []u8, v: u32) {
	v := v
	for i := 3; i >= 0; i -= 1 {
		b[i] = '0' + u8(v % 10)
		v /= 10
	}
}

// A dump view directory as an entry: a name to stat, no more.
dump_file :: proc "contextless" (node: Id) -> (f: fs.File) {
	f.d = {qid_path = node.qid, qid_type = fs.QTDIR, mode = fs.DMDIR | 0o555}
	name: [4]u8
	level := dump_level(node)
	put4(name[:], level == 1 ? dump_year(node) : dump_mmdd(node))
	f.nkey = len(fs.key_ent(f.key[:], 0, level != 0 ? string(name[:]) : ""))
	return
}

// The dump view's names: a year, a day in it, a branch's snapshot that day.
@(require_results)
dump_walk :: proc "contextless" (dir: Id, name: string) -> (child: Id, st: vx.Status) {
	level := dump_level(dir)
	scan_dumps()
	if level < 2 {
		v, ok := digits(name)
		if len(name) != 4 || !ok {
			return {}, .Err_Not_Found
		}
		for &d in dumps {
			if level == 0 && d.year == v {
				return dump_node(dir, 1, v, 0), .Ok
			}
			if level == 1 && d.year == dump_year(dir) && d.mmdd == v {
				return dump_node(dir, 2, dump_year(dir), v), .Ok
			}
		}
		return {}, .Err_Not_Found
	}
	for &d in dumps {
		if d.year != dump_year(dir) || d.mmdd != dump_mmdd(dir) || string(d.branch[:]) != name {
			continue
		}
		label: [dynamic; fs.LABELMAX]u8
		date: [11]u8 = {0 = '@', 5 = '-', 8 = '-'}
		put4(date[1:], d.year)
		date[6], date[7] = '0' + u8(d.mmdd / 1000), '0' + u8(d.mmdd / 100 % 10)
		date[9], date[10] = '0' + u8(d.mmdd / 10 % 10), '0' + u8(d.mmdd % 10)
		_ = append(&label, ..d.branch[:])
		_ = append(&label, ..date[:])
		r := ro_open(string(label[:])) or_return
		return node_of(RO_FIRST + r, dir.user, ro[r].root, dir.permissive), .Ok
	}
	return {}, .Err_Not_Found
}

// The index-th of a dump view directory's entries.
@(require_results)
dump_readdir :: proc "contextless" (dir: Id, index: u32) -> (child: Id, st: vx.Status) {
	level := dump_level(dir)
	n: u32
	scan_dumps()
	for &d, i in dumps {
		in_dir := level == 0 || d.year == dump_year(dir)
		if level == 2 {
			in_dir = in_dir && d.mmdd == dump_mmdd(dir)
		}
		first := true // the first of its year (level 0) or day (level 1); a day's branches each
		if i > 0 && level == 0 {
			first = dumps[i - 1].year != d.year
		}
		if i > 0 && level == 1 {
			first = dumps[i - 1].year != d.year || dumps[i - 1].mmdd != d.mmdd
		}
		if !in_dir || !first {
			continue
		}
		n += 1
		if n - 1 != index {
			continue
		}
		switch level {
		case 0:
			return dump_node(dir, 1, d.year, 0), .Ok
		case 1:
			return dump_node(dir, 2, d.year, d.mmdd), .Ok
		}
		return dump_walk(dir, string(d.branch[:]))
	}
	return {}, .Err_Not_Found
}
