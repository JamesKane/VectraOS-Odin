package backend

import "base:intrinsics"
import vx "abi:vx"
import "linux"
import "vx:memory"
import "vx:ns"
import "vx:p9"
import "vx:rt"

// Reading and writing: the console, pipes and files (fd.odin has the
// descriptions).

// What a reader is behind: a write waits a little and tries again.
@(private="file")
never: u32

console_write :: proc "contextless" (p: []u8) -> int {
	rt.console_write(p)
	return len(p)
}

// A pipe's message: a header, then up to PIPE_CHUNK bytes.
@(private="file")
Pipe_Msg :: struct {
	header: vx.Msg_Header,
	data:   [PIPE_CHUNK]u8,
}

@(private="file")
pipe_write :: proc "contextless" (o: ^Ofd, p: []u8) -> int {
	pipe_msg: Pipe_Msg = --- // the thread's: its waits let the back end go (a static one was another thread's to overwrite)
	done := 0
	for done < len(p) {
		k := copy(pipe_msg.data[:], p[done:])
		pipe_msg.header = {}
		st: vx.Status
		for tries := 0;; tries += 1 {
			st = rt.channel_write(o.pipe, memory.ptr_to_bytes(&pipe_msg)[:size_of(vx.Msg_Header) + k])
			if st != .Err_Should_Wait {
				break
			}
			if .Nonblock in o.flags {
				return done > 0 ? done : fail(.EAGAIN)
			}
			held := be_wait_begin()
			_ = rt.futex_wait(&never, 0, rt.clock_read() + (tries < 10 ? 100_000 : 1_000_000))
			be_wait_end(held)
		}
		if st == .Err_Peer_Closed && done == 0 {
			sig_raise_self(linux.SIGPIPE) // the reader has gone
		}
		if st != .Ok {
			return done > 0 ? done : errno_of(st) // .Err_Peer_Closed: EPIPE
		}
		done += k
	}
	return len(p)
}

// .Readable and .Peer_Closed on fd_port for a pipe's reader, unless they
// are there.
pipe_arm :: proc "contextless" (o: ^Ofd) {
	if !o.read_bound {
		o.read_bound = rt.port_bind(fd_port, o.pipe, .Readable, fd_key(o)) == .Ok
	}
	if !o.closed_bound {
		o.closed_bound = rt.port_bind(fd_port, o.pipe, .Peer_Closed, fd_key(o)) == .Ok
	}
}

// Reads what the pipe has: the rest of the current message, or the next one.
// 0 once every writer has gone and everything is read.
@(private="file")
pipe_read :: proc "contextless" (o: ^Ofd, buf: []u8) -> int {
	if o.msg == nil {
		o.msg = map_pages([PIPE_BUFFER]u8)
		if o.msg == nil {
			return fail(.ENOMEM)
		}
	}
	for o.msg_pos == o.msg_len && !o.ended {
		size, st := rt.channel_read(o.pipe, o.msg[:])
		switch {
		case st == .Ok && size.bytes >= size_of(vx.Msg_Header):
			o.msg_len = size.bytes
			o.msg_pos = size_of(vx.Msg_Header)
		case st == .Err_Should_Wait:
			if .Nonblock in o.flags {
				return fail(.EAGAIN)
			}
			pipe_arm(o)
			// A packet for another description only means trying again.
			if fd_wait(vx.INFINITE) == fail(.EINTR) {
				return fail(.EINTR)
			}
		case st != .Ok:
			o.ended = true // the writers have gone (or sent more than a message holds)
		}
	}
	n := copy(buf, o.msg[o.msg_pos:o.msg_len])
	o.msg_pos += u32(n)
	return n
}

// Whether the file's offset is the server's (posix).
file_shared :: proc "contextless" (o: ^Ofd) -> bool {
	return o.kind == .File && !o.dir && o.f.c != nil && .Posix in o.f.c.extensions
}

