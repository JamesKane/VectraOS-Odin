// vx:prof, profiling zones (upstream docs/05 §9). A zone times a block of
// code in cycles, with no system call:
//
//	work := prof.Zone{name = "work"} // a global, or otherwise long-lived
//	t := prof.begin(&work)
//	...
//	prof.end(&work, t)
//
// Each zone that ends writes a record (its start and end on the cycle
// counter, its zone, its thread) into the ring of the thread it ran on, in a
// VMO the process shares with procfs (upstream's M6 step 6d6b): a thread
// claims a ring of its own the first time it records, and writes it alone,
// so threads share no ring and no counter; past THREADS of them, the rest
// share ring 0, which counts its records atomically. Zones are off until a
// reader writes "zones on" to /proc/N/prof/ctl; off, a zone costs one
// predictable branch. /proc/N/prof/zones reads them: a Header, the zones'
// names, then every ring's records, merged oldest first by their end.
// /sys/clock/info's frequency (in the header too) turns cycles into time.
//
// init(connector) makes the ring and gives it to procfs, through its listen
// channel (a connector to /proc), as process.PROF: the ring's address. procfs
// writes a challenge into the ring and reads it back through the task's
// memory at that address, so no process can give procfs a ring for another.
package prof

import "base:intrinsics"
import vx "abi:vx"
import "vx:process"
import "vx:rt"

MAGIC :: u32(0x666f_7270) // "prof"
ZONES :: 64
NAME :: 32
// The VMO: the header's page, then rings: ring 0, shared, then one each for
// the first THREADS threads that record.
THREADS :: 32
RING_BYTES :: u64(32 * 1024)
HEADER_BYTES :: u64(4096)
RING :: HEADER_BYTES + (THREADS + 1) * RING_BYTES

Record :: struct {
	start, end: u64, // on the cycle counter
	zone:       u32, // from 1: names[zone - 1]
	thread:     u32, // the kernel's id for it (/proc/N/threads)
}

#assert(size_of(Record) == 24)

// The start of the shared VMO, and of what /proc/N/prof/zones reads, where
// head and cap say how many records follow. enabled, nzones and head are
// read and written atomically.
Header :: struct {
	magic, version: u32,
	counter_hz:     u64, // /sys/clock/info's
	nonce:          u64, // procfs's challenge, read back through the task's memory
	enabled:        u32, // set by procfs: ctl's "zones on"
	nzones:         u32,
	head:           u64, // in the VMO, rings claimed; in the file, the records that follow
	cap, rings:     u32, // records each ring holds; rings (in the file: records, and 0)
	names:          [ZONES][NAME]u8,
}

#assert(size_of(Header) == 48 + ZONES * NAME)
#assert(offset_of(Header, head) == 32)
#assert(offset_of(Header, names) == 48)
#assert(size_of(Header) <= HEADER_BYTES)

// A ring, then its records: written by its thread alone (head stored after
// each record; a reader takes what head says, less any it may have been
// overwriting meanwhile), or, ring 0, by any (head counted atomically).
// thread and head are read and written atomically.
Ring :: struct {
	thread:   u32, // its owner's id; 0 for ring 0
	reserved: u32,
	head:     u64, // records written, ever: it holds the last CAP of them
}

#assert(size_of(Ring) == 16)

// The records a ring holds.
CAP :: u32((RING_BYTES - size_of(Ring)) / size_of(Record))

Zone :: struct {
	name: string,
	id:   u32, // from 1, once it has a name in the ring
}

// The process's VMO, once procfs has taken it.
@(private="file")
ring: ^Header
// This thread's ring, once it has one, and its id.
@(private="file", thread_local)
mine: ^Ring
@(private="file", thread_local)
my_id: u32

// The process's VMO, once procfs has taken it (init); nil before.
header :: proc "contextless" () -> ^Header {
	return ring
}

// Ring i (0 ..= THREADS) of the VMO of RING bytes h starts.
ring_at :: proc "contextless" (h: ^Header, i: u32) -> ^Ring {
	return (^Ring)(uintptr(h) + uintptr(HEADER_BYTES + u64(min(i, THREADS)) * RING_BYTES))
}

