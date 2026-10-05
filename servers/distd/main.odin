// distd: the content store and the releases in it, served as /dist
// (upstream's docs/06 §4, §11; its M5 step 9b). The store is files on the
// system volume's store branch, mounted in distd's namespace at /n (its
// manifest's mount=, over bootfs at /): objects as b2/xx/<hex>, release
// records as records/*.ndb.
//
//   service=distd program=/boot/bin/distd post=dist console
//   mount=/ srv=bootfs
//   mount=/n srv=fsd aname=store
//
// It serves:
//
//   /dist/status              state=idle releases=N arch=ARCH
//   /dist/ctl                 (write) rescan: the records read again;
//                             obeyed only for a user who administers
//   /dist/releases/N/record   the release's record, as it is in the store
//   /dist/releases/N/status   state=fetched missing=0 (or state=seen missing=M)
//   /dist/releases/N/tree/    the release's base tree for this architecture,
//                             read-only, every block checked against its
//                             file's index, and the index against its name,
//                             before a byte of it is returned (verified reads)
//   /dist/store/              the objects, read-only, as they are: what peers read
//
// A block that does not match is an IO error, said once on the console with
// the file's path; nothing of it is returned.
//
// On an installed system (upstream's M5 step 9d) it also changes the ESP's
// boot slots (vx:slots), with the ESP (dosfs) at /tmp and fsd's adm branch
// at /adm in its namespace, and the kernel command line (cmdline) saying
// which slot booted (vx.slot=X):
//
//   apply N     release N's tree checked whole; /cfg snapshotted (cfg@apply-N);
//               its kernel, modules and bootfs written to a slot that is not
//               running (slots.target) and read back against their hashes;
//               then the table and Limine's configuration rewritten, each
//               whole, the new slot the default and the running one the
//               previous
//   rollback    the previous slot the default again, and /cfg rolled back to
//               the snapshot taken when the release being left was applied,
//               if that release is the one running
//
// Both take effect at the next boot; status says current= (the release that
// booted) and boot= (the one that will). The running system's base stays
// bootfs's: serving from the store, not switching to it (upstream's 06
// §3.1).
//
// ctl obeys only a user who administers: in group 0 of /adm/users, or adm
// where there is none, as fsd decides (users(6); advisory until keyd,
// upstream's M10).
//
// One request at a time: the buffers below are shared by every callback.
package distd

import vx "abi:vx"
import "vx:crypto"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:p9ring"
import "vx:procns"
import "vx:rt"
import "vx:slots"
import "vx:store"
import "vx:str"
import "vx:users"

when ODIN_ARCH == .amd64 {
	ARCH :: "x86_64"
} else {
	ARCH :: "aarch64"
}

// Not file-private: tests/host mounts its store here.
space: ns.Namespace

fail :: proc "contextless" (what: string, st: vx.Status) -> ! {
	rt.print("distd: FAILED: ", what)
	if st != .Ok {
		rt.print(": ", p9.error_text(st))
	}
	rt.print("\n")
	rt.exits(what)
}

// --- Objects, from the store branch ---

OBJ_MAX :: store.BLOCK + 4096 // a block; an index or directory of a few thousand entries
CACHE :: 24
HASHES_MAX :: 32 * 1024 // the block hashes copied out of an index at once: 1,024 blocks

@(private="file")
Cached :: struct {
	name:  store.Hash,
	last:  u64,
	len:   u32,
	valid: bool, // checked against its name; until then a hit never finds it
	data:  [OBJ_MAX]u8,
}

@(private="file")
cache: [CACHE]Cached
@(private="file")
tick: u64

// An object's bytes, read whole from the store (/n), or why it cannot be.
// What comes back is the store's as it is; its caller checks it against its
// name, and only checked objects are kept (keep). It lasts until the next
// object is read.
@(private="file")
object :: proc "contextless" (name: store.Hash) -> (data: []u8, st: vx.Status) {
	for &c in cache {
		if c.valid && c.name == name {
			tick += 1
			c.last = tick
			return c.data[:c.len], .Ok
		}
	}
	victim := 0
	for &c, i in cache {
		if !c.valid || c.last < cache[victim].last {
			victim = i
		}
	}
	c := &cache[victim]
	rel := store.path(name)
	path_buf: [3 + store.PATH]u8
	path, _ := str.join(path_buf[:], "/n/", string(rel[:]))
	f: ns.File
	ns.open(&space, path, p9.OREAD, &f) or_return
	n := 0
	for n < OBJ_MAX {
		got, _ := ns.read(&f, c.data[n:][:min(OBJ_MAX - n, 65536)])
		if got <= 0 {
			break // an error ends it as the end does: the check refuses what came
		}
		n += got
	}
	ns.close(&f)
	if n == OBJ_MAX {
		return nil, .Err_Range // larger than any object distd reads whole
	}
	tick += 1
	c.valid = false // until it is checked
	c.name, c.len, c.last = name, u32(n), tick
	return c.data[:n], .Ok
}

// The object just read, kept: it was checked against its name.
@(private="file")
keep :: proc "contextless" (name: store.Hash) {
	for &c in cache {
		if !c.valid && c.len > 0 && c.name == name {
			c.valid = true
		}
	}
}

