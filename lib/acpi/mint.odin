package acpi

import vx "abi:vx"

// What bus-acpi asks devmgr for, on the channel devmgr gives it ("devmgr"),
// when its AML first reaches hardware (upstream ADR-0024 item 4, M5 step
// 7b): a range of memory (a physical VMO, uncached), of I/O ports (an
// IoRange, x86_64), or a PCI function's configuration space (its 4 KiB of
// ECAM, a physical VMO). devmgr refuses what is RAM, the kernel's own, or
// another driver's grant: the reply then has the status in flags and no
// handle.

MINT :: u32(0x746e_696d) // "mint": the channel's one ordinal

Mint_Kind :: enum u32 {
	Memory = 1,
	Io     = 2,
	Pci    = 3,
	// The machine off through the kernel's PSCI call (base and size 0), for
	// a firmware whose ACPI cannot (hardware-reduced, no sleep registers:
	// QEMU's aarch64). The reply comes only if it did not happen.
	Off    = 4,
}

Mint :: struct {
	header:   vx.Msg_Header,
	kind:     Mint_Kind,
	reserved: u32,
	base:     u64, // memory: page-aligned; I/O: the first port; PCI: segment << 16 | requester ID
	size:     u64, // memory: a whole number of pages; I/O: ports; PCI: 4096
}
#assert(size_of(Mint) == 40)
#assert(offset_of(Mint, kind) == 16)
#assert(offset_of(Mint, base) == 24)
#assert(offset_of(Mint, size) == 32)

// DEVICE (upstream M5 step 7d): bus-acpi says, with a channel_write and no
// reply, a present device's hardware ID and its _CRS resources, which devmgr
// matches against match=acpi records and grants the matched driver exactly
// (upstream ADR-0024 item 3). Memory and I/O are base and size; an interrupt
// is its line (an ISA IRQ or GSI on x86_64, a GIC INTID on aarch64) in base.
DEVICE :: u32(0x6365_7664) // "dvec"

Res_Kind :: enum u32 {
	Memory = 1,
	Io     = 2,
	Irq    = 3,
}

MAX_RES :: 8

Res :: struct {
	kind:     Res_Kind,
	reserved: u32,
	base:     u64,
	size:     u64,
}
#assert(size_of(Res) == 24)

Device :: struct {
	header:   vx.Msg_Header,
	hid:      [16]u8, // the hardware ID, NUL-terminated: PNP0B00
	path:     [48]u8, // the namespace path, NUL-terminated (cut short if longer): \_SB.PCI0.SF8.RTC
	count:    u32, // resources
	reserved: u32,
	res:      [MAX_RES]Res,
}
#assert(offset_of(Device, hid) == 16)
#assert(offset_of(Device, path) == 32)
#assert(offset_of(Device, count) == 80)
#assert(offset_of(Device, res) == 88)
#assert(size_of(Device) == 88 + MAX_RES * 24)

// /srv/acpi, bus-acpi's post: a client's request, by channel_call, is a
// vx.Msg_Header with this ordinal. POWER_OFF: the machine off (S5, or PSCI
// through devmgr); the reply, with the status in flags, comes only if it did
// not happen.
POWER_OFF :: u32(0x6666_6f70) // "poff"
