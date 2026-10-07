// vx:procns, a process's namespace at start-up, and its namespace group
// (upstream ADR-0009). A child that shares its parent's group is given a
// channel to nsd for it ("nsgroup"), and builds its table from the group's
// text; one with a namespace of its own is given mount= and bind= records,
// what its parent's template or table made (02 §2). A mount record names a
// connector handle in the message; each connector gets its own ring
// connection to the server behind it, which every mount record naming it
// shares. A mount record with dial=ADDRESS instead is a 9P server over TCP,
// which the process dials itself (ns.dial), through the /net its earlier
// records gave it. (lib/ns is the table itself, and builds for the host;
// this is its half that needs the runtime.)
package procns

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:rt"
import "vx:str"

// The process's connections: a slot is free while its end is HANDLE_NONE.
// Each has the name of the connector handle it came through, so mount
// records naming one connector share one connection.
@(private="file")
conns: [ns.MAX_CONNS]rt.Conn
@(private="file")
conn_names: [ns.MAX_CONNS][dynamic; 7]u8

// Parses a flags= value: a, b and c, not a with b. ok is false otherwise.
parse_flags :: proc "contextless" (f: string) -> (flags: ns.Flags, ok: bool) {
	for c in f {
		switch c {
		case 'a':
			flags += {.After}
		case 'b':
			flags += {.Before}
		case 'c':
			flags += {.Create}
		case:
			return {}, false
		}
	}
	return flags, !(.After in flags && .Before in flags)
}

// The namespace let a connection go (unmount): disconnect it, and its slot
// is free.
@(private="file")
release :: proc "contextless" (c: ^p9.Client, connector: vx.Handle) {
	if ns.dial_release(c) {
		return // a TCP connection: no connector
	}
	for &k, i in conns {
		if &k.c == c {
			rt.p9_disconnect(&k) // which leaves its end HANDLE_NONE
			clear(&conn_names[i])
		}
	}
	rt.close_all(connector)
}

// Where records' handles come from: the spawn message's (nil), or a list of
// a process's own (after a fork). A handle taken is the namespace's.
Handles :: struct {
	names:   []string,
	handles: []vx.Handle,
}

@(private="file")
take :: proc "contextless" (from: ^Handles, name: string) -> vx.Handle {
	if from == nil {
		return rt.spawn_take(name)
	}
	for &h, i in from.handles {
		if h != vx.HANDLE_NONE && from.names[i] == name {
			taken := h
			h = vx.HANDLE_NONE
			return taken
		}
	}
	return vx.HANDLE_NONE
}

// The connection through the connector name names: the one already made
// through it (and connector HANDLE_NONE, since the namespace has it
// already), or a new one, with the connector it took.
@(private="file", require_results)
connect :: proc "contextless" (from: ^Handles, name: string) -> (c: ^p9.Client, connector: vx.Handle, st: vx.Status) {
	free_slot := -1
	for &k, i in conns {
		if k.end != vx.HANDLE_NONE && len(conn_names[i]) > 0 && string(conn_names[i][:]) == name {
			return &k.c, vx.HANDLE_NONE, .Ok
		}
		if k.end == vx.HANDLE_NONE && free_slot < 0 {
			free_slot = i
		}
	}
	if len(name) > cap(conn_names[0]) || free_slot < 0 {
		return nil, vx.HANDLE_NONE, .Err_No_Memory
	}
	k := &conns[free_slot]
	connector = take(from, name)
	st = connector != vx.HANDLE_NONE ? rt.p9_connect(connector, k) : .Err_Not_Found // which disconnects again if it fails
	if st != .Ok {
		rt.close_all(connector)
		k^ = {}
		return nil, vx.HANDLE_NONE, st
	}
	clear(&conn_names[free_slot])
	_ = append(&conn_names[free_slot], name) // it fits: checked above
	return &k.c, connector, .Ok
}

