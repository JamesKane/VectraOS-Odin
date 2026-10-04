// 9P over a ring: 9px+shm, the local transpo
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
// fit, is treated as gone. This client has one request in flight.
//
// This file is the client, which every program has for its console;
// lib/p9ring is the server.
package rt

import vx "abi:vx"
import "vx:p9"
import "vx:ring"

CONNECT :: u32(0x3970_6e63) // the listen channel's one ordinal: "cnp9"
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

// Maps a ring's memory into this task and attaches to it as one side. The
// mapping stays for the life of the task until as_unmap lands.
map_ring :: proc "contextless" (memory: vx.Handle, client: bool, r: ^ring.Ring) -> vx.Status {
	layout := ring.layout(PARAMS) or_return
	base := as_map(self, memory, 0, layout.size, {.Write}) or_return
	return ring.attach(r, (cast([^]u8)uintptr(base))[:layout.size], client)
}

@(private="file")
KEY_BELL :: 1
@(private="file")
KEY_CLOSED :: 2

// One connection: a 9P client over its own ring.
Conn :: struct {
	c:    p9.Client,
	ring: ring.Ring,
	end:  vx.Handle,
	port: vx.Handle,
	dead: bool,
	tbuf: [MSIZE]u8,
	rbuf: [MSIZE]u8,
}

bytes_of :: #force_inline proc "contextless" (p: ^$T) -> []u8 {
	return (cast([^]u8)p)[:size_of(T)]
}

@(private="file")
rpc :: proc "contextless" (ctx: rawptr, req, resp: []u8) -> int {
	k := cast(^Conn)ctx
	arena := ring.arena(&k.ring)
	if k.dead || len(req) > len(arena) {
		k.dead = true
		return 0
	}
	slot, ok := ring.produce_slot(&k.ring)
	if !ok {
		k.dead = true
		return 0
	}
	copy(arena, req)
	e := vx.Sqe{opcode = RING_MSG, len = u32(len(req))}
	copy(slot, bytes_of(&e))
	if ring.produce(&k.ring) {
		_ = ring_notify(k.end)
	}
	for {
		c: vx.Cqe
		st := ring.consume(&k.ring, bytes_of(&c))
		if st == .Ok {
			if c.result <= 0 || u64(c.result) > u64(len(resp)) {
				break
			}
			p, pok := ring.peer_bytes(&k.ring, c.aux2, u64(c.result))
			if !pok {
				break
			}
			copy(resp, p)
			return int(c.result)
		}
		if st != .Err_Should_Wait {
			break
		}
		seen, _ := counter_read(k.end)
		if ring.prepare_sleep(&k.ring) {
			pk: [1]vx.Packet
			_ = port_bind(k.port, k.end, .Counter_Ge, KEY_BELL, seen + 1)
			if n, _ := port_wait(k.port, vx.INFINITE, 0, pk[:]); n != 1 || pk[0].key == KEY_CLOSED {
				break
			}
		}
		ring.end_sleep(&k.ring)
	}
	k.dead = true
	return 0
}

// Opens a connection through a connector (a listen channel's client end,
// which stays the caller's) and negotiates 9Px. The connection is ready to
// attach.
p9_connect :: proc "contextless" (connector: vx.Handle, k: ^Conn) -> vx.Status {
	k^ = {}
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
	st := channel_call(connector, &call, clock_read() + 5_000_000_000)
	if st == .Ok && call.actual.handles != 2 {
		st = .Err_Invalid
	}
	if st == .Ok {
		st = map_ring(got[1], true, &k.ring)
	}
	if got[1] != 0 {
		_ = handle_close(got[1]) // the mapping keeps the memory
	}
	k.end = got[0]
	if st == .Ok {
		k.port, st = port_create()
	}
	if st == .Ok {
		st = port_bind(k.port, k.end, .Peer_Closed, KEY_CLOSED)
	}
	if st == .Ok {
		k.c = {rpc = rpc, ctx = k, tbuf = k.tbuf[:], rbuf = k.rbuf[:]}
		st = p9.client_version(&k.c, MSIZE, {})
	}
	if st != .Ok {
		p9_disconnect(k)
	}
	return st
}

p9_disconnect :: proc "contextless" (k: ^Conn) {
	if k.end != 0 {
		_ = handle_close(k.end)
	}
	if k.port != 0 {
		_ = handle_close(k.port)
	}
	k^ = {dead = true}
}

