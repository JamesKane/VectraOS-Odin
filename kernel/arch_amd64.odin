package kernel

import "base:intrinsics"
import vx "abi:vx"

// x86_64: the serial console (COM1, a 16550), the GDT, TSS and IDT, traps,
// page-table entries, and the clock and timer (the TSC, and the local APIC
// in x2APIC mode).

foreign _ {
	vx_outb :: proc "c" (port: u16, value: u8) ---
	vx_inb :: proc "c" (port: u16) -> u8 ---
	vx_rdmsr :: proc "c" (msr: u32) -> u64 ---
	vx_wrmsr :: proc "c" (msr: u32, value: u64) ---
	vx_cpuid :: proc "c" (leaf, subleaf: u32, out: ^[4]u32) ---
	vx_rdtsc :: proc "c" () -> u64 ---
	vx_read_cr2 :: proc "c" () -> u64 ---
	vx_read_cr4 :: proc "c" () -> u64 ---
	vx_write_cr4 :: proc "c" (v: u64) ---
	vx_switch_tables :: proc "c" (root: u64) ---
	vx_load_gdt :: proc "c" (gdtr: ^Descriptor_Ptr, tss_selector: u16) ---
	vx_load_idt :: proc "c" (idtr: ^Descriptor_Ptr) ---
	vx_cpu_index :: proc "c" () -> u64 ---
	vx_pause :: proc "c" () ---
	vx_wait :: proc "c" () ---
	vx_halt :: proc "c" () -> ! ---
	vx_mfence :: proc "c" () ---
	vx_frame_address :: proc "c" () -> u64 ---
	vx_run_on_stack :: proc "c" (top: u64, fn: proc "c" () -> !) -> ! ---
	vx_read_xcr0 :: proc "c" () -> u64 ---
	vx_write_cr3 :: proc "c" (root: u64) ---
	vx_read_cr3 :: proc "c" () -> u64 ---
	vx_invlpg :: proc "c" (va: u64) ---
	vx_context_switch :: proc "c" (save_sp: ^u64, load_sp: u64) ---
	vx_enter_user :: proc "c" (entry, sp, arg, arg2, kstack_top: u64) -> ! ---
	syscall_entry :: proc "c" () --- // entry.S: an address only
	thread_trampoline :: proc "c" () --- // entry.S: an address only
	vx_vreg_irq_test_avx :: proc "c" (input, output: ^[512]u8, fired: ^u64, target: u64) ---
	vx_vreg_irq_test_sse :: proc "c" (input, output: ^[512]u8, fired: ^u64, target: u64) ---
	vx_clobber_vregs_avx :: proc "c" () ---
	vx_clobber_vregs_sse :: proc "c" () ---
	x86_vector_table :: proc "c" () --- // entry.S's 256 stub addresses: an address only
}

// The XSAVE area entry.S reserves below each trap frame (simd_init sets it),
// and the kernel's top table for ap_start and ap_park: Odin's, which the
// assembly reads.
@(export)
vx_xsave_size: u64 = 4096
@(export)
ap_park_tables: [1]u64

// --- Limine's multiprocessor response ---

MP_REQUEST_FLAGS :: 1 // x2APIC IDs

Mp_Info :: struct {
	processor_id:   u32,
	lapic_id:       u32,
	reserved:       u64,
	goto_address:   rawptr,
	extra_argument: u64,
}

#assert(offset_of(Mp_Info, extra_argument) == 24) // entry.S's ap_start reads it there

Mp_Response :: struct {
	revision:     u64,
	flags:        u32,
	bsp_lapic_id: u32,
	cpu_count:    u64,
	cpus:         [^]^Mp_Info,
}

mp_bsp_id :: proc "contextless" (mp: ^Mp_Response) -> u64 {
	return u64(mp.bsp_lapic_id)
}

mp_info_id :: proc "contextless" (info: ^Mp_Info) -> u64 {
	return u64(info.lapic_id)
}

// --- The console ---

@(private="file")
COM1 :: 0x3f8

arch_console_init :: proc "contextless" () {
	vx_outb(COM1 + 1, 0x00) // no interrupts
	vx_outb(COM1 + 3, 0x80) // divisor latch on
	vx_outb(COM1 + 0, 0x01) // divisor 1: 115200 baud
	vx_outb(COM1 + 1, 0x00)
	vx_outb(COM1 + 3, 0x03) // 8 bits, no parity, one stop bit; latch off
	vx_outb(COM1 + 2, 0xc7) // FIFOs on and cleared
}

@(private="file")
serial_putc :: proc "contextless" (c: u8) {
	for vx_inb(COM1 + 5) & 0x20 == 0 {} // wait for an empty transmit register
	vx_outb(COM1, c)
}

arch_console_write :: proc "contextless" (s: string) {
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			serial_putc('\r')
		}
		serial_putc(s[i])
	}
}

// --- GDT, TSS and IDT ---

SEL_KERNEL_CODE :: 0x08
SEL_KERNEL_DATA :: 0x10
SEL_TSS :: 0x28

Tss :: struct #packed {
	reserved0:  u32,
	rsp:        [3]u64, // stacks for entering rings 0-2 from user mode
	reserved1:  u64,
	ist:        [7]u64, // the interrupt stack table: IST1..IST7
	reserved2:  u64,
	reserved3:  u16,
	iomap_base: u16,
}

#assert(size_of(Tss) == 104)

Descriptor_Ptr :: struct #packed {
	limit: u16,
	base:  u64,
}

Idt_Entry :: struct {
	offset_low:  u16,
	selector:    u16,
	ist:         u8,
	type:        u8, // 0x8e: present interrupt gate, DPL 0
	offset_mid:  u16,
	offset_high: u32,
	reserved:    u32,
}

