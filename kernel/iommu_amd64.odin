package kernel

import "base:intrinsics"
import vx "abi:vx"

// Intel VT-d, the x86_64 IOMMU (Intel VT-d specification 4.x). The kernel
// finds the remapping units in the firmware's DMAR table at boot and turns
// translation on before any driver runs, with every device's context empty:
// no device can DMA until devmgr gives it a domain (dma_domain_create,
// device.odin), which closes the window Thunderbolt and USB4 DMA attacks use.
// The firmware's reserved regions (RMRRs) are identity-mapped for the devices
// they name, in every domain those devices get.
//
// Translation is legacy mode: a root table (a context table for each bus),
// each device's context entry naming its domain's second-level page tables,
// 4-level (48-bit) or 3-level (39-bit) as the unit supports, 4 KiB pages.
// Invalidation goes through the queued-invalidation interface where the unit
// has one, else the registers. Every change to the tables is invalidated
// before the call returns, so caching mode (CAP.CM, which QEMU's intel-iommu
// may set) needs nothing more; a unit that wants its write buffer flushed
// (CAP.RWBF) gets that first, and one whose page walks do not snoop (no
// ECAP.C) has each table line it writes flushed from the CPU's caches.
//
// Faults are recorded by the unit and raised as an interrupt (VECTOR_IOMMU),
// which reads the records and counts each against the domain whose requester
// ID it names (dma_fault). Interrupt remapping is not used yet: MSIs go
// through untranslated, as compatibility-format interrupts.
//
// Fuchsia's VT-d driver was upstream's comparison: it supported neither
// bridge nor multi-hop scopes; here a scope's path is walked through PCI
// configuration space (MCFG) to the bus it names.

foreign _ {
	vx_clflush :: proc "c" (p: rawptr) ---
}

@(private="file")
VTD_MAX_UNITS :: 8
@(private="file")
VTD_MAX_RMRR :: 16
@(private="file")
VTD_MAX_DOMAINS :: 128
@(private="file")
VTD_MAX_SCOPES :: 32

VECTOR_IOMMU :: 0xf0 // the units' fault events

// The capability register (§11.4.2), as far as it is read.
@(private="file")
Vtd_Cap :: bit_field u64 {
	nd:       u8   | 3, // domain ids: 2^(4 + 2 * nd)
	afl:      bool | 1,
	rwbf:     bool | 1, // the write buffer must be flushed
	plmr:     bool | 1,
	phmr:     bool | 1,
	cm:       bool | 1, // caching mode: not-present entries may be cached
	sagaw:    u8   | 5, // bit 1: 3-level tables, bit 2: 4-level
	reserved: u8   | 3,
	mgaw:     u8   | 6,
	zlr:      bool | 1,
	dep:      bool | 1,
	fro:      u16  | 10, // the fault recording registers' offset, in 16 bytes
	sllps:    u8   | 4,
	rsvd2:    bool | 1,
	psi:      bool | 1,
	nfr:      u8   | 8, // fault recording registers, less one
}

// The extended capability register (§11.4.3), as far as it is read.
@(private="file")
Vtd_Ecap :: bit_field u64 {
	c:   bool | 1, // page walks snoop the CPU's caches
	qi:  bool | 1, // queued invalidation
	dt:  bool | 1,
	ir:  bool | 1,
	eim: bool | 1,
	rsv: bool | 1,
	pt:  bool | 1,
	sc:  bool | 1,
	iro: u16  | 10, // the IOTLB registers' offset, in 16 bytes
}

// The global command and status registers' bits (§11.4.4, §11.4.5).
@(private="file")
Vtd_Global :: enum u32 {
	Qie  = 26, // queued invalidation on
	Wbf  = 27, // write buffer flush
	Srtp = 30, // set the root table pointer
	Te   = 31, // translation on
}
@(private="file")
Vtd_Globals :: bit_set[Vtd_Global; u32]

// A remapping unit's fixed registers (§11.4); the IOTLB and fault recording
// registers are at offsets its capabilities give.
@(private="file")
Vtd_Regs :: struct {
	ver:      u32,
	_:        u32,
	cap:      Vtd_Cap,
	ecap:     Vtd_Ecap,
	gcmd:     Vtd_Globals,
	gsts:     Vtd_Globals,
	rtaddr:   u64,
	ccmd:     u64,
	_:        u32,
	fsts:     u32,
	fectl:    u32,
	fedata:   u32,
	feaddr:   u32,
	feuaddr:  u32,
	_:        [0x80 - 0x48]u8,
	iqh, iqt: u64,
	iqa:      u64,
}

