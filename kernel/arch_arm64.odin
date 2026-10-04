package kernel

import "base:intrinsics"
import vx "abi:vx"

// aarch64: the early serial console (a PL011), exceptions, page-table
// entries, and the clock and timer (the generic timer's virtual counter,
// through the GICv3).
//
// Limine's direct map covers RAM only, so the console maps the UART's
// registers itself: one 4 KiB device page at hhdm + its physical address,
// first in Limine's page tables and then in the kernel's own. Device pages
// use MAIR attribute 2; Limine guarantees that attributes 2 to 7 are unused.
// The UART and the GIC are at QEMU virt's addresses until the kernel reads
// the device tree.

foreign _ {
	vx_read_ttbr1 :: proc "c" () -> u64 ---
	vx_read_mair :: proc "c" () -> u64 ---
	vx_write_mair :: proc "c" (v: u64) ---
	vx_read_tpidr_el1 :: proc "c" () -> u64 ---
	vx_read_cntvct :: proc "c" () -> u64 ---
	vx_read_cntfrq :: proc "c" () -> u64 ---
	vx_read_mpidr :: proc "c" () -> u64 ---
	vx_read_current_el :: proc "c" () -> u64 ---
	vx_read_elr :: proc "c" () -> u64 ---
	vx_read_esr :: proc "c" () -> u64 ---
	vx_read_far :: proc "c" () -> u64 ---
	vx_read_icc_iar1 :: proc "c" () -> u64 ---
	vx_write_icc_eoir1 :: proc "c" (v: u64) ---
	vx_cpu_set :: proc "c" (vectors: rawptr, index: u64) ---
	vx_switch_tables :: proc "c" (ttbr1, ttbr0: u64) ---
	vx_pte_publish :: proc "c" () ---
	vx_timer_arm :: proc "c" (count: u64) ---
	vx_timer_disarm :: proc "c" () ---
	vx_gic_cpu_init :: proc "c" () ---
	vx_wait :: proc "c" () ---
	vx_halt :: proc "c" () -> ! ---
	vx_pause :: proc "c" () ---
	vx_frame_address :: proc "c" () -> u64 ---
	vx_run_on_stack :: proc "c" (top: u64, fn: proc "c" () -> !) -> ! ---
	vx_vreg_irq_test :: proc "c" (input, output: ^[512]u8, fired: ^u64, target: u64) ---
	vx_switch_user_root :: proc "c" (root: u64) ---
	vx_tlb_shootdown :: proc "c" (va, length: u64) ---
	vx_read_mdscr :: proc "c" () -> u64 ---
	vx_write_mdscr :: proc "c" (v: u64) ---
	vx_os_unlock :: proc "c" () ---
	vx_sync_icache :: proc "c" (p: rawptr, length: u64) ---
	vx_read_tpidr_el0 :: proc "c" () -> u64 ---
	vx_read_id_aa64dfr0 :: proc "c" () -> u64 ---
	vx_watch_slot :: proc "c" (slot: u32, value, control: u64) ---
	vx_read_cntkctl :: proc "c" () -> u64 ---
	vx_write_cntkctl :: proc "c" (v: u64) ---
	vx_write_tpidr_el0 :: proc "c" (v: u64) ---
	vx_write_icc_sgi1r :: proc "c" (v: u64) ---
	vx_pan_off :: proc "c" () ---
	vx_context_switch :: proc "c" (save_sp: ^u64, load_sp: u64) ---
	vx_enter_user :: proc "c" (entry, sp, arg, arg2, kstack_top: u64) -> ! ---
	thread_trampoline :: proc "c" () --- // entry.S: an address only
	vx_clobber_vregs :: proc "c" () ---
	aarch64_vectors :: proc "c" () --- // entry.S's vector table: an address only
}

// TTBR1 and TTBR0 for ap_start and ap_park: Odin's, which the assembly reads.
@(export)
ap_park_tables: [2]u64

// --- Limine's multiprocessor response ---

MP_REQUEST_FLAGS :: 0

Mp_Info :: struct {
	processor_id:   u32,
	reserved1:      u32,
	mpidr:          u64,
	reserved:       u64,
	goto_address:   rawptr,
	extra_argument: u64,
}

#assert(offset_of(Mp_Info, extra_argument) == 32) // entry.S's ap_start reads it there

Mp_Response :: struct {
	revision:  u64,
	flags:     u64,
	bsp_mpidr: u64,
	cpu_count: u64,
	cpus:      [^]^Mp_Info,
}

mp_bsp_id :: proc "contextless" (mp: ^Mp_Response) -> u64 {
	return mp.bsp_mpidr
}

mp_info_id :: proc "contextless" (info: ^Mp_Info) -> u64 {
	return info.mpidr
}

// --- Page tables ---

@(private="file")
PTE_VALID :: Pte(1) << 0
@(private="file")
PTE_TABLE :: Pte(1) << 1 // a table at levels 0-2, a page at level 3
@(private="file")
PTE_DEVICE :: Pte(2) << 2 // MAIR index 2; index 0 is normal write-back memory
@(private="file")
PTE_USER :: Pte(1) << 6 // AP[1]
@(private="file")
PTE_READ_ONLY :: Pte(1) << 7 // AP[2]
@(private="file")
PTE_SH_INNER :: Pte(3) << 8
@(private="file")
PTE_AF :: Pte(1) << 10
@(private="file")
PTE_NG :: Pte(1) << 11 // not global: user mappings belong to one address space
@(private="file")
PTE_PXN :: Pte(1) << 53
@(private="file")
PTE_UXN :: Pte(1) << 54
@(private="file")
PTE_ADDR :: Pte(0x0000_ffff_ffff_f000)

arch_pte_valid :: proc "contextless" (e: Pte) -> bool {
	return e & PTE_VALID != 0
}

arch_pte_is_table :: proc "contextless" (e: Pte, level: int) -> bool {
	return level < 3 && e & PTE_TABLE != 0
}

arch_pte_addr :: proc "contextless" (e: Pte) -> Paddr {
	return Paddr(e & PTE_ADDR)
}

arch_pte_table :: proc "contextless" (pa: Paddr) -> Pte {
	return Pte(pa) | PTE_TABLE | PTE_VALID
}

