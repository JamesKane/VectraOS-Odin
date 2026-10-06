// servers/fsd's file system on the host: the program itself, linked against
// lib/rt with a fake kernel underneath (clock_read and debug_write), as
// tests/host/tmpfs does, on a volume upstream's C made: tests/host/fs's
// c-tool.vxfs.gz, upstream's host/vxfs's mkfs -u vectra, a tree put in home,
// home@fix, a fork named work (tests/host/fs/fixtures/make.sh). fsd mounts
// it from memory, and its p9.Fs is driven through lib/p9's server framework
// and client: what the fsd scenarios' scripts check (tests/user/fsdnone.rc,
// fsdadm.rc, fsddump.rc), at the 9P level. fsd is not a pager here, so Tmap
// is refused; the scenarios check mapping.
//
// Upstream has no host test of fsd; these cases follow its fsd.c. The
// program's state is global, so this is one test, in parts.
package fsd_test

import "core:bytes"
import "core:c/libc"
import "core:compress/gzip"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:fs"
import "vx:p9"
import fsd "../../../servers/fsd"
import "../p9test"

C_TOOL_GZ :: #load("../fs/fixtures/c-tool.vxfs.gz")

kernel_log: [4096]u8
kernel_log_len: int
now: i64 = 1_767_225_600_000_000_000 // 2026-01-01, ns

@(export, link_name = "vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Clock_Read:
		if a0 != 0 {
			(^vx.Clock_Info)(uintptr(a0))^ = {}
		}
		return now
	}
	return i64(vx.Status.Err_Unsupported)
}

// The volume, in memory.
disk: []u8

dev_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	copy(buf[:], disk[addr:][:fs.BLKSZ])
	return .Ok
}

dev_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	copy(disk[addr:][:fs.BLKSZ], buf[:])
	return .Ok
}

dev_barrier :: proc "contextless" (ctx: rawptr) -> vx.Status {
	return .Ok
}

mem_alloc :: proc "contextless" (ctx: rawptr, size: int) -> rawptr {
	return libc.aligned_alloc(16, uint(size + 15) &~ 15)
}

mem_free :: proc "contextless" (ctx: rawptr, p: rawptr, size: int) {
	libc.free(p)
}

Session :: struct {
	srv:        p9.Server,
	shared:     p9.Shared,
	tbuf, rbuf: [8192]u8,
	c:          p9.Client,
	root:       p9.Fid,
}

// A connection to fsd's Fs, attached as uname at aname; the attach's status.
connect :: proc(t: ^testing.T, s: ^Session, uname, aname: string, loc := #caller_location) -> vx.Status {
	s.srv = {fs = fsd.server.fs, max_msize = 8192, supported = fsd.server.supported, shared = &s.shared}
	s.c = {rpc = p9test.loopback, ctx = &s.srv, tbuf = s.tbuf[:], rbuf = s.rbuf[:], uname = uname}
	testing.expect_value(t, p9.client_version(&s.c, 8192, {.Posix, .Xattr, .Map, .Dref}), vx.Status.Ok, loc = loc)
	e: vx.Status
	s.root, e = p9.client_attach(&s.c, aname)
	return e
}

read_file :: proc(s: ^Session, path: string) -> string {
	f, e := p9.client_walk(&s.c, s.root, path)
	if e != .Ok {
		return "(walk failed)"
	}
	defer _ = p9.client_clunk(&s.c, f)
	if p9.client_open(&s.c, f, p9.OREAD) != .Ok {
		return "(open failed)"
	}
	return read_all(s, f)
}

