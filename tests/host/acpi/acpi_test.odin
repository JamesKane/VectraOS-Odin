// lib/acpi and lib/pci's capability walk. Tables are found by signature and
// only whole, with good checksums; MCFG regions read back; and a capability
// list that loops or points nowhere is walked safely.
package acpi_test

import "core:testing"
import vx "abi:vx"
import "vx:acpi"
import "vx:pci"

// A table of `length` bytes with this signature at `at`.
@(private="file")
table :: proc(blob: []u8, at: int, sig: string, length: int) {
	t := blob[at:][:length]
	for &b in t {
		b = 0
	}
	copy(t, sig)
	t[4], t[5] = u8(length), u8(length >> 8)
}

// Fixes the table's checksum.
@(private="file")
seal :: proc(blob: []u8, at: int, length: int) {
	t := blob[at:][:length]
	t[9] = 0
	sum: u8
	for b in t {
		sum += b
	}
	t[9] = -sum
}

@(private="file")
expect_found :: proc(t: ^testing.T, blob: []u8, sig: string, n: int, at, length: int, loc := #caller_location) {
	got, st := acpi.find(blob, sig, n)
	testing.expect_value(t, st, vx.Status.Ok, loc = loc)
	testing.expect_value(t, len(got), length, loc = loc)
	testing.expect_value(t, raw_data(got), &blob[at], loc = loc)
}

@(test)
test_tables :: proc(t: ^testing.T) {
	blob: [512]u8
	table(blob[:], 0, "FACP", 40)
	seal(blob[:], 0, 40)
	table(blob[:], 40, "MCFG", 76) // two regions
	e := blob[40 + 44:]
	e[3] = 0xe0 // base 0xe0000000
	e[10], e[11] = 0, 0xff // buses 0..255
	e[16 + 4], e[16 + 8] = 0x40, 1 // base 0x40_0000_0000 (byte 4: bits 32..39), segment 1
	e[16 + 10], e[16 + 11] = 0, 0x0f // buses 0..15
	seal(blob[:], 40, 76)
	table(blob[:], 116, "APIC", 36)
	seal(blob[:], 116, 36)
	table(blob[:], 152, "APIC", 36)
	seal(blob[:], 152, 36)
	tables := blob[:188]

	expect_found(t, tables, "MCFG", 0, 40, 76)
	expect_found(t, tables, "APIC", 1, 152, 36)
	_, st := acpi.find(tables, "APIC", 2)
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	_, st = acpi.find(tables, "SSDT", 0)
	testing.expect_value(t, st, vx.Status.Err_Not_Found)

	mcfg, _ := acpi.find(tables, "MCFG", 0)
	r: acpi.Ecam
	r, st = acpi.mcfg(mcfg, 0)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, r, acpi.Ecam{base = 0xe000_0000, segment = 0, start_bus = 0, end_bus = 0xff})
	r, st = acpi.mcfg(mcfg, 1)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, r, acpi.Ecam{base = 0x40_0000_0000, segment = 1, start_bus = 0, end_bus = 0x0f})
	_, st = acpi.mcfg(mcfg, 2)
	testing.expect_value(t, st, vx.Status.Err_Not_Found)

	blob[50] ~= 1 // a bad checksum: the MCFG is not found, but the tables after it still are
	_, st = acpi.find(tables, "MCFG", 0)
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	_, st = acpi.find(tables, "APIC", 0)
	testing.expect_value(t, st, vx.Status.Ok)
	blob[50] ~= 1
	blob[44] = 0xff // a length that runs past the end: nothing after it can be trusted
	_, st = acpi.find(tables, "APIC", 0)
	testing.expect_value(t, st, vx.Status.Err_Invalid)
	blob[44] = 76
	_, st = acpi.find(tables[:len(tables) - 1], "APIC", 1) // cut short
	testing.expect_value(t, st, vx.Status.Err_Invalid)
	blob[4] = 10 // shorter than a header
	_, st = acpi.find(tables, "FACP", 0)
	testing.expect_value(t, st, vx.Status.Err_Invalid)
}

