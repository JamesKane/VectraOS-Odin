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

@(private="file")
PL011_PHYS :: 0x0900_0000
@(private="file")
PL011_DR :: 0x00 / 4 // data register, as a u32 index
@(private="file")
PL011_FR :: 0x18 / 4 // flag register
@(private="file")
PL011_FR_TXFF :: 1 << 5 // transmit FIFO full

@(private="file")
pl011: [^]u32

arch_kernel_mappings :: proc "contextless" (root: Paddr) {
	gicr_size := GICR_FRAME_SIZE * max(boot.cpu_count, 1)
	if !map_range(root, boot.hhdm + PL011_PHYS, PL011_PHYS, 4096, {.Write, .Device}) ||
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
	if map_range(Paddr(vx_read_ttbr1() & u64(PTE_ADDR)), va, PL011_PHYS, 4096, {.Write, .Device}) {
		pl011 = cast([^]u32)uintptr(va)
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
	for intrinsics.volatile_load(&pl011[PL011_FR]) & PL011_FR_TXFF != 0 {}
	intrinsics.volatile_store(&pl011[PL011_DR], u32(c))
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

// Sets up the GIC for this CPU: the distributor once, on the boot CPU, then
// this CPU's redistributor with the timer's PPI enabled, then its interface.
arch_timer_init :: proc "contextless" () {
	if arch_cpu_index() == 0 {
		gicd := cast(^u32)uintptr(boot.hhdm + GICD_PHYS)
		intrinsics.volatile_store(gicd, 1 << 4 | 1 << 1 | 1 << 0) // GICD_CTLR: affinity routing, both groups
	}

	// Find this CPU's redistributor by its affinity.
	mpidr := vx_read_mpidr()
	aff := u32((mpidr >> 32 & 0xff) << 24 | (mpidr & 0xffffff))
	rd: u64
	for i in 0 ..< max(boot.cpu_count, 1) {
		frame := boot.hhdm + GICR_PHYS + i * GICR_FRAME_SIZE
		typer := intrinsics.volatile_load(cast(^u64)uintptr(frame + 0x08))
		if u32(typer >> 32) == aff {
			rd = frame
			break
		}
		if typer & (1 << 4) != 0 {
			break // the last redistributor
		}
	}
	if rd == 0 {
		kpanic("no GIC redistributor for this CPU")
	}

	waker := cast(^u32)uintptr(rd + 0x14)
	intrinsics.volatile_store(waker, intrinsics.volatile_load(waker) &~ (1 << 1)) // clear ProcessorSleep
	for intrinsics.volatile_load(waker) & (1 << 2) != 0 {} // wait for ChildrenAsleep to clear

	sgi := rd + 0x1_0000 // the SGI and PPI frame
	ppi := timer_ppi()
	group := cast(^u32)uintptr(sgi + 0x080) // GICR_IGROUPR0: group 1
	lines := u32(1) << ppi | 1 << INTID_RESCHED
	intrinsics.volatile_store(group, intrinsics.volatile_load(group) | lines)
	intrinsics.volatile_store(cast(^u8)uintptr(sgi + 0x400 + u64(ppi)), 0x80) // priorities
	intrinsics.volatile_store(cast(^u8)uintptr(sgi + 0x400 + INTID_RESCHED), 0x80)
	intrinsics.volatile_store(cast(^u32)uintptr(sgi + 0x100), lines) // GICR_ISENABLER0
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
		return // spurious
	}
	if intid == INTID_VIRTUAL_TIMER || intid == INTID_EL2_VIRTUAL_TIMER {
		vx_timer_disarm() // disarm before the EOI: the line is level-triggered
		timer_interrupt()
	} else if intid == INTID_RESCHED {
		this_cpu().resched = true
	} else if intid >= 32 {
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

// Describes an exception: "page fault at 0x... (read, not present, user)", say.
@(private="file")
kput_exception :: proc "contextless" (f: ^Trap_Frame, index: u64) {
	ec := u32(f.esr >> 26) & 0x3f
	iss := u32(f.esr) & 0x1ffffff
	switch {
	case index & 3 == 0 && (ec == 0x24 || ec == 0x25): // data abort
		kput("page fault at ")
		kput_hex(f.far)
		kput(iss & (1 << 6) != 0 ? " (write, " : " (read, ")
		kput(iss & 0x3c == 0x04 ? "not present" : "protection")
		kput(ec == 0x24 ? ", user)" : ", kernel)")
	case index & 3 == 0 && (ec == 0x20 || ec == 0x21):
		kput("page fault at ")
		kput_hex(f.far)
		kput(" (execute)")
	case index & 3 == 0 && ec == 0x3c && iss & 0xffff == 1:
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
// level 0 as a bit in the target list.
arch_send_resched :: proc "contextless" (c: ^Cpu) {
	m := c.arch_id
	aff3, aff2, aff1, aff0 := (m >> 32) & 0xff, (m >> 16) & 0xff, (m >> 8) & 0xff, m & 0xf
	vx_write_icc_sgi1r(aff3 << 48 | aff2 << 32 | aff1 << 16 | u64(INTID_RESCHED) << 24 | 1 << aff0)
}

// Exceptions from EL0 land on SP_EL1, which is the top of the current
// thread's kernel stack whenever it runs in user mode: nothing to set.
arch_set_kernel_stack :: proc "contextless" (top: u64) {}

// A new thread's stack, as the context switch will pop it: x19 to x30, then
// d8 to d15, with x19 carrying the thread and x30 returning into
// thread_trampoline. It starts below the frame vx_enter_user builds at the top.
arch_thread_initial_sp :: proc "contextless" (th: ^Thread) -> u64 {
	sp := cast([^]u64)uintptr(thread_kstack_top(th) - TRAP_FRAME_SIZE - 160)
	sp[0] = u64(uintptr(th)) // x19
	sp[11] = u64(uintptr(rawptr(thread_trampoline))) // x30
	return u64(uintptr(sp))
}

arch_context_switch :: proc "contextless" (save_sp: ^u64, load_sp: u64) {
	vx_context_switch(save_sp, load_sp)
}

arch_enter_user :: proc "contextless" (entry, sp: Uva, arg, arg2, kstack_top: u64) -> ! {
	vx_enter_user(u64(entry), u64(sp), arg, arg2, kstack_top)
}

// The frame entry.S builds: Trap_Frame, then q0-q31, FPCR and FPSR.
TRAP_FRAME_SIZE :: size_of(Trap_Frame) + 32 * 16 + 16

@(private="file")
EC_SVC64 :: 0x15

@(export, link_name="aarch64_trap")
aarch64_trap :: proc "c" (f: ^Trap_Frame, index: u64) {
	from_user := index >= 8
	ec := u32(f.esr >> 26) & 0x3f
	switch {
	case index & 3 == 1: // IRQ
		aarch64_irq()
	case from_user && index & 3 == 0 && ec == EC_SVC64:
		f.x[0] = u64(syscall_dispatch(f.x[8], {f.x[0], f.x[1], f.x[2], f.x[3], f.x[4], f.x[5]}))
	case from_user:
		task_fault_start()
		kput_exception(f, index)
		kput(" at pc ")
		kput_hex(f.elr)
		kput("\n")
		task_fault_exit()
	case:
		panic_start()
		kput_exception(f, index)
		kput(" at pc ")
		kput_hex(f.elr)
		panic_end(f.elr, f.x[29])
	}
	if from_user {
		user_return()
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

@(private="file")
gicd_reg :: proc "contextless" (off: u64) -> ^u32 {
	return cast(^u32)uintptr(boot.hhdm + GICD_PHYS + off)
}

arch_devices_init :: proc "contextless" () {
	n := 32 * ((intrinsics.volatile_load(gicd_reg(0x004)) & 0x1f) + 1) // GICD_TYPER.ITLinesNumber
	gic_lines = min(n, 1020)
}

arch_has_io_ports :: proc "contextless" () -> bool {
	return false
}

arch_console_device :: proc "contextless" (io: bool, base, size: u64) -> bool {
	return !io && base < PL011_PHYS + 4096 && PL011_PHYS < base + size
}

arch_io_switch :: proc "contextless" (t: ^Task) {}

// SPIs only: SGIs and PPIs are the kernel's.
arch_irq_canonical :: proc "contextless" (line: u32) -> (u32, vx.Status) {
	if line < 32 || line >= gic_lines {
		return 0, .Err_Range
	}
	return line, .Ok
}

arch_irq_route :: proc "contextless" (line: u32) -> (level: bool, st: vx.Status) {
	bit := u32(1) << (line % 32)
	g := gicd_reg(0x080 + 4 * u64(line / 32)) // GICD_IGROUPR: group 1
	intrinsics.volatile_store(g, intrinsics.volatile_load(g) | bit)
	intrinsics.volatile_store(cast(^u8)uintptr(boot.hhdm + GICD_PHYS + 0x400 + u64(line)), 0x80) // GICD_IPRIORITYR
	c := gicd_reg(0xc00 + 4 * u64(line / 16)) // GICD_ICFGR: level-triggered
	intrinsics.volatile_store(c, intrinsics.volatile_load(c) &~ (2 << (line % 16 * 2)))
	route := cast(^u64)uintptr(boot.hhdm + GICD_PHYS + 0x6000 + 8 * u64(line)) // GICD_IROUTER
	intrinsics.volatile_store(route, cpus[0].arch_id & 0xff_00ff_ffff)
	intrinsics.volatile_store(gicd_reg(0x100 + 4 * u64(line / 32)), bit) // GICD_ISENABLER
	return true, .Ok
}

arch_irq_mask :: proc "contextless" (line: u32, masked: bool) {
	if line < 32 || line >= gic_lines {
		return
	}
	off: u64 = masked ? 0x180 : 0x100 // GICD_ICENABLER or GICD_ISENABLER
	intrinsics.volatile_store(gicd_reg(off + 4 * u64(line / 32)), u32(1) << (line % 32))
}
