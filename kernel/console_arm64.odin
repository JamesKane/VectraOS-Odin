package kernel

import "base:intrinsics"

// QEMU virt's PL011 at physical 0x0900_0000. Limine's direct map covers RAM
// only, so the UART page is mapped into Limine's TTBR1 tables at hhdm + phys,
// with MAIR attribute 2 set to Device-nGnRnE.
PL011_PHYS :: 0x0900_0000
PL011_DR :: 0x00
PL011_FR :: 0x18 / 4
PL011_FR_TXFF :: 1 << 5

foreign _ {
	vx_read_ttbr1 :: proc "c" () -> u64 ---
	vx_read_mair :: proc "c" () -> u64 ---
	vx_write_mair :: proc "c" (v: u64) ---
	vx_dsb_isb :: proc "c" () ---
}

pl011: [^]u32

// Output before the UART is mapped waits here, and is flushed once it is.
early_buf: [2048]u8
early_len: int

console_init :: proc "contextless" () {}

PTE_VALID :: 1 << 0
PTE_TABLE :: 1 << 1 // at levels 0-2; at level 3 it marks a page
PTE_AF :: 1 << 10
PTE_PXN :: 1 << 53
PTE_UXN :: 1 << 54
PTE_ATTR_DEVICE :: 2 << 2
PTE_ADDR :: 0x0000_ffff_ffff_f000

early_next, early_limit: u64

// Zeroed 4 KiB pages from the top of the largest usable region, never freed.
early_page :: proc "contextless" () -> u64 {
	if early_next - early_limit < 4096 {
		return 0
	}
	early_next -= 4096
	intrinsics.mem_zero(rawptr(uintptr(early_next + hhdm)), 4096)
	return early_next
}

console_map :: proc "contextless" (mm: ^Memmap_Response) {
	largest: u64
	for e in mm.entries[:mm.entry_count] {
		if e.type == MEMMAP_USABLE && e.length > largest {
			largest = e.length
			early_limit = e.base
			early_next = e.base + e.length
		}
	}

	vx_write_mair(vx_read_mair() & ~u64(0xff << 16))
	va := hhdm + PL011_PHYS
	table := vx_read_ttbr1() & PTE_ADDR
	for level in 0 ..< 3 {
		shift := u64(39 - level * 9)
		slot := (^u64)(uintptr(table + hhdm + ((va >> shift) & 511) * 8))
		e := slot^
		if e & PTE_VALID == 0 {
			page := early_page()
			if page == 0 {
				return
			}
			e = page | PTE_TABLE | PTE_VALID
			slot^ = e
		} else if e & PTE_TABLE == 0 {
			return // a block already covers it; the spike does not split blocks
		}
		table = e & PTE_ADDR
	}
	leaf := (^u64)(uintptr(table + hhdm + ((va >> 12) & 511) * 8))
	leaf^ = PL011_PHYS | PTE_AF | PTE_PXN | PTE_UXN | PTE_ATTR_DEVICE | PTE_TABLE | PTE_VALID
	vx_dsb_isb()
	pl011 = cast([^]u32)uintptr(va)
	for c in early_buf[:early_len] {
		uart_putc(c)
	}
}

putc :: proc "contextless" (c: u8) {
	if pl011 == nil {
		if early_len < len(early_buf) {
			early_buf[early_len] = c
			early_len += 1
		}
		return
	}
	uart_putc(c)
}

uart_putc :: proc "contextless" (c: u8) {
	for intrinsics.volatile_load(&pl011[PL011_FR]) & PL011_FR_TXFF != 0 {}
	intrinsics.volatile_store(&pl011[PL011_DR], u32(c))
}
