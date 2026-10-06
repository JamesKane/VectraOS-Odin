package backend

import vx "abi:vx"
import "linux"
import "vx:memory"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:utf"

// File descriptors, in the process (upstream docs/01 §9).
//
// A descriptor names an open file description, which dup and fcntl's F_DUPFD
// share: the offset and the status flags, as POSIX has them. A description
// is the console, an end of a pipe, or a file or directory in the namespace,
// which is built from the spawn message the first time a path is used.
//
// A file on a server with the posix extension keeps its offset and O_APPEND
// in the server (upstream docs/proto/posix.md): reads and writes at its
// current offset, lseek by Tseek. A child (fork, posix_spawn, exec) joins the
// same open file with a token, so the offset is shared as POSIX has it; a
// child that cannot opens the file again, with an offset of its own.
//
// A pipe is a channel: each write a message of a header and up to 4 KiB, as
// vx:rt's stdio has them, so pipes join POSIX programs and first-party ones.
// Its ends are shared as POSIX shares them: dup shares the description, and
// a child (fork, posix_spawn, exec) holds the same channel end, so the reader
// sees the end of the file when the last writer anywhere has closed.
//
// One thread is all a process has until pthreads, so nothing here locks yet.

FD_MAX :: 64
PIPE_CHUNK :: 4096 // the most a reader's message holds (vx:rt's stdio)
DIR_BUFFER :: 8192 // 9P directory entries read at once
PIPE_BUFFER :: 8192 // a reader's message, in a page of its own
// One Rread's data, or one Twrite's, on a read-ahead's connection.
RA_MAX :: rt.MSIZE - p9.IOHDRSZ
// The most one read or write asks a server for.
IO_MAX :: 1 << 20

Ofd_Kind :: enum u8 {
	Free,
	Console,
	Pipe_In,
	Pipe_Out,
	File,
}

// A call kept outstanding on a connection of its own (poll.odin): a read,
// for a terminal, the console or a socket; for a socket, also an open of its
// listen file (accept) or a write (connect's ctl message, or data written
// behind). A server holds a whole connection while it holds a call, so each
// gets its own; once a description has one, its reads go through it.
Ra_Op :: enum u8 {
	Read,
	Open,
	Write,
}

Readahead :: struct {
	k:       rt.Conn, // its connection; never moved: it lives in pages of its own
	fid:     p9.Fid,
	root:    p9.Fid, // a socket's: the attach on this connection (netd's /net)
	op:      Ra_Op,
	pending: bool, // a call sent
	armed:   bool, // its doorbell bound on fd_port
	ready:   bool, // its reply here
	tag:     u16,
	status:  vx.Status, // the reply's: .Ok, or why it failed
	len:     u32,
	pos:     u32,
	data:    [RA_MAX]u8,
}

// A socket's state, beside its /net data file (socket.odin); type 0 is no
// socket.
Sock :: struct {
	type:       u8, // SOCK_STREAM, SOCK_DGRAM
	bound:      bool, // its port announced, or a connection's
	listening:  bool, // TCP, announced
	connecting: bool, // TCP: connect's ctl write outstanding, on ra
	connected:  bool, // TCP: connected, by connect (another is EISCONN) or accept
	shut:       bool, // TCP: shut down for writing (a write is EPIPE without asking netd)
	rcvtimeo:   i64, // SO_RCVTIMEO, in ns: a receive that waits longer is EAGAIN (0: for ever)
	port:       u16, // TCP: what bind asked for, for listen to announce
	error:      linux.Errno, // SO_ERROR: why a connect that did not wait failed
}

