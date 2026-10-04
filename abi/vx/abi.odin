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
	value:     u64, // counter value, IRQ count, exit status; free for user posts
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
	Exit, // a task has ended; value: its exit status
	Irq, // an Irq has fired since it was last bound; value: how many times in all
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

// channel_call's buffers: what to send, and where the reply goes.
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
	id:          u64,
	name:        [24]u8, // NUL-padded
	state:       Task_State,
	threads:     u32, // live threads
	exit_status: i64, // once .Exited
	mapped:      u64, // bytes mapped into its address space
	blocked:     u32, // live threads that are waiting
	reserved:    u32,
}

#assert(size_of(Task_Summary) == 64)

// task_info(task, &summary, id, flags) and task_kill(task, status, id) act on
// the task itself, or with an id, on that task if it is the task or one of
// its descendants. With .Next, task_info finds the one with the next id
// after `id` instead, so a holder of a task handle can list its tree
// (procfs). There is no other way to reach a task: no global lookup.
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
