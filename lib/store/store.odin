// The content store's objects and tree format (upstream's docs/06 §4, M5
// step 9a), shared by distd, install and tools/vxstore. Pure code over
// Monocypher's BLAKE2b (vx:crypto, ADR-0011), so the host's tests run it too.
//
// Every object is named by a BLAKE2b-256 hash, written b2:<64 hex>, and
// stored as b2/<first two hex>/<all 64 hex> under the store's root. Three
// kinds:
//
// - A block: up to 64 KiB of a file. Its name is the leaf hash
//   BLAKE2b(0x00 || bytes).
// - A file's index: "vxsf", the file's size (u64, little-endian), then the
//   hash of each of its blocks (one block, empty, for an empty file). Its
//   name, which is the file's hash, is BLAKE2b(0x02 || size || root): the
//   size, and the root of a hash tree over those block hashes, shaped as
//   RFC 6962's (split at the largest power of two below the count), each
//   inner node BLAKE2b(0x01 || left || right). So a reader checks the index
//   against its name once, then any block against the index on its own.
// - A directory: ndb text, one record per entry, sorted by name (bytes),
//   in one canonical form (dir_put's):
//     name=bin mode=040555 hash=b2:...
//     name=svcd mode=0555 size=394632 hash=b2:...
//     name=sh mode=0120777 link=/bin/rc
//   Its name is BLAKE2b(text), as doc 06 has it. A tree's hash is its root
//   directory's.
//
// The prefixes keep a leaf from passing for an inner node; a directory's
// text never starts with 0x00 or 0x01, so it cannot pass for either.
package store

import vx "abi:vx"
import "vx:crypto"
import "vx:ndb"

BLOCK :: 65536 // the largest block, and every block of a file but its last
HASH :: 32 // bytes in a hash
HEX :: 3 + 2 * HASH // "b2:" and the hash in hex
PATH :: 3 + 3 + 2 * HASH // "b2/9f/" and the hash in hex
INDEX_HEAD :: 12 // "vxsf" and the size
MAX_SIZE :: u64(1) << 48 // the largest file an index may describe

Hash :: distinct [HASH]u8

// POSIX's file types, in an entry's mode.
MODE_TYPE :: 0o170000
MODE_DIR :: 0o040000
MODE_FILE :: 0o100000
MODE_LINK :: 0o120000

// --- Hashes ---

leaf :: proc "contextless" (data: []u8) -> (h: Hash) {
	prefix := [1]u8{0x00}
	b: crypto.Blake2b
	crypto.blake2b_begin(&b, HASH)
	crypto.blake2b_add(&b, prefix[:])
	crypto.blake2b_add(&b, data)
	crypto.blake2b_end(&b, h[:])
	return
}

node :: proc "contextless" (l, r: Hash) -> (h: Hash) {
	l, r := l, r
	prefix := [1]u8{0x01}
	b: crypto.Blake2b
	crypto.blake2b_begin(&b, HASH)
	crypto.blake2b_add(&b, prefix[:])
	crypto.blake2b_add(&b, l[:])
	crypto.blake2b_add(&b, r[:])
	crypto.blake2b_end(&b, h[:])
	return
}

// The root over leaf hashes stored as an index has them, HASH bytes each, at
// least one. Recursion is as deep as the tree, log2 of the count: 33 levels
// for the largest file.
root :: proc "contextless" (leaves: []u8) -> (h: Hash) {
	n := len(leaves) / HASH
	if n <= 1 {
		copy(h[:], leaves)
		return
	}
	k := 1
	for k * 2 < n {
		k *= 2 // the largest power of two below n
	}
	return node(root(leaves[:k * HASH]), root(leaves[k * HASH:n * HASH]))
}

// A file's hash: its size and its blocks' root, bound together.
file_hash :: proc "contextless" (size: u64, root: Hash) -> (h: Hash) {
	root := root
	head := [9]u8{0 = 0x02}
	for i in 0 ..< 8 {
		head[1 + i] = u8(size >> (8 * uint(i)))
	}
	b: crypto.Blake2b
	crypto.blake2b_begin(&b, HASH)
	crypto.blake2b_add(&b, head[:])
	crypto.blake2b_add(&b, root[:])
	crypto.blake2b_end(&b, h[:])
	return
}

