// ktest: the kernel's tests, run from user space as the root task when the
// kernel command line says vx.root=ktest (tests/qemu/m2/ktest.ndb). Each
// check prints a line only when it fails; the last line counts them. Ported
// from upstream's M2 tests/kernel/ktest.c, case by case.
package ktest

import "base:intrinsics"
import vx "abi:vx"
import "vx:ring"
import "vx:rt"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if ok {
		return
	}
	failures += 1
	rt.print("ktest: FAILED line ")
	rt.print_u64(u64(loc.line))
	rt.print(": ", what, "\n")
}

self: vx.Handle

after_ms :: proc "contextless" (ms: i64) -> vx.Instant {
	return rt.clock_read() + vx.Instant(ms * 1_000_000)
}

bytes_of :: proc "contextless" (p: ^$T) -> []u8 {
	return (cast([^]u8)p)[:size_of(T)]
}

// --- Messages ---

Note :: struct {
	h:    vx.Msg_Header,
	text: [16]u8,
}

test_channel_basics :: proc "contextless" () {
	a, b, st := rt.channel_create()
	check(st == .Ok)
	out := Note{h = {ordinal = 7}}
	copy(out.text[:], "hello")
	check(rt.channel_write(a, bytes_of(&out)) == .Ok)

	tiny: [8]u8
	size: vx.Msg_Size
	size, st = rt.channel_read(b, tiny[:])
	check(st == .Err_Too_Small)
	check(size.bytes == size_of(Note) && size.handles == 0)

	inn: Note
	size, st = rt.channel_read(b, bytes_of(&inn))
	check(st == .Ok)
	check(size.bytes == size_of(Note))
	check(inn.h.ordinal == 7 && inn.text[0] == 'h' && inn.text[4] == 'o')
	check(inn.h.sender_intent == .Interactive) // the kernel's, not the sender's
	_, st = rt.channel_read(b, bytes_of(&inn))
	check(st == .Err_Should_Wait)

	// A message shorter than a header, or a channel end sent through itself, is refused.
	check(rt.channel_write(a, bytes_of(&out)[:4]) == .Err_Invalid)
	itself := [1]vx.Handle{a}
	check(rt.channel_write(a, bytes_of(&out), itself[:]) == .Err_Invalid)

	// Closing one end: the other reads PEER_CLOSED and cannot write.
	check(rt.handle_close(a) == .Ok)
	_, st = rt.channel_read(b, bytes_of(&inn))
	check(st == .Err_Peer_Closed)
	check(rt.channel_write(b, bytes_of(&out)) == .Err_Peer_Closed)
	check(rt.handle_close(b) == .Ok)
}

test_handle_transfer :: proc "contextless" () {
	a, b, st := rt.channel_create()
	check(st == .Ok)
	c: vx.Handle
	c, st = rt.counter_create(5)
	check(st == .Ok)
	out := Note{h = {ordinal = 1}}
	moving := [1]vx.Handle{c}
	check(rt.channel_write(a, bytes_of(&out), moving[:]) == .Ok)
	_, st = rt.counter_read(c)
	check(st == .Err_Bad_Handle) // it left the table

	inn: Note
	got: [1]vx.Handle
	size: vx.Msg_Size
	size, st = rt.channel_read(b, bytes_of(&inn), got[:0])
	check(st == .Err_Too_Small && size.handles == 1)
	size, st = rt.channel_read(b, bytes_of(&inn), got[:])
	check(st == .Ok && size.handles == 1)
	v, vst := rt.counter_read(got[0])
	check(got[0] != 0 && vst == .Ok && v == 5)

	// A handle can be duplicated with fewer rights, never more.
	weak, wst := rt.handle_dup(got[0], {.Read})
	check(wst == .Ok)
	v, vst = rt.counter_read(weak)
	check(vst == .Ok && v == 5)
	check(rt.counter_signal(weak, 9) == .Err_Access)
	_, sst := rt.handle_dup(weak, {.Read, .Signal})
	check(sst == .Err_Access)
	_ = rt.handle_close(weak)
	_ = rt.handle_close(got[0])
	_ = rt.handle_close(a)
	_ = rt.handle_close(b)
}

