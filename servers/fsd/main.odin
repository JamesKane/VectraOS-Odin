// fsd: the system volume's file server (upstream docs/11 §7). It mounts a
// vx:fs volume on a block session (its manifest's connect=, as "srv:NAME": a
// partition partd serves, say) and serves its branches over 9Px, with the
// posix and xattr extensions, through vx:p9ring as tmpfs is:
//
//   service=fsd program=/boot/bin/fsd post=fsd console entropy pager
//   connect=disk1.vectra
//
// (entropy: the seed the framework's open-file tokens need, which a forked
// child joins its parent's open files with.)
//
// The attach name is the branch: `mount /srv/fsd /home home`.
//
// A node id (Id) is the branch's slot in its high byte, the attaching
// user's index in the users table in the next, and the entry's qid below
// them: a fid finds its entry by the qid's Kup (lib/fs/file.odin) whatever it
// walked through, and every call knows who makes it. A file removed while it
// is open is an orphan until its last open fid goes (its data then cleared);
// a crash leaves orphans that the branch's next opening reaps.
//
// Users are /adm/users (users.odin); permissions are Plan 9's, as gefs
// checks them. The adm branch's root has two files fsd makes, status and
// ctl (adm.odin), and an attach name of %BRANCH is the branch without
// permissions, for adm's members (gefs's permissive attach). An attach name
// that labels a snapshot, not a branch, is that snapshot, read-only, and
// `dump` is the dump view (dump.odin).
//
// Changes are committed every 5 s, and by Tfsync, which is answered once its
// commit is durable (upstream 11 §6). Single-threaded: one loop, which waits
// for the disk.
//
// fsd is the system's pager (upstream 11 §8) when its manifest gives it
// `pager`: Tmap answers with a pager-backed VMO for the whole file, one per
// file however many map it (pcache.odin).
//
// Everything below runs from p9ring's callbacks, which are contextless.
package fsd

import "base:intrinsics"
import vx "abi:vx"
import "vx:driver"
import "vx:fs"
import "vx:memory"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"
import "vx:str"
import "vx:users"

COMMIT_EVERY :: vx.Duration(5_000_000_000)
CACHE_BLOCKS :: 1024 // 16 MiB of tree nodes and data
MAX_OPEN :: 512 // distinct nodes open at once

// A node id, as fsd hands it to the framework (p9.Node) and to clients (the
// qid's path): the file's qid in its tree, the attaching user's index in
// the users table, whether the attach was %BRANCH, and the tree's slot.
Id :: bit_field u64 {
	qid:        u64  | 48,
	user:       u32  | 7, // a user index is 7 bits: users.MAX + 1
	permissive: bool | 1, // the node's attach was %BRANCH
	slot:       u32  | 8,
}
#assert(size_of(Id) == 8)

// The trees a slot names: a branch's (below fs.MAXBRANCH), a read-only
// snapshot's (RO_FIRST up), or the dump view's.
RO_FIRST :: 16
RO_SLOTS :: 32
DUMP_SLOT :: 0x7f
#assert(fs.MAXBRANCH <= RO_FIRST && RO_FIRST + RO_SLOTS <= DUMP_SLOT)

// The adm branch's made-up files' qids, which no entry has.
CTL_QID :: u64(1) << 48 - 2
STATUS_QID :: u64(1) << 48 - 3

disk: driver.Blk
vol: fs.Vol // large: in static storage, never copied
disk_name: string
dirty: bool
next_commit: vx.Instant
reaped: [fs.MAXBRANCH]bool
halted: bool // ctl's halt: committed, and no more changes

fail :: proc "contextless" (what: string, st: vx.Status = .Ok) -> ! {
	if st != .Ok {
		rt.print("fsd: FAILED: ", what, ": ", p9.error_text(st), "\n")
	} else {
		rt.print("fsd: FAILED: ", what, "\n")
	}
	rt.exits(what)
}

// --- The volume's device and memory ---

@(private="file")
dev_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	return driver.blk_read((^driver.Blk)(ctx), u64(addr), buf[:])
}

@(private="file")
dev_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	return driver.blk_write((^driver.Blk)(ctx), u64(addr), buf[:])
}

@(private="file")
dev_barrier :: proc "contextless" (ctx: rawptr) -> vx.Status {
	return driver.blk_flush((^driver.Blk)(ctx))
}

