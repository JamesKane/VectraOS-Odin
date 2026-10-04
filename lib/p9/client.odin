package p9

// The client (upstream 02 §3): one request at a time over any transport that
// can carry one message and return its reply. Pipelining (02 §3.3) comes with
// the ring transport. Every reply is checked: its tag, that it answers the
// request's type, and an Rerror's text back into a Status.

import "abi:vx"

// Sends req and fills resp with the reply. Returns the reply's length, or 0
// if the connection is gone.
Rpc :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int

// Who a client attaches as when it names no one: the program's user (its
// spawn message's user=, which vx:ns sets here), or "none".
client_user: string

Client :: struct {
	rpc:        Rpc,
	ctx:        rawptr,
	tbuf, rbuf: []u8, // each at least the msize asked for
	msize:      u32, // negotiated
	dialect:    Dialect,
	extensions: Extensions, // negotiated
	next_tag:   u16,
	next_fid:   Fid,
	uname:      string, // who attaches; empty: client_user, or "none"
	reply:      Msg, // the last reply; its strings and data point into rbuf
	// The handle the last reply carried (Rmap's VMO), set by the transport;
	// the call that wants it takes it, and the transport closes one not taken.
	handle:      vx.Handle,
	// A handle for the next request to carry (dref's VMO), which the
	// transport moves to the server, or closes if it cannot.
	send_handle: vx.Handle,
}

@(private="file", require_results)
call :: proc "contextless" (c: ^Client, t: ^Msg) -> vx.Status {
	if t.type != .Tversion {
		t.tag = c.next_tag % NOTAG // NOTAG is Tversion's alone
		c.next_tag += 1
	}
	n := encode(t, c.tbuf)
	if n == 0 {
		return .Err_Too_Small
	}
	rn := c.rpc(c.ctx, c.tbuf[:n], c.rbuf)
	if rn <= 0 || rn > len(c.rbuf) {
		return .Err_Peer_Closed
	}
	if decode(c.rbuf[:rn], &c.reply) != .Ok || c.reply.tag != t.tag {
		return .Err_Invalid
	}
	if c.reply.type == .Rerror {
		return error_status(c.reply.ename)
	}
	return u8(c.reply.type) == u8(t.type) + 1 ? .Ok : .Err_Invalid
}

// The largest message both buffers hold.
@(private="file")
bufsize :: proc "contextless" (c: ^Client) -> u32 {
	return u32(min(len(c.tbuf), len(c.rbuf), int(max(u32))))
}

// Negotiates a session: 9Px with the given extensions, and an msize no larger
// than the buffers. A 9P2000 server answers 9P2000, and then extensions are
// empty.
@(require_results)
client_version :: proc "contextless" (c: ^Client, msize: u32, extensions: Extensions) -> vx.Status {
	version: [96]u8
	t := Msg{type = .Tversion, tag = NOTAG, msize = min(msize, bufsize(c))}
	t.version = string(version[:version_format(.P9_2000X, extensions, version[:])])
	call(c, &t) or_return
	c.dialect, c.extensions = version_parse(c.reply.version)
	c.extensions &= extensions
	if c.dialect == .Unknown || c.reply.msize < MIN_MSIZE || c.reply.msize > t.msize {
		return .Err_Unsupported
	}
	c.msize = c.reply.msize
	c.next_fid = 1
	return .Ok
}

@(require_results)
client_attach :: proc "contextless" (c: ^Client, aname: string) -> (fid: Fid, e: vx.Status) {
	uname := len(client_user) > 0 ? client_user : "none"
	if len(c.uname) > 0 {
		uname = c.uname
	}
	t := Msg{type = .Tattach, fid = c.next_fid, afid = NOFID, uname = uname, aname = aname}
	c.next_fid += 1
	e = call(c, &t)
	return t.fid, e
}

@(require_results)
client_clunk :: proc "contextless" (c: ^Client, fid: Fid) -> vx.Status {
	t := Msg{type = .Tclunk, fid = fid}
	return call(c, &t)
}

