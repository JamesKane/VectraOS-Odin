// relay: one 9P session to a server over TCP, shared by every client that
// connects (upstream's M6 step 6d4d2b), as 9front's mount driver shares one
// mounted channel among all its mounts (devmnt.c): the session is versioned
// once; each client attaches as itself; fids and tags are the relay's own
// on the wire, as they are the kernel's there, so clients number theirs as
// they like.
//
//   relay ADDRESS        (tcp!HOST!PORT, or 9p://HOST:PORT; given as arg=)
//
// It dials ADDRESS through its namespace's /net (vx:ns's dial) and serves
// its `listen` channel as a ring server whose requests it forwards rather
// than serves (vx:p9ring's raw hook): each is decoded, its fids and tag
// swapped for the relay's, and written to the stream; a reader thread files
// each reply under its tag and wakes the server, which hands it back to its
// client with the client's tag. A client's Tversion is answered here, with
// the remote session's dialect (9P2000, say) and the smaller msize; it
// starts that client's session again, clunking its fids. Tflush goes on to
// the server, and the flushed request's reply, if it comes first, is
// dropped. A client that goes has its fids clunked.
//
// It runs while anything can reach it: its listen channel's peer (a post, a
// connector held by whoever spawned it), or a client connected already. If
// the server hangs up, the relay exits, and its clients' calls fail.
package relay

import "base:intrinsics"
import vx "abi:vx"
import usage "gen:usage/relay"
import "vx:ns"
import "vx:p9"
import "vx:p9ring"
import "vx:procns"
import "vx:rt"

@(private="file")
MSIZE :: rt.MSIZE
@(private="file")
CALLS :: 64 // requests in flight on the stream; a call's index is its tag there
@(private="file")
FIDS :: p9ring.MAX_CONNS * p9.MAX_FIDS // the relay's fids, 1 to this

// What a request on the stream is, by its tag there.
@(private="file")
Call_Info :: struct {
	used:     bool,
	orphan:   bool, // its client has gone or flushed it: its reply is dropped
	flushing: bool, // a Tflush of it is out: its tag stays taken until Rflush, answered or not
	conn:     int,
	type:     p9.Type,
	tag:      u16, // the client's
	nwname:   u16, // Twalk's: only a walk of every name makes newfid
	newfid:   p9.Fid, // the client's fid that it makes, or NOFID
	rnew:     p9.Fid, // and the relay's, kept until the reply says whether it was made
	rgone:    p9.Fid, // the relay's fid it ends (Tclunk, Tremove): free once answered
	flushes:  int, // a Tflush's: the call it flushes, or -1
}

@(private="file")
Call :: struct {
	using info: Call_Info,
	replied:    bool, // the reader has filed its reply (under relay_lock)
	len:        u32,
	reply:      [MSIZE]u8,
}

@(private="file")
Fid_Map :: struct {
	local, remote: p9.Fid, // remote 0: a free entry
}

@(private="file")
calls: [CALLS]Call
@(private="file")
fids: [p9ring.MAX_CONNS][p9.MAX_FIDS]Fid_Map
@(private="file")
remote_used: [FIDS + 1]bool
@(private="file")
remote_last: p9.Fid // the last of the relay's fids given out: they go round from 1
@(private="file")
doomed: [dynamic; FIDS]p9.Fid // the relay's fids to clunk once a call is free
@(private="file")
relay_lock: rt.Mutex // the calls' replies, between the reader and the server
@(private="file")
hungup: bool // atomic

@(private="file")
server: p9ring.Server
@(private="file")
space: ns.Namespace
// The conversation's data file, open twice: the server's writes, and the
// reader's reads on a fid of their own, since a file server keeps the
// requests on one fid in order, and a read waiting for the stream would hold
// up every write behind it.
@(private="file")
stream, incoming: ns.File
@(private="file")
dialect: p9.Dialect
@(private="file")
msize: u32
@(private="file")
address: string

@(private="file")
le32 :: proc "contextless" (p: []u8) -> u32 {
	return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24
}

