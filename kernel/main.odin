package kernel

import "base:intrinsics"

// The architecture-independent start of the kernel. Kernel code is
// contextless throughout (ADR-0003): no implicit context, so no hidden
// allocator, and nothing to set up on trap paths.

VERSION :: "0.1.0"

when ODIN_ARCH == .amd64 {
	ARCH_NAME :: "x86_64"
} else when ODIN_ARCH == .arm64 {
	ARCH_NAME :: "aarch64"
} else {
	#panic("VectraOS runs on x86_64 and aarch64")
}

@(export, link_name="kernel_main")
kernel_main :: proc "c" () -> ! {
	entry := arch_counter()
	ok := boot_read()
	arch_console_init()
	if !ok {
		kpanic("the bootloader does not provide Limine base revision 6")
	}
	clock_init(arch_counter_hz(), entry)
	arch_cpu_init(0)
	phys_init()
	paging_init()
	kstack_init()
	// CPU 0 leaves the boot stack for a kernel stack like every other, which
	// it keeps as its idle stack.
	stack := kstack_alloc()
	if stack == 0 {
		kpanic("no memory for CPU 0's stack")
	}
	cpus[0].idle_stack = stack
	arch_run_on_stack(stack + KSTACK_SIZE, kernel_main_on_kstack)
}

@(export, link_name="kernel_main_on_kstack")
kernel_main_on_kstack :: proc "c" () -> ! {
	arch_timer_init()
	smp_init()

	online := intrinsics.atomic_load(&cpus_online)
	kput("vx: kernel " + VERSION + " " + ARCH_NAME + ", ")
	kput_u64(phys.free_pages >> 8)
	kput(" MiB free, ")
	kput_u64(u64(online))
	kput(online == 1 ? " cpu\n" : " cpus\n")

	reclaim_boot_memory() // every CPU is on the kernel's tables and stacks, and the responses are read
	selftests() // after the reclaim, so the allocator tests cover that memory too
	idle_loop()
}

// Recurses until the kernel stack's guard page stops it: a frame a level,
// which neither a tail call nor the optimizer can take away.
@(private="file")
selftest_recurse :: proc "contextless" (depth: u64) -> u64 {
	frame: [512]u8
	intrinsics.volatile_store(&frame[0], u8(depth))
	if depth > 1 << 30 {
		return depth // never: the guard page is far nearer
	}
	return selftest_recurse(depth + 1) + u64(intrinsics.volatile_load(&frame[0]))
}

// Allocates a block of every order, checks alignment and the free count,
// frees them all and checks that the count, and the largest block, come back.
@(private="file")
selftest_phys :: proc "contextless" () {
	before := phys.free_pages
	taken: u64
	pa: [PHYS_MAX_ORDER + 1]u64
	for o in uint(0) ..= PHYS_MAX_ORDER {
		pa[o] = phys_alloc(o)
		if pa[o] == 0 || pa[o] & ((4096 << o) - 1) != 0 {
			kpanic("selftest phys: bad block")
		}
		taken += 1 << o
	}
	if phys.free_pages != before - taken {
		kpanic("selftest phys: free count after allocating")
	}
	for o in uint(0) ..= PHYS_MAX_ORDER {
		phys_free(pa[o], o)
	}
	if phys.free_pages != before {
		kpanic("selftest phys: free count after freeing")
	}
	big := phys_alloc(PHYS_MAX_ORDER)
	if big == 0 {
		kpanic("selftest phys: no largest block after freeing")
	}
	phys_free(big, PHYS_MAX_ORDER)
	kput("vx: selftest phys ok\n")
}

// A duration in nanoseconds as milliseconds with three decimals.
@(private="file")
kput_millis :: proc "contextless" (ns: u64) {
	us := ns / 1000
	kput_u64(us / 1000)
	kput(".")
	kput_u64(us % 1000 / 100)
	kput_u64(us % 100 / 10)
	kput_u64(us % 10)
}

