package kernel

import "base:intrinsics"
import vx "abi:vx"

// The Arm SMMUv3, the aarch64 IOMMU (SMMUv3 architecture, IHI 0070). The
// kernel finds it in the firmware's IORT table at boot, with each PCI root
// complex's map from requester IDs to stream IDs, and turns it on before any
// driver runs with every stream aborting: no device can DMA until devmgr
// gives it a domain (dma_domain_create, device.odin).
//
// A domain is stage 1: a context descriptor with an ASID of its own, and
// LPAE tables with a 4 KiB granule over 39 bits (three levels). A stream
// with a domain has an STE naming its descriptor; every other stream's STE
// aborts. Stage 1 cannot give a device write without read, so a mapping the
// device may write is read-write too. Since a device's MSIs are writes to the
// GIC ITS's doorbell, every domain maps that page at its own address, or a
// translated device could not interrupt.
//
// The stream table is two-level where the SMMU has that (each bus's 256 STEs
// a table of their own, made when a device on it gets a domain), else one
// level of 256 STEs. Commands go through the command queue, each batch closed
// by CMD_SYNC and waited for; every change to the tables is invalidated
// before the call returns. Faults come through the event queue, on its wired
// interrupt, and are counted against the domain whose stream they name
// (dma_fault). An SMMU that does not snoop (no IDR0.COHACC) has each table
// line it reads cleaned from the CPU's caches.
//
// Fuchsia has no SMMUv3; its SMMUv2 design notes were upstream's comparison:
// lock everything down at start, and choose abort, never read-as-zero, for a
// block device's faults.

foreign _ {
	vx_dc_cvac :: proc "c" (p: rawptr) ---
	vx_dc_ivac :: proc "c" (p: rawptr) ---
	vx_dsb_sy :: proc "c" () ---
}

@(private="file")
SMMU_MAX_DOMAINS :: 128
@(private="file")
SMMU_MAX_MAPS :: 16
@(private="file")
SMMU_REGS_SIZE :: u64(128 * 1024) // pages 0 and 1
@(private="file")
CMDQ_LOG2 :: 8
@(private="file")
EVTQ_LOG2 :: 7

// IDR0 (§6.3.1), as far as it is read.
@(private="file")
Smmu_Idr0 :: bit_field u32 {
	s2p:         bool | 1,
	s1p:         bool | 1, // stage 1
	ttf:         u8   | 2, // 1: AArch32 tables only
	cohacc:      bool | 1, // its table walks snoop the CPU's caches
	btm:         bool | 1,
	httu:        u8   | 2,
	dormhint:    bool | 1,
	hyp:         bool | 1,
	ats:         bool | 1,
	ns1ats:      bool | 1,
	asid16:      bool | 1, // 16-bit ASIDs
	msi:         bool | 1,
	sev:         bool | 1,
	atos:        bool | 1,
	pri:         bool | 1,
	vmw:         bool | 1,
	vmid16:      bool | 1,
	cd2l:        bool | 1,
	vatos:       bool | 1,
	ttendian:    u8   | 2,
	atsrecerr:   bool | 1,
	stall_model: u8   | 2,
	term_model:  bool | 1,
	st_level:    u8   | 2, // 1: a two-level stream table
}

// CR0's enables (§6.3.9).
@(private="file")
Smmu_Enable :: enum u32 {
	Smmuen = 0,
	Priqen = 1,
	Evtqen = 2,
	Cmdqen = 3,
}
@(private="file")
Smmu_Enables :: bit_set[Smmu_Enable; u32]

// CR1: how the SMMU reads its queues and tables (§6.3.11).
@(private="file")
Smmu_Cr1 :: bit_field u32 {
	queue_ic: u8 | 2, // 1: write-back
	queue_oc: u8 | 2,
	queue_sh: u8 | 2, // 3: inner shareable
	table_ic: u8 | 2,
	table_oc: u8 | 2,
	table_sh: u8 | 2,
}

