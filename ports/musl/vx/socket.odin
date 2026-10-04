package backend

import "base:intrinsics"
import vx "abi:vx"
import "linux"
import "vx:ns"
import "vx:p9"
import "vx:rt"
import "vx:str"

// BSD sockets over /net (upstream docs/01 §9), as Plan 9's APE has them.
//
// A socket is a conversation in netd's /net: socket() opens /net/tcp/clone
// (or udp), reads the conversation's number N from the ctl file it becomes,
// and opens /net/tcp/N/data, which the descriptor holds; the conversation
// lasts while that is open. Control goes through N/ctl, opened for each
// message as APE does: bind and listen are "announce PORT", connect is
// "connect ADDR!PORT" (held by netd until the connection is made or
// refused), shutdown is "hangup". accept opens N/listen, which waits for a
// call and becomes the new conversation's ctl. getsockname and getpeername
// read N/local and N/remote.
//
// A UDP conversation reads and writes after netd's 52-byte header
// ("headers" in its ctl, sent when the socket is made), so recvfrom learns
// the sender and sendto names the receiver; a header naming 0.0.0.0 sends to
// the connected peer.
//
// The descriptor is a file (.File) with its socket type set, so fork and
// exec open N/data again by its path, as they do any file: the parent's open
// keeps the conversation alive meanwhile. Only IPv4 (AF_INET) for now.
//
// Waiting is poll's (poll.odin): each socket has a connection of its own to
// netd, its read-ahead, attached at /net's root, which keeps one call
// outstanding: a read of N/data, whose reply reads take; for a listener, an
// open of N/listen, which accept takes; while connecting, connect's write of
// N/ctl. So a read, accept or connect that waits ends with EINTR when a
// signal comes, O_NONBLOCK and MSG_DONTWAIT give EAGAIN (connect,
// EINPROGRESS, its result later in SO_ERROR), and poll and select see a
// socket ready when the reply has come. netd holds a connection while it
// holds a call on it, so TCP data written without waiting goes on a second
// connection, written behind: the write takes what one Twrite carries and
// returns, and the socket is writable again once netd has taken all of it.
// A write to a connection that has closed raises SIGPIPE, unless
// MSG_NOSIGNAL.

@(private="file")
HEADER :: 52 // netd's UDP header

// The socket a descriptor is: ENOTSOCK for any other file.
@(private="file")
sock_get :: proc "contextless" (fd: int) -> (^Ofd, int) {
	o := fd_get(fd)
	if o == nil {
		return nil, fail(.EBADF)
	}
	if o.sock.type == 0 {
		return nil, fail(.ENOTSOCK)
	}
	return o, 0
}

// A status from netd as a socket call's errno.
@(private="file")
sock_errno :: proc "contextless" (st: vx.Status) -> int {
	#partial switch st {
	case .Err_Refused:
		return fail(.ECONNREFUSED)
	case .Err_Timed_Out:
		return fail(.ETIMEDOUT)
	case .Err_Exists:
		return fail(.EADDRINUSE)
	case .Err_Peer_Closed:
		return fail(.ECONNRESET)
	case .Err_Bad_State:
		return fail(.ENETDOWN) // no driver, or no address yet
	}
	return errno_of(st)
}

// --- The socket's own connection to netd ---

// "tcp/N/name": a file of the conversation, from /net's root.
@(private="file")
sock_rel :: proc "contextless" (o: ^Ofd, name: string, buf: ^Path_Buf) -> string {
	path := string(o.path[:])
	b := str.Buf {
		buf = buf[:],
	}
	str.write_string(&b, path[5:len(path) - 5]) // without "/net/" and "/data"
	str.write_byte(&b, '/')
	str.write_string(&b, name)
	return str.to_string(&b)
}

// A read-ahead connected to the server the socket's data file is on (netd),
// attached at its root.
@(private="file")
sock_side :: proc "contextless" (o: ^Ofd) -> ^Readahead {
	connector := conn_connector(o.f.c)
	if connector == vx.HANDLE_NONE {
		return nil
	}
	ra := ra_new()
	if ra == nil {
		return nil
	}
	st := rt.p9_connect(connector, &ra.k)
	if st == .Ok {
		ra.root, st = p9.client_attach(&ra.k.c, "")
	}
	if st != .Ok {
		ra_drop(ra)
		return nil
	}
	return ra
}

// A fid on the read-ahead's connection for the conversation's file name,
// opened (mode) unless it is the listen file, whose open is the call kept
// outstanding.
@(private="file")
sock_side_file :: proc "contextless" (o: ^Ofd, ra: ^Readahead, name: string, mode: p9.Open_Mode) -> (st: vx.Status) {
	buf: Path_Buf
	ra.fid, st = p9.client_walk(&ra.k.c, ra.root, sock_rel(o, name, &buf))
	if st == .Ok && name != "listen" {
		st = p9.client_open(&ra.k.c, ra.fid, mode)
	}
	return
}