// Whole pages, each allocation a mapping of its own.
@(private="file")
mem_alloc :: proc "contextless" (ctx: rawptr, n: int) -> rawptr {
	size, ok := memory.page_round(u64(n))
	if !ok {
		return nil
	}
	vmo, st := rt.vmo_create(size)
	if st != .Ok {
		return nil
	}
	at: u64
	at, st = rt.as_map(rt.self, vmo, 0, size, {.Write})
	_ = rt.handle_close(vmo) // the mapping keeps it
	return st == .Ok ? rawptr(uintptr(at)) : nil
}

@(private="file")
mem_free :: proc "contextless" (ctx: rawptr, p: rawptr, n: int) {
	size, _ := memory.page_round(u64(n))
	_ = rt.as_unmap(rt.self, u64(uintptr(p)), size)
}

// --- Nodes ---

// Times, in ns: UTC once there is a wall clock (upstream ADR-0031), from
// boot before, as sysfs's realtime is.
now_ns :: proc "contextless" () -> i64 {
	return rt.clock_utc()
}

node_of :: proc "contextless" (slot: u32, user: u32, qid: u64, permissive := false) -> Id {
	return Id{qid = qid, user = user, permissive = permissive, slot = slot}
}

// The file a node is, whoever reaches it and however: its slot and qid.
file_key :: proc "contextless" (node: Id) -> u64 {
	return u64(node.slot) << 56 | node.qid
}

// The node of entry f, found from dir: in its tree, for its user, as
// permissive as dir.
node_in :: proc "contextless" (dir: Id, f: ^fs.File) -> Id {
	return node_of(dir.slot, dir.user, f.d.qid_path, dir.permissive)
}

tree_of :: proc "contextless" (node: Id) -> ^fs.Tree {
	s := node.slot
	if s < fs.MAXBRANCH {
		return vol.br[s].open ? &vol.br[s].t : nil
	}
	if s >= RO_FIRST && s < RO_FIRST + RO_SLOTS {
		r := &ro[s - RO_FIRST]
		return r.used ? &r.t : nil
	}
	return nil
}

branch_slot :: proc "contextless" (br: ^fs.Branch) -> u32 {
	return u32(intrinsics.ptr_sub(br, &vol.br[0]))
}

is_branch :: proc "contextless" (node: Id, name: string) -> bool {
	s := node.slot
	return s < fs.MAXBRANCH && vol.br[s].open && fs.branch_name(&vol.br[s]) == name
}

is_made_up :: proc "contextless" (node: Id) -> bool {
	return is_branch(node, "adm") && (node.qid == CTL_QID || node.qid == STATUS_QID)
}

is_readonly :: proc "contextless" (node: Id) -> bool {
	return node.slot >= RO_FIRST // a snapshot, or the dump view
}

// ctl or status, as an entry in the adm branch's root.
@(private="file", require_results)
made_up :: proc "contextless" (node: Id) -> (f: fs.File, st: vx.Status) {
	root := fs.root(&vol, tree_of(node)) or_return
	ctl := node.qid == CTL_QID
	now := now_ns()
	f.d = {qid_path = node.qid, mode = ctl ? 0o660 : 0o444, mtime = now, atime = now}
	f.nkey = len(fs.key_ent(f.key[:], root.d.qid_path, ctl ? "ctl" : "status"))
	return f, .Ok
}

@(require_results)
file_of :: proc "contextless" (node: Id) -> (fs.File, vx.Status) {
	if is_dump(node) {
		return dump_file(node), .Ok
	}
	t := tree_of(node)
	if t == nil {
		return {}, .Err_Not_Found
	}
	if is_made_up(node) {
		return made_up(node)
	}
	return fs.file_by_qid(&vol, t, node.qid)
}

// A name as the library sees it: up to its first NUL, as upstream's C
// strings end.
c_name :: proc "contextless" (s: string) -> string {
	if i := str.index_byte(s, 0); i >= 0 {
		return s[:i]
	}
	return s
}

changed :: proc "contextless" () {
	if !dirty {
		next_commit = rt.clock_read() + COMMIT_EVERY
	}
	dirty = true
}