arch_pte_leaf :: proc "contextless" (pa: Paddr, flags: Map_Flags, level: int) -> Pte {
	e := Pte(pa) | PTE_AF | PTE_VALID | (level == 3 ? PTE_TABLE : 0)
	e |= .Device in flags ? PTE_DEVICE : PTE_SH_INNER
	if .Write not_in flags {
		e |= PTE_READ_ONLY
	}
	if .User in flags {
		e |= PTE_USER | PTE_NG | PTE_PXN // the kernel never executes user pages
		if .Exec not_in flags {
			e |= PTE_UXN
		}
	} else {
		e |= PTE_UXN
		if .Exec not_in flags {
			e |= PTE_PXN
		}
	}
	return e
}

arch_pte_publish :: proc "contextless" () {
	vx_pte_publish()
}

// The GICv3: the distributor, and one 128 KiB redistributor frame per CPU.
@(private="file")
GICD_PHYS :: 0x0800_0000
@(private="file")
GICD_SIZE :: u64(0x1_0000)
@(private="file")
GICR_PHYS :: 0x080a_0000
@(private="file")
GICR_FRAME_SIZE :: u64(0x2_0000)

// The distributor's registers that the kernel uses.
@(private="file")
Gicd :: struct {
	ctlr:       u32,
	typer:      u32,
	_:          [30]u32,
	igroupr:    [32]u32,
	isenabler:  [32]u32,
	icenabler:  [32]u32,
	_:          [128]u32, // pending and active
	ipriorityr: [1024]u8,
	_:          [1024]u8, // targets, unused with affinity routing
	icfgr:      [64]u32,
	_:          [(0x6000 - 0xd00) / 4]u32,
	irouter:    [1020]u64, // from INTID 32; the first 32 are reserved
}

#assert(offset_of(Gicd, igroupr) == 0x080)
#assert(offset_of(Gicd, isenabler) == 0x100)
#assert(offset_of(Gicd, icenabler) == 0x180)
#assert(offset_of(Gicd, ipriorityr) == 0x400)
#assert(offset_of(Gicd, icfgr) == 0xc00)
#assert(offset_of(Gicd, irouter) == 0x6000)
#assert(size_of(Gicd) <= GICD_SIZE)

// A redistributor's registers that the kernel uses: its RD frame, then its
// SGI and PPI frame.
@(private="file")
Gicr :: struct {
	ctlr:       u32,
	iidr:       u32,
	typer:      u64,
	statusr:    u32,
	waker:      u32,
	_:          [(0x70 - 0x18) / 4]u32,
	propbaser:  u64, // LPIs: the configuration table
	pendbaser:  u64, // and the pending table
	_:          [(0x1_0000 - 0x80) / 4]u32,
	_:          [32]u32,
	igroupr0:   u32,
	_:          [31]u32,
	isenabler0: u32,
	_:          [191]u32,
	ipriorityr: [32]u8, // SGIs and PPIs
}

#assert(offset_of(Gicr, typer) == 0x08)
#assert(offset_of(Gicr, waker) == 0x14)
#assert(offset_of(Gicr, propbaser) == 0x70)
#assert(offset_of(Gicr, pendbaser) == 0x78)
#assert(offset_of(Gicr, igroupr0) == 0x1_0080)
#assert(offset_of(Gicr, isenabler0) == 0x1_0100)
#assert(offset_of(Gicr, ipriorityr) == 0x1_0400)
#assert(size_of(Gicr) <= GICR_FRAME_SIZE)

@(private="file")
gicd :: #force_inline proc "contextless" () -> ^Gicd {
	return cast(^Gicd)uintptr(boot.hhdm + GICD_PHYS)
}

@(private="file")
PL011_PHYS :: 0x0900_0000

@(private="file")
Pl011 :: struct {
	dr: u32, // data
	_:  [5]u32,
	fr: u32, // flags
}

#assert(offset_of(Pl011, fr) == 0x18)

@(private="file")
PL011_FR_TXFF :: 1 << 5 // transmit FIFO full

@(private="file")
pl011: ^Pl011

arch_kernel_mappings :: proc "contextless" (root: Paddr) {
	gicr_size := GICR_FRAME_SIZE * max(boot.cpu_count, 1)
	if !map_range(root, boot.hhdm + PL011_PHYS, PL011_PHYS, PAGE_SIZE, {.Write, .Device}) ||
	   !map_range(root, boot.hhdm + GICD_PHYS, GICD_PHYS, GICD_SIZE, {.Write, .Device}) ||
	   !map_range(root, boot.hhdm + GICR_PHYS, GICR_PHYS, gicr_size, {.Write, .Device}) {
		kpanic("cannot map the UART and the GIC")
	}
}

@(private="file")
empty_user_root: Paddr // TTBR0 while a CPU runs no task, shared by all

// Installs the kernel's tables in TTBR1, and an empty table in TTBR0 until
// there is a user address space, then drops every cached translation.
// The user half has its own tables in TTBR0; the kernel's stay in TTBR1.
arch_new_user_root :: proc "contextless" () -> Paddr {
	return phys_alloc_zeroed(0)
}

// Loads a task's tables into TTBR0, or with root 0 (no task, as for the idle
// thread) the empty table.
arch_switch_user_root :: proc "contextless" (root: Paddr) {
	vx_switch_user_root(u64(root != 0 ? root : empty_user_root))
}

arch_user_top_slots :: proc "contextless" () -> int {
	return 512
}

// Every CPU drops its translations for [va, va + length): broadcast
// invalidations, which need no interrupts (cpu.S). Without ASIDs yet, the
// root does not narrow them.
arch_tlb_shootdown :: proc "contextless" (root: Paddr, va: Uva, length: u64) {
	vx_tlb_shootdown(u64(va), length)
}

arch_pte_user_ok :: proc "contextless" (e: Pte, write: bool) -> bool {
	return e & PTE_VALID != 0 && e & PTE_USER != 0 && (!write || e & PTE_READ_ONLY == 0)
}

