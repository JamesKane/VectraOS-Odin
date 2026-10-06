// lib/p9's codec, ported from upstream's tests/host/p9_codec_test.c. Every
// message type round-trips with every field set; every truncation of each,
// and a trailing byte, is refused; and the specific traps (long walks, NUL in
// names, counts past the end, unknown types) are refused too.
package p9_codec_test

import vx "abi:vx"
import "core:encoding/hex"
import "core:strconv"
import "core:strings"
import "core:testing"
import "vx:p9"

@(rodata)
data := [5]u8{1, 2, 3, 4, 5}

// A message of the given type with every field it carries set to something
// distinctive. Its stat entry is written into stat.
full_message :: proc(type: p9.Type, stat: []u8) -> p9.Msg {
	st := p9.Stat {
		type = 1,
		dev = 2,
		qid = {p9.QTDIR, 3, 4},
		mode = p9.DMDIR | 0o755,
		length = 9,
		name = "dir",
		uid = "jk",
		gid = "jk",
		muid = "",
	}
	stat_len := p9.stat_encode(&st, stat)
	m := p9.Msg {
		type = type,
		tag = 7,
		fid = 11,
		newfid = 12,
		afid = p9.NOFID,
		msize = 8192,
		iounit = 8168,
		perm = 0o644,
		count = 5,
		offset = 0x1234_5678_9abc,
		mode = p9.ORDWR,
		oldtag = 3,
		version = "9P2000.x/1 +dref",
		uname = "jk",
		aname = "/srv",
		ename = "file does not exist",
		name = "new.txt",
		qid = {p9.QTFILE, 9, 99},
		nwname = 3,
		wname = {0 = "a", 1 = "..", 2 = "c"},
		nwqid = 2,
		wqid = {0 = {p9.QTDIR, 1, 2}, 1 = {p9.QTFILE, 3, 4}},
		data = data[:],
		stat = stat[:stat_len],
		name2 = "target",
		gid = 13,
		mask = p9.GETATTR_BASIC,
		datasync = 1,
		attr = {
			valid = p9.GETATTR_BASIC,
			qid = {p9.QTFILE, 5, 55},
			mode = p9.S_IFREG | 0o644,
			uid = 1,
			gid = 2,
			nlink = 3,
			size = 4,
			blksize = 4096,
			blocks = 8,
			atime_sec = 10,
			atime_nsec = 11,
			mtime_sec = 12,
			mtime_nsec = 13,
			ctime_sec = 14,
			ctime_nsec = 15,
			btime_sec = 16,
			btime_nsec = 17,
			gen = 18,
			data_version = 19,
		},
		lock_type = .Write,
		lock_flags = {.Block},
		start = 100,
		length = 50,
		proc_id = 42,
		client_id = "c",
		status = .Blocked,
		holds = 2,
		token = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16},
		whence = .End,
		desc_flags = {.Append},
		setattr = {
			valid = {.Mode, .Size, .Mtime_Set},
			mode = 0o600,
			uid = 3,
			gid = 4,
			size = 5,
			atime_sec = 6,
			atime_nsec = 7,
			mtime_sec = 8,
			mtime_nsec = 9,
		},
	}
	return m
}

// Not upstream's: every message type, full_message's way, encodes to the
// bytes upstream's p9_encode writes for its own full_message (upstream.txt,
// from a harness built with clang against M4's codec, the P4 cross-check, and
// again against M5's, with map and dref, and against d26fbc7's, with
// 9P2000.L's).
@(test)
test_upstream_bytes :: proc(t: ^testing.T) {
	UPSTREAM :: #load("upstream.txt", string)
	buf, stat: [512]u8
	want := UPSTREAM
	types := 0
	for line in strings.split_lines_iterator(&want) {
		num, _, hex_bytes := strings.partition(line, " ")
		ty, ok := strconv.parse_int(num, 10)
		if !testing.expectf(t, ok, "upstream.txt: %q", line) {
			continue
		}
		m := full_message(p9.Type(ty), stat[:])
		n := p9.encode(&m, buf[:])
		got := hex.encode(buf[:n], context.temp_allocator)
		testing.expectf(t, string(got) == hex_bytes, "%s: %s, upstream's %s", p9.MESSAGES[ty].name, got, hex_bytes)
		types += 1
	}
	testing.expect_value(t, types, 74)
}

