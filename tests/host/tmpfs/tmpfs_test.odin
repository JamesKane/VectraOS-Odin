// servers/tmpfs's file system on the host: the program itself, linked
// against lib/rt, with a fake kernel underneath, as tests/host/bootfs does.
// vmo_create and as_map hand out memory from an arena here, clock_read is a
// clock the test sets, debug_write is kept, and port_create fails, so the
// program's vx_main makes its root, says what it serves and returns. Its
// p9.Fs is then driven through lib/p9's server framework and client, with
// the posix and xattr extensions.
//
// Upstream has no host test of tmpfs; these cases follow its tmpfs.c.
// Everything here is global (the program's state and the fake kernel), so
// it is one test, in parts.
package tmpfs_test

import vx "abi:vx"
import "core:strings"
import "core:testing"
import "vx:p9"
import "vx:rt"
import tmpfs "../../../servers/tmpfs"
import "../p9test"

LISTEN :: vx.Handle(0x202)

kernel_log: [1024]u8
kernel_log_len: int
now: i64 // the clock, ns
arena: [8 << 20]u8 // what as_map hands out, never given back
arena_used: u64
vmos, maps, unmaps: int

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Clock_Read:
		return now
	case .Vmo_Create:
		vmos += 1
		(^vx.Handle)(uintptr(a2))^ = vx.Handle(0x1000 + vmos)
		return 0
	case .As_Map:
		if a3 > u64(len(arena)) - arena_used {
			return i64(vx.Status.Err_No_Memory)
		}
		maps += 1
		(^u64)(uintptr(a5))^ = u64(uintptr(&arena[arena_used]))
		arena_used += a3
		return 0
	case .As_Unmap:
		unmaps += 1
		return 0
	case .Handle_Close:
		return 0
	}
	return i64(vx.Status.Err_Unsupported) // port_create among them: vx_main returns
}

Session :: struct {
	srv:        p9.Server,
	shared:     p9.Shared,
	tbuf, rbuf: [8192]u8,
	c:          p9.Client,
	root:       p9.Fid,
}

// A connection to tmpfs's Fs, attached at its root.
connect :: proc(t: ^testing.T, s: ^Session) {
	s.srv = {fs = tmpfs.server.fs, max_msize = 8192, supported = tmpfs.server.supported, shared = &s.shared}
	s.c = {rpc = p9test.loopback, ctx = &s.srv, tbuf = s.tbuf[:], rbuf = s.rbuf[:]}
	testing.expect_value(t, p9.client_version(&s.c, 8192, {.Posix, .Xattr}), vx.Status.Ok)
	testing.expect_value(t, s.c.extensions, p9.Extensions{.Posix, .Xattr})
	e: vx.Status
	s.root, e = p9.client_attach(&s.c, "")
	testing.expect_value(t, e, vx.Status.Ok)
}

// Creates path's last name in its directory (from root), opened in mode;
// returns the fid, now on the new file.
create :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid, path: string, perm: u32, mode := p9.ORDWR, loc := #caller_location) -> (f: p9.Fid, e: vx.Status) {
	slash := strings.last_index_byte(path, '/')
	dir, name := slash < 0 ? "" : path[:slash], path[slash + 1:]
	f, e = p9.client_walk(c, root, dir)
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	e = p9.client_create(c, f, name, perm, mode)
	if e != .Ok {
		_ = p9.client_clunk(c, f)
	}
	return
}

write_file :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid, path, text: string, loc := #caller_location) {
	f, e := create(t, c, root, path, 0o644, loc = loc)
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	for off := 0; off < len(text); { // in pieces, as the msize allows
		n, we := p9.client_write(c, f, u64(off), transmute([]u8)text[off:])
		testing.expect_value(t, we, vx.Status.Ok, loc = loc)
		if we != .Ok || n == 0 {
			break
		}
		off += n
	}
	_ = p9.client_clunk(c, f)
}

// What the file at path reads as, whole, or why not.
read_file :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> string {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return "(walk failed)"
	}
	defer _ = p9.client_clunk(c, f)
	if p9.client_open(c, f, p9.OREAD) != .Ok {
		return "(open failed)"
	}
	return read_all(c, f)
}

read_all :: proc(c: ^p9.Client, f: p9.Fid) -> string {
	b := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	off := 0
	for {
		n, re := p9.client_read(c, f, u64(off), buf[:])
		if re != .Ok {
			return "(read failed)"
		}
		if n == 0 {
			break
		}
		strings.write_bytes(&b, buf[:n])
		off += n
	}
	return strings.to_string(b)
}