@(require_results)
commit :: proc "contextless" () -> vx.Status {
	writeback_all() // what mappings wrote, into the volume first
	if !dirty {
		return .Ok
	}
	if st := fs.commit(&vol); st != .Ok {
		rt.print("fsd: the commit failed, and the volume is read-only now: ", p9.error_text(st), "\n")
		return st
	}
	dirty = false
	return .Ok
}

// Open fids, counted by file (file_key: every user's, through any attach,
// together): an orphan's data goes with the last.
Opened :: struct {
	node:  Id, // one of them, to find the file by
	count: u32,
}

opens: [MAX_OPEN]Opened

open_slot :: proc "contextless" (node: Id, make: bool) -> ^Opened {
	free: ^Opened
	for &o in opens {
		if o.count != 0 && file_key(o.node) == file_key(node) {
			return &o
		}
		if o.count == 0 && free == nil {
			free = &o
		}
	}
	if !make || free == nil {
		return nil
	}
	free^ = {node = node}
	return free
}

// --- Permissions ---

// What a node's user may do to an entry, as a mode's bits have it.
May :: enum u32 {
	X,
	W,
	R,
}
Mays :: bit_set[May;u32]

may :: proc "contextless" (node: Id, d: ^fs.Dir, want: Mays) -> bool {
	if node.permissive {
		return true
	}
	bits := transmute(u32)want
	if !is_none(node) {
		me := uid_of(node)
		if me == d.uid && (d.mode >> 6) & bits == bits {
			return true
		}
		if users.in_group(&ut, me, d.gid) && (d.mode >> 3) & bits == bits {
			return true
		}
	}
	return d.mode & bits == bits
}

is_adm :: proc "contextless" (node: Id) -> bool {
	return node.permissive || (!is_none(node) && users.in_group(&ut, uid_of(node), 0))
}

// A change, which a halted volume refuses.
@(require_results)
mutable :: proc "contextless" (node: Id) -> vx.Status {
	if halted {
		return .Err_Bad_State
	}
	if is_made_up(node) || is_readonly(node) {
		return .Err_Access // a snapshot, or the dump view
	}
	return .Ok
}

// --- The 9P side ---

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname, uname: string) -> (root: p9.Node, st: vx.Status) {
	name := aname
	all := len(name) > 0 && name[0] == '%' // permissive: adm's members only
	if all {
		name = name[1:]
	}
	who := users.named(&ut, uname)
	if all && !users.adm(&ut, uname) {
		return 0, .Err_Access
	}
	if len(name) == 0 || len(name) > fs.LABELMAX {
		return 0, .Err_Not_Found
	}
	base := node_of(0, who, 0, all)
	if name == "dump" {
		return p9.Node(dump_node(base, 0, 0, 0)), .Ok
	}
	label := c_name(name)
	br: ^fs.Branch
	br, st = fs.branch_open(&vol, label)
	if st == .Err_Access { // a snapshot's label: the snapshot, read-only
		r := ro_open(label) or_return
		return p9.Node(node_of(RO_FIRST + r, who, ro[r].root, all)), .Ok
	}
	if st != .Ok {
		return 0, .Err_Not_Found
	}
	slot := branch_slot(br)
	if !reaped[slot] { // what a crash left of files removed while open
		n := fs.reap_all(&vol, &br.t) or_return
		if n != 0 {
			changed()
		}
		reaped[slot] = true
	}
	f := fs.root(&vol, &br.t) or_return
	return p9.Node(node_of(slot, who, f.d.qid_path, all)), .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, d: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	dir := Id(d)
	if len(name) > fs.NAMEMAX {
		return 0, .Err_Range
	}
	if is_dump(dir) {
		c := dump_walk(dir, name) or_return
		return p9.Node(c), .Ok
	}
	df: fs.File
	df, st = file_of(dir)
	if st == .Ok && fs.is_dir(&df) && !may(dir, &df.d, {.X}) {
		st = .Err_Access
	}
	if st == .Ok && is_branch(dir, "adm") && df.nkey == 9 && (name == "ctl" || name == "status") {
		return p9.Node(node_of(dir.slot, dir.user, name == "ctl" ? CTL_QID : STATUS_QID, dir.permissive)), .Ok
	}
	f: fs.File
	if st == .Ok {
		f, st = fs.walk(&vol, tree_of(dir), &df, name)
	}
	if st == .Err_Invalid {
		st = .Err_Not_Found // through a file
	}
	if st != .Ok {
		return 0, st
	}
	return p9.Node(node_in(dir, &f)), .Ok
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	node := Id(n)
	if is_dump(node) { // a day's year, a year's root
		level := dump_level(node)
		return p9.Node(dump_node(node, level > 0 ? level - 1 : 0, level == 2 ? dump_year(node) : 0, 0)), .Ok
	}
	if r := dated_snapshot(node); r != nil && node.qid == r.root { // its day, in the dump view
		return p9.Node(dump_node(node, 2, r.year, r.mmdd)), .Ok
	}
	f, p: fs.File
	f, st = file_of(node)
	if st == .Ok && fs.is_orphan(&f) {
		st = .Err_Not_Found
	}
	if st == .Ok {
		p, st = fs.walk(&vol, tree_of(node), &f, "..")
	}
	if st != .Ok {
		return 0, st
	}
	return p9.Node(node_in(node, &p)), .Ok
}

