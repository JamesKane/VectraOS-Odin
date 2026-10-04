package kernel

import "base:intrinsics"
import vx "abi:vx"

// Anonymous virtual memory objects.
//
// An anonymous VMO's pages are all allocated and zeroed when it is created:
// commit, not overcommit, so a task learns it is out of memory from a failed
// call, never from a fault later. The page list is one block of physical
// addresses. Physical VMOs (device memory) are made in device.odin. Clones,
// pagers and resizing come in later milestones.

Vmo :: struct {
	using obj:  Object,
	size:       u64, // bytes, a multiple of 4096
	pages:      []Paddr, // each page, in a block of its own through the direct map
	list_order: uint, // the page list's allocation order
	physical:   bool, // device memory: its pages are not RAM, and are never freed
}

#assert(offset_of(Vmo, obj) == 0) // objects are cast from ^Object

vmo_pool: Pool(Vmo)

VMO_MAX_SIZE :: u64(256) << 20 // the list fits one order-7 block

// The allocation order of a page list for `count` pages.
page_list_order :: proc "contextless" (count: u64) -> uint {
	order := uint(0)
	for (4096 << order) < count * size_of(u64) {
		order += 1
	}
	return order
}

@(require_results)
vmo_create :: proc "contextless" (want: u64) -> (^Vmo, vx.Status) {
	if want == 0 || want > VMO_MAX_SIZE {
		return nil, .Err_Range
	}
	size := page_up(want)
	count := size / 4096
	order := page_list_order(count)
	v := pool_alloc(&vmo_pool)
	if v == nil {
		return nil, .Err_No_Memory
	}
	list := phys_alloc(order)
	if list == 0 {
		pool_free(&vmo_pool, v)
		return nil, .Err_No_Memory
	}
	object_init(&v.obj, .Vmo)
	v.size = size
	v.pages = (cast([^]Paddr)phys_to_virt(list))[:count]
	v.list_order = order
	for &pa, i in v.pages {
		pa = phys_alloc_zeroed(0)
		if pa == 0 {
			for k in v.pages[:i] {
				phys_free(k, 0)
			}
			phys_free(list, order)
			pool_free(&vmo_pool, v)
			return nil, .Err_No_Memory
		}
	}
	return v, .Ok
}

vmo_destroy :: proc "contextless" (v: ^Vmo) {
	if !v.physical {
		for pa in v.pages {
			phys_free(pa, 0)
		}
	}
	phys_free(virt_to_phys(raw_data(v.pages)), v.list_order)
	pool_free(&vmo_pool, v)
}

// Copies kernel bytes into the VMO; the range has been checked.
vmo_write :: proc "contextless" (v: ^Vmo, offset: u64, src: []u8) {
	at := offset
	s := src
	for len(s) > 0 {
		in_page := at & 4095
		n := min(4096 - in_page, u64(len(s)))
		page := cast([^]u8)phys_to_virt(v.pages[at / 4096])
		intrinsics.mem_copy_non_overlapping(&page[in_page], raw_data(s), int(n))
		at += n
		s = s[n:]
	}
}
