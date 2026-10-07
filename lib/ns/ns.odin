// A process's namespace, in its own address space (upstream 02 §2, D4). It
// builds for the target and the host, and sees servers only as p9 Clients.
//
// The table holds mount points, each a union: an ordered list of members,
// each a directory on some connection (a fid this table owns, never opened,
// only cloned). mount attaches a connection and adds its root; bind resolves
// a path and adds what it finds. Flags say where the new member goes:
// replacing the union (none), after it (.After, -a), or before it (.Before,
// -b); .Create (-c) marks the member that takes creates.
//
// A mount point is found by identity, as in Plan 9 (9front's findmount,
// upstream ADR-0009), not by the path it was made at: the connection and qid
// of the directory it was made on, so it shows through every name that
// reaches that directory. Resolution cleans the path lexically first, so ".."
// never climbs out of a bind (Plan 9's rule), then walks from the root, a
// Twalk of the names left at a time; each Twalk returns a qid per name, and
// where one is a mount point's, the walk goes on from that union with the
// names after it. A mount point may also be a new name in a directory
// (/n/host, which Plan 9's mntgen would provide): it is found by that
// directory and the name. Confinement is not this table's job: it is the
// connections' (02 §2). A relative name is joined to the process's current
// directory (the getwd hook, ADR-0017) before it is cleaned.
//
// ns output (print) is namespace(6), and replays: one mount or bind line per
// member, in the order the members were added, since each may resolve paths
// that earlier ones made; each union's first member to be replayed without a
// flag, the rest with -b or -a for where they go among those replayed before
// them. newns.odin reads the same form.
//
// A namespace may belong to a group (ADR-0009; nsd.odin is nsd's protocol):
// its refresh and publish hooks keep the table in step with the group's.
// Building a namespace from a spawn message, and the group's half that needs
// the runtime, sit on top of this package (lib/procns). dial.odin adds 9P
// servers over TCP, reached through the namespace's own /net.
package ns

import "abi:vx"
import "vx:p9"
import "vx:str"
import "vx:utf"

MAX_PATH :: 256
MAX_ENTRIES :: 32
MAX_MEMBERS :: 8
MAX_CONNS :: 16 // the POSIX template has 7, and fsd's branches come on top
MAX_SRC :: 64
MAX_DEPTH :: 64 // names in a path

// As a u8, the same bits as upstream's flags: -a is 1, -b is 2, -c is 4. No
// flags at all replaces the union.
Flag :: enum u8 {
	After  = 0, // -a
	Before = 1, // -b
	Create = 2, // -c
}
Flags :: bit_set[Flag;u8]

REPLACE :: Flags{}

Conn :: struct {
	client:    ^p9.Client, // nil: the slot is free
	connector: vx.Handle, // where it came from, to give children their own (or HANDLE_NONE)
	src:       [dynamic; MAX_SRC]u8, // "/srv/bootfs", for ns output
}

Member :: struct {
	conn:    u8,
	flags:   Flags, // .Create only
	mounted: bool, // a mount (src and aname) rather than a bind (the path it came from)
	fid:     p9.Fid,
	qid:     u64, // the qid path of the directory its fid is: walks from it check mount points against it
	from:    [dynamic; MAX_PATH]u8, // bind: the path; mount: the aname
	seq:     u32, // when it was added: ns output and children replay members in this order
}

// What a mount point is: the root, a directory (a connection and its qid),
// or a new name in a directory (that directory, and the last component of
// the entry's path). In a union directory, the directory is its first member.
Id :: enum u8 {
	Root,
	Object,
	Name,
}

Entry :: struct {
	path:    [dynamic; MAX_PATH]u8, // where it was made, for ns output; empty: the slot is free
	id:      Id,
	id_conn: u8, // .Object, .Name: the connection
	id_qid:  u64, // .Object: the directory's qid path; .Name: the directory the name is in
	members: [dynamic; MAX_MEMBERS]Member,
}

// All zeroes is an empty namespace of its own.
Namespace :: struct {
	conns:    [MAX_CONNS]Conn,
	entries:  [MAX_ENTRIES]Entry,
	next_seq: u32,
	// Called when unmount leaves a connection with no members, after its fids
	// are clunked; the connection's slot is free once it returns. May be nil.
	release:  proc "contextless" (c: ^p9.Client, connector: vx.Handle),
	// A namespace group's (lib/procns and nsd), or nil for a namespace of its
	// own. refresh brings the table up to the group's, before a name is
	// resolved; publish tells the group the table has changed, adding
	// connection new_conn if it is not MAX_CONNS, and answers Err_Bad_State
	// if the group moved on meanwhile: the change is then made again, after a
	// refresh.
	refresh:  proc "contextless" (ns: ^Namespace),
	publish:  proc "contextless" (ns: ^Namespace, new_conn: u8) -> vx.Status,
	quiet:    bool, // a refresh is replaying the group's table: no hooks
	// The process's current directory (ADR-0017, upstream's ADR-0039;
	// vx:rt's getwd), which a relative name is resolved against: copied into
	// buf, a slice of it, or "". Nil: a relative name is refused (host tests).
	getwd:    proc "contextless" (buf: []u8) -> string,
	// A name the process serves itself, not a 9P server: /fd/N (ADR-0018,
	// upstream's ADR-0040; vx:procns's). Err_Not_Found for any other, which
	// resolves as usual. Nil: none (host tests).
	open_dev: proc "contextless" (ns: ^Namespace, path: string, mode: p9.Open_Mode, f: ^File) -> vx.Status,
}

