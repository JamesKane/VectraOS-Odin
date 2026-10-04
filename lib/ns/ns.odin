// A process's namespace, in its own address space (upstream 02 §2, D4). It
// builds for the target and the host, and sees servers only as p9 Clients.
//
// The table maps paths to unions: each entry is an absolute path and an
// ordered list of members, each a directory on some connection (a fid this
// table owns, never opened, only cloned). mount attaches a connection and adds
// its root; bind resolves a path and adds what it finds. Flags say where the
// new member goes: replacing the union (none), after it (.After, -a), or
// before it (.Before, -b); .Create (-c) marks the member that takes creates.
//
// Resolution cleans the path lexically first, so ".." never climbs out of a
// bind (Plan 9's rule), then takes the entry with the longest matching prefix
// and walks the rest from each member in order until one has it. Confinement
// is not this table's job: it is the connections' (02 §2).
//
// ns output (print) replays: one mount or bind line per member, the first of
// each union without -a, the rest with it.
//
// Building a namespace from a spawn message's mount= and bind= records sits
// on top of this package: each mount record gets a connection of its own to
// the server behind its connector, and is handed to mount with that
// connector, so a child can be given its own connection later.
package ns

import "abi:vx"
import "vx:p9"
import "vx:str"

MAX_PATH :: 256
MAX_ENTRIES :: 32
MAX_MEMBERS :: 8
MAX_CONNS :: 8
MAX_SRC :: 64

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
	from:    [dynamic; MAX_PATH]u8, // bind: the path; mount: the aname
}

Entry :: struct {
	path:    [dynamic; MAX_PATH]u8, // empty: the slot is free
	members: [dynamic; MAX_MEMBERS]Member,
}

// All zeroes is an empty namespace.
Namespace :: struct {
	conns:   [MAX_CONNS]Conn,
	entries: [MAX_ENTRIES]Entry,
}

// Cleans an absolute path lexically into out: no empty, "." or ".."
// components, and ".." above the root is the root. Returns the cleaned path,
// a slice of out, or "" for a relative path or one that does not fit.
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

// The path an entry is for; "" for a free slot.
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

