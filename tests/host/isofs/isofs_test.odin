// servers/isofs on the host: the program itself, linked against lib/rt, on
// tests/host/blkfake's fake kernel and block device, its p9.Fs then driven
// through lib/p9's server framework and client with the posix and xattr
// extensions. Upstream has no host test of isofs (its iso_test tests
// lib/vx-iso, ported as tests/host/iso); these cases follow its scenario's
// script, tests/user/isofstest.rc, check for check, on the image the
// scenario reads: make_test_iso's, as upstream's write_iso wrote it
// (tests/host/iso's fixture, which ./build check compares this tree's
// writer with). As the scenario does, one instance reads its Rock Ridge,
// another, with -r, its Joliet tree; a third, with -r -j, plain ISO 9660.
//
// The program's state and the fake kernel are global, so it is one test.
package isofs_test

import vx "abi:vx"
import "core:bytes"
import "core:compress/gzip"
import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:iso"
import "vx:p9"
import isofs "../../../servers/isofs"
import "../blkfake"
import "../p9test"

FIXTURE :: #load("../iso/test.iso.gz")
IMAGE_SECTORS :: 194
BIG_LBA :: 47 // big.bin's extent: the image's tail, which the fixture leaves out
BIG_SIZE :: 300_000

LONG :: "A Long Mixed-Case Name That Goes On And On, Past What One Directory Record Can Hold, So Its Rock Ridge NM Entry Has To Continue In The Directory's Continuation Area, Which Is The Point Of It.txt"

big_byte :: proc(i: int) -> u8 {
	return u8((i * 7 + i / 251) & 0xff)
}

// make_test_iso's image, whole; the caller deletes it.
load_image :: proc(t: ^testing.T) -> []u8 {
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := gzip.load_from_bytes(FIXTURE, &buf); err != nil {
		testing.fail_now(t, "../iso/test.iso.gz does not decompress")
	}
	image := make([]u8, IMAGE_SECTORS * iso.SECTOR)
	copy(image, bytes.buffer_to_bytes(&buf))
	for i in 0 ..< BIG_SIZE {
		image[BIG_LBA * iso.SECTOR + i] = big_byte(i)
	}
	return image
}

Session :: struct {
	srv:        p9.Server,
	shared:     p9.Shared,
	tbuf, rbuf: [8192]u8,
	c:          p9.Client,
	root:       p9.Fid,
}

connect :: proc(t: ^testing.T, s: ^Session) {
	s.srv = {fs = isofs.server.fs, max_msize = 8192, supported = isofs.server.supported, shared = &s.shared}
	s.c = {rpc = p9test.loopback, ctx = &s.srv, tbuf = s.tbuf[:], rbuf = s.rbuf[:]}
	testing.expect_value(t, p9.client_version(&s.c, 8192, {.Posix, .Xattr}), vx.Status.Ok)
	e: vx.Status
	s.root, e = p9.client_attach(&s.c, "")
	testing.expect_value(t, e, vx.Status.Ok)
}

// What the file at path reads as, whole, or why not.
cat :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> string {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return fmt.tprintf("(walk: %v)", e)
	}
	defer _ = p9.client_clunk(c, f)
	if e = p9.client_open(c, f, p9.OREAD); e != .Ok {
		return fmt.tprintf("(open: %v)", e)
	}
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

readlink :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> string {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return fmt.tprintf("(walk: %v)", e)
	}
	defer _ = p9.client_clunk(c, f)
	target, re := p9.client_readlink(c, f)
	return re == .Ok ? strings.clone(target, context.temp_allocator) : fmt.tprintf("(readlink: %v)", re)
}

// How many entries the directory at path has.
count :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> int {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return -1
	}
	defer _ = p9.client_clunk(c, f)
	if p9.client_open(c, f, p9.OREAD) != .Ok {
		return -1
	}
	n := 0
	dir: [8192]u8
	for off := 0; true; {
		got, re := p9.client_read(c, f, u64(off), dir[:])
		if re != .Ok {
			return -1
		}
		if got == 0 {
			break
		}
		it := p9.Dir_Entries{buf = dir[:got]}
		for _ in p9.next_entry(&it) {
			n += 1
		}
		off += got
	}
	return n
}

exists :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> bool {
	f, e := p9.client_walk(c, root, path)
	if e == .Ok {
		_ = p9.client_clunk(c, f)
	}
	return e == .Ok
}

@(test)
test_isofs :: proc(t: ^testing.T) {
	image := load_image(t)
	defer delete(image)
	blkfake.disk = {image = image, sector = 2048, readonly = true, max_transfer = 64 * 1024}
	rock(t)
	joliet(t)
	plain(t)
}

