package kernel

import "base:intrinsics"

// The physical page allocator: a buddy allocator over the memory map, in
// blocks of 2^order pages, order 0 (4 KiB) to PHYS_MAX_ORDER (4 MiB). One
// zone, one lock and no per-CPU caches yet.

PHYS_MAX_ORDER :: 10

// frame_state: the first frame of a free block has this bit, and its order
// in the low bits.
@(private="file")
FRAME_FREE_HEAD :: 0x80

// Lives in the free memory itself, through the direct map.
@(private="file")
Free_Block :: struct {
	next, prev: ^Free_Block,
}

phys: struct {
	lock:        Spinlock,
	lists:       [PHYS_MAX_ORDER + 1]^Free_Block,
	frame_state: []u8, // one byte per 4 KiB frame
	free_pages:  u64,
}

@(private="file")
list_push :: proc "contextless" (order: uint, pa: Paddr) {
	b := cast(^Free_Block)phys_to_virt(pa)
	b^ = {next = phys.lists[order]}
	if b.next != nil {
		b.next.prev = b
	}
	phys.lists[order] = b
}

@(private="file")
list_remove :: proc "contextless" (order: uint, pa: Paddr) {
	b := cast(^Free_Block)phys_to_virt(pa)
	if b.prev != nil {
		b.prev.next = b.next
	} else {
		phys.lists[order] = b.next
	}
	if b.next != nil {
		b.next.prev = b.prev
	}
}

phys_free :: proc "contextless" (pa: Paddr, order: uint) {
	spin_lock(&phys.lock)
	phys.free_pages += 1 << order
	frame := u64(pa) >> 12
	o := order
	for o < PHYS_MAX_ORDER {
		buddy := frame ~ (1 << o)
		if buddy + (1 << o) > u64(len(phys.frame_state)) || phys.frame_state[buddy] != u8(FRAME_FREE_HEAD | o) {
			break
		}
		list_remove(o, Paddr(buddy << 12))
		phys.frame_state[buddy] = 0
		frame &~= 1 << o
		o += 1
	}
	phys.frame_state[frame] = u8(FRAME_FREE_HEAD | o)
	list_push(o, Paddr(frame << 12))
	spin_unlock(&phys.lock)
}

// The physical address of 2^order free pages, or 0 if there are none.
@(require_results)
phys_alloc :: proc "contextless" (order: uint) -> Paddr {
	spin_guard(&phys.lock)
	k := order
	for k <= PHYS_MAX_ORDER && phys.lists[k] == nil {
		k += 1
	}
	if k > PHYS_MAX_ORDER {
		return 0
	}
	pa := virt_to_phys(phys.lists[k])
	list_remove(k, pa)
	phys.frame_state[pa >> 12] = 0
	for k > order { // return the upper halves
		k -= 1
		upper := pa + Paddr(PAGE_SIZE << k)
		phys.frame_state[upper >> 12] = u8(FRAME_FREE_HEAD | k)
		list_push(k, upper)
	}
	phys.free_pages -= 1 << order
	return pa
}

@(require_results)
phys_alloc_zeroed :: proc "contextless" (order: uint) -> Paddr {
	pa := phys_alloc(order)
	if pa != 0 {
		arch_page_zero(phys_to_virt(pa), PAGE_SIZE << order)
	}
	return pa
}

// The smallest order whose block holds `bytes`.
order_for :: proc "contextless" (bytes: u64) -> uint {
	order := uint(0)
	for (PAGE_SIZE << order) < bytes {
		order += 1
	}
	return order
}

// Frees [start, end) in the largest aligned blocks that fit. Frame 0 is never
// added: 0 is phys_alloc's "no memory", and Limine may report page 0 usable.
phys_add_range :: proc "contextless" (lo, end: Paddr) {
	start := lo == 0 ? PAGE_SIZE : lo
	for start < end {
		order := uint(PHYS_MAX_ORDER)
		for order > 0 && ((start >> 12) & ((1 << order) - 1) != 0 || start + Paddr(PAGE_SIZE << order) > end) {
			order -= 1
		}
		phys_free(start, order)
		start += Paddr(PAGE_SIZE << order)
	}
}

// Builds the allocator from the usable memory map entries, minus what the
// early allocator has handed out, and closes the early allocator. Memory
// Limine itself used (bootloader-reclaimable) is added only after SMP
// bring-up: the parked CPUs wait on structures inside it.
phys_init :: proc "contextless" () {
	mm := response(&memmap_request)
	top: u64
	for e in mm.entries[:mm.entry_count] {
		if (e.type == .Usable || e.type == .Bootloader_Reclaimable) && e.base + e.length > top {
			top = e.base + e.length
		}
	}
	frames := top >> 12
	state_pa := early_alloc((frames + PAGE_SIZE - 1) / PAGE_SIZE)
	if state_pa == 0 {
		kpanic("no memory for the page allocator")
	}
	phys.frame_state = (cast([^]u8)phys_to_virt(state_pa))[:frames]

	taken_lo, taken_hi := early_next, early_top
	early_limit = early_next // the early allocator is closed from here on
	for e in mm.entries[:mm.entry_count] {
		if e.type != .Usable {
			continue
		}
		lo, hi := Paddr(e.base), Paddr(e.base + e.length)
		if taken_lo >= lo && taken_hi <= hi {
			phys_add_range(lo, taken_lo)
			phys_add_range(taken_hi, hi)
		} else {
			phys_add_range(lo, hi)
		}
	}
}

// Hands the memory Limine used for itself to the allocator: its page tables,
// the CPUs' first stacks, and the responses. Only once every CPU runs on the
// kernel's own tables and stacks and nothing reads a response any more. The
// ranges are copied out first: the memory map lives in that memory.
reclaim_boot_memory :: proc "contextless" () {
	mm := response(&memmap_request)
	ranges: [64]Phys_Range
	n := 0
	for e in mm.entries[:mm.entry_count] {
		if e.type == .Bootloader_Reclaimable && n < len(ranges) {
			ranges[n] = {Paddr(e.base), Paddr(e.base + e.length)}
			n += 1
		}
	}
	for r in ranges[:n] {
		phys_add_range(r.base, r.end)
	}
}
