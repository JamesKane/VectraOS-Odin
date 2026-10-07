package backend

import vx "abi:vx"
import "linux"
import "vx:ns"
import "vx:p9"
import "vx:rt"

// Opening, closing and duplicating descriptors, and fcntl.

// The 9P open mode for a description's access mode.
open_mode :: proc "contextless" (flags: linux.Open_Flags) -> p9.Open_Mode {
	switch flags & linux.O_ACCMODE {
	case linux.O_WRONLY:
		return p9.OWRITE
	case linux.O_RDWR:
		return p9.ORDWR
	}
	return p9.OREAD
}

// What a description keeps of open's flags.
KEPT_FLAGS :: linux.O_ACCMODE + {.Append, .Nonblock}

// The pty number a ptyd device's name starts with.
@(private="file")
pty_number :: proc "contextless" (name: string) -> (pty: u32) {
	for c in transmute([]u8)name {
		if c < '0' || c > '9' {
			break
		}
		pty = pty * 10 + u32(c - '0')
	}
	return
}

// A terminal is a file its server marks a device: ptyd's ptmx (opened, the
// master) and pts/N (the slave).
tty_note :: proc "contextless" (o: ^Ofd, device: bool, pty: u32) {
	if !device {
		return
	}
	o.tty = true
	o.pty = pty
	path := string(o.path[:])
	o.master = len(path) >= 5 && path[len(path) - 5:] == "/ptmx"
}

// tty_note from the fid's stat: for a file opened again or joined.
tty_check :: proc "contextless" (o: ^Ofd) {
	s: p9.Stat
	names: p9.Stat_Text // the name: the pty's number (UPSTREAM-FINDINGS, fixed upstream in 6319e48)
	if p9.client_stat(o.f.c, o.f.fid, &s, &names) != .Ok || s.mode & p9.DMDEVICE == 0 {
		return
	}
	tty_note(o, true, pty_number(s.name))
}

// Whether path names something: what a create that failed is told apart by,
// since a server may refuse a create (a read-only one, or at a mount point)
// before it looks for the name, and POSIX's answer is then EEXIST.
fd_exists :: proc "contextless" (p: string) -> bool {
	c, fid, st := ns.walk(namespace(), p)
	if st != .Ok {
		return false
	}
	_ = p9.client_clunk(c, fid)
	return true
}

fd_openat :: proc "contextless" (dirfd: int, path: string, flags: linux.Open_Flags, mode: u32) -> int {
	buf: Path_Buf
	excl := flags >= {.Creat, .Excl}
	// O_EXCL never follows a link in the last component: a link there, even a
	// dangling one, is a name that exists.
	p, e := fd_resolve(dirfd, path, .Nofollow not_in flags && !excl, &buf)
	if e < 0 {
		return e
	}
	if len(p) == 5 && p[:4] == "/fd/" && p[4] >= '0' && p[4] <= '9' { // a copy of that descriptor (ADR-0018)
		n := int(p[4] - '0')
		return fd_get(n) != nil ? fd_dup(n, -1, flags & {.Cloexec}) : fail(.ENOENT)
	}
	if .Nofollow in flags {
		target: Path_Buf
		if r, _ := link_at(p, &target); r == 1 {
			return fail(.ELOOP) // the last component is a link
		}
	}
	mode9 := open_mode(flags)
	space := namespace()
	f: ns.File
	open9 := mode9
	if .Trunc in flags {
		open9.trunc = true
	}
	// With O_EXCL, only Tcreate: the server refuses a name that exists, in the
	// same step as making it, so nothing is opened (or truncated) first.
	st := excl ? vx.Status.Err_Not_Found : ns.open(space, p, open9, &f)
	if st == .Err_Not_Found && .Creat in flags {
		st = ns.create(space, p, mode & ~umask & 0o777, mode9, &f)
		// Another process made it between the open and the create: open theirs.
		if st == .Err_Exists && !excl {
			st = ns.open(space, p, open9, &f)
		}
		if excl && st != .Ok && st != .Err_Exists && fd_exists(p) {
			st = .Err_Exists
		}
	}
	if st != .Ok {
		return errno_of(st)
	}
	s: p9.Stat
	names: p9.Stat_Text // a pty's number is its name
	st = p9.client_stat(f.c, f.fid, &s, &names)
	dir := st == .Ok && s.mode & p9.DMDIR != 0
	device := st == .Ok && s.mode & p9.DMDEVICE != 0
	pty := device ? pty_number(s.name) : 0
	if st == .Ok && .Directory in flags && !dir {
		st = .Err_Invalid
	}
	o := st == .Ok ? ofd_new(.File, flags & KEPT_FLAGS) : nil
	if o == nil {
		ns.close(&f)
		if st == .Err_Invalid {
			return fail(.ENOTDIR)
		}
		return st != .Ok ? errno_of(st) : fail(.ENFILE)
	}
	o.f = f
	o.dir = dir
	_ = append(&o.path, p)
	if .Append in flags && file_shared(o) {
		_ = p9.client_append(o.f.c, o.f.fid, true) // atomic, at the server
	}
	tty_note(o, device, pty)
	return fd_install(o, 0, .Cloexec in flags)
}

