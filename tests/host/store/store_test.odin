// lib/store (upstream's docs/06 §4), ported from upstream's
// tests/host/store_test.c. Monocypher as linked through vx:crypto, against
// RFC 7693's BLAKE2b-512("abc") and RFC 8032's first Ed25519 vector; the hash
// tree's shape (RFC 6962's split) for one to five leaves; a file's index
// checked whole and each block against it, and refused when a hash, a length
// or the size is wrong; directories written canonically and read back, names
// with spaces and quotes included, and records that are not entries refused,
// a key store(6) does not name among them; a release record's keys; and one
// small tree's hash, fixed, so the format cannot drift unnoticed (the
// same value upstream's C prints).
// host-links: monocypher
package store_test

import "core:encoding/hex"
import "core:testing"
import vx "abi:vx"
import "vx:crypto"
import "vx:ndb"
import "vx:store"

FIXED_TREE :: "b2:504f0b421e49fbf7de23620bb329b15884cd839c21bf77c70604f5adbce868b0"

unhex :: proc(s: string, out: []u8) {
	b, ok := hex.decode(transmute([]u8)s, context.temp_allocator)
	assert(ok && len(b) == len(out))
	copy(out, b)
}

@(test)
test_monocypher :: proc(t: ^testing.T) {
	h, want: [64]u8
	crypto.blake2b(h[:], transmute([]u8)string("abc"))
	unhex("ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1" + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923", want[:])
	testing.expect_value(t, h, want)
	// The incremental form agrees, in any pieces.
	b: crypto.Blake2b
	crypto.blake2b_begin(&b, 64)
	crypto.blake2b_add(&b, transmute([]u8)string("a"))
	crypto.blake2b_add(&b, nil)
	crypto.blake2b_add(&b, transmute([]u8)string("bc"))
	crypto.blake2b_end(&b, h[:])
	testing.expect_value(t, h, want)
	pk: [32]u8
	sig: [64]u8
	unhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", pk[:])
	unhex(
		"e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25b" + "f5f0595bbe24655141438e7a100b",
		sig[:],
	)
	testing.expect(t, crypto.ed25519_check(&sig, &pk, nil))
	sig[0] ~= 1
	testing.expect(t, !crypto.ed25519_check(&sig, &pk, nil))
}

@(test)
test_tree_shape :: proc(t: ^testing.T) {
	leaves: [5 * store.HASH]u8
	l: [5]store.Hash
	for i in 0 ..< 5 {
		b := [1]u8{u8(i)}
		l[i] = store.leaf(b[:])
		copy(leaves[store.HASH * i:], l[i][:])
	}
	// The leaf prefix: BLAKE2b(0x00 || 0x00) for the one-byte block {0}.
	raw := [2]u8{0, 0}
	want: store.Hash
	crypto.blake2b(want[:], raw[:])
	testing.expect_value(t, l[0], want)
	testing.expect_value(t, store.root(leaves[:1 * store.HASH]), l[0])
	ab := store.node(l[0], l[1])
	testing.expect_value(t, store.root(leaves[:2 * store.HASH]), ab)
	abc := store.node(ab, l[2]) // 3 = 2 + 1
	testing.expect_value(t, store.root(leaves[:3 * store.HASH]), abc)
	cd := store.node(l[2], l[3])
	abcd := store.node(ab, cd)
	abcde := store.node(abcd, l[4]) // 5 = 4 + 1
	testing.expect_value(t, store.root(leaves[:5 * store.HASH]), abcde)
	testing.expect(t, store.node(l[1], l[0]) != ab) // order matters
}

// An index for data, as tools/vxstore makes one.
make_index :: proc(data: []u8) -> (idx: []u8, name: store.Hash) {
	size := u64(len(data))
	n := store.blocks(size)
	idx = make([]u8, store.INDEX_HEAD + n * store.HASH)
	head := store.index_head(size)
	copy(idx, head[:])
	for i in 0 ..< n {
		at := i * store.BLOCK
		h := store.leaf(data[at:min(at + store.BLOCK, size)])
		copy(idx[store.INDEX_HEAD + i * store.HASH:], h[:])
	}
	name = store.file_hash(size, store.root(idx[store.INDEX_HEAD:]))
	return
}

@(test)
test_files :: proc(t: ^testing.T) {
	data := make([]u8, 200_000)
	defer delete(data)
	for &b, i in data {
		b = u8(i * 31 + i / 997)
	}
	idx, name := make_index(data)
	defer delete(idx)
	x, st := store.index_check(name, idx)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, x.size, u64(len(data)))
	testing.expect_value(t, store.index_blocks(x), 4)
	for i in 0 ..< store.index_blocks(x) {
		at := i * store.BLOCK
		testing.expect_value(t, store.block_check(x, i, data[at:min(at + store.BLOCK, x.size)]), vx.Status.Ok)
	}
	data[70_000] ~= 1 // block 1 changed
	testing.expect_value(t, store.block_check(x, 1, data[store.BLOCK:][:store.BLOCK]), vx.Status.Err_Io)
	testing.expect_value(t, store.block_check(x, 3, data[3 * store.BLOCK:][:100]), vx.Status.Err_Io) // short
	testing.expect_value(t, store.block_check(x, 4, data[:1]), vx.Status.Err_Range)
	Case :: struct {
		at:   int,
		want: vx.Status,
		why:  string,
	}
	for c in ([]Case {
			{store.INDEX_HEAD + 40, .Err_Io, "a block hash changed: the index no longer hashes to its name"},
			{4, .Err_Io, "the size changed by one, the block count not: the name binds the size"},
			{6, .Err_Invalid, "by 65536: the count no longer matches the hashes"},
		}) {
		idx[c.at] ~= 1
		_, st = store.index_check(name, idx)
		testing.expectf(t, st == c.want, "%s: got %v", c.why, st)
		idx[c.at] ~= 1
	}
	_, st = store.index_check(name, idx[:len(idx) - 1])
	testing.expect_value(t, st, vx.Status.Err_Invalid)
	_, st = store.index_check(name, transmute([]u8)string("vxs"))
	testing.expect_value(t, st, vx.Status.Err_Invalid)
	// An empty file: one empty block.
	empty, empty_name := make_index(nil)
	defer delete(empty)
	x, st = store.index_check(empty_name, empty)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, x.size, 0)
	testing.expect_value(t, store.index_blocks(x), 1)
	testing.expect_value(t, store.block_check(x, 0, data[:0]), vx.Status.Ok)
}

