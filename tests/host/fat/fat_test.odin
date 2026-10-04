// lib/fat, ported from upstream's tests/host/fat_test.c: against FAT12,
// FAT16 and FAT32 images that mtools made (fixtures_test.odin), so the
// format is checked against another implementation's: the type and label;
// short and long names, UTF-8 (past the BMP patched in), case-insensitive
// lookup by long name and by 8.3 alias; a deleted entry not seen; a file of
// many clusters read whole and in pieces; a directory spanning clusters;
// nodes found again and their parents; a known time. Then damage: a
// truncated device, a FAT loop, a boot sector that is not FAT. (A loop is
// bounded by the file's size and the volume's cluster count, not found:
// that wants a visited set.) Then writing, on each image and on a volume
// format made.
//
// Added here: format's image is digested, and the digest is the one
// upstream's C (lib/vx-fat, built with clang) gives for the same steps, so
// the bytes cannot drift unnoticed.
package fat_test

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:fat"

// A device over bytes in memory. writes_left >= 0: the device fails once
// this many more writes are done.
Image :: struct {
	bytes:       []u8,
	writes_left: int,
}

image_read :: proc "contextless" (ctx: rawptr, off: u64, buf: []u8) -> bool {
	m := (^Image)(ctx)
	if off > u64(len(m.bytes)) || u64(len(buf)) > u64(len(m.bytes)) - off {
		return false
	}
	copy(buf, m.bytes[off:])
	return true
}

image_write :: proc "contextless" (ctx: rawptr, off: u64, data: []u8) -> bool {
	m := (^Image)(ctx)
	if m.writes_left == 0 {
		return false
	}
	if m.writes_left > 0 {
		m.writes_left -= 1
	}
	if off > u64(len(m.bytes)) || u64(len(data)) > u64(len(m.bytes)) - off {
		return false
	}
	copy(m.bytes[off:], data)
	return true
}

readable :: proc(m: ^Image) -> fat.Dev {
	return {ctx = m, read = image_read}
}

writable :: proc(m: ^Image) -> fat.Dev {
	return {ctx = m, read = image_read, write = image_write}
}

new_image :: proc(bytes: []u8) -> Image {
	return {bytes = bytes, writes_left = -1}
}

// The entry at path from the root, components split at '/'.
walk :: proc(v: ^fat.Vol, path: string, e: ^fat.Entry) -> bool {
	e^ = fat.root_entry(v)
	rest := path
	for part in strings.split_iterator(&rest, "/") {
		if part == "" {
			continue
		}
		d := e^
		if fat.lookup(v, &d, part, e) != .Ok {
			return false
		}
	}
	return true
}

reads :: proc(t: ^testing.T, v: ^fat.Vol, path, want: string, loc := #caller_location) {
	e: fat.Entry
	if !testing.expectf(t, walk(v, path, &e), "%s: not found", path, loc = loc) {
		return
	}
	buf: [512]u8
	n, st := fat.read(v, &e, 0, buf[:])
	testing.expect_value(t, st, vx.Status.Ok, loc)
	testing.expect_value(t, string(buf[:n]), want, loc)
}