// Page 0's registers (§6.3).
@(private="file")
Smmu_Regs :: struct {
	idr0:            Smmu_Idr0,
	idr1:            u32,
	idr2, idr3:      u32,
	idr4, idr5:      u32,
	iidr, aidr:      u32,
	cr0:             Smmu_Enables,
	cr0ack:          Smmu_Enables,
	cr1:             Smmu_Cr1,
	cr2:             u32,
	_:               [(0x44 - 0x30) / 4]u32,
	gbpa:            u32,
	agbpa:           u32,
	_:               u32,
	irq_ctrl:        u32,
	irq_ctrlack:     u32,
	_:               [(0x60 - 0x58) / 4]u32,
	gerror:          u32,
	_:               [(0x80 - 0x64) / 4]u32,
	strtab_base:     u64,
	strtab_base_cfg: u32,
	_:               u32,
	cmdq_base:       u64,
	cmdq_prod:       u32,
	cmdq_cons:       u32,
	eventq_base:     u64,
}

#assert(offset_of(Smmu_Regs, cr0) == 0x20 && offset_of(Smmu_Regs, gbpa) == 0x44 && offset_of(Smmu_Regs, irq_ctrl) == 0x50)
#assert(offset_of(Smmu_Regs, gerror) == 0x60 && offset_of(Smmu_Regs, strtab_base) == 0x80 && offset_of(Smmu_Regs, cmdq_base) == 0x90)
#assert(offset_of(Smmu_Regs, cmdq_cons) == 0x9c && offset_of(Smmu_Regs, eventq_base) == 0xa0)

// Page 1's: the event queue's indices.
@(private="file")
Smmu_Page1 :: struct {
	_:           [0xa8 / 4]u32,
	eventq_prod: u32,
	eventq_cons: u32,
}

#assert(offset_of(Smmu_Page1, eventq_prod) == 0xa8)

@(private="file")
GBPA_UPDATE :: u32(1 << 31)
@(private="file")
GBPA_ABORT :: u32(1 << 20)
@(private="file")
CR2_RECINVSID :: u32(1 << 1) // invalid stream IDs recorded
@(private="file")
CR2_PTM :: u32(1 << 2) // no broadcast TLB maintenance
@(private="file")
IRQ_CTRL_EVENTQ :: u32(1 << 2)
@(private="file")
QUEUE_RA :: u64(1) << 62 // a queue's or table's base: read-allocate

// An STE's first word (§5.2): valid, how the stream is handled, its context descriptors.
@(private="file")
Ste0 :: bit_field u64 {
	valid:    bool | 1,
	config:   u8   | 3, // 0: abort; 5: stage-1 translate
	s1fmt:    u8   | 2,
	s1ctxptr: u64  | 46, // the descriptor's address >> 6
	reserved: u8   | 7,
	s1cdmax:  u8   | 5,
}

// Its second: how the descriptor is fetched.
@(private="file")
Ste1 :: bit_field u64 {
	s1dss:     u8  | 2,
	s1cir:     u8  | 2, // 1: write-back
	s1cor:     u8  | 2,
	s1csh:     u8  | 2, // 3: inner shareable
	reserved:  u64 | 36,
	shcfg:     u8  | 2, // 1: the incoming shareability
	reserved2: u32 | 18,
}

@(private="file")
Ste :: struct {
	w0:   Ste0,
	w1:   Ste1,
	rest: [6]u64,
}

#assert(size_of(Ste) == 64)

@(private="file")
STE_ABORT :: Ste0{valid = true} // config 0