@(private="file")
is_kept :: proc "contextless" (name: store.Hash) -> bool {
	for &c in cache {
		if c.valid && c.name == name {
			return true
		}
	}
	return false
}

@(private="file")
said_bad :: proc "contextless" (what, path: string) {
	rt.print("distd: ", what, " does not match its hash: ", path, " (refused)\n")
}

// A directory object, checked.
@(private="file")
dir_object :: proc "contextless" (name: store.Hash) -> (text: []u8, st: vx.Status) {
	kept := is_kept(name)
	text = object(name) or_return
	if kept {
		return text, .Ok
	}
	if store.dir_check(name, text) != .Ok {
		return nil, .Err_Io
	}
	keep(name)
	return text, .Ok
}

// --- Releases ---

RELEASES :: 16
RECORD_MAX :: 16384

@(private="file")
Release :: struct {
	seq:    u64,
	tree:   store.Hash, // this architecture's base tree
	record: [dynamic; RECORD_MAX]u8,
}

@(private="file")
releases: [dynamic; RELEASES]Release

@(private="file")
record_scratch: [RECORD_MAX]u8

// The records in /n/records, read again: each that names a base tree for
// this architecture is a release.
rescan :: proc "contextless" () {
	clear(&releases)
	dir: ns.File
	if ns.open(&space, "/n/records", p9.OREAD, &dir) != .Ok {
		return
	}
	@(static) listing: [8192]u8
	for {
		n, _ := ns.read(&dir, listing[:])
		if n <= 0 {
			break
		}
		it := p9.Dir_Entries{buf = listing[:n]}
		for e in p9.next_entry(&it) {
			if len(releases) == RELEASES {
				break
			}
			if len(e.name) < 5 || !str.has_suffix(e.name, ".ndb") || e.length > RECORD_MAX {
				continue
			}
			path_buf: [96]u8
			if len(e.name) > len(path_buf) - 12 {
				continue
			}
			path, _ := str.join(path_buf[:], "/n/records/", e.name)
			f: ns.File
			if ns.open(&space, path, p9.OREAD, &f) != .Ok {
				continue
			}
			// Read in place, in the next slot (never a Release on the stack:
			// LLVM's SROA takes minutes over a local of 16 KiB of bytes).
			resize(&releases, len(releases) + 1) // room: checked above
			r := &releases[len(releases) - 1]
			r^ = {}
			resize(&r.record, RECORD_MAX)
			got, _ := ns.read_all(&f, r.record[:])
			resize(&r.record, got)
			ns.close(&f)
			// release=N ...; set=base arch=ARCH tree=b2:...
			rd := ndb.Reader{src = string(r.record[:]), scratch = record_scratch[:]}
			rec: ndb.Record
			have_seq, have_tree, known := false, false, true
			for ndb.next(&rd, &rec) == .Record {
				rd.scratch_used = 0
				known = known && store.release_known(&rec) // a key release(6) does not name: not a release
				if ndb.has(&rec, "release") {
					r.seq, have_seq = ndb.get_u64(&rec, "release")
				}
				set, _ := ndb.get(&rec, "set")
				arch, _ := ndb.get(&rec, "arch")
				if set == "base" && arch == ARCH {
					tree, _ := ndb.get(&rec, "tree")
					r.tree, have_tree = store.parse(tree)
				}
			}
			if !have_seq || !have_tree || !known {
				resize(&releases, len(releases) - 1)
			}
		}
	}
	ns.close(&dir)
}

@(private="file")
release_of :: proc "contextless" (seq: u64) -> ^Release {
	for &r in releases {
		if r.seq == seq {
			return &r
		}
	}
	return nil
}

// --- Nodes ---
//
// /dist's files, the releases' directories, and every tree entry and store
// object a walk or a listing reaches, each a slot here, found again by its
// parent and name. Never let go: a long-running distd fills it (a known gap
// upstream too).

Kind :: enum u8 {
	None,
	Root,
	Status,
	Ctl,
	Releases,
	Release,
	Record,
	Release_Status,
	Tree, // an entry of a release's tree (or the tree's root)
	Store, // /dist/store and its directories
	Object, // an object under it
}

NAME_MAX :: 255
STORE_PATH_MAX :: 79

Node :: struct {
	kind:   Kind,
	parent: u32,
	seq:    u64, // its release's
	e:      store.Entry, // a tree entry's, without its strings, which are below
	name:   [dynamic; NAME_MAX]u8, // a tree entry's, or a store path component
	target: [dynamic; NAME_MAX]u8, // a link's
	path:   [dynamic; STORE_PATH_MAX]u8, // a store directory's or object's path under /store ("b2/9f")
}

MAX_NODES :: 8192

@(private="file")
nodes: [dynamic; MAX_NODES]Node // 0 is no node

// The node with this kind, parent, release, name and store path, found, or
// made in place (a Node is never a local: LLVM's SROA takes minutes over
// one); made says which. 0 if the table is full, or name or path too long.
@(private="file")
add_node :: proc "contextless" (kind: Kind, parent: u32, seq: u64, name: string, path := "") -> (id: u32, made: bool) {
	for i in 1 ..< len(nodes) {
		x := &nodes[i]
		if x.kind == kind && x.parent == parent && x.seq == seq && string(x.name[:]) == name && string(x.path[:]) == path {
			return u32(i), false
		}
	}
	if len(name) > NAME_MAX || len(path) > STORE_PATH_MAX || len(nodes) == MAX_NODES {
		return 0, false
	}
	resize(&nodes, len(nodes) + 1)
	n := &nodes[len(nodes) - 1]
	n^ = {}
	n.kind, n.parent, n.seq = kind, parent, seq
	_ = append(&n.name, name)
	_ = append(&n.path, path)
	return u32(len(nodes) - 1), true
}

