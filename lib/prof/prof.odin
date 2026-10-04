// vx:prof, profiling zones (upstream docs/05 §9). A zone times a block of
// code in cycles, with no system call:
//
//	work := prof.Zone{name = "work"} // a global, or otherwise long-lived
//	t := prof.begin(&work)
//	...
//	prof.end(&work, t)
//
// Each zone that ends writes a record (its start and end on the cycle
// counter, its zone, its thread) into a ring in a VMO the process shares with
// procfs. Zones are off until a reader writes "zones on" to /proc/N/prof/ctl;
// off, a zone costs one predictable branch. /proc/N/prof/zones reads the
// ring: a Header, the zones' names, then the records, oldest first.
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
RING :: u64(64 * 1024)

Record :: struct {
	start, end: u64, // on the cycle counter
	zone:       u32, // from 1: names[zone - 1]
	thread:     u32,
}

#assert(size_of(Record) == 24)

// The start of the shared ring, and of what /proc/N/prof/zones reads.
// enabled, nzones and head are read and written atomically.
Header :: struct {
	magic, version: u32,
	counter_hz:     u64, // /sys/clock/info's
	nonce:          u64, // procfs's challenge, read back through the task's memory
	enabled:        u32, // set by procfs: ctl's "zones on"
	nzones:         u32,
	head:           u64, // records written, ever: the ring holds the last `cap` of them
	cap, reserved:  u32,
	names:          [ZONES][NAME]u8,
}

#assert(size_of(Header) == 48 + ZONES * NAME)
#assert(offset_of(Header, head) == 32)
#assert(offset_of(Header, names) == 48)

Zone :: struct {
	name: string,
	id:   u32, // from 1, once it has a name in the ring
}

// The process's ring, once procfs has taken it.
@(private="file")
ring: ^Header

// The records that follow h in a ring of RING bytes.
records :: proc "contextless" (h: ^Header) -> []Record {
	return ([^]Record)(intrinsics.ptr_offset(h, 1))[:h.cap]
}

// Writes a fresh header at the start of a ring of RING bytes.
@(private="file")
format :: proc "contextless" (h: ^Header, counter_hz: u64) {
	h^ = {
		magic      = MAGIC,
		version    = 1,
		counter_hz = counter_hz,
		cap        = u32((RING - size_of(Header)) / size_of(Record)),
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
	slot := intrinsics.atomic_add_explicit(&ring.head, 1, .Release)
	records(ring)[slot % u64(ring.cap)] = {
		start  = start,
		end    = stop,
		zone   = id,
		thread = 1,
	}
}
