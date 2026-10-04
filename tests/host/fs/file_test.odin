// Upstream's vxfs_file_test.c: lib/fs's file layer against a model. Random
// directories, files and symbolic links are made, written (small, so inline,
// and large, in blocks, sparse, across the boundary between the two),
// truncated, renamed (a directory into itself refused, a target replaced) and
// removed. After every few operations every file's contents and every
// directory's listing agree with the model, the checker finds no leak (data
// cleared as files go), and now and then the volume is committed, mounted
// again and compared once more. And what each run leaves on its device is
// what upstream's leaves.
package fs_test

import "core:fmt"
import "core:log"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:fs"

// --- The model ---

MAXN :: 96
MAXLEN :: 100_000

Node :: struct {
	used:   bool,
	dir:    bool,
	link:   bool,
	parent: int,
	name:   [16]u8,
	nname:  int,
	data:   [dynamic]u8,
}

node_name :: proc(n: ^Node) -> string {
	return string(n.name[:n.nname])
}

File_World :: struct {
	d:     ^Memdev,
	v:     ^fs.Vol,
	br:    ^fs.Branch,
	now:   i64,
	rng:   Rng,
	nodes: [MAXN]Node, // 0 is the root
	buf:   []u8, // reads, MAXLEN + 10
	data:  []u8, // writes, MAXLEN
}

// Recursive as deep as the model, a few levels.
path_of :: proc(w: ^File_World, i: int, b: ^strings.Builder) {
	if i == 0 {
		strings.write_byte(b, '/')
		return
	}
	path_of(w, w.nodes[i].parent, b)
	if w.nodes[i].parent != 0 {
		strings.write_byte(b, '/')
	}
	strings.write_string(b, node_name(&w.nodes[i]))
}

child :: proc(w: ^File_World, dir: int, name: string) -> int {
	for i in 1 ..< MAXN {
		if w.nodes[i].used && w.nodes[i].parent == dir && node_name(&w.nodes[i]) == name {
			return i
		}
	}
	return 0
}

has_children :: proc(w: ^File_World, dir: int) -> bool {
	for i in 1 ..< MAXN {
		if w.nodes[i].used && w.nodes[i].parent == dir {
			return true
		}
	}
	return false
}

// A node at random: a directory (1), a file (0), or any but the root (-1);
// MAXN if there is none.
pick_node :: proc(w: ^File_World, want_dir: int) -> int {
	c: [MAXN]int
	n := 0
	for i in 0 ..< MAXN {
		if w.nodes[i].used && (want_dir < 0 ? i != 0 : w.nodes[i].dir == (want_dir == 1)) {
			c[n] = i
			n += 1
		}
	}
	return n > 0 ? c[below(&w.rng, u32(n))] : MAXN
}

free_slot :: proc(w: ^File_World) -> int {
	for i in 1 ..< MAXN {
		if !w.nodes[i].used {
			return i
		}
	}
	return 0
}

drop_node :: proc(w: ^File_World, i: int) {
	delete(w.nodes[i].data)
	w.nodes[i] = {}
}

// --- The volume ---

at :: proc(w: ^File_World, i: int) -> (fs.File, vx.Status) {
	b := strings.builder_make(context.temp_allocator)
	path_of(w, i, &b)
	return fs.walk_path(w.v, &w.br.t, strings.to_string(b))
}

// --- Agreement ---

