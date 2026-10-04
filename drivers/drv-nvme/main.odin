// drv-nvme: an NVMe controller (NVM Express base specification 1.4;
// upstream's docs/11 §10), serving the block class protocol (lib/driver's
// blockproto.odin) on its post, /srv/diskN, for its first namespace.
//
// devmgr starts it, as any PCI driver, with the function's configuration
// space, its memory BARs, a DMA domain, MSI-X interrupts and the post's
// listen end. It serves up to MAX_CLIENTS sessions at once, each reaching its
// own window of the namespace.
//
// Queues. The admin queue is polled. The I/O queues are made at start, as
// many pairs as the controller grants (MAX_QUEUES at most), each with its own
// MSI-X vector while vectors last; a session submits to queue pair
// 1 + (its slot mod their number), so sessions share pairs when there are
// fewer. A queue must be physically contiguous (CAP.CQR), so its depth is
// what the controller allows (CAP.MQES) and what its memory gives the device
// in one run: a page, through a pass-through DMA domain; more, where an
// IOMMU gives contiguous device addresses.
//
// Commands. Each command in flight has an id, its index in its queue's
// table, apart from where it sits in the submission queue, and its own PRP
// list (in memory of the driver's that the device can reach). Zero copy: a
// session's client arena is given to the device when the session opens, and
// a transfer names the arena's own pages.
//
// Recovery. A command past its deadline is aborted; one still not done a
// while after that, or a controller that reports a fatal status (CSTS.CFS),
// is a reset: the controller disabled and enabled again, its queues made
// again, and every command that was in flight submitted again, under its old
// id. Reads, writes of the same data, flushes and discards may each be done
// twice, so a client sees a delay, not an error. The command line's
// drv-nvme.reset=N resets the controller after every N completions (the
// fsdnvmereset scenario); drv-nvme.die=N makes the first start exit after N
// completions, with commands in flight, as a crash would (fsdnvmerestart);
// drv-nvme.fault=1 aims a command where the DMA domain maps nothing, to see
// the IOMMU stop it (nvmefault).
//
// Everything the controller writes (completions, identify data) is read as
// untrusted: ids and indices bounded, sizes checked.
//
// One thread, one port: the interrupts, the listen channel, each session's
// doorbell and going away, and the next deadline.
package nvme

import "base:intrinsics"
import vx "abi:vx"
import "vx:driver"
import "vx:memory"
import "vx:ndb"
import "vx:pci"
import "vx:ring"
import "vx:rt"
import "vx:str"

MAX_CLIENTS :: 8
MAX_QUEUES :: 8
MAX_VECTORS :: 8
MAX_DEPTH :: 256
ADMIN_DEPTH :: 32
MAX_TRANSFER :: 128 << 10 // bytes one request moves, at most
PRP_SLOT :: 512 // a command's PRP list and DSM range
IO_TIMEOUT :: vx.Duration(10_000_000_000) // a command's, before it is aborted
ABORT_GRACE :: vx.Duration(5_000_000_000) // after the abort, before a reset
ARENA_PAGES :: driver.BLOCK_ARENA / 4096

// The controller's registers (§3.1), at the start of BAR 0; the doorbells
// follow at 0x1000. 64-bit registers are read and written as two halves.
Regs :: struct {
	cap:   [2]u32,
	vs:    u32,
	intms: u32,
	intmc: u32,
	cc:    u32,
	_:     u32,
	csts:  Csts,
	nssr:  u32,
	aqa:   u32,
	asq:   [2]u32,
	acq:   [2]u32,
}
#assert(offset_of(Regs, cc) == 0x14)
#assert(offset_of(Regs, csts) == 0x1c)
#assert(offset_of(Regs, aqa) == 0x24)
#assert(offset_of(Regs, asq) == 0x28)
#assert(offset_of(Regs, acq) == 0x30)

Csts_Bit :: enum u32 {
	Rdy, // ready
	Cfs, // a fatal status
}
Csts :: bit_set[Csts_Bit; u32]

CC_EN :: u32(1)
CC_IOSQES :: u32(6) << 16 // 64-byte submission entries
CC_IOCQES :: u32(4) << 20 // 16-byte completion entries
DOORBELLS :: 0x1000

// Admin (§5) and NVM (NVM command set §3) opcodes.
Opcode :: enum u8 {
	Delete_Sq    = 0x00,
	Create_Sq    = 0x01,
	Delete_Cq    = 0x04,
	Create_Cq    = 0x05,
	Identify     = 0x06,
	Abort        = 0x08,
	Set_Features = 0x09,
	Flush        = 0x00,
	Write        = 0x01,
	Read         = 0x02,
	Dsm          = 0x09,
}
FUA :: u32(1) << 30 // a read's or write's cdw12

// A submission queue entry (§4.2).
Sq_Entry :: struct {
	cdw0:      u32, // the opcode, and the command id above bit 16
	nsid:      u32,
	_:         [2]u32,
	mptr:      u64,
	prp1, prp2: u64,
	cdw:       [6]u32, // cdw10 to cdw15
}
#assert(size_of(Sq_Entry) == 64)

