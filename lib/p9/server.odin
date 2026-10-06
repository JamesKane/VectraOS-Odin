package p9

// The server framework (upstream 02 §2, §3): one request in, one reply out,
// no transport. A file server supplies an Fs, operations on its own opaque
// node IDs; this file keeps the fid table and owns everything a hostile
// client could abuse:
//
//  - the attach root: each fid remembers the root it was attached at, `..`
//    there stays there, and `..` elsewhere goes through the file server's
//    parent operation, so a walk can never leave the root (02 §2);
//  - names: ".", "", names holding '/', and names that are not UTF-8 or hold
//    a control character (upstream ADR-0013) are refused before the file
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
// cannot do yet (a console with no input typed), or an open (a listen file
// with no call yet, through the clone hook), answers Err_Should_Wait; serve
// then returns .Defer, without a reply, and the transport holds the
// request and serves it again when the file server's device has done
// something (lib/p9ring does this), dropping it if a Tflush names it.
// Everything else completes as it arrives, so a Tflush finds nothing else to
// cancel.
//
// This file also does, for every file server (upstream's M6 step 6d4c1):
// ORCLOSE, the file removed as its last fid goes (a file server without
// remove refuses it); DMAPPEND, a write at the end whatever its offset (a
// file whose qid says QTAPPEND); and Twstat, mapped onto the file server's
// setattr and rename. DMEXCL is the file server's, which counts its opens;
// one that cannot keep DMAPPEND or DMEXCL in a mode refuses a create that
// asks.
//
// With the posix extension, open files and locks are the server's, shared
// by all its connections (Shared, below), and with xattr, Tgetattr and
// Tsetattr (upstream docs/proto/posix.md). With map, Tmap answers a VMO,
// and with dref, Treadref and Twriteref move data through the client's VMO
// (upstream docs/proto/map.md, dref.md); the handles go by the transport,
// through Server's reply_handle and request_handle.

import "base:intrinsics"
import "abi:vx"
import "vx:drbg"
import "vx:str"
import "vx:utf"

// A file server's own name for one of its files, which it chooses; the
// framework only stores and compares them.
Node :: distinct u64

// The file server's side. Strings a call is given point into the request and
// last only for the call. Stat's strings must last until the next call.
Fs :: struct {
	ctx:     rawptr,
	attach:  proc "contextless" (ctx: rawptr, aname: string) -> (root: Node, st: vx.Status),
	// Optional: attach, told who attaches (Tattach's uname); used instead of
	// attach when set. Advisory until keyd (upstream's M10): a client can
	// name anyone.
	attach_as: proc "contextless" (ctx: rawptr, aname, uname: string) -> (root: Node, st: vx.Status),
	// Never ".", "..", or a name with '/'.
	walk:    proc "contextless" (ctx: rawptr, dir: Node, name: string) -> (child: Node, st: vx.Status),
	// Only asked below an attach root.
	parent:  proc "contextless" (ctx: rawptr, node: Node) -> (parent: Node, st: vx.Status),
	stat:    proc "contextless" (ctx: rawptr, node: Node, out: ^Stat) -> vx.Status,
	open:    proc "contextless" (ctx: rawptr, node: Node, mode: Open_Mode) -> vx.Status,
	// Optional: after an open, a clone file (upstream 02 §5) makes a new
	// node, and the fid moves there, opened. Err_Not_Found: the node is not
	// a clone file. Err_Should_Wait: not yet (a listen file before a call
	// comes); the open is held and made again, so open must do nothing that
	// cannot be repeated.
	clone:   proc "contextless" (ctx: rawptr, node: Node, mode: Open_Mode) -> (opened: Node, st: vx.Status),
	// Files: up to len(buf) bytes at offset; or Err_Should_Wait.
	read:    proc "contextless" (ctx: rawptr, node: Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status),
	// The index-th entry of a directory; Err_Not_Found past the end.
	readdir: proc "contextless" (ctx: rawptr, dir: Node, index: u32) -> (child: Node, st: vx.Status),
	// May write less than it is given; or nil.
	write:   proc "contextless" (ctx: rawptr, node: Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status),
	// Or nil.
	create:  proc "contextless" (ctx: rawptr, dir: Node, name: string, perm: u32, mode: Open_Mode) -> (node: Node, st: vx.Status),
	// Or nil.
	remove:  proc "contextless" (ctx: rawptr, node: Node) -> vx.Status,
	// Optional: a fid let the node go; opened says whether the fid had it open.
	clunk:    proc "contextless" (ctx: rawptr, node: Node, opened: bool),
	// The posix and xattr extensions, each optional: a server without one
	// refuses its message. Rgetattr needs nothing new: it is made from stat.
	setattr:  proc "contextless" (ctx: rawptr, node: Node, a: ^Setattr) -> vx.Status,
	rename:   proc "contextless" (ctx: rawptr, olddir: Node, oldname: string, newdir: Node, newname: string) -> vx.Status,
	symlink:  proc "contextless" (ctx: rawptr, dir: Node, name, target: string) -> (node: Node, st: vx.Status),
	// The target's bytes last until the next call.
	readlink: proc "contextless" (ctx: rawptr, node: Node) -> (target: string, st: vx.Status),
	// Optional: Tfsync, answered when it returns. A server that writes
	// before Rwrite has none; one that commits later (fsd) commits here.
	fsync:    proc "contextless" (ctx: rawptr, node: Node) -> vx.Status,
	// The map extension, optional: a VMO for the file's [offset, offset +
	// length), with rights for prot and no more, where in it the range
	// starts, and how many bytes it has from there (the rest of the range is
	// past the file). The handle becomes the framework's, which the
	// transport hands to the client.
	map_range: proc "contextless" (ctx: rawptr, node: Node, offset, length: u64, prot: Prot) -> (m: Mapped, st: vx.Status),
	// The dref extension, optional: a file's bytes copied into, or from, the
	// client's VMO at roffset, at most count of them; how many, as Tread's
	// and Twrite's. The VMO stays the framework's.
	read_ref:  proc "contextless" (ctx: rawptr, node: Node, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status),
	write_ref: proc "contextless" (ctx: rawptr, node: Node, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status),
}