// The records that follow r in its ring.
ring_records :: proc "contextless" (r: ^Ring) -> []Record {
	return ([^]Record)(intrinsics.ptr_offset(r, 1))[:CAP]
}

// Writes a fresh header at the start of a ring of RING bytes.
@(private="file")
format :: proc "contextless" (h: ^Header, counter_hz: u64) {
	h^ = {
		magic      = MAGIC,
		version    = 2,
		counter_hz = counter_hz,
		cap        = CAP,
		rings      = THREADS + 1,
	}
}

// Makes the ring and gives it to procfs (connector: to its listen channel).
@(require_results)
init :: proc "contextless" (connector: vx.Handle) -> vx.Status {
	if ring != nil {
		return .Ok
	}
	vmo := rt.vmo_create(RING) or_return
	at, st := rt.as_map(rt.self, vmo, 0, RING, {.Write})
	dup: vx.Handle
	if st == .Ok {
		dup, st = rt.handle_dup(vmo, vx.RIGHTS_SAME)
	}
	_ = rt.handle_close(vmo)
	if st != .Ok {
		return st
	}
	clock, _ := rt.clock_info() // /sys/clock/info's: the clock and the cycle counter it is made from
	h := (^Header)(uintptr(at))
	format(h, clock.counter_hz)
	me, _ := rt.task_info(rt.self)
	req := process.Msg {
		header = {ordinal = process.PROF},
		arg = {i64(me.id), i64(at), 0},
	}
	rep: process.Msg
	c := vx.Call {
		wr_bytes   = &req,
		wr_len     = size_of(req),
		wr_handles = &dup,
		wr_count   = 1,
		rd_bytes   = &rep,
		rd_cap     = size_of(rep),
	}
	rt.channel_call(connector, &c, rt.clock_read() + 2_000_000_000) or_return
	process.reply_status(&rep) or_return
	ring = h
	return .Ok
}

// The zone's number, given it a name in the ring the first time; 0 if the
// ring has no room for another.
@(private="file")
zone_id :: proc "contextless" (z: ^Zone) -> u32 {
	if z.id != 0 {
		return z.id
	}
	n := intrinsics.atomic_add_explicit(&ring.nzones, 1, .Relaxed)
	if n >= ZONES {
		return 0 // no room: not recorded
	}
	copy(ring.names[n][:NAME - 1], z.name)
	z.id = n + 1
	return z.id
}

// A zone starts: the cycle counter, or 0 if zones are off.
begin :: #force_inline proc "contextless" (z: ^Zone) -> u64 {
	if intrinsics.expect(ring == nil || intrinsics.atomic_load_explicit(&ring.enabled, .Relaxed) == 0, true) {
		return 0
	}
	return u64(intrinsics.read_cycle_counter())
}

// This thread's ring: claimed the first time, or ring 0 if none is left.
@(private="file")
ring_of_thread :: proc "contextless" () -> ^Ring {
	if mine != nil {
		return mine
	}
	my_id = rt.thread_self_id()
	n := intrinsics.atomic_add_explicit(&ring.head, 1, .Relaxed)
	r := ring_at(ring, n < THREADS ? u32(n) + 1 : 0)
	if n < THREADS {
		intrinsics.atomic_store_explicit(&r.thread, my_id, .Release)
	}
	mine = r
	return r
}

// A zone ends: its record, if it started with zones on.
end :: #force_inline proc "contextless" (z: ^Zone, start: u64) {
	if intrinsics.expect(start == 0, true) {
		return
	}
	stop := u64(intrinsics.read_cycle_counter())
	id := zone_id(z)
	if id == 0 {
		return
	}
	r := ring_of_thread()
	rec := Record {
		start  = start,
		end    = stop,
		zone   = id,
		thread = my_id,
	}
	if r == ring_at(ring, 0) { // shared: a slot of its own, counted
		slot := intrinsics.atomic_add_explicit(&r.head, 1, .Acq_Rel)
		ring_records(r)[slot % u64(CAP)] = rec
		return
	}
	head := intrinsics.atomic_load_explicit(&r.head, .Relaxed) // its own: no one else writes it
	ring_records(r)[head % u64(CAP)] = rec
	intrinsics.atomic_store_explicit(&r.head, head + 1, .Release)
}
