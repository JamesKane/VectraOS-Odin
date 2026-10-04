// servers/dosfs on the host: the program itself, linked against lib/rt, on
// tests/host/blkfake's fake kernel and block device, its p9.Fs then driven
// through lib/p9's server framework and client with the posix and xattr
// extensions. Upstream has no host test of dosfs (its fat_test tests
// lib/vx-fat, ported as tests/host/fat); these cases follow its scenarios'
// scripts, tests/user/dosfswrite.rc and dosfstest.rc, check for check, on
// disks mtools makes as upstream's ./build makes them: a fresh FAT16 test
// disk with no partition table (fat_disk), written; then a FAT32 volume laid
// out as the boot disk's ESP, read-only. What was written is then checked by
// another implementation, the host's fsck, as upstream's runner checks the
// dosfswrite scenario's disk: fsck.fat -n must find it sound; or, on macOS,
// fsck_msdos -n must find nothing it does not find on the disk mtools made
// (it warns of a "long filename entry for volume label" on every volume
// mtools labels).
//
// The program's state and the fake kernel are global, so it is one test.
package dosfs_test

import vx "abi:vx"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"
import "vx:p9"
import dosfs "../../../servers/dosfs"
import "../blkfake"
import "../p9test"

DIR :: "out/host/dosfs-disks" // not out/host/dosfs: ./build check's test binary

when ODIN_OS == .Darwin {
	MFORMAT :: "/opt/homebrew/bin/mformat"
	MMD :: "/opt/homebrew/bin/mmd"
	MCOPY :: "/opt/homebrew/bin/mcopy"
	FSCK :: []string{"/sbin/fsck_msdos", "-n"}
} else {
	MFORMAT :: "/usr/bin/mformat"
	MMD :: "/usr/bin/mmd"
	MCOPY :: "/usr/bin/mcopy"
	FSCK :: []string{"/usr/bin/fsck.fat", "-n"}
}

big_byte :: proc(i: int) -> u8 {
	return u8((i * 7 + i / 251) & 0xff)
}

exec :: proc(cmd: ..string) -> (ok: bool, output: string) {
	state, stdout, stderr, err := os.process_exec({command = cmd, env = {"MTOOLS_SKIP_CHECK=1", "TZ=UTC"}}, context.temp_allocator)
	ok = err == nil && state.exited && state.exit_code == 0
	if err != nil {
		return false, fmt.tprintf("%v", err)
	}
	return ok, fmt.tprintf("%s%s", string(stdout), string(stderr))
}

run :: proc(t: ^testing.T, cmd: ..string, loc := #caller_location) -> bool {
	ok, output := exec(..cmd)
	testing.expectf(t, ok, "%v failed: %s", cmd, output, loc = loc)
	return ok
}

// What the host's fsck finds wrong with an image, a line each; none if it
// finds it sound. Its progress and summary lines are left out.
fsck_findings :: proc(img: string) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, ..FSCK)
	append(&cmd, img)
	ok, output := exec(..cmd[:])
	if ok {
		return nil
	}
	found := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines_iterator(&output) {
		summary := strings.has_prefix(line, "Warning: ") && strings.contains(line, " files, ")
		if line != "" && !strings.has_prefix(line, "**") && !summary {
			append(&found, line)
		}
	}
	return found[:]
}

// The host's fsck on the image written from fresh: sound, or (fsck_msdos)
// no finding the fresh image lacks.
fsck :: proc(t: ^testing.T, written, fresh: string) {
	when ODIN_OS == .Darwin {
		known := fsck_findings(fresh)
		for f in fsck_findings(written) {
			testing.expectf(t, slice.contains(known, f), "fsck_msdos -n %s: %s", written, f)
		}
	} else {
		testing.expectf(t, len(fsck_findings(written)) == 0, "fsck.fat -n %s: %v", written, fsck_findings(written))
	}
}

put_file :: proc(path: string, data: []u8) -> bool {
	return os.write_entire_file(path, data) == nil
}

// A test disk of mib MiB that is one FAT volume, as upstream's fat_disk
// makes it: mtools, labelled VECTRAFAT; FAT32 with fat32.
fat_disk :: proc(t: ^testing.T, path: string, mib: int, fat32: bool) -> bool {
	_ = os.remove(path)
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, MFORMAT, "-C", "-i", path, "-v", "VECTRAFAT", "-T", fmt.tprint(mib << 11), "-h", "64", "-s", "32")
	if fat32 {
		append(&cmd, "-F")
	}
	append(&cmd, "::")
	return run(t, ..cmd[:])
}

load :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	return err == nil ? data : nil
}