@(test)
test_tmpfs :: proc(t: ^testing.T) {
	now = 5_000_000_000
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "listen", LISTEN
	rt.spawn.handle_count = 1
	testing.expect_value(t, tmpfs.vx_main(), int(vx.Status.Err_Unsupported)) // made its root, then no port to serve on
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "tmpfs: serving /srv/tmpfs\n")

	s := new(Session, context.temp_allocator)
	connect(t, s)
	c, root := &s.c, s.root
	files(t, c, root)
	directories(t, c, root)
	removing(t, c, root)
	attributes(t, c, root)
	renaming(t, c, root)
	links(t, c, root)
}

// Files: made, written and read back, at offsets and across a hole, grown
// past their first mapping, and truncated by an open.
files :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid) {
	names: p9.Stat_Text
	st: p9.Stat
	testing.expect_value(t, p9test.stat_of(c, root, "", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "/")
	testing.expect_value(t, st.mode, p9.DMDIR | 0o777)
	testing.expect_value(t, st.mtime, 5)
	testing.expect_value(t, st.uid, "posix")
	testing.expect_value(t, st.gid, "posix")
	testing.expect_value(t, st.muid, "posix")

	now = 7_000_000_000
	f, e := create(t, c, root, "a", 0o640)
	testing.expect_value(t, e, vx.Status.Ok)
	n: int
	n, e = p9.client_write(c, f, 0, transmute([]u8)string("hello"))
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 5)
	n, e = p9.client_write(c, f, 8, transmute([]u8)string("x"))
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, read_all(c, f), "hello\x00\x00\x00x") // a hole reads as zeros
	testing.expect_value(t, p9.client_stat(c, f, &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "a")
	testing.expect_value(t, st.mode, 0o640)
	testing.expect_value(t, st.length, 9)
	testing.expect_value(t, st.mtime, 7)
	testing.expect_value(t, st.qid.type, p9.QTFILE)
	testing.expect_value(t, st.qid.version, 2) // a version per write
	testing.expect_value(t, st.qid.path, 2) // the first node made: slot 2, generation 0
	_ = p9.client_clunk(c, f)

	// Past the first 4 KiB mapping: a new one twice as large, the old copied.
	big := strings.repeat("0123456789", 1000, context.temp_allocator)
	maps_before := maps
	write_file(t, c, root, "big", big)
	got := read_file(c, root, "big")
	testing.expect_value(t, len(got), len(big))
	testing.expect(t, got == big)
	testing.expect(t, maps > maps_before)

	// Reads past the end are empty.
	f, _ = p9.client_walk(c, root, "a")
	_ = p9.client_open(c, f, p9.OREAD)
	buf: [16]u8
	n, e = p9.client_read(c, f, 100, buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 0)
	_ = p9.client_clunk(c, f)

	// An open with OTRUNC empties the file.
	f, _ = p9.client_walk(c, root, "a")
	testing.expect_value(t, p9.client_open(c, f, p9.Open_Mode{access = .Write, trunc = true}), vx.Status.Ok)
	_ = p9.client_clunk(c, f)
	testing.expect_value(t, read_file(c, root, "a"), "")

	// A name taken, and one too long.
	_, e = create(t, c, root, "a", 0o644)
	testing.expect_value(t, e, vx.Status.Err_Exists)
	_, e = create(t, c, root, strings.repeat("n", 128, context.temp_allocator), 0o644)
	testing.expect_value(t, e, vx.Status.Err_Range)
	f, e = create(t, c, root, strings.repeat("n", 127, context.temp_allocator), 0o644)
	testing.expect_value(t, e, vx.Status.Ok)
	_ = p9.client_remove(c, f)
}

