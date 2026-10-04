package bus_acpi

// What the AML reaches: asked of devmgr, kept (upstream's ADR-0024 item 4).
//
// Each memory region, port range and PCI function's configuration space is
// asked for when the AML first touches it, and kept: devmgr refuses what is
// RAM, the kernel's or a driver's, and a refusal is said once.

import "base:intrinsics"
import vx "abi:vx"
import "acpica"
import "vx:acpi"
import "vx:memory"
import "vx:rt"

devmgr: vx.Handle // the channel to ask on

@(private="file")
status_name :: proc "contextless" (st: vx.Status) -> string {
	#partial switch st {
	case .Err_Access:
		return "refused (RAM, the kernel's, or a driver's)"
	case .Err_Range:
		return "out of range"
	case .Err_Unsupported:
		return "no such thing here"
	case .Err_No_Memory:
		return "no room"
	case .Err_Peer_Closed:
		return "devmgr is gone"
	}
	return "refused"
}

// v in lowercase hex, without leading zeros: C's %llx.
print_hex :: proc "contextless" (v: u64) {
	DIGITS := "0123456789abcdef"
	buf: [16]u8
	i := len(buf)
	v := v
	for {
		i -= 1
		buf[i] = DIGITS[v & 15]
		v >>= 4
		if v == 0 {
			break
		}
	}
	rt.print(string(buf[i:]))
}

@(private="file")
said_once :: proc "contextless" (what: string, at: u64, st: vx.Status) {
	@(static) seen: [dynamic; 64]u64
	for s in seen {
		if s == at {
			return
		}
	}
	_ = append(&seen, at) // past 64, said again
	rt.print("bus-acpi: no ", what, " at 0x")
	print_hex(at)
	rt.print(": ", status_name(st), "\n")
}

// What devmgr gives for a request: a handle, or the status of its refusal.
ask :: proc "contextless" (kind: acpi.Mint_Kind, base, size: u64) -> (h: vx.Handle, st: vx.Status) {
	m := acpi.Mint {
		header = {ordinal = acpi.MINT},
		kind = kind,
		base = base,
		size = size,
	}
	rep: vx.Msg_Header
	h = vx.HANDLE_NONE
	call := vx.Call {
		wr_bytes     = &m,
		wr_len       = size_of(m),
		rd_bytes     = &rep,
		rd_cap       = size_of(rep),
		rd_handles   = &h,
		rd_count_cap = 1,
	}
	st = .Err_Peer_Closed
	if devmgr != vx.HANDLE_NONE {
		st = rt.channel_call(devmgr, &call, rt.clock_read() + 5_000_000_000)
	}
	if st == .Ok && rep.flags != 0 {
		st = vx.Status(i32(rep.flags))
	}
	if st == .Ok && call.actual.handles != 1 {
		st = .Err_Invalid
	}
	if st != .Ok && h != vx.HANDLE_NONE {
		_ = rt.handle_close(h)
		h = vx.HANDLE_NONE
	}
	return
}

// --- Memory ---

Mapped :: struct {
	base, size: u64, // physical, page-aligned
	at:         []u8,
}

maps: [dynamic; 64]Mapped

// Physical memory [where, where + length), mapped: devmgr's VMO, kept.
@(private="file")
map_physical :: proc "contextless" (where_, length: u64) -> rawptr {
	for m in maps {
		if where_ >= m.base && where_ + length <= m.base + m.size {
			return rawptr(uintptr(raw_data(m.at)) + uintptr(where_ - m.base))
		}
	}
	base := where_ &~ (memory.PAGE_SIZE - 1)
	end, ok := memory.page_round(where_ + length)
	st := vx.Status.Err_No_Memory
	at: u64
	if ok && len(maps) < cap(maps) {
		vmo: vx.Handle
		vmo, st = ask(.Memory, base, end - base)
		if st == .Ok {
			at, st = rt.as_map(rt.self, vmo, 0, end - base, {.Write})
			_ = rt.handle_close(vmo)
		}
	}
	if st != .Ok {
		said_once("memory", where_, st)
		return nil
	}
	m := Mapped{base, end - base, (cast([^]u8)uintptr(at))[:end - base]}
	_ = append(&maps, m)
	return rawptr(uintptr(at) + uintptr(where_ - base))
}