Session :: struct {
	srv:        p9.Server,
	shared:     p9.Shared,
	tbuf, rbuf: [8192]u8,
	c:          p9.Client,
	root:       p9.Fid,
}

connect :: proc(t: ^testing.T, s: ^Session) {
	s.srv = {fs = dosfs.server.fs, max_msize = 8192, supported = dosfs.server.supported, shared = &s.shared}
	s.c = {rpc = p9test.loopback, ctx = &s.srv, tbuf = s.tbuf[:], rbuf = s.rbuf[:]}
	testing.expect_value(t, p9.client_version(&s.c, 8192, {.Posix, .Xattr}), vx.Status.Ok)
	e: vx.Status
	s.root, e = p9.client_attach(&s.c, "")
	testing.expect_value(t, e, vx.Status.Ok)
}

// Opens path (from root) in mode; the fid, or why not.
open :: proc(c: ^p9.Client, root: p9.Fid, path: string, mode: p9.Open_Mode) -> (f: p9.Fid, e: vx.Status) {
	f = p9.client_walk(c, root, path) or_return
	if e = p9.client_open(c, f, mode); e != .Ok {
		_ = p9.client_clunk(c, f)
	}
	return
}

// Creates path's last name in its directory (from root), opened in mode.
create :: proc(c: ^p9.Client, root: p9.Fid, path: string, perm: u32, mode := p9.ORDWR) -> (f: p9.Fid, e: vx.Status) {
	slash := strings.last_index_byte(path, '/')
	f = p9.client_walk(c, root, slash < 0 ? "" : path[:slash]) or_return
	if e = p9.client_create(c, f, path[slash + 1:], perm, mode); e != .Ok {
		_ = p9.client_clunk(c, f)
	}
	return
}

write_all :: proc(c: ^p9.Client, f: p9.Fid, offset: u64, data: []u8) -> vx.Status {
	for off := 0; off < len(data); {
		n := p9.client_write(c, f, offset + u64(off), data[off:]) or_return
		if n == 0 {
			return .Err_Io
		}
		off += n
	}
	return .Ok
}

// echo text >path: created, or opened with truncation, and written.
echo :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid, path, text: string, loc := #caller_location) {
	f, e := open(c, root, path, {access = .Write, trunc = true})
	if e == .Err_Not_Found {
		f, e = create(c, root, path, 0o644, p9.OWRITE)
	}
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	testing.expect_value(t, write_all(c, f, 0, transmute([]u8)text), vx.Status.Ok, loc = loc)
	_ = p9.client_clunk(c, f)
}

// What the file at path reads as, whole, or why not.
cat :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> string {
	f, e := open(c, root, path, p9.OREAD)
	if e != .Ok {
		return fmt.tprintf("(%v)", e)
	}
	defer _ = p9.client_clunk(c, f)
	b := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	off := 0
	for {
		n, re := p9.client_read(c, f, u64(off), buf[:])
		if re != .Ok {
			return fmt.tprintf("(read: %v)", re)
		}
		if n == 0 {
			break
		}
		strings.write_bytes(&b, buf[:n])
		off += n
	}
	return strings.to_string(b)
}

// ls: the names in a directory, sorted, as ls prints them.
ls :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> string {
	f, e := open(c, root, path, p9.OREAD)
	if e != .Ok {
		return fmt.tprintf("(%v)", e)
	}
	defer _ = p9.client_clunk(c, f)
	names := make([dynamic]string, context.temp_allocator)
	dir: [8192]u8
	off := 0
	for {
		n, re := p9.client_read(c, f, u64(off), dir[:])
		if re != .Ok {
			return fmt.tprintf("(read: %v)", re)
		}
		if n == 0 {
			break
		}
		it := p9.Dir_Entries{buf = dir[:n]}
		for st in p9.next_entry(&it) {
			append(&names, strings.clone(st.name, context.temp_allocator))
		}
		off += n
	}
	slice.sort(names[:])
	return strings.join(names[:], " ", context.temp_allocator)
}

mode_of :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> u32 {
	st: p9.Stat
	if p9test.stat_of(c, root, path, &st) != .Ok {
		return 0xffff_ffff
	}
	return st.mode
}

exists :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> bool {
	f, e := p9.client_walk(c, root, path)
	if e == .Ok {
		_ = p9.client_clunk(c, f)
	}
	return e == .Ok
}

remove :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> vx.Status {
	f := p9.client_walk(c, root, path) or_return
	return p9.client_remove(c, f) // the fid goes, whatever is said
}

