// nsd: namespace groups (upstream ADR-0009), posted as /srv/nsd. The
// protocol is lib/ns/nsd.odin.
//
// A group is the namespace(6) text its members share, the connectors its
// mount lines name, and a VMO holding the text, which nsd writes and each
// member maps read-only. Each member has its own channel here; nsd waits on
// one port for its listen channel and every member channel, and a group goes
// when its last member does. It keeps no other state: a member resolves names
// from its own copy, made from the text.
//
// nsd is not restarted: the groups live only in it (upstream
// docs/milestones.md).
package nsd

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:ns"
import "vx:rt"

MAX_GROUPS :: 32
MAX_MEMBERS :: 128
// A group's connectors: 8, as upstream's nsd keeps them, though M5 gave a
// namespace 16 connections (ns.MAX_CONNS) for fsd's branches.
MAX_CONNECTORS :: 8
SRC_MAX :: 64 // a connector's source is shorter

#assert(MAX_CONNECTORS <= ns.MAX_CONNS)

@(private="file")
PAGE_BYTES :: (size_of(ns.Nsd_Page) + memory.PAGE_SIZE - 1) / memory.PAGE_SIZE * memory.PAGE_SIZE

Connector :: struct {
	src:       [dynamic; SRC_MAX - 1]u8, // empty: the slot is free
	connector: vx.Handle,
}

Group :: struct {
	used:    bool,
	vmo:     vx.Handle,
	page:    ^ns.Nsd_Page,
	members: u32,
	conns:   [MAX_CONNECTORS]Connector,
}

Member :: struct {
	used:  bool,
	gen:   u32,
	chan:  vx.Handle,
	group: ^Group,
	task:  u64, // as it said (.New, .Hello), for /proc/N/ns
}

// Not file-private: tests/host looks at them.
groups: [MAX_GROUPS]Group
members: [MAX_MEMBERS]Member
@(private="file")
port, listen_ch: vx.Handle

// The port keys. A member's carry its slot and the slot's generation, so a
// packet from a binding on a member that has gone is never taken for one
// about its slot's next member.
@(private="file")
Key_Kind :: enum u8 {
	None,
	Listen,
	Readable,
	Closed,
}

@(private="file")
Port_Key :: bit_field u64 {
	kind: Key_Kind | 8,
	slot: u32      | 24,
	gen:  u32      | 32,
}
#assert(size_of(Port_Key) == 8)

@(private="file")
member_key :: proc "contextless" (kind: Key_Kind, m: ^Member) -> u64 {
	slot := u32((uintptr(m) - uintptr(&members[0])) / size_of(Member))
	return transmute(u64)Port_Key{kind = kind, slot = slot, gen = m.gen}
}

@(private="file")
LISTEN_KEY :: u64(Key_Kind.Listen) // slot and generation 0

// A message: the protocol's header and args, then text and names.
@(private="file")
Message :: struct #raw_union {
	msg:   ns.Nsd_Msg,
	bytes: [vx.CHANNEL_MAX_BYTES]u8,
}

@(private="file")
in_msg: Message
@(private="file")
out_msg: Message
@(private="file")
in_handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle

@(private="file")
source_of :: proc "contextless" (c: ^Connector) -> string {
	return string(c.src[:])
}

// Writes the group's text, as its members read it: the sequence odd while it
// changes, even again after (lib/procns reads it so).
@(private="file")
publish :: proc "contextless" (g: ^Group, text: string) {
	page := g.page
	seq := intrinsics.atomic_load_explicit(&page.seq, .Relaxed)
	intrinsics.atomic_store_explicit(&page.seq, seq + 1, .Relaxed)
	intrinsics.atomic_thread_fence(.Release)
	copy(page.text[:], text)
	intrinsics.volatile_store(&page.len, u32(len(text)))
	intrinsics.atomic_store_explicit(&page.seq, seq + 2, .Release)
}

