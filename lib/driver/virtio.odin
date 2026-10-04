package driver

import "base:intrinsics"
import vx "abi:vx"
import "vx:pci"
import "vx:rt"

// virtio: the virtio-pci modern transport (virtio 1.x, §4.1) and split
// virtqueues (§2.7), for user-space drivers.
//
// devmgr gives a virtio driver its function's configuration space, its memory
// BARs, a DMA domain and MSI-X interrupts. The vendor capabilities in
// configuration space say where in the BARs the common, notify, ISR and
// device-specific registers are. Queue memory is a VMO mapped in the driver
// and, through the DMA domain, given to the device; each part of a queue (the
// descriptors, the available and used rings) fits in its own page.
//
// Everything the device writes (the used ring, device config) is read as
// untrusted: indices are masked, lengths bounded.

// The common configuration registers (§4.1.4.3).
Virtio_Common :: struct {
	device_feature_select: u32,
	device_feature:        u32,
	driver_feature_select: u32,
	driver_feature:        u32,
	config_msix_vector:    u16,
	num_queues:            u16,
	device_status:         Virtio_Status,
	config_generation:     u8,
	queue_select:          u16,
	queue_size:            u16,
	queue_msix_vector:     u16,
	queue_enable:          u16,
	queue_notify_off:      u16,
	queue_desc:            u64,
	queue_driver:          u64,
	queue_device:          u64,
}

#assert(offset_of(Virtio_Common, device_status) == 20)
#assert(offset_of(Virtio_Common, queue_select) == 22)
#assert(offset_of(Virtio_Common, queue_desc) == 32)
#assert(size_of(Virtio_Common) == 56)

Virtio_Status_Bit :: enum u8 {
	Acknowledge = 0,
	Driver      = 1,
	Driver_Ok   = 2,
	Features_Ok = 3,
	Failed      = 7,
}
Virtio_Status :: bit_set[Virtio_Status_Bit; u8]

VIRTIO_F_VERSION_1 :: u64(1) << 32
VIRTIO_NO_VECTOR :: u16(0xffff)
VIRTQ_MAX :: 256 // entries a queue may have here: each part of it fits a page

Virtq_Desc_Flag :: enum u16 {
	Next,
	Write, // the device writes the buffer
}

Virtq_Desc :: struct {
	addr:  u64,
	len:   u32,
	flags: bit_set[Virtq_Desc_Flag; u16],
	next:  u16,
}

#assert(size_of(Virtq_Desc) == 16)

Virtq_Avail :: struct {
	flags: u16,
	idx:   u16,
	ring:  [VIRTQ_MAX]u16,
}

Virtq_Used_Elem :: struct {
	id:  u32,
	len: u32,
}

Virtq_Used :: struct {
	flags: u16,
	idx:   u16,
	ring:  [VIRTQ_MAX]Virtq_Used_Elem,
}

#assert(offset_of(Virtq_Used, ring) == 4)
#assert(size_of(Virtq_Avail) <= 4096 && size_of(Virtq_Used) <= 4096)

Virtq :: struct {
	index:     u16,
	size:      u16, // a power of two, at most VIRTQ_MAX
	desc:      ^[VIRTQ_MAX]Virtq_Desc,
	avail:     ^Virtq_Avail,
	used:      ^Virtq_Used,
	avail_idx: u16,
	used_seen: u16,
	notify:    ^u16,
}

// An MSI-X table entry (PCI 3.0 §6.8.2).
Msix_Entry :: struct {
	address_lo: u32,
	address_hi: u32,
	data:       u32,
	control:    u32, // bit 0 masks it
}

Virtio :: struct {
	fn:          pci.Function,
	bar:         [6][]u8, // mapped by the driver; empty if not given
	common:      ^Virtio_Common,
	notify_base: []u8,
	notify_mult: u32,
	isr:         ^u8,
	device:      []u8, // the device-specific configuration
	msix:        []Msix_Entry,
	dma:         vx.Handle, // the DMA domain
}

// The register block one vendor capability describes, if it lies inside a
// BAR the driver has and holds at least `need` bytes.
@(private="file")
virtio_region :: proc "contextless" (v: ^Virtio, cap: u8, need: u32) -> []u8 {
	bar := pci.read8(&v.fn, u32(cap) + 4)
	offset := u64(pci.read32(&v.fn, u32(cap) + 8))
	length := u64(pci.read32(&v.fn, u32(cap) + 12))
	if bar > 5 || length < u64(need) || offset > u64(len(v.bar[bar])) || length > u64(len(v.bar[bar])) - offset {
		return nil
	}
	return v.bar[bar][offset:][:length]
}