// What a stat's strings point into, until the next call.
@(private="file")
stat_file: fs.File
@(private="file")
uid_bufs: [3][12]u8

@(private="file")
user_name :: proc "contextless" (buf: []u8, id: u32) -> string {
	if u := users.by_id(&ut, id); u != nil {
		return string(u.name[:])
	}
	return str.format_u64(buf, u64(id))
}

// A root's name: a dated snapshot's is its branch's, as the dump view lists
// it; others are /.
@(private="file")
root_name :: proc "contextless" (node: Id) -> string {
	if r := dated_snapshot(node); r != nil {
		return string(r.name[:len(r.name) - 11])
	}
	return "/"
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, n: p9.Node, out: ^p9.Stat) -> (st: vx.Status) {
	node := Id(n)
	stat_file = file_of(node) or_return
	d := &stat_file.d
	dir := d.mode & fs.DMDIR != 0
	root := stat_file.nkey == 9 && !fs.is_orphan(&stat_file)
	out^ = {
		qid    = {type = dir ? p9.QTDIR : {}, version = d.qid_vers, path = u64(node)},
		mode   = d.mode,
		atime  = u32(d.atime / 1_000_000_000),
		mtime  = u32(d.mtime / 1_000_000_000),
		length = dir ? 0 : d.length,
		name   = root ? root_name(node) : string(stat_file.key[9:stat_file.nkey]),
		uid    = user_name(uid_bufs[0][:], d.uid),
		gid    = user_name(uid_bufs[1][:], d.gid),
		muid   = user_name(uid_bufs[2][:], d.muid),
	}
	return .Ok
}

