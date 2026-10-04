// drv-virtio-blk: the virtio block device (virtio 1.x, §5.2; upstream's docs/11
// §10), serving the block class protocol (lib/driver's blockproto.odin) on its
// post, /srv/diskN.
//
// devmgr starts it with only its device: the function's configuration space,
// its memory BARs, a DMA domain, one MSI-X interrupt for the request queue,
// and the post's listen end. It serves up to MAX_CLIENTS sessions at once,
// each reaching its own window of the disk.
//
// Zero copy: a session's client arena is given to the device through the DMA
// domain when the session opens, so a transfer is described to the device as
// the arena's own pages and nothing is copied. Each request in flight holds a
// slot: an indirect descriptor table (§2.7.5.3), the request's header and its
// status byte, in memory of the driver's own that the device can reach. The
// device's view of a request is one queue descriptor, pointing at its table.
//
// virtio-blk has no FUA: WRITE_FUA is a write, then a flush, on the same slot.
// A session that ends with requests in flight stays half-open until they
// complete, so the device never writes into memory that has been let go.
//
// One thread, one port: the interrupt, the listen channel, and each
// session's doorbell and going away.
package virtioblk

import "base:intrinsics"
import vx "abi:vx"
import "vx:driver"
import "vx:memory"
import "vx:ndb"
import "vx:pci"
import "vx:ring"
import "vx:rt"

MAX_CLIENTS :: 8
SLOTS :: 64 // requests in flight, all sessions together
MAX_TRANSFER :: 128 << 10 // bytes one request moves, at most
MAX_SEGMENTS :: MAX_TRANSFER / 4096 + 1 // pages one transfer may touch
SLOT_BYTES :: 1024 // a slot's memory, four to a page
ARENA_PAGES :: driver.BLOCK_ARENA / 4096

// Features (§5.2.3).
F_SEG_MAX :: u64(1) << 2
F_RO :: u64(1) << 5
F_BLK_SIZE :: u64(1) << 6
F_FLUSH :: u64(1) << 9
F_DISCARD :: u64(1) << 13

// Request types (§5.2.6) and statuses.
Req_Type :: enum u32 {
	In      = 0,
	Out     = 1,
	Flush   = 4,
	Discard = 11,
}

Req_Status :: enum u8 {
	Ok     = 0,
	Io_Err = 1,
	Unsupp = 2,
}

// struct virtio_blk_req's header (§5.2.6).
Req_Header :: struct {
	type:     Req_Type,
	reserved: u32,
	sector:   u64, // in 512-byte units, whatever the device's sector size
}

// struct virtio_blk_discard_write_zeroes.
Discard_Range :: struct {
	sector:      u64,
	num_sectors: u32,
	flags:       u32,
}

// A request's memory, which the device reads (the table, the header, the
// range) and writes (the status byte).
Slot_Mem :: struct {
	table:   [MAX_SEGMENTS + 2]driver.Virtq_Desc,
	header:  Req_Header,
	discard: Discard_Range,
	status:  Req_Status,
}
#assert(size_of(Slot_Mem) <= SLOT_BYTES)

Slot_Page :: struct {
	using mem: Slot_Mem,
	_:         [SLOT_BYTES - size_of(Slot_Mem)]u8,
}
#assert(size_of(Slot_Page) == SLOT_BYTES)

// Port keys: a session's carry its slot and generation, so a packet about a
// session that has gone is never taken for the next one in its slot.
Key :: enum u64 {
	Irq = 1,
	Listen,
	Bell,
	Closed,
}

Client :: struct {
	on, dying:            bool, // dying: gone, but with requests still in flight
	gen:                  u32,
	ring:                 ring.Ring,
	end, memory, mapping: vx.Handle, // mapping: the arena's, for the device
	pages:                [ARENA_PAGES]u64, // the arena's device addresses, by page
	first, count:         u64, // the window, in sectors
	readonly:             bool,
	armed:                bool,
	inflight:             u32,
}

Stage :: enum u8 {
	Free,
	Busy,
	Fua_Flush, // a write, whose flush is still to come
}

Slot :: struct {
	stage:     Stage,
	client:    u8,
	gen:       u32,
	user_data: u64,
	result:    i64, // what completing it reports, if the device says it worked
}

dev: driver.Virtio
q: driver.Virtq
irq, port, listen: vx.Handle
slot_mem: ^[SLOTS]Slot_Page // mapped here
slot_mapping: vx.Handle // theirs, for the device: kept as long as the driver lives
slot_pages: [SLOTS / 4]u64 // their device addresses, a page each
slots: [SLOTS]Slot
clients: [MAX_CLIENTS]Client
sectors: u64 // the disk's, in sector_size units
sector_size: u32 // bytes
max_transfer, max_discard: u32
has_flush, has_discard, device_ro: bool
next_client: u32 // where the round robin over sessions starts

