package backend

import vx "abi:vx"
import "linux"
import "vx:memory"
import "vx:ns"
import "vx:p9"
import "vx:rt"

// Names: stat, access, mkdir, unlink, the working directory, directories,
// and the posix and xattr extensions' calls: rename, symbolic links and
// attributes.

// Walks to path (cleaned into buf): the client and fid, which the caller
// clunks, and the cleaned path; or -errno.
fd_walk :: proc "contextless" (dirfd: int, path: string, follow: bool, buf: ^Path_Buf) -> (c: ^p9.Client, fid: p9.Fid, p: string, e: int) {
	p, e = fd_resolve(dirfd, path, follow, buf)
	if e < 0 {
		return
	}
	st: vx.Status
	c, fid, st = ns.walk(namespace(), p)
	return c, fid, p, errno_of(st)
}

fd_fstat :: proc "contextless" (fd: int, st: ^linux.Stat) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	if o.sock.type != 0 {
		st^ = {
			mode    = linux.S_IFSOCK | 0o777,
			nlink   = 1,
			blksize = 4096,
		}
		return 0
	}
	if o.kind != .File {
		st^ = {
			mode    = o.kind == .Console ? linux.S_IFCHR | 0o620 : linux.S_IFIFO | 0o600,
			nlink   = 1,
			blksize = 4096,
		}
		return 0
	}
	return errno_of(stat_fid(o.f.c, o.f.fid, st))
}

fd_fstatat :: proc "contextless" (dirfd: int, path: string, st: ^linux.Stat, flag: int) -> int {
	if flag & linux.AT_EMPTY_PATH != 0 && len(path) == 0 {
		return fd_fstat(dirfd, st)
	}
	buf: Path_Buf
	c, fid, _, e := fd_walk(dirfd, path, flag & linux.AT_SYMLINK_NOFOLLOW == 0, &buf)
	if e < 0 {
		return e
	}
	sst := stat_fid(c, fid, st)
	_ = p9.client_clunk(c, fid)
	return errno_of(sst)
}

fd_faccessat :: proc "contextless" (dirfd: int, path: string) -> int {
	buf: Path_Buf
	c, fid, _, e := fd_walk(dirfd, path, true, &buf)
	if e < 0 {
		return e
	}
	_ = p9.client_clunk(c, fid)
	return 0 // it exists; permissions are the server's to refuse when it is opened
}

fd_mkdirat :: proc "contextless" (dirfd: int, path: string, mode: u32) -> int {
	buf: Path_Buf
	p, e := fd_resolve(dirfd, path, false, &buf)
	if e < 0 {
		return e
	}
	f: ns.File
	st := ns.create(namespace(), p, p9.DMDIR | (mode & 0o755), p9.OREAD, &f)
	if st == .Ok {
		ns.close(&f)
	}
	if st != .Ok && st != .Err_Exists && fd_exists(p) {
		st = .Err_Exists
	}
	return errno_of(st)
}

fd_unlinkat :: proc "contextless" (dirfd: int, path: string, flag: int) -> int {
	buf: Path_Buf
	c, fid, _, e := fd_walk(dirfd, path, false, &buf)
	if e < 0 {
		return e
	}
	s: p9.Stat
	st := p9.client_stat(c, fid, &s)
	rmdir := flag & linux.AT_REMOVEDIR != 0
	if st == .Ok && (s.mode & p9.DMDIR != 0) != rmdir {
		_ = p9.client_clunk(c, fid)
		return rmdir ? fail(.ENOTDIR) : fail(.EISDIR)
	}
	if st != .Ok {
		_ = p9.client_clunk(c, fid)
		return errno_of(st)
	}
	return errno_of(p9.client_remove(c, fid)) // which clunks it
}

fd_getcwd :: proc "contextless" (buf: []u8) -> int {
	dir := cwd()
	if len(buf) < len(dir) + 1 {
		return fail(.ERANGE)
	}
	copy(buf, dir)
	buf[len(dir)] = 0
	return len(dir) + 1
}