@(require_results)
truncate_to :: proc "contextless" (node: Id, f: ^fs.File, size: u64) -> vx.Status {
	now := now_ns()
	fs.setattr(&vol, tree_of(node), f, {valid = {.Size, .Mtime}, length = size, mtime = now}, now) or_return
	changed()
	pcache_truncated(node, size)
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> (st: vx.Status) {
	node := Id(n)
	f := file_of(node) or_return
	writes := p9.writes(mode) || mode.trunc
	if fs.is_dir(&f) && writes {
		return .Err_Access
	}
	want: Mays
	if mode.access == .Read || mode.access == .Rdwr {
		want += {.R}
	}
	if writes {
		want += {.W}
	}
	if mode.access == .Exec {
		want += {.X}
	}
	if is_made_up(node) { // ctl: adm's, to write; status: anyone's, to read
		ctl := node.qid == CTL_QID
		if ctl ? .R in want || !is_adm(node) : writes {
			return .Err_Access
		}
		if !ctl && make_status() != .Ok {
			return .Err_No_Memory
		}
		return .Ok
	}
	if writes && is_readonly(node) {
		return .Err_Access // a snapshot, or the dump view
	}
	if !mode.join && !may(node, &f.d, want) {
		return .Err_Access // a join has its open's rights
	}
	if halted && writes {
		return .Err_Bad_State
	}
	o := open_slot(node, true)
	if o == nil {
		return .Err_No_Memory
	}
	if mode.trunc {
		truncate_to(node, &f, 0) or_return
	}
	o.count += 1
	return .Ok
}

@(private="file")
fs_clunk :: proc "contextless" (ctx: rawptr, n: p9.Node, was_open: bool) {
	if was_open {
		clunk_node(Id(n))
	}
}

// One open of node let go: a fid's, or a cache entry's.
clunk_node :: proc "contextless" (node: Id) {
	o := open_slot(node, false)
	if o == nil {
		return
	}
	o.count -= 1
	if o.count != 0 {
		return
	}
	f, st := file_of(node)
	if st != .Ok {
		return
	}
	if fs.is_orphan(&f) { // the last of a removed file
		if fs.reap(&vol, tree_of(node), node.qid) == .Ok {
			changed()
		}
	} else if is_branch(node, "adm") && string(f.key[:f.nkey][9:]) == "users" {
		load_users() // /adm/users, as it is now
	}
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	node := Id(n)
	if is_made_up(node) { // status, as it was when opened (or read from the start)
		if offset == 0 {
			_ = make_status()
		}
		text := status_text[:]
		return u32(copy(buf, text[min(offset, u64(len(text))):])), .Ok
	}
	if c := pcache_find(node); c != nil {
		writeback(c) // what its mappings wrote, read too
	}
	f := file_of(node) or_return
	got: u64
	got, st = fs.read(&vol, tree_of(node), &f, offset, buf)
	return u32(got), st
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	node := Id(n)
	if is_made_up(node) {
		if node.qid != CTL_QID {
			return 0, .Err_Access
		}
		ctl_command(node, string(data)) or_return
		return u32(len(data)), .Ok
	}
	if halted {
		return 0, .Err_Bad_State
	}
	f := file_of(node) or_return
	if fs.is_dir(&f) {
		return 0, .Err_Access
	}
	fs.write(&vol, tree_of(node), &f, offset, data, now_ns(), uid_of(node)) or_return
	changed()
	pcache_wrote(node, offset, data)
	return u32(len(data)), .Ok
}

// dref (upstream docs/proto/dref.md): Tread and Twrite with the data in the
// client's VMO, through a bounce a chunk at a time, not by mapping it: a VMO
// of fsd's own page cache, mapped here, would fault to fsd itself.
@(private="file")
ref_buf: [64 * 1024]u8

@(private="file")
fs_read_ref :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status) {
	node := Id(n)
	if is_made_up(node) {
		return 0, .Err_Access
	}
	if c := pcache_find(node); c != nil {
		writeback(c)
	}
	f: fs.File
	f, st = file_of(node)
	for st == .Ok && done < count {
		want := min(count - done, len(ref_buf))
		got: u64
		got, st = fs.read(&vol, tree_of(node), &f, offset + u64(done), ref_buf[:want])
		if st == .Ok && got > 0 {
			st = rt.vmo_write(vmo, roffset + u64(done), ref_buf[:got])
		}
		if st == .Ok {
			done += u32(got)
		}
		if got < u64(want) {
			break // the end of the file
		}
	}
	return done, done > 0 ? .Ok : st // what was read, if anything was, as a short read
}

@(private="file")
fs_write_ref :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status) {
	node := Id(n)
	if is_made_up(node) {
		return 0, .Err_Access // ctl takes a command a write, inline
	}
	if halted {
		return 0, .Err_Bad_State
	}
	f := file_of(node) or_return
	if fs.is_dir(&f) {
		return 0, .Err_Access
	}
	for st == .Ok && done < count {
		chunk := ref_buf[:min(count - done, len(ref_buf))]
		st = rt.vmo_read(vmo, roffset + u64(done), chunk)
		if st == .Ok {
			st = fs.write(&vol, tree_of(node), &f, offset + u64(done), chunk, now_ns(), uid_of(node))
		}
		if st == .Ok {
			changed()
			pcache_wrote(node, offset + u64(done), chunk)
			done += u32(len(chunk))
		}
	}
	return done, done > 0 ? .Ok : st
}