@(export, link_name = "AcpiOsMapMemory")
os_map_memory :: proc "c" (where_: acpica.Physical_Address, length: acpica.Size) -> rawptr {
	if where_ >= TABLES_AT && where_ - TABLES_AT <= len(roots) && length <= len(roots) - (where_ - TABLES_AT) {
		return raw_data(roots[where_ - TABLES_AT:])
	}
	if where_ >= COPIES_AT && where_ - COPIES_AT <= u64(len(copies)) && length <= u64(len(copies)) - (where_ - COPIES_AT) {
		return raw_data(copies[where_ - COPIES_AT:])
	}
	return map_physical(where_, length)
}

@(export, link_name = "AcpiOsUnmapMemory")
os_unmap_memory :: proc "c" (logical: rawptr, size: acpica.Size) {} // kept

@(private="file")
load :: proc "contextless" (p: rawptr, width: u32) -> u64 {
	switch width {
	case 8:
		return u64(intrinsics.volatile_load(cast(^u8)p))
	case 16:
		return u64(intrinsics.volatile_load(cast(^u16)p))
	case 32:
		return u64(intrinsics.volatile_load(cast(^u32)p))
	}
	return intrinsics.volatile_load(cast(^u64)p)
}

@(private="file")
store :: proc "contextless" (p: rawptr, v: u64, width: u32) {
	switch width {
	case 8:
		intrinsics.volatile_store(cast(^u8)p, u8(v))
	case 16:
		intrinsics.volatile_store(cast(^u16)p, u16(v))
	case 32:
		intrinsics.volatile_store(cast(^u32)p, u32(v))
	case:
		intrinsics.volatile_store(cast(^u64)p, v)
	}
}

@(export, link_name = "AcpiOsReadMemory")
os_read_memory :: proc "c" (address: acpica.Physical_Address, value: ^u64, width: u32) -> acpica.Status {
	p := os_map_memory(address, acpica.Size(width / 8))
	value^ = p != nil ? load(p, width) : 0
	return p != nil ? .Ok : .Not_Exist
}

@(export, link_name = "AcpiOsWriteMemory")
os_write_memory :: proc "c" (address: acpica.Physical_Address, value: u64, width: u32) -> acpica.Status {
	p := os_map_memory(address, acpica.Size(width / 8))
	if p != nil {
		store(p, value, width)
	}
	return p != nil ? .Ok : .Not_Exist
}

// --- I/O ports (x86_64): the ranges devmgr gave, each mapped into this task ---

Port_Range :: struct {
	base, size: u64,
}

ports: [dynamic; 64]Port_Range