// A completion queue entry (§4.6).
Cq_Entry :: struct {
	result:  u32,
	_:       u32,
	sq_head: u16,
	sq_id:   u16,
	cid:     u16,
	status:  u16, // the phase tag in bit 0, the status above it
}
#assert(size_of(Cq_Entry) == 16)

// A Dataset Management range (NVM command set §3.2.3).
Dsm_Range :: struct {
	attributes: u32,
	length:     u32, // in sectors
	slba:       u64,
}

// A command's own memory: its PRP list, and its DSM range.
Prp_Slot :: struct {
	list: [MAX_TRANSFER / 4096 + 1]u64,
	_:    [384 - (MAX_TRANSFER / 4096 + 1) * 8]u8,
	dsm:  Dsm_Range,
	_:    [PRP_SLOT - 384 - size_of(Dsm_Range)]u8,
}
#assert(size_of(Prp_Slot) == PRP_SLOT)

// Port keys: below 256 the driver's own; a session's carry its slot and
// generation, so a packet about a session that has gone is never taken for
// the next one in its slot.
KEY_LISTEN :: 1
KEY_IRQ :: 16 // + the vector
Client_Key :: enum u64 {
	Bell   = 1,
	Closed = 2,
}

Client :: struct {
	on, dying:            bool, // dying: gone, but with commands still in flight
	gen:                  u32,
	ring:                 ring.Ring,
	end, memory, mapping: vx.Handle, // mapping: the arena's, for the device
	pages:                [ARENA_PAGES]u64, // the arena's device addresses, by page
	first, count:         u64, // the window, in sectors
	readonly, armed:      bool,
	inflight:             u32,
}

// A command in flight, by its id: enough to submit it again after a reset.
Cmd :: struct {
	busy, aborted: bool,
	client:        u8,
	opcode:        Opcode,
	gen:           u32,
	user_data:     u64,
	result:        i64, // what completing it reports, if the controller says it worked
	prp1, prp2:    u64,
	cdw:           [6]u32, // cdw10 to cdw15
	deadline:      vx.Instant,
}

Queue :: struct {
	id, depth, vector: u16,
	sq:                []Sq_Entry,
	cq:                []Cq_Entry,
	sq_addr, cq_addr:  u64, // device addresses
	sq_tail, cq_head:  u16,
	phase:             bool,
	inflight:          u32,
	prp:               []Prp_Slot, // depth slots
	prp_pages:         [MAX_DEPTH * PRP_SLOT / 4096]u64,
	cmds:              [MAX_DEPTH]Cmd,
}

fn: pci.Function
regs: ^Regs
bar0: []u8
doorbell_stride: u32 // bytes
ready_timeout: vx.Duration
dma, port, listen: vx.Handle
irqs: [dynamic; MAX_VECTORS]vx.Handle
admin: Queue
ioq: [MAX_QUEUES]Queue
nqueues: u32
scratch: []u8 // a page for identify data
scratch_addr: u64
clients: [MAX_CLIENTS]Client
nsid, sector_size, max_transfer: u32
sectors: u64
has_cache, has_discard: bool
reset_every, completions, resets: u64
fault_test: bool // drv-nvme.fault=1: see fault_once
die_after: u64 // drv-nvme.die=N: on its first start, exit after N completions
next_client: u32
never: u32 // what a pause waits on: nothing wakes it

fail :: proc "contextless" (what: string) -> ! {
	rt.print("drv-nvme: FAILED: ", what, "\n")
	rt.exits(what)
}

nap :: proc "contextless" (d: vx.Duration) {
	_ = rt.futex_wait(&never, 0, rt.clock_read() + d)
}

r32 :: proc "contextless" (r: ^u32) -> u32 {
	return intrinsics.volatile_load(r)
}

w32 :: proc "contextless" (r: ^u32, v: u32) {
	intrinsics.volatile_store(r, v)
}

w64 :: proc "contextless" (r: ^[2]u32, v: u64) {
	w32(&r[0], u32(v))
	w32(&r[1], u32(v >> 32))
}

csts :: proc "contextless" () -> Csts {
	return intrinsics.volatile_load(&regs.csts)
}

doorbell :: proc "contextless" (index: u32, v: u16) {
	at := DOORBELLS + int(index * doorbell_stride)
	intrinsics.volatile_store(cast(^u32)&bar0[at], u32(v))
}

ring_sq :: proc "contextless" (q: ^Queue) {
	doorbell(2 * u32(q.id), q.sq_tail)
}

ring_cq :: proc "contextless" (q: ^Queue) {
	doorbell(2 * u32(q.id) + 1, q.cq_head)
}

key_of :: proc "contextless" (c: u32, kind: Client_Key) -> u64 {
	return u64(clients[c].gen) << 16 | u64(c) << 8 | u64(kind)
}

// Maps the handle the spawn message calls `name` (`size` bytes), or returns nil.
map_handle :: proc "contextless" (name: string, size: u64) -> []u8 {
	h := rt.spawn_take(name)
	if h == vx.HANDLE_NONE {
		return nil
	}
	defer rt.close_all(h) // the mapping keeps it
	at, st := rt.as_map(rt.self, h, 0, size, {.Write})
	return st == .Ok ? (cast([^]u8)uintptr(at))[:size] : nil
}

