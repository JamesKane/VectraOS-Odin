package kernel

import vx "abi:vx"

// Channels, the control plane.
//
// A channel is two ends. A message written to one end is queued at the
// other: a 16-byte header, a body of up to 64 KiB, and up to 64 handles,
// which move out of the writer's handle table and into the reader's. The
// kernel copies the body twice, in and out, and writes the header's
// sender_intent itself.
//
// Each end's queue is bounded by CHANNEL_QUEUE_MESSAGES and
// CHANNEL_QUEUE_BYTES, so a flood fails the writer with SHOULD_WAIT and never
// grows the kernel.
//
// channel_call writes a request and waits on its own end for the reply whose
// txid matches; the kernel picks the txid, and the reply goes straight to the
// waiting caller instead of the queue. A call that ends without its reply
// takes back a request the server has not read yet.
//
// Both ends share one lock. Objects that leave the kernel's hands (a
// message's handles, a dying end's bindings) are released after it is
// dropped, because releasing one may destroy another channel.

CHANNEL_QUEUE_MESSAGES :: 64
CHANNEL_QUEUE_BYTES :: u64(1) << 20

// A message lives in one physical block: this header, then `count` moved
// handles, then the body.
Channel_Msg :: struct {
	next:  ^Channel_Msg,
	call:  ^Call_Wait, // the channel_call that sent it, while it waits in a queue
	order: uint, // the physical block it lives in
	len:   u32, // body bytes, header included
	count: u32, // handles
}

msg_handles :: proc "contextless" (m: ^Channel_Msg) -> []Moved_Handle {
	return (cast([^]Moved_Handle)(cast([^]Channel_Msg)m)[1:])[:m.count]
}

msg_body :: proc "contextless" (m: ^Channel_Msg) -> []u8 {
	after := cast([^]u8)raw_data(msg_handles(m)[m.count:])
	return after[:m.len]
}

msg_header :: proc "contextless" (m: ^Channel_Msg) -> ^vx.Msg_Header {
	return cast(^vx.Msg_Header)raw_data(msg_body(m))
}

// A thread in channel_call, waiting on its own end for its reply.
@(private="file")
Call_Wait :: struct {
	next:   ^Call_Wait,
	thread: ^Thread,
	txid:   u32,
	reply:  ^Channel_Msg, // set by the writer of the reply
	read:   bool, // its request has left the server's queue: read, and maybe freed
}

Channel :: struct {
	using obj: Object,
	pair:      ^Channel_Pair,
	side:      Side, // this end is pair.ends[side]
	queue:     Fifo(Channel_Msg), // messages for this end's reader
	count:     u32,
	bytes:     u64,
	obs:       Observers, // READABLE and PEER_CLOSED bindings on this end
	calls:     ^Call_Wait, // channel_calls waiting for a reply on this end
	next_txid: u32,
}

#assert(offset_of(Channel, obj) == 0) // objects are cast from ^Object

Channel_Pair :: struct {
	lock: Spinlock,
	ends: [Side]^Channel, // nil once that end is destroyed
}

// Kernel-picked txids have the top bit set; bit 30 says which end's call it
// is, so a call in each direction at once is never taken for the other's reply.
CALL_TXID :: u32(0x8000_0000)
SIDE_TXID :: u32(0x4000_0000)

channel_pool: Pool(Channel)
channel_pair_pool: Pool(Channel_Pair)

@(require_results)
channel_create :: proc "contextless" () -> (a, b: ^Channel, st: vx.Status) {
	pair := pool_alloc(&channel_pair_pool)
	if pair == nil {
		return nil, nil, .Err_No_Memory
	}
	defer if st != .Ok {
		pool_free(&channel_pair_pool, pair)
	}
	e0 := pool_alloc(&channel_pool)
	if e0 == nil {
		return nil, nil, .Err_No_Memory
	}
	defer if st != .Ok {
		pool_free(&channel_pool, e0)
	}
	e1 := pool_alloc(&channel_pool)
	if e1 == nil {
		return nil, nil, .Err_No_Memory
	}
	ends := [Side]^Channel {
		.Client = e0,
		.Server = e1,
	}
	for e, side in ends {
		object_init(&e.obj, .Channel)
		e.pair = pair
		e.side = side
		e.next_txid = CALL_TXID | u32(side) << 30 // each end's calls in a half of their own
		pair.ends[side] = e
	}
	return e0, e1, .Ok
}

