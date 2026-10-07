// tmpfs: a file system in memory (upstream 02 §5), posted as /srv/tmpfs and
// mounted on /tmp by the POSIX template (/lib/ns/posix).
//
// Files and directories are made, written, truncated and removed as 9P has
// them, and renamed, changed (mode, size, times) and linked symbolically as
// the posix and xattr extensions have them (upstream docs/proto/posix.md). A
// file's bytes are in a mapping of its own that grows by doubling; a symbolic
// link's are its target.
//
// A file removed while it is open keeps its bytes until the last fid that
// opened it lets go, as POSIX has it; a node id names one node only, so a fid
// to a removed one finds nothing. What it holds lives only in it, and is
// limited to MAX_BYTES and MAX_NODES.
//
// It serves trees: the shared one (aname "", what procfs's crash
// directories and the tests share), and one for each user (aname "user": the
// attaching user's own, made at its first attach, 0700), which is that
// user's /tmp where it has no home on disk (upstream's M6 step 6e1c2, as
// 9front's /usr/$user/tmp). The trees share the server's limits. aname
// "crash" is the shared tree's /crash, where procfs saves crash directories
// (05 §5), which namespaces mount on /tmp/crash inside the user's own /tmp.
package tmpfs

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

MAX_NODES :: 1024
MAX_BYTES :: u64(128) << 20
MAX_FILE :: u64(64) << 20
MAX_NAME :: 128 // a name is shorter
@(private="file")
ROOT :: u32(1)

@(private="file")
Node :: struct {
	used, dir, removed, link:          bool,
	top:                               bool, // a tree's root: the shared one (ROOT), or a user's, named after the user
	gen:                               u32, // with the slot, the node's id: a removed node's id names nothing
	name:                              [dynamic; MAX_NAME - 1]u8,
	parent, first_child, next_sibling: u32, // slots; 0 is none
	mode, atime, mtime, version:       u32,
	opens:                             u32, // fids that opened it: a removed file keeps its bytes until 0
	data:                              []u8, // the mapping, as long as its capacity
	size:                              u64,
}

@(private="file")
nodes: [MAX_NODES]Node // 0 is unused, so a zero link means none
@(private="file")
bytes_used: u64

@(private="file")
id_of :: proc "contextless" (slot: u32) -> p9.Node {
	return p9.Node(u64(nodes[slot].gen) << 32 | u64(slot))
}

// The node an id names, and its slot; nil for none, or one removed and
// reused since.
@(private="file")
node_at :: proc "contextless" (id: p9.Node) -> (n: ^Node, slot: u32) {
	s := u32(id)
	if s == 0 || s >= MAX_NODES || !nodes[s].used || nodes[s].gen != u32(id >> 32) {
		return nil, 0
	}
	return &nodes[s], s
}

@(private="file")
now_seconds :: proc "contextless" () -> u32 {
	return u32(rt.clock_utc() / 1_000_000_000) // UTC once there is a wall clock (upstream ADR-0031)
}

// vx:rt's as_unmap wrapper comes with the kernel's M4 port; until then, the
// call itself, as lib/procns makes it.
@(private="file")
unmap :: proc "contextless" (b: []u8) {
	_ = rt.vx_syscall(.As_Unmap, u64(rt.self), u64(uintptr(raw_data(b))), u64(len(b)))
}

@(private="file")
free_data :: proc "contextless" (n: ^Node) {
	if n.data != nil {
		unmap(n.data)
	}
	bytes_used -= u64(len(n.data))
	n.data = nil
	n.size = 0
}

@(private="file")
free_node :: proc "contextless" (n: ^Node) {
	free_data(n)
	n^ = {gen = n.gen + 1}
}

// Room for `size` bytes: a mapping twice as large as before, the old copied.
@(private="file", require_results)
reserve :: proc "contextless" (n: ^Node, size: u64) -> vx.Status {
	old := u64(len(n.data))
	if size <= old {
		return .Ok
	}
	if size > MAX_FILE {
		return .Err_No_Memory
	}
	capacity := old != 0 ? old : memory.PAGE_SIZE
	for capacity < size {
		capacity *= 2
	}
	if bytes_used - old + capacity > MAX_BYTES {
		return .Err_No_Memory
	}
	vmo := rt.vmo_create(capacity) or_return
	at, st := rt.as_map(rt.self, vmo, 0, capacity, {.Write})
	_ = rt.handle_close(vmo) // the mapping keeps it
	st or_return
	data := (cast([^]u8)uintptr(at))[:capacity]
	copy(data, n.data[:n.size])
	size_was := n.size
	free_data(n)
	n.data = data
	n.size = size_was
	bytes_used += capacity
	return .Ok
}