#assert(size_of(Idt_Entry) == 16)

// Double faults, NMIs and machine checks run on stacks of their own, so a
// kernel stack overflow or a fault at the wrong moment still reaches the
// panic. Each holds a trap frame and an XSAVE area below it.
IST_DOUBLE_FAULT :: 1
IST_NMI :: 2
IST_MACHINE_CHECK :: 3
IST_STACK_SIZE :: 8192

@(private="file")
boot_ist_stacks: [3][IST_STACK_SIZE]u8 // the boot CPU's, before the allocator exists

@(private="file")
GDT_TEMPLATE := [7]u64 {
	0,
	0x00af9a000000ffff, // 0x08 kernel code, 64-bit
	0x00cf92000000ffff, // 0x10 kernel data
	0x00cff2000000ffff, // 0x18 user data
	0x00affa000000ffff, // 0x20 user code, 64-bit
	0,
	0, // 0x28 the TSS, 16 bytes, filled in per CPU
}

// Per-CPU data at %gs while in the kernel; entry.S reads the first two fields.
Cpu_Local :: struct {
	kernel_rsp: u64, // the current thread's kernel stack top
	user_rsp:   u64, // scratch for SYSCALL
	index:      u64, // this CPU's index, for arch_cpu_index
}

#assert(offset_of(Cpu_Local, index) == 16) // cpu.S's vx_cpu_index

// Each CPU has its own GDT (for its own TSS descriptor), TSS and GS data.
// The IDT is shared.
// The TSS's I/O permission bitmap follows it: a 0 bit lets user code use
// that port. It holds the ports of the task this CPU runs (arch_io_switch),
// and `open` remembers which, to close them again.
@(private="file")
IO_PORTS :: 0x1_0000

@(private="file")
X86_Cpu :: struct {
	gdt:        [7]u64,
	tss:        Tss,
	iomap:      [IO_PORTS / 8 + 1]u8, // one bit a port, then the 0xff the CPU requires after the last
	open:       [dynamic; TASK_MAX_IO]Io_Range,
	local:      Cpu_Local,
}

#assert(offset_of(X86_Cpu, iomap) == offset_of(X86_Cpu, tss) + size_of(Tss))

@(private="file")
x86_cpus: [MAX_CPUS]X86_Cpu

@(private="file")
idt: [256]Idt_Entry

@(private="file")
percpu_ready: bool // %gs holds this CPU's Cpu_Local

MSR_EFER :: 0xc0000080
MSR_STAR :: 0xc0000081
MSR_LSTAR :: 0xc0000082
MSR_FMASK :: 0xc0000084
MSR_GS_BASE :: 0xc0000101
MSR_KERNEL_GS_BASE :: 0xc0000102

@(private="file")
EFER_SCE :: 1 << 0 // SYSCALL and SYSRET
@(private="file")
EFER_NXE :: 1 << 11 // the NX bit is honoured
@(private="file")
CR4_TSD :: 1 << 2 // RDTSC only in ring 0
@(private="file")
CR4_FSGSBASE :: 1 << 16 // RDFSBASE and friends in user mode
@(private="file")
CPUID1_ECX_X2APIC :: 1 << 21
@(private="file")
CPUID1_ECX_TSC_DEADLINE :: 1 << 24
@(private="file")
CPUID1_ECX_XSAVE :: 1 << 26

// The TSS's descriptor: the low half of a 16-byte system descriptor (the
// high half is the base's upper 32 bits).
@(private="file")
Tss_Descriptor :: bit_field u64 {
	limit_lo: u64 | 16,
	base_lo:  u64 | 24,
	type:     u8  | 8, // 0x89: present, a 64-bit TSS, available
	limit_hi: u64 | 4,
	flags:    u8  | 4,
	base_hi:  u64 | 8,
}