// The plain hash of an object's bytes: a directory's name.
text_hash :: proc "contextless" (text: []u8) -> (h: Hash) {
	crypto.blake2b(h[:], text)
	return
}

// --- Names ---

@(private="file")
DIGITS := "0123456789abcdef"

// "b2:" and the hash in lower-case hex; string(out[:]) is the name.
hex :: proc "contextless" (h: Hash) -> (out: [HEX]u8) {
	copy(out[:], "b2:")
	for b, i in h {
		out[3 + 2 * i] = DIGITS[b >> 4]
		out[4 + 2 * i] = DIGITS[b & 15]
	}
	return
}

// "b2:<64 lower-case hex>" as a hash; ok is false if it is not one.
@(require_results)
parse :: proc "contextless" (s: string) -> (h: Hash, ok: bool) {
	if len(s) != HEX || s[:3] != "b2:" {
		return
	}
	for i in 0 ..< 2 * HASH {
		c := s[3 + i]
		d: u8
		switch c {
		case '0' ..= '9':
			d = c - '0'
		case 'a' ..= 'f':
			d = c - 'a' + 10
		case:
			return {}, false
		}
		h[i / 2] |= i % 2 == 0 ? d << 4 : d
	}
	return h, true
}

// The object's path under the store's root, "b2/9f/9f3c...": string(out[:]).
path :: proc "contextless" (h: Hash) -> (out: [PATH]u8) {
	x := hex(h)
	copy(out[:], "b2/")
	copy(out[3:], x[3:5])
	out[5] = '/'
	copy(out[6:], x[3:])
	return
}

// --- Files ---

// How many blocks a file of size bytes has: one, empty, if it is empty.
blocks :: proc "contextless" (size: u64) -> u64 {
	return size == 0 ? 1 : (size - 1) / BLOCK + 1
}

// A checked index: the file's size, and its block hashes (HASH bytes each),
// pointing into the index object.
Index :: struct {
	size:   u64,
	hashes: []u8,
}

// The number of blocks an index holds hashes for.
index_blocks :: proc "contextless" (x: Index) -> u64 {
	return u64(len(x.hashes) / HASH)
}

// A file's index checked against its name. .Err_Invalid if it is not an
// index; .Err_Io if it is one that does not hash to the name (corrupt, or not
// the object asked for).
@(require_results)
index_check :: proc "contextless" (name: Hash, obj: []u8) -> (x: Index, st: vx.Status) {
	if len(obj) < INDEX_HEAD || string(obj[:4]) != "vxsf" {
		return {}, .Err_Invalid
	}
	size: u64
	for i := 7; i >= 0; i -= 1 {
		size = size << 8 | u64(obj[4 + i])
	}
	if size > MAX_SIZE || u64(len(obj)) != INDEX_HEAD + blocks(size) * HASH {
		return {}, .Err_Invalid // blocks(size) * HASH stays far below 2^64 for size <= MAX_SIZE
	}
	hashes := obj[INDEX_HEAD:]
	if file_hash(size, root(hashes)) != name {
		return {}, .Err_Io
	}
	return {size, hashes}, .Ok
}

// Block i of a file checked against its index: .Err_Range if there is no
// such block, .Err_Io if data is not it.
@(require_results)
block_check :: proc "contextless" (x: Index, i: u64, data: []u8) -> vx.Status {
	n := index_blocks(x)
	if i >= n {
		return .Err_Range
	}
	want := i + 1 < n ? BLOCK : x.size - i * BLOCK
	if u64(len(data)) != want {
		return .Err_Io
	}
	h := leaf(data)
	return string(h[:]) == string(x.hashes[i * HASH:][:HASH]) ? .Ok : .Err_Io
}

// The head of an index for a file of size bytes; its block hashes follow.
index_head :: proc "contextless" (size: u64) -> (out: [INDEX_HEAD]u8) {
	copy(out[:], "vxsf")
	for i in 0 ..< 8 {
		out[4 + i] = u8(size >> (8 * uint(i)))
	}
	return
}