// A connection through a connector handle (which the namespace takes, if it
// succeeds), in a free slot.
@(require_results)
connect_handle :: proc "contextless" (connector: vx.Handle) -> (c: ^p9.Client, st: vx.Status) {
	for &k, i in conns {
		if k.end != vx.HANDLE_NONE {
			continue
		}
		if st = rt.p9_connect(connector, &k); st != .Ok {
			k = {}
			return nil, st
		}
		clear(&conn_names[i])
		return &k.c, .Ok
	}
	return nil, .Err_No_Memory
}

@(private="file")
scratch: [vx.CHANNEL_MAX_BYTES]u8

// Replays namespace records in order: the spawn message's, or (from not nil)
// a process's own after a fork. Stops at the first that fails, and says
// which.
@(private="file", require_results)
replay_records :: proc "contextless" (space: ^ns.Namespace, records: string, from: ^Handles) -> vx.Status {
	r := ndb.Reader{src = records, scratch = scratch[:]}
	space.release = release
	for {
		rec: ndb.Record
		if ndb.next(&r, &rec) != .Record {
			break
		}
		mount := ndb.has(&rec, "mount")
		if !mount && !ndb.has(&rec, "bind") {
			continue
		}
		if st := replay(space, &rec, mount, from); st != .Ok {
			where_ := from != nil ? " of the namespace after a fork: " : " of the spawn message: "
			rt.print("vx-ns: cannot replay the record on line ", u64(rec.line), where_, p9.error_text(st), "\n")
			return st
		}
	}
	return .Ok
}

// One mount or bind record. A mount record with dial= dials its server; one
// with handle= connects through that connector, or shares the connection
// already made through it.
@(private="file", require_results)
replay :: proc "contextless" (space: ^ns.Namespace, rec: ^ndb.Record, mount: bool, from: ^Handles) -> vx.Status {
	fv, _ := ndb.get(rec, "flags")
	flags, fok := parse_flags(fv)
	if !fok {
		return .Err_Invalid
	}
	if !mount {
		nw, _ := ndb.get(rec, "new")
		b, _ := ndb.get(rec, "bind")
		return ns.bind(space, nw, b, flags)
	}
	aname, _ := ndb.get(rec, "aname")
	old, _ := ndb.get(rec, "mount")
	if addr, dialed := ndb.get(rec, "dial"); dialed {
		c, src := ns.dial(space, addr) or_return
		return ns.mount(space, c, vx.HANDLE_NONE, src, aname, old, flags)
	}
	name, _ := ndb.get(rec, "handle")
	c, connector := connect(from, name) or_return
	src, _ := ndb.get(rec, "src")
	return ns.mount(space, c, connector, src, aname, old, flags)
}

// --- Namespace groups (ADR-0009; nsd's protocol is ns.Nsd_Call) ---
//
// A member keeps its own table, built from the group's text, which it maps
// read-only from nsd: before a name is resolved, if the text's sequence has
// moved, the table is emptied and the text replayed (refresh). A change made
// to the table is sent to nsd as the table's new text (publish).

Group :: struct {
	chan:  vx.Handle, // this process's channel to nsd for its group, or none: a namespace of its own
	srv:   vx.Handle, // a connector to nsd's post, to make a group with, or none
	page:  ^ns.Nsd_Page, // the group's text, mapped read-only
	seq:   u64, // the sequence the table was last built from
}

@(private)
group: Group

@(private="file")
PAGE_SIZE :: (size_of(ns.Nsd_Page) + memory.PAGE_SIZE - 1) / memory.PAGE_SIZE * memory.PAGE_SIZE

// A call to nsd: the header and args, then text and names.
@(private="file")
Nsd_Request :: struct {
	msg:   ns.Nsd_Msg,
	bytes: [vx.CHANNEL_MAX_BYTES - size_of(ns.Nsd_Msg)]u8,
}

@(private="file")
request: Nsd_Request

