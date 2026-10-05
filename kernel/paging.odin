package kernel

// The kernel's page tables. Both architectures use a 4 KiB granule and four
// levels for 48-bit virtual addresses: level 0 is the top, level 3 holds 4 KiB
// pages, and levels 1 and 2 may hold 1 GiB and 2 MiB leaves. The entry format
// is the architecture's (arch_pte_*).

Map_Flag :: enum u32 {
	Write,
	Exec,
	User,
	Device, // uncached device memory
}

Map_Flags :: bit_set[Map_Flag; u32] // a mapping is always readable

PAGE_SIZE :: 4096

// A page's bytes, through the direct map.
page_bytes :: #force_inline proc "contextless" (pa: Paddr) -> []u8 {
	return (cast([^]u8)phys_to_virt(pa))[:PAGE_SIZE]
}

// One whole page copied to another, the architecture's fastest way
// (arch_page_copy: rep movsb on x86_64, NEON on aarch64; M6 step 6c2): a
// fork's, a pager's supply, vmo_clone's, a mapping's private copy.
page_copy :: #force_inline proc "contextless" (dst, src: Paddr) {
	arch_page_copy(phys_to_virt(dst), phys_to_virt(src), PAGE_SIZE)
}

// A page-table entry, in the architecture's format (arch_pte_*).
Pte :: distinct u64

kernel_root: Paddr // the kernel's top-level table

table_at :: #force_inline proc "contextless" (pa: Paddr) -> ^[512]Pte {
	return cast(^[512]Pte)phys_to_virt(pa)
}

// The index of va's entry in its level's table.
pt_index :: #force_inline proc "contextless" (va: u64, level: int) -> u64 {
	return (va >> uint(39 - 9 * level)) & 511
}

// Pages for new tables: from the early allocator until phys_init has run.
@(private="file")
table_page :: proc "contextless" () -> Paddr {
	return phys.frame_state != nil ? phys_alloc_zeroed(0) : early_alloc(1)
}

// Maps [va, va + size) to [pa, pa + size), with the largest leaves that
// alignment allows; a user mapping's leaves carry its protection key
// (ADR-0035). Fails without undoing anything if a table cannot be allocated
// or the range is already mapped; callers treat that as fatal.
@(require_results)
map_range :: proc "contextless" (root: Paddr, va_start: u64, pa_start: Paddr, length: u64, flags: Map_Flags, key: u32 = 0) -> bool {
	va, pa, size := va_start, pa_start, length
	for size > 0 {
		level := 3
		step := u64(PAGE_SIZE)
		if (va | u64(pa)) & (1 << 30 - 1) == 0 && size >= 1 << 30 {
			level, step = 1, 1 << 30
		} else if (va | u64(pa)) & (1 << 21 - 1) == 0 && size >= 1 << 21 {
			level, step = 2, 1 << 21
		}
		t := table_at(root)
		for l in 0 ..< level {
			idx := pt_index(va, l)
			if !arch_pte_valid(t[idx]) {
				page := table_page()
				if page == 0 {
					return false
				}
				arch_pte_publish() // the new table's zeroes, before the entry that leads to it
				t[idx] = arch_pte_table(page)
			} else if !arch_pte_is_table(t[idx], l) {
				return false
			}
			t = table_at(arch_pte_addr(t[idx]))
		}
		idx := pt_index(va, level)
		if arch_pte_valid(t[idx]) {
			return false
		}
		t[idx] = arch_pte_leaf(pa, flags, level, key)
		va += step
		pa += Paddr(step)
		size -= step
	}
	arch_pte_publish()
	return true
}

// Section bounds from the linker script: addresses only (console.odin says why
// they are declared as procedures).
foreign _ {
	vx_text_start :: proc "c" () ---
	vx_text_end :: proc "c" () ---
	vx_rodata_start :: proc "c" () ---
	vx_rodata_end :: proc "c" () ---
	vx_data_start :: proc "c" () ---
	vx_data_end :: proc "c" () ---
	vx_boot_stack_bottom :: proc "c" () ---
	vx_boot_stack_top :: proc "c" () ---
}

page_up :: #force_inline proc "contextless" (v: u64) -> u64 {
	return (v + PAGE_SIZE - 1) &~ (PAGE_SIZE - 1)
}

@(private="file")
map_image_part :: proc "contextless" (start, end: proc "c" (), flags: Map_Flags) {
	va := u64(uintptr(rawptr(start)))
	size := page_up(u64(uintptr(rawptr(end)))) - va
	if !map_range(kernel_root, va, Paddr(va - boot.kernel_virt) + boot.kernel_phys, size, flags) {
		kpanic("cannot map the kernel image")
	}
}

