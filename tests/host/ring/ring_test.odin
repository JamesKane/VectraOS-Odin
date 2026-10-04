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
slot :: proc(r: ^ring.Ring, $T: typeid) -> ^T {
	e, ok := ring.produce_slot(r)
	if !ok {
		return nil
	}
	assert(len(e) >= size_of(T))
	return (^T)(raw_data(e))
}

header :: proc(memory: []u8) -> ^vx.Ring_Header {
	return (^vx.Ring_Header)(raw_data(memory))
}

lines :: proc(memory: []u8) -> ^[vx.Ring_Line]vx.Ring_Index {
	return (^[vx.Ring_Line]vx.Ring_Index)(&memory[vx.RING_INDEX_OFFSET])
}

@(test)
test_layout :: proc(t: ^testing.T) {
	refused := []vx.Ring_Params {
		{3, 4, 64, 32, 0, 0}, // not a power of two
		{8192, 4, 64, 32, 0, 0},
		{4, 4, 40, 32, 0, 0}, // not a multiple of 16
	}
	for p in refused {
		_, status := ring.layout(p)
		testing.expectf(t, status == .Err_Invalid, "layout(%v) is %v", p, status)
	}
	h, status := ring.layout({64, 64, 64, 32, 5000, 1})
	testing.expect_value(t, status, vx.Status.Ok)
	testing.expect_value(t, h.sq_offset, 8192)
	testing.expect_value(t, h.cq_offset, 8192 + 64 * 64)
	testing.expect_value(t, h.client_arena_offset % 4096, 0)
	testing.expect_value(t, h.client_arena_size, 8192)
	testing.expect_value(t, h.server_arena_size, 4096)
	testing.expect_value(t, h.size, h.server_arena_offset + 4096)
}

@(test)
test_queues :: proc(t: ^testing.T) {
	p := vx.Ring_Params{8, 8, 64, 32, 4096, 4096}
	memory, h, ok := make_ring(p)
	if !testing.expect(t, ok) {
		return
	}
	defer free_ring(memory)
	client, server: ring.Ring
	testing.expect_value(t, ring.attach(&client, memory[:h.size], .Client, p), vx.Status.Ok)
	testing.expect_value(t, ring.attach(&server, memory[:h.size], .Server, p), vx.Status.Ok)

	// Three laps of the queue, filling it each time.
	produced, consumed: u64
	for _ in 0 ..< 3 {
		for _ in 0 ..< 8 {
			e := slot(&client, vx.Sqe)
			if !testing.expect(t, e != nil) {
				return
			}
			e^ = {opcode = 1, user_data = produced}
			produced += 1
			ring.produce(&client)
		}
		testing.expect(t, slot(&client, vx.Sqe) == nil) // full
		got: vx.Sqe
		for ring.consume(&server, mem.ptr_to_bytes(&got)) == .Ok {
			testing.expect_value(t, got.user_data, consumed)
			consumed += 1
		}
		testing.expect_value(t, consumed, produced)
	}

	// Completions flow the other way.
	c := slot(&server, vx.Cqe)
	c^ = {user_data = 77, result = -2}
	ring.produce(&server)
	done: vx.Cqe
	testing.expect_value(t, ring.consume(&client, mem.ptr_to_bytes(&done)), vx.Status.Ok)
	testing.expect_value(t, done.user_data, 77)
	testing.expect_value(t, done.result, -2)
	testing.expect_value(t, ring.consume(&client, mem.ptr_to_bytes(&done)), vx.Status.Err_Should_Wait)

	// The sleep handshake: the producer learns the consumer is asleep.
	testing.expect(t, ring.prepare_sleep(&server)) // empty: may sleep
	e := slot(&client, vx.Sqe)
	e^ = {user_data = 5}
	testing.expect(t, ring.produce(&client)) // asleep: ring the doorbell
	ring.end_sleep(&server)
	testing.expect(t, !ring.prepare_sleep(&server)) // an entry is waiting: do not sleep
	got: vx.Sqe
	testing.expect_value(t, ring.consume(&server, mem.ptr_to_bytes(&got)), vx.Status.Ok)
	testing.expect_value(t, got.user_data, 5)
	e = slot(&client, vx.Sqe)
	e^ = {user_data = 6}
	testing.expect(t, !ring.produce(&client)) // awake: no doorbell
	testing.expect_value(t, ring.consume(&server, mem.ptr_to_bytes(&got)), vx.Status.Ok)

	// Arenas: each side writes its own; the peer's ranges are checked.
	mine := ring.arena(&client)
	testing.expect_value(t, len(mine), 4096)
	mine[100] = 42
	b, bok := ring.peer_bytes(&server, 100, 1)
	if testing.expect(t, bok) {
		testing.expect_value(t, b[0], 42)
	}
	_, bok = ring.peer_bytes(&server, 4000, 97)
	testing.expect(t, !bok)
	_, bok = ring.peer_bytes(&server, max(u64), 2)
	testing.expect(t, !bok)
}