file_offset :: proc "contextless" (o: ^Ofd) -> (at: u64, ok: bool) {
	if !file_shared(o) {
		return o.f.offset, true
	}
	got, st := p9.client_seek(o.f.c, o.f.fid, 0, .Current)
	return got, st == .Ok
}

// A count from a read or write as Linux returns it.
@(private="file")
counted :: proc "contextless" (n: int, st: vx.Status) -> int {
	return st != .Ok ? errno_of(st) : n
}

// --- Calls that may wait for long (upstream's 6d4b) ---
//
// A read of a terminal, the console or a server's pipe, a write a full pipe
// holds, a wait for a child: the back end is let go for the 9P call, so the
// process's other threads go on meanwhile. The description is held for the
// call (a close from another thread takes effect after it), and a file whose
// offset is kept here takes one read or write at a time. Metadata calls
// (walk, stat, open, clunk) are quick, and keep the back end.

@(private="file")
file_read_unlocked :: proc "contextless" (o: ^Ofd, buf: []u8) -> (n: int, st: vx.Status) {
	o.refs += 1
	shared := file_shared(o)
	held := be_wait_begin()
	if shared {
		n, st = p9.client_read(o.f.c, o.f.fid, p9.OFFSET_CURRENT, buf)
	} else {
		rt.mutex_lock(&o.io)
		n, st = ns.read(&o.f, buf)
		rt.mutex_unlock(&o.io)
	}
	be_wait_end(held)
	ofd_release(o)
	return
}

// One write of buf: at the server's offset (shared), at offset (if not -1),
// or at the description's own.
@(private="file")
file_write_unlocked :: proc "contextless" (o: ^Ofd, buf: []u8, offset: i64) -> (n: int, st: vx.Status) {
	o.refs += 1
	shared := file_shared(o)
	held := be_wait_begin()
	if offset >= 0 || shared {
		n, st = p9.client_write(o.f.c, o.f.fid, offset >= 0 ? u64(offset) : p9.OFFSET_CURRENT, buf)
	} else {
		rt.mutex_lock(&o.io)
		n, st = ns.write(&o.f, buf)
		rt.mutex_unlock(&o.io)
	}
	be_wait_end(held)
	ofd_release(o)
	return
}

// The console's read (vx:rt's): one reader at a time, the back end let go.
@(private="file")
console_readers: rt.Mutex

@(private="file")
console_read_unlocked :: proc "contextless" (buf: []u8) -> (n: int, st: vx.Status) {
	held := be_wait_begin()
	rt.mutex_lock(&console_readers)
	n, st = rt.console_read(buf)
	rt.mutex_unlock(&console_readers)
	be_wait_end(held)
	return
}

@(private="file")
file_write :: proc "contextless" (o: ^Ofd, p: []u8) -> int {
	if file_shared(o) { // at the open file's offset, or its end, which the server moves on
		done := 0
		for done < len(p) {
			w, st := file_write_unlocked(o, p[done:][:min(len(p) - done, IO_MAX)], -1)
			if (st != .Ok || w == 0) && done > 0 {
				return done
			}
			if st != .Ok {
				return errno_of(st)
			}
			if w == 0 {
				return fail(.EIO)
			}
			done += w
		}
		return len(p)
	}
	if .Append in o.flags { // to the end as it is now: not atomic without the posix extension
		s: p9.Stat
		if st := p9.client_stat(o.f.c, o.f.fid, &s); st != .Ok {
			return errno_of(st)
		}
		o.f.offset = s.length
	}
	done := 0
	for done < len(p) {
		w, st := file_write_unlocked(o, p[done:][:min(len(p) - done, IO_MAX)], -1)
		if (st != .Ok || w == 0) && done > 0 {
			return done
		}
		if st != .Ok {
			return errno_of(st)
		}
		if w == 0 {
			return fail(.EIO)
		}
		done += w
	}
	return len(p)
}