// Listing: the entry after the last one given, when the next index is
// asked for in turn; otherwise from the start.
@(private="file")
Cursor :: struct {
	dir:  Id,
	next: u32,
	key:  [dynamic; fs.KEYMAX]u8,
}
@(private="file")
cursor: Cursor

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, d: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	dir := Id(d)
	if is_dump(dir) {
		c := dump_readdir(dir, index) or_return
		return p9.Node(c), .Ok
	}
	df := file_of(dir) or_return
	if !fs.is_dir(&df) {
		return 0, .Err_Invalid
	}
	index := index
	if is_branch(dir, "adm") && df.nkey == 9 { // ctl and status first
		if index < 2 {
			return p9.Node(node_of(dir.slot, dir.user, index == 1 ? STATUS_QID : CTL_QID, dir.permissive)), .Ok
		}
		index -= 2 // the entries after them, as the cursor counts them
	}
	t := tree_of(dir)
	pfx: [9]u8
	prefix := fs.key_ent(pfx[:], df.d.qid_path, "")
	resume := index > 0 && cursor.dir == dir && cursor.next == index
	s: fs.Scan
	if resume {
		fs.scan_from(&s, t, prefix, cursor.key[:])
	} else {
		fs.scan_start(&s, t, prefix)
	}
	skip := resume ? 0 : index
	st = .Err_Not_Found
	for kv in fs.scan_next(&vol.fs, &s) {
		if resume && string(kv.key) == string(cursor.key[:]) {
			continue // the last one given
		}
		if skip > 0 {
			skip -= 1
			continue
		}
		if len(kv.val) != fs.DIRSZ {
			st = .Err_Invalid
			break
		}
		child = p9.Node(node_of(dir.slot, dir.user, fs.unpack_dir(kv.val).qid_path, dir.permissive))
		cursor.dir, cursor.next = dir, index + 1
		clear(&cursor.key)
		_ = append(&cursor.key, ..kv.key)
		st = .Ok
		break
	}
	fs.scan_end(&vol.fs, &s)
	if vol.fs.err != .Ok {
		return 0, vol.fs.err
	}
	return child, st
}

@(private="file", require_results)
name_ok :: proc "contextless" (name: string) -> vx.Status {
	return len(name) == 0 || len(name) > fs.NAMEMAX ? .Err_Range : .Ok
}

@(private="file")
fs_create :: proc "contextless" (ctx: rawptr, d: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	dir := Id(d)
	name_ok(name) or_return
	df := file_of(dir) or_return
	isdir := perm & p9.DMDIR != 0
	if isdir && mode.access != .Read {
		return 0, .Err_Access
	}
	mutable(dir) or_return
	if !may(dir, &df.d, {.W}) {
		return 0, .Err_Access
	}
	if is_branch(dir, "adm") && df.nkey == 9 && (name == "ctl" || name == "status") {
		return 0, .Err_Exists
	}
	// Plan 9's: no more of the directory's bits, and in its group.
	bits := isdir ? perm & (df.d.mode & 0o777) : perm & (~u32(0o666) | (df.d.mode & 0o666))
	f := fs.create(&vol, tree_of(dir), &df, name, (isdir ? fs.DMDIR : 0) | (bits & 0o777), uid_of(dir), df.d.gid, now_ns()) or_return
	changed()
	out := node_in(dir, &f)
	if o := open_slot(out, true); o != nil { // create opens it
		o.count += 1
	}
	return p9.Node(out), .Ok
}

@(private="file")
fs_remove :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (st: vx.Status) {
	node := Id(n)
	mutable(node) or_return
	f := file_of(node) or_return
	if fs.is_orphan(&f) {
		return .Err_Not_Found
	}
	if f.nkey == 9 {
		return .Err_Access // the root
	}
	t := tree_of(node)
	d := fs.file_by_qid(&vol, t, fs.kget64(f.key[1:])) or_return
	if !may(node, &d.d, {.W}) {
		return .Err_Access
	}
	name := string(f.key[9:f.nkey])
	if open_slot(node, false) != nil && !fs.is_dir(&f) {
		st = fs.orphan(&vol, t, &d, name, now_ns()) // open still: kept until its last fid goes
	} else {
		st = fs.remove(&vol, t, &d, name, now_ns())
	}
	if st == .Ok {
		changed()
	}
	return
}

