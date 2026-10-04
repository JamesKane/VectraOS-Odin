// abi:vx: the types the kernel and user space share. Every list expands from
// a .def table (abi_gen.odin, which ./build generates), so nothing is kept in
// sync by hand. Imports nothing beyond the language.
package vx

Handle :: distinct u32 // table index plus a generation count
Duration :: i64 // nanoseconds
Instant :: i64 // the one monotonic clock, in nanoseconds

HANDLE_NONE :: Handle(0)
INFINITE :: Instant(max(i64)) // a deadline that never comes

// Every right, and handle_dup's "the rights the handle has": bit 31, which
// no right may use. On the wire a Rights is the u32 whose bit i is Right(i).
ALL_RIGHTS :: ~Rights{}
RIGHTS_SAME :: transmute(Rights)(u32(1) << 31)

#assert(len(Right) <= 31)
#assert(Status.Ok == Status(0))

// A port packet: 32 bytes.
Packet :: struct {
	key:       u64, // chosen by whoever bound or posted it
	value:     u64, // counter value, IRQ count, exit string's length; free for user posts
	timestamp: Instant,
	source:    u32, // the handle it came from, or 0 for port_post
	trigger:   Trigger,
}

#assert(size_of(Packet) == 32)

// What a port binding waits for (port_bind). A binding is one-shot: it fires
// once, at once if its condition already holds, and is gone.
Trigger :: enum u32 {
	User = 1, // port_post
	Readable, // a channel end has a message to read
	Peer_Closed, // a channel end's peer is gone
	Counter_Ge, // a counter has reached the binding's threshold; value: the counter
	Exit, // a task has ended; value: its exit string's length (0: success)
	Irq, // an Irq has fired since it was last bound; value: how many times in all
	Exception, // a thread stopped at an exception (exception_bind); value: its thread id
}

// The intents a thread declares. Until scheduling contexts land, every thread
// is .Interactive.
Intent :: enum u32 {
	Realtime = 1,
	Interactive_Frame,
	Interactive,
	Throughput,
	Background,
}

// Every channel message starts with this header. The kernel writes
// sender_intent; the rest is the protocol's.
Msg_Header :: struct {
	txid:          u32, // matches a reply to its call; 0 for a message that wants none
	ordinal:       u32, // the protocol's operation
	flags:         u32,
	sender_intent: Intent, // of the sending thread
}

#assert(size_of(Msg_Header) == 16)

CHANNEL_MAX_BYTES :: 64 * 1024
CHANNEL_MAX_HANDLES :: 64

Msg_Size :: struct { // what channel_read and channel_call report
	bytes:   u32,
	handles: u32,
}

// The spawn message. A new task's first thread starts with one handle, its
// bootstrap channel, and the first message there comes from its parent (for
// the root task, from the kernel): this header with ordinal SPAWN, then ndb
// records saying what the message's handles are and what the program is given:
//
//   spawn=NAME                       the program
//   handle=NAME index=N              the message's handle N; "self" is the task
//   arg=VALUE                        an argument; repeated, in order
//   cmdline=VALUE                    the kernel command line (the root task's)
//   bootimage size=N                 the boot image's length (the bootimage handle)
//   mount=OLD handle=NAME [aname=A] [flags=F] [src=S]    the namespace, as
//   bind=OLD new=NEW [flags=F]                           vx-ns replays it
SPAWN :: u32(0x6e77_7073) // "spwn"

// channel_call's buffers: what to send, and where the reply goes. A call
// that ends without its reply (interrupted, or past its deadline) takes back
// its request if the server has not read it yet: it is never answered, and
// its handles are closed. An interrupted call whose request the server has
// read waits on for the reply, so no answer is lost; the interrupt comes when
// the call returns. A server that holds calls answers one before
// interrupting its caller.
Call :: struct {
	wr_bytes:     rawptr,
	wr_handles:   [^]Handle,
	rd_bytes:     rawptr,
	rd_handles:   [^]Handle,
	wr_len:       u32,
	wr_count:     u32,
	rd_cap:       u32,
	rd_count_cap: u32,
	actual:       Msg_Size,
}