// poll.odin's read-ahead for a socket: a read of N/data kept outstanding.
sock_ra_start :: proc "contextless" (o: ^Ofd) -> bool {
	ra := sock_side(o)
	if ra == nil {
		return false
	}
	if sock_side_file(o, ra, "data", p9.OREAD) != .Ok {
		ra_drop(ra)
		return false
	}
	ra.op = .Read
	o.ra = ra
	return true
}

// The socket's read-ahead, started for reading if it has none.
@(private="file")
sock_reader :: proc "contextless" (o: ^Ofd) -> ^Readahead {
	if o.ra != nil && o.ra.op != .Read {
		return nil // listening, or connecting
	}
	if o.ra == nil && !sock_ra_start(o) {
		return nil
	}
	return o.ra
}

// A listener's read-ahead, with an open of N/listen outstanding: what
// accept takes, and poll waits for.
@(private="file")
sock_listener :: proc "contextless" (o: ^Ofd) -> ^Readahead {
	if o.ra != nil && o.ra.op != .Open {
		ra_free(o)
	}
	if o.ra == nil {
		ra := sock_side(o)
		if ra == nil {
			return nil
		}
		ra.op = .Open
		o.ra = ra
	}
	ra := o.ra
	if !ra.pending && !ra.ready { // idle: the next call
		if sock_side_file(o, ra, "listen", {}) != .Ok {
			ra_free(o)
			return nil
		}
		t := p9.Msg {
			type = .Topen,
			fid  = ra.fid,
			mode = p9.ORDWR,
		}
		ra_send(ra, &t)
	}
	return ra
}

// Opens file name in the conversation's directory, "/net/tcp/N".
@(private="file")
sock_open :: proc "contextless" (o: ^Ofd, name: string, mode: p9.Open_Mode, f: ^ns.File) -> vx.Status {
	path := string(o.path[:])
	buf: Path_Buf
	b := str.Buf {
		buf = buf[:len(buf) - 1],
	}
	str.write_string(&b, path[:len(path) - 5]) // without "/data"
	str.write_byte(&b, '/')
	str.write_string(&b, name)
	return ns.open(namespace(), str.to_string(&b), mode, f)
}

// One control message, written to N/ctl.
@(private="file")
sock_ctl :: proc "contextless" (o: ^Ofd, msg: string) -> vx.Status {
	ctl: ns.File
	sock_open(o, "ctl", p9.ORDWR, &ctl) or_return
	_, st := p9.client_write(ctl.c, ctl.fid, 0, transmute([]u8)msg)
	ns.close(&ctl)
	return st
}

// Trailing newlines and blanks off.
@(private="file")
trim :: proc "contextless" (s: string) -> string {
	n := len(s)
	for n > 0 && (s[n - 1] == '\n' || s[n - 1] == ' ') {
		n -= 1
	}
	return s[:n]
}

// A file of the conversation's that is text ("ADDR!PORT", N), read whole.
@(private="file")
sock_text :: proc "contextless" (o: ^Ofd, name: string, buf: []u8) -> (string, int) {
	f: ns.File
	if st := sock_open(o, name, p9.OREAD, &f); st != .Ok {
		return "", errno_of(st)
	}
	n, st := p9.client_read(f.c, f.fid, 0, buf[:len(buf) - 1])
	ns.close(&f)
	if st != .Ok {
		return "", errno_of(st)
	}
	return trim(string(buf[:n])), 0
}

// "a.b.c.d!port" from an address and port in host order.
@(private="file")
sock_format :: proc "contextless" (b: ^str.Buf, addr: u32, port: u16) {
	for i in 0 ..< 4 {
		str.write_u64(b, u64(addr >> uint(24 - 8 * i) & 0xff))
		if i < 3 {
			str.write_byte(b, '.')
		}
	}
	str.write_byte(b, '!')
	str.write_u64(b, u64(port))
}

// "a.b.c.d!port" (or "a.b.c.d", port 0) into an address and port; false if
// it is not one.
sock_parse :: proc "contextless" (s: string) -> (addr: u32, port: u16, ok: bool) {
	i := 0
	for part in 0 ..< 4 {
		v, d := u32(0), 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' && d < 4 {
			v = v * 10 + u32(s[i] - '0')
			i += 1
			d += 1
		}
		if d == 0 || v > 255 {
			return
		}
		addr = addr << 8 | v
		if part < 3 {
			if i >= len(s) || s[i] != '.' {
				return
			}
			i += 1
		}
	}
	p: u32
	if i < len(s) && s[i] == '!' {
		i += 1
		d := 0
		for i < len(s) && s[i] >= '0' && s[i] <= '9' && d < 6 {
			p = p * 10 + u32(s[i] - '0')
			i += 1
			d += 1
		}
		if d == 0 || p > 65535 {
			return
		}
	}
	if i != len(s) {
		return
	}
	return addr, u16(p), true
}