fd_chdir :: proc "contextless" (path: string) -> int {
	buf: Path_Buf
	c, fid, p, e := fd_walk(linux.AT_FDCWD, path, true, &buf)
	if e < 0 {
		return e
	}
	s: p9.Stat
	st := p9.client_stat(c, fid, &s)
	_ = p9.client_clunk(c, fid)
	if st != .Ok {
		return errno_of(st)
	}
	if s.mode & p9.DMDIR == 0 {
		return fail(.ENOTDIR)
	}
	set_cwd(p)
	return 0
}

// 9P directory entries, as Linux's dirent64 (musl's struct dirent is the
// same). A 9P directory can only be read on from where it was, so entries
// that do not fit the caller's buffer wait in the description's page.
fd_getdents :: proc "contextless" (fd: int, buf: []u8) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	if o.kind != .File || !o.dir {
		return fail(.ENOTDIR)
	}
	if o.dirs == nil {
		o.dirs = map_pages([DIR_BUFFER]u8)
		if o.dirs == nil {
			return fail(.ENOMEM)
		}
	}
	written := 0
	for {
		if o.dirs_at == o.dirs_len {
			n, st := ns.read(&o.f, o.dirs[:])
			if (st != .Ok || n == 0) && written > 0 {
				return written
			}
			if st != .Ok {
				return errno_of(st)
			}
			if n == 0 {
				return 0
			}
			o.dirs_len = u32(n)
			o.dirs_at = 0
		}
		it := p9.Dir_Entries {
			buf = o.dirs[:o.dirs_len],
			off = int(o.dirs_at),
		}
		s, ok := p9.next_entry(&it)
		if !ok {
			return written > 0 ? written : fail(.EIO)
		}
		name := s.name[:min(len(s.name), 255)]
		reclen := (linux.DIRENT_NAME + len(name) + 1 + 7) &~ 7
		if written + reclen > len(buf) {
			return written > 0 ? written : fail(.EINVAL)
		}
		rec := buf[written:][:reclen]
		o.dir_next += 1
		d := linux.Dirent {
			ino    = s.qid.path,
			off    = o.dir_next,
			reclen = u16(reclen),
			type   = linux.DT_REG,
		}
		if s.mode & p9.DMDIR != 0 {
			d.type = linux.DT_DIR
		}
		if s.mode & p9.DMSYMLINK != 0 {
			d.type = linux.DT_LNK
		}
		copy(rec, memory.ptr_to_bytes(&d)[:linux.DIRENT_NAME])
		copy(rec[linux.DIRENT_NAME:], name)
		rec[linux.DIRENT_NAME + len(name)] = 0
		written += reclen
		o.dirs_at = u32(it.off)
	}
}

// --- The posix and xattr extensions: names and attributes ---

// path's parent directory, walked, and its last component's name (in buf).
@(private="file")
fd_parent :: proc "contextless" (dirfd: int, path: string, buf: ^Path_Buf) -> (c: ^p9.Client, fid: p9.Fid, name: string, e: int) {
	p, re := fd_resolve(dirfd, path, false, buf)
	if re < 0 {
		return nil, 0, "", re
	}
	slash := len(p)
	for slash > 0 && p[slash - 1] != '/' {
		slash -= 1
	}
	if slash == len(p) {
		return nil, 0, "", fail(.EINVAL) // "/"
	}
	st: vx.Status
	c, fid, st = ns.walk(namespace(), p[:max(slash - 1, 1)])
	if st != .Ok {
		e = errno_of(st)
		return nil, 0, "", e < 0 ? e : fail(.EIO)
	}
	return c, fid, p[slash:], 0
}

// A server without the extension refuses: EPERM, as Linux answers a file
// system that cannot.
@(private="file")
ext_errno :: proc "contextless" (st: vx.Status) -> int {
	return st == .Err_Unsupported ? fail(.EPERM) : errno_of(st)
}