check_image :: proc(t: ^testing.T, name: string, kind: fat.Kind, label: string) {
	bytes := load(name)
	defer delete(bytes)
	if !testing.expectf(t, len(bytes) > 0, "%s: no image", name) {
		return
	}
	m := new_image(bytes)
	v := new(fat.Vol)
	defer free(v)
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Ok)
	testing.expect_value(t, v.kind, kind)
	testing.expect_value(t, fat.volume_label(v), label)

	// Names.
	reads(t, v, "SHORT.TXT", "hello\n")
	reads(t, v, "short.txt", "hello\n") // FAT ignores case
	reads(t, v, "lower.txt", "lower\n")
	reads(t, v, "A Long Directory Name/" + UNICODE_FILE, "unicode\n")
	reads(t, v, "a long directory name/sub dir/deep.txt", "deep\n")
	reads(t, v, "ALONGD~1/sub dir/DEEP.TXT", "deep\n") // by the 8.3 alias
	e: fat.Entry
	testing.expect(t, !walk(v, "gone.txt", &e)) // deleted
	testing.expect(t, !walk(v, "SHORT.TXT/x", &e))
	testing.expect(t, !walk(v, "nothing", &e))

	// The root's listing: what mcopy put there, and no more.
	root := fat.root_entry(v)
	it, st := fat.open_dir(v, &root)
	testing.expect_value(t, st, vx.Status.Ok)
	count := 0
	saw_long, saw_lower := false, false
	d: fat.Entry
	for fat.dir_next(v, &it, &d) == .Ok {
		count += 1
		saw_long = saw_long || fat.entry_name(&d) == "A Long Directory Name"
		saw_lower = saw_lower || fat.entry_name(&d) == "lower.txt"
	}
	testing.expect_value(t, count, 5) // SHORT.TXT lower.txt "A Long Directory Name" big.bin many
	testing.expect(t, saw_long)
	testing.expect(t, saw_lower)

	// A directory of 100 entries, more than one cluster's on FAT16 and FAT32.
	many: fat.Entry
	testing.expect(t, walk(v, "many", &many))
	testing.expect(t, .Directory in many.attr)
	it, st = fat.open_dir(v, &many)
	testing.expect_value(t, st, vx.Status.Ok)
	count = 0
	for fat.dir_next(v, &it, &d) == .Ok {
		count += 1
	}
	testing.expect_value(t, count, 100)
	reads(t, v, "many/f099.txt", "f099\n")

	// A file of many clusters: whole, and in odd pieces across clusters.
	big: fat.Entry
	testing.expect(t, walk(v, "big.bin", &big))
	testing.expect_value(t, big.size, 300_000)
	buf := make([]u8, 300_000 + 100)
	defer delete(buf)
	n: u32
	n, st = fat.read(v, &big, 0, buf)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 300_000)
	same := true
	for i in 0 ..< 300_000 {
		same = same && buf[i] == big_byte(i)
	}
	testing.expect(t, same)
	same = true
	for off := 0; off < 300_000; off += 7919 {
		n, st = fat.read(v, &big, u64(off), buf[:3001])
		same = same && st == .Ok
		for i in 0 ..< int(n) {
			same = same && buf[i] == big_byte(off + i)
		}
	}
	testing.expect(t, same)
	n, st = fat.read(v, &big, 300_000, buf[:10])
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 0)

	// Nodes: found again by node, and their parents.
	deep, again, sub, top: fat.Entry
	testing.expect(t, walk(v, "A Long Directory Name/sub dir/deep.txt", &deep))
	testing.expect_value(t, fat.get(v, deep.node, &again), vx.Status.Ok)
	testing.expect_value(t, fat.entry_name(&again), "deep.txt")
	testing.expect(t, walk(v, "A Long Directory Name/sub dir", &sub))
	testing.expect(t, walk(v, "A Long Directory Name", &top))
	p, pst := fat.parent(v, deep.node)
	testing.expect_value(t, pst, vx.Status.Ok)
	testing.expect_value(t, p, sub.node)
	p, pst = fat.parent(v, sub.node)
	testing.expect_value(t, pst, vx.Status.Ok)
	testing.expect_value(t, p, top.node)
	p, pst = fat.parent(v, top.node)
	testing.expect_value(t, pst, vx.Status.Ok)
	testing.expect_value(t, p, fat.ROOT)
	testing.expect_value(t, fat.get(v, top.node, &again), vx.Status.Ok)
	testing.expect_value(t, fat.entry_name(&again), "A Long Directory Name")
	testing.expect_value(t, fat.get(v, fat.ROOT, &again), vx.Status.Ok)
	testing.expect(t, .Directory in again.attr)

	// A known time.
	s: fat.Entry
	testing.expect(t, walk(v, "SHORT.TXT", &s))
	testing.expect_value(t, s.mtime, 981_173_106) // 2001-02-03 04:05:06

	// A device cut short: reads past it fail as Err_Io, not garbage.
	cut := new_image(bytes[:len(bytes) / 2])
	v2 := new(fat.Vol)
	defer free(v2)
	if fat.mount(v2, readable(&cut)) == .Ok {
		b2: fat.Entry
		root = fat.root_entry(v2)
		if fat.lookup(v2, &root, "big.bin", &b2) == .Ok {
			_, st = fat.read(v2, &b2, 0, buf)
			testing.expectf(t, st == .Ok || st == .Err_Io, "a read of a device cut short gave %v", st)
		}
	}
}