@(private="file")
child_named :: proc "contextless" (dir: u32, name: string) -> u32 {
	for c := nodes[dir].first_child; c != 0; c = nodes[c].next_sibling {
		if string(nodes[c].name[:]) == name {
			return c
		}
	}
	return 0
}

@(private="file")
unlink_child :: proc "contextless" (s: u32) {
	n := &nodes[s]
	for link := &nodes[n.parent].first_child; link^ != 0; link = &nodes[link^].next_sibling {
		if link^ == s {
			link^ = n.next_sibling
			break
		}
	}
	nodes[n.parent].mtime = now_seconds()
	n.next_sibling = 0
}

// Children in the order they came.
@(private="file")
append_child :: proc "contextless" (dir, s: u32) {
	link := &nodes[dir].first_child
	for link^ != 0 {
		link = &nodes[link^].next_sibling
	}
	link^ = s
	nodes[s].parent = dir
	nodes[dir].mtime = now_seconds()
}

// The node leaves its directory; its bytes stay while a fid has it open.
@(private="file")
drop :: proc "contextless" (s: u32) {
	unlink_child(s)
	n := &nodes[s]
	n.removed = true
	if n.opens == 0 {
		free_node(n)
	}
}

// --- The file system ---

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return id_of(ROOT), .Ok
}