#assert(offset_of(Vtd_Regs, gcmd) == 0x18 && offset_of(Vtd_Regs, rtaddr) == 0x20 && offset_of(Vtd_Regs, fsts) == 0x34)
#assert(offset_of(Vtd_Regs, feuaddr) == 0x44 && offset_of(Vtd_Regs, iqh) == 0x80 && offset_of(Vtd_Regs, iqa) == 0x90)

// FSTS: a pending fault, a fault overflow, an invalidation queue error.
@(private="file")
FSTS_PFO :: u32(1)
@(private="file")
FSTS_PPF :: u32(2)
@(private="file")
FSTS_IQE :: u32(1 << 4)

// A second-level page-table entry (§9.8).
@(private="file")
Sl_Pte :: bit_field u64 {
	r:        bool | 1,
	w:        bool | 1,
	reserved: u16  | 10,
	addr:     u64  | 40, // bits 12-51 of the next table or the page
}

@(private="file")
sl_present :: #force_inline proc "contextless" (e: Sl_Pte) -> bool {
	return e.r || e.w
}

// A context entry (§9.3): which domain a device is in, and its tables.
@(private="file")
Context_Entry :: struct {
	lo: bit_field u64 {
		present:  bool | 1,
		fpd:      bool | 1, // faults not recorded
		tt:       u8   | 2, // translation type: 0, through the tables
		reserved: u8   | 8,
		slptptr:  u64  | 52, // the tables' address >> 12
	},
	hi: bit_field u64 {
		aw:        u8  | 3, // address width: 1 (39 bits) or 2 (48)
		avail:     u8  | 4,
		reserved:  u8  | 1,
		did:       u16 | 16,
		reserved2: u64 | 40,
	},
}

#assert(size_of(Context_Entry) == 16)

// What a scope names: an endpoint's requester ID, or a bridge's buses.
@(private="file")
Vtd_Scope :: union {
	Rid,
	Bus_Range,
}

@(private="file")
Rid :: distinct u32 // bus << 8 | device << 3 | function

@(private="file")
Bus_Range :: struct {
	first, last: u8, // secondary to subordinate
}

@(private="file")
Vtd_Unit :: struct {
	regs:         ^Vtd_Regs,
	regs_bytes:   []u8, // all of its registers, for those at offsets
	cap:          Vtd_Cap,
	ecap:         Vtd_Ecap,
	segment:      u16,
	all:          bool, // INCLUDE_PCI_ALL: every device of its segment no other unit names
	levels:       int, // 3 or 4
	aw:           u8, // the context entry's address width field
	root:         Paddr, // the root table
	ctx:          [256]^[256]Context_Entry, // each bus's context table, made when a device on it is attached
	iq:           Paddr, // the invalidation queue, or 0 if invalidations go through registers
	iq_tail:      u32, // in descriptors
	iq_status:    ^u32, // what a wait descriptor writes, in a page of its own
	iq_status_pa: Paddr,
	lock:         Spinlock,
	scopes:       [dynamic; VTD_MAX_SCOPES]Vtd_Scope,
}

@(private="file")
Vtd_Rmrr :: struct {
	base, limit: u64, // [base, limit], inclusive, as DMAR has it
	rid:         Rid,
}

@(private="file")
vtd: struct {
	units:        [dynamic; VTD_MAX_UNITS]Vtd_Unit,
	rmrrs:        [dynamic; VTD_MAX_RMRR]Vtd_Rmrr,
	domains:      [VTD_MAX_DOMAINS]^Dma_Domain, // attached, for faults to find by requester ID
	domains_lock: Spinlock,
	did_used:     [VTD_MAX_UNITS][1024 / 64]u64, // domain ids in use, at most 1024 a unit here
	ecam_base:    Paddr, // MCFG's segment 0 window, for scope paths
	ecam_start:   u8,
	ecam_end:     u8,
}

@(private="file")
reg64 :: #force_inline proc "contextless" (u: ^Vtd_Unit, at: int) -> ^u64 {
	return cast(^u64)raw_data(u.regs_bytes[at:][:8])
}