// Arms the timer 10 ms ahead and sleeps until it fires. The wake-up must
// never come early, and must come within 20 ms of the deadline even under
// emulation.
@(private="file")
selftest_timer :: proc "contextless" () {
	start := clock_now()
	deadline := start + 10_000_000
	fired := intrinsics.atomic_load(&cpu_timer[0].fired)
	timer_arm(deadline)
	for intrinsics.atomic_load(&cpu_timer[0].fired) == fired {
		arch_wait()
	}
	woke := clock_now()
	if woke < deadline {
		kpanic("selftest timer: woke before the deadline")
	}
	if woke - deadline > 20_000_000 {
		kpanic("selftest timer: woke more than 20 ms late")
	}
	kput("vx: selftest timer ok: requested 10.000 ms, woke after ")
	kput_millis(u64(woke - start))
	kput(" ms\n")
}

// Self-tests that tests/qemu scenarios ask for on the command line. The
// fault tests end in a panic, which the scenario checks.
@(private="file")
selftests :: proc "contextless" () {
	if cmdline_has("vx.selftest=smp") {
		selftest_smp()
	}
	if cmdline_has("vx.selftest=timer") {
		selftest_timer()
	}
	if cmdline_has("vx.selftest=phys") {
		selftest_phys()
	}
	if cmdline_has("vx.selftest=stack-overflow") {
		_ = selftest_recurse(0) // into the guard page
	}
	if cmdline_has("vx.selftest=fault") {
		// Nothing is mapped this far above the direct map's start.
		_ = intrinsics.volatile_load(cast(^u64)uintptr(boot.hhdm + 1 << 46))
	}
	if cmdline_has("vx.selftest=lower-half") {
		// The lower half is empty until there is a user address space.
		_ = intrinsics.volatile_load(cast(^u64)uintptr(8))
	}
	if cmdline_has("vx.selftest=write-text") {
		// Kernel code is read-only (W^X).
		intrinsics.volatile_store(cast(^u8)rawptr(kernel_main), 0)
	}
	if cmdline_has("vx.selftest=write-text-alias") {
		// And so is its other mapping, in the direct map.
		pa := u64(uintptr(rawptr(kernel_main))) - boot.kernel_virt + boot.kernel_phys
		intrinsics.volatile_store(cast(^u8)phys_to_virt(pa), 0)
	}
	if cmdline_has("vx.selftest=simd") {
		selftest_simd()
	}
}

// Vector registers work in the kernel and survive interrupts (ADR-0004).
// First Odin's own vector code, checked against scalar arithmetic. Then the
// real test: every vector register is filled with a pattern and kept live
// while eight timer interrupts arrive, each of which wipes them all; only the
// trap path's save and restore can bring the pattern back.
@(private="file")
selftest_simd :: proc "contextless" () {
	a := #simd[4]u32{1, 2, 3, 4}
	b := #simd[4]u32{10, 20, 30, 40}
	if transmute([4]u32)(a * b + a) != ([4]u32{11, 42, 93, 164}) {
		kpanic("selftest simd: vector lanes wrong")
	}

	IRQS :: 8
	input, output: [512]u8
	for i in 0 ..< len(input) {
		input[i] = u8(i * 7 + 3)
	}
	fired := intrinsics.atomic_load(&cpu_timer[0].fired)
	simd_test_irqs = IRQS
	timer_arm(clock_now() + 1_000_000)
	n := arch_vreg_irq_test(&input, &output, &cpu_timer[0].fired, fired + IRQS)
	for i in 0 ..< n {
		if input[i] != output[i] {
			kpanic("selftest simd: vector state lost across an interrupt")
		}
	}
	kput("vx: selftest simd ok: ")
	kput_u64(u64(n))
	kput(" bytes of vector state kept across ")
	kput_u64(IRQS)
	kput(" interrupts\n")
}
