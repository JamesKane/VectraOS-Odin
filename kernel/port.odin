package kernel

import vx "abi:vx"

// Ports, the one wait, and the bindings that feed them.
//
// A port delivers packets from two places: bindings and posts. port_bind
// attaches a one-shot binding to a source, such as a channel end, a counter
// or a task. When the source's condition holds, at once if it already does,
// the binding moves to the port's ready list; port_wait returns it as a
// packet and the binding is gone. Each binding is the packet it delivers,
// allocated when it is bound, so bindings can never overflow a port. Posts
// (port_post) queue in a fixed ring of PORT_CAPACITY; a post to a full ring
// fails with SHOULD_WAIT.
//
// Locks are taken source first, then port, then scheduler. A waiter whose
// deadline passes is woken by the timer, which holds only the scheduler's
// lock, so it takes itself off the port's list afterwards.

PORT_CAPACITY :: 64

Port :: struct {
	using obj:  Object,
	lock:       Spinlock,
	head:       u32, // posted packets in queue
	count:      u32,
	ready:      Fifo(Binding), // fired bindings
	waiters:    ^Thread, // first come, first served; may hold waiters that timed out
	queue:      [PORT_CAPACITY]vx.Packet,
}

#assert(offset_of(Port, obj) == 0) // objects are cast from ^Object

Binding :: struct {
	next:          ^Binding, // on its source's list, then on its port's ready list
	port:          ^Port, // holds a reference until it fires; then the port holds it
	fired:         bool,
	key:           u64,
	threshold:     u64, // .Counter_Ge
	trigger:       vx.Trigger,
	source_handle: u32,
	packet:        vx.Packet, // filled when it fires
}

port_pool: Pool(Port)
binding_pool: Pool(Binding)

@(require_results)
port_create :: proc "contextless" () -> (^Port, vx.Status) {
	p := pool_alloc(&port_pool)
	if p == nil {
		return nil, .Err_No_Memory
	}
	object_init(&p.obj, .Port)
	return p, .Ok
}

// The last reference is gone: no waiter can be left (each held a reference
// through its handle_get), and the packets fired into the port go with it.
port_destroy :: proc "contextless" (p: ^Port) {
	for b := fifo_pop(&p.ready); b != nil; b = fifo_pop(&p.ready) {
		pool_free(&binding_pool, b)
	}
	pool_free(&port_pool, p)
}

// Wakes the first waiter still waiting. Called with the port's lock held.
@(private="file")
port_wake_one :: proc "contextless" (p: ^Port) {
	for p.waiters != nil {
		t := p.waiters
		p.waiters = t.wait_next
		if thread_wake_token(t, p, .Ok) {
			break
		}
	}
}

// Queues a packet and wakes the first waiter still waiting.
@(require_results)
port_post :: proc "contextless" (p: ^Port, packet: vx.Packet) -> vx.Status {
	spin_lock(&p.lock)
	defer spin_unlock(&p.lock)
	if p.count == PORT_CAPACITY {
		return .Err_Should_Wait
	}
	p.queue[(p.head + p.count) % PORT_CAPACITY] = packet
	p.count += 1
	port_wake_one(p)
	return .Ok
}

binding_free :: proc "contextless" (b: ^Binding) {
	if !b.fired { // a fired one gave its reference up
		object_drop(&b.port.obj)
	}
	pool_free(&binding_pool, b)
}

// Takes up to len(out) packets, fired bindings first. Returns how many.
port_take :: proc "contextless" (p: ^Port, out: []vx.Packet) -> int {
	done: ^Binding
	spin_lock(&p.lock)
	n := 0
	for n < len(out) && p.ready.head != nil {
		b := fifo_pop(&p.ready)
		out[n] = b.packet
		n += 1
		b.next = done
		done = b
	}
	for n < len(out) && p.count > 0 {
		out[n] = p.queue[p.head]
		n += 1
		p.head = (p.head + 1) % PORT_CAPACITY
		p.count -= 1
	}
	spin_unlock(&p.lock)
	for done != nil {
		next := done.next
		binding_free(done)
		done = next
	}
	return n
}

// Joins the port's waiters, unless a packet is already there. Returns
// whether it joined; the caller then blocks.
port_join_waiters :: proc "contextless" (p: ^Port, t: ^Thread) -> bool {
	spin_lock(&p.lock)
	defer spin_unlock(&p.lock)
	if p.count != 0 || p.ready.head != nil {
		return false
	}
	t.wait_token = p // set before t is on the list; wakers only find it there, under this lock
	t.wait_next = nil
	link := &p.waiters
	for link^ != nil {
		link = &link^.wait_next
	}
	link^ = t
	return true
}

port_remove_waiter :: proc "contextless" (p: ^Port, t: ^Thread) {
	spin_lock(&p.lock)
	defer spin_unlock(&p.lock)
	unlink(&p.waiters, t, "wait_next")
}

// --- Bindings ---

binding_new :: proc "contextless" (p: ^Port, trigger: vx.Trigger, key, threshold: u64, source: vx.Handle) -> ^Binding {
	b := pool_alloc(&binding_pool)
	if b == nil {
		return nil
	}
	object_ref(&p.obj)
	b^ = {port = p, trigger = trigger, key = key, threshold = threshold, source_handle = u32(source)}
	return b
}

// Moves a binding to its port's ready list as a packet with this value.
binding_fire :: proc "contextless" (b: ^Binding, value: u64) {
	p := b.port
	b.packet = {
		key       = b.key,
		value     = value,
		timestamp = vx.Instant(clock_now()),
		source    = b.source_handle,
		trigger   = b.trigger,
	}
	b.fired = true
	spin_lock(&p.lock)
	fifo_push(&p.ready, b)
	port_wake_one(p)
	spin_unlock(&p.lock)
	// The port owns the fired binding now, so the binding no longer keeps the
	// port alive: a port with packets no one takes is still freed
	// (port_destroy). Only a drop: this runs under the source's lock, or in an
	// interrupt.
	object_drop(&p.obj)
}

observers_add :: proc "contextless" (o: ^Observers, b: ^Binding) {
	b.next = o.head
	o.head = b
}

// Fires every binding waiting for this trigger; for .Counter_Ge, only those
// whose threshold `value` has reached. Called with the source's lock held.
observers_fire :: proc "contextless" (o: ^Observers, trigger: vx.Trigger, value: u64) {
	link := &o.head
	for link^ != nil {
		b := link^
		if b.trigger == trigger && (trigger != .Counter_Ge || value >= b.threshold) {
			link^ = b.next
			binding_fire(b, value)
		} else {
			link = &b.next
		}
	}
}

// The source is being destroyed: its unfired bindings go too. The caller
// takes them off the source under its lock and calls this without it.
observers_free :: proc "contextless" (list: ^Binding) {
	b := list
	for b != nil {
		next := b.next
		binding_free(b)
		b = next
	}
}