@(private="file")
le16 :: proc "contextless" (p: []u8) -> u16 {
	return u16(p[0]) | u16(p[1]) << 8
}

@(private="file")
wake :: proc "contextless" () {
	pk := vx.Packet {
		key = p9ring.KEY_USER,
	}
	_ = rt.port_post(server.port, &pk)
}

@(private="file")
replied :: proc "contextless" (c: ^Call) -> bool {
	rt.mutex_lock(&relay_lock)
	defer rt.mutex_unlock(&relay_lock)
	return c.replied
}

// --- The relay's fids ---

@(private="file")
remote_take :: proc "contextless" () -> p9.Fid {
	for _ in 0 ..< FIDS {
		f := remote_last % FIDS + 1
		remote_last = f
		if !remote_used[f] {
			remote_used[f] = true
			return f
		}
	}
	return p9.NOFID
}

@(private="file")
remote_give :: proc "contextless" (f: p9.Fid) {
	if f != 0 && f <= FIDS {
		remote_used[f] = false
	}
}

@(private="file")
fid_find :: proc "contextless" (conn: int, local: p9.Fid) -> ^Fid_Map {
	for &m in fids[conn] {
		if m.remote != 0 && m.local == local {
			return &m
		}
	}
	return nil
}

@(private="file")
fid_put :: proc "contextless" (conn: int, local, remote: p9.Fid) -> bool {
	for &m in fids[conn] {
		if m.remote == 0 {
			m = {local, remote}
			return true
		}
	}
	return false
}

// --- The stream ---

@(private="file")
hang_up :: proc "contextless" () {
	intrinsics.atomic_store(&hungup, true)
	wake()
}

@(private="file")
send_buf: [MSIZE]u8

// Writes t to the server, with tag; false (and the relay hangs up) if the
// stream will not take it.
@(private="file")
send :: proc "contextless" (t: ^p9.Msg, tag: int) -> bool {
	t.tag = u16(tag)
	n := p9.encode(t, send_buf[:msize])
	if n == 0 {
		return false
	}
	for sent := 0; sent < n; {
		w, st := ns.write(&stream, send_buf[sent:n])
		if st != .Ok || w <= 0 {
			hang_up()
			return false
		}
		sent += w
	}
	return true
}

@(private="file")
call_take :: proc "contextless" () -> int {
	for &c, i in calls {
		if !c.used {
			return i
		}
	}
	return -1
}

@(private="file")
call_start :: proc "contextless" (i: int, info: Call_Info) {
	rt.mutex_lock(&relay_lock)
	calls[i].info = info
	calls[i].used = true
	calls[i].flushing = false
	calls[i].replied = false
	rt.mutex_unlock(&relay_lock)
}

// Clunks one of the relay's fids, its reply dropped; later if no call is
// free.
@(private="file")
clunk_remote :: proc "contextless" (rfid: p9.Fid) {
	i := call_take()
	if i < 0 {
		_ = append(&doomed, rfid)
		return
	}
	call_start(i, {orphan = true, type = .Tclunk, newfid = p9.NOFID, rnew = p9.NOFID, rgone = rfid, flushes = -1})
	t := p9.Msg {
		type = .Tclunk,
		fid  = rfid,
	}
	if !send(&t, i) {
		calls[i].used = false
	}
}

// Whether a call's reply did what was asked: Rwalk of every name, say.
@(private="file")
call_made :: proc "contextless" (c: ^Call) -> bool {
	if c.len < 7 || c.reply[4] != u8(c.type) + 1 {
		return false
	}
	return c.type != .Twalk || (c.len >= 9 && le16(c.reply[7:]) == c.nwname)
}

// Lets go of answered call i: the fids its reply made or ended. For a
// Tflush, the call it flushed, whose turn it is next (retire's loop); -1
// otherwise.
@(private="file")
retire_one :: proc "contextless" (i: int) -> int {
	c := &calls[i]
	made := call_made(c)
	clunk := p9.NOFID
	if c.rnew != p9.NOFID {
		if made && !c.orphan && fid_put(c.conn, c.newfid, c.rnew) {
			// the client's now
		} else if made {
			clunk = c.rnew // made for no one
		} else {
			remote_give(c.rnew)
		}
	}
	if c.rgone != p9.NOFID {
		remote_give(c.rgone)
	}
	flushed := c.type == .Tflush ? c.flushes : -1
	c.used = false
	if clunk != p9.NOFID {
		clunk_remote(clunk)
	}
	return flushed
}

