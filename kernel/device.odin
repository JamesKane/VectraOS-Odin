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
		page = page_of(pa + Paddr(i * PAGE_SIZE))
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

// --- DmaDomain and DmaMapping ---
//
// What a device may reach by DMA: a domain for one PCI function (its
// requester ID, `source`), which devmgr creates and keeps, giving the driver
// a duplicate that can only map. Each dma_map is a DmaMapping of its own: a
// range of a VMO, with whether the device may read it, write it or both,
// checked against the VMO handle's rights.
//
// Letting go. dma_unmap says the device is done with a mapping: its pages are
// let go at once. A mapping whose last handle goes without that (its driver
// died) cannot be trusted done: in a pass-through domain nothing stops the
// device, so its pages are kept until devmgr has reset the device and says so
// (dma_domain_op .Quiesced). .Revoke makes every mapping kept at once, for a
// driver that will not be asked. (Fuchsia's BTIs leak such pages for good and
// make every driver release them; here the domain's owner does, once.)
//
// Faults (the IOMMU's) are counted, and fire .Dma_Fault on the domain.
//
// With an IOMMU (iommu_amd64.odin, VT-d; iommu_arm64.odin, SMMUv3) a domain
// translates: a mapping gets device addresses of the domain's own,
// contiguous however its pages lie, and unmapping takes them out of the
// device's tables and invalidates before the pages go, so nothing need be
// kept. A function no IOMMU covers gets a pass-through domain, whose device
// addresses are physical: only safe with devices QEMU emulates.

// The IOMMU's side of a domain.
Iommu_Domain :: struct {
	on:   bool, // translated: the IOMMU has its tables for the device
	unit: u8, // which remapping unit
	did:  u16, // its domain id there (SMMUv3: its ASID)
	root: Paddr, // the top of its page tables
	ctx:  Paddr, // SMMUv3: its context descriptor
}

Dma_Mapping :: struct {
	using obj: Object,
	domain:    ^Dma_Domain, // referenced, until the mapping is freed
	vmo:       ^Vmo, // held while the device may reach it; nil once let go
	offset:    u64,
	size:      u64,
	iova:      u64, // translated: where the device sees it
	options:   vx.Dma_Options,
	revoked:   bool, // its handles of no more use (.Revoke): let go only at .Quiesced
	kept:      bool, // its handles gone, its pages not let go: on the domain's kept list
	next:      ^Dma_Mapping,
}

#assert(offset_of(Dma_Mapping, obj) == 0) // objects are cast from ^Object

Dma_Domain :: struct {
	using obj: Object,
	lock:      Spinlock,
	source:    u32, // the requester ID it is for
	live:      ^Dma_Mapping, // mappings with handles
	kept:      ^Dma_Mapping, // without: freed at .Quiesced
	faults:    u64,
	obs:       Observers, // .Dma_Fault bindings
	io:        Iommu_Domain,
}

#assert(offset_of(Dma_Domain, obj) == 0) // objects are cast from ^Object

dma_pool: Pool(Dma_Domain)
dma_mapping_pool: Pool(Dma_Mapping)

@(require_results)
dma_domain_create :: proc "contextless" (source: u32) -> (^Dma_Domain, vx.Status) {
	d := pool_alloc(&dma_pool)
	if d == nil {
		return nil, .Err_No_Memory
	}
	object_init(&d.obj, .Dma_Domain)
	d.source = source
	if st := iommu_attach(d); st != .Ok { // fails closed: a device an IOMMU covers is never pass-through
		pool_free(&dma_pool, d)
		return nil, st
	}
	return d, .Ok
}

// Device addresses for a mapping in a translated domain: the first gap from
// 4 GiB up (below, the firmware's reserved regions may be identity-mapped).
IOVA_BASE :: u64(1) << 32
IOVA_TOP :: u64(1) << 39

// Where a mapping of `size` bytes goes in d's device address space; 0 if it
// is full. Under d's lock.
@(private="file")
iova_alloc :: proc "contextless" (d: ^Dma_Domain, size: u64) -> u64 {
	at := IOVA_BASE
	for moved := true; moved; {
		moved = false
		for list in ([2]^Dma_Mapping{d.live, d.kept}) {
			for m := list; m != nil; m = m.next {
				if m.iova != 0 && at < m.iova + m.size && m.iova < at + size {
					at = m.iova + m.size
					moved = true
				}
			}
		}
	}
	return at + size <= IOVA_TOP ? at : 0
}

@(private="file")
dma_mapping_free :: proc "contextless" (m: ^Dma_Mapping) {
	d, v := m.domain, m.vmo
	pool_free(&dma_mapping_pool, m)
	if v != nil {
		object_drop(&v.obj)
	}
	object_drop(&d.obj)
}

