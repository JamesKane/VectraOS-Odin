// lib/prof on the host (upstream has no host test for vx-prof), linked
// against lib/rt with a fake kernel underneath: this file defines vx_syscall,
// so init's VMO "maps" a buffer of the test's own, the clock reports its
// frequency, and the call to procfs is checked and answered here. Zones are
// off until the reader turns them on; then each zone that ends leaves a
// record naming it, and the ring keeps the last `cap` of them.
//
// The ring is the library's one global, so this is one test.
package prof_test

import vx "abi:vx"
import "core:testing"
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
	testing.expect_value(t, h.version, 1)
	testing.expect_value(t, h.counter_hz, 1_000_000_000)
	testing.expect_value(t, h.cap, u32((prof.RING - size_of(prof.Header)) / size_of(prof.Record)))
	// procfs was given the ring: PROF, the pid and the address, and the VMO.
	testing.expect_value(t, call_seen.header.ordinal, process.PROF)
	testing.expect_value(t, call_seen.arg[0], PID)
	testing.expect_value(t, call_seen.arg[1], i64(uintptr(&ring[0])))
	testing.expect_value(t, call_handle, DUP)

	testing.expect_value(t, prof.begin(&work), 0) // zones off
	prof.end(&work, 0)
	testing.expect_value(t, h.head, 0)

	h.enabled = 1 // ctl's "zones on"
	start := prof.begin(&work)
	testing.expect(t, start != 0)
	prof.end(&work, start)
	testing.expect_value(t, h.head, 1)
	testing.expect_value(t, h.nzones, 1)
	testing.expect_value(t, string(h.names[0][:4]), "work")
	r := prof.records(h)[0]
	testing.expect_value(t, r.zone, 1)
	testing.expect_value(t, r.start, start)
	testing.expect(t, r.end >= r.start)

	// A name longer than the ring's slot is cut to leave a NUL.
	long := prof.Zone {
		name = "a zone with a name much longer than thirty-two bytes",
	}
	prof.end(&long, prof.begin(&long))
	testing.expect_value(t, long.id, 2)
	testing.expect_value(t, string(h.names[1][:prof.NAME - 1]), long.name[:prof.NAME - 1])
	testing.expect_value(t, h.names[1][prof.NAME - 1], 0)

	// The ring wraps: the record after `cap` of them overwrites the first.
	for _ in 0 ..< h.cap {
		prof.end(&work, prof.begin(&work))
	}
	testing.expect_value(t, h.head, u64(h.cap) + 2)
	testing.expect_value(t, prof.records(h)[0].zone, 1)
	testing.expect_value(t, prof.records(h)[1].zone, 1)

	testing.expect_value(t, prof.init(PROCFS), vx.Status.Ok) // once is enough
}
