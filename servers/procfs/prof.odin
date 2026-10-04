// /proc/N/prof (upstream docs/05 §9), a process's profiling zones.
//
//   /proc/N/prof/ctl     zones on · zones off
//   /proc/N/prof/zones   the ring as it is now: a prof.Header, then the
//                        records it holds, oldest first (vx:prof)
//
// A process gives procfs its ring with process.PROF (prof.init): procfs maps
// the VMO too, writes a challenge of its own into it, and takes it only if the
// process's memory, at the address it says it maps the ring at, then shows
// that challenge: the proof that the process maps that VMO there. (What the
// sender wrote itself proves nothing: it chose the address, and could name
// bytes another process happens to hold.)
package procfs

import "base:intrinsics"
import vx "abi:vx"
import "vx:prof"
import "vx:process"
import "vx:rt"

@(private="file")
rings: [MAX_PROCS]^prof.Header // each process's, mapped here; nil if none
@(private="file")
PROF_SLOTS :: u32((prof.RING - size_of(prof.Header)) / size_of(prof.Record))

@(private)
prof_forget :: proc "contextless" (p: ^Proc) {
	if r := rings[p.slot]; r != nil {
		_ = rt.as_unmap(rt.self, u64(uintptr(r)), prof.RING)
	}
	rings[p.slot] = nil
}

@(private="file")
challenges: u64

@(private, require_results)
prof_register :: proc "contextless" (m: ^process.Msg, vmo: vx.Handle) -> vx.Status {
	p := by_pid(u64(m.arg[0]))
	at: u64
	st := vx.Status.Err_Not_Found
	if p != nil {
		at, st = rt.as_map(rt.self, vmo, 0, prof.RING, {.Write})
	}
	_ = rt.handle_close(vmo)
	st or_return
	h := (^prof.Header)(uintptr(at))
	challenges += 1
	challenge := (rt.cycles() ~ (challenges * 0x9e37_79b9_7f4a_7c15)) | 1
	h.nonce = challenge
	theirs: u64
	st = mem_rw(p, u64(m.arg[1]) + u64(offset_of(prof.Header, nonce)), ptr_bytes(&theirs), false)
	if st != .Ok || h.magic != prof.MAGIC || theirs != challenge {
		_ = rt.as_unmap(rt.self, at, prof.RING)
		return .Err_Access // not that process's ring
	}
	prof_forget(p)
	rings[p.slot] = h
	return .Ok
}

@(private, require_results)
prof_ctl :: proc "contextless" (p: ^Proc, cmd: string) -> vx.Status {
	h := rings[p.slot]
	if h == nil {
		return .Err_Not_Found // it has no ring (it never called prof.init)
	}
	switch cmd {
	case "zones on":
		intrinsics.atomic_store_explicit(&h.enabled, 1, .Relaxed)
	case "zones off":
		intrinsics.atomic_store_explicit(&h.enabled, 0, .Relaxed)
	case:
		return .Err_Invalid
	}
	return .Ok
}

// The ring, as it is now: its header, then its records in order. The process
// still writes the header, so what it says is read once and held to the
// ring's size: a cap or head it changed gives it nonsense, not procfs a fault.
@(private)
prof_snapshot :: proc "contextless" (p: ^Proc) -> []u8 {
	@(static) snap: struct {
		header:  prof.Header,
		records: [PROF_SLOTS]prof.Record,
	}
	h := rings[p.slot]
	if h == nil {
		return nil
	}
	snap.header = h^
	head := intrinsics.atomic_load_explicit(&h.head, .Acquire)
	ring := snap.header.cap
	if ring == 0 || ring > PROF_SLOTS {
		ring = PROF_SLOTS
	}
	snap.header.cap = ring
	n := min(head, u64(ring))
	first := head - n
	recs := ([^]prof.Record)(intrinsics.ptr_offset(h, 1))[:ring]
	for i in 0 ..< n {
		snap.records[i] = recs[(first + i) % u64(ring)]
	}
	return ptr_bytes(&snap)[:size_of(prof.Header) + int(n) * size_of(prof.Record)]
}