@(private="file")
channel_peer :: proc "contextless" (c: ^Channel) -> ^Channel {
	return c.pair.ends[peer_side(c.side)]
}

msg_free :: proc "contextless" (m: ^Channel_Msg) {
	for h in msg_handles(m) {
		object_drop(h.obj)
	}
	phys_free(virt_to_phys(m), m.order)
}

@(private="file")
msg_list_free :: proc "contextless" (list: ^Channel_Msg) {
	m := list
	for m != nil {
		next := m.next
		msg_free(m)
		m = next
	}
}

// A message block for `body_len` body bytes and `count` handles, or nil.
msg_alloc :: proc "contextless" (body_len, count: u32) -> ^Channel_Msg {
	order := order_for(u64(size_of(Channel_Msg)) + u64(count) * size_of(Moved_Handle) + u64(body_len))
	pa := phys_alloc(order)
	if pa == 0 {
		return nil
	}
	m := cast(^Channel_Msg)phys_to_virt(pa)
	m^ = {order = order, len = body_len, count = count}
	return m
}

// Queues m for the reader of `to`, or hands it to the channel_call waiting
// for it there. Called with the pair's lock held. Fails with SHOULD_WAIT when
// the queue is full.
@(private="file", require_results)
channel_deliver :: proc "contextless" (to: ^Channel, m: ^Channel_Msg) -> vx.Status {
	txid := msg_header(m).txid
	if txid != 0 {
		for link := &to.calls; link^ != nil; link = &link^.next {
			w := link^
			if w.txid != txid {
				continue
			}
			link^ = w.next
			w.reply = m
			_ = thread_wake_token(w.thread, w, .Ok)
			return .Ok
		}
	}
	if to.count == CHANNEL_QUEUE_MESSAGES || to.bytes + u64(m.len) > CHANNEL_QUEUE_BYTES {
		return .Err_Should_Wait
	}
	fifo_push(&to.queue, m)
	to.count += 1
	to.bytes += u64(m.len)
	observers_fire(&to.obs, .Readable, u64(to.count))
	return .Ok
}

// Sends a message the caller has filled in, handles included, to c's peer.
// On success the message belongs to the channel; on failure to the caller.
@(require_results)
channel_write :: proc "contextless" (c: ^Channel, m: ^Channel_Msg) -> vx.Status {
	msg_header(m).sender_intent = sched_thread_intent(this_cpu().current)
	spin_lock(&c.pair.lock)
	defer spin_unlock(&c.pair.lock)
	peer := channel_peer(c)
	return peer != nil ? channel_deliver(peer, m) : .Err_Peer_Closed
}

// Takes the next message if it fits caps of `cap_bytes` bytes and `count_cap`
// handles; otherwise reports its size in need and leaves it queued.
@(require_results)
channel_read :: proc "contextless" (c: ^Channel, cap_bytes, count_cap: u32) -> (out: ^Channel_Msg, need: vx.Msg_Size, st: vx.Status) {
	spin_lock(&c.pair.lock)
	defer spin_unlock(&c.pair.lock)
	m := c.queue.head
	if m == nil {
		return nil, {}, channel_peer(c) != nil ? .Err_Should_Wait : .Err_Peer_Closed
	}
	need = {m.len, m.count}
	if m.len > cap_bytes || m.count > count_cap {
		return nil, need, .Err_Too_Small
	}
	_ = fifo_pop(&c.queue)
	c.count -= 1
	c.bytes -= u64(m.len)
	if m.call != nil {
		m.call.read = true
		m.call = nil
	}
	return m, need, .Ok
}