agrees :: proc(w: ^File_World) -> bool {
	for i in 0 ..< MAXN {
		n := &w.nodes[i]
		if !n.used {
			continue
		}
		f, st := at(w, i)
		if st != .Ok {
			return false
		}
		if n.dir {
			want := 0
			for k in 1 ..< MAXN {
				if w.nodes[k].used && w.nodes[k].parent == i {
					want += 1
				}
			}
			it: fs.Dir_Iter
			if fs.readdir_start(&it, w.v, &w.br.t, &f) != .Ok {
				return false
			}
			ok, seen := true, 0
			for e in fs.readdir_next(&it) {
				if len(e.name) >= 32 {
					ok = false
					break
				}
				c := child(w, i, e.name)
				if c == 0 || w.nodes[c].dir != (e.d.mode & fs.DMDIR != 0) || w.nodes[c].link != (e.d.mode & fs.DMSYMLINK != 0) || (!w.nodes[c].dir && e.d.length != u64(len(w.nodes[c].data))) {
					ok = false
				}
				seen += 1
			}
			if fs.readdir_end(&it) != .Ok || !ok || seen != want {
				return false
			}
			continue
		}
		got: u64
		got, st = fs.read(w.v, &w.br.t, &f, 0, w.buf)
		if f.d.length != u64(len(n.data)) || st != .Ok || got != u64(len(n.data)) || !bytes_eq(w.buf[:got], n.data[:]) {
			return false
		}
		// A read from the middle, too.
		if len(n.data) > 10 {
			off := int(below(&w.rng, u32(len(n.data))))
			got, st = fs.read(w.v, &w.br.t, &f, u64(off), w.buf[:7000])
			if st != .Ok || got != u64(min(len(n.data) - off, 7000)) || !bytes_eq(w.buf[:got], n.data[off:][:got]) {
				return false
			}
		}
	}
	return true
}

fw_clean :: proc(t: ^testing.T, w: ^File_World, loc := #caller_location) -> bool {
	return clean(t, w.v, loc)
}

// --- Operations ---

op_create :: proc(t: ^testing.T, w: ^File_World, dir, link: bool) {
	parent, s := pick_node(w, 1), free_slot(w)
	if parent == MAXN || s == 0 {
		return
	}
	kind := u8('f')
	if dir {
		kind = 'd'
	}
	if link {
		kind = 'l'
	}
	nb: [16]u8
	name := fmt.bprintf(nb[:], "%c%d", rune(kind), below(&w.rng, 40))
	pf, st := at(w, parent)
	testing.expect_value(t, st, vx.Status.Ok)
	w.now += 1
	if link {
		_, st = fs.symlink(w.v, &w.br.t, &pf, name, "../some/target", 7, 8, w.now)
	} else {
		_, st = fs.create(w.v, &w.br.t, &pf, name, dir ? fs.DMDIR | 0o755 : 0o644, 7, 8, w.now)
	}
	if child(w, parent, name) != 0 {
		testing.expect_value(t, st, vx.Status.Err_Exists)
		return
	}
	testing.expect_value(t, st, vx.Status.Ok)
	w.nodes[s] = {used = true, dir = dir, link = link, parent = parent}
	w.nodes[s].nname = copy(w.nodes[s].name[:], name)
	if link {
		append(&w.nodes[s].data, "../some/target")
	}
}

op_write :: proc(t: ^testing.T, w: ^File_World) {
	i := pick_node(w, 0)
	if i == MAXN || w.nodes[i].link {
		return
	}
	nd := &w.nodes[i]
	// Small writes and large, within a file or past its end (sparse).
	off := below(&w.rng, 4) != 0 ? int(below(&w.rng, u32(len(nd.data) + 1))) : int(below(&w.rng, MAXLEN / 2))
	n := below(&w.rng, 3) != 0 ? 1 + int(below(&w.rng, 300)) : 1 + int(below(&w.rng, 40_000))
	if off + n > MAXLEN {
		n = MAXLEN - off
	}
	for k in 0 ..< n {
		w.data[k] = u8(rnd(&w.rng))
	}
	f, st := at(w, i)
	testing.expect_value(t, st, vx.Status.Ok)
	w.now += 1
	testing.expect_value(t, fs.write(w.v, &w.br.t, &f, u64(off), w.data[:n], w.now, 9), vx.Status.Ok)
	if off + n > len(nd.data) {
		resize(&nd.data, off + n) // zeros past the old end
	}
	copy(nd.data[off:], w.data[:n])
}

