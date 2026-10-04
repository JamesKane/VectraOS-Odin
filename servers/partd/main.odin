// partd: partitions as windows (upstream's docs/proto/block.md §6, docs/11
// §10). It holds a connector to a whole disk (its manifest's connect=, as
// "srv:DISK"), reads the disk's GPT through a read-only session of its own
// (vx:gpt), and serves each partition its manifest names on a post of its
// own, claimed from svcd:
//
//   service=partd program=/boot/bin/partd console
//   connect=disk0
//   claim=disk0.esp
//   part=disk0.esp type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
//   claim=disk0.system
//   part=disk0.system type=7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35
//
// A part= record matches the first GPT entry with that type GUID, or with
// that name (name=NAME). A CONNECT on a partition's post is answered with a
// session the driver opens on the window narrowed to the partition: partd
// passes the driver's reply on as it is and keeps nothing of it, so the
// session is between the client and the driver, and reaches only the
// partition. A post whose partition is not on the disk refuses every CONNECT
// (.Err_Not_Found). The table is read once; a disk repartitioned under a
// running partd is not seen until it starts again.
package partd

import vx "abi:vx"
import "vx:driver"
import "vx:gpt"
import "vx:memory"
import "vx:ndb"
import "vx:p9"
import "vx:ring"
import "vx:rt"
import "vx:str"

MAX_PARTS :: 8
MAX_POST :: 31

Served :: struct {
	post:         [dynamic; MAX_POST]u8,
	listen:       vx.Handle, // the claimed post's server end
	found:        bool,
	first, count: u64, // the partition's window, in the disk's sectors
	armed:        bool,
}

parts: [dynamic; MAX_PARTS]Served
disk, port: vx.Handle
disk_name: string
table: gpt.Gpt // large: static storage

fail :: proc(what: string) -> ! {
	rt.print("partd: FAILED: ", what, "\n")
	rt.exits(what)
}

// --- Reading the table, through a session of partd's own ---

Reader :: struct {
	ring:      ring.Ring,
	end, port: vx.Handle,
	arena:     []u8,
	max:       u32, // bytes a transfer moves, at most
}

wait_one :: proc "contextless" (r: ^Reader, c: ^vx.Cqe) -> bool {
	deadline := rt.clock_read() + 5_000_000_000
	for {
		if ring.consume(&r.ring, memory.ptr_to_bytes(c)) == .Ok {
			return true
		}
		seen, _ := rt.counter_read(r.end)
		if !ring.prepare_sleep(&r.ring) {
			ring.end_sleep(&r.ring)
			continue
		}
		pk: [1]vx.Packet
		_ = rt.port_bind(r.port, r.end, .Counter_Ge, 1, seen + 1)
		n, _ := rt.port_wait(r.port, deadline, 0, pk[:])
		ring.end_sleep(&r.ring)
		if n != 1 {
			return false
		}
	}
}

call :: proc "contextless" (r: ^Reader, e: vx.Sqe, c: ^vx.Cqe) -> bool {
	e := e
	slot, ok := ring.produce_slot(&r.ring)
	if !ok {
		return false
	}
	copy(slot, memory.ptr_to_bytes(&e))
	if ring.produce(&r.ring) {
		_ = rt.ring_notify(r.end)
	}
	return wait_one(r, c)
}

SECTOR :: 512 // the table is read in no other size yet

read_sectors :: proc "contextless" (ctx: rawptr, lba: u64, buf: []u8) -> bool {
	r := cast(^Reader)ctx
	count := u32(len(buf) / SECTOR)
	for done := u32(0); done < count; {
		n := min(count - done, r.max / SECTOR)
		c: vx.Cqe
		e := vx.Sqe {
			opcode = u16(driver.Block_Op.Read),
			flags  = {.Dref},
			target = lba + u64(done),
			len    = n * SECTOR,
		}
		if !call(r, e, &c) || c.result != i64(n) * SECTOR {
			return false
		}
		copy(buf[done * SECTOR:], r.arena[:n * SECTOR])
		done += n
	}
	return true
}

// The table, or why not.
read_table :: proc(g: ^gpt.Gpt) -> (st: vx.Status) {
	r: Reader
	req := driver.Block_Connect {
		header = {ordinal = driver.BLOCK_CONNECT},
		flags  = {.Readonly},
	}
	r.end = rt.session_dial_with(disk, memory.ptr_to_bytes(&req), driver.BLOCK_PARAMS, &r.ring) or_return
	defer {
		rt.close_all(r.port, r.end)
		rt.session_unmap(&r.ring)
	}
	pst: vx.Status
	if r.port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	r.arena = ring.arena(&r.ring)
	info: vx.Cqe
	if !call(&r, {opcode = u16(driver.Block_Op.Info)}, &info) {
		return .Err_Timed_Out
	}
	if info.aux != SECTOR || info.result < SECTOR {
		return .Err_Unsupported // 4 KiB sectors: when a disk has them
	}
	r.max = u32(min(info.result, driver.BLOCK_ARENA))
	return gpt.read(g, info.aux, info.aux2, read_sectors, &r)
}

// --- The manifest ---