// Memory the device reaches: size bytes, mapped here, its pages' device
// addresses in pages, and the bytes it gives in one run from its start. The
// device reads and writes it all (queues, PRP lists, identify data), for as
// long as the driver lives.
dma_memory :: proc "contextless" (size: u64, pages: []u64) -> (mem: []u8, run: u64) {
	vmo, st := rt.vmo_create(size)
	at: u64
	if st == .Ok {
		at, st = rt.as_map(rt.self, vmo, 0, size, {.Write})
	}
	if st == .Ok {
		_, st = rt.dma_map(dma, vmo, 0, size, {.Read, .Write}, pages[:size / 4096]) // the mapping kept as long as the driver lives
	}
	rt.close_all(vmo) // the mappings keep it
	if st != .Ok {
		fail("no memory the device can reach")
	}
	n := u64(1)
	for n < size / 4096 && pages[n] == pages[0] + n * 4096 {
		n += 1
	}
	return (cast([^]u8)uintptr(at))[:size], n * 4096
}

// A queue pair's memory: as deep as the controller and one contiguous run
// of each queue allow, at most `want`.
queue_memory :: proc "contextless" (q: ^Queue, id, want, mqes: u16) {
	pages: [MAX_DEPTH * size_of(Sq_Entry) / 4096]u64
	q.id = id
	sq, sq_run := dma_memory(MAX_DEPTH * size_of(Sq_Entry), pages[:])
	q.sq = (cast([^]Sq_Entry)raw_data(sq))[:MAX_DEPTH]
	q.sq_addr = pages[0]
	cq, cq_run := dma_memory(max(MAX_DEPTH * size_of(Cq_Entry), 4096), pages[:])
	q.cq = (cast([^]Cq_Entry)raw_data(cq))[:MAX_DEPTH]
	q.cq_addr = pages[0]
	depth := min(u64(want), u64(mqes) + 1, sq_run / size_of(Sq_Entry), cq_run / size_of(Cq_Entry))
	if depth < 2 {
		fail("a queue of fewer than two entries")
	}
	q.depth = u16(depth)
	prp, _ := dma_memory(max(depth * PRP_SLOT, 4096), q.prp_pages[:])
	q.prp = (cast([^]Prp_Slot)raw_data(prp))[:depth]
}

queue_reset :: proc "contextless" (q: ^Queue) {
	for &e in q.cq[:q.depth] {
		intrinsics.volatile_store(&e, Cq_Entry{})
	}
	q.sq_tail, q.cq_head = 0, 0
	q.phase = true
}

// The device address of byte `at` of command cid's PRP slot.
prp_addr :: proc "contextless" (q: ^Queue, cid: u16, at: uintptr) -> u64 {
	off := u64(cid) * PRP_SLOT + u64(at)
	return q.prp_pages[off / 4096] + off % 4096
}

// Puts command cid at the queue's tail, for namespace ns; the caller rings.
put_sqe :: proc "contextless" (q: ^Queue, cid: u16, ns: u32) {
	c := &q.cmds[cid]
	e := Sq_Entry {
		cdw0 = u32(c.opcode) | u32(cid) << 16,
		nsid = ns,
		prp1 = c.prp1,
		prp2 = c.prp2,
		cdw  = c.cdw,
	}
	intrinsics.volatile_store(&q.sq[q.sq_tail], e)
	q.sq_tail = (q.sq_tail + 1) % q.depth
}

// The next completion on q, if one has come: its id, status and result.
take_cqe :: proc "contextless" (q: ^Queue) -> (cid, status: u16, result: u32, ok: bool) {
	e := &q.cq[q.cq_head]
	tail := intrinsics.volatile_load(&e.status)
	if (tail & 1 != 0) != q.phase {
		return
	}
	intrinsics.atomic_thread_fence(.Acquire) // the entry, after its phase tag
	result = intrinsics.volatile_load(&e.result)
	cid = intrinsics.volatile_load(&e.cid)
	status = tail >> 1
	q.cq_head += 1
	if q.cq_head == q.depth {
		q.cq_head = 0
		q.phase = !q.phase
	}
	return cid, status, result, true
}

// --- The admin queue: one command at a time, polled ---

@(require_results)
admin_cmd :: proc "contextless" (opcode: Opcode, ns: u32, prp1: u64, cdw: [6]u32) -> (result: u32, st: vx.Status) {
	c := &admin.cmds[0]
	c^ = {busy = true, opcode = opcode, prp1 = prp1, cdw = cdw}
	put_sqe(&admin, 0, ns)
	ring_sq(&admin)
	deadline := rt.clock_read() + ready_timeout
	for {
		cid, status, res, ok := take_cqe(&admin)
		if ok {
			ring_cq(&admin)
			if cid != 0 {
				continue // not ours: a stale completion
			}
			c.busy = false
			return res, status != 0 ? .Err_Io : .Ok
		}
		if .Cfs in csts() || rt.clock_read() > deadline {
			c.busy = false
			return 0, .Err_Timed_Out
		}
		nap(100_000) // 0.1 ms
	}
}

