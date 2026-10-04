package bus_acpi

// The tables, at addresses of their own.
//
// ACPICA finds the tables through an RSDP and an XSDT at physical addresses.
// The firmware's memory they came from may have been reclaimed since, so the
// kernel's copies (all of them, end to end, in the `acpi` VMO) are laid out
// in an address range that is never a real one (TABLES_AT), behind an RSDP
// and an XSDT made here, and ACPICA's "physical" mappings of that range are
// into the copies. The FADT's copy names the DSDT's copy. There is no FACS
// among the copies, so the FADT's copy names none (ADR-0012).

import "acpica"

TABLES_AT :: 0x0000_7f00_0000_0000 // the RSDP and the XSDT, then the copies
COPIES_AT :: TABLES_AT + 0x1_0000
XSDT_AT :: 64 // in roots

roots: [0x1_0000]u8 // the RSDP at 0, the XSDT at XSDT_AT
copies: []u8 // the kernel's tables, end to end, writable: the FADT's copy is changed

@(private="file")
get32 :: proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

@(private="file")
put32 :: proc "contextless" (b: []u8, v: u32) {
	for i in 0 ..< 4 {
		b[i] = u8(v >> (8 * uint(i)))
	}
}

@(private="file")
put64 :: proc "contextless" (b: []u8, v: u64) {
	put32(b, u32(v))
	put32(b[4:], u32(v >> 32))
}

// Sets t[at] so that t's bytes sum to zero.
@(private="file")
checksum :: proc "contextless" (t: []u8, at: int) {
	t[at] = 0
	sum: u8
	for b in t {
		sum += b
	}
	t[at] = -sum
}

// The table at the start of `rest`, or nil if what is left is malformed.
@(private="file")
next_table :: proc "contextless" (rest: []u8) -> []u8 {
	if len(rest) < 36 {
		return nil
	}
	length := get32(rest[4:])
	if length < 36 || u64(length) > u64(len(rest)) {
		return nil
	}
	return rest[:length]
}

// The RSDP and the XSDT naming each copy (but the DSDT, which the FADT
// names, and any FACS), and the FADT's copy pointing at the DSDT's copy.
// false if the copies are malformed.
lay_out_tables :: proc "contextless" () -> bool {
	x := roots[XSDT_AT:]
	copy(x[0:], "XSDT")
	copy(x[10:], "VECTRA")
	x[8] = 1
	n := 0
	dsdt: u64
	for at := 0; len(copies) - at >= 36; {
		t := next_table(copies[at:])
		if t == nil {
			return false
		}
		switch {
		case string(t[:4]) == "DSDT":
			dsdt = COPIES_AT + u64(at)
		case string(t[:4]) != "FACS" && 36 + 8 * (n + 1) <= len(x):
			put64(x[36 + 8 * n:], COPIES_AT + u64(at))
			n += 1
		}
		at += len(t)
	}
	put32(x[4:], u32(36 + 8 * n))
	checksum(x[:36 + 8 * n], 9)
	for at := 0; len(copies) - at >= 36; {
		f := next_table(copies[at:]) // well formed: checked above
		at += len(f)
		if string(f[:4]) != "FACP" {
			continue
		}
		if len(f) >= 44 {
			put32(f[36:], 0) // FIRMWARE_CTRL
			put32(f[40:], 0) // DSDT
		}
		if len(f) >= 140 {
			put64(f[132:], 0) // X_FIRMWARE_CTRL
		}
		if len(f) >= 148 {
			put64(f[140:], dsdt) // X_DSDT
		} else if len(f) >= 44 && dsdt < 1 << 32 {
			put32(f[40:], u32(dsdt))
		}
		checksum(f, 9)
	}
	r := roots[:]
	copy(r[0:], "RSD PTR ")
	copy(r[9:], "VECTRA")
	r[15] = 2
	put32(r[20:], 36)
	put64(r[24:], TABLES_AT + XSDT_AT)
	checksum(r[:20], 8)
	checksum(r[:36], 32)
	return true
}

// Whether the FADT says the hardware is reduced: no fixed hardware, so no
// sleep registers. ACPICA reads the same bit from its copy of the FADT,
// which it zero-fills past a short table's end.
hardware_reduced :: proc "contextless" () -> bool {
	for at := 0; len(copies) - at >= 36; {
		f := next_table(copies[at:])
		if f == nil {
			return false
		}
		at += len(f)
		if string(f[:4]) == "FACP" && len(f) >= acpica.FADT_FLAGS + 4 {
			return get32(f[acpica.FADT_FLAGS:]) & acpica.FADT_HW_REDUCED != 0
		}
	}
	return false
}

@(export, link_name = "AcpiOsGetRootPointer")
os_get_root_pointer :: proc "c" () -> acpica.Physical_Address {
	return TABLES_AT
}
