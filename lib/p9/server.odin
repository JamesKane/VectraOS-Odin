package p9

// The server framework (upstream 02 §2, §3): one request in, one reply out,
// no transport. A file server supplies an Fs, operations on its own opaque
// node IDs; this file keeps the fid table and owns everything a hostile
// client could abuse:
//
//  - the attach root: each fid remembers the root it was attached at, `..`
//    there stays there, and `..` elsewhere goes through the file server's
//    parent operation, so a walk can never leave the root (02 §2);
//  - names: ".", "", and names holding '/' are refused before the file
//    server sees them;
//  - fids: every message's fid must exist, newfids must be free, open fids
//    cannot walk, and only open fids read or write in their mode;
//  - sizes: msize is negotiated, and reads and writes are clamped to it;
//  - directory reads: whole stat entries, at offset 0 or where the last read
//    ended (9P2000's rule).
//
// The transport is whoever calls serve. It owns one Server per connection
// (the Fs may be shared), hands serve each whole request and a buffer for the
// reply, sends what comes back, and calls hang_up when the connection goes,
// so the file server hears every node let go. A read or write the file server
// cannot do yet (a console with no input typed) answers Err_Should_Wait;
// serve then returns .Defer, without a reply, and the transport holds the
// request and serves it again when the file server's device has done
// something (upstream's ring transport does this). Everything else completes
// as it arrives, so Tflush has nothing to cancel.

import "base:intrinsics"
import "abi:vx"

// The file server's side. Strings a call is given point into the request and
// last only for the call. Stat's strings must last until the next call.
Fs :: struct {
	ctx:     rawptr,
	attach:  proc "contextless" (ctx: rawptr, aname: string) -> (root: u64, st: vx.Status),
	// Never ".", "..", or a name with '/'.
	walk:    proc "contextless" (ctx: rawptr, dir: u64, name: string) -> (child: u64, st: vx.Status),
	// Only asked below an attach root.
	parent:  proc "contextless" (ctx: rawptr, node: u64) -> (parent: u64, st: vx.Status),
	stat:    proc "contextless" (ctx: rawptr, node: u64, out: ^Stat) -> vx.Status,
	open:    proc "contextless" (ctx: rawptr, node: u64, mode: u8) -> vx.Status,
	// Files: up to len(buf) bytes at offset; or Err_Should_Wait.
	read:    proc "contextless" (ctx: rawptr, node: u64, offset: u64, buf: []u8) -> (count: u32, st: vx.Status),
	// The index-th entry of a directory; Err_Not_Found past the end.
	readdir: proc "contextless" (ctx: rawptr, dir: u64, index: u32) -> (child: u64, st: vx.Status),
	// May write less than it is given; or nil.
	write:   proc "contextless" (ctx: rawptr, node: u64, offset: u64, data: []u8) -> (count: u32, st: vx.Status),
	// Or nil.
	create:  proc "contextless" (ctx: rawptr, dir: u64, name: string, perm: u32, mode: u8) -> (node: u64, st: vx.Status),
	// Or nil.
	remove:  proc "contextless" (ctx: rawptr, node: u64) -> vx.Status,
	// Optional: a fid let the node go.
	clunk:   proc "contextless" (ctx: rawptr, node: u64),
}

MAX_FIDS :: 256 // per connection, for now

Fid :: struct {
	fid:        u32,
	used, open: bool,
	mode:       u8,
	node, root: u64, // root: where it was attached; `..` stops there
	qid:        Qid,
	dir_offset: u64, // a directory read continues only from here
	dir_index:  u32, // the next entry to read
}

// One connection's state. Zeroed with fs, max_msize and supported set, it is
// a connection that has not yet sent Tversion.
Server :: struct {
	fs:         Fs,
	max_msize:  u32, // the largest this server accepts
	supported:  Extensions, // the 9Px extensions it implements
	msize:      u32, // negotiated; 0 until Tversion
	dialect:    Dialect,
	extensions: Extensions, // negotiated
	fids:       [MAX_FIDS]Fid,
	version:    [96]u8, // Rversion's string
	stat:       [1024]u8, // Rstat's entry
}

// What serve made of a request.
Serve_Result :: enum u8 {
	Reply, // send the reply it wrote
	Defer, // no reply yet: hold the request and serve it again later
	Hang_Up, // the request was too broken to answer: end the connection
}

// The size of Rread's header: size, type, tag, count. Read data goes straight
// after it in the reply buffer, where Rread carries it.
@(private="file")
RREAD_HDR :: 4 + 1 + 2 + 4

@(private="file")
fid_find :: proc "contextless" (s: ^Server, fid: u32) -> ^Fid {
	for &f in s.fids {
		if f.used && f.fid == fid {
			return &f
		}
	}
	return nil
}