// --- Bringing the controller up (§7.6.1), at start and at each reset ---

wait_ready :: proc "contextless" (want: bool) -> bool {
	deadline := rt.clock_read() + ready_timeout
	for (.Rdy in csts()) != want {
		if rt.clock_read() > deadline || (want && .Cfs in csts()) {
			return false
		}
		nap(1_000_000)
	}
	return true
}

create_io_queue :: proc "contextless" (q: ^Queue) -> bool {
	PC :: 1 // physically contiguous
	IEN :: 2 // interrupts enabled
	queue_reset(q)
	size := u32(q.depth - 1) << 16 | u32(q.id)
	_, cst := admin_cmd(.Create_Cq, 0, q.cq_addr, {size, u32(q.vector) << 16 | IEN | PC, 0, 0, 0, 0})
	if cst != .Ok {
		return false
	}
	_, sst := admin_cmd(.Create_Sq, 0, q.sq_addr, {size, u32(q.id) << 16 | PC, 0, 0, 0, 0}) // its CQ
	return sst == .Ok
}

// Disabled, then enabled with the admin queue; the I/O queues made again if
// they were (a reset). False if the controller will not come up.
controller_up :: proc "contextless" (again: bool) -> bool {
	if r32(&regs.cc) & CC_EN != 0 || .Rdy in csts() {
		w32(&regs.cc, r32(&regs.cc) &~ CC_EN)
		if !wait_ready(false) {
			return false
		}
	}
	queue_reset(&admin)
	w32(&regs.aqa, u32(admin.depth - 1) << 16 | u32(admin.depth - 1))
	w64(&regs.asq, admin.sq_addr)
	w64(&regs.acq, admin.cq_addr)
	w32(&regs.cc, CC_IOCQES | CC_IOSQES | CC_EN) // NVM command set, 4 KiB pages, round robin
	if !wait_ready(true) {
		return false
	}
	if !again {
		return true
	}
	NUMBER_OF_QUEUES :: 0x07
	if _, st := admin_cmd(.Set_Features, 0, 0, {NUMBER_OF_QUEUES, (nqueues - 1) << 16 | (nqueues - 1), 0, 0, 0, 0}); st != .Ok {
		return false
	}
	for &q in ioq[:nqueues] {
		if !create_io_queue(&q) {
			return false
		}
	}
	return true
}

le16 :: proc "contextless" (b: []u8, at: int) -> u16 {
	return u16(intrinsics.unaligned_load(cast(^u16le)raw_data(b[at:][:2])))
}

le32 :: proc "contextless" (b: []u8, at: int) -> u32 {
	return u32(intrinsics.unaligned_load(cast(^u32le)raw_data(b[at:][:4])))
}

le64 :: proc "contextless" (b: []u8, at: int) -> u64 {
	return u64(intrinsics.unaligned_load(cast(^u64le)raw_data(b[at:][:8])))
}

identify :: proc "contextless" (cns: u32, ns: u32, what: string) {
	if _, st := admin_cmd(.Identify, ns, scratch_addr, {cns, 0, 0, 0, 0, 0}); st != .Ok {
		fail(what)
	}
}