@(test)
test_dirs :: proc(t: ^testing.T) {
	h: store.Hash = 0xab
	entries := []store.Entry {
		{name = "bin", mode = 0o040555, hash = h},
		{name = "a file \"quoted\"", mode = 0o100444, size = 12, hash = h},
		{name = "sh", mode = 0o120777, link = "/bin/rc"},
	}
	text: [4096]u8
	w := ndb.Writer {
		buf = text[:],
	}
	for e in entries {
		testing.expect(t, store.dir_put(&w, e))
	}
	testing.expect(t, !w.failed)
	want :=
		"name=bin mode=040555 hash=b2:abababababababababababababababababababababababababababababababab\n" +
		"name=\"a file \"\"quoted\"\"\" mode=0100444 size=12 " +
		"hash=b2:abababababababababababababababababababababababababababababababab\n" +
		"name=sh mode=0120777 link=/bin/rc\n"
	testing.expect_value(t, ndb.written(&w), want)
	dir := text[:w.len]
	scratch: [4096]u8
	e, st := store.dir_find(dir, "a file \"quoted\"", scratch[:])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, e.size, 12)
	testing.expect_value(t, e.mode, 0o100444)
	testing.expect_value(t, e.hash, h)
	e, st = store.dir_find(dir, "sh", scratch[:])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, store.is_link(e))
	testing.expect_value(t, e.link, "/bin/rc")
	e, st = store.dir_find(dir, "bin", scratch[:])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, store.is_dir(e))
	_, st = store.dir_find(dir, "nothing", scratch[:])
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	name := store.text_hash(dir)
	testing.expect_value(t, store.dir_check(name, dir), vx.Status.Ok)
	text[0] ~= 1
	testing.expect_value(t, store.dir_check(name, dir), vx.Status.Err_Io)

	// Records that are not entries.
	bad := []string {
		"name=x mode=0100444 hash=b2:ab\n", // a short hash
		"name=x mode=100444 size=1 hash=b2:abababababababababababababababababababababababababababababababab\n", // no 0
		"name=x mode=0100448 size=1 hash=b2:abababababababababababababababababababababababababababababababab\n", // 8
		"name=a/b mode=0100444 size=1 hash=b2:abababababababababababababababababababababababababababababababab\n",
		"name=.. mode=040555 hash=b2:abababababababababababababababababababababababababababababababab\n",
		"name=x mode=0100444 hash=b2:abababababababababababababababababababababababababababababababab\n", // no size
		"name=x mode=0120777\n", // no target
		"name=x mode=060644 hash=b2:abababababababababababababababababababababababababababababababab\n", // a device
		"name=x mode=0100444 size=1 hash=b2:ABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABABAB\n",
		"name=x mode=0100444 size=1 owner=adm hash=b2:abababababababababababababababababababababababababababababababab\n", // a key not in store(6)
	}
	for b in bad {
		_, st = store.dir_find(transmute([]u8)b, "y", scratch[:])
		testing.expectf(t, st == .Err_Invalid, "%q: got %v", b, st)
	}

	// A release record's keys (release(6)).
	rs: [256]u8
	r := ndb.Reader{src = "release=3 name=x unsigned set=base", scratch = rs[:]}
	rec: ndb.Record
	testing.expect_value(t, ndb.next(&r, &rec), ndb.Result.Record)
	testing.expect(t, store.release_known(&rec))
	r = ndb.Reader{src = "release=3 expires=9", scratch = rs[:]}
	testing.expect_value(t, ndb.next(&r, &rec), ndb.Result.Record)
	testing.expect(t, !store.release_known(&rec))

	// Paths and names.
	path := store.path(h)
	testing.expect_value(t, string(path[:]), "b2/ab/abababababababababababababababababababababababababababababababab")
	x := store.hex(h)
	back, ok := store.parse(string(x[:]))
	testing.expect(t, ok)
	testing.expect_value(t, back, h)
}

// One small tree, its hash fixed: a directory holding "hello\n" as hello.txt
// and an empty directory. If this changes, the format changed.
@(test)
test_fixed_tree :: proc(t: ^testing.T) {
	idx, file := make_index(transmute([]u8)string("hello\n"))
	delete(idx)
	empty := store.text_hash(nil)
	text: [512]u8
	w := ndb.Writer {
		buf = text[:],
	}
	testing.expect(t, store.dir_put(&w, {name = "empty", mode = 0o040555, hash = empty}))
	testing.expect(t, store.dir_put(&w, {name = "hello.txt", mode = 0o100444, size = 6, hash = file}))
	x := store.hex(store.text_hash(text[:w.len]))
	testing.expect_value(t, string(x[:]), FIXED_TREE)
}