arch_cpu_index :: proc "contextless" () -> u32 {
	return percpu_ready ? u32(vx_cpu_index()) : 0
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

cpuid :: proc "contextless" (leaf: u32, subleaf: u32 = 0) -> (r: [4]u32) {
	vx_cpuid(leaf, subleaf, &r)
	return
}

@(private="file")
build_idt :: proc "contextless" () {
	for v in 0 ..< 256 {
		h := (cast([^]u64)rawptr(x86_vector_table))[v]
		idt[v] = Idt_Entry {
			offset_low  = u16(h),
			selector    = SEL_KERNEL_CODE,
			type        = 0x8e,
			offset_mid  = u16(h >> 16),
			offset_high = u32(h >> 32),
		}
	}
	idt[3].type = 0xee // int3 may come from user mode (DPL 3): a breakpoint, not a #GP
	idt[8].ist = IST_DOUBLE_FAULT
	idt[2].ist = IST_NMI
	idt[18].ist = IST_MACHINE_CHECK
}

// The XSAVE area every trap reserves (ADR-0004): the size CPUID leaf 0Dh
// gives for the state XCR0 enables, which entry.S's ENABLE_SIMD chose.
@(private="file")
simd_init :: proc "contextless" () {
	if cpuid(1)[2] & CPUID1_ECX_XSAVE == 0 {
		kpanic("the CPU has no XSAVE, which the kernel needs for vector state (ADR-0004)")
	}
	size := u64(cpuid(0xd, 0)[1])
	intrinsics.volatile_store(&vx_xsave_size, (size + 63) &~ 63)
}

// Per CPU: control registers and MSRs, this CPU's GDT, TSS and GS data, and
// the shared IDT (built by the boot CPU).
arch_cpu_init :: proc "contextless" (index: u32) {
	xc := &x86_cpus[index]
	vx_wrmsr(MSR_EFER, vx_rdmsr(MSR_EFER) | EFER_NXE | EFER_SCE)
	// SYSCALL loads CS 0x08 and SS 0x10; returns go through IRETQ.
	vx_wrmsr(MSR_STAR, u64(0x10) << 48 | u64(SEL_KERNEL_CODE) << 32)
	vx_wrmsr(MSR_LSTAR, u64(uintptr(rawptr(syscall_entry))))
	vx_wrmsr(MSR_FMASK, 0x47700) // clear TF, IF, DF, NT and AC on entry
	xc.local.index = u64(index)
	vx_wrmsr(MSR_GS_BASE, u64(uintptr(&xc.local)))
	vx_wrmsr(MSR_KERNEL_GS_BASE, 0)
	// TSD off: user code may always read the cycle counter. FSGSBASE off:
	// user code changes its FS base only through thread_state.
	vx_write_cr4(vx_read_cr4() &~ (CR4_TSD | CR4_FSGSBASE))
	if index == 0 {
		simd_init()
	}

	ist: [^]u8
	if index == 0 {
		ist = &boot_ist_stacks[0][0]
	} else {
		pa := phys_alloc_zeroed(3) // 32 KiB: three 8 KiB stacks
		if pa == 0 {
			kpanic("no memory for interrupt stacks")
		}
		ist = cast([^]u8)phys_to_virt(pa)
	}
	xc.tss = {iomap_base = size_of(Tss)}
	for &b in xc.iomap {
		b = 0xff // no ports for user code
	}
	xc.open = {}
	for i in 0 ..< 3 {
		xc.tss.ist[i] = u64(uintptr(&ist[(i + 1) * IST_STACK_SIZE]))
	}

	xc.gdt = GDT_TEMPLATE
	base, limit := u64(uintptr(&xc.tss)), u64(size_of(Tss) + size_of(xc.iomap) - 1)
	xc.gdt[5] = transmute(u64)Tss_Descriptor{limit_lo = limit, base_lo = base, type = 0x89, limit_hi = limit >> 16, base_hi = base >> 24}
	xc.gdt[6] = base >> 32
	gp := Descriptor_Ptr{limit = size_of(xc.gdt) - 1, base = u64(uintptr(&xc.gdt))}
	vx_load_gdt(&gp, SEL_TSS)

	if index == 0 {
		build_idt()
	}
	ip := Descriptor_Ptr{limit = size_of(idt) - 1, base = u64(uintptr(&idt))}
	vx_load_idt(&ip)
	percpu_ready = true
}

// --- Page tables ---

@(private="file")
X86_PRESENT :: Pte(1) << 0
@(private="file")
X86_WRITE :: Pte(1) << 1
@(private="file")
X86_USER :: Pte(1) << 2
@(private="file")
X86_PWT :: Pte(1) << 3
@(private="file")
X86_PCD :: Pte(1) << 4
@(private="file")
X86_LARGE :: Pte(1) << 7 // a 2 MiB or 1 GiB leaf
@(private="file")
X86_NX :: Pte(1) << 63
@(private="file")
X86_ADDR :: Pte(0x000f_ffff_ffff_f000)

arch_pte_valid :: proc "contextless" (e: Pte) -> bool {
	return e & X86_PRESENT != 0
}

arch_pte_is_table :: proc "contextless" (e: Pte, level: int) -> bool {
	return level < 3 && e & X86_LARGE == 0
}

arch_pte_addr :: proc "contextless" (e: Pte) -> Paddr {
	return Paddr(e & X86_ADDR)
}

// Tables allow everything; the leaf decides.
arch_pte_table :: proc "contextless" (pa: Paddr) -> Pte {
	return Pte(pa) | X86_USER | X86_WRITE | X86_PRESENT
}

arch_pte_leaf :: proc "contextless" (pa: Paddr, flags: Map_Flags, level: int) -> Pte {
	e := Pte(pa) | X86_PRESENT
	if .Write in flags {
		e |= X86_WRITE
	}
	if .User in flags {
		e |= X86_USER
	}
	if .Exec not_in flags {
		e |= X86_NX
	}
	if .Device in flags {
		e |= X86_PCD | X86_PWT // uncached under the default PAT
	}
	if level < 3 {
		e |= X86_LARGE
	}
	return e
}

arch_pte_publish :: proc "contextless" () {
	intrinsics.atomic_signal_fence(.Seq_Cst) // x86 table walks see stores in order
}

// Every task's top table will share the kernel's upper half by copying its
// 256 upper entries, so they must exist before the first task: fill them now
// with empty tables (1 MiB in all), and later kernel mappings land in tables
// every task already shares. COM1 is an I/O port: nothing else to map.
arch_kernel_mappings :: proc "contextless" (root: Paddr) {
	top := table_at(root)
	for i in 256 ..< 512 {
		if arch_pte_valid(top[i]) {
			continue
		}
		page := phys_alloc_zeroed(0)
		if page == 0 {
			kpanic("no memory for page tables")
		}
		top[i] = arch_pte_table(page)
	}
}

// Every task's top table shares the kernel's upper half by copying its 256
// upper entries (arch_kernel_mappings made them all).
arch_new_user_root :: proc "contextless" () -> Paddr {
	root := phys_alloc_zeroed(0)
	if root != 0 {
		copy(table_at(root)[256:], table_at(kernel_root)[256:])
	}
	return root
}

// Loads a task's tables, or with root 0 (no task, as for the idle thread)
// the kernel's.
arch_switch_user_root :: proc "contextless" (root: Paddr) {
	vx_write_cr3(u64(root != 0 ? root : kernel_root))
}

arch_user_top_slots :: proc "contextless" () -> int {
	return 256
}

arch_pte_user_ok :: proc "contextless" (e: Pte, write: bool) -> bool {
	return e & X86_PRESENT != 0 && e & X86_USER != 0 && (!write || e & X86_WRITE != 0)
}

arch_switch_tables :: proc "contextless" (root: Paddr) {
	ap_park_tables[0] = u64(root) // for ap_start and ap_park
	vx_switch_tables(u64(root))
}

// Drops this CPU's user translations (loading CR3 again keeps only global,
// kernel, entries) if a shootdown has asked it to since it last did.
@(private="file")
tlb_answer :: proc "contextless" (c: ^Cpu) {
	asked := intrinsics.atomic_load_explicit(&c.tlb_asked, .Acquire)
	if intrinsics.atomic_load_explicit(&c.tlb_done, .Relaxed) >= asked {
		return
	}
	vx_write_cr3(vx_read_cr3())
	intrinsics.atomic_store_explicit(&c.tlb_done, asked, .Release)
}

@(private="file")
shootdown_gen: u64

// Every CPU drops its translations for [va, va + length) in the address
// space with this root; once it returns, the pages may be freed. x86 has no
// broadcast invalidation: every other CPU with the tables loaded gets an
// interrupt, and this one waits until each has flushed, or loaded other
// tables since (a load flushes too). While waiting it answers any shootdown
// asked of it, so two at once cannot wait for each other. The caller holds
// no lock that a CPU it waits for might be spinning on.
arch_tlb_shootdown :: proc "contextless" (root: Paddr, va: Uva, length: u64) {
	me := this_cpu()
	if intrinsics.atomic_load_explicit(&me.user_root, .Relaxed) == root {
		if length / PAGE_SIZE > 32 {
			vx_write_cr3(vx_read_cr3())
		} else {
			for p := u64(va); p < u64(va) + length; p += PAGE_SIZE {
				vx_invlpg(p)
			}
		}
	}
	gen := intrinsics.atomic_add_explicit(&shootdown_gen, 1, .Relaxed) + 1
	loads: [MAX_CPUS]u64
	waiting: bit_set[0 ..< MAX_CPUS; u64]
	for &c, i in cpus[:min(cpu_total, MAX_CPUS)] {
		if &c == me || intrinsics.atomic_load_explicit(&c.user_root, .Acquire) != root {
			continue
		}
		loads[i] = intrinsics.atomic_load_explicit(&c.root_loads, .Acquire)
		old := intrinsics.atomic_load_explicit(&c.tlb_asked, .Relaxed)
		for old < gen {
			_, swapped := intrinsics.atomic_compare_exchange_weak_explicit(&c.tlb_asked, old, gen, .Release, .Relaxed)
			if swapped {
				break
			}
			old = intrinsics.atomic_load_explicit(&c.tlb_asked, .Relaxed)
		}
		waiting += {i}
		vx_wrmsr(X2APIC_ICR, c.arch_id << 32 | VECTOR_SHOOTDOWN)
	}
	for i in waiting {
		c := &cpus[i]
		for intrinsics.atomic_load_explicit(&c.tlb_done, .Acquire) < gen && intrinsics.atomic_load_explicit(&c.root_loads, .Acquire) == loads[i] {
			tlb_answer(me)
			vx_pause()
		}
	}
}

// --- The clock and the timer ---
//
// The timer uses TSC-deadline mode where the CPU has it. Otherwise (QEMU
// without KVM, for one) it uses the APIC's own one-shot countdown, calibrated
// against the TSC at boot; time.odin re-arms if a countdown ends early.

@(private="file")
MSR_APIC_BASE :: 0x1b
@(private="file")
MSR_TSC_DEADLINE :: 0x6e0
@(private="file")
X2APIC_EOI :: 0x80b
@(private="file")
X2APIC_SPURIOUS :: 0x80f
@(private="file")
X2APIC_LVT_TIMER :: 0x832
@(private="file")
X2APIC_INITIAL :: 0x838
@(private="file")
X2APIC_CURRENT :: 0x839
@(private="file")
X2APIC_DIVIDE :: 0x83e

@(private="file")
VECTOR_TIMER :: 0x20
@(private="file")
VECTOR_SPURIOUS :: 0xff

@(private="file")
tsc_deadline: bool
@(private="file")
apic_per_tsc: u64 // APIC timer ticks per TSC tick, << 32

arch_counter :: proc "contextless" () -> u64 {
	return vx_rdtsc()
}

arch_counter_hz :: proc "contextless" () -> u64 {
	return boot.tsc_hz
}

// Per CPU: this CPU's local APIC and its timer. The boot CPU also masks the
// legacy PICs and, without TSC-deadline mode, measures the APIC timer once.
arch_timer_init :: proc "contextless" () {
	features := cpuid(1)
	if features[2] & CPUID1_ECX_X2APIC == 0 {
		kpanic("the CPU has no x2APIC")
	}
	tsc_deadline = features[2] & CPUID1_ECX_TSC_DEADLINE != 0

	if arch_cpu_index() == 0 {
		vx_outb(0x21, 0xff) // mask both legacy PICs: interrupts come through the APICs only
		vx_outb(0xa1, 0xff)
	}
	vx_wrmsr(MSR_APIC_BASE, vx_rdmsr(MSR_APIC_BASE) | 1 << 11 | 1 << 10) // enabled, x2APIC mode
	vx_wrmsr(X2APIC_SPURIOUS, 0x100 | VECTOR_SPURIOUS) // software-enabled

	if tsc_deadline {
		vx_wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER | 2 << 17) // TSC-deadline mode
		vx_mfence() // the mode change lands before the first deadline
		return
	}
	vx_wrmsr(X2APIC_DIVIDE, 0xb) // divide by 1
	if apic_per_tsc != 0 { // measured on the boot CPU: every APIC timer runs at the same rate
		vx_wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER)
		return
	}
	// One-shot mode, masked while it is measured against the TSC for 1 ms.
	vx_wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER | 1 << 16)
	t0, wait := arch_counter(), clock.hz / 1000
	vx_wrmsr(X2APIC_INITIAL, 0xffffffff)
	for arch_counter() - t0 < wait {}
	ticks, elapsed := 0xffffffff - vx_rdmsr(X2APIC_CURRENT), arch_counter() - t0
	vx_wrmsr(X2APIC_INITIAL, 0)
	apic_per_tsc = (ticks << 32) / elapsed
	vx_wrmsr(X2APIC_LVT_TIMER, VECTOR_TIMER) // one-shot, unmasked
}

