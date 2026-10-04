// servers/bootfs's file system on the host: the program itself, linked
// against lib/rt, with a fake kernel underneath. This file defines
// vx_syscall, so the runtime's syscalls land here: as_map "maps" a boot
// image built here with lib/tar's writer, debug_write is kept, and
// port_create fails, so the program's vx_main loads the image, says what it
// serves and returns instead of serving rings. Its p9.Fs is then driven
// through lib/p9's server framework and client, as tests/host/p9_server does.
//
// Everything here is global (the program's state and the fake kernel), so
// it is one test.
package bootfs_test

import vx "abi:vx"
import "core:fmt"
import "core:testing"
import "vx:p9"
import "vx:rt"
import "vx:tar"
import bootfs "../../../servers/bootfs"

IMAGE :: vx.Handle(0x201)
LISTEN :: vx.Handle(0x202)

image: [16 * 1024]u8
kernel_log: [1024]u8
kernel_log_len: int
mapped_size: u64

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .As_Map:
		if vx.Handle(a1) != IMAGE || a2 != 0 {
			return i64(vx.Status.Err_Bad_Handle)
		}
		mapped_size = a3
		(^u64)(uintptr(a5))^ = u64(uintptr(&image[0]))
		return 0
	case .Handle_Close:
		return 0
	}
	return i64(vx.Status.Err_Unsupported) // port_create among them: vx_main returns
}

loopback :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int {
	return p9.serve((^p9.Server)(ctx), req, resp)
}

// The names a directory reads as, in order, joined by spaces.
list :: proc(c: ^p9.Client, root: u32, path: string, out: []u8) -> string {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return "(walk failed)"
	}
	defer _ = p9.client_clunk(c, f)
	if p9.client_open(c, f, p9.OREAD) != .Ok {
		return "(open failed)"
	}
	dir: [4096]u8
	n, re := p9.client_read(c, f, 0, dir[:])
	if re != .Ok {
		return "(read failed)"
	}
	used := 0
	for off := 0; off + 2 <= n; {
		length := int(dir[off]) | int(dir[off + 1]) << 8
		st: p9.Stat
		if p9.stat_decode(dir[off:][:length + 2], &st) != .Ok {
			return "(bad entry)"
		}
		if used > 0 {
			used += copy(out[used:], " ")
		}
		used += copy(out[used:], st.name)
		off += length + 2
	}
	return string(out[:used])
}

stat_of :: proc(c: ^p9.Client, root: u32, path: string, st: ^p9.Stat) -> vx.Status {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return e
	}
	defer _ = p9.client_clunk(c, f)
	return p9.client_stat(c, f, st)
}