// A flushed call that its Rflush came for. Answered first, its reply is
// dropped (and a fid it made clunked: retire_one); unanswered, it is as if
// it had not happened, but for a fid it was ending, which is clunked again
// to be sure. -1, or a call for retire's loop to go on with.
@(private="file")
call_flushed :: proc "contextless" (p: int) -> int {
	c := &calls[p]
	if !c.used {
		return -1
	}
	c.flushing = false
	if replied(c) {
		return retire_one(p)
	}
	if c.rnew != p9.NOFID {
		remote_give(c.rnew)
	}
	gone := c.rgone
	c.used = false
	if gone != p9.NOFID {
		clunk_remote(gone)
	}
	return -1
}

// Retires answered call i, and the call it flushed if it is a Tflush.
@(private="file")
retire :: proc "contextless" (i: int) {
	for next := retire_one(i); next >= 0; {
		next = call_flushed(next)
	}
}

// Retires the answered calls no client waits for, and sends the clunks that
// waited for a free call.
@(private="file")
sweep :: proc "contextless" () {
	for &c, i in calls {
		rt.mutex_lock(&relay_lock)
		done := c.used && c.orphan && !c.flushing && c.replied
		rt.mutex_unlock(&relay_lock)
		if done {
			retire(i)
		}
	}
	for len(doomed) > 0 && call_take() >= 0 {
		f := doomed[len(doomed) - 1]
		resize(&doomed, len(doomed) - 1)
		clunk_remote(f)
	}
}

@(private="file")
reader_buf: [2 * MSIZE]u8

// Files each reply under its tag. Runs until the stream ends.
@(private="file")
reader :: proc(arg: rawptr) {
	rd := (^ns.File)(arg)
	buf := reader_buf[:]
	have := 0
	for {
		want := min(len(buf) - have, 8192)
		n, st := ns.read(rd, buf[have:][:want])
		if st != .Ok || n <= 0 {
			break
		}
		have += n
		filed := false
		for have >= 7 {
			size := le32(buf)
			if size < 7 || size > msize {
				hang_up() // nothing it says from here can be matched to a call
				return
			}
			if have < int(size) {
				break
			}
			tag := le16(buf[5:])
			rt.mutex_lock(&relay_lock)
			if tag < CALLS && calls[tag].used && !calls[tag].replied {
				c := &calls[tag]
				copy(c.reply[:], buf[:size])
				c.len, c.replied = size, true
				filed = true
			}
			rt.mutex_unlock(&relay_lock)
			copy(buf, buf[size:have])
			have -= int(size)
		}
		if filed {
			wake()
		}
	}
	hang_up()
}

// --- The clients ---

// An error reply in the session's dialect.
@(private="file")
refuse :: proc "contextless" (tag: u16, st: vx.Status, resp: []u8) -> int {
	r := p9.Msg {
		tag = tag,
	}
	if dialect == .P9_2000L {
		r.type, r.ecode = .Rlerror, p9.status_errno(st)
	} else {
		r.type, r.ename = .Rerror, p9.error_text(st)
	}
	return p9.encode(&r, resp)
}

// Clunks every fid conn has, as a new session or a client gone.
@(private="file")
forget :: proc "contextless" (conn: int) {
	for &m in fids[conn] {
		if m.remote != 0 {
			r := m.remote
			m = {}
			clunk_remote(r)
		}
	}
}

// The calls of conn's session go unanswered: it has gone, or begun again.
@(private="file")
orphan_all :: proc "contextless" (conn: int) {
	for &c in calls {
		if c.used && c.conn == conn {
			c.orphan = true
		}
	}
	forget(conn)
	sweep()
}

@(private="file")
relay_closed :: proc "contextless" (ctx: rawptr, conn: int) {
	orphan_all(conn)
}