// --- Ports and bindings ---

test_bindings :: proc "contextless" () {
	pk: [4]vx.Packet
	port, st := rt.port_create()
	check(st == .Ok)
	a, b, cst := rt.channel_create()
	check(cst == .Ok)

	// READABLE fires when a message arrives, once.
	check(rt.port_bind(port, b, .Readable, 11) == .Ok)
	_, st = rt.port_wait(port, after_ms(1), 0, pk[:])
	check(st == .Err_Timed_Out)
	out: Note
	check(rt.channel_write(a, bytes_of(&out)) == .Ok)
	n: int
	n, st = rt.port_wait(port, after_ms(100), 0, pk[:])
	check(n == 1)
	check(pk[0].key == 11 && pk[0].trigger == .Readable && pk[0].source == u32(b))
	check(rt.channel_write(a, bytes_of(&out)) == .Ok)
	_, st = rt.port_wait(port, after_ms(1), 0, pk[:])
	check(st == .Err_Timed_Out) // one-shot

	// A binding whose condition already holds fires at once.
	check(rt.port_bind(port, b, .Readable, 12) == .Ok)
	n, st = rt.port_wait(port, after_ms(100), 0, pk[:])
	check(n == 1 && pk[0].key == 12 && pk[0].value == 2)

	// PEER_CLOSED.
	check(rt.port_bind(port, b, .Peer_Closed, 13) == .Ok)
	_ = rt.handle_close(a)
	n, st = rt.port_wait(port, after_ms(100), 0, pk[:])
	check(n == 1 && pk[0].key == 13)
	_ = rt.handle_close(b)

	// COUNTER_GE fires when the counter reaches the threshold, with its value.
	c, ccst := rt.counter_create(0)
	check(ccst == .Ok)
	check(rt.port_bind(port, c, .Counter_Ge, 14, 5) == .Ok)
	check(rt.counter_signal(c, 3) == .Ok)
	_, st = rt.port_wait(port, after_ms(1), 0, pk[:])
	check(st == .Err_Timed_Out)
	check(rt.counter_signal(c, 7) == .Ok)
	n, st = rt.port_wait(port, after_ms(100), 0, pk[:])
	check(n == 1 && pk[0].key == 14 && pk[0].value == 7)
	v, _ := rt.counter_read(c)
	check(rt.counter_signal(c, 6) == .Ok && v == 7) // never backwards
	v, _ = rt.counter_read(c)
	check(v == 7)

	// A trigger that does not fit the source is refused.
	check(rt.port_bind(port, c, .Readable, 15) == .Err_Invalid)
	_ = rt.handle_close(c)
	_ = rt.handle_close(port)
}

// --- Threads, futexes and calls ---

// A stack for a thread in this task: a mapped VMO, returned as its top.
new_stack :: proc "contextless" () -> u64 {
	vmo, st := rt.vmo_create(16 * 1024)
	if st != .Ok {
		return 0
	}
	base, mst := rt.as_map(self, vmo, 0, 16 * 1024, {.Write})
	_ = rt.handle_close(vmo) // the mapping keeps it
	return mst == .Ok ? base + 16 * 1024 : 0
}

Shared :: struct {
	stage:      u32, // the main thread and the worker take turns through it
	server_end: vx.Handle, // the worker serves calls on this channel end
}

wait_for_stage :: proc "contextless" (s: ^Shared, want: u32) {
	for {
		now := intrinsics.atomic_load(&s.stage)
		if now == want {
			return
		}
		_ = rt.futex_wait(&s.stage, now, after_ms(1000))
	}
}

set_stage :: proc "contextless" (s: ^Shared, to: u32) {
	intrinsics.atomic_store(&s.stage, to)
	_, _ = rt.futex_wake(&s.stage, 1)
}

Request :: struct {
	h: vx.Msg_Header,
	n: u64,
}

