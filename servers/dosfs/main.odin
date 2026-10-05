// dosfs: FAT12, FAT16 and FAT32 over a block session (upstream docs/11 §11),
// served as 9Px on its post: the EFI system partition, USB sticks, SD cards.
// After 9front's dossrv; the format is lib/fat's. Read and write (upstream's
// M5 steps 8a and 8b), with the posix extension's renames and setattr; -r,
// or a disk that is read-only, serves it read-only.
//
//   service=dosfs program=/boot/bin/dosfs post=esp console
//   connect=disk0.esp
//   arg=-u
//   arg=vectra
//
// FAT has no owners and no permissions: every file is the -u user's (none
// if not given), 0644, and every directory 0755; an entry marked read-only
// is 0444, and chmod turning the owner's write bit off or on marks it or
// not. Changing owners is refused.
//
// Writes reach the disk as they are made (lib/fat's cache is
// write-through); Tfsync, and a clunk of a file opened for writing, flush
// the disk and FAT32's FSInfo. A node is its entry's place, which a rename
// changes: the old node is remembered as moved, for fids that still hold it.
package dosfs

import vx "abi:vx"
import "vx:driver"
import "vx:fat"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"
import "vx:str"
import usage "gen:usage/dosfs"

@(private="file")
disk: driver.Blk
@(private="file")
disk_name: string
@(private="file")
owner := "none"
@(private="file")
read_only: bool
@(private="file")
vol: fat.Vol
@(private="file")
bounce: [fat.MAX_SECTOR]u8

@(private="file")
fail :: proc "contextless" (what: string, st := vx.Status.Ok) -> ! {
	if st != .Ok {
		rt.print("dosfs: FAILED: ", what, ": ", p9.error_text(st), "\n")
	} else {
		rt.print("dosfs: FAILED: ", what, "\n")
	}
	rt.exits(what)
}

// The volume's reads: whole disk sectors straight through, the boot
// sector's 512 bytes through a bounce buffer when the disk's are larger.
@(private="file")
dev_read :: proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool {
	b := (^driver.Blk)(ctx)
	sector := u64(b.sector)
	if off % sector == 0 && u64(len(buf)) % sector == 0 {
		return driver.blk_read(b, off, buf) == .Ok
	}
	if sector > u64(len(bounce)) || off % sector + u64(len(buf)) > sector {
		return false
	}
	if driver.blk_read(b, off / sector * sector, bounce[:sector]) != .Ok {
		return false
	}
	copy(buf, bounce[off % sector:])
	return true
}

@(private="file")
dev_write :: proc "contextless" (ctx: rawptr, off: u64, data: []u8) -> bool {
	b := (^driver.Blk)(ctx)
	sector := u64(b.sector)
	return off % sector == 0 && u64(len(data)) % sector == 0 && driver.blk_write(b, off, data) == .Ok
}

@(private="file")
dev_flush :: proc "contextless" (ctx: rawptr) -> bool {
	return driver.blk_flush((^driver.Blk)(ctx)) == .Ok
}

// --- Nodes ---

// A renamed entry's old node, and where it went.
@(private="file")
Move :: struct {
	from, to: fat.Node,
}

// The last 64 renames.
@(private="file")
moved: [64]Move
@(private="file")
moves: u32

// Where a node is now, after any renames (64 hops at most).
@(private="file")
resolve :: proc "contextless" (node: fat.Node) -> fat.Node {
	node := node
	hops: for _ in 0 ..< 64 {
		for m in moved {
			if m.from == node && node != 0 {
				node = m.to
				continue hops
			}
		}
		break
	}
	return node
}

// A new entry where an old one moved from: that move is no longer this node's.
@(private="file")
forget_moves_to :: proc "contextless" (node: fat.Node) {
	for &m in moved {
		if m.from == node {
			m.from = 0
		}
	}
}

@(private="file", require_results)
get :: proc "contextless" (node: p9.Node, e: ^fat.Entry) -> vx.Status {
	return fat.get(&vol, resolve(fat.Node(node)), e)
}

// The entry reads and writes use, kept: they usually go on with the same file.
@(private="file")
current: fat.Entry

@(private="file", require_results)
use :: proc "contextless" (node: p9.Node) -> (e: ^fat.Entry, st: vx.Status) {
	n := resolve(fat.Node(node))
	if current.node != n {
		if st = fat.get(&vol, n, &current); st != .Ok {
			current.node = 0
			return nil, st
		}
	}
	return &current, .Ok
}

// A listing goes index by index: the last one's place is kept, so the next
// index continues from it instead of reading the directory from its start.
@(private="file")
Listing :: struct {
	dir:  p9.Node, // 0: none
	next: u32, // the index the iterator is at
	it:   fat.Iter,
}