// Builds the kernel's own page tables and switches to them:
//  - the kernel image, each part with its own permissions (W^X);
//  - the direct map: RAM, firmware tables and runtime services, never
//    executable, read-write but for the kernel image and the modules;
//  - the architecture's device pages (arch_kernel_mappings);
//  - nothing in the lower half, so null pointers fault.
paging_init :: proc "contextless" () {
	kernel_root = phys_alloc_zeroed(0)
	if kernel_root == 0 {
		kpanic("no memory for page tables")
	}
	map_image_part(vx_text_start, vx_text_end, {.Exec})
	map_image_part(vx_rodata_start, vx_rodata_end, {})
	map_image_part(vx_data_start, vx_data_end, {.Write})
	map_image_part(vx_boot_stack_bottom, vx_boot_stack_top, {.Write}) // the page below stays unmapped

	// Runs of adjacent regions with the same permissions merge, so large
	// leaves fit. The kernel image and the boot modules are read-only here:
	// the image is written only through its own mapping (W^X).
	mm := response(&memmap_request)
	run_lo, run_hi: u64
	run_flags: Map_Flags
	for i in 0 ..= mm.entry_count {
		lo, hi: u64
		flags := Map_Flags{.Write}
		if i < mm.entry_count {
			e := mm.entries[i]
			#partial switch e.type {
			case .Executable_And_Modules:
				flags = {}
			case .Usable, .Bootloader_Reclaimable, .Acpi_Reclaimable, .Acpi_Nvs, .Reserved_Mapped:
			case:
				continue
			}
			lo = e.base &~ (PAGE_SIZE - 1)
			hi = page_up(e.base + e.length)
			if run_hi != 0 && lo <= run_hi && flags == run_flags { // the map is sorted: extend the run
				if hi > run_hi {
					run_hi = hi
				}
				continue
			}
			if run_hi != 0 && lo < run_hi {
				lo = run_hi // a page shared with the run before: that run has it
			}
		}
		if run_hi != 0 && !map_range(kernel_root, boot.hhdm + run_lo, Paddr(run_lo), run_hi - run_lo, run_flags) {
			kpanic("cannot build the direct map")
		}
		run_lo, run_hi, run_flags = lo, hi, flags
	}

	arch_kernel_mappings(kernel_root)
	arch_switch_tables(kernel_root)
}

// The leaf entry mapping va in root, and its level, or nil if there is none.
leaf_entry :: proc "contextless" (root: Paddr, va: u64) -> (^Pte, int) {
	t := table_at(root)
	for level in 0 ..= 3 {
		e := &t[pt_index(va, level)]
		if !arch_pte_valid(e^) {
			return nil, 0
		}
		if !arch_pte_is_table(e^, level) {
			return e, level
		}
		t = table_at(arch_pte_addr(e^))
	}
	return nil, 0
}

// The physical address behind user address va in root, or 0 if it is not
// mapped for user access. Futexes are keyed on it.
user_page_pa :: proc "contextless" (root: Paddr, va: Uva) -> Paddr {
	e, level := leaf_entry(root, u64(va))
	if e == nil || !arch_pte_user_ok(e^, false) {
		return 0
	}
	page := u64(1) << uint(39 - 9 * level)
	return arch_pte_addr(e^) + Paddr(u64(va) & (page - 1))
}

// Whether va is mapped in root for user access, and writable if asked.
user_page_ok :: proc "contextless" (root: Paddr, va: Uva, write: bool) -> bool {
	e, _ := leaf_entry(root, u64(va))
	return e != nil && arch_pte_user_ok(e^, write)
}

// Clears a 4 KiB page's entry. Its translation may still be cached on any
// CPU that has the tables loaded: the caller shoots it down
// (arch_tlb_shootdown), with no lock held, before the page can be freed.
unmap_page :: proc "contextless" (root: Paddr, va: u64) {
	e, level := leaf_entry(root, va)
	if e != nil && level == 3 {
		e^ = 0
	}
}

// Frees the user half's page tables and the top table itself. The leaves are
// VMO pages, which their VMOs free. No CPU may be using the address space.
// Three nested loops rather than recursion.
free_user_tables :: proc "contextless" (root: Paddr) {
	top := table_at(root)
	for i in 0 ..< arch_user_top_slots() {
		if !arch_pte_valid(top[i]) || !arch_pte_is_table(top[i], 0) {
			continue
		}
		l1 := table_at(arch_pte_addr(top[i]))
		for j in 0 ..< 512 {
			if !arch_pte_valid(l1[j]) || !arch_pte_is_table(l1[j], 1) {
				continue
			}
			l2 := table_at(arch_pte_addr(l1[j]))
			for k in 0 ..< 512 {
				if arch_pte_valid(l2[k]) && arch_pte_is_table(l2[k], 2) {
					phys_free(arch_pte_addr(l2[k]), 0)
				}
			}
			phys_free(arch_pte_addr(l1[j]), 0)
		}
		phys_free(arch_pte_addr(top[i]), 0)
	}
	phys_free(root, 0)
}