// A sockaddr_in from the caller: its address and port in host order.
@(private="file")
sock_addr_in :: proc "contextless" (sa: rawptr, length: u32) -> (addr: u32, port: u16, e: int) {
	if sa == nil || length < size_of(linux.Sockaddr_In) {
		return 0, 0, fail(.EINVAL)
	}
	sin := intrinsics.unaligned_load((^linux.Sockaddr_In)(sa))
	if sin.family != linux.AF_INET {
		return 0, 0, fail(.EAFNOSUPPORT)
	}
	return u32(sin.addr), u16(sin.port), 0
}

// Gives an address to the caller, cut to the room it has, as Linux does;
// length becomes the whole address's size.
@(private="file")
sock_give :: proc "contextless" (sa: rawptr, length: ^u32, addr: u32, port: u16) {
	if sa == nil || length == nil {
		return
	}
	sin := linux.Sockaddr_In {
		family = linux.AF_INET,
		port   = u16be(port),
		addr   = u32be(addr),
	}
	copy(([^]u8)(sa)[:min(length^, size_of(sin))], ([^]u8)(&sin)[:size_of(sin)])
	length^ = size_of(sin)
}

// N/local or N/remote, as an address and port.
@(private="file")
sock_end :: proc "contextless" (o: ^Ofd, name: string) -> (addr: u32, port: u16, e: int) {
	buf: [64]u8
	text, r := sock_text(o, name, buf[:])
	if r < 0 {
		return 0, 0, r
	}
	ok: bool
	addr, port, ok = sock_parse(text)
	return addr, port, ok ? 0 : fail(.EIO)
}

// A descriptor for conversation N of proto, its data file opened.
@(private="file")
sock_install :: proc "contextless" (proto, num: string, type: u8, flags: int) -> int {
	buf: Path_Buf
	b := str.Buf {
		buf = buf[:len(buf) - 1],
	}
	str.write_string(&b, "/net/")
	str.write_string(&b, proto)
	str.write_byte(&b, '/')
	str.write_string(&b, num)
	str.write_string(&b, "/data")
	p := str.to_string(&b)
	f: ns.File
	if st := ns.open(namespace(), p, p9.ORDWR, &f); st != .Ok {
		return sock_errno(st)
	}
	o := ofd_new(.File, linux.O_RDWR + (flags & linux.SOCK_NONBLOCK != 0 ? {.Nonblock} : {}))
	if o == nil {
		ns.close(&f)
		return fail(.ENFILE)
	}
	o.f = f
	o.sock.type = type
	_ = append(&o.path, p)
	return fd_install(o, 0, flags & linux.SOCK_CLOEXEC != 0)
}

// The conversation number a ctl file (open) reads as.
@(private="file")
sock_number :: proc "contextless" (c: ^p9.Client, fid: p9.Fid, buf: []u8) -> (string, int) {
	n, st := p9.client_read(c, fid, 0, buf)
	if st != .Ok {
		return "", sock_errno(st)
	}
	num := trim(string(buf[:n]))
	if len(num) == 0 {
		return "", fail(.EIO)
	}
	for ch in transmute([]u8)num {
		if ch < '0' || ch > '9' {
			return "", fail(.EIO)
		}
	}
	return num, 0
}

sock_socket :: proc "contextless" (domain, type, protocol: int) -> int {
	kind, flags := type & linux.SOCK_TYPE_MASK, type & ~int(linux.SOCK_TYPE_MASK)
	if domain != linux.AF_INET {
		return fail(.EAFNOSUPPORT)
	}
	if flags & ~int(linux.SOCK_NONBLOCK | linux.SOCK_CLOEXEC) != 0 {
		return fail(.EINVAL)
	}
	proto: string
	switch {
	case kind == linux.SOCK_STREAM && (protocol == 0 || protocol == linux.IPPROTO_TCP):
		proto = "tcp"
	case kind == linux.SOCK_DGRAM && (protocol == 0 || protocol == linux.IPPROTO_UDP):
		proto = "udp"
	case:
		return fail(.EPROTONOSUPPORT)
	}
	buf: Path_Buf
	b := str.Buf {
		buf = buf[:len(buf) - 1],
	}
	str.write_string(&b, "/net/")
	str.write_string(&b, proto)
	str.write_string(&b, "/clone")
	ctl: ns.File
	st := ns.open(namespace(), str.to_string(&b), p9.ORDWR, &ctl)
	if st == .Err_Not_Found {
		return fail(.EAFNOSUPPORT) // no /net here
	}
	if st != .Ok {
		return sock_errno(st)
	}
	digits: [12]u8
	num, r := sock_number(ctl.c, ctl.fid, digits[:])
	if r == 0 && kind == linux.SOCK_DGRAM { // datagrams after their header, both ways
		if _, wst := p9.client_write(ctl.c, ctl.fid, 0, transmute([]u8)string("headers")); wst != .Ok {
			r = sock_errno(wst)
		}
	}
	fd := r == 0 ? sock_install(proto, num, u8(kind), flags) : r
	ns.close(&ctl) // the data file keeps the conversation
	return fd
}

