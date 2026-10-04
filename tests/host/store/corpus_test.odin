// Upstream's content-store fuzzer (tests/fuzz/store_fuzz.c) over its corpus
// (tests/fuzz/corpus/store), and over hostile variants: arbitrary bytes as
// objects, as distd and install meet them from untrusted peers and media
// (upstream's 06 §6). As a directory: every entry found must be one (a name
// without '/', a known type, a hash or a target). As a file's index: one
// that checks must have as many hashes as its size has blocks, inside the
// input. As a block of such a file: it is checked, and only a block of the
// right length can pass.
package store_test

import "core:testing"
import "vx:store"

CORPUS := #load_directory("corpus")

@(private="file")
store_fuzz :: proc(t: ^testing.T, name: string, data: []u8) {
	scratch := make([]u8, 1 << 16)
	defer delete(scratch)
	for want in ([]string{"bin", "a", ""}) {
		e, st := store.dir_find(data, want, scratch)
		if st != .Ok {
			continue
		}
		for i in 0 ..< len(e.name) {
			testing.expectf(t, e.name[i] != '/', "%s: %q has a '/'", name, e.name)
		}
		type := e.mode & store.MODE_TYPE
		testing.expectf(t, type == store.MODE_DIR || type == store.MODE_FILE || type == store.MODE_LINK, "%s: %q is of type %o", name, e.name, type)
		testing.expectf(t, type != store.MODE_LINK || len(e.link) > 0, "%s: %q links to nothing", name, e.name)
	}
	// As an index named by its own computed hash (so the check can pass).
	if len(data) >= store.INDEX_HEAD && string(data[:4]) == "vxsf" {
		size: u64
		for i := 7; i >= 0; i -= 1 {
			size = size << 8 | u64(data[4 + i])
		}
		hash: store.Hash
		if size <= store.MAX_SIZE && u64(len(data)) == store.INDEX_HEAD + store.blocks(size) * store.HASH {
			hash = store.file_hash(size, store.root(data[store.INDEX_HEAD:]))
		}
		if x, st := store.index_check(hash, data); st == .Ok {
			n := store.index_blocks(x)
			testing.expectf(t, n == store.blocks(x.size), "%s: %d hashes for %d bytes", name, n, x.size)
			testing.expectf(t, raw_data(x.hashes[len(x.hashes):]) == raw_data(data[len(data):]), "%s: the hashes do not end the input", name)
			// The input itself as each block: only one of the right length can pass.
			for i in 0 ..< min(n, 4) {
				want := i + 1 < n ? store.BLOCK : x.size - i * store.BLOCK
				if store.block_check(x, i, data) == .Ok {
					testing.expectf(t, u64(len(data)) == want, "%s: block %d of the wrong length passed", name, i)
				}
			}
		}
	}
	_ = store.dir_check({}, data)
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	testing.expect_value(t, len(CORPUS), 1)
	for file in CORPUS {
		store_fuzz(t, file.name, file.data)
	}
}

// Not upstream's corpus: the directory cut at every byte and with every byte
// flipped in turn, and an index for a two-block file the same way.
@(test)
test_mutants :: proc(t: ^testing.T) {
	data := make([]u8, len(CORPUS[0].data))
	defer delete(data)
	copy(data, CORPUS[0].data)
	for cut in 0 ..< len(data) {
		store_fuzz(t, "cut", data[:cut])
	}
	for at in 0 ..< len(data) {
		data[at] ~= 0x20
		store_fuzz(t, "flipped", data)
		data[at] ~= 0x20
	}
	file := make([]u8, store.BLOCK + 10)
	defer delete(file)
	idx, _ := make_index(file)
	defer delete(idx)
	for cut in 0 ..< len(idx) {
		store_fuzz(t, "index cut", idx[:cut])
	}
	for at in 0 ..< len(idx) {
		idx[at] ~= 0x01
		store_fuzz(t, "index flipped", idx)
		idx[at] ~= 0x01
	}
}