// An open file description.
Ofd :: struct {
	kind:         Ofd_Kind,
	dir:          bool,
	refs:         u32,
	flags:        linux.Open_Flags, // the access mode, O_APPEND, O_NONBLOCK
	f:            ns.File, // a file's fid and offset
	dirs:         ^[DIR_BUFFER]u8, // a directory's 9P entries read but not yet returned
	dirs_len:     u32,
	dirs_at:      u32,
	dir_next:     i64, // getdents64's d_off for the next entry
	path:         [dynamic; ns.MAX_PATH]u8, // cleaned and absolute: for *at calls and rewinding a directory
	pipe:         vx.Handle, // a pipe's channel end
	msg:          ^[PIPE_BUFFER]u8, // a reader's current message,
	msg_len:      u32, // and how much of it has been read
	msg_pos:      u32,
	ended:        bool, // the writers have all gone
	closed_bound: bool, // .Peer_Closed is bound once (it fires once)
	read_bound:   bool, // a .Readable binding is on fd_port for its pipe
	token:        [p9.TOKEN_SIZE]u8, // a file's, for a forked child to join its open file
	has_token:    bool,
	lost:         bool, // a file a forked child could not get back: every call on it is EBADF but close
	tty:          bool, // a terminal's slave or master (ptyd: the file is a 9P device)
	master:       bool,
	pty:          u32,
	locked:       bool, // a lock was taken through it: let go at exit, before the exit is seen
	ra:           ^Readahead,
	wb:           ^Readahead, // TCP: data written behind, without waiting (O_NONBLOCK)
	sock:         Sock,
}

Slot :: struct {
	o:       ^Ofd,
	cloexec: bool,
}

ofds: [FD_MAX]Ofd
fd_table: [FD_MAX]Slot

// The namespace, built from the spawn message when a path is first used.
@(private="file")
space: ns.Namespace
@(private="file")
space_built: bool

// Where every wait in the back end waits: a blocked pipe read, a read-ahead's
// doorbell, a signal (KEY_SIGNAL).
fd_port: vx.Handle

// A packet sig_note posts on fd_port: a signal came while the back end ran,
// just before a wait it ends.
KEY_SIGNAL :: max(u64)

// The working directory, cleaned and absolute; empty is "/".
@(private="file")
cwd_buf: [dynamic; ns.MAX_PATH]u8

cwd :: proc "contextless" () -> string {
	return len(cwd_buf) == 0 ? "/" : string(cwd_buf[:])
}

set_cwd :: proc "contextless" (p: string) {
	clear(&cwd_buf)
	_ = append(&cwd_buf, p)
}

// fd_port's keys: 1 + a description's index, and FD_MAX more for its
// write-behind; a packet names its binding's trigger, and a binding that
// fired is gone.
ofd_index :: proc "contextless" (o: ^Ofd) -> u64 {
	return u64((uintptr(o) - uintptr(&ofds[0])) / size_of(Ofd))
}

fd_key :: proc "contextless" (o: ^Ofd) -> u64 {
	return 1 + ofd_index(o)
}

wb_key :: proc "contextless" (o: ^Ofd) -> u64 {
	return fd_key(o) + FD_MAX
}

@(private="file")
noted :: proc "contextless" (packets: []vx.Packet) {
	for &pk in packets {
		if pk.key == 0 || pk.key > 2 * FD_MAX {
			continue
		}
		o := &ofds[(pk.key - 1) % FD_MAX]
		if pk.key > FD_MAX {
			if o.wb != nil {
				o.wb.armed = false
			}
			continue
		}
		#partial switch pk.trigger {
		case .Readable:
			o.read_bound = false
		case .Counter_Ge:
			if o.ra != nil {
				o.ra.armed = false
			}
		}
	}
}

// Waits on fd_port until something armed there fires, or the deadline:
// 0, -ETIMEDOUT, or -EINTR (a signal: the caller's call ends).
fd_wait :: proc "contextless" (deadline: vx.Instant) -> int {
	pk: [16]vx.Packet
	held := be_wait_begin() // another thread may write the pipe this one waits on
	n, st := rt.port_wait(fd_port, deadline, 0, pk[:])
	be_wait_end(held)
	#partial switch st {
	case .Err_Interrupted:
		return fail(.EINTR)
	case .Err_Timed_Out:
		return fail(.ETIMEDOUT)
	}
	noted(pk[:n])
	for &p in pk[:n] {
		if p.key == KEY_SIGNAL {
			return fail(.EINTR)
		}
	}
	return 0
}

ofd_new :: proc "contextless" (kind: Ofd_Kind, flags: linux.Open_Flags) -> ^Ofd {
	for &o in ofds {
		if o.kind == .Free {
			o = {
				kind  = kind,
				refs  = 1,
				flags = flags,
			}
			return &o
		}
	}
	return nil
}