@(private="file")
catch_up :: proc "contextless" (ns: ^Namespace) {
	if ns.refresh != nil && !ns.quiet {
		ns.refresh(ns)
	}
}

// Cleans an absolute path lexically into out: no empty, "." or ".."
// components, and ".." above the root is the root. Returns the cleaned path,
// a slice of out, or "" for a relative path, one that does not fit, or one
// holding a name ADR-0013 refuses (not UTF-8, or with a control character).
clean :: proc "contextless" (path: string, out: []u8) -> string {
	if len(path) == 0 || path[0] != '/' || len(out) < 2 {
		return ""
	}
	n := 0
	out[n] = '/'
	n += 1
	rest := path
	for name in str.split_iterator(&rest, '/') {
		if len(name) == 0 || name == "." {
			continue
		}
		if !utf.is_name(name) {
			return "" // UTF-8, no control characters (ADR-0013)
		}
		if name == ".." {
			for n > 1 && out[n - 1] != '/' {
				n -= 1
			}
			if n > 1 {
				n -= 1 // the slash before the component
			}
			continue
		}
		if n > 1 {
			if n == len(out) {
				return ""
			}
			out[n] = '/'
			n += 1
		}
		if len(name) > len(out) - n {
			return ""
		}
		copy(out[n:], name)
		n += len(name)
	}
	return string(out[:n])
}

// A name as an absolute, clean path (clean's): a relative one joined to the
// current directory first (ADR-0017), its ".." cleaned away against it, as
// 9front's ".." follows its dot's name (chan.c, fixdotdotname). "" as clean
// gives it, or with no current directory to resolve against.
@(private="file")
clean_name :: proc "contextless" (ns: ^Namespace, path: string, out: []u8) -> string {
	if len(path) == 0 || path[0] == '/' {
		return clean(path, out)
	}
	joined: [2 * MAX_PATH]u8
	wd := ns.getwd != nil ? ns.getwd(joined[:MAX_PATH - 1]) : ""
	if len(wd) == 0 || len(wd) + 1 + len(path) > len(joined) {
		return ""
	}
	n := len(wd)
	joined[n] = '/'
	n += 1
	n += copy(joined[n:], path)
	return clean(string(joined[:n]), out)
}

// The path an entry was made at; "" for a free slot.
entry_path :: proc "contextless" (e: ^Entry) -> string {
	return string(e.path[:])
}

// What a member came from, as ns output and unmount name it: a mount's
// source, or a bind's path.
member_source :: proc "contextless" (ns: ^Namespace, m: ^Member) -> string {
	if m.mounted {
		return string(ns.conns[m.conn].src[:])
	}
	return string(m.from[:])
}

@(private="file")
exact :: proc "contextless" (ns: ^Namespace, path: string) -> ^Entry {
	for &e in ns.entries {
		if len(e.path) > 0 && entry_path(&e) == path {
			return &e
		}
	}
	return nil
}

// The last component of a cleaned path ("" for "/").
@(private="file")
last_name :: proc "contextless" (path: string) -> string {
	at := len(path)
	for at > 0 && path[at - 1] != '/' {
		at -= 1
	}
	return path[at:]
}

@(private="file")
root_entry :: proc "contextless" (ns: ^Namespace) -> ^Entry {
	for &e in ns.entries {
		if len(e.path) > 0 && e.id == .Root {
			return &e
		}
	}
	return nil
}

// The mount point that is directory qid on connection conn, if any.
@(private="file")
find_object :: proc "contextless" (ns: ^Namespace, conn: u8, qid: u64) -> ^Entry {
	for &e in ns.entries {
		if len(e.path) > 0 && e.id == .Object && e.id_conn == conn && e.id_qid == qid {
			return &e
		}
	}
	return nil
}

// The mount point that is the new name in directory (conn, qid), if any.
@(private="file")
find_name :: proc "contextless" (ns: ^Namespace, conn: u8, qid: u64, name: string) -> ^Entry {
	for &e in ns.entries {
		if len(e.path) > 0 && e.id == .Name && e.id_conn == conn && e.id_qid == qid && last_name(entry_path(&e)) == name {
			return &e
		}
	}
	return nil
}