op_truncate :: proc(t: ^testing.T, w: ^File_World) {
	i := pick_node(w, 0)
	if i == MAXN || w.nodes[i].link {
		return
	}
	nd := &w.nodes[i]
	length := below(&w.rng, 2) != 0 ? int(below(&w.rng, u32(len(nd.data) + 1))) : int(below(&w.rng, MAXLEN))
	f, st := at(w, i)
	testing.expect_value(t, st, vx.Status.Ok)
	w.now += 1
	testing.expect_value(t, fs.setattr(w.v, &w.br.t, &f, {valid = {.Size}, length = u64(length)}, w.now), vx.Status.Ok)
	resize(&nd.data, length)
}

op_remove :: proc(t: ^testing.T, w: ^File_World) {
	i := pick_node(w, -1)
	if i == MAXN {
		return
	}
	pf, st := at(w, w.nodes[i].parent)
	testing.expect_value(t, st, vx.Status.Ok)
	w.now += 1
	st = fs.remove(w.v, &w.br.t, &pf, node_name(&w.nodes[i]), w.now)
	if w.nodes[i].dir && has_children(w, i) {
		testing.expect_value(t, st, vx.Status.Err_Exists)
		return
	}
	testing.expect_value(t, st, vx.Status.Ok)
	drop_node(w, i)
}

// Is dir i itself, or under it?
inside :: proc(w: ^File_World, i, dir: int) -> bool {
	for up := dir; ; up = w.nodes[up].parent {
		if up == i {
			return true
		}
		if up == 0 {
			return false
		}
	}
}

op_rename :: proc(t: ^testing.T, w: ^File_World) {
	i := pick_node(w, -1)
	to := pick_node(w, 1)
	if i == MAXN || to == MAXN {
		return
	}
	nb: [16]u8
	name: string
	if below(&w.rng, 2) != 0 {
		name = fmt.bprintf(nb[:], "%s", node_name(&w.nodes[i]))
	} else {
		name = fmt.bprintf(nb[:], "%c%d", w.nodes[i].dir ? 'd' : 'f', below(&w.rng, 40))
	}
	from, st := at(w, w.nodes[i].parent)
	testing.expect_value(t, st, vx.Status.Ok)
	dest: fs.File
	dest, st = at(w, to)
	testing.expect_value(t, st, vx.Status.Ok)
	w.now += 1
	st = fs.rename(w.v, &w.br.t, &from, node_name(&w.nodes[i]), &dest, name, w.now, nil, nil)
	there := child(w, to, name)
	want := vx.Status.Ok
	switch {
	case w.nodes[i].dir && inside(w, i, to):
		want = .Err_Invalid
	case there != 0 && there != i && w.nodes[there].dir != w.nodes[i].dir:
		want = w.nodes[there].dir ? .Err_Exists : .Err_Invalid
	case there != 0 && there != i && w.nodes[there].dir && has_children(w, there):
		want = .Err_Exists
	}
	testing.expect_value(t, st, want)
	if st != .Ok || there == i {
		return
	}
	if there != 0 {
		drop_node(w, there)
	}
	w.nodes[i].parent = to
	w.nodes[i].nname = copy(w.nodes[i].name[:], name)
}

fw_remount :: proc(t: ^testing.T, w: ^File_World) {
	testing.expect_value(t, fs.commit(w.v), vx.Status.Ok)
	fs.unmount(w.v)
	testing.expect_value(t, fs.mount(w.v, dev_of(w.d), mem(), 512), vx.Status.Ok)
	st: vx.Status
	w.br, st = fs.branch_open(w.v, "home")
	testing.expect_value(t, st, vx.Status.Ok)
}