// --- Rings ---
//
// A ring is one VMO both sides map: this header, four index lines, the
// submission and completion queues, and an arena for each side. The kernel
// writes the header when it creates the ring and never reads the ring again;
// lib/ring is the protocol. Every offset is from the start of the VMO.

RING_MAGIC :: u32(0x4252_5856) // "VXRB", little-endian
RING_VERSION :: u32(1)
RING_NEED_WAKEUP :: u32(1) // in a consumer line's flags: it sleeps, ring the doorbell

Ring_Header :: struct {
	magic, version:         u32,
	sq_entries, cq_entries: u32, // powers of two
	sqe_size, cqe_size:     u32, // bytes per entry
	features:               u32,
	reserved:               u32,
	sq_offset, cq_offset:   u64, // the entries
	client_arena_offset:    u64,
	client_arena_size:      u64,
	server_arena_offset:    u64,
	server_arena_size:      u64,
	size:                   u64, // of the whole VMO
}

#assert(size_of(Ring_Header) == 88)

// The four index lines start at 4096, 64 bytes apart, so no two sides write
// one cache line: SQ tail (client), SQ head and flags (server), CQ tail
// (server), CQ head and flags (client). Indices run free and wrap at 2^32.
Ring_Index :: struct {
	index: u32,
	flags: u32, // the consumer lines only: RING_NEED_WAKEUP
	pad:   [56]u8,
}

#assert(size_of(Ring_Index) == 64)

RING_INDEX_OFFSET :: u64(4096)

Ring_Line :: enum u32 {
	Sq_Tail,
	Sq_Head,
	Cq_Tail,
	Cq_Head,
}

Ring_Params :: struct { // ring_create's request
	sq_entries, cq_entries: u32,
	sqe_size, cqe_size:     u32, // multiples of 16, at most 256
	client_arena:           u64, // bytes, rounded up to pages
	server_arena:           u64,
}

Ring_Handles :: struct { // ring_create's answer
	client, server: Handle, // the two ends
	memory:         Handle, // the VMO; each side maps it
}

Ring_Xfer :: enum u32 { // ring_xfer_handles
	Put  = 0, // handles -> a slot for the peer; returns the slot
	Take = 1, // a slot from the peer -> handles; returns their count
}

RING_SLOTS :: 16 // per direction
RING_SLOT_HANDLES :: 4 // per slot

Sqe_Flag :: enum u16 {
	Link,
	Dref,
	Handles,
	Fence,
}

Sqe_Flags :: bit_set[Sqe_Flag; u16]

Sqe :: struct #align (64) { // the generic submission entry, 64 bytes
	opcode:      u16,
	flags:       Sqe_Flags,
	reserved:    [4]u8, // no per-entry priority: the service class belongs to the ring
	user_data:   u64, // echoed in the Cqe
	target:      u64, // fid, block, socket, surface: the protocol's
	offset:      u64,
	arena_off:   u32, // valid with .Dref
	len:         u32,
	handle_slot: u32, // valid with .Handles
	pad:         u32,
	inline_data: [16]u8,
}

#assert(size_of(Sqe) == 64)

Cqe :: struct #align (32) { // the generic completion entry, 32 bytes
	user_data: u64,
	result:    i64,
	flags:     u32,
	aux:       u32,
	aux2:      u64,
}

#assert(size_of(Cqe) == 32)