// A cleaned path's names, in names; ok is false if there are too many.
@(private="file")
split :: proc "contextless" (path: string, names: ^[MAX_DEPTH]string) -> (n: int, ok: bool) {
	rest := path
	for name in str.split_iterator(&rest, '/') {
		if len(name) == 0 {
			continue
		}
		if n == MAX_DEPTH {
			return n, false
		}
		names[n] = name
		n += 1
	}
	return n, true
}

// Where a resolution ended: a fid (the caller's to clunk) on a connection,
// with the qid path of what it reached; and the mount point it is, if it is
// one (the walk ended exactly on it).
@(private="file")
At :: struct {
	conn:  u8,
	fid:   p9.Fid,
	qid:   u64,
	entry: ^Entry,
}

// Walks names[i^:] from fid (conn, at qid) on, checking each name reached
// against the mount points. Returns done with out filled when it reaches the
// last name; or jump, a mount point, with i moved past what led there; or the
// error that stopped it. A fid this walk made is clunked unless returned.
@(private="file", require_results)
walk_on :: proc "contextless" (ns: ^Namespace, conn: u8, fid: p9.Fid, qid: u64, names: []string, i: ^int) -> (jump: ^Entry, done: bool, out: At, st: vx.Status) {
	c := ns.conns[conn].client
	cur, cur_qid := fid, qid
	owned := false // cur is a fid this walk made
	for {
		if hit := find_name(ns, conn, cur_qid, names[i^]); hit != nil { // a new name mounted here
			i^ += 1
			jump = hit
			break
		}
		count := min(len(names) - i^, p9.MAXWELEM)
		qids: [p9.MAXWELEM]p9.Qid
		next, got, made, e := p9.client_walk_names(c, cur, names[i^:][:count], &qids)
		if e != .Ok || got == 0 {
			if owned {
				_ = p9.client_clunk(c, cur)
			}
			return nil, false, {}, e != .Ok ? e : .Err_Not_Found
		}
		hit: ^Entry
		for j in 0 ..< got { // a mount point among the names reached, or just past one?
			after := i^ + j + 1 // the names used up once qids[j] is reached
			if hit = find_object(ns, conn, qids[j].path); hit != nil {
				i^ = after
				break
			}
			if after < len(names) {
				if hit = find_name(ns, conn, qids[j].path, names[after]); hit != nil {
					i^ = after + 1
					break
				}
			}
		}
		if hit != nil {
			if made {
				_ = p9.client_clunk(c, next)
			}
			jump = hit
			break
		}
		if got < count { // stopped partway, at no mount point
			if owned {
				_ = p9.client_clunk(c, cur)
			}
			return nil, false, {}, .Err_Not_Found
		}
		if owned {
			_ = p9.client_clunk(c, cur)
		}
		cur = next
		owned = true
		cur_qid = qids[got - 1].path
		i^ += count
		if i^ == len(names) {
			return nil, true, {conn = conn, fid = cur, qid = cur_qid}, .Ok
		}
	}
	if owned {
		_ = p9.client_clunk(c, cur)
	}
	return jump, false, {}, .Ok
}

// Resolves a cleaned path from the root, crossing mount points by identity.
@(private="file", require_results)
resolve :: proc "contextless" (ns: ^Namespace, path: string) -> (out: At, st: vx.Status) {
	names: [MAX_DEPTH]string
	n, ok := split(path, &names)
	e := root_entry(ns)
	if !ok {
		return {}, .Err_Range
	}
	if e == nil {
		return {}, .Err_Not_Found
	}
	i := 0
	for _ in 0 ..= MAX_DEPTH {
		if i == n { // exactly at a mount point: its first member
			m := &e.members[0]
			out.fid = p9.client_walk(ns.conns[m.conn].client, m.fid, "") or_return
			out.conn, out.qid, out.entry = m.conn, m.qid, e
			return out, .Ok
		}
		st = .Err_Not_Found
		jump: ^Entry
		for &m in e.members { // a union: each member in turn
			at := i
			done: bool
			jump, done, out, st = walk_on(ns, m.conn, m.fid, m.qid, names[:n], &at)
			if st == .Ok && done {
				return out, .Ok
			}
			if jump != nil {
				i = at
				break
			}
		}
		if jump == nil {
			return {}, st
		}
		e = jump
	}
	return {}, .Err_Range // mount points in a loop
}

// Resolves a path to a new fid on one of the namespace's connections: the
// caller owns it and clunks it. Members of a union are tried in order.
@(require_results)
walk :: proc "contextless" (ns: ^Namespace, path: string) -> (c: ^p9.Client, fid: p9.Fid, e: vx.Status) {
	catch_up(ns)
	buf: [MAX_PATH]u8
	cleaned := clean_name(ns, path, buf[:])
	if len(cleaned) == 0 {
		return nil, 0, .Err_Invalid
	}
	at := resolve(ns, cleaned) or_return
	return ns.conns[at.conn].client, at.fid, .Ok
}