fd_read :: proc "contextless" (fd: int, buf: []u8) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	if o.sock.type != 0 {
		return sock_recv(o, buf, {}, nil, nil)
	}
	if o.flags & linux.O_ACCMODE == linux.O_WRONLY {
		return fail(.EBADF)
	}
	b := buf[:min(len(buf), IO_MAX)]
	#partial switch o.kind {
	case .Console:
		if o.ra != nil {
			return ra_read(o, b, .Nonblock not_in o.flags)
		}
		return counted(console_read_unlocked(b))
	case .Pipe_In:
		return pipe_read(o, b)
	case .File:
		if o.dir {
			return fail(.EISDIR)
		}
		if o.ra != nil {
			return ra_read(o, b, .Nonblock not_in o.flags)
		}
		return counted(file_read_unlocked(o, b))
	}
	return fail(.EBADF)
}

fd_write :: proc "contextless" (fd: int, buf: []u8) -> int {
	o := fd_get(fd)
	if o == nil || o.flags & linux.O_ACCMODE == linux.O_RDONLY {
		return fail(.EBADF)
	}
	if o.sock.type != 0 {
		return sock_send(o, buf, {}, nil, 0)
	}
	#partial switch o.kind {
	case .Console:
		return console_write(buf)
	case .Pipe_Out:
		return pipe_write(o, buf)
	case .File:
		return file_write(o, buf)
	}
	return fail(.EBADF)
}

// The caller's iovecs, or -EINVAL if there are more than IOV_MAX of them or
// they add up to more than a read or write can return (Linux's SSIZE_MAX).
iovecs :: proc "contextless" (iov: [^]linux.Iovec, count: int) -> (v: []linux.Iovec, total: int, e: int) {
	if count < 0 || count > linux.IOV_MAX {
		return nil, 0, fail(.EINVAL)
	}
	v = iov[:count]
	t: uint
	for &x in v {
		over: bool
		t, over = intrinsics.overflow_add(t, x.len)
		if over || t > uint(max(int)) {
			return nil, 0, fail(.EINVAL)
		}
	}
	return v, int(t), 0
}

iov_bytes :: proc "contextless" (x: linux.Iovec) -> []u8 {
	return ([^]u8)(x.base)[:x.len]
}

// Short reads are allowed, so readv stops at the first one; and after the
// first iovec that got anything, unless the descriptor is a file: a pipe's
// message, a terminal's line or a datagram is what one read gives, and a
// read for the next would wait for more.
fd_readv :: proc "contextless" (fd: int, iov: [^]linux.Iovec, count: int) -> int {
	v, _, e := iovecs(iov, count)
	if e < 0 {
		return e
	}
	o := fd_get(fd)
	file := o != nil && o.kind == .File && o.sock.type == 0 && !o.tty && !o.master
	total := 0
	for x in v {
		if x.len == 0 {
			continue
		}
		r := fd_read(fd, iov_bytes(x))
		if r < 0 {
			return total > 0 ? total : r
		}
		total += r
		if uint(r) < x.len || !file {
			break
		}
	}
	return total
}

// stdio's writes come as a buffer and the data after it: gathered into one
// write, so a line reaches the console or a pipe whole.
fd_writev :: proc "contextless" (fd: int, iov: [^]linux.Iovec, count: int) -> int {
	v, total, e := iovecs(iov, count)
	if e < 0 {
		return e
	}
	gather: [PIPE_CHUNK]u8 = --- // the thread's: a write lets the back end go
	if total <= len(gather) {
		at := 0
		for x in v {
			at += copy(gather[at:], iov_bytes(x))
		}
		if total == 0 {
			return fd_valid(fd) ? 0 : fail(.EBADF)
		}
		return fd_write(fd, gather[:total])
	}
	done := 0
	for x in v {
		if x.len == 0 {
			continue
		}
		w := fd_write(fd, iov_bytes(x))
		if w < 0 {
			return done > 0 ? done : w
		}
		done += w
		if uint(w) < x.len {
			break
		}
	}
	return done
}

// A description pread and pwrite can be used on: a file that is not a
// socket or a terminal.
@(private="file")
positional :: proc "contextless" (o: ^Ofd) -> bool {
	return o.kind == .File && o.sock.type == 0 && !o.tty && !o.master
}

