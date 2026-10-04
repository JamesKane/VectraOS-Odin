// ktest: the kernel's tests, run from user space as the root task when the
// kernel command line says vx.root=ktest (tests/qemu/m2/ktest.ndb). Each
// check prints a line only when it fails; the last line counts them. Ported
// from upstream's M2 tests/kernel/ktest.c, case by case.
package ktest

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:ring"
import "vx:rt"
import "vx:str"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if ok {
		return
	}
	failures += 1
	rt.print("ktest: FAILED line ", u64(loc.line), ": ", what, "\n")
}

after_ms :: proc "contextless" (ms: i64) -> vx.Instant {
	return rt.clock_read() + vx.Instant(ms * 1_000_000)
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
	check(rt.channel_write(a, memory.ptr_to_bytes(&out)) == .Ok)

	tiny: [8]u8
	size: vx.Msg_Size
	size, st = rt.channel_read(b, tiny[:])
	check(st == .Err_Too_Small)
	check(size.bytes == size_of(Note) && size.handles == 0)

	inn: Note
	size, st = rt.channel_read(b, memory.ptr_to_bytes(&inn))
	check(st == .Ok)
	check(size.bytes == size_of(Note))
	check(inn.h.ordinal == 7 && inn.text[0] == 'h' && inn.text[4] == 'o')
	check(inn.h.sender_intent == .Interactive) // the kernel's, not the sender's
	_, st = rt.channel_read(b, memory.ptr_to_bytes(&inn))
	check(st == .Err_Should_Wait)

	// A message shorter than a header, or a channel end sent through itself, is refused.
	check(rt.channel_write(a, memory.ptr_to_bytes(&out)[:4]) == .Err_Invalid)
	itself := [1]vx.Handle{a}
	check(rt.channel_write(a, memory.ptr_to_bytes(&out), itself[:]) == .Err_Invalid)

	// Closing one end: the other reads PEER_CLOSED and cannot write.
	check(rt.handle_close(a) == .Ok)
	_, st = rt.channel_read(b, memory.ptr_to_bytes(&inn))
	check(st == .Err_Peer_Closed)
	check(rt.channel_write(b, memory.ptr_to_bytes(&out)) == .Err_Peer_Closed)
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
	check(rt.channel_write(a, memory.ptr_to_bytes(&out), moving[:]) == .Ok)
	_, st = rt.counter_read(c)
	check(st == .Err_Bad_Handle) // it left the table

	inn: Note
	got: [1]vx.Handle
	size: vx.Msg_Size
	size, st = rt.channel_read(b, memory.ptr_to_bytes(&inn), got[:0])
	check(st == .Err_Too_Small && size.handles == 1)
	size, st = rt.channel_read(b, memory.ptr_to_bytes(&inn), got[:])
	check(st == .Ok && size.handles == 1)
	v, vst := rt.counter_read(got[0])
	check(got[0] != vx.HANDLE_NONE && vst == .Ok && v == 5)

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
	check(rt.channel_write(a, memory.ptr_to_bytes(&out)) == .Ok)
	n: int
	n, st = rt.port_wait(port, after_ms(100), 0, pk[:])
	check(n == 1)
	check(pk[0].key == 11 && pk[0].trigger == .Readable && pk[0].source == u32(b))
	check(rt.channel_write(a, memory.ptr_to_bytes(&out)) == .Ok)
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
	base, mst := rt.as_map(rt.self, vmo, 0, 16 * 1024, {.Write})
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
			if _, st := rt.channel_read(s.server_end, memory.ptr_to_bytes(&rq)); st != .Ok {
				break
			}
			rq.n *= 2
			_ = rt.channel_write(s.server_end, memory.ptr_to_bytes(&rq)) // the txid comes back as it came
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
	th, st = rt.thread_create(rt.self)
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
	Port_Block,
	Use_Simd,
	Read_Loop,
	Fault_Load,
	Break_Step,
}

CHILD_DATA :: u64(0x30_0000) // .Fault_Load's page, which nothing maps at first

Child_Image :: [dynamic; 64]u8 // more than any of them needs