@(test)
test_hostile_peer :: proc(t: ^testing.T) {
	p := vx.Ring_Params{8, 8, 64, 32, 0, 0}
	memory, h, ok := make_ring(p)
	if !testing.expect(t, ok) {
		return
	}
	defer free_ring(memory)
	server, other: ring.Ring
	testing.expect_value(t, ring.attach(&other, memory[:h.size - 1], .Server, p), vx.Status.Err_Invalid) // mapping too small
	testing.expect(t, slot(&other, vx.Cqe) == nil) // a failed attach leaves nothing usable
	header(memory).cq_offset += 64 // a rewritten header
	testing.expect_value(t, ring.attach(&other, memory[:h.size], .Client, p), vx.Status.Err_Invalid)
	header(memory).cq_offset -= 64

	// A ring made, consistently, with bigger entries than this side's protocol
	// has: refused, since each consume would copy an entry that size into the
	// caller's (smaller) buffer.
	wide, big, wok := make_ring({8, 8, 64, 256, 0, 0})
	if !testing.expect(t, wok) {
		return
	}
	defer free_ring(wide)
	testing.expect(t, big.size <= h.size + 4096) // it may even fit the same mapping
	testing.expect_value(t, ring.attach(&other, wide[:big.size], .Client, p), vx.Status.Err_Invalid)

	// A client whose tail runs past what fits: the server marks the ring broken.
	testing.expect_value(t, ring.attach(&server, memory[:h.size], .Server, p), vx.Status.Ok)
	lines(memory)[.Sq_Tail].index = 9
	got: vx.Sqe
	testing.expect(t, server.intact)
	testing.expect_value(t, ring.consume(&server, mem.ptr_to_bytes(&got)), vx.Status.Err_Bad_State)
	testing.expect(t, !server.intact) // by the overrun check, not by an earlier failure
	lines(memory)[.Sq_Tail].index = 1 // putting it back does not mend it
	testing.expect_value(t, ring.consume(&server, mem.ptr_to_bytes(&got)), vx.Status.Err_Bad_State)
	testing.expect(t, slot(&server, vx.Sqe) == nil)
}

// --- Two threads and a doorbell ---

Doorbell :: struct { // what ring_notify and a port_wait do, in host terms
	lock:  sync.Mutex,
	rung:  sync.Cond,
	count: u64,
}

ring_bell :: proc(d: ^Doorbell) {
	sync.guard(&d.lock)
	d.count += 1
	sync.cond_broadcast(&d.rung)
}

bell_count :: proc(d: ^Doorbell) -> u64 {
	sync.guard(&d.lock)
	return d.count
}

wait_bell :: proc(d: ^Doorbell, seen: u64) {
	sync.guard(&d.lock)
	for d.count == seen {
		sync.cond_wait(&d.rung, &d.lock)
	}
}

STRESS_ENTRIES :: 2_000_000

Stress :: struct {
	client, server: ring.Ring,
	server_bell:    Doorbell,
}

producer :: proc(s: ^Stress) {
	for i in u64(0) ..< STRESS_ENTRIES {
		e := slot(&s.client, vx.Sqe)
		for e == nil {
			thread.yield() // full: let the consumer run
			e = slot(&s.client, vx.Sqe)
		}
		e^ = {user_data = i}
		if ring.produce(&s.client) {
			ring_bell(&s.server_bell)
		}
	}
}

// The watchdog is a process-wide alarm, not testing.set_fail_timeout: on a
// timeout the runner cancels the test's thread with pthread_cancel and joins
// it, and a thread asleep in sync.cond_wait (a futex wait on macOS, not a
// cancellation point) never sees the cancel, so the runner would hang in the
// join instead of reporting. The producer thread would run on regardless.
alarm_fired :: proc "c" (sig: posix.Signal) {
	msg := "ring_test: the consumer slept through a doorbell (lost wake-up)\n"
	posix.write(posix.STDERR_FILENO, raw_data(msg), len(msg))
	posix._exit(1)
}

@(test)
test_threads :: proc(t: ^testing.T) {
	p := vx.Ring_Params{64, 64, 64, 32, 0, 0}
	memory, h, ok := make_ring(p)
	if !testing.expect(t, ok) {
		return
	}
	defer free_ring(memory)
	s := new(Stress)
	defer free(s)
	testing.expect_value(t, ring.attach(&s.client, memory[:h.size], .Client, p), vx.Status.Ok)
	testing.expect_value(t, ring.attach(&s.server, memory[:h.size], .Server, p), vx.Status.Ok)
	posix.signal(.SIGALRM, alarm_fired)
	posix.alarm(60)

	th := thread.create_and_start_with_poly_data(s, producer)
	consumed, sleeps: u64
	out_of_order := 0
	for consumed < STRESS_ENTRIES {
		got: vx.Sqe
		if ring.consume(&s.server, mem.ptr_to_bytes(&got)) == .Ok {
			if got.user_data != consumed {
				out_of_order += 1
			}
			consumed += 1
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
	testing.expect_value(t, out_of_order, 0)
	testing.expect(t, sleeps > 0) // the handshake was exercised, not just the busy path
}
