// vx:pci, PCI configuration space, through ECAM, which maps each function's
// 4 KiB of configuration registers into memory. Host tests give it a fake
// function.
package pci

import "base:intrinsics"
import vx "abi:vx"

CONFIG_SIZE :: 4096

Function :: struct {
	cfg: ^[CONFIG_SIZE / 4]u32, // its 4 KiB of configuration space
	bus: u8,
	dev: u8,
	fn:  u8,
}

read32 :: proc "contextless" (f: ^Function, off: u32) -> u32 {
	return intrinsics.volatile_load(&f.cfg[off >> 2])
}

read16 :: proc "contextless" (f: ^Function, off: u32) -> u16 {
	return u16(read32(f, off) >> (8 * (off & 2)))
}

read8 :: proc "contextless" (f: ^Function, off: u32) -> u8 {
	return u8(read32(f, off) >> (8 * (off & 3)))
}

write32 :: proc "contextless" (f: ^Function, off: u32, v: u32) {
	intrinsics.volatile_store(&f.cfg[off >> 2], v)
}

write16 :: proc "contextless" (f: ^Function, off: u32, v: u16) {
	halves := cast(^[CONFIG_SIZE / 2]u16)f.cfg
	intrinsics.volatile_store(&halves[off >> 1], v)
}

// The requester ID: how the function names itself on the bus (MSIs, the IOMMU).
rid :: proc "contextless" (f: ^Function) -> u32 {
	return u32(f.bus) << 8 | u32(f.dev) << 3 | u32(f.fn)
}

// Offset of the n-th capability with this ID (from 0) in the list, or 0. The
// list comes from the device, so it is walked a bounded number of steps.
cap :: proc "contextless" (f: ^Function, id: u8, n: int) -> u8 {
	if read16(f, 0x06) & (1 << 4) == 0 {
		return 0 // status: no capability list
	}
	n := n
	at := read8(f, 0x34) & 0xfc
	for steps := 0; at >= 0x40 && steps < 48; steps += 1 {
		if read8(f, u32(at)) == id {
			if n == 0 {
				return at
			}
			n -= 1
		}
		at = read8(f, u32(at) + 1) & 0xfc
	}
	return 0
}

Bar :: struct {
	base:         u64,
	size:         u64, // 0: the BAR is not implemented
	io:           bool,
	prefetchable: bool,
}

// Reads BAR i (a 64-bit BAR also takes i + 1) and sizes it, with memory and
// I/O decoding off while its address is all ones. A BAR the function does
// not implement reads back 0, and has size 0.
bar_read :: proc "contextless" (f: ^Function, i: u32) -> Bar {
	off := 0x10 + 4 * i
	low := read32(f, off)
	high, high_mask: u32
	io := low & 1 != 0
	wide := !io && low & 6 == 4 && i < 5
	command := read16(f, 0x04)
	write16(f, 0x04, command &~ 3)
	write32(f, off, ~u32(0))
	low_mask := read32(f, off)
	write32(f, off, low)
	if wide {
		high = read32(f, off + 4)
		write32(f, off + 4, ~u32(0))
		high_mask = read32(f, off + 4)
		write32(f, off + 4, high)
	}
	write16(f, 0x04, command)
	b := Bar{io = io, prefetchable = !io && low & 8 != 0}
	if io {
		m := low_mask &~ 3
		b.base = u64(low &~ 3)
		b.size = m != 0 ? u64(u16(~(m | 0xffff_0000) + 1)) : 0 // I/O BARs decode 16 bits
	} else {
		m := u64(low_mask &~ 0xf) | u64(high_mask) << 32
		if !wide && m != 0 {
			m |= 0xffff_ffff_0000_0000 // a 32-bit BAR's upper half is all address
		}
		b.base = u64(low &~ 0xf) | u64(high) << 32
		b.size = m != 0 ? ~m + 1 : 0
	}
	return b
}

// --- MSI-X (PCI 3.0 §6.8.2) ---

// An MSI-X table entry.
Msix_Entry :: struct {
	address_lo: u32,
	address_hi: u32,
	data:       u32,
	control:    u32, // bit 0 masks it
}
#assert(size_of(Msix_Entry) == 16)

// The MSI-X table, in whichever of the BARs (mapped by the caller; empty if
// not) the capability names; nil if there is none, or it does not fit.
msix_table :: proc "contextless" (f: ^Function, bars: [][]u8) -> []Msix_Entry {
	at := cap(f, 0x11, 0)
	if at == 0 {
		return nil
	}
	table := read32(f, u32(at) + 4)
	bir, offset := table & 7, u64(table &~ 7)
	count := u64(read16(f, u32(at) + 2) & 0x7ff) + 1
	if bir >= u32(len(bars)) || offset + size_of(Msix_Entry) * count > u64(len(bars[bir])) {
		return nil
	}
	return (cast([^]Msix_Entry)&bars[bir][offset])[:count]
}

// Points entry i at an MSI (from irq_create_msi), unmasked, and turns MSI-X
// on, not function-masked.
msix_set :: proc "contextless" (f: ^Function, table: []Msix_Entry, i: int, msi: vx.Msi) {
	e := &table[i]
	intrinsics.volatile_store(&e.address_lo, u32(msi.address))
	intrinsics.volatile_store(&e.address_hi, u32(msi.address >> 32))
	intrinsics.volatile_store(&e.data, msi.data)
	intrinsics.volatile_store(&e.control, 0) // unmasked
	MSIX_ENABLE :: 1 << 15
	MSIX_FUNCTION_MASK :: 1 << 14
	at := u32(cap(f, 0x11, 0))
	control := read16(f, at + 2)
	write16(f, at + 2, (control | MSIX_ENABLE) &~ MSIX_FUNCTION_MASK)
}

// Memory decoding and bus mastering on, INTx off: what a driver of a device
// with MSI-X and DMA wants before it starts it.
enable :: proc "contextless" (f: ^Function) {
	MEMORY :: 1 << 1
	BUS_MASTER :: 1 << 2
	INTX_DISABLE :: 1 << 10
	command := read16(f, 0x04)
	write16(f, 0x04, command | BUS_MASTER | MEMORY | INTX_DISABLE)
}