// The second thread: a futex handshake, then a server answering two calls on
// its channel end (doubling the number), then an exit.
worker :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	s := cast(^Shared)uintptr(arg)
	wait_for_stage(s, 1)
	set_stage(s, 2)

	port, _ := rt.port_create()
	served := 0
	for served < 2 {
		pk: [1]vx.Packet
		_ = rt.port_bind(port, s.server_end, .Readable, 1)
		if n, _ := rt.port_wait(port, after_ms(2000), 0, pk[:]); n != 1 {
			break
		}
		rq: Request
		for {
			if _, st := rt.channel_read(s.server_end, bytes_of(&rq)); st != .Ok {
				break
			}
			rq.n *= 2
			_ = rt.channel_write(s.server_end, bytes_of(&rq)) // the txid comes back as it came
			served += 1
		}
	}
	_ = rt.handle_close(port)
	set_stage(s, 3)
	rt.thread_exit(0)
}

shared: Shared

test_threads_and_calls :: proc "contextless" () {
	a, b, st := rt.channel_create()
	check(st == .Ok)
	shared.server_end = b
	sp := new_stack()
	check(sp != 0)
	th: vx.Handle
	th, st = rt.thread_create(self)
	check(st == .Ok)
	entry := u64(uintptr(rawptr(worker)))
	check(rt.thread_start(th, entry, sp, 0, u64(uintptr(&shared))) == .Ok)
	check(rt.thread_start(th, entry, sp, 0, u64(uintptr(&shared))) == .Err_Bad_State) // only once

	set_stage(&shared, 1)
	wait_for_stage(&shared, 2)
	check(intrinsics.atomic_load(&shared.stage) == 2)

	// A futex whose word already changed does not sleep.
	check(rt.futex_wait(&shared.stage, 99, after_ms(100)) == .Err_Bad_State)

	for n in u64(21) ..= 22 {
		rq := Request{n = n}
		reply: Request
		call := vx.Call {
			wr_bytes = &rq,
			wr_len   = size_of(rq),
			rd_bytes = &reply,
			rd_cap   = size_of(reply),
		}
		check(rt.channel_call(a, &call, after_ms(2000)) == .Ok)
		check(reply.n == n * 2 && call.actual.bytes == size_of(reply))
		check(reply.h.txid != 0 && reply.h.txid & 0x8000_0000 != 0) // the kernel's txid came back
	}
	wait_for_stage(&shared, 3)
	check(intrinsics.atomic_load(&shared.stage) == 3)
	_ = rt.handle_close(th)
	_ = rt.handle_close(a)
	_ = rt.handle_close(b)
}

// --- Child tasks ---
//
// Without an ELF loader in user space yet, a child runs a few instructions
// written here for each architecture.

Child_Code :: enum {
	Exit_7,
	Spin,
	Block,
}