// Who may change what (gefs's rules): the size, with write permission; the
// mode, the owner or the group's leader; the owner, adm only; the group, the
// owner to a group they are in, or a leader of both; the times as given,
// the owner; the times to now, the owner or a writer.
@(private="file")
may_setattr :: proc "contextless" (node: Id, d: ^fs.Dir, a: ^p9.Setattr) -> bool {
	me := uid_of(node)
	owner := !is_none(node) && me == d.uid
	if node.permissive {
		return true // %BRANCH: adm's members, without permissions (gefs's permit)
	}
	if .Size in a.valid && !may(node, d, {.W}) {
		return false
	}
	if .Mode in a.valid && !owner && !users.leads(&ut, me, d.gid) {
		return false
	}
	if .Uid in a.valid && a.uid != d.uid && !is_adm(node) {
		return false // owners are adm's to give
	}
	if .Gid in a.valid && a.gid != d.gid && !((owner && users.in_group(&ut, me, a.gid)) || (users.leads(&ut, me, d.gid) && users.leads(&ut, me, a.gid))) {
		return false
	}
	if a.valid & {.Atime_Set, .Mtime_Set} != {} && !owner {
		return false
	}
	if a.valid & {.Atime, .Mtime} != {} && !owner && !may(node, d, {.W}) {
		return false
	}
	return true
}

@(private="file")
fs_setattr :: proc "contextless" (ctx: rawptr, n: p9.Node, a: ^p9.Setattr) -> (st: vx.Status) {
	node := Id(n)
	mutable(node) or_return
	f := file_of(node) or_return
	if !may_setattr(node, &f.d, a) {
		return .Err_Access
	}
	if .Size in a.valid {
		if c := pcache_find(node); c != nil { // what its mappings wrote, in first; then the file as it was, for the rest
			writeback(c)
			f = file_of(node) or_return
		}
	}
	now := now_ns()
	x: fs.Attr
	if .Size in a.valid {
		x.valid += {.Size}
		x.length = a.size
	}
	if .Mode in a.valid {
		x.valid += {.Mode}
		x.mode = a.mode & 0o7777
	}
	if .Uid in a.valid {
		x.valid += {.Uid}
		x.uid = a.uid
	}
	if .Gid in a.valid {
		x.valid += {.Gid}
		x.gid = a.gid
	}
	if .Atime in a.valid {
		x.valid += {.Atime}
		x.atime = .Atime_Set in a.valid ? i64(a.atime_sec * 1_000_000_000 + a.atime_nsec) : now
	}
	if a.valid & {.Mtime, .Size} != {} {
		x.valid += {.Mtime}
		x.mtime = .Mtime_Set in a.valid ? i64(a.mtime_sec * 1_000_000_000 + a.mtime_nsec) : now
	}
	fs.setattr(&vol, tree_of(node), &f, x, now) or_return
	changed()
	if .Size in a.valid {
		pcache_truncated(node, a.size)
	}
	return .Ok
}

// Whether file qid in the slot ctx points at is open (or mapped): a rename
// over it keeps it as an orphan, as POSIX does.
@(private="file")
open_qid :: proc "contextless" (ctx: rawptr, qid: u64) -> bool {
	return open_slot(node_of((^u32)(ctx)^, 0, qid), false) != nil
}

@(private="file")
fs_rename :: proc "contextless" (ctx: rawptr, od: p9.Node, oldname: string, nd: p9.Node, newname: string) -> (st: vx.Status) {
	olddir, newdir := Id(od), Id(nd)
	if olddir.slot != newdir.slot {
		return .Err_Invalid // one branch: one tree
	}
	mutable(olddir) or_return
	name_ok(oldname) or_return
	name_ok(newname) or_return
	a := file_of(olddir) or_return
	b := file_of(newdir) or_return
	if !may(olddir, &a.d, {.W}) || !may(newdir, &b.d, {.W}) {
		return .Err_Access
	}
	slot := olddir.slot
	fs.rename(&vol, tree_of(olddir), &a, oldname, &b, newname, now_ns(), open_qid, &slot) or_return
	changed()
	return .Ok
}

@(private="file")
fs_symlink :: proc "contextless" (ctx: rawptr, d: p9.Node, name, target: string) -> (node: p9.Node, st: vx.Status) {
	dir := Id(d)
	if len(target) == 0 || len(target) >= len(link_target) {
		return 0, .Err_Invalid
	}
	mutable(dir) or_return
	name_ok(name) or_return
	df := file_of(dir) or_return
	if !may(dir, &df.d, {.W}) {
		return 0, .Err_Access
	}
	f := fs.symlink(&vol, tree_of(dir), &df, name, target, uid_of(dir), df.d.gid, now_ns()) or_return
	changed()
	return p9.Node(node_in(dir, &f)), .Ok
}

