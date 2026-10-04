// isofs: ISO 9660 with Rock Ridge and Joliet over a block session (upstream
// docs/11 §11, its M5 step 8c), served read-only as 9Px on its post: install
// media, CD images. After 9front's 9660srv; the format is lib/iso's, which
// reads Rock Ridge if the volume has it, else Joliet, else plain ISO 9660;
// -r and -j avoid Rock Ridge and Joliet.
//
//   service=isofs program=/boot/bin/isofs post=cd console
//   connect=disk1
//   arg=-u
//   arg=vectra
//
// Every file is the -u user's (none if not given); its permissions are
// Rock Ridge's, or 0444 (directories 0555). Rock Ridge's symbolic links are
// served with the posix extension's Treadlink.
package isofs

import vx "abi:vx"
import "vx:driver"
import "vx:iso"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"
import "vx:str"

@(private="file")
disk: driver.Blk
@(private="file")
disk_name: string
@(private="file")
owner := "none"
@(private="file")
vol: iso.Vol

@(private="file")
fail :: proc "contextless" (what: string, st := vx.Status.Ok) -> ! {
	if st != .Ok {
		rt.print("isofs: FAILED: ", what, ": ", p9.error_text(st), "\n")
	} else {
		rt.print("isofs: FAILED: ", what, "\n")
	}
	rt.exits(what)
}

@(private="file")
dev_read :: proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool {
	return driver.blk_read((^driver.Blk)(ctx), off, buf) == .Ok // 2048-byte sectors: whole disk sectors
}

// --- 9Px ---

@(private="file")
scratch: iso.Entry // stat's strings live here until the next call
@(private="file")
current: iso.Entry // the entry reads use, kept: they usually go on with the same file

@(private="file", require_results)
use :: proc "contextless" (node: p9.Node) -> (e: ^iso.Entry, st: vx.Status) {
	if current.node != iso.Node(node) {
		if st = iso.get(&vol, iso.Node(node), &current); st != .Ok {
			current.node = 0
			return nil, st
		}
	}
	return &current, .Ok
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return p9.Node(iso.ROOT), .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	d, e: iso.Entry
	st = iso.get(&vol, iso.Node(dir), &d)
	if st == .Ok {
		st = iso.lookup(&vol, &d, name, &e)
	}
	if st == .Ok {
		child = p9.Node(e.node)
	}
	return child, st == .Err_Invalid ? .Err_Not_Found : st
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	up: iso.Node
	up, st = iso.parent(&vol, iso.Node(node))
	return p9.Node(up), st
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	iso.get(&vol, iso.Node(node), &scratch) or_return
	mode := scratch.mode & 0o777
	if scratch.dir {
		mode |= p9.DMDIR
	}
	if scratch.link {
		mode |= p9.DMSYMLINK
	}
	out^ = {
		// A link is DMSYMLINK in its mode, as fsd's are.
		qid    = {type = scratch.dir ? p9.QTDIR : p9.QTFILE, version = 0, path = u64(node)},
		mode   = mode,
		atime  = u32(scratch.mtime),
		mtime  = u32(scratch.mtime),
		length = scratch.dir || scratch.link ? 0 : u64(scratch.size),
		name   = iso.entry_name(&scratch),
		uid    = owner,
		gid    = owner,
		muid   = owner,
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	return mode.access == .Read && !mode.trunc && !mode.rclose ? .Ok : .Err_Access
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	e := use(node) or_return
	if e.dir {
		return 0, .Err_Invalid // read as a directory, through readdir
	}
	n: int
	n, st = iso.read(&vol, e, offset, buf)
	return u32(n), st
}

@(private="file")
fs_readlink :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (target: string, st: vx.Status) {
	e := use(node) or_return
	if !e.link {
		return "", .Err_Invalid
	}
	return iso.entry_target(e), .Ok
}

// A listing goes index by index: the last one's place is kept.
@(private="file")
Listing :: struct {
	dir:  p9.Node,
	next: u32,
	open: bool,
	it:   iso.Iter,
}

@(private="file")
listing: Listing

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	if !listing.open || listing.dir != dir || index < listing.next {
		d: iso.Entry
		st = iso.get(&vol, iso.Node(dir), &d)
		if st == .Ok {
			listing.it, st = iso.open_dir(&d)
		}
		if st != .Ok {
			listing.open = false
			return 0, st
		}
		listing.dir, listing.next, listing.open = dir, 0, true
	}
	e: iso.Entry
	for st == .Ok && listing.next <= index {
		st = iso.dir_next(&vol, &listing.it, &e)
		listing.next += 1
	}
	if st != .Ok {
		listing.open = false
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
		readlink = fs_readlink,
	},
	name = "isofs",
	supported = {.Posix, .Xattr}, // Treadlink; Tgetattr, for stat
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
	disk, disk_name, owner = {}, "", "none"
	vol, current, scratch, listing = {}, {}, {}, {}
}

// Everything vx_main does, up to its exit string: tests/host calls it,
// with a fake kernel that lets it mount a disk and then not serve.
start :: proc() -> string {
	reset()
	avoid: iso.Kinds
	args := rt.args()
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "-u" && i + 1 < len(args) && args[i + 1] != "":
			i += 1
			owner = args[i]
		case args[i] == "-r":
			avoid += {.Rock}
		case args[i] == "-j":
			avoid += {.Joliet}
		case:
			fail("usage: isofs [-r] [-j] [-u user]")
		}
	}
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		fail("no listen channel (post=)")
	}
	if st := driver.blk_open(&disk, find_disk(), {}); st != .Ok {
		fail("cannot open a session on the disk", st)
	}
	if iso.SECTOR % disk.sector != 0 {
		fail("the disk's sectors do not divide 2048")
	}
	if st := iso.mount(&vol, {ctx = &disk, read = dev_read}, avoid); st != .Ok {
		fail("no ISO 9660 volume on the disk", st)
	}
	rt.print("isofs: /srv/", disk_name, ": ISO 9660")
	#partial switch vol.kind {
	case .Rock:
		rt.print(" with Rock Ridge")
	case .Joliet:
		rt.print(" with Joliet")
	}
	if label := iso.label(&vol); label != "" {
		rt.print(" \"", label, "\"")
	}
	rt.print(", ", vol.sectors, " sectors\n")
	return p9ring.serve(&server) == .Ok ? "" : "cannot serve"
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(start())
}