// Writes the child's code into `code`; returns its length in bytes.
write_child :: proc "contextless" (code: []u8, what: Child_Code) -> int {
	n := 0
	when ODIN_ARCH == .amd64 {
		emit :: proc "contextless" (code: []u8, n: ^int, bytes: ..u8) {
			for b in bytes {
				code[n^] = b
				n^ += 1
			}
		}
		emit32 :: proc "contextless" (code: []u8, n: ^int, v: u32) {
			emit(code, n, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
		}
		switch what {
		case .Exit_7:
			emit(code, &n, 0xbf); emit32(code, &n, 7) // mov $7, %edi
			emit(code, &n, 0xb8); emit32(code, &n, u32(vx.Syscall.Thread_Exit)) // mov $thread_exit, %eax
			emit(code, &n, 0x0f, 0x05) // syscall
		case .Spin:
			emit(code, &n, 0xeb, 0xfe) // jmp .
		case .Block:
			emit(code, &n, 0x48, 0x8d, 0x7c, 0x24, 0xf0) // lea -16(%rsp), %rdi: a zero word
			emit(code, &n, 0x31, 0xf6) // xor %esi, %esi: expect 0
			emit(code, &n, 0x48, 0xba); emit32(code, &n, 0xffffffff); emit32(code, &n, 0x7fffffff) // mov $INT64_MAX, %rdx
			emit(code, &n, 0xb8); emit32(code, &n, u32(vx.Syscall.Futex_Wait)) // mov $futex_wait, %eax
			emit(code, &n, 0x0f, 0x05) // syscall
			emit(code, &n, 0xeb, 0xfe) // jmp .
		}
	} else {
		emit :: proc "contextless" (code: []u8, n: ^int, words: ..u32) {
			for w in words {
				code[n^], code[n^ + 1], code[n^ + 2], code[n^ + 3] = u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24)
				n^ += 4
			}
		}
		switch what {
		case .Exit_7:
			emit(code, &n, 0xd2800000 | 7 << 5) // movz x0, #7
			emit(code, &n, 0xd2800008 | u32(vx.Syscall.Thread_Exit) << 5) // movz x8, #thread_exit
			emit(code, &n, 0xd4000001) // svc #0
		case .Spin:
			emit(code, &n, 0x14000000) // b .
		case .Block:
			emit(code, &n, 0xd10043e0) // sub x0, sp, #16: a zero word
			emit(code, &n, 0xd2800001) // movz x1, #0: expect 0
			emit(code, &n, 0x92800002) // movn x2, #0: all ones
			emit(code, &n, 0xd341fc42) // lsr x2, x2, #1: INT64_MAX
			emit(code, &n, 0xd2800008 | u32(vx.Syscall.Futex_Wait) << 5) // movz x8, #futex_wait
			emit(code, &n, 0xd4000001) // svc #0
			emit(code, &n, 0x14000000) // b .
		}
	}
	return n
}

CHILD_CODE :: u64(0x10_0000)
CHILD_STACK_TOP :: u64(0x20_0000)

// A child task running `what`, started.
start_child :: proc "contextless" (what: Child_Code) -> (task: vx.Handle, ok: bool) {
	code: [64]u8
	n := write_child(code[:], what)
	text, stack, th: vx.Handle // closing 0 is a harmless BAD_HANDLE
	defer {
		_ = rt.handle_close(text)
		_ = rt.handle_close(stack)
		_ = rt.handle_close(th)
	}
	st: vx.Status
	if task, st = rt.task_create("child"); st != .Ok {
		return
	}
	if text, st = rt.vmo_create(4096); st != .Ok || rt.vmo_write(text, 0, code[:n]) != .Ok {
		return
	}
	if _, st = rt.as_map(task, text, 0, 4096, {.Exec}, CHILD_CODE); st != .Ok {
		return
	}
	if stack, st = rt.vmo_create(4096); st != .Ok {
		return
	}
	if _, st = rt.as_map(task, stack, 0, 4096, {.Write}, CHILD_STACK_TOP - 4096); st != .Ok {
		return
	}
	if th, st = rt.thread_create(task); st != .Ok {
		return
	}
	return task, rt.thread_start(th, CHILD_CODE, CHILD_STACK_TOP, 0, 0) == .Ok
}

// Waits for a task's EXIT binding; returns its exit status, or min(i64).
wait_exit :: proc "contextless" (port, task: vx.Handle) -> i64 {
	pk: [1]vx.Packet
	if rt.port_bind(port, task, .Exit, 99) != .Ok {
		return min(i64)
	}
	if n, _ := rt.port_wait(port, after_ms(2000), 0, pk[:]); n != 1 || pk[0].key != 99 {
		return min(i64)
	}
	return i64(pk[0].value)
}

