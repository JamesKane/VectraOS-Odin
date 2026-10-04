package kernel

import "base:intrinsics"

// ACPI tables, by signature, through the RSDT or XSDT. Each is checked to
// lie inside memory the direct map covers before it is read.

// Little-endian fields at any alignment, as both architectures read them.
read32 :: #force_inline proc "contextless" (p: []u8) -> u32 {
	return intrinsics.unaligned_load(cast(^u32)raw_data(p[:4]))
}

read64 :: #force_inline proc "contextless" (p: []u8) -> u64 {
	return intrinsics.unaligned_load(cast(^u64)raw_data(p[:8]))
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

// The bytes at pa, which the caller has checked are in the direct map.
@(private="file")
phys_bytes :: proc "contextless" (pa: Paddr, length: u32) -> []u8 {
	return (cast([^]u8)phys_to_virt(pa))[:length]
}

// An ACPI table by signature, header included; nil if there is none.
acpi_table :: proc "contextless" (sig: string) -> []u8 {
	HEADER :: 36 // an SDT's header, and the RSDP's revision 2 form
	if boot.rsdp == 0 || !in_direct_map(boot.rsdp, HEADER) {
		return nil
	}
	rsdp := phys_bytes(boot.rsdp, HEADER)
	xsdt := rsdp[15] >= 2
	root := Paddr(xsdt ? read64(rsdp[24:]) : u64(read32(rsdp[16:])))
	if !in_direct_map(root, HEADER) {
		return nil
	}
	length, entry := read32(phys_bytes(root, HEADER)[4:]), u32(xsdt ? 8 : 4)
	if !in_direct_map(root, u64(length)) {
		return nil
	}
	sdt := phys_bytes(root, length)
	for off := u32(HEADER); off + entry <= length; off += entry {
		pa := Paddr(xsdt ? read64(sdt[off:]) : u64(read32(sdt[off:])))
		if !in_direct_map(pa, HEADER) {
			continue
		}
		header := phys_bytes(pa, HEADER)
		table_length := read32(header[4:])
		if string(header[:4]) == sig && table_length >= HEADER && in_direct_map(pa, u64(table_length)) {
			return phys_bytes(pa, table_length)
		}
	}
	return nil
}
