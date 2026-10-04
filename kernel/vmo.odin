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
	size:       u64, // bytes, a multiple of PAGE_SIZE
	pages:      []Paddr, // each page, in a block of its own through the direct map
	list_order: uint, // the page list's allocation order
	physical:   bool, // device memory: its pages are not RAM, and are never freed
	ring:       bool, // a ring's memory (ring.odin), never copied into a forked task
}

#assert(offset_of(Vmo, obj) == 0) // objects are cast from ^Object

vmo_pool: Pool(Vmo)

VMO_MAX_SIZE :: u64(256) << 20 // the list fits one order-7 block

// A VMO with a page list for `count` pages, not yet filled in.
@(require_results)
vmo_alloc :: proc "contextless" (count: u64) -> (vmo: ^Vmo, st: vx.Status) {
	v := pool_alloc(&vmo_pool)
	if v == nil {
		return nil, .Err_No_Memory
	}
	order := order_for(count * size_of(Paddr))
	list := phys_alloc(order)
	if list == 0 {
		pool_free(&vmo_pool, v)
		return nil, .Err_No_Memory
	}
	object_init(&v.obj, .Vmo)
	v.size = count * PAGE_SIZE
	v.pages = (cast([^]Paddr)phys_to_virt(list))[:count]
	v.list_order = order
	return v, .Ok
}

// Gives back what vmo_alloc took, for a VMO that never got going.
vmo_unalloc :: proc "contextless" (v: ^Vmo) {
	phys_free(virt_to_phys(raw_data(v.pages)), v.list_order)
	pool_free(&vmo_pool, v)
}

@(require_results)
vmo_create :: proc "contextless" (want: u64) -> (vmo: ^Vmo, st: vx.Status) {
	if want == 0 || want > VMO_MAX_SIZE {
		return nil, .Err_Range
	}
	v := vmo_alloc(page_up(want) / PAGE_SIZE) or_return
	for &pa, i in v.pages {
		pa = phys_alloc_zeroed(0)
		if pa == 0 {
			for k in v.pages[:i] {
				phys_free(k, 0)
			}
			vmo_unalloc(v)
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
	vmo_unalloc(v)
}

// Copies kernel bytes into the VMO; the range has been checked.
vmo_write :: proc "contextless" (v: ^Vmo, offset: u64, src: []u8) {
	at := offset
	for s := src; len(s) > 0; {
		n := copy(page_bytes(v.pages[at / PAGE_SIZE])[at % PAGE_SIZE:], s)
		at += u64(n)
		s = s[n:]
	}
}
