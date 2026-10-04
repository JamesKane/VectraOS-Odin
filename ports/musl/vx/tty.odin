package backend

import "linux"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:str"

// Terminals.
//
// A terminal is a file its server marks a device: ptyd's ptmx (opened, the
// master) and pts/N (the slave). Its settings are in pts/N.ctl, beside the
// slave, read and written as one ndb record (servers/ptyd); the ioctls are
// Linux's, the POSIX personality's. The console is a terminal of 80 by 24
// that has no settings yet.

@(private="file")
Tty_State :: struct {
	iflag, oflag, cflag, lflag: u32,
	cc:                         [linux.NCCS]u8,
	rows, cols:                 u16,
	pgrp, avail:                i64,
}

// pts/N.ctl's path: beside the slave's path, or under the master's ptmx.
@(private="file")
tty_ctl_path :: proc "contextless" (o: ^Ofd, out: ^Path_Buf) -> string {
	path := string(o.path[:])
	dir := len(path)
	for dir > 1 && path[dir - 1] != '/' {
		dir -= 1
	}
	b := str.Buf {
		buf = out[:len(out) - 1], // room for nothing past VX_NS_MAX_PATH - 1, as upstream's
	}
	str.write_string(&b, path[:dir])
	if o.master {
		str.write_string(&b, "pts/")
	}
	str.write_u64(&b, u64(o.pty))
	str.write_string(&b, ".ctl")
	return b.failed ? "" : str.to_string(&b)
}

// Writes set to the terminal's ctl file, or (set "") reads its settings.
@(private="file")
tty_ctl :: proc "contextless" (o: ^Ofd, set: string, st: ^Tty_State) -> int {
	buf: Path_Buf
	path := tty_ctl_path(o, &buf)
	f: ns.File
	mode := p9.OREAD
	if len(set) > 0 {
		mode = p9.OWRITE
	}
	if len(path) == 0 || ns.open(namespace(), path, mode, &f) != .Ok {
		return fail(.ENOTTY)
	}
	defer ns.close(&f)
	if len(set) > 0 {
		n, wst := ns.write(&f, transmute([]u8)set)
		return wst == .Ok && n == len(set) ? 0 : fail(.EIO)
	}
	@(static) text, scratch: [512]u8
	n, rst := ns.read(&f, text[:])
	st^ = {}
	r := ndb.Reader {
		src     = string(text[:rst == .Ok ? n : 0]),
		scratch = scratch[:],
	}
	rec: ndb.Record
	if rst != .Ok || n <= 0 || ndb.next(&r, &rec) != .Record {
		return fail(.EIO)
	}
	if v, ok := ndb.get_u64(&rec, "iflag"); ok {
		st.iflag = u32(v)
	}
	if v, ok := ndb.get_u64(&rec, "oflag"); ok {
		st.oflag = u32(v)
	}
	if v, ok := ndb.get_u64(&rec, "cflag"); ok {
		st.cflag = u32(v)
	}
	if v, ok := ndb.get_u64(&rec, "lflag"); ok {
		st.lflag = u32(v)
	}
	if v, ok := ndb.get_u64(&rec, "rows"); ok {
		st.rows = u16(v)
	}
	if v, ok := ndb.get_u64(&rec, "cols"); ok {
		st.cols = u16(v)
	}
	if v, ok := ndb.get_u64(&rec, "pgrp"); ok {
		st.pgrp = i64(v)
	}
	if v, ok := ndb.get_u64(&rec, "avail"); ok {
		st.avail = i64(v)
	}
	if cc, ok := ndb.get(&rec, "cc"); ok && len(cc) == len(st.cc) {
		copy(st.cc[:], cc)
	}
	return 0
}

// Sets fields, as a record ptyd reads: key=value pairs, the cc as bytes.
@(private="file")
tty_set :: proc "contextless" (o: ^Ofd, t: ^linux.Termios, w: ^linux.Winsize, pgrp: i64, flush: bool) -> int {
	@(static) rec: [512]u8
	wr := ndb.Writer {
		buf = rec[:len(rec) - 1],
	}
	if t != nil {
		ndb.put_u64(&wr, "iflag", u64(t.iflag))
		ndb.put_u64(&wr, "oflag", u64(t.oflag))
		ndb.put_u64(&wr, "cflag", u64(t.cflag))
		ndb.put_u64(&wr, "lflag", u64(t.lflag))
		ndb.put(&wr, "cc", string(t.cc[:]))
	}
	if w != nil {
		ndb.put_u64(&wr, "rows", u64(w.row))
		ndb.put_u64(&wr, "cols", u64(w.col))
	}
	if pgrp >= 0 {
		ndb.put_u64(&wr, "pgrp", u64(pgrp))
	}
	if flush {
		ndb.flag(&wr, "flush")
	}
	if !ndb.end(&wr) {
		return fail(.EINVAL)
	}
	return tty_ctl(o, ndb.written(&wr), nil)
}

fd_ioctl :: proc "contextless" (fd: int, request: uint, arg: rawptr) -> int {
	o := fd_get(fd)
	if o == nil {
		return fail(.EBADF)
	}
	if o.kind == .Console && request == linux.TIOCGWINSZ {
		(^linux.Winsize)(arg)^ = {
			row = 24,
			col = 80,
		}
		return 0
	}
	if o.kind != .File || !o.tty {
		return fail(.ENOTTY)
	}
	switch request {
	case linux.TCGETS, linux.TIOCGWINSZ, linux.TIOCGPGRP, linux.FIONREAD:
		st: Tty_State
		if r := tty_ctl(o, "", &st); r < 0 {
			return r
		}
		switch request {
		case linux.TIOCGWINSZ:
			(^linux.Winsize)(arg)^ = {
				row = st.rows,
				col = st.cols,
			}
		case linux.TIOCGPGRP:
			(^i32)(arg)^ = i32(st.pgrp)
		case linux.FIONREAD: // ptyd's, and what the read-ahead holds already (poll.odin)
			held := o.ra != nil && o.ra.op == .Read ? i64(o.ra.len - o.ra.pos) : 0
			(^i32)(arg)^ = i32(st.avail + held)
		case linux.TCGETS:
			t := (^linux.Termios)(arg)
			t^ = {
				iflag  = st.iflag,
				oflag  = st.oflag,
				cflag  = st.cflag,
				lflag  = st.lflag,
				cc     = st.cc,
				ispeed = linux.B38400,
				ospeed = linux.B38400,
			}
		}
		return 0
	case linux.TCSETS, linux.TCSETSW, linux.TCSETSF: // output is never held back: nothing to drain
		return tty_set(o, (^linux.Termios)(arg), nil, -1, request == linux.TCSETSF)
	case linux.TIOCSWINSZ:
		return tty_set(o, nil, (^linux.Winsize)(arg), -1, false)
	case linux.TIOCSPGRP:
		return tty_set(o, nil, nil, i64((^i32)(arg)^), false)
	case linux.TCFLSH:
		return uintptr(arg) == linux.TCOFLUSH ? 0 : tty_set(o, nil, nil, -1, true)
	case linux.TIOCGPTN:
		(^u32)(arg)^ = o.pty
		return 0
	case linux.TIOCGSID:
		(^i32)(arg)^ = i32(posix_getsid(0))
		return 0
	case linux.TIOCSPTLCK, // grantpt and unlockpt: a terminal is ready from the start
	     linux.TIOCSCTTY, // controlling terminals are not kept apart yet
	     linux.TIOCNOTTY,
	     linux.TCSBRK,
	     linux.TCXONC:
		return 0
	}
	return fail(.ENOTTY)
}