@(test)
test_image_fat12 :: proc(t: ^testing.T) {
	check_image(t, "fat12.img", .Fat12, "SMALL")
}

@(test)
test_image_fat16 :: proc(t: ^testing.T) {
	check_image(t, "fat16.img", .Fat16, "MIDDLE")
}

@(test)
test_image_fat32 :: proc(t: ^testing.T) {
	check_image(t, "fat32.img", .Fat32, "LARGE")
}

// Names past the BMP, which mtools cannot write: "A Long Directory Name"'s
// first long-name slot patched to start with U+1F600 (a surrogate pair in
// place of "A "), then with a lone high surrogate.
@(test)
test_surrogates :: proc(t: ^testing.T) {
	bytes := load("fat16.img")
	defer delete(bytes)
	if !testing.expect(t, len(bytes) > 0) {
		return
	}
	m := new_image(bytes)
	v := new(fat.Vol)
	defer free(v)
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Ok)
	slot: []u8
	for i in 0 ..< int(v.root_entries) {
		at := int(v.root_start) * int(v.sector_size) + i * 32
		s := bytes[at:at + 32]
		if s[11] == 0x0f && s[0] & 0x1f == 1 && s[1] == 'A' && s[3] == ' ' && s[5] == 'L' {
			slot = s
			break
		}
	}
	if !testing.expect(t, slot != nil) {
		return
	}
	slot[1], slot[2], slot[3], slot[4] = 0x3d, 0xd8, 0x00, 0xde // U+1F600
	e: fat.Entry
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Ok)
	testing.expect(t, walk(v, "\xf0\x9f\x98\x80Long Directory Name/sub dir/deep.txt", &e))
	slot[3], slot[4] = ' ', 0 // the high surrogate alone, then the space
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Ok)
	testing.expect(t, walk(v, "\xef\xbf\xbd Long Directory Name", &e)) // U+FFFD
}

// A chain that loops, and a boot sector that is not FAT.
@(test)
test_damage :: proc(t: ^testing.T) {
	bytes := load("fat16.img")
	defer delete(bytes)
	if !testing.expect(t, len(bytes) > 0) {
		return
	}
	m := new_image(bytes)
	v := new(fat.Vol)
	defer free(v)
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Ok)
	big: fat.Entry
	testing.expect(t, walk(v, "big.bin", &big))
	// big.bin's second cluster points back at its first.
	next, st := fat.next_cluster(v, big.cluster)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, next != 0)
	at := int(v.fat_start) * int(v.sector_size) + int(next) * 2
	bytes[at], bytes[at + 1] = u8(big.cluster), u8(big.cluster >> 8)
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Ok)
	buf := make([]u8, 300_000)
	defer delete(buf)
	testing.expect(t, walk(v, "big.bin", &big))
	_, st = fat.read(v, &big, 0, buf) // round the loop, but never past the file's size
	testing.expectf(t, st == .Ok || st == .Err_Io, "a looping chain read gave %v", st)
	bytes[510] = 0
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Err_Invalid)
	bytes[510] = 0x55
	bytes[13] = 3 // sectors per cluster not a power of two
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Err_Invalid)
}

// --- Writing ---

// The entry at path made, in the directory its parent path names.
make_entry :: proc(v: ^fat.Vol, path: string, attr: fat.Attrs, out: ^fat.Entry) -> bool {
	dir: fat.Entry
	name := path
	if slash := strings.last_index_byte(path, '/'); slash >= 0 {
		walk(v, path[:slash], &dir) or_return
		name = path[slash + 1:]
	} else {
		dir = fat.root_entry(v)
	}
	return fat.create(v, &dir, name, attr, out) == .Ok
}

put :: proc(v: ^fat.Vol, path: string, off: u64, data: []u8) -> bool {
	e: fat.Entry
	return walk(v, path, &e) && fat.write(v, &e, off, data) == .Ok
}

free_clusters :: proc(v: ^fat.Vol) -> u32 {
	n: u32
	for c: u32 = 2; c <= v.clusters + 1; c += 1 {
		e, st := fat.raw_entry(v, c)
		if st == .Ok && e == 0 {
			n += 1
		}
	}
	return n
}