arch_switch_tables :: proc "contextless" (root: Paddr) {
	if empty_user_root == 0 {
		empty_user_root = phys_alloc_zeroed(0) // first on the boot CPU, before the others start
	}
	if empty_user_root == 0 {
		kpanic("no memory for page tables")
	}
	ap_park_tables[0] = u64(root) // for ap_start and ap_park
	ap_park_tables[1] = u64(empty_user_root)
	vx_switch_tables(u64(root), u64(empty_user_root))
}

// --- The console ---

arch_console_init :: proc "contextless" () {
	if boot.hhdm == 0 {
		return
	}
	vx_write_mair(vx_read_mair() &~ (0xff << 16)) // attribute 2 = 0x00: Device-nGnRnE
	va := boot.hhdm + PL011_PHYS
	if map_range(Paddr(vx_read_ttbr1() & u64(PTE_ADDR)), va, PL011_PHYS, PAGE_SIZE, {.Write, .Device}) {
		pl011 = cast(^Pl011)uintptr(va)
	}
}

arch_console_write :: proc "contextless" (s: string) {
	if pl011 == nil {
		return
	}
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			uart_putc('\r')
		}
		uart_putc(s[i])
	}
}

@(private="file")
uart_putc :: proc "contextless" (c: u8) {
	for intrinsics.volatile_load(&pl011.fr) & PL011_FR_TXFF != 0 {}
	intrinsics.volatile_store(&pl011.dr, u32(c))
}

// --- CPUs ---

@(private="file")
percpu_ready: bool // TPIDR_EL1 holds this CPU's index

// Per CPU: the vector table, the CPU's index in TPIDR_EL1, and MAIR
// attribute 2 as device memory. FP and SIMD were enabled in entry.S.
arch_cpu_init :: proc "contextless" (index: u32) {
	vx_cpu_set(rawptr(aarch64_vectors), u64(index))
	vx_pan_off()
	vx_write_mair(vx_read_mair() &~ (0xff << 16))
	// Software step for user threads (exception_resume .Step): the OS lock
	// open, and MDSCR_EL1 with KDE off, so the kernel itself is never
	// stepped. SS is set only on the way to a thread being stepped
	// (step_on_return).
	vx_os_unlock()
	vx_write_mdscr(vx_read_mdscr() &~ (MDSCR_KDE | MDSCR_SS))
	// CNTKCTL_EL1.EL0VCTEN: user code may read the virtual counter.
	vx_write_cntkctl(vx_read_cntkctl() | 1 << 1)
	percpu_ready = true
}

arch_cpu_index :: proc "contextless" () -> u32 {
	return percpu_ready ? u32(vx_read_tpidr_el1()) : 0
}

arch_pause :: proc "contextless" () {
	vx_pause()
}

arch_halt :: proc "contextless" () -> ! {
	vx_halt()
}

arch_frame_address :: proc "contextless" () -> u64 {
	return vx_frame_address()
}

arch_run_on_stack :: proc "contextless" (top: u64, fn: proc "c" () -> !) -> ! {
	vx_run_on_stack(top, fn)
}

// --- The clock and the timer ---

// The virtual timer's PPI: 27 at EL1. At EL2 with VHE the CNTV_*_EL0 names
// reach the EL2 virtual timer instead, which raises PPI 28.
@(private="file")
INTID_RESCHED :: 0 // an SGI: another CPU made a thread ready
@(private="file")
INTID_VIRTUAL_TIMER :: 27
@(private="file")
INTID_EL2_VIRTUAL_TIMER :: 28

@(private="file")
timer_ppi :: proc "contextless" () -> u32 {
	return (vx_read_current_el() >> 2) & 3 == 2 ? INTID_EL2_VIRTUAL_TIMER : INTID_VIRTUAL_TIMER
}

arch_counter :: proc "contextless" () -> u64 {
	return vx_read_cntvct()
}

arch_counter_hz :: proc "contextless" () -> u64 {
	return vx_read_cntfrq()
}

// The generic timer's virtual counter: one rate always, and user code reads
// it (CNTKCTL_EL1.EL0VCTEN, arch_cpu_init).
arch_counter_flags :: proc "contextless" () -> vx.Clock_Flags {
	return {.User, .Invariant, .Cntvct}
}

// Sets up the GIC for this CPU: the distributor once, on the boot CPU, then
// this CPU's redistributor with the timer's PPI enabled, then its interface.
arch_timer_init :: proc "contextless" () {
	if arch_cpu_index() == 0 {
		intrinsics.volatile_store(&gicd().ctlr, 1 << 4 | 1 << 1 | 1 << 0) // affinity routing, both groups
	}

	// Find this CPU's redistributor by its affinity.
	mpidr := vx_read_mpidr()
	aff := u32((mpidr >> 32 & 0xff) << 24 | (mpidr & 0xffffff))
	rd: ^Gicr
	for i in 0 ..< max(boot.cpu_count, 1) {
		frame := cast(^Gicr)uintptr(boot.hhdm + GICR_PHYS + i * GICR_FRAME_SIZE)
		typer := intrinsics.volatile_load(&frame.typer)
		if u32(typer >> 32) == aff {
			rd = frame
			break
		}
		if typer & (1 << 4) != 0 {
			break // the last redistributor
		}
	}
	if rd == nil {
		kpanic("no GIC redistributor for this CPU")
	}
	if arch_cpu_index() == 0 {
		boot_rd = rd // LPIs (MSIs) go to the boot CPU
	}

	intrinsics.volatile_store(&rd.waker, intrinsics.volatile_load(&rd.waker) &~ (1 << 1)) // clear ProcessorSleep
	for intrinsics.volatile_load(&rd.waker) & (1 << 2) != 0 {} // wait for ChildrenAsleep to clear

	ppi := timer_ppi()
	lines := u32(1) << ppi | 1 << INTID_RESCHED
	intrinsics.volatile_store(&rd.igroupr0, intrinsics.volatile_load(&rd.igroupr0) | lines) // group 1
	intrinsics.volatile_store(&rd.ipriorityr[ppi], 0x80)
	intrinsics.volatile_store(&rd.ipriorityr[INTID_RESCHED], 0x80)
	intrinsics.volatile_store(&rd.isenabler0, lines)
	vx_gic_cpu_init()
}