@(private="file")
fid_new :: proc "contextless" (s: ^Server, fid: u32) -> ^Fid {
	if fid == NOFID || fid_find(s, fid) != nil {
		return nil
	}
	for &f in s.fids {
		if !f.used {
			f = {fid = fid, used = true}
			return &f
		}
	}
	return nil
}

@(private="file")
fid_drop :: proc "contextless" (s: ^Server, f: ^Fid) {
	if s.fs.clunk != nil {
		s.fs.clunk(s.fs.ctx, f.node)
	}
	f^ = {}
}

// Ends the session: every fid is clunked, and the connection must send
// Tversion before anything else. A transport calls it when the connection
// goes; Tversion does it too.
hang_up :: proc "contextless" (s: ^Server) {
	for &f in s.fids {
		if f.used {
			fid_drop(s, &f)
		}
	}
	s.msize = 0
}

@(private="file")
qid_of :: proc "contextless" (s: ^Server, node: u64, qid: ^Qid) -> vx.Status {
	st: Stat
	e := s.fs.stat(s.fs.ctx, node, &st)
	if e == .Ok {
		qid^ = st.qid
	}
	return e
}

// A name the file server may see: not empty, not ".", no '/'.
@(private="file")
good_name :: proc "contextless" (n: string) -> bool {
	if len(n) == 0 || n == "." {
		return false
	}
	for c in transmute([]u8)n {
		if c == '/' {
			return false
		}
	}
	return true
}

// Walks one step from node, keeping inside root.
@(private="file", require_results)
step :: proc "contextless" (s: ^Server, root, node: u64, name: string) -> (next: u64, e: vx.Status) {
	if name == ".." {
		if node == root {
			return root, .Ok // `..` at the attach root is the root
		}
		return s.fs.parent(s.fs.ctx, node)
	}
	if !good_name(name) {
		return 0, .Err_Invalid
	}
	return s.fs.walk(s.fs.ctx, node, name)
}

// Fills out with whole stat entries from a directory fid. Returns how many
// bytes it used.
@(private="file")
read_dir :: proc "contextless" (s: ^Server, f: ^Fid, offset: u64, out: []u8) -> (count: u32, e: vx.Status) {
	if offset == 0 {
		f.dir_index, f.dir_offset = 0, 0
	} else if offset != f.dir_offset {
		return 0, .Err_Range
	}
	used := 0
	for {
		child, re := s.fs.readdir(s.fs.ctx, f.node, f.dir_index)
		if re == .Err_Not_Found {
			break
		}
		if re != .Ok {
			return 0, re
		}
		st: Stat
		if se := s.fs.stat(s.fs.ctx, child, &st); se != .Ok {
			return 0, se
		}
		n := stat_encode(&st, out[used:])
		if n == 0 {
			if used == 0 {
				return 0, .Err_Too_Small // not even one entry fits the count asked for
			}
			break
		}
		used += n
		f.dir_index += 1
	}
	// out is at most msize bytes, so neither sum can overflow; check anyway,
	// since the offset is the client's to choose.
	next, overflow := intrinsics.overflow_add(f.dir_offset, u64(used))
	if overflow {
		return 0, .Err_Range
	}
	f.dir_offset = next
	return u32(used), .Ok
}