// The child's code.
write_child :: proc "contextless" (what: Child_Code) -> (code: Child_Image) {
	when ODIN_ARCH == .amd64 {
		emit :: proc "contextless" (code: ^Child_Image, bytes: ..u8) {
			_ = append(code, ..bytes)
		}
		emit32 :: proc "contextless" (code: ^Child_Image, v: u32) {
			emit(code, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
		}
		what := what
		if what == .Use_Simd {
			emit(&code, 0x66, 0x0f, 0xef, 0xc0) // pxor %xmm0, %xmm0: user tasks have SIMD (ADR-0004)
			what = .Exit_7
		}
		if what == .Break_Step {
			emit(&code, 0xcc) // int3: a breakpoint, then exit 7
			what = .Exit_7
		}
		switch what {
		case .Exit_7, .Use_Simd, .Break_Step:
			emit(&code, 0xbf); emit32(&code, 7) // mov $7, %edi
			emit(&code, 0xb8); emit32(&code, u32(vx.Syscall.Thread_Exit)) // mov $thread_exit, %eax
			emit(&code, 0x0f, 0x05) // syscall
		case .Spin:
			emit(&code, 0xeb, 0xfe) // jmp .
		case .Read_Loop:
			emit(&code, 0x48, 0x8b, 0x44, 0x24, 0xf8) // 1: mov -8(%rsp), %rax: a load from its stack
			emit(&code, 0xeb, 0xf9) // jmp 1b, with no system call
		case .Fault_Load:
			emit(&code, 0x48, 0xb8); emit32(&code, u32(CHILD_DATA)); emit32(&code, 0) // movabs $CHILD_DATA, %rax
			emit(&code, 0x48, 0x8b, 0x10) // mov (%rax), %rdx: faults until it is mapped
			emit(&code, 0x48, 0x89, 0xd7) // mov %rdx, %rdi: what it loaded
			emit(&code, 0xb8); emit32(&code, u32(vx.Syscall.Thread_Exit)) // mov $thread_exit, %eax: is its exit status
			emit(&code, 0x0f, 0x05) // syscall
		case .Port_Block:
			emit(&code, 0x48, 0x8d, 0x74, 0x24, 0xf0) // lea -16(%rsp), %rsi: the handle's place
			emit(&code, 0x31, 0xff) // xor %edi, %edi: no options
			emit(&code, 0xb8); emit32(&code, u32(vx.Syscall.Port_Create)) // mov $port_create, %eax
			emit(&code, 0x0f, 0x05) // syscall
			emit(&code, 0x8b, 0x7c, 0x24, 0xf0) // mov -16(%rsp), %edi: the port
			emit(&code, 0x48, 0xbe); emit32(&code, 0xffffffff); emit32(&code, 0x7fffffff) // mov $INT64_MAX, %rsi: no deadline
			emit(&code, 0x31, 0xd2) // xor %edx, %edx: no leeway
			emit(&code, 0x4c, 0x8d, 0x54, 0x24, 0xc0) // lea -64(%rsp), %r10: a packet's place
			emit(&code, 0x41, 0xb8); emit32(&code, 1) // mov $1, %r8d
			emit(&code, 0xb8); emit32(&code, u32(vx.Syscall.Port_Wait)) // mov $port_wait, %eax
			emit(&code, 0x0f, 0x05) // syscall
			emit(&code, 0xeb, 0xfe) // jmp .
		case .Block:
			emit(&code, 0x48, 0x8d, 0x7c, 0x24, 0xf0) // lea -16(%rsp), %rdi: a zero word
			emit(&code, 0x31, 0xf6) // xor %esi, %esi: expect 0
			emit(&code, 0x48, 0xba); emit32(&code, 0xffffffff); emit32(&code, 0x7fffffff) // mov $INT64_MAX, %rdx
			emit(&code, 0xb8); emit32(&code, u32(vx.Syscall.Futex_Wait)) // mov $futex_wait, %eax
			emit(&code, 0x0f, 0x05) // syscall
			emit(&code, 0xeb, 0xfe) // jmp .
		}
	} else {
		emit :: proc "contextless" (code: ^Child_Image, words: ..u32) {
			for w in words {
				_ = append(code, u8(w), u8(w >> 8), u8(w >> 16), u8(w >> 24))
			}
		}
		what := what
		if what == .Use_Simd {
			emit(&code, 0x9e6703e0) // fmov d0, xzr: user tasks have FP/SIMD (ADR-0004)
			what = .Exit_7
		}
		if what == .Break_Step {
			emit(&code, 0xd4200020) // brk #1: a breakpoint, then exit 7
			what = .Exit_7
		}
		switch what {
		case .Exit_7, .Use_Simd, .Break_Step:
			emit(&code, 0xd2800000 | 7 << 5) // movz x0, #7
			emit(&code, 0xd2800008 | u32(vx.Syscall.Thread_Exit) << 5) // movz x8, #thread_exit
			emit(&code, 0xd4000001) // svc #0
		case .Spin:
			emit(&code, 0x14000000) // b .
		case .Read_Loop:
			emit(&code, 0xf85f83e0) // 1: ldur x0, [sp, #-8]: a load from its stack
			emit(&code, 0x17ffffff) // b 1b, with no system call
		case .Fault_Load:
			emit(&code, 0xd2a00001 | u32(CHILD_DATA >> 16) << 5) // movz x1, #CHILD_DATA >> 16, lsl #16
			emit(&code, 0xf9400022) // ldr x2, [x1]: faults until it is mapped
			emit(&code, 0xaa0203e0) // mov x0, x2: what it loaded
			emit(&code, 0xd2800008 | u32(vx.Syscall.Thread_Exit) << 5) // movz x8, #thread_exit: is its exit status
			emit(&code, 0xd4000001) // svc #0
		case .Port_Block:
			emit(&code, 0xd10043e1) // sub x1, sp, #16: the handle's place
			emit(&code, 0xd2800000) // movz x0, #0: no options
			emit(&code, 0xd2800008 | u32(vx.Syscall.Port_Create) << 5) // movz x8, #port_create
			emit(&code, 0xd4000001) // svc #0
			emit(&code, 0xb85f03e0) // ldur w0, [sp, #-16]: the port
			emit(&code, 0x92800001) // movn x1, #0
			emit(&code, 0xd341fc21) // lsr x1, x1, #1: INT64_MAX, no deadline
			emit(&code, 0xd2800002) // movz x2, #0: no leeway
			emit(&code, 0xd10103e3) // sub x3, sp, #64: a packet's place
			emit(&code, 0xd2800024) // movz x4, #1
			emit(&code, 0xd2800008 | u32(vx.Syscall.Port_Wait) << 5) // movz x8, #port_wait
			emit(&code, 0xd4000001) // svc #0
			emit(&code, 0x14000000) // b .
		case .Block:
			emit(&code, 0xd10043e0) // sub x0, sp, #16: a zero word
			emit(&code, 0xd2800001) // movz x1, #0: expect 0
			emit(&code, 0x92800002) // movn x2, #0: all ones
			emit(&code, 0xd341fc42) // lsr x2, x2, #1: INT64_MAX
			emit(&code, 0xd2800008 | u32(vx.Syscall.Futex_Wait) << 5) // movz x8, #futex_wait
			emit(&code, 0xd4000001) // svc #0
			emit(&code, 0x14000000) // b .
		}
	}
	return
}

CHILD_CODE :: u64(0x10_0000)
CHILD_STACK_TOP :: u64(0x20_0000)

// Waits until every thread of the task is blocked in the kernel (task_info
// counts them). False if it has not happened within a second.
wait_blocked :: proc "contextless" (task: vx.Handle) -> bool {
	@(static) never: u32
	for _ in 0 ..< 1000 {
		info, st := rt.task_info(task)
		if st == .Ok && info.threads != 0 && info.blocked == info.threads {
			return true
		}
		_ = rt.futex_wait(&never, 0, after_ms(1)) // a millisecond's nap
	}
	return false
}

// A child task running `what`, started.
start_child :: proc "contextless" (what: Child_Code) -> (task: vx.Handle, ok: bool) {
	return start_child_bound(what, vx.HANDLE_NONE, {})
}

// A child task running `what`, started, with its faults going to exc_port if
// that is not HANDLE_NONE (bound before it starts), and a handle to itself as
// its first argument.
start_child_bound :: proc "contextless" (what: Child_Code, exc_port: vx.Handle, options: vx.Exception_Options) -> (task: vx.Handle, ok: bool) {
	code := write_child(what)
	text, stack, th, itself: vx.Handle
	defer rt.close_all(text, stack, th, itself) // itself is the child's once started
	st: vx.Status
	if task, st = rt.task_create("child"); st != .Ok {
		return
	}
	if text, st = rt.vmo_create(4096); st != .Ok || rt.vmo_write(text, 0, code[:]) != .Ok {
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
	if exc_port != vx.HANDLE_NONE && rt.exception_bind(task, exc_port, 5, options) != .Ok {
		return
	}
	if th, st = rt.thread_create(task); st != .Ok {
		return
	}
	if itself, st = rt.handle_dup(task, vx.RIGHTS_SAME); st != .Ok {
		return
	}
	ok = rt.thread_start(th, CHILD_CODE, CHILD_STACK_TOP, itself, 0) == .Ok
	if ok {
		itself = vx.HANDLE_NONE
	}
	return
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
	check(wait_blocked(child)) // in futex_wait, so the kill is of a blocked thread
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
		if built && chain != vx.HANDLE_NONE {
			moving := [1]vx.Handle{chain}
			built = rt.channel_write(a, memory.ptr_to_bytes(&n), moving[:]) == .Ok
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

// The test protocol's opcodes, in a Sqe's opcode.
Op :: enum u16 {
	Double = 1,
	Counter,
	Stop,
}

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
			copy(slot, memory.ptr_to_bytes(e))
			break
		}
		nap() // full: let the other side drain it
	}
	if ring.produce(r) {
		_ = rt.ring_notify(end)
	}
}

// The server: answers .Double with twice its target, .Counter with the value
// of the counter whose handle came in the entry's slot, and stops at
// anything else (.Stop).
ring_server :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	s := cast(^Ring_Shared)uintptr(arg)
	port, _ := rt.port_create()
	for stop := false; !stop; {
		e: vx.Sqe
		if ring.consume(&s.server, memory.ptr_to_bytes(&e)) != .Ok {
			ring_sleep(&s.server, s.end, port)
			continue
		}
		out := vx.Cqe{user_data = e.user_data}
		op := Op(e.opcode)
		switch {
		case op == .Double:
			out.result = i64(e.target) * 2
		case op == .Counter && .Handles in e.flags:
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
	bad := vx.Ring_Params{sq_entries = 3, cq_entries = 16, sqe_size = 64, cqe_size = 32}
	_, st := rt.ring_create(&bad)
	check(st == .Err_Invalid)
	params := vx.Ring_Params {
		sq_entries   = 16,
		cq_entries   = 16,
		sqe_size     = 64,
		cqe_size     = 32,
		client_arena = 4096,
		server_arena = 4096,
	}
	h: vx.Ring_Handles
	h, st = rt.ring_create(&params)
	check(st == .Ok)
	layout, _ := ring.layout(params)
	base, mst := rt.as_map(rt.self, h.memory, 0, layout.size, {.Write})
	check(mst == .Ok)
	ring_memory := (cast([^]u8)uintptr(base))[:layout.size]

	client: ring.Ring
	check(ring.attach(&client, ring_memory, .Client, params) == .Ok)
	check(ring.attach(&ring_shared.server, ring_memory, .Server, params) == .Ok)
	ring_shared.end = h.server
	th, tst := rt.thread_create(rt.self)
	check(tst == .Ok)
	check(rt.thread_start(th, u64(uintptr(rawptr(ring_server))), new_stack(), 0, u64(uintptr(&ring_shared))) == .Ok)

	// 200 requests through 16-entry queues: both sides wrap, and both sleep and wake.
	port, _ := rt.port_create()
	sent, done: u64
	right := true
	for done < 200 {
		if sent < 200 && sent - done < 16 {
			e := vx.Sqe{opcode = u16(Op.Double), user_data = sent, target = sent}
			put_entry(&client, h.client, &e)
			sent += 1
			continue
		}
		c: vx.Cqe
		if ring.consume(&client, memory.ptr_to_bytes(&c)) == .Ok {
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
	e := vx.Sqe{opcode = u16(Op.Counter), flags = {.Handles}, user_data = 500, handle_slot = slot}
	put_entry(&client, h.client, &e)
	c: vx.Cqe
	for ring.consume(&client, memory.ptr_to_bytes(&c)) != .Ok {
		ring_sleep(&client, h.client, port)
	}
	check(c.user_data == 500 && c.result == 33)
	_, est := rt.ring_take_handles(h.server, 15, moving[:])
	check(est == .Err_Invalid) // an empty slot

	// Stop the server, then its end goes: the client sees PEER_CLOSED.
	stop := vx.Sqe{opcode = u16(Op.Stop)}
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
	addr, mst := rt.as_map(rt.self, vmo, 0, 64 * 1024, {.Write})
	check(mst == .Ok)
	words := cast([^]u64)uintptr(addr)
	check(intrinsics.volatile_load(&words[0]) == 0 && intrinsics.volatile_load(&words[8191]) == 0)
	intrinsics.volatile_store(&words[0], 0x5678)
	intrinsics.volatile_store(&words[8191], 0x1234)
	check(rt.handle_close(vmo) == .Ok) // the mapping keeps it
	check(intrinsics.volatile_load(&words[0]) == 0x5678 && intrinsics.volatile_load(&words[8191]) == 0x1234)
}

// The kernel's spawn message for the root task: its name, a handle to
// itself, the boot image, and the command line that chose ktest.
test_spawn_message :: proc "contextless" () {
	check(rt.self != vx.HANDLE_NONE)
	check(rt.spawn.name == "ktest")
	check(str.contains(rt.spawn.cmdline, "vx.root=ktest"))
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
	at, mst := rt.as_map(rt.self, h, 0, 4096, {})
	check(mst == .Ok)
	value := intrinsics.volatile_load(cast(^u32)uintptr(at)) // HPET: capabilities and revision; PL031: the time
	check(value != 0 && value != 0xffff_ffff)
	// A futex in device memory: refused (the kernel has no direct mapping of it to read).
	check(rt.futex_wait(cast(^u32)uintptr(at), value, after_ms(1)) == .Err_Invalid)
	_ = rt.handle_close(h)

	when ODIN_ARCH == .amd64 {
		_, st = rt.iorange_create(res, 0xfff0, 0x20)
		check(st == .Err_Range)
		h, st = rt.iorange_create(res, 0x2f8, 8) // COM2's ports
		check(st == .Ok)
		_, st = rt.as_map(rt.self, h, 0, 4096, {})
		check(st == .Err_Invalid)
		_, st = rt.as_map(rt.self, h, 0, 0, {})
		check(st == .Ok)
		_ = rt.inb(0x2fd) // faults unless the port is ours
		check(true)
		_ = rt.handle_close(h)
	} else {
		_, st = rt.iorange_create(res, 0x2f8, 8)
		check(st == .Err_Unsupported)
	}

	// MSIs: picked by the kernel, for a PCI function (00:03.0 here, by requester ID).
	m1, m2: vx.Handle
	msi, msi2: vx.Msi
	_, _, st = rt.irq_create_msi(weak, 0x18)
	check(st == .Err_Access)
	m1, msi, st = rt.irq_create_msi(res, 0x18)
	check(st == .Ok && msi.address != 0)
	m2, msi2, st = rt.irq_create_msi(res, 0x18)
	check(st == .Ok)
	check(msi2.address == msi.address && msi2.data != msi.data) // one target; another vector or event
	when ODIN_ARCH == .amd64 {
		check(msi.address & 0xfff0_0000 == 0xfee0_0000)
	}
	port, _ = rt.port_create()
	check(rt.port_bind(port, m1, .Irq, 1) == .Ok)
	_, st = rt.port_wait(port, after_ms(2), 0, pk[:])
	check(st == .Err_Timed_Out) // no device writes it
	rt.close_all(port, m1, m2)
	m1, msi2, st = rt.irq_create_msi(res, 0x18)
	check(st == .Ok && msi2.data == msi.data) // freed, so given again
	_ = rt.handle_close(m1)

	// A DMA domain (pass-through): device addresses for a VMO's pages, held until unmapped.
	addrs: [4]u64
	_, st = rt.dma_domain_create(weak)
	check(st == .Err_Access)
	dom: vx.Handle
	dom, st = rt.dma_domain_create(res)
	check(st == .Ok)
	mem, _ := rt.vmo_create(16 * 1024)
	check(rt.dma_map(dom, mem, 4096, 16 * 1024, addrs[:]) == .Err_Range)
	check(rt.dma_map(dom, mem, 0, 16 * 1024, addrs[:]) == .Ok)
	check(addrs[0] != 0 && addrs[3] != 0 && addrs[0] & 4095 == 0 && addrs[0] != addrs[1])
	h, st = rt.vmo_create_physical(res, DEVICE, 4096)
	check(st == .Ok)
	check(rt.dma_map(dom, h, 0, 4096, addrs[:]) == .Err_Unsupported) // not RAM: peer-to-peer comes later
	_ = rt.handle_close(h)
	check(rt.dma_unmap(dom, mem) == .Ok)
	check(rt.dma_unmap(dom, mem) == .Err_Not_Found)
	check(rt.dma_map(dom, mem, 0, 4096, addrs[:]) == .Ok) // held by the domain when it closes, and let go
	rt.close_all(mem, dom, weak, res)
}

// Review fixes (M3): a killed task's freed tables are never used, and a
// mapping that collides with another fails without taking a page from it.
test_torn_down :: proc "contextless" () {
	port, _ := rt.port_create()
	child, st := rt.task_create("doomed")
	check(st == .Ok)
	th: vx.Handle
	th, st = rt.thread_create(child) // made before the kill, started after
	check(st == .Ok)
	check(rt.task_kill(child, -5) == .Ok)
	check(wait_exit(port, child) == -5) // torn down: no threads ever ran
	vmo, _ := rt.vmo_create(4096)
	_, st = rt.as_map(child, vmo, 0, 4096, {})
	check(st == .Err_Bad_State) // its mapping table is gone
	a, b, _ := rt.channel_create()
	check(rt.thread_start(th, 0x40_0000, 0x50_0000, a, 0) != .Ok) // and its handle table
	rt.close_all(b, th, child)

	// A thread's entry and stack must be user addresses: a non-canonical entry
	// would fault in the kernel on its way to user mode.
	child, st = rt.task_create("bad entry")
	check(st == .Ok)
	th, st = rt.thread_create(child)
	check(st == .Ok)
	check(rt.thread_start(th, 0x8000_0000_0000_0000, 0x50_0000, 0, 0) == .Err_Invalid)
	check(rt.thread_start(th, 0x40_0000, 0xffff_8000_0000_0000, 0, 0) == .Err_Invalid)
	check(rt.thread_start(th, 0x0000_8000_0000_0000, 0x50_0000, 0, 0) == .Err_Invalid) // just past the top
	_ = rt.task_kill(child, 0)
	rt.close_all(th, child)

	// vmo (one page) where the kernel puts it; then two pages ending on it:
	// refused, and the first page is still there.
	at, mst := rt.as_map(rt.self, vmo, 0, 4096, {.Write})
	check(mst == .Ok)
	spot := cast(^u64)uintptr(at)
	intrinsics.volatile_store(spot, 0x1234)
	two, _ := rt.vmo_create(8192)
	_, st = rt.as_map(rt.self, two, 0, 8192, {.Write}, at - 4096) // free: the kernel leaves a guard page before what it places
	check(st != .Ok)
	check(intrinsics.volatile_load(spot) == 0x1234) // would fault if the failed map took the page
	_, st = rt.as_map(rt.self, two, 0, 4096, {.Write}, at - 4096)
	check(st == .Ok) // the page it did map was taken back
	rt.close_all(two, vmo, port)
}

// Review fixes (M3): port waiters. A waiter that times out does not cut off
// the waiter behind it, and a kill ends a task waiting on a port.
Port_Pair :: struct {
	port:  vx.Handle,
	stage: u32,
	got:   int, // how many packets the second waiter's port_wait returned
	st:    vx.Status,
}

second_waiter :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	pp := cast(^Port_Pair)uintptr(arg)
	for intrinsics.atomic_load(&pp.stage) != 1 {
		_ = rt.futex_wait(&pp.stage, 0, after_ms(100))
	}
	pk: [1]vx.Packet
	pp.got, pp.st = rt.port_wait(pp.port, after_ms(2000), 0, pk[:]) // queued behind the first waiter
	intrinsics.atomic_store(&pp.stage, 2)
	_, _ = rt.futex_wake(&pp.stage, 1)
	rt.thread_exit(0)
}

test_port_waiters :: proc "contextless" () {
	@(static) pp: Port_Pair
	pk: [1]vx.Packet
	pp.port, _ = rt.port_create()
	th, st := rt.thread_create(rt.self)
	check(st == .Ok)
	check(rt.thread_start(th, u64(uintptr(rawptr(second_waiter))), new_stack(), 0, u64(uintptr(&pp))) == .Ok)
	intrinsics.atomic_store(&pp.stage, 1)
	_, _ = rt.futex_wake(&pp.stage, 1)
	_, st = rt.port_wait(pp.port, after_ms(30), 0, pk[:])
	check(st == .Err_Timed_Out) // first in line, gives up
	packet := vx.Packet{key = 5}
	check(rt.port_post(pp.port, &packet) == .Ok)
	for i := 0; i < 100 && intrinsics.atomic_load(&pp.stage) != 2; i += 1 {
		_ = rt.futex_wait(&pp.stage, 1, after_ms(10))
	}
	check(pp.got == 1 && pp.st == .Ok) // woken by the post, not by its 2 s deadline
	rt.close_all(th, pp.port)

	// A port closed with fired bindings in it, many times over: the path that
	// used to leak each port (its fired binding kept it alive). A leak itself
	// does not show from here: ktest cannot see the kernel's free memory.
	counter, _ := rt.counter_create(1)
	all := true
	for i := 0; i < 2000 && all; i += 1 {
		p, pst := rt.port_create()
		all = pst == .Ok && rt.port_bind(p, counter, .Counter_Ge, 1, 0) == .Ok && rt.handle_close(p) == .Ok
	}
	check(all)
	_ = rt.handle_close(counter)

	port, _ := rt.port_create()
	// User tasks have FP/SIMD, saved at every entry (ADR-0004; upstream traps it at M3).
	child, ok := start_child(.Use_Simd)
	check(ok)
	check(wait_exit(port, child) == 7)
	_ = rt.handle_close(child)
	child, ok = start_child(.Port_Block)
	check(ok)
	check(wait_blocked(child)) // in port_wait
	check(rt.task_kill(child, -3) == .Ok)
	check(wait_exit(port, child) == -3) // the kill ends the wait
	rt.close_all(child, port)
}

// --- as_unmap ---

PAGE :: u64(4096)

// A user address as a slice the kernel copies through.
bytes_at :: proc "contextless" (at: u64, n: int) -> []u8 {
	return (cast([^]u8)uintptr(at))[:n]
}

// as_unmap: whole mappings and parts of them, the hole mapped again, and the
// pages gone for the kernel's copies too.
test_unmap :: proc "contextless" () {
	v, st := rt.vmo_create(4 * PAGE)
	at: u64
	if st == .Ok {
		at, st = rt.as_map(rt.self, v, 0, 4 * PAGE, {.Write})
	}
	check(st == .Ok)
	if st != .Ok || at == 0 {
		return
	}
	for p in u64(0) ..< 4 {
		intrinsics.volatile_store(cast(^u8)uintptr(at + p * PAGE), u8(p + 1))
	}
	check(rt.as_unmap(rt.self, at + PAGE, PAGE + 1) == .Err_Range) // pages only
	check(rt.as_unmap(rt.self, at + PAGE, 2 * PAGE) == .Ok) // the middle: two mappings now
	check(rt.vmo_read(v, 0, bytes_at(at + PAGE, 1)) == .Err_Invalid) // gone for the kernel too
	check(rt.vmo_read(v, 0, bytes_at(at + 2 * PAGE + 100, 1)) == .Err_Invalid)
	check(intrinsics.volatile_load(cast(^u8)uintptr(at)) == 1) // the ends stay
	check(intrinsics.volatile_load(cast(^u8)uintptr(at + 3 * PAGE)) == 4)
	check(rt.as_unmap(rt.self, at + PAGE, 2 * PAGE) == .Ok) // nothing there: fine
	hole, hst := rt.as_map(rt.self, v, PAGE, 2 * PAGE, {.Write}, at + PAGE)
	check(hst == .Ok && hole == at + PAGE)
	check(intrinsics.volatile_load(cast(^u8)uintptr(hole)) == 2) // the VMO kept them
	check(intrinsics.volatile_load(cast(^u8)uintptr(hole + PAGE)) == 3)
	byte: [1]u8
	check(rt.vmo_read(v, 0, byte[:]) == .Ok && byte[0] == 1)
	check(rt.as_unmap(rt.self, at, 4 * PAGE) == .Ok) // all three mappings at once
	check(rt.vmo_read(v, 0, bytes_at(at, 1)) == .Err_Invalid)
	_ = rt.handle_close(v)

	// Every CPU loses the translations: a child spinning on loads from its
	// stack page, with no system call to switch its tables, faults once the
	// page is unmapped. Without the shootdown it would read on, from a cached
	// entry; that shows under TCG (and so always on aarch64), as KVM flushes a
	// guest's TLB on its own often enough to hide it.
	port, _ := rt.port_create()
	child, ok := start_child(.Read_Loop)
	check(ok)
	_ = rt.futex_wait(&never, 0, after_ms(50)) // it is spinning, on another CPU
	check(rt.as_unmap(child, CHILD_STACK_TOP - 4096, 4096) == .Ok)
	check(wait_exit(port, child) == -1) // killed by the fault
	rt.close_all(child, port)
}

// Kernel copies that lose their page part-way fail, and the kernel goes on:
// one thread unmaps and maps a page again and again while another copies
// into it.
Copy_Race :: struct {
	stop:                bool,
	vmo:                 vx.Handle,
	page:                u64,
	ok, invalid, other: u32,
}

copy_racer :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	r := cast(^Copy_Race)uintptr(arg)
	for !intrinsics.atomic_load(&r.stop) {
		#partial switch rt.vmo_read(r.vmo, 0, bytes_at(r.page, 4096)) {
		case .Ok:
			intrinsics.atomic_add(&r.ok, 1)
		case .Err_Invalid:
			intrinsics.atomic_add(&r.invalid, 1)
		case:
			intrinsics.atomic_add(&r.other, 1)
		}
	}
	rt.thread_exit(0)
}

test_copy_race :: proc "contextless" () {
	@(static) r: Copy_Race
	target: vx.Handle
	st: vx.Status
	r.vmo, st = rt.vmo_create(4096)
	check(st == .Ok)
	target, st = rt.vmo_create(4096)
	check(st == .Ok)
	r.page, st = rt.as_map(rt.self, target, 0, 4096, {.Write})
	check(st == .Ok)
	th, tst := rt.thread_create(rt.self)
	check(tst == .Ok)
	check(rt.thread_start(th, u64(uintptr(rawptr(copy_racer))), new_stack(), 0, u64(uintptr(&r))) == .Ok)
	mapped, all := true, true
	for _ in 0 ..< 20000 {
		if mapped {
			all = all && rt.as_unmap(rt.self, r.page, 4096) == .Ok
		} else {
			at, mst := rt.as_map(rt.self, target, 0, 4096, {.Write}, r.page)
			all = all && mst == .Ok && at == r.page
		}
		mapped = !mapped
	}
	check(all)
	intrinsics.atomic_store(&r.stop, true)
	_ = rt.futex_wait(&never, 0, after_ms(20))
	check(intrinsics.atomic_load(&r.other) == 0)
	check(intrinsics.atomic_load(&r.ok) + intrinsics.atomic_load(&r.invalid) > 0)
	if !mapped {
		_, _ = rt.as_map(rt.self, target, 0, 4096, {.Write}, r.page)
	}
	rt.close_all(th, target)
}

// --- Exceptions (exception.odin) ---

// A page at a child's address, holding one word.
map_child_word :: proc "contextless" (child: vx.Handle, at, value: u64) -> bool {
	value := value
	v, st := rt.vmo_create(4096)
	defer rt.close_all(v)
	if st != .Ok || rt.vmo_write(v, 0, memory.ptr_to_bytes(&value)) != .Ok {
		return false
	}
	_, st = rt.as_map(child, v, 0, 4096, {}, at)
	return st == .Ok
}

// The packet for a child's fault, at its exception port.
child_stopped :: proc "contextless" (port: vx.Handle) -> bool {
	pk: [1]vx.Packet
	n, _ := rt.port_wait(port, after_ms(2000), 0, pk[:])
	return n == 1 && pk[0].trigger == .Exception && pk[0].key == 5 && pk[0].value == 1
}

test_exception_port :: proc "contextless" () {
	port, _ := rt.port_create()
	// A child's fault stops it at its port; the port's holder reads what
	// happened, maps the page it missed, and continues it: the load is retried.
	child, ok := start_child_bound(.Fault_Load, port, {})
	check(ok)
	check(child_stopped(port))
	e: vx.Exception
	check(rt.thread_state(child, 1, .Get_Exception, &e) == .Ok)
	check(e.kind == .Page_Fault && e.address == CHILD_DATA && e.code == 0 && e.thread == 1)
	small: u64
	check(rt.thread_state(child, 1, .Get_Exception, &small) == .Err_Too_Small)
	check(rt.thread_state(child, 2, .Get_Exception, &e) == .Err_Not_Found)
	check(map_child_word(child, CHILD_DATA, 7))
	check(rt.exception_resume(child, 1, .Continue) == .Ok)
	check(rt.exception_resume(child, 1, .Continue) != .Ok) // once
	check(wait_exit(port, child) == 7) // it exits with what it loaded
	_ = rt.handle_close(child)

	// Its registers can be changed before it continues: the load goes elsewhere.
	child, ok = start_child_bound(.Fault_Load, port, {})
	check(ok)
	check(child_stopped(port))
	regs: vx.Regs
	check(rt.thread_state(child, 1, .Get_Regs, &regs) == .Ok)
	bad := regs
	when ODIN_ARCH == .amd64 {
		check(regs.rax == CHILD_DATA)
		regs.rax = CHILD_DATA + 4096
		bad.rip = 0xffff_8000_0000_0000 // a kernel address: refused
	} else {
		check(regs.x[1] == CHILD_DATA)
		regs.x[1] = CHILD_DATA + 4096
		bad.pc = 0xffff_8000_0000_0000
	}
	check(rt.thread_state(child, 1, .Set_Regs, &bad) == .Err_Invalid)
	check(rt.thread_state(child, 1, .Set_Regs, &regs) == .Ok)
	check(map_child_word(child, CHILD_DATA + 4096, 9))
	check(rt.exception_resume(child, 1, .Continue) == .Ok)
	check(wait_exit(port, child) == 9)
	_ = rt.handle_close(child)

	// Or it can be killed. (.Step and .Pass are a debugger's, from its own port.)
	child, ok = start_child_bound(.Fault_Load, port, {})
	check(ok)
	check(child_stopped(port))
	check(rt.exception_resume(child, 1, .Step) == .Err_Bad_State)
	check(rt.exception_resume(child, 1, .Pass) == .Err_Bad_State)
	check(rt.exception_resume(child, 1, .Kill) == .Ok)
	check(wait_exit(port, child) == EXIT_FAULT) // the fault's default
	_ = rt.handle_close(child)

	// A kill reaches a thread stopped at its port.
	child, ok = start_child_bound(.Fault_Load, port, {})
	check(ok)
	check(child_stopped(port))
	check(rt.task_kill(child, 44) == .Ok)
	check(wait_exit(port, child) == 44)
	rt.close_all(child, port)
}

EXIT_FAULT :: -1 // a task killed by a fault no one handled

// What the in-task handler sees and does.
In_Task :: struct {
	missing:            vx.Handle, // what it maps where a fault was
	handled:            [vx.Exception_Kind]u32,
	interrupted_thread: u32,
	note:               [dynamic; vx.ERRMAX]u8, // the note the last interrupt carried
}

in_task: In_Task

handler :: proc "c" (e: ^vx.Exception) -> ! {
	if e.kind >= min(vx.Exception_Kind) && e.kind <= max(vx.Exception_Kind) {
		intrinsics.atomic_add(&in_task.handled[e.kind], 1)
	}
	#partial switch e.kind {
	case .Page_Fault:
		_, _ = rt.as_map(rt.self, in_task.missing, 0, 4096, {}, e.address &~ 4095) // then the load is retried
	case .Breakpoint:
		when ODIN_ARCH == .arm64 {
			e.regs.pc += 4 // brk stops at itself; int3 has already been stepped past
		}
	case .Interrupt:
		clear(&in_task.note)
		_ = append(&in_task.note, ..e.note[:min(e.code, vx.ERRMAX)])
		intrinsics.atomic_store(&in_task.interrupted_thread, e.thread)
	}
	_ = rt.exception_resume(rt.self, 0, .Continue, &e.regs)
	for {}
}