@(private="file")
seq_of :: proc "contextless" (g: ^Group) -> u64 {
	return intrinsics.atomic_load_explicit(&g.page.seq, .Relaxed)
}

// Adds the connectors a .New or .Update carried, named by the lines after
// its text; a source the group has already keeps its connector, and the new
// handle is closed. All or nothing: false (and nothing taken, the caller
// closing every handle) if the names do not match or there is no room.
@(require_results)
add_connectors :: proc "contextless" (g: ^Group, names: string, handles: []vx.Handle) -> bool {
	if len(handles) > vx.CHANNEL_MAX_HANDLES {
		return false
	}
	srcs: [vx.CHANNEL_MAX_HANDLES]string
	known: [vx.CHANNEL_MAX_HANDLES]bool
	free_slots, needed := 0, 0
	for &c in g.conns {
		if len(c.src) == 0 {
			free_slots += 1
		}
	}
	rest := names
	for i in 0 ..< len(handles) { // first, every name checked and the room counted
		end := 0
		for end < len(rest) && rest[end] != '\n' {
			end += 1
		}
		srcs[i] = rest[:end]
		rest = rest[min(end + 1, len(rest)):]
		if srcs[i] == "" || len(srcs[i]) >= SRC_MAX {
			return false
		}
		for &c in g.conns {
			if len(c.src) > 0 && source_of(&c) == srcs[i] {
				known[i] = true
			}
		}
		for j in 0 ..< i {
			if srcs[j] == srcs[i] {
				known[i] = true // named twice
			}
		}
		if !known[i] {
			needed += 1
		}
	}
	if needed > free_slots {
		return false
	}
	for h, i in handles { // then taken
		if known[i] {
			_ = rt.handle_close(h)
			continue
		}
		for &c in g.conns {
			if len(c.src) == 0 {
				_ = append(&c.src, srcs[i]) // it fits: checked above
				c.connector = h
				break
			}
		}
	}
	return true
}

@(private="file")
forget_group :: proc "contextless" (g: ^Group) {
	for &c in g.conns {
		if len(c.src) > 0 {
			_ = rt.handle_close(c.connector)
		}
	}
	if g.page != nil {
		// vx:rt has no as_unmap yet (the kernel's M4 port brings it): the call itself.
		_ = rt.vx_syscall(.As_Unmap, u64(rt.self), u64(uintptr(g.page)), PAGE_BYTES)
	}
	rt.close_all(g.vmo)
	g^ = {}
}

// A new member of g: a channel pair, nsd keeping one end. Returns the other.
@(private="file")
add_member :: proc "contextless" (g: ^Group) -> vx.Handle {
	slot := 0
	for slot < MAX_MEMBERS && members[slot].used {
		slot += 1
	}
	if slot == MAX_MEMBERS {
		return vx.HANDLE_NONE
	}
	mine, theirs, st := rt.channel_create()
	if st != .Ok {
		return vx.HANDLE_NONE
	}
	m := &members[slot]
	m^ = {used = true, gen = m.gen + 1, chan = mine, group = g}
	g.members += 1
	_ = rt.port_bind(port, mine, .Readable, member_key(.Readable, m))
	_ = rt.port_bind(port, mine, .Peer_Closed, member_key(.Closed, m))
	return theirs
}

@(private="file")
drop_member :: proc "contextless" (m: ^Member) {
	g := m.group
	_ = rt.handle_close(m.chan)
	m^ = {gen = m.gen}
	if g != nil {
		g.members -= 1
		if g.members == 0 {
			forget_group(g)
		}
	}
}

@(private="file")
reply :: proc "contextless" (ch: vx.Handle, txid: u32, st: vx.Status, seq: u64, text: string, give: []vx.Handle) {
	r := &out_msg.msg
	r^ = {
		header = {txid = txid, flags = u32(i32(st))},
		args = {seq = seq, text_len = u32(len(text))},
	}
	n := copy(out_msg.bytes[size_of(ns.Nsd_Msg):], text)
	if rt.channel_write(ch, out_msg.bytes[:size_of(ns.Nsd_Msg) + n], give) != .Ok {
		rt.close_all(..give) // the caller has gone
	}
}