setup :: proc "contextless" () {
	cfg := map_handle("config", pci.CONFIG_SIZE)
	dma = rt.spawn_take("dma")
	if cfg == nil || dma == vx.HANDLE_NONE {
		fail("no configuration space or DMA domain")
	}
	fn.cfg = cast(^[pci.CONFIG_SIZE / 4]u32)raw_data(cfg)
	@(static) text: [vx.CHANNEL_MAX_BYTES]u8
	r := ndb.Reader{src = rt.spawn.text, scratch = text[:]}
	rec: ndb.Record
	bars: [6][]u8
	msi: [MAX_VECTORS]vx.Msi
	for ndb.next(&r, &rec) == .Record {
		if n, ok := ndb.get_u64(&rec, "bar"); ok && n < 6 {
			if size, sok := ndb.get_u64(&rec, "size"); sok {
				name := [4]u8{'b', 'a', 'r', u8('0' + n)}
				bars[n] = map_handle(string(name[:]), size)
			}
		} else if m, mok := ndb.get_u64(&rec, "msi"); mok && m < MAX_VECTORS {
			if address, aok := ndb.get_u64(&rec, "address"); aok {
				data, _ := ndb.get_u64(&rec, "data")
				msi[m] = {address = address, data = u32(data)}
			}
		}
	}
	bar0 = bars[0]
	if len(bar0) < 0x2000 {
		fail("no register BAR")
	}
	regs = cast(^Regs)raw_data(bar0)
	table := pci.msix_table(&fn, bars[:])
	if table == nil {
		fail("no MSI-X")
	}
	for v := 0; v < MAX_VECTORS && v < len(table) && msi[v].address != 0; v += 1 {
		name := [4]u8{'m', 's', 'i', u8('0' + v)}
		h := rt.spawn_take(string(name[:]))
		if h == vx.HANDLE_NONE {
			break
		}
		_ = append(&irqs, h)
		pci.msix_set(&fn, table, v, msi[v])
	}
	if len(irqs) == 0 {
		fail("no MSI")
	}
	pci.enable(&fn)

	// The controller's limits (§3.1.1), read as untrusted.
	cap := u64(r32(&regs.cap[0])) | u64(r32(&regs.cap[1])) << 32
	mqes := u16(cap)
	doorbell_stride = 4 << ((cap >> 32) & 0xf)
	ready_timeout = vx.Duration((cap >> 24) & 0xff + 1) * 500_000_000
	if cap >> 37 & 1 == 0 {
		fail("no NVM command set")
	}
	if (cap >> 48) & 0xf != 0 {
		fail("4 KiB pages are not supported")
	}
	if DOORBELLS + (2 * MAX_QUEUES + 2) * u64(doorbell_stride) > u64(len(bar0)) {
		fail("doorbells outside the BAR")
	}
	queue_memory(&admin, 0, ADMIN_DEPTH, mqes)
	if !controller_up(false) {
		fail("the controller does not come up")
	}
	one: [1]u64
	scratch, _ = dma_memory(4096, one[:])
	scratch_addr = one[0]

	// Identify the controller (CNS 1), the namespaces it has (CNS 2), the
	// first's size and format (CNS 0).
	identify(1, 0, "identify controller")
	mdts := scratch[77]
	has_cache = scratch[525] & 1 != 0
	oncs := le16(scratch, 520)
	has_discard = oncs & 4 != 0
	identify(2, 0, "identify namespaces")
	nsid = le32(scratch, 0)
	if nsid == 0 || nsid == 0xffff_ffff {
		fail("no namespace")
	}
	identify(0, nsid, "identify namespace")
	sectors = le64(scratch, 0)
	format := int(scratch[26] & 0xf)
	lbaf := le32(scratch, 128 + 4 * format)
	lbads := (lbaf >> 16) & 0xff
	if lbaf & 0xffff != 0 {
		fail("a format with metadata")
	}
	if lbads < 9 || lbads > 12 {
		fail("a sector size outside 512 to 4096")
	}
	sector_size = 1 << lbads
	max_transfer = MAX_TRANSFER
	if mdts != 0 && mdts < 16 && u32(4096) << mdts < max_transfer {
		max_transfer = u32(4096) << mdts
	}
	max_transfer -= max_transfer % sector_size
	if fault_test {
		fault_once()
	}

	// The I/O queues: as many pairs as granted, each with its own vector while
	// they last (vector 0 is the admin queue's).
	NUMBER_OF_QUEUES :: 0x07
	granted, st := admin_cmd(.Set_Features, 0, 0, {NUMBER_OF_QUEUES, (MAX_QUEUES - 1) << 16 | (MAX_QUEUES - 1), 0, 0, 0, 0})
	if st != .Ok {
		fail("set the number of queues")
	}
	nqueues = min(MAX_QUEUES, (granted & 0xffff) + 1, (granted >> 16) + 1)
	vectors := u32(len(irqs))
	for &q, i in ioq[:nqueues] {
		queue_memory(&q, u16(i + 1), MAX_DEPTH, mqes)
		q.vector = u16(vectors > 1 ? 1 + u32(i) % (vectors - 1) : 0)
		if !create_io_queue(&q) {
			fail("create the I/O queues")
		}
	}
}

// --- Sessions ---

// Completes a request. False if the client does not drain its completions.
complete :: proc "contextless" (c: u32, e: vx.Cqe) -> bool {
	e := e
	k := &clients[c]
	slot, ok := ring.produce_slot(&k.ring)
	if !ok {
		return false
	}
	copy(slot, memory.ptr_to_bytes(&e))
	if ring.produce(&k.ring) {
		_ = rt.ring_notify(k.end)
	}
	return true
}

// The session's memory, given back once nothing in flight can write to it.
release_client :: proc "contextless" (c: u32) {
	k := &clients[c]
	_ = rt.dma_unmap(k.mapping)
	rt.close_all(k.memory)
	rt.session_unmap(&k.ring)
	gen := k.gen
	k^ = {gen = gen}
}

drop_client :: proc "contextless" (c: u32) {
	k := &clients[c]
	if !k.on {
		return
	}
	rt.close_all(k.end)
	k.on = false
	k.dying = true
	if k.inflight == 0 {
		release_client(c)
	}
}

queue_of :: proc "contextless" (c: u32) -> ^Queue {
	return &ioq[c % nqueues]
}

free_cid :: proc "contextless" (q: ^Queue) -> (cid: u16, ok: bool) {
	if q.inflight + 1 >= u32(q.depth) {
		return 0, false // a full queue: the tail would meet the head
	}
	for &m, i in q.cmds[:q.depth] {
		if !m.busy {
			return u16(i), true
		}
	}
	return 0, false
}