Waiter :: struct {
	word:   u32,
	result: vx.Status,
	done:   bool,
}

interrupted_waiter :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	w := cast(^Waiter)uintptr(arg)
	intrinsics.atomic_store(&w.result, rt.futex_wait(&w.word, 0, vx.INFINITE)) // no deadline: only an interrupt ends it
	intrinsics.atomic_store(&w.done, true)
	rt.thread_exit(0)
}

test_in_task :: proc "contextless" () {
	check(rt.exception_bind(rt.self, vx.HANDLE_NONE, u64(uintptr(rawptr(handler))), {.In_Task}) == .Ok)
	// A page fault, handled by mapping the page: the load is retried, and sees it.
	value := u64(0x1234_5678)
	st: vx.Status
	in_task.missing, st = rt.vmo_create(4096)
	check(st == .Ok && rt.vmo_write(in_task.missing, 0, memory.ptr_to_bytes(&value)) == .Ok)
	probe, _ := rt.vmo_create(4096)
	at, mst := rt.as_map(rt.self, probe, 0, 4096, {})
	check(mst == .Ok)
	check(rt.as_unmap(rt.self, at, 4096) == .Ok) // an address nothing maps now
	_ = rt.handle_close(probe)
	check(at != 0 && intrinsics.volatile_load(cast(^u64)uintptr(at)) == 0x1234_5678)
	check(intrinsics.atomic_load(&in_task.handled[.Page_Fault]) == 1)
	check(rt.as_unmap(rt.self, at, 4096) == .Ok)
	_ = rt.handle_close(in_task.missing)
	// A breakpoint, stepped past.
	intrinsics.debug_trap()
	check(intrinsics.atomic_load(&in_task.handled[.Breakpoint]) == 1)
	// An interrupt wakes a call that would wait for ever, and goes to the
	// handler on the way out.
	@(static) w: Waiter
	th, id, tst := rt.thread_create_id(rt.self)
	check(tst == .Ok && id > 1)
	check(rt.thread_start(th, u64(uintptr(rawptr(interrupted_waiter))), new_stack(), 0, u64(uintptr(&w))) == .Ok)
	_ = rt.futex_wait(&never, 0, after_ms(30)) // it is waiting
	check(rt.thread_interrupt(rt.self, id, "wake up") == .Ok)
	for i := 0; i < 1000 && !intrinsics.atomic_load(&w.done); i += 1 {
		_ = rt.futex_wait(&never, 0, after_ms(1))
	}
	check(intrinsics.atomic_load(&w.done) && intrinsics.atomic_load(&w.result) == .Err_Interrupted)
	check(intrinsics.atomic_load(&in_task.handled[.Interrupt]) == 1)
	check(intrinsics.atomic_load(&in_task.interrupted_thread) == id)
	check(string(in_task.note[:]) == "wake up")
	check(rt.thread_interrupt(rt.self, 999, "nobody") == .Err_Not_Found)
	_ = rt.handle_close(th)
	check(rt.exception_bind(rt.self, vx.HANDLE_NONE, 0, {.In_Task}) == .Ok) // unbound
}