// Whether path names a directory, for a change of the current directory
// (ADR-0017): its absolute, clean form, a slice of out (MAX_PATH bytes).
// Err_Invalid if it is not a directory, or the walk's error.
@(require_results)
dir_check :: proc "contextless" (ns: ^Namespace, path: string, out: []u8) -> (dir: string, st: vx.Status) {
	dir = clean_name(ns, path, out)
	if len(dir) == 0 {
		return "", .Err_Invalid
	}
	c, fid := walk(ns, dir) or_return
	s: p9.Stat
	st = p9.client_stat(c, fid, &s)
	_ = p9.client_clunk(c, fid)
	if st == .Ok && s.mode & p9.DMDIR == 0 {
		st = .Err_Invalid
	}
	return dir, st
}

// The connector of the first mount at the path path was made at (a spawner
// registers its children with whatever serves /proc: vx:process), or
// HANDLE_NONE. The namespace keeps it: the caller does not close it.
connector :: proc "contextless" (ns: ^Namespace, path: string) -> vx.Handle {
	catch_up(ns)
	e := exact(ns, path)
	if e == nil {
		return vx.HANDLE_NONE
	}
	for &m in e.members {
		if m.mounted && ns.conns[m.conn].connector != vx.HANDLE_NONE {
			return ns.conns[m.conn].connector
		}
	}
	return vx.HANDLE_NONE
}

@(private="file")
drop_member :: proc "contextless" (ns: ^Namespace, m: ^Member) {
	_ = p9.client_clunk(ns.conns[m.conn].client, m.fid)
}

@(private="file", require_results)
insert :: proc "contextless" (ns: ^Namespace, e: ^Entry, m: Member, flags: Flags, at: int) -> vx.Status {
	m := m
	m.flags = flags & {.Create}
	m.seq = ns.next_seq
	if append(&e.members, m) != 1 {
		return .Err_No_Memory
	}
	ns.next_seq += 1
	copy(e.members[at + 1:], e.members[at:len(e.members) - 1])
	e.members[at] = m
	return .Ok
}

// The mount point at the cleaned path old, found or made: what old resolves
// to now, as 9front's cmount finds the mount head by what it is mounted on: a
// mount point already (joined), or a directory; or, to replace rather than
// join, a new name in a directory that exists (/n/host for a mount needs only
// /n). "/" may be mounted on in an empty namespace. To join a union with what
// was there, the union starts with it.
@(private="file", require_results)
point :: proc "contextless" (ns: ^Namespace, old: string, flags: Flags) -> (out: ^Entry, st: vx.Status) {
	union_with_old := flags & {.After, .Before} != {}
	fresh: ^Entry
	for &e in ns.entries {
		if len(e.path) == 0 {
			fresh = &e
			break
		}
	}
	at: At
	st = .Err_Not_Found
	if root_entry(ns) != nil {
		at, st = resolve(ns, old)
	}
	if st == .Ok && at.entry != nil { // a mount point already: the same one, by whatever name
		_ = p9.client_clunk(ns.conns[at.conn].client, at.fid)
		return at.entry, .Ok
	}
	e: Entry
	_ = append(&e.path, old) // cleaned, so it fits
	switch {
	case st == .Ok:
		e.id, e.id_conn, e.id_qid = .Object, at.conn, at.qid
		if union_with_old {
			base := Member {
				conn = at.conn,
				fid  = at.fid,
				qid  = at.qid,
				seq  = ns.next_seq,
			}
			ns.next_seq += 1
			_ = append(&base.from, old)
			_ = append(&e.members, base)
		} else {
			_ = p9.client_clunk(ns.conns[at.conn].client, at.fid) // it only had to exist
		}
	case old == "/" && !union_with_old && root_entry(ns) == nil:
		e.id = .Root
	case st == .Err_Not_Found && !union_with_old && len(old) > 1: // a new name: its directory must exist
		up := len(old) - len(last_name(old))
		dir, de := resolve(ns, old[:up > 1 ? up - 1 : 1])
		if de != .Ok {
			return nil, st
		}
		_ = p9.client_clunk(ns.conns[dir.conn].client, dir.fid)
		e.id, e.id_conn, e.id_qid = .Name, dir.conn, dir.qid // a union's: its first member's
	case:
		return nil, st
	}
	if fresh == nil {
		if len(e.members) > 0 {
			_ = p9.client_clunk(ns.conns[e.members[0].conn].client, e.members[0].fid)
		}
		return nil, .Err_No_Memory
	}
	fresh^ = e
	return fresh, .Ok
}

// Without -a or -b, a new member replaces the union: every member goes.
@(private="file")
replace_union :: proc "contextless" (ns: ^Namespace, e: ^Entry, flags: Flags) {
	if flags & {.After, .Before} == {} {
		for &m in e.members {
			drop_member(ns, &m)
		}
		clear(&e.members)
	}
}

