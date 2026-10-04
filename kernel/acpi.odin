package kernel

import "base:intrinsics"
import vx "abi:vx"

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

// A table at a physical address, if it is whole and in the direct map.
@(private="file")
acpi_at :: proc "contextless" (pa: Paddr) -> []u8 {
	HEADER :: 36
	if pa == 0 || !in_direct_map(pa, HEADER) {
		return nil
	}
	length := read32(phys_bytes(pa, HEADER)[4:])
	if length < HEADER || !in_direct_map(pa, u64(length)) {
		return nil
	}
	return phys_bytes(pa, length)
}

// Every table the RSDT or XSDT lists, and the DSDT the FADT points to, end
// to end in one VMO for the root task, so that devmgr can read the rest (the
// MCFG for PCI, and the AML later) in user space. Each starts with its own
// header, whose length says where the next begins.
@(require_results)
acpi_export :: proc "contextless" () -> (v: ^Vmo, size: u64, ok: bool) {
	if boot.rsdp == 0 || !in_direct_map(boot.rsdp, 36) {
		return
	}
	rsdp := phys_bytes(boot.rsdp, 36)
	xsdt := rsdp[15] >= 2
	sdt := acpi_at(Paddr(xsdt ? read64(rsdp[24:]) : u64(read32(rsdp[16:]))))
	if sdt == nil {
		return
	}
	tables: [dynamic; 64][]u8
	entry := xsdt ? 8 : 4
	for off := 36; off + entry <= len(sdt) && len(tables) < 63; off += entry {
		if t := acpi_at(Paddr(xsdt ? read64(sdt[off:]) : u64(read32(sdt[off:])))); t != nil {
			_ = append(&tables, t) // below 63, so room
		}
	}
	if fadt := acpi_table("FACP"); fadt != nil {
		// The DSDT: X_DSDT where the FADT is long enough to have it, else DSDT.
		pa := len(fadt) >= 44 ? Paddr(read32(fadt[40:])) : 0
		if len(fadt) >= 148 && read64(fadt[140:]) != 0 {
			pa = Paddr(read64(fadt[140:]))
		}
		if dsdt := acpi_at(pa); dsdt != nil {
			_ = append(&tables, dsdt) // the 64th at most
		}
	}
	for t in tables {
		size += u64(len(t))
	}
	if size == 0 {
		return
	}
	st: vx.Status
	v, st = vmo_create(size)
	if st != .Ok {
		return nil, 0, false
	}
	at: u64
	for t in tables {
		vmo_write(v, at, t)
		at += u64(len(t))
	}
	return v, size, true
}