test_vmo_clone :: proc "contextless" () {
	words := [2]u64{11, 22}
	got: [2]u64
	v, st := rt.vmo_create(2 * 4096)
	check(st == .Ok && rt.vmo_write(v, 4096, memory.ptr_to_bytes(&words)) == .Ok)
	c, cst := rt.vmo_clone(v, 4096, 4096) // its second page
	check(cst == .Ok)
	words[0] = 99
	check(rt.vmo_write(v, 4096, memory.ptr_to_bytes(&words)) == .Ok) // the original changes; the copy does not
	check(rt.vmo_read(c, 0, memory.ptr_to_bytes(&got)) == .Ok && got[0] == 11 && got[1] == 22)
	_, st = rt.vmo_clone(v, 4096, 2 * 4096)
	check(st == .Err_Range)
	_, st = rt.vmo_clone(v, 1, 4096)
	check(st == .Err_Range)
	rt.close_all(c, v)
}

// --- Debugging ---

test_debugger :: proc "contextless" () {
	port, _ := rt.port_create()
	e: vx.Exception
	regs: vx.Regs
	// A breakpoint goes first to a debugger's port; it steps one instruction,
	// sees what that did, and continues.
	child, ok := start_child_bound(.Break_Step, port, {.First_Chance})
	check(ok)
	check(child_stopped(port))
	check(rt.thread_state(child, 1, .Get_Exception, &e) == .Ok && e.kind == .Breakpoint)
	when ODIN_ARCH == .arm64 {
		e.regs.pc += 4 // past the brk
		check(rt.thread_state(child, 1, .Set_Regs, &e.regs) == .Ok)
	}
	check(rt.exception_resume(child, 1, .Step) == .Ok)
	check(child_stopped(port))
	check(rt.thread_state(child, 1, .Get_Exception, &e) == .Ok && e.kind == .Step)
	when ODIN_ARCH == .amd64 {
		check(e.regs.rdi == 7 && e.regs.rip == CHILD_CODE + 1 + 5) // int3, then mov $7, %edi
	} else {
		check(e.regs.x[0] == 7 && e.regs.pc == CHILD_CODE + 8) // brk, then movz x0, #7
	}
	check(rt.exception_resume(child, 1, .Continue) == .Ok)
	check(wait_exit(port, child) == 7)
	_ = rt.handle_close(child)

	// Passed on, the breakpoint reaches nobody else: the default kills it.
	child, ok = start_child_bound(.Break_Step, port, {.First_Chance})
	check(ok)
	check(child_stopped(port))
	check(rt.exception_resume(child, 1, .Pass) == .Ok)
	check(wait_exit(port, child) == EXIT_FAULT)
	_ = rt.handle_close(child)

	// Suspended, a spinning child holds still: its code is patched (a private
	// copy, as its mapping is not writable), its pc moved there, and it exits.
	child, ok = start_child(.Spin)
	check(ok)
	weak, wst := rt.handle_dup(child, vx.ALL_RIGHTS - {.Debug})
	check(wst == .Ok)
	check(rt.thread_suspend(weak, 1) == .Err_Access)
	check(rt.exception_bind(weak, port, 1, {.First_Chance}) == .Err_Access)
	check(rt.thread_state(child, 1, .Get_Regs, &regs) == .Err_Bad_State) // running
	check(rt.thread_suspend(child, 1) == .Ok)
	check(rt.thread_state(child, 1, .Get_Regs, &regs) == .Ok)
	check(rt.thread_state(weak, 1, .Get_Regs, &regs) == .Err_Bad_State) // DEBUG needed
	// Its threads, listed; its mappings, from the code page on.
	ti: vx.Thread_Info
	check(rt.thread_state(child, 0, .Next_Thread, &ti) == .Ok && ti.id == 1 && ti.state == .Suspended && ti.suspend_count == 1)
	check(rt.thread_state(child, 1, .Next_Thread, &ti) == .Err_Not_Found)
	// Its FP registers, read and written back (a bad MXCSR made safe).
	fp: vx.Fpregs
	check(rt.thread_state(child, 1, .Get_Fpregs, &fp) == .Ok)
	when ODIN_ARCH == .amd64 {
		mxcsr := intrinsics.unaligned_load((^u32)(&fp.fxsave[24]))
		check(mxcsr == 0x1f80) // the reset value: every exception masked
		intrinsics.unaligned_store((^u32)(&fp.fxsave[24]), 0xffff_1f80) // reserved bits: XRSTOR would fault on them
		fp.fxsave[160] = 0x5a // XMM0's first byte
		check(rt.thread_state(child, 1, .Set_Fpregs, &fp) == .Ok)
		check(rt.thread_state(child, 1, .Get_Fpregs, &fp) == .Ok)
		check(intrinsics.unaligned_load((^u32)(&fp.fxsave[24])) == 0x1f80 && fp.fxsave[160] == 0x5a)
	} else {
		fp.v[0][0] = 0x5a
		fp.fpcr = ~u64(0)
		check(rt.thread_state(child, 1, .Set_Fpregs, &fp) == .Ok)
		check(rt.thread_state(child, 1, .Get_Fpregs, &fp) == .Ok)
		check(fp.v[0][0] == 0x5a && fp.fpcr == 0x07ff9f00)
	}
	check(rt.thread_state(weak, 1, .Get_Fpregs, &fp) == .Err_Bad_State) // DEBUG needed
	mi, qst := rt.as_query(child, 0)
	check(qst == .Ok && mi.base <= CHILD_CODE && mi.base + mi.size > CHILD_CODE && mi.flags == {.Exec})
	_, qst = rt.as_query(child, ~u64(0) - 4096)
	check(qst == .Err_Not_Found)
	when ODIN_ARCH == .amd64 {
		check(regs.rip == CHILD_CODE)
		regs.rip = CHILD_CODE + 64
	} else {
		check(regs.pc == CHILD_CODE)
		regs.pc = CHILD_CODE + 64
	}
	code := write_child(.Exit_7)
	back: [64]u8
	word: u64
	ops := [3]vx.Mem_Op {
		{address = CHILD_CODE + 64, buffer = u64(uintptr(&code[0])), size = u64(len(code)), write = true},
		{address = CHILD_CODE + 64, buffer = u64(uintptr(&back)), size = u64(len(code))},
		{address = CHILD_DATA, buffer = u64(uintptr(&word)), size = 8}, // nothing mapped there
	}
	check(rt.task_mem_rw(child, ops[:]) == .Ok)
	check(ops[0].status == .Ok && ops[1].status == .Ok && string(code[:]) == string(back[:len(code)]))
	check(ops[2].status == .Err_Invalid)
	check(rt.task_mem_rw(weak, ops[:1]) == .Err_Access)
	check(rt.thread_state(child, 1, .Set_Regs, &regs) == .Ok)
	check(rt.thread_resume(child, 1) == .Ok)
	again := rt.thread_resume(child, 1) // counted: not suspended any more, or
	check(again == .Err_Bad_State || again == .Err_Not_Found) // already run on to its end
	check(wait_exit(port, child) == 7)
	rt.close_all(weak, child)

	// A thread blocked in a call holds still too, and goes on waiting once resumed.
	child, ok = start_child(.Block)
	check(ok)
	check(wait_blocked(child))
	check(rt.thread_suspend(child, 1) == .Ok && rt.thread_suspend(child, 1) == .Ok) // counted
	check(rt.thread_state(child, 1, .Get_Regs, &regs) == .Ok)
	check(rt.thread_resume(child, 1) == .Ok && rt.thread_resume(child, 1) == .Ok)
	check(wait_blocked(child))
	// Thread 0: every thread of the task, as a process stops as a whole.
	check(rt.thread_suspend(child, 0) == .Ok && rt.thread_resume(child, 0) == .Ok)
	check(rt.thread_resume(child, 0) == .Err_Bad_State) // counted: not suspended any more
	check(wait_blocked(child))
	check(rt.task_kill(child, 45) == .Ok && wait_exit(port, child) == 45)
	rt.close_all(child, port)
}

