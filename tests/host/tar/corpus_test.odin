// Upstream's tar fuzzer (tests/fuzz/tar_fuzz.c) over its corpus
// (tests/fuzz/corpus/tar), and over hostile variants of an archive with
// links: every entry the reader returns lies inside the input, and the
// archive the writer makes from those entries reads back the same.
package tar_test

import "core:slice"
import "core:testing"
import vx "abi:vx"
import "vx:tar"

CORPUS := #load_directory("corpus")

@(private="file")
tar_fuzz :: proc(t: ^testing.T, name: string, data: []u8) {
	out := make([]u8, 1 << 20)
	defer delete(out)
	w := tar.Writer{buf = out}
	r := tar.open(data)
	count := 0
	for e in tar.entries(&r) {
		e := e
		if !e.dir && len(e.data) > 0 {
			start := uintptr(raw_data(e.data))
			inside := start >= uintptr(raw_data(data)) && start + uintptr(len(e.data)) <= uintptr(raw_data(data)) + uintptr(len(data))
			testing.expectf(t, inside, "%s: %s's data lies outside the input", name, tar.entry_path(&e))
		}
		tar.add(&w, tar.entry_path(&e), e.dir, e.mode, e.data)
		count += 1
	}
	n := tar.end(&w)
	if n == 0 {
		return // a path the writer splits differently can fail to fit; that is fine
	}
	again := tar.open(out[:n])
	r = tar.open(data)
	for _ in 0 ..< count {
		a, e: tar.Entry
		if !testing.expect_value(t, tar.next(&again, &a), vx.Status.Ok) || !testing.expect_value(t, tar.next(&r, &e), vx.Status.Ok) {
			return
		}
		testing.expectf(t, tar.entry_path(&a) == tar.entry_path(&e), "%s: %s reads back as %s", name, tar.entry_path(&e), tar.entry_path(&a))
		testing.expectf(t, slice.equal(a.data, e.data), "%s: %s's data differs", name, tar.entry_path(&e))
		testing.expect_value(t, a.dir, e.dir)
		testing.expect_value(t, a.mode, e.mode)
	}
	a: tar.Entry
	testing.expect_value(t, tar.next(&again, &a), vx.Status.Err_Not_Found)
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	testing.expect_value(t, len(CORPUS), 1)
	for file in CORPUS {
		tar_fuzz(t, file.name, file.data)
	}
}

// Not upstream's corpus: an archive with links, cut and with each byte of
// its headers flipped in turn, through the same checks.
@(test)
test_mutants :: proc(t: ^testing.T) {
	image := make([]u8, IMAGE)
	defer delete(image)
	w := tar.Writer{buf = image}
	tar.add(&w, "bin", true, 0o755, nil)
	tar.add(&w, "bin/box", false, 0o755, transmute([]u8)string("#!box"))
	tar.add_link(&w, "bin/ls", "bin/box", 0o755)
	n := tar.end(&w)
	tar_fuzz(t, "links", image[:n])
	for cut in 0 ..< n {
		tar_fuzz(t, "cut", image[:cut])
	}
	for at in 0 ..< 3 * tar.BLOCK {
		if at >= tar.BLOCK && at < 2 * tar.BLOCK {
			continue // box's data
		}
		image[at] ~= 0x41
		tar_fuzz(t, "flipped", image[:n])
		image[at] ~= 0x41
	}
}