arch_timer_arm :: proc "contextless" (count: u64) {
	if tsc_deadline {
		vx_wrmsr(MSR_TSC_DEADLINE, count != 0 ? count : 1) // 0 would disarm it
		return
	}
	now := arch_counter()
	ticks := u64(1)
	if count > now {
		ticks = u64((u128(count - now) * u128(apic_per_tsc)) >> 32)
	}
	ticks = clamp(ticks, 1, 0xffffffff)
	vx_wrmsr(X2APIC_INITIAL, ticks)
}

arch_wait :: proc "contextless" () {
	vx_wait()
}

// --- Traps ---

Trap_Frame :: struct { // the layout entry.S builds
	rax, rbx, rcx, rdx, rsi, rdi, rbp, r8, r9, r10, r11, r12, r13, r14, r15: u64,
	vector, error:                                                          u64,
	rip, cs, rflags, rsp, ss:                                               u64, // pushed by the CPU
}

@(private="file")
EXCEPTION_NAMES := [22]string {
	"divide error",
	"debug",
	"NMI",
	"breakpoint",
	"overflow",
	"bound range",
	"invalid opcode",
	"device not available",
	"double fault",
	"coprocessor segment overrun",
	"invalid TSS",
	"segment not present",
	"stack fault",
	"general protection fault",
	"page fault",
	"reserved",
	"x87 floating-point error",
	"alignment check",
	"machine check",
	"SIMD floating-point error",
	"virtualization exception",
	"control protection fault",
}