// The fields 9P2000.L's messages add come back as they went.
@(test)
test_posix_fields :: proc(t: ^testing.T) {
	buf, stat: [512]u8
	m := full_message(.Rgetattr, stat[:])
	d: p9.Msg
	n := p9.encode(&m, buf[:])
	testing.expect_value(t, n, 7 + 8 + 13 + 12 + 15 * 8) // Rgetattr's fixed size
	testing.expect_value(t, p9.decode(buf[:n], &d), vx.Status.Ok)
	testing.expect_value(t, d.attr.valid, p9.GETATTR_BASIC)
	testing.expect_value(t, transmute(u64)d.attr.valid, 0x7ff)
	testing.expect_value(t, d.attr.qid.path, 55)
	testing.expect_value(t, d.attr.mode, p9.S_IFREG | 0o644)
	testing.expect_value(t, d.attr.mtime_nsec, 13)
	testing.expect_value(t, d.attr.data_version, 19)
	m = full_message(.Tsetattr, stat[:])
	n = p9.encode(&m, buf[:])
	testing.expect_value(t, n, 7 + 4 + 4 + 12 + 5 * 8)
	testing.expect_value(t, p9.decode(buf[:n], &d), vx.Status.Ok)
	testing.expect_value(t, d.setattr.valid, m.setattr.valid)
	testing.expect_value(t, transmute(u32)d.setattr.valid, 0x109) // MODE | SIZE | MTIME_SET
	testing.expect_value(t, d.setattr.size, 5)
	testing.expect_value(t, d.setattr.mode, 0o600)
	testing.expect_value(t, d.setattr.mtime_sec, 8)
	testing.expect_value(t, d.setattr.mtime_nsec, 9)
	m = full_message(.Tjoin, stat[:])
	n = p9.encode(&m, buf[:])
	testing.expect_value(t, n, 7 + 4 + 16)
	testing.expect_value(t, p9.decode(buf[:n], &d), vx.Status.Ok)
	testing.expect_value(t, d.newfid, 12)
	testing.expect_value(t, d.token[15], 16)
	m = full_message(.Tlock, stat[:])
	n = p9.encode(&m, buf[:])
	testing.expect_value(t, p9.decode(buf[:n], &d), vx.Status.Ok)
	testing.expect_value(t, d.lock_type, p9.Lock_Type.Write)
	testing.expect_value(t, d.start, 100)
	testing.expect_value(t, d.length, 50)
	testing.expect_value(t, d.proc_id, 42)
	testing.expect_value(t, len(d.client_id), 1)
	m = full_message(.Trenameat, stat[:])
	n = p9.encode(&m, buf[:])
	testing.expect_value(t, p9.decode(buf[:n], &d), vx.Status.Ok)
	testing.expect_value(t, d.fid, 11)
	testing.expect_value(t, d.newfid, 12)
	testing.expect_value(t, len(d.name), 7)
	testing.expect_value(t, len(d.name2), 6)
}