@(test)
test_file_random :: proc(t: ^testing.T) {
	digests := [3]u64{0x0c2d1ec2af11f8e2, 0x83fb37a99fa4f651, 0xb9ae82eeccf60f93}
	for seed in u64(1) ..= 3 {
		w := new(File_World)
		defer free(w)
		w.rng = {seed * 0x9E3779B97F4A7C15}
		w.buf = make([]u8, MAXLEN + 10)
		defer delete(w.buf)
		w.data = make([]u8, MAXLEN)
		defer delete(w.data)
		w.nodes[0] = {used = true, dir = true}
		w.d = memdev_new(8192)
		defer memdev_free(w.d)
		w.v = new(fs.Vol)
		defer free(w.v)
		testing.expect_value(t, fs.mkfs(w.v, dev_of(w.d), mem(), 512, 2, {"home"}, 0o755, 1, 1, 1), vx.Status.Ok)
		st: vx.Status
		w.br, st = fs.branch_open(w.v, "home")
		testing.expect_value(t, st, vx.Status.Ok)
		ok := true
		for k in 0 ..< 900 {
			if !ok {
				break
			}
			op := below(&w.rng, 100)
			switch {
			case op < 15:
				op_create(t, w, true, false)
			case op < 35:
				op_create(t, w, false, false)
			case op < 38:
				op_create(t, w, false, true)
			case op < 65:
				op_write(t, w)
			case op < 75:
				op_truncate(t, w)
			case op < 87:
				op_remove(t, w)
			case:
				op_rename(t, w)
			}
			if k % 25 == 24 {
				a, c := agrees(w), fw_clean(t, w)
				testing.expect(t, a)
				testing.expect(t, c)
				ok = a && c
			}
			if k % 150 == 149 {
				fw_remount(t, w)
				ok = ok && agrees(w) && fw_clean(t, w)
				testing.expect(t, ok)
			}
			if !ok {
				log.errorf("seed %d: wrong at op %d", seed, k)
			}
		}
		// Everything removed, deepest first.
		for _ in 0 ..< 20 {
			for i in 1 ..< MAXN {
				if w.nodes[i].used && !has_children(w, i) {
					pf: fs.File
					pf, st = at(w, w.nodes[i].parent)
					testing.expect_value(t, st, vx.Status.Ok)
					w.now += 1
					testing.expect_value(t, fs.remove(w.v, &w.br.t, &pf, node_name(&w.nodes[i]), w.now), vx.Status.Ok)
					drop_node(w, i)
				}
			}
		}
		fw_remount(t, w)
		c: fs.Check
		testing.expect_value(t, fs.check_volume(w.v, &c), vx.Status.Ok)
		testing.expect(t, agrees(w))
		// Not every block is back yet: the removes are messages buffered in
		// pivots until a flush takes them to the leaves, as in any Bε tree.
		// Clean is what holds: nothing leaked, nothing reachable that should not
		// be.
		expect_digest(t, fmt.tprintf("file random %d", seed), w.d.bytes, digests[seed - 1])
		fs.unmount(w.v)
		for i in 0 ..< MAXN {
			drop_node(w, i)
		}
	}
}