arch_timer_arm :: proc "contextless" (count: u64) {
	vx_timer_arm(count)
}

arch_wait :: proc "contextless" () {
	vx_wait()
}

@(private="file")
aarch64_irq :: proc "contextless" () {
	iar := vx_read_icc_iar1()
	intid := u32(iar) & 0xffffff
	if intid >= 1020 && intid <= 1023 {
		return // spurious; LPIs (MSIs) are 8192 and up
	}
	if intid == INTID_VIRTUAL_TIMER || intid == INTID_EL2_VIRTUAL_TIMER {
		vx_timer_disarm() // disarm before the EOI: the line is level-triggered
		timer_interrupt()
	} else if intid == INTID_RESCHED {
		this_cpu().resched = true
	} else if intid >= LPI_BASE && intid < LPI_BASE + LPI_COUNT {
		irq_fire(MSI_LINE_BASE + intid - LPI_BASE) // an MSI: edge-triggered, never masked
	} else if intid >= 32 && intid < 1020 {
		irq_fire(intid) // a device's SPI: masked before the EOI, as it is level-triggered
	}
	vx_write_icc_eoir1(iar)
}

// --- Exceptions ---

Trap_Frame :: struct { // the layout entry.S builds, below the vector state
	x:                  [31]u64, // x29 is the frame pointer, x30 the link register
	elr, spsr, esr, far: u64,
	sp_el0:             u64, // the user stack pointer
}

#assert(size_of(Trap_Frame) == 288) // entry.S's GP_FRAME

@(private="file")
VECTOR_KINDS := [4]string{"synchronous exception", "IRQ", "FIQ", "SError"}

// The exception syndrome register, and the exception classes the kernel
// tells apart.
@(private="file")
Exception_Class :: enum u8 {
	Unknown       = 0x00, // an undefined instruction
	Fp_Access     = 0x07,
	Illegal_State = 0x0e,
	Svc64         = 0x15,
	Iabt_Lower    = 0x20, // an instruction abort from EL0
	Iabt_Same     = 0x21,
	Pc_Align      = 0x22,
	Dabt_Lower    = 0x24, // a data abort from EL0
	Dabt_Same     = 0x25,
	Sp_Align      = 0x26,
	Fp_Exc64      = 0x2c, // a trapped FP exception
	Step_Lower    = 0x32, // software step, from EL0
	Watch_Lower   = 0x34, // a watchpoint, from EL0
	Brk           = 0x3c,
}

@(private="file")
Esr :: bit_field u64 {
	iss: u32             | 25, // the syndrome, which the class defines
	il:  bool            | 1,
	ec:  Exception_Class | 6,
}

// A data abort's ISS: write, not read (WnR), and the fault status code,
// which is a translation fault at some level when its bits 5-2 are 0b0001.
@(private="file")
DABT_WNR :: 1 << 6
@(private="file")
DABT_FSC_LEVEL_MASK :: 0x3c
@(private="file")
DABT_FSC_TRANSLATION :: 0x04

// Describes an exception: "page fault at 0x... (read, not present, user)", say.
@(private="file")
kput_exception :: proc "contextless" (f: ^Trap_Frame, index: u64) {
	esr := transmute(Esr)f.esr
	sync := index & 3 == 0
	switch {
	case sync && (esr.ec == .Dabt_Lower || esr.ec == .Dabt_Same):
		kput("page fault at ")
		kput_hex(f.far)
		kput(esr.iss & DABT_WNR != 0 ? " (write, " : " (read, ")
		kput(esr.iss & DABT_FSC_LEVEL_MASK == DABT_FSC_TRANSLATION ? "not present" : "protection")
		kput(esr.ec == .Dabt_Lower ? ", user)" : ", kernel)")
	case sync && (esr.ec == .Iabt_Lower || esr.ec == .Iabt_Same):
		kput("page fault at ")
		kput_hex(f.far)
		kput(" (execute)")
	case sync && esr.ec == .Brk && esr.iss & 0xffff == 1:
		// brk #1: Odin's runtime trap. A bounds check or an assertion failed;
		// its message went to a stderr that freestanding builds do not have.
		kput("Odin runtime trap (a bounds check or assertion failed)")
	case:
		kput(VECTOR_KINDS[index & 3])
		kput(", ESR ")
		kput_hex(f.esr)
	}
}

// An exception in the kernel found its stack pointer outside a kernel stack's
// valid half (entry.S): an overflow into the guard below, or an exception
// before CPU 0 left the boot stack. Either way, the end.
@(export, link_name="aarch64_kernel_stack_fault")
aarch64_kernel_stack_fault :: proc "c" (sp: u64) -> ! {
	elr, esr, far := vx_read_elr(), vx_read_esr(), vx_read_far()
	panic_start()
	kput(kstack_in_guard(sp) ? "kernel stack overflow" : "exception off any kernel stack")
	kput(": sp ")
	kput_hex(sp)
	kput(", ESR ")
	kput_hex(esr)
	kput(", FAR ")
	kput_hex(far)
	kput(" at pc ")
	kput_hex(elr)
	panic_end(elr, 0)
}

// SGI 0 to one CPU, through ICC_SGI1R_EL1: its affinity levels 3 to 1, and
// level 0 as a bit in a 16-wide target list, with RS choosing which 16.
arch_send_resched :: proc "contextless" (c: ^Cpu) {
	m := c.arch_id
	aff3, aff2, aff1, aff0 := (m >> 32) & 0xff, (m >> 16) & 0xff, (m >> 8) & 0xff, m & 0xff
	rs := aff0 >> 4 // which 16 of Aff0
	vx_write_icc_sgi1r(aff3 << 48 | aff2 << 32 | aff1 << 16 | u64(INTID_RESCHED) << 24 | rs << 44 | 1 << (aff0 & 0xf))
}

// Exceptions from EL0 land on SP_EL1, which is the top of the current
// thread's kernel stack whenever it runs in user mode: nothing to set.
arch_set_kernel_stack :: proc "contextless" (top: u64) {}