// --- fork ---

fork_page: [512]u64
fork_ring: u64 // where a ring's memory is mapped, in the parent

FORK_OK :: 100 // fork_child's exit status when all is well; more says what was not

// The forked child's first thread. Its exit status says what it found:
// FORK_OK if all is well, more by the bits of what was not.
fork_child :: proc "c" (unused: vx.Handle, my_id: u64) -> ! {
	wrong: i64
	if intrinsics.volatile_load(&fork_page[7]) != 0x1234 {
		wrong |= 1 // memory as it was at the fork
	}
	intrinsics.volatile_store(&fork_page[7], 0x9999) // and its own: the parent never sees this
	me, st := rt.task_info(rt.self)
	if st != .Ok || me.id != my_id {
		wrong |= 2 // "self" is itself
	}
	if fork_ring != 0 {
		_ = intrinsics.volatile_load(cast(^u64)uintptr(fork_ring)) // not there: a fault ends it
	}
	_ = rt.task_kill(rt.self, FORK_OK + wrong)
	rt.thread_exit(0)
}

run_fork :: proc "contextless" (sp: u64, port: vx.Handle) -> i64 {
	child, st := rt.task_fork("forked")
	if st != .Ok {
		return min(i64)
	}
	defer rt.close_all(child)
	intrinsics.volatile_store(&fork_page[7], 0x5555) // after the fork: not the child's
	info, ist := rt.task_info(child)
	th, tst := rt.thread_create(child)
	if ist != .Ok || tst != .Ok {
		return min(i64)
	}
	defer rt.close_all(th)
	if rt.thread_start(th, u64(uintptr(rawptr(fork_child))), sp, 0, info.id) != .Ok {
		return min(i64)
	}
	return wait_exit(port, child)
}