// Finds the registers through the vendor capabilities (§4.1.4) and the MSI-X
// table. The caller has mapped the BARs into v.bar.
@(require_results)
virtio_find :: proc "contextless" (v: ^Virtio) -> vx.Status {
	for n in 0 ..< 16 {
		cap := pci.cap(&v.fn, 0x09, n)
		if cap == 0 {
			break
		}
		switch pci.read8(&v.fn, u32(cap) + 3) {
		case 1:
			if v.common == nil {
				if r := virtio_region(v, cap, size_of(Virtio_Common)); r != nil {
					v.common = cast(^Virtio_Common)raw_data(r)
				}
			}
		case 2:
			if v.notify_base == nil {
				v.notify_base = virtio_region(v, cap, 2)
				v.notify_mult = pci.read32(&v.fn, u32(cap) + 16)
			}
		case 3:
			if v.isr == nil {
				if r := virtio_region(v, cap, 1); r != nil {
					v.isr = &r[0]
				}
			}
		case 4:
			if v.device == nil {
				v.device = virtio_region(v, cap, 8)
			}
		}
	}
	if msix := pci.cap(&v.fn, 0x11, 0); msix != 0 {
		table := pci.read32(&v.fn, u32(msix) + 4)
		bir, offset := table & 7, u64(table &~ 7)
		count := u64(pci.read16(&v.fn, u32(msix) + 2) & 0x7ff) + 1
		if bir < 6 && offset + size_of(Msix_Entry) * count <= u64(len(v.bar[bir])) {
			v.msix = (cast([^]Msix_Entry)&v.bar[bir][offset])[:count]
		}
	}
	if v.common == nil || v.notify_base == nil || v.isr == nil || v.device == nil || v.msix == nil {
		return .Err_Unsupported
	}
	return .Ok
}

// Points MSI-X table entry i at an MSI (from irq_create_msi), unmasked, and
// turns MSI-X on (PCI 3.0 §6.8.2).
virtio_msix :: proc "contextless" (v: ^Virtio, i: int, msi: vx.Msi) {
	e := &v.msix[i]
	intrinsics.volatile_store(&e.address_lo, u32(msi.address))
	intrinsics.volatile_store(&e.address_hi, u32(msi.address >> 32))
	intrinsics.volatile_store(&e.data, msi.data)
	intrinsics.volatile_store(&e.control, 0) // unmasked
	MSIX_ENABLE :: 1 << 15
	MSIX_FUNCTION_MASK :: 1 << 14
	cap := u32(pci.cap(&v.fn, 0x11, 0))
	control := pci.read16(&v.fn, cap + 2)
	pci.write16(&v.fn, cap + 2, (control | MSIX_ENABLE) &~ MSIX_FUNCTION_MASK)
	MEMORY :: 1 << 1
	BUS_MASTER :: 1 << 2
	INTX_DISABLE :: 1 << 10
	command := pci.read16(&v.fn, 0x04)
	pci.write16(&v.fn, 0x04, command | BUS_MASTER | MEMORY | INTX_DISABLE)
}

@(private="file")
set_status :: proc "contextless" (c: ^Virtio_Common, s: Virtio_Status) {
	intrinsics.volatile_store(&c.device_status, s)
}

// Resets the device and negotiates features: VERSION_1 and whichever of
// `wanted` it offers, which it returns.
@(require_results)
virtio_start :: proc "contextless" (v: ^Virtio, wanted: u64) -> (features: u64, st: vx.Status) {
	c := v.common
	set_status(c, {})
	for _ in 0 ..< 1_000_000 { // the reset completes when it reads 0
		if intrinsics.volatile_load(&c.device_status) == {} {
			break
		}
	}
	set_status(c, {.Acknowledge})
	set_status(c, {.Acknowledge, .Driver})
	intrinsics.volatile_store(&c.device_feature_select, 0)
	offered := u64(intrinsics.volatile_load(&c.device_feature))
	intrinsics.volatile_store(&c.device_feature_select, 1)
	offered |= u64(intrinsics.volatile_load(&c.device_feature)) << 32
	use := offered & (wanted | VIRTIO_F_VERSION_1)
	if use & VIRTIO_F_VERSION_1 == 0 {
		return 0, .Err_Unsupported // a legacy-only device
	}
	intrinsics.volatile_store(&c.driver_feature_select, 0)
	intrinsics.volatile_store(&c.driver_feature, u32(use))
	intrinsics.volatile_store(&c.driver_feature_select, 1)
	intrinsics.volatile_store(&c.driver_feature, u32(use >> 32))
	set_status(c, {.Acknowledge, .Driver, .Features_Ok})
	if .Features_Ok not_in intrinsics.volatile_load(&c.device_status) {
		return 0, .Err_Unsupported
	}
	intrinsics.volatile_store(&c.config_msix_vector, VIRTIO_NO_VECTOR)
	return use, .Ok
}

