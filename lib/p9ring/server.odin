// vx:p9ring, 9P over a ring, the server side (lib/rt/p9conn.odin describes
// the transport, and is the client).
package p9ring

import vx "abi:vx"
import "vx:drbg"
import "vx:memory"
import "vx:ndb"
import "vx:p9"
import "vx:ring"
import "vx:rt"
//
// The server waits on one port for everything: READABLE on the listen
// channel; for each connection, its doorbell (COUNTER_GE) and its client
// going away (PEER_CLOSED); and whatever the file server binds there itself,
// such as a driver's Irq, with keys from KEY_USER up, which go to its event
// hook.
//
// A request the file server cannot do yet (p9.serve's .Defer) is held, and
// served again after every event, after every tick, and when the file server
// says something it did may let it go on (`again`): a request on another
// connection, say, that queued what the held one waits for. A connection
// holds up to rt.DEPTH of them (upstream's M6 step 6d4a) and goes on taking
// new requests meanwhile, so replies go out in any order, as 9P allows. Two
// rules keep that safe:
//   - a request on a fid that an earlier held request is on waits behind it,
//     so writes to a pipe, say, stay in their order;
//   - Tflush of a held request drops it, unanswered, before Rflush goes out
//     (9P's rule: the flushed request's reply comes first, or never).
// A held request's bytes stay in the client's arena until it is answered,
// and are copied out again each time it is served.
//
// All the connections share one table of open files and locks (p9.Shared),
// for the posix extension; its tokens come from the spawn message's
// entropy= record, and without one Tshare is refused.

MAX_CONNS :: 16 // a server's connections, unless it gives more of its own
MAX_CONNS_LIMIT :: 256 // what a port key's slot can name

KEY_USER :: u64(1) << 62 // and up: the file server's own bindings

// The port keys below KEY_USER. A connection's keys carry its slot and the
// slot's generation, so a packet from a binding on a connection that has
// gone is never taken for one about its slot's next connection. The listen
// channel's key is all zeroes.
@(private="file")
Key_Kind :: enum u32 {
	Listen,
	Conn_Bell,
	Conn_Closed,
}

@(private="file")
Port_Key :: bit_field u64 {
	slot: u32      | 8,
	gen:  u32      | 32,
	kind: Key_Kind | 22,
	user: u8       | 2, // set from KEY_USER up
}
#assert(size_of(Port_Key) == 8)

@(private="file")
conn_key :: proc "contextless" (kind: Key_Kind, slot: int, gen: u32) -> u64 {
	return transmute(u64)Port_Key{slot = u32(slot), gen = gen, kind = kind}
}

// --- The server's arena, allotted in order ---
//
// Regions are taken in order, each contiguous (one that would run past the
// end starts again at 0, the rest of the end going with it), and given back
// in any order; the space comes free as the oldest regions are given back.
// Positions count bytes for ever; a position's offset is it modulo the size.

@(private="file")
REGIONS :: 2 * rt.DEPTH

@(private="file")
Arena :: struct {
	size:         u64,
	head, tail:   u64, // [head, tail): taken
	first, count: int,
	regions:      [REGIONS]struct {
		end:  u64,
		done: bool,
	},
}

// A region of length bytes: its index for arena_free, and its offset; not
// ok if there is no room now (or no region left).
@(private="file")
arena_alloc :: proc "contextless" (a: ^Arena, length: u64) -> (index: int, off: u64, ok: bool) {
	if length == 0 || length > a.size || a.count == REGIONS {
		return 0, 0, false
	}
	pos := a.tail
	off = pos % a.size
	if off + length > a.size { // to the start, the end's rest with it
		pos += a.size - off
		off = 0
	}
	if pos + length - a.head > a.size {
		return 0, 0, false
	}
	index = (a.first + a.count) % REGIONS
	a.count += 1
	a.regions[index] = {
		end = pos + length,
	}
	a.tail = pos + length
	return index, off, true
}

// Gives region i back.
@(private="file")
arena_free :: proc "contextless" (a: ^Arena, i: int) {
	a.regions[i].done = true
	for a.count != 0 && a.regions[a.first].done {
		a.head = a.regions[a.first].end
		a.first = (a.first + 1) % REGIONS
		a.count -= 1
	}
}