// Adds m at the cleaned path old, as flags say: replacing the union, or
// after it (-a), or before it (-b).
@(private="file", require_results)
add :: proc "contextless" (ns: ^Namespace, old: string, m: Member, flags: Flags) -> vx.Status {
	e := point(ns, old, flags) or_return
	replace_union(ns, e, flags)
	return insert(ns, e, m, flags, .Before in flags ? 0 : len(e.members))
}

// mount's change, to this table alone.
@(private="file", require_results)
mount_raw :: proc "contextless" (ns: ^Namespace, c: ^p9.Client, connector: vx.Handle, src, aname, old: string, flags: Flags) -> vx.Status {
	buf: [MAX_PATH]u8
	cleaned := clean_name(ns, old, buf[:])
	if len(cleaned) == 0 || len(src) > MAX_SRC || len(aname) > MAX_PATH {
		return .Err_Invalid
	}
	slot := u8(MAX_CONNS)
	for i in 0 ..< u8(MAX_CONNS) {
		if ns.conns[i].client == c {
			slot = i // the same connection again: one more attach
		}
		if slot == MAX_CONNS && ns.conns[i].client == nil {
			slot = i
		}
	}
	if slot == MAX_CONNS {
		return .Err_No_Memory
	}
	m := Member {
		conn    = slot,
		mounted = true,
	}
	_ = append(&m.from, aname)
	qid: p9.Qid
	st: vx.Status
	m.fid, qid, st = p9.client_attach_qid(c, aname)
	if st != .Ok {
		return st
	}
	m.qid = qid.path
	fresh := ns.conns[slot].client == nil
	if fresh {
		ns.conns[slot] = {
			client    = c,
			connector = connector,
		}
		_ = append(&ns.conns[slot].src, src)
	}
	st = add(ns, cleaned, m, flags)
	if st != .Ok {
		_ = p9.client_clunk(c, m.fid)
		if fresh {
			ns.conns[slot] = {}
		}
	}
	return st
}

// bind's change, to this table alone.
@(private="file", require_results)
bind_raw :: proc "contextless" (ns: ^Namespace, new, old: string, flags: Flags) -> vx.Status {
	from_buf, to_buf: [MAX_PATH]u8
	from, to := clean_name(ns, new, from_buf[:]), clean_name(ns, old, to_buf[:])
	if len(from) == 0 || len(to) == 0 {
		return .Err_Invalid
	}
	src := resolve(ns, from) or_return
	m := Member {
		conn = src.conn,
		fid  = src.fid,
		qid  = src.qid,
	}
	_ = append(&m.from, from)
	e, st := point(ns, to, flags)
	if st == .Ok && src.entry == e {
		st = .Err_Invalid // a union onto itself
	}
	if st != .Ok {
		_ = p9.client_clunk(ns.conns[src.conn].client, src.fid)
		return st
	}
	replace_union(ns, e, flags)
	at := .Before in flags ? 0 : len(e.members)
	st = insert(ns, e, m, flags, at)
	if st != .Ok {
		_ = p9.client_clunk(ns.conns[src.conn].client, src.fid)
	}
	if st == .Ok && src.entry != nil { // the rest of a union, copied whole, in order
		for &u in src.entry.members[1:] {
			more := u
			more.fid = p9.client_walk(ns.conns[u.conn].client, u.fid, "") or_return
			at += 1
			insert(ns, e, more, u.flags & {.Create}, at) or_return
		}
	}
	return st
}

// unmount's change, to this table alone.
@(private="file", require_results)
unmount_raw :: proc "contextless" (ns: ^Namespace, new, old: string) -> vx.Status {
	to_buf, from_buf: [MAX_PATH]u8
	to := clean_name(ns, old, to_buf[:])
	from := len(new) > 0 ? clean_name(ns, new, from_buf[:]) : ""
	if len(to) == 0 || (len(new) > 0 && len(from) == 0) {
		return .Err_Invalid
	}
	// The mount point there, by identity, or by the path it was made at.
	e: ^Entry
	if at, st := resolve(ns, to); st == .Ok {
		e = at.entry
		_ = p9.client_clunk(ns.conns[at.conn].client, at.fid)
	}
	if e == nil {
		e = exact(ns, to)
	}
	if e == nil {
		return .Err_Not_Found
	}
	kept := 0
	removed := false
	for &m in e.members {
		if len(new) == 0 || member_source(ns, &m) == from {
			drop_member(ns, &m)
			removed = true
		} else {
			e.members[kept] = m
			kept += 1
		}
	}
	resize(&e.members, kept)
	if kept == 0 {
		clear(&e.path)
	}
	// A connection no member uses any more is let go: no member, mounted or
	// bound (a bind of something under a mount walks on its connection too,
	// and outlives the mount: mount; bind /n/x/bin /bin; unmount /n/x).
	for &c, slot in ns.conns {
		if c.client == nil || conn_used(ns, u8(slot)) {
			continue
		}
		if ns.release != nil {
			ns.release(c.client, c.connector)
		}
		c = {}
	}
	return removed ? .Ok : .Err_Not_Found
}