// mv: Trenameat from one directory to another (from root).
mv :: proc(c: ^p9.Client, root: p9.Fid, from, to: string) -> vx.Status {
	split :: proc(p: string) -> (dir, name: string) {
		slash := strings.last_index_byte(p, '/')
		return slash < 0 ? "" : p[:slash], p[slash + 1:]
	}
	fd, fname := split(from)
	td, tname := split(to)
	olddir := p9.client_walk(c, root, fd) or_return
	defer _ = p9.client_clunk(c, olddir)
	newdir := p9.client_walk(c, root, td) or_return
	defer _ = p9.client_clunk(c, newdir)
	return p9.client_renameat(c, olddir, fname, newdir, tname)
}

chmod :: proc(c: ^p9.Client, root: p9.Fid, path: string, mode: u32) -> vx.Status {
	f := p9.client_walk(c, root, path) or_return
	defer _ = p9.client_clunk(c, f)
	return p9.client_setattr(c, f, {valid = {.Mode}, mode = mode})
}

@(test)
test_dosfs :: proc(t: ^testing.T) {
	testing.expect(t, os.make_directory_all(DIR) == nil || os.exists(DIR))
	writing(t)
	reading(t)
}

// tests/user/dosfswrite.rc's checks, on a fresh FAT16 disk (fat=16 disk=64).
writing :: proc(t: ^testing.T) {
	img :: DIR + "/fat16.img"
	if !fat_disk(t, img, 64, false) {
		return
	}
	blkfake.disk = {image = load(img), sector = 512, max_transfer = 64 * 1024}
	defer delete(blkfake.disk.image)
	blkfake.spawn("srv:disk1", "-u", "vectra")
	testing.expect_value(t, dosfs.start(), "cannot serve") // mounted, then no port to serve on
	testing.expect(t, strings.has_prefix(blkfake.log(), "dosfs: /srv/disk1: FAT16 \"VECTRAFAT\", "))
	testing.expect(t, strings.has_suffix(blkfake.log(), " clusters of 1024 bytes\n"))

	s := new(Session, context.temp_allocator)
	connect(t, s)
	c, root := &s.c, s.root

	for d in ([]string{"dir", "A Long Directory"}) {
		f, e := create(c, root, d, p9.DMDIR | 0o755, p9.OREAD)
		testing.expect_value(t, e, vx.Status.Ok)
		_ = p9.client_clunk(c, f)
	}
	echo(t, c, root, "dir/a long file name.txt", "hello\n")
	echo(t, c, root, "small.txt", "small\n")
	echo(t, c, root, "UPPER.TXT", "UPPER\n")
	testing.expect_value(t, cat(c, root, "DIR/A LONG FILE NAME.TXT"), "hello\n") // long
	testing.expect_value(t, ls(c, root, ""), "A Long Directory UPPER.TXT dir small.txt") // names

	// Many clusters: a program, copied and compared (copy).
	big := make([]u8, 300_000, context.temp_allocator)
	for &b, i in big {
		b = big_byte(i)
	}
	f, e := create(c, root, "dir/copy", 0o755, p9.OWRITE)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, write_all(c, f, 0, big), vx.Status.Ok)
	_ = p9.client_clunk(c, f)
	testing.expect(t, cat(c, root, "dir/copy") == string(big))

	// Appending, and truncation as a file is opened.
	echo(t, c, root, "trunc", "one two three\n")
	f, e = open(c, root, "trunc", p9.OWRITE)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, write_all(c, f, 14, transmute([]u8)string("four\n")), vx.Status.Ok)
	_ = p9.client_clunk(c, f)
	testing.expect_value(t, cat(c, root, "trunc"), "one two three\nfour\n") // append
	echo(t, c, root, "trunc", "one\n") // opened with truncation, then shorter than it was
	testing.expect_value(t, cat(c, root, "trunc"), "one\n") // truncate

	// Renames: in a directory, across directories, over a file; a directory.
	testing.expect_value(t, mv(c, root, "small.txt", "renamed.txt"), vx.Status.Ok)
	testing.expect_value(t, cat(c, root, "renamed.txt"), "small\n") // rename
	testing.expect_value(t, mv(c, root, "renamed.txt", "A Long Directory/moved.txt"), vx.Status.Ok)
	testing.expect_value(t, cat(c, root, "A Long Directory/moved.txt"), "small\n") // across
	testing.expect_value(t, mv(c, root, "UPPER.TXT", "A Long Directory/moved.txt"), vx.Status.Ok)
	testing.expect_value(t, cat(c, root, "A Long Directory/moved.txt"), "UPPER\n") // over
	testing.expect_value(t, mv(c, root, "A Long Directory", "dir/inner"), vx.Status.Ok)
	testing.expect_value(t, cat(c, root, "dir/inner/moved.txt"), "UPPER\n") // dirmove

	// Removal: a file; a directory only when empty.
	testing.expect_value(t, remove(c, root, "dir/inner/moved.txt"), vx.Status.Ok)
	testing.expect(t, !exists(c, root, "dir/inner/moved.txt")) // rmfile
	testing.expect(t, remove(c, root, "dir") != .Ok) // rmdir-full
	testing.expect_value(t, remove(c, root, "dir/inner"), vx.Status.Ok)
	testing.expect(t, !exists(c, root, "dir/inner")) // rmdir

	// chmod: the owner's write bit is FAT's read-only bit.
	testing.expect_value(t, chmod(c, root, "trunc", 0o444), vx.Status.Ok)
	testing.expect_value(t, mode_of(c, root, "trunc"), 0o444) // readonly
	testing.expect_value(t, chmod(c, root, "trunc", 0o644), vx.Status.Ok)
	testing.expect_value(t, mode_of(c, root, "trunc"), 0o644) // writable

	// Beyond the script: what stat says of the rest, and that nothing was
	// left unflushed.
	st: p9.Stat
	testing.expect_value(t, p9test.stat_of(c, root, "dir", &st), vx.Status.Ok)
	testing.expect_value(t, st.mode, p9.DMDIR | 0o755)
	testing.expect_value(t, st.uid, "vectra")
	testing.expect_value(t, st.mtime, 1_759_536_004) // the fake kernel's UTC, 1759536005, in FAT's 2-second steps
	testing.expect_value(t, p9test.stat_of(c, root, "dir/copy", &st), vx.Status.Ok)
	testing.expect_value(t, st.length, 300_000)
	testing.expect(t, blkfake.disk.flushes > 0)

	// What the disk holds now, checked by another implementation.
	written :: DIR + "/fat16-written.img"
	testing.expect(t, put_file(written, blkfake.disk.image))
	fsck(t, written, img)
}