// A page-rounded mapping of a VMO of its own, writable: buffers too large to
// keep for every description.
map_pages :: proc "contextless" ($T: typeid) -> ^T {
	size, _ := memory.page_round(size_of(T))
	vmo, st := rt.vmo_create(size)
	if st != .Ok {
		return nil
	}
	at, mst := rt.as_map(rt.self, vmo, 0, size, {.Write})
	rt.close_all(vmo) // the mapping keeps it
	return mst == .Ok ? (^T)(uintptr(at)) : nil
}

unmap_pages :: proc "contextless" (p: ^$T) {
	size, _ := memory.page_round(size_of(T))
	_ = rt.as_unmap(rt.self, u64(uintptr(p)), size)
}

ofd_release :: proc "contextless" (o: ^Ofd) {
	o.refs -= 1
	if o.refs > 0 {
		return
	}
	if o.kind == .File {
		ns.close(&o.f)
	}
	if o.dirs != nil {
		unmap_pages(o.dirs)
	}
	if o.msg != nil {
		unmap_pages(o.msg)
	}
	if o.pipe != vx.HANDLE_NONE {
		rt.close_all(o.pipe) // the last writer gone: the reader sees the end of the file
	}
	if o.ra != nil {
		ra_free(o)
	}
	if o.wb != nil { // what was written behind goes first, as a close lets it on Linux
		for ra_wait(o.wb, wb_key(o), false, true) == fail(.EINTR) {}
		ra_drop(o.wb)
	}
	o^ = {}
}

// The lowest free descriptor from low, given o (whose reference it takes).
fd_install :: proc "contextless" (o: ^Ofd, low: int, cloexec: bool) -> int {
	for fd in max(low, 0) ..< FD_MAX {
		if fd_table[fd].o == nil {
			fd_table[fd] = {o, cloexec}
			return fd
		}
	}
	ofd_release(o)
	return fail(.EMFILE)
}

fd_get :: proc "contextless" (fd: int) -> ^Ofd {
	if fd < 0 || fd >= FD_MAX {
		return nil
	}
	o := fd_table[fd].o
	return o != nil && !o.lost ? o : nil
}

fd_valid :: proc "contextless" (fd: int) -> bool {
	return fd_get(fd) != nil
}

pipe_ofd :: proc "contextless" (end: vx.Handle, reader: bool, flags: linux.Open_Flags) -> ^Ofd {
	o := ofd_new(reader ? .Pipe_In : .Pipe_Out, (reader ? linux.O_RDONLY : linux.O_WRONLY) + flags)
	if o == nil {
		rt.close_all(end)
		return nil
	}
	o.pipe = end
	return o
}

fd_place :: proc "contextless" (fd: int, o: ^Ofd) {
	if o == nil {
		return
	}
	if fd_table[fd].o != nil {
		ofd_release(fd_table[fd].o)
	}
	fd_table[fd] = {o, false}
}

// The descriptors the spawn message gives: fd= records from a POSIX parent
// (from_records), or else 0, 1 and 2 from the pipes it names ("stdin",
// "stdout", "stderr", as vx:rt's programs take them: a shell's
// redirections) and the console for what it does not. Without a pipe for
// it, standard error goes to the console, so a pipeline's errors reach its
// terminal; without a console either, to stdout.
fd_init :: proc "contextless" () {
	console := rt.spawn_take("console")
	if console != vx.HANDLE_NONE && rt.console_attach(console) != .Ok {
		rt.print("vx-musl: cannot open the console\n")
	}
	fd_port, _ = rt.port_create()
	rec: ndb.Record
	if rt.spawn_record("fd", &rec) {
		from_records()
		return
	}
	in_end, out_end, err_end := rt.spawn_take("stdin"), rt.spawn_take("stdout"), rt.spawn_take("stderr")
	cons := console != vx.HANDLE_NONE ? ofd_new(.Console, linux.O_RDWR) : nil
	input := in_end != vx.HANDLE_NONE ? pipe_ofd(in_end, true, {}) : cons
	output := out_end != vx.HANDLE_NONE ? pipe_ofd(out_end, false, {}) : cons
	errors := cons != nil ? cons : output
	if err_end != vx.HANDLE_NONE {
		errors = pipe_ofd(err_end, false, {})
	}
	std := [3]^Ofd{input, output, errors}
	for o, fd in std {
		if o == nil {
			continue
		}
		if fd_table[0].o == o || fd_table[1].o == o || fd_table[2].o == o {
			o.refs += 1
		}
		fd_table[fd].o = o
	}
}

