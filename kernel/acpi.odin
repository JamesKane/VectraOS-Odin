package kernel

import "base:intrinsics"

// ACPI tables, by signature, through the RSDT or XSDT. Each is checked to
// lie inside memory the direct map covers before it is read.

read32 :: proc "contextless" (p: [^]u8) -> u32 {
	v: u32
	intrinsics.mem_copy_non_overlapping(&v, p, 4)
	return v
}

read64 :: proc "contextless" (p: [^]u8) -> u64 {
	v: u64
	intrinsics.mem_copy_non_overlapping(&v, p, 8)
	return v
}

// Whether [pa, pa + length) is firmware or RAM memory, which the direct map covers.
in_direct_map :: proc "contextless" (pa: Paddr, length: u64) -> bool {
	for r in boot.ram[:boot.ram_count] {
		if pa >= r.base && pa < r.end && length <= u64(r.end - pa) {
			return true
		}
	}
	return false
}

// An ACPI table by signature; nil if there is none.
acpi_table :: proc "contextless" (sig: string) -> [^]u8 {
	if boot.rsdp == 0 || !in_direct_map(boot.rsdp, 36) {
		return nil
	}
	rsdp := cast([^]u8)phys_to_virt(boot.rsdp)
	xsdt := rsdp[15] >= 2
	root := Paddr(xsdt ? read64(rsdp[24:]) : u64(read32(rsdp[16:])))
	if !in_direct_map(root, 36) {
		return nil
	}
	sdt := cast([^]u8)phys_to_virt(root)
	length, entry := read32(sdt[4:]), u32(xsdt ? 8 : 4)
	if !in_direct_map(root, u64(length)) {
		return nil
	}
	for off := u32(36); off + entry <= length; off += entry {
		pa := Paddr(xsdt ? read64(sdt[off:]) : u64(read32(sdt[off:])))
		if !in_direct_map(pa, 36) {
			continue
		}
		t := cast([^]u8)phys_to_virt(pa)
		if string(t[:4]) == sig && in_direct_map(pa, u64(read32(t[4:]))) {
			return t
		}
	}
	return nil
}