// One call to nsd on ch: args, then text and names, giving handles; the
// reply, its handles in got. Returns the channel's status, or the reply's;
// on a failure, any handle that came is closed.
@(private, require_results)
nsd :: proc "contextless" (ch: vx.Handle, call: ns.Nsd_Call, args: ns.Nsd_Args, text, names: string, give: []vx.Handle, got: []vx.Handle) -> (rep: ns.Nsd_Msg, st: vx.Status) {
	if len(text) + len(names) > len(request.bytes) {
		return {}, .Err_Range
	}
	request.msg = {
		header = {ordinal = u32(call)},
		args = args,
	}
	request.msg.args.text_len = u32(len(text))
	copy(request.bytes[:], text)
	copy(request.bytes[len(text):], names)
	c := vx.Call {
		wr_bytes     = &request,
		wr_len       = u32(size_of(ns.Nsd_Msg) + len(text) + len(names)),
		wr_handles   = raw_data(give),
		wr_count     = u32(len(give)),
		rd_bytes     = &rep,
		rd_cap       = size_of(rep),
		rd_handles   = raw_data(got),
		rd_count_cap = u32(len(got)),
	}
	st = rt.channel_call(ch, &c, vx.INFINITE)
	if st == .Ok && c.actual.bytes < size_of(rep) {
		st = .Err_Invalid
	}
	if st == .Ok && rep.header.flags != 0 {
		st = vx.Status(i32(rep.header.flags))
	}
	if st != .Ok {
		rt.close_all(..got[:min(int(c.actual.handles), len(got))])
	}
	return
}

@(private="file")
my_task_id :: proc "contextless" () -> u64 {
	me, st := rt.task_info(rt.self)
	return st == .Ok ? me.id : 0
}

@(private="file")
script: ns.Script

// Replays a group's text onto an empty table: a mount's source is a
// connection the table has from it already, a connector nsd keeps for the
// group (/srv/NAME, or an address a member mounted through a relay:
// relay.odin), or an address to dial. A line that fails is said, and
// the rest replayed: one line lost, not all after it.
@(private="file", require_results)
group_apply :: proc "contextless" (space: ^ns.Namespace, text: string) -> vx.Status {
	script = {
		text = text,
	}
	op: ns.Op
	st, first: vx.Status
	for {
		if st = ns.script_next(&script, &op); st != .Ok {
			break
		}
		#partial switch op.kind {
		case .Mount:
			src, old := op.args[0], op.args[1]
			aname := len(op.args) > 2 ? op.args[2] : ""
			st = ns.mount_srv(space, src, aname, old, op.flags)
			post := len(src) > 5 && str.has_prefix(src, "/srv/")
			if st == .Err_Not_Found { // a post, or an address mounted through a relay: nsd has it
				connector: [1]vx.Handle
				_, st = nsd(group.chan, .Connector, {}, src, "", nil, connector[:])
				c: ^p9.Client
				if st == .Ok {
					c, st = connect_handle(connector[0])
				}
				if c != nil {
					st = ns.mount(space, c, connector[0], src, aname, old, op.flags)
				} else {
					rt.close_all(connector[0])
				}
			}
			if st == .Err_Not_Found && !post { // an address dialed by its first member: dialed
				c, dsrc, dst := ns.dial(space, src)
				st = dst
				if st == .Ok {
					st = ns.mount(space, c, vx.HANDLE_NONE, dsrc, aname, old, op.flags)
				}
			}
		case .Bind:
			st = ns.bind(space, op.args[0], op.args[1], op.flags)
		case .Unmount:
			st = ns.unmount(space, len(op.args) == 2 ? op.args[0] : "", op.args[len(op.args) - 1])
		}
		if st != .Ok {
			rt.print("vx-ns: cannot replay line ", u64(op.line), " of the namespace group's: ", p9.error_text(st), "\n")
			if first == .Ok {
				first = st
			}
		}
	}
	if st != .Err_Not_Found {
		return st // the text itself is bad
	}
	return first
}

@(private="file")
group_text: [ns.NSD_TEXT_MAX]u8

