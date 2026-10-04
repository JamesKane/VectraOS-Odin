// vx:procns, a process's namespace at start-up: it builds the namespace from
// the spawn message, whose mount= and bind= records are what its parent's
// template made, and writes it back out as spawn records for a child. A
// mount record names a connector handle in the message; each connector gets
// its own ring connection to the server behind it, which every mount record
// naming it shares. A mount record with dial=ADDRESS instead is a 9P server
// over TCP, which the process dials itself (ns.dial), through the /net its
// earlier records gave it. (lib/ns is the table itself, and builds for the
// host; this is its half that needs the runtime.)
package procns

import vx "abi:vx"
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

// The connection through the connector the spawn message calls name: the one
// already made through it (and connector HANDLE_NONE, since the namespace
// has it already), or a new one, with the connector it took.
@(private="file", require_results)
connect :: proc "contextless" (name: string) -> (c: ^p9.Client, connector: vx.Handle, st: vx.Status) {
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
	connector = rt.spawn_take(name)
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

@(private="file")
scratch: [vx.CHANNEL_MAX_BYTES]u8

// Replays the spawn message's namespace records in order. Stops at the first
// that fails, and says which.
@(require_results)
from_spawn :: proc "contextless" (space: ^ns.Namespace) -> vx.Status {
	r := ndb.Reader{src = rt.spawn.text, scratch = scratch[:]}
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
		if st := replay(space, &rec, mount); st != .Ok {
			rt.print("vx-ns: cannot replay the record on line ", u64(rec.line), " of the spawn message\n")
			return st
		}
	}
	return .Ok
}

// One mount or bind record. A mount record with dial= dials its server; one
// with handle= connects through that connector, or shares the connection
// already made through it.
@(private="file", require_results)
replay :: proc "contextless" (space: ^ns.Namespace, rec: ^ndb.Record, mount: bool) -> vx.Status {
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
	c, connector := connect(name) or_return
	src, _ := ndb.get(rec, "src")
	return ns.mount(space, c, connector, src, aname, old, flags)
}

@(private="file")
name_buf: [vx.CHANNEL_MAX_HANDLES][8]u8

// Writes the namespace as spawn records for a child (a child gets a copy of
// its parent's namespace), in the order the members were added (as ns.print
// writes them): a mount record for each mounted member, naming a duplicate
// of its connection's connector, added to handles (one "ns.NN" for each
// connection, NN its index there, however many mounts use it); a dial record
// for a member mounted over TCP, which the child dials too; and a bind record
// for the rest. The child connects to each server itself. handles[:first]
// are taken already; count is how many are taken after. On failure, the
// handles this added are closed and count is first.
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

// "ns." and the index in two digits, as upstream names them: ns.03.
@(private="file")
handle_name :: proc "contextless" (index: int) -> string {
	b := str.Buf{buf = name_buf[index][:]}
	str.write_string(&b, index < 10 ? "ns.0" : "ns.")
	str.write_u64(&b, u64(index))
	return str.to_string(&b)
}

// The connection the spawn message's i-th connector made, for a program that
// speaks to its server directly (nstest's hostile client).
conn :: proc "contextless" (i: int) -> ^rt.Conn {
	return &conns[i]
}