virtio_ready :: proc "contextless" (v: ^Virtio) {
	set_status(v.common, {.Acknowledge, .Driver, .Features_Ok, .Driver_Ok})
}

// Sets up queue `index` with `want` entries (at most what the device
// offers), its interrupts on MSI-X entry `vector`. Its memory: three pages of
// a new VMO, given to the device through the DMA domain.
@(require_results)
virtq_init :: proc "contextless" (v: ^Virtio, q: ^Virtq, index, want, vector: u16) -> vx.Status {
	c := v.common
	intrinsics.volatile_store(&c.queue_select, index)
	size := min(want, intrinsics.volatile_load(&c.queue_size))
	if size == 0 || size & (size - 1) != 0 || size > VIRTQ_MAX {
		return .Err_Unsupported
	}
	QUEUE_BYTES :: 3 * 4096 // descriptors, available ring, used ring
	vmo := rt.vmo_create(QUEUE_BYTES) or_return
	defer rt.close_all(vmo) // the mappings keep it
	at := rt.as_map(rt.self, vmo, 0, QUEUE_BYTES, {.Write}) or_return
	pa: [3]u64
	// The DMA mapping's handle is kept as long as the driver lives: the
	// device reads the queue and writes its used ring.
	_ = rt.dma_map(v.dma, vmo, 0, QUEUE_BYTES, {.Read, .Write}, pa[:]) or_return
	q^ = {
		index = index,
		size  = size,
		desc  = cast(^[VIRTQ_MAX]Virtq_Desc)uintptr(at),
		avail = cast(^Virtq_Avail)uintptr(at + 4096),
		used  = cast(^Virtq_Used)uintptr(at + 8192),
	}
	intrinsics.volatile_store(&c.queue_size, size)
	intrinsics.volatile_store(&c.queue_desc, pa[0])
	intrinsics.volatile_store(&c.queue_driver, pa[1])
	intrinsics.volatile_store(&c.queue_device, pa[2])
	intrinsics.volatile_store(&c.queue_msix_vector, vector)
	if intrinsics.volatile_load(&c.queue_msix_vector) != vector {
		return .Err_Unsupported // the device could not take it
	}
	notify_at := u64(intrinsics.volatile_load(&c.queue_notify_off)) * u64(v.notify_mult)
	if notify_at + 2 > u64(len(v.notify_base)) {
		return .Err_Invalid // the device's offset, outside its own region
	}
	q.notify = cast(^u16)&v.notify_base[notify_at]
	intrinsics.volatile_store(&c.queue_enable, 1)
	return .Ok
}

// Makes descriptor d (one buffer) available to the device.
virtq_offer :: proc "contextless" (q: ^Virtq, d: u16, addr: u64, length: u32, device_writes: bool) {
	desc := Virtq_Desc{addr = addr, len = length}
	if device_writes {
		desc.flags = {.Write}
	}
	intrinsics.volatile_store(&q.desc[d], desc)
	intrinsics.volatile_store(&q.avail.ring[q.avail_idx % q.size], d)
	intrinsics.atomic_thread_fence(.Release) // the descriptor and ring entry, before the index
	q.avail_idx += 1
	intrinsics.volatile_store(&q.avail.idx, q.avail_idx)
}

// Tells the device the queue has new buffers.
virtq_kick :: proc "contextless" (q: ^Virtq) {
	intrinsics.atomic_thread_fence(.Seq_Cst)
	intrinsics.volatile_store(q.notify, q.index)
}

// The next buffer the device has finished with: its descriptor, and how many
// bytes it wrote. False if there is none.
virtq_used :: proc "contextless" (q: ^Virtq) -> (d: u16, length: u32, ok: bool) {
	if intrinsics.volatile_load(&q.used.idx) == q.used_seen {
		return 0, 0, false
	}
	intrinsics.atomic_thread_fence(.Acquire) // the entry, after the index
	e := intrinsics.volatile_load(&q.used.ring[q.used_seen % q.size])
	q.used_seen += 1
	return u16(e.id % u32(q.size)), e.len, true // the device's word, kept in range
}