// The table, brought up to the group's: emptied and built again from its
// text, if that has changed since the table was last built.
@(private="file")
group_refresh :: proc "contextless" (space: ^ns.Namespace) {
	page := group.page
	if page == nil || intrinsics.atomic_load_explicit(&page.seq, .Acquire) == group.seq {
		return
	}
	seq: u64
	n: int
	for { // a copy nsd was not writing: the same even sequence before and after
		seq = intrinsics.atomic_load_explicit(&page.seq, .Acquire)
		if seq & 1 != 0 {
			continue
		}
		n = min(int(intrinsics.volatile_load(&page.len)), ns.NSD_TEXT_MAX)
		copy(group_text[:n], page.text[:n])
		intrinsics.atomic_thread_fence(.Acquire)
		if intrinsics.atomic_load_explicit(&page.seq, .Relaxed) == seq {
			break
		}
	}
	space.quiet = true
	ns.reset(space)
	_ = group_apply(space, string(group_text[:n]))
	space.quiet = false
	group.seq = seq
}

@(private="file")
publish_text: [ns.NSD_TEXT_MAX]u8

// The table has changed: its text, to nsd, from the sequence it was built
// on, with the connector of a connection the change added. Err_Bad_State if
// another member changed the group first.
@(private="file")
group_publish :: proc "contextless" (space: ^ns.Namespace, new_conn: u8) -> vx.Status {
	n := ns.print(space, publish_text[:])
	if n == 0 && !ns.is_empty(space) {
		return .Err_Range // too long to send: never an empty text in its place
	}
	names: [ns.MAX_SRC + 1]u8
	line := ""
	give: [1]vx.Handle
	if new_conn < ns.MAX_CONNS && space.conns[new_conn].connector != vx.HANDLE_NONE {
		if h, st := rt.handle_dup(space.conns[new_conn].connector, vx.RIGHTS_SAME); st == .Ok {
			give[0] = h
			src := space.conns[new_conn].src[:]
			copy(names[:], src)
			names[len(src)] = '\n'
			line = string(names[:len(src) + 1])
		}
	}
	given := give[0] != vx.HANDLE_NONE ? give[:] : nil
	rep, st := nsd(group.chan, .Update, {seq = group.seq, count = u32(len(given))}, string(publish_text[:n]), line, given, nil)
	if st == .Ok {
		group.seq = rep.args.seq
	}
	return st
}

// Maps the group's text, given a handle to its VMO (which the mapping keeps).
@(private="file", require_results)
group_map :: proc "contextless" (vmo: vx.Handle) -> vx.Status {
	va, st := rt.as_map(rt.self, vmo, 0, PAGE_SIZE, {})
	_ = rt.handle_close(vmo)
	if st == .Ok {
		group.page = (^ns.Nsd_Page)(uintptr(va))
	}
	return st
}

// ns.dial_lock: vx:rt's mutex, on the dialed connection's word.
@(private="file")
dial_lock :: proc "contextless" (word: ^u32, take: bool) {
	m := (^rt.Mutex)(word)
	#assert(size_of(rt.Mutex) == size_of(u32))
	if take {
		rt.mutex_lock(m)
	} else {
		rt.mutex_unlock(m)
	}
}

@(private="file")
group_hooks :: proc "contextless" (space: ^ns.Namespace) {
	space.release = release
	space.refresh = group_refresh
	space.publish = group_publish
}

// Joins the group chan is a channel for: maps its text, and builds the table
// from it.
@(private="file", require_results)
group_join :: proc "contextless" (space: ^ns.Namespace, chan: vx.Handle) -> vx.Status {
	group.chan = chan
	vmo: [1]vx.Handle
	_ = nsd(chan, .Hello, {task = my_task_id()}, "", "", nil, vmo[:]) or_return
	group_map(vmo[0]) or_return
	group.seq = max(u64) // never a sequence: the first refresh builds the table
	group_hooks(space)
	group_refresh(space)
	return .Ok
}