// A transfer's PRPs (§4.3): the first page's address with its offset, then
// the second page, or a list of the rest in the command's slot.
build_prps :: proc "contextless" (q: ^Queue, cid: u16, k: ^Client, arena_off, length: u32, m: ^Cmd) {
	in_page, page := arena_off % 4096, arena_off / 4096
	m.prp1 = k.pages[page] + u64(in_page)
	first := 4096 - in_page
	if length <= first {
		return
	}
	rest := (length - first + 4095) / 4096
	if rest == 1 {
		m.prp2 = k.pages[page + 1]
		return
	}
	copy(q.prp[cid].list[:rest], k.pages[page + 1:][:rest])
	m.prp2 = prp_addr(q, cid, offset_of(Prp_Slot, list))
}

issue :: proc "contextless" (q: ^Queue, cid: u16, c: u32, proto: Cmd) {
	m := &q.cmds[cid]
	m^ = proto
	m.busy = true
	m.client = u8(c)
	m.gen = clients[c].gen
	m.deadline = rt.clock_read() + IO_TIMEOUT
	q.inflight += 1
	clients[c].inflight += 1
	put_sqe(q, cid, nsid)
}

// Checks a transfer against the session's window and arena.
check_transfer :: proc "contextless" (k: ^Client, e: ^vx.Sqe) -> vx.Status {
	if .Dref not_in e.flags || e.len == 0 || e.len % sector_size != 0 || e.arena_off % sector_size != 0 || e.len > max_transfer {
		return .Err_Invalid
	}
	if u64(e.arena_off) + u64(e.len) > driver.BLOCK_ARENA {
		return .Err_Range
	}
	n := u64(e.len / sector_size)
	if e.target >= k.count || n > k.count - e.target {
		return .Err_Range
	}
	return .Ok
}

// Takes what session c has submitted, as long as its queue has room. False
// if it broke the protocol. rang: the queues to ring, by bit.
serve_client :: proc "contextless" (c: u32, rang: ^u32) -> bool {
	k := &clients[c]
	q := queue_of(c)
	for k.on {
		cid, free := free_cid(q)
		if !free {
			return true // taken again when a command completes
		}
		e: vx.Sqe
		st := ring.consume(&k.ring, memory.ptr_to_bytes(&e))
		if st == .Err_Should_Wait {
			return true
		}
		if st != .Ok {
			return false
		}
		done := vx.Cqe{user_data = e.user_data}
		m := Cmd{user_data = e.user_data}
		now := true // completed here, without the controller
		switch op := driver.Block_Op(e.opcode); op {
		case .Info:
			done.result = i64(max_transfer)
			done.aux = sector_size
			done.aux2 = k.count
			flags: driver.Block_Info_Flags
			if k.readonly {
				flags += {.Readonly}
			}
			if has_cache {
				flags += {.Cache}
			}
			if has_discard {
				flags += {.Discard}
			}
			done.flags = transmute(u32)flags
		case .Read, .Write, .Write_Fua:
			write := op != .Read
			why := check_transfer(k, &e)
			if why == .Ok && write && k.readonly {
				why = .Err_Access
			}
			if why != .Ok {
				done.result = i64(why)
				break
			}
			lba := k.first + e.target
			m.opcode = write ? .Write : .Read
			m.result = i64(e.len)
			m.cdw[0], m.cdw[1] = u32(lba), u32(lba >> 32)
			m.cdw[2] = e.len / sector_size - 1
			if op == .Write_Fua {
				m.cdw[2] |= FUA
			}
			build_prps(q, cid, k, e.arena_off, e.len, &m)
			issue(q, cid, c, m)
			now = false
		case .Flush:
			if k.readonly || !has_cache {
				break // nothing of this session's to make durable
			}
			m.opcode = .Flush
			issue(q, cid, c, m)
			now = false
		case .Discard:
			if k.readonly {
				done.result = i64(vx.Status.Err_Access)
				break
			}
			if e.target >= k.count || e.offset > k.count - e.target {
				done.result = i64(vx.Status.Err_Range)
				break
			}
			if !has_discard || e.offset == 0 {
				break // a hint the controller cannot take: done
			}
			// At most one range's worth (2^32 - 1 sectors); a discard is a
			// hint, so the rest may go undone.
			count := min(e.offset, 0xffff_ffff)
			lba := k.first + e.target
			intrinsics.volatile_store(&q.prp[cid].dsm, Dsm_Range{length = u32(count), slba = lba})
			m.opcode = .Dsm
			m.prp1 = prp_addr(q, cid, offset_of(Prp_Slot, dsm))
			DEALLOCATE :: 4
			m.cdw[0], m.cdw[1] = 0, DEALLOCATE // one range
			issue(q, cid, c, m)
			now = false
		case:
			done.result = i64(vx.Status.Err_Invalid)
		}
		if !now {
			rang^ |= 1 << (q.id - 1)
			continue
		}
		if !complete(c, done) {
			return false
		}
	}
	return true
}

// Commands the controller has finished, on queue q: each completed to its session.
service_queue :: proc "contextless" (q: ^Queue) {
	took := false
	for {
		cid, status, _, ok := take_cqe(q)
		if !ok {
			break
		}
		took = true
		if cid >= q.depth || !q.cmds[cid].busy {
			continue // not one we submitted
		}
		m := &q.cmds[cid]
		c := u32(m.client)
		k := &clients[c]
		result := status != 0 ? i64(vx.Status.Err_Io) : m.result
		user_data := m.user_data
		same := k.gen == m.gen
		m^ = {}
		q.inflight -= 1
		completions += 1
		if !same {
			continue
		}
		k.inflight -= 1
		if k.on && !complete(c, {user_data = user_data, result = result}) {
			drop_client(c)
		}
		if k.dying && k.inflight == 0 {
			release_client(c)
		}
	}
	if took {
		ring_cq(q)
	}
}