test_fork :: proc "contextless" () {
	port, _ := rt.port_create()
	sp := new_stack() // mapped before the fork, so the child has it too
	check(sp != 0)
	intrinsics.volatile_store(&fork_page[7], 0x1234)
	check(run_fork(sp, port) == FORK_OK)
	check(intrinsics.volatile_load(&fork_page[7]) == 0x5555) // the child's write stayed in the child

	// A ring's memory is not copied: the child faults where the parent has it.
	params := vx.Ring_Params {
		sq_entries   = 16,
		cq_entries   = 16,
		sqe_size     = 64,
		cqe_size     = 32,
		client_arena = 4096,
		server_arena = 4096,
	}
	layout, _ := ring.layout(params)
	h, st := rt.ring_create(&params)
	check(st == .Ok)
	fork_ring, st = rt.as_map(rt.self, h.memory, 0, layout.size, {.Write})
	check(st == .Ok)
	intrinsics.volatile_store(&fork_page[7], 0x1234)
	check(intrinsics.volatile_load(cast(^u64)uintptr(fork_ring)) != 0x5a5a) // the parent reads it
	check(run_fork(sp, port) == EXIT_FAULT) // the child is killed by the fault
	check(rt.as_unmap(rt.self, fork_ring, layout.size) == .Ok)
	fork_ring = 0
	rt.close_all(h.memory, h.client, h.server)
	none := vx.HANDLE_NONE
	check(rt.vx_syscall(.Task_Create, u64(uintptr(raw_data(string("x")))), 1, u64(uintptr(&none)), 2) == i64(vx.Status.Err_Invalid))
	_ = rt.handle_close(port)
}