@(private="file")
reg32 :: #force_inline proc "contextless" (u: ^Vtd_Unit, at: int) -> ^u32 {
	return cast(^u32)raw_data(u.regs_bytes[at:][:4])
}

// A table line the unit's walks read, out of the CPU's caches if they do not snoop.
@(private="file")
vtd_flush :: proc "contextless" (u: ^Vtd_Unit, p: rawptr) {
	if !u.ecap.c {
		vx_clflush(p)
	}
}

@(private="file")
vtd_flush_page :: proc "contextless" (u: ^Vtd_Unit, pa: Paddr) {
	if !u.ecap.c {
		for line := 0; line < PAGE_SIZE; line += 64 {
			vx_clflush(rawptr(uintptr(phys_to_virt(pa)) + uintptr(line)))
		}
	}
}

@(private="file")
vtd_fence :: #force_inline proc "contextless" () {
	vx_mfence()
}

// A global command (§11.4.4): the enabled bits kept, one set or cleared, and waited for.
@(private="file")
vtd_command :: proc "contextless" (u: ^Vtd_Unit, bit: Vtd_Global, on: bool) -> bool {
	keep := intrinsics.volatile_load(&u.regs.gsts) & {.Te, .Qie} // the persistent ones
	intrinsics.volatile_store(&u.regs.gcmd, on ? keep + {bit} : keep - {bit})
	for _ in 0 ..< 10_000_000 {
		if (bit in intrinsics.volatile_load(&u.regs.gsts)) == on {
			return true
		}
	}
	return false
}

// .Srtp and .Wbf: set, then done when the status says.
@(private="file")
vtd_one_shot :: proc "contextless" (u: ^Vtd_Unit, bit: Vtd_Global) -> bool {
	keep := intrinsics.volatile_load(&u.regs.gsts) & {.Te, .Qie}
	intrinsics.volatile_store(&u.regs.gcmd, keep + {bit})
	for _ in 0 ..< 10_000_000 {
		st := intrinsics.volatile_load(&u.regs.gsts)
		if bit == .Srtp ? .Srtp in st : .Wbf not_in st {
			return true
		}
	}
	return false
}

// --- Invalidation (§6.5) ---

@(private="file")
vtd_qi_submit :: proc "contextless" (u: ^Vtd_Unit, lo, hi: u64) {
	q := cast(^[256][2]u64)phys_to_virt(u.iq)
	q[u.iq_tail] = {lo, hi}
	u.iq_tail = (u.iq_tail + 1) % 256
}

// Context caches and the IOTLB, for one domain (did) or all (did 0): every
// change made before this is seen by the unit when it returns.
@(private="file")
vtd_invalidate :: proc "contextless" (u: ^Vtd_Unit, did: u16, ctx: bool) {
	if u.cap.rwbf {
		_ = vtd_one_shot(u, .Wbf)
	}
	spin_guard(&u.lock)
	if u.iq != 0 {
		gran := u64(did != 0 ? 2 : 1) // domain-selective, or global
		if ctx {
			vtd_qi_submit(u, 0x1 | gran << 4 | u64(did) << 16, 0) // context-cache invalidate
		}
		vtd_qi_submit(u, 0x2 | gran << 4 | 1 << 6 | 1 << 7 | u64(did) << 16, 0) // IOTLB, draining reads and writes
		intrinsics.atomic_store(u.iq_status, 0)
		vtd_qi_submit(u, 0x5 | 1 << 5 | 1 << 32, u64(u.iq_status_pa)) // wait: status 1 written when done
		vtd_fence()
		intrinsics.volatile_store(&u.regs.iqt, u64(u.iq_tail) << 4)
		for _ in 0 ..< 100_000_000 {
			if intrinsics.atomic_load(u.iq_status) == 1 || intrinsics.volatile_load(&u.regs.fsts) & FSTS_IQE != 0 {
				break // done, or an invalidation queue error
			}
		}
		return
	}
	if ctx { // CCMD: ICC, global or domain-selective
		intrinsics.volatile_store(&u.regs.ccmd, 1 << 63 | u64(did != 0 ? 2 : 1) << 61 | u64(did))
		for i := 0; i < 10_000_000 && intrinsics.volatile_load(&u.regs.ccmd) >> 63 != 0; i += 1 {}
	}
	iotlb := reg64(u, int(u.ecap.iro) * 16 + 8)
	intrinsics.volatile_store(iotlb, 1 << 63 | u64(did != 0 ? 2 : 1) << 60 | 1 << 49 | 1 << 48 | u64(did) << 32)
	for i := 0; i < 10_000_000 && intrinsics.volatile_load(iotlb) >> 63 != 0; i += 1 {}
}

