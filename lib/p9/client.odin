package p9

// The client (upstream 02 §3), over any transport: a serial one that
// carries one message and returns its reply (a TCP stream, a host test's
// loopback), or a pipelined one with several calls in flight (the ring,
// lib/rt's p9conn.odin). Every reply is checked: its tag, that it answers
// the request's type, and an Rerror's text back into a Status.
//
// Each call has its own buffers for the length of the call (an Xfer): with
// a pipelined transport, so several threads can use one connection; with a
// serial one, the client's own pair, under the transport's lock if it has
// one. A call's reply is decoded where it landed, and what the caller keeps
// of it is copied out before the buffers go back (upstream's M6 step 6d4a).

import "base:intrinsics"
import "abi:vx"

// Sends req and fills resp with the reply. Returns the reply's length, or 0
// if the connection is gone.
Rpc :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int

// One call's buffers and handles, the transport's for the length of the call.
Xfer :: struct {
	// The request is encoded into req, and the reply lands in resp (perhaps
	// the same buffer); each holds at least the msize.
	req, resp:   []u8,
	tag:         u16, // the transport's choice (NOTAG for Tversion)
	// The handle the reply carried (Rmap's VMO): the call that wants it
	// takes it, and the transport closes one not taken.
	handle:      vx.Handle,
	// A handle for the request to carry (dref's VMO), which the transport
	// moves to the server, or closes if it cannot.
	send_handle: vx.Handle,
}

// A transport with several calls in flight: a call's buffers from begin
// (waiting for some if all are in use; nil once the connection is gone),
// the call (the reply's length; or .Err_Peer_Closed, or .Err_Interrupted or
// .Err_Timed_Out for a call the transport flushed), and the buffers back
// with end. msize is the most a call's buffers hold.
Pipe :: struct {
	msize: u32,
	begin: proc "contextless" (ctx: rawptr, version: bool) -> ^Xfer,
	call:  proc "contextless" (ctx: rawptr, x: ^Xfer, n: int) -> (reply_len: int, st: vx.Status),
	end:   proc "contextless" (ctx: rawptr, x: ^Xfer),
}

// Who a client attaches as when it names no one: the program's user (its
// spawn message's user=, which vx:ns sets here), or "none".
client_user: string

Client :: struct {
	// A serial transport: rpc, with tbuf and rbuf (each at least the msize
	// asked for), and a lock if threads share it (take, or let go; optional).
	rpc:        Rpc,
	ctx:        rawptr,
	tbuf, rbuf: []u8,
	lock:       proc "contextless" (ctx: rawptr, take: bool),
	// Or a pipelined one, with ctx, instead.
	pipe:       ^Pipe,
	msize:      u32, // negotiated
	dialect:    Dialect,
	extensions: Extensions, // negotiated
	next_tag:   u16, // a serial transport's
	next_fid:   Fid, // taken atomically: threads share a connection
	uname:      string, // who attaches; empty: client_user, or "none"
	serial:     Xfer, // a serial transport's one call
	// 9P2000.L (upstream's 6d4c2): the directories open on it, whose reads
	// are Treaddir made into stat entries, each with the cookie and offset to
	// go on from.
	dirs_lock:  u32, // a spin lock: threads share a connection
	dirs:       [16]Dir_Read,
}

@(private)
Dir_Read :: struct {
	fid:        Fid, // 0: free
	cookie, at: u64,
}

// A reply, decoded where it landed; its strings and data are the call's
// buffers', until finish.
@(private="file")
Rcall :: struct {
	r: Msg,
	x: ^Xfer,
}

@(private="file")
new_fid :: proc "contextless" (c: ^Client) -> Fid {
	return intrinsics.atomic_add_explicit(&c.next_fid, 1, .Relaxed)
}