// Announces the port (0: a free one), once. TCP's listen and UDP's bind.
@(private="file")
sock_announce :: proc "contextless" (o: ^Ofd, port: u16) -> int {
	msg: [24]u8
	b := str.Buf {
		buf = msg[:],
	}
	str.write_string(&b, "announce ")
	str.write_u64(&b, u64(port))
	st := sock_ctl(o, str.to_string(&b))
	if st == .Err_Bad_State {
		return fail(.EINVAL) // announced already
	}
	if st != .Ok {
		return sock_errno(st)
	}
	o.sock.bound = true
	return 0
}

sock_bind :: proc "contextless" (fd: int, sa: rawptr, length: u32) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	addr, port, e := sock_addr_in(sa, length)
	if e < 0 {
		return e
	}
	if o.sock.bound || o.sock.port != 0 {
		return fail(.EINVAL)
	}
	if addr != linux.INADDR_ANY && addr >> 24 != 127 { // only the interface's own, or loopback
		mine, _, le := sock_end(o, "local")
		if le < 0 || mine != addr {
			return fail(.EADDRNOTAVAIL)
		}
	}
	if o.sock.type == linux.SOCK_DGRAM {
		return sock_announce(o, port)
	}
	// TCP: the port is announced by listen, as Plan 9 does; netd has no way
	// to hold one for a connection made from it, so connect does not use it.
	o.sock.port = port
	return 0
}

sock_listen :: proc "contextless" (fd: int) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if o.sock.type != linux.SOCK_STREAM {
		return fail(.EOPNOTSUPP)
	}
	if o.sock.listening {
		return 0
	}
	r = sock_announce(o, o.sock.port)
	if r == 0 {
		o.sock.listening = true
	}
	return r
}

sock_accept :: proc "contextless" (fd: int, sa: rawptr, length: ^u32, flags: int) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if flags & ~int(linux.SOCK_NONBLOCK | linux.SOCK_CLOEXEC) != 0 {
		return fail(.EINVAL)
	}
	if o.sock.type != linux.SOCK_STREAM {
		return fail(.EOPNOTSUPP)
	}
	if !o.sock.listening {
		return fail(.EINVAL)
	}
	ra := sock_listener(o) // an open of N/listen, outstanding: it waits for a call
	if ra == nil {
		return fail(.ENOBUFS)
	}
	if w := ra_wait(ra, fd_key(o), false, .Nonblock not_in o.flags); w < 0 {
		return w
	}
	ra.ready = false // taken: the next accept, or poll, sends another
	c := &ra.k.c
	if ra.status != .Ok {
		_ = p9.client_clunk(c, ra.fid)
		return sock_errno(ra.status)
	}
	digits: [12]u8 // the fid is the new conversation's ctl now
	num, nr := sock_number(c, ra.fid, digits[:])
	nfd := nr == 0 ? sock_install("tcp", num, linux.SOCK_STREAM, flags) : nr
	_ = p9.client_clunk(c, ra.fid) // once its data file is open, which keeps the conversation
	if nfd >= 0 {
		fd_get(nfd).sock.connected = true
	}
	if nfd < 0 || sa == nil {
		return nfd
	}
	addr, port, _ := sock_end(fd_get(nfd), "remote")
	sock_give(sa, length, addr, port)
	return nfd
}

sock_connect :: proc "contextless" (fd: int, sa: rawptr, length: u32) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	addr, port, e := sock_addr_in(sa, length)
	if e < 0 {
		return e
	}
	if o.sock.listening {
		return fail(.EISCONN)
	}
	if addr == linux.INADDR_ANY {
		addr = linux.INADDR_LOOPBACK // as Linux takes it
	}
	if o.sock.type == linux.SOCK_STREAM && port == 0 {
		return fail(.ECONNREFUSED)
	}
	msg: [40]u8
	b := str.Buf {
		buf = msg[:],
	}
	str.write_string(&b, "connect ")
	sock_format(&b, addr, port)
	if o.sock.type == linux.SOCK_STREAM {
		return sock_connect_tcp(o, str.to_bytes(&b))
	}
	st := sock_ctl(o, str.to_string(&b)) // UDP's: netd never holds it
	if st == .Err_Invalid {
		return fail(.EISCONN)
	}
	if st != .Ok {
		return sock_errno(st)
	}
	o.sock.bound = true
	return 0
}