// A node id as distd hands it to the framework: the node's slot in nodes,
// and whether the fid's attach was by an administrator (users(6): group 0),
// whom alone ctl obeys; walks, parents and listings keep it. The qid's path
// is the slot alone.
@(private="file")
Id :: bit_field u64 {
	node: u64  | 63,
	adm:  bool | 1,
}
#assert(size_of(Id) == 8)

@(private="file")
id_of :: proc "contextless" (n: p9.Node) -> Id {
	return transmute(Id)u64(n)
}

// A node's slot as a p9.Node, carrying like's adm.
@(private="file")
as_node :: proc "contextless" (index: u32, like: p9.Node) -> p9.Node {
	return p9.Node(transmute(u64)Id{node = u64(index), adm = id_of(like).adm})
}

// A node id's slot in nodes.
@(private="file")
slot_of :: proc "contextless" (n: p9.Node) -> u32 {
	return u32(id_of(n).node)
}

@(private="file")
node_of :: proc "contextless" (id: p9.Node) -> ^Node {
	i := id_of(id).node
	return i > 0 && i < u64(len(nodes)) ? &nodes[i] : nil
}

@(private="file")
fixed :: proc "contextless" (kind: Kind, parent: u32, seq: u64, name: string) -> u32 {
	id, _ := add_node(kind, parent, seq, name)
	return id
}

// A tree entry as a node under parent; 0 if its name or link is too long.
@(private="file")
tree_node :: proc "contextless" (parent: u32, seq: u64, e: store.Entry) -> u32 {
	if len(e.name) > NAME_MAX || len(e.link) > NAME_MAX {
		return 0
	}
	id, made := add_node(.Tree, parent, seq, e.name)
	if made {
		n := &nodes[id]
		n.e = e
		_ = append(&n.target, e.link)
		n.e.name, n.e.link = "", "" // they pointed into a scratch buffer
	}
	return id
}

@(private="file")
is_dir :: proc "contextless" (n: ^Node) -> bool {
	#partial switch n.kind {
	case .Tree:
		return store.is_dir(n.e)
	case .Root, .Releases, .Release, .Store:
		return true
	}
	return false
}

// The path of a tree node, for what distd says ("/bin/ls": from the tree).
@(private="file")
tree_path :: proc "contextless" (id: u32, out: []u8) -> string {
	chain: [dynamic; 64]u32
	for i := id; i != 0 && nodes[i].kind == .Tree && len(chain) < cap(chain); i = nodes[i].parent {
		_ = append(&chain, i)
	}
	b := str.Buf{buf = out}
	for d := len(chain) - 1; d >= 0; d -= 1 {
		nm := string(nodes[chain[d]].name[:])
		if d == len(chain) - 1 && nm == "" {
			continue // the tree's root
		}
		str.write_byte(&b, '/')
		str.write_string(&b, nm)
	}
	return str.to_string(&b)
}

// --- 9Px ---

@(private="file")
root_id, status_id, ctl_id, releases_id, store_id: u32

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname, uname: string) -> (root: p9.Node, st: vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return p9.Node(transmute(u64)Id{node = u64(root_id), adm = administers(uname)}), .Ok
}

// A release's number as a directory names it: decimal, no leading zero.
@(private="file")
seq_of :: proc "contextless" (name: string) -> (seq: u64, ok: bool) {
	if len(name) == 0 || len(name) >= 20 || (name[0] == '0' && len(name) > 1) {
		return 0, false
	}
	for c in transmute([]u8)name {
		if c < '0' || c > '9' {
			return 0, false
		}
		seq = seq * 10 + u64(c - '0')
	}
	return seq, true
}