check_writes :: proc(t: ^testing.T, name, out: string) {
	bytes := load(name)
	defer delete(bytes)
	if !testing.expectf(t, len(bytes) > 0, "%s: no image", name) {
		return
	}
	m := new_image(bytes)
	v := new(fat.Vol)
	defer free(v)
	testing.expect_value(t, fat.mount(v, writable(&m)), vx.Status.Ok)
	v.now = 1_893_553_445 // 2030-01-02 03:04:05
	free_before := free_clusters(v)
	e, d: fat.Entry

	// New files: an 8.3 name, a lower-case one (no long name: NT's flags), a
	// long one, one past the BMP, and a directory with a file in it.
	testing.expect(t, make_entry(v, "NEW.TXT", {}, &e))
	testing.expect_value(t, fat.entry_name(&e), "NEW.TXT")
	testing.expect_value(t, fat.entry_alias(&e), "NEW.TXT")
	testing.expect(t, make_entry(v, "small.txt", {}, &e))
	testing.expect_value(t, fat.entry_name(&e), "small.txt")
	testing.expect_value(t, fat.entry_alias(&e), "SMALL.TXT")
	testing.expect(t, make_entry(v, "A new file with a long name.text", {}, &e))
	testing.expect_value(t, fat.entry_alias(&e), "ANEWFI~1.TEX")
	testing.expect(t, make_entry(v, "A new file with a long name.texts", {}, &e))
	testing.expect_value(t, fat.entry_alias(&e), "ANEWFI~2.TEX")
	testing.expect(t, make_entry(v, "\xf0\x9f\x98\x80 new", {}, &e))
	testing.expect_value(t, fat.entry_name(&e), "\xf0\x9f\x98\x80 new")
	testing.expect(t, make_entry(v, "New Directory", {.Directory}, &d))
	testing.expect(t, .Directory in d.attr)
	testing.expect(t, d.cluster != 0)
	testing.expect(t, make_entry(v, "New Directory/inside.txt", {}, &e))
	testing.expect(t, !make_entry(v, "new.txt", {}, &e)) // taken, in another case
	testing.expect(t, !make_entry(v, "bad:name", {}, &e))
	testing.expect(t, !make_entry(v, "trailing.", {}, &e))
	testing.expect(t, !make_entry(v, "..", {}, &e))
	testing.expect_value(t, e.mtime, 1_893_553_444) // FAT keeps even seconds

	// Writing: a little, a lot (many clusters), at an offset past the end
	// (zeros between), appended to in pieces.
	testing.expect(t, put(v, "NEW.TXT", 0, transmute([]u8)string("new\n")))
	big := make([]u8, 200_000)
	defer delete(big)
	back := make([]u8, 200_100)
	defer delete(back)
	for &b, i in big {
		b = u8((i * 13 + i / 509) & 0xff)
	}
	testing.expect(t, put(v, "A new file with a long name.text", 0, big))
	testing.expect(t, put(v, "small.txt", 10_000, transmute([]u8)string("end")))
	all := true
	for off := 0; off < 30_000; off += 1000 {
		all = all && put(v, "New Directory/inside.txt", u64(off), big[off:off + 1000])
	}
	testing.expect(t, all)

	// Remount: everything is on the device.
	testing.expect_value(t, fat.mount(v, writable(&m)), vx.Status.Ok)
	reads(t, v, "new.txt", "new\n")
	testing.expect(t, walk(v, "a new file with a long name.text", &e))
	testing.expect_value(t, e.size, u32(len(big)))
	n, st := fat.read(v, &e, 0, back)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, slice.equal(back[:n], big))
	testing.expect(t, walk(v, "small.txt", &e))
	testing.expect_value(t, e.size, 10_003)
	n, st = fat.read(v, &e, 0, back)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 10_003)
	testing.expect(t, slice.all_of(back[:10_000], 0))
	testing.expect_value(t, string(back[10_000:10_003]), "end")
	testing.expect(t, walk(v, "New Directory/inside.txt", &e))
	n, st = fat.read(v, &e, 0, back)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, slice.equal(back[:n], big[:30_000]))
	testing.expect(t, walk(v, "SHORT.TXT", &e))
	testing.expect_value(t, e.mtime, 981_173_106) // untouched
	v.now = 1_893_553_445

	// Truncating: shorter, to nothing, longer.
	testing.expect(t, walk(v, "a new file with a long name.text", &e))
	testing.expect_value(t, fat.truncate(v, &e, 5000), vx.Status.Ok)
	testing.expect(t, walk(v, "a new file with a long name.text", &e))
	testing.expect_value(t, e.size, 5000)
	n, st = fat.read(v, &e, 0, back)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, slice.equal(back[:n], big[:5000]))
	testing.expect_value(t, fat.truncate(v, &e, 0), vx.Status.Ok)
	testing.expect_value(t, e.cluster, 0)
	testing.expect_value(t, fat.truncate(v, &e, 3), vx.Status.Ok)
	testing.expect(t, walk(v, "a new file with a long name.text", &e))
	testing.expect_value(t, e.size, 3)
	n, st = fat.read(v, &e, 0, back)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, slice.equal(back[:n], []u8{0, 0, 0}))

	// Renaming: in place to another case, to another directory, over a file;
	// a directory, whose ".." then names its new parent.
	moved: fat.Entry
	testing.expect(t, walk(v, "NEW.TXT", &e))
	testing.expect(t, walk(v, "", &d))
	testing.expect_value(t, fat.rename(v, &e, &d, "New.txt", &moved), vx.Status.Ok)
	testing.expect_value(t, fat.entry_name(&moved), "New.txt")
	reads(t, v, "New.txt", "new\n")
	testing.expect(t, walk(v, "New.txt", &e))
	testing.expect(t, walk(v, "New Directory", &d))
	testing.expect_value(t, fat.rename(v, &e, &d, "moved here.txt", &moved), vx.Status.Ok)
	testing.expect(t, !walk(v, "New.txt", &e))
	reads(t, v, "New Directory/moved here.txt", "new\n")
	testing.expect(t, walk(v, "small.txt", &e))
	testing.expect(t, walk(v, "New Directory", &d))
	testing.expect_value(t, fat.rename(v, &e, &d, "inside.txt", &moved), vx.Status.Ok) // replaces it
	testing.expect(t, walk(v, "New Directory/inside.txt", &e))
	testing.expect_value(t, e.size, 10_003)
	testing.expect(t, walk(v, "New Directory", &e))
	testing.expect(t, walk(v, "A Long Directory Name", &d))
	testing.expect_value(t, fat.rename(v, &e, &d, "Moved Directory", &moved), vx.Status.Ok)
	testing.expect(t, walk(v, "A Long Directory Name/Moved Directory/moved here.txt", &e))
	up, ust := fat.parent(v, e.node)
	testing.expect_value(t, ust, vx.Status.Ok)
	testing.expect_value(t, up, moved.node)
	up, ust = fat.parent(v, moved.node)
	testing.expect_value(t, ust, vx.Status.Ok)
	testing.expect(t, walk(v, "A Long Directory Name", &d))
	testing.expect_value(t, up, d.node)
	testing.expect(t, walk(v, "A Long Directory Name", &e))
	testing.expect(t, walk(v, "A Long Directory Name/Moved Directory", &d))
	testing.expect_value(t, fat.rename(v, &e, &d, "loop", &moved), vx.Status.Err_Invalid) // into itself

	// Removing: a file, a directory only when empty.
	testing.expect(t, walk(v, "A Long Directory Name/Moved Directory", &d))
	testing.expect_value(t, fat.remove(v, &d), vx.Status.Err_Exists)
	testing.expect(t, walk(v, "A Long Directory Name/Moved Directory/moved here.txt", &e))
	testing.expect_value(t, fat.remove(v, &e), vx.Status.Ok)
	testing.expect(t, walk(v, "A Long Directory Name/Moved Directory/inside.txt", &e))
	testing.expect_value(t, fat.remove(v, &e), vx.Status.Ok)
	testing.expect(t, walk(v, "A Long Directory Name/Moved Directory", &d))
	testing.expect_value(t, fat.remove(v, &d), vx.Status.Ok)
	testing.expect(t, !walk(v, "A Long Directory Name/Moved Directory", &d))

	// A directory grown past a cluster by many entries.
	testing.expect(t, make_entry(v, "grown", {.Directory}, &d))
	all = true
	for i in 0 ..< 300 {
		all = all && make_entry(v, fmt.tprintf("grown/a rather long file name %03d", i), {}, &e)
	}
	testing.expect(t, all)
	reads(t, v, "grown/A RATHER LONG FILE NAME 299", "")

	// The volume full: Err_No_Space, and what was written before it stays.
	testing.expect(t, make_entry(v, "filler", {}, &e))
	chunk := make([]u8, 65536)
	defer delete(chunk)
	st = .Ok
	for off: u64 = 0; st == .Ok && off < 64 << 20; off += u64(len(chunk)) {
		st = fat.write(v, &e, off, chunk)
	}
	testing.expect_value(t, st, vx.Status.Err_No_Space)
	testing.expect(t, walk(v, "filler", &e))
	testing.expect(t, e.size > 0)
	testing.expect_value(t, e.size % u32(len(chunk)), 0)
	testing.expect_value(t, fat.remove(v, &e), vx.Status.Ok)
	testing.expect_value(t, fat.flush(v), vx.Status.Ok)
	testing.expect_value(t, free_clusters(v), v.free_count)
	testing.expect(t, free_clusters(v) < free_before) // what is left: the new files and directories

	save(out, bytes) // for a check by fsck.fat -n
	// A device that fails part way through a create: an error, not a crash.
	// (It leaves orphaned long-name slots, which fsck.fat removes: so after the
	// image is saved.)
	m.writes_left = 3
	testing.expect(t, !make_entry(v, "failing with a long name.txt", {}, &e))
	m.writes_left = -1
}