// Whether any member, mounted or bound, holds a fid on the connection in
// slot.
@(private="file")
conn_used :: proc "contextless" (ns: ^Namespace, slot: u8) -> bool {
	for &e in ns.entries {
		if len(e.path) == 0 {
			continue
		}
		for &m in e.members {
			if m.conn == slot {
				return true
			}
		}
	}
	return false
}

// The table, emptied: every member's fid clunked, every mount point gone.
// Its connections stay, for a refresh to use again.
reset :: proc "contextless" (ns: ^Namespace) {
	for &e in ns.entries {
		if len(e.path) > 0 {
			for &m in e.members {
				drop_member(ns, &m)
			}
		}
		e = {}
	}
}

// A change to the table, and the group told of it; again is set when the
// group moved on meanwhile, and the change must be made again after catching
// up (ADR-0009).
@(private="file", require_results)
publish_change :: proc "contextless" (ns: ^Namespace, st: vx.Status, new_conn: u8) -> (result: vx.Status, again: bool) {
	if st != .Ok || ns.publish == nil || ns.quiet {
		return st, false
	}
	result = ns.publish(ns, new_conn)
	return result, result == .Err_Bad_State
}

// The slot of connection c, or MAX_CONNS.
conn_of :: proc "contextless" (ns: ^Namespace, c: ^p9.Client) -> u8 {
	for &k, i in ns.conns {
		if k.client == c {
			return u8(i)
		}
	}
	return MAX_CONNS
}

// Tries a change at most this many times while the group keeps moving on.
@(private="file")
TRIES :: 8

// Adds a connection (attached at its aname) at old. The namespace takes c: it
// is used until the namespace drops it. connector and src say where it came
// from, for children and for ns output.
@(require_results)
mount :: proc "contextless" (
	ns: ^Namespace,
	c: ^p9.Client,
	connector: vx.Handle,
	src, aname, old: string,
	flags: Flags,
) -> (
	st: vx.Status,
) {
	// New to this namespace or not, as it was before the first try: a try
	// made again finds c among the connections (reset keeps them), and the
	// group must still be given its connector.
	fresh := conn_of(ns, c) == MAX_CONNS
	st = .Err_Bad_State
	again := true
	for tries := 0; again && tries < TRIES; tries += 1 {
		catch_up(ns)
		st = mount_raw(ns, c, connector, src, aname, old, flags)
		st, again = publish_change(ns, st, fresh ? conn_of(ns, c) : MAX_CONNS)
	}
	return
}

// Makes old show what new names now. A union bound on a directory is copied
// whole, as 9front's cmount copies one: its members in order.
@(require_results)
bind :: proc "contextless" (ns: ^Namespace, new, old: string, flags: Flags) -> (st: vx.Status) {
	st = .Err_Bad_State
	again := true
	for tries := 0; again && tries < TRIES; tries += 1 {
		catch_up(ns)
		st, again = publish_change(ns, bind_raw(ns, new, old, flags), MAX_CONNS)
	}
	return
}

// Removes what was bound or mounted from new at old, or, with an empty new,
// everything at old.
@(require_results)
unmount :: proc "contextless" (ns: ^Namespace, new, old: string) -> (st: vx.Status) {
	st = .Err_Bad_State
	again := true
	for tries := 0; again && tries < TRIES; tries += 1 {
		catch_up(ns)
		st, again = publish_change(ns, unmount_raw(ns, new, old), MAX_CONNS)
	}
	return
}

// --- Replay order ---

// Every member, in the order they were added: the order a script or a child
// must replay them in, since each may resolve paths that earlier ones made.
//
//	r := ns.replay_order(space)
//	for step in ns.next_step(&r) { ... }
Replay :: struct {
	ns:    ^Namespace,
	steps: [dynamic; MAX_ENTRIES * MAX_MEMBERS]Step_Index,
	next:  int,
}

Step_Index :: struct {
	entry, member: u8,
}

// One member to replay, with the flags that put it back where it was among
// the members of its entry replayed before it: none for the first; "b" if it
// comes before every one of them, else "a"; and "c" if it takes creates.
Step :: struct {
	entry:  ^Entry,
	member: ^Member,
	flags:  string,
}

replay_order :: proc "contextless" (ns: ^Namespace) -> (r: Replay) {
	r.ns = ns
	for &e, i in ns.entries {
		if len(e.path) == 0 {
			continue
		}
		for &m, k in e.members {
			// Insertion sort: a few hundred members at most.
			_ = append(&r.steps, Step_Index{})
			at := len(r.steps) - 1
			for at > 0 && step_member(&r, at - 1).seq > m.seq {
				r.steps[at] = r.steps[at - 1]
				at -= 1
			}
			r.steps[at] = {u8(i), u8(k)}
		}
	}
	return
}