// Writes a request with a kernel-picked txid and waits on c for the reply, or
// the deadline. The reply is returned whole; the caller checks its size.
// `sent` says whether the request went out: if so it belongs to the channel,
// whatever happens next; if not it is still the caller's.
@(require_results)
channel_call :: proc "contextless" (c: ^Channel, request: ^Channel_Msg, deadline: Instant) -> (reply: ^Channel_Msg, sent: bool, st: vx.Status) {
	t := this_cpu().current
	w := Call_Wait{thread = t}
	spin_lock(&c.pair.lock)
	peer := channel_peer(c)
	if peer == nil {
		spin_unlock(&c.pair.lock)
		return nil, false, .Err_Peer_Closed
	}
	w.txid = c.next_txid
	c.next_txid = CALL_TXID | c.next_txid & SIDE_TXID | (c.next_txid + 1) &~ (CALL_TXID | SIDE_TXID)
	h := msg_header(request)
	h.txid = w.txid
	h.sender_intent = sched_thread_intent(t)
	request.call = &w
	st = channel_deliver(peer, request)
	if st == .Ok {
		sent = true
		t.wait_token = &w
		w.next = c.calls
		c.calls = &w
	} else {
		request.call = nil
	}
	spin_unlock(&c.pair.lock)
	if st != .Ok {
		return nil, false, st
	}

	// A call that ends without its reply (interrupted, timed out) takes back
	// a request the server has not read yet, so the server never answers a
	// call nobody waits for. Whether it is still queued is w.read, not a
	// search for its address: once read, its block may be freed and given to
	// another message in the same queue. An interrupted call whose request
	// the server has read waits on for the reply, so no answer is lost: the
	// interrupt is delivered once it returns. (A server that holds a call
	// answers it before it interrupts the caller.)
	woke: vx.Status
	for {
		woke = thread_block(deadline, 0)
		spin_lock(&c.pair.lock)
		server := channel_peer(c)
		queued := server != nil && !w.read && w.reply == nil
		if queued && (woke == .Err_Interrupted || woke == .Err_Timed_Out || woke == .Err_Killed) && fifo_remove(&server.queue, request) {
			server.count -= 1
			server.bytes -= u64(request.len)
			request.call = nil
			sent = false // the caller's again, and freed with its handles
		}
		if w.reply == nil && woke == .Err_Interrupted && server != nil && !queued {
			t.wait_token = &w // the server has it: its answer is coming
			spin_unlock(&c.pair.lock)
			continue
		}
		unlink(&c.calls, &w, "next") // stop waiting
		if sent && !w.read && server != nil {
			request.call = nil // left queued: w is gone
		}
		spin_unlock(&c.pair.lock)
		break
	}
	if w.reply != nil {
		return w.reply, sent, .Ok
	}
	return nil, sent, woke == .Ok ? .Err_Peer_Closed : woke
}

// Attaches a READABLE or PEER_CLOSED binding, or fires it at once if it holds.
@(require_results)
channel_bind :: proc "contextless" (c: ^Channel, b: ^Binding) -> vx.Status {
	if b.trigger != .Readable && b.trigger != .Peer_Closed {
		return .Err_Invalid
	}
	spin_lock(&c.pair.lock)
	defer spin_unlock(&c.pair.lock)
	switch {
	case b.trigger == .Readable && c.queue.head != nil:
		binding_fire(b, u64(c.count))
	case b.trigger == .Peer_Closed && channel_peer(c) == nil:
		binding_fire(b, 0)
	case:
		observers_add(&c.obs, b)
	}
	return .Ok
}

// The last reference to an end is gone: its peer sees PEER_CLOSED, and calls
// waiting on the peer end fail.
channel_destroy :: proc "contextless" (c: ^Channel) {
	pair := c.pair
	spin_lock(&pair.lock)
	queued := c.queue.head
	bindings := c.obs.head
	pair.ends[c.side] = nil
	peer := channel_peer(c)
	if peer != nil {
		observers_fire(&peer.obs, .Peer_Closed, 0)
		for w := peer.calls; w != nil; w = w.next {
			_ = thread_wake_token(w.thread, w, .Err_Peer_Closed)
		}
		peer.calls = nil
	}
	spin_unlock(&pair.lock)
	msg_list_free(queued)
	observers_free(bindings)
	pool_free(&channel_pool, c)
	if peer == nil {
		pool_free(&channel_pair_pool, pair)
	}
}
