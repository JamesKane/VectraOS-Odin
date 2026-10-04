// lib/tar, ported from upstream's tests/host/tar_test.c. Archives the writer
// makes read back entry for entry; long paths split into prefix and name; and
// the reader refuses bad checksums, bad octal, unsafe paths, links, and files
// that run past the image.
package tar_test

import "core:encoding/hex"
import "core:testing"
import "vx:sha256"
import vx "abi:vx"
import "vx:tar"

IMAGE :: 64 * 1024

build :: proc(image: []u8) -> int {
	w := tar.Writer{buf = image}
	tar.add(&w, "boot", true, 0o755, nil)
	tar.add(&w, "boot/svc", true, 0o755, nil)
	tar.add(&w, "boot/svc/bootfs.ndb", false, 0o644, transmute([]u8)string("service=bootfs\n"))
	tar.add(&w, "empty", false, 0o644, transmute([]u8)string(""))
	big: [1000]u8
	for &b in big {
		b = 'x'
	}
	tar.add(&w, "big", false, 0o755, big[:])
	// 150 bytes of path: a prefix and a name.
	tar.add(
		&w,
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" +
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		false,
		0o644,
		transmute([]u8)string("long"),
	)
	return tar.end(&w)
}

data_is :: proc(e: ^tar.Entry, want: string) -> bool {
	return string(e.data) == want
}

@(test)
test_round_trip :: proc(t: ^testing.T) {
	image := make([]u8, IMAGE)
	defer delete(image)
	n := build(image)
	testing.expect(t, n == tar.BLOCK * (1 + 1 + 2 + 1 + 3 + 2 + 2)) // dirs, files with their data, the end
	r := tar.open(image[:n])
	e: tar.Entry
	testing.expect(t, tar.next(&r, &e) == .Ok && e.dir && len(tar.entry_path(&e)) == 4 && e.mode == 0o755)
	testing.expect(t, tar.next(&r, &e) == .Ok && e.dir && len(tar.entry_path(&e)) == 8)
	testing.expect(t, tar.next(&r, &e) == .Ok && !e.dir && len(e.data) == 15 && data_is(&e, "service=bootfs\n"))
	testing.expect(t, tar.next(&r, &e) == .Ok && len(e.data) == 0 && raw_data(e.data) != nil)
	testing.expect(t, tar.next(&r, &e) == .Ok && len(e.data) == 1000 && e.data[999] == 'x' && e.mode == 0o755)
	testing.expect(t, tar.next(&r, &e) == .Ok && len(tar.entry_path(&e)) == 150 && tar.entry_path(&e)[80] == '/' && data_is(&e, "long"))
	testing.expect(t, tar.next(&r, &e) == .Err_Not_Found)
	testing.expect(t, tar.next(&r, &e) == .Err_Not_Found)

	testing.expect(t, tar.find(image[:n], "boot/svc/bootfs.ndb", &e) == .Ok && len(e.data) == 15)
	testing.expect(t, tar.find(image[:n], "boot/svc", &e) == .Ok && e.dir)
	testing.expect(t, tar.find(image[:n], "boot/sv", &e) == .Err_Not_Found)
	testing.expect(t, tar.find(image[:n - 1024], "big", &e) == .Ok) // no end blocks: still fine

	// The writer refuses what the reader would.
	small: [2048]u8
	w := tar.Writer{buf = small[:]}
	tar.add(&w, "../etc", false, 0o644, transmute([]u8)string("x"))
	testing.expect(t, w.failed)
	w = tar.Writer{buf = small[:]}
	tar.add(&w, "f", false, 0o644, image[:1024]) // header + 2 blocks + end > 2048
	testing.expect(t, !w.failed && tar.end(&w) == 0)
}

// Not upstream's: the writer's bytes are upstream's. The digest is of what
// upstream's vx_tar_add and vx_tar_end write for these same calls (7680
// bytes), so a change to any header field, padding or split shows here.
@(test)
test_upstream_bytes :: proc(t: ^testing.T) {
	image := make([]u8, IMAGE)
	defer delete(image)
	w := tar.Writer{buf = image}
	tar.add(&w, "boot", true, 0o755, nil)
	tar.add(&w, "boot/svc", true, 0o755, nil)
	tar.add(&w, "boot/svc/bootfs.ndb", false, 0o644, transmute([]u8)string("service=bootfs\n"))
	tar.add(&w, "empty", false, 0o644, transmute([]u8)string(""))
	big: [1000]u8
	for &b in big {
		b = 'x'
	}
	tar.add(&w, "big", false, 0o755, big[:])
	tar.add(
		&w,
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" +
		"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		false,
		0o640,
		transmute([]u8)string("long"),
	)
	p: [200]u8
	for &c in p {
		c = 'c'
	}
	p[60] = '/'
	p[120] = '/' // two places it could split; the later one wins
	tar.add(&w, string(p[:]), false, 0o7777, transmute([]u8)string("z"))
	tar.add(&w, "d/e", true, 0, nil)
	n := tar.end(&w)
	testing.expect(t, n == 7680)
	h := sha256.begin()
	sha256.add(&h, image[:n])
	d := sha256.end(&h)
	got := hex.encode(d[:])
	defer delete(got)
	testing.expect_value(t, string(got), "de7642a9bb23e1c04a9734cab25218e3bfb3cb0c3e47e63acc4986ca502ebea8")
}

