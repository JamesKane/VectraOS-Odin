// lib/ring on the host: the layout, both queues, wraparound, the sleep
// handshake, a hostile peer, and two threads passing two million entries
// through a real doorbell. A lost wake-up would hang that last test, so an
// alarm turns a hang into a failure. Ported from upstream's
// tests/host/ring_test.c.
package ring_test

import "core:mem"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import vx "abi:vx"
import "vx:ring"

// A ring in ordinary memory, laid out as the kernel lays one out.
make_ring :: proc(p: vx.Ring_Params) -> (memory: []u8, h: vx.Ring_Header, ok: bool) {
	status: vx.Status
	h, status = ring.layout(p)
	if status != .Ok {
		return nil, h, false
	}
	err: mem.Allocator_Error
	memory, err = mem.alloc_bytes(int(h.size), 4096)
	if err != nil {
		return nil, h, false
	}
	(^vx.Ring_Header)(raw_data(memory))^ = h
	return memory, h, true
}

free_ring :: proc(memory: []u8) {
	mem.free_bytes(memory)
}

// The entry produce_slot gave, as the type it holds.
sqe_slot :: proc(r: ^ring.Ring) -> ^vx.Sqe {
	e, ok := ring.produce_slot(r)
	if !ok {
		return nil
	}
	assert(len(e) >= size_of(vx.Sqe))
	return (^vx.Sqe)(raw_data(e))
}

cqe_slot :: proc(r: ^ring.Ring) -> ^vx.Cqe {
	e, ok := ring.produce_slot(r)
	if !ok {
		return nil
	}
	assert(len(e) >= size_of(vx.Cqe))
	return (^vx.Cqe)(raw_data(e))
}

header :: proc(memory: []u8) -> ^vx.Ring_Header {
	return (^vx.Ring_Header)(raw_data(memory))
}

lines :: proc(memory: []u8) -> ^[vx.Ring_Line]vx.Ring_Index {
	return (^[vx.Ring_Line]vx.Ring_Index)(&memory[vx.RING_INDEX_OFFSET])
}

@(test)
test_layout :: proc(t: ^testing.T) {
	h, status := ring.layout({3, 4, 64, 32, 0, 0})
	testing.expect(t, status == .Err_Invalid) // not a power of two
	h, status = ring.layout({8192, 4, 64, 32, 0, 0})
	testing.expect(t, status == .Err_Invalid)
	h, status = ring.layout({4, 4, 40, 32, 0, 0})
	testing.expect(t, status == .Err_Invalid) // not a multiple of 16
	h, status = ring.layout({64, 64, 64, 32, 5000, 1})
	testing.expect(t, status == .Ok)
	testing.expect(t, h.sq_offset == 8192 && h.cq_offset == 8192 + 64 * 64)
	testing.expect(t, h.client_arena_offset % 4096 == 0 && h.client_arena_size == 8192 && h.server_arena_size == 4096)
	testing.expect(t, h.size == h.server_arena_offset + 4096)
}

@(test)
test_queues :: proc(t: ^testing.T) {
	memory, h, ok := make_ring({8, 8, 64, 32, 4096, 4096})
	if !testing.expect(t, ok) {
		return
	}
	defer free_ring(memory)
	client, server: ring.Ring
	testing.expect(t, ring.attach(&client, memory[:h.size], .Client) == .Ok)
	testing.expect(t, ring.attach(&server, memory[:h.size], .Server) == .Ok)

	// Three laps of the queue, filling it each time.
	next, expect: u64
	for _ in 0 ..< 3 {
		for _ in 0 ..< 8 {
			e := sqe_slot(&client)
			if !testing.expect(t, e != nil) {
				return
			}
			e^ = {opcode = 1, user_data = next}
			next += 1
			ring.produce(&client)
		}
		testing.expect(t, sqe_slot(&client) == nil) // full
		got: vx.Sqe
		for ring.consume(&server, mem.ptr_to_bytes(&got)) == .Ok {
			testing.expect(t, got.user_data == expect)
			expect += 1
		}
		testing.expect(t, expect == next)
	}

	// Completions flow the other way.
	c := cqe_slot(&server)
	c^ = {user_data = 77, result = -2}
	ring.produce(&server)
	done: vx.Cqe
	testing.expect(t, ring.consume(&client, mem.ptr_to_bytes(&done)) == .Ok && done.user_data == 77 && done.result == -2)
	testing.expect(t, ring.consume(&client, mem.ptr_to_bytes(&done)) == .Err_Should_Wait)

	// The sleep handshake: the producer learns the consumer is asleep.
	testing.expect(t, ring.prepare_sleep(&server)) // empty: may sleep
	e := sqe_slot(&client)
	e^ = {user_data = 5}
	testing.expect(t, ring.produce(&client)) // asleep: ring the doorbell
	ring.end_sleep(&server)
	testing.expect(t, !ring.prepare_sleep(&server)) // an entry is waiting: do not sleep
	got: vx.Sqe
	testing.expect(t, ring.consume(&server, mem.ptr_to_bytes(&got)) == .Ok && got.user_data == 5)
	e = sqe_slot(&client)
	e^ = {user_data = 6}
	testing.expect(t, !ring.produce(&client)) // awake: no doorbell
	testing.expect(t, ring.consume(&server, mem.ptr_to_bytes(&got)) == .Ok)

	// Arenas: each side writes its own; the peer's ranges are checked.
	mine := ring.arena(&client)
	testing.expect(t, len(mine) == 4096)
	mine[100] = 42
	b, bok := ring.peer_bytes(&server, 100, 1)
	testing.expect(t, bok && b[0] == 42)
	_, bok = ring.peer_bytes(&server, 4000, 97)
	testing.expect(t, !bok)
	_, bok = ring.peer_bytes(&server, max(u64), 2)
	testing.expect(t, !bok)
}