fd_renameat :: proc "contextless" (olddirfd: int, old: string, newdirfd: int, new: string, flags: uint) -> int {
	if flags != 0 {
		return fail(.EINVAL) // RENAME_NOREPLACE and the rest
	}
	b1, b2: Path_Buf
	c1, f1, n1, e1 := fd_parent(olddirfd, old, &b1)
	if e1 < 0 {
		return e1
	}
	c2, f2, n2, e2 := fd_parent(newdirfd, new, &b2)
	if e2 < 0 {
		_ = p9.client_clunk(c1, f1)
		return e2
	}
	// The directories, as fd_parent left them in the buffers before the names.
	d1 := string(b1[:uintptr(raw_data(n1)) - uintptr(&b1[0])])
	d2 := string(b2[:uintptr(raw_data(n2)) - uintptr(&b2[0])])
	posix := c1 == c2 && (.Posix in c1.extensions || c1.dialect == .P9_2000L) // Trenameat's
	r: int
	switch {
	case c1 != c2 || (!posix && d1 != d2):
		r = fail(.EXDEV) // within one server only; a 9P2000 server's (Twstat) within a directory only
	case posix:
		r = ext_errno(p9.client_renameat(c1, f1, n1, f2, n2))
	case:
		// Twstat does not replace what is there, as POSIX's rename does: what
		// is there goes first (not atomically, on such a server).
		st := p9.client_rename_wstat(c1, f1, n1, n2)
		if st == .Err_Exists {
			if there, we := p9.client_walk(c1, f1, n2); we == .Ok && p9.client_remove(c1, there) == .Ok {
				st = p9.client_rename_wstat(c1, f1, n1, n2)
			}
		}
		r = ext_errno(st)
	}
	_ = p9.client_clunk(c1, f1)
	_ = p9.client_clunk(c2, f2)
	return r
}

fd_symlinkat :: proc "contextless" (target: string, dirfd: int, path: string) -> int {
	if len(target) == 0 {
		return fail(.ENOENT)
	}
	buf: Path_Buf
	c, fid, name, e := fd_parent(dirfd, path, &buf)
	if e < 0 {
		return e
	}
	r := ext_errno(p9.client_symlink(c, fid, name, target))
	_ = p9.client_clunk(c, fid)
	return r
}

fd_readlinkat :: proc "contextless" (dirfd: int, path: string, out: []u8) -> int {
	buf, target_buf: Path_Buf
	p, e := fd_resolve(dirfd, path, false, &buf)
	if e < 0 {
		return e
	}
	r, target := link_at(p, &target_buf)
	if r <= 0 {
		return r < 0 ? r : fail(.EINVAL) // not a link
	}
	return copy(out, target) // cut short, as readlink does
}

// Tsetattr on what path names (following its links, unless told not to), or
// on an open descriptor's file (path "" and fd >= 0).
@(private="file")
fd_setattr :: proc "contextless" (fd: int, dirfd: int, path: string, has_path: bool, follow: bool, a: p9.Setattr) -> int {
	if !has_path {
		o := fd_get(fd)
		if o == nil {
			return fail(.EBADF)
		}
		if o.kind != .File {
			return fail(.EINVAL)
		}
		return ext_errno(p9.client_setattr(o.f.c, o.f.fid, a))
	}
	buf: Path_Buf
	c, fid, _, e := fd_walk(dirfd, path, follow, &buf)
	if e < 0 {
		return e
	}
	r := ext_errno(p9.client_setattr(c, fid, a))
	_ = p9.client_clunk(c, fid)
	return r
}

// EACCES from the server is POSIX's EPERM here: not the owner's to change.
@(private="file")
not_owner :: proc "contextless" (r: int) -> int {
	return r == fail(.EACCES) ? fail(.EPERM) : r
}

fd_chmod :: proc "contextless" (fd, dirfd: int, path: string, has_path: bool, mode: u32) -> int {
	return not_owner(fd_setattr(fd, dirfd, path, has_path, true, {valid = {.Mode}, mode = mode & 0o7777}))
}

