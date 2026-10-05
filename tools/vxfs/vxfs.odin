// vxfs: makes, fills, reads and checks vx:fs volume images on the build
// machine (upstream docs/11 §7, its host/vxfs), with the library fsd uses.
//
//	vxfs mkfs [-u USER] IMAGE MIB BRANCH...
//	                                    a new volume of MIB MiB, an empty root in each branch;
//	                                    with an adm branch, /adm/users: adm, none and USER
//	                                    (vectra by default), who owns home's root
//	vxfs put IMAGE BRANCH DIR           DIR's tree copied into the branch's root, committed
//	vxfs ls IMAGE LABEL [PATH]          a directory's entries
//	vxfs cat IMAGE LABEL PATH           a file's contents, to stdout
//	vxfs verify IMAGE LABEL DIR         exit 0 if the label holds DIR's tree exactly
//	vxfs check IMAGE                    the checker; exit 0 if the volume is clean
//	vxfs info IMAGE                     the last commit, arenas, labels and space
//	vxfs snap IMAGE BRANCH LABEL        as /adm/ctl's commands (11 §9), each committed
//	vxfs fork IMAGE LABEL BRANCH
//	vxfs del IMAGE LABEL
//	vxfs rollback IMAGE BRANCH LABEL
//
// A LABEL is a snapshot's or a branch's (its last commit). Files are copied
// with their modes, mtimes and symbolic links, owned by the branch root's
// owner, in the order the host's readdir gives them, as upstream's tool
// copies them, so the two make the same image from the same tree.
//
// Its output, its exit codes and the images it makes are upstream's. One
// addition: the time a new volume's roots and users file are stamped with is
// SOURCE_DATE_EPOCH when that is set (as everything ./build makes is), the
// clock's otherwise.
//
// Build: odin build tools/vxfs -collection:vx=lib -collection:abi=abi -out:out/host/vxfs
// (after any ./build command has generated abi/vx/abi_gen.odin). The package
// is not `main` so that tests/host/fs can call run.
package vxfs

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:sys/posix"
import vx "abi:vx"
import "vx:fs"

CACHE :: 4096 // blocks: 64 MiB
USER_ID :: 1000
CHUNK :: 1 << 20

Tool :: struct {
	image:  string,
	fd:     posix.FD,
	vol:    ^fs.Vol,
	out:    io.Writer,
	err:    io.Writer,
	copied: u64,
	owner:  u32, // the branch root's
	group:  u32,
	buf:    []u8, // a file's chunk, as put and cat copy it
	other:  []u8, // the volume's side of it, as verify compares it
}

main :: proc() {
	os.exit(run(os.args[1:], os.to_writer(os.stdout), os.to_writer(os.stderr)))
}

// Runs one command (os.args[1:]): its exit status.
run :: proc(args: []string, out, err: io.Writer) -> int {
	t := Tool{fd = -1, out = out, err = err}
	t.vol = new(fs.Vol)
	t.buf = make([]u8, CHUNK)
	t.other = make([]u8, CHUNK)
	defer {
		if t.fd >= 0 {
			posix.close(t.fd)
		}
		free(t.vol)
		delete(t.buf)
		delete(t.other)
	}
	return command(&t, args)
}

// --- The image as a device, the C heap as memory ---

img_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	n := posix.pread((^posix.FD)(ctx)^, raw_data(buf[:]), fs.BLKSZ, posix.off_t(addr))
	return n == fs.BLKSZ ? .Ok : .Err_Io
}

img_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[fs.BLKSZ]u8) -> vx.Status {
	n := posix.pwrite((^posix.FD)(ctx)^, raw_data(buf[:]), fs.BLKSZ, posix.off_t(addr))
	return n == fs.BLKSZ ? .Ok : .Err_Io
}

// The block class's FLUSH: upstream's fdatasync, which macOS has as fsync.
img_barrier :: proc "contextless" (ctx: rawptr) -> vx.Status {
	return posix.fsync((^posix.FD)(ctx)^) == .OK ? .Ok : .Err_Io
}

