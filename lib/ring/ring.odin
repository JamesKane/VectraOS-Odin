// The ring protocol (upstream 01 §4.3). Pure memory operations, no syscalls,
// so the kernel, user space and the host tests share it; the caller rings
// doorbells (ring_notify) and sleeps (port_wait) when this says to.
//
// Each side produces into one queue and consumes from the other: the client
// produces submissions (SQ) and consumes completions (CQ); the server does the
// opposite. Each queue has one producer and one consumer, so both are
// wait-free. A side writes only its own lines and its own arena.
//
// The wake protocol, model-checked by lib/check (tests/host/check):
//
//   producer: write entry; tail.store(release); fence(seq_cst);
//             if the consumer's flags hold NEED_WAKEUP, ring its doorbell
//   consumer: before sleeping: flags.store(NEED_WAKEUP); fence(seq_cst);
//             recheck the tail; sleep only if still empty
//
// One of the two fences always sees the other side's store, so a wake-up is
// never lost (the store-buffer litmus test). With both sides busy, nothing
// enters the kernel.
//
// Shared memory is hostile (upstream 01 §4.3): the header is validated once
// and used only from a private copy, each entry is copied out exactly once,
// and an index that runs ahead of the other marks the ring broken.
package ring

import "base:intrinsics"
import vx "abi:vx"

// A zeroed Ring is one that failed to attach: every operation on it fails.
Ring :: struct {
	memory: []u8, // the mapping, as long as the header says the ring is
	h:      vx.Ring_Header, // the validated copy; the one in shared memory is never read again
	client: bool,
	intact: bool, // attached, and the peer has kept to the protocol; once false, every call fails

	// The queue this side produces into.
	out_tail:       ^u32, // ours
	out_head:       ^u32, // the peer's
	out_flags:      ^u32, // the peer's NEED_WAKEUP
	out_entries:    []u8,
	out_mask:       u32,
	out_size:       u32,
	out_tail_local: u32,

	// The queue this side consumes.
	in_tail:       ^u32, // the peer's
	in_head:       ^u32, // ours
	in_flags:      ^u32, // ours
	in_entries:    []u8,
	in_mask:       u32,
	in_size:       u32,
	in_head_local: u32,
}

@(private="file")
is_pow2 :: proc "contextless" (n: u32) -> bool {
	return n != 0 && n & (n - 1) == 0
}

@(private="file")
page_up :: proc "contextless" (v: u64) -> u64 {
	return (v + 4095) &~ 4095
}

// The layout for these parameters: the header the kernel writes into a new
// ring. .Err_Invalid for queue lengths that are not powers of two from 1 to
// 4096, or entry sizes that are not multiples of 16 up to 256; .Err_Range for
// an arena over 1 GiB. Those bounds come first and keep every sum below
// 2^32, so none of the arithmetic after them can overflow.
@(require_results)
layout :: proc "contextless" (p: vx.Ring_Params) -> (h: vx.Ring_Header, status: vx.Status) {
	if !is_pow2(p.sq_entries) || !is_pow2(p.cq_entries) || p.sq_entries > 4096 || p.cq_entries > 4096 {
		return {}, .Err_Invalid
	}
	if p.sqe_size == 0 || p.cqe_size == 0 || p.sqe_size % 16 != 0 || p.cqe_size % 16 != 0 || p.sqe_size > 256 || p.cqe_size > 256 {
		return {}, .Err_Invalid
	}
	if p.client_arena > 1 << 30 || p.server_arena > 1 << 30 {
		return {}, .Err_Range
	}
	h = {
		magic      = vx.RING_MAGIC,
		version    = vx.RING_VERSION,
		sq_entries = p.sq_entries,
		cq_entries = p.cq_entries,
		sqe_size   = p.sqe_size,
		cqe_size   = p.cqe_size,
		sq_offset  = vx.RING_INDEX_OFFSET + 4096,
	}
	h.cq_offset = (h.sq_offset + u64(h.sq_entries) * u64(h.sqe_size) + 63) &~ 63
	h.client_arena_offset = page_up(h.cq_offset + u64(h.cq_entries) * u64(h.cqe_size))
	h.client_arena_size = page_up(p.client_arena)
	h.server_arena_offset = h.client_arena_offset + h.client_arena_size
	h.server_arena_size = page_up(p.server_arena)
	h.size = h.server_arena_offset + h.server_arena_size
	return h, .Ok
}