// A page fault's error code.
@(private="file")
Pf_Cause :: enum u64 {
	Present, // a protection violation, not a missing page
	Write,
	User,
	Reserved, // a reserved bit was set in an entry
	Fetch,
}

@(private="file")
Pf_Error :: bit_set[Pf_Cause; u64]

// Describes an exception: "page fault at 0x... (read, not present, user)", say.
@(private="file")
kput_exception :: proc "contextless" (f: ^Trap_Frame) {
	switch {
	case f.vector == 14:
		pf := transmute(Pf_Error)f.error
		kput("page fault at ")
		kput_hex(vx_read_cr2())
		access := " (read, "
		if .Write in pf {
			access = " (write, "
		}
		if .Fetch in pf {
			access = " (execute, "
		}
		kput(access)
		kput(.Present in pf ? "protection" : "not present")
		kput(.User in pf ? ", user)" : ", kernel)")
	case f.vector == 6 && f.cs & 3 == 0 && (cast([^]u8)uintptr(f.rip))[0] == 0x0f && (cast([^]u8)uintptr(f.rip))[1] == 0x0b:
		// ud2: Odin's runtime trap. A bounds check or an assertion failed;
		// its message went to a stderr that freestanding builds do not have.
		kput("Odin runtime trap (a bounds check or assertion failed)")
	case f.vector < len(EXCEPTION_NAMES):
		kput(EXCEPTION_NAMES[f.vector])
		kput(", error code ")
		kput_hex(f.error)
	case:
		kput("unexpected interrupt ")
		kput_u64(f.vector)
	}
}

@(private="file")
VECTOR_RESCHED :: 0x21 // another CPU made a thread ready
@(private="file")
VECTOR_SHOOTDOWN :: 0x22 // another CPU unmapped user pages: flush (arch_tlb_shootdown)
@(private="file")
VECTOR_SYSCALL :: 0x100 // entry.S
@(private="file")
X2APIC_ICR :: 0x830

// A fixed interrupt to one CPU by its x2APIC ID: one 64-bit write to the ICR.
arch_send_resched :: proc "contextless" (c: ^Cpu) {
	vx_wrmsr(X2APIC_ICR, c.arch_id << 32 | VECTOR_RESCHED)
}

// Where traps from user mode land: the TSS's for interrupts and exceptions,
// the per-CPU block's for SYSCALL.
arch_set_kernel_stack :: proc "contextless" (top: u64) {
	xc := &x86_cpus[arch_cpu_index()]
	xc.tss.rsp[0] = top
	xc.local.kernel_rsp = top
}

// What vx_context_switch (entry.S) pops, lowest address first: six
// callee-saved registers, then its return address.
@(private="file")
Switch_Frame :: struct {
	r15, r14, r13, r12, rbx, rbp: u64,
	ret:                          u64,
}

#assert(size_of(Switch_Frame) == 7 * 8)