// --- PCI configuration space, for the scopes' paths ---

@(private="file")
vtd_config8 :: proc "contextless" (bus, dev, fn: u8, off: u64) -> u8 {
	if vtd.ecam_base == 0 || bus < vtd.ecam_start || bus > vtd.ecam_end {
		return 0xff
	}
	pa := vtd.ecam_base + Paddr(u64(bus) << 20 | u64(dev) << 15 | u64(fn) << 12)
	if e, _ := leaf_entry(kernel_root, boot.hhdm + u64(pa)); e == nil && !map_range(kernel_root, boot.hhdm + u64(pa), pa, PAGE_SIZE, {.Write, .Device}) {
		return 0xff
	}
	return intrinsics.volatile_load(cast(^u8)(uintptr(phys_to_virt(pa)) + uintptr(off)))
}

// A device scope (§8.3.1): an endpoint's requester ID, or a bridge's buses,
// found by following its path from its start bus through the bridges on it.
// An RMRR's scope (u nil) adds the region for the device.
@(private="file")
vtd_scope :: proc "contextless" (u: ^Vtd_Unit, sc: []u8, rmrr: ^Vtd_Rmrr) {
	type, bus := sc[0], sc[5]
	if len(sc) < 8 || (type != 1 && type != 2) {
		return // endpoints and bridges; IOAPICs, HPETs and the rest are not DMA
	}
	dev, fn: u8
	for at := 6; at + 2 <= len(sc); at += 2 {
		dev, fn = sc[at] & 31, sc[at + 1] & 7
		if at + 2 < len(sc) {
			bus = vtd_config8(bus, dev, fn, 0x19) // through this bridge: its secondary bus
		}
	}
	rid := Rid(u32(bus) << 8 | u32(dev) << 3 | u32(fn))
	if rmrr != nil {
		r := rmrr^
		r.rid = rid
		_ = append(&vtd.rmrrs, r) // past VTD_MAX_RMRR, not kept
		return
	}
	if type == 2 { // a bridge: the buses behind it, secondary to subordinate
		_ = append(&u.scopes, Bus_Range{vtd_config8(bus, dev, fn, 0x19), vtd_config8(bus, dev, fn, 0x1a)})
	} else {
		_ = append(&u.scopes, rid)
	}
}

@(private="file")
vtd_names :: proc "contextless" (u: ^Vtd_Unit, rid: Rid) -> bool {
	for s in u.scopes {
		switch v in s {
		case Rid:
			if v == rid {
				return true
			}
		case Bus_Range:
			if bus := u8(rid >> 8); bus >= v.first && bus <= v.last {
				return true
			}
		}
	}
	return false
}

// The unit for a requester ID (segment 0): the one that names it, else the
// one that takes all the rest; -1 if none.
@(private="file")
vtd_unit_for :: proc "contextless" (rid: Rid) -> int {
	for &u, i in vtd.units {
		if u.segment == 0 && vtd_names(&u, rid) {
			return i
		}
	}
	for &u, i in vtd.units {
		if u.segment == 0 && u.all {
			return i
		}
	}
	return -1
}

// --- Second-level page tables (§9.8) ---

// The leaf entry for iova, the tables to it made if `make`; nil if not there.
@(private="file")
vtd_leaf :: proc "contextless" (u: ^Vtd_Unit, root: Paddr, iova: u64, make: bool) -> ^Sl_Pte {
	table := root
	for level := u.levels; level > 1; level -= 1 {
		e := &(cast(^[512]Sl_Pte)phys_to_virt(table))[(iova >> uint(12 + 9 * (level - 1))) & 511]
		if !sl_present(e^) {
			if !make {
				return nil
			}
			next := phys_alloc_zeroed(0)
			if next == 0 {
				return nil
			}
			vtd_flush_page(u, next)
			e^ = {r = true, w = true, addr = u64(next) >> 12}
			vtd_flush(u, e)
		}
		table = Paddr(e.addr << 12)
	}
	return &(cast(^[512]Sl_Pte)phys_to_virt(table))[(iova >> 12) & 511]
}