// Attaches to a ring mapped as `memory` as the client or the server. The
// header is checked against what layout would have made, so a peer that
// rewrote it is caught here. Takes the indices as they stand: a side attaches
// before it uses the ring.
@(require_results)
attach :: proc "contextless" (r: ^Ring, memory: []u8, client: bool) -> vx.Status {
	r^ = {} // after a failed attach, every operation fails
	if len(memory) < size_of(vx.Ring_Header) {
		return .Err_Invalid // too small to hold even the header, let alone the ring it describes
	}
	h: vx.Ring_Header
	intrinsics.mem_copy_non_overlapping(&h, raw_data(memory), size_of(h))
	p := vx.Ring_Params {
		sq_entries   = h.sq_entries,
		cq_entries   = h.cq_entries,
		sqe_size     = h.sqe_size,
		cqe_size     = h.cqe_size,
		client_arena = h.client_arena_size,
		server_arena = h.server_arena_size,
	}
	want, status := layout(p)
	if h.magic != vx.RING_MAGIC || h.version != vx.RING_VERSION || status != .Ok || h != want || h.size > u64(len(memory)) {
		return .Err_Invalid
	}

	// The header matched layout's, so every offset below lies inside h.size.
	m := memory[:h.size]
	lines := (^[vx.Ring_Line]vx.Ring_Index)(&m[vx.RING_INDEX_OFFSET])
	out_tail, out_head := vx.Ring_Line.Sq_Tail, vx.Ring_Line.Sq_Head
	in_tail, in_head := vx.Ring_Line.Cq_Tail, vx.Ring_Line.Cq_Head
	if !client {
		out_tail, out_head, in_tail, in_head = in_tail, in_head, out_tail, out_head
	}
	sq := m[h.sq_offset:][:u64(h.sq_entries) * u64(h.sqe_size)]
	cq := m[h.cq_offset:][:u64(h.cq_entries) * u64(h.cqe_size)]
	r^ = {
		memory = m,
		h      = h,
		client = client,
		intact = true,
	}
	r.out_tail = &lines[out_tail].index
	r.out_head = &lines[out_head].index
	r.out_flags = &lines[out_head].flags
	r.out_entries = sq if client else cq
	r.out_mask = (h.sq_entries if client else h.cq_entries) - 1
	r.out_size = h.sqe_size if client else h.cqe_size
	r.out_tail_local = intrinsics.atomic_load_explicit(r.out_tail, .Relaxed)
	r.in_tail = &lines[in_tail].index
	r.in_head = &lines[in_head].index
	r.in_flags = &lines[in_head].flags
	r.in_entries = cq if client else sq
	r.in_mask = (h.cq_entries if client else h.sq_entries) - 1
	r.in_size = h.cqe_size if client else h.sqe_size
	r.in_head_local = intrinsics.atomic_load_explicit(r.in_head, .Relaxed)
	return .Ok
}

// --- Producing ---

// The next free entry to fill (the entry size bytes), or ok false if the
// queue is full or the ring is broken. Nothing is visible to the peer until
// produce.
@(require_results)
produce_slot :: proc "contextless" (r: ^Ring) -> (entry: []u8, ok: bool) {
	if !r.intact {
		return nil, false
	}
	head := intrinsics.atomic_load_explicit(r.out_head, .Acquire)
	used := r.out_tail_local - head // indices run free, so this wraps as they do
	if used > r.out_mask + 1 { // the peer's head ran past our tail
		r.intact = false
		return nil, false
	}
	if used == r.out_mask + 1 {
		return nil, false
	}
	return r.out_entries[(r.out_tail_local & r.out_mask) * r.out_size:][:r.out_size], true
}

// Publishes the entry produce_slot gave. Returns true if the peer is asleep,
// and its doorbell must be rung (ring_notify).
produce :: proc "contextless" (r: ^Ring) -> bool {
	r.out_tail_local += 1
	intrinsics.atomic_store_explicit(r.out_tail, r.out_tail_local, .Release)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	return intrinsics.atomic_load_explicit(r.out_flags, .Relaxed) & vx.RING_NEED_WAKEUP != 0
}

// --- Consuming ---

// Copies the next entry into out (the entry size bytes, which out must hold)
// and frees its slot. .Err_Should_Wait if the queue is empty; .Err_Bad_State
// once the peer has broken the protocol, which the caller treats as the peer
// going away.
@(require_results)
consume :: proc "contextless" (r: ^Ring, out: []u8) -> vx.Status {
	if !r.intact {
		return .Err_Bad_State
	}
	tail := intrinsics.atomic_load_explicit(r.in_tail, .Acquire)
	ready := tail - r.in_head_local
	if ready == 0 {
		return .Err_Should_Wait
	}
	if ready > r.in_mask + 1 { // the peer's tail ran ahead of what fits
		r.intact = false
		return .Err_Bad_State
	}
	copy(out[:r.in_size], r.in_entries[(r.in_head_local & r.in_mask) * r.in_size:][:r.in_size])
	r.in_head_local += 1
	intrinsics.atomic_store_explicit(r.in_head, r.in_head_local, .Release)
	return .Ok
}

// About to sleep: announces it, then looks once more. Returns true if the
// queue is still empty, and the caller may sleep until its doorbell rings;
// false if an entry arrived meanwhile (and the announcement is withdrawn).
@(require_results)
prepare_sleep :: proc "contextless" (r: ^Ring) -> bool {
	intrinsics.atomic_store_explicit(r.in_flags, vx.RING_NEED_WAKEUP, .Relaxed)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	if intrinsics.atomic_load_explicit(r.in_tail, .Acquire) != r.in_head_local {
		intrinsics.atomic_store_explicit(r.in_flags, 0, .Relaxed)
		return false
	}
	return true
}

// Awake again: the peer need not ring until the next prepare_sleep.
end_sleep :: proc "contextless" (r: ^Ring) {
	intrinsics.atomic_store_explicit(r.in_flags, 0, .Relaxed)
}

// --- Arenas ---

// This side's arena, where it puts payloads for the peer to read.
arena :: proc "contextless" (r: ^Ring) -> []u8 {
	offset := r.h.client_arena_offset if r.client else r.h.server_arena_offset
	size := r.h.client_arena_size if r.client else r.h.server_arena_size
	return r.memory[offset:][:size]
}

// [offset, offset + length) of the peer's arena, or ok false if an entry named a
// range outside it. The bytes are still shared: copy them out once.
@(require_results)
peer_bytes :: proc "contextless" (r: ^Ring, offset, length: u64) -> (bytes: []u8, ok: bool) {
	size := r.h.server_arena_size if r.client else r.h.client_arena_size
	if r.memory == nil || offset > size || length > size - offset { // in that order, so nothing overflows
		return nil, false
	}
	start := r.h.server_arena_offset if r.client else r.h.client_arena_offset
	return r.memory[start + offset:][:length], true
}