sock_name :: proc "contextless" (fd: int, sa: rawptr, length: ^u32, peer: bool) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if sa == nil || length == nil {
		return fail(.EFAULT)
	}
	addr, port, e := sock_end(o, peer ? "remote" : "local")
	if e < 0 {
		return e
	}
	if peer && addr == 0 {
		return fail(.ENOTCONN)
	}
	if !peer && port == 0 { // not announced: what bind asked for, from no address
		port = o.sock.port
		addr = 0
	}
	sock_give(sa, length, addr, port)
	return 0
}

// --- Connecting, without waiting ---

// Finishes a connect whose ctl write has its reply: 0, or why it failed.
@(private="file")
sock_connect_done :: proc "contextless" (o: ^Ofd) -> int {
	st := o.ra.status
	ra_free(o) // a read-ahead for the data comes when it is wanted
	o.sock.connecting = false
	if st == .Ok {
		o.sock.bound, o.sock.connected = true, true
		return 0
	}
	if st == .Err_Bad_State {
		return fail(.EISCONN) // connected elsewhere already
	}
	return sock_errno(st)
}

// Waits for a connect under way to finish (unless it must not wait): 0, or
// -EAGAIN, -EINTR, or why it failed (also kept for SO_ERROR).
@(private="file")
sock_connected :: proc "contextless" (o: ^Ofd, block: bool) -> int {
	if !o.sock.connecting {
		return 0
	}
	if w := ra_wait(o.ra, fd_key(o), false, block); w < 0 {
		return w
	}
	r := sock_connect_done(o)
	o.sock.error = linux.Errno(-r)
	return r
}

// TCP's connect: the ctl write kept outstanding on the socket's connection,
// so a signal or O_NONBLOCK need not wait for it (EINTR, EINPROGRESS).
@(private="file")
sock_connect_tcp :: proc "contextless" (o: ^Ofd, msg: []u8) -> int {
	block := .Nonblock not_in o.flags
	if o.sock.connected {
		return fail(.EISCONN) // done already, the connecting too
	}
	if o.sock.connecting { // made again: after EINTR, or by a program asking how it went
		if !block && !ra_poll(o.ra, false) {
			return fail(.EALREADY)
		}
		r := sock_connected(o, block)
		if r != fail(.EINTR) {
			o.sock.error = {} // told here, not in SO_ERROR too
		}
		return r == 0 && !block ? fail(.EISCONN) : r
	}
	if o.ra != nil {
		ra_free(o) // a read kept outstanding before connecting
	}
	ra := sock_side(o)
	if ra == nil {
		return fail(.ENOBUFS)
	}
	if sock_side_file(o, ra, "ctl", p9.ORDWR) != .Ok {
		ra_drop(ra)
		return fail(.ENOBUFS)
	}
	ra.op = .Write
	ra.len = u32(copy(ra.data[:], msg))
	ra.pos = 0
	o.ra = ra
	ra_send_write(ra)
	o.sock.connecting = true
	o.sock.error = {}
	if !block {
		return fail(.EINPROGRESS)
	}
	r := sock_connected(o, true)
	if r != fail(.EINTR) {
		o.sock.error = {}
	}
	return r
}

// --- Data ---

// A UDP datagram's buffer: netd's header, then the payload. One Twrite (or
// Rread) carries it, so a datagram is at most RA_MAX bytes with its header.
@(private="file")
dgram: [RA_MAX]u8

// A write's failure: a connection that has closed raises SIGPIPE, unless
// MSG_NOSIGNAL, and is EPIPE.
@(private="file")
sock_write_errno :: proc "contextless" (st: vx.Status, flags: linux.Msg_Flags) -> int {
	if st != .Err_Peer_Closed {
		return sock_errno(st)
	}
	if .Nosignal not_in flags {
		sig_raise_self(linux.SIGPIPE)
	}
	return fail(.EPIPE)
}