// The controller reset (§7.3.2), and every command that was in flight
// submitted again: a client sees a delay, not an error.
reset_controller :: proc "contextless" (why: string) {
	resets += 1
	rt.print("drv-nvme: reset: ", why, "\n")
	for tries := 0; !controller_up(true); tries += 1 {
		if tries == 3 {
			fail("the controller does not come back after a reset")
		}
	}
	now := rt.clock_read()
	for &q in ioq[:nqueues] {
		for &m, cid in q.cmds[:q.depth] {
			if m.busy {
				m.aborted = false
				m.deadline = now + IO_TIMEOUT
				put_sqe(&q, u16(cid), nsid)
			}
		}
		ring_sq(&q)
	}
}

// Commands past their deadlines: aborted (§5.1), and if that does not settle
// them, the controller reset. Returns when to look again.
check_deadlines :: proc "contextless" () -> vx.Instant {
	now, next := rt.clock_read(), vx.INFINITE
	if .Cfs in csts() {
		reset_controller("the controller reports a fatal status")
		now = rt.clock_read()
	}
	for &q in ioq[:nqueues] {
		for &m, cid in q.cmds[:q.depth] {
			if !m.busy {
				continue
			}
			if m.deadline <= now && !m.aborted {
				// Its completion, if it comes, says how it ended.
				_, _ = admin_cmd(.Abort, 0, 0, {u32(cid) << 16 | u32(q.id), 0, 0, 0, 0, 0})
				m.aborted = true
				m.deadline = now + ABORT_GRACE
			} else if m.deadline <= now {
				reset_controller("a command not done after it was aborted")
				return rt.clock_read()
			}
			next = min(next, m.deadline)
		}
	}
	return next
}

accept_client :: proc "contextless" () {
	for {
		req: driver.Block_Connect
		size, st := rt.channel_read(listen, memory.ptr_to_bytes(&req))
		if st == .Err_Should_Wait {
			return
		}
		if st == .Err_Peer_Closed {
			fail("the listen channel is gone")
		}
		if st == .Err_Too_Small { // not a request this protocol makes: read it, to be rid of it
			@(static) junk: [vx.CHANNEL_MAX_BYTES]u8
			@(static) junk_handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle
			if jsize, jst := rt.channel_read(listen, junk[:], junk_handles[:]); jst == .Ok {
				rt.close_all(..junk_handles[:jsize.handles])
			}
			continue
		}
		if st != .Ok || size.bytes < size_of(vx.Msg_Header) {
			continue
		}
		if size.bytes != size_of(req) || req.header.ordinal != driver.BLOCK_CONNECT || req.flags - {.Readonly} != {} {
			rt.session_refuse(listen, req.header, .Err_Invalid)
			continue
		}
		count := req.count
		if count == 0 && req.first < sectors {
			count = sectors - req.first
		}
		if req.first >= sectors || count == 0 || count > sectors - req.first {
			rt.session_refuse(listen, req.header, .Err_Range)
			continue
		}
		c := u32(0)
		for c < MAX_CLIENTS && (clients[c].on || clients[c].dying) {
			c += 1
		}
		if c == MAX_CLIENTS {
			rt.session_refuse(listen, req.header, .Err_No_Memory)
			continue
		}
		k := &clients[c]
		gen := k.gen + 1
		k^ = {gen = gen, first = req.first, count = count, readonly = .Readonly in req.flags}
		ast: vx.Status
		k.end, k.memory, ast = rt.session_accept_keep(listen, req.header, driver.BLOCK_PARAMS, &k.ring)
		if ast != .Ok {
			k^ = {gen = gen}
			continue
		}
		// The client arena, to the device.
		mst: vx.Status
		k.mapping, mst = rt.dma_map(dma, k.memory, k.ring.h.client_arena_offset, driver.BLOCK_ARENA, {.Read, .Write}, k.pages[:])
		if mst != .Ok {
			rt.close_all(k.end, k.memory)
			rt.session_unmap(&k.ring)
			k^ = {gen = gen}
			continue
		}
		k.on = true
		_ = rt.port_bind(port, k.end, .Peer_Closed, key_of(c, .Closed))
	}
}

// drv-nvme.fault=1: an Identify aimed where the domain maps nothing, to see
// the IOMMU stop the controller's write, count it, and say so (nvmefault).
fault_once :: proc "contextless" () {
	p, pst := rt.port_create()
	if pst != .Ok {
		fail("port_create")
	}
	bound := rt.port_bind(p, dma, .Dma_Fault, 1) == .Ok
	_, st := admin_cmd(.Identify, 0, 1 << 38, {1, 0, 0, 0, 0, 0})
	pk: [1]vx.Packet
	told := false
	if bound {
		n, _ := rt.port_wait(p, rt.clock_read() + 2_000_000_000, 0, pk[:])
		told = n == 1
	}
	rt.close_all(p)
	faults, _ := rt.dma_domain_op(dma, .Faults)
	rt.print("drv-nvme: a DMA fault, as asked: the command ", st == .Ok ? "completed" : "failed")
	rt.print(told ? ", the fault reported, " : ", no fault reported, ", faults, " counted\n")
}