// A read-only handle to g's VMO, for a member to map.
@(private="file")
page_for :: proc "contextless" (g: ^Group) -> vx.Handle {
	h, _ := rt.handle_dup(g.vmo, {.Read, .Map, .Duplicate, .Transfer})
	return h
}

// The text and names after a message's args; ok is false if text_len says
// more than came.
@(private="file")
body_of :: proc "contextless" (m: ^ns.Nsd_Msg, size: int) -> (text, names: string, ok: bool) {
	body := string(in_msg.bytes[size_of(ns.Nsd_Msg):size])
	if u64(m.args.text_len) > u64(len(body)) {
		return "", "", false
	}
	return body[:m.args.text_len], body[m.args.text_len:], true
}

// .New, on the listen channel: a group, and its first member.
@(private="file")
new_group :: proc "contextless" (m: ^ns.Nsd_Msg, size: int, handles: []vx.Handle) {
	left := handles // closed at the end, unless a group takes them
	st := vx.Status.Err_No_Memory
	g: ^Group
	for &x in groups {
		if !x.used {
			g = &x
			break
		}
	}
	text, names, ok := body_of(m, size)
	if !ok || m.args.text_len > ns.NSD_TEXT_MAX || int(m.args.count) != len(handles) {
		st = .Err_Invalid
	} else if g != nil {
		g^ = {used = true}
		g.vmo, st = rt.vmo_create(PAGE_BYTES)
		va: u64
		if st == .Ok {
			va, st = rt.as_map(rt.self, g.vmo, 0, PAGE_BYTES, {.Write})
		}
		if st == .Ok {
			g.page = (^ns.Nsd_Page)(uintptr(va))
			st = add_connectors(g, names, handles) ? .Ok : .Err_Invalid
			if st == .Ok {
				left = nil // add_connectors took them; else they are closed below
			}
		}
	}
	give: [2]vx.Handle
	if st == .Ok {
		publish(g, text)
		give[0] = add_member(g)
		give[1] = page_for(g)
		for &x in members { // the member just made is the caller
			if x.used && x.group == g {
				x.task = m.args.task
			}
		}
		if give[0] == vx.HANDLE_NONE || give[1] == vx.HANDLE_NONE {
			st = .Err_No_Memory
			rt.close_all(..give[:]) // the reply gives none
		}
	}
	rt.close_all(..left)
	if st != .Ok && g != nil {
		for &x in members {
			if x.used && x.group == g {
				drop_member(&x)
			}
		}
		if g.used {
			forget_group(g)
		}
	}
	if st == .Ok {
		reply(listen_ch, m.header.txid, st, seq_of(g), "", give[:])
	} else {
		reply(listen_ch, m.header.txid, st, 0, "", nil)
	}
}

// .Text, on the listen channel: the namespace of the group a task is in.
@(private="file")
text_of :: proc "contextless" (m: ^ns.Nsd_Msg) {
	for &x in members {
		if !x.used || x.task != m.args.task {
			continue
		}
		page := x.group.page
		n := min(int(page.len), ns.NSD_TEXT_MAX)
		reply(listen_ch, m.header.txid, .Ok, seq_of(x.group), string(page.text[:n]), nil)
		return
	}
	reply(listen_ch, m.header.txid, .Err_Not_Found, 0, "", nil)
}