// Directories: children in the order they came; a directory opens only to
// read; and a file is not a directory.
directories :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid) {
	names: p9.Stat_Text
	f, e := create(t, c, root, "d", p9.DMDIR | 0o755, p9.OREAD)
	testing.expect_value(t, e, vx.Status.Ok)
	_ = p9.client_clunk(c, f)
	for name in ([]string{"z", "y", "x"}) {
		write_file(t, c, root, strings.concatenate({"d/", name}, context.temp_allocator), name)
	}
	testing.expect_value(t, p9test.list(c, root, "d"), "z y x")
	testing.expect_value(t, p9test.list(c, root, ""), "a big d")
	st: p9.Stat
	_ = p9test.stat_of(c, root, "d", &st, &names)
	testing.expect_value(t, st.mode, p9.DMDIR | 0o755)
	testing.expect_value(t, st.qid.type, p9.QTDIR)
	testing.expect_value(t, st.length, 0)

	_, e = create(t, c, root, "e", p9.DMDIR | 0o755, p9.ORDWR)
	testing.expect_value(t, e, vx.Status.Err_Access) // a directory is not made to write
	testing.expect_value(t, p9test.list(c, root, ""), "a big d")
	f, _ = p9.client_walk(c, root, "d")
	testing.expect_value(t, p9.client_open(c, f, p9.OWRITE), vx.Status.Err_Access)
	testing.expect_value(t, p9.client_open(c, f, p9.Open_Mode{access = .Read, trunc = true}), vx.Status.Err_Access)
	_ = p9.client_clunk(c, f)
	_, e = p9.client_walk(c, root, "a/b")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	f, e = p9.client_walk(c, root, "a")
	testing.expect_value(t, p9.client_create(c, f, "b", 0o644, p9.ORDWR), vx.Status.Err_Invalid) // lib/p9 refuses it first
	_ = p9.client_clunk(c, f)
}

// Removing: a directory only when empty, never the root; a file removed
// while open keeps its bytes for that fid, and its id names nothing once
// the last fid lets go and its slot is used again.
removing :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid) {
	names: p9.Stat_Text
	f, e := p9.client_walk(c, root, "d")
	testing.expect_value(t, p9.client_remove(c, f), vx.Status.Err_Exists) // not empty
	r, _ := p9.client_walk(c, root, "")
	testing.expect_value(t, p9.client_remove(c, r), vx.Status.Err_Access)

	write_file(t, c, root, "gone", "still here")
	f, _ = p9.client_walk(c, root, "gone")
	_ = p9.client_open(c, f, p9.OREAD)
	st: p9.Stat
	_ = p9.client_stat(c, f, &st, &names)
	id := st.qid.path
	other, _ := p9.client_walk(c, root, "gone")
	testing.expect_value(t, p9.client_remove(c, other), vx.Status.Ok)
	_, e = p9.client_walk(c, root, "gone")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	testing.expect_value(t, read_all(c, f), "still here") // open, so its bytes stay
	unmaps_before := unmaps
	_ = p9.client_clunk(c, f)
	testing.expect_value(t, unmaps, unmaps_before + 1) // the last fid let go: its mapping goes

	write_file(t, c, root, "again", "") // the removed node's slot, a generation on
	_ = p9test.stat_of(c, root, "again", &st, &names)
	testing.expect_value(t, u32(st.qid.path), u32(id))
	testing.expect(t, st.qid.path != id)
	f, _ = p9.client_walk(c, root, "again")
	_ = p9.client_remove(c, f)

	// `..` from a directory that was removed under a fid finds nothing.
	f, e = create(t, c, root, "dd", p9.DMDIR | 0o755, p9.OREAD)
	testing.expect_value(t, e, vx.Status.Ok)
	_ = p9.client_clunk(c, f)
	f, _ = p9.client_walk(c, root, "dd")
	other, _ = p9.client_walk(c, root, "dd")
	testing.expect_value(t, p9.client_remove(c, other), vx.Status.Ok)
	_, e = p9.client_walk(c, f, "..")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	_ = p9.client_clunk(c, f)
}

// The xattr extension's Tsetattr: size, mode and times, as POSIX has them.
attributes :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid) {
	names: p9.Stat_Text
	write_file(t, c, root, "s", "abcdef")
	f, _ := p9.client_walk(c, root, "s")
	now = 9_000_000_000
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Size}, size = 3}), vx.Status.Ok)
	testing.expect_value(t, read_file(c, root, "s"), "abc")
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Size}, size = 5}), vx.Status.Ok)
	testing.expect_value(t, read_file(c, root, "s"), "abc\x00\x00") // grown with zeros
	a, e := p9.client_getattr(c, f)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, a.size, 5)
	testing.expect_value(t, a.mtime_sec, 9) // a size changed without a time: now
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Mode}, mode = 0o104755}), vx.Status.Ok)
	st: p9.Stat
	_ = p9.client_stat(c, f, &st, &names)
	testing.expect_value(t, st.mode, 0o4755) // the permission bits and set-id, no type
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Atime, .Atime_Set, .Mtime, .Mtime_Set}, atime_sec = 11, mtime_sec = 12}), vx.Status.Ok)
	_ = p9.client_stat(c, f, &st, &names)
	testing.expect_value(t, st.atime, 11)
	testing.expect_value(t, st.mtime, 12)
	now = 13_000_000_000
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Atime, .Mtime}}), vx.Status.Ok)
	_ = p9.client_stat(c, f, &st, &names)
	testing.expect_value(t, st.atime, 13) // without _Set: now
	testing.expect_value(t, st.mtime, 13)
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Uid, .Gid}, uid = 5, gid = 6}), vx.Status.Ok) // owners are not kept
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Size}, size = 64 << 20 + 1}), vx.Status.Err_No_Memory)
	_ = p9.client_clunk(c, f)
	f, _ = p9.client_walk(c, root, "d")
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Size}, size = 0}), vx.Status.Err_Invalid) // a directory has no size to set
	_ = p9.client_clunk(c, f)
}