test_tasks :: proc "contextless" () {
	port, _ := rt.port_create()

	// A child that exits on its own: its status is the task's, and it is torn down.
	child, ok := start_child(.Exit_7)
	check(ok)
	check(wait_exit(port, child) == 7)
	info, st := rt.task_info(child)
	check(st == .Ok)
	check(info.state == .Exited && info.exit_status == 7 && info.threads == 0 && info.mapped == 0)
	_, lst := rt.thread_create(child)
	check(lst == .Err_Bad_State) // an ended task takes no threads
	_ = rt.handle_close(child)

	// A child spinning in user mode, perhaps on another CPU, is killed.
	child, ok = start_child(.Spin)
	check(ok)
	info, st = rt.task_info(child)
	check(st == .Ok && info.state == .Running && info.threads == 1)
	check(rt.task_kill(child, 99) == .Ok)
	check(wait_exit(port, child) == 99)
	_ = rt.handle_close(child)

	// A child blocked in the kernel is killed too: its wait ends with KILLED.
	child, ok = start_child(.Block)
	check(ok)
	pk: [1]vx.Packet
	_, _ = rt.port_wait(port, after_ms(20), 0, pk[:]) // give it time to block
	check(rt.task_kill(child, 55) == .Ok)
	check(wait_exit(port, child) == 55)
	_ = rt.handle_close(child)

	// A task that never ran ends at once when killed, and its binding fires.
	child, st = rt.task_create("idle")
	check(st == .Ok)
	check(rt.task_kill(child, 3) == .Ok)
	check(wait_exit(port, child) == 3)
	_ = rt.handle_close(child)
	_ = rt.handle_close(port)
}

// A chain of channel ends, each queued in a message on the next, closed from
// the top: the kernel destroys it one end at a time, never recursing, so no
// depth can overflow its stack.
test_nested_channels :: proc "contextless" () {
	chain: vx.Handle
	built := true
	for i := 0; i < 1000 && built; i += 1 {
		a, b, st := rt.channel_create()
		built = st == .Ok
		n: Note
		if built && chain != 0 {
			moving := [1]vx.Handle{chain}
			built = rt.channel_write(a, bytes_of(&n), moving[:]) == .Ok
		}
		_ = rt.handle_close(a) // b keeps the queue, and the rest of the chain with it
		chain = b
	}
	check(built)
	check(rt.handle_close(chain) == .Ok)
}

// --- Rings ---

never: u32

// Sleeps about a millisecond: a futex wait on a word that never changes.
nap :: proc "contextless" () {
	_ = rt.futex_wait(&never, 0, after_ms(1))
}

// Sleeps until this end's doorbell rings, unless an entry arrived while it
// was getting ready (the protocol lib/check proves).
ring_sleep :: proc "contextless" (r: ^ring.Ring, end, port: vx.Handle) {
	seen, _ := rt.counter_read(end)
	if ring.prepare_sleep(r) {
		pk: [1]vx.Packet
		_ = rt.port_bind(port, end, .Counter_Ge, 1, seen + 1)
		_, _ = rt.port_wait(port, after_ms(2000), 0, pk[:])
	}
	ring.end_sleep(r)
}

OP_DOUBLE :: 1
OP_COUNTER :: 2
OP_STOP :: 3

Ring_Shared :: struct {
	server: ring.Ring,
	end:    vx.Handle,
	stage:  u32,
}

ring_shared: Ring_Shared

// Submits an entry, waiting for room if the queue is full.
put_entry :: proc "contextless" (r: ^ring.Ring, end: vx.Handle, e: ^$T) {
	for {
		slot, ok := ring.produce_slot(r)
		if ok {
			copy(slot, bytes_of(e))
			break
		}
		nap() // full: let the other side drain it
	}
	if ring.produce(r) {
		_ = rt.ring_notify(end)
	}
}

