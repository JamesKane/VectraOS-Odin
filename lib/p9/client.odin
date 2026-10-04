package p9

// The client (upstream 02 §3): one request at a time over any transport that
// can carry one message and return its reply. Pipelining (02 §3.3) comes with
// the ring transport. Every reply is checked: its tag, that it answers the
// request's type, and an Rerror's text back into a Status.

import "abi:vx"

// Sends req and fills resp with the reply. Returns the reply's length, or 0
// if the connection is gone.
Rpc :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int

Client :: struct {
	rpc:        Rpc,
	ctx:        rawptr,
	tbuf, rbuf: []u8, // each at least the msize asked for
	msize:      u32, // negotiated
	dialect:    Dialect,
	extensions: Extensions, // negotiated
	next_tag:   u16,
	next_fid:   Fid,
	uname:      string, // who attaches; empty: "none"
	reply:      Msg, // the last reply; its strings and data point into rbuf
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
	t := Msg{type = .Tattach, fid = c.next_fid, afid = NOFID, uname = c.uname if len(c.uname) > 0 else "none", aname = aname}
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
