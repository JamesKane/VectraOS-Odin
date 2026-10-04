package kernel

import "base:intrinsics"

// The CPUs, and bringing up the others.
//
// Limine parks every application processor (AP) and starts one when its
// goto_address is written. Each AP gets an idle stack from the kernel stack
// region, with its CPU index stored at the top; ap_start (entry.S) loads the
// kernel's tables, moves onto that stack, enables FP and SIMD and calls
// ap_main, which sets up the CPU's vectors and timer and enters its idle loop.

MAX_CPUS :: 64 // Limine's others stay parked

cpus: [MAX_CPUS]Cpu // sched.odin's
cpu_total: u32 // started, or being started
cpus_online: u32

foreign _ {
	ap_start :: proc "c" (info: ^Mp_Info) ---
	ap_park :: proc "c" (info: ^Mp_Info) ---
}

@(private="file")
smp_test_go: bool
@(private="file")
smp_test_done: u32

SMP_TEST_ROUNDS :: 4000

// Every CPU allocates and frees blocks of orders 0 to 3, stamping each one
// with its CPU and round and checking the stamp before freeing it: a block
// handed to two CPUs at once would show up as a wrong stamp.
@(private="file")
smp_stress :: proc "contextless" (index: u32) {
	Held :: struct {
		pa:    Paddr,
		tag:   u64,
		order: uint,
	}
	held: [8]Held
	for r in u32(0) ..< SMP_TEST_ROUNDS {
		h := &held[r % 8]
		if h.pa != 0 {
			first := cast(^u64)phys_to_virt(h.pa)
			last := cast(^u64)phys_to_virt(h.pa + Paddr(4096 << h.order) - 8)
			if intrinsics.volatile_load(first) != h.tag || intrinsics.volatile_load(last) != h.tag {
				kpanic("selftest smp: a block was handed out twice")
			}
			phys_free(h.pa, h.order)
		}
		order := uint(r % 4)
		h^ = {pa = phys_alloc(order), tag = u64(index) << 32 | u64(r), order = order}
		if h.pa == 0 {
			kpanic("selftest smp: out of memory")
		}
		intrinsics.volatile_store(cast(^u64)phys_to_virt(h.pa), h.tag)
		intrinsics.volatile_store(cast(^u64)phys_to_virt(h.pa + Paddr(4096 << order) - 8), h.tag)
	}
	for h in held {
		if h.pa != 0 {
			phys_free(h.pa, h.order)
		}
	}
}

@(export, link_name="ap_main")
ap_main :: proc "c" (index: u32) -> ! {
	arch_switch_tables(kernel_root)
	arch_cpu_init(index)
	arch_timer_init()
	sched_enter_cpu()
	intrinsics.atomic_add_explicit(&cpus_online, 1, .Release)
	if cmdline_has("vx.selftest=smp") {
		for !intrinsics.atomic_load_explicit(&smp_test_go, .Acquire) {
			arch_pause()
		}
		smp_stress(index)
		intrinsics.atomic_add_explicit(&smp_test_done, 1, .Release)
	}
	sched_idle_loop()
}

// Starts every AP and waits up to a second for all of them to come online.
smp_init :: proc "contextless" () {
	cpu_total = 1
	intrinsics.atomic_store(&cpus_online, 1)
	mp := intrinsics.volatile_load(&mp_request.response)
	if mp == nil {
		return
	}
	bsp_id := mp_bsp_id(mp)
	cpus[0].arch_id = bsp_id
	parked := 0
	for info in mp.cpus[:mp.cpu_count] {
		id := mp_info_id(info)
		if id == bsp_id {
			continue
		}
		if cpu_total == MAX_CPUS { // the rest halt for good, on the kernel's tables
			if parked == 0 {
				kput("vx: more CPUs than MAX_CPUS; the rest are halted\n")
			}
			parked += 1
			intrinsics.atomic_store_explicit(&info.goto_address, rawptr(ap_park), .Release)
			continue
		}
		index := cpu_total
		cpu_total += 1
		stack := kstack_alloc()
		if stack == 0 {
			kpanic("no memory for an idle stack")
		}
		cpus[index].index = index
		cpus[index].arch_id = id
		cpus[index].idle_stack = stack
		top := cast([^]u64)uintptr(stack + KSTACK_SIZE)
		(top[-1:])[0] = u64(index)
		info.extra_argument = u64(uintptr(rawptr(&(top[-2:])[0]))) // ap_start: sp = this, and its index just above
		intrinsics.atomic_store_explicit(&info.goto_address, rawptr(ap_start), .Release)
	}
	give_up := clock_now() + 1_000_000_000
	for intrinsics.atomic_load_explicit(&cpus_online, .Acquire) < cpu_total && clock_now() < give_up {
		arch_pause()
	}
	if intrinsics.atomic_load(&cpus_online) < cpu_total {
		kpanic("a CPU did not come online")
	}
}

// Runs the CPUs' allocator stress together (vx.selftest=smp), then checks
// that the free count is what it was.
selftest_smp :: proc "contextless" () {
	before := phys.free_pages
	intrinsics.atomic_store_explicit(&smp_test_go, true, .Release)
	smp_stress(0)
	for intrinsics.atomic_load_explicit(&smp_test_done, .Acquire) < cpu_total - 1 {
		arch_pause()
	}
	if phys.free_pages != before {
		kpanic("selftest smp: the free count does not balance")
	}
	kput("vx: selftest smp ok: ")
	kput_u64(u64(cpu_total))
	kput(" cpus, ")
	kput_u64(u64(cpu_total) * SMP_TEST_ROUNDS)
	kput(" allocations\n")
}