// A request held for later: its submission (its bytes stay in the client's
// arena), the VMO it came with, and what the rules above look at.
@(private="file")
Held :: struct {
	e:      vx.Sqe,
	handle: vx.Handle, // dref's VMO, the server's until it is answered
	tag:    u16,
	fid:    p9.Fid, // NOFID: the message has none
}

Server_Conn :: struct {
	used, armed: bool,
	gen:         u32,
	slot:        int,
	owner:       ^Server,
	held:        [dynamic; rt.DEPTH]Held, // oldest first
	ring:        ring.Ring,
	out:         Arena, // the server's arena: the replies' bytes
	released:    u32, // completions whose bytes have been given back
	end:         vx.Handle,
	srv:         p9.Server,
	req:         [rt.MSIZE]u8,
	resp:        [rt.MSIZE]u8,
}

Server :: struct {
	fs:           p9.Fs,
	supported:    p9.Extensions, // 9Px extensions
	name:         string, // for messages
	listen:       vx.Handle,
	port:         vx.Handle, // the file server may bind its own sources here, keyed from KEY_USER
	listen_armed: bool,
	ctx:          rawptr,
	event:        proc "contextless" (ctx: rawptr, pk: ^vx.Packet), // a packet keyed from KEY_USER up
	// Optional: does what is due by now, and says when to be called again
	// (vx.INFINITE: never), as a protocol's retransmission timers need.
	tick:          proc "contextless" (ctx: rawptr) -> vx.Instant,
	// Optional: a message on the listen channel that is not CONNECT, with
	// the one handle it may carry (HANDLE_NONE if none), which becomes the
	// hook's. procfs takes registrations this way (vx:process).
	listen_msg:    proc "contextless" (ctx: rawptr, msg: []u8, handle: vx.Handle),
	// Set by the file server when what it just did may let a held request go
	// on: the held requests are served again before the server sleeps.
	again:         bool,
	// Optional, in place of fs: each request as it came, on connection
	// `conn` (its slot), for a server that forwards requests rather than
	// serving them (the relay, upstream's M6 step 6d4d2b). It answers as
	// p9.serve does: the reply's length in resp, or .Defer to be asked
	// again; the rules above hold as for fs, Tflush's too. `closed` is told
	// when a connection has gone, its held requests dropped unanswered.
	raw:           proc "contextless" (ctx: rawptr, conn: int, req: []u8, resp: []u8) -> (reply_len: int, res: p9.Serve_Result),
	closed:        proc "contextless" (ctx: rawptr, conn: int),
	// Whether to go on serving the connections it has once the listen
	// channel's peer has gone: serve then returns when the last one goes.
	// Without it, it returns at once.
	linger:        bool,
	// Its connections: default_conns, unless the file server gives more of
	// its own (procfs, which holds one per process) before serving. At most
	// MAX_CONNS_LIMIT. serve points it at default_conns otherwise, so a Server
	// must not move once it serves.
	conns:         []Server_Conn,
	default_conns: [MAX_CONNS]Server_Conn,
	shared:        p9.Shared, // the open files and locks all its connections share (posix)
}

// The handle a request came with, if any (dref's VMO): the server's while it
// serves it.
@(private="file")
drop_request_handle :: proc "contextless" (c: ^Server_Conn) {
	rt.close_all(c.srv.request_handle)
	c.srv.request_handle = vx.HANDLE_NONE
}

// A connection goes: every fid is clunked, and its ring leaves the address
// space, so a long-lived server does not run out of mappings.
@(private="file")
close_conn :: proc "contextless" (c: ^Server_Conn) {
	drop_request_handle(c)
	if c.owner != nil && c.owner.closed != nil {
		c.owner.closed(c.owner.ctx, c.slot)
	}
	for h in c.held {
		rt.close_all(h.handle)
	}
	clear(&c.held)
	p9.hang_up(&c.srv)
	_ = rt.handle_close(c.end)
	rt.session_unmap(&c.ring)
	c.used = false
}

// Answers one CONNECT: a new ring, its client end and memory in the reply;
// or, if that cannot be done, a refusal.
@(private="file")
accept :: proc "contextless" (s: ^Server, req: ^vx.Msg_Header) {
	rep := vx.Msg_Header{txid = req.txid, ordinal = rt.CONNECT}
	if connect(s, &rep) != .Ok {
		rep.flags = rt.CONNECT_REFUSED
		_ = rt.channel_write(s.listen, memory.ptr_to_bytes(&rep))
	}
}