// A new thread's stack, as the context switch will pop it: r12 carrying the
// thread, and a return into thread_trampoline. It starts a page below the
// top, clear of the trap frame and XSAVE area vx_enter_user builds there.
arch_thread_initial_sp :: proc "contextless" (th: ^Thread) -> u64 {
	f := cast(^Switch_Frame)uintptr(thread_kstack_top(th) - PAGE_SIZE - size_of(Switch_Frame))
	f^ = {
		r12 = u64(uintptr(th)),
		ret = u64(uintptr(rawptr(thread_trampoline))),
	}
	return u64(uintptr(f))
}

arch_context_switch :: proc "contextless" (save_sp: ^u64, load_sp: u64) {
	vx_context_switch(save_sp, load_sp)
}

// As if called (thread_start): a zero return address below sp. If it cannot
// be written, the thread faults on its first use of its stack.
arch_enter_user :: proc "contextless" (entry, sp: Uva, arg, arg2, kstack_top: u64) -> ! {
	zero: u64
	_ = copy_out(sp - 8, &zero)
	vx_enter_user(u64(entry), u64(sp - 8), arg, arg2, kstack_top)
}

// --- User-mode registers (exception.odin) ---

// The frame at the top of a thread's kernel stack: its user-mode registers,
// once it has entered the kernel from user mode.
arch_user_frame :: proc "contextless" (th: ^Thread) -> ^Trap_Frame {
	return cast(^Trap_Frame)uintptr(thread_kstack_top(th) - size_of(Trap_Frame))
}

arch_frame_regs :: proc "contextless" (f: ^Trap_Frame) -> vx.Regs {
	return {
		rax = f.rax, rbx = f.rbx, rcx = f.rcx, rdx = f.rdx, rsi = f.rsi, rdi = f.rdi, rbp = f.rbp, rsp = f.rsp,
		r8 = f.r8, r9 = f.r9, r10 = f.r10, r11 = f.r11, r12 = f.r12, r13 = f.r13, r14 = f.r14, r15 = f.r15,
		rip = f.rip, rflags = f.rflags,
	}
}

// The flags user code may set: carry, parity, adjust, zero, sign, direction,
// overflow, alignment check and ID. Interrupts stay on; trap (single step)
// is the debugger's (arch_frame_step).
@(private="file")
USER_FLAGS :: u64(0x1 | 0x4 | 0x10 | 0x40 | 0x80 | 0x400 | 0x800 | 0x40000 | 0x200000)
@(private="file")
RFLAGS_IF :: u64(0x200)
@(private="file")
RFLAGS_TF :: u64(0x100) // trap after the next instruction
@(private="file")
RFLAGS_DF :: u64(0x400)

// cs and ss stay user mode's: only what user mode may hold is taken.
@(require_results)
arch_frame_set_regs :: proc "contextless" (f: ^Trap_Frame, r: ^vx.Regs) -> vx.Status {
	if r.rip >= u64(USER_TOP) || r.rsp > u64(USER_TOP) {
		return .Err_Invalid // iretq would fault on them, in the kernel
	}
	f.rax, f.rbx, f.rcx, f.rdx, f.rsi, f.rdi, f.rbp, f.rsp = r.rax, r.rbx, r.rcx, r.rdx, r.rsi, r.rdi, r.rbp, r.rsp
	f.r8, f.r9, f.r10, f.r11, f.r12, f.r13, f.r14, f.r15 = r.r8, r.r9, r.r10, r.r11, r.r12, r.r13, r.r14, r.r15
	f.rip = r.rip
	f.rflags = r.rflags & USER_FLAGS | RFLAGS_IF | 0x2 // bit 1 is always set
	return .Ok
}

regs_sp :: proc "contextless" (r: ^vx.Regs) -> Uva {
	return Uva(r.rsp)
}

regs_pc :: proc "contextless" (r: ^vx.Regs) -> u64 {
	return r.rip
}

// The register a syscall's result goes back in.
regs_result :: proc "contextless" (r: ^vx.Regs) -> u64 {
	return r.rax
}

arch_frame_step :: proc "contextless" (f: ^Trap_Frame, on: bool) {
	f.rflags = on ? f.rflags | RFLAGS_TF : f.rflags &~ RFLAGS_TF
}

arch_sync_icache :: proc "contextless" (p: []u8) {} // x86 keeps it coherent itself

// To pc(arg) as if called: a zero return address below arg, which is
// 16-aligned.
arch_frame_divert :: proc "contextless" (f: ^Trap_Frame, pc, arg: Uva) -> bool {
	zero: u64
	if copy_out(arg - 8, &zero) != .Ok {
		return false
	}
	f.rip = u64(pc)
	f.rsp = u64(arg - 8)
	f.rdi = u64(arg)
	f.rflags &~= RFLAGS_DF // the ABI starts functions with the direction flag clear
	return true
}

// A user-mode fault as an exception: its kind, code and address.
@(private="file")
x86_exception_kind :: proc "contextless" (f: ^Trap_Frame) -> (kind: vx.Exception_Kind, code: u32, address: u64) {
	code = u32(f.error)
	switch f.vector {
	case 0:
		return .Arithmetic, code, 0 // divide error
	case 1:
		return .Step, code, 0 // the trap flag (exception_raise clears it, or sets it again)
	case 3:
		return .Breakpoint, code, 0
	case 6:
		return .Illegal, code, 0
	case 7:
		return .Fp_Disabled, code, 0
	case 14:
		pf := transmute(Pf_Error)f.error
		code = 0 // read
		if .Write in pf {
			code = 1
		}
		if .Fetch in pf {
			code = 2
		}
		return .Page_Fault, code, vx_read_cr2()
	case 16, 19:
		return .Arithmetic, code, 0 // x87 and SIMD FP exceptions
	case 17:
		return .Alignment, code, 0
	}
	return .General, u32(f.vector), 0
}