@(private="file")
begin :: proc "contextless" (c: ^Client, version: bool) -> ^Xfer {
	if c.pipe != nil {
		return c.pipe.begin(c.ctx, version)
	}
	if c.lock != nil {
		c.lock(c.ctx, true)
	}
	c.serial = {
		req  = c.tbuf,
		resp = c.rbuf,
		tag  = NOTAG,
	}
	if !version {
		c.serial.tag = c.next_tag % NOTAG // NOTAG is Tversion's alone
		c.next_tag += 1
	}
	return &c.serial
}

// The call's buffers back.
@(private="file")
finish :: proc "contextless" (c: ^Client, rc: ^Rcall) {
	if rc.x == nil {
		return
	}
	if c.pipe != nil {
		c.pipe.end(c.ctx, rc.x)
	} else if c.lock != nil {
		c.lock(c.ctx, false)
	}
	rc.x = nil
}

// Sends t, with `send` for the request to carry (or HANDLE_NONE), and waits
// for its reply, in rc.r until finish, which the caller calls whatever this
// returns.
@(private="file", require_results)
exchange :: proc "contextless" (c: ^Client, t: ^Msg, rc: ^Rcall, send := vx.HANDLE_NONE) -> vx.Status {
	x := begin(c, t.type == .Tversion)
	rc.x = x
	if x == nil {
		return .Err_Peer_Closed // a pipelined connection, gone (and send with it, the caller's)
	}
	x.send_handle = send
	t.tag = x.tag
	n := encode(t, x.req)
	if n == 0 {
		return .Err_Too_Small
	}
	rn: int
	if c.pipe != nil {
		rn = c.pipe.call(c.ctx, x, n) or_return
	} else {
		rn = c.rpc(c.ctx, x.req[:n], x.resp)
	}
	if rn <= 0 || rn > len(x.resp) {
		return .Err_Peer_Closed
	}
	if decode(x.resp[:rn], &rc.r) != .Ok || rc.r.tag != t.tag {
		return .Err_Invalid
	}
	if rc.r.type == .Rerror {
		return error_status(rc.r.ename)
	}
	if rc.r.type == .Rlerror {
		return errno_status(rc.r.ecode) // 9P2000.L's: an errno
	}
	return u8(rc.r.type) == u8(t.type) + 1 ? .Ok : .Err_Invalid
}

// --- 9P2000.L's directory reads (upstream's 6d4c2) ---

@(private="file")
dotl :: proc "contextless" (c: ^Client) -> bool {
	return c.dialect == .P9_2000L
}

@(private="file")
dirs_lock :: proc "contextless" (c: ^Client) {
	for intrinsics.atomic_exchange_explicit(&c.dirs_lock, 1, .Acquire) != 0 {
		intrinsics.cpu_relax()
	}
}

@(private="file")
dirs_unlock :: proc "contextless" (c: ^Client) {
	intrinsics.atomic_store_explicit(&c.dirs_lock, 0, .Release)
}

// fid's slot in the table, or -1; with add, a free one taken for it.
@(private="file")
dir_slot :: proc "contextless" (c: ^Client, fid: Fid, add: bool) -> int {
	free := -1
	for &d, i in c.dirs {
		if d.fid == fid {
			return i
		}
		if d.fid == 0 && free < 0 {
			free = i
		}
	}
	if add && free >= 0 {
		c.dirs[free] = {
			fid = fid,
		}
	}
	return add ? free : -1
}

@(private="file")
dir_note :: proc "contextless" (c: ^Client, fid: Fid, dir: bool) {
	dirs_lock(c)
	i := dir_slot(c, fid, dir)
	if !dir && i >= 0 {
		c.dirs[i].fid = 0
	}
	dirs_unlock(c)
}

// A call whose reply says nothing the caller keeps.
@(private="file", require_results)
call :: proc "contextless" (c: ^Client, t: ^Msg) -> vx.Status {
	rc: Rcall
	defer finish(c, &rc)
	return exchange(c, t, &rc)
}