// TCP: what was written behind goes first; then the data, waiting until
// netd has taken it all, or (without waiting) behind, as much as one Twrite
// carries.
@(private="file")
sock_send_stream :: proc "contextless" (o: ^Ofd, buf: []u8, flags: linux.Msg_Flags) -> int {
	block := .Nonblock not_in o.flags && .Dontwait not_in flags
	if o.sock.shut {
		return sock_write_errno(.Err_Peer_Closed, flags)
	}
	if r := sock_connected(o, block); r < 0 {
		return r == fail(.EINTR) || r == fail(.EAGAIN) ? r : sock_write_errno(.Err_Peer_Closed, flags)
	}
	if o.wb != nil {
		if r := ra_wait(o.wb, wb_key(o), false, block); r < 0 {
			return r
		}
		if o.wb.status != .Ok {
			return sock_write_errno(o.wb.status, flags) // and stays so
		}
	}
	if block {
		done := 0
		for done < len(buf) {
			w, st := p9.client_write(o.f.c, o.f.fid, 0, buf[done:][:min(len(buf) - done, IO_MAX)])
			if (st != .Ok || w == 0) && done > 0 {
				return done
			}
			if st != .Ok {
				return sock_write_errno(st, flags)
			}
			if w == 0 {
				return fail(.EIO)
			}
			done += w
		}
		return len(buf)
	}
	if o.wb == nil {
		wb := sock_side(o)
		if wb != nil && sock_side_file(o, wb, "data", p9.OWRITE) != .Ok {
			ra_drop(wb)
			wb = nil
		}
		if wb == nil {
			return fail(.ENOBUFS)
		}
		wb.op = .Write
		o.wb = wb
	}
	k := copy(o.wb.data[:], buf)
	o.wb.len = u32(k)
	o.wb.pos = 0
	ra_send_write(o.wb)
	return k
}

sock_send :: proc "contextless" (o: ^Ofd, buf: []u8, flags: linux.Msg_Flags, sa: rawptr, salen: u32) -> int {
	if o.sock.type == linux.SOCK_STREAM {
		return sock_send_stream(o, buf, flags) // a destination is ignored, as Linux does
	}
	addr: u32
	port: u16
	if sa != nil {
		e: int
		addr, port, e = sock_addr_in(sa, salen)
		if e < 0 {
			return e
		}
		if addr == linux.INADDR_ANY {
			addr = linux.INADDR_LOOPBACK
		}
	}
	if len(buf) > RA_MAX - HEADER {
		return fail(.EMSGSIZE)
	}
	if !o.sock.bound { // from a free port, as an unbound socket sends on Linux
		_, p, e := sock_end(o, "local")
		if e < 0 || p == 0 {
			if r := sock_announce(o, 0); r < 0 {
				return r
			}
		}
		o.sock.bound = true
	}
	h := dgram[:HEADER]
	h = {}
	h[10], h[11] = 0xff, 0xff // IPv4, mapped into IPv6
	h[12], h[13], h[14], h[15] = u8(addr >> 24), u8(addr >> 16), u8(addr >> 8), u8(addr)
	h[48], h[49] = u8(port >> 8), u8(port)
	copy(dgram[HEADER:], buf)
	_, st := p9.client_write(o.f.c, o.f.fid, 0, dgram[:HEADER + len(buf)]) // netd never holds a datagram
	if st == .Err_Bad_State {
		return sa != nil ? fail(.ENETUNREACH) : fail(.EDESTADDRREQ)
	}
	return st != .Ok ? sock_errno(st) : len(buf)
}

// A datagram's sender, from netd's header.
@(private="file")
sock_give_sender :: proc "contextless" (h: []u8, sa: rawptr, salen: ^u32) {
	addr := u32(h[12]) << 24 | u32(h[13]) << 16 | u32(h[14]) << 8 | u32(h[15])
	sock_give(sa, salen, addr, u16(h[48]) << 8 | u16(h[49]))
}

RECV_FLAGS :: linux.Msg_Flags{.Nosignal, .Waitall, .Trunc, .Peek, .Dontwait}