// The entry whose path is the longest prefix of path at a component boundary,
// and what follows it, without a leading '/'.
@(private="file")
lookup :: proc "contextless" (ns: ^Namespace, path: string) -> (best: ^Entry, rest: string) {
	for &e in ns.entries {
		n := len(e.path)
		if n == 0 || n > len(path) || entry_path(&e) != path[:n] {
			continue
		}
		if n > 1 && n < len(path) && path[n] != '/' {
			continue // "/bin" is not a prefix of "/binary"
		}
		if best == nil || n > len(best.path) {
			best = &e
		}
	}
	if best != nil {
		n := len(best.path)
		skip := n == 1 ? 1 : n + (len(path) > n ? 1 : 0)
		rest = path[skip:]
	}
	return
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

// The slot of a connection that walk returned, so one the namespace holds.
@(private="file")
conn_index :: proc "contextless" (ns: ^Namespace, c: ^p9.Client) -> (slot: u8) {
	for &conn, i in ns.conns {
		if conn.client == c {
			slot = u8(i)
		}
	}
	return
}

// Resolves a path to a new fid on one of the namespace's connections: the
// caller owns it and clunks it. Members of a union are tried in order.
@(require_results)
walk :: proc "contextless" (ns: ^Namespace, path: string) -> (c: ^p9.Client, fid: p9.Fid, e: vx.Status) {
	buf: [MAX_PATH]u8
	cleaned := clean(path, buf[:])
	if len(cleaned) == 0 {
		return nil, 0, .Err_Invalid
	}
	entry, rest := lookup(ns, cleaned)
	if entry == nil {
		return nil, 0, .Err_Not_Found
	}
	e = .Err_Not_Found
	for &m in entry.members {
		client := ns.conns[m.conn].client
		fid, e = p9.client_walk(client, m.fid, rest)
		if e == .Ok {
			return client, fid, .Ok
		}
	}
	return nil, 0, e
}

@(private="file")
drop_member :: proc "contextless" (ns: ^Namespace, m: ^Member) {
	_ = p9.client_clunk(ns.conns[m.conn].client, m.fid)
}

// Adds m at the cleaned path old, which must name something already (but "/"
// may be mounted on in an empty namespace).
@(private="file", require_results)
add :: proc "contextless" (ns: ^Namespace, old: string, m: Member, flags: Flags) -> vx.Status {
	m := m
	e := exact(ns, old)
	if e == nil {
		base: Member
		union_with_old := flags & {.After, .Before} != {}
		bc, fid, st := walk(ns, old)
		if st != .Ok && !(len(old) == 1 && !union_with_old) {
			return st
		}
		base.fid = fid
		if st == .Ok && !union_with_old {
			_ = p9.client_clunk(bc, base.fid) // it only had to exist
		}
		for &free in ns.entries {
			if len(free.path) == 0 {
				e = &free
				break
			}
		}
		if e == nil {
			if st == .Ok && union_with_old {
				_ = p9.client_clunk(bc, base.fid)
			}
			return .Err_No_Memory
		}
		_ = append(&e.path, old) // cleaned, so it fits
		clear(&e.members)
		if union_with_old {
			// The union starts with what was there: a bind of the path onto itself.
			base.conn = conn_index(ns, bc)
			_ = append(&base.from, old)
			_ = append(&e.members, base)
		}
	}
	if flags & {.After, .Before} == {} {
		for &member in e.members {
			drop_member(ns, &member)
		}
		clear(&e.members)
	}
	m.flags = flags & {.Create}
	if append(&e.members, m) != 1 {
		return .Err_No_Memory
	}
	if .Before in flags {
		copy(e.members[1:], e.members[:len(e.members) - 1])
		e.members[0] = m
	}
	return .Ok
}

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
) -> vx.Status {
	buf: [MAX_PATH]u8
	cleaned := clean(old, buf[:])
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
	st: vx.Status
	m.fid, st = p9.client_attach(c, aname)
	if st != .Ok {
		return st
	}
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

// Makes old show what new names now.
@(require_results)
bind :: proc "contextless" (ns: ^Namespace, new, old: string, flags: Flags) -> vx.Status {
	from_buf, to_buf: [MAX_PATH]u8
	from, to := clean(new, from_buf[:]), clean(old, to_buf[:])
	if len(from) == 0 || len(to) == 0 {
		return .Err_Invalid
	}
	m: Member
	_ = append(&m.from, from)
	c: ^p9.Client
	st: vx.Status
	c, m.fid, st = walk(ns, from)
	if st != .Ok {
		return st
	}
	m.conn = conn_index(ns, c)
	st = add(ns, to, m, flags)
	if st != .Ok {
		_ = p9.client_clunk(c, m.fid)
	}
	return st
}

// Removes what was bound or mounted from new at old, or, with an empty new,
// everything at old.
@(require_results)
unmount :: proc "contextless" (ns: ^Namespace, new, old: string) -> vx.Status {
	to_buf, from_buf: [MAX_PATH]u8
	to := clean(old, to_buf[:])
	from := len(new) > 0 ? clean(new, from_buf[:]) : ""
	if len(to) == 0 || (len(new) > 0 && len(from) == 0) {
		return .Err_Invalid
	}
	e := exact(ns, to)
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
	return removed ? .Ok : .Err_Not_Found
}

// --- ns output ---

// Writes the namespace as a script of mount and bind lines, entries in the
// order they were made. Returns its length, or 0 if it does not fit.
print :: proc "contextless" (ns: ^Namespace, buf: []u8) -> int {
	t := str.Buf{buf = buf}
	for &e in ns.entries {
		if len(e.path) == 0 {
			continue
		}
		for &m, k in e.members {
			str.write_string(&t, m.mounted ? "mount " : "bind ")
			if k > 0 || .Create in m.flags {
				str.write_byte(&t, '-')
				if k > 0 {
					str.write_byte(&t, 'a')
				}
				if .Create in m.flags {
					str.write_byte(&t, 'c')
				}
				str.write_byte(&t, ' ')
			}
			str.write_string(&t, member_source(ns, &m))
			str.write_byte(&t, ' ')
			str.write_string(&t, entry_path(&e))
			if m.mounted && len(m.from) > 0 {
				str.write_byte(&t, ' ')
				str.write_bytes(&t, m.from[:])
			}
			str.write_byte(&t, '\n')
		}
	}
	return t.failed ? 0 : t.len
}

// --- Files ---

// All zeroes is a file that is not open.
File :: struct {
	ns:     ^Namespace,
	c:      ^p9.Client,
	fid:    p9.Fid,
	offset: u64,
	u:      ^Entry, // a union directory being read member by member, or nil
	member: int,
}

// Opens a path. A directory that is a union reads as each member in turn.
@(require_results)
open :: proc "contextless" (ns: ^Namespace, path: string, mode: p9.Open_Mode, f: ^File) -> vx.Status {
	f^ = {
		ns = ns,
	}
	buf: [MAX_PATH]u8
	cleaned := clean(path, buf[:])
	if len(cleaned) == 0 {
		return .Err_Invalid
	}
	e := exact(ns, cleaned)
	st: vx.Status
	if e != nil && len(e.members) > 1 && mode.access == .Read {
		f.u = e
		f.c = ns.conns[e.members[0].conn].client
		f.fid, st = p9.client_walk(f.c, e.members[0].fid, "")
	} else {
		c: ^p9.Client
		fid: p9.Fid
		c, fid, st = walk(ns, cleaned)
		if st == .Ok {
			f.c, f.fid = c, fid
		}
	}
	if st != .Ok {
		return st
	}
	st = p9.client_open(f.c, f.fid, mode)
	if st != .Ok {
		_ = p9.client_clunk(f.c, f.fid)
		f^ = {}
	}
	return st
}

// Reads at the file's offset and moves it on. Returns the count, 0 at the
// end, or an error.
@(require_results)
read :: proc "contextless" (f: ^File, buf: []u8) -> (n: int, e: vx.Status) {
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
	if f.c != nil {
		_ = p9.client_clunk(f.c, f.fid)
	}
	f^ = {}
}