// The largest message a call's buffers hold.
@(private="file")
bufsize :: proc "contextless" (c: ^Client) -> u32 {
	if c.pipe != nil {
		return c.pipe.msize
	}
	return u32(min(len(c.tbuf), len(c.rbuf), int(max(u32))))
}

// Negotiates a session: 9Px with the given extensions, and an msize no larger
// than the buffers. A 9P2000 server answers 9P2000, and then extensions are
// empty. One that answers "unknown" is asked for 9P2000.L (diod, QEMU's
// virtfs: Linux's dialect), then for plain 9P2000 (upstream 02 §3.1).
@(require_results)
client_version :: proc "contextless" (c: ^Client, msize: u32, extensions: Extensions) -> vx.Status {
	m := min(msize, bufsize(c))
	e := version_as(c, m, .P9_2000X, extensions)
	if e == .Err_Unsupported && c.dialect == .Unknown {
		e = version_as(c, m, .P9_2000L, {})
	}
	if e == .Err_Unsupported && c.dialect == .Unknown {
		e = version_as(c, m, .P9_2000, {})
	}
	return e
}

// One Tversion of dialect d: what the server answers, in c.
@(private="file", require_results)
version_as :: proc "contextless" (c: ^Client, msize: u32, d: Dialect, extensions: Extensions) -> vx.Status {
	version: [96]u8
	t := Msg{type = .Tversion, tag = NOTAG, msize = msize}
	t.version = string(version[:version_format(d, extensions, version[:])])
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	c.dialect, c.extensions = version_parse(rc.r.version)
	c.extensions &= extensions
	if c.dialect == .Unknown || rc.r.msize < MIN_MSIZE || rc.r.msize > t.msize {
		return .Err_Unsupported
	}
	c.msize = rc.r.msize
	c.next_fid = 1
	return .Ok
}

// Attaches to aname: the new fid, and the root's qid.
@(require_results)
client_attach_qid :: proc "contextless" (c: ^Client, aname: string) -> (fid: Fid, qid: Qid, e: vx.Status) {
	uname := len(client_user) > 0 ? client_user : "none"
	if len(c.uname) > 0 {
		uname = c.uname
	}
	t := Msg{type = .Tattach, fid = new_fid(c), afid = NOFID, uname = uname, aname = aname}
	if dotl(c) {
		t.has_n_uname, t.n_uname = true, NONUNAME // by name, as there are no numbers to give
	}
	rc: Rcall
	defer finish(c, &rc)
	e = exchange(c, &t, &rc)
	return t.fid, rc.r.qid, e
}

@(require_results)
client_attach :: proc "contextless" (c: ^Client, aname: string) -> (fid: Fid, e: vx.Status) {
	fid, _, e = client_attach_qid(c, aname)
	return
}

@(require_results)
client_clunk :: proc "contextless" (c: ^Client, fid: Fid) -> vx.Status {
	t := Msg{type = .Tclunk, fid = fid}
	if dotl(c) {
		dir_note(c, fid, false)
	}
	return call(c, &t)
}

// Walks a '/'-separated path from fid to a new fid, in walks of at most 16
// names. An empty path clones the fid.
@(require_results)
client_walk :: proc "contextless" (c: ^Client, fid: Fid, path: string) -> (newfid: Fid, e: vx.Status) {
	from, to := fid, new_fid(c)
	// Not str.split_iterator: that would eat the slash after a 16th name,
	// and a path that ends there would lose its last (empty) walk, which
	// the server sees.
	i := 0
	for {
		t := Msg{type = .Twalk, fid = from, newfid = to}
		for i < len(path) && t.nwname < MAXWELEM {
			for i < len(path) && path[i] == '/' {
				i += 1
			}
			start := i
			for i < len(path) && path[i] != '/' {
				i += 1
			}
			if i > start {
				t.wname[t.nwname] = path[start:i]
				t.nwname += 1
			}
		}
		rc: Rcall
		e = exchange(c, &t, &rc)
		if e == .Ok && rc.r.nwqid != t.nwname {
			e = .Err_Not_Found // stopped partway
		}
		finish(c, &rc)
		if e != .Ok {
			if from != fid {
				_ = client_clunk(c, from)
			}
			return 0, e
		}
		from = to // later walks continue from the new fid, in place
		if i >= len(path) {
			break
		}
	}
	return to, .Ok
}