// --- The thread pointer (a C library's TLS) ---

tls_shared: Shared
tls_worker_bad: u32

// Its own thread pointer, kept across the switches its sleeps cause.
tls_worker :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	@(static) mine: u64 = 0xb0b0_b0b0
	if rt.tls_set(u64(uintptr(&mine))) != .Ok {
		intrinsics.atomic_add(&tls_worker_bad, 1)
	}
	set_stage(&tls_shared, 1)
	for _ in 0 ..< 20 {
		got, st := rt.tls_get()
		if rt.thread_word() != mine || st != .Ok || got != u64(uintptr(&mine)) {
			intrinsics.atomic_add(&tls_worker_bad, 1)
		}
		_ = rt.futex_wait(&never, 0, after_ms(1))
	}
	set_stage(&tls_shared, 2)
	rt.thread_exit(0)
}

test_tls :: proc "contextless" () {
	@(static) main_word: u64 = 0xa1a1_a1a1
	main_at := u64(uintptr(&main_word))
	check(rt.tls_set(main_at) == .Ok)
	got, gst := rt.tls_get()
	check(gst == .Ok && got == main_at && rt.thread_word() == main_word)
	// Each thread keeps its own, though both sleep and run on whichever CPU.
	sp := new_stack()
	check(sp != 0)
	th, st := rt.thread_create(rt.self)
	check(st == .Ok)
	check(rt.thread_start(th, u64(uintptr(rawptr(tls_worker))), sp, 0, 0) == .Ok)
	wait_for_stage(&tls_shared, 1)
	kept := true
	for _ in 0 ..< 20 {
		kept = kept && rt.thread_word() == main_word
		_ = rt.futex_wait(&never, 0, after_ms(1))
	}
	check(kept)
	wait_for_stage(&tls_shared, 2)
	check(intrinsics.atomic_load(&tls_worker_bad) == 0)
	got, gst = rt.tls_get()
	check(rt.thread_word() == main_word && gst == .Ok && got == main_at)
	_ = rt.handle_close(th)

	// Only a user address, and thread 0 only of the caller's own task.
	bad := u64(0xffff_8000_0000_0000) // the kernel half
	check(rt.thread_state(rt.self, 0, .Set_Tls, &bad) == .Err_Range)
	small: u32
	check(rt.thread_state(rt.self, 0, .Set_Tls, &small) == .Err_Too_Small)
	child, ok := start_child(.Spin)
	check(ok)
	check(rt.thread_state(child, 0, .Get_Tls, &bad) == .Err_Invalid)
	// Another thread's, while it is suspended: read, set, read back.
	v := u64(1)
	check(rt.thread_state(child, 1, .Get_Tls, &v) == .Err_Bad_State) // running
	check(rt.thread_suspend(child, 1) == .Ok)
	check(rt.thread_state(child, 1, .Get_Tls, &v) == .Ok && v == 0) // never set
	v = 0x1000
	check(rt.thread_state(child, 1, .Set_Tls, &v) == .Ok)
	v = 0
	check(rt.thread_state(child, 1, .Get_Tls, &v) == .Ok && v == 0x1000)
	other, ost := rt.handle_dup(child, vx.ALL_RIGHTS - {.Debug})
	check(ost == .Ok)
	check(rt.thread_state(other, 1, .Get_Tls, &v) == .Err_Bad_State) // DEBUG needed
	_ = rt.handle_close(other)
	check(rt.thread_resume(child, 1) == .Ok)
	check(rt.task_kill(child, 46) == .Ok)
	_ = rt.handle_close(child)
	check(rt.tls_set(0) == .Ok)
}