fd_close :: proc "contextless" (fd: int) -> int {
	if fd < 0 || fd >= FD_MAX || fd_table[fd].o == nil { // a lost one too
		return fail(.EBADF)
	}
	o := fd_table[fd].o
	fd_table[fd].o = nil
	// POSIX: closing any descriptor for a file lets go of the process's locks
	// on it, though another still has it open (the last one's close clunks).
	if o.refs > 1 && o.locked && o.kind == .File && o.f.c != nil {
		_, _ = p9.client_lock(o.f.c, o.f.fid, .Unlock, 0, 0, u32(posix_pid()))
	}
	ofd_release(o)
	return 0
}

// dup (to the lowest free, `to` < 0), dup2 and dup3 (to `to`, closing what
// was there).
fd_dup :: proc "contextless" (fd: int, to: int, flags: linux.Open_Flags) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	if to >= FD_MAX {
		return fail(.EBADF)
	}
	if flags - {.Cloexec} != {} {
		return fail(.EINVAL)
	}
	o.refs += 1
	if to < 0 {
		return fd_install(o, 0, false)
	}
	if fd_table[to].o != nil {
		ofd_release(fd_table[to].o)
	}
	fd_table[to] = {o, .Cloexec in flags}
	return to
}

// dup2 to itself changes nothing, if the descriptor is open (dup3 refuses it).
fd_dup2 :: proc "contextless" (fd, to: int) -> int {
	if fd != to {
		return fd_dup(fd, to, {})
	}
	return fd_valid(fd) ? fd : fail(.EBADF)
}

@(private="file")
lock_type :: proc "contextless" (t: i16) -> (p9.Lock_Type, bool) {
	switch t {
	case linux.F_RDLCK:
		return .Read, true
	case linux.F_WRLCK:
		return .Write, true
	case linux.F_UNLCK:
		return .Unlock, true
	}
	return .Unlock, false
}

// How often F_SETLKW asks again while a lock is held.
@(private="file")
LOCK_RETRY :: vx.Instant(10_000_000)

@(private="file")
never_changes: u32