// What vx_context_switch (entry.S) pops, lowest address first.
@(private="file")
Switch_Frame :: struct {
	x19, x20, x21, x22, x23, x24, x25, x26, x27, x28: u64,
	x29, x30:                                         u64, // the frame pointer and the return address
	d:                                                [8]u64, // d8 to d15
}

#assert(size_of(Switch_Frame) == 160)

// A new thread's stack, as the context switch will pop it: x19 carrying the
// thread, and x30 returning into thread_trampoline. It starts below the
// frame vx_enter_user builds at the top.
arch_thread_initial_sp :: proc "contextless" (th: ^Thread) -> u64 {
	f := cast(^Switch_Frame)uintptr(thread_kstack_top(th) - TRAP_FRAME_SIZE - size_of(Switch_Frame))
	f^ = {
		x19 = u64(uintptr(th)),
		x30 = u64(uintptr(rawptr(thread_trampoline))),
	}
	return u64(uintptr(f))
}

arch_context_switch :: proc "contextless" (save_sp: ^u64, load_sp: u64) {
	vx_context_switch(save_sp, load_sp)
}

arch_enter_user :: proc "contextless" (entry, sp: Uva, arg, arg2, kstack_top: u64) -> ! {
	step_on_return() // a new thread is never being stepped
	vx_enter_user(u64(entry), u64(sp), arg, arg2, kstack_top)
}

// The frame entry.S builds: Trap_Frame, then q0-q31, FPCR and FPSR.
TRAP_FRAME_SIZE :: size_of(Trap_Frame) + 32 * 16 + 16

// --- User-mode registers (exception.odin) ---

// The frame at the top of a thread's kernel stack: its user-mode registers,
// once it has entered the kernel from user mode.
arch_user_frame :: proc "contextless" (th: ^Thread) -> ^Trap_Frame {
	return cast(^Trap_Frame)uintptr(thread_kstack_top(th) - TRAP_FRAME_SIZE)
}

arch_frame_regs :: proc "contextless" (f: ^Trap_Frame) -> vx.Regs {
	return {x = f.x, sp = f.sp_el0, pc = f.elr, pstate = f.spsr}
}

// NZCV only: EL0t, every interrupt unmasked.
@(require_results)
arch_frame_set_regs :: proc "contextless" (f: ^Trap_Frame, r: ^vx.Regs) -> vx.Status {
	if r.pc >= u64(USER_TOP) || r.sp > u64(USER_TOP) {
		return .Err_Invalid
	}
	f.x = r.x
	f.sp_el0 = r.sp
	f.elr = r.pc
	f.spsr = r.pstate & 0xf000_0000
	return .Ok
}

regs_sp :: proc "contextless" (r: ^vx.Regs) -> Uva {
	return Uva(r.sp)
}

regs_pc :: proc "contextless" (r: ^vx.Regs) -> u64 {
	return r.pc
}

// The register a syscall's result goes back in.
regs_result :: proc "contextless" (r: ^vx.Regs) -> u64 {
	return r.x[0]
}

// To pc(arg), with arg (16-aligned) as the stack pointer, and no frame or
// return address to go back to.
arch_frame_divert :: proc "contextless" (f: ^Trap_Frame, pc, arg: Uva) -> bool {
	f.elr = u64(pc)
	f.sp_el0 = u64(arg)
	f.x[0] = u64(arg)
	f.x[29] = 0
	f.x[30] = 0
	return true
}

@(private="file")
SPSR_SS :: u64(1) << 21 // software step
@(private="file")
MDSCR_SS :: u64(1)
@(private="file")
MDSCR_KDE :: u64(1) << 13

// Always the current thread's frame: its own exception, or its resumption.
arch_frame_step :: proc "contextless" (f: ^Trap_Frame, on: bool) {
	f.spsr = on ? f.spsr | SPSR_SS : f.spsr &~ SPSR_SS
	this_cpu().current.stepping = on
}

// MDSCR_EL1.SS on only for a return to a thread being stepped: with it on, a
// return with SPSR.SS clear takes a step exception at once (the
// active-pending state), before running anything. Which is what a stepped
// svc needs: the call leaves SPSR.SS clear, the instruction done, and the
// step is reported as the call returns. So it follows the thread's stepping,
// not SPSR.SS, which would lose that step.
@(private="file")
step_enabled: [MAX_CPUS]bool

@(private="file")
step_on_return :: proc "contextless" () {
	want := this_cpu().current.stepping
	cpu := arch_cpu_index()
	if step_enabled[cpu] == want {
		return
	}
	mdscr := vx_read_mdscr()
	vx_write_mdscr(want ? mdscr | MDSCR_SS : mdscr &~ MDSCR_SS)
	step_enabled[cpu] = want
}

// TPIDR_EL0 is the user's to write directly; the kernel only keeps it with
// its thread.
arch_tls_read :: proc "contextless" () -> u64 {
	return vx_read_tpidr_el0()
}

arch_tls_write :: proc "contextless" (value: u64) {
	vx_write_tpidr_el0(value)
}

// The vector state entry.S saves above the general registers (ADR-0004):
// q0-q31, FPCR and FPSR, laid out as an Fpregs.
@(private="file")
frame_fp :: proc "contextless" (f: ^Trap_Frame) -> ^vx.Fpregs {
	return cast(^vx.Fpregs)uintptr(u64(uintptr(f)) + size_of(Trap_Frame))
}

#assert(size_of(vx.Fpregs) == TRAP_FRAME_SIZE - size_of(Trap_Frame))

arch_frame_fpregs :: proc "contextless" (f: ^Trap_Frame) -> vx.Fpregs {
	return frame_fp(f)^
}

// FPCR and FPSR are kept to their defined bits.
arch_frame_set_fpregs :: proc "contextless" (f: ^Trap_Frame, r: ^vx.Fpregs) {
	fp := frame_fp(f)
	fp^ = r^
	fp.fpcr &= 0x07ff_9f00
	fp.fpsr &= 0xf800_009f
}

// Code written through the direct map: cleaned to the point of unification,
// then every CPU's instruction cache invalidated (cpu.S).
arch_sync_icache :: proc "contextless" (p: []u8) {
	vx_sync_icache(raw_data(p), u64(len(p)))
}

