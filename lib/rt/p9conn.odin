// 9P over a ring: 9px+shm, the local transport.
//
// Connecting. A server reads a listen channel, which svcd posts as
// /srv/NAME and hands out to clients. A client sends CONNECT there with
// channel_call; the server creates a ring, keeps the server end, and answers
// with the client end and the ring's memory. Each connection is its own ring,
// so each queue has one producer and one consumer, as lib/ring requires.
//
// Messages. One 9P message is one submission: opcode RING_MSG, its bytes at
// arena_off in the client's arena, len bytes long. The reply is one
// completion: result is its length, aux2 its offset in the server's arena.
// Each side copies the other's bytes out once before it decodes them, and a
// peer that names bytes outside its arena, or sends a reply that does not
// fit, is treated as gone. This client has one request in flight; a
// reader that waits on many things at once sends a request and takes its
// reply later (p9_send, p9_receive, p9_arm).
//
// This file is the client, which every program has for its console;
// lib/p9ring is the server.
package rt

import vx "abi:vx"
import "vx:memory"
import "vx:p9"
import "vx:ring"

CONNECT :: u32(0x3970_6e63) // the listen channel's one ordinal: "cnp9"
CONNECT_REFUSED :: u32(1) // a CONNECT reply's flags: no ring, and no handles
RING_MSG :: u16(1) // the one submission opcode
MSIZE :: 16 * 1024

PARAMS :: vx.Ring_Params {
	sq_entries   = 8,
	cq_entries   = 8,
	sqe_size     = size_of(vx.Sqe),
	cqe_size     = size_of(vx.Cqe),
	client_arena = MSIZE,
	server_arena = MSIZE,
}

// Maps a ring's memory into this task and attaches to it as one side; a
// ring it will not attach to is unmapped again.
@(require_results)
map_ring :: proc "contextless" (mem: vx.Handle, side: ring.Side, r: ^ring.Ring) -> vx.Status {
	return session_map(mem, side, PARAMS, r)
}

// Lets a ring's memory go from this task's address space.
ring_unmap :: proc "contextless" (r: ^ring.Ring) {
	session_unmap(r)
}

@(private="file")
KEY_BELL :: 1
@(private="file")
KEY_CLOSED :: 2

// One connection: a 9P client over its own ring. Its client points back
// into it (ctx, tbuf, rbuf), so a Conn stays where p9_connect filled it in:
// never copy or move one.
Conn :: struct {
	c:       p9.Client,
	ring:    ring.Ring,
	end:     vx.Handle,
	port:    vx.Handle,
	dead:    bool,
	sent:    p9.Type, // the type of the call p9_send sent, for its reply's
	timeout: vx.Duration, // a call not answered in that long ends the connection (0: none)
	tbuf:    [MSIZE]u8,
	rbuf:    [MSIZE]u8,
}

// Puts one request on the ring (the connection has at most one outstanding).
@(private="file", require_results)
put :: proc "contextless" (k: ^Conn, req: []u8) -> bool {
	arena := ring.arena(&k.ring)
	if k.dead || len(req) > len(arena) {
		k.dead = true
		return false
	}
	slot, ok := ring.produce_slot(&k.ring)
	if !ok {
		k.dead = true
		return false
	}
	copy(arena, req)
	e := vx.Sqe{opcode = RING_MSG, len = u32(len(req))}
	copy(slot, memory.ptr_to_bytes(&e))
	if ring.produce(&k.ring) {
		_ = ring_notify(k.end)
	}
	return true
}

// Takes the reply if it has come, into resp: its length; .Err_Should_Wait if
// it has not come yet; .Err_Peer_Closed if the connection is broken.
@(private="file", require_results)
take :: proc "contextless" (k: ^Conn, resp: []u8) -> (n: int, st: vx.Status) {
	c: vx.Cqe
	if cst := ring.consume(&k.ring, memory.ptr_to_bytes(&c)); cst != .Ok {
		return 0, cst == .Err_Should_Wait ? cst : .Err_Peer_Closed
	}
	if c.result <= 0 || u64(c.result) > u64(len(resp)) {
		return 0, .Err_Peer_Closed
	}
	p, ok := ring.peer_bytes(&k.ring, c.aux2, u64(c.result))
	if !ok {
		return 0, .Err_Peer_Closed
	}
	return copy(resp, p), .Ok
}