// --- FP/SIMD state, kept per thread (ADR-0004) ---

when ODIN_ARCH == .amd64 {
	FP_CTL_DEFAULT :: u32(0x1f80)
	FP_CTL_ZERO :: u32(0x7f80) // round toward zero
} else {
	FP_CTL_DEFAULT :: u32(0)
	FP_CTL_ZERO :: u32(3) << 22 // FPCR.RMode: toward zero
}

fp_shared: Shared
fp_worker_bad: u32

// A new thread's registers are clean; then its own survive its sleeps.
fp_worker :: proc "c" (unused: vx.Handle, arg: u64) -> ! {
	v, ctl := rt.fp_probe_get()
	if v != 0 || ctl != FP_CTL_DEFAULT {
		intrinsics.atomic_add(&fp_worker_bad, 1)
	}
	rt.fp_probe_put(0xb0b0_b0b0_b0b0_b0b0, FP_CTL_ZERO)
	set_stage(&fp_shared, 1)
	for _ in 0 ..< 20 {
		_ = rt.futex_wait(&never, 0, after_ms(1))
		v, ctl = rt.fp_probe_get()
		if v != 0xb0b0_b0b0_b0b0_b0b0 || ctl != FP_CTL_ZERO {
			intrinsics.atomic_add(&fp_worker_bad, 1)
		}
	}
	set_stage(&fp_shared, 2)
	rt.thread_exit(0)
}

test_fp :: proc "contextless" () {
	rt.fp_probe_put(0xa1a1_a1a1_a1a1_a1a1, FP_CTL_DEFAULT)
	sp := new_stack()
	check(sp != 0)
	th, st := rt.thread_create(rt.self)
	check(st == .Ok)
	check(rt.thread_start(th, u64(uintptr(rawptr(fp_worker))), sp, 0, 0) == .Ok)
	wait_for_stage(&fp_shared, 1)
	kept := true
	for _ in 0 ..< 20 {
		_ = rt.futex_wait(&never, 0, after_ms(1))
		v, ctl := rt.fp_probe_get()
		kept = kept && v == 0xa1a1_a1a1_a1a1_a1a1 && ctl == FP_CTL_DEFAULT
	}
	check(kept)
	wait_for_stage(&fp_shared, 2)
	check(intrinsics.atomic_load(&fp_worker_bad) == 0)
	_ = rt.handle_close(th)
	// And floating point itself, compiled: 1/3 rounds differently by mode.
	third, three := 1.0, 3.0
	q := intrinsics.volatile_load(&third) / intrinsics.volatile_load(&three)
	check(q > 0.333 && q < 0.334)
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	test_spawn_message()
	test_m1_basics()
	test_channel_basics()
	test_handle_transfer()
	test_bindings()
	test_threads_and_calls()
	test_tasks()
	test_torn_down()
	test_port_waiters()
	test_unmap()
	test_copy_race()
	test_exception_port()
	test_in_task()
	test_vmo_clone()
	test_debugger()
	test_tls()
	test_fork()
	test_fp()
	test_nested_channels()
	test_rings()
	test_vmo_rw()
	test_devices()
	rt.print("ktest: ", u64(checks), " checks, ", u64(failures), failures != 0 ? " FAILED\n" : " failed\n")
	port, _ := rt.port_create()
	for {
		pk: [1]vx.Packet
		_, _ = rt.port_wait(port, vx.INFINITE, 0, pk[:])
	}
}