fail :: proc "contextless" (what: string) -> ! {
	rt.print("drv-virtio-blk: FAILED: ", what, "\n")
	rt.exits(what)
}

key_of :: proc "contextless" (c: u32, k: Key) -> u64 {
	return u64(clients[c].gen) << 16 | u64(c) << 8 | u64(k)
}

// The device address of field `at` (an offset in Slot_Mem) of slot s.
slot_addr :: proc "contextless" (s: u16, at: uintptr) -> u64 {
	return slot_pages[s / 4] + u64(s % 4) * SLOT_BYTES + u64(at)
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

// A 32-bit field of the device's configuration (§5.2.4), or 0 past its end.
cfg32 :: proc "contextless" (at: int) -> u32 {
	if at + 4 > len(dev.device) {
		return 0
	}
	return intrinsics.volatile_load(cast(^u32)&dev.device[at])
}

setup_device :: proc "contextless" () {
	cfg := map_handle("config", pci.CONFIG_SIZE)
	dev.dma = rt.spawn_take("dma")
	if cfg == nil || dev.dma == vx.HANDLE_NONE {
		fail("no configuration space or DMA domain")
	}
	dev.fn.cfg = cast(^[pci.CONFIG_SIZE / 4]u32)raw_data(cfg)
	@(static) scratch: [vx.CHANNEL_MAX_BYTES]u8
	r := ndb.Reader{src = rt.spawn.text, scratch = scratch[:]}
	rec: ndb.Record
	msi: vx.Msi
	for ndb.next(&r, &rec) == .Record {
		if n, ok := ndb.get_u64(&rec, "bar"); ok && n < 6 {
			if size, sok := ndb.get_u64(&rec, "size"); sok {
				name := [4]u8{'b', 'a', 'r', u8('0' + n)}
				dev.bar[n] = map_handle(string(name[:]), size)
			}
		} else if m, mok := ndb.get_u64(&rec, "msi"); mok && m == 0 {
			if address, aok := ndb.get_u64(&rec, "address"); aok {
				data, _ := ndb.get_u64(&rec, "data")
				msi = {address = address, data = u32(data)}
			}
		}
	}
	irq = rt.spawn_take("msi0")
	if irq == vx.HANDLE_NONE || msi.address == 0 {
		fail("no MSI")
	}
	if driver.virtio_find(&dev) != .Ok || len(dev.msix) < 1 {
		fail("not a modern virtio device with MSI-X")
	}
	features, st := driver.virtio_start(&dev, driver.VIRTIO_RING_F_INDIRECT_DESC | F_SEG_MAX | F_RO | F_BLK_SIZE | F_FLUSH | F_DISCARD)
	if st != .Ok {
		fail("feature negotiation")
	}
	if features & driver.VIRTIO_RING_F_INDIRECT_DESC == 0 {
		fail("no indirect descriptors")
	}
	driver.virtio_msix(&dev, 0, msi)
	if driver.virtq_init(&dev, &q, 0, SLOTS, 0) != .Ok || q.size < SLOTS {
		fail("the request queue")
	}

	// The device's configuration (§5.2.4), read as untrusted: sizes bounded.
	capacity := u64(cfg32(0)) | u64(cfg32(4)) << 32 // in 512-byte sectors, always
	sector_size = features & F_BLK_SIZE != 0 ? cfg32(20) : 512
	if sector_size < 512 || sector_size > 4096 || sector_size & (sector_size - 1) != 0 {
		sector_size = 512
	}
	sectors = capacity / u64(sector_size / 512)
	seg_max := features & F_SEG_MAX != 0 ? cfg32(12) : MAX_SEGMENTS
	if seg_max < 2 {
		fail("the device takes too few segments")
	}
	// The worst case: an unaligned start.
	max_transfer = seg_max >= MAX_SEGMENTS ? MAX_TRANSFER : (seg_max - 1) * 4096
	max_transfer -= max_transfer % sector_size
	has_flush = features & F_FLUSH != 0
	device_ro = features & F_RO != 0
	has_discard = features & F_DISCARD != 0
	max_discard = has_discard ? cfg32(36) : 0
	if max_discard == 0 {
		has_discard = false
	}

	SIZE :: SLOTS * SLOT_BYTES
	vmo, vst := rt.vmo_create(SIZE)
	at: u64
	if vst == .Ok {
		at, vst = rt.as_map(rt.self, vmo, 0, SIZE, {.Write})
	}
	if vst == .Ok {
		slot_mapping, vst = rt.dma_map(dev.dma, vmo, 0, SIZE, {.Read, .Write}, slot_pages[:])
	}
	rt.close_all(vmo) // the mappings keep it
	if vst != .Ok {
		fail("no memory for request slots")
	}
	slot_mem = cast(^[SLOTS]Slot_Page)uintptr(at)
	driver.virtio_ready(&dev)
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

// Describes a transfer to the device: the header, the arena's pages, the
// status byte, chained in slot s's table. Returns the table's length.
build_transfer :: proc "contextless" (s: u16, k: ^Client, type: Req_Type, sector: u64, arena_off, length: u32) -> u16 {
	m := &slot_mem[s]
	m.header = {type = type, sector = sector * u64(sector_size / 512)}
	intrinsics.volatile_store(&m.status, Req_Status(0xff))
	t := &m.table
	t[0] = {addr = slot_addr(s, offset_of(Slot_Mem, header)), len = size_of(Req_Header), flags = {.Next}, next = 1}
	n := u16(1)
	writes: bit_set[driver.Virtq_Desc_Flag; u16]
	if type == .In { // the device writes what it reads into the arena
		writes = {.Write}
	}
	for done := u32(0); done < length; {
		off := arena_off + done
		in_page := off % 4096
		take := min(4096 - in_page, length - done)
		pa := k.pages[off / 4096] + u64(in_page)
		prev := &t[n - 1]
		if n > 1 && prev.addr + u64(prev.len) == pa { // physically contiguous: one segment
			prev.len += take
		} else {
			t[n] = {addr = pa, len = take, flags = {.Next} + writes, next = n + 1}
			n += 1
		}
		done += take
	}
	t[n] = {addr = slot_addr(s, offset_of(Slot_Mem, status)), len = 1, flags = {.Write}}
	return n + 1
}

build_flush :: proc "contextless" (s: u16) -> u16 {
	m := &slot_mem[s]
	m.header = {type = .Flush}
	intrinsics.volatile_store(&m.status, Req_Status(0xff))
	m.table[0] = {addr = slot_addr(s, offset_of(Slot_Mem, header)), len = size_of(Req_Header), flags = {.Next}, next = 1}
	m.table[1] = {addr = slot_addr(s, offset_of(Slot_Mem, status)), len = 1, flags = {.Write}}
	return 2
}

build_discard :: proc "contextless" (s: u16, sector: u64, count: u32) -> u16 {
	m := &slot_mem[s]
	m.header = {type = .Discard}
	m.discard = {sector = sector * u64(sector_size / 512), num_sectors = count * (sector_size / 512)}
	intrinsics.volatile_store(&m.status, Req_Status(0xff))
	m.table[0] = {addr = slot_addr(s, offset_of(Slot_Mem, header)), len = size_of(Req_Header), flags = {.Next}, next = 1}
	m.table[1] = {addr = slot_addr(s, offset_of(Slot_Mem, discard)), len = size_of(Discard_Range), flags = {.Next}, next = 2}
	m.table[2] = {addr = slot_addr(s, offset_of(Slot_Mem, status)), len = 1, flags = {.Write}}
	return 3
}

free_slot :: proc "contextless" () -> (s: u16, ok: bool) {
	for &sl, i in slots {
		if sl.stage == .Free {
			return u16(i), true
		}
	}
	return 0, false
}

issue :: proc "contextless" (s: u16, c: u32, user_data: u64, result: i64, stage: Stage, n: u16) {
	slots[s] = {stage = stage, client = u8(c), gen = clients[c].gen, user_data = user_data, result = result}
	clients[c].inflight += 1
	driver.virtq_offer_indirect(&q, s, slot_addr(s, offset_of(Slot_Mem, table)), n)
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

// Takes what session c has submitted, as long as slots are free. False if it
// broke the protocol. kicked: whether anything went to the device.
serve_client :: proc "contextless" (c: u32, kicked: ^bool) -> bool {
	k := &clients[c]
	for k.on {
		s, free := free_slot()
		if !free {
			return true // taken again when a slot comes back
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
		now := true // completed here, without the device
		switch op := driver.Block_Op(e.opcode); op {
		case .Info:
			done.result = i64(max_transfer)
			done.aux = sector_size
			done.aux2 = k.count
			flags: driver.Block_Info_Flags
			if k.readonly {
				flags += {.Readonly}
			}
			if has_flush {
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
			n := build_transfer(s, k, write ? .Out : .In, k.first + e.target, e.arena_off, e.len)
			issue(s, c, e.user_data, i64(e.len), op == .Write_Fua && has_flush ? .Fua_Flush : .Busy, n)
			now = false
		case .Flush:
			if k.readonly || !has_flush {
				break // nothing of this session's to make durable
			}
			issue(s, c, e.user_data, 0, .Busy, build_flush(s))
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
				break // a hint the device cannot take: done
			}
			// At most what the device takes at once; a discard is a hint, so
			// the rest may go undone.
			count := min(e.offset, u64(max_discard))
			issue(s, c, e.user_data, 0, .Busy, build_discard(s, k.first + e.target, u32(count)))
			now = false
		case:
			done.result = i64(vx.Status.Err_Invalid)
		}
		if !now {
			kicked^ = true
			continue
		}
		if !complete(c, done) {
			return false
		}
	}
	return true
}

// Requests the device has finished: each completed, or its FUA's flush
// issued. Returns whether anything went to the device again.
service_queue :: proc "contextless" () -> (kicked: bool) {
	for {
		d, _, ok := driver.virtq_used(&q)
		if !ok {
			return
		}
		if d >= SLOTS || slots[d].stage == .Free {
			continue // not one we offered
		}
		sl := &slots[d]
		c := u32(sl.client)
		k := &clients[c]
		status := intrinsics.volatile_load(&slot_mem[d].status)
		if sl.stage == .Fua_Flush && status == .Ok && k.on && k.gen == sl.gen { // the write: now its flush
			sl.stage = .Busy
			driver.virtq_offer_indirect(&q, d, slot_addr(d, offset_of(Slot_Mem, table)), build_flush(d))
			kicked = true
			continue
		}
		result := i64(vx.Status.Err_Io)
		#partial switch status {
		case .Ok:
			result = sl.result
		case .Unsupp:
			result = i64(vx.Status.Err_Unsupported)
		}
		user_data := sl.user_data
		same := k.gen == sl.gen
		sl^ = {}
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
		k^ = {gen = gen, first = req.first, count = count, readonly = device_ro || .Readonly in req.flags}
		ast: vx.Status
		k.end, k.memory, ast = rt.session_accept_keep(listen, req.header, driver.BLOCK_PARAMS, &k.ring)
		if ast != .Ok {
			k^ = {gen = gen}
			continue
		}
		// The client arena, to the device.
		mst: vx.Status
		k.mapping, mst = rt.dma_map(dev.dma, k.memory, k.ring.h.client_arena_offset, driver.BLOCK_ARENA, {.Read, .Write}, k.pages[:])
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

print_size :: proc "contextless" () {
	rt.print(sectors * u64(sector_size) >> 20, " MiB, ", u64(sector_size), "-byte sectors")
	if device_ro {
		rt.print(", read-only")
	}
	if has_flush {
		rt.print(", write cache")
	}
	if has_discard {
		rt.print(", discard")
	}
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	listen = rt.spawn_take("listen")
	if listen == vx.HANDLE_NONE {
		fail("no listen channel")
	}
	setup_device()
	pst: vx.Status
	if port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	_ = rt.port_bind(port, irq, .Irq, u64(Key.Irq))
	rt.print("drv-virtio-blk: ")
	print_size()
	rt.print("\n")

	listen_armed := false
	for {
		kicked := service_queue()
		accept_client()
		for i in u32(0) ..< MAX_CLIENTS { // round robin: each session in turn takes slots first
			c := (next_client + i) % MAX_CLIENTS
			if clients[c].on && !serve_client(c, &kicked) {
				drop_client(c)
			}
		}
		next_client = (next_client + 1) % MAX_CLIENTS
		if kicked {
			driver.virtq_kick(&q)
		}

		// Arm what is idle; sleep unless a queue filled meanwhile. A session
		// waiting for a slot is not armed: a completion frees one, and that
		// comes as an interrupt.
		idle := true
		_, slot_free := free_slot()
		for &k, c in clients {
			if !k.on || !slot_free {
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
			listen_armed = rt.port_bind(port, listen, .Readable, u64(Key.Listen)) == .Ok
		}
		if idle {
			pk: [16]vx.Packet
			n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
			for p in pk[:n] {
				kind := Key(p.key & 0xff)
				c := u32(p.key >> 8 & 0xff)
				switch p.key {
				case u64(Key.Irq):
					_ = rt.port_bind(port, irq, .Irq, u64(Key.Irq))
				case u64(Key.Listen):
					listen_armed = false
				}
				if p.key < 256 || c >= MAX_CLIENTS || p.key != key_of(c, kind) {
					continue // a gone session's
				}
				#partial switch kind {
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
