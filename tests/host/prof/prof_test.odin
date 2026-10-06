// lib/prof on the host (upstream has no host test for vx-prof), linked
// against lib/rt with a fake kernel underneath: this file defines vx_syscall,
// so init's VMO "maps" a buffer of the test's own, the clock reports its
// frequency, and the call to procfs is checked and answered here. Zones are
// off until the reader turns them on; then each zone that ends leaves a
// record naming it in its thread's ring, which keeps the last CAP of them
// (upstream's 6d6b): a thread claims a ring of its own the first time, and
// past THREADS of them the rest share ring 0. On the host every thread's id
// is 1 (vx:rt sets up none of them).
//
// The ring is the library's one global, so this is one test.
package prof_test

import vx "abi:vx"
import "core:testing"
import "core:thread"
import "vx:process"
import "vx:prof"
import "vx:rt"

VMO :: vx.Handle(0x201)
DUP :: vx.Handle(0x202)
PROCFS :: vx.Handle(0x203)
PID :: 77

ring: [prof.RING / 8]u64 // u64s: the header's alignment
call_seen: process.Msg
call_handle: vx.Handle

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	return 0
}

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Vmo_Create:
		(^vx.Handle)(uintptr(a2))^ = VMO
		return 0
	case .As_Map:
		if vx.Handle(a1) != VMO || a3 != prof.RING {
			return i64(vx.Status.Err_Bad_Handle)
		}
		(^u64)(uintptr(a5))^ = u64(uintptr(&ring[0]))
		return 0
	case .Handle_Dup:
		(^vx.Handle)(uintptr(a2))^ = DUP
		return 0
	case .Handle_Close:
		return 0
	case .Clock_Read:
		if a0 != 0 {
			(^u64)(uintptr(a0))^ = 1_000_000_000 // counter_hz
		}
		return 1
	case .Task_Info:
		(^vx.Task_Summary)(uintptr(a1)).id = PID
		return 0
	case .Channel_Call:
		if vx.Handle(a0) != PROCFS {
			return i64(vx.Status.Err_Bad_Handle)
		}
		c := (^vx.Call)(uintptr(a1))
		call_seen = (^process.Msg)(c.wr_bytes)^
		call_handle = c.wr_handles[0]
		(^process.Msg)(c.rd_bytes)^ = {}
		c.actual = {bytes = size_of(process.Msg)}
		return 0
	}
	return i64(vx.Status.Err_Unsupported)
}

@(test)
test_zones :: proc(t: ^testing.T) {
	work := prof.Zone {
		name = "work",
	}
	// No ring yet: a zone costs a branch and records nothing.
	testing.expect_value(t, prof.begin(&work), 0)

	rt.self = vx.Handle(0x101)
	testing.expect_value(t, prof.init(PROCFS), vx.Status.Ok)
	h := (^prof.Header)(&ring[0])
	testing.expect_value(t, h.magic, prof.MAGIC)
	testing.expect_value(t, h.version, 2)
	testing.expect_value(t, h.counter_hz, 1_000_000_000)
	testing.expect_value(t, h.cap, prof.CAP)
	testing.expect_value(t, h.cap, u32((32 * 1024 - 16) / 24))
	testing.expect_value(t, h.rings, prof.THREADS + 1)
	testing.expect_value(t, prof.header(), h)
	// procfs was given the ring: PROF, the pid and the address, and the VMO.
	testing.expect_value(t, call_seen.header.ordinal, process.PROF)
	testing.expect_value(t, call_seen.arg[0], PID)
	testing.expect_value(t, call_seen.arg[1], i64(uintptr(&ring[0])))
	testing.expect_value(t, call_handle, DUP)

	testing.expect_value(t, prof.begin(&work), 0) // zones off
	prof.end(&work, 0)
	testing.expect_value(t, h.head, 0) // no ring claimed

	h.enabled = 1 // ctl's "zones on"
	start := prof.begin(&work)
	testing.expect(t, start != 0)
	prof.end(&work, start)
	testing.expect_value(t, h.head, 1) // this thread's ring claimed: ring 1
	mine := prof.ring_at(h, 1)
	testing.expect_value(t, mine.thread, 1)
	testing.expect_value(t, mine.head, 1)
	testing.expect_value(t, prof.ring_at(h, 0).head, 0)
	testing.expect_value(t, h.nzones, 1)
	testing.expect_value(t, string(h.names[0][:4]), "work")
	r := prof.ring_records(mine)[0]
	testing.expect_value(t, r.zone, 1)
	testing.expect_value(t, r.thread, 1)
	testing.expect_value(t, r.start, start)
	testing.expect(t, r.end >= r.start)
	// The rings' places: after the header's page, 32 KiB each.
	testing.expect_value(t, uintptr(mine) - uintptr(h), 4096 + 32 * 1024)
	testing.expect_value(t, uintptr(prof.ring_at(h, prof.THREADS)) - uintptr(h), uintptr(prof.RING - 32 * 1024))

	// A name longer than the ring's slot is cut to leave a NUL.
	long := prof.Zone {
		name = "a zone with a name much longer than thirty-two bytes",
	}
	prof.end(&long, prof.begin(&long))
	testing.expect_value(t, long.id, 2)
	testing.expect_value(t, string(h.names[1][:prof.NAME - 1]), long.name[:prof.NAME - 1])
	testing.expect_value(t, h.names[1][prof.NAME - 1], 0)

	// The ring wraps: the record after CAP of them overwrites the first.
	for _ in 0 ..< prof.CAP {
		prof.end(&work, prof.begin(&work))
	}
	testing.expect_value(t, mine.head, u64(prof.CAP) + 2)
	testing.expect_value(t, prof.ring_records(mine)[0].zone, 1)
	testing.expect_value(t, prof.ring_records(mine)[1].zone, 1)
	testing.expect_value(t, h.head, 1) // still one ring claimed

	// Another thread claims the next ring; once THREADS are claimed, a new
	// thread shares ring 0, counted there.
	record :: proc() {
		z := prof.Zone {
			name = "other",
		}
		prof.end(&z, prof.begin(&z))
		prof.end(&z, prof.begin(&z))
	}
	th := thread.create_and_start(record)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, h.head, 2)
	testing.expect_value(t, prof.ring_at(h, 2).head, 2)
	testing.expect_value(t, prof.ring_at(h, 2).thread, 1)
	h.head = prof.THREADS // every ring claimed
	th = thread.create_and_start(record)
	thread.join(th)
	thread.destroy(th)
	testing.expect_value(t, prof.ring_at(h, 0).head, 2)
	testing.expect_value(t, prof.ring_at(h, 0).thread, 0) // ring 0 has no owner
	testing.expect_value(t, prof.ring_records(prof.ring_at(h, 0))[1].zone, 4) // its own "other", the fourth zone named

	testing.expect_value(t, prof.init(PROCFS), vx.Status.Ok) // once is enough
}
