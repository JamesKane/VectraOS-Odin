// servers/nsd on the host: the program itself, linked against lib/rt, with a
// fake kernel underneath that keeps channels (pairs of message queues),
// VMOs mapped from an arena, duplicates and port bindings. nsd's start takes
// its listen channel; the test then plays its members, writing nsd's
// protocol (lib/ns/nsd.odin) on their channels and handing nsd the packet
// its port would have had, keyed as nsd bound it, one at a time (nsd.handle).
//
// Upstream has no host test of nsd; these cases follow its nsd.c and
// ADR-0009: a group made by NEW with its first member and connectors, its
// text published in a page after an even sequence, HELLO, SHARE, UPDATE (and
// a stale one refused), CONNECTOR, TEXT for procfs, malformed calls, the
// connector table full, and the group gone with its last member.
package nsd_test

import vx "abi:vx"
import "core:testing"
import "vx:ns"
import "vx:rt"
import nsd "../../../servers/nsd"

MAX_OBJECTS :: 256
MAX_QUEUE :: 4
MAX_BINDINGS :: 512
HANDLE_BASE :: 0x100

Kind :: enum {
	Free,
	Port,
	Channel,
	Vmo,
	Token, // a handle given by the test, standing for a connector
}

Message :: struct {
	bytes:   [dynamic; size_of(ns.Nsd_Msg) + ns.NSD_TEXT_MAX + 256]u8,
	handles: [dynamic; vx.CHANNEL_MAX_HANDLES]vx.Handle,
}

Object :: struct {
	kind:        Kind,
	closed:      bool,
	of:          vx.Handle, // a duplicate's original (a token's, a VMO's)
	rights:      vx.Rights,
	// A channel end: its peer, and the messages written to it.
	peer:        vx.Handle,
	queue:       [MAX_QUEUE]Message,
	head, count: int,
	// A VMO: where it is mapped.
	memory:      rawptr,
}

Binding :: struct {
	source:  vx.Handle,
	trigger: vx.Trigger,
	key:     u64,
}

objects: [MAX_OBJECTS]Object
bindings: [dynamic; MAX_BINDINGS]Binding
arena: [8 * 20 * 1024]u8
arena_used: int
unmaps: int
kernel_log: [1024]u8
kernel_log_len: int

object :: proc "contextless" (h: vx.Handle) -> ^Object {
	i := int(h) - HANDLE_BASE
	if i < 0 || i >= MAX_OBJECTS || objects[i].kind == .Free || objects[i].closed {
		return nil
	}
	return &objects[i]
}

new_handle :: proc "contextless" (kind: Kind) -> vx.Handle {
	for &o, i in objects {
		if o.kind == .Free {
			o = {kind = kind}
			return vx.Handle(HANDLE_BASE + i)
		}
	}
	return vx.HANDLE_NONE
}

// The VMO a handle names, through any duplicates.
original :: proc "contextless" (h: vx.Handle) -> ^Object {
	o := object(h)
	for o != nil && o.of != vx.HANDLE_NONE {
		o = &objects[int(o.of) - HANDLE_BASE]
	}
	return o
}

write :: proc "contextless" (ch: vx.Handle, bytes: []u8, handles: []vx.Handle) -> vx.Status {
	o := object(ch)
	if o == nil || o.kind != .Channel {
		return .Err_Bad_Handle
	}
	p := object(o.peer)
	if p == nil {
		return .Err_Peer_Closed
	}
	if p.count == MAX_QUEUE {
		return .Err_Should_Wait
	}
	m := &p.queue[(p.head + p.count) % MAX_QUEUE]
	clear(&m.bytes)
	clear(&m.handles)
	_ = append(&m.bytes, ..bytes)
	_ = append(&m.handles, ..handles)
	p.count += 1
	return .Ok
}