// By hand: names refused, "..", walking paths, the root's own parent.
@(test)
test_names :: proc(t: ^testing.T) {
	d := memdev_new(2048)
	defer memdev_free(d)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.mkfs(v, dev_of(d), mem(), 256, 1, {"cfg"}, 0o755, 0, 0, 5), vx.Status.Ok)
	br, st := fs.branch_open(v, "cfg")
	testing.expect_value(t, st, vx.Status.Ok)
	tr := &br.t
	root, a, b, f, up: fs.File
	root, st = fs.root(v, tr)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, fs.is_dir(&root))
	testing.expect_value(t, root.d.btime, 5)
	a, st = fs.create(v, tr, &root, "a", fs.DMDIR | 0o700, 1, 1, 6)
	testing.expect_value(t, st, vx.Status.Ok)
	b, st = fs.create(v, tr, &a, "b", fs.DMDIR | 0o700, 1, 1, 7)
	testing.expect_value(t, st, vx.Status.Ok)
	f, st = fs.create(v, tr, &b, "file", 0o600, 1, 1, 8)
	testing.expect_value(t, st, vx.Status.Ok)
	for bad in ([]string{"", ".", "..", "x/y"}) {
		_, st = fs.create(v, tr, &root, bad, 0o600, 1, 1, 9)
		testing.expectf(t, st == .Err_Invalid, "create %q: %v", bad, st)
	}
	longname := strings.repeat("n", fs.NAMEMAX + 1, context.temp_allocator)
	_, st = fs.create(v, tr, &root, longname, 0o600, 1, 1, 9)
	testing.expect_value(t, st, vx.Status.Err_Range)
	_, st = fs.create(v, tr, &root, longname[:fs.NAMEMAX], 0o600, 1, 1, 9) // the longest there may be
	testing.expect_value(t, st, vx.Status.Ok)
	f, st = fs.walk_path(v, tr, "/a/b/file")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, f.d.mtime, 8)
	f, st = fs.walk_path(v, tr, "a//b/../b/./file")
	testing.expect_value(t, st, vx.Status.Ok)
	up, st = fs.walk(v, tr, &b, "..")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, up.d.qid_path, a.d.qid_path)
	up, st = fs.walk(v, tr, &root, "..")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, up.d.qid_path, root.d.qid_path)
	_, st = fs.walk_path(v, tr, "/a/nothing")
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	_, st = fs.walk_path(v, tr, "/a/b/file/x") // through a file
	testing.expect_value(t, st, vx.Status.Err_Invalid)
	a, st = fs.walk_path(v, tr, "/a")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, a.d.mtime, 7) // b's creation touched it
	// A directory moved: its ".." follows it.
	testing.expect_value(t, fs.rename(v, tr, &a, "b", &root, "b2", 10, nil, nil), vx.Status.Ok)
	f, st = fs.walk_path(v, tr, "/b2/../a")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, f.d.qid_path, a.d.qid_path)
	b, st = fs.walk_path(v, tr, "/b2")
	testing.expect_value(t, st, vx.Status.Ok)
	up, st = fs.walk(v, tr, &b, "..")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, up.d.qid_path, root.d.qid_path)
	testing.expect_value(t, fs.remove(v, tr, &root, "..", 11), vx.Status.Err_Invalid)
	// Entries by qid: a file, a moved directory, the root; and one removed.
	byq: fs.File
	f, st = fs.walk_path(v, tr, "/b2/file")
	testing.expect_value(t, st, vx.Status.Ok)
	byq, st = fs.file_by_qid(v, tr, f.d.qid_path)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, bytes_eq(fs.file_key(&byq), fs.file_key(&f)))
	byq, st = fs.file_by_qid(v, tr, b.d.qid_path)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, byq.d.qid_path, b.d.qid_path)
	byq, st = fs.file_by_qid(v, tr, root.d.qid_path)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, byq.nkey, 9)
	testing.expect_value(t, fs.remove(v, tr, &b, "file", 12), vx.Status.Ok)
	_, st = fs.file_by_qid(v, tr, f.d.qid_path)
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	// An orphan: removed while open, found by its qid, written, then reaped.
	o, oq: fs.File
	o, st = fs.create(v, tr, &root, "open-file", 0o600, 1, 1, 13)
	testing.expect_value(t, st, vx.Status.Ok)
	big := make([]u8, 40000)
	defer delete(big)
	for &c in big {
		c = 0x42
	}
	testing.expect_value(t, fs.write(v, tr, &o, 0, big, 14, 1), vx.Status.Ok)
	testing.expect_value(t, fs.orphan(v, tr, &root, "open-file", 15), vx.Status.Ok)
	_, st = fs.walk(v, tr, &root, "open-file")
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	oq, st = fs.file_by_qid(v, tr, o.d.qid_path)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, fs.is_orphan(&oq))
	testing.expect_value(t, oq.d.length, 40000)
	tail := "tail"
	testing.expect_value(t, fs.write(v, tr, &oq, 40000, transmute([]u8)tail, 16, 1), vx.Status.Ok)
	oq, st = fs.file_by_qid(v, tr, o.d.qid_path)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, oq.d.length, 40004)
	back: [8]u8
	got: u64
	got, st = fs.read(v, tr, &oq, 40000 - 2, back[:])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, got, 6)
	testing.expect_value(t, string(back[:6]), "\x42\x42tail")
	testing.expect_value(t, fs.reap(v, tr, o.d.qid_path), vx.Status.Ok)
	_, st = fs.file_by_qid(v, tr, o.d.qid_path)
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	// Orphans a crash left: committed while orphaned, reaped when next opened.
	o, st = fs.create(v, tr, &root, "left", 0o600, 1, 1, 17)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, fs.write(v, tr, &o, 0, big, 18, 1), vx.Status.Ok)
	testing.expect_value(t, fs.orphan(v, tr, &root, "left", 19), vx.Status.Ok)
	testing.expect_value(t, fs.commit(v), vx.Status.Ok)
	c: fs.Check
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Ok)
	with_orphan := c.trees
	fs.unmount(v)
	testing.expect_value(t, fs.mount(v, dev_of(d), mem(), 256), vx.Status.Ok)
	br, st = fs.branch_open(v, "cfg")
	testing.expect_value(t, st, vx.Status.Ok)
	tr = &br.t
	n: u32
	n, st = fs.reap_all(v, tr)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 1)
	_, st = fs.file_by_qid(v, tr, o.d.qid_path)
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	testing.expect_value(t, fs.commit(v), vx.Status.Ok)
	testing.expect_value(t, fs.check_volume(v, &c), vx.Status.Ok)
	testing.expect(t, c.trees < with_orphan)
	fs.unmount(v)
	expect_digest(t, "names", d.bytes, 0x544c9230d2e3504d)
}

