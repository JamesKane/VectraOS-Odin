// host-links: monocypher
//
// servers/distd on the host: the program itself, linked against lib/rt and
// Monocypher, with a fake kernel underneath for its console. Its namespace
// is one file server in memory (memfs_test.odin) holding a content store
// made here with lib/store (the scenario's small release: a file of several
// blocks, another never read before it is damaged, a nested directory, a
// link, a UTF-8 name, and boot/vx's slot files), an ESP with a slot table,
// and fsd's adm ctl. distd's p9.Fs is driven through lib/p9's server
// framework and client.
//
// Upstream has no host test of distd (its scenarios distd and slots test
// it); these cases follow its distd.c and those scenarios' checks. One test
// procedure: distd's state is the program's globals.
package distd_test

import vx "abi:vx"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "vx:crypto"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:rt"
import "vx:slots"
import "vx:store"
import distd "../../../servers/distd"
import "../p9test"

kernel_log: [8192]u8
kernel_log_len: int

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Handle_Close:
		return 0
	}
	return i64(vx.Status.Err_Unsupported)
}

// What distd said since the last call.
said :: proc() -> string {
	s := strings.clone(string(kernel_log[:kernel_log_len]), context.temp_allocator)
	kernel_log_len = 0
	return s
}

// --- A store, made as vxstore makes one ---

put_object :: proc(h: store.Hash, data: []u8) {
	p := store.path(h)
	mem_put(fmt.tprintf("n/%s", string(p[:])), data)
}

// A file's blocks and index into the store; its name.
put_file :: proc(data: []u8) -> store.Hash {
	size := u64(len(data))
	nb := store.blocks(size)
	leaves := make([]u8, nb * store.HASH, context.temp_allocator)
	for b in 0 ..< nb {
		block := data[min(b * store.BLOCK, size):min((b + 1) * store.BLOCK, size)]
		h := store.leaf(block)
		copy(leaves[b * store.HASH:], h[:])
		put_object(h, block)
	}
	head := store.index_head(size)
	name := store.file_hash(size, store.root(leaves))
	put_object(name, slice.concatenate([][]u8{head[:], leaves}, context.temp_allocator))
	return name
}

file :: proc(name: string, data: string) -> store.Entry {
	return {name = name, mode = 0o100444, size = u64(len(data)), hash = put_file(transmute([]u8)data)}
}

link :: proc(name, target: string) -> store.Entry {
	return {name = name, mode = 0o120777, link = target}
}

// A directory's canonical text into the store, its entries sorted by name.
dir :: proc(name: string, entries: ..store.Entry) -> store.Entry {
	sorted := slice.clone(entries, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: store.Entry) -> bool {return a.name < b.name})
	buf := make([]u8, 64 * 1024, context.temp_allocator)
	w := ndb.Writer{buf = buf}
	for e in sorted {
		_ = store.dir_put(&w, e)
	}
	text := transmute([]u8)ndb.written(&w)
	h := store.text_hash(text)
	put_object(h, text)
	return {name = name, mode = 0o040555, hash = h}
}

pattern :: proc(n, a, b: int) -> string {
	out := make([]u8, n, context.temp_allocator)
	for &c, i in out {
		c = u8((i * a + i / b) & 0xff)
	}
	return string(out)
}

hex_of :: proc(h: store.Hash) -> string {
	x := store.hex(h)
	return strings.clone(string(x[:]), context.temp_allocator)
}

blake512_hex :: proc(data: []u8) -> string {
	h: [64]u8
	crypto.blake2b(h[:], data)
	b := strings.builder_make(context.temp_allocator)
	for v in h {
		fmt.sbprintf(&b, "%02x", v)
	}
	return strings.to_string(b)
}

// The slot files' contents in a release's boot/vx.
slot_dir :: proc(release: int) -> store.Entry {
	return dir(
		"boot",
		dir(
			"vx",
			file("kernel.elf", fmt.tprintf("kernel.elf of release %d\n", release)),
			file("svcd", fmt.tprintf("svcd of release %d\n", release)),
			file("ktest", fmt.tprintf("ktest of release %d\n", release)),
			file("bootfs.tar", fmt.tprintf("bootfs.tar of release %d\n", release)),
		),
	)
}

record :: proc(seq: int, tree: string) -> string {
	return fmt.tprintf("release=%d name=test-%d channel=dev commit=test vx-abi=0 unsigned\nset=base arch=x86_64 tree=%s size=500021\nset=base arch=aarch64 tree=%s size=500021\n", seq, seq, tree, tree)
}