read :: proc "contextless" (ch: vx.Handle, bytes: []u8, handles: []vx.Handle) -> (size: vx.Msg_Size, st: vx.Status) {
	o := object(ch)
	if o == nil || o.kind != .Channel {
		return {}, .Err_Bad_Handle
	}
	if o.count == 0 {
		return {}, object(o.peer) == nil ? .Err_Peer_Closed : .Err_Should_Wait
	}
	m := &o.queue[o.head]
	if len(m.bytes) > len(bytes) || len(m.handles) > len(handles) {
		return {u32(len(m.bytes)), u32(len(m.handles))}, .Err_Too_Small
	}
	copy(bytes, m.bytes[:])
	copy(handles, m.handles[:])
	o.head = (o.head + 1) % MAX_QUEUE
	o.count -= 1
	return {u32(len(m.bytes)), u32(len(m.handles))}, .Ok
}

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	out :: proc "contextless" (at: u64, h: vx.Handle) {
		(^vx.Handle)(uintptr(at))^ = h
	}
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Port_Create:
		out(a1, new_handle(.Port))
		return 0
	case .Port_Bind:
		_ = append(&bindings, Binding{vx.Handle(a1), vx.Trigger(a2), a3})
		return 0
	case .Channel_Create:
		a, b := new_handle(.Channel), new_handle(.Channel)
		object(a).peer, object(b).peer = b, a
		hs := ([^]vx.Handle)(uintptr(a1))
		hs[0], hs[1] = a, b
		return 0
	case .Channel_Write:
		st := write(vx.Handle(a0), ([^]u8)(uintptr(a1))[:a2], ([^]vx.Handle)(uintptr(a3))[:a4])
		return i64(st)
	case .Channel_Read:
		size, st := read(vx.Handle(a0), ([^]u8)(uintptr(a1))[:a2], ([^]vx.Handle)(uintptr(a3))[:a4])
		(^vx.Msg_Size)(uintptr(a5))^ = size
		return i64(st)
	case .Vmo_Create:
		out(a2, new_handle(.Vmo))
		return 0
	case .As_Map:
		v := original(vx.Handle(a1))
		if v == nil || v.kind != .Vmo || int(a3) > len(arena) - arena_used {
			return i64(vx.Status.Err_Bad_Handle)
		}
		v.memory = &arena[arena_used]
		arena_used += int(a3)
		(^u64)(uintptr(a5))^ = u64(uintptr(v.memory))
		return 0
	case .As_Unmap:
		unmaps += 1
		return 0
	case .Handle_Dup:
		o := object(vx.Handle(a0))
		if o == nil {
			return i64(vx.Status.Err_Bad_Handle)
		}
		d := new_handle(o.kind)
		object(d).of = vx.Handle(a0)
		object(d).rights = transmute(vx.Rights)u32(a1)
		out(a2, d)
		return 0
	case .Handle_Close:
		o := object(vx.Handle(a0))
		if o == nil {
			return i64(vx.Status.Err_Bad_Handle)
		}
		o.closed = true
		return 0
	}
	return i64(vx.Status.Err_Unsupported)
}

// --- The members' side ---

msg_buf: Message

// Sends call on ch: args, text and names, with handles.
call :: proc(ch: vx.Handle, c: ns.Nsd_Call, args: ns.Nsd_Args, text := "", names := "", handles: []vx.Handle = nil, txid := u32(7)) -> vx.Status {
	m := ns.Nsd_Msg {
		header = {txid = txid, ordinal = u32(c)},
		args = args,
	}
	m.args.text_len = u32(len(text))
	bytes := make([dynamic]u8, context.temp_allocator)
	append(&bytes, ..([^]u8)(&m)[:size_of(m)])
	append(&bytes, text)
	append(&bytes, names)
	return write(ch, bytes[:], handles)
}

Reply :: struct {
	status:  vx.Status,
	txid:    u32,
	seq:     u64,
	text:    string,
	handles: []vx.Handle,
}