// Leaves the namespace group (rc's rfork n, upstream's 6d7b3, as RFNAMEG):
// the table, as it is, a copy of this process's own; the group's later
// changes are not seen, nor are this one's by the group. A child shares it
// in a group made for it (spawn_records). Nothing to do without a group.
group_leave :: proc "contextless" (space: ^ns.Namespace) {
	if group.chan == vx.HANDLE_NONE {
		return
	}
	if !space.quiet {
		group_refresh(space) // the group's table as it is now
	}
	space.refresh, space.publish = nil, nil
	rt.close_all(group.chan)
	if group.page != nil {
		// vx:rt has no as_unmap yet (the kernel's M4 port brings it): the call itself.
		_ = rt.vx_syscall(.As_Unmap, u64(rt.self), u64(uintptr(group.page)), PAGE_SIZE)
	}
	group.chan, group.page, group.seq = vx.HANDLE_NONE, nil, 0
}

@(private="file")
make_text: [ns.NSD_TEXT_MAX]u8
@(private="file")
make_names: [ns.MAX_CONNS * (ns.MAX_SRC + 1)]u8

// Makes a group of this process's namespace, with it as the first member,
// so a child can share it. Err_Not_Found without nsd.
@(private="file", require_results)
group_make :: proc "contextless" (space: ^ns.Namespace) -> vx.Status {
	if group.srv == vx.HANDLE_NONE {
		return .Err_Not_Found
	}
	n := ns.print(space, make_text[:])
	if n == 0 && !ns.is_empty(space) {
		return .Err_Range // too long to send: never a group with an empty text
	}
	give: [dynamic; ns.MAX_CONNS]vx.Handle
	names := str.Buf{buf = make_names[:]}
	for &c in space.conns {
		if c.client == nil || c.connector == vx.HANDLE_NONE {
			continue
		}
		h, st := rt.handle_dup(c.connector, vx.RIGHTS_SAME)
		if st != .Ok {
			continue
		}
		_ = append(&give, h)
		str.write_bytes(&names, c.src[:])
		str.write_byte(&names, '\n')
	}
	got: [2]vx.Handle
	args := ns.Nsd_Args{task = my_task_id(), count = u32(len(give))}
	rep := nsd(group.srv, .New, args, string(make_text[:n]), str.to_string(&names), give[:], got[:]) or_return
	group.chan = got[0]
	group_map(got[1]) or_return
	group.seq = rep.args.seq // the table is the text already
	group_hooks(space)
	return .Ok
}

// --- /fd (ADR-0018, upstream's ADR-0040): the process's own descriptors, as 9front's devdup ---
//
// /fd/N opened is a copy of descriptor N (rt.fd_pipe): a pipe end, read or
// written with the pipe protocol; or an open file it was given (rt.fd_file),
// joined by its token once, else opened again by its name at its offset. Not
// listed, and not in the namespace.

@(private="file")
Fd_Opened :: struct { // an open /fd/N's state
	used:  bool,
	input: rt.Pipe_In, // a reading end's
	out:   vx.Handle, // a writing end
}

@(private="file")
fd_opens: [8]Fd_Opened
@(private="file")
fd_opens_lock: rt.Mutex

@(private="file")
fd_read :: proc "contextless" (f: ^ns.File, buf: []u8) -> (n: int, e: vx.Status) {
	x := (^Fd_Opened)(f.dev_ctx)
	if x.input.end == vx.HANDLE_NONE {
		return 0, .Err_Access
	}
	return rt.pipe_read(&x.input, buf)
}

@(private="file")
fd_write :: proc "contextless" (f: ^ns.File, data: []u8) -> (n: int, e: vx.Status) {
	x := (^Fd_Opened)(f.dev_ctx)
	if x.out == vx.HANDLE_NONE {
		return 0, .Err_Access
	}
	rt.pipe_send(x.out, data)
	return len(data), .Ok
}