@(private="file")
dir_scratch: [16384]u8

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	d := node_of(dir)
	if d == nil || !is_dir(d) || len(name) > NAME_MAX {
		return 0, .Err_Not_Found
	}
	id: u32
	#partial switch d.kind {
	case .Root:
		switch name {
		case "status":
			id = status_id
		case "ctl":
			id = ctl_id
		case "releases":
			id = releases_id
		case "store":
			id = store_id
		}
	case .Releases:
		if seq, ok := seq_of(name); ok && release_of(seq) != nil {
			id = fixed(.Release, slot_of(dir), seq, name)
		}
	case .Release:
		switch name {
		case "record":
			id = fixed(.Record, slot_of(dir), d.seq, name)
		case "status":
			id = fixed(.Release_Status, slot_of(dir), d.seq, name)
		case "tree":
			if r := release_of(d.seq); r != nil {
				made: bool
				if id, made = add_node(.Tree, slot_of(dir), d.seq, ""); made {
					nodes[id].e = {mode = 0o040555, hash = r.tree}
				}
			}
		}
	case .Tree:
		text := dir_object(d.e.hash) or_return
		e, fst := store.dir_find(text, name, dir_scratch[:])
		if fst != .Ok {
			return 0, fst == .Err_Invalid ? .Err_Io : fst
		}
		id = tree_node(slot_of(dir), d.seq, e)
	case .Store:
		// b2, then two hex digits, then the object's 64: as the store has them.
		plen := len(d.path)
		if plen + 1 + len(name) >= STORE_PATH_MAX + 1 {
			return 0, .Err_Not_Found
		}
		full_buf: [3 + STORE_PATH_MAX]u8
		full, _ := str.join(full_buf[:], "/n/", string(d.path[:]), plen > 0 ? "/" : "", name)
		path := full[len("/n/"):]
		kind := Kind.Store
		if len(path) - len(name) == 6 { // under "b2/xx/"
			kind = .Object
		}
		c, fid := ns.walk(&space, full) or_return
		_ = p9.client_clunk(c, fid)
		id, _ = add_node(kind, slot_of(dir), 0, name, path)
	}
	if id == 0 {
		return 0, .Err_Not_Found
	}
	return as_node(id, dir), .Ok
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, id: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	n := node_of(id)
	if n == nil {
		return 0, .Err_Not_Found
	}
	return as_node(n.parent != 0 ? n.parent : root_id, id), .Ok
}

// A tree file's index, checked against its name, and against the size its
// directory gives.
@(private="file")
index_of :: proc "contextless" (e: store.Entry) -> (x: store.Index, st: vx.Status) {
	kept := is_kept(e.hash)
	obj := object(e.hash) or_return
	cst: vx.Status
	if x, cst = store.index_check(e.hash, obj); cst != .Ok {
		return {}, .Err_Io
	}
	if !kept {
		keep(e.hash)
	}
	return x, x.size == e.size ? .Ok : .Err_Io
}

// The index may move in the cache as blocks come in: its hashes are copied
// out here first.
@(private="file")
hashes_copy: [HASHES_MAX]u8

// Block b of a file whose index's hashes are in hashes_copy: read, and
// checked against it.
@(private="file")
checked_block :: proc "contextless" (x: store.Index, b: u64) -> (data: []u8, st: vx.Status) {
	h: store.Hash
	copy(h[:], x.hashes[b * store.HASH:][:store.HASH])
	data = object(h) or_return
	if store.block_check(x, b, data) != .Ok {
		return nil, .Err_Io
	}
	return data, .Ok
}

// --- Slots (upstream's M5 step 9d) ---

@(private="file")
booted: u8 // vx.slot's letter, or 0

@(private="file")
find_booted :: proc "contextless" () {
	c := rt.spawn.cmdline
	for i := 0; i + 9 <= len(c); i += 1 {
		if (i == 0 || c[i - 1] == ' ') && c[i:][:8] == "vx.slot=" {
			booted = c[i + 8]
		}
	}
}

// All of data written at f's offset, however little each write moves (a
// 9P write moves at most the connection's message size).
@(private="file")
write_all :: proc "contextless" (f: ^ns.File, data: []u8) -> vx.Status {
	for at := 0; at < len(data); {
		w := ns.write(f, data[at:][:min(len(data) - at, 65536)]) or_return
		if w <= 0 {
			return .Err_Io
		}
		at += w
	}
	return .Ok
}

// path read whole into buf: .Err_Range if it fills it.
@(private="file")
read_whole :: proc "contextless" (path: string, buf: []u8) -> (text: []u8, st: vx.Status) {
	f: ns.File
	ns.open(&space, path, p9.OREAD, &f) or_return
	n := 0
	for n < len(buf) {
		got, rst := ns.read(&f, buf[n:])
		if rst != .Ok {
			ns.close(&f)
			return nil, rst
		}
		if got == 0 {
			break
		}
		n += got
	}
	ns.close(&f)
	return buf[:n], n == len(buf) ? .Err_Range : .Ok
}

// path written whole with data (made, or cut to nothing first).
@(private="file")
write_whole :: proc "contextless" (path: string, data: []u8) -> vx.Status {
	f: ns.File
	st := ns.open(&space, path, {access = .Write, trunc = true}, &f)
	if st == .Err_Not_Found {
		st = ns.create(&space, path, 0o644, p9.OWRITE, &f)
	}
	if st != .Ok {
		return st
	}
	st = write_all(&f, data)
	ns.close(&f)
	return st
}

SLOT_TABLE :: "/tmp/EFI/vectra/slots.ndb"

// dir/name replaced by data: written whole as dir/name.new, then renamed
// over it (Trenameat), so a crash leaves the old file or the new, not one
// half written; FAT's rename is itself two steps, a small window (upstream's
// BUGS).
@(private="file")
replace_whole :: proc "contextless" (dir, name: string, data: []u8) -> vx.Status {
	tmp_buf: [96]u8
	fresh_buf: [48]u8
	fresh, _ := str.join(fresh_buf[:], name, ".new")
	tmp, _ := str.join(tmp_buf[:], dir, "/", fresh)
	write_whole(tmp, data) or_return
	c, fid := ns.walk(&space, dir) or_return
	st := p9.client_renameat(c, fid, fresh, fid, name)
	_ = p9.client_clunk(c, fid)
	return st
}