// The reply waiting on ch.
reply :: proc(t: ^testing.T, ch: vx.Handle, loc := #caller_location) -> (r: Reply) {
	buf := make([]u8, vx.CHANNEL_MAX_BYTES, context.temp_allocator)
	hs := make([]vx.Handle, vx.CHANNEL_MAX_HANDLES, context.temp_allocator)
	size, st := read(ch, buf, hs)
	testing.expect_value(t, st, vx.Status.Ok, loc = loc)
	if st != .Ok || size.bytes < size_of(ns.Nsd_Msg) {
		return {status = .Err_Invalid}
	}
	m := (^ns.Nsd_Msg)(raw_data(buf))
	return {
		status = vx.Status(i32(m.header.flags)),
		txid = m.header.txid,
		seq = m.args.seq,
		text = string(buf[size_of(ns.Nsd_Msg):][:m.args.text_len]),
		handles = hs[:size.handles],
	}
}

// The packet nsd's port would have for its end of ch, the client's end.
packet :: proc(ch: vx.Handle, trigger: vx.Trigger) -> vx.Packet {
	theirs := object(ch).peer
	#reverse for b in bindings {
		if b.source == theirs && b.trigger == trigger {
			return {key = b.key, trigger = trigger}
		}
	}
	return {key = ~u64(0)}
}

LISTEN_KEY_PACKET :: vx.Packet{key = 1, trigger = .Readable}

page_of :: proc(vmo: vx.Handle) -> ^ns.Nsd_Page {
	return (^ns.Nsd_Page)(original(vmo).memory)
}

page_text :: proc(p: ^ns.Nsd_Page) -> string {
	return string(p.text[:p.len])
}

token :: proc() -> vx.Handle {
	return new_handle(.Token)
}

closed :: proc(h: vx.Handle) -> bool {
	return objects[int(h) - HANDLE_BASE].closed
}