fd_chown :: proc "contextless" (fd, dirfd: int, path: string, has_path: bool, uid, gid: u32, follow: bool) -> int {
	a := p9.Setattr {
		uid = uid,
		gid = gid,
	}
	if uid != max(u32) {
		a.valid += {.Uid}
	}
	if gid != max(u32) {
		a.valid += {.Gid}
	}
	return a.valid != {} ? not_owner(fd_setattr(fd, dirfd, path, has_path, follow, a)) : 0
}

fd_truncate :: proc "contextless" (fd: int, path: string, has_path: bool, size: i64) -> int {
	if size < 0 {
		return fail(.EINVAL)
	}
	return fd_setattr(fd, linux.AT_FDCWD, path, has_path, true, {valid = {.Size}, size = u64(size)})
}

// utimensat and futimens: each time now (UTIME_NOW, or no times at all), as
// given, or left alone (UTIME_OMIT).
fd_utimens :: proc "contextless" (dirfd: int, path: string, has_path: bool, times: ^[2]linux.Timespec, flags: int) -> int {
	a: p9.Setattr
	for i in 0 ..< 2 {
		nsec := times != nil ? times[i].nsec : linux.UTIME_NOW
		if nsec == linux.UTIME_OMIT {
			continue
		}
		a.valid += {i == 1 ? .Mtime : .Atime}
		if nsec == linux.UTIME_NOW {
			continue
		}
		if nsec < 0 || nsec >= 1_000_000_000 {
			return fail(.EINVAL)
		}
		a.valid += {i == 1 ? .Mtime_Set : .Atime_Set}
		if i == 1 {
			a.mtime_sec, a.mtime_nsec = u64(times[i].sec), u64(nsec)
		} else {
			a.atime_sec, a.atime_nsec = u64(times[i].sec), u64(nsec)
		}
	}
	if a.valid == {} {
		return 0
	}
	// "Now", as this side's clock has it: a server without the xattr
	// extension is told the time itself (Twstat has no "now").
	now: linux.Timespec
	_ = time_get(linux.CLOCK_REALTIME, &now)
	if .Atime in a.valid && .Atime_Set not_in a.valid {
		a.atime_sec, a.atime_nsec = u64(now.sec), u64(now.nsec)
		a.valid += {.Atime_Set}
	}
	if .Mtime in a.valid && .Mtime_Set not_in a.valid {
		a.mtime_sec, a.mtime_nsec = u64(now.sec), u64(now.nsec)
		a.valid += {.Mtime_Set}
	}
	return fd_setattr(has_path ? -1 : dirfd, dirfd, path, has_path, flags & linux.AT_SYMLINK_NOFOLLOW == 0, a)
}

fd_fsync :: proc "contextless" (fd: int) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	if o.kind != .File {
		return fail(.EINVAL)
	}
	return errno_of(p9.client_fsync(o.f.c, o.f.fid))
}

// --- Pipes ---

fd_pipe2 :: proc "contextless" (fds: ^[2]i32, flags: linux.Open_Flags) -> int {
	if flags - {.Cloexec, .Nonblock} != {} {
		return fail(.EINVAL)
	}
	a, b, st := rt.channel_create()
	if st != .Ok {
		return errno_of(st)
	}
	nonblock := flags & {.Nonblock}
	r, w := pipe_ofd(a, true, nonblock), pipe_ofd(b, false, nonblock)
	if r == nil || w == nil {
		if r != nil {
			ofd_release(r)
		}
		if w != nil {
			ofd_release(w)
		}
		return fail(.ENFILE)
	}
	rfd := fd_install(r, 0, .Cloexec in flags)
	if rfd < 0 {
		ofd_release(w)
		return rfd
	}
	wfd := fd_install(w, 0, .Cloexec in flags)
	if wfd < 0 {
		_ = fd_close(rfd)
		return wfd
	}
	fds^ = {i32(rfd), i32(wfd)}
	return 0
}