@(test)
test_writes_fat12 :: proc(t: ^testing.T) {
	check_writes(t, "fat12.img", "out/host/fat12-written.img")
}

@(test)
test_writes_fat16 :: proc(t: ^testing.T) {
	check_writes(t, "fat16.img", "out/host/fat16-written.img")
}

@(test)
test_writes_fat32 :: proc(t: ^testing.T) {
	check_writes(t, "fat32.img", "out/host/fat32-written.img")
}

// What upstream's C (lib/vx-fat at 1976c1f, built with clang) leaves on the
// 64 MiB image after the steps of test_format below, to the save.
FORMATTED_SHA256 :: "77340614b02d7cb613f6da09fa46c0e20f1e70fcb4fc150c53e430f9c870cf86"

// format's FAT32, as install makes the ESP: mounted, written to as install
// writes it (directories, a file of many clusters), read back, and saved for
// a check by fsck.fat -n; one too small refused.
@(test)
test_format :: proc(t: ^testing.T) {
	bytes := make([]u8, 64 << 20)
	defer delete(bytes)
	m := new_image(bytes)
	dev := writable(&m)
	testing.expect_value(t, fat.format(dev, u64(len(bytes)) / 512, 2048, "VECTRA", 0x1234_5678), vx.Status.Ok)
	v := new(fat.Vol)
	defer free(v)
	testing.expect_value(t, fat.mount(v, dev), vx.Status.Ok)
	testing.expect_value(t, v.kind, fat.Kind.Fat32)
	testing.expect_value(t, fat.volume_label(v), "VECTRA")
	v.now = 1_893_553_445
	e, d: fat.Entry
	testing.expect(t, make_entry(v, "EFI", {.Directory}, &d))
	testing.expect(t, make_entry(v, "EFI/BOOT", {.Directory}, &d))
	testing.expect(t, make_entry(v, "EFI/vectra", {.Directory}, &d))
	testing.expect(t, make_entry(v, "EFI/vectra/a", {.Directory}, &d))
	testing.expect(t, make_entry(v, "EFI/vectra/a/kernel.elf", {}, &e))
	big := make([]u8, 300_000)
	defer delete(big)
	back := make([]u8, 300_000)
	defer delete(back)
	for &b, i in big {
		b = u8((i * 3 + i / 1021) & 0xff)
	}
	testing.expect(t, put(v, "EFI/vectra/a/kernel.elf", 0, big))
	testing.expect_value(t, fat.flush(v), vx.Status.Ok)
	testing.expect_value(t, fat.mount(v, dev), vx.Status.Ok)
	testing.expect(t, walk(v, "EFI/vectra/a/kernel.elf", &e))
	n, st := fat.read(v, &e, 0, back)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, u32(len(big)))
	testing.expect(t, slice.equal(back, big))
	digest: [sha2.DIGEST_SIZE_256]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, bytes)
	sha2.final(&ctx, digest[:])
	testing.expect_value(t, string(hex.encode(digest[:], context.temp_allocator)), FORMATTED_SHA256)
	save("out/host/fat32-formatted.img", bytes)
	testing.expect_value(t, fat.format(dev, 60_000, 0, "SMALL", 1), vx.Status.Err_Invalid) // under 65525 clusters
}