// aname "user": the attaching user's own tree, made the first time; "crash":
// the shared tree's /crash, made if it is not there.
@(private="file")
fs_attach_as :: proc "contextless" (ctx: rawptr, aname, uname: string) -> (root: p9.Node, st: vx.Status) {
	if aname == "crash" {
		c := child_named(ROOT, "crash")
		if c == 0 {
			made := fs_create(ctx, id_of(ROOT), "crash", p9.DMDIR | 0o777, p9.OREAD) or_return
			c = u32(made)
		}
		return id_of(c), .Ok
	}
	if aname != "user" {
		return fs_attach(ctx, aname)
	}
	user := uname != "" ? uname : "none"
	if len(user) >= MAX_NAME {
		return 0, .Err_Range
	}
	free_slot := u32(0)
	for s in ROOT + 1 ..< MAX_NODES {
		n := &nodes[s]
		if n.used && n.top && string(n.name[:]) == user {
			return id_of(s), .Ok
		}
		if !n.used && free_slot == 0 {
			free_slot = s
		}
	}
	if free_slot == 0 {
		return 0, .Err_No_Memory
	}
	n := &nodes[free_slot]
	n^ = {
		used  = true,
		dir   = true,
		top   = true,
		gen   = n.gen,
		mode  = 0o700,
		mtime = now_seconds(),
	}
	_ = append(&n.name, user) // it fits: checked above
	return id_of(free_slot), .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	d, ds := node_at(dir)
	if d == nil || !d.dir {
		return 0, .Err_Not_Found
	}
	c := child_named(ds, name)
	if c == 0 {
		return 0, .Err_Not_Found
	}
	return id_of(c), .Ok
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, id: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	n, _ := node_at(id)
	// A removed directory has no parent to go back to (its slot may hold
	// another node by now): ENOENT, as Linux answers .. in one.
	if n == nil || n.removed {
		return 0, .Err_Not_Found
	}
	if n.parent == 0 {
		return id, .Ok // a tree's root is its own parent
	}
	return id_of(n.parent), .Ok
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, id: p9.Node, out: ^p9.Stat) -> vx.Status {
	n, _ := node_at(id)
	if n == nil {
		return .Err_Not_Found
	}
	qtype := n.dir ? p9.QTDIR : p9.QTFILE
	qtype += transmute(p9.Qid_Type)u8(n.mode >> 24) & (p9.QTAPPEND + p9.QTEXCL)
	out^ = {
		qid    = {type = qtype, version = n.version, path = u64(id)},
		mode   = (n.dir ? p9.DMDIR : 0) | (n.link ? p9.DMSYMLINK : 0) | n.mode,
		atime  = n.atime,
		mtime  = n.mtime,
		length = n.dir ? 0 : n.size,
		name   = n.top ? "/" : string(n.name[:]),
		uid    = "posix",
		gid    = "posix",
		muid   = "posix",
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, id: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	n, _ := node_at(id)
	if n == nil || (n.removed && !mode.join) { // a join: open still, removed or not
		return .Err_Not_Found
	}
	if n.dir && (p9.writes(mode) || mode.trunc) {
		return .Err_Access
	}
	if n.mode & p9.DMEXCL != 0 && n.opens != 0 && !mode.join {
		return .Err_Access // open already
	}
	if mode.trunc {
		n.size = 0
		n.mtime = now_seconds()
		n.version += 1
	}
	n.opens += 1
	return .Ok
}

@(private="file")
fs_clunk :: proc "contextless" (ctx: rawptr, id: p9.Node, opened: bool) {
	n, _ := node_at(id)
	if n == nil || !opened {
		return
	}
	if n.opens > 0 {
		n.opens -= 1
	}
	if n.removed && n.opens == 0 {
		free_node(n) // the last of a removed file
	}
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, id: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	n, _ := node_at(id)
	if n == nil {
		return 0, .Err_Not_Found
	}
	if offset >= n.size {
		return 0, .Ok
	}
	return u32(copy(buf, n.data[offset:n.size])), .Ok
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, id: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	n, _ := node_at(id)
	if n == nil || n.dir {
		return 0, .Err_Access
	}
	end, overflow := intrinsics.overflow_add(offset, u64(len(data)))
	if overflow {
		return 0, .Err_Range
	}
	reserve(n, end) or_return
	if offset > n.size {
		intrinsics.mem_zero(&n.data[n.size], offset - n.size) // a hole reads as zeros
	}
	copy(n.data[offset:], data)
	n.size = max(n.size, end)
	n.mtime = now_seconds()
	n.version += 1
	return u32(len(data)), .Ok
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	d, _ := node_at(dir)
	if d == nil {
		return 0, .Err_Not_Found
	}
	c := d.first_child
	for i := index; c != 0 && i > 0; i -= 1 {
		c = nodes[c].next_sibling
	}
	if c == 0 {
		return 0, .Err_Not_Found
	}
	return id_of(c), .Ok
}

@(private="file")
fs_create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	d, ds := node_at(dir)
	if d == nil || !d.dir || d.removed {
		return 0, .Err_Not_Found
	}
	if name == "" || len(name) >= MAX_NAME {
		return 0, .Err_Range
	}
	if child_named(ds, name) != 0 {
		return 0, .Err_Exists
	}
	s := ROOT + 1
	for s < MAX_NODES && nodes[s].used {
		s += 1
	}
	if s == MAX_NODES {
		return 0, .Err_No_Memory
	}
	is_dir := perm & p9.DMDIR != 0
	if is_dir && mode.access != .Read {
		return 0, .Err_Access
	}
	n := &nodes[s]
	n^ = {
		used   = true,
		dir    = is_dir,
		gen    = n.gen,
		parent = ds,
		mode   = perm & (0o777 | (is_dir ? 0 : p9.DMAPPEND | p9.DMEXCL)), // a file's DMAPPEND, DMEXCL
		mtime  = now_seconds(),
		opens  = 1, // create opens it
	}
	_ = append(&n.name, name) // it fits: checked above
	append_child(ds, s)
	return id_of(s), .Ok
}

// A directory only when empty. The node leaves its directory at once; a file
// still open keeps its bytes until it is not (fs_clunk).
@(private="file")
fs_remove :: proc "contextless" (ctx: rawptr, id: p9.Node) -> vx.Status {
	n, s := node_at(id)
	if n == nil || n.removed {
		return .Err_Not_Found
	}
	if n.top {
		return .Err_Access
	}
	if n.dir && n.first_child != 0 {
		return .Err_Exists // not empty
	}
	drop(s)
	return .Ok
}

// --- The posix and xattr extensions ---