m_alloc :: proc "contextless" (_: rawptr, n: int) -> rawptr {
	return libc.malloc(uint(n))
}

m_free :: proc "contextless" (_: rawptr, p: rawptr, _: int) {
	libc.free(p)
}

MEM :: fs.Mem{alloc = m_alloc, free = m_free}

// Says why and gives the exit status 1, as upstream's die does.
die :: proc(t: ^Tool, msg: string, st := vx.Status.Ok) -> int {
	fmt.wprint(t.err, "vxfs: ", msg, sep = "")
	if st != .Ok {
		fmt.wprintf(t.err, ": status %d", i32(st))
	}
	fmt.wprint(t.err, "\n")
	return 1
}

usage :: proc(t: ^Tool) -> int {
	fmt.wprint(t.err, "usage: vxfs mkfs [-u USER] IMAGE MIB BRANCH... | put IMAGE BRANCH DIR | ls IMAGE LABEL [PATH] |\n" +
		"       cat IMAGE LABEL PATH | verify IMAGE LABEL DIR | check IMAGE | info IMAGE |\n" +
		"       snap IMAGE BRANCH LABEL | fork IMAGE LABEL BRANCH | del IMAGE LABEL |\n" +
		"       rollback IMAGE BRANCH LABEL\n")
	return 2
}

cpath :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