@(private="file")
fd_close :: proc "contextless" (f: ^ns.File) {
	x := (^Fd_Opened)(f.dev_ctx)
	rt.close_all(x.input.end, x.input.port, x.out)
	rt.mutex_lock(&fd_opens_lock)
	x^ = {}
	rt.mutex_unlock(&fd_opens_lock)
	f.dev = nil
}

@(private="file")
fd_dev := ns.Dev {
	read  = fd_read,
	write = fd_write,
	close = fd_close,
}

// An open file given as a descriptor: joined by its token, the first time,
// as the open file the parent had; else opened again by its name, at the
// offset it was at.
@(private="file", require_results)
fd_open_file :: proc "contextless" (space: ^ns.Namespace, e: ^rt.Fd_Entry, mode: p9.Open_Mode, f: ^ns.File) -> vx.Status {
	path := string(e.path[:])
	if e.has_token {
		e.has_token = false
		dir := len(path) // the file's connection, or its directory's if it has gone since
		for dir > 1 && path[dir - 1] != '/' {
			dir -= 1
		}
		c, fid, st := ns.walk(space, path)
		if st != .Ok {
			c, fid, st = ns.walk(space, path[:dir])
		}
		if st == .Ok {
			_ = p9.client_clunk(c, fid)
			if joined, jst := p9.client_join(c, e.token); jst == .Ok {
				f^ = {
					ns     = space,
					c      = c,
					fid    = joined,
					offset = e.offset,
				}
				return .Ok
			}
		}
	}
	st := ns.open(space, path, mode, f)
	if st == .Ok {
		f.offset = e.offset
	}
	return st
}

// ns.Namespace's open_dev: /fd/N, for a descriptor this process has, opened
// the way it goes (Err_Access otherwise); Err_Not_Found for any other name.
@(private="file")
fd_open :: proc "contextless" (space: ^ns.Namespace, path: string, mode: p9.Open_Mode, f: ^ns.File) -> vx.Status {
	if len(path) != 5 || path[:4] != "/fd/" || path[4] < '0' || path[4] > '9' {
		return .Err_Not_Found
	}
	n := int(path[4] - '0')
	if file := rt.fd_file(n); file != nil {
		return fd_open_file(space, file, mode, f)
	}
	h, reader := rt.fd_pipe(n)
	if h == vx.HANDLE_NONE {
		return .Err_Not_Found
	}
	if mode.access != (reader ? p9.Access.Read : p9.Access.Write) {
		return .Err_Access
	}
	dup := rt.handle_dup(h, vx.RIGHTS_SAME) or_return
	rt.mutex_lock(&fd_opens_lock)
	x: ^Fd_Opened
	for &o in fd_opens {
		if !o.used {
			x = &o
			break
		}
	}
	if x != nil {
		x^ = {used = true}
		if reader {
			x.input.end = dup
		} else {
			x.out = dup
		}
	}
	rt.mutex_unlock(&fd_opens_lock)
	if x == nil {
		rt.close_all(dup)
		return .Err_No_Memory
	}
	f.dev, f.dev_ctx = &fd_dev, x
	return .Ok
}

// Builds the process's namespace from its spawn message: the group nsgroup
// names, or the mount= and bind= records.
@(require_results)
from_spawn :: proc "contextless" (space: ^ns.Namespace) -> vx.Status {
	p9.client_user = rt.spawn.user // its attaches name its user (upstream docs/11 §9)
	ns.dial_lock = dial_lock // a TCP connection's threads take turns
	space.getwd = rt.getwd // relative names from the current directory (ADR-0017)
	space.open_dev = fd_open // and /fd/N, its descriptors (ADR-0018)
	group.srv = rt.spawn_take("srv:nsd")
	st: vx.Status
	if chan := rt.spawn_take("nsgroup"); chan != vx.HANDLE_NONE {
		st = group_join(space, chan)
	} else {
		st = replay_records(space, rt.spawn.text, nil)
	}
	// Its parent's rfork m (RFNOMNT), after what it was given is in place.
	rec: ndb.Record
	space.nomount = rt.spawn_record("nomount", &rec)
	return st
}