// A context descriptor's first word (§5.4).
@(private="file")
Cd0 :: bit_field u64 {
	t0sz:  u8   | 6,
	tg0:   u8   | 2, // 0: 4 KiB
	ir0:   u8   | 2, // 1: write-back
	or0:   u8   | 2,
	sh0:   u8   | 2, // 3: inner shareable
	epd0:  bool | 1,
	endi:  bool | 1,
	t1sz:  u8   | 6,
	tg1:   u8   | 2,
	ir1:   u8   | 2,
	or1:   u8   | 2,
	sh1:   u8   | 2,
	epd1:  bool | 1, // no walks through TTB1
	valid: bool | 1,
	ips:   u8   | 3,
	affd:  bool | 1,
	wxn:   bool | 1,
	uwxn:  bool | 1,
	tbi:   u8   | 2,
	pan:   bool | 1,
	aa64:  bool | 1,
	hd:    bool | 1,
	ha:    bool | 1,
	s:     bool | 1,
	r:     bool | 1, // faults recorded
	a:     bool | 1, // and aborted
	aset:  bool | 1,
	asid:  u16  | 16,
}

// An LPAE descriptor, a table's or a 4 KiB page's.
@(private="file")
Lpae :: bit_field u64 {
	valid:      bool | 1,
	page:       bool | 1, // a table above level 3, a page at it
	attr_index: u8   | 3, // MAIR's
	ns:         bool | 1,
	ap:         u8   | 2, // 1: read-write, 3: read-only, both unprivileged
	sh:         u8   | 2, // 3: inner shareable
	af:         bool | 1, // accessed
	ng:         bool | 1,
	addr:       u64  | 36, // bits 12-47
	reserved:   u8   | 5,
	pxn:        bool | 1,
	uxn:        bool | 1,
	software:   u16  | 9,
}

// A root complex's requester IDs [rid, rid + count) to streams from sid.
@(private="file")
Smmu_Map :: struct {
	rid, count, sid: u32,
}

@(private="file")
Smmu :: struct {
	regs:        ^Smmu_Regs,
	page1:       ^Smmu_Page1,
	idr0:        Smmu_Idr0,
	sid_bits:    u32,
	oas:         u8,
	two_level:   bool,
	coherent:    bool,
	asid16:      bool,
	strtab:      Paddr, // level 1 (two-level) or the STEs (linear)
	l2:          [256]^[256]Ste, // two-level: each bus's STEs, once made
	cmdq, evtq:  Paddr,
	cmdq_prod:   u32,
	evtq_cons:   u32,
	event_intid: u32, // the event queue's wired interrupt, or 0
	maps:        [dynamic; SMMU_MAX_MAPS]Smmu_Map,
	lock:        Spinlock,
}

smmu0: Smmu // one SMMU here; QEMU's virt has one. The interrupt handler reads event_intid.

@(private="file")
smmu_state: struct {
	on:           bool,
	domains:      [SMMU_MAX_DOMAINS]^Dma_Domain,
	domains_lock: Spinlock,
	asids:        [65536 / 64]u64,
}

// A line the SMMU reads, out of the CPU's caches if it does not snoop; then
// the stores ordered before the SMMU is told.
@(private="file")
smmu_clean :: proc "contextless" (p: rawptr) {
	if !smmu0.coherent {
		vx_dc_cvac(p)
	}
}

@(private="file")
smmu_clean_range :: proc "contextless" (pa: Paddr, size: int) {
	if !smmu0.coherent {
		for line := 0; line < size; line += 64 {
			vx_dc_cvac(rawptr(uintptr(phys_to_virt(pa)) + uintptr(line)))
		}
	}
}

@(private="file")
smmu_barrier :: #force_inline proc "contextless" () {
	vx_dsb_sy()
}

@(private="file")
smmu_cr0 :: proc "contextless" (value: Smmu_Enables) -> bool {
	intrinsics.volatile_store(&smmu0.regs.cr0, value)
	for _ in 0 ..< 10_000_000 {
		if intrinsics.volatile_load(&smmu0.regs.cr0ack) == value {
			return true
		}
	}
	return false
}

// --- The command queue (§4) ---