// --- Driving distd ---

Client :: struct {
	srv:        p9.Server,
	tbuf, rbuf: [8192]u8,
	c:          p9.Client,
	root:       p9.Fid,
}

connect :: proc(t: ^testing.T, x: ^Client, fs: p9.Fs, supported: p9.Extensions) {
	x.srv = {fs = fs, max_msize = 8192, supported = supported}
	x.c = {rpc = p9test.loopback, ctx = &x.srv, tbuf = x.tbuf[:], rbuf = x.rbuf[:]}
	testing.expect_value(t, p9.client_version(&x.c, 8192, {.Posix, .Xattr}), vx.Status.Ok)
	e: vx.Status
	x.root, e = p9.client_attach(&x.c, "")
	testing.expect_value(t, e, vx.Status.Ok)
}

open_file :: proc(c: ^p9.Client, root: p9.Fid, path: string, mode: p9.Open_Mode) -> (f: p9.Fid, e: vx.Status) {
	f = p9.client_walk(c, root, path) or_return
	if e = p9.client_open(c, f, mode); e != .Ok {
		_ = p9.client_clunk(c, f)
	}
	return
}

// A file's bytes, read whole in the client's message size; or the error.
read_all :: proc(x: ^Client, path: string) -> (data: string, e: vx.Status) {
	f := open_file(&x.c, x.root, path, p9.OREAD) or_return
	defer _ = p9.client_clunk(&x.c, f)
	b := strings.builder_make(context.temp_allocator)
	buf: [8192]u8
	for {
		n := p9.client_read(&x.c, f, u64(strings.builder_len(b)), buf[:]) or_return
		if n == 0 {
			break
		}
		strings.write_bytes(&b, buf[:n])
	}
	return strings.to_string(b), .Ok
}

ctl :: proc(x: ^Client, cmd: string) -> vx.Status {
	f := open_file(&x.c, x.root, "ctl", p9.OWRITE) or_return
	defer _ = p9.client_clunk(&x.c, f)
	_ = p9.client_write(&x.c, f, 0, transmute([]u8)cmd) or_return
	return .Ok
}

read_table :: proc(t: ^testing.T, table: ^slots.Table, loc := #caller_location) {
	text, ok := mem_get("tmp/EFI/vectra/slots.ndb")
	testing.expect(t, ok, loc = loc)
	scratch: [4096]u8
	testing.expect_value(t, slots.parse(table, string(text), scratch[:]), vx.Status.Ok, loc = loc)
}