@(export, link_name="x86_trap")
x86_trap :: proc "c" (f: ^Trap_Frame) {
	from_user := f.cs & 3 != 0
	switch f.vector {
	case VECTOR_SYSCALL:
		f.rax = u64(syscall_dispatch(f.rax, {f.rdi, f.rsi, f.rdx, f.r10, f.r8, f.r9}))
	case VECTOR_TIMER:
		vx_wrmsr(X2APIC_EOI, 0)
		timer_interrupt()
	case VECTOR_RESCHED:
		vx_wrmsr(X2APIC_EOI, 0)
		this_cpu().resched = true
	case VECTOR_SHOOTDOWN:
		vx_wrmsr(X2APIC_EOI, 0)
		tlb_answer(this_cpu())
	case VECTOR_SPURIOUS:
		return
	case VECTOR_MSI_FIRST ..= VECTOR_MSI_LAST:
		irq_fire(MSI_LINE_BASE + u32(f.vector))
		vx_wrmsr(X2APIC_EOI, 0)
	case VECTOR_IRQ_BASE ..< VECTOR_IRQ_BASE + MAX_GSI:
		irq_fire(u32(f.vector - VECTOR_IRQ_BASE)) // a level line is masked before the EOI
		vx_wrmsr(X2APIC_EOI, 0)
	case:
		if f.vector == 14 && !from_user && vx_read_cr2() < u64(USER_TOP) && uaccess_fixup(f.rip) != 0 {
			f.rip = uaccess_fixup(f.rip) // a user page gone under a copy: it reports the failure
			return
		}
		if from_user {
			kind, code, address := x86_exception_kind(f)
			if !exception_raise(f, kind, code, address) { // nobody took it
				task_fault_start()
				kput_exception(f)
				kput(" at rip ")
				kput_hex(f.rip)
				kput("\n")
				task_fault_exit(kind, code, address, f.rip)
			}
			break
		}
		panic_start()
		if (f.vector == 8 || f.vector == 14) && kstack_in_guard(vx_read_cr2()) {
			kput("kernel stack overflow: ") // a double fault: the page fault had nowhere to push its frame
		}
		kput_exception(f)
		kput(" at rip ")
		kput_hex(f.rip)
		panic_end(f.rip, f.rbp)
	}
	if from_user {
		user_return()
	}
}

// --- ADR-0004's test (main.odin) ---

@(private="file")
avx_enabled :: proc "contextless" () -> bool {
	return vx_read_xcr0() & 4 != 0
}

// Vector registers live from `input` across interrupts until *fired reaches
// target, then stored to `output`. Returns how many bytes of them that is:
// ymm0-ymm15 with AVX, xmm0-xmm15 without.
arch_vreg_irq_test :: proc "contextless" (input, output: ^[512]u8, fired: ^u64, target: u64) -> int {
	if avx_enabled() {
		vx_vreg_irq_test_avx(input, output, fired, target)
		return 512
	}
	vx_vreg_irq_test_sse(input, output, fired, target)
	return 256
}

arch_clobber_vregs :: proc "contextless" () {
	if avx_enabled() {
		vx_clobber_vregs_avx()
	} else {
		vx_clobber_vregs_sse()
	}
}

// --- Devices: I/O ports, the IOAPICs and the MADT (device.odin) ---

arch_has_io_ports :: proc "contextless" () -> bool {
	return true
}

arch_console_device :: proc "contextless" (io: bool, base, size: u64) -> bool {
	return io && base < COM1 + 8 && COM1 < base + size
}

@(private="file")
iomap_set :: proc "contextless" (m: []u8, base, count: u32, allow: bool) {
	for p in base ..< base + count {
		if allow {
			m[p / 8] &~= u8(1 << (p % 8))
		} else {
			m[p / 8] |= u8(1 << (p % 8))
		}
	}
}

// This CPU's I/O port permissions become t's; t may be nil.
arch_io_switch :: proc "contextless" (t: ^Task) {
	xc := &x86_cpus[arch_cpu_index()]
	for r in xc.open {
		iomap_set(xc.iomap[:], u32(r.base), r.count, false)
	}
	xc.open = {}
	if t == nil {
		return
	}
	for r in t.io {
		iomap_set(xc.iomap[:], u32(r.base), r.count, true)
	}
	xc.open = t.io
}

// An IOAPIC's two registers: a register is selected, then read or written
// through the window.
@(private="file")
Ioapic_Regs :: struct {
	sel: u32,
	_:   [3]u32,
	win: u32,
}

#assert(offset_of(Ioapic_Regs, win) == 0x10)

@(private="file")
Ioapic :: struct {
	regs:     ^Ioapic_Regs,
	gsi_base: u32,
	count:    u32,
}

@(private="file")
ioapics: [8]Ioapic
@(private="file")
ioapic_count: int
@(private="file")
Isa_Override :: struct {
	present: bool,
	gsi:     u32,
	flags:   u16, // MPS INTI flags: polarity in bits 0-1, trigger mode in bits 2-3
}
@(private="file")
isa_overrides: [16]Isa_Override
@(private="file")
ioapic_lock: Spinlock

@(private="file")
VECTOR_IRQ_BASE :: 0x30 // device interrupts: VECTOR_IRQ_BASE + GSI
@(private="file")
MAX_GSI :: 0x50 // up to vector 0x7f
// MSIs: line MSI_LINE_BASE + vector.
@(private="file")
VECTOR_MSI_FIRST :: 0x80
@(private="file")
VECTOR_MSI_LAST :: 0xef

