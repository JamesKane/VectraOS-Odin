// vx:p9ring, 9P over a ring, the server side (lib/rt/p9conn.odin describes
// the transport, and is the client).
package p9ring

import vx "abi:vx"
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
// after every event.

MAX_CONNS :: 16

// A connection's port keys carry its slot and the slot's generation, so a
// packet from a binding on a connection that has gone is never taken for
// one about its slot's next connection.
@(private="file")
KEY_LISTEN :: 0
@(private="file")
KEY_CONN_BELL :: 1
@(private="file")
KEY_CONN_CLOSED :: 2
KEY_USER :: u64(1) << 62 // and up: the file server's own bindings

@(private="file")
conn_key :: proc "contextless" (kind: u64, slot, gen: u32) -> u64 {
	return kind << 40 | u64(gen) << 8 | u64(slot)
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
	conns:        [MAX_CONNS]Server_Conn,
}

@(private="file")
close_conn :: proc "contextless" (c: ^Server_Conn) {
	p9.hang_up(&c.srv)
	_ = rt.handle_close(c.end)
	c.used = false
}

// Answers one CONNECT: a new ring, its client end and memory in the reply.
@(private="file")
accept :: proc "contextless" (s: ^Server, req: ^vx.Msg_Header) {
	rep := vx.Msg_Header{txid = req.txid, ordinal = rt.CONNECT}
	i := 0
	for i < MAX_CONNS && s.conns[i].used {
		i += 1
	}
	h: vx.Ring_Handles
	st := vx.Status.Err_No_Memory
	c: ^Server_Conn
	if i < MAX_CONNS {
		c = &s.conns[i]
		params := rt.PARAMS
		h, st = rt.ring_create(&params)
	}
	if st == .Ok {
		st = rt.map_ring(h.memory, false, &c.ring)
	}
	if st == .Ok {
		c.gen += 1
		st = rt.port_bind(s.port, h.server, .Peer_Closed, conn_key(KEY_CONN_CLOSED, u32(i), c.gen))
	}
	if st == .Ok {
		give := [2]vx.Handle{h.client, h.memory}
		st = rt.channel_write(s.listen, rt.bytes_of(&rep), give[:])
		h.client, h.memory = vx.HANDLE_NONE, vx.HANDLE_NONE // moved, whatever happened
	}
	if st == .Ok {
		c.used = true
		c.armed, c.holding = false, false
		c.end = h.server
		c.srv = {fs = s.fs, max_msize = rt.MSIZE, supported = s.supported}
		return
	}
	for v in ([]vx.Handle{h.client, h.server, h.memory}) {
		if v != 0 {
			_ = rt.handle_close(v)
		}
	}
	rep.flags = 1 // refused: a reply without handles
	_ = rt.channel_write(s.listen, rt.bytes_of(&rep))
}

// Serves every request waiting on one connection: first one it holds, if it
// can be served now. False if the client broke the protocol, or sent
// something too broken to answer, and must be dropped.
@(private="file")
drain :: proc "contextless" (c: ^Server_Conn) -> bool {
	for {
		e := vx.Sqe{user_data = c.held_user_data, len = c.held_len}
		if !c.holding {
			st := ring.consume(&c.ring, rt.bytes_of(&e))
			if st == .Err_Should_Wait {
				return true
			}
			if st != .Ok || e.opcode != rt.RING_MSG || e.len > len(c.req) {
				return false
			}
			p, ok := ring.peer_bytes(&c.ring, u64(e.arena_off), u64(e.len))
			if !ok {
				return false
			}
			copy(c.req[:], p)
		}
		n, res := p9.serve(&c.srv, c.req[:e.len], c.resp[:])
		switch res {
		case .Defer:
			c.holding = true
			c.held_len = e.len
			c.held_user_data = e.user_data
			return true
		case .Hang_Up:
			return false // unanswerable
		case .Reply:
			c.holding = false
		}
		arena := ring.arena(&c.ring)
		if n > len(arena) {
			return false
		}
		slot, ok := ring.produce_slot(&c.ring)
		if !ok {
			return false // a client that does not drain its completions
		}
		copy(arena, c.resp[:n])
		out := vx.Cqe{user_data = e.user_data, result = i64(n)}
		copy(slot, rt.bytes_of(&out))
		if ring.produce(&c.ring) {
			_ = rt.ring_notify(c.end)
		}
	}
}

@(private="file")
junk: [vx.CHANNEL_MAX_BYTES]u8
@(private="file")
junk_handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle

// Serves the file system on the listen channel until the channel goes away.
// The port is made here unless the file server made it already, to bind its
// own sources first.
serve :: proc "contextless" (s: ^Server) -> vx.Status {
	if s.port == 0 {
		s.port = rt.port_create() or_return
	}
	for {
		for &c in s.conns {
			if c.used && !drain(&c) {
				close_conn(&c)
			}
		}
		for {
			req: vx.Msg_Header
			size, st := rt.channel_read(s.listen, rt.bytes_of(&req))
			if st == .Err_Should_Wait {
				break
			}
			if st == .Err_Peer_Closed {
				return st
			}
			if st == .Ok && size.bytes == size_of(req) && req.ordinal == rt.CONNECT {
				accept(s, &req)
			}
			// Anything else, including a message too big for us (TOO_SMALL), is dropped.
			if st == .Err_Too_Small {
				if jsize, jst := rt.channel_read(s.listen, junk[:], junk_handles[:]); jst == .Ok {
					for h in junk_handles[:jsize.handles] {
						_ = rt.handle_close(h)
					}
				}
			}
		}

		// Arm what is idle, then sleep unless something arrived meanwhile. A
		// connection holding a request waits for an event, not its doorbell.
		idle := true
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
				c.armed = rt.port_bind(s.port, c.end, .Counter_Ge, conn_key(KEY_CONN_BELL, u32(i), c.gen), seen + 1) == .Ok
			}
		}
		if idle && !s.listen_armed {
			s.listen_armed = rt.port_bind(s.port, s.listen, .Readable, KEY_LISTEN) == .Ok
		}
		if idle {
			pk: [16]vx.Packet
			n, _ := rt.port_wait(s.port, vx.INFINITE, 0, pk[:])
			for &p in pk[:n] {
				key := p.key
				kind, slot, gen := key >> 40, u32(key & 0xff), u32(key >> 8)
				if key >= KEY_USER {
					if s.event != nil {
						s.event(s.ctx, &p)
					}
					continue
				}
				if key == KEY_LISTEN {
					s.listen_armed = false
					continue
				}
				if slot >= MAX_CONNS {
					continue
				}
				c := &s.conns[slot]
				if !c.used || c.gen != gen {
					continue // about a connection that has gone
				}
				if kind == KEY_CONN_CLOSED {
					close_conn(c)
				} else if kind == KEY_CONN_BELL {
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