// The digits a command-line word has after its key: drv-nvme.reset=50 is 50.
option_value :: proc "contextless" (word, key: string) -> (v: u64, ok: bool) {
	if !str.has_prefix(word, key) {
		return 0, false
	}
	for c in transmute([]u8)word[len(key):] {
		if c < '0' || c > '9' {
			break
		}
		v = v * 10 + u64(c - '0')
	}
	return v, true
}

// The driver's options, PROGRAM.KEY=VALUE words of the kernel command line,
// which devmgr passes on.
read_options :: proc "contextless" () {
	start := u64(1)
	rec: ndb.Record
	if rt.spawn_record("start", &rec) {
		start, _ = ndb.get_u64(&rec, "start")
	}
	line := rt.spawn.cmdline
	for word in str.split_iterator(&line, ' ') {
		if n, ok := option_value(word, "drv-nvme.die="); ok && start == 1 {
			die_after = n
		}
		if str.has_prefix(word, "drv-nvme.fault=1") {
			fault_test = true
		}
		if n, ok := option_value(word, "drv-nvme.reset="); ok {
			reset_every = n
		}
	}
}

print_size :: proc "contextless" () {
	rt.print(sectors * u64(sector_size) >> 20, " MiB, ", u64(sector_size), "-byte sectors, ")
	rt.print(u64(nqueues), " queues of ", u64(ioq[0].depth), ", ", u64(len(irqs)), " vectors")
	if has_cache {
		rt.print(", write cache")
	}
	if has_discard {
		rt.print(", discard")
	}
	if reset_every != 0 {
		rt.print(", a reset every ", reset_every)
	}
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	listen = rt.spawn_take("listen")
	if listen == vx.HANDLE_NONE {
		fail("no listen channel")
	}
	read_options()
	setup()
	pst: vx.Status
	if port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	for irq, v in irqs {
		_ = rt.port_bind(port, irq, .Irq, KEY_IRQ + u64(v))
	}
	rt.print("drv-nvme: ")
	print_size()
	rt.print("\n")

	listen_armed := false
	next_reset := reset_every
	for {
		for &q in ioq[:nqueues] {
			service_queue(&q)
		}
		if die_after != 0 && completions >= die_after { // as a crash would: with commands in flight
			rt.print("drv-nvme: exiting, as asked (drv-nvme.die)\n")
			rt.exits("drv-nvme.die")
		}
		if reset_every != 0 && completions >= next_reset {
			next_reset = completions + reset_every
			reset_controller("drv-nvme.reset")
		}
		deadline := check_deadlines()
		accept_client()
		rang: u32
		for i in u32(0) ..< MAX_CLIENTS { // round robin: each session in turn takes ids first
			c := (next_client + i) % MAX_CLIENTS
			if clients[c].on && !serve_client(c, &rang) {
				drop_client(c)
			}
		}
		next_client = (next_client + 1) % MAX_CLIENTS
		for &q, i in ioq[:nqueues] {
			if rang & (1 << uint(i)) != 0 {
				ring_sq(&q)
			}
		}

		// Arm what is idle; sleep unless a ring filled meanwhile. A session
		// whose queue is full is not armed: a completion frees an id, and that
		// comes as an interrupt.
		idle := true
		for &k, c in clients {
			if !k.on {
				continue
			}
			if _, free := free_cid(queue_of(u32(c))); !free {
				continue
			}
			seen, _ := rt.counter_read(k.end)
			if !ring.prepare_sleep(&k.ring) {
				idle = false
			} else if !k.armed {
				k.armed = rt.port_bind(port, k.end, .Counter_Ge, key_of(u32(c), .Bell), seen + 1) == .Ok
			}
		}
		if !listen_armed {
			listen_armed = rt.port_bind(port, listen, .Readable, KEY_LISTEN) == .Ok
		}
		if idle {
			pk: [16]vx.Packet
			n, _ := rt.port_wait(port, deadline, 0, pk[:])
			for p in pk[:n] {
				if p.key >= KEY_IRQ && p.key < KEY_IRQ + u64(len(irqs)) {
					_ = rt.port_bind(port, irqs[p.key - KEY_IRQ], .Irq, p.key)
				}
				if p.key == KEY_LISTEN {
					listen_armed = false
				}
				kind := Client_Key(p.key & 0xff)
				c := u32(p.key >> 8 & 0xff)
				if p.key < 256 || c >= MAX_CLIENTS || p.key != key_of(c, kind) {
					continue // a gone session's
				}
				switch kind {
				case .Bell:
					clients[c].armed = false
				case .Closed:
					drop_client(c)
				}
			}
		}
		for &k in clients {
			if k.on {
				ring.end_sleep(&k.ring)
			}
		}
	}
}