keep_all :: proc "contextless" (_: rawptr, _: u64) -> bool {
	return true
}

committed_clean :: proc(v: ^fs.Vol) -> bool {
	c: fs.Check
	return fs.commit(v) == .Ok && fs.check_volume(v, &c) == .Ok && v.fs.err == .Ok
}

// The review's cases (upstream's docs/milestones.md): a rename over an open
// file, a file of many blocks removed, a rename deep in a tree, a full volume.
@(test)
test_limits :: proc(t: ^testing.T) {
	d := memdev_new(4096)
	defer memdev_free(d)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.mkfs(v, dev_of(d), mem(), 256, 2, {"cfg"}, 0o755, 0, 0, 5), vx.Status.Ok)
	br, st := fs.branch_open(v, "cfg")
	testing.expect_value(t, st, vx.Status.Ok)
	tr := &br.t
	root, a, b, f, q: fs.File
	root, st = fs.root(v, tr)
	testing.expect_value(t, st, vx.Status.Ok)
	back: [16]u8
	got: u64

	// Renamed over while open: the old file kept, as an orphan, until reaped.
	a, st = fs.create(v, tr, &root, "old", 0o600, 1, 1, 6)
	testing.expect_value(t, st, vx.Status.Ok)
	old_data, new_data := "old data", "new data"
	testing.expect_value(t, fs.write(v, tr, &a, 0, transmute([]u8)old_data, 6, 1), vx.Status.Ok)
	b, st = fs.create(v, tr, &root, "new", 0o600, 1, 1, 7)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, fs.write(v, tr, &b, 0, transmute([]u8)new_data, 7, 1), vx.Status.Ok)
	testing.expect_value(t, fs.rename(v, tr, &root, "new", &root, "old", 8, keep_all, nil), vx.Status.Ok)
	f, st = fs.walk(v, tr, &root, "old")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, f.d.qid_path, b.d.qid_path)
	q, st = fs.file_by_qid(v, tr, a.d.qid_path)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, fs.is_orphan(&q))
	got, st = fs.read(v, tr, &q, 0, back[:8])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, got, 8)
	testing.expect_value(t, string(back[:8]), "old data")
	testing.expect_value(t, fs.reap(v, tr, a.d.qid_path), vx.Status.Ok)
	testing.expect(t, committed_clean(v))

	// A file of many blocks (more than one chunk of clear_data's) removed.
	chunk := make([]u8, 64 * 1024)
	defer delete(chunk)
	for &c in chunk {
		c = 0x77
	}
	f, st = fs.create(v, tr, &root, "big", 0o600, 1, 1, 9)
	testing.expect_value(t, st, vx.Status.Ok)
	for off := u64(0); off < 600 * B; off += u64(len(chunk)) {
		testing.expect_value(t, fs.write(v, tr, &f, off, chunk, 9, 1), vx.Status.Ok)
	}
	testing.expect(t, committed_clean(v))
	testing.expect_value(t, fs.remove(v, tr, &root, "big", 10), vx.Status.Ok)
	testing.expect(t, committed_clean(v))

	// A tree deeper than the old limit of 4096: a rename into its depths is fine.
	dir := root
	for _ in 0 ..< 5000 {
		sub: fs.File
		sub, st = fs.create(v, tr, &dir, "d", fs.DMDIR | 0o700, 1, 1, 11)
		if !testing.expect_value(t, st, vx.Status.Ok) {
			break
		}
		dir = sub
	}
	f, st = fs.create(v, tr, &root, "x", 0o600, 1, 1, 12)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, fs.rename(v, tr, &root, "x", &dir, "x", 13, nil, nil), vx.Status.Ok)
	testing.expect_value(t, v.fs.err, vx.Status.Ok)
	testing.expect(t, committed_clean(v))

	// Full: a write refused with NO_SPACE, the volume still sound; a remove
	// makes room, and writing works again.
	f, st = fs.create(v, tr, &root, "fill", 0o600, 1, 1, 14)
	testing.expect_value(t, st, vx.Status.Ok)
	st = .Ok
	off := u64(0)
	for ; st == .Ok && off < u64(len(d.bytes)); off += u64(len(chunk)) {
		st = fs.write(v, tr, &f, off, chunk, 15, 1)
	}
	testing.expect_value(t, st, vx.Status.Err_No_Space)
	testing.expect_value(t, v.fs.err, vx.Status.Ok)
	testing.expect(t, off > u64(len(d.bytes)) / 2)
	testing.expect_value(t, fs.commit(v), vx.Status.Ok) // what was written, kept
	_, st = fs.create(v, tr, &root, "more", 0o600, 1, 1, 16)
	testing.expect(t, st == .Ok || v.fs.err == .Ok)
	testing.expect_value(t, fs.remove(v, tr, &root, "fill", 17), vx.Status.Ok) // a remove may dig into the reserve
	testing.expect(t, committed_clean(v))
	_, st = fs.walk(v, tr, &root, "fill")
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	f, st = fs.create(v, tr, &root, "after", 0o600, 1, 1, 18)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, fs.write(v, tr, &f, 0, chunk, 18, 1), vx.Status.Ok)
	testing.expect(t, committed_clean(v))
	fs.unmount(v)
	expect_digest(t, "limits", d.bytes, 0x091f497c03297117)
}