// Frees a domain's tables, recursing as deep as they go: four levels at most.
@(private="file")
vtd_free_tables :: proc "contextless" (table: Paddr, level: int) {
	if level > 1 {
		for e in cast(^[512]Sl_Pte)phys_to_virt(table) {
			if sl_present(e) {
				vtd_free_tables(Paddr(e.addr << 12), level - 1)
			}
		}
	}
	phys_free(table, 0)
}

iommu_map :: proc "contextless" (d: ^Dma_Domain, iova: u64, pages: []Page, options: vx.Dma_Options) -> bool {
	u := &vtd.units[d.io.unit]
	ok := true
	{
		spin_guard(&d.lock) // the tables are the domain's
		for p, i in pages {
			e := vtd_leaf(u, d.io.root, iova + u64(i) * PAGE_SIZE, true)
			if e == nil {
				ok = false
				break
			}
			e^ = {r = .Read in options, w = .Write in options, addr = p.frame}
			vtd_flush(u, e)
		}
	}
	vtd_fence()
	vtd_invalidate(u, d.io.did, false) // caching mode caches what was not present, too
	return ok
}

iommu_unmap :: proc "contextless" (d: ^Dma_Domain, iova, count: u64) {
	u := &vtd.units[d.io.unit]
	{
		spin_guard(&d.lock)
		for i in 0 ..< count {
			if e := vtd_leaf(u, d.io.root, iova + i * PAGE_SIZE, false); e != nil {
				e^ = {}
				vtd_flush(u, e)
			}
		}
	}
	vtd_fence()
	vtd_invalidate(u, d.io.did, false) // the device cannot reach them when this returns
}

// --- Domains: a device's context entry (§9.3) ---

iommu_attach :: proc "contextless" (d: ^Dma_Domain) -> vx.Status {
	ui := vtd_unit_for(Rid(d.source))
	if ui < 0 {
		return .Ok // no IOMMU in front of it: pass-through
	}
	u := &vtd.units[ui]
	bus, devfn := d.source >> 8 & 0xff, d.source & 0xff
	nd := min(u32(1) << (4 + 2 * u32(u.cap.nd)), 1024)
	did: u16
	{
		spin_guard(&vtd.domains_lock)
		slot := -1
		for x, i in vtd.domains {
			if x == nil && slot < 0 {
				slot = i
			}
			if x != nil && x.source == d.source && x.io.on {
				return .Err_Exists // one domain to a device
			}
		}
		for i in 1 ..< nd { // 0 is reserved under caching mode: never used
			if vtd.did_used[ui][i / 64] >> (i % 64) & 1 == 0 {
				did = u16(i)
				break
			}
		}
		if slot < 0 || did == 0 {
			return .Err_No_Memory
		}
		vtd.did_used[ui][did / 64] |= 1 << (did % 64)
		vtd.domains[slot] = d
	}
	d.io = {on = true, unit = u8(ui), did = did, root = phys_alloc_zeroed(0)}
	{
		spin_guard(&u.lock)
		if u.ctx[bus] == nil { // this bus's context table, and the root entry naming it
			if t := phys_alloc_zeroed(0); t != 0 {
				u.ctx[bus] = cast(^[256]Context_Entry)phys_to_virt(t)
				vtd_flush_page(u, t)
				r := &(cast(^[256][2]u64)phys_to_virt(u.root))[bus]
				r[0] = u64(t) | 1 // present
				vtd_flush(u, r)
			}
		}
	}
	ok := d.io.root != 0 && u.ctx[bus] != nil
	// The firmware's reserved regions for this device: identity-mapped in it.
	for r in vtd.rmrrs {
		if !ok {
			break
		}
		if r.rid != Rid(d.source) {
			continue
		}
		for pa := r.base &~ (PAGE_SIZE - 1); ok && pa <= r.limit; pa += PAGE_SIZE {
			ok = iommu_map(d, pa, {page_of(Paddr(pa))}, {.Read, .Write})
		}
	}
	if !ok {
		iommu_detach(d)
		return .Err_No_Memory
	}
	spin_lock(&u.lock)
	ce := &u.ctx[bus][devfn]
	ce.hi = {aw = u.aw, did = did}
	vtd_flush(u, &ce.hi)
	vtd_fence()
	ce.lo = {present = true, slptptr = u64(d.io.root) >> 12} // translation type 0: through the tables; faults recorded
	vtd_flush(u, &ce.lo)
	spin_unlock(&u.lock)
	vtd_fence()
	vtd_invalidate(u, did, true)
	return .Ok
}