// Commands, each two words.
@(private="file")
CMD_CFGI_STE :: u64(0x03) // | sid << 32; hi: 1, the leaf
@(private="file")
CMD_CFGI_ALL :: u64(0x04) // hi: range 31
@(private="file")
CMD_TLBI_NH_ALL :: u64(0x10)
@(private="file")
CMD_TLBI_NH_ASID :: u64(0x11) // | asid << 48
@(private="file")
CMD_SYNC :: u64(0x46) // no completion signal: CONS is watched

// Queues a command, under the lock; the caller syncs.
@(private="file")
smmu_cmd :: proc "contextless" (lo, hi: u64) {
	MASK :: u32(1 << CMDQ_LOG2 - 1)
	WRAP :: u32(1 << CMDQ_LOG2)
	for _ in 0 ..< 100_000_000 { // room: prod not a whole queue ahead of cons
		cons := intrinsics.volatile_load(&smmu0.regs.cmdq_cons)
		if smmu0.cmdq_prod & MASK != cons & MASK || smmu0.cmdq_prod & WRAP == cons & WRAP {
			break
		}
	}
	q := cast(^[1 << CMDQ_LOG2][2]u64)phys_to_virt(smmu0.cmdq)
	slot := &q[smmu0.cmdq_prod & MASK]
	slot^ = {lo, hi}
	smmu_clean(slot)
	smmu0.cmdq_prod = (smmu0.cmdq_prod + 1) & (2 * WRAP - 1)
}

// Everything queued so far done when it returns; under the lock.
@(private="file")
smmu_sync :: proc "contextless" () {
	smmu_cmd(CMD_SYNC, 0)
	smmu_barrier()
	intrinsics.volatile_store(&smmu0.regs.cmdq_prod, smmu0.cmdq_prod)
	for _ in 0 ..< 100_000_000 {
		cons := intrinsics.volatile_load(&smmu0.regs.cmdq_cons)
		if cons & (2 << CMDQ_LOG2 - 1) == smmu0.cmdq_prod || cons >> 24 & 0x7f != 0 {
			return // done, or an error: the queue stops (reported in GERROR)
		}
	}
}

// --- Streams ---

@(private="file")
smmu_sid_for :: proc "contextless" (rid: u32) -> (sid: u32, ok: bool) {
	for m in smmu0.maps {
		if rid >= m.rid && rid - m.rid < m.count {
			sid = m.sid + (rid - m.rid)
			return sid, sid < 1 << smmu0.sid_bits
		}
	}
	return 0, false
}

// The STE for sid, its level-2 table made if need be; nil if it cannot be.
// Under the lock.
@(private="file")
smmu_ste :: proc "contextless" (sid: u32) -> ^Ste {
	if !smmu0.two_level {
		return sid < 256 ? &(cast(^[256]Ste)phys_to_virt(smmu0.strtab))[sid] : nil
	}
	hi := sid >> 8
	if hi >= 256 {
		return nil
	}
	if smmu0.l2[hi] == nil {
		t := phys_alloc_zeroed(2) // 256 STEs of 64 bytes
		if t == 0 {
			return nil
		}
		stes := cast(^[256]Ste)phys_to_virt(t)
		for &s in stes {
			s.w0 = STE_ABORT
		}
		smmu_clean_range(t, 16384)
		smmu0.l2[hi] = stes
		l1 := &(cast(^[256]u64)phys_to_virt(smmu0.strtab))[hi]
		l1^ = u64(t) | 9 // span 9: 2^(9 - 1) = 256 STEs
		smmu_clean(l1)
		smmu_barrier()
		smmu_cmd(CMD_CFGI_ALL, 31) // the level-1 descriptor is new
	}
	return &smmu0.l2[hi][sid & 0xff]
}

// --- Stage-1 tables (LPAE, 4 KiB granule, 39 bits: levels 1 to 3) ---

