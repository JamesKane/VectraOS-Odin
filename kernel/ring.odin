package kernel

import vx "abi:vx"
import "vx:ring"

// Rings, the data plane.
//
// The kernel makes a ring's shared VMO and writes its header (lib/ring's
// layout), and after that never reads the ring: the queues are the two
// sides' business, and lib/ring is the protocol. What the kernel keeps is
// per end:
//
//  - a doorbell: a counter the peer rings with ring_notify, which a port
//    waits on through a COUNTER_GE binding on the end (counter_read on the
//    end reads it), and PEER_CLOSED bindings for when the peer goes away;
//  - the handle side channel: an entry cannot carry a capability, so a side
//    puts handles in a numbered slot (ring_xfer_handles, PUT), names the slot
//    in the entry, and the peer takes them (TAKE). Unclaimed slots are
//    released with the ring.

@(private="file")
Ring_Slot :: struct {
	count:   u32, // 0: free
	handles: [vx.RING_SLOT_HANDLES]Moved_Handle,
}

Ring_End :: struct {
	using obj: Object,
	pair:      ^Ring_Pair,
	side:      u32, // 0: the client, 1: the server
	doorbell:  ^Counter, // rung by the peer
	obs:       Observers, // PEER_CLOSED
}

#assert(offset_of(Ring_End, obj) == 0) // objects are cast from ^Object

Ring_Pair :: struct {
	lock:  Spinlock,
	ends:  [2]^Ring_End, // nil once that end is destroyed
	slots: [2][vx.RING_SLOTS]Ring_Slot, // slots[d]: put by side d, taken by the other
}

ring_end_pool := Pool{size = (size_of(Ring_End) + 15) &~ 15}
ring_pair_pool := Pool{size = (size_of(Ring_Pair) + 15) &~ 15}

#assert(size_of(Ring_Pair) <= 4096) // a pool object fits in a page

// A new ring: its memory, with the header written, and its two ends.
@(require_results)
ring_create :: proc "contextless" (p: vx.Ring_Params) -> (client, server: ^Ring_End, memory: ^Vmo, st: vx.Status) {
	h := ring.layout(p) or_return
	v := vmo_create(h.size) or_return
	vmo_write(v, 0, (cast([^]u8)&h)[:size_of(h)])
	pair := cast(^Ring_Pair)pool_alloc(&ring_pair_pool)
	ends: [2]^Ring_End
	bells: [2]^Counter
	ok := pair != nil
	for i in 0 ..< 2 {
		if !ok {
			break
		}
		ends[i] = cast(^Ring_End)pool_alloc(&ring_end_pool)
		bell, bst := counter_create(0)
		bells[i] = bell
		ok = ends[i] != nil && bst == .Ok
		if !ok {
			break
		}
		object_init(&ends[i].obj, .Ring)
		ends[i].pair = pair
		ends[i].side = u32(i)
		ends[i].doorbell = bells[i]
		pair.ends[i] = ends[i]
	}
	if !ok {
		for i in 0 ..< 2 {
			if bells[i] != nil {
				object_release(&bells[i].obj)
			}
			if ends[i] != nil {
				pool_free(&ring_end_pool, ends[i])
			}
		}
		if pair != nil {
			pool_free(&ring_pair_pool, pair)
		}
		object_release(&v.obj)
		return nil, nil, nil, .Err_No_Memory
	}
	return ends[0], ends[1], v, .Ok
}

// Rings the peer's doorbell (the producer saw it sleep). PEER_CLOSED if it is gone.
@(require_results)
ring_notify :: proc "contextless" (e: ^Ring_End) -> vx.Status {
	spin_lock(&e.pair.lock)
	peer := e.pair.ends[1 - e.side]
	bell := peer != nil ? peer.doorbell : nil
	if bell != nil {
		object_ref(&bell.obj)
	}
	spin_unlock(&e.pair.lock)
	if bell == nil {
		return .Err_Peer_Closed
	}
	counter_add(bell, 1)
	object_release(&bell.obj)
	return .Ok
}

// COUNTER_GE waits on this end's doorbell; PEER_CLOSED on the peer going.
@(require_results)
ring_bind :: proc "contextless" (e: ^Ring_End, b: ^Binding) -> vx.Status {
	if b.trigger == .Counter_Ge {
		return counter_bind(e.doorbell, b)
	}
	if b.trigger != .Peer_Closed {
		return .Err_Invalid
	}
	spin_lock(&e.pair.lock)
	defer spin_unlock(&e.pair.lock)
	if e.pair.ends[1 - e.side] == nil {
		binding_fire(b, 0)
	} else {
		observers_add(&e.obs, b)
	}
	return .Ok
}

// Puts moved handles in a free slot for the peer; returns the slot, or
// SHOULD_WAIT if all are taken.
ring_put :: proc "contextless" (e: ^Ring_End, handles: []Moved_Handle) -> i64 {
	spin_lock(&e.pair.lock)
	defer spin_unlock(&e.pair.lock)
	for i in 0 ..< vx.RING_SLOTS {
		s := &e.pair.slots[e.side][i]
		if s.count != 0 {
			continue
		}
		s.count = u32(len(handles))
		copy(s.handles[:], handles)
		return i64(i)
	}
	return i64(vx.Status.Err_Should_Wait)
}

// Takes the peer's slot; its handles are the caller's to install. INVALID if
// the slot holds nothing.
@(require_results)
ring_take :: proc "contextless" (e: ^Ring_End, slot: u32, out: []Moved_Handle) -> (count: u32, st: vx.Status) {
	if slot >= vx.RING_SLOTS {
		return 0, .Err_Invalid
	}
	spin_lock(&e.pair.lock)
	defer spin_unlock(&e.pair.lock)
	s := &e.pair.slots[1 - e.side][slot]
	if s.count == 0 {
		return 0, .Err_Invalid
	}
	count = s.count
	copy(out, s.handles[:count])
	s.count = 0
	return count, .Ok
}

ring_destroy :: proc "contextless" (e: ^Ring_End) {
	pair := e.pair
	spin_lock(&pair.lock)
	pair.ends[e.side] = nil
	peer := pair.ends[1 - e.side]
	if peer != nil {
		observers_fire(&peer.obs, .Peer_Closed, 0)
	}
	bindings := e.obs.head
	spin_unlock(&pair.lock)
	observers_free(bindings)
	object_drop(&e.doorbell.obj)
	pool_free(&ring_end_pool, e)
	if peer != nil {
		return
	}
	for d in 0 ..< 2 { // the last end: unclaimed handles go with the ring
		for &s in pair.slots[d] {
			for h in s.handles[:s.count] {
				object_drop(h.obj)
			}
		}
	}
	pool_free(&ring_pair_pool, pair)
}