@(private="file")
name_buf: [vx.CHANNEL_MAX_HANDLES][8]u8

// Writes a copy of the namespace as spawn records for a child, in the order
// the members were added (as ns.print writes them): a mount record for each
// mounted member, naming a duplicate of its connection's connector, added to
// handles (one "ns.NN" for each connection, NN its index there, however many
// mounts use it); a dial record for a member mounted over TCP, which the
// child dials too; and a bind record for the rest. The child connects to
// each server itself. handles[:first] are taken already; count is how many
// are taken after. On failure, the handles this added are closed and count
// is first.
@(require_results)
copy_records :: proc "contextless" (
	space: ^ns.Namespace,
	w: ^ndb.Writer,
	handles: []vx.Handle,
	names: []string,
	first: int,
) -> (
	count: int,
	st: vx.Status,
) {
	count = first
	defer if st != .Ok {
		rt.close_all(..handles[first:count])
		count = first
	}
	handle_of: [ns.MAX_CONNS]int // each connection's handle in this message, plus one; 0: none yet
	r := ns.replay_order(space)
	for step in ns.next_step(&r) {
		m := step.member
		path, from := ns.entry_path(step.entry), string(m.from[:])
		c := &space.conns[m.conn]
		switch {
		case m.mounted && c.connector == vx.HANDLE_NONE: // dialed: the child dials it too
			ndb.put(w, "mount", path)
			ndb.put(w, "dial", string(c.src[:]))
			if from != "" {
				ndb.put(w, "aname", from)
			}
		case m.mounted:
			if handle_of[m.conn] == 0 {
				if count == len(handles) || count >= vx.CHANNEL_MAX_HANDLES {
					return count, .Err_No_Memory
				}
				h, dst := rt.handle_dup(c.connector, vx.RIGHTS_SAME)
				if dst != .Ok {
					return count, .Err_No_Memory
				}
				handles[count] = h
				names[count] = handle_name(count)
				count += 1
				handle_of[m.conn] = count
			}
			ndb.put(w, "mount", path)
			ndb.put(w, "handle", names[handle_of[m.conn] - 1])
			if from != "" {
				ndb.put(w, "aname", from)
			}
			ndb.put(w, "src", string(c.src[:]))
		case:
			ndb.put(w, "bind", path)
			ndb.put(w, "new", from)
		}
		if step.flags != "" {
			ndb.put(w, "flags", step.flags)
		}
		_ = ndb.end(w)
	}
	return count, w.failed ? .Err_Range : .Ok
}

// The namespace for a child, as spawn records and handles (02 §2), and the
// current directory it starts in (cwd=, ADR-0017). As Plan
// 9's rfork shares a namespace unless asked not to, the child joins this
// process's namespace group, made now if this is the first child to share
// it: a channel to nsd for it ("nsgroup"). Without nsd, a copy
// (copy_records). Either way the child gets nsd's post too ("srv:nsd"), to
// make a group of its own. handles[:first] are taken already; count is how
// many are taken after. On failure, the handles this added are closed and
// count is first.
@(require_results)
spawn_records :: proc "contextless" (
	space: ^ns.Namespace,
	w: ^ndb.Writer,
	handles: []vx.Handle,
	names: []string,
	first: int,
) -> (
	count: int,
	st: vx.Status,
) {
	limit := min(len(handles), vx.CHANNEL_MAX_HANDLES)
	if first + 2 > limit {
		return first, .Err_No_Memory
	}
	wd: [rt.WD_MAX]u8 // the child starts where this process is (ADR-0017)
	if dir := rt.getwd(wd[:]); dir != "" {
		ndb.put(w, "cwd", dir)
		_ = ndb.end(w)
	}
	if space.nomount { // RFNOMNT, inherited
		ndb.flag(w, "nomount")
		_ = ndb.end(w)
	}
	count = first
	st = .Err_Not_Found
	if group.chan == vx.HANDLE_NONE {
		_ = group_make(space) // Err_Not_Found without nsd: a copy, below
	}
	if group.chan != vx.HANDLE_NONE {
		chan: [1]vx.Handle
		if _, st = nsd(group.chan, .Share, {}, "", "", nil, chan[:]); st == .Ok {
			handles[count], names[count] = chan[0], "nsgroup"
			count += 1
		}
	}
	if st != .Ok {
		count, st = copy_records(space, w, handles[:limit - 1], names, first)
	}
	if st == .Ok && group.srv != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(group.srv, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "srv:nsd"
			count += 1
		}
	}
	return
}

