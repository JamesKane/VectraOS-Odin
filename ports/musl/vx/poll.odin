package backend

import vx "abi:vx"
import "linux"
import "vx:p9"
import "vx:ring"
import "vx:rt"

// poll, ppoll, select and pselect6, on the one port (upstream docs/01 §9).
//
// Each description knows when it can be read or written:
//   a file or directory      always, as POSIX has it
//   a pipe's reader          its channel has a message, or its writers have
//                            gone (.Readable and .Peer_Closed on fd_port)
//   a pipe's writer          always, unless its reader has gone (POLLERR)
//   a terminal, the console  written always; read once a read kept
//                            outstanding has its reply (the read-ahead, on a
//                            connection of its own; its doorbell on fd_port)
//   a socket                 as a terminal, read; listening, read once an
//                            open of its listen file kept outstanding has its
//                            reply; connecting, written once connect's ctl
//                            write has; written once data written behind has
//                            gone (socket.odin)
// A wait is one port_wait on fd_port, until something armed fires, the
// deadline passes, or a signal comes.

// --- Read-ahead ---

ra_new :: proc "contextless" () -> ^Readahead {
	return map_pages(Readahead)
}

// Lets go of a read-ahead: its connection, and with it its fids and any call
// still outstanding.
ra_drop :: proc "contextless" (ra: ^Readahead) {
	if ra.k.end != vx.HANDLE_NONE {
		rt.p9_disconnect(&ra.k)
	}
	unmap_pages(ra)
}

ra_free :: proc "contextless" (o: ^Ofd) {
	ra := o.ra
	o.ra = nil
	ra_drop(ra)
}

// A connection of the read-ahead's own, and a fid on it: for a terminal, the
// same open file, joined by token (posix); for the console, its cons file.
@(private="file")
ra_start :: proc "contextless" (o: ^Ofd) -> bool {
	if o.sock.type != 0 {
		return sock_ra_start(o)
	}
	ra := ra_new()
	if ra == nil {
		return false
	}
	tty := o.kind == .File
	connector := tty ? conn_connector(o.f.c) : rt.console_connector()
	st := connector != vx.HANDLE_NONE ? rt.p9_connect(connector, &ra.k) : vx.Status.Err_Not_Found
	c := &ra.k.c
	if st == .Ok && tty {
		token: [p9.TOKEN_SIZE]u8
		token, st = p9.client_share(o.f.c, o.f.fid, 1)
		if st == .Ok {
			ra.fid, st = p9.client_join(c, token)
		}
	} else if st == .Ok {
		root: p9.Fid
		root, st = p9.client_attach(c, "")
		if st == .Ok {
			ra.fid, st = p9.client_walk(c, root, "cons")
			if st == .Ok {
				st = p9.client_open(c, ra.fid, p9.OREAD)
			}
			_ = p9.client_clunk(c, root)
		}
	}
	o.ra = ra
	if st != .Ok {
		ra_free(o)
		return false
	}
	return true
}

// Sends the call t on the read-ahead's connection, outstanding until
// ra_poll takes its reply. A call that cannot be sent is answered at once,
// with why.
ra_send :: proc "contextless" (ra: ^Readahead, t: ^p9.Msg) {
	st := rt.p9_send(&ra.k, t)
	ra.ready = st != .Ok
	ra.pending = st == .Ok
	ra.status = st
	ra.tag = t.tag
}

// A write's rest, from ra.pos: what the server did not take yet.
ra_send_write :: proc "contextless" (ra: ^Readahead) {
	t := p9.Msg {
		type = .Twrite,
		fid  = ra.fid,
		data = ra.data[ra.pos:ra.len],
	}
	ra_send(ra, &t)
}

// Takes the reply to the call outstanding, if it has come; for a read, sends
// one if none is outstanding. True once there is an answer: bytes, the end
// of the file, or an error (a read); the open or write done, or why not. A
// write the server took only part of goes on with the rest. Idle (no call),
// true.
ra_poll :: proc "contextless" (ra: ^Readahead, tty: bool) -> bool {
	if ra.ready || (ra.op == .Read && ra.pos < ra.len) {
		return true
	}
	if !ra.pending && ra.op != .Read {
		return true
	}
	if !ra.pending {
		t := p9.Msg {
			type   = .Tread,
			fid    = ra.fid,
			offset = tty ? p9.OFFSET_CURRENT : 0,
			count  = RA_MAX,
		}
		ra_send(ra, &t)
		if ra.ready {
			return true
		}
	}
	r: p9.Msg
	st := rt.p9_receive(&ra.k, ra.tag, &r)
	if st == .Err_Should_Wait {
		return false
	}
	ring.end_sleep(&ra.k.ring)
	ra.pending = false
	ra.status = st
	if ra.op == .Write {
		if st == .Ok && r.count > 0 && r.count <= ra.len - ra.pos {
			ra.pos += r.count
		}
		if st == .Ok && ra.pos < ra.len { // the rest, as the server makes room
			ra_send_write(ra)
			return ra.ready
		}
		ra.ready = true
		return true
	}
	ra.ready = true
	ra.pos, ra.len = 0, 0
	if st == .Ok && r.type == .Rread {
		ra.len = u32(copy(ra.data[:], r.data))
	}
	return true
}