@(test)
test_bootfs :: proc(t: ^testing.T) {
	// The image: directories and files in an order of their own, a path whose
	// directories are only implied, and an entry for one of those after it.
	w := tar.Writer{buf = image[:]}
	tar.add(&w, "boot", true, 0o755, nil)
	tar.add(&w, "boot/bin", true, 0o755, nil)
	tar.add(&w, "boot/bin/hello", false, 0o755, transmute([]u8)string("hello, world\n"))
	tar.add(&w, "x/y/z.txt", false, 0o600, transmute([]u8)string("zed"))
	tar.add(&w, "boot/readme", false, 0o644, nil)
	tar.add(&w, "x", true, 0o700, nil)
	size := tar.end(&w)
	testing.expect(t, size > 0)

	// The spawn message svcd would send: the image, its size, and "listen".
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "bootimage", IMAGE
	rt.spawn.handle_names[1], rt.spawn.handles[1] = "listen", LISTEN
	rt.spawn.handle_count = 2
	rt.spawn.text = fmt.tprintf("bootimage size=%d\n", size)
	testing.expect_value(t, bootfs.vx_main(), int(vx.Status.Err_Unsupported)) // loaded, then no port to serve on
	testing.expect_value(t, mapped_size, u64((size + 4095) &~ 4095))
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "bootfs: serving 3 files in 5 directories\n")

	srv := p9.Server{fs = bootfs.server.fs, max_msize = 8192}
	tbuf, rbuf: [8192]u8
	c := p9.Client{rpc = loopback, ctx = &srv, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {}), vx.Status.Ok)
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)

	// The tree, children in the archive's order.
	names: [256]u8
	testing.expect_value(t, list(&c, root, "", names[:]), "boot x")
	testing.expect_value(t, list(&c, root, "boot", names[:]), "bin readme")
	testing.expect_value(t, list(&c, root, "boot/bin", names[:]), "hello")
	testing.expect_value(t, list(&c, root, "x/y", names[:]), "z.txt")

	// Stats: qids are node numbers in the order nodes were made; modes are
	// read-only; implied directories are 0555.
	st: p9.Stat
	testing.expect_value(t, stat_of(&c, root, "", &st), vx.Status.Ok)
	testing.expect(t, st.name == "/" && st.mode == p9.DMDIR | 0o555 && st.qid == {type = p9.QTDIR, path = 1} && st.length == 0)
	testing.expect(t, st.uid == "boot" && st.gid == "boot" && st.muid == "boot")
	_ = stat_of(&c, root, "boot/bin/hello", &st)
	testing.expect(t, st.name == "hello" && st.mode == 0o555 && st.qid == {type = p9.QTFILE, path = 4} && st.length == 13)
	_ = stat_of(&c, root, "x", &st)
	testing.expect(t, st.mode == p9.DMDIR | 0o500 && st.qid == {type = p9.QTDIR, path = 5})
	_ = stat_of(&c, root, "x/y", &st)
	testing.expect(t, st.mode == p9.DMDIR | 0o555 && st.qid == {type = p9.QTDIR, path = 6})
	_ = stat_of(&c, root, "x/y/z.txt", &st)
	testing.expect(t, st.mode == 0o400 && st.qid == {type = p9.QTFILE, path = 7} && st.length == 3)
	_ = stat_of(&c, root, "boot/readme", &st)
	testing.expect(t, st.mode == 0o444 && st.qid == {type = p9.QTFILE, path = 8} && st.length == 0)

	// Reads, at offsets and past the end.
	buf: [64]u8
	f: u32
	n: int
	f, _ = p9.client_walk(&c, root, "boot/bin/hello")
	testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect(t, e == .Ok && string(buf[:n]) == "hello, world\n")
	n, e = p9.client_read(&c, f, 7, buf[:3])
	testing.expect(t, e == .Ok && string(buf[:n]) == "wor")
	n, e = p9.client_read(&c, f, 13, buf[:])
	testing.expect(t, e == .Ok && n == 0)
	n, e = p9.client_read(&c, f, 1 << 40, buf[:])
	testing.expect(t, e == .Ok && n == 0)
	_ = p9.client_clunk(&c, f)
	f, _ = p9.client_walk(&c, root, "boot/readme")
	_ = p9.client_open(&c, f, p9.OREAD)
	n, e = p9.client_read(&c, f, 0, buf[:])
	testing.expect(t, e == .Ok && n == 0)
	_ = p9.client_clunk(&c, f)

	// Nothing opens for writing.
	for mode in ([]u8{p9.OWRITE, p9.ORDWR, p9.OREAD | p9.OTRUNC, p9.OREAD | p9.ORCLOSE}) {
		f, _ = p9.client_walk(&c, root, "boot/bin/hello")
		testing.expect_value(t, p9.client_open(&c, f, mode), vx.Status.Err_Access)
		_ = p9.client_clunk(&c, f)
	}
	f, _ = p9.client_walk(&c, root, "boot/bin/hello")
	testing.expect_value(t, p9.client_open(&c, f, p9.OEXEC), vx.Status.Ok)
	_ = p9.client_clunk(&c, f)

	// Walks: missing names, through a file, and `..`.
	for path in ([]string{"nope", "boot/nope", "boot/bin/hello/x", "boot/bin/hell", "Boot"}) {
		_, e = p9.client_walk(&c, root, path)
		testing.expect_value(t, e, vx.Status.Err_Not_Found)
	}
	f, e = p9.client_walk(&c, root, "x/y/z.txt/../..")
	testing.expect_value(t, e, vx.Status.Ok)
	_ = p9.client_stat(&c, f, &st)
	testing.expect_value(t, st.name, "x")
	_ = p9.client_clunk(&c, f)

	// Attach names: below the root, directories only, no `.` or `..`.
	sub: u32
	sub, e = p9.client_attach(&c, "boot/bin")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, list(&c, sub, "", names[:]), "hello")
	f, e = p9.client_walk(&c, sub, "..")
	testing.expect_value(t, e, vx.Status.Ok)
	_ = p9.client_stat(&c, f, &st)
	testing.expect_value(t, st.name, "bin") // `..` at the attach root stays there
	_ = p9.client_clunk(&c, f)
	_ = p9.client_clunk(&c, sub)
	sub, e = p9.client_attach(&c, "/boot//bin/")
	testing.expect_value(t, e, vx.Status.Ok)
	_ = p9.client_clunk(&c, sub)
	for aname in ([]string{"boot/bin/hello", "nope", "./boot", "boot/.", "boot/..", "boot/../x"}) {
		_, e = p9.client_attach(&c, aname)
		testing.expect_value(t, e, vx.Status.Err_Not_Found)
	}
}