@(test)
test_distd :: proc(t: ^testing.T) {
	mem_reset()
	big := pattern(300_000, 7, 251)
	other := pattern(200_000, 13, 509)
	tree1 := dir(
		"",
		file("README.txt", "readme\n"),
		file("big.bin", big),
		file("other.bin", other),
		dir("bin", dir("deeper", file("file.txt", "deep\n"))),
		link("readme-link", "README.txt"),
		file("Ünïcode.txt", "unicode\n"),
		slot_dir(1),
	)
	tree2 := dir("", file("README.txt", "release 2\n"), slot_dir(2))
	// Release 3's tree names a file whose objects are not in the store.
	missing := store.text_hash(transmute([]u8)string("not stored"))
	tree3 := dir("", store.Entry{name = "gone", mode = 0o100444, size = 3, hash = missing})
	record1 := record(1, hex_of(tree1.hash))
	mem_put("n/records/1.ndb", transmute([]u8)record1)
	mem_put("n/records/notes.txt", transmute([]u8)string("not a record\n"))
	mem_lookup("adm/ctl", true)
	mem_nodes[mem_lookup("adm/ctl")].ctl = true
	// The ESP as install leaves it: slot a, release 1, booting.
	table: slots.Table
	table.boot = .A
	a := &table.slots[.A]
	a.used, a.release = true, 1
	_ = append(&a.tree, hex_of(tree1.hash))
	for name, i in slots.FILE_NAMES {
		_ = append(&a.hash[i], blake512_hex(transmute([]u8)fmt.tprintf("%s of release 1\n", name)))
	}
	tbuf: [4096]u8
	w := ndb.Writer{buf = tbuf[:]}
	testing.expect(t, slots.print(&table, &w))
	mem_put("tmp/EFI/vectra/slots.ndb", transmute([]u8)ndb.written(&w))
	mem_put("tmp/boot/limine/limine.conf", transmute([]u8)string("# install's\n"))

	// distd's namespace: the memory server at /.
	store_side := new(Client)
	defer free(store_side)
	store_side.srv = {fs = mem_fs, max_msize = 8192}
	store_side.c = {rpc = p9test.loopback, ctx = &store_side.srv, tbuf = store_side.tbuf[:], rbuf = store_side.rbuf[:]}
	testing.expect_value(t, p9.client_version(&store_side.c, 8192, {}), vx.Status.Ok)
	testing.expect_value(t, ns.mount(&distd.space, &store_side.c, vx.HANDLE_NONE, "/srv/fsd", "", "/", {}), vx.Status.Ok)
	rt.spawn.cmdline = "vx.skip=gsh vx.system vx.slot=a"
	kernel_log_len = 0
	distd.start()
	testing.expect_value(t, said(), fmt.tprintf("distd: 1 releases for %s; serving /srv/dist\n", distd.ARCH))

	x := new(Client)
	defer free(x)
	connect(t, x, distd.server.fs, distd.server.supported)
	testing.expect_value(t, x.c.extensions, p9.Extensions{.Posix, .Xattr})
	_, e := p9.client_attach(&x.c, "store")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)

	// /dist and its files.
	testing.expect_value(t, p9test.list(&x.c, x.root, ""), "status ctl releases store")
	status, st := read_all(x, "status")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, status, fmt.tprintf("state=idle releases=1 arch=%s current=1 slot=a boot=1\n", distd.ARCH))
	testing.expect_value(t, p9test.list(&x.c, x.root, "releases"), "1")
	testing.expect_value(t, p9test.list(&x.c, x.root, "releases/1"), "record status tree")
	got: string
	got, st = read_all(x, "releases/1/record")
	testing.expect_value(t, got, record1)
	got, _ = read_all(x, "releases/1/status")
	testing.expect_value(t, got, "state=fetched missing=0\n")
	s: p9.Stat
	Stat_Case :: struct {
		path:   string,
		name:   string,
		mode:   u32,
		length: u64,
	}
	for c in ([]Stat_Case {
			{"", "/", p9.DMDIR | 0o555, 0},
			{"status", "status", 0o444, 0},
			{"ctl", "ctl", 0o220, 0},
			{"releases/1", "1", p9.DMDIR | 0o555, 0},
			{"releases/1/record", "record", 0o444, u64(len(record1))},
			{"releases/1/tree", "tree", p9.DMDIR | 0o555, 0},
			{"releases/1/tree/big.bin", "big.bin", 0o444, 300_000},
			{"releases/1/tree/bin", "bin", p9.DMDIR | 0o555, 0},
			{"releases/1/tree/readme-link", "readme-link", p9.DMSYMLINK | 0o777, 0},
			{"store", "store", p9.DMDIR | 0o555, 0},
		}) {
		testing.expectf(t, p9test.stat_of(&x.c, x.root, c.path, &s) == .Ok, "stat %q", c.path)
		testing.expectf(t, s.name == c.name, "stat %q: name %q", c.path, s.name)
		testing.expectf(t, s.mode == c.mode, "stat %q: mode %o", c.path, s.mode)
		testing.expectf(t, s.length == c.length, "stat %q: length %d", c.path, s.length)
		testing.expectf(t, s.uid == "dist", "stat %q: uid %q", c.path, s.uid)
	}
	for bad in ([]string{"releases/2", "releases/01", "releases/x", "nope", "releases/1/tree/nope", "store/b3"}) {
		_, e = p9.client_walk(&x.c, x.root, bad)
		testing.expectf(t, e == .Err_Not_Found, "walk %q: %v", bad, e)
	}
	_, e = open_file(&x.c, x.root, "ctl", p9.OREAD)
	testing.expect_value(t, e, vx.Status.Err_Access)
	_, e = open_file(&x.c, x.root, "status", p9.OWRITE)
	testing.expect_value(t, e, vx.Status.Err_Access)

	// The tree, through verified reads.
	r := "releases/1/tree"
	testing.expect_value(t, p9test.list(&x.c, x.root, r), "README.txt big.bin bin boot other.bin readme-link Ünïcode.txt")
	got, _ = read_all(x, fmt.tprintf("%s/README.txt", r))
	testing.expect_value(t, got, "readme\n")
	got, _ = read_all(x, fmt.tprintf("%s/bin/deeper/file.txt", r))
	testing.expect_value(t, got, "deep\n")
	got, _ = read_all(x, fmt.tprintf("%s/Ünïcode.txt", r))
	testing.expect_value(t, got, "unicode\n")
	got, st = read_all(x, fmt.tprintf("%s/big.bin", r))
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, got == big, "big.bin reads as it was stored")
	f: p9.Fid
	f, e = open_file(&x.c, x.root, fmt.tprintf("%s/big.bin", r), p9.OREAD)
	buf: [200]u8
	n: int
	n, e = p9.client_read(&x.c, f, 65_500, buf[:]) // across a block's end
	testing.expect_value(t, n, 200)
	testing.expect(t, string(buf[:n]) == big[65_500:][:200], "a read across blocks")
	n, e = p9.client_read(&x.c, f, 299_950, buf[:])
	testing.expect_value(t, n, 50)
	n, e = p9.client_read(&x.c, f, 300_000, buf[:])
	testing.expect_value(t, n, 0)
	_ = p9.client_clunk(&x.c, f)
	f, _ = p9.client_walk(&x.c, x.root, fmt.tprintf("%s/readme-link", r))
	target: string
	target, e = p9.client_readlink(&x.c, f)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, target, "README.txt")
	_ = p9.client_clunk(&x.c, f)

	// The store's objects as they are: b2 alone at the top, not records/.
	testing.expect_value(t, p9test.list(&x.c, x.root, "store"), "b2")
	readme := store.path(put_file(transmute([]u8)string("readme\n")))
	got, st = read_all(x, fmt.tprintf("store/%s", string(readme[:])))
	testing.expect_value(t, st, vx.Status.Ok)
	raw, _ := mem_get(fmt.tprintf("n/%s", string(readme[:])))
	testing.expect(t, got == string(raw), "an object reads as the store has it")
	testing.expect_value(t, said(), "")

	// ctl: rescan finds a record added; what it does not know is refused.
	testing.expect_value(t, ctl(x, "frobnicate"), vx.Status.Err_Invalid)
	testing.expect_value(t, ctl(x, "apply 1x"), vx.Status.Err_Invalid)
	mem_put("n/records/2.ndb", transmute([]u8)record(2, hex_of(tree2.hash)))
	mem_put("n/records/3.ndb", transmute([]u8)record(3, hex_of(tree3.hash)))
	testing.expect_value(t, ctl(x, "rescan\n"), vx.Status.Ok)
	testing.expect_value(t, p9test.list(&x.c, x.root, "releases"), "1 2 3")

	// apply: a release that is not there, one not whole, then release 2.
	testing.expect_value(t, ctl(x, "apply 9"), vx.Status.Err_Not_Found)
	testing.expect_value(t, said(), fmt.tprintf("distd: apply: no such release: %s\n", p9.error_text(.Err_Not_Found)))
	testing.expect_value(t, ctl(x, "apply 3"), vx.Status.Err_Not_Found)
	testing.expect_value(t, said(), fmt.tprintf("distd: release 3 is not whole and sound in the store (%s): not applied\n", p9.error_text(.Err_Not_Found)))
	testing.expect_value(t, len(ctl_log), 0)
	testing.expect_value(t, ctl(x, "apply 2\n"), vx.Status.Ok)
	testing.expect_value(t, said(), "distd: release 2 staged: the next boot is its slot's\n")
	testing.expect_value(t, len(ctl_log), 2)
	if len(ctl_log) == 2 {
		testing.expect_value(t, ctl_log[0], "del cfg@apply-2")
		testing.expect_value(t, ctl_log[1], "snap cfg cfg@apply-2")
	}
	read_table(t, &table)
	testing.expect_value(t, table.boot, slots.Name.B)
	testing.expect_value(t, table.previous, slots.Name.A)
	b := &table.slots[.B]
	testing.expect_value(t, b.release, 2)
	testing.expect_value(t, string(b.tree[:]), hex_of(tree2.hash))
	testing.expect_value(t, string(table.cmdline[:]), "")
	for name, i in slots.FILE_NAMES {
		want := fmt.tprintf("%s of release 2\n", name)
		data, ok := mem_get(fmt.tprintf("tmp/EFI/vectra/b/%s", name))
		testing.expectf(t, ok && string(data) == want, "slot b's %s", name)
		testing.expectf(t, string(b.hash[i][:]) == blake512_hex(transmute([]u8)want), "slot b's %s hash", name)
	}
	conf_buf: [4096]u8
	conf, _ := slots.limine(&table, conf_buf[:])
	written, _ := mem_get("tmp/boot/limine/limine.conf")
	testing.expect_value(t, string(written), conf)
	testing.expect(t, strings.contains(conf, "default_entry: 2\n"), "slot b is Limine's default")
	got, _ = read_all(x, "status")
	testing.expect_value(t, got, fmt.tprintf("state=idle releases=3 arch=%s current=1 slot=a boot=2\n", distd.ARCH))
	// No free slot: a and b are boot and previous, c is free; after c,
	// none is.
	testing.expect_value(t, ctl(x, "apply 1"), vx.Status.Ok)
	testing.expect_value(t, said(), "distd: release 1 staged: the next boot is its slot's\n")
	testing.expect_value(t, ctl(x, "apply 2"), vx.Status.Ok) // into a, which is neither boot (c) nor previous (b)
	testing.expect_value(t, said(), "distd: release 2 staged: the next boot is its slot's\n")
	read_table(t, &table)
	testing.expect_value(t, table.boot, slots.Name.A)
	testing.expect_value(t, table.previous, slots.Name.C)

	// rollback: the previous slot boots again, /cfg rolled back to the
	// snapshot taken when the release being left was applied.
	clear(&ctl_log)
	testing.expect_value(t, ctl(x, "rollback"), vx.Status.Ok)
	testing.expect_value(t, said(), "distd: rolled back: the next boot is release 1's slot\n")
	testing.expect_value(t, len(ctl_log), 1)
	if len(ctl_log) == 1 {
		testing.expect_value(t, ctl_log[0], "rollback cfg cfg@apply-2")
	}
	read_table(t, &table)
	testing.expect_value(t, table.boot, slots.Name.C)
	testing.expect_value(t, table.previous, slots.Name.A)
	ctl_status = .Err_Not_Found // no such snapshot
	testing.expect_value(t, ctl(x, "rollback"), vx.Status.Ok)
	testing.expect_value(t, said(), "distd: no snapshot of /cfg to roll back to\ndistd: rolled back: the next boot is release 2's slot\n")
	testing.expect_value(t, ctl(x, "apply 3"), vx.Status.Err_Not_Found) // still not whole
	_ = said()
	ctl_status = .Ok

	// Damage: other.bin's second block, never read before, rewritten in the
	// store; and a file's index. Each read is refused and said once.
	ob := store.leaf(transmute([]u8)other[store.BLOCK:][:store.BLOCK])
	op := store.path(ob)
	mem_put(fmt.tprintf("n/%s", string(op[:])), transmute([]u8)string("not the block\n"))
	_, st = read_all(x, fmt.tprintf("%s/other.bin", r))
	testing.expect_value(t, st, vx.Status.Err_Io)
	testing.expect_value(t, said(), "distd: a block does not match its hash: /other.bin (refused)\n")
	got, st = read_all(x, fmt.tprintf("%s/README.txt", r))
	testing.expect_value(t, got, "readme\n")
	// A file's index, long gone from the cache (apply read many objects
	// since): read again, and refused.
	deep := put_file(transmute([]u8)string("deep\n"))
	dp := store.path(deep)
	mem_put(fmt.tprintf("n/%s", string(dp[:])), transmute([]u8)string("vxsf, not an index"))
	_, st = read_all(x, fmt.tprintf("%s/bin/deeper/file.txt", r))
	testing.expect_value(t, st, vx.Status.Err_Io)
	testing.expect_value(t, said(), "distd: a file's index does not match its hash: /bin/deeper/file.txt (refused)\n")
	// Release 1 is no longer whole: apply checks every object first.
	testing.expect_value(t, ctl(x, "apply 1"), vx.Status.Err_Io)
	testing.expect_value(t, said(), fmt.tprintf("distd: release 1 is not whole and sound in the store (%s): not applied\n", p9.error_text(.Err_Io)))

	// A release whose root directory's object is not in the store: seen,
	// not fetched.
	mem_put("n/records/4.ndb", transmute([]u8)record(4, hex_of(missing)))
	testing.expect_value(t, ctl(x, "rescan"), vx.Status.Ok)
	got, _ = read_all(x, "releases/4/status")
	testing.expect_value(t, got, "state=seen missing=1\n")
	got, _ = read_all(x, "releases/3/status")
	testing.expect_value(t, got, "state=fetched missing=0\n")
	_, e = p9.client_walk(&x.c, x.root, "releases/4/tree/README.txt")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	testing.expect_value(t, said(), "")
}
