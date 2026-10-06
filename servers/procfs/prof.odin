// /proc/N/prof (upstream docs/05 §9), a process's profiling zones.
//
//   /proc/N/prof/ctl     zones on · zones off
//   /proc/N/prof/zones   the rings as they are now: a prof.Header, then
//                        every thread's records, merged oldest first by
//                        their end (vx:prof)
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

@(private="file")
N_RINGS :: prof.THREADS + 1

// The rings, as they are now: the header, then every ring's records merged
// oldest first by their end (each thread's ring is in that order already;
// ring 0, shared, nearly). The process still writes all of it, so what it
// says is read once and held to the VMO's layout: a head it changed gives
// it nonsense, not procfs a fault; and a record its thread may have been
// writing over while it was copied is left out (upstream's 6d6b).
@(private)
prof_snapshot :: proc "contextless" (p: ^Proc) -> []u8 {
	@(static) all: [N_RINGS * prof.CAP]prof.Record // each ring's, oldest first, at i * CAP
	@(static) snap: struct {
		header:  prof.Header,
		records: [N_RINGS * prof.CAP]prof.Record,
	}
	#assert(size_of(snap) <= prof.RING) // as upstream's, which holds the file to the VMO's size
	h := rings[p.slot]
	if h == nil {
		return nil
	}
	snap.header = h^
	from, to: [N_RINGS]u32
	for i in u32(0) ..< N_RINGS {
		r := prof.ring_at(h, i)
		head := intrinsics.atomic_load_explicit(&r.head, .Acquire)
		n := min(head, u64(prof.CAP))
		first := head - n
		base := i * prof.CAP
		for k in u64(0) ..< n {
			all[u64(base) + k] = prof.ring_records(r)[(first + k) % u64(prof.CAP)]
		}
		after := intrinsics.atomic_load_explicit(&r.head, .Acquire) // what was written meanwhile
		lost := after > head ? after - head : 0 // over the oldest ones
		if after < head {
			lost = n // a head it set back: nothing trusted
		}
		from[i], to[i] = base + u32(min(lost, n)), base + u32(n)
	}
	written := 0
	for ; written < len(snap.records); written += 1 { // the earliest end among them
		best := -1
		for i in 0 ..< N_RINGS {
			if from[i] < to[i] && (best < 0 || all[from[i]].end < all[from[best]].end) {
				best = i
			}
		}
		if best < 0 {
			break
		}
		snap.records[written] = all[from[best]]
		from[best] += 1
	}
	snap.header.head = u64(written)
	snap.header.cap, snap.header.rings = u32(written), 0
	return ptr_bytes(&snap)[:size_of(prof.Header) + written * size_of(prof.Record)]
}