// Makes a connection in a free slot and sends rep with its handles.
@(private="file", require_results)
connect :: proc "contextless" (s: ^Server, rep: ^vx.Msg_Header) -> (st: vx.Status) {
	h: vx.Ring_Handles
	defer if st != .Ok {
		rt.close_all(h.client, h.server, h.memory)
	}
	i := 0
	for i < len(s.conns) && s.conns[i].used {
		i += 1
	}
	if i == len(s.conns) {
		return .Err_No_Memory
	}
	c := &s.conns[i]
	params := rt.PARAMS
	h = rt.ring_create(&params) or_return
	rt.map_ring(h.memory, .Server, &c.ring) or_return
	c.gen += 1
	rt.port_bind(s.port, h.server, .Peer_Closed, conn_key(.Conn_Closed, i, c.gen)) or_return
	give := [2]vx.Handle{h.client, h.memory}
	h.client, h.memory = vx.HANDLE_NONE, vx.HANDLE_NONE // moved, whatever happens
	rt.channel_write(s.listen, memory.ptr_to_bytes(rep), give[:]) or_return
	c.used = true
	c.armed = false
	clear(&c.held)
	c.released = 0
	c.out = {
		size = u64(len(ring.arena(&c.ring))),
	}
	c.end = h.server
	c.slot, c.owner = i, s
	c.srv = {fs = s.fs, max_msize = rt.MSIZE, supported = s.supported, shared = &s.shared}
	return .Ok
}

// Requests served on one connection before the server turns to the others: a
// client that keeps its queue full gets its share, not the whole server.
@(private="file")
BUDGET :: 8

@(private="file")
Drained :: enum u8 {
	Drained, // nothing is left to serve now
	More, // the budget ran out with requests left
	Broken, // the client broke the protocol, or sent something too broken to answer: drop it
}

// Gives back the arena of every completion the client has consumed.
@(private="file")
release :: proc "contextless" (c: ^Server_Conn) {
	consumed := ring.peer_consumed(&c.ring)
	for c.released != consumed && c.out.count != 0 {
		arena_free(&c.out, c.out.first)
		c.released += 1
	}
}

// Sends a reply of n bytes (none: the request was too broken to answer) for
// the submission e, with the reply's handle if the request made one. False
// if the client has broken the protocol: no room in the completion queue or
// the arena, which a client that keeps to the depth always leaves.
@(private="file")
reply :: proc "contextless" (c: ^Server_Conn, e: ^vx.Sqe, n: int) -> bool {
	release(c)
	entry: []u8
	off: u64
	ok := false
	if n > 0 {
		entry, ok = ring.produce_slot(&c.ring)
	}
	if ok {
		_, off, ok = arena_alloc(&c.out, u64(n))
	}
	if !ok {
		rt.close_all(c.srv.reply_handle) // no reply to carry it
		c.srv.reply_handle = vx.HANDLE_NONE
		return false
	}
	copy(ring.arena(&c.ring)[off:], c.resp[:n])
	out := vx.Cqe{user_data = e.user_data, result = i64(n), aux2 = off}
	if c.srv.reply_handle != vx.HANDLE_NONE { // Rmap's VMO, in a slot the completion names
		h := [1]vx.Handle{c.srv.reply_handle}
		c.srv.reply_handle = vx.HANDLE_NONE
		if hslot, hst := rt.ring_put_handles(c.end, h[:]); hst == .Ok {
			out.flags, out.aux = rt.CQE_HANDLE, hslot
		} else {
			rt.close_all(h[0]) // the client finds none, and its call fails
		}
	}
	copy(entry, memory.ptr_to_bytes(&out))
	if ring.produce(&c.ring) {
		_ = rt.ring_notify(c.end)
	}
	return true
}

@(private="file")
Tried :: enum u8 {
	Answered,
	Held,
	Broken,
}