@(private="file")
smmu_leaf :: proc "contextless" (root: Paddr, iova: u64, make: bool) -> ^Lpae {
	table := root
	for level in 1 ..< 3 {
		e := &(cast(^[512]Lpae)phys_to_virt(table))[(iova >> uint(39 - 9 * level)) & 511]
		if !e.valid {
			if !make {
				return nil
			}
			next := phys_alloc_zeroed(0)
			if next == 0 {
				return nil
			}
			smmu_clean_range(next, PAGE_SIZE)
			e^ = {valid = true, page = true, addr = u64(next) >> 12} // a table
			smmu_clean(e)
		}
		table = Paddr(e.addr << 12)
	}
	return &(cast(^[512]Lpae)phys_to_virt(table))[(iova >> 12) & 511]
}

// Frees a domain's tables, recursing as deep as they go: three levels.
@(private="file")
smmu_free_tables :: proc "contextless" (table: Paddr, level: int) {
	if level < 3 {
		for e in cast(^[512]Lpae)phys_to_virt(table) {
			if e.valid {
				smmu_free_tables(Paddr(e.addr << 12), level + 1)
			}
		}
	}
	phys_free(table, 0)
}

@(private="file")
smmu_tlbi :: proc "contextless" (asid: u16) {
	spin_guard(&smmu0.lock)
	smmu_cmd(CMD_TLBI_NH_ASID | u64(asid) << 48, 0)
	smmu_sync()
}

iommu_map :: proc "contextless" (d: ^Dma_Domain, iova: u64, pages: []Page, options: vx.Dma_Options) -> bool {
	// A page: valid, accessed, inner shareable, normal memory (MAIR index 0),
	// never executed; read-only, or read-write (stage 1 has no write-only),
	// and reachable unprivileged, as a device's transactions are.
	attrs := Lpae {
		valid = true,
		page  = true,
		ap    = .Write in options ? 1 : 3,
		sh    = 3,
		af    = true,
		pxn   = true,
		uxn   = true,
	}
	ok := true
	{
		spin_guard(&d.lock)
		for p, i in pages {
			e := smmu_leaf(d.io.root, iova + u64(i) * PAGE_SIZE, true)
			if e == nil {
				ok = false
				break
			}
			e^ = attrs
			e.addr = p.frame
			smmu_clean(e)
		}
	}
	smmu_barrier()
	smmu_tlbi(d.io.did)
	return ok
}

iommu_unmap :: proc "contextless" (d: ^Dma_Domain, iova, count: u64) {
	{
		spin_guard(&d.lock)
		for i in 0 ..< count {
			if e := smmu_leaf(d.io.root, iova + i * PAGE_SIZE, false); e != nil {
				e^ = {}
				smmu_clean(e)
			}
		}
	}
	smmu_barrier()
	smmu_tlbi(d.io.did) // the device cannot reach them when this returns
}

// --- Domains: a stream's STE and context descriptor (§5.2, §5.4) ---