// A call on a member's channel.
@(private="file")
member_call :: proc "contextless" (x: ^Member, m: ^ns.Nsd_Msg, size: int, handles: []vx.Handle) {
	g := x.group
	left := handles // closed at the end, unless the group takes them
	st := vx.Status.Ok
	give := vx.HANDLE_NONE
	text, names, ok := body_of(m, size)
	switch ns.Nsd_Call(m.header.ordinal) {
	case .Share:
		give = add_member(g)
		st = give != vx.HANDLE_NONE ? .Ok : .Err_No_Memory
	case .Hello:
		x.task = m.args.task
		give = page_for(g)
		st = give != vx.HANDLE_NONE ? .Ok : .Err_No_Memory
	case .Update:
		if !ok || m.args.text_len > ns.NSD_TEXT_MAX || int(m.args.count) != len(handles) {
			st = .Err_Invalid
		} else if m.args.seq != seq_of(g) {
			st = .Err_Bad_State // stale: another member changed the group first
		} else if !add_connectors(g, names, handles) {
			st = .Err_No_Memory
		}
		if st == .Ok {
			left = nil
			publish(g, text)
		}
	case .Connector:
		st = ok ? .Err_Not_Found : .Err_Invalid
		for &c in g.conns {
			if st == .Err_Not_Found && len(c.src) > 0 && source_of(&c) == text {
				give, st = rt.handle_dup(c.connector, vx.RIGHTS_SAME)
			}
		}
	case .New, .Text:
		st = .Err_Invalid
	case:
		st = .Err_Invalid
	}
	rt.close_all(..left)
	gives := [1]vx.Handle{give}
	reply(x.chan, m.header.txid, st, seq_of(g), "", give != vx.HANDLE_NONE ? gives[:] : nil)
}

// Reads every message waiting on ch; x is its member, or nil for the listen
// channel.
@(private="file")
drain :: proc "contextless" (ch: vx.Handle, x: ^Member) {
	for {
		size, st := rt.channel_read(ch, in_msg.bytes[:], in_handles[:])
		if st != .Ok {
			return // empty, or gone (PEER_CLOSED says so)
		}
		handles := in_handles[:size.handles]
		if size.bytes < size_of(ns.Nsd_Msg) {
			rt.close_all(..handles)
			continue
		}
		m := &in_msg.msg
		switch {
		case x != nil:
			member_call(x, m, int(size.bytes), handles)
		case m.header.ordinal == u32(ns.Nsd_Call.New):
			new_group(m, int(size.bytes), handles)
		case m.header.ordinal == u32(ns.Nsd_Call.Text):
			text_of(m)
			rt.close_all(..handles)
		case:
			rt.close_all(..handles)
			reply(listen_ch, m.header.txid, .Err_Invalid, 0, "", nil)
		}
		if x != nil && !x.used {
			return // a .New's failure can drop members, but never the caller's
		}
	}
}

// Takes the listen channel and makes the port: false (and said) without
// them. Not file-private, nor is handle: tests/host drives nsd a packet at a
// time.
start :: proc "contextless" () -> bool {
	listen_ch = rt.spawn_take("listen")
	pst: vx.Status
	if listen_ch != vx.HANDLE_NONE {
		port, pst = rt.port_create()
	}
	if listen_ch == vx.HANDLE_NONE || pst != .Ok {
		rt.print("nsd: no listen channel\n")
		return false
	}
	_ = rt.port_bind(port, listen_ch, .Readable, LISTEN_KEY)
	rt.print("nsd: serving /srv/nsd\n")
	return true
}

// One packet from the port: the listen channel's, or a member's.
handle :: proc "contextless" (p: vx.Packet) {
	key := transmute(Port_Key)p.key
	if key.kind == .Listen {
		drain(listen_ch, nil)
		_ = rt.port_bind(port, listen_ch, .Readable, LISTEN_KEY)
		return
	}
	if key.slot >= MAX_MEMBERS {
		return
	}
	x := &members[key.slot]
	if !x.used || x.gen != key.gen {
		return // an earlier member's
	}
	drain(x.chan, x) // and if it has gone, what it sent before it went
	if !x.used {
		return
	}
	if key.kind == .Closed {
		drop_member(x)
	} else {
		_ = rt.port_bind(port, x.chan, .Readable, member_key(.Readable, x))
	}
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	if !start() {
		return -1 // upstream's exit string: "no listen channel"
	}
	for {
		pk: [16]vx.Packet
		n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:n] {
			handle(p)
		}
	}
}
