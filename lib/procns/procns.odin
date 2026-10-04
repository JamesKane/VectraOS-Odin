// vx:procns, a process's namespace at start-up: it builds the namespace from
// the spawn message, whose mount= and bind= records are what its parent's
// template made, and writes it back out as spawn records for a child. A
// mount record names a connector handle in the message; each one gets its
// own ring connection to the server behind it. (lib/ns is the table itself,
// and builds for the host; this is its half that needs the runtime.)
package procns

import vx "abi:vx"
import "vx:ndb"
import "vx:ns"
import "vx:rt"
import "vx:str"

@(private="file")
conns: [ns.MAX_CONNS]rt.Conn

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

@(private="file")
scratch: [vx.CHANNEL_MAX_BYTES]u8

// Replays the spawn message's namespace records in order. Stops at the first
// that fails, and says which.
@(require_results)
from_spawn :: proc "contextless" (space: ^ns.Namespace) -> vx.Status {
	r := ndb.Reader{src = rt.spawn.text, scratch = scratch[:]}
	used := 0
	for {
		rec: ndb.Record
		if ndb.next(&r, &rec) != .Record {
			break
		}
		mount := ndb.has(&rec, "mount")
		if !mount && !ndb.has(&rec, "bind") {
			continue
		}
		if st := replay(space, &rec, mount, &used); st != .Ok {
			rt.print("vx-ns: cannot replay the record on line ", u64(rec.line), " of the spawn message\n")
			return st
		}
	}
	return .Ok
}

// One mount or bind record. A mount takes its connector from the spawn
// message, and the next free connection; on failure it closes both.
@(private="file", require_results)
replay :: proc "contextless" (space: ^ns.Namespace, rec: ^ndb.Record, mount: bool, used: ^int) -> (st: vx.Status) {
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
	name, _ := ndb.get(rec, "handle")
	connector := rt.spawn_take(name)
	defer if st != .Ok {
		rt.close_all(connector)
	}
	if connector == vx.HANDLE_NONE || used^ == ns.MAX_CONNS {
		return .Err_Not_Found
	}
	k := &conns[used^]
	rt.p9_connect(connector, k) or_return // which disconnects again if it fails
	src, _ := ndb.get(rec, "src")
	aname, _ := ndb.get(rec, "aname")
	old, _ := ndb.get(rec, "mount")
	if st = ns.mount(space, &k.c, connector, src, aname, old, flags); st != .Ok {
		rt.p9_disconnect(k)
		return st
	}
	used^ += 1
	return .Ok
}

@(private="file")
name_buf: [vx.CHANNEL_MAX_HANDLES][8]u8

// Writes the namespace as spawn records for a child (a child gets a copy of
// its parent's namespace), in the order ns.print uses: a mount record for
// each mounted member, with a duplicate of its connection's connector added
// to handles (named "ns.NN", NN its index there), and a bind record for the
// rest. The child connects to each server itself. handles[:first] are
// taken already; count is how many are taken after. On failure to
// duplicate, the handles this added are closed and count is first.
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
	for &e in space.entries {
		if e.path_len == 0 {
			continue
		}
		path := string(e.path[:e.path_len])
		for &m, k in e.members[:e.count] {
			from := string(m.from[:m.from_len])
			flags: [2]u8
			nf := 0
			if k > 0 {
				flags[nf] = 'a'
				nf += 1
			}
			if .Create in m.flags {
				flags[nf] = 'c'
				nf += 1
			}
			if m.mounted {
				c := &space.conns[m.conn]
				ok := count < len(handles) && count < vx.CHANNEL_MAX_HANDLES
				if ok {
					h, dst := rt.handle_dup(c.connector, vx.RIGHTS_SAME)
					handles[count] = h
					ok = dst == .Ok
				}
				if !ok {
					rt.close_all(..handles[first:count])
					return first, .Err_No_Memory
				}
				names[count] = handle_name(count)
				ndb.put(w, "mount", path)
				ndb.put(w, "handle", names[count])
				if from != "" {
					ndb.put(w, "aname", from)
				}
				ndb.put(w, "src", string(c.src[:c.src_len]))
				count += 1
			} else {
				ndb.put(w, "bind", path)
				ndb.put(w, "new", from)
			}
			if nf > 0 {
				ndb.put(w, "flags", string(flags[:nf]))
			}
			_ = ndb.end(w)
		}
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

// The connection the spawn message's i-th mount record made, for a program
// that speaks to its server directly (nstest's hostile client).
conn :: proc "contextless" (i: int) -> ^rt.Conn {
	return &conns[i]
}