MAX_FIDS :: 256 // per connection, for now

// --- Open files and locks shared between connections (posix) ---
//
// An open fid on a server with the posix extension has an open file, kept
// here: its node, mode, offset and O_APPEND, shared by every fid that joins
// it, on any of the server's connections. Tshare gives a token for it, good
// for `holds` joins within HOLD_TIME of the last Tshare (or of its last fid's
// going, which a hold outlives so long): holds a client never used run out
// then, open file or not. A Tshare with no holds outstanding makes a new
// token, so an old one never joins again. Locks are POSIX's: byte ranges, owned by a
// connection and a process id, and let go when the owner lets go of any fid
// on the file.

MAX_OPEN_FILES :: 256
MAX_LOCKS :: 256
MAX_HOLDS :: 64
HOLD_TIME :: i64(10_000_000_000) // ns

Open_File :: struct {
	used, append, shared: bool,
	orclose:              bool, // opened with ORCLOSE: removed when its last fid goes
	mode:                 Open_Mode,
	node:                 Node,
	offset:               u64,
	fids, holds:          u32,
	hold_until:           i64,
	token:                [TOKEN_SIZE]u8,
}

Lock :: struct {
	used:       bool,
	type:       Lock_Type, // .Read or .Write
	node:       Node,
	start, end: u64, // [start, end); end max(u64): to the end of the file
	conn:       ^Server, // the owner: a connection and a process on it
	proc_id:    u32,
}

Shared :: struct {
	files:  [MAX_OPEN_FILES]Open_File,
	locks:  [MAX_LOCKS]Lock,
	random: drbg.Drbg, // tokens; unseeded: Tshare is refused
	now:    proc "contextless" () -> i64, // nanoseconds; nil: holds never run out
}