@(private="file")
rpc :: proc "contextless" (ctx: rawptr, req, resp: []u8) -> int {
	k := (^Conn)(ctx)
	if !put(k, req) {
		return 0
	}
	deadline := k.timeout != 0 ? clock_read() + vx.Instant(k.timeout) : vx.INFINITE
	for {
		n, st := take(k, resp)
		if st == .Ok {
			return n
		}
		if st != .Err_Should_Wait {
			break
		}
		seen, _ := counter_read(k.end)
		if ring.prepare_sleep(&k.ring) {
			pk: [1]vx.Packet
			_ = port_bind(k.port, k.end, .Counter_Ge, KEY_BELL, seen + 1)
			got, wst := port_wait(k.port, deadline, 0, pk[:])
			// An interrupt (a POSIX signal) does not end a call the server is
			// answering: the wait goes on, and its handler runs once the call
			// is done (upstream 01 §9). The binding made for this wait may
			// fire later, too.
			if wst == .Err_Interrupted {
				ring.end_sleep(&k.ring)
				continue
			}
			if got != 1 || pk[0].key == KEY_CLOSED {
				break
			}
		}
		ring.end_sleep(&k.ring)
	}
	k.dead = true
	return 0
}

// Opens a connection through a connector (a listen channel's client end,
// which stays the caller's) and negotiates 9Px, with the posix and xattr
// extensions where the server has them. The connection is ready to attach.
@(require_results)
p9_connect :: proc "contextless" (connector: vx.Handle, k: ^Conn) -> (st: vx.Status) {
	k^ = {}
	defer if st != .Ok {
		p9_disconnect(k)
	}
	req := vx.Msg_Header{ordinal = CONNECT}
	rep: vx.Msg_Header
	got: [2]vx.Handle
	call := vx.Call {
		wr_bytes     = &req,
		wr_len       = size_of(req),
		rd_bytes     = &rep,
		rd_cap       = size_of(rep),
		rd_handles   = &got[0],
		rd_count_cap = 2,
	}
	st = channel_call(connector, &call, clock_read() + 5_000_000_000)
	if st == .Ok && call.actual.handles != 2 {
		st = .Err_Invalid
	}
	if st == .Ok {
		st = map_ring(got[1], .Client, &k.ring)
	}
	close_all(got[1]) // the mapping keeps the memory
	k.end = got[0]
	st or_return
	k.port = port_create() or_return
	port_bind(k.port, k.end, .Peer_Closed, KEY_CLOSED) or_return
	k.c = {rpc = rpc, ctx = k, tbuf = k.tbuf[:], rbuf = k.rbuf[:]}
	return p9.client_version(&k.c, MSIZE, {.Posix, .Xattr})
}

// Ends the connection: its ring's memory is unmapped and its handles
// closed. Safe on a connection that never connected.
p9_disconnect :: proc "contextless" (k: ^Conn) {
	ring_unmap(&k.ring)
	close_all(k.end, k.port)
	k^ = {dead = true}
}

// --- One call at a time, its reply taken later ---
//
// For a reader that waits on many things at once (poll's read-ahead, in the
// musl back end): send a request, then look for its reply, arming a port of
// the caller's to hear when one may have come. Nothing else may use the
// connection while a call is outstanding.

// Sends t, giving it the next tag.
@(require_results)
p9_send :: proc "contextless" (k: ^Conn, t: ^p9.Msg) -> vx.Status {
	t.tag = k.c.next_tag % p9.NOTAG
	k.c.next_tag += 1
	n := p9.encode(t, k.c.tbuf)
	if n == 0 {
		return .Err_Too_Small
	}
	k.sent = t.type
	return put(k, k.c.tbuf[:n]) ? .Ok : .Err_Peer_Closed
}

// The reply to the call sent with tag: .Ok, with r decoded (its data in the
// connection's buffer, until the next call); .Err_Should_Wait if it has not
// come; the error an Rerror names; or .Err_Peer_Closed.
@(require_results)
p9_receive :: proc "contextless" (k: ^Conn, tag: u16, r: ^p9.Msg) -> vx.Status {
	n, st := take(k, k.c.rbuf)
	if st == .Err_Should_Wait {
		return st
	}
	if st != .Ok {
		k.dead = true
		return .Err_Peer_Closed
	}
	// One call at a time: anything but its reply (or its error) means the
	// server is confused, and nothing more it says can be matched to a call.
	ok := p9.decode(k.c.rbuf[:n], r) == .Ok && r.tag == tag
	if ok && r.type == .Rerror {
		return p9.error_status(r.ename)
	}
	if !ok || u8(r.type) != u8(k.sent) + 1 {
		k.dead = true
		return .Err_Peer_Closed
	}
	return .Ok
}

// Arms port to get `key` once a reply may have come. False when one may
// already have: look again rather than wait. ring.end_sleep after.
@(require_results)
p9_arm :: proc "contextless" (k: ^Conn, port: vx.Handle, key: u64) -> bool {
	seen, _ := counter_read(k.end)
	if !ring.prepare_sleep(&k.ring) {
		return false
	}
	return port_bind(port, k.end, .Counter_Ge, key, seen + 1) == .Ok
}