// Watchpoints (thread_state .Set_Watch): DBGWVRn_EL1 and DBGWCRn_EL1, for
// EL0 only (PAC), so the kernel's own accesses never fire them, with
// MDSCR_EL1.MDE on while a task that has them runs. ID_AA64DFR0_EL1.WRPs says
// how many there are.
@(private="file")
watch_loaded: [MAX_CPUS]bool
@(private="file")
MDSCR_MDE :: u64(1) << 15

arch_watch_count :: proc "contextless" () -> u32 {
	return min(u32(vx_read_id_aa64dfr0() >> 20 & 15) + 1, vx.WATCH_MAX)
}

arch_watch_load :: proc "contextless" (t: ^Task) {
	cpu := arch_cpu_index()
	if !t.watching && !watch_loaded[cpu] {
		return
	}
	for &w, i in t.watches[:arch_watch_count()] {
		if !t.watching || w.kind == .Off {
			vx_watch_slot(u32(i), 0, 0)
			continue
		}
		base, bas := w.address &~ 7, (u64(1) << w.len - 1) << (w.address & 7)
		lsc := w.kind == .Write ? u64(2) : 3 // stores, or loads and stores
		vx_watch_slot(u32(i), base, bas << 5 | lsc << 3 | 2 << 1 | 1) // BAS, LSC, PAC = EL0, E
	}
	mdscr := vx_read_mdscr()
	vx_write_mdscr(t.watching ? mdscr | MDSCR_MDE : mdscr &~ MDSCR_MDE)
	watch_loaded[cpu] = t.watching
}

// A user-mode fault as an exception: its kind, code and address.
@(private="file")
aarch64_exception_kind :: proc "contextless" (f: ^Trap_Frame) -> (kind: vx.Exception_Kind, code: u32, address: u64) {
	esr := transmute(Esr)f.esr
	code = u32(f.esr)
	#partial switch esr.ec {
	case .Dabt_Lower:
		return .Page_Fault, esr.iss & DABT_WNR != 0 ? 1 : 0, f.far
	case .Iabt_Lower:
		return .Page_Fault, 2, f.far
	case .Fp_Access:
		return .Fp_Disabled, code, 0
	case .Brk:
		return .Breakpoint, esr.iss & 0xffff, 0 // brk #imm
	case .Unknown, .Illegal_State:
		return .Illegal, code, 0
	case .Pc_Align, .Sp_Align:
		return .Alignment, code, f.far
	case .Fp_Exc64:
		return .Arithmetic, code, 0
	case .Step_Lower:
		return .Step, code, 0
	case .Watch_Lower: // before the access
		t := this_cpu().current.task
		slot: u32
		for w, i in t.watches { // the slot whose 8-byte span holds what was touched
			if w.kind != .Off && w.address &~ 7 == f.far &~ 7 {
				slot = u32(i)
			}
		}
		return .Watchpoint, slot, t.watches[slot].address
	}
	return .General, code, 0
}

@(export, link_name="aarch64_trap")
aarch64_trap :: proc "c" (f: ^Trap_Frame, index: u64) {
	from_user := index >= 8
	esr := transmute(Esr)f.esr
	switch {
	case index & 3 == 1: // IRQ
		aarch64_irq()
	case from_user && index & 3 == 0 && esr.ec == .Svc64:
		f.x[0] = u64(syscall_dispatch(f.x[8], {f.x[0], f.x[1], f.x[2], f.x[3], f.x[4], f.x[5]}))
	case !from_user && index & 3 == 0 && esr.ec == .Dabt_Same && f.far < u64(USER_TOP) && uaccess_fixup(f.elr) != 0:
		f.elr = uaccess_fixup(f.elr) // a user page gone under a copy: it reports the failure
	case from_user:
		kind, code, address := aarch64_exception_kind(f)
		if index & 3 != 0 {
			kind = .General // an SError or FIQ
		}
		if index & 3 != 0 || !exception_raise(f, kind, code, address) { // nobody took it
			task_fault_start()
			kput_exception(f, index)
			kput(" at pc ")
			kput_hex(f.elr)
			kput("\n")
			task_fault_exit(kind, code, address, f.elr)
		}
	case:
		panic_start()
		kput_exception(f, index)
		kput(" at pc ")
		kput_hex(f.elr)
		panic_end(f.elr, f.x[29])
	}
	if from_user {
		user_return()
		step_on_return()
	}
}

// --- ADR-0004's test (main.odin) ---

// q0-q31 live from `input` across interrupts until *fired reaches target,
// then stored to `output`: all 512 bytes.
arch_vreg_irq_test :: proc "contextless" (input, output: ^[512]u8, fired: ^u64, target: u64) -> int {
	vx_vreg_irq_test(input, output, fired, target)
	return 512
}

arch_clobber_vregs :: proc "contextless" () {
	vx_clobber_vregs()
}

// --- Devices: GIC SPIs (device.odin) ---
//
// SPIs are configured level-triggered, as the GIC starts them, and routed to
// the boot CPU.

@(private="file")
gic_lines: u32 // INTIDs below this exist

arch_devices_init :: proc "contextless" () {
	n := 32 * ((intrinsics.volatile_load(&gicd().typer) & 0x1f) + 1) // ITLinesNumber
	gic_lines = min(n, 1020)
}

arch_has_io_ports :: proc "contextless" () -> bool {
	return false
}

arch_console_device :: proc "contextless" (io: bool, base, size: u64) -> bool {
	return !io && base < PL011_PHYS + PAGE_SIZE && PL011_PHYS < base + size
}

arch_io_switch :: proc "contextless" (t: ^Task) {}

// SPIs only: SGIs and PPIs are the kernel's.
@(require_results)
arch_irq_canonical :: proc "contextless" (line: u32) -> (u32, vx.Status) {
	if line < 32 || line >= gic_lines {
		return 0, .Err_Range
	}
	return line, .Ok
}

