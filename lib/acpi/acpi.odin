// vx:acpi, reading the firmware's ACPI tables in user space.
//
// The kernel gives the root task every table end to end in one VMO
// (kernel/acpi.odin). The tables come from firmware, so each is checked before
// use: its length must fit, and its bytes must sum to zero. The AML in the
// DSDT is not read here; bus-acpi's interpreter comes later.
package acpi

import vx "abi:vx"

HEADER :: 36 // every table's header

@(private="file")
le32 :: proc "contextless" (p: []u8) -> u32 {
	return u32(p[0]) | u32(p[1]) << 8 | u32(p[2]) << 16 | u32(p[3]) << 24
}

@(private="file")
le64 :: proc "contextless" (p: []u8) -> u64 {
	return u64(le32(p)) | u64(le32(p[4:])) << 32
}

// The n-th table with this signature (n from 0) in the blob, header
// included. .Err_Not_Found if there is none; .Err_Invalid if the tables
// before it are malformed.
@(require_results)
find :: proc "contextless" (blob: []u8, sig: string, n: int) -> (table: []u8, st: vx.Status) {
	n := n
	for at := 0; at < len(blob); {
		if len(blob) - at < HEADER {
			return nil, .Err_Invalid
		}
		length := le32(blob[at + 4:])
		if length < HEADER || u64(length) > u64(len(blob) - at) {
			return nil, .Err_Invalid
		}
		t := blob[at:][:length]
		sum: u8
		for b in t {
			sum += b
		}
		if string(t[:4]) == sig && sum == 0 {
			if n == 0 {
				return t, .Ok
			}
			n -= 1
		}
		at += int(length)
	}
	return nil, .Err_Not_Found
}

// --- MCFG: where PCI configuration space is (ECAM) ---

Ecam :: struct {
	base:      u64, // the address of bus 0's space, even if start_bus is not 0
	segment:   u16,
	start_bus: u8,
	end_bus:   u8,
}

// The MCFG's n-th region. .Err_Not_Found past the last.
@(require_results)
mcfg :: proc "contextless" (table: []u8, n: int) -> (Ecam, vx.Status) {
	at := 44 + u64(n) * 16
	if at + 16 > u64(len(table)) {
		return {}, .Err_Not_Found
	}
	e := table[at:][:16]
	r := Ecam {
		base      = le64(e),
		segment   = u16(e[8]) | u16(e[9]) << 8,
		start_bus = e[10],
		end_bus   = e[11],
	}
	return r, r.end_bus >= r.start_bus ? .Ok : .Err_Invalid
}