// tests/user/dosfstest.rc's checks, read-only (-r) on a FAT32 volume laid
// out as ./build lays out the boot disk's ESP.
reading :: proc(t: ^testing.T) {
	img :: DIR + "/esp.img"
	src :: DIR + "/esp-src"
	_ = os.remove_all(src)
	testing.expect(t, os.make_directory_all(src) == nil)
	big := make([]u8, 300_000, context.temp_allocator)
	for &b, i in big {
		b = big_byte(i)
	}
	testing.expect(t, put_file(src + "/BOOTX64.EFI", transmute([]u8)string("loader\n")))
	testing.expect(t, put_file(src + "/limine.conf", transmute([]u8)string("timeout: 0\n\n/VectraOS\n")))
	testing.expect(t, put_file(src + "/bootfs.tar", big))
	if !fat_disk(t, img, 64, true) {
		return
	}
	run(t, MMD, "-i", img, "::/EFI", "::/EFI/BOOT", "::/boot", "::/boot/vx", "::/boot/limine")
	run(t, MCOPY, "-i", img, src + "/BOOTX64.EFI", "::/EFI/BOOT/BOOTX64.EFI")
	run(t, MCOPY, "-i", img, src + "/limine.conf", "::/boot/limine/limine.conf")
	run(t, MCOPY, "-i", img, src + "/bootfs.tar", "::/boot/vx/bootfs.tar")

	blkfake.disk = {image = load(img), sector = 512, max_transfer = 64 * 1024}
	defer delete(blkfake.disk.image)
	blkfake.spawn("srv:disk0.esp", "-r", "-u", "vectra")
	testing.expect_value(t, dosfs.start(), "cannot serve")
	testing.expect(t, strings.has_prefix(blkfake.log(), "dosfs: /srv/disk0.esp: FAT32 \"VECTRAFAT\", "))
	testing.expect(t, strings.has_suffix(blkfake.log(), " clusters of 512 bytes, read-only\n"))

	s := new(Session, context.temp_allocator)
	connect(t, s)
	c, root := &s.c, s.root
	testing.expect_value(t, ls(c, root, ""), "EFI boot") // root
	testing.expect_value(t, ls(c, root, "efi/boot"), "BOOTX64.EFI") // case
	testing.expect(t, strings.has_prefix(cat(c, root, "boot/limine/limine.conf"), "timeout: 0\n")) // conf
	testing.expect_value(t, mode_of(c, root, "boot/limine/limine.conf"), 0o444) // mode
	testing.expect(t, cat(c, root, "boot/vx/bootfs.tar") == string(big)) // tar: many clusters, whole
	f, e := create(c, root, "new", 0o644, p9.OWRITE)
	if e == .Ok {
		_ = p9.client_clunk(c, f)
	}
	testing.expect_value(t, e, vx.Status.Err_Access) // write refused
	testing.expect_value(t, mode_of(c, root, "boot"), p9.DMDIR | 0o555)
	testing.expect_value(t, blkfake.disk.writes, 0)
}