@(test)
test_round_trips :: proc(t: ^testing.T) {
	buf, again, stat: [512]u8
	types := 0
	for ty in 0 ..< 256 {
		if !p9.known(p9.Type(ty)) {
			continue
		}
		types += 1
		name := p9.MESSAGES[ty].name
		m := full_message(p9.Type(ty), stat[:])
		d: p9.Msg
		n := p9.encode(&m, buf[:])
		testing.expectf(t, n >= 7, "%s encodes in %d bytes", name, n)
		st := p9.decode(buf[:n], &d)
		testing.expectf(t, st == .Ok, "%s does not decode: %v", name, st)
		testing.expectf(t, int(d.type) == ty, "%s decodes as %v", name, d.type)
		testing.expectf(t, d.tag == 7, "%s decodes with tag %d", name, d.tag)
		again_n := p9.encode(&d, again[:])
		testing.expectf(t, again_n == n, "%s re-encodes in %d bytes, not %d", name, again_n, n)
		testing.expectf(t, string(buf[:n]) == string(again[:n]), "%s re-encodes differently", name)

		// Every shorter length, with the size field saying so, is malformed.
		for length in 0 ..< n {
			cut: [512]u8
			copy(cut[:], buf[:length])
			if length >= 4 {
				cut[0], cut[1], cut[2], cut[3] = u8(length), 0, 0, 0
			}
			if !testing.expectf(t, p9.decode(cut[:length], &d) != .Ok, "a truncated %s (%d of %d bytes) decoded", name, length, n) {
				break
			}
		}
		// So is one byte too many.
		buf[n] = 0
		buf[0] = u8(n + 1)
		testing.expectf(t, p9.decode(buf[:n + 1], &d) == .Err_Invalid, "%s with a trailing byte decoded", name)
		// So is a size field that disagrees with the length.
		buf[0] = u8(n - 1)
		testing.expectf(t, p9.decode(buf[:n], &d) == .Err_Invalid, "%s with a short size field decoded", name)
	}
	testing.expect_value(t, types, 74) // 9P2000's 27, 33 of 9P2000.L's (6d4c2: all it has but xattrs and mknod), 9Px's 14
	testing.expect(t, !p9.known(p9.Type(106))) // there is no Terror
	m := p9.Msg{type = p9.Type(106)}
	testing.expect_value(t, p9.encode(&m, buf[:]), 0)
	m = p9.Msg{type = .Tclunk}
	testing.expect_value(t, p9.encode(&m, buf[:6]), 0) // does not fit
}

// A hand-built Twalk with n names, and optionally a NUL in the last.
raw_walk :: proc(b: []u8, n: u16, nul: bool) -> []u8 {
	length := 4
	push :: proc(b: []u8, length: ^int, bytes: ..u8) {
		copy(b[length^:], bytes)
		length^ += len(bytes)
	}
	push(b, &length, u8(p9.Type.Twalk))
	push(b, &length, 1, 0) // tag
	push(b, &length, 0, 0, 0, 0, 0, 0, 0, 0) // fid, newfid
	push(b, &length, u8(n), u8(n >> 8))
	for i in 0 ..< n {
		push(b, &length, 1, 0, (nul && i == n - 1) ? 0 : 'a')
	}
	b[0], b[1], b[2], b[3] = u8(length), u8(length >> 8), 0, 0
	return b[:length]
}

@(test)
test_traps :: proc(t: ^testing.T) {
	b, stat: [256]u8
	d: p9.Msg
	testing.expect_value(t, p9.decode(raw_walk(b[:], 16, false), &d), vx.Status.Ok)
	testing.expect_value(t, d.nwname, 16)
	testing.expect_value(t, p9.decode(raw_walk(b[:], 17, false), &d), vx.Status.Err_Invalid) // more than MAXWELEM
	testing.expect_value(t, p9.decode(raw_walk(b[:], 2, true), &d), vx.Status.Err_Invalid) // NUL in a name

	// A Twrite whose count runs past the message.
	w := full_message(.Twrite, stat[:])
	n := p9.encode(&w, b[:])
	b[4 + 1 + 2 + 4 + 8] = 200 // count's low byte
	testing.expect_value(t, p9.decode(b[:n], &d), vx.Status.Err_Invalid)

	// Unknown types.
	tiny := [7]u8{7, 0, 0, 0, 99, 0, 0}
	testing.expect_value(t, p9.decode(tiny[:], &d), vx.Status.Err_Invalid)
	tiny[4] = 106
	testing.expect_value(t, p9.decode(tiny[:], &d), vx.Status.Err_Invalid)
	tiny[4] = u8(p9.Type.Rflush)
	testing.expect_value(t, p9.decode(tiny[:], &d), vx.Status.Ok)
	testing.expect_value(t, p9.decode(tiny[:6], &d), vx.Status.Err_Invalid)
}