// "ns." and the index in two digits, as upstream names them: ns.03.
@(private="file")
handle_name :: proc "contextless" (index: int) -> string {
	b := str.Buf{buf = name_buf[index][:]}
	str.write_string(&b, index < 10 ? "ns.0" : "ns.")
	str.write_u64(&b, u64(index))
	return str.to_string(&b)
}

// Lets go of every connection here (the parent keeps its own), and of the
// connectors the table held.
@(private="file")
drop_conns :: proc "contextless" (space: ^ns.Namespace) {
	for &k, i in conns {
		if k.end != vx.HANDLE_NONE {
			rt.p9_disconnect(&k)
		}
		k = {}
		clear(&conn_names[i])
		rt.close_all(space.conns[i].connector)
	}
	getwd, open_dev := space.getwd, space.open_dev
	intrinsics.mem_zero(space, size_of(ns.Namespace)) // in place: too big to build on the stack first
	space.getwd, space.open_dev = getwd, open_dev // the process's, not the table's
}

@(private="file")
fork_records: [16 * 1024]u8

// After a fork (01 §9): the namespace's rings were not copied into this
// process, so its connections are let go, here only (the parent keeps its
// own), and the namespace is built again over new connections: from the
// group's text, through a channel of this process's own; or from its own
// records, through the connectors it kept. A dialed mount is dialed again;
// the old TCP connection's state is left behind.
@(require_results)
after_fork :: proc "contextless" (space: ^ns.Namespace) -> vx.Status {
	if group.chan != vx.HANDLE_NONE {
		// In a group: the channel to nsd and the mapping of its text were
		// copied from the parent's; this process gets a channel of its own,
		// maps the text again, and builds its table from it.
		chan: [1]vx.Handle
		_, st := nsd(group.chan, .Share, {}, "", "", nil, chan[:])
		_ = rt.handle_close(group.chan)
		// vx:rt has no as_unmap yet (the kernel's M4 port brings it): the call itself.
		_ = rt.vx_syscall(.As_Unmap, u64(rt.self), u64(uintptr(group.page)), PAGE_SIZE)
		drop_conns(space)
		group = {
			srv = group.srv,
		}
		return st == .Ok ? group_join(space, chan[0]) : st
	}
	handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES]string
	w := ndb.Writer {
		buf = fork_records[:],
	}
	count, st := copy_records(space, &w, handles[:], names[:], 0)
	drop_conns(space)
	if st != .Ok {
		return st
	}
	from := Handles {
		names   = names[:count],
		handles = handles[:count],
	}
	space.release = release
	st = replay_records(space, string(fork_records[:w.len]), &from)
	rt.close_all(..handles[:count]) // those the records did not use
	return st
}

// The connection the spawn message's i-th connector made, for a program that
// speaks to its server directly (nstest's hostile client).
conn :: proc "contextless" (i: int) -> ^rt.Conn {
	return &conns[i]
}

// Changes the current directory to path (ADR-0017): resolved, walked and
// found to be a directory, else refused (Err_Invalid if it is not one) and
// left as it was. libvx's (upstream's 6e1), until libvx.
@(require_results)
chdir :: proc "contextless" (space: ^ns.Namespace, path: string) -> vx.Status {
	buf: [ns.MAX_PATH]u8
	dir := ns.dir_check(space, path, buf[:]) or_return
	return rt.wd_set(dir) ? .Ok : .Err_Range
}