@(private="file")
ioapic_read :: proc "contextless" (a: ^Ioapic, reg: u32) -> u32 {
	intrinsics.volatile_store(&a.regs.sel, reg)
	return intrinsics.volatile_load(&a.regs.win)
}

@(private="file")
ioapic_write :: proc "contextless" (a: ^Ioapic, reg, v: u32) {
	intrinsics.volatile_store(&a.regs.sel, reg)
	intrinsics.volatile_store(&a.regs.win, v)
}

// Finds the IOAPICs and the ISA overrides in the MADT, maps the IOAPICs and
// masks every line. Without a MADT, irq_create has no lines to give.
arch_devices_init :: proc "contextless" () {
	madt := acpi_table("APIC")
	if madt == nil {
		return
	}
	for off := 44; off + 2 <= len(madt) && madt[off + 1] >= 2 && off + int(madt[off + 1]) <= len(madt); off += int(madt[off + 1]) {
		e := madt[off:][:madt[off + 1]]
		if e[0] == 1 && e[1] >= 12 && ioapic_count < len(ioapics) {
			pa := Paddr(read32(e[4:]))
			if !map_range(kernel_root, boot.hhdm + u64(pa), pa, PAGE_SIZE, {.Write, .Device}) {
				kpanic("cannot map an IOAPIC")
			}
			a := &ioapics[ioapic_count]
			ioapic_count += 1
			a.regs = cast(^Ioapic_Regs)phys_to_virt(pa)
			a.gsi_base = read32(e[8:])
			a.count = (ioapic_read(a, 1) >> 16 & 0xff) + 1
			for i in 0 ..< a.count {
				ioapic_write(a, 0x10 + 2 * i, 1 << 16) // masked
			}
		} else if e[0] == 2 && e[1] >= 10 && e[2] == 0 && e[3] < 16 {
			o := &isa_overrides[e[3]]
			o.present = true
			o.gsi = read32(e[4:])
			o.flags = u16(e[8]) | u16(e[9]) << 8
		}
	}
}

@(private="file")
ioapic_for :: proc "contextless" (gsi: u32) -> ^Ioapic {
	for &a in ioapics[:ioapic_count] {
		if gsi >= a.gsi_base && gsi - a.gsi_base < a.count {
			return &a
		}
	}
	return nil
}

// An ISA IRQ (below 16) becomes its GSI through the MADT's overrides; any
// other number is a GSI already.
@(require_results)
arch_irq_canonical :: proc "contextless" (line: u32) -> (u32, vx.Status) {
	gsi := line < 16 && isa_overrides[line].present ? isa_overrides[line].gsi : line
	if gsi >= MAX_GSI || ioapic_for(gsi) == nil {
		return 0, .Err_Range
	}
	return gsi, .Ok
}

// ISA lines are edge-triggered and active high unless an override says
// otherwise; the rest (PCI) are level-triggered and active low.
@(require_results)
arch_irq_route :: proc "contextless" (line: u32) -> (level: bool, st: vx.Status) {
	isa := false
	flags: u16
	for i in u32(0) ..< 16 { // the ISA IRQ that lands on this GSI, if any (line: a GSI)
		to := isa_overrides[i].present ? isa_overrides[i].gsi : i
		if to != line {
			continue
		}
		isa = true
		flags = isa_overrides[i].present ? isa_overrides[i].flags : 0
	}
	active_low := !isa
	level = !isa
	switch flags & 3 { // the override's polarity and trigger mode, where it gives them
	case 1:
		active_low = false
	case 3:
		active_low = true
	}
	switch flags >> 2 & 3 {
	case 1:
		level = false
	case 3:
		level = true
	}
	a := ioapic_for(line)
	pin := line - a.gsi_base
	spin_lock(&ioapic_lock)
	ioapic_write(a, 0x10 + 2 * pin + 1, u32(cpus[0].arch_id << 24)) // to the boot CPU
	ioapic_write(a, 0x10 + 2 * pin, (VECTOR_IRQ_BASE + line) | (active_low ? 1 << 13 : 0) | (level ? 1 << 15 : 0)) // unmasked
	spin_unlock(&ioapic_lock)
	return level, .Ok
}

// An MSI is a write to the boot CPU's local APIC (x2APIC IDs above 255 need
// interrupt remapping, which comes with the IOMMU) with a free vector. The
// PCI function does not matter: any vector can come from any device.
arch_msi_create :: proc "contextless" (source: u32) -> (line: u32, msi: vx.Msi, st: vx.Status) {
	for v in u32(VECTOR_MSI_FIRST) ..= VECTOR_MSI_LAST {
		if irq_lines[MSI_LINE_BASE + v] != nil {
			continue
		}
		if cpus[0].arch_id > 0xff {
			return 0, {}, .Err_Unsupported
		}
		return MSI_LINE_BASE + v, {address = 0xfee0_0000 | cpus[0].arch_id << 12, data = v}, .Ok // fixed, edge
	}
	return 0, {}, .Err_No_Memory
}

arch_msi_destroy :: proc "contextless" (line: u32) {} // nothing routes it but the device

arch_irq_mask :: proc "contextless" (line: u32, masked: bool) {
	if line >= MSI_LINE_BASE {
		return // an MSI: edge-triggered, and the device masks it if anything does
	}
	a := ioapic_for(line)
	if a == nil {
		return
	}
	reg := 0x10 + 2 * (line - a.gsi_base)
	spin_lock(&ioapic_lock)
	v := ioapic_read(a, reg)
	ioapic_write(a, reg, masked ? v | 1 << 16 : v &~ (1 << 16))
	spin_unlock(&ioapic_lock)
}