// fcntl's POSIX locks, held by the server (posix), owned by this process.
// F_SETLKW asks again every 10 ms until it is granted or a signal comes.
@(private="file")
fd_lock :: proc "contextless" (o: ^Ofd, cmd: int, l: ^linux.Flock) -> int {
	if o.kind != .File || o.dir {
		return fail(.EBADF)
	}
	if !file_shared(o) {
		return fail(.ENOLCK) // no server to keep it
	}
	type, known := lock_type(l.type)
	if !known {
		return fail(.EINVAL)
	}
	acc := o.flags & linux.O_ACCMODE
	if cmd == linux.F_SETLK || cmd == linux.F_SETLKW {
		if type == .Read && acc == linux.O_WRONLY {
			return fail(.EBADF)
		}
		if type == .Write && acc == linux.O_RDONLY {
			return fail(.EBADF)
		}
	}
	base: i64
	switch l.whence {
	case linux.SEEK_SET:
	case linux.SEEK_CUR:
		at, ok := file_offset(o)
		if !ok {
			return fail(.EINVAL)
		}
		base = i64(at)
	case linux.SEEK_END:
		st: linux.Stat
		if stat_fid(o.f.c, o.f.fid, &st) != .Ok {
			return fail(.EIO)
		}
		base = st.size
	case:
		return fail(.EINVAL)
	}
	if base < 0 {
		return fail(.EINVAL)
	}
	start, length := base + l.start, l.len
	if length < 0 { // the bytes before
		start += length
		length = -length
	}
	if start < 0 {
		return fail(.EINVAL)
	}
	me := u32(posix_pid())
	if cmd == linux.F_GETLK {
		got, st := p9.client_getlock(o.f.c, o.f.fid, type, u64(start), u64(length), me)
		if st != .Ok {
			return errno_of(st)
		}
		if got.type == .Unlock {
			l.type = linux.F_UNLCK
		} else {
			l^ = {
				type   = i16(got.type),
				whence = linux.SEEK_SET,
				start  = i64(got.start),
				len    = i64(got.length),
				pid    = i32(got.proc_id),
			}
		}
		return 0
	}
	for {
		status, st := p9.client_lock(o.f.c, o.f.fid, type, u64(start), u64(length), me)
		if st != .Ok {
			return errno_of(st)
		}
		if status == .Success {
			o.locked = o.locked || type != .Unlock
			return 0
		}
		if status != .Blocked {
			return fail(.ENOLCK)
		}
		if cmd == linux.F_SETLK {
			return fail(.EAGAIN)
		}
		held := be_wait_begin()
		w := rt.futex_wait(&never_changes, 0, rt.clock_read() + LOCK_RETRY)
		be_wait_end(held)
		if w == .Err_Interrupted {
			return fail(.EINTR)
		}
	}
}

// flock: a lock on the whole file owned by the open file description, as
// BSD's and Linux's are: Tlock with an owner no process id can be (the top
// bit, the description's slot, the process's id), so fcntl's locks and other
// descriptions' do not count as its own. LOCK_NB answers EWOULDBLOCK; without
// it, it asks again every 10 ms, as F_SETLKW.
fd_flock :: proc "contextless" (fd: int, op: int) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	type: p9.Lock_Type
	switch op &~ linux.LOCK_NB {
	case linux.LOCK_SH:
		type = .Read
	case linux.LOCK_EX:
		type = .Write
	case linux.LOCK_UN:
		type = .Unlock
	case:
		return fail(.EINVAL)
	}
	if o.kind != .File || !file_shared(o) {
		return fail(.ENOLCK) // no server to keep it
	}
	owner := 1 << 31 | u32(ofd_index(o)) << 22 | u32(posix_pid()) & (1 << 22 - 1)
	for {
		status, st := p9.client_lock(o.f.c, o.f.fid, type, 0, 0, owner)
		if st != .Ok {
			return errno_of(st)
		}
		if status == .Success {
			return 0
		}
		if status != .Blocked {
			return fail(.ENOLCK)
		}
		if op & linux.LOCK_NB != 0 {
			return fail(.EAGAIN) // EWOULDBLOCK
		}
		held := be_wait_begin()
		w := rt.futex_wait(&never_changes, 0, rt.clock_read() + LOCK_RETRY)
		be_wait_end(held)
		if w == .Err_Interrupted {
			return fail(.EINTR)
		}
	}
}

fd_fcntl :: proc "contextless" (fd: int, cmd: int, arg: int) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	switch cmd {
	case linux.F_DUPFD, linux.F_DUPFD_CLOEXEC:
		if arg < 0 || arg >= FD_MAX {
			return fail(.EINVAL)
		}
		o.refs += 1
		return fd_install(o, arg, cmd == linux.F_DUPFD_CLOEXEC)
	case linux.F_GETFD:
		return fd_table[fd].cloexec ? linux.FD_CLOEXEC : 0
	case linux.F_SETFD:
		fd_table[fd].cloexec = arg & linux.FD_CLOEXEC != 0
		return 0
	case linux.F_GETFL:
		return int(transmute(i32)o.flags)
	case linux.F_SETFL:
		want := transmute(linux.Open_Flags)i32(arg)
		if file_shared(o) && (.Append in o.flags) != (.Append in want) {
			_ = p9.client_append(o.f.c, o.f.fid, .Append in want)
		}
		o.flags = o.flags & linux.O_ACCMODE + want & {.Append, .Nonblock}
		return 0
	case linux.F_GETLK, linux.F_SETLK, linux.F_SETLKW:
		return fd_lock(o, cmd, (^linux.Flock)(uintptr(arg)))
	}
	return fail(.EINVAL) // open-file-description locks and the rest
}
