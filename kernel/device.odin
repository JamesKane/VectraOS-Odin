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

MAX_IRQ_LINES :: 2048
MSI_LINE_BASE :: 1024 // lines from here are MSIs (arch_msi_create)

// Under irq_lines_lock; at most one Irq per line. The architecture reads it
// to find a free MSI line.
@(private)
irq_lines: [MAX_IRQ_LINES]^Irq
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
vmo_create_physical :: proc "contextless" (pa: Paddr, size: u64) -> (vmo: ^Vmo, st: vx.Status) {
	end, overflow := intrinsics.overflow_add(pa, Paddr(size))
	if size == 0 || size > VMO_MAX_SIZE || (u64(pa) | size) & (PAGE_SIZE - 1) != 0 || overflow {
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
	v := vmo_alloc(size / PAGE_SIZE) or_return
	v.physical = true
	for &page, i in v.pages {
		page = pa + Paddr(i * PAGE_SIZE)
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

// An MSI for the PCI function `source`: the architecture picks a free line
// (it reads irq_lines, under irq_lines_lock) and says what to write where.
@(require_results)
irq_create_msi :: proc "contextless" (source: u32) -> (q: ^Irq, msi: vx.Msi, st: vx.Status) {
	irq := pool_alloc(&irq_pool)
	if irq == nil {
		return nil, {}, .Err_No_Memory
	}
	object_init(&irq.obj, .Irq)
	spin_lock(&irq_lines_lock)
	irq.line, msi, st = arch_msi_create(source)
	if st == .Ok {
		irq_lines[irq.line] = irq
	}
	spin_unlock(&irq_lines_lock)
	if st != .Ok {
		pool_free(&irq_pool, irq)
		return nil, {}, st
	}
	return irq, msi, .Ok // edge-triggered: never masked
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
	if q.line >= MSI_LINE_BASE {
		arch_msi_destroy(q.line)
	}
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

// --- DmaDomain ---
//
// What a device may reach by DMA. There is no IOMMU behind it yet: a
// pass-through domain gives devices physical addresses, so it is only safe
// with devices QEMU emulates (M3). It holds each VMO it maps, so the pages
// stay where the device was told they are.

DMA_MAPPINGS :: 128

Dma_Domain :: struct {
	using obj: Object,
	lock:      Spinlock,
	mapped:    [DMA_MAPPINGS]^Vmo, // a reference for each dma_map
}

#assert(offset_of(Dma_Domain, obj) == 0) // objects are cast from ^Object

dma_pool: Pool(Dma_Domain)

@(require_results)
dma_domain_create :: proc "contextless" () -> (^Dma_Domain, vx.Status) {
	d := pool_alloc(&dma_pool)
	if d == nil {
		return nil, .Err_No_Memory
	}
	object_init(&d.obj, .Dma_Domain)
	return d, .Ok
}

// Holds the VMO for the device and gives the address of each page of the
// range into `addresses`; `slot` says which mapping it is, to undo just this one.
@(require_results)
dma_map :: proc "contextless" (d: ^Dma_Domain, v: ^Vmo, offset, size: u64, addresses: []Paddr) -> (slot: int, st: vx.Status) {
	end, overflow := intrinsics.overflow_add(offset, size)
	if size == 0 || (offset | size) & (PAGE_SIZE - 1) != 0 || overflow || end > v.size {
		return 0, .Err_Range
	}
	if v.physical {
		return 0, .Err_Unsupported // device memory: peer-to-peer comes later
	}
	slot = -1
	{
		spin_guard(&d.lock)
		for m, i in d.mapped {
			if m == nil {
				object_ref(&v.obj)
				d.mapped[i] = v
				slot = i
				break
			}
		}
	}
	if slot < 0 {
		return 0, .Err_No_Memory
	}
	first := offset / PAGE_SIZE
	copy(addresses, v.pages[first:][:size / PAGE_SIZE])
	return slot, .Ok
}

// Undoes one dma_map, by the slot it gave.
dma_unmap_slot :: proc "contextless" (d: ^Dma_Domain, slot: int) {
	spin_lock(&d.lock)
	v := d.mapped[slot]
	d.mapped[slot] = nil
	spin_unlock(&d.lock)
	if v != nil {
		object_release(&v.obj)
	}
}

// Lets go of every mapping of the VMO.
@(require_results)
dma_unmap :: proc "contextless" (d: ^Dma_Domain, v: ^Vmo) -> vx.Status {
	drop: [dynamic; DMA_MAPPINGS]^Vmo
	spin_lock(&d.lock)
	for &m in d.mapped {
		if m == v {
			_ = append(&drop, m) // room for every slot
			m = nil
		}
	}
	spin_unlock(&d.lock)
	for m in drop {
		object_release(&m.obj)
	}
	return len(drop) > 0 ? .Ok : .Err_Not_Found
}

dma_domain_destroy :: proc "contextless" (d: ^Dma_Domain) {
	for m in d.mapped {
		if m != nil {
			object_drop(&m.obj)
		}
	}
	pool_free(&dma_pool, d)
}