// Maps [offset, offset + size) of v for the device, as options allow, and
// gives the device address of each page.
@(require_results)
dma_map :: proc "contextless" (d: ^Dma_Domain, v: ^Vmo, offset, size: u64, options: vx.Dma_Options, addresses: []u64) -> (^Dma_Mapping, vx.Status) {
	end, overflow := intrinsics.overflow_add(offset, size)
	if size == 0 || (offset | size) & (PAGE_SIZE - 1) != 0 || overflow || end > v.size {
		return nil, .Err_Range
	}
	if v.physical {
		return nil, .Err_Unsupported // device memory: peer-to-peer comes later
	}
	m := pool_alloc(&dma_mapping_pool)
	if m == nil {
		return nil, .Err_No_Memory
	}
	object_init(&m.obj, .Dma_Mapping)
	object_ref(&d.obj)
	object_ref(&v.obj)
	m.domain, m.vmo, m.offset, m.size, m.options = d, v, offset, size, options
	spin_lock(&d.lock)
	if d.io.on {
		m.iova = iova_alloc(d, size)
		if m.iova == 0 {
			spin_unlock(&d.lock)
			dma_mapping_free(m)
			return nil, .Err_No_Memory // no room left in the domain's space
		}
	}
	m.next = d.live
	d.live = m
	spin_unlock(&d.lock)
	pages := v.pages[offset / PAGE_SIZE:][:size / PAGE_SIZE]
	if d.io.on && !iommu_map(d, m.iova, pages, options) {
		iommu_unmap(d, m.iova, size / PAGE_SIZE) // what it did of it
		spin_lock(&d.lock)
		unlink(&d.live, m, "next")
		spin_unlock(&d.lock)
		dma_mapping_free(m)
		return nil, .Err_No_Memory
	}
	for &a, i in addresses[:size / PAGE_SIZE] {
		a = d.io.on ? m.iova + u64(i) * PAGE_SIZE : pages[i].frame << 12
	}
	return m, .Ok
}

// The device is done with it: its pages let go now. Not a revoked one's: the
// device may still be using it until .Quiesced.
@(require_results)
dma_unmap :: proc "contextless" (m: ^Dma_Mapping) -> vx.Status {
	d := m.domain
	spin_lock(&d.lock)
	v := m.revoked ? nil : m.vmo
	refused := m.revoked || m.vmo == nil
	if v != nil {
		m.vmo = nil
	}
	spin_unlock(&d.lock)
	if v != nil {
		if d.io.on {
			iommu_unmap(d, m.iova, m.size / PAGE_SIZE) // out of the device's reach first
		}
		object_release(&v.obj)
	}
	return refused ? .Err_Bad_State : .Ok
}

// Its last handle gone: freed if its pages were let go, else kept for .Quiesced.
dma_mapping_destroy :: proc "contextless" (m: ^Dma_Mapping) {
	d := m.domain
	if d.io.on && m.vmo != nil {
		iommu_unmap(d, m.iova, m.size / PAGE_SIZE) // translated: out of reach, so let go now
	}
	spin_lock(&d.lock)
	unlink(&d.live, m, "next")
	keep := m.vmo != nil && !d.io.on
	if keep {
		m.kept = true
		m.next = d.kept
		d.kept = m
	}
	spin_unlock(&d.lock)
	if !keep {
		dma_mapping_free(m)
	}
}

// .Revoke: every live mapping's pages kept until .Quiesced, whatever its
// driver does.
dma_revoke :: proc "contextless" (d: ^Dma_Domain) {
	spin_lock(&d.lock)
	for m := d.live; m != nil; m = m.next {
		m.revoked = true
	}
	spin_unlock(&d.lock)
	if !d.io.on {
		return
	}
	// Translated: every mapping out of the device's reach now, its pages let go.
	for {
		v: ^Vmo
		iova, pages: u64
		spin_lock(&d.lock)
		for m := d.live; m != nil && v == nil; m = m.next {
			if m.vmo != nil {
				v, m.vmo, iova, pages = m.vmo, nil, m.iova, m.size / PAGE_SIZE
			}
		}
		spin_unlock(&d.lock)
		if v == nil {
			return
		}
		iommu_unmap(d, iova, pages)
		object_release(&v.obj)
	}
}

// .Quiesced: the device has been reset, so what was kept is let go.
dma_quiesced :: proc "contextless" (d: ^Dma_Domain) {
	for {
		v: ^Vmo
		spin_lock(&d.lock)
		m := d.kept
		if m != nil {
			d.kept = m.next
		}
		for l := d.live; m == nil && v == nil && l != nil; l = l.next { // revoked, its handles not yet gone
			if l.revoked && l.vmo != nil {
				v, l.vmo = l.vmo, nil
			}
		}
		spin_unlock(&d.lock)
		switch {
		case v != nil:
			object_release(&v.obj)
		case m != nil:
			dma_mapping_free(m)
		case:
			return
		}
	}
}

// A fault the IOMMU reported for this domain's device.
dma_fault :: proc "contextless" (d: ^Dma_Domain) {
	spin_guard(&d.lock)
	d.faults += 1
	observers_fire(&d.obs, .Dma_Fault, d.faults)
}

@(require_results)
dma_bind :: proc "contextless" (d: ^Dma_Domain, b: ^Binding) -> vx.Status {
	if b.trigger != .Dma_Fault {
		return .Err_Invalid
	}
	spin_guard(&d.lock)
	if d.faults > b.threshold { // faults since the count the binder saw: at once
		binding_fire(b, d.faults)
	} else {
		observers_add(&d.obs, b)
	}
	return .Ok
}

dma_domain_destroy :: proc "contextless" (d: ^Dma_Domain) { // no mapping refers to it any more
	iommu_detach(d)
	observers_free(d.obs.head)
	pool_free(&dma_pool, d)
}
