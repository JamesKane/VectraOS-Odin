package kernel

import "base:intrinsics"
import vx "abi:vx"

// What user-space drivers get from the kernel: the Resource, Irq and IoRange
// objects, and physical VMOs.
//
// The Resource is root authority over device space: physical memory that is
// not RAM, interrupt lines and I/O ports. The kernel gives it to the root
// task (root.odin), which mints narrower objects from it for each driver.
//
// An Irq owns one line. When the line fires, the kernel counts it and fires
// the IRQ binding, or remembers that it fired so the next binding fires at
// once. A level-triggered line is masked until irq_ack, since it would fire
// again at once; an edge-triggered line is never masked, because an edge that
// arrived while it was masked would be lost, and with it the device. A
// driver therefore handles everything the device has pending before it binds
// again.
//
// The kernel's console belongs to the kernel only until a driver is given
// its device: from then on the kernel writes to it only to report a panic.

Resource :: struct {
	using obj: Object,
}

#assert(offset_of(Resource, obj) == 0) // objects are cast from ^Object

Irq :: struct {
	using obj: Object,
	lock:      Spinlock,
	line:      u32,
	level:     bool, // masked when it fires, until irq_ack
	masked:    bool, // by the kernel, now
	pending:   bool, // fired with no binding to tell
	count:     u64,
	obs:       Observers, // IRQ bindings
}

#assert(offset_of(Irq, obj) == 0) // objects are cast from ^Object

Iorange :: struct {
	using obj: Object,
	range:     Io_Range,
}

#assert(offset_of(Iorange, obj) == 0) // objects are cast from ^Object

resource_pool: Pool(Resource)
irq_pool: Pool(Irq)
iorange_pool: Pool(Iorange)

MAX_IRQ_LINES :: 1024

@(private="file")
irq_lines: [MAX_IRQ_LINES]^Irq // under irq_lines_lock; at most one Irq per line
@(private="file")
irq_lines_lock: Spinlock

// A driver has the console's device. With vx.kconsole on the command line
// the kernel keeps writing to it anyway, for debugging what goes on after.
@(private="file")
console_hand_off :: proc "contextless" () {
	if !cmdline_has("vx.kconsole") {
		console_handed_off = true
	}
}

root_resource :: proc "contextless" () -> ^Resource {
	r := pool_alloc(&resource_pool)
	if r == nil {
		kpanic("no memory for the root resource")
	}
	object_init(&r.obj, .Resource)
	return r
}

// --- Physical VMOs ---

// A VMO over [pa, pa + size) of device memory, which may not overlap RAM or
// firmware memory.
@(require_results)
vmo_create_physical :: proc "contextless" (pa: Paddr, size: u64) -> (^Vmo, vx.Status) {
	end, overflow := intrinsics.overflow_add(pa, Paddr(size))
	if size == 0 || size > VMO_MAX_SIZE || (u64(pa) | size) & 4095 != 0 || overflow {
		return nil, .Err_Range
	}
	if boot.ram_incomplete {
		return nil, .Err_Access
	}
	for r in boot.ram[:boot.ram_count] {
		if pa < r.end && r.base < end {
			return nil, .Err_Access
		}
	}
	count := size / 4096
	order := page_list_order(count)
	v := pool_alloc(&vmo_pool)
	list := v != nil ? phys_alloc(order) : 0
	if list == 0 {
		if v != nil {
			pool_free(&vmo_pool, v)
		}
		return nil, .Err_No_Memory
	}
	object_init(&v.obj, .Vmo)
	v.size = size
	v.pages = (cast([^]Paddr)phys_to_virt(list))[:count]
	v.list_order = order
	v.physical = true
	for &page, i in v.pages {
		page = pa + Paddr(i * 4096)
	}
	if arch_console_device(false, u64(pa), size) {
		console_hand_off()
	}
	return v, .Ok
}

// --- Irq ---

@(require_results)
irq_create :: proc "contextless" (line: u32) -> (^Irq, vx.Status) {
	if line >= MAX_IRQ_LINES {
		return nil, .Err_Range
	}
	q := pool_alloc(&irq_pool)
	if q == nil {
		return nil, .Err_No_Memory
	}
	object_init(&q.obj, .Irq)
	q.line = line
	spin_lock(&irq_lines_lock)
	st := vx.Status.Err_Exists
	if irq_lines[line] == nil {
		q.level, st = arch_irq_route(line)
	}
	if st == .Ok {
		irq_lines[line] = q
	}
	spin_unlock(&irq_lines_lock)
	if st != .Ok {
		pool_free(&irq_pool, q)
		return nil, st
	}
	return q, .Ok
}

// The line fired: called by the architecture's interrupt handler.
irq_fire :: proc "contextless" (line: u32) {
	spin_lock(&irq_lines_lock)
	defer spin_unlock(&irq_lines_lock)
	q := line < MAX_IRQ_LINES ? irq_lines[line] : nil
	if q == nil {
		arch_irq_mask(line, true) // no one owns it: keep it quiet
		return
	}
	spin_lock(&q.lock)
	q.count += 1
	if q.level && !q.masked {
		arch_irq_mask(line, true)
		q.masked = true
	}
	if q.obs.head != nil {
		observers_fire(&q.obs, .Irq, q.count)
	} else {
		q.pending = true
	}
	spin_unlock(&q.lock)
}

@(require_results)
irq_bind :: proc "contextless" (q: ^Irq, b: ^Binding) -> vx.Status {
	if b.trigger != .Irq {
		return .Err_Invalid
	}
	spin_lock(&q.lock)
	defer spin_unlock(&q.lock)
	if q.pending {
		q.pending = false
		binding_fire(b, q.count)
	} else {
		observers_add(&q.obs, b)
	}
	return .Ok
}

irq_ack :: proc "contextless" (q: ^Irq) {
	spin_lock(&q.lock)
	defer spin_unlock(&q.lock)
	if q.masked {
		q.masked = false
		arch_irq_mask(q.line, false)
	}
}

irq_destroy :: proc "contextless" (q: ^Irq) {
	spin_lock(&irq_lines_lock)
	arch_irq_mask(q.line, true)
	irq_lines[q.line] = nil
	spin_unlock(&irq_lines_lock)
	observers_free(q.obs.head)
	pool_free(&irq_pool, q)
}

// --- IoRange ---

@(require_results)
iorange_create :: proc "contextless" (base, count: u64) -> (^Iorange, vx.Status) {
	if !arch_has_io_ports() {
		return nil, .Err_Unsupported
	}
	end, overflow := intrinsics.overflow_add(base, count)
	if count == 0 || overflow || end > 0x1_0000 {
		return nil, .Err_Range
	}
	r := pool_alloc(&iorange_pool)
	if r == nil {
		return nil, .Err_No_Memory
	}
	object_init(&r.obj, .Iorange)
	r.range = {u16(base), u32(count)}
	if arch_console_device(true, base, count) {
		console_hand_off()
	}
	return r, .Ok
}

// Lets task t use the range's ports. Its threads see them from their next
// switch onto a CPU; the calling thread, at once.
@(require_results)
task_enable_io :: proc "contextless" (t: ^Task, r: ^Iorange) -> vx.Status {
	spin_lock(&t.lock)
	added := append(&t.io, r.range) == 1
	spin_unlock(&t.lock)
	if !added {
		return .Err_No_Memory
	}
	if t == this_cpu().current.task {
		arch_io_switch(t)
	}
	return .Ok
}