// Walks a '/'-separated path from fid to a new fid, in walks of at most 16
// names. An empty path clones the fid.
@(require_results)
client_walk :: proc "contextless" (c: ^Client, fid: Fid, path: string) -> (newfid: Fid, e: vx.Status) {
	from, to := fid, c.next_fid
	c.next_fid += 1
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
		e = call(c, &t)
		if e == .Ok && c.reply.nwqid != t.nwname {
			e = .Err_Not_Found // stopped partway
		}
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

@(require_results)
client_open :: proc "contextless" (c: ^Client, fid: Fid, mode: Open_Mode) -> vx.Status {
	t := Msg{type = .Topen, fid = fid, mode = mode}
	return call(c, &t)
}

// Creates name in the directory fid, which then refers to the new file, open.
@(require_results)
client_create :: proc "contextless" (c: ^Client, fid: Fid, name: string, perm: u32, mode: Open_Mode) -> vx.Status {
	t := Msg{type = .Tcreate, fid = fid, name = name, perm = perm, mode = mode}
	return call(c, &t)
}

// Reads up to len(buf) bytes (at most msize - 24) at offset into buf. Returns
// how many; 0 at the end.
@(require_results)
client_read :: proc "contextless" (c: ^Client, fid: Fid, offset: u64, buf: []u8) -> (n: int, e: vx.Status) {
	count := u32(min(len(buf), int(c.msize - IOHDRSZ)))
	t := Msg{type = .Tread, fid = fid, offset = offset, count = count}
	call(c, &t) or_return
	if c.reply.count > count {
		return 0, .Err_Invalid // more than asked for
	}
	copy(buf, c.reply.data)
	return int(c.reply.count), .Ok
}

// Writes up to len(data) bytes (at most msize - 24). Returns how many.
@(require_results)
client_write :: proc "contextless" (c: ^Client, fid: Fid, offset: u64, data: []u8) -> (n: int, e: vx.Status) {
	count := min(len(data), int(c.msize - IOHDRSZ))
	t := Msg{type = .Twrite, fid = fid, offset = offset, data = data[:count]}
	call(c, &t) or_return
	if int(c.reply.count) > count {
		return 0, .Err_Invalid
	}
	return int(c.reply.count), .Ok
}

// The fid's stat entry; its strings point into the client's reply buffer and
// last until the next call.
@(require_results)
client_stat :: proc "contextless" (c: ^Client, fid: Fid, out: ^Stat) -> vx.Status {
	t := Msg{type = .Tstat, fid = fid}
	call(c, &t) or_return
	return stat_decode(c.reply.stat, out)
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
	t := Msg{type = .Twalk, fid = fid, newfid = c.next_fid, nwname = u16(len(names))}
	c.next_fid += 1
	copy(t.wname[:], names)
	call(c, &t) or_return
	nwqid = int(c.reply.nwqid) <= len(names) ? int(c.reply.nwqid) : 0
	copy(qids[:nwqid], c.reply.wqid[:nwqid])
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
	if .Xattr not_in c.extensions {
		return {}, .Err_Unsupported
	}
	t := Msg{type = .Tgetattr, fid = fid, mask = GETATTR_BASIC}
	call(c, &t) or_return
	return c.reply.attr, .Ok
}

@(require_results)
client_setattr :: proc "contextless" (c: ^Client, fid: Fid, a: Setattr) -> vx.Status {
	if .Xattr not_in c.extensions {
		return .Err_Unsupported
	}
	t := Msg{type = .Tsetattr, fid = fid, setattr = a}
	return call(c, &t)
}

// Renames olddir's entry oldname to newname in newdir, both on this
// connection.
@(require_results)
client_renameat :: proc "contextless" (c: ^Client, olddir: Fid, oldname: string, newdir: Fid, newname: string) -> vx.Status {
	if .Posix not_in c.extensions {
		return .Err_Unsupported
	}
	t := Msg{type = .Trenameat, fid = olddir, name = oldname, newfid = newdir, name2 = newname}
	return call(c, &t)
}

@(require_results)
client_symlink :: proc "contextless" (c: ^Client, dir: Fid, name, target: string) -> vx.Status {
	if .Posix not_in c.extensions {
		return .Err_Unsupported
	}
	t := Msg{type = .Tsymlink, fid = dir, name = name, name2 = target}
	return call(c, &t)
}

// A symbolic link's target; it points into the reply buffer, until the next
// call.
@(require_results)
client_readlink :: proc "contextless" (c: ^Client, fid: Fid) -> (target: string, e: vx.Status) {
	if .Posix not_in c.extensions {
		return "", .Err_Unsupported
	}
	t := Msg{type = .Treadlink, fid = fid}
	call(c, &t) or_return
	return c.reply.name2, .Ok
}

@(require_results)
client_fsync :: proc "contextless" (c: ^Client, fid: Fid) -> vx.Status {
	if .Posix not_in c.extensions {
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
	call(c, &t) or_return
	return c.reply.token, .Ok
}

// A new fid, open on the open file a token names (on this connection's
// server).
@(require_results)
client_join :: proc "contextless" (c: ^Client, token: [TOKEN_SIZE]u8) -> (fid: Fid, e: vx.Status) {
	if .Posix not_in c.extensions {
		return 0, .Err_Unsupported
	}
	t := Msg{type = .Tjoin, newfid = c.next_fid, token = token}
	c.next_fid += 1
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
	call(c, &t) or_return
	return c.reply.offset, .Ok
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
	if .Posix not_in c.extensions {
		return .Error, .Err_Unsupported
	}
	t := Msg{type = .Tlock, fid = fid, lock_type = type, start = start, length = length, proc_id = proc_id, client_id = ""}
	call(c, &t) or_return
	return c.reply.status, .Ok
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
	if .Posix not_in c.extensions {
		return {}, .Err_Unsupported
	}
	t := Msg{type = .Tgetlock, fid = fid, lock_type = type, start = start, length = length, proc_id = proc_id, client_id = ""}
	call(c, &t) or_return
	return {type = c.reply.lock_type, start = c.reply.start, length = c.reply.length, proc_id = c.reply.proc_id}, .Ok
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
	call(c, &t) or_return
	if c.handle == vx.HANDLE_NONE {
		return {}, .Err_Invalid // an Rmap without its VMO
	}
	m = {vmo = c.handle, vmo_offset = c.reply.offset, avail = c.reply.length}
	c.handle = vx.HANDLE_NONE
	return m, .Ok
}

// Treadref and Twriteref (upstream's docs/proto/dref.md): count bytes of the
// file at offset copied into, or from, a VMO at roffset by the server, in one
// message whatever the msize. The request carries send_handle, which the
// caller sets to a duplicate of its VMO (lib/rt's p9_readref does), and which
// the transport moves; one left over was never sent, and is the caller's to
// close. Returns how many bytes moved.
@(require_results)
client_ref :: proc "contextless" (c: ^Client, type: Type, fid: Fid, offset, roffset: u64, count: u32) -> (done: u32, e: vx.Status) {
	if .Dref not_in c.extensions || (type != .Treadref && type != .Twriteref) {
		return 0, .Err_Unsupported
	}
	t := Msg{type = type, fid = fid, offset = offset, count = count, roffset = roffset}
	call(c, &t) or_return
	return c.reply.count, .Ok
}