@(private="file")
table_text: [4096]u8
@(private="file")
table_scratch: [4096]u8

@(private="file")
load_table :: proc "contextless" (t: ^slots.Table) -> vx.Status {
	text := read_whole(SLOT_TABLE, table_text[:]) or_return
	return slots.parse(t, string(text), table_scratch[:])
}

// The table, then Limine's configuration made from it: in that order, so a
// configuration never names a slot the table does not.
@(private="file")
save_table :: proc "contextless" (t: ^slots.Table) -> vx.Status {
	@(static) text: [4096]u8
	@(static) conf: [4096]u8
	w := ndb.Writer{buf = text[:]}
	if !slots.print(t, &w) {
		return .Err_Range
	}
	c, ok := slots.limine(t, conf[:])
	if !ok {
		return .Err_Range
	}
	replace_whole("/tmp/EFI/vectra", "slots.ndb", transmute([]u8)ndb.written(&w)) or_return
	return replace_whole("/tmp/boot/limine", "limine.conf", transmute([]u8)c)
}

// The slot that booted, from vx.slot; nil if the system did not boot from one.
@(private="file")
booted_slot :: proc "contextless" () -> Maybe(slots.Name) {
	if booted >= 'a' && booted < 'a' + len(slots.Name) {
		return slots.Name(booted - 'a')
	}
	return nil
}

// A whole tree checked: every directory, index and block, present and
// sound. Directories wait in a queue; each one's text is copied before its
// entries are checked, since checking them moves the cache.
@(private="file")
check_tree :: proc "contextless" (top: store.Hash) -> vx.Status {
	@(static) queue: [dynamic; 4096]store.Hash
	@(static) text: [OBJ_MAX]u8
	@(static) scratch: [16384]u8
	clear(&queue)
	_ = append(&queue, top)
	for head := 0; head < len(queue); head += 1 {
		t := dir_object(queue[head]) or_return
		n := copy(text[:], t)
		r := ndb.Reader{src = string(text[:n]), scratch = scratch[:]}
		rec: ndb.Record
		for ndb.next(&r, &rec) == .Record {
			r.scratch_used = 0
			e, est := store.dir_entry(&rec)
			if est != .Ok {
				return .Err_Io
			}
			if store.is_link(e) {
				continue
			}
			if store.is_dir(e) {
				if append(&queue, e.hash) == 0 {
					return .Err_Range
				}
				continue
			}
			x := index_of(e) or_return
			nb := store.index_blocks(x)
			if nb * store.HASH > HASHES_MAX {
				return .Err_Range
			}
			copy(hashes_copy[:], x.hashes)
			x.hashes = hashes_copy[:nb * store.HASH]
			for b in 0 ..< nb {
				_ = checked_block(x, b) or_return
			}
		}
	}
	return .Ok
}

// A file of a tree, by path, copied to the ESP at to, verified as it is
// read; its BLAKE2b-512 into hash, as hex, once the ESP's copy is read back
// and found the same.
@(private="file")
copy_to_slot :: proc "contextless" (tree: store.Hash, path: string, to: string, hash: ^[dynamic; slots.HASH_HEX]u8) -> vx.Status {
	e := store.Entry{mode = 0o040555, hash = tree}
	rest := path
	for name in str.split_iterator(&rest, '/') {
		t := dir_object(e.hash) or_return
		e = store.dir_find(t, name, dir_scratch[:]) or_return
	}
	x := index_of(e) or_return
	nb := store.index_blocks(x)
	if nb * store.HASH > HASHES_MAX {
		return .Err_Range
	}
	copy(hashes_copy[:], x.hashes)
	x.hashes = hashes_copy[:nb * store.HASH]
	f: ns.File
	st := ns.open(&space, to, {access = .Write, trunc = true}, &f)
	if st == .Err_Not_Found {
		st = ns.create(&space, to, 0o644, p9.OWRITE, &f)
	}
	if st != .Ok {
		return st
	}
	hc: crypto.Blake2b
	crypto.blake2b_begin(&hc, 64)
	for b in 0 ..< nb {
		data: []u8
		if data, st = checked_block(x, b); st != .Ok {
			break
		}
		crypto.blake2b_add(&hc, data)
		if len(data) > 0 {
			if st = write_all(&f, data); st != .Ok {
				break
			}
		}
	}
	ns.close(&f)
	if st != .Ok {
		return st
	}
	h, back: [64]u8
	crypto.blake2b_end(&hc, h[:])
	// Read back: what the ESP holds is what Limine will check.
	ns.open(&space, to, p9.OREAD, &f) or_return
	crypto.blake2b_begin(&hc, 64)
	@(static) buf: [65536]u8
	rst: vx.Status
	for {
		got: int
		got, rst = ns.read(&f, buf[:])
		if rst != .Ok || got == 0 {
			break
		}
		crypto.blake2b_add(&hc, buf[:got])
	}
	ns.close(&f)
	crypto.blake2b_end(&hc, back[:])
	if rst != .Ok || h != back {
		return .Err_Io
	}
	clear(hash)
	for v in h {
		_ = append(hash, DIGITS[v >> 4], DIGITS[v & 15])
	}
	return .Ok
}

@(private="file")
DIGITS := "0123456789abcdef"

