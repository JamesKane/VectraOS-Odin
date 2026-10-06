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
import "vx:memory"

// Which end of the ring a side is: the client produces submissions and
// consumes completions; the server the opposite.
Side :: enum u8 {
	Client,
	Server,
}

// One queue as one side sees it. Its tail line belongs to the producer and
// its head line to the consumer, NEED_WAKEUP included (flags), so each side
// writes only its own.
Queue :: struct {
	tail:    ^u32,
	head:    ^u32,
	flags:   ^u32, // the consumer's NEED_WAKEUP
	entries: []u8,
	mask:    u32,
	size:    u32, // of one entry
	local:   u32, // this side's own index: the tail if it produces, the head if it consumes
}

// A zeroed Ring is one that failed to attach: every operation on it fails.
Ring :: struct {
	memory: []u8, // the mapping, as long as the header says the ring is
	h:      vx.Ring_Header, // the validated copy; the one in shared memory is never read again
	side:   Side,
	intact: bool, // attached, and the peer has kept to the protocol; once false, every call fails
	prod:   Queue, // the queue this side produces into
	cons:   Queue, // and the one it consumes
}

@(private="file")
is_pow2 :: proc "contextless" (n: u32) -> bool {
	return n != 0 && n & (n - 1) == 0
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
	h.client_arena_offset, _ = memory.page_round(h.cq_offset + u64(h.cq_entries) * u64(h.cqe_size))
	h.client_arena_size, _ = memory.page_round(u64(p.client_arena))
	h.server_arena_offset = h.client_arena_offset + h.client_arena_size
	h.server_arena_size, _ = memory.page_round(u64(p.server_arena))
	h.size = h.server_arena_offset + h.server_arena_size
	return h, .Ok
}

// Attaches to a ring mapped as `mapping` as one side. The header must be
// exactly what layout makes of `expect`, the parameters this side's protocol
// uses: whoever made the ring may be hostile, and entry sizes and queue
// lengths decide how much each consume copies into the caller's buffer.
// Takes the indices as they stand: a side attaches before it uses the ring.
@(require_results)
attach :: proc "contextless" (r: ^Ring, mapping: []u8, side: Side, expect: vx.Ring_Params) -> vx.Status {
	r^ = {} // after a failed attach, every operation fails
	if len(mapping) < size_of(vx.Ring_Header) {
		return .Err_Invalid // too small to hold even the header, let alone the ring it describes
	}
	h := intrinsics.unaligned_load((^vx.Ring_Header)(raw_data(mapping))) // one read of hostile memory
	want, status := layout(expect)
	if status != .Ok || h != want || h.size > u64(len(mapping)) {
		return .Err_Invalid
	}

	// The header matched layout's, so every offset below lies inside h.size.
	m := mapping[:h.size]
	lines := (^[vx.Ring_Line]vx.Ring_Index)(&m[vx.RING_INDEX_OFFSET])
	queue :: proc "contextless" (lines: ^[vx.Ring_Line]vx.Ring_Index, tail, head: vx.Ring_Line, entries: []u8, count, size: u32) -> Queue {
		return {tail = &lines[tail].index, head = &lines[head].index, flags = &lines[head].flags, entries = entries, mask = count - 1, size = size}
	}
	sq := queue(lines, .Sq_Tail, .Sq_Head, m[h.sq_offset:][:u64(h.sq_entries) * u64(h.sqe_size)], h.sq_entries, h.sqe_size)
	cq := queue(lines, .Cq_Tail, .Cq_Head, m[h.cq_offset:][:u64(h.cq_entries) * u64(h.cqe_size)], h.cq_entries, h.cqe_size)
	r^ = {
		memory = m,
		h      = h,
		side   = side,
		intact = true,
		prod   = sq if side == .Client else cq,
		cons   = cq if side == .Client else sq,
	}
	r.prod.local = intrinsics.atomic_load_explicit(r.prod.tail, .Relaxed)
	r.cons.local = intrinsics.atomic_load_explicit(r.cons.head, .Relaxed)
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
	q := &r.prod
	head := intrinsics.atomic_load_explicit(q.head, .Acquire)
	used := q.local - head // indices run free, so this wraps as they do
	if used > q.mask + 1 { // the peer's head ran past our tail
		r.intact = false
		return nil, false
	}
	if used == q.mask + 1 {
		return nil, false
	}
	return q.entries[(q.local & q.mask) * q.size:][:q.size], true
}

// Publishes the entry produce_slot gave. Returns true if the peer is asleep,
// and its doorbell must be rung (ring_notify).
produce :: proc "contextless" (r: ^Ring) -> bool {
	q := &r.prod
	q.local += 1
	intrinsics.atomic_store_explicit(q.tail, q.local, .Release)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	return intrinsics.atomic_load_explicit(q.flags, .Relaxed) & vx.RING_NEED_WAKEUP != 0
}

// How many entries the peer has consumed of what this side produced: the
// head of the queue this side produces into, as a running count.
peer_consumed :: proc "contextless" (r: ^Ring) -> u32 {
	return intrinsics.atomic_load_explicit(r.prod.head, .Acquire)
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
	q := &r.cons
	tail := intrinsics.atomic_load_explicit(q.tail, .Acquire)
	ready := tail - q.local
	if ready == 0 {
		return .Err_Should_Wait
	}
	if ready > q.mask + 1 { // the peer's tail ran ahead of what fits
		r.intact = false
		return .Err_Bad_State
	}
	copy(out[:q.size], q.entries[(q.local & q.mask) * q.size:][:q.size])
	q.local += 1
	intrinsics.atomic_store_explicit(q.head, q.local, .Release)
	return .Ok
}

// About to sleep: announces it, then looks once more. Returns true if the
// queue is still empty, and the caller may sleep until its doorbell rings;
// false if an entry arrived meanwhile (and the announcement is withdrawn).
@(require_results)
prepare_sleep :: proc "contextless" (r: ^Ring) -> bool {
	q := &r.cons
	intrinsics.atomic_store_explicit(q.flags, vx.RING_NEED_WAKEUP, .Relaxed)
	intrinsics.atomic_thread_fence(.Seq_Cst)
	if intrinsics.atomic_load_explicit(q.tail, .Acquire) != q.local {
		intrinsics.atomic_store_explicit(q.flags, 0, .Relaxed)
		return false
	}
	return true
}

// Awake again: the peer need not ring until the next prepare_sleep.
end_sleep :: proc "contextless" (r: ^Ring) {
	intrinsics.atomic_store_explicit(r.cons.flags, 0, .Relaxed)
}

// --- Arenas ---

// This side's arena, where it puts payloads for the peer to read.
arena :: proc "contextless" (r: ^Ring) -> []u8 {
	client := r.side == .Client
	offset := r.h.client_arena_offset if client else r.h.server_arena_offset
	size := r.h.client_arena_size if client else r.h.server_arena_size
	return r.memory[offset:][:size]
}

// [offset, offset + length) of the peer's arena, or ok false if an entry named a
// range outside it. The bytes are still shared: copy them out once.
@(require_results)
peer_bytes :: proc "contextless" (r: ^Ring, offset, length: u64) -> (bytes: []u8, ok: bool) {
	client := r.side == .Client
	size := r.h.server_arena_size if client else r.h.client_arena_size
	if r.memory == nil || offset > size || length > size - offset { // in that order, so nothing overflows
		return nil, false
	}
	start := r.h.server_arena_offset if client else r.h.client_arena_offset
	return r.memory[start + offset:][:length], true
}