// At exit: what print has buffered goes out, and this process's pipe ends
// close, so a reader sees the end of its file before the exit.
fd_exit :: proc "contextless" () {
	if rt.console_pending() {
		rt.console_flush()
	}
	// Locks go with the process, as POSIX has it: let go now, not when the
	// server notices the connection has gone, which can be after a parent's
	// wait has returned.
	for &o in ofds {
		if o.kind == .File && o.locked {
			ns.close(&o.f)
		}
	}
	for &o in ofds {
		if o.kind != .Free && o.pipe != vx.HANDLE_NONE {
			rt.close_all(o.pipe)
			o.pipe = vx.HANDLE_NONE
		}
	}
}

// The namespace, built the first time it is wanted. One that failed to
// build has what it got, perhaps nothing.
namespace :: proc "contextless" () -> ^ns.Namespace {
	if !space_built {
		space_built = true
		_ = procns.from_spawn(&space)
	}
	return &space
}

// After a fork: the namespace's connections were not copied; it is built
// again over new ones, if it had been built.
namespace_after_fork :: proc "contextless" () {
	if space_built {
		_ = procns.after_fork(&space)
	}
}

// The connector the namespace's connection c came through, or HANDLE_NONE.
conn_connector :: proc "contextless" (c: ^p9.Client) -> vx.Handle {
	h := vx.HANDLE_NONE
	for &k in space.conns {
		if k.client == c {
			h = k.connector
		}
	}
	return h
}

// A buffer for a cleaned path.
Path_Buf :: [ns.MAX_PATH]u8

// path, relative to dirfd's directory or the working directory, cleaned and
// absolute into out. Returns it, or -errno.
fd_path :: proc "contextless" (dirfd: int, path: string, out: ^Path_Buf) -> (string, int) {
	if len(path) == 0 {
		return "", fail(.ENOENT)
	}
	// Names as ADR-0013 has them: vx:ns would refuse the rest as invalid.
	for i := 0; i < len(path); {
		start := i
		for i < len(path) && path[i] != '/' {
			i += 1
		}
		if !utf.is_name(path[start:i]) {
			return "", fail(.EILSEQ)
		}
		for i < len(path) && path[i] == '/' {
			i += 1
		}
	}
	base := ""
	if path[0] != '/' && dirfd == linux.AT_FDCWD {
		base = cwd()
	} else if path[0] != '/' {
		d := fd_get(dirfd)
		if d == nil {
			return "", fail(.EBADF)
		}
		if d.kind != .File || !d.dir {
			return "", fail(.ENOTDIR)
		}
		base = string(d.path[:])
	}
	joined: [2 * ns.MAX_PATH]u8
	if len(base) + 1 + len(path) >= len(joined) {
		return "", fail(.ENAMETOOLONG)
	}
	n := copy(joined[:], base)
	joined[n] = '/'
	n += 1
	n += copy(joined[n:], path)
	cleaned := ns.clean(string(joined[:n]), out[:])
	return cleaned, len(cleaned) > 0 ? 0 : fail(.ENAMETOOLONG)
}

// A 9P2000 stat as Linux's.
@(private="file")
stat_fill :: proc "contextless" (st: ^linux.Stat, s: ^p9.Stat) {
	dir := s.mode & p9.DMDIR != 0
	type := u32(dir ? linux.S_IFDIR : linux.S_IFREG)
	if s.mode & p9.DMSYMLINK != 0 {
		type = linux.S_IFLNK
	}
	if s.mode & p9.DMDEVICE != 0 {
		type = linux.S_IFCHR
	}
	st^ = {
		dev     = u64(s.dev),
		ino     = s.qid.path,
		mode    = type | (s.mode & 0o777),
		nlink   = dir ? 2 : 1,
		size    = i64(s.length),
		blksize = 4096,
		blocks  = i64((s.length + 511) / 512),
		atim    = {sec = i64(s.atime)},
		mtim    = {sec = i64(s.mtime)},
		ctim    = {sec = i64(s.mtime)},
	}
}