// Added here: hostile directories and offsets that upstream's C mishandles
// (docs/UPSTREAM-FINDINGS.md): a long-name slot numbered 0 first in the
// directory (upstream stores its units 13 places before its buffer), a long
// name of 20 slots of units at U+0800 and up (780 bytes of UTF-8, which
// overrun upstream's 766-byte name), and a write at an offset whose end
// wraps (upstream's check wraps with it and fills the volume with zeros).
@(test)
test_hostile :: proc(t: ^testing.T) {
	bytes := load("fat16.img")
	defer delete(bytes)
	if !testing.expect(t, len(bytes) > 0) {
		return
	}
	m := new_image(bytes)
	v := new(fat.Vol)
	defer free(v)
	testing.expect_value(t, fat.mount(v, writable(&m)), vx.Status.Ok)
	root_dir := bytes[int(v.root_start) * int(v.sector_size):]

	// A slot numbered 0, with the checksum dir_next starts with, in the
	// label's place: no name forms from it, and the listing is as before.
	label := root_dir[:32]
	saved: [32]u8
	copy(saved[:], label)
	slice.fill(label, 0)
	label[0], label[11] = 0x20, 0x0f
	testing.expect_value(t, fat.mount(v, readable(&m)), vx.Status.Ok)
	root := fat.root_entry(v)
	it, st := fat.open_dir(v, &root)
	testing.expect_value(t, st, vx.Status.Ok)
	count := 0
	e: fat.Entry
	for fat.dir_next(v, &it, &e) == .Ok {
		count += 1
	}
	testing.expect_value(t, count, 5)
	copy(label, saved[:])

	// Twenty slots of U+4E00 before a short entry they name.
	file := new_image(slice.clone(bytes))
	defer delete(file.bytes)
	dir := file.bytes[int(v.root_start) * int(v.sector_size):]
	short := "HOSTILE    "
	sum: u8
	for c in transmute([]u8)short {
		sum = (sum & 1) << 7 + sum >> 1 + c
	}
	slice.fill(dir[:32 * 22], 0)
	for k in 0 ..< 20 {
		s := dir[32 * k:][:32]
		s[0] = u8(20 - k) | (k == 0 ? 0x40 : 0)
		s[11], s[13] = 0x0f, sum
		for at in ([]int{1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30}) {
			s[at], s[at + 1] = 0x00, 0x4e
		}
	}
	copy(dir[32 * 20:], short)
	dir[32 * 20 + 11] = 0x20
	testing.expect_value(t, fat.mount(v, readable(&file)), vx.Status.Ok)
	root = fat.root_entry(v)
	it, st = fat.open_dir(v, &root)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, fat.dir_next(v, &it, &e), vx.Status.Ok)
	testing.expect_value(t, len(fat.entry_name(&e)), 780)
	testing.expect_value(t, fat.entry_name(&e)[:6], "\xe4\xb8\x80\xe4\xb8\x80")
	testing.expect_value(t, fat.entry_alias(&e), "HOSTILE")

	// An offset whose end wraps: refused, and nothing allocated.
	testing.expect_value(t, fat.mount(v, writable(&m)), vx.Status.Ok)
	testing.expect(t, walk(v, "lower.txt", &e))
	free_before := free_clusters(v)
	testing.expect_value(t, fat.write(v, &e, max(u64) - 1, transmute([]u8)string("xyz")), vx.Status.Err_No_Space)
	testing.expect_value(t, free_clusters(v), free_before)
}