// The server: answers OP_DOUBLE with twice its target, OP_COUNTER with the
// value of the counter whose handle came in the entry's slot, and stops at
// OP_STOP.
ring_server :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	s := cast(^Ring_Shared)uintptr(arg)
	port, _ := rt.port_create()
	for stop := false; !stop; {
		e: vx.Sqe
		if ring.consume(&s.server, bytes_of(&e)) != .Ok {
			ring_sleep(&s.server, s.end, port)
			continue
		}
		out := vx.Cqe{user_data = e.user_data}
		switch {
		case e.opcode == OP_DOUBLE:
			out.result = i64(e.target) * 2
		case e.opcode == OP_COUNTER && .Handles in e.flags:
			got: [1]vx.Handle
			out.result = -1
			if n, _ := rt.ring_take_handles(s.end, e.handle_slot, got[:]); n == 1 {
				v, _ := rt.counter_read(got[0])
				out.result = i64(v)
			}
			_ = rt.handle_close(got[0])
		case:
			stop = true
		}
		put_entry(&s.server, s.end, &out)
	}
	_ = rt.handle_close(port)
	intrinsics.atomic_store(&s.stage, 1)
	_, _ = rt.futex_wake(&s.stage, 1)
	rt.thread_exit(0)
}

test_rings :: proc "contextless" () {
	bad := vx.Ring_Params{3, 16, 64, 32, 0, 0}
	_, st := rt.ring_create(&bad)
	check(st == .Err_Invalid)
	params := vx.Ring_Params{16, 16, 64, 32, 4096, 4096}
	h: vx.Ring_Handles
	h, st = rt.ring_create(&params)
	check(st == .Ok)
	layout, _ := ring.layout(params)
	base, mst := rt.as_map(self, h.memory, 0, layout.size, {.Write})
	check(mst == .Ok)
	memory := (cast([^]u8)uintptr(base))[:layout.size]

	client: ring.Ring
	check(ring.attach(&client, memory, .Client) == .Ok)
	check(ring.attach(&ring_shared.server, memory, .Server) == .Ok)
	ring_shared.end = h.server
	th, tst := rt.thread_create(self)
	check(tst == .Ok)
	check(rt.thread_start(th, u64(uintptr(rawptr(ring_server))), new_stack(), 0, u64(uintptr(&ring_shared))) == .Ok)

	// 200 requests through 16-entry queues: both sides wrap, and both sleep and wake.
	port, _ := rt.port_create()
	sent, done: u64
	right := true
	for done < 200 {
		if sent < 200 && sent - done < 16 {
			e := vx.Sqe{opcode = OP_DOUBLE, user_data = sent, target = sent}
			put_entry(&client, h.client, &e)
			sent += 1
			continue
		}
		c: vx.Cqe
		if ring.consume(&client, bytes_of(&c)) == .Ok {
			right = right && c.user_data == done && c.result == i64(done) * 2
			done += 1
		} else {
			ring_sleep(&client, h.client, port)
		}
	}
	check(right)

	// A handle through the side channel.
	counter, cst := rt.counter_create(33)
	check(cst == .Ok)
	moving := [1]vx.Handle{counter}
	slot, pst := rt.ring_put_handles(h.client, moving[:])
	check(pst == .Ok)
	_, rst := rt.counter_read(counter)
	check(rst == .Err_Bad_Handle) // it left our table
	e := vx.Sqe{opcode = OP_COUNTER, flags = {.Handles}, user_data = 500, handle_slot = slot}
	put_entry(&client, h.client, &e)
	c: vx.Cqe
	for ring.consume(&client, bytes_of(&c)) != .Ok {
		ring_sleep(&client, h.client, port)
	}
	check(c.user_data == 500 && c.result == 33)
	_, est := rt.ring_take_handles(h.server, 15, moving[:])
	check(est == .Err_Invalid) // an empty slot

	// Stop the server, then its end goes: the client sees PEER_CLOSED.
	stop := vx.Sqe{opcode = OP_STOP}
	put_entry(&client, h.client, &stop)
	for intrinsics.atomic_load(&ring_shared.stage) != 1 {
		_ = rt.futex_wait(&ring_shared.stage, 0, after_ms(100))
	}
	_ = rt.handle_close(th)
	check(rt.handle_close(h.server) == .Ok)
	pk: [1]vx.Packet
	check(rt.port_bind(port, h.client, .Peer_Closed, 7) == .Ok)
	n, _ := rt.port_wait(port, after_ms(100), 0, pk[:])
	check(n == 1 && pk[0].key == 7)
	check(rt.ring_notify(h.client) == .Err_Peer_Closed)
	_ = rt.handle_close(h.client)
	_ = rt.handle_close(h.memory)
	_ = rt.handle_close(port)
}