// A fid's stat: Tgetattr's where the server has the xattr extension (times
// to the nanosecond, links, inode), Tstat's otherwise.
stat_fid :: proc "contextless" (c: ^p9.Client, fid: p9.Fid, st: ^linux.Stat) -> vx.Status {
	if a, e := p9.client_getattr(c, fid); e == .Ok {
		st^ = {
			ino     = a.qid.path,
			mode    = a.mode,
			nlink   = auto_cast a.nlink,
			uid     = a.uid,
			gid     = a.gid,
			size    = i64(a.size),
			blksize = auto_cast a.blksize,
			blocks  = i64(a.blocks),
			atim    = {i64(a.atime_sec), i64(a.atime_nsec)},
			mtim    = {i64(a.mtime_sec), i64(a.mtime_nsec)},
			ctim    = {i64(a.ctime_sec), i64(a.ctime_nsec)},
		}
		return .Ok
	}
	s: p9.Stat
	p9.client_stat(c, fid, &s) or_return
	stat_fill(st, &s)
	return .Ok
}

// --- Symbolic links ---
//
// The servers walk names only, so the client follows links (upstream
// docs/proto/posix.md): a walk of the whole path that succeeds went through
// no link, as a link is no directory, and only its last component may be
// one; a walk that fails may have met one on the way, so its prefixes are
// looked at in turn. Only connections with the posix extension can hold
// links.

// Whether the path's last component is a link (1, with its target in
// target), is not (0), or is not there (-errno).
link_at :: proc "contextless" (p: string, target: ^Path_Buf) -> (r: int, t: string) {
	c, fid, st := ns.walk(namespace(), p)
	if st != .Ok {
		return errno_of(st), ""
	}
	s: p9.Stat
	if .Posix in c.extensions && p9.client_stat(c, fid, &s) == .Ok && s.mode & p9.DMSYMLINK != 0 {
		got, rst := p9.client_readlink(c, fid, target[:len(target) - 1])
		#partial switch rst {
		case .Ok:
			r, t = 1, got
		case .Err_Too_Small:
			r = fail(.ENAMETOOLONG)
		case:
			r = fail(.EINVAL)
		}
	}
	_ = p9.client_clunk(c, fid)
	return
}

// path (cleaned, absolute, in out) with its links followed: every one, or
// all but the last component's. Returns it, or -errno; a path that is not
// there comes back as it is, for the caller to find so.
fd_resolve :: proc "contextless" (dirfd: int, path: string, follow: bool, out: ^Path_Buf) -> (string, int) {
	p, e := fd_path(dirfd, path, out)
	if e < 0 {
		return "", e
	}
	for hops := 0; len(p) > 1; hops += 1 {
		if hops == 40 {
			return "", fail(.ELOOP)
		}
		limit := len(p) // what may be followed: all, or up to the last component's parent
		if !follow {
			for limit > 1 && p[limit - 1] != '/' {
				limit -= 1
			}
			if limit > 1 {
				limit -= 1
			}
		}
		if limit <= 1 {
			return p, 0
		}
		buf: Path_Buf
		at := limit
		r, target := link_at(p[:limit], &buf)
		if r < 0 { // not there: a link on the way, perhaps
			r = 0
			for at = 1; at <= limit; at += 1 {
				for at < limit && p[at] != '/' {
					at += 1
				}
				r, target = link_at(p[:at], &buf)
				if r == 0 && at == limit {
					return p, 0
				}
				if r != 0 {
					break
				}
			}
			if r < 0 {
				return p, 0 // a component is missing: the caller finds so
			}
		}
		if r == 0 {
			return p, 0
		}
		// p[:at] is a link: its target, from its directory, and the rest after it.
		next: [2 * ns.MAX_PATH]u8
		n := 0
		dir := at
		for dir > 1 && p[dir - 1] != '/' {
			dir -= 1
		}
		if len(target) == 0 || target[0] != '/' {
			n = copy(next[:], p[:dir])
		}
		if n + len(target) + 1 + (len(p) - at) > len(next) {
			return "", fail(.ENAMETOOLONG)
		}
		n += copy(next[n:], target)
		next[n] = '/'
		n += 1
		n += copy(next[n:], p[at:])
		p = ns.clean(string(next[:n]), out[:])
		if len(p) == 0 {
			return "", fail(.ENAMETOOLONG)
		}
	}
	return p, 0
}
