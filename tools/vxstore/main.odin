// vxstore: makes and reads content stores (upstream's docs/06 §4) on the
// build machine, with lib/store: what upstream's ./build release uses (M5
// step 9a). Upstream's host/vxstore, in Odin.
//
//	vxstore put STORE DIR [TAR]     DIR's tree (and TAR's entries, at its root)
//	                                into STORE; prints the tree's hash and the
//	                                bytes of its files
//	vxstore tar STORE TREE OUT [NAME=FILE...]
//	                                every object TREE reaches, as a ustar
//	                                archive of b2/xx/<hex> paths (store.tar),
//	                                after each FILE named NAME (records/1.ndb)
//	vxstore check STORE TREE        every object TREE reaches, checked; exit 0
//	                                if all are there and sound
//	vxstore ls STORE TREE [PATH]    a directory's entries
//	vxstore cat STORE TREE PATH     a file's bytes, to stdout
//	vxstore blocks STORE TREE PATH  a file's block objects' paths in the
//	                                store, one a line (for tests that damage one)
//
// Modes are not the build machine's: a file is 0444, or 0555 if any execute
// bit is set; a directory 0555; a link 0777. Times and owners are not kept.
// So a tree's hash depends only on names, contents and links, and two builds
// of one commit give one hash (upstream's 04 §7).
//
// Build: ./build all makes out/host/vxstore, linked with Monocypher's host
// archive (tools/build/cobj.odin, ADR-0011).
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import vx "abi:vx"
import "vx:ndb"
import "vx:store"
import "vx:tar"

// Ends the program as upstream's does: "vxstore: what: arg", status 1.
die :: proc(what: string, arg: Maybe(string) = nil) -> ! {
	if a, ok := arg.?; ok {
		fmt.eprintfln("vxstore: %s: %s", what, a)
	} else {
		fmt.eprintfln("vxstore: %s", what)
	}
	os.exit(1)
}

// --- The store ---

store_root: string

// rwxr-xr-x, as upstream makes the store's directories.
DIR_MODE :: os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User}

object_path :: proc(h: store.Hash) -> string {
	rel := store.path(h)
	return fmt.aprintf("%s/%s", store_root, string(rel[:]))
}

// An object written, if the store lacks it: to a temporary name, then renamed.
put_object :: proc(h: store.Hash, data: []u8) {
	path := object_path(h)
	defer delete(path)
	if os.exists(path) {
		return
	}
	// As upstream: each directory made if it can be, and any failure seen
	// when the object itself is written.
	_ = os.make_directory(store_root, DIR_MODE)
	_ = os.make_directory(fmt.tprintf("%s/b2", store_root), DIR_MODE)
	_ = os.make_directory(path[:strings.last_index_byte(path, '/')], DIR_MODE)
	tmp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(tmp, data, perm = os.Permissions_Read_All); err != nil {
		die("cannot write", path)
	}
	if err := os.rename(tmp, path); err != nil {
		die("cannot write", path)
	}
}

get_object :: proc(h: store.Hash) -> []u8 {
	path := object_path(h)
	defer delete(path)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		x := store.hex(h)
		die("the store lacks", string(x[:]))
	}
	return data
}

// --- Trees in memory ---

Node :: struct {
	name:     string,
	mode:     u32,
	kids:     [dynamic]^Node,
	from_tar: bool, // data is the file's bytes, from a tar; otherwise read from path
	data:     []u8,
	size:     u64,
	path:     string,
	link:     string,
}

child :: proc(dir: ^Node, name: string, make_it: bool) -> ^Node {
	for k in dir.kids {
		if k.name == name {
			return k
		}
	}
	if !make_it {
		return nil
	}
	n := new(Node)
	n.name = strings.clone(name)
	n.mode = store.MODE_DIR | 0o555
	append(&dir.kids, n)
	return n
}

file_mode :: proc(host: os.Permissions) -> u32 {
	return host & os.Permissions_Execute_All != {} ? store.MODE_FILE | 0o555 : store.MODE_FILE | 0o444
}

add_dir :: proc(dir: ^Node, path: string) {
	entries, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {
		die("cannot read the directory", path)
	}
	for e in entries {
		p := fmt.aprintf("%s/%s", path, e.name)
		fi, serr := os.lstat(p, context.allocator)
		if serr != nil {
			die("cannot stat", p)
		}
		n := child(dir, e.name, true)
		#partial switch fi.type {
		case .Directory:
			add_dir(n, p)
		case .Symlink:
			target, lerr := os.read_link(p, context.allocator)
			if lerr != nil || len(target) == 0 {
				die("cannot read the link", p)
			}
			n.mode = store.MODE_LINK | 0o777
			n.link = target
		case .Regular:
			n.mode = file_mode(fi.mode)
			n.path = p
			n.size = u64(fi.size)
		case:
			die("neither a file, a directory nor a link", p)
		}
	}
}