// What a fid refers to, on the server's side.
Fid_Entry :: struct {
	fid:        Fid,
	used, open: bool,
	mode:       Open_Mode,
	file:       ^Open_File, // its open file in the Shared table, or nil
	node, root: Node, // root: where it was attached; `..` stops there
	qid:        Qid,
	dir_offset: u64, // a directory read continues only from here
	dir_index:  u32, // the next entry to read
	orclose:    bool, // opened with ORCLOSE, and no open file shares it: removed as it is clunked
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
	fids:       [MAX_FIDS]Fid_Entry,
	shared:     ^Shared, // the server's open files and locks, for posix; may be nil
	version:    [96]u8, // Rversion's string
	stat:       [1024]u8, // Rstat's entry
	// The handle the last reply carries (Rmap's VMO), for the transport to
	// pass on; HANDLE_NONE when it carries none. The transport's to close.
	reply_handle:   vx.Handle,
	// The handle the request carried (dref's VMO), set by the transport;
	// HANDLE_NONE when it carried none. The transport's to close.
	request_handle: vx.Handle,
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
fid_find :: proc "contextless" (s: ^Server, fid: Fid) -> ^Fid_Entry {
	for &f in s.fids {
		if f.used && f.fid == fid {
			return &f
		}
	}
	return nil
}

@(private="file")
fid_new :: proc "contextless" (s: ^Server, fid: Fid) -> ^Fid_Entry {
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
now :: proc "contextless" (sh: ^Shared) -> i64 {
	return sh.now != nil ? sh.now() : 0
}

@(private="file")
file_live :: proc "contextless" (sh: ^Shared, o: ^Open_File) -> bool {
	return o.used && (o.fids != 0 || (o.holds != 0 && (sh.now == nil || now(sh) < o.hold_until)))
}

// Lets go of the owner's locks on node in [start, end): cut, shortened or
// split. False, with nothing changed, when a split finds no free slot.
@(private="file")
unlock :: proc "contextless" (sh: ^Shared, conn: ^Server, proc_id: u32, any_proc: bool, node: Node, start, end: u64) -> bool {
	free_slots := 0
	for &l in sh.locks {
		free_slots += int(!l.used)
	}
	for &l in sh.locks {
		if !l.used || l.node != node || l.conn != conn || (!any_proc && l.proc_id != proc_id) {
			continue
		}
		if l.end <= start || l.start >= end {
			continue
		}
		switch {
		case l.start < start && l.end > end: // the middle: two pieces
			if free_slots == 0 {
				return false
			}
			for &k in sh.locks {
				if !k.used {
					k = l
					k.start = end
					free_slots -= 1
					break
				}
			}
			l.end = start
		case l.start < start:
			l.end = start
		case l.end > end:
			l.start = end
		case:
			l.used = false
			free_slots += 1
		}
	}
	return true
}

@(private="file")
fid_drop :: proc "contextless" (s: ^Server, f: ^Fid_Entry) {
	remove := f.orclose
	if o := f.file; o != nil && s.shared != nil {
		remove = remove || (o.orclose && o.fids == 1) // its last fid
	}
	if remove && s.fs.remove != nil {
		_ = s.fs.remove(s.fs.ctx, f.node) // ORCLOSE; it may already be gone
	}
	if s.fs.clunk != nil {
		s.fs.clunk(s.fs.ctx, f.node, f.open)
	}
	if o := f.file; o != nil && s.shared != nil {
		if o.fids > 0 {
			o.fids -= 1
		}
		if o.fids == 0 && o.holds != 0 {
			o.hold_until = now(s.shared) + HOLD_TIME
		}
		if !file_live(s.shared, o) {
			o.used = false
		}
	}
	// POSIX: any close lets go, of a fid with an open file of its own or not
	// (a directory's; one opened when the table was full).
	if f.open && s.shared != nil {
		_ = unlock(s.shared, s, 0, true, f.node, 0, max(u64))
	}
	f^ = {}
}

// A new open file for a fid just opened: nil if there is no room.
@(private="file")
file_new :: proc "contextless" (sh: ^Shared, node: Node, mode: Open_Mode) -> ^Open_File {
	for &o in sh.files {
		if file_live(sh, &o) {
			continue
		}
		m := mode
		m.append = false
		o = {used = true, append = mode.append, mode = m, node = node, fids = 1}
		return &o
	}
	return nil
}

// The mode a file server is given, and a fid keeps: without the posix bits.
@(private="file")
plain_mode :: proc "contextless" (mode: Open_Mode) -> Open_Mode {
	m := mode
	m.append, m.join = false, false
	return m
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

@(private="file", require_results)
qid_of :: proc "contextless" (s: ^Server, node: Node) -> (Qid, vx.Status) {
	st: Stat
	e := s.fs.stat(s.fs.ctx, node, &st)
	return st.qid, e
}

// Opens a fid's node. A clone file moves the fid to the node it makes, as
// opening /net/tcp/clone moves it to the new conversation's ctl (upstream
// 02 §5).
@(private="file", require_results)
open_node :: proc "contextless" (s: ^Server, f: ^Fid_Entry, mode: Open_Mode) -> vx.Status {
	s.fs.open(s.fs.ctx, f.node, mode) or_return
	if s.fs.clone == nil {
		return .Ok
	}
	node, e := s.fs.clone(s.fs.ctx, f.node, mode)
	if e != .Ok {
		return e == .Err_Not_Found ? .Ok : e
	}
	qid: Qid
	if qid, e = qid_of(s, node); e != .Ok {
		if s.fs.clunk != nil {
			s.fs.clunk(s.fs.ctx, node, true) // opened, and let go at once
		}
		return e
	}
	if s.fs.clunk != nil {
		s.fs.clunk(s.fs.ctx, f.node, false)
	}
	f.node, f.qid = node, qid
	return .Ok
}

// A name a client may walk to, create or rename to: never empty, ".", or
// holding a '/'; and UTF-8 with no control characters (ADR-0013), so a server
// is safe from a client that does not use vx:ns.
@(private="file")
good_name :: proc "contextless" (n: string) -> bool {
	return len(n) > 0 && n != "." && str.index_byte(n, '/') < 0 && utf.is_name(n)
}

// A name something new may have: a good one, and not "..".
@(private="file")
new_name_ok :: proc "contextless" (n: string) -> bool {
	return good_name(n) && n != ".."
}

// Walks one step from node, keeping inside root.
@(private="file", require_results)
step :: proc "contextless" (s: ^Server, root, node: Node, name: string) -> (next: Node, e: vx.Status) {
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
read_dir :: proc "contextless" (s: ^Server, f: ^Fid_Entry, offset: u64, out: []u8) -> (count: u32, e: vx.Status) {
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

// Writes at the offset given, or at the open file's (OFFSET_CURRENT): its end
// if it appends, which is atomic, as the server does one request at a time.
@(private="file", require_results)
write :: proc "contextless" (s: ^Server, f: ^Fid_Entry, t: ^Msg) -> (count: u32, e: vx.Status) {
	o := s.shared != nil ? f.file : nil
	offset := t.offset
	if .Append in f.qid.type { // DMAPPEND: at the end, whatever the offset
		st: Stat
		s.fs.stat(s.fs.ctx, f.node, &st) or_return
		offset = st.length
	} else if offset == OFFSET_CURRENT {
		if o == nil {
			return 0, .Err_Invalid
		}
		offset = o.offset
		if o.append {
			st: Stat
			s.fs.stat(s.fs.ctx, f.node, &st) or_return
			offset = st.length
		}
	}
	count = s.fs.write(s.fs.ctx, f.node, offset, t.data) or_return
	if o != nil && t.offset == OFFSET_CURRENT {
		o.offset = offset + u64(count)
	}
	return count, .Ok
}

@(private="file")
locks_conflict :: proc "contextless" (l: ^Lock, conn: ^Server, proc_id: u32, node: Node, type: Lock_Type, start, end: u64) -> bool {
	return l.used && l.node == node && (l.conn != conn || l.proc_id != proc_id) && l.start < end && start < l.end && (type == .Write || l.type == .Write)
}

// Tlock and Tgetlock: POSIX's byte-range locks.
@(private="file", require_results)
serve_lock :: proc "contextless" (s: ^Server, f: ^Fid_Entry, t: ^Msg, r: ^Msg) -> vx.Status {
	sh := s.shared
	if sh == nil || !f.open {
		return .Err_Bad_State
	}
	start := t.start
	end := t.length != 0 ? t.start + t.length : max(u64)
	if t.length != 0 && end < start {
		return .Err_Range
	}
	if u8(t.lock_type) > u8(Lock_Type.Unlock) {
		return .Err_Invalid
	}
	if t.type == .Tgetlock {
		r^ = {
			type      = r.type,
			tag       = r.tag,
			lock_type = .Unlock,
			start     = t.start,
			length    = t.length,
			proc_id   = t.proc_id,
			client_id = t.client_id,
		}
		if t.lock_type == .Unlock {
			return .Ok
		}
		for &l in sh.locks {
			if !locks_conflict(&l, s, t.proc_id, f.node, t.lock_type, start, end) {
				continue
			}
			r.lock_type = l.type
			r.start = l.start
			r.length = l.end == max(u64) ? 0 : l.end - l.start
			r.proc_id = l.proc_id
			r.client_id = ""
			break
		}
		return .Ok
	}
	// A lock as the fid was opened for, as POSIX has it: reading for a read
	// lock, writing for a write lock.
	if (t.lock_type == .Read && f.mode.access == .Write) || (t.lock_type == .Write && !writes(f.mode)) {
		return .Err_Access
	}
	r.status = .Success
	if t.lock_type != .Unlock {
		for &l in sh.locks {
			if locks_conflict(&l, s, t.proc_id, f.node, t.lock_type, start, end) {
				r.status = .Blocked // the client waits and asks again (F_SETLKW)
				return .Ok
			}
		}
	}
	// The room it needs, found before anything changes, so an error leaves the
	// caller's locks as they were: a slot for the new lock, and one more if it
	// falls inside one of its own, which then splits in two.
	free_slots := 0
	need := t.lock_type != .Unlock ? 1 : 0
	for &l in sh.locks {
		free_slots += int(!l.used)
		if l.used && l.node == f.node && l.conn == s && l.proc_id == t.proc_id && l.start < start && l.end > end {
			need += 1
		}
	}
	if free_slots < need || !unlock(sh, s, t.proc_id, false, f.node, start, end) { // its own, replaced
		r.status = .Error
		return .Ok
	}
	if t.lock_type == .Unlock {
		return .Ok
	}
	for &l in sh.locks {
		if !l.used {
			l = {
				used    = true,
				type    = t.lock_type,
				node    = f.node,
				start   = start,
				end     = end,
				conn    = s,
				proc_id = t.proc_id,
			}
			return .Ok
		}
	}
	r.status = .Error
	return .Ok
}

// Tjoin: a new fid, open on the open file a token names.
@(private="file", require_results)
serve_join :: proc "contextless" (s: ^Server, t: ^Msg, r: ^Msg) -> vx.Status {
	sh := s.shared
	if sh == nil {
		return .Err_Unsupported
	}
	o: ^Open_File
	for &c in sh.files {
		if !file_live(sh, &c) || !c.shared || c.holds == 0 || (sh.now != nil && now(sh) >= c.hold_until) {
			continue
		}
		diff: u8 // the whole token, every time
		for b, k in c.token {
			diff |= b ~ t.token[k]
		}
		if diff == 0 {
			o = &c
			break
		}
	}
	if o == nil {
		return .Err_Not_Found
	}
	n := fid_new(s, t.newfid)
	if n == nil {
		return .Err_Bad_State
	}
	mode := o.mode
	mode.trunc, mode.rclose, mode.join = false, false, true
	if e := s.fs.open(s.fs.ctx, o.node, mode); e != .Ok {
		n^ = {}
		return e
	}
	qid, e := qid_of(s, o.node)
	if e != .Ok {
		if s.fs.clunk != nil {
			s.fs.clunk(s.fs.ctx, o.node, true) // the open just made, let go
		}
		n^ = {}
		return e
	}
	o.holds -= 1
	o.fids += 1
	n.qid = qid
	n.node, n.root = o.node, o.node
	n.open = true
	n.mode = o.mode
	n.file = o
	r.qid = n.qid
	r.iounit = s.msize - IOHDRSZ
	return .Ok
}

// Tshare, Tseek and Tdesc: an open file shared between connections.
@(private="file", require_results)
serve_share :: proc "contextless" (s: ^Server, f: ^Fid_Entry, t: ^Msg, r: ^Msg) -> vx.Status {
	sh := s.shared
	if sh == nil {
		return .Err_Unsupported
	}
	o := f.file
	if o == nil {
		return .Err_Bad_State // not open, or a directory
	}
	#partial switch t.type {
	case .Tshare:
		if !sh.random.seeded {
			return .Err_Unsupported // no token that cannot be guessed
		}
		if sh.now != nil && now(sh) >= o.hold_until {
			o.holds = 0 // run out, unused
		}
		if t.holds == 0 || t.holds > MAX_HOLDS || o.holds + t.holds > MAX_HOLDS {
			return .Err_Range
		}
		// A new token whenever none is outstanding (its holds used or run
		// out), so a token once given is never good again after its holds
		// are gone.
		if !o.shared || o.holds == 0 {
			drbg.read(&sh.random, o.token[:])
		}
		o.shared = true
		o.holds += t.holds
		o.hold_until = now(sh) + HOLD_TIME
		r.token = o.token
		return .Ok
	case .Tseek:
		base: i64
		#partial switch t.whence {
		case .Current:
			base = i64(o.offset)
		case .End:
			st: Stat
			s.fs.stat(s.fs.ctx, o.node, &st) or_return
			base = i64(st.length)
		}
		at, overflow := intrinsics.overflow_add(base, i64(t.offset))
		if u8(t.whence) > u8(Whence.End) || overflow || at < 0 {
			return .Err_Invalid
		}
		o.offset = u64(at)
		r.offset = o.offset
		return .Ok
	case .Tdesc:
		o.append = .Append in t.desc_flags
		return .Ok
	}
	return .Err_Unsupported
}

// A stat's mode as POSIX has it, for Rgetattr.
@(private="file")
posix_mode :: proc "contextless" (mode: u32) -> u32 {
	type := S_IFREG
	if mode & DMDIR != 0 {
		type = S_IFDIR
	}
	if mode & DMSYMLINK != 0 {
		type = S_IFLNK
	}
	if mode & DMDEVICE != 0 {
		type = S_IFCHR
	}
	return type | mode & 0o7777
}

// The posix and xattr extensions' messages: each only once its extension is
// negotiated.
@(private="file", require_results)
serve_posix :: proc "contextless" (s: ^Server, t: ^Msg, r: ^Msg) -> vx.Status {
	xattr := t.type == .Tgetattr || t.type == .Tsetattr
	linux_has := t.type != .Tshare && t.type != .Tjoin && t.type != .Tseek && t.type != .Tdesc
	dotl := s.dialect == .P9_2000L && linux_has // 9P2000.L's own messages, which these extensions borrow
	if !dotl && (xattr ? Extension.Xattr : Extension.Posix) not_in s.extensions {
		return .Err_Unsupported
	}
	if t.type == .Tjoin {
		return serve_join(s, t, r)
	}
	f := fid_find(s, t.fid)
	if f == nil {
		return .Err_Bad_Handle
	}
	#partial switch t.type {
	case .Tlock, .Tgetlock:
		return serve_lock(s, f, t, r)
	case .Tshare, .Tseek, .Tdesc:
		return serve_share(s, f, t, r)
	case .Tgetattr:
		st: Stat
		s.fs.stat(s.fs.ctx, f.node, &st) or_return
		r.attr = {
			valid        = GETATTR_BASIC,
			qid          = st.qid,
			mode         = posix_mode(st.mode),
			nlink        = st.mode & DMDIR != 0 ? 2 : 1,
			size         = st.length,
			blksize      = 4096,
			blocks       = (st.length + 511) / 512,
			atime_sec    = u64(st.atime),
			mtime_sec    = u64(st.mtime),
			ctime_sec    = u64(st.mtime),
			data_version = u64(st.qid.version),
		}
		return .Ok
	case .Tsetattr:
		return s.fs.setattr != nil ? s.fs.setattr(s.fs.ctx, f.node, &t.setattr) : .Err_Access
	case .Trenameat:
		to := fid_find(s, t.newfid)
		if to == nil {
			return .Err_Bad_Handle
		}
		if .Dir not_in f.qid.type || .Dir not_in to.qid.type || !new_name_ok(t.name) || !new_name_ok(t.name2) {
			return .Err_Invalid
		}
		if s.fs.rename == nil {
			return .Err_Access
		}
		return s.fs.rename(s.fs.ctx, f.node, t.name, to.node, t.name2)
	case .Tsymlink:
		if .Dir not_in f.qid.type || !new_name_ok(t.name) {
			return .Err_Invalid
		}
		if s.fs.symlink == nil {
			return .Err_Access
		}
		node := s.fs.symlink(s.fs.ctx, f.node, t.name, t.name2) or_return
		qid, e := qid_of(s, node)
		r.qid = qid
		if s.fs.clunk != nil {
			s.fs.clunk(s.fs.ctx, node, false) // no fid holds it, whether its qid came or not
		}
		return e
	case .Treadlink:
		if s.fs.readlink == nil {
			return .Err_Invalid
		}
		target, e := s.fs.readlink(s.fs.ctx, f.node)
		r.name2 = target
		return e
	case .Tfsync:
		return s.fs.fsync != nil ? s.fs.fsync(s.fs.ctx, f.node) : .Ok
	}
	return .Err_Unsupported // Tlink: no server has hard links
}

// The file server's attach, told who attaches if it asks to be.
@(private="file", require_results)
attach :: proc "contextless" (s: ^Server, aname, uname: string) -> (root: Node, st: vx.Status) {
	if s.fs.attach_as != nil {
		return s.fs.attach_as(s.fs.ctx, aname, uname)
	}
	return s.fs.attach(s.fs.ctx, aname)
}

// Tmap: only on a fid open for reading, and for writing too if the mapping
// writes, as POSIX's mmap asks of a descriptor.
@(private="file", require_results)
serve_map :: proc "contextless" (s: ^Server, t: ^Msg, r: ^Msg) -> vx.Status {
	if .Map not_in s.extensions || s.fs.map_range == nil {
		return .Err_Unsupported
	}
	f := fid_find(s, t.fid)
	if f == nil {
		return .Err_Bad_Handle
	}
	if !f.open || .Dir in f.qid.type || f.mode.access == .Write {
		return .Err_Access
	}
	if .Write in t.prot && f.mode.access != .Rdwr {
		return .Err_Access
	}
	known := Prot{.Read, .Write, .Exec}
	write_exec := Prot{.Write, .Exec}
	if t.length == 0 || transmute(u32)t.prot &~ transmute(u32)known != 0 || t.prot >= write_exec {
		return .Err_Invalid // W^X (upstream 01 §11)
	}
	if _, overflow := intrinsics.overflow_add(t.offset, t.length); overflow {
		return .Err_Range
	}
	m := s.fs.map_range(s.fs.ctx, f.node, t.offset, t.length, t.prot) or_return
	s.reply_handle = m.vmo
	r.offset, r.length = m.vmo_offset, m.avail
	return .Ok
}

// Treadref and Twriteref: Tread and Twrite, open files' offsets and
// appending too, with the data in the request's VMO.
@(private="file", require_results)
serve_dref :: proc "contextless" (s: ^Server, t: ^Msg, r: ^Msg) -> vx.Status {
	read := t.type == .Treadref
	op := read ? s.fs.read_ref : s.fs.write_ref
	if .Dref not_in s.extensions || op == nil {
		return .Err_Unsupported
	}
	f := fid_find(s, t.fid)
	if f == nil {
		return .Err_Bad_Handle
	}
	if !f.open || .Dir in f.qid.type {
		return .Err_Access
	}
	if read ? f.mode.access == .Write : !writes(f.mode) {
		return .Err_Access
	}
	if s.request_handle == vx.HANDLE_NONE {
		return .Err_Invalid // no VMO came with it
	}
	o := s.shared != nil ? f.file : nil
	offset := t.offset
	if offset == OFFSET_CURRENT {
		if o == nil {
			return .Err_Invalid
		}
		offset = o.offset
		if !read && o.append {
			st: Stat
			s.fs.stat(s.fs.ctx, f.node, &st) or_return
			offset = st.length
		}
	}
	count := op(s.fs.ctx, f.node, offset, s.request_handle, t.roffset, t.count) or_return
	if o != nil && t.offset == OFFSET_CURRENT {
		o.offset = offset + u64(count)
	}
	r.count = count
	return .Ok
}

// Twstat (stat(5)): the entry's fields that are not "don't touch" (all
// ones, or an empty string) are changed, all of them or none:
//   - name: a rename in the file's own directory (not of an attach root);
//   - length, mode (its permission bits; DMDIR as it is), mtime and atime:
//     the file server's setattr;
//   - type, dev, qid and muid may not change, nor uid (no chown in 9P);
//     gid only to what it is; DMAPPEND and DMEXCL only at create.
// The rename goes first, and back if setattr then fails. Nothing to change
// asks the file to be written out (fsync), as 9P has it.
@(private="file", require_results)
serve_wstat :: proc "contextless" (s: ^Server, f: ^Fid_Entry, t: ^Msg) -> vx.Status {
	w, cur: Stat
	if stat_decode(t.stat, &w) != .Ok {
		return .Err_Invalid
	}
	s.fs.stat(s.fs.ctx, f.node, &cur) or_return
	old_buf: [256]u8 // the name, kept: the file server's strings last until its next call
	if len(cur.name) >= len(old_buf) {
		return .Err_Range
	}
	old := string(old_buf[:copy(old_buf[:], cur.name)])
	same_gid := len(w.gid) == 0 || w.gid == cur.gid
	same_uid := len(w.uid) == 0 || w.uid == cur.uid
	untouched := stat_untouched()
	keep_qid := w.qid == untouched.qid || w.qid == cur.qid
	if (w.type != max(u16) && w.type != cur.type) || (w.dev != max(u32) && w.dev != cur.dev) || !keep_qid || len(w.muid) > 0 {
		return .Err_Invalid
	}
	if !same_uid || !same_gid {
		return .Err_Access
	}
	a: Setattr
	if w.mode != max(u32) {
		if (w.mode ~ cur.mode) & DMDIR != 0 {
			return .Err_Invalid
		}
		if (w.mode ~ cur.mode) & (DMAPPEND | DMEXCL | DMSYMLINK | DMDEVICE) != 0 {
			return .Err_Unsupported
		}
		a.valid += {.Mode}
		a.mode = w.mode & 0o777
	}
	if w.length != max(u64) {
		dir := cur.mode & DMDIR != 0
		if dir && w.length != cur.length {
			return .Err_Invalid
		}
		if !dir {
			a.valid += {.Size}
			a.size = w.length
		}
	}
	if w.mtime != max(u32) {
		a.valid += {.Mtime, .Mtime_Set}
		a.mtime_sec = u64(w.mtime)
	}
	if w.atime != max(u32) {
		a.valid += {.Atime, .Atime_Set}
		a.atime_sec = u64(w.atime)
	}
	rename := len(w.name) > 0 && w.name != old
	if !rename && a.valid == {} {
		return s.fs.fsync != nil ? s.fs.fsync(s.fs.ctx, f.node) : .Ok
	}
	if (a.valid != {} && s.fs.setattr == nil) || (rename && s.fs.rename == nil) {
		return .Err_Access
	}
	dir: Node
	if rename {
		if f.node == f.root {
			return .Err_Access
		}
		if !new_name_ok(w.name) {
			return .Err_Invalid
		}
		dir = s.fs.parent(s.fs.ctx, f.node) or_return
		if there, we := s.fs.walk(s.fs.ctx, dir, w.name); we == .Ok { // 9P's rename replaces nothing
			if s.fs.clunk != nil {
				s.fs.clunk(s.fs.ctx, there, false)
			}
			return .Err_Exists
		}
		s.fs.rename(s.fs.ctx, dir, old, dir, w.name) or_return
	}
	if a.valid != {} {
		if e := s.fs.setattr(s.fs.ctx, f.node, &a); e != .Ok {
			if rename {
				_ = s.fs.rename(s.fs.ctx, dir, w.name, dir, old) // none of it, then
			}
			return e
		}
	}
	return .Ok
}

// --- 9P2000.L (upstream's M6 step 6d4c2) ---
//
// Linux's dialect, for its `mount -t 9p` and the servers it speaks to. Its
// Tlopen and Tlcreate are Topen and Tcreate with Linux's flags (serve turns
// them into those); its Tgetattr, Tsetattr, Trenameat, Tsymlink, Treadlink,
// Tfsync, Tlock and Tgetlock are the posix and xattr extensions' (which
// borrowed them); the rest are here. Errors go back as Rlerror, an errno.

// A 9P open mode from Linux's open flags.
@(private="file")
mode_of_flags :: proc "contextless" (flags: u32) -> (mode: Open_Mode) {
	switch flags & L_O_ACCMODE {
	case 1:
		mode.access = .Write
	case 2:
		mode.access = .Rdwr
	}
	mode.trunc = flags & L_O_TRUNC != 0
	return // O_APPEND: Linux's client writes at the end itself
}

@(private="file")
dirent_type :: proc "contextless" (mode: u32) -> u8 {
	switch {
	case mode & DMDIR != 0:
		return DT_DIR
	case mode & DMSYMLINK != 0:
		return DT_LNK
	case mode & DMDEVICE != 0:
		return DT_CHR
	}
	return DT_REG
}

// Rreaddir's entries from the cookie (an entry's index): qid[13] offset[8]
// type[1] name[s], each entry's offset the next one's cookie.
@(private="file", require_results)
readdir_l :: proc "contextless" (s: ^Server, f: ^Fid_Entry, cookie: u64, out: []u8) -> (count: u32, e: vx.Status) {
	used := 0
	for i := cookie; i < u64(max(u32)); i += 1 {
		child, re := s.fs.readdir(s.fs.ctx, f.node, u32(i))
		if re == .Err_Not_Found {
			break
		}
		re or_return
		st: Stat
		s.fs.stat(s.fs.ctx, child, &st) or_return
		o := str.Buf{buf = out[used:]}
		dirent_put(&o, st.qid, i + 1, dirent_type(st.mode), st.name)
		if o.failed {
			if used == 0 {
				return 0, .Err_Too_Small // not even one entry fits the count asked for
			}
			break
		}
		used += o.len
	}
	return u32(used), .Ok
}

// Tmkdir, Tunlinkat, Trename, Treaddir and Tstatfs.
@(private="file", require_results)
serve_l :: proc "contextless" (s: ^Server, t: ^Msg, r: ^Msg, resp: []u8) -> vx.Status {
	f := fid_find(s, t.fid)
	if f == nil {
		return .Err_Bad_Handle
	}
	#partial switch t.type {
	case .Tmkdir:
		if .Dir not_in f.qid.type || !new_name_ok(t.name) {
			return .Err_Invalid
		}
		if s.fs.create == nil {
			return .Err_Access
		}
		node := s.fs.create(s.fs.ctx, f.node, t.name, DMDIR | (t.lmode & 0o777), OREAD) or_return
		qid, e := qid_of(s, node)
		r.qid = qid
		if s.fs.clunk != nil {
			s.fs.clunk(s.fs.ctx, node, true) // the create opened it; no fid holds it
		}
		return e
	case .Tunlinkat:
		if .Dir not_in f.qid.type || !new_name_ok(t.name) {
			return .Err_Invalid
		}
		if s.fs.remove == nil {
			return .Err_Access
		}
		child := s.fs.walk(s.fs.ctx, f.node, t.name) or_return
		st: Stat
		e := s.fs.stat(s.fs.ctx, child, &st)
		if e == .Ok {
			dir := st.mode & DMDIR != 0
			if dir != (t.lflags & L_AT_REMOVEDIR != 0) {
				e = dir ? .Err_Access : .Err_Not_Found // EISDIR, ENOTDIR as errno has them
			} else {
				e = s.fs.remove(s.fs.ctx, child)
			}
		}
		if s.fs.clunk != nil {
			s.fs.clunk(s.fs.ctx, child, false)
		}
		return e
	case .Trename:
		to := fid_find(s, t.newfid)
		if to == nil {
			return .Err_Bad_Handle
		}
		if .Dir not_in to.qid.type || !new_name_ok(t.name) {
			return .Err_Invalid
		}
		if s.fs.rename == nil || f.node == f.root {
			return .Err_Access
		}
		st: Stat
		s.fs.stat(s.fs.ctx, f.node, &st) or_return
		old_buf: [256]u8
		if len(st.name) >= len(old_buf) {
			return .Err_Range
		}
		old := string(old_buf[:copy(old_buf[:], st.name)])
		dir := s.fs.parent(s.fs.ctx, f.node) or_return
		return s.fs.rename(s.fs.ctx, dir, old, to.node, t.name)
	case .Treaddir:
		if !f.open || .Dir not_in f.qid.type {
			return .Err_Access
		}
		if len(resp) < RREAD_HDR {
			return .Err_Too_Small
		}
		room := min(s.msize - IOHDRSZ, u32(min(len(resp) - RREAD_HDR, int(max(u32)))))
		out := resp[RREAD_HDR:][:min(t.count, room)]
		count := readdir_l(s, f, t.offset, out) or_return
		r.data = out[:count]
		return .Ok
	case .Tstatfs: // what Linux's statfs asks for; the file servers keep no such numbers
		r.statfs = {
			type    = 0x01021997, // V9FS_MAGIC
			bsize   = 4096,
			namelen = 255,
		}
		return .Ok
	}
	return .Err_Unsupported
}

// Handles one request (one whole message) and writes the reply into resp.
// Returns the reply's length with .Reply; otherwise the length is 0.
@(require_results)
serve :: proc "contextless" (s: ^Server, req: []u8, resp: []u8) -> (reply_len: int, res: Serve_Result) {
	t, r: Msg
	dotl := s.dialect == .P9_2000L
	if decode(req, &t) != .Ok {
		// A .L request this server does not know (Txattrwalk, Tmknod):
		// Rlerror, as Linux's client expects, not a hang-up.
		whole := len(req) >= 7 && (u64(req[0]) | u64(req[1]) << 8 | u64(req[2]) << 16 | u64(req[3]) << 24) == u64(len(req))
		if !dotl || !whole || req[4] % 2 != 0 || known(Type(req[4])) {
			return 0, .Hang_Up
		}
		r = {type = .Rlerror, tag = u16(req[5]) | u16(req[6]) << 8, ecode = status_errno(.Err_Unsupported)} // EOPNOTSUPP
		if reply_len = encode(&r, resp); reply_len == 0 {
			return 0, .Hang_Up
		}
		return reply_len, .Reply
	}
	if u8(t.type) % 2 != 0 || t.type == .Rerror || t.type == .Rlerror {
		return 0, .Hang_Up // only T-messages come to a server
	}
	r.type = Type(u8(t.type) + 1)
	r.tag = t.tag
	if dotl && t.type == .Tlopen { // Topen, in Linux's words; Rlopen is Ropen's shape
		t.type, t.mode = .Topen, mode_of_flags(t.lflags)
	} else if dotl && t.type == .Tlcreate { // Tcreate, likewise; a file, never a directory (Tmkdir)
		t.type, t.perm, t.mode = .Tcreate, t.lmode & 0o777, mode_of_flags(t.lflags)
	}
	e := vx.Status.Ok
	f: ^Fid_Entry

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
			} else if f.node, e = attach(s, t.aname, t.uname); e == .Ok {
				r.qid, e = qid_of(s, f.node)
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
					qid, se = qid_of(s, next)
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
				s.fs.clunk(s.fs.ctx, f.node, false) // walked fids are never open
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
			if t.mode.rclose && s.fs.remove == nil {
				e = .Err_Access // nothing here is removed
				break
			}
			if t.type == .Tcreate {
				node: Node
				if .Dir not_in f.qid.type || !good_name(t.name) || t.name == ".." {
					e = .Err_Invalid
				} else if s.fs.create == nil {
					e = .Err_Access
				} else {
					node, e = s.fs.create(s.fs.ctx, f.node, t.name, t.perm, plain_mode(t.mode))
				}
				if e == .Ok {
					if s.fs.clunk != nil {
						s.fs.clunk(s.fs.ctx, f.node, false)
					}
					f.node = node
					qid: Qid
					if qid, e = qid_of(s, node); e == .Ok {
						f.qid = qid
					}
				}
			} else {
				if .Dir in f.qid.type && (writes(t.mode) || t.mode.trunc) {
					e = .Err_Access // directories are only read
				} else {
					e = open_node(s, f, plain_mode(t.mode))
				}
			}
			if e != .Ok {
				break
			}
			if .Posix in s.extensions && s.shared != nil && .Dir not_in f.qid.type {
				f.file = file_new(s.shared, f.node, t.mode)
				if f.file == nil { // the server's table of open files is full: the open fails, now
					if s.fs.clunk != nil {
						s.fs.clunk(s.fs.ctx, f.node, true)
					}
					e = .Err_No_Memory
					break
				}
			}
			f.open = true
			f.mode = plain_mode(t.mode)
			if t.mode.rclose && f.file != nil {
				f.file.orclose = true // the open file's, which forks share
			} else {
				f.orclose = t.mode.rclose
			}
			r.qid = f.qid
			r.iounit = s.msize - IOHDRSZ
		case .Tread:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
				break
			}
			if !f.open || f.mode.access == .Write {
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
			o := s.shared != nil ? f.file : nil
			offset := t.offset
			if offset == OFFSET_CURRENT {
				if o == nil {
					e = .Err_Invalid // no open file keeps an offset for it
					break
				}
				offset = o.offset
			}
			if .Dir in f.qid.type {
				count, e = read_dir(s, f, offset, out)
			} else {
				count, e = s.fs.read(s.fs.ctx, f.node, offset, out)
			}
			if e == .Ok && count > u32(len(out)) {
				e = .Err_Range // the file server claims more than it was given room for
				break
			}
			if e == .Ok && o != nil && t.offset == OFFSET_CURRENT {
				o.offset = offset + u64(count)
			}
			r.data = out[:count] if e == .Ok else nil
		case .Twrite:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
			} else if !f.open || !writes(f.mode) || s.fs.write == nil {
				e = .Err_Access
			} else if t.count > s.msize - IOHDRSZ {
				e = .Err_Too_Small
			} else {
				r.count, e = write(s, f, &t)
			}
		case .Tclunk, .Tremove:
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
				break
			}
			if t.type == .Tremove {
				e = s.fs.remove != nil ? s.fs.remove(s.fs.ctx, f.node) : .Err_Access
				f.orclose = false // removed already, or not to be
				if f.file != nil && s.shared != nil {
					f.file.orclose = false
				}
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
			if f = fid_find(s, t.fid); f == nil {
				e = .Err_Bad_Handle
			} else {
				e = serve_wstat(s, f, &t)
			}
		case .Tgetattr, .Tsetattr, .Trenameat, .Tsymlink, .Treadlink, .Tfsync, .Tlink, .Tlock, .Tgetlock, .Tshare, .Tjoin, .Tseek, .Tdesc:
			e = serve_posix(s, &t, &r)
		case .Tmap:
			e = serve_map(s, &t, &r)
		case .Treadref, .Twriteref:
			e = serve_dref(s, &t, &r)
		case .Tmkdir, .Tunlinkat, .Trename, .Treaddir, .Tstatfs:
			e = dotl ? serve_l(s, &t, &r, resp) : .Err_Unsupported
		case:
			return 0, .Hang_Up
		}
	}
	if e == .Err_Should_Wait && (t.type == .Tread || t.type == .Twrite || t.type == .Topen) {
		return 0, .Defer
	}
	if e != .Ok && s.dialect == .P9_2000L {
		r = {type = .Rlerror, tag = t.tag, ecode = status_errno(e)}
	} else if e != .Ok {
		r = {type = .Rerror, tag = t.tag, ename = error_text(e)}
	}
	if reply_len = encode(&r, resp); reply_len == 0 {
		return 0, .Hang_Up
	}
	return reply_len, .Reply
}