read_all :: proc(s: ^Session, f: p9.Fid) -> string {
	b := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	off := 0
	for {
		n, re := p9.client_read(&s.c, f, u64(off), buf[:])
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

// Creates (or truncates) the file at path and writes text; the status of
// the first step that failed.
write_file :: proc(s: ^Session, path, text: string, perm: u32 = 0o644) -> vx.Status {
	slash := strings.last_index_byte(path, '/')
	dir, name := slash < 0 ? "" : path[:slash], path[slash + 1:]
	f, e := p9.client_walk(&s.c, s.root, path)
	if e == .Ok {
		e = p9.client_open(&s.c, f, {access = .Write, trunc = true})
	} else {
		f, e = p9.client_walk(&s.c, s.root, dir)
		if e != .Ok {
			return e
		}
		e = p9.client_create(&s.c, f, name, perm, p9.OWRITE)
	}
	defer _ = p9.client_clunk(&s.c, f)
	if e != .Ok {
		return e
	}
	for off := 0; off < len(text); {
		n, we := p9.client_write(&s.c, f, u64(off), transmute([]u8)text[off:])
		if we != .Ok {
			return we
		}
		off += n
	}
	return .Ok
}

// One command written to the adm branch's ctl.
ctl :: proc(s: ^Session, cmd: string) -> vx.Status {
	f, e := p9.client_walk(&s.c, s.root, "ctl")
	if e != .Ok {
		return e
	}
	defer _ = p9.client_clunk(&s.c, f)
	if e = p9.client_open(&s.c, f, p9.OWRITE); e != .Ok {
		return e
	}
	_, e = p9.client_write(&s.c, f, 0, transmute([]u8)cmd)
	return e
}

remove :: proc(s: ^Session, path: string) -> vx.Status {
	f, e := p9.client_walk(&s.c, s.root, path)
	if e != .Ok {
		return e
	}
	return p9.client_remove(&s.c, f) // clunks it, whatever it answers
}

// The status file's lines that start with prefix.
status_lines :: proc(adm: ^Session, prefix: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	text := read_file(adm, "status")
	for line in strings.split_lines_iterator(&text) {
		if strings.has_prefix(line, prefix) {
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	return strings.to_string(b)
}

@(test)
test_fsd :: proc(t: ^testing.T) {
	names: p9.Stat_Text
	buf: bytes.Buffer
	defer bytes.buffer_destroy(&buf)
	if err := gzip.load(C_TOOL_GZ, &buf); !testing.expectf(t, err == nil, "gunzip: %v", err) {
		return
	}
	disk = buf.buf[:]
	dev := fs.Dev{read = dev_read, write = dev_write, barrier = dev_barrier, size = u64(len(disk))}
	if !testing.expect_value(t, fs.mount(&fsd.vol, dev, {alloc = mem_alloc, free = mem_free}, fs.MINCACHE * 4), vx.Status.Ok) {
		return
	}
	defer fs.unmount(&fsd.vol)
	fsd.load_users()
	testing.expect_value(t, len(fsd.ut.users), 3)
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "") // nothing to say of a good users file

	sessions := new([8]Session)
	defer free(sessions)
	home, none, adm, all, snap, dump, work, none_adm := &sessions[0], &sessions[1], &sessions[2], &sessions[3], &sessions[4], &sessions[5], &sessions[6], &sessions[7]
	testing.expect_value(t, connect(t, home, "vectra", "home"), vx.Status.Ok)
	testing.expect_value(t, connect(t, none, "none", "home"), vx.Status.Ok)
	testing.expect_value(t, connect(t, adm, "vectra", "adm"), vx.Status.Ok)
	testing.expect_value(t, connect(t, none_adm, "", "adm"), vx.Status.Ok) // no name: none
	testing.expect_value(t, connect(t, all, "vectra", "%home"), vx.Status.Ok)
	testing.expect_value(t, connect(t, work, "vectra", "work"), vx.Status.Ok)
	testing.expect_value(t, connect(t, snap, "none", "%home"), vx.Status.Err_Access) // permissive: adm's members only
	testing.expect_value(t, connect(t, snap, "vectra", "nosuch"), vx.Status.Err_Not_Found)
	testing.expect_value(t, connect(t, snap, "vectra", ""), vx.Status.Err_Not_Found)

	// What the volume upstream's C made holds, read through fsd.
	testing.expect_value(t, p9test.list(&home.c, home.root, ""), "README big bin block-512 docs empty inline-511 link")
	testing.expect_value(t, read_file(home, "docs/a/b/deep.txt"), "three directories down\n")
	big := read_file(home, "big")
	testing.expect_value(t, len(big), 40000)
	st: p9.Stat
	testing.expect_value(t, p9test.stat_of(&home.c, home.root, "README", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.uid, "vectra")
	testing.expect_value(t, st.gid, "vectra")
	testing.expect_value(t, st.mode, 0o644)
	testing.expect_value(t, st.length, 214)
	testing.expect_value(t, p9test.stat_of(&home.c, home.root, "", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "/")
	testing.expect_value(t, st.qid.type, p9.QTDIR)
	link: [256]u8
	target, rl := p9.client_readlink(&home.c, walk(home, "link"), link[:])
	testing.expect_value(t, rl, vx.Status.Ok)
	testing.expect_value(t, target, "README")

	// none (tests/user/fsdnone.rc): only other's bits.
	readme := read_file(home, "README")
	testing.expect_value(t, read_file(none, "README"), readme)
	testing.expect_value(t, p9test.list(&none.c, none.root, ""), "README big bin block-512 docs empty inline-511 link")
	testing.expect_value(t, write_file(none, "none-was-here", "x"), vx.Status.Err_Access)
	testing.expect_value(t, remove(none, "README"), vx.Status.Err_Access)
	testing.expect_value(t, read_file(none, "README"), readme)
	testing.expect_value(t, ctl(none_adm, "sync"), vx.Status.Err_Access)

	// vectra writes in its home; what it wrote is there through another attach.
	testing.expect_value(t, write_file(home, "hello.txt", "hello from fsd"), vx.Status.Ok)
	testing.expect_value(t, read_file(all, "hello.txt"), "hello from fsd")
	testing.expect_value(t, p9test.stat_of(&home.c, home.root, "hello.txt", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.uid, "vectra")
	testing.expect_value(t, st.muid, "vectra")
	testing.expect_value(t, st.mtime, u32(now / 1_000_000_000))

	// The adm files (tests/user/fsdadm.rc).
	users := read_file(adm, "users")
	testing.expect_value(t, users, "0:adm:adm:vectra\n1:none::\n1000:vectra:vectra:\n")
	testing.expect_value(t, p9test.list(&adm.c, adm.root, ""), "ctl status users")
	status := read_file(adm, "status")
	testing.expect(t, strings.has_prefix(status, "volume commit=9 arenas=1 used="))
	testing.expect(t, strings.contains(status, " users=3 check=unchecked\n"))
	testing.expect_value(t, status_lines(adm, "label="), "label=adm snapshot=14 branch\nlabel=cfg snapshot=20 branch\nlabel=home snapshot=17 branch\nlabel=home@fix snapshot=17\nlabel=store snapshot=7 branch\nlabel=work snapshot=22 branch\n")
	testing.expect_value(t, write_file(adm, "status", "x"), vx.Status.Err_Access)
	testing.expect_value(t, write_file(adm, "ctl", "x"), vx.Status.Err_Invalid) // opened, written: no such command
	testing.expect_value(t, ctl(adm, "snap home home@t1"), vx.Status.Ok)
	testing.expect_value(t, status_lines(adm, "label=home@t1 "), "label=home@t1 snapshot=27\n")
	testing.expect_value(t, ctl(adm, "fork home@t1 exp"), vx.Status.Ok)
	testing.expect(t, status_lines(adm, "label=exp ") != "")
	testing.expect_value(t, ctl(adm, "del home@t1"), vx.Status.Ok)
	testing.expect_value(t, status_lines(adm, "label=home@t1 "), "")
	testing.expect_value(t, ctl(adm, "del exp"), vx.Status.Ok)
	testing.expect_value(t, status_lines(adm, "label=exp "), "")
	testing.expect_value(t, ctl(adm, "bogus"), vx.Status.Err_Invalid)
	testing.expect_value(t, ctl(adm, "del adm"), vx.Status.Err_Access)
	testing.expect_value(t, ctl(adm, "del home"), vx.Status.Err_Bad_State) // open
	testing.expect_value(t, ctl(adm, "sync"), vx.Status.Ok)
	testing.expect_value(t, ctl(adm, "check"), vx.Status.Ok)
	testing.expect(t, strings.contains(read_file(adm, "status"), " check=clean\n"))

	// Permissive: a file its owner gave no bits, read only through %home.
	testing.expect_value(t, write_file(home, "secret", "secret"), vx.Status.Ok)
	f := walk(home, "secret")
	testing.expect_value(t, p9.client_setattr(&home.c, f, {valid = {.Mode}, mode = 0}), vx.Status.Ok)
	_ = p9.client_clunk(&home.c, f)
	testing.expect_value(t, read_file(home, "secret"), "(open failed)")
	testing.expect_value(t, read_file(all, "secret"), "secret")
	// none may not change another's mode; the owner may give a file away
	// only through adm.
	f = walk(none, "hello.txt")
	testing.expect_value(t, p9.client_setattr(&none.c, f, {valid = {.Mode}, mode = 0o777}), vx.Status.Err_Access)
	_ = p9.client_clunk(&none.c, f)
	f = walk(home, "hello.txt")
	testing.expect_value(t, p9.client_setattr(&home.c, f, {valid = {.Uid}, uid = 1}), vx.Status.Ok) // vectra is in adm
	_ = p9.client_clunk(&home.c, f)
	testing.expect_value(t, p9test.stat_of(&home.c, home.root, "hello.txt", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.uid, "none")

	// Open through one attach (%home), removed through another (home): kept
	// until it is closed, as one file, whoever has it open and however.
	testing.expect_value(t, write_file(home, "held", "held"), vx.Status.Ok)
	held := walk(all, "held")
	testing.expect_value(t, p9.client_open(&all.c, held, p9.OREAD), vx.Status.Ok)
	testing.expect_value(t, remove(home, "held"), vx.Status.Ok)
	testing.expect_value(t, read_file(home, "held"), "(walk failed)")
	testing.expect_value(t, read_all(all, held), "held")
	_ = p9.client_clunk(&all.c, held)

	// A users file of 127 users and no none: fsd adds none, in a slot of its
	// own, and goes on answering. Then the old one again.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "0:adm:adm:vectra\n2:u2::\n1000:vectra:vectra:\n")
	for i in 3 ..= 126 {
		strings.write_string(&b, fmt.tprintf("%d:u%d::\n", i, i))
	}
	testing.expect_value(t, write_file(adm, "users", strings.to_string(b)), vx.Status.Ok)
	testing.expect_value(t, len(fsd.ut.users), 128)
	testing.expect_value(t, p9test.list(&adm.c, adm.root, ""), "ctl status users")
	testing.expect_value(t, write_file(adm, "users", "0:adm:nobody:\n"), vx.Status.Ok) // malformed: kept as they were
	testing.expect_value(t, len(fsd.ut.users), 128)
	testing.expect(t, strings.contains(string(kernel_log[:kernel_log_len]), "fsd: /adm/users is malformed: the users stay as they were\n"))
	testing.expect_value(t, write_file(adm, "users", users), vx.Status.Ok)
	testing.expect_value(t, len(fsd.ut.users), 3)

	// Read-only snapshots and the dump view (tests/user/fsddump.rc).
	testing.expect_value(t, ctl(adm, "snap home home@2026-01-01"), vx.Status.Ok)
	testing.expect_value(t, ctl(adm, "snap work work@2026-01-01"), vx.Status.Ok)
	testing.expect_value(t, ctl(adm, "snap home home@2025-12-31"), vx.Status.Ok)
	testing.expect_value(t, connect(t, dump, "vectra", "dump"), vx.Status.Ok)
	testing.expect_value(t, p9test.list(&dump.c, dump.root, ""), "2025 2026")
	testing.expect_value(t, p9test.list(&dump.c, dump.root, "2026"), "0101")
	testing.expect_value(t, p9test.list(&dump.c, dump.root, "2026/0101"), "home work")
	testing.expect_value(t, read_file(dump, "2026/0101/home/hello.txt"), "hello from fsd")
	testing.expect_value(t, p9test.stat_of(&dump.c, dump.root, "2026/0101/home", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "home")
	testing.expect_value(t, p9test.stat_of(&dump.c, dump.root, "2026", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "2026")
	testing.expect_value(t, st.mode, p9.DMDIR | 0o555)
	f = walk(dump, "2026/0101/home/docs")
	up, ue := p9.client_walk(&dump.c, f, "../..")
	testing.expect_value(t, ue, vx.Status.Ok)
	testing.expect_value(t, p9.client_stat(&dump.c, up, &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "0101") // a dated snapshot's root's parent: its day
	_ = p9.client_clunk(&dump.c, up)
	_ = p9.client_clunk(&dump.c, f)
	testing.expect_value(t, write_file(dump, "2026/0101/home/new", "x"), vx.Status.Err_Access)
	testing.expect_value(t, write_file(dump, "2026/0101/home/hello.txt", "x"), vx.Status.Err_Access)
	testing.expect_value(t, connect(t, snap, "vectra", "home@fix"), vx.Status.Ok) // a label: read-only
	testing.expect_value(t, read_file(snap, "README"), readme)
	testing.expect_value(t, read_file(snap, "hello.txt"), "(walk failed)")
	testing.expect_value(t, write_file(snap, "README", "x"), vx.Status.Err_Access)
	testing.expect_value(t, ctl(adm, "del home@2026-01-01"), vx.Status.Ok)
	testing.expect_value(t, read_file(dump, "2026/0101/home/hello.txt"), "(walk failed)")
	testing.expect_value(t, p9test.list(&dump.c, dump.root, "2026/0101"), "work")

	// A rollback: what came after the snapshot is gone, the old head kept.
	testing.expect_value(t, ctl(adm, "snap home home@t2"), vx.Status.Ok)
	testing.expect_value(t, write_file(home, "later.txt", "later"), vx.Status.Ok)
	testing.expect_value(t, ctl(adm, "rollback home home@t2"), vx.Status.Ok)
	testing.expect_value(t, read_file(home, "later.txt"), "(walk failed)")
	testing.expect_value(t, read_file(all, "secret"), "secret")
	testing.expect_value(t, strings.count(status_lines(adm, "label=home@before-"), "\n"), 1)
	testing.expect_value(t, ctl(adm, "rollback adm home@t2"), vx.Status.Err_Access)

	// An over-long word is refused, not cut, and ctl still answers.
	testing.expect_value(t, ctl(adm, strings.concatenate({"snap home ", strings.repeat("x", 1024, context.temp_allocator)}, context.temp_allocator)), vx.Status.Err_Invalid)
	testing.expect_value(t, strings.count(status_lines(adm, "label=home@t2"), "\n"), 1)

	// fsync commits; the volume upstream's C made, as fsd left it, checks clean.
	f = walk(home, "README")
	testing.expect_value(t, p9.client_fsync(&home.c, f), vx.Status.Ok)
	_ = p9.client_clunk(&home.c, f)
	c: fs.Check
	testing.expect_value(t, fs.check_volume(&fsd.vol, &c), vx.Status.Ok)

	// Tmap needs a pager, which fsd is not here.
	f = walk(home, "README")
	testing.expect_value(t, p9.client_open(&home.c, f, p9.OREAD), vx.Status.Ok)
	_, me := p9.client_map(&home.c, f, 0, 4096, {.Read})
	testing.expect_value(t, me, vx.Status.Err_Unsupported)
	_ = p9.client_clunk(&home.c, f)

	// A halt: committed, and nothing more changes.
	testing.expect_value(t, ctl(adm, "halt"), vx.Status.Ok)
	testing.expect_value(t, write_file(home, "after-halt", "x"), vx.Status.Err_Bad_State)
	testing.expect_value(t, read_file(all, "secret"), "secret")
	testing.expect(t, strings.contains(read_file(adm, "status"), " halted\n"))
	testing.expect_value(t, ctl(adm, "snap home home@t3"), vx.Status.Err_Bad_State)

	// The volume as fsd left it, for upstream's host/vxfs to check and read
	// (the reverse of the cross-format test): FSD_TEST_IMAGE=PATH writes it.
	if path := os.get_env("FSD_TEST_IMAGE", context.temp_allocator); path != "" {
		testing.expect_value(t, os.write_entire_file(path, disk), nil)
	}
}

walk :: proc(s: ^Session, path: string) -> p9.Fid {
	f, _ := p9.client_walk(&s.c, s.root, path)
	return f
}