// Waits for the read-ahead's answer (ra_poll), its doorbell on fd_port
// under key: 0; -EAGAIN if it must not wait (or SO_RCVTIMEO's deadline
// passed); -EINTR if a signal came (the call stays outstanding).
ra_wait_until :: proc "contextless" (ra: ^Readahead, key: u64, tty, block: bool, deadline: vx.Instant) -> int {
	for !ra_poll(ra, tty) {
		if !block {
			return fail(.EAGAIN)
		}
		if !ra.armed {
			ra.armed = rt.p9_arm(&ra.k, fd_port, key)
		}
		if !ra.armed {
			continue // a reply may be there already
		}
		switch fd_wait(deadline) {
		case fail(.EINTR):
			return fail(.EINTR)
		case fail(.ETIMEDOUT):
			return fail(.EAGAIN) // SO_RCVTIMEO's, as Linux answers it
		}
	}
	return 0
}

ra_wait :: proc "contextless" (ra: ^Readahead, key: u64, tty, block: bool) -> int {
	return ra_wait_until(ra, key, tty, block, vx.INFINITE)
}

// Before a fork, a spawn or an exec: a terminal's or the console's read kept
// outstanding, with nothing in hand yet, is let go with its connection, so
// the input it waits for goes to the child that reads next, not to this
// process's call, served first. (What it holds already stays this
// process's, as stdio's buffer does.) The next poll sends another.
fd_quiet_reads :: proc "contextless" () {
	for &o in ofds {
		if o.kind == .Free || o.ra == nil || o.sock.type != 0 || o.ra.op != .Read {
			continue
		}
		if ra_poll(o.ra, o.kind == .File) && (o.ra.ready || o.ra.pos < o.ra.len) {
			continue
		}
		ra_free(&o)
	}
}

@(private="file")
ra_arm :: proc "contextless" (o: ^Ofd) {
	if !o.ra.armed {
		o.ra.armed = rt.p9_arm(&o.ra.k, fd_port, fd_key(o))
	}
}

// A read through the read-ahead: what it holds, or what its outstanding read
// brings. A signal ends the wait (EINTR); the read stays outstanding.
ra_read :: proc "contextless" (o: ^Ofd, buf: []u8, block: bool) -> int {
	ra := o.ra
	if w := ra_wait(ra, fd_key(o), o.kind == .File, block); w < 0 {
		return w
	}
	if ra.status != .Ok {
		ra.ready = false
		return errno_of(ra.status) // ptyd's "interrupted" is EINTR
	}
	n := copy(buf, ra.data[ra.pos:ra.len])
	ra.pos += u32(n)
	if ra.pos == ra.len {
		ra.ready = false // all given: the next read sends another
	}
	return n
}

// --- Readiness ---

POLL_IN :: linux.Poll_Events{.In, .Rdnorm}
POLL_OUT :: linux.Poll_Events{.Out, .Wrnorm}

// What fd is ready for, of events; arming fd_port to hear of the rest.
@(private="file")
fd_ready :: proc "contextless" (fd: int, events: linux.Poll_Events, arm: bool) -> linux.Poll_Events {
	o := fd_get(fd)
	if o == nil {
		return {.Nval}
	}
	switch o.kind {
	case .Pipe_In:
		if o.msg_pos < o.msg_len || o.ended {
			return events & POLL_IN
		}
		_, st := rt.channel_read(o.pipe, nil) // a look, taking nothing
		#partial switch st {
		case .Err_Too_Small:
			return events & POLL_IN
		case .Err_Peer_Closed:
			return {.Hup} + events & POLL_IN
		}
		if arm && events & POLL_IN != {} {
			pipe_arm(o)
		}
		return {}
	case .Pipe_Out:
		if _, st := rt.channel_read(o.pipe, nil); st == .Err_Peer_Closed {
			return {.Err}
		}
		return events & POLL_OUT
	case .Console, .File:
		if o.sock.type != 0 {
			return sock_ready(o, events, arm)
		}
		r := events & POLL_OUT
		if events & POLL_IN == {} {
			return r
		}
		if o.kind == .File && !o.tty {
			return r + events & POLL_IN
		}
		if o.ra == nil && !ra_start(o) {
			return r + events & POLL_IN // no read-ahead: a read just blocks
		}
		if ra_poll(o.ra, o.kind == .File) {
			return r + events & POLL_IN
		}
		if arm {
			ra_arm(o)
		}
		return r
	case .Free:
	}
	return {.Nval}
}