@(test)
test_capabilities :: proc(t: ^testing.T) {
	space: [1024]u32 // a function's 4 KiB of configuration space
	cfg := (cast([^]u8)&space)[:4096]
	f := pci.Function{cfg = &space, bus = 1, dev = 2, fn = 3}
	testing.expect_value(t, pci.rid(&f), u32(1 << 8 | 2 << 3 | 3))
	testing.expect_value(t, pci.cap(&f, 0x11, 0), 0) // no list: the status bit is clear
	cfg[0x06], cfg[0x34] = 1 << 4, 0x40
	cfg[0x40], cfg[0x41] = 0x09, 0x50 // vendor-specific, then
	cfg[0x50], cfg[0x51] = 0x11, 0x60 // MSI-X, then
	cfg[0x60], cfg[0x61] = 0x09, 0x00 // vendor-specific, the end
	testing.expect_value(t, pci.cap(&f, 0x11, 0), 0x50)
	testing.expect_value(t, pci.cap(&f, 0x09, 0), 0x40)
	testing.expect_value(t, pci.cap(&f, 0x09, 1), 0x60)
	testing.expect_value(t, pci.cap(&f, 0x09, 2), 0)
	cfg[0x61] = 0x40 // a loop: the walk still ends
	testing.expect_value(t, pci.cap(&f, 0x05, 0), 0)
	cfg[0x61] = 0x10 // into the header: the walk stops
	testing.expect_value(t, pci.cap(&f, 0x05, 0), 0)
	testing.expect_value(t, pci.read16(&f, 0x50), 0x60 << 8 | 0x11)
	testing.expect_value(t, pci.read8(&f, 0x51), 0x60)
}

// Upstream fuzzes vx-acpi with arbitrary bytes as the kernel's export; its
// corpus, and every prefix of it, must keep the fuzzer's invariants: each
// table found lies inside the input with a checksum of zero, and each MCFG
// region inside its table.
// The fuzzer's invariants on one input: each table found lies inside it
// with a checksum of zero, and each MCFG region inside its table. Returns how
// many tables it found.
@(private="file")
check_invariants :: proc(t: ^testing.T, data: []u8) -> (found: int) {
	SIGS :: [?]string{"APIC", "MCFG", "FACP", "DSDT"}
	for sig in SIGS {
		for n in 0 ..< 8 {
			tab, st := acpi.find(data, sig, n)
			if st != .Ok {
				break
			}
			found += 1
			base, at := uintptr(raw_data(data)), uintptr(raw_data(tab))
			testing.expect(t, at >= base && at + uintptr(len(tab)) <= base + uintptr(len(data)))
			testing.expect(t, len(tab) >= acpi.HEADER)
			sum: u8
			for b in tab {
				sum += b
			}
			testing.expect_value(t, sum, 0)
			for r in 0 ..< 64 {
				e, mst := acpi.mcfg(tab, r)
				if mst != .Ok {
					break
				}
				testing.expect(t, 44 + r * 16 + 16 <= len(tab))
				testing.expect(t, e.end_bus >= e.start_bus)
			}
		}
	}
	return
}

// Upstream fuzzes vx-acpi with arbitrary bytes as the kernel's export. Its
// corpus file, and every prefix of it, keeps the fuzzer's invariants; it is
// an MCFG whose checksum is not zero, so it is not found, and once sealed it
// is, with its one region.
@(test)
test_corpus :: proc(t: ^testing.T) {
	corpus := #load("mcfg.corpus")
	for size in 0 ..= len(corpus) {
		testing.expect_value(t, check_invariants(t, corpus[:size]), 0)
	}
	buf: [256]u8
	sealed := buf[:len(corpus)]
	copy(sealed, corpus)
	seal(sealed, 0, len(sealed))
	for size in 0 ..< len(sealed) {
		testing.expect_value(t, check_invariants(t, sealed[:size]), 0)
	}
	testing.expect_value(t, check_invariants(t, sealed), 1)
	mcfg, _ := acpi.find(sealed, "MCFG", 0)
	r, st := acpi.mcfg(mcfg, 0)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, r, acpi.Ecam{base = 0xe000_0000, segment = 0, start_bus = 0, end_bus = 0xff})
}