@(private="file")
listing: Listing

// After a change to a directory: what was kept of it read again.
@(private="file")
changed :: proc "contextless" () {
	current.node = 0
	listing.dir = 0
}

@(private="file")
stamp :: proc "contextless" () {
	vol.now = rt.clock_utc() / 1_000_000_000
}

// --- 9Px ---

@(private="file")
scratch: fat.Entry // stat's strings live here until the next call

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return p9.Node(fat.ROOT), .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	d, e: fat.Entry
	st = get(dir, &d)
	if st == .Ok {
		st = fat.lookup(&vol, &d, name, &e)
	}
	if st == .Ok {
		child = p9.Node(e.node)
	}
	return child, st == .Err_Invalid ? .Err_Not_Found : st
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	up: fat.Node
	up, st = fat.parent(&vol, resolve(fat.Node(node)))
	return p9.Node(up), st
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	get(node, &scratch) or_return
	dir := .Directory in scratch.attr
	perm := u32(.Read_Only in scratch.attr || read_only ? 0o444 : 0o644)
	if dir {
		perm |= 0o111
	}
	out^ = {
		qid    = {type = dir ? p9.QTDIR : p9.QTFILE, version = u32(scratch.mtime), path = u64(scratch.node)},
		mode   = dir ? p9.DMDIR | perm : perm,
		atime  = u32(scratch.atime > 0 ? scratch.atime : scratch.mtime),
		mtime  = u32(scratch.mtime),
		length = u64(scratch.size),
		name   = fat.entry_name(&scratch),
		uid    = owner,
		gid    = owner,
		muid   = owner,
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	e := use(node) or_return
	if mode.access == .Read && !mode.trunc && !mode.rclose {
		return .Ok
	}
	if read_only || .Read_Only in e.attr || (.Directory in e.attr && mode.access != .Read) {
		return .Err_Access
	}
	if mode.trunc && .Directory not_in e.attr && e.size != 0 {
		stamp()
		return fat.truncate(&vol, e, 0)
	}
	return .Ok
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	e := use(node) or_return
	if .Directory in e.attr {
		return 0, .Err_Invalid // read as a directory, through readdir
	}
	return fat.read(&vol, e, offset, buf)
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	e := use(node) or_return
	if read_only {
		return 0, .Err_Access
	}
	stamp()
	if st = fat.write(&vol, e, offset, data); st != .Ok {
		current.node = 0 // what it holds may be part way
		return 0, st
	}
	return u32(len(data)), .Ok
}

@(private="file")
fs_create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	if read_only {
		return 0, .Err_Access
	}
	if perm & ~(p9.DMDIR | 0o777) != 0 {
		return 0, .Err_Unsupported // no symbolic links, devices or the like on FAT
	}
	d, e: fat.Entry
	get(dir, &d) or_return
	stamp()
	attr := perm & p9.DMDIR != 0 ? fat.Attrs{.Directory} : {}
	if perm & 0o200 == 0 && perm & p9.DMDIR == 0 {
		attr += {.Read_Only}
	}
	st = fat.create(&vol, &d, name, attr, &e)
	changed()
	if st != .Ok {
		return 0, st
	}
	forget_moves_to(e.node)
	return p9.Node(e.node), .Ok
}

@(private="file")
fs_remove :: proc "contextless" (ctx: rawptr, node: p9.Node) -> vx.Status {
	if read_only {
		return .Err_Access
	}
	e: fat.Entry
	st := get(node, &e)
	if st == .Ok {
		st = fat.remove(&vol, &e)
	}
	changed()
	return st
}

@(private="file")
fs_rename :: proc "contextless" (ctx: rawptr, olddir: p9.Node, oldname: string, newdir: p9.Node, newname: string) -> vx.Status {
	if read_only {
		return .Err_Access
	}
	from_dir, to_dir, e, out: fat.Entry
	get(olddir, &from_dir) or_return
	fat.lookup(&vol, &from_dir, oldname, &e) or_return
	get(newdir, &to_dir) or_return
	stamp()
	st := fat.rename(&vol, &e, &to_dir, newname, &out)
	changed()
	if st != .Ok {
		return st
	}
	forget_moves_to(out.node)
	if out.node != e.node {
		moved[moves % len(moved)] = {from = e.node, to = out.node}
		moves += 1
	}
	return .Ok
}

