// lib/iso, ported from upstream's tests/host/iso_test.c: the ISO upstream's
// write_iso makes (image_test.odin), read each of the three ways: Rock
// Ridge (real names, a name continued in a continuation area, UTF-8 past
// the BMP, case kept and matched exactly, symbolic links, modes, a deep
// directory and its parents, a file of many sectors); Joliet with Rock Ridge
// avoided (UTF-16, names cut at 64 units, no links, case ignored); and ISO
// 9660 alone (lower-cased 8.3-ish names, the ~1 made for a case clash).
// Then damage: a descriptor that is not ISO 9660, a record that overruns
// its sector, a continuation pointing past the volume. (Upstream's
// ./build check also lists the image with 7z, another reader; here the
// image is upstream's, which that already checks.)
package iso_test

import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:iso"

LONG :: "A Long Mixed-Case Name That Goes On And On, Past What One Directory Record Can Hold, So Its Rock " + "Ridge NM Entry Has To Continue In The Directory's Continuation Area, Which Is The Point Of It.txt"

// The entry at path, from the root, into e.
walk :: proc(v: ^iso.Vol, path: string, e: ^iso.Entry) -> bool {
	iso.root_entry(v, e)
	rest := path
	for part in strings.split_iterator(&rest, "/") {
		if part == "" {
			continue
		}
		d := e^
		if iso.lookup(v, &d, part, e) != .Ok {
			return false
		}
	}
	return true
}

// Whether the file at path holds want.
reads :: proc(v: ^iso.Vol, path, want: string) -> bool {
	e: iso.Entry
	buf: [512]u8
	walk(v, path, &e) or_return
	n, st := iso.read(v, &e, 0, buf[:])
	return st == .Ok && string(buf[:n]) == want
}

// How many entries the directory at path lists; -1 if it is not one.
listed :: proc(v: ^iso.Vol, path: string) -> int {
	d, e: iso.Entry
	if !walk(v, path, &d) {
		return -1
	}
	it, st := iso.open_dir(&d)
	if st != .Ok {
		return -1
	}
	n := 0
	for iso.dir_next(v, &it, &e) == .Ok {
		n += 1
	}
	return n
}

@(test)
test_rock :: proc(t: ^testing.T) {
	image := load_image(t)
	defer delete(image)
	v := new(iso.Vol)
	defer free(v)
	testing.expect_value(t, iso.mount(v, dev_of(&image), {}), vx.Status.Ok)
	testing.expect_value(t, v.kind, iso.Kind.Rock)
	testing.expect_value(t, iso.label(v), "VECTRAOS")
	testing.expect(t, reads(v, "README.txt", "readme\n"))
	testing.expect(t, !reads(v, "readme.txt", "readme\n")) // Rock Ridge names are matched exactly
	testing.expect(t, reads(v, LONG, "long\n"))
	testing.expect(t, reads(v, "\xc3\x9cn\xc3\xafcode file.txt", "unicode\n"))
	testing.expect(t, reads(v, "\xf0\x9f\x98\x80 smile.txt", "smile\n"))
	testing.expect(t, reads(v, "dir with spaces/same name.txt", "lower\n"))
	testing.expect(t, reads(v, "dir with spaces/Same Name.txt", "upper\n"))
	testing.expect(t, reads(v, "deep/er/still/deeper/file.txt", "deep\n"))
	// The root: README, long, unicode, smile, two links, deep, "dir with
	// spaces", big.bin; boot.catalog and efiboot.img.
	testing.expect_value(t, listed(v, ""), 11)
	e: iso.Entry
	testing.expect(t, walk(v, "link-to-readme", &e))
	testing.expect(t, e.link)
	testing.expect_value(t, iso.entry_target(&e), "README.txt")
	testing.expect(t, walk(v, "abs-link", &e))
	testing.expect(t, e.link)
	testing.expect_value(t, iso.entry_target(&e), "/boot/limine/limine.conf")
	testing.expect(t, walk(v, "deep/er/up-link", &e))
	testing.expect(t, e.link)
	testing.expect_value(t, iso.entry_target(&e), "../../dir with spaces/./same name.txt")
	testing.expect(t, walk(v, "README.txt", &e))
	testing.expect_value(t, e.mode, 0o444)
	testing.expect(t, !e.dir)
	testing.expect(t, !e.link)
	testing.expect(t, walk(v, "deep", &e))
	testing.expect(t, e.dir)
	testing.expect_value(t, e.mode, 0o555)
	testing.expect(t, e.mtime >= 315_532_800) // SOURCE_DATE_EPOCH's, 1980 or later

	// Many sectors, whole and in pieces.
	big: iso.Entry
	testing.expect(t, walk(v, "big.bin", &big))
	testing.expect_value(t, big.size, BIG_SIZE)
	buf := make([]u8, 300_100)
	defer delete(buf)
	n, st := iso.read(v, &big, 0, buf)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, BIG_SIZE)
	same := true
	for i in 0 ..< u64(BIG_SIZE) {
		same = same && buf[i] == big_byte(i)
	}
	for off: u64 = 0; off < BIG_SIZE; off += 7919 {
		got, rst := iso.read(v, &big, off, buf[:3001])
		same = same && rst == .Ok
		for i in 0 ..< u64(got) {
			same = same && buf[i] == big_byte(off + i)
		}
	}
	testing.expect(t, same)

	// Nodes: found again, and their parents, up to the root.
	file, still, er, deep, again, deeper: iso.Entry
	testing.expect(t, walk(v, "deep/er/still/deeper/file.txt", &file))
	testing.expect(t, walk(v, "deep/er/still", &still))
	testing.expect(t, walk(v, "deep/er", &er))
	testing.expect(t, walk(v, "deep", &deep))
	testing.expect_value(t, iso.get(v, file.node, &again), vx.Status.Ok)
	testing.expect_value(t, iso.entry_name(&again), "file.txt")
	testing.expect_value(t, iso.get(v, still.node, &again), vx.Status.Ok)
	testing.expect_value(t, iso.entry_name(&again), "still")
	testing.expect(t, again.dir)
	testing.expect(t, walk(v, "deep/er/still/deeper", &deeper))
	expect_parent(t, v, file.node, deeper.node)
	expect_parent(t, v, deeper.node, still.node)
	expect_parent(t, v, er.node, deep.node)
	expect_parent(t, v, deep.node, iso.ROOT)
	// Not a record's start.
	testing.expect_value(t, iso.get(v, iso.Node(1 << 62 | u64(v.root_lba) << 24 | 3), &again), vx.Status.Err_Not_Found)
}