@(private="file")
adm_ctl :: proc "contextless" (cmd: string) -> vx.Status {
	return write_whole("/adm/ctl", transmute([]u8)cmd)
}

@(private="file")
adm_users, adm_next: users.Table
@(private="file")
users_text: [64 * 1024]u8

// Whether uname administers, by /adm/users as it is now, or users(6)'s
// default (adm alone) where there is none, as fsd has it.
@(private="file")
administers :: proc "contextless" (uname: string) -> bool {
	text, st := read_whole("/adm/users", users_text[:])
	if st != .Ok || !users.parse(&adm_users, string(text), &adm_next) {
		_ = users.parse(&adm_users, users.DEFAULT, &adm_next)
	}
	return users.adm(&adm_users, uname)
}

// A step of apply or rollback that failed, said: the step and the error.
@(private="file")
refused :: proc "contextless" (what: string, st: vx.Status) -> vx.Status {
	rt.print("distd: ", what, ": ", p9.error_text(st), "\n")
	return st
}

@(private="file")
apply :: proc "contextless" (seq: u64) -> vx.Status {
	r := release_of(seq)
	if r == nil {
		return refused("apply: no such release", .Err_Not_Found)
	}
	if st := check_tree(r.tree); st != .Ok {
		rt.print("distd: release ", seq, " is not whole and sound in the store (", p9.error_text(st), "): not applied\n")
		return st
	}
	@(static) t: slots.Table
	if st := load_table(&t); st != .Ok {
		return refused("apply: cannot read the slot table", st)
	}
	now, from_slot := booted_slot().?
	if !from_slot {
		return refused("apply: the system did not boot from a slot", .Err_Bad_State)
	}
	slot, has := slots.target(&t, now)
	if !has {
		return refused("apply: no slot to write", .Err_No_Space)
	}
	num_buf: [str.U64_DIGITS]u8
	num := str.format_u64(num_buf[:], seq)
	cmd_buf: [96]u8
	cmd, _ := str.join(cmd_buf[:], "del cfg@apply-", num)
	_ = adm_ctl(cmd) // a snapshot from an earlier apply of it, if any
	cmd, _ = str.join(cmd_buf[:], "snap cfg cfg@apply-", num)
	if st := adm_ctl(cmd); st != .Ok {
		return refused("apply: cannot snapshot /cfg", st)
	}
	letter := [1]u8{slots.letter(slot)}
	dir_buf: [40]u8
	dir, _ := str.join(dir_buf[:], "/tmp/EFI/vectra/", string(letter[:]))
	f: ns.File
	if ns.create(&space, dir, p9.DMDIR | 0o755, p9.OREAD, &f) == .Ok {
		ns.close(&f)
	}
	sl := &t.slots[slot]
	for name, i in slots.FILE_NAMES {
		from_buf, to_buf: [64]u8
		from, _ := str.join(from_buf[:], "boot/vx/", name)
		to, _ := str.join(to_buf[:], dir, "/", name)
		if st := copy_to_slot(r.tree, from, to, &sl.hash[i]); st != .Ok {
			return refused("apply: cannot write the slot", st)
		}
	}
	sl.used, sl.release = true, seq
	x := store.hex(r.tree)
	clear(&sl.tree)
	_ = append(&sl.tree, string(x[:]))
	t.previous, t.boot = now, slot // the running release is what a rollback returns to
	if st := save_table(&t); st != .Ok {
		return refused("apply: cannot write the slot table", st)
	}
	rt.print("distd: release ", seq, " staged: the next boot is its slot's\n")
	return .Ok
}

@(private="file")
rollback :: proc "contextless" () -> vx.Status {
	@(static) t: slots.Table
	if st := load_table(&t); st != .Ok {
		return refused("rollback: cannot read the slot table", st)
	}
	prev, has := t.previous.?
	if !has {
		return refused("rollback: no previous slot", .Err_Not_Found)
	}
	b := t.boot.? or_else prev // load_table makes sure a slot boots
	leaving := t.slots[b].release
	running, from_slot := booted_slot().?
	ran := from_slot && b == running // a staged release that never booted changed no /cfg
	t.boot, t.previous = prev, b
	if st := save_table(&t); st != .Ok {
		return refused("rollback: cannot write the slot table", st)
	}
	num_buf: [str.U64_DIGITS]u8
	cmd_buf: [96]u8
	cmd, _ := str.join(cmd_buf[:], "rollback cfg cfg@apply-", str.format_u64(num_buf[:], leaving))
	if ran && adm_ctl(cmd) != .Ok {
		rt.print("distd: no snapshot of /cfg to roll back to\n")
	}
	rt.print("distd: rolled back: the next boot is release ", t.slots[prev].release, "'s slot\n")
	return .Ok
}

// Status files, made when read.
@(private="file")
status_buf: [16384]u8