when ODIN_ARCH == .amd64 {
	// arch/x86_64/io.S: only the ports an IoRange has given this task.
	foreign _ {
		bus_acpi_in8 :: proc "c" (port: u16) -> u8 ---
		bus_acpi_in16 :: proc "c" (port: u16) -> u16 ---
		bus_acpi_in32 :: proc "c" (port: u16) -> u32 ---
		bus_acpi_out8 :: proc "c" (port: u16, value: u8) ---
		bus_acpi_out16 :: proc "c" (port: u16, value: u16) ---
		bus_acpi_out32 :: proc "c" (port: u16, value: u32) ---
	}

	@(private="file")
	have_ports :: proc "contextless" (base, count: u64) -> bool {
		for r in ports {
			if base >= r.base && base + count <= r.base + r.size {
				return true
			}
		}
		st := vx.Status.Err_No_Memory
		if len(ports) < cap(ports) {
			io: vx.Handle
			io, st = ask(.Io, base, count)
			if st == .Ok {
				_, st = rt.as_map(rt.self, io, 0, 0, {}) // kept: the mapping holds it
			}
		}
		if st != .Ok {
			said_once("I/O port", base, st)
			return false
		}
		_ = append(&ports, Port_Range{base, count})
		return true
	}

	@(export, link_name = "AcpiOsReadPort")
	os_read_port :: proc "c" (address: acpica.Io_Address, value: ^u32, width: u32) -> acpica.Status {
		value^ = 0xffff_ffff
		if !have_ports(address, u64(width / 8)) {
			return .Not_Exist
		}
		port := u16(address)
		switch width {
		case 8:
			value^ = u32(bus_acpi_in8(port))
		case 16:
			value^ = u32(bus_acpi_in16(port))
		case:
			value^ = bus_acpi_in32(port)
		}
		return .Ok
	}

	@(export, link_name = "AcpiOsWritePort")
	os_write_port :: proc "c" (address: acpica.Io_Address, value: u32, width: u32) -> acpica.Status {
		if !have_ports(address, u64(width / 8)) {
			return .Not_Exist
		}
		port := u16(address)
		switch width {
		case 8:
			bus_acpi_out8(port, u8(value))
		case 16:
			bus_acpi_out16(port, u16(value))
		case:
			bus_acpi_out32(port, value)
		}
		return .Ok
	}
} else {
	@(export, link_name = "AcpiOsReadPort")
	os_read_port :: proc "c" (address: acpica.Io_Address, value: ^u32, width: u32) -> acpica.Status {
		value^ = 0xffff_ffff
		said_once("I/O port", address, .Err_Unsupported)
		return .Not_Exist
	}

	@(export, link_name = "AcpiOsWritePort")
	os_write_port :: proc "c" (address: acpica.Io_Address, value: u32, width: u32) -> acpica.Status {
		said_once("I/O port", address, .Err_Unsupported)
		return .Not_Exist
	}
}

// --- PCI configuration space: a function's 4 KiB of ECAM, kept ---

Config :: struct {
	id: u32, // segment << 16 | requester ID
	at: ^[4096]u8,
}

configs: [dynamic; 64]Config

@(private="file")
config_of :: proc "contextless" (pci: ^acpica.Pci_Id) -> ^[4096]u8 {
	id := u32(pci.segment) << 16 | u32(pci.bus) << 8 | u32(pci.device) << 3 | u32(pci.function)
	for c in configs {
		if c.id == id {
			return c.at
		}
	}
	st := vx.Status.Err_No_Memory
	at: u64
	if len(configs) < cap(configs) {
		vmo: vx.Handle
		vmo, st = ask(.Pci, u64(id), 4096)
		if st == .Ok {
			at, st = rt.as_map(rt.self, vmo, 0, 4096, {.Write})
			_ = rt.handle_close(vmo)
		}
	}
	if st != .Ok {
		said_once("PCI configuration for", u64(id), st)
		return nil
	}
	c := Config{id, cast(^[4096]u8)uintptr(at)}
	_ = append(&configs, c)
	return c.at
}

@(export, link_name = "AcpiOsReadPciConfiguration")
os_read_pci_configuration :: proc "c" (pci: ^acpica.Pci_Id, reg: u32, value: ^u64, width: u32) -> acpica.Status {
	c := u64(reg) + u64(width / 8) <= 4096 ? config_of(pci) : nil
	value^ = c != nil ? load(&c[reg], width) : ~u64(0)
	return c != nil ? .Ok : .Not_Exist
}

@(export, link_name = "AcpiOsWritePciConfiguration")
os_write_pci_configuration :: proc "c" (pci: ^acpica.Pci_Id, reg: u32, value: u64, width: u32) -> acpica.Status {
	c := u64(reg) + u64(width / 8) <= 4096 ? config_of(pci) : nil
	if c != nil {
		store(&c[reg], value, width)
	}
	return c != nil ? .Ok : .Not_Exist
}