// --- Devices ---
//
// A Resource is root authority over physical memory that is not RAM,
// interrupt lines and I/O ports; svcd gets it, and makes narrower objects
// from it for each driver:
//
//   vmo_create(size, {.Physical}, &out, resource, physical_address)
//       MMIO: uncached device memory, never RAM; mapped like any VMO
//   irq_create(resource, line, 0, &out)
//       x86_64: an ISA IRQ below 16 (through the firmware's overrides), or a
//       GSI; aarch64: a GIC SPI's INTID. Bound to a port with .Irq. A
//       level-triggered line is masked when it fires until irq_ack; an
//       edge-triggered one is never masked, and a binding made after it
//       fired fires at once.
//   irq_create(resource, source, {.Msi}, &out, &msi)
//       an MSI or MSI-X interrupt for the PCI function whose requester ID
//       (bus << 8 | device << 3 | function) is `source`: the kernel picks
//       it, and Msi says what the device must write, and where. Always
//       edge-triggered. (x86_64: an APIC vector; aarch64: an LPI, through the
//       GIC's ITS, which knows the device by its requester ID.)
//   dma_domain_create(resource, 0, &out)
//       a DmaDomain: what a device may reach by DMA. In pass-through mode,
//       the only one so far (QEMU; the IOMMU comes with M5), a device
//       address is the physical address.
//   dma_map(domain, vmo, offset, size, addresses)
//       the device address of each page of [offset, offset + size), into
//       addresses[size / 4096]; the domain holds the VMO until dma_unmap
//   dma_unmap(domain, vmo)
//   iorange_create(resource, base, count, &out)
//       x86_64 only: I/O ports, which a task may use once as_map has been
//       called with the IoRange in place of a VMO (offset, size and flags 0)
Vmo_Option :: enum u32 { // vmo_create
	Physical,
}
Vmo_Options :: bit_set[Vmo_Option; u32]

Irq_Option :: enum u32 { // irq_create
	Msi,
}
Irq_Options :: bit_set[Irq_Option; u32]

Msi :: struct { // what a device writes to raise an MSI
	address:  u64,
	data:     u32,
	reserved: u32,
}

#assert(size_of(Msi) == 16)

Vmo_Op :: enum u32 { // vmo_rw
	Read  = 0,
	Write = 1,
}

Task_State :: enum u32 {
	New = 0, // no thread has started
	Running,
	Exited, // every thread has exited, or it was killed
}

Task_Summary :: struct { // what task_info returns
	id:       u64,
	name:     [24]u8, // NUL-padded
	state:    Task_State,
	threads:  u32, // live threads
	mapped:   u64, // bytes mapped into its address space
	blocked:  u32, // live threads that are waiting
	exit_len: u32,
	exit:     [ERRMAX]u8, // once .Exited, its exit string: exit_len bytes, empty for success
}

#assert(size_of(Task_Summary) == 56 + ERRMAX)

// The task's exit string, from its summary.
exit_string :: proc "contextless" (s: ^Task_Summary) -> string {
	return string(s.exit[:min(s.exit_len, ERRMAX)])
}

// A task ends with an exit string (ADR-0010): empty for success, else why,
// in at most ERRMAX bytes of UTF-8. task_kill(task, msg, len, id) ends it
// with msg; a task whose last thread exits (thread_exit) ends with the empty
// string; a fault no one handles ends it with Plan 9's words for the trap
// ("sys: trap: fault read addr=0x0 pc=0x401000", trap_note).
//
// task_info(task, &summary, id, flags) and task_kill(task, msg, len, id) act on
// the task itself, or with an id, on that task if it is the task or one of
// its descendants. With .Next, task_info finds the one with the next id
// after `id` instead, so a holder of a task handle can list its tree
// (procfs). There is no other way to reach a task: no global lookup.
// task_create(name, len, &task, options): a new task, with nothing in it.
// With .Fork, it has a copy of the caller's memory, made now, and of its
// handle table: the same values and rights, a handle to the caller becoming
// one to the new task. Rings' memory and device memory are not copied, and
// the copy has no threads: the caller starts one.
Task_Option :: enum u32 {
	Fork,
}
Task_Options :: bit_set[Task_Option; u32]

Task_Info_Option :: enum u32 {
	Next,
}
Task_Info_Options :: bit_set[Task_Info_Option; u32]

Map_Option :: enum u32 { // as_map; a mapping is always readable
	Write,
	Exec,
}
Map_Options :: bit_set[Map_Option; u32]

// On the wire, an option set is the u32 whose bit i is the option with value i.
#assert(u32(Map_Option.Write) == 0 && u32(Map_Option.Exec) == 1)

// as_map(task, vmo, offset, size, flags, &address): maps part of a VMO, at
// address, or where the kernel picks with address 0.
// as_unmap(task, address, size): unmaps the pages of [address, address +
// size), whole mappings or parts of them; a mapping cut in the middle becomes
// two. Pages nothing maps there are left alone. Once it returns, no CPU can
// reach the pages through those addresses any more.

// The longest exit string or note, in bytes: Plan 9's ERRMAX (ADR-0010).
ERRMAX :: 128