@(test)
test_stat :: proc(t: ^testing.T) {
	s := p9.Stat {
		qid = {p9.QTFILE, 1, 2},
		mode = 0o644,
		length = 10,
		name = "f",
		uid = "u",
		gid = "g",
		muid = "m",
	}
	b: [128]u8
	n := p9.stat_encode(&s, b[:])
	d: p9.Stat
	testing.expect_value(t, n, 2 + 39 + 4 * 3)
	testing.expect_value(t, p9.stat_decode(b[:n], &d), vx.Status.Ok)
	testing.expect_value(t, d.length, 10)
	testing.expect_value(t, d.qid.path, 2)
	testing.expect_value(t, len(d.name), 1)
	testing.expect_value(t, d.muid[0], 'm')
	testing.expect_value(t, p9.stat_decode(b[:n - 1], &d), vx.Status.Err_Invalid)
	testing.expect_value(t, p9.stat_encode(&s, b[:20]), 0)
}

@(test)
test_versions :: proc(t: ^testing.T) {
	d, ext := p9.version_parse("9P2000.x/1 +dref +map +future")
	testing.expect_value(t, d, p9.Dialect.P9_2000X)
	testing.expect_value(t, ext, p9.Extensions{.Dref, .Map})
	d, ext = p9.version_parse("9P2000.x/1")
	testing.expect_value(t, d, p9.Dialect.P9_2000X)
	testing.expect_value(t, ext, p9.Extensions{})
	d, _ = p9.version_parse("9P2000")
	testing.expect_value(t, d, p9.Dialect.P9_2000)
	d, _ = p9.version_parse("9P2000.L")
	testing.expect_value(t, d, p9.Dialect.P9_2000L) // Linux's dialect (6d4c2)
	d, _ = p9.version_parse("9P2000.u")
	testing.expect_value(t, d, p9.Dialect.P9_2000)
	d, _ = p9.version_parse("9P1999")
	testing.expect_value(t, d, p9.Dialect.Unknown)
	d, _ = p9.version_parse("")
	testing.expect_value(t, d, p9.Dialect.Unknown)
	buf: [96]u8
	n := p9.version_format(.P9_2000X, {.Dref, .Notify}, buf[:])
	testing.expect_value(t, n, 24)
	testing.expect_value(t, string(buf[:n]), "9P2000.x/1 +dref +notify")
	testing.expect_value(t, p9.version_format(.P9_2000, {}, buf[:]), 6)

	testing.expect_value(t, p9.error_status(p9.error_text(.Err_Not_Found)), vx.Status.Err_Not_Found)
	testing.expect_value(t, p9.error_status(p9.error_text(.Err_Access)), vx.Status.Err_Access)
	testing.expect_value(t, p9.error_status("something only plan 9 says"), vx.Status.Err_Invalid)
	// Other servers' wordings: Unix's strerror() as u9fs passes it on, and u9fs's own.
	Case :: struct {
		text: string,
		want: vx.Status,
	}
	heard := []Case {
		{"No such file or directory", .Err_Not_Found},
		{"Permission denied", .Err_Access},
		{"file or directory already exists", .Err_Exists},
		{"No such file or directory!", .Err_Invalid}, // whole text only
		{"No such file", .Err_Invalid},
	}
	for c in heard {
		got := p9.error_status(c.text)
		testing.expectf(t, got == c.want, "error_status(%q) is %v, want %v", c.text, got, c.want)
	}
}

// Directory reads: each entry is bounded by what was read, not by its own size.
@(test)
test_dir_next :: proc(t: ^testing.T) {
	s := p9.Stat{name = "a", uid = "u", gid = "g", muid = "m"}
	b: [256]u8
	one := p9.stat_encode(&s, b[:])
	two := one + p9.stat_encode(&s, b[one:])
	it := p9.Dir_Entries{buf = b[:two]}
	_, ok := p9.next_entry(&it)
	testing.expect(t, ok)
	testing.expect_value(t, it.off, one)
	_, ok = p9.next_entry(&it)
	testing.expect(t, ok)
	testing.expect_value(t, it.off, two)
	_, ok = p9.next_entry(&it)
	testing.expect(t, !ok) // the end

	it = {buf = b[:one - 1]}
	_, ok = p9.next_entry(&it)
	testing.expect(t, !ok) // cut short
	testing.expect_value(t, it.off, 0)

	b[one], b[one + 1] = 0xff, 0xff // the second claims 64 KiB
	it = {buf = b[:two], off = one}
	_, ok = p9.next_entry(&it)
	testing.expect(t, !ok)
	testing.expect_value(t, it.off, one)
}