fd_pread :: proc "contextless" (fd: int, buf: []u8, offset: i64) -> int {
	o := fd_get(fd)
	if o == nil || o.flags & linux.O_ACCMODE == linux.O_WRONLY {
		return fail(.EBADF)
	}
	if !positional(o) {
		return fail(.ESPIPE)
	}
	if o.dir {
		return fail(.EISDIR)
	}
	if offset < 0 {
		return fail(.EINVAL)
	}
	o.refs += 1
	held := be_wait_begin()
	n, st := p9.client_read(o.f.c, o.f.fid, u64(offset), buf[:min(len(buf), IO_MAX)])
	be_wait_end(held)
	ofd_release(o)
	return counted(n, st)
}

fd_pwrite :: proc "contextless" (fd: int, buf: []u8, offset: i64) -> int {
	o := fd_get(fd)
	if o == nil || o.flags & linux.O_ACCMODE == linux.O_RDONLY {
		return fail(.EBADF)
	}
	if !positional(o) {
		return fail(.ESPIPE)
	}
	if offset < 0 {
		return fail(.EINVAL)
	}
	return counted(file_write_unlocked(o, buf[:min(len(buf), IO_MAX)], offset))
}

// preadv2 and pwritev2, which musl's pread and pwrite use first: at the
// offset given, or (-1) at the file's own. RWF_NOAPPEND is what an explicit
// offset already means here; any other flag is not supported.
fd_prw2 :: proc "contextless" (fd: int, iov: [^]linux.Iovec, count: int, offset: i64, flags: int, write: bool) -> int {
	if flags & ~int(linux.RWF_NOAPPEND) != 0 {
		return fail(.EOPNOTSUPP)
	}
	if offset == -1 {
		return write ? fd_writev(fd, iov, count) : fd_readv(fd, iov, count)
	}
	if count < 0 || count > linux.IOV_MAX {
		return fail(.EINVAL)
	}
	done := 0
	for x in iov[:count] {
		if x.len == 0 {
			continue
		}
		r := write ? fd_pwrite(fd, iov_bytes(x), offset + i64(done)) : fd_pread(fd, iov_bytes(x), offset + i64(done))
		if r < 0 {
			return done > 0 ? done : r
		}
		done += r
		if uint(r) < x.len {
			break
		}
	}
	return done
}

fd_lseek :: proc "contextless" (fd: int, offset: i64, whence: int) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	if o.kind != .File || o.sock.type != 0 {
		return fail(.ESPIPE)
	}
	if o.dir { // only back to the start (rewinddir): the directory is opened again
		if offset != 0 || whence != linux.SEEK_SET {
			return fail(.EINVAL)
		}
		f: ns.File
		if st := ns.open(namespace(), string(o.path[:]), p9.OREAD, &f); st != .Ok {
			return errno_of(st)
		}
		ns.close(&o.f)
		o.f = f
		o.dirs_len, o.dirs_at, o.dir_next = 0, 0, 0
		return 0
	}
	if file_shared(o) {
		if whence < linux.SEEK_SET || whence > linux.SEEK_END {
			return fail(.EINVAL)
		}
		at, st := p9.client_seek(o.f.c, o.f.fid, offset, p9.Whence(whence)) // SEEK_* are 0, 1, 2
		return st == .Ok ? int(at) : errno_of(st)
	}
	base: i64
	switch whence {
	case linux.SEEK_SET:
	case linux.SEEK_CUR:
		base = i64(o.f.offset)
	case linux.SEEK_END:
		s: p9.Stat
		if st := p9.client_stat(o.f.c, o.f.fid, &s); st != .Ok {
			return errno_of(st)
		}
		base = i64(s.length)
	case:
		return fail(.EINVAL)
	}
	at, over := intrinsics.overflow_add(base, offset)
	if over || at < 0 {
		return fail(.EINVAL)
	}
	o.f.offset = u64(at)
	return int(at)
}