// Linux's open flags from a 9P mode (9P2000.L's Tlopen and Tlcreate).
@(private="file")
flags_of_mode :: proc "contextless" (mode: Open_Mode) -> (flags: u32) {
	#partial switch mode.access { // O_RDONLY, for Read and Exec
	case .Write:
		flags = 1
	case .Rdwr:
		flags = 2
	}
	if mode.trunc {
		flags |= L_O_TRUNC
	}
	return
}

// Tlopen: Topen in 9P2000.L's words; a directory open is noted for its reads.
@(private="file", require_results)
lopen :: proc "contextless" (c: ^Client, fid: Fid, mode: Open_Mode) -> vx.Status {
	if mode.rclose {
		return .Err_Unsupported // .L has no remove-on-close
	}
	t := Msg{type = .Tlopen, fid = fid, lflags = flags_of_mode(mode)}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	dir_note(c, fid, .Dir in rc.r.qid.type)
	return .Ok
}

@(require_results)
client_open :: proc "contextless" (c: ^Client, fid: Fid, mode: Open_Mode) -> vx.Status {
	if dotl(c) {
		return lopen(c, fid, mode)
	}
	t := Msg{type = .Topen, fid = fid, mode = mode}
	return call(c, &t)
}

// Creates name in the directory fid, which then refers to the new file,
// open. Under 9P2000.L a file is Tlcreate's, and a directory Tmkdir's, then
// walked to and opened.
@(require_results)
client_create :: proc "contextless" (c: ^Client, fid: Fid, name: string, perm: u32, mode: Open_Mode) -> vx.Status {
	if dotl(c) && perm &~ (DMDIR | 0o777) != 0 {
		return .Err_Unsupported // DMAPPEND and the rest
	}
	if dotl(c) && perm & DMDIR != 0 {
		t := Msg{type = .Tmkdir, fid = fid, name = name, lmode = perm & 0o777}
		call(c, &t) or_return
		w := Msg{type = .Twalk, fid = fid, newfid = fid, nwname = 1}
		w.wname[0] = name
		call(c, &w) or_return
		return lopen(c, fid, mode)
	}
	if dotl(c) {
		if mode.rclose {
			return .Err_Unsupported
		}
		t := Msg{type = .Tlcreate, fid = fid, name = name, lflags = flags_of_mode(mode), lmode = perm & 0o777}
		return call(c, &t)
	}
	t := Msg{type = .Tcreate, fid = fid, name = name, perm = perm, mode = mode}
	return call(c, &t)
}

// A Treaddir entry's type as a 9P mode: the type, and permissions it does
// not carry (any reader may stat the file for its own).
@(private="file")
mode_of_dirent :: proc "contextless" (type: u8) -> u32 {
	switch type {
	case DT_DIR:
		return DMDIR | 0o755
	case DT_LNK:
		return DMSYMLINK | 0o777
	}
	return 0o644
}

// POSIX's file type as 9P's mode bits.
@(private="file")
type_bits :: proc "contextless" (type: u32) -> u32 {
	switch type {
	case S_IFDIR:
		return DMDIR
	case S_IFLNK:
		return DMSYMLINK
	case S_IFCHR:
		return DMDEVICE
	}
	return 0
}