@(private="file")
link_target: [4097]u8

@(private="file")
fs_readlink :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (target: string, st: vx.Status) {
	node := Id(n)
	f := file_of(node) or_return
	if f.d.mode & fs.DMSYMLINK == 0 {
		return "", .Err_Invalid
	}
	got: u64
	got, st = fs.read(&vol, tree_of(node), &f, 0, link_target[:len(link_target) - 1])
	return string(link_target[:got]), st
}

@(private="file")
fs_fsync :: proc "contextless" (ctx: rawptr, node: p9.Node) -> vx.Status {
	return commit()
}

@(private="file")
next_writeback := vx.INFINITE // while files are mapped

@(private="file")
tick :: proc "contextless" (ctx: rawptr) -> vx.Instant {
	now := rt.clock_read()
	mapped := false
	for &c in pcache {
		if c.used {
			mapped = true
			break
		}
	}
	if mapped && now >= next_writeback {
		writeback_all()
		next_writeback = now + COMMIT_EVERY
	}
	if !mapped {
		next_writeback = now + COMMIT_EVERY
	}
	if dirty && now >= next_commit {
		_ = commit()
	}
	at := dirty ? next_commit : vx.INFINITE
	return mapped && next_writeback < at ? next_writeback : at
}

// Not file-private: tests/host/fsd drives its Fs on the host.
server := p9ring.Server {
	fs = {
		attach_as = fs_attach,
		walk      = fs_walk,
		parent    = fs_parent,
		stat      = fs_stat,
		open      = fs_open,
		read      = fs_read,
		readdir   = fs_readdir,
		write     = fs_write,
		create    = fs_create,
		remove    = fs_remove,
		clunk     = fs_clunk,
		setattr   = fs_setattr,
		rename    = fs_rename,
		symlink   = fs_symlink,
		readlink  = fs_readlink,
		fsync     = fs_fsync,
		map_range = fs_map,
		read_ref  = fs_read_ref,
		write_ref = fs_write_ref,
	},
	name = "fsd",
	supported = {.Posix, .Xattr, .Map, .Dref},
	event = on_event,
	tick = tick,
}

// --- Starting ---

// The disk's connector: the one handle named srv:NAME.
@(private="file")
find_disk :: proc "contextless" () -> vx.Handle {
	for name, i in rt.spawn.handle_names {
		h := rt.spawn.handles[i]
		if len(name) > 4 && str.has_prefix(name, "srv:") && h != vx.HANDLE_NONE {
			disk_name = name[4:]
			rt.spawn.handles[i] = vx.HANDLE_NONE
			return h
		}
	}
	fail("no connector to a disk (connect=)")
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		fail("no listen channel (post=)")
	}
	if st := driver.blk_open(&disk, find_disk(), {}); st != .Ok {
		fail("cannot open a session on the disk", st)
	}
	if .Readonly in disk.flags {
		fail("the disk is read-only")
	}
	if fs.BLKSZ % disk.sector != 0 {
		fail("the disk's sectors do not divide a block")
	}
	dev := fs.Dev {
		ctx     = &disk,
		read    = dev_read,
		write   = dev_write,
		barrier = dev_barrier,
		size    = disk.sectors * u64(disk.sector) / fs.BLKSZ * fs.BLKSZ,
	}
	if st := fs.mount(&vol, dev, {alloc = mem_alloc, free = mem_free}, CACHE_BLOCKS); st != .Ok {
		fail("no volume it can mount", st)
	}
	load_users()
	// The pager, if the manifest makes fsd one (`pager`): Tmap without it is refused.
	if authority := rt.spawn_take("pager"); authority != vx.HANDLE_NONE {
		st: vx.Status
		if server.port, st = rt.port_create(); st != .Ok {
			fail("no port", st)
		}
		if st = pager_start(server.port, authority); st != .Ok {
			fail("cannot be a pager", st)
		}
		_ = rt.handle_close(authority)
	}
	rt.print("fsd: /srv/", disk_name, ": commit ", vol.sb.commit, ", ", u64(len(vol.fs.arenas)), " arenas, ", u64(len(ut.users)), " users\n")
	rt.print("fsd: serving /srv/fsd\n")
	if p9ring.serve(&server) != .Ok {
		rt.exits("cannot serve")
	}
	return 0
}