iommu_attach :: proc "contextless" (d: ^Dma_Domain) -> vx.Status {
	sid, covered := smmu_sid_for(d.source)
	if !smmu_state.on || !covered {
		return .Ok // no SMMU in front of it: pass-through
	}
	asid: u32
	{
		spin_guard(&smmu_state.domains_lock)
		slot := -1
		for x, i in smmu_state.domains {
			if x == nil && slot < 0 {
				slot = i
			}
			if x != nil && x.source == d.source {
				return .Err_Exists
			}
		}
		nasid := u32(smmu0.asid16 ? 65536 : 256)
		for i in 1 ..< nasid {
			if smmu_state.asids[i / 64] >> (i % 64) & 1 == 0 {
				asid = i
				break
			}
		}
		if slot < 0 || asid == 0 {
			return .Err_No_Memory
		}
		smmu_state.asids[asid / 64] |= 1 << (asid % 64)
		smmu_state.domains[slot] = d
	}
	d.io = {on = true, did = u16(asid), root = phys_alloc_zeroed(0), ctx = phys_alloc_zeroed(0)}
	// The ITS doorbell, where the device's MSIs go, at its own address.
	bell := arch_msi_doorbell()
	if d.io.root == 0 || d.io.ctx == 0 || (bell != 0 && !iommu_map(d, u64(bell), {page_of(bell)}, {.Write})) {
		iommu_detach(d)
		return .Err_No_Memory
	}
	// The context descriptor: TTB0 the tables, 39 bits, 4 KiB, cached and
	// inner shareable walks, TTB1 off, AArch64, faults recorded and aborted.
	cd := cast(^[8]u64)phys_to_virt(d.io.ctx)
	cd[1] = u64(d.io.root) & 0x0000_ffff_ffff_f000
	cd[3] = 0xff // MAIR: attribute 0, normal write-back memory
	smmu_clean(cd)
	smmu_barrier()
	cd[0] = transmute(u64)Cd0{t0sz = 25, ir0 = 1, or0 = 1, sh0 = 3, epd1 = true, valid = true, ips = smmu0.oas, aa64 = true, r = true, a = true, asid = u16(asid)}
	smmu_clean(cd)
	smmu_barrier()
	spin_lock(&smmu0.lock)
	ste := smmu_ste(sid)
	if ste != nil {
		ste.w1 = {s1cir = 1, s1cor = 1, s1csh = 3, shcfg = 1} // the CD's fetch: write-back, inner shareable; SHCFG incoming
		smmu_clean(ste)
		smmu_barrier()
		ste.w0 = {valid = true, config = 5, s1ctxptr = u64(d.io.ctx) >> 6} // stage 1 translate, one CD
		smmu_clean(ste)
		smmu_barrier()
		smmu_cmd(CMD_CFGI_STE | u64(sid) << 32, 1)
		smmu_cmd(CMD_TLBI_NH_ASID | u64(asid) << 48, 0)
		smmu_sync()
	}
	spin_unlock(&smmu0.lock)
	if ste == nil {
		iommu_detach(d)
		return .Err_No_Memory
	}
	return .Ok
}

iommu_detach :: proc "contextless" (d: ^Dma_Domain) {
	if !d.io.on {
		return
	}
	spin_lock(&smmu0.lock)
	ste: ^Ste
	if sid, ok := smmu_sid_for(d.source); ok {
		ste = smmu_ste(sid)
		if ste != nil && ste.w0.s1ctxptr == u64(d.io.ctx) >> 6 { // abort from here
			ste.w0 = STE_ABORT
			smmu_clean(ste)
			smmu_barrier()
			smmu_cmd(CMD_CFGI_STE | u64(sid) << 32, 1)
		}
	}
	smmu_cmd(CMD_TLBI_NH_ASID | u64(d.io.did) << 48, 0)
	smmu_sync()
	spin_unlock(&smmu0.lock)
	if d.io.root != 0 {
		smmu_free_tables(d.io.root, 1)
	}
	if d.io.ctx != 0 {
		phys_free(d.io.ctx, 0)
	}
	spin_lock(&smmu_state.domains_lock)
	for &x in smmu_state.domains {
		if x == d {
			x = nil
		}
	}
	smmu_state.asids[d.io.did / 64] &~= 1 << (d.io.did % 64)
	spin_unlock(&smmu_state.domains_lock)
	d.io = {}
}

// --- Faults: the event queue (§7) ---