sock_recv :: proc "contextless" (o: ^Ofd, buf: []u8, flags: linux.Msg_Flags, sa: rawptr, salen: ^u32) -> int {
	if flags - RECV_FLAGS != {} {
		return fail(.EOPNOTSUPP)
	}
	block := .Nonblock not_in o.flags && .Dontwait not_in flags
	if o.sock.listening {
		return fail(.ENOTCONN)
	}
	if r := sock_connected(o, block); r == fail(.EINTR) || r == fail(.EAGAIN) {
		return r
	}
	ra := sock_reader(o)
	if ra == nil {
		return fail(.ENOBUFS)
	}
	b := buf[:min(len(buf), IO_MAX)]
	deadline := vx.INFINITE
	if o.sock.rcvtimeo != 0 {
		deadline = rt.clock_read() + o.sock.rcvtimeo
	}
	if o.sock.type == linux.SOCK_DGRAM {
		if w := ra_wait_until(ra, fd_key(o), false, block, deadline); w < 0 {
			return w
		}
		st := ra.status
		if st != .Ok || ra.len < HEADER {
			ra.ready = false
			return st != .Ok ? sock_errno(st) : fail(.EIO)
		}
		payload := ra.data[HEADER:ra.len]
		take := copy(b, payload)
		sock_give_sender(ra.data[:], sa, salen)
		if .Peek not_in flags {
			ra.ready = false // the next read sends another
			ra.pos = ra.len
		}
		return .Trunc in flags ? len(payload) : take // a datagram's rest is lost, as on Linux
	}
	got := 0
	for { // once; with MSG_WAITALL, until all of it is here or the stream ends
		if w := ra_wait_until(ra, fd_key(o), false, block, deadline); w < 0 {
			return got > 0 ? got : w
		}
		if ra.status != .Ok {
			st := ra.status
			ra.ready = false
			return got > 0 ? got : sock_errno(st)
		}
		avail := int(ra.len - ra.pos)
		k := copy(b[got:], ra.data[ra.pos:ra.len])
		got += k
		if .Peek not_in flags {
			ra.pos += u32(k)
			if ra.pos == ra.len {
				ra.ready = false // all given: the next read sends another
			}
		}
		if avail == 0 || got == len(b) || .Waitall not_in flags || .Peek in flags {
			break // avail 0: the end
		}
	}
	if sa != nil && salen != nil {
		addr, port, _ := sock_end(o, "remote")
		sock_give(sa, salen, addr, port)
	}
	return got
}

sock_sendto :: proc "contextless" (fd: int, buf: []u8, flags: linux.Msg_Flags, sa: rawptr, salen: u32) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if flags - {.Nosignal, .Dontroute, .Dontwait} != {} {
		return fail(.EOPNOTSUPP)
	}
	return sock_send(o, buf, flags, sa, salen)
}

sock_recvfrom :: proc "contextless" (fd: int, buf: []u8, flags: linux.Msg_Flags, sa: rawptr, salen: ^u32) -> int {
	o, r := sock_get(fd)
	return r < 0 ? r : sock_recv(o, buf, flags, sa, salen)
}

// --- Readiness (poll.odin) ---

// Whether the read-ahead has its answer; if not, arming fd_port (under key)
// to hear when it does.
@(private="file")
sock_answered :: proc "contextless" (ra: ^Readahead, key: u64, arm: bool) -> bool {
	for _ in 0 ..< 2 {
		if ra_poll(ra, false) {
			return true
		}
		if !arm || ra.armed {
			return false
		}
		ra.armed = rt.p9_arm(&ra.k, fd_port, key)
		if ra.armed {
			return false
		}
	} // not armed: a reply may have come meanwhile
	return ra_poll(ra, false)
}

sock_ready :: proc "contextless" (o: ^Ofd, events: linux.Poll_Events, arm: bool) -> linux.Poll_Events {
	if o.sock.listening { // a call to take
		if events & POLL_IN == {} {
			return {}
		}
		ra := sock_listener(o)
		return ra == nil || sock_answered(ra, fd_key(o), arm) ? events & POLL_IN : {} // no listener: accept just blocks
	}
	if o.sock.connecting {
		if !sock_answered(o.ra, fd_key(o), arm) {
			return {}
		}
		o.sock.error = linux.Errno(-sock_connect_done(o))
	}
	r: linux.Poll_Events
	if o.sock.error != {} {
		r += {.Err, .Hup}
	}
	if events & POLL_OUT != {} && (o.wb == nil || sock_answered(o.wb, wb_key(o), arm)) {
		r += events & POLL_OUT
	}
	if events & POLL_IN != {} {
		ra := sock_reader(o)
		if ra == nil || sock_answered(ra, fd_key(o), arm) {
			r += events & POLL_IN // no read-ahead: a read blocks
		}
	}
	return r
}

// sendmsg and recvmsg: the iovecs gathered into one datagram (or written in
// turn, on a stream), with no ancillary data.
@(private="file")
msg_gather: [RA_MAX]u8

sock_sendmsg :: proc "contextless" (fd: int, m: ^linux.Msghdr, flags: linux.Msg_Flags) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if m.controllen != 0 {
		return fail(.EOPNOTSUPP)
	}
	v, total, e := iovecs(m.iov, int(m.iovlen))
	if e < 0 {
		return e
	}
	if o.sock.type == linux.SOCK_STREAM {
		done := 0
		for x in v {
			w := sock_sendto(fd, iov_bytes(x), flags, nil, 0)
			if w < 0 {
				return done > 0 ? done : w
			}
			done += w
		}
		return done
	}
	if total > len(msg_gather) {
		return fail(.EMSGSIZE)
	}
	at := 0
	for x in v {
		at += copy(msg_gather[at:], iov_bytes(x))
	}
	return sock_sendto(fd, msg_gather[:total], flags, m.name, m.namelen)
}