add_tar :: proc(root: ^Node, image: []u8) {
	r := tar.open(image)
	e: tar.Entry
	for tar.next(&r, &e) == .Ok {
		dir := root
		p := tar.entry_path(&e)
		for len(p) > 0 {
			n := strings.index_byte(p, '/')
			last := n < 0
			if last {
				n = len(p)
			}
			k := child(dir, p[:n], true)
			if last && !e.dir {
				k.mode = file_mode(transmute(os.Permissions)(e.mode & 0o777))
				k.from_tar = true
				k.data = e.data
				k.size = u64(len(e.data))
			}
			dir = k
			p = last ? "" : p[n + 1:]
		}
	}
	if r.failed {
		die("a malformed tar")
	}
}

// A file's blocks and index, written; its hash.
hash_file :: proc(n: ^Node) -> store.Hash {
	data := n.data
	if !n.from_tar {
		read, err := os.read_entire_file(n.path, context.allocator)
		if err != nil {
			die("cannot read", n.path)
		}
		data = read
		n.size = u64(len(read))
	}
	defer if !n.from_tar {
		delete(data)
	}
	count := store.blocks(n.size)
	idx := make([]u8, store.INDEX_HEAD + count * store.HASH)
	defer delete(idx)
	head := store.index_head(n.size)
	copy(idx, head[:])
	for i in 0 ..< count {
		at := i * store.BLOCK
		block := data[at:min(at + store.BLOCK, n.size)]
		h := store.leaf(block)
		put_object(h, block)
		copy(idx[store.INDEX_HEAD + i * store.HASH:], h[:])
	}
	name := store.file_hash(n.size, store.root(idx[store.INDEX_HEAD:]))
	put_object(name, idx)
	return name
}

// A directory's entries' objects, then its own; its hash, and the bytes under it.
hash_dir :: proc(dir: ^Node) -> (h: store.Hash, bytes: u64) {
	slice.sort_by(dir.kids[:], proc(a, b: ^Node) -> bool {return a.name < b.name}) // bytes, unsigned
	text := make([]u8, 256 + len(dir.kids) * 512) // upstream's room: an entry that does not fit fails as there
	defer delete(text)
	w := ndb.Writer {
		buf = text,
	}
	for k in dir.kids {
		e := store.Entry {
			name = k.name,
			mode = k.mode,
		}
		switch k.mode & store.MODE_TYPE {
		case store.MODE_DIR:
			n: u64
			e.hash, n = hash_dir(k)
			bytes += n
		case store.MODE_LINK:
			e.link = k.link
		case:
			e.hash = hash_file(k)
			e.size = k.size
			bytes += k.size
		}
		if !store.dir_put(&w, e) {
			die("a name ndb cannot hold, or too many entries", k.name)
		}
	}
	dir_text := text[:w.len]
	h = store.text_hash(dir_text)
	put_object(h, dir_text)
	return
}

// --- Walking a stored tree ---

Visit :: proc(h: store.Hash, block: bool, names: ^[dynamic]string)

walk_tree :: proc(dir: store.Hash, visit: Visit, names: ^[dynamic]string) {
	text := get_object(dir)
	defer delete(text)
	if store.dir_check(dir, text) != .Ok {
		die("a directory does not match its name")
	}
	visit(dir, false, names)
	scratch := make([]u8, 1 << 16)
	defer delete(scratch)
	r := ndb.Reader {
		src     = string(text),
		scratch = scratch,
	}
	rec := new(ndb.Record)
	defer free(rec)
	for ndb.next(&r, rec) == .Record {
		r.scratch_used = 0
		e, st := store.dir_entry(rec)
		if st != .Ok {
			die("a malformed directory entry")
		}
		if store.is_link(e) {
			continue
		}
		if store.is_dir(e) {
			walk_tree(e.hash, visit, names)
			continue
		}
		idx := get_object(e.hash)
		defer delete(idx)
		x, ist := store.index_check(e.hash, idx)
		if ist != .Ok || x.size != e.size {
			die("a file's index does not match its name")
		}
		visit(e.hash, false, names)
		for i in 0 ..< store.index_blocks(x) {
			b := block_hash(x, i)
			data := get_object(b)
			if store.block_check(x, i, data) != .Ok {
				die("a block does not match its hash")
			}
			delete(data)
			visit(b, true, names)
		}
	}
}

block_hash :: proc(x: store.Index, i: u64) -> (b: store.Hash) {
	copy(b[:], x.hashes[i * store.HASH:][:store.HASH])
	return
}

collect :: proc(h: store.Hash, block: bool, names: ^[dynamic]string) {
	rel := store.path(h)
	append(names, strings.clone(string(rel[:])))
}

none :: proc(h: store.Hash, block: bool, names: ^[dynamic]string) {}

