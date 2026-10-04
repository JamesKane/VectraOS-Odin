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
// the connection takes nothing more until it completes: it is served again
// after every event, after every tick, and when the file server says
// something it did may let it go on (`again`): a request on another
// connection, say, that queued what the held one waits for. (Holding one
// request per connection is what a synchronous client needs; Tflush of a
// held request comes with pipelining.)
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

Server_Conn :: struct {
	used, armed:    bool,
	holding:        bool, // req holds a deferred request (held_len bytes), answered with held_user_data
	gen, held_len:  u32,
	held_user_data: u64,
	ring:           ring.Ring,
	end:            vx.Handle,
	srv:            p9.Server,
	req:            [rt.MSIZE]u8,
	resp:           [rt.MSIZE]u8,
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
	// Its connections: default_conns, unless the file server gives more of
	// its own (procfs, which holds one per process) before serving. At most
	// MAX_CONNS_LIMIT. serve points it at default_conns otherwise, so a Server
	// must not move once it serves.
	conns:         []Server_Conn,
	default_conns: [MAX_CONNS]Server_Conn,
	shared:        p9.Shared, // the open files and locks all its connections share (posix)
}

// A connection goes: every fid is clunked. (Upstream's M4 also unmaps the
// ring here; that waits for vx:rt's as_unmap, with the kernel's M4 port.)
@(private="file")
close_conn :: proc "contextless" (c: ^Server_Conn) {
	p9.hang_up(&c.srv)
	_ = rt.handle_close(c.end)
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
	c.armed, c.holding = false, false
	c.end = h.server
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

// Serves the requests waiting on one connection, up to its budget: first one
// it holds, if it can be served now.
@(private="file")
drain :: proc "contextless" (c: ^Server_Conn) -> Drained {
	for _ in 0 ..< BUDGET {
		e := vx.Sqe{user_data = c.held_user_data, len = c.held_len}
		if !c.holding {
			st := ring.consume(&c.ring, memory.ptr_to_bytes(&e))
			if st == .Err_Should_Wait {
				return .Drained
			}
			if st != .Ok || e.opcode != rt.RING_MSG || e.len > len(c.req) {
				return .Broken
			}
			p, ok := ring.peer_bytes(&c.ring, u64(e.arena_off), u64(e.len))
			if !ok {
				return .Broken
			}
			copy(c.req[:], p)
		}
		n, res := p9.serve(&c.srv, c.req[:e.len], c.resp[:])
		switch res {
		case .Defer:
			c.holding = true
			c.held_len = e.len
			c.held_user_data = e.user_data
			return .Drained
		case .Hang_Up:
			return .Broken // unanswerable
		case .Reply:
			c.holding = false
		}
		arena := ring.arena(&c.ring)
		if n > len(arena) {
			return .Broken
		}
		slot, ok := ring.produce_slot(&c.ring)
		if !ok {
			return .Broken // a client that does not drain its completions
		}
		copy(arena, c.resp[:n])
		out := vx.Cqe{user_data = e.user_data, result = i64(n)}
		copy(slot, memory.ptr_to_bytes(&out))
		if ring.produce(&c.ring) {
			_ = rt.ring_notify(c.end)
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
		for {
			msg: Listen_Msg
			handle := [1]vx.Handle{vx.HANDLE_NONE}
			size, st := rt.channel_read(s.listen, msg.bytes[:], handle[:])
			if st == .Err_Should_Wait {
				break
			}
			if st == .Err_Peer_Closed {
				return st
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

		// Arm what is idle, then sleep unless something arrived meanwhile. A
		// connection holding a request waits for an event, not its doorbell.
		if s.again { // a held request may go on now: once more round
			more = true
			s.again = false
		}
		idle := !more
		for &c, i in s.conns {
			if !idle {
				break
			}
			if !c.used || c.holding {
				continue
			}
			seen, _ := rt.counter_read(c.end)
			if !ring.prepare_sleep(&c.ring) {
				idle = false
			} else if !c.armed {
				c.armed = rt.port_bind(s.port, c.end, .Counter_Ge, conn_key(.Conn_Bell, i, c.gen), seen + 1) == .Ok
			}
		}
		if idle && !s.listen_armed {
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