// --- Exceptions and interrupts ---
//
// A fault in user mode goes first to a debugger's port, if one is bound with
// .First_Chance, then to the task's in-task handler, if it has one, then to
// its exception port, then to the default: the task is killed.
//
// thread_create(task, &out, &id): a thread, and (unless id is null) its id
//     in the task, from 1 in creation order, which exceptions and
//     thread_interrupt name it by.
// thread_start(thread, entry, sp, handle, arg2): runs entry(handle, arg2) as
//     if called, sp being a 16-aligned stack top: on x86_64 with a zero
//     return address just below it, so any C function can be the entry.
// exception_bind(task, port, key, options): with no options, faults stop the
//     thread and post a packet to port: trigger .Exception, the binding's
//     key, and value the thread's id. A port of HANDLE_NONE unbinds. With
//     .In_Task, key is a handler in the task (port ignored, 0 unbinds): the
//     kernel puts an Exception on the faulting thread's own stack, below the
//     128 bytes under its stack pointer, and starts the thread at
//     handler(exception). A handler never returns: it resumes with
//     exception_resume. With .First_Chance (and the DEBUG right), a
//     debugger's port, as with no options but before the rest; it also gets
//     .Step exceptions.
// exception_resume(task, thread, action, regs): resumes a thread stopped at
//     its port: .Continue (with the registers at regs, if not null; else as
//     it stopped, retrying the instruction), .Kill, or, from a debugger's
//     port, .Pass (to whoever is next in line) or .Step (.Continue for one
//     instruction, then a .Step exception to the debugger). With thread 0,
//     the caller resumes itself from its handler: .Continue with the
//     registers its Exception holds, perhaps changed.
// thread_state(task, thread, op, buffer, size): for a thread stopped at a
//     port, .Get_Exception reads its Exception; for one stopped or suspended,
//     .Get_Regs and .Set_Regs its registers (DEBUG for a suspended one).
//     .Get_Tls and .Set_Tls its thread pointer (x86_64's FS base, aarch64's
//     TPIDR_EL0), a u64, on the same terms; with thread 0, the caller's own,
//     at any time. .Get_Fpregs and .Set_Fpregs its FP/SIMD registers, an
//     Fpregs, on the same terms. .Get_Watch and .Set_Watch (DEBUG), with
//     thread 0, the task's watchpoints, a Watches, which every thread of it
//     has, from when each next runs; .Get_Watch says how many the hardware
//     has in count. .Next_Thread, at any time, describes the live thread with
//     the next id after `thread` (0: the first) in a Thread_Info;
//     .Err_Not_Found after the last.
// thread_suspend(task, thread), thread_resume(task, thread): counted, with
//     the DEBUG right; with thread 0, every thread of the task. A suspended
//     thread stops before it next returns to user mode; thread_suspend
//     returns once it has (stopped there, or blocked in a call), or
//     .Err_Timed_Out after a second.
// task_mem_rw(task, ops, count): with the DEBUG right, copies between
//     another task's memory and the caller's, a Mem_Op each; each op gets its
//     own status. A write to a mapping that is not writable (code, for a
//     breakpoint) first gives the task a private copy of that mapping, as
//     ptrace does: never a writable mapping of it.
// thread_interrupt(task, thread, note, len): posts a note (ADR-0010), a
//     string of 1 to ERRMAX bytes, to the thread (any thread of the task,
//     with thread 0): a call it is blocked in returns .Err_Interrupted, and
//     on its way back to user mode it is diverted to the in-task handler with
//     an exception of kind .Interrupt carrying the note. A task with no
//     in-task handler ends instead, with the note as its exit string, as in
//     Plan 9. Up to eight notes wait for delivery, each its own exception;
//     more is .Err_Should_Wait.
// vmo_clone(vmo, offset, size, options, &out): a new VMO holding a copy of
//     the range, charged in full (commit, not overcommit).
// as_query(task, address, &info): with INSPECT on the task, the first of its
//     mappings that ends after address, in a Map_Info; .Err_Not_Found if
//     none. A caller lists an address space by asking again from each one's
//     end.
//
// Registers a handler or a debugger may change are checked: a thread can be
// given any user-mode state, and never a privileged one.