@(test)
test_nsd :: proc(t: ^testing.T) {
	listen_ours, listen_nsd, _ := rt.channel_create()
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "listen", listen_nsd
	rt.spawn.handle_count = 1
	testing.expect(t, nsd.start())
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "nsd: serving /srv/nsd\n")

	// NEW: a group from a namespace's text and its connectors, named by the
	// lines after the text; the caller its first member.
	conn_a := token()
	text1 := "mount /srv/a /\nbind -a /bin /x\n"
	testing.expect_value(t, call(listen_ours, .New, {task = 5, count = 1}, text1, "/srv/a\n", {conn_a}, 11), vx.Status.Ok)
	nsd.handle(LISTEN_KEY_PACKET)
	r := reply(t, listen_ours)
	testing.expect_value(t, r.status, vx.Status.Ok)
	testing.expect_value(t, r.txid, 11)
	testing.expect_value(t, r.seq, 2)
	testing.expect_value(t, len(r.handles), 2)
	m1, vmo1 := r.handles[0], r.handles[1]
	testing.expect_value(t, object(vmo1).rights, vx.Rights{.Read, .Map, .Duplicate, .Transfer})
	page := page_of(vmo1)
	testing.expect_value(t, page.seq, 2)
	testing.expect_value(t, page_text(page), text1)
	testing.expect_value(t, closed(conn_a), false) // the group keeps it
	testing.expect_value(t, nsd.groups[0].members, 1)

	// HELLO: a member says who it is, and gets the page.
	testing.expect_value(t, call(m1, .Hello, {task = 6}), vx.Status.Ok)
	nsd.handle(packet(m1, .Readable))
	r = reply(t, m1)
	testing.expect_value(t, r.status, vx.Status.Ok)
	testing.expect_value(t, r.seq, 2)
	testing.expect_value(t, len(r.handles), 1)
	testing.expect_value(t, original(r.handles[0]), original(vmo1))

	// TEXT, on the listen channel: the text of the group a task is in.
	_ = call(listen_ours, .Text, {task = 6})
	nsd.handle(LISTEN_KEY_PACKET)
	r = reply(t, listen_ours)
	testing.expect_value(t, r.status, vx.Status.Ok)
	testing.expect_value(t, r.text, text1)
	_ = call(listen_ours, .Text, {task = 5}) // HELLO said 6: 5 is no one's now
	nsd.handle(LISTEN_KEY_PACKET)
	r = reply(t, listen_ours)
	testing.expect_value(t, r.status, vx.Status.Err_Not_Found)

	// UPDATE from the sequence it was made on, with a new connector and one
	// the group has already (whose handle is closed).
	conn_b, conn_a2 := token(), token()
	text2 := "mount /srv/a /\nmount /srv/b /n\n"
	_ = call(m1, .Update, {seq = 2, count = 2}, text2, "/srv/b\n/srv/a\n", {conn_b, conn_a2})
	nsd.handle(packet(m1, .Readable))
	r = reply(t, m1)
	testing.expect_value(t, r.status, vx.Status.Ok)
	testing.expect_value(t, r.seq, 4)
	testing.expect_value(t, page.seq, 4)
	testing.expect_value(t, page_text(page), text2)
	testing.expect_value(t, closed(conn_b), false)
	testing.expect_value(t, closed(conn_a2), true)

	// A stale UPDATE is refused, and its handles closed.
	conn_c := token()
	_ = call(m1, .Update, {seq = 2, count = 1}, "x\n", "/srv/c\n", {conn_c})
	nsd.handle(packet(m1, .Readable))
	r = reply(t, m1)
	testing.expect_value(t, r.status, vx.Status.Err_Bad_State)
	testing.expect_value(t, r.seq, 4)
	testing.expect_value(t, page_text(page), text2)
	testing.expect_value(t, closed(conn_c), true)

	// Malformed: a count that is not the handles', names that do not match,
	// a text longer than came.
	conn_d := token()
	_ = call(m1, .Update, {seq = 4, count = 2}, "y\n", "/srv/d\n", {conn_d})
	nsd.handle(packet(m1, .Readable))
	testing.expect_value(t, reply(t, m1).status, vx.Status.Err_Invalid)
	testing.expect_value(t, closed(conn_d), true)
	conn_e := token()
	_ = call(m1, .Update, {seq = 4, count = 1}, "y\n", "", {conn_e}) // no name for it
	nsd.handle(packet(m1, .Readable))
	testing.expect_value(t, reply(t, m1).status, vx.Status.Err_No_Memory)
	testing.expect_value(t, closed(conn_e), true)
	{
		bad := ns.Nsd_Msg {
			header = {txid = 3, ordinal = u32(ns.Nsd_Call.Update)},
			args = {seq = 4, text_len = 100},
		}
		_ = write(m1, ([^]u8)(&bad)[:size_of(bad)], nil)
		nsd.handle(packet(m1, .Readable))
		testing.expect_value(t, reply(t, m1).status, vx.Status.Err_Invalid)
	}
	_ = call(m1, .New, {}) // NEW is the listen channel's
	nsd.handle(packet(m1, .Readable))
	testing.expect_value(t, reply(t, m1).status, vx.Status.Err_Invalid)
	_ = write(m1, {1, 2, 3}, nil) // shorter than a message: dropped, unanswered
	nsd.handle(packet(m1, .Readable))
	testing.expect_value(t, object(m1).count, 0)
	testing.expect_value(t, page_text(page), text2)

	// CONNECTOR: a duplicate of the connector for a source the group has.
	_ = call(m1, .Connector, {}, "/srv/b")
	nsd.handle(packet(m1, .Readable))
	r = reply(t, m1)
	testing.expect_value(t, r.status, vx.Status.Ok)
	testing.expect_value(t, len(r.handles), 1)
	testing.expect_value(t, object(r.handles[0]).of, conn_b)
	testing.expect_value(t, object(r.handles[0]).rights, vx.RIGHTS_SAME)
	_ = call(m1, .Connector, {}, "/srv/nope")
	nsd.handle(packet(m1, .Readable))
	testing.expect_value(t, reply(t, m1).status, vx.Status.Err_Not_Found)

	// The table of connectors is full at eight: all or nothing.
	names := "/srv/1\n/srv/2\n/srv/3\n/srv/4\n/srv/5\n/srv/6\n/srv/7\n"
	more: [7]vx.Handle
	for &h in more {
		h = token()
	}
	_ = call(m1, .Update, {seq = 4, count = 7}, "z\n", names, more[:])
	nsd.handle(packet(m1, .Readable))
	testing.expect_value(t, reply(t, m1).status, vx.Status.Err_No_Memory) // two taken, six free
	for h in more {
		testing.expect(t, closed(h))
	}
	testing.expect_value(t, page_text(page), text2)

	// SHARE: a channel for another member, as a child that shares the group
	// is given.
	_ = call(m1, .Share, {})
	nsd.handle(packet(m1, .Readable))
	r = reply(t, m1)
	testing.expect_value(t, r.status, vx.Status.Ok)
	testing.expect_value(t, len(r.handles), 1)
	m2 := r.handles[0]
	testing.expect_value(t, nsd.groups[0].members, 2)
	_ = call(m2, .Hello, {task = 9})
	nsd.handle(packet(m2, .Readable))
	r = reply(t, m2)
	testing.expect_value(t, r.status, vx.Status.Ok)
	_ = call(m2, .Update, {seq = 4}, "mount /srv/b /\n")
	nsd.handle(packet(m2, .Readable))
	testing.expect_value(t, reply(t, m2).seq, 6)
	testing.expect_value(t, page_text(page), "mount /srv/b /\n")

	// A second group, apart from the first.
	_ = call(listen_ours, .New, {task = 20}, "")
	nsd.handle(LISTEN_KEY_PACKET)
	r = reply(t, listen_ours)
	testing.expect_value(t, r.status, vx.Status.Ok)
	m3, vmo3 := r.handles[0], r.handles[1]
	testing.expect(t, original(vmo3) != original(vmo1))
	testing.expect_value(t, page_of(vmo3).seq, 2)
	_ = call(listen_ours, .Text, {task = 20})
	nsd.handle(LISTEN_KEY_PACKET)
	r = reply(t, listen_ours)
	testing.expect_value(t, r.status, vx.Status.Ok)
	testing.expect_value(t, r.text, "")

	// A malformed NEW: refused, its handles closed, no group made.
	conn_f := token()
	_ = call(listen_ours, .New, {count = 2}, "", "/srv/f\n", {conn_f})
	nsd.handle(LISTEN_KEY_PACKET)
	r = reply(t, listen_ours)
	testing.expect_value(t, r.status, vx.Status.Err_Invalid)
	testing.expect_value(t, len(r.handles), 0)
	testing.expect(t, closed(conn_f))
	testing.expect_value(t, nsd.groups[2].used, false)
	_ = call(listen_ours, .Share, {}) // not the listen channel's
	nsd.handle(LISTEN_KEY_PACKET)
	testing.expect_value(t, reply(t, listen_ours).status, vx.Status.Err_Invalid)

	// Members go: what one sent before it went is answered first; a packet
	// from a member that has gone is ignored; the group goes with its last
	// member, its connectors closed and its page unmapped.
	_ = call(m1, .Hello, {task = 6})
	stale := packet(m1, .Peer_Closed)
	_ = rt.handle_close(m1)
	nsd.handle(stale)
	testing.expect_value(t, nsd.groups[0].members, 1)
	nsd.handle(stale) // again: an earlier member's now
	testing.expect_value(t, nsd.groups[0].members, 1)
	unmaps_before := unmaps
	last := packet(m2, .Peer_Closed)
	_ = rt.handle_close(m2)
	nsd.handle(last)
	testing.expect_value(t, nsd.groups[0].used, false)
	testing.expect(t, closed(conn_a))
	testing.expect(t, closed(conn_b))
	testing.expect_value(t, unmaps, unmaps_before + 1)
	_ = call(listen_ours, .Text, {task = 9})
	nsd.handle(LISTEN_KEY_PACKET)
	testing.expect_value(t, reply(t, listen_ours).status, vx.Status.Err_Not_Found)
	testing.expect_value(t, nsd.groups[1].used, true) // the other group stays
	_ = m3
}