test_vmo_rw :: proc "contextless" () {
	vmo, st := rt.vmo_create(8192)
	check(st == .Ok)
	inn := [8]u8{'a', 'b', 'c', 'd', 'e', 'f', 'g', 0}
	out: [8]u8
	check(rt.vmo_write(vmo, 4092, inn[:]) == .Ok) // across a page boundary
	check(rt.vmo_read(vmo, 4092, out[:]) == .Ok)
	check(out[0] == 'a' && out[6] == 'g')
	check(rt.vmo_read(vmo, 8190, out[:]) == .Err_Range)
	_ = rt.handle_close(vmo)
}

// What svcd checked at M1: a port wait ends at its deadline and not before,
// a self-posted packet is the next thing a wait returns, and a VMO mapped
// where the kernel chooses is zeroed, writable, and stays mapped after its
// handle closes.
test_m1_basics :: proc "contextless" () {
	port, st := rt.port_create()
	check(st == .Ok)
	got: [4]vx.Packet
	deadline := rt.clock_read() + 10_000_000
	_, st = rt.port_wait(port, deadline, 0, got[:])
	check(st == .Err_Timed_Out)
	check(rt.clock_read() >= deadline)
	post := vx.Packet{key = 42, value = 7}
	check(rt.port_post(port, &post) == .Ok)
	n, _ := rt.port_wait(port, vx.INFINITE, 0, got[:])
	check(n == 1 && got[0].key == 42 && got[0].value == 7 && got[0].trigger == .User)
	_ = rt.handle_close(port)

	vmo, vst := rt.vmo_create(64 * 1024)
	check(vst == .Ok)
	addr, mst := rt.as_map(self, vmo, 0, 64 * 1024, {.Write})
	check(mst == .Ok)
	words := cast([^]u64)uintptr(addr)
	check(intrinsics.volatile_load(&words[0]) == 0 && intrinsics.volatile_load(&words[8191]) == 0)
	intrinsics.volatile_store(&words[0], 0x5678)
	intrinsics.volatile_store(&words[8191], 0x1234)
	check(rt.handle_close(vmo) == .Ok) // the mapping keeps it
	check(intrinsics.volatile_load(&words[0]) == 0x5678 && intrinsics.volatile_load(&words[8191]) == 0x1234)
}

contains :: proc "contextless" (s, sub: string) -> bool {
	for i := 0; i + len(sub) <= len(s); i += 1 {
		if s[i:i + len(sub)] == sub {
			return true
		}
	}
	return false
}

// The kernel's spawn message for the root task: its name, a handle to
// itself, the boot image, and the command line that chose ktest.
test_spawn_message :: proc "contextless" () {
	check(rt.self != vx.HANDLE_NONE)
	check(rt.spawn.name == "ktest")
	check(contains(rt.spawn.cmdline, "vx.root=ktest"))
	image := rt.spawn_take("bootimage")
	check(image != vx.HANDLE_NONE && rt.spawn_take("bootimage") == vx.HANDLE_NONE)
	magic: [5]u8
	check(rt.vmo_read(image, 257, magic[:]) == .Ok && string(magic[:]) == "ustar")
	check(rt.vmo_write(image, 0, magic[:1]) == .Err_Access) // read-only
	_ = rt.handle_close(image)
}

// Device objects from the root Resource. ktest stays away from the
// console's own device, which would take the console from the kernel.
when ODIN_ARCH == .amd64 {
	SPARE_LINE :: 3 // ISA IRQ 3: COM2, which nothing uses
	DEVICE :: u64(0xfed0_0000) // the HPET
	RAM :: u64(0x10_0000) // RAM at 1 MiB
} else {
	SPARE_LINE :: 40 // an SPI no device has
	DEVICE :: u64(0x0901_0000) // the PL031 RTC
	RAM :: u64(0x4000_0000) // the start of RAM
}