// Handles one request (one whole message) and writes the reply into resp.
// Returns the reply's length with .Reply; otherwise the length is 0.
@(require_results)
serve :: proc "contextless" (s: ^Server, req: []u8, resp: []u8) -> (reply_len: int, res: Serve_Result) {
	t, r: Msg
	if decode(req, &t) != .Ok {
		return 0, .Hang_Up
	}
	if u8(t.type) % 2 != 0 || t.type == .Rerror {
		return 0, .Hang_Up // only T-messages come to a server
	}
	r.type = Type(u8(t.type) + 1)
	r.tag = t.tag
	e := vx.Status.Ok
	f: ^Fid

	if t.type != .Tversion && s.msize == 0 {
		e = .Err_Bad_State // nothing before Tversion
	} else {
		#partial switch t.type {
		case .Tversion:
			hang_up(s) // a new session
			s.dialect, s.extensions = version_parse(t.version)
			s.extensions &= s.supported
			s.msize = min(t.msize, s.max_msize)
			if s.msize < MIN_MSIZE {
				s.msize = 0
				e = .Err_Too_Small
				break
			}
			r.msize = s.msize
			r.version = string(s.version[:version_format(s.dialect, s.extensions, s.version[:])])
			if s.dialect == .Unknown {
				s.msize = 0 // "unknown": the client may try again
			}
		case .Tauth:
			e = .Err_Unsupported // tokens come with keyd (02 §3.4)
		case .Tattach:
			if t.afid != NOFID {
				e = .Err_Unsupported
			} else if f = fid_new(s, t.fid); f == nil {
				e = .Err_Bad_State
			} else if f.node, e = s.fs.attach(s.fs.ctx, t.aname); e == .Ok {
				e = qid_of(s, f.node, &r.qid)
			}
			if e == .Ok {
				f.root, f.qid = f.node, r.qid
			} else if f != nil {
				f^ = {}
			}
		case .Tflush:
		case .Twalk:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
				break
			}
			if f.open || (t.newfid != t.fid && fid_find(s, t.newfid) != nil) || t.newfid == NOFID {
				e = .Err_Bad_State
				break
			}
			node, qid := f.node, f.qid
			for i in 0 ..< int(t.nwname) {
				next, se := step(s, f.root, node, t.wname[i])
				if se == .Ok {
					se = qid_of(s, next, &qid)
				}
				if se != .Ok {
					if i == 0 {
						e = se // nothing walked: an error; otherwise the qids so far, and no newfid
					}
					break
				}
				node = next
				r.wqid[r.nwqid] = qid
				r.nwqid += 1
			}
			if e != .Ok || r.nwqid != t.nwname {
				break
			}
			n := t.newfid == t.fid ? f : fid_new(s, t.newfid)
			if n == nil {
				e = .Err_No_Memory // too many fids
				break
			}
			if n == f && s.fs.clunk != nil {
				s.fs.clunk(s.fs.ctx, f.node)
			}
			root := f.root
			n^ = {fid = t.newfid, used = true, node = node, root = root, qid = qid}
		case .Topen, .Tcreate:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
				break
			}
			if f.open {
				e = .Err_Bad_State
				break
			}
			if t.type == .Tcreate {
				node: u64
				if f.qid.type & QTDIR == 0 || !good_name(t.name) || t.name == ".." {
					e = .Err_Invalid
				} else if s.fs.create == nil {
					e = .Err_Access
				} else {
					node, e = s.fs.create(s.fs.ctx, f.node, t.name, t.perm, t.mode)
				}
				if e == .Ok {
					if s.fs.clunk != nil {
						s.fs.clunk(s.fs.ctx, f.node)
					}
					f.node = node
					e = qid_of(s, node, &f.qid)
				}
			} else {
				writes := t.mode & 3 == OWRITE || t.mode & 3 == ORDWR || t.mode & OTRUNC != 0
				if f.qid.type & QTDIR != 0 && writes {
					e = .Err_Access // directories are only read
				} else {
					e = s.fs.open(s.fs.ctx, f.node, t.mode)
				}
			}
			if e != .Ok {
				break
			}
			f.open = true
			f.mode = t.mode
			r.qid = f.qid
			r.iounit = s.msize - IOHDRSZ
		case .Tread:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
				break
			}
			if !f.open || f.mode & 3 == OWRITE {
				e = .Err_Access
				break
			}
			// The data goes straight where Rread carries it: size, type, tag, count.
			if len(resp) < RREAD_HDR {
				return 0, .Hang_Up
			}
			room := s.msize - IOHDRSZ
			if u64(len(resp) - RREAD_HDR) < u64(room) {
				room = u32(len(resp) - RREAD_HDR)
			}
			count := min(t.count, room)
			out := resp[RREAD_HDR:][:count]
			if f.qid.type & QTDIR != 0 {
				count, e = read_dir(s, f, t.offset, out)
			} else {
				count, e = s.fs.read(s.fs.ctx, f.node, t.offset, out)
			}
			if e == .Ok && count > u32(len(out)) {
				e = .Err_Range // the file server claims more than it was given room for
				break
			}
			r.data = out[:count] if e == .Ok else nil
		case .Twrite:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
			} else if !f.open || (f.mode & 3 != OWRITE && f.mode & 3 != ORDWR) || s.fs.write == nil {
				e = .Err_Access
			} else if t.count > s.msize - IOHDRSZ {
				e = .Err_Too_Small
			} else {
				r.count, e = s.fs.write(s.fs.ctx, f.node, t.offset, t.data)
			}
		case .Tclunk, .Tremove:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
				break
			}
			if t.type == .Tremove {
				e = s.fs.remove != nil ? s.fs.remove(s.fs.ctx, f.node) : .Err_Access
			}
			fid_drop(s, f) // a remove clunks the fid whether or not it worked
		case .Tstat:
			st: Stat
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
			} else if e = s.fs.stat(s.fs.ctx, f.node, &st); e == .Ok {
				n := stat_encode(&st, s.stat[:])
				if n == 0 {
					e = .Err_Too_Small
				}
				r.stat = s.stat[:n]
			}
		case .Twstat:
			e = .Err_Unsupported // renames and chmod come with fsd
		case:
			return 0, .Hang_Up
		}
	}
	if e == .Err_Should_Wait && (t.type == .Tread || t.type == .Twrite) {
		return 0, .Defer
	}
	if e != .Ok {
		r = {type = .Rerror, tag = t.tag, ename = error_text(e)}
	}
	if reply_len = encode(&r, resp); reply_len == 0 {
		return 0, .Hang_Up
	}
	return reply_len, .Reply
}