@(private="file")
fs_setattr :: proc "contextless" (ctx: rawptr, node: p9.Node, a: ^p9.Setattr) -> vx.Status {
	if read_only {
		return .Err_Access
	}
	e := use(node) or_return
	if a.valid & {.Uid, .Gid} != {} {
		return .Err_Access // FAT has no owners
	}
	stamp()
	if .Size in a.valid {
		fat.truncate(&vol, e, a.size) or_return
	}
	if .Mode in a.valid {
		if a.mode & 0o200 != 0 {
			e.attr -= {.Read_Only}
		} else {
			e.attr += {.Read_Only}
		}
	}
	if .Mtime in a.valid {
		e.mtime = .Mtime_Set in a.valid ? i64(a.mtime_sec) : vol.now
	}
	if .Atime in a.valid {
		e.atime = .Atime_Set in a.valid ? i64(a.atime_sec) : vol.now
	}
	return fat.put_entry(&vol, e)
}

@(private="file")
fs_fsync :: proc "contextless" (ctx: rawptr, node: p9.Node) -> vx.Status {
	return fat.flush(&vol)
}

@(private="file")
fs_clunk :: proc "contextless" (ctx: rawptr, node: p9.Node, opened: bool) {
	if opened && !read_only {
		_ = fat.flush(&vol) // cheap: FSInfo if it changed, and the disk's cache
	}
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	if listing.dir != dir || index < listing.next || listing.it.index == 0 {
		d: fat.Entry
		st = get(dir, &d)
		if st == .Ok {
			listing.it, st = fat.open_dir(&vol, &d)
		}
		if st != .Ok {
			listing.dir = 0
			return 0, st
		}
		listing.dir, listing.next = dir, 0
	}
	e: fat.Entry
	for st == .Ok && listing.next <= index {
		st = fat.dir_next(&vol, &listing.it, &e)
		listing.next += 1
	}
	if st != .Ok {
		listing.dir = 0
		return 0, st
	}
	return p9.Node(e.node), .Ok
}

// Not file-private: tests/host drives its Fs on the host.
server := p9ring.Server {
	fs = {
		attach = fs_attach,
		walk = fs_walk,
		parent = fs_parent,
		stat = fs_stat,
		open = fs_open,
		read = fs_read,
		readdir = fs_readdir,
		write = fs_write,
		create = fs_create,
		remove = fs_remove,
		clunk = fs_clunk,
		setattr = fs_setattr,
		rename = fs_rename,
		fsync = fs_fsync,
	},
	name = "dosfs",
	supported = {.Posix, .Xattr}, // Trenameat and Tsetattr; Tgetattr, for stat
}

// --- Starting ---

// The disk's connector: the one handle named srv:NAME.
@(private="file")
find_disk :: proc "contextless" () -> vx.Handle {
	for &h, i in rt.spawn.handles[:rt.spawn.handle_count] {
		name := rt.spawn.handle_names[i]
		if len(name) > 4 && str.has_prefix(name, "srv:") && h != vx.HANDLE_NONE {
			disk_name = name[4:]
			taken := h
			h = vx.HANDLE_NONE
			return taken
		}
	}
	fail("no connector to a disk (connect=)")
}

// The program's state as a new task has it, so tests/host may start the
// program more than once in one process.
@(private="file")
reset :: proc() {
	disk, disk_name, owner, read_only = {}, "", "none", false
	vol, current, scratch, listing = {}, {}, {}, {}
	moved, moves = {}, 0
}

// Everything vx_main does, up to its exit string: tests/host calls it,
// with a fake kernel that lets it mount a disk and then not serve.
start :: proc() -> string {
	reset()
	args := rt.args()
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "-u" && i + 1 < len(args) && args[i + 1] != "":
			i += 1
			owner = args[i]
		case args[i] == "-r":
			read_only = true
		case:
			fail(usage.TEXT)
		}
	}
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		fail("no listen channel (post=)")
	}
	if st := driver.blk_open(&disk, find_disk(), {}); st != .Ok {
		fail("cannot open a session on the disk", st)
	}
	read_only = read_only || .Readonly in disk.flags
	dev := fat.Dev{ctx = &disk, read = dev_read}
	if !read_only {
		dev.write, dev.flush = dev_write, dev_flush
	}
	if st := fat.mount(&vol, dev); st != .Ok {
		fail("no FAT volume on the disk", st)
	}
	if vol.sector_size % disk.sector != 0 {
		fail("the volume's sectors are smaller than the disk's")
	}
	rt.print("dosfs: /srv/", disk_name, ": FAT", u64(vol.kind))
	if label := fat.volume_label(&vol); label != "" {
		rt.print(" \"", label, "\"")
	}
	rt.print(", ", u64(vol.clusters), " clusters of ", u64(vol.cluster_bytes), read_only ? " bytes, read-only\n" : " bytes\n")
	return p9ring.serve(&server) == .Ok ? "" : "cannot serve"
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(start())
}