// The entry at path under a tree.
lookup :: proc(tree: store.Hash, path: string) -> store.Entry {
	e := store.Entry {
		mode = store.MODE_DIR | 0o555,
		hash = tree,
	}
	scratch := make([]u8, 1 << 16)
	rest := path
	for len(rest) > 0 {
		rest = strings.trim_left(rest, "/")
		n := strings.index_byte(rest, '/')
		if n < 0 {
			n = len(rest)
		}
		if n == 0 {
			break
		}
		if !store.is_dir(e) {
			die("not a directory on the way", rest)
		}
		dir := get_object(e.hash) // kept: e's strings point into it
		st: vx.Status
		e, st = store.dir_find(dir, rest[:n], scratch)
		if st != .Ok {
			die("no such entry", rest)
		}
		rest = rest[n:]
	}
	return e
}

tree_arg :: proc(s: string) -> store.Hash {
	h, ok := store.parse(s)
	if !ok {
		die("not a b2: hash", s)
	}
	return h
}

// A sound file's index: its size and block hashes.
file_index :: proc(e: store.Entry, path: string) -> store.Index {
	obj := get_object(e.hash)
	x, st := store.index_check(e.hash, obj)
	if store.is_dir(e) || st != .Ok {
		die("not a sound file", path)
	}
	return x
}

USAGE :: "usage: vxstore put|tar|check|ls|cat STORE ..."

main :: proc() {
	args := os.args
	argc := len(args)
	if argc < 4 {
		die(USAGE)
	}
	store_root = args[2]
	if args[1] == "put" && (argc == 4 || argc == 5) {
		root := new(Node)
		root.mode = store.MODE_DIR | 0o555
		add_dir(root, args[3])
		if argc == 5 {
			image, err := os.read_entire_file(args[4], context.allocator)
			if err != nil {
				die("cannot read", args[4])
			}
			add_tar(root, image)
		}
		h, bytes := hash_dir(root)
		x := store.hex(h)
		fmt.printfln("%s %d", string(x[:]), bytes)
		os.exit(0)
	}
	tree := tree_arg(args[3])
	switch {
	case args[1] == "check" && argc == 4:
		walk_tree(tree, none, nil)
	case args[1] == "tar" && argc >= 5:
		write_tar(tree, args[4], args[5:])
	case args[1] == "blocks" && argc == 5:
		x := file_index(lookup(tree, args[4]), args[4])
		for i in 0 ..< store.index_blocks(x) {
			rel := store.path(block_hash(x, i))
			fmt.println(string(rel[:]))
		}
	case args[1] == "ls" && (argc == 4 || argc == 5), args[1] == "cat" && argc == 5:
		path := argc == 5 ? args[4] : ""
		e := lookup(tree, path)
		if args[1] == "ls" {
			if !store.is_dir(e) {
				die("not a directory", path)
			}
			_, _ = os.write(os.stdout, get_object(e.hash))
			break
		}
		x := file_index(e, path)
		for i in 0 ..< store.index_blocks(x) {
			data := get_object(block_hash(x, i))
			if store.block_check(x, i, data) != .Ok {
				die("a block does not match its hash")
			}
			_, _ = os.write(os.stdout, data)
			delete(data)
		}
	case:
		die(USAGE)
	}
	os.exit(0)
}

// Every object tree reaches, by path, as a ustar archive at out, after each
// NAME=FILE in extra.
write_tar :: proc(tree: store.Hash, out: string, extra: []string) {
	names := make([dynamic]string)
	walk_tree(tree, collect, &names)
	slice.sort(names[:])
	total := 2 * tar.BLOCK // the two zero blocks that end it
	for p in names {
		fi, err := os.stat(fmt.tprintf("%s/%s", store_root, p), context.temp_allocator)
		if err != nil {
			die("cannot stat", fmt.tprintf("%s/%s", store_root, p))
		}
		total += 2 * tar.BLOCK + int(fi.size)
	}
	for x in extra {
		eq := strings.index_byte(x, '=')
		if eq < 0 {
			die("not NAME=FILE", x)
		}
		fi, err := os.stat(x[eq + 1:], context.temp_allocator)
		if err != nil {
			die("not NAME=FILE", x)
		}
		total += 2 * tar.BLOCK + int(fi.size) + 2 * tar.BLOCK // and its directories
	}
	w := tar.Writer {
		buf = make([]u8, total),
	}
	for x in extra {
		eq := strings.index_byte(x, '=')
		data, err := os.read_entire_file(x[eq + 1:], context.allocator)
		if err != nil {
			die("cannot read", x[eq + 1:])
		}
		tar.add(&w, x[:eq], false, 0o444, data)
		delete(data)
	}
	for p, i in names {
		if i > 0 && p == names[i - 1] {
			continue // shared by two files
		}
		data, err := os.read_entire_file(fmt.tprintf("%s/%s", store_root, p), context.allocator)
		if err != nil {
			die("cannot read", p)
		}
		tar.add(&w, p, false, 0o444, data)
		delete(data)
	}
	n := tar.end(&w)
	if n == 0 {
		die("cannot write the archive")
	}
	if err := os.write_entire_file(out, w.buf[:n]); err != nil {
		die("cannot write", out)
	}
}