@(private="file")
fs_setattr :: proc "contextless" (ctx: rawptr, id: p9.Node, a: ^p9.Setattr) -> vx.Status {
	n, _ := node_at(id)
	if n == nil || n.removed {
		return .Err_Not_Found
	}
	if .Size in a.valid {
		if n.dir || n.link {
			return .Err_Invalid
		}
		reserve(n, a.size) or_return
		if a.size > n.size {
			intrinsics.mem_zero(&n.data[n.size], a.size - n.size)
		}
		n.size = a.size
		n.version += 1
	}
	if .Mode in a.valid {
		n.mode = (n.mode & (p9.DMAPPEND | p9.DMEXCL)) | (a.mode & 0o7777)
	}
	now := now_seconds()
	if .Atime in a.valid {
		n.atime = .Atime_Set in a.valid ? u32(a.atime_sec) : now
	}
	if .Mtime in a.valid {
		n.mtime = .Mtime_Set in a.valid ? u32(a.mtime_sec) : now
	}
	if .Size in a.valid && .Mtime not_in a.valid {
		n.mtime = now
	}
	return .Ok // owners are not kept: uid and gid change nothing
}

// Moves olddir's entry to newdir as newname, replacing what is there as
// POSIX's rename does: a file by a file, an empty directory by a directory.
@(private="file")
fs_rename :: proc "contextless" (ctx: rawptr, olddir: p9.Node, oldname: string, newdir: p9.Node, newname: string) -> vx.Status {
	from_dir, from := node_at(olddir)
	to_dir, to := node_at(newdir)
	if from_dir == nil || to_dir == nil || !to_dir.dir || to_dir.removed {
		return .Err_Not_Found
	}
	if len(newname) >= MAX_NAME {
		return .Err_Range
	}
	s := child_named(from, oldname)
	if s == 0 {
		return .Err_Not_Found
	}
	for up := to; up != 0; up = nodes[up].top ? 0 : nodes[up].parent {
		if up == s {
			return .Err_Invalid // into itself
		}
	}
	there := child_named(to, newname)
	if there == s {
		return .Ok
	}
	if there != 0 {
		t := &nodes[there]
		if t.dir != nodes[s].dir {
			return t.dir ? .Err_Exists : .Err_Invalid
		}
		if t.dir && t.first_child != 0 {
			return .Err_Exists // not empty
		}
		drop(there)
	}
	unlink_child(s)
	clear(&nodes[s].name)
	_ = append(&nodes[s].name, newname) // it fits: checked above
	append_child(to, s)
	return .Ok
}

@(private="file")
fs_symlink :: proc "contextless" (ctx: rawptr, dir: p9.Node, name, target: string) -> (node: p9.Node, st: vx.Status) {
	if target == "" {
		return 0, .Err_Invalid
	}
	node = fs_create(ctx, dir, name, 0o777, p9.OREAD) or_return
	n, _ := node_at(node)
	n.opens = 0 // made, not opened
	n.link = true
	if st = reserve(n, u64(len(target))); st != .Ok {
		_ = fs_remove(ctx, node)
		return 0, st
	}
	copy(n.data, target)
	n.size = u64(len(target))
	return node, .Ok
}

@(private="file")
fs_readlink :: proc "contextless" (ctx: rawptr, id: p9.Node) -> (target: string, st: vx.Status) {
	n, _ := node_at(id)
	if n == nil || !n.link {
		return "", .Err_Invalid
	}
	return string(n.data[:n.size]), .Ok
}

// Not file-private: tests/host drives its Fs on the host.
server := p9ring.Server {
	fs = {
		attach    = fs_attach,
		attach_as = fs_attach_as,
		walk      = fs_walk,
		parent   = fs_parent,
		stat     = fs_stat,
		open     = fs_open,
		read     = fs_read,
		readdir  = fs_readdir,
		write    = fs_write,
		create   = fs_create,
		remove   = fs_remove,
		clunk    = fs_clunk,
		setattr  = fs_setattr,
		rename   = fs_rename,
		symlink  = fs_symlink,
		readlink = fs_readlink,
	},
	name = "tmpfs",
	supported = {.Posix, .Xattr, .Notify},
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		rt.print("tmpfs: no listen channel\n")
		return -1 // upstream's exit string: "no listen channel"
	}
	nodes[ROOT] = {used = true, dir = true, top = true, mode = 0o777, mtime = now_seconds()}
	rt.print("tmpfs: serving /srv/tmpfs\n")
	return int(p9ring.serve(&server))
}
