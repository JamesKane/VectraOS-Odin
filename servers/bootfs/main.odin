// bootfs: the boot image as a read-only 9Px tree (upstream docs/01 §10,
// 04 §5 M2).
//
// svcd gives it the boot image (bootfs.tar, a read-only VMO) and a listen
// channel, which it posts as /srv/bootfs. bootfs maps the image, makes a node
// for each entry (and for any directory the archive only implies), and serves
// the tree over rings. Nothing is copied: a read comes straight from the
// mapped archive. Every file is read-only, whatever the archive says.
//
// An aname attaches below the root: "boot/bin" serves only that directory.
package bootfs

import "base:intrinsics"
import vx "abi:vx"
import "vx:ndb"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"
import "vx:tar"

@(private="file")
MAX_NODES :: 1024
@(private="file")
ROOT :: u64(1)

@(private="file")
Node :: struct {
	name:                             string,
	parent, first_child, next_sibling: u64,
	dir:                              bool,
	mode:                             u32,
	data:                             []u8, // into the mapped image
}

@(private="file")
nodes: [MAX_NODES]Node // 0 is unused, so a zero link means none
@(private="file")
node_count := u32(2)
@(private="file")
names: [64 * 1024]u8
@(private="file")
names_used: int

@(private="file")
fail :: proc "contextless" (what: string) -> ! {
	rt.print("bootfs: FAILED: ", what, "\n")
	rt.thread_exit(-1)
}

@(private="file")
child_named :: proc "contextless" (dir: u64, name: string) -> u64 {
	for c := nodes[dir].first_child; c != 0; c = nodes[c].next_sibling {
		if nodes[c].name == name {
			return c
		}
	}
	return 0
}

// The node for `name` in dir, made if it is not there yet. Children keep the
// archive's order.
@(private="file")
add_child :: proc "contextless" (dir: u64, name: string, is_dir: bool) -> u64 {
	if c := child_named(dir, name); c != 0 {
		return nodes[c].dir == is_dir ? c : 0 // a file and a directory of one name
	}
	if node_count == MAX_NODES || len(name) > len(names) - names_used {
		fail("the boot image has too many entries")
	}
	copy(names[names_used:], name)
	c := u64(node_count)
	node_count += 1
	nodes[c] = {name = string(names[names_used:][:len(name)]), parent = dir, dir = is_dir, mode = 0o555}
	names_used += len(name)
	link := &nodes[dir].first_child
	for link^ != 0 {
		link = &nodes[link^].next_sibling
	}
	link^ = c
	return c
}

@(private="file")
load :: proc "contextless" (image: []u8) {
	nodes[ROOT] = {name = "/", dir = true, mode = 0o555}
	t := tar.open(image)
	e: tar.Entry
	st: vx.Status
	for st = tar.next(&t, &e); st == .Ok; st = tar.next(&t, &e) {
		at := ROOT
		start := 0
		for i in 0 ..= len(e.path) {
			if i < len(e.path) && e.path[i] != '/' {
				continue
			}
			last := i == len(e.path)
			at = add_child(at, e.path[start:i], e.dir if last else true)
			if at == 0 {
				fail("the boot image has a file and a directory with one name")
			}
			start = i + 1
		}
		if !e.dir {
			nodes[at].data = e.data
		}
		nodes[at].mode = e.mode & 0o555 // read-only
	}
	if st == .Err_Invalid {
		fail("the boot image is malformed")
	}
}

// --- The file system ---

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: u64, name: string) -> (child: u64, st: vx.Status) {
	child = child_named(dir, name)
	return child, child != 0 ? .Ok : .Err_Not_Found
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: u64, st: vx.Status) {
	at := ROOT
	start := 0
	for i in 0 ..= len(aname) {
		if i < len(aname) && aname[i] != '/' {
			continue
		}
		part := aname[start:i]
		start = i + 1
		if len(part) == 0 {
			continue
		}
		// part is not empty and holds no '/', so of lib/p9's name rules
		// only "." is left to refuse; ".." is refused here too.
		if part == "." || part == ".." {
			return 0, .Err_Not_Found
		}
		next, wst := fs_walk(ctx, at, part)
		if wst != .Ok {
			return 0, .Err_Not_Found
		}
		at = next
	}
	if !nodes[at].dir {
		return 0, .Err_Not_Found
	}
	return at, .Ok
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, n: u64) -> (parent: u64, st: vx.Status) {
	return n == ROOT ? ROOT : nodes[n].parent, .Ok
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, n: u64, out: ^p9.Stat) -> vx.Status {
	x := &nodes[n]
	out^ = {
		qid    = {type = x.dir ? p9.QTDIR : p9.QTFILE, version = 0, path = n},
		mode   = (x.dir ? p9.DMDIR : 0) | x.mode,
		length = u64(len(x.data)),
		name   = x.name,
		uid    = "boot",
		gid    = "boot",
		muid   = "boot",
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, n: u64, mode: u8) -> vx.Status {
	writes := mode & 3 == p9.OWRITE || mode & 3 == p9.ORDWR || mode & (p9.OTRUNC | p9.ORCLOSE) != 0
	return writes ? .Err_Access : .Ok
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, n: u64, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	data := nodes[n].data
	left := offset < u64(len(data)) ? u64(len(data)) - offset : 0
	count = u32(min(u64(len(buf)), left))
	if count > 0 {
		copy(buf, data[offset:][:count])
	}
	return count, .Ok
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: u64, index: u32) -> (child: u64, st: vx.Status) {
	c := nodes[dir].first_child
	for i := index; c != 0 && i > 0; i -= 1 {
		c = nodes[c].next_sibling
	}
	return c, c != 0 ? .Ok : .Err_Not_Found
}

// Not file-private: tests/host drives its Fs on the host.
server := p9ring.Server {
	fs = {attach = fs_attach, walk = fs_walk, parent = fs_parent, stat = fs_stat, open = fs_open, read = fs_read, readdir = fs_readdir},
	name = "bootfs",
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	image := rt.spawn_take("bootimage")
	server.listen = rt.spawn_take("listen")
	rec: ndb.Record
	size: u64
	ok := image != vx.HANDLE_NONE && server.listen != vx.HANDLE_NONE && rt.spawn_record("bootimage", &rec)
	if ok {
		size, ok = ndb.get_u64(&rec, "size")
	}
	if !ok {
		fail("no boot image or listen channel in the spawn message")
	}
	// The size comes from svcd; round it up to pages without wrapping.
	padded, overflow := intrinsics.overflow_add(size, 4095)
	if overflow {
		fail("cannot map the boot image")
	}
	base, st := rt.as_map(rt.self, image, 0, padded &~ 4095, {})
	if st != .Ok {
		fail("cannot map the boot image")
	}
	_ = rt.handle_close(image) // the mapping keeps it
	load(([^]u8)(uintptr(base))[:size])

	files, dirs: u64
	for i in ROOT ..< u64(node_count) {
		if nodes[i].dir {
			dirs += 1
		} else {
			files += 1
		}
	}
	rt.print("bootfs: serving ")
	rt.print_u64(files)
	rt.print(" files in ")
	rt.print_u64(dirs)
	rt.print(" directories\n")
	return int(p9ring.serve(&server))
}