smmu_event_interrupt :: proc "contextless" () {
	MASK :: u32(1 << EVTQ_LOG2 - 1)
	WRAP2 :: u32(2 << EVTQ_LOG2 - 1)
	q := cast(^[1 << EVTQ_LOG2][4]u64)phys_to_virt(smmu0.evtq)
	for _ in 0 ..= MASK {
		prod := intrinsics.volatile_load(&smmu0.page1.eventq_prod) & WRAP2
		if prod == smmu0.evtq_cons & WRAP2 {
			break
		}
		e := &q[smmu0.evtq_cons & MASK]
		if !smmu0.coherent {
			vx_dc_ivac(e)
		}
		type, sid, address := e[0] & 0xff, u32(e[0] >> 32), e[2]
		smmu0.evtq_cons = (smmu0.evtq_cons + 1) & WRAP2
		kput("vx: iommu: event ")
		kput_hex(type)
		kput(" from stream ")
		kput_hex(u64(sid))
		kput(" at ")
		kput_hex(address)
		kput("\n")
		d: ^Dma_Domain
		{
			spin_guard(&smmu_state.domains_lock)
			for x in smmu_state.domains {
				if x == nil {
					continue
				}
				if s, ok := smmu_sid_for(x.source); ok && s == sid {
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
	}
	intrinsics.volatile_store(&smmu0.page1.eventq_cons, smmu0.evtq_cons)
}

// --- Bringing it up ---

// The IORT (DEN 0049): the first SMMUv3, and the root complexes' maps to it.
@(private="file")
smmu_from_iort :: proc "contextless" () -> Paddr {
	iort := acpi_table("IORT")
	if len(iort) < 48 {
		return 0
	}
	nodes, first := read32(iort[36:]), int(read32(iort[40:]))
	node_len :: proc "contextless" (iort: []u8, at: int) -> int {
		return int(iort[at + 1]) | int(iort[at + 2]) << 8
	}
	base: Paddr
	smmu_off: u32
	at := first
	for _ in 0 ..< nodes { // the SMMUv3 node first
		if at + 16 > len(iort) {
			break
		}
		n := node_len(iort, at)
		if n < 16 || at + n > len(iort) {
			break
		}
		if iort[at] == 4 && n >= 60 && base == 0 {
			base = Paddr(read64(iort[at + 16:]))
			smmu0.event_intid = read32(iort[at + 44:])
			smmu_off = u32(at)
		}
		at += n
	}
	if base == 0 {
		return 0
	}
	at = first
	for _ in 0 ..< nodes { // the root complexes' IDs to it
		if at + 16 > len(iort) {
			break
		}
		n := node_len(iort, at)
		if n < 16 || at + n > len(iort) {
			break
		}
		nids, ids := read32(iort[at + 8:]), int(read32(iort[at + 12:]))
		for k := 0; iort[at] == 2 && k < int(nids) && ids + 20 * (k + 1) <= n && len(smmu0.maps) < SMMU_MAX_MAPS; k += 1 {
			m := iort[at + ids + 20 * k:][:20]
			if read32(m[12:]) != smmu_off {
				continue
			}
			_ = append(&smmu0.maps, Smmu_Map{rid = read32(m), count = read32(m[4:]) + 1, sid = read32(m[8:])}) // below SMMU_MAX_MAPS
		}
		at += n
	}
	return base
}

iommu_init :: proc "contextless" () {
	base := smmu_from_iort()
	if base == 0 {
		return // no SMMUv3: pass-through, as before
	}
	if !map_range(kernel_root, boot.hhdm + u64(base), base, SMMU_REGS_SIZE, {.Write, .Device}) {
		kpanic("smmu: cannot map its registers")
	}
	smmu0.regs = cast(^Smmu_Regs)phys_to_virt(base)
	smmu0.page1 = cast(^Smmu_Page1)phys_to_virt(base + 0x1_0000)
	smmu0.idr0 = intrinsics.volatile_load(&smmu0.regs.idr0)
	if !smmu0.idr0.s1p || smmu0.idr0.ttf == 1 {
		kpanic("smmu: no AArch64 stage 1")
	}
	smmu0.two_level = smmu0.idr0.st_level >= 1
	smmu0.coherent = smmu0.idr0.cohacc
	smmu0.asid16 = smmu0.idr0.asid16
	smmu0.sid_bits = min(intrinsics.volatile_load(&smmu0.regs.idr1) & 0x3f, 16)
	smmu0.oas = u8(intrinsics.volatile_load(&smmu0.regs.idr5) & 7)
	// Off first, and aborting while off, then the tables and queues.
	_ = smmu_cr0({})
	intrinsics.volatile_store(&smmu0.regs.gbpa, GBPA_UPDATE | GBPA_ABORT)
	for i := 0; i < 10_000_000 && intrinsics.volatile_load(&smmu0.regs.gbpa) & GBPA_UPDATE != 0; i += 1 {}
	if smmu0.two_level { // level 1: 256 descriptors, each a bus's 256 STEs, none yet (span 0)
		smmu0.strtab = phys_alloc_zeroed(0)
		intrinsics.volatile_store(&smmu0.regs.strtab_base, u64(smmu0.strtab) | QUEUE_RA)
		bits := max(smmu0.sid_bits, 9) // at most 16: 256 level-1 descriptors
		intrinsics.volatile_store(&smmu0.regs.strtab_base_cfg, 1 << 16 | 8 << 6 | bits) // two-level, split 8
	} else { // linear: 256 STEs, every one aborting
		smmu0.strtab = phys_alloc_zeroed(2)
		if smmu0.strtab != 0 {
			for &s in cast(^[256]Ste)phys_to_virt(smmu0.strtab) {
				s.w0 = STE_ABORT
			}
		}
		intrinsics.volatile_store(&smmu0.regs.strtab_base, u64(smmu0.strtab) | QUEUE_RA)
		intrinsics.volatile_store(&smmu0.regs.strtab_base_cfg, 8)
	}
	smmu0.cmdq = phys_alloc_zeroed(0)
	smmu0.evtq = phys_alloc_zeroed(0)
	if smmu0.strtab == 0 || smmu0.cmdq == 0 || smmu0.evtq == 0 {
		kpanic("smmu: no memory")
	}
	smmu_clean_range(smmu0.strtab, 16384)
	intrinsics.volatile_store(&smmu0.regs.cmdq_base, QUEUE_RA | u64(smmu0.cmdq) | CMDQ_LOG2)
	intrinsics.volatile_store(&smmu0.regs.cmdq_prod, 0)
	intrinsics.volatile_store(&smmu0.regs.cmdq_cons, 0)
	intrinsics.volatile_store(&smmu0.regs.eventq_base, QUEUE_RA | u64(smmu0.evtq) | EVTQ_LOG2)
	intrinsics.volatile_store(&smmu0.page1.eventq_prod, 0)
	intrinsics.volatile_store(&smmu0.page1.eventq_cons, 0)
	// Queues and tables cached, inner shareable; invalid stream IDs recorded.
	intrinsics.volatile_store(&smmu0.regs.cr1, Smmu_Cr1{queue_ic = 1, queue_oc = 1, queue_sh = 3, table_ic = 1, table_oc = 1, table_sh = 3})
	intrinsics.volatile_store(&smmu0.regs.cr2, CR2_RECINVSID | CR2_PTM)
	if !smmu_cr0({.Cmdqen}) {
		kpanic("smmu: the command queue would not start")
	}
	spin_lock(&smmu0.lock)
	smmu_cmd(CMD_CFGI_ALL, 31)
	smmu_cmd(CMD_TLBI_NH_ALL, 0)
	smmu_sync()
	spin_unlock(&smmu0.lock)
	if !smmu_cr0({.Cmdqen, .Evtqen}) {
		kpanic("smmu: the event queue would not start")
	}
	if smmu0.event_intid >= 32 {
		arch_kernel_spi(smmu0.event_intid, true)
		intrinsics.volatile_store(&smmu0.regs.irq_ctrl, IRQ_CTRL_EVENTQ) // wired (no MSI configured)
	}
	if !smmu_cr0({.Cmdqen, .Evtqen, .Smmuen}) {
		kpanic("smmu: translation would not turn on")
	}
	smmu_state.on = true
	kput("vx: SMMUv3: ")
	kput(smmu0.two_level ? "two-level" : "linear")
	kput(" stream table, ")
	kput_u64(u64(len(smmu0.maps)))
	kput(len(smmu0.maps) == 1 ? " root complex" : " root complexes")
	kput(", deny-all\n")
}