@(private="file")
status_text :: proc "contextless" (n: ^Node) -> string {
	w := ndb.Writer{buf = status_buf[:]}
	if n.kind == .Status {
		ndb.put(&w, "state", "idle")
		ndb.put_u64(&w, "releases", u64(len(releases)))
		ndb.put(&w, "arch", ARCH)
		@(static) t: slots.Table
		if booted != 0 && load_table(&t) == .Ok { // an installed system: which release booted, which will
			if booted >= 'a' && booted < 'a' + len(slots.Name) && t.slots[slots.Name(booted - 'a')].used {
				ndb.put_u64(&w, "current", t.slots[slots.Name(booted - 'a')].release)
			}
			l := [1]u8{booted}
			ndb.put(&w, "slot", string(l[:]))
			if b, ok := t.boot.?; ok {
				ndb.put_u64(&w, "boot", t.slots[b].release)
			}
		}
		_ = ndb.end(&w)
	} else { // a release's: is every object of its tree here?
		// Only the root directory's object is looked for: presence, not
		// soundness (reads check that).
		missing: u64
		r := release_of(n.seq)
		if r == nil {
			missing += 1
		} else if _, st := dir_object(r.tree); st != .Ok {
			missing += 1
		}
		ndb.put(&w, "state", missing > 0 ? "seen" : "fetched")
		ndb.put_u64(&w, "missing", missing)
		_ = ndb.end(&w)
	}
	return w.failed ? "" : ndb.written(&w)
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, id: p9.Node, out: ^p9.Stat) -> vx.Status {
	n := node_of(id)
	if n == nil {
		return .Err_Not_Found
	}
	dir := is_dir(n)
	mode := dir ? p9.DMDIR | 0o555 : 0o444
	length: u64
	name := string(n.name[:])
	#partial switch n.kind {
	case .Root:
		name = "/"
	case .Ctl:
		mode = 0o220
	case .Record:
		if r := release_of(n.seq); r != nil {
			length = u64(len(r.record))
		}
	case .Tree:
		if store.is_link(n.e) {
			mode = p9.DMSYMLINK | 0o777
		} else if !dir {
			mode, length = n.e.mode & 0o777, n.e.size
		}
		if name == "" {
			name = "tree"
		}
	}
	out^ = {
		qid    = {type = dir ? p9.QTDIR : p9.QTFILE, path = id_of(id).node},
		mode   = mode,
		length = length,
		name   = name,
		uid    = "dist",
		gid    = "dist",
		muid   = "dist",
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, id: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	n := node_of(id)
	if n == nil {
		return .Err_Not_Found
	}
	if n.kind == .Ctl {
		return mode.access == .Write ? .Ok : .Err_Access
	}
	return mode.access == .Read && !mode.trunc && !mode.rclose ? .Ok : .Err_Access
}

// src's bytes from offset, as many as buf takes.
@(private="file")
give :: proc "contextless" (src: []u8, offset: u64, buf: []u8) -> u32 {
	if offset >= u64(len(src)) {
		return 0
	}
	return u32(copy(buf, src[offset:]))
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, id: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	n := node_of(id)
	if n == nil {
		return 0, .Err_Not_Found
	}
	if is_dir(n) {
		return 0, .Err_Invalid
	}
	#partial switch n.kind {
	case .Status, .Release_Status:
		return give(transmute([]u8)status_text(n), offset, buf), .Ok
	case .Record:
		r := release_of(n.seq)
		if r == nil {
			return 0, .Err_Not_Found
		}
		return give(r.record[:], offset, buf), .Ok
	case .Object: // as the store has it: peers check it themselves
		full_buf: [3 + STORE_PATH_MAX]u8
		full, _ := str.join(full_buf[:], "/n/", string(n.path[:]))
		f: ns.File
		ns.open(&space, full, p9.OREAD, &f) or_return
		f.offset = offset
		got, rst := ns.read(&f, buf)
		ns.close(&f)
		return u32(got), rst
	case .Tree:
		if store.is_link(n.e) {
			return 0, .Err_Invalid
		}
	case:
		return 0, .Err_Invalid
	}
	// A verified read: the index, then each block the range touches.
	where_buf: [512]u8
	x, ist := index_of(n.e)
	if ist != .Ok {
		said_bad("a file's index", tree_path(slot_of(id), where_buf[:]))
		return 0, ist
	}
	if offset >= x.size {
		return 0, .Ok
	}
	last := min(x.size, offset + u64(len(buf))) // offset < x.size <= 2^48: no wrap
	first, lastb := offset / store.BLOCK, (last - 1) / store.BLOCK
	if (lastb - first + 1) * store.HASH > HASHES_MAX {
		return 0, .Err_Range
	}
	nblocks := store.index_blocks(x)
	copy(hashes_copy[:], x.hashes[first * store.HASH:][:(lastb - first + 1) * store.HASH])
	done: u32
	for b in first ..= lastb {
		bh: store.Hash
		copy(bh[:], hashes_copy[(b - first) * store.HASH:][:store.HASH])
		kept := is_kept(bh)
		data := object(bh) or_return
		if !kept {
			want := b + 1 < nblocks ? store.BLOCK : x.size - b * store.BLOCK
			if u64(len(data)) != want || store.leaf(data) != bh {
				said_bad("a block", tree_path(slot_of(id), where_buf[:]))
				return 0, .Err_Io
			}
			keep(bh)
		}
		from := b == first ? offset % store.BLOCK : 0
		to := b == lastb ? (last - 1) % store.BLOCK + 1 : u64(len(data))
		done += u32(copy(buf[done:], data[from:to]))
	}
	return done, .Ok
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, id: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	n := node_of(id)
	if n == nil || n.kind != .Ctl || !id_of(id).adm {
		return 0, .Err_Access // adm's alone
	}
	cmd := string(data)
	for len(cmd) > 0 && (cmd[len(cmd) - 1] == '\n' || cmd[len(cmd) - 1] == ' ') {
		cmd = cmd[:len(cmd) - 1]
	}
	count = u32(len(data))
	switch {
	case cmd == "rescan":
		rescan()
		return count, .Ok
	case cmd == "rollback":
		return count, rollback()
	case len(cmd) > 6 && str.has_prefix(cmd, "apply "):
		seq: u64
		for c in transmute([]u8)cmd[6:] {
			if c < '0' || c > '9' {
				return 0, .Err_Invalid
			}
			seq = seq * 10 + u64(c - '0') // wraps past 2^64, as upstream's does
		}
		return count, apply(seq)
	}
	return 0, .Err_Invalid // fetch and the rest: with upstream's M10 sources
}