@(private="file")
msg_scatter: [RA_MAX]u8

sock_recvmsg :: proc "contextless" (fd: int, m: ^linux.Msghdr, flags: linux.Msg_Flags) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	total: uint
	for x in m.iov[:max(m.iovlen, 0)] {
		total += x.len
	}
	namelen := m.namelen
	r = sock_recv(o, msg_scatter[:min(total, len(msg_scatter))], flags - {.Trunc}, m.name, m.name != nil ? &namelen : nil)
	if r < 0 {
		return r
	}
	m.namelen = m.name != nil ? namelen : 0
	m.controllen = 0
	m.flags = 0
	at := 0
	for x in m.iov[:max(m.iovlen, 0)] {
		if at >= r {
			break
		}
		at += copy(iov_bytes(x), msg_scatter[at:r])
	}
	return r
}

sock_shutdown :: proc "contextless" (fd: int, how: int) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if how != linux.SHUT_RD && how != linux.SHUT_WR && how != linux.SHUT_RDWR {
		return fail(.EINVAL)
	}
	if how == linux.SHUT_RD || o.sock.type != linux.SOCK_STREAM {
		return 0
	}
	if o.wb != nil {
		_ = ra_wait(o.wb, wb_key(o), false, true) // what was written behind goes before the FIN
	}
	st := sock_ctl(o, "hangup") // a FIN once what was written has gone; reading goes on
	if st == .Ok {
		o.sock.shut = true
		return 0
	}
	return sock_errno(st)
}

// The options programs set that netd has no use for are taken and ignored;
// SO_RCVTIMEO bounds a receive's wait; the rest are ENOPROTOOPT.
// (SO_SNDTIMEO is taken: a send waits only for room in netd's queue.)
sock_setsockopt :: proc "contextless" (fd, level, name: int, val: rawptr, length: u32) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if val == nil && length != 0 {
		return fail(.EFAULT)
	}
	if level == linux.SOL_SOCKET && name == linux.SO_RCVTIMEO {
		if length < size_of(linux.Timeval) {
			return fail(.EINVAL)
		}
		tv := intrinsics.unaligned_load((^linux.Timeval)(val))
		if tv.sec < 0 || tv.usec < 0 || tv.usec >= 1_000_000 {
			return fail(.EDOM)
		}
		secs, o1 := intrinsics.overflow_mul(tv.sec, i64(NS_PER_SEC))
		total, o2 := intrinsics.overflow_add(secs, tv.usec * 1000)
		o.sock.rcvtimeo = o1 || o2 ? 0 : total // longer than can be waited: for ever
		return 0
	}
	if level == linux.SOL_SOCKET {
		switch name {
		case linux.SO_REUSEADDR, linux.SO_REUSEPORT, linux.SO_KEEPALIVE, linux.SO_RCVBUF, linux.SO_SNDBUF, linux.SO_LINGER, linux.SO_BROADCAST, linux.SO_SNDTIMEO:
			return 0
		}
	}
	if level == linux.IPPROTO_TCP {
		switch name {
		case linux.TCP_NODELAY, linux.TCP_KEEPIDLE, linux.TCP_KEEPINTVL, linux.TCP_KEEPCNT:
			return 0
		}
	}
	return fail(.ENOPROTOOPT)
}

sock_getsockopt :: proc "contextless" (fd, level, name: int, val: rawptr, length: ^u32) -> int {
	o, r := sock_get(fd)
	if r < 0 {
		return r
	}
	if val == nil || length == nil || length^ < size_of(i32) {
		return fail(.EINVAL)
	}
	if level != linux.SOL_SOCKET {
		return fail(.ENOPROTOOPT)
	}
	v: i32
	switch name {
	case linux.SO_TYPE:
		v = i32(o.sock.type)
	case linux.SO_DOMAIN:
		v = linux.AF_INET
	case linux.SO_PROTOCOL:
		v = o.sock.type == linux.SOCK_STREAM ? linux.IPPROTO_TCP : linux.IPPROTO_UDP
	case linux.SO_ACCEPTCONN:
		v = o.sock.listening ? 1 : 0
	case linux.SO_ERROR: // a connect that did not wait: how it went, once
		if o.sock.connecting && ra_poll(o.ra, false) {
			o.sock.error = linux.Errno(-sock_connect_done(o))
		}
		v = i32(o.sock.error)
		o.sock.error = {}
	case linux.SO_RCVBUF, linux.SO_SNDBUF:
		v = 65536
	case:
		return fail(.ENOPROTOOPT)
	}
	intrinsics.unaligned_store((^i32)(val), v)
	length^ = size_of(i32)
	return 0
}