// --- Directories ---

Entry :: struct {
	name: string,
	mode: u32, // POSIX: type bits and permissions (0o040555 a directory, 0o120777 a link)
	size: u64, // a file's
	hash: Hash, // a file's or a directory's
	link: string, // a link's target
}

is_dir :: proc "contextless" (e: Entry) -> bool {
	return e.mode & MODE_TYPE == MODE_DIR
}

is_link :: proc "contextless" (e: Entry) -> bool {
	return e.mode & MODE_TYPE == MODE_LINK
}

// An entry's record, canonical: name, mode (octal, with a leading 0), size
// (files), hash or link. False if the record must not be used.
@(require_results)
dir_put :: proc "contextless" (w: ^ndb.Writer, e: Entry) -> bool {
	digits: [12]u8
	i := len(digits)
	m := e.mode
	for {
		i -= 1
		digits[i] = u8('0' + (m & 7))
		m >>= 3
		if m == 0 {
			break
		}
	}
	i -= 1
	digits[i] = '0'
	ndb.put(w, "name", e.name)
	ndb.put(w, "mode", string(digits[i:]))
	if is_link(e) {
		ndb.put(w, "link", e.link)
	} else {
		x := hex(e.hash)
		if !is_dir(e) {
			ndb.put_u64(w, "size", e.size)
		}
		ndb.put(w, "hash", string(x[:]))
	}
	return ndb.end(w)
}

// An entry from a directory's record: .Err_Invalid if the record is not one.
// Its strings point where the record's values do (the reader's input or
// scratch).
@(require_results)
dir_entry :: proc "contextless" (rec: ^ndb.Record) -> (e: Entry, st: vx.Status) {
	e.name, _ = ndb.get(rec, "name")
	mode, _ := ndb.get(rec, "mode")
	if len(e.name) == 0 || len(mode) < 2 || len(mode) > 7 || mode[0] != '0' {
		return {}, .Err_Invalid
	}
	for i in 0 ..< len(e.name) {
		if e.name[i] == '/' || e.name[i] == 0 {
			return {}, .Err_Invalid
		}
	}
	if e.name == "." || e.name == ".." {
		return {}, .Err_Invalid
	}
	for i in 1 ..< len(mode) {
		if mode[i] < '0' || mode[i] > '7' {
			return {}, .Err_Invalid
		}
		e.mode = e.mode << 3 | u32(mode[i] - '0')
	}
	switch e.mode & MODE_TYPE {
	case MODE_LINK:
		e.link, _ = ndb.get(rec, "link")
		if len(e.link) == 0 {
			return {}, .Err_Invalid
		}
		return e, .Ok
	case MODE_DIR, MODE_FILE:
	case:
		return {}, .Err_Invalid
	}
	hash, _ := ndb.get(rec, "hash")
	ok: bool
	if e.hash, ok = parse(hash); !ok {
		return {}, .Err_Invalid
	}
	if e.mode & MODE_TYPE == MODE_FILE {
		if e.size, ok = ndb.get_u64(rec, "size"); !ok {
			return {}, .Err_Invalid
		}
	}
	return e, .Ok
}

// A directory object checked against its name: .Err_Io if it does not hash to it.
@(require_results)
dir_check :: proc "contextless" (name: Hash, text: []u8) -> vx.Status {
	return text_hash(text) == name ? .Ok : .Err_Io
}

// The entry named name in a directory's text (checked already):
// .Err_Not_Found if there is none, .Err_Invalid if a record is not an entry
// or the text is not ndb. scratch holds the values the reader decodes.
@(require_results)
dir_find :: proc "contextless" (text: []u8, name: string, scratch: []u8) -> (e: Entry, st: vx.Status) {
	r := ndb.Reader {
		src     = string(text),
		scratch = scratch,
	}
	rec: ndb.Record
	for {
		switch ndb.next(&r, &rec) {
		case .Record:
			e = dir_entry(&rec) or_return
			if e.name == name {
				return e, .Ok
			}
		case .End:
			return {}, .Err_Not_Found
		case .Error:
			return {}, .Err_Invalid
		}
	}
}
