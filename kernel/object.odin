package kernel

import "base:intrinsics"

// Kernel objects and their pools.
//
// Every object starts with an Object header holding its type and an atomic
// reference count. Objects come from per-type pools carved out of whole
// pages; there is no general-purpose allocator in the kernel. Charging pools
// to memory budgets comes with budgets themselves.

Obj_Type :: enum u8 {
	None,
	Task,
	Thread,
	Vmo,
	Port,
	Channel,
	Counter,
	Ring,
	Resource,
	Irq,
	Iorange,
}

Object :: struct {
	type:       Obj_Type,
	refs:       u32,
	dying_next: ^Object, // on its CPU's list of objects to destroy (object_drop)
}

object_init :: proc "contextless" (o: ^Object, type: Obj_Type) {
	o.type = type
	intrinsics.atomic_store_explicit(&o.refs, 1, .Relaxed)
}

object_ref :: proc "contextless" (o: ^Object) {
	intrinsics.atomic_add_explicit(&o.refs, 1, .Relaxed)
}

// A reference to an object found through a list rather than a handle, unless
// its last reference is already gone (it is about to be destroyed).
object_tryref :: proc "contextless" (o: ^Object) -> bool {
	refs := intrinsics.atomic_load_explicit(&o.refs, .Relaxed)
	for refs != 0 {
		old, ok := intrinsics.atomic_compare_exchange_weak_explicit(&o.refs, refs, refs + 1, .Relaxed, .Relaxed)
		if ok {
			return true
		}
		refs = old
	}
	return false
}

// Dropping references, without recursion.
//
// Destroying one object can release others: a channel end frees its queued
// messages and the handles in them, which may be channel ends with messages
// of their own, as deep as a program cares to nest them. So destruction never
// recurses. object_drop takes a reference away and, if it was the last,
// queues the object on its CPU's dying list; object_drain destroys that list
// one object at a time, including whatever those destructions drop in turn.
// Destructors, and everything they call, only ever drop.
//
// object_release is drop then drain, for everywhere else. Drops made outside
// a destructor are drained by the next release on that CPU, and on every
// return to user mode. Destructors do not block, so a drain stays on one CPU.
@(private="file")
Dying :: struct {
	head:     ^Object,
	draining: bool,
}

@(private="file")
dying: [MAX_CPUS]Dying

object_drop :: proc "contextless" (o: ^Object) {
	if intrinsics.atomic_sub_explicit(&o.refs, 1, .Acq_Rel) != 1 {
		return
	}
	d := &dying[arch_cpu_index()]
	o.dying_next = d.head
	d.head = o
}

object_drain :: proc "contextless" () {
	d := &dying[arch_cpu_index()]
	if d.draining {
		return // an outer drain on this CPU will get to it
	}
	d.draining = true
	for d.head != nil {
		o := d.head
		d.head = o.dying_next
		object_destroy(o)
	}
	d.draining = false
}

object_release :: proc "contextless" (o: ^Object) {
	object_drop(o)
	object_drain()
}

// The last reference is gone: the type's destructor.
@(private="file")
object_destroy :: proc "contextless" (o: ^Object) {
	switch o.type {
	case .None:
		kpanic("destroying an untyped object")
	case .Vmo:
		vmo_destroy(cast(^Vmo)o)
	case .Port:
		port_destroy(cast(^Port)o)
	case .Channel:
		channel_destroy(cast(^Channel)o)
	case .Counter:
		counter_destroy(cast(^Counter)o)
	case .Ring:
		ring_destroy(cast(^Ring_End)o)
	case .Task:
		task_destroy(cast(^Task)o)
	case .Thread:
		thread_destroy(cast(^Thread)o)
	case .Resource:
		pool_free(&resource_pool, o)
	case .Irq:
		irq_destroy(cast(^Irq)o)
	case .Iorange:
		pool_free(&iorange_pool, o)
	}
}

// A pool hands out zeroed objects of one size, carved from whole pages.
Pool :: struct {
	lock: Spinlock,
	size: int, // rounded up to 16 bytes
	free: rawptr, // free list, through each free object's first word
}

// A pool's size is set in its declaration, as a constant expression:
// `x_pool := Pool{size = (size_of(X) + 15) &~ 15}`. (A global initialised by
// a procedure call would need Odin's startup code, which the kernel does not
// run: -disable-non-constant-globals refuses one.)

@(require_results)
pool_alloc :: proc "contextless" (p: ^Pool) -> rawptr {
	spin_lock(&p.lock)
	if p.free == nil {
		pa := phys_alloc(0)
		if pa == 0 {
			spin_unlock(&p.lock)
			return nil
		}
		page := cast([^]u8)phys_to_virt(pa)
		for off := 0; off + p.size <= 4096; off += p.size {
			(cast(^rawptr)&page[off])^ = p.free
			p.free = &page[off]
		}
	}
	o := p.free
	p.free = (cast(^rawptr)o)^
	spin_unlock(&p.lock)
	intrinsics.mem_zero(o, p.size)
	return o
}

pool_free :: proc "contextless" (p: ^Pool, o: rawptr) {
	spin_lock(&p.lock)
	(cast(^rawptr)o)^ = p.free
	p.free = o
	spin_unlock(&p.lock)
}

// A source's port bindings that have not fired (port.odin), under the
// source's own lock.
Observers :: struct {
	head: ^Binding,
}