// /n in tests/user/isofstest.rc: Rock Ridge, owned by vectra.
rock :: proc(t: ^testing.T) {
	blkfake.spawn("srv:disk1", "-u", "vectra")
	testing.expect_value(t, isofs.start(), "cannot serve") // mounted, then no port to serve on
	testing.expect_value(t, blkfake.log(), "isofs: /srv/disk1: ISO 9660 with Rock Ridge \"VECTRAOS\", 194 sectors\n")
	s := new(Session, context.temp_allocator)
	connect(t, s)
	c, root := &s.c, s.root

	testing.expect_value(t, cat(c, root, LONG), "long\n") // long
	testing.expect_value(t, cat(c, root, "\xc3\x9cn\xc3\xaf" + "code file.txt"), "unicode\n") // unicode
	testing.expect_value(t, cat(c, root, "\xf0\x9f\x98\x80 smile.txt"), "smile\n") // smile
	testing.expect_value(t, cat(c, root, "dir with spaces/Same Name.txt"), "upper\n") // upper
	testing.expect_value(t, cat(c, root, "dir with spaces/same name.txt"), "lower\n") // lower
	testing.expect_value(t, cat(c, root, "deep/er/still/deeper/file.txt"), "deep\n") // deep
	testing.expect_value(t, readlink(c, root, "link-to-readme"), "README.txt") // readlink
	testing.expect_value(t, cat(c, root, "README.txt"), "readme\n") // follow: where the link leads
	testing.expect_value(t, readlink(c, root, "abs-link"), "/boot/limine/limine.conf") // absolute
	// relative: up-link's target, from deep/er, reached through its parents.
	testing.expect_value(t, readlink(c, root, "deep/er/up-link"), "../../dir with spaces/./same name.txt")
	testing.expect_value(t, cat(c, root, "deep/er/../../dir with spaces/same name.txt"), "lower\n")
	big := cat(c, root, "big.bin")
	testing.expect_value(t, len(big), BIG_SIZE) // big
	for i in 0 ..< min(len(big), BIG_SIZE) {
		if big[i] != big_byte(i) {
			testing.expectf(t, false, "big.bin differs at byte %d", i)
			break
		}
	}
	testing.expect_value(t, count(c, root, ""), 11) // root
	f, e := p9.client_walk(c, root, "")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect(t, p9.client_create(c, f, "new", 0o644, p9.OWRITE) != .Ok) // write refused
	_ = p9.client_clunk(c, f)
	f, e = p9.client_walk(c, root, "README.txt")
	testing.expect_value(t, p9.client_open(c, f, p9.OWRITE), vx.Status.Err_Access)
	_ = p9.client_clunk(c, f)

	// Beyond the script: what stat says.
	st: p9.Stat
	testing.expect_value(t, p9test.stat_of(c, root, "link-to-readme", &st), vx.Status.Ok)
	testing.expect_value(t, st.mode, p9.DMSYMLINK | 0o777)
	testing.expect_value(t, st.length, 0)
	testing.expect_value(t, st.uid, "vectra")
	testing.expect_value(t, p9test.stat_of(c, root, "deep", &st), vx.Status.Ok)
	testing.expect_value(t, st.mode, p9.DMDIR | 0o555)
	testing.expect_value(t, st.qid.type, p9.QTDIR)
	testing.expect_value(t, p9test.stat_of(c, root, "README.txt", &st), vx.Status.Ok)
	testing.expect_value(t, st.mode, 0o444)
	testing.expect_value(t, st.length, 7)
	testing.expect_value(t, st.mtime, 1_759_536_000) // SOURCE_DATE_EPOCH's, as the image was written
}

// /j in tests/user/isofstest.rc: the Joliet tree (-r), owned by none.
joliet :: proc(t: ^testing.T) {
	blkfake.spawn("srv:disk1", "-r")
	testing.expect_value(t, isofs.start(), "cannot serve")
	testing.expect_value(t, blkfake.log(), "isofs: /srv/disk1: ISO 9660 with Joliet \"VECTRAOS\", 194 sectors\n")
	s := new(Session, context.temp_allocator)
	connect(t, s)
	c, root := &s.c, s.root

	testing.expect_value(t, cat(c, root, "readme.TXT"), "readme\n") // joliet-case
	testing.expect_value(t, cat(c, root, "A Long Mixed-Case Name That Goes On And On, Past What One Direct"), "long\n") // joliet-cut
	testing.expect(t, !exists(c, root, "link-to-readme")) // joliet-links
	testing.expect_value(t, cat(c, root, "\xf0\x9f\x98\x80 smile.txt"), "smile\n") // a surrogate pair
	st: p9.Stat
	testing.expect_value(t, p9test.stat_of(c, root, "README.txt", &st), vx.Status.Ok)
	testing.expect_value(t, st.uid, "none")
}

// Neither (-r -j): ISO 9660's own names, lower-cased.
plain :: proc(t: ^testing.T) {
	blkfake.spawn("srv:disk1", "-r", "-j")
	testing.expect_value(t, isofs.start(), "cannot serve")
	testing.expect_value(t, blkfake.log(), "isofs: /srv/disk1: ISO 9660 \"VECTRAOS\", 194 sectors\n")
	s := new(Session, context.temp_allocator)
	connect(t, s)
	c, root := &s.c, s.root
	testing.expect_value(t, cat(c, root, "readme.txt"), "readme\n")
	testing.expect_value(t, cat(c, root, "dir_with_spaces/same_name~1.txt"), "upper\n") // the second of two names that differ only in case
	testing.expect_value(t, count(c, root, ""), 11) // the links are there, as empty files
}