iommu_detach :: proc "contextless" (d: ^Dma_Domain) {
	if !d.io.on {
		return
	}
	u := &vtd.units[d.io.unit]
	bus, devfn := d.source >> 8 & 0xff, d.source & 0xff
	{
		spin_guard(&u.lock)
		if u.ctx[bus] != nil { // the device's context gone: its DMA faults from here
			ce := &u.ctx[bus][devfn]
			if ce.hi.did == d.io.did {
				ce^ = {}
				vtd_flush(u, ce)
			}
		}
	}
	vtd_fence()
	vtd_invalidate(u, d.io.did, true)
	if d.io.root != 0 {
		vtd_free_tables(d.io.root, u.levels)
	}
	spin_lock(&vtd.domains_lock)
	for &x in vtd.domains {
		if x == d {
			x = nil
		}
	}
	vtd.did_used[d.io.unit][d.io.did / 64] &~= 1 << (d.io.did % 64)
	spin_unlock(&vtd.domains_lock)
	d.io = {}
}

// --- Faults (§7.2) ---

// The fault interrupt: each recorded fault counted against its device's domain.
vtd_fault_interrupt :: proc "contextless" () {
	for &u, ui in vtd.units {
		fsts := intrinsics.volatile_load(&u.regs.fsts)
		if fsts & (FSTS_PFO | FSTS_PPF) == 0 {
			continue // neither a pending fault nor an overflow
		}
		fro, nfr := int(u.cap.fro) * 16, u32(u.cap.nfr) + 1
		i := fsts >> 8 & 0xff
		for _ in 0 ..< nfr {
			hi := intrinsics.volatile_load(reg64(&u, fro + 16 * int(i) + 8))
			if hi >> 63 == 0 {
				break // no fault recorded here
			}
			rid, reason := u32(hi & 0xffff), hi >> 32 & 0xff
			address := intrinsics.volatile_load(reg64(&u, fro + 16 * int(i))) &~ (PAGE_SIZE - 1)
			intrinsics.volatile_store(reg32(&u, fro + 16 * int(i) + 12), 1 << 31) // the record's F, cleared
			kput("vx: iommu: a fault from ")
			kput_hex(u64(rid))
			kput(" at ")
			kput_hex(address)
			kput(", reason ")
			kput_u64(reason)
			kput("\n")
			d: ^Dma_Domain
			{
				spin_guard(&vtd.domains_lock)
				for x in vtd.domains {
					if x != nil && x.source == rid && int(x.io.unit) == ui {
						d = x
						object_ref(&d.obj)
						break
					}
				}
			}
			if d != nil {
				dma_fault(d)
				object_drop(&d.obj)
			}
			i = (i + 1) % nfr
		}
		intrinsics.volatile_store(&u.regs.fsts, fsts & (FSTS_PFO | FSTS_PPF)) // write 1 to clear
	}
}

// --- Bringing the units up ---

