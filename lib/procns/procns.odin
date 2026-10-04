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
		fv, _ := ndb.get(&rec, "flags")
		flags, fok := parse_flags(fv)
		st := fok ? vx.Status.Ok : vx.Status.Err_Invalid
		if st == .Ok && mount {
			name, _ := ndb.get(&rec, "handle")
			connector := rt.spawn_take(name)
			if connector == 0 || used == ns.MAX_CONNS {
				st = .Err_Not_Found
			}
			if st == .Ok {
				st = rt.p9_connect(connector, &conns[used])
			}
			if st == .Ok {
				src, _ := ndb.get(&rec, "src")
				aname, _ := ndb.get(&rec, "aname")
				old, _ := ndb.get(&rec, "mount")
				st = ns.mount(space, &conns[used].c, connector, src, aname, old, flags)
			}
			if st == .Ok {
				used += 1
			} else {
				if used < ns.MAX_CONNS && conns[used].end != 0 {
					rt.p9_disconnect(&conns[used])
				}
				if connector != 0 {
					_ = rt.handle_close(connector)
				}
			}
		} else if st == .Ok {
			nw, _ := ndb.get(&rec, "new")
			b, _ := ndb.get(&rec, "bind")
			st = ns.bind(space, nw, b, flags)
		}
		if st != .Ok {
			rt.print("vx-ns: cannot replay the record on line ")
			rt.print_u64(u64(rec.line))
			rt.print(" of the spawn message\n")
			return st
		}
	}
	return .Ok
}

@(private="file")
name_buf: [vx.CHANNEL_MAX_HANDLES][8]u8

// Writes the namespace as spawn records for a child (a child gets a copy of
// its parent's namespace), in the order ns.print uses: a mount record for
// each mounted member, with a duplicate of its connection's connector added
// to handles (named "ns.N"), and a bind record for the rest. The child
// connects to each server itself. count is how many handles are already
// there, and grows; on failure the handles this added are closed.
spawn_records :: proc "contextless" (space: ^ns.Namespace, w: ^ndb.Writer, handles: []vx.Handle, names: []string, count: ^int) -> vx.Status {
	first := count^
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
				ok := count^ < len(handles) && count^ < vx.CHANNEL_MAX_HANDLES
				if ok {
					h, st := rt.handle_dup(c.connector, vx.RIGHTS_SAME)
					handles[count^] = h
					ok = st == .Ok
				}
				if !ok {
					for h in handles[first:count^] {
						_ = rt.handle_close(h)
					}
					count^ = first
					return .Err_No_Memory
				}
				n := &name_buf[count^]
				n^ = {'n', 's', '.', u8('0' + count^ / 10), u8('0' + count^ % 10), 0, 0, 0}
				names[count^] = string(n[:5])
				ndb.put(w, "mount", path)
				ndb.put(w, "handle", names[count^])
				if from != "" {
					ndb.put(w, "aname", from)
				}
				ndb.put(w, "src", string(c.src[:c.src_len]))
				count^ += 1
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
	return w.failed ? .Err_Range : .Ok
}