@(private="file")
version :: proc "contextless" (conn: int, t: ^p9.Msg, resp: []u8) -> int {
	orphan_all(conn) // the old session's calls go unanswered
	want, _ := p9.version_parse(t.version)
	// A client gets the session's dialect if it asked for it, or for 9Px,
	// whose clients take whatever they are answered, or if the session's is
	// plain 9P2000, which every dialect's clients speak.
	ok := want != .Unknown && (want == dialect || want == .P9_2000X || dialect == .P9_2000)
	v: [64]u8
	r := p9.Msg {
		type    = .Rversion,
		tag     = t.tag,
		msize   = min(t.msize, msize),
		version = ok ? string(v[:p9.version_format(dialect, {}, v[:])]) : "unknown",
	}
	return p9.encode(&r, resp)
}

@(private="file")
flush :: proc "contextless" (conn: int, t: ^p9.Msg, resp: []u8) -> (int, p9.Serve_Result) {
	p := -1
	for &c, i in calls {
		if c.used && !c.orphan && c.conn == conn && c.tag == t.oldtag && c.type != .Tflush {
			p = i
			break
		}
	}
	r := p9.Msg {
		type = .Rflush,
		tag  = t.tag,
	}
	if p < 0 {
		return p9.encode(&r, resp), .Reply // never sent, or answered: nothing to flush
	}
	calls[p].orphan = true
	if replied(&calls[p]) { // its reply is here and goes unread
		retire(p)
		return p9.encode(&r, resp), .Reply
	}
	i := call_take()
	if i < 0 {
		return 0, .Defer // asked again once a call is free
	}
	calls[p].flushing = true
	call_start(i, {conn = conn, type = .Tflush, tag = t.tag, newfid = p9.NOFID, rnew = p9.NOFID, rgone = p9.NOFID, flushes = p})
	u := p9.Msg {
		type   = .Tflush,
		oldtag = u16(p),
	}
	if !send(&u, i) {
		calls[i].used = false
		calls[p].flushing = false
	}
	return 0, .Defer
}

// A request to forward: its fids made the relay's, then sent.
@(private="file")
forward :: proc "contextless" (conn: int, t: ^p9.Msg, resp: []u8) -> (int, p9.Serve_Result) {
	if !p9.known(t.type) || u8(t.type) % 2 != 0 {
		return refuse(t.tag, .Err_Unsupported, resp), .Reply
	}
	u := t^
	newfid := p9.NOFID
	// As vx:ns's dialed attaches: a Plan 9 server refuses "none" until the
	// session has authenticated, and nothing can before keyd (upstream's
	// M10), so a client with no user (the console shell, as yet) attaches as
	// vectra.
	if (t.type == .Tattach || t.type == .Tauth) && (t.uname == "" || t.uname == "none") {
		u.uname = "vectra"
	}
	for f in p9.MESSAGES[u8(t.type)].fields {
		field: ^p9.Fid
		local: p9.Fid
		#partial switch f {
		case .Fid:
			field, local = &u.fid, t.fid
		case .Newfid:
			field, local = &u.newfid, t.newfid
		case .Afid:
			field, local = &u.afid, t.afid
		case:
			continue
		}
		makes := (f == .Fid && t.type == .Tattach) || (f == .Afid && t.type == .Tauth) || (f == .Newfid && (t.type == .Twalk || t.type == .Tjoin))
		if f == .Newfid && t.type == .Twalk && t.newfid == t.fid {
			u.newfid = u.fid // a walk of the fid itself
		} else if makes {
			if fid_find(conn, local) != nil {
				return refuse(t.tag, .Err_Bad_State, resp), .Reply // in use
			}
			newfid = local
		} else if f == .Afid && local == p9.NOFID {
			// no auth fid
		} else if m := fid_find(conn, local); m != nil {
			field^ = m.remote
		} else {
			return refuse(t.tag, .Err_Bad_Handle, resp), .Reply // no such fid
		}
	}
	i := call_take()
	rnew := newfid != p9.NOFID ? remote_take() : p9.NOFID
	if i < 0 || (newfid != p9.NOFID && rnew == p9.NOFID) {
		remote_give(rnew)
		if i < 0 {
			return 0, .Defer
		}
		return refuse(t.tag, .Err_No_Memory, resp), .Reply
	}
	if newfid != p9.NOFID {
		#partial switch t.type {
		case .Tattach:
			u.fid = rnew
		case .Tauth:
			u.afid = rnew
		case .Twalk, .Tjoin:
			u.newfid = rnew
		}
	}
	rgone := p9.NOFID
	if t.type == .Tclunk || t.type == .Tremove { // the client's fid goes now, the relay's once answered
		m := fid_find(conn, t.fid)
		rgone = m.remote
		m^ = {}
	}
	call_start(i, {conn = conn, type = t.type, tag = t.tag, nwname = t.nwname, newfid = newfid, rnew = rnew, rgone = rgone, flushes = -1})
	if !send(&u, i) {
		calls[i].used = false
		remote_give(rnew)
		return refuse(t.tag, .Err_Peer_Closed, resp), .Reply
	}
	return 0, .Defer
}