@(private="file")
step_member :: proc "contextless" (r: ^Replay, s: int) -> ^Member {
	return &r.ns.entries[r.steps[s].entry].members[r.steps[s].member]
}

next_step :: proc "contextless" (r: ^Replay) -> (step: Step, ok: bool) {
	if r.next >= len(r.steps) {
		return {}, false
	}
	s := r.next
	r.next += 1
	me := r.steps[s]
	earlier, before_all := false, true
	for i in 0 ..< s {
		if r.steps[i].entry != me.entry {
			continue
		}
		earlier = true
		if r.steps[i].member < me.member {
			before_all = false
		}
	}
	step.entry = &r.ns.entries[me.entry]
	step.member = &step.entry.members[me.member]
	create := .Create in step.member.flags
	switch {
	case !earlier:
		step.flags = create ? "c" : ""
	case before_all:
		step.flags = create ? "bc" : "b"
	case:
		step.flags = create ? "ac" : "a"
	}
	return step, true
}

// --- ns output ---

// A word as namespace(6) reads it: in single quotes ('' for a quote) if it
// holds white space, a quote, a '$' or a '#', or is empty.
@(private="file")
write_word :: proc "contextless" (t: ^str.Buf, s: string) {
	quote := len(s) == 0
	for c in transmute([]u8)s {
		if c == ' ' || c == '\t' || c == '\'' || c == '$' || c == '#' {
			quote = true
			break
		}
	}
	if !quote {
		str.write_string(t, s)
		return
	}
	str.write_byte(t, '\'')
	for c in transmute([]u8)s {
		if c == '\'' {
			str.write_string(t, "''")
		} else {
			str.write_byte(t, c)
		}
	}
	str.write_byte(t, '\'')
}

// Asks each server mounted in the namespace to put its changes on disk
// (Tfsync on the mount's fid; fsd commits its volume), as POSIX's sync.
sync :: proc "contextless" (ns: ^Namespace) {
	catch_up(ns)
	for &e in ns.entries {
		if len(e.path) == 0 {
			continue
		}
		for &m in e.members {
			if m.mounted {
				_ = p9.client_fsync(ns.conns[m.conn].client, m.fid)
			}
		}
	}
}

// c's connection's slot plus 1, which POSIX's st_dev tells servers apart by,
// or 0 if c is none of this namespace's. An unmounted connection's number may
// come again for another.
conn_id :: proc "contextless" (ns: ^Namespace, c: ^p9.Client) -> u64 {
	slot := conn_of(ns, c)
	return slot < MAX_CONNS ? u64(slot) + 1 : 0
}

// Writes the namespace as namespace(6): mount and bind lines, in the order
// they would rebuild it. Returns its length, or 0 if it does not fit.
print :: proc "contextless" (ns: ^Namespace, buf: []u8) -> int {
	t := str.Buf{buf = buf}
	r := replay_order(ns)
	for step in next_step(&r) {
		m := step.member
		str.write_string(&t, m.mounted ? "mount " : "bind ")
		if len(step.flags) > 0 {
			str.write_byte(&t, '-')
			str.write_string(&t, step.flags)
			str.write_byte(&t, ' ')
		}
		write_word(&t, member_source(ns, m))
		str.write_byte(&t, ' ')
		write_word(&t, entry_path(step.entry))
		if m.mounted && len(m.from) > 0 {
			str.write_byte(&t, ' ')
			write_word(&t, string(m.from[:]))
		}
		str.write_byte(&t, '\n')
	}
	return t.failed ? 0 : t.len
}

// Whether the table has no mount points.
is_empty :: proc "contextless" (ns: ^Namespace) -> bool {
	for &e in ns.entries {
		if len(e.path) > 0 {
			return false
		}
	}
	return true
}

// --- Files ---

// What a file the process serves itself does for reads, writes and its close.
Dev :: struct {
	read:  proc "contextless" (f: ^File, buf: []u8) -> (n: int, e: vx.Status),
	write: proc "contextless" (f: ^File, data: []u8) -> (n: int, e: vx.Status),
	close: proc "contextless" (f: ^File),
}

// All zeroes is a file that is not open.
File :: struct {
	ns:      ^Namespace,
	c:       ^p9.Client,
	fid:     p9.Fid,
	offset:  u64,
	u:       ^Entry, // a union directory being read member by member, or nil
	member:  int,
	dev:     ^Dev, // a file the process serves (open_dev's), not a 9P one; dev_ctx its state
	dev_ctx: rawptr,
}