// Not upstream's: a path that fills both prefix (155) and name (100) is
// written and read back. Upstream's reader writes a NUL one byte past its
// path buffer for it.
@(test)
test_longest_path :: proc(t: ^testing.T) {
	path: [tar.MAX_PATH]u8
	for &c in path {
		c = 'p'
	}
	path[155] = '/'
	image: [4 * tar.BLOCK]u8
	w := tar.Writer{buf = image[:]}
	tar.add(&w, string(path[:]), false, 0o644, nil)
	n := tar.end(&w)
	testing.expect(t, n == 3 * tar.BLOCK)
	e: tar.Entry
	testing.expect(t, tar.find(image[:n], string(path[:]), &e) == .Ok)

	// One more byte fits nowhere.
	long: [tar.MAX_PATH + 1]u8
	for &c in long {
		c = 'p'
	}
	long[155] = '/'
	w = tar.Writer{buf = image[:]}
	tar.add(&w, string(long[:]), false, 0o644, nil)
	testing.expect(t, w.failed)
}

header :: proc(image: []u8, at: int) -> ^tar.Header {
	return (^tar.Header)(raw_data(image[at:][:tar.BLOCK]))
}

// Rewrites the checksum of the header at `at` after a change: six octal
// digits, a NUL and a space, the checksum field counted as spaces.
reseal :: proc(image: []u8, at: int) {
	b := image[at:][:tar.BLOCK]
	sum: u32
	for c, i in b {
		sum += (i >= 148 && i < 156) ? ' ' : u32(c)
	}
	h := header(image, at)
	put_octal(h.chksum[:7], u64(sum))
	h.chksum[7] = ' '
}

put_octal :: proc(f: []u8, v: u64) {
	f[len(f) - 1] = 0
	x := v
	for i := len(f) - 2; i >= 0; i -= 1 {
		f[i] = u8('0' + (x & 7))
		x >>= 3
	}
}

first_entry :: proc(image: []u8, n: int) -> vx.Status {
	r := tar.open(image[:n])
	e: tar.Entry
	return tar.next(&r, &e)
}

@(test)
test_hostile :: proc(t: ^testing.T) {
	image := make([]u8, IMAGE)
	defer delete(image)
	bad_names := []string{"/abs", "a//b", "./a", "a/../b", "..", "a/.", "tab\there"}
	for name in bad_names {
		n := build(image)
		h := header(image, 0)
		h.name = {}
		copy(h.name[:], name)
		reseal(image, 0)
		testing.expectf(t, first_entry(image, n) == .Err_Invalid, "accepted %q", name)
	}
	n := build(image)
	h := header(image, 0)
	image[3] ~= 1 // a name byte, with the checksum left alone
	testing.expect(t, first_entry(image, n) == .Err_Invalid)

	n = build(image)
	h.typeflag = '2' // a symlink
	reseal(image, 0)
	testing.expect(t, first_entry(image, n) == .Err_Invalid)

	n = build(image)
	copy(h.mode[:], "07x5\x00\x00\x00\x00") // not octal
	reseal(image, 0)
	testing.expect(t, first_entry(image, n) == .Err_Invalid)

	n = build(image)
	h.name[99] = 'z' // a name that fills its field is fine...
	for &c in h.name[4:][:95] {
		c = 'q'
	}
	reseal(image, 0)
	testing.expect(t, first_entry(image, n) == .Ok)
	h.magic[0] = 'x' // ...but not without the ustar magic
	reseal(image, 0)
	testing.expect(t, first_entry(image, n) == .Err_Invalid)

	// A file whose size runs past the image, at the third header.
	n = build(image)
	f := header(image, 1024)
	put_octal(f.size[:], 1 << 30)
	reseal(image, 1024)
	r := tar.open(image[:n])
	e: tar.Entry
	testing.expect(t, tar.next(&r, &e) == .Ok && tar.next(&r, &e) == .Ok)
	testing.expect(t, tar.next(&r, &e) == .Err_Invalid)
	testing.expect(t, tar.next(&r, &e) == .Err_Invalid) // and it stays ended
	testing.expect(t, tar.find(image[:n], "big", &e) == .Err_Invalid)

	// Truncated mid-header and mid-file.
	n = build(image)
	testing.expect(t, first_entry(image, 511) == .Err_Not_Found)
	r2 := tar.open(image[:1024 + 512 + 8])
	testing.expect(t, tar.next(&r2, &e) == .Ok && tar.next(&r2, &e) == .Ok && tar.next(&r2, &e) == .Err_Invalid)
}