// The disk's connector: the one handle named srv:NAME.
find_disk :: proc() {
	for &h, i in rt.spawn.handles[:rt.spawn.handle_count] {
		n := rt.spawn.handle_names[i]
		if len(n) > 4 && str.has_prefix(n, "srv:") && h != vx.HANDLE_NONE {
			disk_name = n[4:]
			disk = h
			h = vx.HANDLE_NONE
			return
		}
	}
	fail("no connector to a disk (connect=)")
}

matches :: proc(p: ^gpt.Part, rec: ^ndb.Record) -> bool {
	if type, _ := ndb.get(rec, "type"); type != "" {
		guid, ok := gpt.guid(type)
		return ok && guid == p.type
	}
	name, _ := ndb.get(rec, "name")
	return name != "" && string(p.name[:]) == name
}

say_part :: proc(s: ^Served, p: ^gpt.Part) {
	rt.print("partd: /srv/", string(s.post[:]))
	if p == nil {
		rt.print(": no such partition on the disk\n")
		return
	}
	rt.print(" is sectors ", p.first, "-", p.last, " (", string(p.name[:]), ")\n")
}

load_manifest :: proc(g: ^gpt.Gpt) {
	@(static) scratch: [vx.CHANNEL_MAX_BYTES]u8
	r := ndb.Reader{src = rt.spawn.text, scratch = scratch[:]}
	rec: ndb.Record
	for ndb.next(&r, &rec) == .Record {
		if !ndb.has(&rec, "part") {
			continue
		}
		if len(parts) == MAX_PARTS {
			fail("more part= records than partd serves")
		}
		post, _ := ndb.get(&rec, "part")
		s: Served
		if append(&s.post, post) != len(post) {
			fail("a part= record's post name is too long")
		}
		claim_buf: [len("claim:") + MAX_POST]u8
		claim, _ := str.join(claim_buf[:], "claim:", post)
		s.listen = rt.spawn_take(claim)
		if s.listen == vx.HANDLE_NONE {
			fail("a part= record with no claim= for its post")
		}
		found: ^gpt.Part
		if g != nil {
			for &p in g.parts {
				if matches(&p, &rec) {
					found = &p
					break
				}
			}
		}
		if found != nil {
			s.found = true
			s.first = found.first
			s.count = found.last - found.first + 1
		}
		_ = append(&parts, s)
		say_part(&parts[len(parts) - 1], found)
	}
}

// --- Serving ---

// The requests waiting on partition s's post.
serve :: proc(s: ^Served) {
	for {
		req: driver.Block_Connect
		size, st := rt.channel_read(s.listen, memory.ptr_to_bytes(&req))
		if st == .Err_Should_Wait {
			return
		}
		if st == .Err_Peer_Closed {
			fail("a post is gone")
		}
		if st == .Err_Too_Small { // not a request this protocol makes: read it, to be rid of it
			@(static) junk: [vx.CHANNEL_MAX_BYTES]u8
			@(static) junk_handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle
			if jsize, jst := rt.channel_read(s.listen, junk[:], junk_handles[:]); jst == .Ok {
				rt.close_all(..junk_handles[:jsize.handles])
			}
			continue
		}
		if st != .Ok || size.bytes < size_of(vx.Msg_Header) {
			continue
		}
		if size.bytes != size_of(req) || req.header.ordinal != driver.BLOCK_CONNECT {
			rt.session_refuse(s.listen, req.header, .Err_Invalid)
			continue
		}
		if !s.found {
			rt.session_refuse(s.listen, req.header, .Err_Not_Found)
			continue
		}
		// The window, counted in the partition and kept inside it.
		count := req.count
		if count == 0 && req.first < s.count {
			count = s.count - req.first
		}
		if req.first >= s.count || count == 0 || count > s.count - req.first {
			rt.session_refuse(s.listen, req.header, .Err_Range)
			continue
		}
		to := driver.Block_Connect {
			header = {ordinal = driver.BLOCK_CONNECT},
			first  = s.first + req.first,
			count  = count,
			flags  = req.flags,
		}
		got: [2]vx.Handle
		got, st = rt.session_ask_raw(disk, memory.ptr_to_bytes(&to), rt.clock_read() + 5_000_000_000)
		if st != .Ok {
			rt.session_refuse(s.listen, req.header, st)
			continue
		}
		rep := vx.Msg_Header{txid = req.header.txid, ordinal = req.header.ordinal}
		if rt.channel_write(s.listen, memory.ptr_to_bytes(&rep), got[:]) != .Ok { // the client gave up: let it go
			rt.close_all(..got[:])
		}
	}
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	find_disk()
	pst: vx.Status
	if port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	st := read_table(&table)
	rt.print("partd: /srv/", disk_name)
	if st == .Ok {
		rt.print(": ", u64(len(table.parts)), table.backup ? " partitions, from the backup table: the primary is damaged\n" : " partitions\n")
	} else {
		rt.print(": no partition table it can trust: ", p9.error_text(st), "\n")
	}
	load_manifest(st == .Ok ? &table : nil)
	for {
		for &p, i in parts {
			serve(&p)
			if !p.armed {
				p.armed = rt.port_bind(port, p.listen, .Readable, u64(i)) == .Ok
			}
		}
		pk: [MAX_PARTS]vx.Packet
		n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:n] {
			if p.key < u64(len(parts)) {
				parts[p.key].armed = false
			}
		}
	}
}