// The posix extension's Trenameat, replacing what is there as POSIX's
// rename does.
renaming :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid) {
	d, _ := p9.client_walk(c, root, "d")
	testing.expect_value(t, p9.client_renameat(c, root, "s", d, "w"), vx.Status.Ok)
	testing.expect_value(t, p9test.list(c, root, "d"), "z y x w") // at the end, as a new child
	testing.expect_value(t, read_file(c, root, "d/w"), "abc\x00\x00")
	testing.expect_value(t, p9.client_renameat(c, d, "z", d, "y"), vx.Status.Ok) // a file replaces a file
	testing.expect_value(t, p9test.list(c, root, "d"), "x w y")
	testing.expect_value(t, read_file(c, root, "d/y"), "z")
	testing.expect_value(t, p9.client_renameat(c, d, "y", d, "y"), vx.Status.Ok) // onto itself: nothing
	testing.expect_value(t, p9.client_renameat(c, d, "nope", d, "q"), vx.Status.Err_Not_Found)
	testing.expect_value(t, p9.client_renameat(c, root, "d", d, "inner"), vx.Status.Err_Invalid) // into itself
	testing.expect_value(t, p9.client_renameat(c, d, "x", root, "d"), vx.Status.Err_Exists) // a file over a directory
	f, e := create(t, c, root, "e", p9.DMDIR | 0o755, p9.OREAD)
	testing.expect_value(t, e, vx.Status.Ok)
	_ = p9.client_clunk(c, f)
	testing.expect_value(t, p9.client_renameat(c, root, "e", d, "x"), vx.Status.Err_Invalid) // a directory over a file
	testing.expect_value(t, p9.client_renameat(c, root, "e", root, "d"), vx.Status.Err_Exists) // over a directory not empty
	f, _ = create(t, c, root, "f", p9.DMDIR | 0o755, p9.OREAD)
	_ = p9.client_clunk(c, f)
	testing.expect_value(t, p9.client_renameat(c, root, "e", root, "f"), vx.Status.Ok) // over an empty one
	testing.expect_value(t, p9test.list(c, root, ""), "a big d f")
	testing.expect_value(t, p9.client_renameat(c, root, "a", d, strings.repeat("n", 128, context.temp_allocator)), vx.Status.Err_Range)
	_ = p9.client_clunk(c, d)
}

// Symbolic links: a target kept as the link's bytes, read back by
// Treadlink, and DMSYMLINK in its mode.
links :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid) {
	names: p9.Stat_Text
	testing.expect_value(t, p9.client_symlink(c, root, "l", "d/w"), vx.Status.Ok)
	f, e := p9.client_walk(c, root, "l")
	testing.expect_value(t, e, vx.Status.Ok)
	target: string
	link: [256]u8
	target, e = p9.client_readlink(c, f, link[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, target, "d/w")
	st: p9.Stat
	_ = p9.client_stat(c, f, &st, &names)
	testing.expect_value(t, st.mode, p9.DMSYMLINK | 0o777)
	testing.expect_value(t, st.length, 3)
	testing.expect_value(t, p9.client_setattr(c, f, {valid = {.Size}, size = 1}), vx.Status.Err_Invalid)
	_ = p9.client_clunk(c, f)
	testing.expect_value(t, p9.client_symlink(c, root, "l", "x"), vx.Status.Err_Exists)
	testing.expect_value(t, p9.client_symlink(c, root, "m", ""), vx.Status.Err_Invalid)
	f, _ = p9.client_walk(c, root, "a")
	_, e = p9.client_readlink(c, f, link[:])
	testing.expect_value(t, e, vx.Status.Err_Invalid) // not a link
	_ = p9.client_clunk(c, f)
}