@(private="file")
relay_raw :: proc "contextless" (ctx: rawptr, conn: int, req: []u8, resp: []u8) -> (int, p9.Serve_Result) {
	t: p9.Msg
	if p9.decode(req, &t) != .Ok || u8(t.type) % 2 != 0 {
		return refuse(len(req) >= 7 ? le16(req[5:]) : p9.NOTAG, .Err_Invalid, resp), .Reply
	}
	for &c, i in calls { // asked again: one already sent
		if !c.used || c.orphan || c.conn != conn || c.tag != t.tag || c.type != t.type {
			continue
		}
		if !replied(&c) {
			return 0, .Defer
		}
		n := int(c.len) <= len(resp) ? int(c.len) : 0
		copy(resp, c.reply[:n])
		if c.type == .Tflush { // Rflush, whatever the server answered
			r := p9.Msg {
				type = .Rflush,
				tag  = t.tag,
			}
			n = p9.encode(&r, resp)
		}
		resp[5], resp[6] = u8(t.tag), u8(t.tag >> 8)
		retire(i)
		return n, .Reply
	}
	#partial switch t.type {
	case .Tversion:
		return version(conn, &t, resp), .Reply
	case .Tflush:
		return flush(conn, &t, resp)
	}
	return forward(conn, &t, resp)
}

@(private="file")
relay_event :: proc "contextless" (ctx: rawptr, pk: ^vx.Packet) {
	if intrinsics.atomic_load(&hungup) {
		rt.print("relay: ", address, " hung up\n")
		rt.exits("hungup")
	}
	sweep()
	server.again = true // held requests whose replies came
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		rt.exits("no listen channel")
	}
	args := rt.args()
	if len(args) < 1 {
		rt.exits(usage.TEXT)
	}
	address = args[0]
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	c, src, st := ns.dial(&space, address)
	if st != .Ok {
		rt.print("relay: cannot dial ", address, ": ", p9.error_text(st), "\n")
		rt.exits("cannot dial")
	}
	// The dialed connection's stream, now the relay's: nothing calls through c again.
	path: string
	stream, path, _ = ns.dial_stream(c)
	dialect, msize = c.dialect, min(c.msize, MSIZE)
	if ns.open(&space, path, p9.OREAD, &incoming) != .Ok {
		rt.exits("cannot open the stream again")
	}
	pst: vx.Status
	if server.port, pst = rt.port_create(); pst != .Ok {
		rt.exits("no port")
	}
	if _, tst := rt.thread_spawn(reader, &incoming); tst != .Ok {
		rt.exits("no reader thread")
	}
	v: [64]u8
	rt.print("relay: ", src, " as ", string(v[:p9.version_format(dialect, {}, v[:])]), "\n")
	server.name = "relay"
	server.raw = relay_raw
	server.closed = relay_closed
	server.event = relay_event
	server.linger = true
	_ = p9ring.serve(&server)
	return 0 // nothing can reach it any more
}
