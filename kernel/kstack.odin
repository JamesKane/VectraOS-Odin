package kernel

import "base:intrinsics"

// Kernel stacks, with a guard page below each.
//
// Every kernel stack (a thread's, a CPU's idle stack, and CPU 0's once it
// leaves the boot stack) is 16 KiB at the top of a 32 KiB slot in a region of
// its own, with the slot's lower half never mapped. An overflow faults instead
// of writing over the next object. On aarch64 the slot layout is also what
// lets the exception vectors notice an overflow before they push a frame: a
// valid stack pointer has bit 14 set, and one that has run into the guard has
// it clear (entry.S).
//
// A slot's pages stay mapped when its stack is freed, for the next stack to
// use: unmapping kernel pages would need every CPU to drop their cached
// translations. So the region's memory is the most stacks ever live at once.

KSTACK_BASE :: u64(0xffff_ff00_0000_0000) // top-level slot 510 on both architectures
KSTACK_SIZE :: u64(16 * 1024)
KSTACK_SLOT :: u64(32 * 1024)
KSTACK_SLOTS :: 8192 // 256 MiB of address space

#assert(KSTACK_SIZE == 1 << 14 && KSTACK_SLOT == 2 * KSTACK_SIZE)

@(private="file")
kstacks: struct {
	lock:   Spinlock,
	free:   [KSTACK_SLOTS / 64]u64, // bit i: slot i holds a stack nobody uses
	mapped: [KSTACK_SLOTS / 64]u64, // bit i: slot i's pages are mapped
	next:   u32, // slots below this have been used
}

@(private="file")
bit :: proc "contextless" (bits: []u64, i: u32) -> bool {
	return bits[i / 64] >> (i % 64) & 1 != 0
}

@(private="file")
set_bit :: proc "contextless" (bits: []u64, i: u32, on: bool) {
	if on {
		bits[i / 64] |= 1 << (i % 64)
	} else {
		bits[i / 64] &~= 1 << (i % 64)
	}
}

// Whether addr is in some slot's guard: below a stack, never mapped.
kstack_in_guard :: proc "contextless" (addr: u64) -> bool {
	return addr >= KSTACK_BASE && addr < KSTACK_BASE + KSTACK_SLOTS * KSTACK_SLOT && (addr - KSTACK_BASE) % KSTACK_SLOT < KSTACK_SLOT - KSTACK_SIZE
}

// A stack: the address of its lowest byte (its top is that plus KSTACK_SIZE),
// or 0 when there is no memory or no slot left.
@(require_results)
kstack_alloc :: proc "contextless" () -> u64 {
	spin_lock(&kstacks.lock)
	slot := u32(KSTACK_SLOTS)
	for w in 0 ..< len(kstacks.free) {
		if kstacks.free[w] != 0 {
			slot = u32(w * 64) + u32(intrinsics.count_trailing_zeros(kstacks.free[w]))
			break
		}
	}
	if slot == KSTACK_SLOTS && kstacks.next < KSTACK_SLOTS {
		slot = kstacks.next
		kstacks.next += 1
	}
	if slot == KSTACK_SLOTS {
		spin_unlock(&kstacks.lock)
		return 0
	}
	set_bit(kstacks.free[:], slot, false)
	base := KSTACK_BASE + u64(slot) * KSTACK_SLOT + (KSTACK_SLOT - KSTACK_SIZE)
	if !bit(kstacks.mapped[:], slot) {
		pa := phys_alloc_zeroed(2) // 16 KiB
		if pa == 0 || !map_range(kernel_root, base, pa, KSTACK_SIZE, {.Write}) {
			if pa != 0 {
				phys_free(pa, 2)
			}
			set_bit(kstacks.free[:], slot, true)
			spin_unlock(&kstacks.lock)
			return 0
		}
		set_bit(kstacks.mapped[:], slot, true)
	}
	spin_unlock(&kstacks.lock)
	return base
}

kstack_free :: proc "contextless" (base: u64) {
	slot := u32((base - KSTACK_BASE) / KSTACK_SLOT)
	spin_lock(&kstacks.lock)
	set_bit(kstacks.free[:], slot, true)
	spin_unlock(&kstacks.lock)
}

// Makes the region's top-level entry before any user address space copies
// the kernel half: a stack mapped later is then in every address space.
kstack_init :: proc "contextless" () {
	first := kstack_alloc()
	if first == 0 {
		kpanic("no memory for the first kernel stack")
	}
	kstack_free(first)
}