// Serves h once: its bytes copied out of the client's arena again, its VMO
// lent to the file server for the call.
@(private="file")
try :: proc "contextless" (c: ^Server_Conn, h: ^Held) -> Tried {
	p, ok := ring.peer_bytes(&c.ring, u64(h.e.arena_off), u64(h.e.len))
	if !ok || h.e.len > len(c.req) {
		return .Broken
	}
	copy(c.req[:], p)
	c.srv.request_handle = h.handle
	h.handle = vx.HANDLE_NONE
	n: int
	res: p9.Serve_Result
	if s := c.owner; s != nil && s.raw != nil {
		n, res = s.raw(s.ctx, c.slot, c.req[:h.e.len], c.resp[:])
	} else {
		n, res = p9.serve(&c.srv, c.req[:h.e.len], c.resp[:])
	}
	if res == .Defer {
		h.handle = c.srv.request_handle // kept until it is served
		c.srv.request_handle = vx.HANDLE_NONE
		return .Held
	}
	drop_request_handle(c)
	return reply(c, &h.e, res == .Reply ? n : 0) ? .Answered : .Broken
}

// Whether an older held request than held[i] (or than a new one, i ==
// len(held)) is on fid: if so, it waits behind that one.
@(private="file")
behind :: proc "contextless" (c: ^Server_Conn, i: int, fid: p9.Fid) -> bool {
	if fid == p9.NOFID {
		return false
	}
	for &h in c.held[:i] {
		if h.fid == fid {
			return true
		}
	}
	return false
}

@(private="file")
unhold :: proc "contextless" (c: ^Server_Conn, i: int) {
	copy(c.held[i:], c.held[i + 1:])
	resize(&c.held, len(c.held) - 1)
}

// The fid a request is on, for the ordering rule; NOFID if none.
@(private="file")
request_fid :: proc "contextless" (t: ^p9.Msg) -> p9.Fid {
	#partial switch t.type {
	case .Tversion, .Tauth, .Tflush:
		return p9.NOFID
	}
	return t.fid
}

// Serves the requests waiting on one connection, up to its budget: the held
// ones first, oldest first, then new ones.
@(private="file")
drain :: proc "contextless" (c: ^Server_Conn) -> Drained {
	for i := 0; i < len(c.held); {
		if behind(c, i, c.held[i].fid) {
			i += 1
			continue
		}
		switch try(c, &c.held[i]) {
		case .Broken:
			return .Broken
		case .Answered:
			unhold(c, i)
		case .Held:
			i += 1
		}
	}
	for _ in 0 ..< BUDGET {
		if len(c.held) == rt.DEPTH {
			return .Drained // a client past the depth waits for its answers
		}
		h := Held {
			fid = p9.NOFID,
		}
		st := ring.consume(&c.ring, memory.ptr_to_bytes(&h.e))
		if st == .Err_Should_Wait {
			return .Drained
		}
		if st != .Ok || h.e.opcode != rt.RING_MSG || h.e.len > len(c.req) {
			return .Broken
		}
		p, ok := ring.peer_bytes(&c.ring, u64(h.e.arena_off), u64(h.e.len))
		if !ok {
			return .Broken
		}
		if .Handles in h.e.flags { // dref's VMO, for Treadref and Twriteref
			got: [1]vx.Handle
			if n, _ := rt.ring_take_handles(c.end, h.e.handle_slot, got[:]); n == 1 {
				h.handle = got[0]
			}
		}
		copy(c.req[:], p)
		t: p9.Msg
		if p9.decode(c.req[:h.e.len], &t) != .Ok {
			rt.close_all(h.handle)
			return .Broken
		}
		h.tag = t.tag
		h.fid = request_fid(&t)
		if t.type == .Tflush { // a held request it names goes unanswered; then Rflush
			for &x, i in c.held {
				if x.tag == t.oldtag {
					rt.close_all(x.handle)
					unhold(c, i)
					break
				}
			}
		}
		if behind(c, len(c.held), h.fid) {
			_ = append(&c.held, h)
			continue
		}
		switch try(c, &h) {
		case .Broken:
			return .Broken
		case .Held:
			_ = append(&c.held, h)
		case .Answered:
		}
	}
	return .More
}

@(private="file")
junk: [vx.CHANNEL_MAX_BYTES]u8
@(private="file")
junk_handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle

@(private="file")
now :: proc "contextless" () -> i64 {
	return i64(rt.clock_read())
}

// A message on the listen channel: CONNECT, or another the file server
// takes, or nothing anyone wants.
@(private="file")
Listen_Msg :: struct #raw_union {
	header: vx.Msg_Header,
	bytes:  [64]u8,
}