// A directory's read under 9P2000.L: Treaddir from the cookie the last read
// ended at, its entries written into buf as 9P2000's stat entries (whole,
// as a directory read has them), each with its type in its mode and nothing
// else; offset 0, or where the last read ended (9P2000's rule).
@(private="file", require_results)
readdir_as_stat :: proc "contextless" (c: ^Client, slot: int, offset: u64, buf: []u8) -> (n: int, e: vx.Status) {
	dirs_lock(c)
	d := c.dirs[slot]
	dirs_unlock(c)
	if offset == 0 {
		d.cookie, d.at = 0, 0
	}
	if offset != d.at {
		return 0, .Err_Range
	}
	// A dirent is 24 bytes and its name; a stat entry 49 and the name: ask
	// for what will fit made over.
	count := u32(min(len(buf), int(max(u32))))
	t := Msg{type = .Treaddir, fid = d.fid, offset = d.cookie, count = min(count / 2, c.msize - IOHDRSZ)}
	used := 0
	{
		rc: Rcall
		defer finish(c, &rc)
		exchange(c, &t, &rc) or_return
		pos := 0
		for {
			q, next, type, name, ok := dirent_next(rc.r.data, &pos)
			if !ok {
				break
			}
			st := Stat {
				qid  = q,
				mode = mode_of_dirent(type),
				name = name,
			}
			k := stat_encode(&st, buf[used:])
			if k == 0 {
				break
			}
			used += k
			d.cookie = next
		}
		if used == 0 && pos < len(rc.r.data) {
			return 0, .Err_Too_Small // not one entry fits
		}
	}
	dirs_lock(c)
	if c.dirs[slot].fid == d.fid {
		c.dirs[slot].cookie, c.dirs[slot].at = d.cookie, d.at + u64(used)
	}
	dirs_unlock(c)
	return used, .Ok
}

// Reads up to len(buf) bytes (at most msize - 24) at offset into buf. Returns
// how many; 0 at the end.
@(require_results)
client_read :: proc "contextless" (c: ^Client, fid: Fid, offset: u64, buf: []u8) -> (n: int, e: vx.Status) {
	if dotl(c) {
		dirs_lock(c)
		slot := dir_slot(c, fid, false)
		dirs_unlock(c)
		if slot >= 0 {
			return readdir_as_stat(c, slot, offset, buf)
		}
	}
	count := u32(min(len(buf), int(c.msize - IOHDRSZ)))
	t := Msg{type = .Tread, fid = fid, offset = offset, count = count}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	if rc.r.count > count {
		return 0, .Err_Invalid // more than asked for
	}
	return copy(buf, rc.r.data), .Ok
}

// Writes up to len(data) bytes (at most msize - 24). Returns how many.
@(require_results)
client_write :: proc "contextless" (c: ^Client, fid: Fid, offset: u64, data: []u8) -> (n: int, e: vx.Status) {
	count := min(len(data), int(c.msize - IOHDRSZ))
	t := Msg{type = .Twrite, fid = fid, offset = offset, data = data[:count]}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	if int(rc.r.count) > count {
		return 0, .Err_Invalid
	}
	return int(rc.r.count), .Ok
}

// Room for a stat entry's strings, which client_stat copies there.
Stat_Text :: struct {
	bytes: [1024]u8,
}

// The fid's stat entry. Its strings are in keep's bytes, or empty without
// one (.Err_Too_Small if they do not fit).
@(require_results)
client_stat :: proc "contextless" (c: ^Client, fid: Fid, out: ^Stat, keep: ^Stat_Text = nil) -> vx.Status {
	if dotl(c) { // 9P2000.L has no Tstat: Tgetattr's, without a name (it carries none)
		a := client_getattr(c, fid) or_return
		out^ = {
			qid    = a.qid,
			mode   = type_bits(a.mode & S_IFMT) | (a.mode & 0o777),
			atime  = u32(a.atime_sec),
			mtime  = u32(a.mtime_sec),
			length = a.size,
		}
		return .Ok
	}
	t := Msg{type = .Tstat, fid = fid}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	if keep == nil {
		stat_decode(rc.r.stat, out) or_return
		out.name, out.uid, out.gid, out.muid = "", "", "", ""
		return .Ok
	}
	if len(rc.r.stat) > len(keep.bytes) {
		return .Err_Too_Small
	}
	n := copy(keep.bytes[:], rc.r.stat)
	return stat_decode(keep.bytes[:n], out)
}