expect_parent :: proc(t: ^testing.T, v: ^iso.Vol, node, want: iso.Node, loc := #caller_location) {
	p, st := iso.parent(v, node)
	testing.expect_value(t, st, vx.Status.Ok, loc)
	testing.expect_value(t, p, want, loc)
}

@(test)
test_joliet :: proc(t: ^testing.T) {
	image := load_image(t)
	defer delete(image)
	v := new(iso.Vol)
	defer free(v)
	testing.expect_value(t, iso.mount(v, dev_of(&image), {.Rock}), vx.Status.Ok)
	testing.expect_value(t, v.kind, iso.Kind.Joliet)
	testing.expect(t, reads(v, "readme.TXT", "readme\n")) // case ignored
	testing.expect(t, reads(v, "\xc3\x9cn\xc3\xafcode file.txt", "unicode\n"))
	testing.expect(t, reads(v, "\xf0\x9f\x98\x80 smile.txt", "smile\n")) // a surrogate pair
	testing.expect(t, reads(v, LONG[:64], "long\n")) // 64 units
	e: iso.Entry
	testing.expect(t, !walk(v, "link-to-readme", &e)) // Joliet has no links
	testing.expect(t, reads(v, "deep/er/still/deeper/file.txt", "deep\n"))
	testing.expect_value(t, listed(v, ""), 9) // the root's, without the two links
}

@(test)
test_plain :: proc(t: ^testing.T) {
	image := load_image(t)
	defer delete(image)
	v := new(iso.Vol)
	defer free(v)
	testing.expect_value(t, iso.mount(v, dev_of(&image), {.Rock, .Joliet}), vx.Status.Ok)
	testing.expect_value(t, v.kind, iso.Kind.Plain)
	testing.expect(t, reads(v, "readme.txt", "readme\n"))
	testing.expect(t, reads(v, "README.TXT", "readme\n"))
	testing.expect(t, reads(v, "dir_with_spaces/same_name.txt", "upper\n") || reads(v, "dir_with_spaces/same_name.txt", "lower\n"))
	testing.expect(t, reads(v, "dir_with_spaces/same_name~1.txt", "upper\n") || reads(v, "dir_with_spaces/same_name~1.txt", "lower\n"))
	testing.expect(t, reads(v, "deep/er/still/deeper/file.txt", "deep\n"))
	e: iso.Entry
	testing.expect(t, walk(v, "link_to_readme", &e)) // a link without Rock Ridge: an empty file
	testing.expect(t, !e.link)
	testing.expect_value(t, e.size, 0)
	// The writer's longest name, 30 characters, keeps its version (upstream
	// f24356f, from this tree's finding: ";1" lost its 1).
	testing.expect(t, strings.contains(string(image), "A_LONG_MIXED_CASE_NAME_THA.TXT;1"), "the long name's version")
}