@(private="file")
vtd_unit_init :: proc "contextless" (u: ^Vtd_Unit) {
	u.cap = intrinsics.volatile_load(&u.regs.cap)
	u.ecap = intrinsics.volatile_load(&u.regs.ecap)
	switch {
	case u.cap.sagaw & 4 != 0:
		u.levels, u.aw = 4, 2
	case u.cap.sagaw & 2 != 0:
		u.levels, u.aw = 3, 1
	case:
		kpanic("vtd: no 3- or 4-level tables")
	}
	// Off first (the firmware's), then the empty root table: deny-all.
	if .Te in intrinsics.volatile_load(&u.regs.gsts) {
		_ = vtd_command(u, .Te, false)
	}
	u.root = phys_alloc_zeroed(0)
	if u.root == 0 {
		kpanic("vtd: no memory")
	}
	vtd_flush_page(u, u.root)
	if u.ecap.qi { // the invalidation queue, one page (256 descriptors)
		u.iq = phys_alloc_zeroed(0)
		u.iq_status_pa = phys_alloc_zeroed(0)
		if u.iq_status_pa != 0 {
			u.iq_status = cast(^u32)phys_to_virt(u.iq_status_pa)
		} else {
			u.iq = 0
		}
		if u.iq != 0 {
			intrinsics.volatile_store(&u.regs.iqt, 0)
			intrinsics.volatile_store(&u.regs.iqa, u64(u.iq)) // QS 0: one page; 128-bit descriptors
			if !vtd_command(u, .Qie, true) {
				u.iq = 0
			}
		}
	}
	intrinsics.volatile_store(&u.regs.rtaddr, u64(u.root)) // legacy mode (TTM 0)
	if !vtd_one_shot(u, .Srtp) {
		kpanic("vtd: the root table was not taken")
	}
	vtd_invalidate(u, 0, true)
	// Faults, to the boot CPU (compatibility format: no interrupt remapping).
	intrinsics.volatile_store(&u.regs.fedata, VECTOR_IOMMU)
	intrinsics.volatile_store(&u.regs.feaddr, 0xfee0_0000 | u32(cpus[0].arch_id << 12))
	intrinsics.volatile_store(&u.regs.feuaddr, 0)
	intrinsics.volatile_store(&u.regs.fectl, 0) // unmasked
	if !vtd_command(u, .Te, true) {
		kpanic("vtd: translation would not turn on")
	}
}

// The DMAR table's units and reserved regions, and translation on: called at
// boot, before the root task starts, so no driver ever runs without it.
iommu_init :: proc "contextless" () {
	if mcfg := acpi_table("MCFG"); len(mcfg) >= 44 + 16 { // the first window, for scope paths
		vtd.ecam_base = Paddr(read64(mcfg[44:]))
		vtd.ecam_start, vtd.ecam_end = mcfg[44 + 10], mcfg[44 + 11]
	}
	dmar := acpi_table("DMAR")
	if dmar == nil {
		return // no VT-d: pass-through, as before
	}
	for off := 48; off + 4 <= len(dmar); {
		type, slen := u16(dmar[off]) | u16(dmar[off + 1]) << 8, int(dmar[off + 2]) | int(dmar[off + 3]) << 8
		if slen < 4 || off + slen > len(dmar) {
			break
		}
		s := dmar[off:][:slen]
		switch {
		case type == 0 && slen >= 16 && len(vtd.units) < VTD_MAX_UNITS: // DRHD
			base := Paddr(read64(s[8:]))
			size := min(u64(PAGE_SIZE) << (s[5] & 0xf), 16 * PAGE_SIZE)
			if !map_range(kernel_root, boot.hhdm + u64(base), base, size, {.Write, .Device}) {
				kpanic("vtd: cannot map a unit's registers")
			}
			_ = append(&vtd.units, Vtd_Unit{}) // below VTD_MAX_UNITS
			u := &vtd.units[len(vtd.units) - 1]
			u.regs = cast(^Vtd_Regs)phys_to_virt(base)
			u.regs_bytes = (cast([^]u8)phys_to_virt(base))[:size]
			u.segment = u16(s[6]) | u16(s[7]) << 8
			u.all = s[4] & 1 != 0
			for at := 16; at + 6 <= slen && s[at + 1] >= 6 && at + int(s[at + 1]) <= slen; at += int(s[at + 1]) {
				vtd_scope(u, s[at:][:s[at + 1]], nil)
			}
		case type == 1 && slen >= 24: // RMRR
			r := Vtd_Rmrr{base = read64(s[8:]), limit = read64(s[16:])}
			for at := 24; at + 6 <= slen && s[at + 1] >= 6 && at + int(s[at + 1]) <= slen; at += int(s[at + 1]) {
				vtd_scope(nil, s[at:][:s[at + 1]], &r)
			}
		}
		off += slen
	}
	for &u in vtd.units {
		vtd_unit_init(&u)
	}
	n := len(vtd.units)
	kput("vx: VT-d: ")
	kput_u64(u64(n))
	kput(n == 1 ? " unit" : " units")
	if n > 0 && vtd.units[0].iq != 0 {
		kput(", queued invalidation")
	}
	if n > 0 && vtd.units[0].cap.cm {
		kput(", caching mode")
	}
	kput(", deny-all\n")
}