// A stat entry that changes nothing: every field "don't touch" (all ones, or
// empty), for Twstat to change only what the caller then sets.
stat_untouched :: proc "contextless" () -> Stat {
	return {
		type = max(u16),
		dev = max(u32),
		qid = {type = transmute(Qid_Type)u8(0xff), version = max(u32), path = max(u64)},
		mode = max(u32),
		atime = max(u32),
		mtime = max(u32),
		length = max(u64),
	}
}

// Twstat: what w's fields say, all or none (stat_untouched for the rest).
@(require_results)
client_wstat :: proc "contextless" (c: ^Client, fid: Fid, w: ^Stat) -> vx.Status {
	entry: [512]u8
	n := stat_encode(w, entry[:])
	if n == 0 {
		return .Err_Too_Small
	}
	t := Msg{type = .Twstat, fid = fid, stat = entry[:n]}
	return call(c, &t)
}

// Renames dir's entry oldname to newname in the same directory, by Twstat:
// a 9P2000 server's rename. Unlike POSIX's, it fails if newname is there.
@(require_results)
client_rename_wstat :: proc "contextless" (c: ^Client, dir: Fid, oldname, newname: string) -> vx.Status {
	fid := client_walk(c, dir, oldname) or_return
	w := stat_untouched()
	w.name = newname
	e := client_wstat(c, fid, &w)
	_ = client_clunk(c, fid)
	return e
}

@(require_results)
client_remove :: proc "contextless" (c: ^Client, fid: Fid) -> vx.Status {
	t := Msg{type = .Tremove, fid = fid}
	return call(c, &t)
}

// One Twalk of at most MAXWELEM names from fid: the qid of each name it
// reached goes in qids, and how many in nwqid. Only a walk that reaches every
// name makes a new fid, as 9P has it (made is then true). An error is the
// server's, for the first name.
@(require_results)
client_walk_names :: proc "contextless" (c: ^Client, fid: Fid, names: []string, qids: ^[MAXWELEM]Qid) -> (newfid: Fid, nwqid: int, made: bool, e: vx.Status) {
	if len(names) > MAXWELEM {
		return 0, 0, false, .Err_Range
	}
	t := Msg{type = .Twalk, fid = fid, newfid = new_fid(c), nwname = u16(len(names))}
	copy(t.wname[:], names)
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	nwqid = int(rc.r.nwqid) <= len(names) ? int(rc.r.nwqid) : 0
	copy(qids[:nwqid], rc.r.wqid[:nwqid])
	if nwqid == len(names) {
		return t.newfid, nwqid, true, .Ok
	}
	return 0, nwqid, false, .Ok
}

// --- The posix and xattr extensions (upstream docs/proto/posix.md) ---
//
// Each needs its extension negotiated (c.extensions); without it the call is
// Err_Unsupported and sends nothing.

@(require_results)
client_getattr :: proc "contextless" (c: ^Client, fid: Fid) -> (attr: Attr, e: vx.Status) {
	if .Xattr not_in c.extensions && !dotl(c) {
		return {}, .Err_Unsupported
	}
	t := Msg{type = .Tgetattr, fid = fid, mask = GETATTR_BASIC}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	return rc.r.attr, .Ok
}