when ODIN_ARCH == .amd64 {
	Regs :: struct {
		rax, rbx, rcx, rdx, rsi, rdi, rbp, rsp: u64,
		r8, r9, r10, r11, r12, r13, r14, r15:   u64,
		rip, rflags:                            u64,
	}

	Fpregs :: struct { // FXSAVE's 512-byte image: x87, MXCSR, XMM0-15
		fxsave: [512]u8,
	}
} else {
	Regs :: struct {
		x:              [31]u64, // x30 is the link register
		sp, pc, pstate: u64,
	}

	Fpregs :: struct {
		v:          [32][16]u8, // V0-V31
		fpcr, fpsr: u64,
	}
}

Exception_Kind :: enum u32 {
	Page_Fault = 1, // address: what was touched; code: read 0, write 1, execute 2
	Illegal, // an undefined or privileged instruction
	Breakpoint, // int3, brk
	Arithmetic, // division by zero, an FP exception
	Alignment,
	Fp_Disabled, // FP/SIMD while the kernel does not save it
	General, // any other fault (x86 #GP, say); code: the architecture's
	Interrupt, // thread_interrupt; code: the note's length, note: its text
	Step, // one instruction done, after exception_resume(.Step)
	// A watched address touched; code: the watchpoint's slot, address: what
	// it watches. x86_64 stops after the access, aarch64 before it (resuming
	// touches it again: step it with the watchpoint off).
	Watchpoint,
}

Exception :: struct {
	kind:     Exception_Kind,
	code:     u32,
	address:  u64,
	thread:   u32, // the id of the thread it happened to
	reserved: u32,
	regs:     Regs,
	note:     [ERRMAX]u8, // .Interrupt: the note, `code` bytes of it
}

Exception_Option :: enum u32 {
	In_Task,
	First_Chance,
}
Exception_Options :: bit_set[Exception_Option; u32]

Resume_Action :: enum u32 {
	Continue = 1,
	Kill,
	Pass,
	Step,
}

Thread_State_Op :: enum u32 {
	Get_Exception = 1,
	Get_Regs,
	Set_Regs,
	Get_Tls,
	Set_Tls,
	Get_Fpregs,
	Set_Fpregs,
	Next_Thread,
	Get_Watch,
	Set_Watch,
}

// Watchpoints: the debug registers, x86_64's four, aarch64's two to sixteen.
// An address aligned to its length (1, 2, 4 or 8 bytes), in user space.
WATCH_MAX :: 16

Watch_Kind :: enum u32 {
	Off,
	Write,
	Rw,
}

Watch :: struct {
	address: u64,
	len:     u32,
	kind:    Watch_Kind,
}

Watches :: struct {
	count:    u32, // .Get_Watch: how many the hardware has; slots from there on are .Off
	reserved: u32,
	slot:     [WATCH_MAX]Watch,
}

Thread_Run_State :: enum u32 {
	Running = 1, // running or ready
	Blocked, // waiting in a call
	Stopped, // at an exception port, until exception_resume
	Suspended, // parked by thread_suspend
}

Thread_Info :: struct { // thread_state(.Next_Thread)
	id:            u32,
	state:         Thread_Run_State,
	suspend_count: u32, // thread_suspend's, less thread_resume's
	first_chance:  b32, // stopped at a debugger's port (exception_bind .First_Chance)
}

Map_Info :: struct { // as_query
	base, size: u64,
	offset:     u64, // into the VMO mapped
	flags:      Map_Options, // always readable
	reserved:   u32,
}

Mem_Op :: struct { // task_mem_rw
	address: u64, // in the task
	buffer:  u64, // in the caller
	size:    u64,
	write:   b32, // buffer to address; else address to buffer
	status:  Status, // set by the kernel
}

#assert(size_of(Exception) == 24 + size_of(Regs) + ERRMAX)
#assert(size_of(Thread_Info) == 16 && size_of(Map_Info) == 32 && size_of(Mem_Op) == 32)
#assert(size_of(Watches) == 8 + WATCH_MAX * 16)
#assert(u32(Exception_Option.In_Task) == 0 && u32(Exception_Option.First_Chance) == 1)