// How block 0 of a file is kept: .Inline, .Ref (a block), or 0xff (none).
block0_kind :: proc(v: ^fs.Vol, tr: ^fs.Tree, qid: u64) -> u8 {
	k: [17]u8
	buf: [fs.INLMAX]u8
	val, st := fs.lookup(&v.fs, tr, fs.key_dat(k[:], qid, 0), &buf)
	return st == .Ok && len(val) > 0 ? val[0] : 0xff
}

// M5 step 10's close-out of the file layer's review findings: a write of
// nothing does not extend; a size that would wrap when rounded up is refused;
// setattr keeps 11 §3's rule (a file is inline whole, or in blocks) both
// ways; "." and ".." are never removed, and say INVALID; only an orphan is
// reaped; a link's target is inline, at most INLINE.
@(test)
test_file_close_out :: proc(t: ^testing.T) {
	d := memdev_new(1024)
	defer memdev_free(d)
	v := new(fs.Vol)
	defer free(v)
	testing.expect_value(t, fs.mkfs(v, dev_of(d), mem(), 256, 1, {"cfg"}, 0o755, 0, 0, 5), vx.Status.Ok)
	br, st := fs.branch_open(v, "cfg")
	testing.expect_value(t, st, vx.Status.Ok)
	tr := &br.t
	root, f, l, sub: fs.File
	root, st = fs.root(v, tr)
	testing.expect_value(t, st, vx.Status.Ok)
	f, st = fs.create(v, tr, &root, "f", 0o600, 1, 1, 6)
	testing.expect_value(t, st, vx.Status.Ok)
	hello := "hello"
	testing.expect_value(t, fs.write(v, tr, &f, 0, transmute([]u8)hello, 6, 1), vx.Status.Ok)
	testing.expect_value(t, f.d.length, 5)
	testing.expect_value(t, fs.write(v, tr, &f, 1000, nil, 7, 1), vx.Status.Ok) // nothing: not extended
	testing.expect_value(t, f.d.length, 5)
	testing.expect_value(t, fs.setattr(v, tr, &f, {valid = {.Size}, length = max(u64) - 3}, 8), vx.Status.Err_Range)
	testing.expect_value(t, f.d.length, 5)
	testing.expect_value(t, block0_kind(v, tr, f.d.qid_path), u8(fs.Value_Kind.Inline))
	// Grown by setattr past inline: into a block, the bytes kept and zeros after.
	testing.expect_value(t, fs.setattr(v, tr, &f, {valid = {.Size}, length = 2000}, 9), vx.Status.Ok)
	testing.expect_value(t, block0_kind(v, tr, f.d.qid_path), u8(fs.Value_Kind.Ref))
	back: [2000]u8
	got: u64
	got, st = fs.read(v, tr, &f, 0, back[:])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, got, 2000)
	testing.expect_value(t, string(back[:5]), "hello")
	testing.expect_value(t, back[5], 0)
	testing.expect_value(t, back[1999], 0)
	// Shrunk by setattr to inline size: inline again, the bytes kept.
	testing.expect_value(t, fs.setattr(v, tr, &f, {valid = {.Size}, length = 3}, 10), vx.Status.Ok)
	testing.expect_value(t, block0_kind(v, tr, f.d.qid_path), u8(fs.Value_Kind.Inline))
	got, st = fs.read(v, tr, &f, 0, back[:100])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, got, 3)
	testing.expect_value(t, string(back[:3]), "hel")
	testing.expect(t, committed_clean(v)) // no block left behind by either change
	// "." and "..".
	sub, st = fs.create(v, tr, &root, "d", fs.DMDIR | 0o700, 1, 1, 11)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, fs.remove(v, tr, &sub, "..", 12), vx.Status.Err_Invalid)
	testing.expect_value(t, fs.remove(v, tr, &sub, ".", 12), vx.Status.Err_Invalid)
	// Reaping what is not an orphan: refused, the file untouched.
	testing.expect_value(t, fs.reap(v, tr, f.d.qid_path), vx.Status.Err_Invalid)
	got, st = fs.read(v, tr, &f, 0, back[:100])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, got, 3)
	// A link's target: inline, so at most INLINE bytes.
	target := strings.repeat("x", fs.INLINE + 1, context.temp_allocator)
	_, st = fs.symlink(v, tr, &root, "long", target, 1, 1, 13)
	testing.expect_value(t, st, vx.Status.Err_Range)
	l, st = fs.symlink(v, tr, &root, "max", target[:fs.INLINE], 1, 1, 13)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, block0_kind(v, tr, l.d.qid_path), u8(fs.Value_Kind.Inline))
	testing.expect(t, committed_clean(v))
	fs.unmount(v)
	expect_digest(t, "file close_out", d.bytes, 0x2aee579745516e62)
}