// Without the xattr extension, as Twstat (a 9P2000 server: 9front, u9fs):
// the mode's permission bits, the size, and times given; an owner, a group
// or a time "now" is .Err_Unsupported there (the caller gives the time).
@(require_results)
client_setattr :: proc "contextless" (c: ^Client, fid: Fid, a: Setattr) -> vx.Status {
	if .Xattr in c.extensions || dotl(c) {
		t := Msg{type = .Tsetattr, fid = fid, setattr = a}
		return call(c, &t)
	}
	CAN :: Setattr_Mask{.Mode, .Size, .Atime, .Atime_Set, .Mtime, .Mtime_Set}
	if a.valid - CAN != {} || (.Atime in a.valid && .Atime_Set not_in a.valid) || (.Mtime in a.valid && .Mtime_Set not_in a.valid) {
		return .Err_Unsupported
	}
	w := stat_untouched()
	if .Mode in a.valid {
		cur: Stat
		client_stat(c, fid, &cur) or_return // its type bits stay
		w.mode = (cur.mode &~ 0o777) | (a.mode & 0o777)
	}
	if .Size in a.valid {
		w.length = a.size
	}
	if .Atime_Set in a.valid {
		w.atime = u32(a.atime_sec)
	}
	if .Mtime_Set in a.valid {
		w.mtime = u32(a.mtime_sec)
	}
	return client_wstat(c, fid, &w)
}

// Renames olddir's entry oldname to newname in newdir, both on this
// connection.
@(require_results)
client_renameat :: proc "contextless" (c: ^Client, olddir: Fid, oldname: string, newdir: Fid, newname: string) -> vx.Status {
	if .Posix not_in c.extensions && !dotl(c) {
		return .Err_Unsupported
	}
	t := Msg{type = .Trenameat, fid = olddir, name = oldname, newfid = newdir, name2 = newname}
	return call(c, &t)
}

@(require_results)
client_symlink :: proc "contextless" (c: ^Client, dir: Fid, name, target: string) -> vx.Status {
	if .Posix not_in c.extensions && !dotl(c) {
		return .Err_Unsupported
	}
	t := Msg{type = .Tsymlink, fid = dir, name = name, name2 = target}
	return call(c, &t)
}

// A symbolic link's target, copied into buf (.Err_Too_Small if it does not
// fit).
@(require_results)
client_readlink :: proc "contextless" (c: ^Client, fid: Fid, buf: []u8) -> (target: string, e: vx.Status) {
	if .Posix not_in c.extensions && !dotl(c) {
		return "", .Err_Unsupported
	}
	t := Msg{type = .Treadlink, fid = fid}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	if len(rc.r.name2) > len(buf) {
		return "", .Err_Too_Small
	}
	return string(buf[:copy(buf, rc.r.name2)]), .Ok
}

@(require_results)
client_fsync :: proc "contextless" (c: ^Client, fid: Fid) -> vx.Status {
	if .Posix not_in c.extensions && !dotl(c) {
		return .Ok // a server without it has no later to write at
	}
	t := Msg{type = .Tfsync, fid = fid}
	return call(c, &t)
}

// An open file shared between connections (posix): a token for `holds`
// joins of it.
@(require_results)
client_share :: proc "contextless" (c: ^Client, fid: Fid, holds: u32) -> (token: [TOKEN_SIZE]u8, e: vx.Status) {
	if .Posix not_in c.extensions {
		return {}, .Err_Unsupported
	}
	t := Msg{type = .Tshare, fid = fid, holds = holds}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	return rc.r.token, .Ok
}

// A new fid, open on the open file a token names (on this connection's
// server).
@(require_results)
client_join :: proc "contextless" (c: ^Client, token: [TOKEN_SIZE]u8) -> (fid: Fid, e: vx.Status) {
	if .Posix not_in c.extensions {
		return 0, .Err_Unsupported
	}
	t := Msg{type = .Tjoin, newfid = new_fid(c), token = token}
	call(c, &t) or_return
	return t.newfid, .Ok
}

// Moves the open file's own offset, and says where it is.
@(require_results)
client_seek :: proc "contextless" (c: ^Client, fid: Fid, offset: i64, whence: Whence) -> (at: u64, e: vx.Status) {
	if .Posix not_in c.extensions {
		return 0, .Err_Unsupported
	}
	t := Msg{type = .Tseek, fid = fid, offset = u64(offset), whence = whence}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	return rc.r.offset, .Ok
}