// Every fd's readiness, arming what is not ready, until one is, the deadline
// passes, or a signal comes.
@(private="file")
fd_poll :: proc "contextless" (fds: []linux.Pollfd, deadline: vx.Instant) -> int {
	if len(fds) > FD_MAX * 4 {
		return fail(.EINVAL)
	}
	for {
		ready := 0
		for &p in fds {
			p.revents = p.fd < 0 ? {} : fd_ready(int(p.fd), p.events, true)
			if p.revents != {} {
				ready += 1
			}
		}
		if ready > 0 || rt.clock_read() >= deadline {
			return ready
		}
		if fd_wait(deadline) == fail(.EINTR) {
			return fail(.EINTR)
		}
	}
}

// --- The calls ---

// The deadline, kept when the call is made again after a signal; or -EINVAL
// for a timeout that is not one.
@(private="file")
poll_deadline :: proc "contextless" (ts: ^linux.Timespec) -> (vx.Instant, int) {
	if sig_restarting {
		return sig_call_deadline, 0
	}
	sig_call_deadline = vx.INFINITE
	if ts != nil {
		d, e := time_deadline(ts, false)
		if e < 0 {
			return 0, e
		}
		sig_call_deadline = d
	}
	return sig_call_deadline, 0
}

// ppoll and pselect6's mask: in place for the wait, and for the handlers a
// signal it lets through runs (as sigsuspend's); the old one after.
poll_masked :: proc "contextless" (fds: []linux.Pollfd, ts: ^linux.Timespec, mask: rawptr) -> int {
	deadline, e := poll_deadline(ts)
	if e < 0 {
		return e
	}
	if mask == nil {
		return fd_poll(fds, deadline)
	}
	was := sig_mask
	sig_mask = sigset_word(mask) - UNBLOCKABLE
	r := pending_load() - sig_mask != {} ? fail(.EINTR) : fd_poll(fds, deadline)
	if r == fail(.EINTR) {
		_ = sig_deliver_pending()
	}
	sig_mask = was
	return r
}

// x86_64's poll; aarch64 has ppoll only.
sys_poll :: proc "contextless" (fds: []linux.Pollfd, timeout_ms: int) -> int {
	ts := linux.Timespec{i64(timeout_ms / 1000), i64(timeout_ms % 1000) * 1_000_000}
	return poll_masked(fds, timeout_ms < 0 ? nil : &ts, nil)
}

@(private="file")
fd_isset :: proc "contextless" (s: ^linux.Fd_Set, fd: int) -> bool {
	return s != nil && s.bits[fd / 64] & (1 << uint(fd % 64)) != 0
}

@(private="file")
fd_change :: proc "contextless" (s: ^linux.Fd_Set, fd: int, set: bool) {
	if s == nil {
		return
	}
	if set {
		s.bits[fd / 64] |= 1 << uint(fd % 64)
	} else {
		s.bits[fd / 64] &~= 1 << uint(fd % 64)
	}
}

// select and pselect6: fd_sets as pollfds, and back.
sys_select :: proc "contextless" (nfds: int, rd, wr, ex: ^linux.Fd_Set, ts: ^linux.Timespec, mask: rawptr) -> int {
	if nfds < 0 || nfds > linux.FD_SETSIZE {
		return fail(.EINVAL)
	}
	watched := min(nfds, FD_MAX)
	fds: [FD_MAX]linux.Pollfd
	n := 0
	for fd in 0 ..< watched {
		events: linux.Poll_Events
		if fd_isset(rd, fd) {
			events += {.In}
		}
		if fd_isset(wr, fd) {
			events += {.Out}
		}
		if fd_isset(ex, fd) {
			events += {.Pri}
		}
		if events == {} {
			continue
		}
		if !fd_valid(fd) {
			return fail(.EBADF)
		}
		fds[n] = {
			fd     = i32(fd),
			events = events,
		}
		n += 1
	}
	r := poll_masked(fds[:n], ts, mask)
	if r < 0 {
		return r
	}
	for fd in 0 ..< watched { // only the first nfds bits: a caller's set may be no larger
		fd_change(rd, fd, false)
		fd_change(wr, fd, false)
		fd_change(ex, fd, false)
	}
	// Each in the sets it was asked for: a hang-up or error is readable and
	// writable, as Linux has it; for a descriptor watched only for
	// exceptions, exceptional, so the wait it ended is not taken for a
	// timeout.
	count := 0
	for p in fds[:n] {
		got, asked := p.revents, p.events
		in_ := .In in asked && got & {.In, .Hup, .Err} != {}
		out := .Out in asked && got & {.Out, .Err} != {}
		exc_on := linux.Poll_Events{.Pri}
		if asked == {.Pri} {
			exc_on += {.Hup, .Err}
		}
		exc := .Pri in asked && got & exc_on != {}
		if in_ {
			fd_change(rd, int(p.fd), true)
			count += 1
		}
		if out {
			fd_change(wr, int(p.fd), true)
			count += 1
		}
		if exc {
			fd_change(ex, int(p.fd), true)
			count += 1
		}
	}
	return count
}