@(test)
test_damage :: proc(t: ^testing.T) {
	m := load_image(t)
	defer delete(m)
	c := make([]u8, len(m))
	defer delete(c)
	v := new(iso.Vol)
	defer free(v)
	// Not ISO 9660.
	copy(c, m)
	c[16 * 2048 + 1] = 'X'
	testing.expect_value(t, iso.mount(v, dev_of(&c), {}), vx.Status.Err_Invalid)
	copy(c, m)
	// The root's records: the first file record's length made to overrun its sector.
	testing.expect_value(t, iso.mount(v, dev_of(&c), {}), vx.Status.Ok)
	dir := c[v.root_lba * 2048:]
	at := int(dir[0]) // past "."
	at += int(dir[at]) // past ".."
	dir[at] = 0xff // 255 bytes from wherever it is: past the sector if near its end, else into the next record
	root, e: iso.Entry
	iso.root_entry(v, &root)
	it, _ := iso.open_dir(&root)
	st := vx.Status.Ok
	for i := 0; i < 100 && st == .Ok; i += 1 {
		st = iso.dir_next(v, &it, &e) // ends: no loop, no overrun
	}
	testing.expect(t, st == .Err_Not_Found || st == .Err_Io)
	copy(c, m)
	// A continuation past the volume: the CE in the long name's record (found
	// by its ISO 9660 name; its NM is all in the continuation area),
	// corrupted before the volume is read.
	testing.expect_value(t, iso.mount(v, dev_of(&c), {}), vx.Status.Ok)
	start := int(v.root_lba) * 2048
	end := start + int(v.root_len)
	found := false
	for i := start; i + 16 < end && !found; i += 1 {
		if string(c[i:][:12]) != "A_LONG_MIXED" { // its ISO 9660 name
			continue
		}
		for k := i; k + 28 < i + 255 && !found; k += 1 {
			if c[k] == 'C' && c[k + 1] == 'E' && c[k + 2] == 28 && c[k + 3] == 1 {
				c[k + 4], c[k + 5], c[k + 6] = 0x7f, 0x7f, 0x7f // block 0x7f7f7f..: past the end
				found = true
			}
		}
	}
	testing.expect(t, found)
	testing.expect_value(t, iso.mount(v, dev_of(&c), {}), vx.Status.Ok)
	testing.expect_value(t, v.kind, iso.Kind.Rock)
	testing.expect(t, !reads(v, LONG, "long\n"))
}

// Upstream's check_hostile (ab83fe6, from this tree's findings), through the
// package's own calls: a root directory claiming 4 GiB of records is
// refused at once rather than walked until its offset wraps; and a sector
// whose read fails is not kept as the sector it replaced, so what is read
// once the device answers again is the volume's.
@(private="file")
failing: bool

@(private="file")
flaky_read :: proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool {
	if failing {
		for &b in buf {
			b = 0xee // what a partial read might leave
		}
		return false
	}
	return image_read(ctx, off, buf)
}

@(test)
test_hostile :: proc(t: ^testing.T) {
	image := load_image(t)
	defer delete(image)
	v := new(iso.Vol)
	defer free(v)

	// The primary descriptor's root record (sector 16, at 156): its length,
	// both-endian, at 10.
	c := make([]u8, len(image))
	defer delete(c)
	copy(c, image)
	root := c[16 * iso.SECTOR + 156:]
	root[10], root[11], root[12], root[13] = 0x00, 0xf0, 0xff, 0xff
	root[14], root[15], root[16], root[17] = 0xff, 0xff, 0xf0, 0x00
	if iso.mount(v, dev_of(&c), {.Rock, .Joliet}) == .Ok {
		r: iso.Entry
		iso.root_entry(v, &r)
		it, _ := iso.open_dir(&r)
		e: iso.Entry
		testing.expect_value(t, iso.dir_next(v, &it, &e), vx.Status.Err_Io)
	}

	// Every file read once, the device failing for one more, then every
	// file again: the volume's bytes, never the failed read's.
	failing = false
	testing.expect_value(t, iso.mount(v, {ctx = &image, read = flaky_read}, {}), vx.Status.Ok)
	testing.expect(t, reads(v, "README.txt", "readme\n"))
	testing.expect(t, reads(v, "deep/er/still/deeper/file.txt", "deep\n"))
	failing = true
	testing.expect(t, !reads(v, "dir with spaces/same name.txt", "lower\n"))
	failing = false
	testing.expect(t, reads(v, "dir with spaces/same name.txt", "lower\n"))
	testing.expect(t, reads(v, "README.txt", "readme\n"))
	testing.expect(t, reads(v, "deep/er/still/deeper/file.txt", "deep\n"))
}