@(require_results)
client_append :: proc "contextless" (c: ^Client, fid: Fid, append: bool) -> vx.Status {
	if .Posix not_in c.extensions {
		return .Err_Unsupported
	}
	t := Msg{type = .Tdesc, fid = fid, desc_flags = append ? {.Append} : {}}
	return call(c, &t)
}

// A byte-range lock, owned by proc_id on this connection; length 0 is to the
// end.
@(require_results)
client_lock :: proc "contextless" (c: ^Client, fid: Fid, type: Lock_Type, start, length: u64, proc_id: u32) -> (status: Lock_Status, e: vx.Status) {
	if .Posix not_in c.extensions && !dotl(c) {
		return .Error, .Err_Unsupported
	}
	t := Msg{type = .Tlock, fid = fid, lock_type = type, start = start, length = length, proc_id = proc_id, client_id = ""}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	return rc.r.status, .Ok
}

// A lock, as Rgetlock describes it.
Lock_Held :: struct {
	type:          Lock_Type, // .Unlock: none
	start, length: u64, // length 0: to the end
	proc_id:       u32,
}

// The first lock that would stop one of `type` over the range: its type,
// range and owner, or .Unlock as its type when none would.
@(require_results)
client_getlock :: proc "contextless" (c: ^Client, fid: Fid, type: Lock_Type, start, length: u64, proc_id: u32) -> (l: Lock_Held, e: vx.Status) {
	if .Posix not_in c.extensions && !dotl(c) {
		return {}, .Err_Unsupported
	}
	t := Msg{type = .Tgetlock, fid = fid, lock_type = type, start = start, length = length, proc_id = proc_id, client_id = ""}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	return {type = rc.r.lock_type, start = rc.r.start, length = rc.r.length, proc_id = rc.r.proc_id}, .Ok
}

// What Tmap answers: a VMO for the range, where in it the range starts, and
// how many bytes it has from there (less than asked for past the file's end).
Mapped :: struct {
	vmo:        vx.Handle,
	vmo_offset: u64,
	avail:      u64,
}

// Tmap (upstream's docs/proto/map.md): a VMO for the file's [offset, offset
// + length), the fid open as the mapping needs. The VMO is the caller's.
@(require_results)
client_map :: proc "contextless" (c: ^Client, fid: Fid, offset, length: u64, prot: Prot) -> (m: Mapped, e: vx.Status) {
	if .Map not_in c.extensions {
		return {}, .Err_Unsupported
	}
	t := Msg{type = .Tmap, fid = fid, offset = offset, length = length, prot = prot}
	rc: Rcall
	defer finish(c, &rc)
	exchange(c, &t, &rc) or_return
	if rc.x.handle == vx.HANDLE_NONE {
		return {}, .Err_Invalid // an Rmap without its VMO
	}
	m = {
		vmo        = rc.x.handle,
		vmo_offset = rc.r.offset,
		avail      = rc.r.length,
	}
	rc.x.handle = vx.HANDLE_NONE // taken
	return m, .Ok
}

// Treadref and Twriteref (upstream's docs/proto/dref.md): count bytes of the
// file at offset copied into, or from, a VMO at roffset by the server, in one
// message whatever the msize. The request carries `send`, a duplicate of the
// caller's VMO (lib/rt's p9_readref makes it), which the transport moves or
// closes once a call has it: taken says so, and one not taken is the
// caller's to close. Returns how many bytes moved.
@(require_results)
client_ref :: proc "contextless" (c: ^Client, type: Type, fid: Fid, offset, roffset: u64, count: u32, send: vx.Handle) -> (done: u32, taken: bool, e: vx.Status) {
	if .Dref not_in c.extensions || (type != .Treadref && type != .Twriteref) {
		return 0, false, .Err_Unsupported
	}
	t := Msg{type = type, fid = fid, offset = offset, count = count, roffset = roffset}
	rc: Rcall
	defer finish(c, &rc)
	e = exchange(c, &t, &rc, send)
	taken = rc.x != nil
	if e != .Ok {
		return 0, taken, e
	}
	return rc.r.count, taken, .Ok
}