open_image :: proc(t: ^Tool, path: string, create: bool, size: u64) -> (dev: fs.Dev, status: int) {
	flags := posix.O_Flags{.RDWR}
	if create {
		flags += {.CREAT, .TRUNC}
	}
	t.fd = posix.open(cpath(path), flags, posix.mode_t{.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if t.fd < 0 {
		return {}, die(t, fmt.tprintf("cannot open %s", path))
	}
	if create && posix.ftruncate(t.fd, posix.off_t(size)) != .OK {
		return {}, die(t, fmt.tprintf("cannot size %s", path))
	}
	st: posix.stat_t
	if posix.fstat(t.fd, &st) != .OK {
		return {}, die(t, fmt.tprintf("cannot stat %s", path))
	}
	return {ctx = &t.fd, read = img_read, write = img_write, barrier = img_barrier, size = u64(st.st_size)}, 0
}

mount :: proc(t: ^Tool) -> int {
	dev, status := open_image(t, t.image, false, 0)
	if status != 0 {
		return status
	}
	if st := fs.mount(t.vol, dev, MEM, CACHE); st != .Ok {
		return die(t, fmt.tprintf("%s: not a volume it can mount", t.image), st)
	}
	return 0
}

finish :: proc(t: ^Tool) -> int {
	if st := fs.commit(t.vol); st != .Ok {
		return die(t, fmt.tprintf("%s: the commit failed", t.image), st)
	}
	fs.unmount(t.vol)
	return 0
}

ns_of :: proc(ts: posix.timespec) -> i64 {
	return i64(ts.tv_sec) * 1_000_000_000 + i64(ts.tv_nsec)
}

// SOURCE_DATE_EPOCH if it is set, as strtoll reads it; the clock otherwise.
now_ns :: proc() -> i64 {
	if e := os.get_env("SOURCE_DATE_EPOCH", context.temp_allocator); e != "" {
		return i64(libc.strtoll(cpath(e), nil, 10)) * 1_000_000_000
	}
	ts: posix.timespec
	posix.clock_gettime(.REALTIME, &ts)
	return ns_of(ts)
}

label_tree :: proc(t: ^Tool, label: string) -> (fs.Tree, int) {
	tr, st := fs.snap_open(t.vol, label)
	if st != .Ok {
		return {}, die(t, fmt.tprintf("no label %s", label), st)
	}
	return tr, 0
}

// --- mkfs: the users file, and home's owner ---

// users(6) as gefs's ream writes it: adm, whose group USER is in; none;
// USER. adm is 0, as POSIX's root is.
make_users :: proc(t: ^Tool, name: string, now: i64) -> vx.Status {
	v := t.vol
	br, st := fs.branch_open(v, "adm")
	if st == .Err_Not_Found {
		return .Ok // no adm branch: no users file
	}
	text := fmt.tprintf("0:adm:adm:%s\n1:none::\n%d:%s:%s:\n", name, USER_ID, name, name)
	if len(text) >= 256 {
		return .Err_Range // as upstream's 256-byte text refuses it (f24356f): a name too long for users(6)'s 32 bytes anyway
	}
	root, f: fs.File
	if st == .Ok {
		root, st = fs.root(v, &br.t)
	}
	if st == .Ok {
		f, st = fs.create(v, &br.t, &root, "users", 0o664, 0, 0, now)
	}
	if st == .Ok {
		st = fs.write(v, &br.t, &f, 0, transmute([]u8)text, now, 0)
	}
	if st != .Ok {
		return st
	}
	if br, st = fs.branch_open(v, "home"); st != .Ok {
		return st == .Err_Not_Found ? .Ok : st
	}
	if root, st = fs.root(v, &br.t); st == .Ok {
		st = fs.setattr(v, &br.t, &root, {valid = {.Uid, .Gid}, uid = USER_ID, gid = USER_ID}, now)
	}
	return st
}

// --- put: a host tree copied in ---

dirent_name :: proc(e: ^posix.dirent) -> string {
	return string(cstring(&e.d_name[0]))
}

mode_bits :: proc(st: ^posix.stat_t) -> u32 {
	return u32(transmute(posix._mode_t)st.st_mode) & 0o7777
}

// Recursive as deep as the host tree.
put_dir :: proc(t: ^Tool, tr: ^fs.Tree, dir: ^fs.File, host: string) -> int {
	v := t.vol
	d := posix.opendir(cpath(host))
	if d == nil {
		return die(t, fmt.tprintf("cannot read %s", host))
	}
	defer posix.closedir(d)
	for e := posix.readdir(d); e != nil; e = posix.readdir(d) {
		name := dirent_name(e)
		if name == "." || name == ".." {
			continue
		}
		path := fmt.aprintf("%s/%s", host, name)
		defer delete(path)
		st: posix.stat_t
		if posix.lstat(cpath(path), &st) != .OK {
			return die(t, fmt.tprintf("cannot stat %s", path))
		}
		mtime := ns_of(st.st_mtim)
		f: fs.File
		s: vx.Status
		switch {
		case posix.S_ISDIR(st.st_mode):
			if f, s = fs.create(v, tr, dir, name, fs.DMDIR | mode_bits(&st), t.owner, t.group, mtime); s != .Ok {
				return die(t, fmt.tprintf("cannot make %s", path), s)
			}
			if status := put_dir(t, tr, &f, path); status != 0 {
				return status
			}
		case posix.S_ISLNK(st.st_mode):
			target: [4097]u8
			n := posix.readlink(cpath(path), raw_data(target[:]), len(target) - 1)
			if n <= 0 {
				return die(t, fmt.tprintf("cannot read the link %s", path))
			}
			if f, s = fs.symlink(v, tr, dir, name, string(target[:n]), t.owner, t.group, mtime); s != .Ok {
				return die(t, fmt.tprintf("cannot make the link %s", path), s)
			}
		case posix.S_ISREG(st.st_mode):
			if f, s = fs.create(v, tr, dir, name, mode_bits(&st), t.owner, t.group, mtime); s != .Ok {
				return die(t, fmt.tprintf("cannot make %s", path), s)
			}
			in_fd := posix.open(cpath(path), {})
			if in_fd < 0 {
				return die(t, fmt.tprintf("cannot open %s", path))
			}
			off: u64
			for {
				n := posix.read(in_fd, raw_data(t.buf), c.size_t(len(t.buf)))
				if n <= 0 {
					break
				}
				if s = fs.write(v, tr, &f, off, t.buf[:n], mtime, 0); s != .Ok {
					posix.close(in_fd)
					return die(t, fmt.tprintf("cannot write %s", path), s)
				}
				off += u64(n)
			}
			posix.close(in_fd)
			t.copied += off
		case:
			continue // devices, sockets and fifos have no place in a volume image
		}
		if s = fs.setattr(v, tr, &f, {valid = {.Mtime, .Atime}, mtime = mtime, atime = mtime}, mtime); s != .Ok {
			return die(t, fmt.tprintf("cannot set the times of %s", path), s)
		}
	}
	return 0
}

// --- verify: a label against a host tree ---

same_file :: proc(t: ^Tool, tr: ^fs.Tree, f: ^fs.File, path: string, size: u64) -> bool {
	if f.d.length != size {
		return false
	}
	in_fd := posix.open(cpath(path), {})
	if in_fd < 0 {
		return false
	}
	defer posix.close(in_fd)
	same := true
	for off := u64(0); same && off < size; {
		n := posix.read(in_fd, raw_data(t.buf), c.size_t(len(t.buf)))
		if n <= 0 {
			same = false
			break
		}
		got, st := fs.read(t.vol, tr, f, off, t.other[:n])
		same = st == .Ok && got == u64(n) && fs.bytes_equal(t.buf[:n], t.other[:n])
		off += u64(n)
	}
	return same
}

// Recursive as deep as the host tree.
verify_dir :: proc(t: ^Tool, tr: ^fs.Tree, dir: ^fs.File, host: string) -> bool {
	v := t.vol
	d := posix.opendir(cpath(host))
	if d == nil {
		return false
	}
	ok := true
	entries := 0
	for e := posix.readdir(d); ok && e != nil; e = posix.readdir(d) {
		name := dirent_name(e)
		if name == "." || name == ".." {
			continue
		}
		path := fmt.tprintf("%s/%s", host, name)
		st: posix.stat_t
		if posix.lstat(cpath(path), &st) != .OK {
			ok = false
		}
		if ok && !posix.S_ISDIR(st.st_mode) && !posix.S_ISLNK(st.st_mode) && !posix.S_ISREG(st.st_mode) {
			continue
		}
		entries += 1
		f: fs.File
		if ok {
			s: vx.Status
			f, s = fs.walk(v, tr, dir, name)
			ok = s == .Ok
		}
		if ok && posix.S_ISDIR(st.st_mode) {
			ok = f.d.mode & fs.DMDIR != 0 && verify_dir(t, tr, &f, path)
		} else if ok && posix.S_ISLNK(st.st_mode) {
			target, got: [4097]u8
			n := posix.readlink(cpath(path), raw_data(target[:]), len(target) - 1)
			g, s := fs.read(v, tr, &f, 0, got[:])
			ok = n > 0 && f.d.mode & fs.DMSYMLINK != 0 && s == .Ok && g == u64(n) && fs.bytes_equal(target[:n], got[:g])
		} else if ok {
			ok = f.d.mode & (fs.DMDIR | fs.DMSYMLINK) == 0 && f.d.mode & 0o7777 == mode_bits(&st) && f.d.mtime == ns_of(st.st_mtim) && same_file(t, tr, &f, path, u64(st.st_size))
		}
		if !ok {
			fmt.wprintf(t.err, "vxfs: %s differs\n", path)
		}
	}
	posix.closedir(d)
	if ok {
		it: fs.Dir_Iter
		n := 0
		st := fs.readdir_start(&it, v, tr, dir)
		if st == .Ok {
			for _ in fs.readdir_next(&it) {
				n += 1
			}
			st = fs.readdir_end(&it)
		}
		if st != .Ok || n != entries {
			fmt.wprintf(t.err, "vxfs: %s holds other entries too\n", host)
			ok = false
		}
	}
	return ok
}

// --- ls, info, check ---

// n right-aligned in width columns (fmt's %4d would pad with zeros).
right :: proc(n: u64, width: int) -> string {
	s := fmt.tprint(n)
	return len(s) >= width ? s : fmt.tprint(strings.repeat(" ", width - len(s), context.temp_allocator), s, sep = "")
}

octal4 :: proc(n: u32) -> string {
	s := fmt.tprintf("%o", n)
	return len(s) >= 4 ? s : fmt.tprint(strings.repeat("0", 4 - len(s), context.temp_allocator), s, sep = "")
}

// One line of ls, as upstream's printf("%c%04o %4u %10llu %.*s\n") writes it.
ls_line :: proc(w: io.Writer, e: fs.Dir_Entry) {
	kind := 'L' if e.d.mode & fs.DMSYMLINK != 0 else ('d' if e.d.mode & fs.DMDIR != 0 else '-')
	fmt.wprintf(w, "%c%s %s %s %s\n", kind, octal4(e.d.mode & 0o7777), right(u64(e.d.uid), 4), right(e.d.length, 10), e.name)
}

info :: proc(t: ^Tool) {
	v := t.vol
	fmt.wprintf(t.out, "commit %d, %d arenas, next generation %d\n", v.sb.commit, len(v.fs.arenas), u64(v.sb.nextgen))
	used, size: u64
	for &a in v.fs.arenas {
		used += a.used
		size += a.size
	}
	fmt.wprintf(t.out, "used %d of %d KiB\n", used / 1024, size / 1024)
	pfx := [1]u8{u8(fs.Key_Kind.Label)}
	s: fs.Scan
	fs.scan_start(&s, &v.snap, pfx[:])
	for kv in fs.scan_next(&v.fs, &s) {
		if len(kv.val) == size_of(fs.Label_Disk) {
			l := fs.load(fs.Label_Disk, kv.val)
			kind := .Mutable in transmute(fs.Label_Flags)u32(l.flags) ? "branch" : "label"
			fmt.wprintf(t.out, "%s %s: snapshot %d\n", kind, string(kv.key[1:]), u64(l.gen))
		}
	}
	fs.scan_end(&v.fs, &s)
}

check :: proc(t: ^Tool) -> int {
	c: fs.Check
	st := fs.check_volume(t.vol, &c)
	fmt.wprintf(t.out, "%d snapshots, %d labels, %d deadlists; %d blocks in use: %d in trees, %d else\n", c.snapshots, c.labels, c.dlists, c.used, c.trees, c.other)
	if st != .Ok {
		fmt.wprintf(t.out, "NOT CLEAN: leaked %d, unallocated %d, shared %d, damaged %d, bad snapshots %d, bad deadlists %d\n", c.leaked, c.unallocated, c.shared, c.damaged, c.bad_snaps, c.bad_lists)
	}
	fs.unmount(t.vol)
	return st == .Ok ? 0 : 1
}

// --- The commands ---

command :: proc(t: ^Tool, args_in: []string) -> int {
	args := args_in
	if len(args) < 2 {
		return usage(t)
	}
	cmd, name := args[0], "vectra"
	if cmd == "mkfs" && len(args) >= 3 && args[1] == "-u" { // -u USER: the volume's user
		name = args[2]
		args = args[2:] // args[1] the image, as for every command
	}
	t.image = args[1]
	v := t.vol
	switch {
	case cmd == "mkfs" && len(args) >= 4:
		end: [^]c.char
		mib := u64(libc.strtoul(cpath(args[2]), &end, 10))
		if end[0] != 0 || mib < 1 || mib > 1 << 22 {
			return die(t, fmt.tprintf("%s is not a size in MiB", args[2]))
		}
		dev, status := open_image(t, t.image, true, mib << 20)
		if status != 0 {
			return status
		}
		now := now_ns()
		st := fs.mkfs(v, dev, MEM, CACHE, 0, args[3:], 0o755, 0, 0, now)
		if st == .Ok {
			st = make_users(t, name, now)
		}
		if st == .Ok {
			st = fs.commit(v)
		}
		if st != .Ok {
			return die(t, fmt.tprintf("cannot make a volume on %s", t.image), st)
		}
		fs.unmount(v)
		return 0
	case cmd == "put" && len(args) == 4:
		if status := mount(t); status != 0 {
			return status
		}
		br, st := fs.branch_open(v, args[2])
		if st != .Ok {
			return die(t, fmt.tprintf("no branch %s", args[2]), st)
		}
		root: fs.File
		if root, st = fs.root(v, &br.t); st != .Ok {
			return die(t, fmt.tprintf("%s has no root", args[2]), st)
		}
		t.owner, t.group = root.d.uid, root.d.gid
		if status := put_dir(t, &br.t, &root, args[3]); status != 0 {
			return status
		}
		if status := finish(t); status != 0 {
			return status
		}
		fmt.wprintf(t.err, "vxfs: %d bytes into %s\n", t.copied, args[2])
		return 0
	case (cmd == "ls" && (len(args) == 3 || len(args) == 4)) || (cmd == "cat" && len(args) == 4):
		if status := mount(t); status != 0 {
			return status
		}
		tr, status := label_tree(t, args[2])
		if status != 0 {
			return status
		}
		path := len(args) == 4 ? args[3] : "/"
		f, st := fs.walk_path(v, &tr, path)
		if st != .Ok {
			return die(t, fmt.tprintf("no %s", path), st)
		}
		if cmd == "ls" {
			it: fs.Dir_Iter
			if st = fs.readdir_start(&it, v, &tr, &f); st == .Ok {
				for e in fs.readdir_next(&it) {
					ls_line(t.out, e)
				}
				st = fs.readdir_end(&it)
			}
			if st != .Ok {
				return die(t, fmt.tprintf("cannot list %s", path), st)
			}
		} else {
			off: u64
			for {
				got: u64
				if got, st = fs.read(v, &tr, &f, off, t.buf); st != .Ok || got == 0 {
					break
				}
				io.write(t.out, t.buf[:got])
				off += got
			}
			if st != .Ok {
				return die(t, fmt.tprintf("cannot read %s", path), st)
			}
		}
		fs.unmount(v)
		return 0
	case cmd == "verify" && len(args) == 4:
		if status := mount(t); status != 0 {
			return status
		}
		tr, status := label_tree(t, args[2])
		if status != 0 {
			return status
		}
		root, st := fs.root(v, &tr)
		if st != .Ok {
			return die(t, fmt.tprintf("%s has no root", args[2]), st)
		}
		ok := verify_dir(t, &tr, &root, args[3])
		fs.unmount(v)
		return ok ? 0 : 1
	case cmd == "check" && len(args) == 2:
		if status := mount(t); status != 0 {
			return status
		}
		return check(t)
	case cmd == "info" && len(args) == 2:
		if status := mount(t); status != 0 {
			return status
		}
		info(t)
		fs.unmount(v)
		return 0
	case (cmd == "snap" || cmd == "fork" || cmd == "rollback") && len(args) == 4:
		if status := mount(t); status != 0 {
			return status
		}
		st: vx.Status
		if cmd == "rollback" {
			st = fs.rollback(v, args[2], args[3])
		} else {
			st = fs.label(v, args[2], args[3], cmd == "fork" ? {.Mutable} : {})
		}
		if st != .Ok {
			return die(t, fmt.tprintf("%s failed", cmd), st)
		}
		return finish(t)
	case cmd == "del" && len(args) == 3:
		if status := mount(t); status != 0 {
			return status
		}
		if st := fs.unlabel(v, args[2]); st != .Ok {
			return die(t, fmt.tprintf("no label %s to delete", args[2]), st)
		}
		return finish(t)
	}
	return usage(t)
}