test_devices :: proc "contextless" () {
	res := rt.spawn_take("resource")
	check(res != vx.HANDLE_NONE)
	weak, wst := rt.handle_dup(res, {.Duplicate, .Inspect})
	check(wst == .Ok)

	_, st := rt.irq_create(weak, SPARE_LINE)
	check(st == .Err_Access) // no MANAGE
	_, st = rt.irq_create(res, 5000)
	check(st == .Err_Range)
	when ODIN_ARCH == .arm64 {
		_, st = rt.irq_create(res, 27)
		check(st == .Err_Range) // a PPI: the kernel's timer
	}
	h: vx.Handle
	h, st = rt.irq_create(res, SPARE_LINE)
	check(st == .Ok)
	_, st = rt.irq_create(res, SPARE_LINE)
	check(st == .Err_Exists) // one Irq a line
	port, _ := rt.port_create()
	pk: [1]vx.Packet
	check(rt.port_bind(port, h, .Counter_Ge, 1, 1) == .Err_Invalid)
	check(rt.port_bind(port, h, .Irq, 1) == .Ok)
	_, st = rt.port_wait(port, after_ms(2), 0, pk[:])
	check(st == .Err_Timed_Out) // nothing raises the line
	check(rt.irq_ack(h) == .Ok)
	check(rt.irq_ack(port) == .Err_Bad_Handle) // not an Irq
	_ = rt.handle_close(port)
	_ = rt.handle_close(h)
	h, st = rt.irq_create(res, SPARE_LINE)
	check(st == .Ok) // free again once its Irq is gone
	_ = rt.handle_close(h)

	_, st = rt.vmo_create_physical(res, RAM, 4096)
	check(st == .Err_Access) // never RAM
	_, st = rt.vmo_create_physical(res, DEVICE + 1, 4096)
	check(st == .Err_Range)
	_, st = rt.vmo_create_physical(weak, DEVICE, 4096)
	check(st == .Err_Access)
	h, st = rt.vmo_create_physical(res, DEVICE, 4096)
	check(st == .Ok)
	word: [4]u8
	check(rt.vmo_read(h, 0, word[:]) == .Err_Unsupported) // map it instead
	at, mst := rt.as_map(self, h, 0, 4096, {})
	check(mst == .Ok)
	value := intrinsics.volatile_load(cast(^u32)uintptr(at)) // HPET: capabilities and revision; PL031: the time
	check(value != 0 && value != 0xffff_ffff)
	_ = rt.handle_close(h)

	when ODIN_ARCH == .amd64 {
		_, st = rt.iorange_create(res, 0xfff0, 0x20)
		check(st == .Err_Range)
		h, st = rt.iorange_create(res, 0x2f8, 8) // COM2's ports
		check(st == .Ok)
		_, st = rt.as_map(self, h, 0, 4096, {})
		check(st == .Err_Invalid)
		_, st = rt.as_map(self, h, 0, 0, {})
		check(st == .Ok)
		_ = rt.inb(0x2fd) // faults unless the port is ours
		check(true)
		_ = rt.handle_close(h)
	} else {
		_, st = rt.iorange_create(res, 0x2f8, 8)
		check(st == .Err_Unsupported)
	}
	_ = rt.handle_close(weak)
	_ = rt.handle_close(res)
}

@(export, link_name="vx_main")
main :: proc() -> int {
	self = rt.self
	test_spawn_message()
	test_m1_basics()
	test_channel_basics()
	test_handle_transfer()
	test_bindings()
	test_threads_and_calls()
	test_tasks()
	test_nested_channels()
	test_rings()
	test_vmo_rw()
	test_devices()
	rt.print("ktest: ")
	rt.print_u64(u64(checks))
	rt.print(" checks, ")
	rt.print_u64(u64(failures))
	rt.print(failures != 0 ? " FAILED\n" : " failed\n")
	port, _ := rt.port_create()
	for {
		pk: [1]vx.Packet
		_, _ = rt.port_wait(port, vx.INFINITE, 0, pk[:])
	}
}