// Opens a path. A directory that is a union reads as each member in turn.
@(require_results)
open :: proc "contextless" (ns: ^Namespace, path: string, mode: p9.Open_Mode, f: ^File) -> vx.Status {
	catch_up(ns)
	f^ = {
		ns = ns,
	}
	buf: [MAX_PATH]u8
	cleaned := clean_name(ns, path, buf[:])
	if len(cleaned) == 0 {
		return .Err_Invalid
	}
	if ns.open_dev != nil {
		if st := ns.open_dev(ns, cleaned, mode, f); st != .Err_Not_Found {
			return st
		}
	}
	at := resolve(ns, cleaned) or_return
	f.c = ns.conns[at.conn].client
	f.fid = at.fid // a union's first member, if it is a union
	if at.entry != nil && len(at.entry.members) > 1 && mode.access == .Read {
		f.u = at.entry
	}
	st := p9.client_open(f.c, f.fid, mode)
	if st != .Ok {
		_ = p9.client_clunk(f.c, f.fid)
		f^ = {}
	}
	return st
}

// Creates the file at path (in the directory its last '/' names), open in
// mode, with permissions perm. In a union, the first member bound with -c
// takes it, or none does (9front's createdir).
@(require_results)
create :: proc "contextless" (ns: ^Namespace, path: string, perm: u32, mode: p9.Open_Mode, f: ^File) -> vx.Status {
	catch_up(ns)
	f^ = {
		ns = ns,
	}
	buf: [MAX_PATH]u8
	cleaned := clean_name(ns, path, buf[:])
	slash := len(cleaned)
	for slash > 0 && cleaned[slash - 1] != '/' {
		slash -= 1
	}
	if len(cleaned) == 0 || slash == len(cleaned) {
		return .Err_Invalid // "/" itself
	}
	at := resolve(ns, cleaned[:max(slash - 1, 1)]) or_return
	f.c, f.fid = ns.conns[at.conn].client, at.fid
	if at.entry != nil && len(at.entry.members) > 1 {
		creator: ^Member
		for &m in at.entry.members {
			if .Create in m.flags {
				creator = &m
				break
			}
		}
		_ = p9.client_clunk(f.c, f.fid)
		if creator == nil {
			f^ = {}
			return .Err_Access
		}
		fid, st := p9.client_walk(ns.conns[creator.conn].client, creator.fid, "")
		if st != .Ok {
			f^ = {}
			return st
		}
		f.c, f.fid = ns.conns[creator.conn].client, fid
	}
	if st := p9.client_create(f.c, f.fid, cleaned[slash:], perm, mode); st != .Ok {
		_ = p9.client_clunk(f.c, f.fid)
		f^ = {}
		return st
	}
	return .Ok
}

// Reads at the file's offset and moves it on. Returns the count, 0 at the
// end, or an error.
@(require_results)
read :: proc "contextless" (f: ^File, buf: []u8) -> (n: int, e: vx.Status) {
	if f.dev != nil {
		return f.dev.read(f, buf)
	}
	if f.c == nil {
		return 0, .Err_Bad_Handle // not open
	}
	for {
		n, e = p9.client_read(f.c, f.fid, f.offset, buf)
		if e != .Ok || n != 0 || f.u == nil || f.member + 1 >= len(f.u.members) {
			if e == .Ok && n > 0 {
				f.offset += u64(n)
			}
			return
		}
		// This member is done: on to the next member of the union.
		_ = p9.client_clunk(f.c, f.fid)
		f.member += 1
		m := &f.u.members[f.member]
		f.c = f.ns.conns[m.conn].client
		f.offset = 0
		f.fid, e = p9.client_walk(f.c, m.fid, "")
		if e == .Ok {
			if e = p9.client_open(f.c, f.fid, p9.OREAD); e != .Ok {
				_ = p9.client_clunk(f.c, f.fid)
			}
		}
		if e != .Ok {
			f^ = {} // nothing open: close has nothing to do
			return 0, e
		}
	}
}

// Reads until buf is full or the file ends; returns how much it read. A
// failure ends the read, with what came before it.
@(require_results)
read_all :: proc "contextless" (f: ^File, buf: []u8) -> (n: int, e: vx.Status) {
	for n < len(buf) {
		got := read(f, buf[n:]) or_return
		if got == 0 {
			break
		}
		n += got
	}
	return n, .Ok
}

@(require_results)
write :: proc "contextless" (f: ^File, data: []u8) -> (n: int, e: vx.Status) {
	if f.dev != nil {
		return f.dev.write(f, data)
	}
	if f.c == nil {
		return 0, .Err_Bad_Handle
	}
	n, e = p9.client_write(f.c, f.fid, f.offset, data)
	if e == .Ok && n > 0 {
		f.offset += u64(n)
	}
	return
}

close :: proc "contextless" (f: ^File) {
	if f.dev != nil {
		f.dev.close(f)
	}
	if f.c != nil {
		_ = p9.client_clunk(f.c, f.fid)
	}
	f^ = {}
}