@(private="file")
fs_readlink :: proc "contextless" (ctx: rawptr, id: p9.Node) -> (target: string, st: vx.Status) {
	n := node_of(id)
	if n == nil || n.kind != .Tree || !store.is_link(n.e) {
		return "", .Err_Invalid
	}
	return string(n.target[:]), .Ok
}

// A listing, index by index.
@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	d := node_of(dir)
	if d == nil || !is_dir(d) {
		return 0, .Err_Invalid
	}
	id: u32
	#partial switch d.kind {
	case .Root:
		list := [4]u32{status_id, ctl_id, releases_id, store_id}
		if index >= len(list) {
			return 0, .Err_Not_Found
		}
		id = list[index]
	case .Releases:
		if int(index) >= len(releases) {
			return 0, .Err_Not_Found
		}
		seq := releases[index].seq
		num_buf: [str.U64_DIGITS]u8
		id = fixed(.Release, slot_of(dir), seq, str.format_u64(num_buf[:], seq))
	case .Release:
		names := [3]string{"record", "status", "tree"}
		if index >= len(names) {
			return 0, .Err_Not_Found
		}
		return fs_walk(ctx, dir, names[index])
	case .Tree:
		text := dir_object(d.e.hash) or_return
		r := ndb.Reader{src = string(text), scratch = dir_scratch[:]}
		rec: ndb.Record
		for i: u32 = 0; ; i += 1 {
			r.scratch_used = 0
			if ndb.next(&r, &rec) != .Record {
				return 0, .Err_Not_Found
			}
			if i < index {
				continue
			}
			e, est := store.dir_entry(&rec)
			if est != .Ok {
				return 0, .Err_Io
			}
			id = tree_node(slot_of(dir), d.seq, e)
			break
		}
	case .Store: // as the store branch lists it
		full_buf: [3 + STORE_PATH_MAX]u8
		full, _ := str.join(full_buf[:], len(d.path) > 0 ? "/n/" : "/n", string(d.path[:]))
		f: ns.File
		ns.open(&space, full, p9.OREAD, &f) or_return
		@(static) listing: [8192]u8
		i: u32
		for {
			n, _ := ns.read(&f, listing[:])
			if n <= 0 {
				break
			}
			it := p9.Dir_Entries{buf = listing[:n]}
			for e in p9.next_entry(&it) {
				shown := len(d.path) > 0 || e.name == "b2" // the objects, not records/
				if !shown {
					continue
				}
				if i < index {
					i += 1
					continue
				}
				// e.name points into listing, which the walk does not touch.
				ns.close(&f)
				child, st = fs_walk(ctx, dir, e.name)
				return child, st == .Ok ? .Ok : .Err_Io
			}
		}
		ns.close(&f)
		return 0, .Err_Not_Found
	}
	if id == 0 {
		return 0, .Err_No_Memory
	}
	return as_node(id, dir), .Ok
}

// Not file-private: tests/host drives its Fs on the host.
server := p9ring.Server {
	fs = {attach_as = fs_attach, walk = fs_walk, parent = fs_parent, stat = fs_stat, open = fs_open, read = fs_read, write = fs_write, readdir = fs_readdir, readlink = fs_readlink},
	name = "distd",
	supported = {.Posix, .Xattr}, // Treadlink; Tgetattr, for stat
}

// /dist's fixed nodes, the records read, and the slot the system booted
// from; what distd says it serves. Not file-private: tests/host starts
// distd here, with its own namespace.
start :: proc "contextless" () {
	resize(&nodes, 1) // 0 is no node
	nodes[0] = {}
	root_id = fixed(.Root, 0, 0, "")
	status_id = fixed(.Status, root_id, 0, "status")
	ctl_id = fixed(.Ctl, root_id, 0, "ctl")
	releases_id = fixed(.Releases, root_id, 0, "releases")
	store_id = fixed(.Store, root_id, 0, "store")
	rescan()
	find_booted()
	rt.print("distd: ", u64(len(releases)), " releases for ", ARCH, "; serving /srv/dist\n")
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		fail("no listen channel (post=)", .Ok)
	}
	if st := procns.from_spawn(&space); st != .Ok {
		fail("no namespace", st)
	}
	start()
	if p9ring.serve(&server) != .Ok {
		rt.exits("cannot serve")
	}
	rt.exits("")
}