@(require_results)
arch_irq_route :: proc "contextless" (line: u32) -> (level: bool, st: vx.Status) {
	d := gicd()
	bit := u32(1) << (line % 32)
	g := &d.igroupr[line / 32] // group 1
	intrinsics.volatile_store(g, intrinsics.volatile_load(g) | bit)
	intrinsics.volatile_store(&d.ipriorityr[line], 0x80)
	c := &d.icfgr[line / 16] // level-triggered
	intrinsics.volatile_store(c, intrinsics.volatile_load(c) &~ (2 << (line % 16 * 2)))
	intrinsics.volatile_store(&d.irouter[line], cpus[0].arch_id & 0xff_00ff_ffff)
	intrinsics.volatile_store(&d.isenabler[line / 32], bit)
	return true, .Ok
}

arch_irq_mask :: proc "contextless" (line: u32, masked: bool) {
	// An MSI is edge-triggered; arch_msi_destroy turns it off.
	if line < 32 || line >= gic_lines {
		return
	}
	d := gicd()
	reg := masked ? &d.icenabler[line / 32] : &d.isenabler[line / 32]
	intrinsics.volatile_store(reg, u32(1) << (line % 32))
}

// --- MSIs: LPIs through the ITS ---
//
// A PCI function's MSI write goes to the ITS's translation register, with the
// function's requester ID as its DeviceID and the data as an EventID. The ITS
// maps the pair to an LPI, through tables in memory it is given, and sends
// the LPI to a redistributor: here always the boot CPU's, through collection
// 0. The kernel sets it all up the first time an MSI is created. LPIs are
// edge-triggered and have no active state; one is turned off by clearing its
// enable bit in the configuration table.

@(private="file")
ITS_PHYS_DEFAULT :: Paddr(0x0808_0000) // QEMU virt's, if the MADT has none
@(private="file")
ITS_SIZE :: u64(128 * 1024)
@(private="file")
ITS_TRANSLATER :: 0x1_0040 // GITS_TRANSLATER, in the ITS's second frame
LPI_BASE :: 8192
LPI_COUNT :: 1024
@(private="file")
LPI_ID_BITS :: 14 // INTIDs up to 2^14: LPIs 8192..16383
@(private="file")
ITS_EVENTS :: 32 // per device
@(private="file")
ITS_QUEUE_BYTES :: 64 * 1024

// The ITS's control registers that the kernel uses.
@(private="file")
Its :: struct {
	ctlr:    u32,
	iidr:    u32,
	typer:   u64,
	_:       [(0x80 - 0x10) / 8]u64,
	cbaser:  u64, // the command queue
	cwriter: u64,
	creadr:  u64,
	_:       [(0x100 - 0x98) / 8]u64,
	baser:   [8]u64, // the tables it asks for
}

#assert(offset_of(Its, typer) == 0x08)
#assert(offset_of(Its, cbaser) == 0x80)
#assert(offset_of(Its, cwriter) == 0x88)
#assert(offset_of(Its, creadr) == 0x90)
#assert(offset_of(Its, baser) == 0x100)

// The LPI configuration byte: a priority, bit 1 (RES1, group 1), and bit 0, enable.
@(private="file")
LPI_OFF :: 0xa2
@(private="file")
LPI_ON :: 0xa3

// ITS commands, by their opcodes.
@(private="file")
Its_Command :: enum u64 {
	Sync    = 0x05,
	Mapd    = 0x08,
	Mapc    = 0x09,
	Mapti   = 0x0a,
	Inv     = 0x0c,
	Discard = 0x0f,
}

@(private="file")
Its_Device :: struct {
	id:     u32, // the DeviceID: a requester ID
	events: bit_set[0 ..< ITS_EVENTS; u32], // the EventIDs in use
	used:   bool,
}

@(private="file")
Lpi_Event :: struct { // what an LPI in use was mapped from
	device: u8, // in its.devices
	event:  u8,
	used:   bool,
}

@(private="file")
boot_rd: ^Gicr // the boot CPU's redistributor

@(private="file")
its: struct {
	regs:       ^Its,
	pa:         Paddr,
	lpi_config: []u8, // a byte for each LPI: priority, and bit 0 enables it
	queue:      []u64, // the command queue
	queue_at:   u64, // bytes written
	target:     u64, // the redistributor, as MAPC and SYNC name it
	device_ids: u64, // DeviceIDs below this fit the ITS and its device table
	unusable:   bool, // its setup failed: no MSIs (and no second try)
	devices:    [64]Its_Device,
	lpis:       [LPI_COUNT]Lpi_Event,
}

@(private="file")
its_command :: proc "contextless" (op: Its_Command, d0_high: u64, d1, d2, d3: u64) {
	at := its.queue_at / 8
	its.queue[at] = u64(op) | d0_high << 32
	its.queue[at + 1] = d1
	its.queue[at + 2] = d2
	its.queue[at + 3] = d3
	its.queue_at = (its.queue_at + 32) % ITS_QUEUE_BYTES
	vx_pte_publish() // the command reaches memory before the ITS is told
	intrinsics.volatile_store(&its.regs.cwriter, its.queue_at)
	for { // until it has run them
		read := intrinsics.volatile_load(&its.regs.creadr)
		if read & 1 != 0 {
			kpanic("the GIC's ITS stalled on a command") // Stalled: a command it refused
		}
		if read == its.queue_at {
			break
		}
	}
}

@(private="file")
its_sync :: proc "contextless" () {
	its_command(.Sync, 0, 0, its.target << 16, 0)
}

@(private="file")
its_table :: proc "contextless" (order: uint) -> Paddr {
	pa := phys_alloc_zeroed(order)
	if pa == 0 {
		kpanic("no memory for the ITS's tables")
	}
	return pa
}