@(test)
test_hostile_peer :: proc(t: ^testing.T) {
	memory, h, ok := make_ring({8, 8, 64, 32, 0, 0})
	if !testing.expect(t, ok) {
		return
	}
	defer free_ring(memory)
	client, server: ring.Ring
	testing.expect(t, ring.attach(&server, memory[:h.size], .Server) == .Ok)
	testing.expect(t, ring.attach(&server, memory[:h.size - 1], .Server) == .Err_Invalid) // mapping too small
	header(memory).cq_offset += 64 // a rewritten header
	testing.expect(t, ring.attach(&client, memory[:h.size], .Client) == .Err_Invalid)
	header(memory).cq_offset -= 64

	// A client whose tail runs past what fits: the server marks the ring broken.
	lines(memory)[.Sq_Tail].index = 9
	got: vx.Sqe
	testing.expect(t, ring.consume(&server, mem.ptr_to_bytes(&got)) == .Err_Bad_State)
	lines(memory)[.Sq_Tail].index = 1 // putting it back does not mend it
	testing.expect(t, ring.consume(&server, mem.ptr_to_bytes(&got)) == .Err_Bad_State)
	testing.expect(t, sqe_slot(&server) == nil)
}

// --- Two threads and a doorbell ---

Doorbell :: struct { // what ring_notify and a port_wait do, in host terms
	lock:  sync.Mutex,
	rung:  sync.Cond,
	count: u64,
}

ring_bell :: proc(d: ^Doorbell) {
	sync.mutex_lock(&d.lock)
	d.count += 1
	sync.cond_broadcast(&d.rung)
	sync.mutex_unlock(&d.lock)
}

bell_count :: proc(d: ^Doorbell) -> u64 {
	sync.mutex_lock(&d.lock)
	c := d.count
	sync.mutex_unlock(&d.lock)
	return c
}

wait_bell :: proc(d: ^Doorbell, seen: u64) {
	sync.mutex_lock(&d.lock)
	for d.count == seen {
		sync.cond_wait(&d.rung, &d.lock)
	}
	sync.mutex_unlock(&d.lock)
}

STRESS_ENTRIES :: 2_000_000

Stress :: struct {
	client, server: ring.Ring,
	server_bell:    Doorbell,
}

producer :: proc(s: ^Stress) {
	for i in u64(0) ..< STRESS_ENTRIES {
		e := sqe_slot(&s.client)
		for e == nil {
			thread.yield() // full: let the consumer run
			e = sqe_slot(&s.client)
		}
		e^ = {user_data = i}
		if ring.produce(&s.client) {
			ring_bell(&s.server_bell)
		}
	}
}

alarm_fired :: proc "c" (sig: posix.Signal) {
	msg := "ring_test: the consumer slept through a doorbell (lost wake-up)\n"
	posix.write(posix.STDERR_FILENO, raw_data(msg), len(msg))
	posix._exit(1)
}

@(test)
test_threads :: proc(t: ^testing.T) {
	memory, h, ok := make_ring({64, 64, 64, 32, 0, 0})
	if !testing.expect(t, ok) {
		return
	}
	defer free_ring(memory)
	s := new(Stress)
	defer free(s)
	testing.expect(t, ring.attach(&s.client, memory[:h.size], .Client) == .Ok)
	testing.expect(t, ring.attach(&s.server, memory[:h.size], .Server) == .Ok)
	posix.signal(.SIGALRM, alarm_fired)
	posix.alarm(60)

	th := thread.create_and_start_with_poly_data(s, producer)
	expect, sleeps: u64
	in_order := true
	for expect < STRESS_ENTRIES {
		got: vx.Sqe
		if ring.consume(&s.server, mem.ptr_to_bytes(&got)) == .Ok {
			in_order = in_order && got.user_data == expect
			expect += 1
			continue
		}
		seen := bell_count(&s.server_bell) // before announcing: a ring after this is not missed
		if ring.prepare_sleep(&s.server) {
			sleeps += 1
			wait_bell(&s.server_bell, seen)
		}
		ring.end_sleep(&s.server)
	}
	thread.join(th)
	thread.destroy(th)
	posix.alarm(0)
	testing.expect(t, in_order)
	testing.expect(t, sleeps > 0) // the handshake was exercised, not just the busy path
}