// Serves the file system on the listen channel until the channel goes away.
// The port is made here unless the file server made it already, to bind its
// own sources first.
@(require_results)
serve :: proc "contextless" (s: ^Server) -> vx.Status {
	if s.port == 0 {
		s.port = rt.port_create() or_return
	}
	if s.conns == nil || len(s.conns) > MAX_CONNS_LIMIT {
		s.conns = s.default_conns[:]
	}
	// Tokens for shared open files come from the entropy the spawn message
	// gives (a manifest's `entropy`); without it, Tshare is refused.
	s.shared.now = now
	rec: ndb.Record
	if rt.spawn_record("entropy", &rec) {
		if seed, ok := ndb.get(&rec, "entropy"); ok && len(seed) >= 16 && !s.shared.random.seeded {
			drbg.mix(&s.shared.random, transmute([]u8)seed, true)
		}
	}
	listening := true // the listen channel's peer is there (linger)
	for {
		more := false // a connection still has requests: no sleeping this time round
		for &c in s.conns {
			if !c.used {
				continue
			}
			switch drain(&c) {
			case .Broken:
				close_conn(&c)
			case .More:
				more = true
			case .Drained:
			}
		}
		for listening {
			msg: Listen_Msg
			handle := [1]vx.Handle{vx.HANDLE_NONE}
			size, st := rt.channel_read(s.listen, msg.bytes[:], handle[:])
			if st == .Err_Should_Wait {
				break
			}
			if st == .Err_Peer_Closed && !s.linger {
				return st
			}
			if st == .Err_Peer_Closed {
				listening = false
				break
			}
			req := &msg.header
			if st == .Ok && size.bytes == size_of(req^) && req.ordinal == rt.CONNECT && size.handles == 0 {
				accept(s, req)
			} else if st == .Ok && size.bytes >= size_of(req^) && req.ordinal != rt.CONNECT && s.listen_msg != nil {
				s.listen_msg(s.ctx, msg.bytes[:size.bytes], size.handles > 0 ? handle[0] : vx.HANDLE_NONE)
			} else if st == .Ok && size.handles > 0 {
				_ = rt.handle_close(handle[0])
			}
			// Anything else, including a message too big for us (TOO_SMALL), is dropped.
			if st == .Err_Too_Small {
				if jsize, jst := rt.channel_read(s.listen, junk[:], junk_handles[:]); jst == .Ok {
					rt.close_all(..junk_handles[:jsize.handles])
				}
			}
		}

		if !listening { // lingering: until the last connection goes
			any := false
			for &c in s.conns {
				any = any || c.used
			}
			if !any {
				return .Err_Peer_Closed
			}
		}

		// Arm what is idle, then sleep unless something arrived meanwhile. A
		// connection holding requests waits for an event or its doorbell: a
		// new request, or a Tflush of a held one.
		if s.again { // a held request may go on now: once more round
			more = true
			s.again = false
		}
		idle := !more
		for &c, i in s.conns {
			if !idle {
				break
			}
			if !c.used {
				continue
			}
			seen, _ := rt.counter_read(c.end)
			if !ring.prepare_sleep(&c.ring) {
				idle = false
			} else if !c.armed {
				c.armed = rt.port_bind(s.port, c.end, .Counter_Ge, conn_key(.Conn_Bell, i, c.gen), seen + 1) == .Ok
			}
		}
		if idle && listening && !s.listen_armed {
			s.listen_armed = rt.port_bind(s.port, s.listen, .Readable, conn_key(.Listen, 0, 0)) == .Ok
		}
		deadline := s.tick(s.ctx) if s.tick != nil else vx.INFINITE
		if idle {
			pk: [16]vx.Packet
			n, _ := rt.port_wait(s.port, deadline, 0, pk[:]) // Err_Timed_Out: the tick is due
			for &p in pk[:n] {
				if p.key >= KEY_USER {
					if s.event != nil {
						s.event(s.ctx, &p)
					}
					continue
				}
				key := transmute(Port_Key)p.key
				if key.kind == .Listen {
					s.listen_armed = false
					continue
				}
				if int(key.slot) >= len(s.conns) {
					continue
				}
				c := &s.conns[key.slot]
				if !c.used || c.gen != key.gen {
					continue // about a connection that has gone
				}
				#partial switch key.kind {
				case .Conn_Closed:
					close_conn(c)
				case .Conn_Bell:
					c.armed = false
				}
			}
		}
		for &c in s.conns {
			if c.used {
				ring.end_sleep(&c.ring)
			}
		}
	}
}