@(private="file", require_results)
its_init :: proc "contextless" () -> vx.Status {
	if its.regs != nil {
		return .Ok
	}
	if its.unusable {
		return .Err_Unsupported
	}
	its.unusable = true // until it has all worked
	if boot_rd == nil || intrinsics.volatile_load(&gicd().typer) & (1 << 17) == 0 { // GICD_TYPER.LPIS
		return .Err_Unsupported
	}
	pa := ITS_PHYS_DEFAULT
	if madt := acpi_table("APIC"); madt != nil {
		for off := 44; off + 2 <= len(madt) && madt[off + 1] >= 2; off += int(madt[off + 1]) {
			if madt[off] == 0xf && madt[off + 1] >= 20 && off + 16 <= len(madt) { // a GIC ITS structure
				pa = Paddr(read64(madt[off + 8:]))
			}
		}
	}
	if !map_range(kernel_root, boot.hhdm + u64(pa), pa, ITS_SIZE, {.Write, .Device}) {
		return .Err_No_Memory
	}
	regs := cast(^Its)uintptr(boot.hhdm + u64(pa))
	typer := intrinsics.volatile_load(&regs.typer)

	// The redistributor: its LPI configuration and pending tables, then LPIs on.
	config := its_table(1) // 8 KiB: a byte for each of 8192 LPIs
	its.lpi_config = (cast([^]u8)phys_to_virt(config))[:2 * PAGE_SIZE]
	for &c in its.lpi_config[:LPI_COUNT] {
		c = LPI_OFF
	}
	pending := its_table(4) // 64 KiB-aligned, as the GIC requires
	intrinsics.volatile_store(&boot_rd.propbaser, u64(config) | 1 << 10 | 7 << 7 | (LPI_ID_BITS - 1))
	intrinsics.volatile_store(&boot_rd.pendbaser, u64(pending) | 1 << 10 | 7 << 7)
	intrinsics.volatile_store(&boot_rd.ctlr, intrinsics.volatile_load(&boot_rd.ctlr) | 1) // EnableLPIs

	// The ITS: the tables it asks for (devices and collections), then the command queue.
	for &baser in regs.baser {
		b := intrinsics.volatile_load(&baser)
		type, entry := b >> 56 & 7, (b >> 48 & 0x1f) + 1
		if type != 1 && type != 4 {
			continue // devices, collections
		}
		bits := type == 1 ? (typer >> 13 & 0x1f) + 1 : 16
		pages := min(((entry << bits) + PAGE_SIZE - 1) / PAGE_SIZE, 256) // 1 MiB of entries is room for every device QEMU has
		if type == 1 {
			its.device_ids = min(pages * PAGE_SIZE / entry, 1 << bits)
		}
		order: uint
		for (u64(1) << order) < pages {
			order += 1
		}
		want := 1 << 63 | 7 << 59 | (entry - 1) << 48 | u64(its_table(order)) | 1 << 10 | (pages - 1)
		intrinsics.volatile_store(&baser, want)
		// The ITS may not take 4 KiB pages or inner-shareable, cached tables;
		// then these tables are the wrong size or need cache maintenance: no MSIs.
		ATTRS :: u64(3 << 8 | 3 << 10)
		if intrinsics.volatile_load(&baser) & ATTRS != want & ATTRS {
			return .Err_Unsupported
		}
	}
	queue := its_table(4)
	its.queue = (cast([^]u64)phys_to_virt(queue))[:ITS_QUEUE_BYTES / 8]
	intrinsics.volatile_store(&regs.cbaser, 1 << 63 | 7 << 59 | u64(queue) | 1 << 10 | 15)
	intrinsics.volatile_store(&regs.cwriter, 0)
	intrinsics.volatile_store(&regs.ctlr, intrinsics.volatile_load(&regs.ctlr) | 1) // Enabled
	its.regs = regs
	its.pa = pa

	// Collection 0 is the boot CPU's redistributor, by address or by number as GITS_TYPER.PTA says.
	rd_pa := u64(virt_to_phys(boot_rd))
	its.target = typer & (1 << 19) != 0 ? rd_pa >> 16 : intrinsics.volatile_load(&boot_rd.typer) >> 8 & 0xffff
	its_command(.Mapc, 0, 0, 1 << 63 | its.target << 16 | 0, 0) // valid, target, ICID 0
	its_sync()
	its.unusable = false
	return .Ok
}

// Called with irq_lines_lock held.
arch_msi_create :: proc "contextless" (source: u32) -> (line: u32, msi: vx.Msi, st: vx.Status) {
	its_init() or_return
	lpi := u32(0)
	for lpi < LPI_COUNT && irq_lines[MSI_LINE_BASE + lpi] != nil {
		lpi += 1
	}
	if u64(source) >= its.device_ids {
		return 0, {}, .Err_Range // a DeviceID the ITS has no room for would stall it
	}
	dev, free_dev := -1, -1
	for d, i in its.devices {
		if d.used && d.id == source {
			dev = i
		}
		if !d.used && free_dev < 0 {
			free_dev = i
		}
	}
	if lpi == LPI_COUNT || (dev < 0 && free_dev < 0) {
		return 0, {}, .Err_No_Memory
	}
	if dev < 0 { // a new device: its interrupt translation table, then MAPD
		dev = free_dev
		its.devices[dev] = {id = source, used = true}
		itt := its_table(0)
		its_command(.Mapd, u64(source), 4 /* 5 EventID bits */, 1 << 63 | u64(itt), 0)
	}
	d := &its.devices[dev]
	event := 0
	for event < ITS_EVENTS && (event in d.events) {
		event += 1
	}
	if event == ITS_EVENTS {
		return 0, {}, .Err_No_Memory
	}
	d.events += {event}
	its.lpis[lpi] = {device = u8(dev), event = u8(event), used = true}
	its.lpi_config[lpi] = LPI_ON
	vx_pte_publish()
	its_command(.Mapti, u64(source), u64(event) | u64(LPI_BASE + lpi) << 32, 0, 0) // to ICID 0
	its_command(.Inv, u64(source), u64(event), 0, 0)
	its_sync()
	return MSI_LINE_BASE + lpi, {address = u64(its.pa) + ITS_TRANSLATER, data = u32(event)}, .Ok
}

// Turns the LPI off and forgets its event. (The ITS keeps the device's
// table: devices come back, as restarted drivers do.)
arch_msi_destroy :: proc "contextless" (line: u32) {
	lpi := line - MSI_LINE_BASE
	if lpi >= LPI_COUNT || !its.lpis[lpi].used {
		return
	}
	its.lpi_config[lpi] = LPI_OFF
	e := its.lpis[lpi]
	d := &its.devices[e.device]
	its_command(.Discard, u64(d.id), u64(e.event), 0, 0)
	its_sync()
	d.events -= {int(e.event)}
	its.lpis[lpi].used = false
}
