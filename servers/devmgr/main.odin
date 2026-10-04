// devmgr: the device manager. It finds the PCI functions, through the
// MCFG's ECAM regions, matches them against the drivers' manifests in
// /boot/drv/*.ndb, and starts each matched driver with only its device: the
// function's configuration space, its memory BARs, its MSIs and a DMA domain,
// minted from the root Resource; and the server end of the post the driver
// serves, which svcd gave devmgr (claim=). It restarts a driver that exits,
// up to a limit.
//
// A driver manifest:
//
//   match=pci vendor=0x1af4 device=0x1041 program=/boot/bin/drv-virtio-net post=ether0 msi=2
//
// svcd gives it the root Resource, the ACPI tables, a namespace with the boot
// image at /, and the claims. Configuration space is mapped one bus (1 MiB)
// at a time, as buses are found: the first in each region, then whatever
// bridges lead to.
package devmgr

import vx "abi:vx"
import "vx:acpi"
import "vx:memory"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:pci"
import "vx:procns"
import "vx:rt"
import "vx:str"

resource, port: vx.Handle
space: ns.Namespace

// A function found, for matching.
Function :: struct {
	fn:        pci.Function,
	config_pa: u64, // its 4 KiB of configuration space
	vendor:    u16,
	device:    u16,
}

functions: [dynamic; 64]Function
found: u64 // every function, those that do not fit `functions` too

BUS_SPACE :: 1 << 20 // a bus's configuration space: 32 devices of 8 functions

class_name :: proc "contextless" (c: u8) -> string {
	NAMES :: [?]string{"old", "storage", "net", "display", "media", "memory", "bridge", "comms", "system", "input", "dock", "cpu", "serial-bus"}
	names := NAMES
	return int(c) < len(names) ? names[c] : "other"
}

// v in `digits` lowercase hex digits, zero-padded.
print_hex :: proc "contextless" (v: u64, digits: int) {
	DIGITS := "0123456789abcdef"
	buf: [16]u8
	v := v
	for i := digits - 1; i >= 0; i -= 1 {
		buf[i] = DIGITS[v & 15]
		v >>= 4
	}
	rt.print(string(buf[:digits]))
}

// Maps a bus's configuration space; nil if it cannot.
map_bus :: proc "contextless" (e: ^acpi.Ecam, bus: u8) -> [^]u32 {
	vmo, st := rt.vmo_create_physical(resource, e.base + u64(bus) << 20, BUS_SPACE)
	if st != .Ok {
		return nil
	}
	defer rt.close_all(vmo) // the mapping keeps it
	at, mst := rt.as_map(rt.self, vmo, 0, BUS_SPACE, {.Write})
	return mst == .Ok ? cast([^]u32)uintptr(at) : nil
}

// Buses to scan: the first, and those bridges lead to. A worklist rather
// than recursion, since the device decides how deep the bridges go.
pending: [dynamic; 256]u8
seen_bus: [256]bool

// Whether BAR i is a 64-bit memory BAR, whose upper half is BAR i + 1.
bar_is_wide :: proc "contextless" (f: ^pci.Function, i: u32) -> bool {
	return pci.read32(f, 0x10 + 4 * i) & 7 == 4
}

scan_bus :: proc "contextless" (e: ^acpi.Ecam, bus: u8) {
	cfg := map_bus(e, bus)
	if cfg == nil {
		return
	}
	for dev in u8(0) ..< 32 {
		for fn in u8(0) ..< 8 {
			offset := u32(dev) << 15 | u32(fn) << 12
			f := pci.Function{cfg = cast(^[pci.CONFIG_SIZE / 4]u32)&cfg[offset / 4], bus = bus, dev = dev, fn = fn}
			vendor := pci.read16(&f, 0x00)
			if vendor == 0xffff {
				if fn == 0 {
					break // no device here
				}
				continue
			}
			class := pci.read32(&f, 0x08) >> 8
			header := pci.read8(&f, 0x0e)
			device := pci.read16(&f, 0x02)
			found += 1
			if header & 0x7f == 0 {
				_ = append(&functions, Function{fn = f, config_pa = e.base + (u64(bus) << 20 | u64(offset)), vendor = vendor, device = device}) // past 64, unmatched
			}
			rt.print("devmgr: ")
			print_hex(u64(bus), 2)
			rt.print(":")
			print_hex(u64(dev), 2)
			rt.print(".")
			print_hex(u64(fn), 1)
			rt.print(" ")
			print_hex(u64(vendor), 4)
			rt.print(":")
			print_hex(u64(device), 4)
			rt.print(" ", class_name(u8(class >> 16)))
			if pci.cap(&f, 0x11, 0) != 0 {
				rt.print(" msi-x")
			}
			for i := u32(0); header & 0x7f == 0 && i < 6; i += 1 {
				wide := bar_is_wide(&f, i)
				b := pci.bar_read(&f, i)
				if b.size != 0 {
					rt.print(" bar")
					print_hex(u64(i), 1)
					rt.print(b.io ? "=io:" : "=")
					if b.size >= 1024 {
						rt.print(b.size >> 10, "K")
					} else {
						rt.print(b.size)
					}
				}
				if wide {
					i += 1
				}
			}
			rt.print("\n")
			if header & 0x7f == 1 { // a bridge: the bus behind it
				secondary := pci.read8(&f, 0x19)
				if secondary > bus && secondary <= e.end_bus && !seen_bus[secondary] {
					seen_bus[secondary] = true
					_ = append(&pending, secondary) // each bus once: 256 at most
				}
			}
			if fn == 0 && header & 0x80 == 0 {
				break // a single-function device
			}
		}
	}
}

// --- Drivers ---

MAX_DRIVERS :: 16
MAX_STARTS :: 5
MAX_PROGRAM :: 63
MAX_POST :: 25

Driver :: struct {
	f:       ^Function, // a PCI function's; nil for an ACPI device's (acpi.odin)
	acpi:    acpi.Device, // an ACPI device's: what bus-acpi reported, its resources the grants
	clock:   bool, // it keeps time: given a channel to say it on
	report:  vx.Handle, // devmgr's end of that channel
	program: [dynamic; MAX_PROGRAM]u8,
	post:    [dynamic; MAX_POST]u8,
	msis:    u32,
	listen:  vx.Handle, // the post's server end; each start gets a duplicate
	bars:    [6]Range, // the memory BARs it was given: no one else's
	dma:     vx.Handle, // the function's DMA domain, which each start gets a duplicate of
	task:    vx.Handle,
	starts:  u32,
}

drivers: [dynamic; MAX_DRIVERS]Driver
image: [2 << 20]u8

say :: proc "contextless" (parts: ..rt.Print_Arg) {
	rt.print("devmgr: ")
	rt.print(..parts)
}

program_of :: proc "contextless" (d: ^Driver) -> string {
	return string(d.program[:])
}

// Reads a whole file through the namespace into buf; its length, or 0.
read_whole :: proc "contextless" (path: string, buf: []u8) -> int {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return 0
	}
	defer ns.close(&f)
	n, _ := ns.read_all(&f, buf)
	return n
}

// The handles a driver is given, in the spawn message's order, with their
// names there.
Grants :: struct {
	handles: [dynamic; vx.CHANNEL_MAX_HANDLES - 1]vx.Handle,
	names:   [dynamic; vx.CHANNEL_MAX_HANDLES - 1]string,
}

// Adds h, as `name`, if what made it (with status st) succeeded.
@(require_results)
grant :: proc "contextless" (g: ^Grants, name: string, h: vx.Handle, st: vx.Status) -> vx.Status {
	if st != .Ok {
		return st
	}
	if append(&g.handles, h) == 0 {
		_ = rt.handle_close(h)
		return .Err_Range
	}
	_ = append(&g.names, name)
	return .Ok
}

name_buf: [vx.CHANNEL_MAX_HANDLES][8]u8
records_buf: [4096]u8

// "bar1", "msi0": a prefix and a digit, in the name buffer of the handle about
// to be granted.
numbered :: proc "contextless" (g: ^Grants, prefix: string, n: u32) -> string {
	b := str.Buf{buf = name_buf[len(g.handles)][:]}
	str.write_string(&b, prefix)
	str.write_byte(&b, u8('0' + n))
	return str.to_string(&b)
}

// Starts (or starts again) a driver: makes its device objects, loads its
// program, and spawns it with them.
@(require_results)
start_driver :: proc "contextless" (index: int) -> vx.Status {
	d := &drivers[index]
	g: Grants
	given := false // to spawn_elf, which takes them whatever happens
	defer if !given {
		rt.close_all(..g.handles[:])
	}
	w := ndb.Writer{buf = records_buf[:]}
	if d.f != nil {
		grant(&g, "config", rt.vmo_create_physical(resource, d.f.config_pa, 4096)) or_return
		for i := u32(0); i < 6; i += 1 { // memory BARs, mapped whole
			wide := bar_is_wide(&d.f.fn, i)
			b := pci.bar_read(&d.f.fn, i)
			n := i
			if wide {
				i += 1
			}
			if b.size == 0 || b.io || b.base & 4095 != 0 {
				continue
			}
			size, _ := memory.page_round(b.size) // a BAR's size is a power of two in 64 bits
			grant(&g, numbered(&g, "bar", n), rt.vmo_create_physical(resource, b.base, size)) or_return
			d.bars[n] = {b.base, size}
			ndb.put_u64(&w, "bar", u64(n))
			ndb.put_u64(&w, "size", size)
			_ = ndb.end(&w)
		}
		for i in 0 ..< min(d.msis, 8) {
			h, msi, st := rt.irq_create_msi(resource, pci.rid(&d.f.fn))
			grant(&g, numbered(&g, "msi", i), h, st) or_return
			ndb.put_u64(&w, "msi", u64(i))
			ndb.put_u64(&w, "address", msi.address)
			ndb.put_u64(&w, "data", u64(msi.data))
			_ = ndb.end(&w)
		}
		// The function's DMA domain: devmgr's, kept across the driver's
		// restarts; the driver's duplicate only maps, and cannot revoke what
		// it mapped.
		if d.dma == vx.HANDLE_NONE {
			d.dma = rt.dma_domain_create(resource, pci.rid(&d.f.fn)) or_return
		}
		grant(&g, "dma", rt.handle_dup(d.dma, {.Map, .Wait, .Inspect, .Transfer})) or_return
	}
	acpi_grants(index, &g, &w) or_return
	if d.listen != vx.HANDLE_NONE {
		grant(&g, "listen", rt.handle_dup(d.listen, vx.RIGHTS_SAME)) or_return
	}
	if c := rt.console_connector(); c != vx.HANDLE_NONE {
		if h, st := rt.handle_dup(c, vx.RIGHTS_SAME); st == .Ok {
			_ = grant(&g, "console", h, st) // without one, it says nothing
		}
	}
	size := read_whole(program_of(d), image[:])
	if size == 0 {
		return .Err_Not_Found
	}
	if w.failed {
		return .Err_Range
	}
	program := program_of(d)
	base := program[str.last_index_byte(program, '/') + 1:]
	a := rt.Spawn_Args {
		name         = len(base) < 24 ? base : base[:23],
		image        = image[:size],
		handles      = g.handles[:],
		handle_names = g.names[:],
		records      = ndb.written(&w),
	}
	given = true
	d.task = rt.spawn_elf(&a) or_return
	rt.port_bind(port, d.task, .Exit, u64(index)) or_return
	d.starts += 1
	say("started ", base, "\n")
	return .Ok
}

driver_exited :: proc "contextless" (index: int) {
	d := &drivers[index]
	// The device may still hold addresses of the dead driver's DMA memory:
	// the domain keeps those pages (its mappings revoked, the ones whose
	// handles went with the driver kept) until the device cannot reach
	// memory at all, and only then lets them go.
	BUS_MASTER :: 1 << 2
	if d.f != nil { // a PCI function's; an ACPI device has no domain
		_, _ = rt.dma_domain_op(d.dma, .Revoke)
		command := pci.read16(&d.f.fn, 0x04)
		pci.write16(&d.f.fn, 0x04, command &~ BUS_MASTER)
		_ = pci.read16(&d.f.fn, 0x04) // the write has reached the device
		_, _ = rt.dma_domain_op(d.dma, .Quiesced)
	}
	_ = rt.handle_close(d.task)
	d.task = vx.HANDLE_NONE
	say(program_of(d), " exited\n")
	if d.starts >= MAX_STARTS {
		say(program_of(d), " keeps exiting; it is not started again\n")
		return
	}
	if start_driver(index) != .Ok {
		say("cannot restart ", program_of(d), "\n")
	}
}

// Starts a driver for each function this manifest record matches.
match_record :: proc "contextless" (rec: ^ndb.Record) {
	if bus, _ := ndb.get(rec, "match"); bus == "acpi" {
		keep_acpi_match(rec) // for bus-acpi's reports
		return
	}
	vendor, vok := ndb.get_u64(rec, "vendor")
	device, dok := ndb.get_u64(rec, "device")
	program, _ := ndb.get(rec, "program")
	post, _ := ndb.get(rec, "post")
	if !ndb.has(rec, "match") || !vok || !dok || program == "" || len(program) > MAX_PROGRAM || len(post) > MAX_POST {
		return
	}
	msis, _ := ndb.get_u64(rec, "msi")
	for &f in functions {
		if len(drivers) == MAX_DRIVERS {
			return
		}
		if u64(f.vendor) != vendor || u64(f.device) != device {
			continue
		}
		claim_buf: [len("claim:") + MAX_POST]u8
		claim, _ := str.join(claim_buf[:], "claim:", post)
		listen := rt.spawn_take(claim) // one device to a post: the first match takes it
		if listen == vx.HANDLE_NONE {
			say("no claim on /srv/", post, " for its driver\n")
			continue
		}
		d := Driver{f = &f, msis = u32(msis), listen = listen}
		_ = append(&d.program, program) // both fit: checked above
		_ = append(&d.post, post)
		_ = append(&drivers, d)
		if start_driver(len(drivers) - 1) != .Ok {
			say("cannot start ", program, "\n")
		}
	}
}

// Reads the driver manifests and starts a driver for each function one matches.
match_drivers :: proc "contextless" () {
	DIR :: "/boot/drv/"
	dir: ns.File
	if ns.open(&space, DIR[:len(DIR) - 1], p9.OREAD, &dir) != .Ok {
		return
	}
	defer ns.close(&dir)
	@(static) listing: [4096]u8
	@(static) text: [8192]u8
	@(static) scratch: [8192]u8
	for {
		n, _ := ns.read(&dir, listing[:])
		if n <= 0 {
			break
		}
		it := p9.Dir_Entries{buf = listing[:n]}
		for entry in p9.next_entry(&it) {
			path_buf: [96]u8
			path, ok := str.join(path_buf[:], DIR, entry.name)
			if !ok {
				continue
			}
			length := read_whole(path, text[:])
			r := ndb.Reader{src = string(text[:length]), scratch = scratch[:]}
			rec: ndb.Record
			for ndb.next(&r, &rec) == .Record {
				match_record(&rec)
			}
		}
	}
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	resource = rt.spawn_take("resource")
	tables := rt.spawn_take("acpi")
	rec: ndb.Record
	size: u64
	size_ok := false
	if rt.spawn_record("acpi", &rec) {
		size, size_ok = ndb.get_u64(&rec, "size")
	}
	padded, pok := memory.page_round(size)
	at: u64
	mst := vx.Status.Err_Invalid
	if resource != vx.HANDLE_NONE && tables != vx.HANDLE_NONE && size_ok && pok {
		at, mst = rt.as_map(rt.self, tables, 0, padded, {})
	}
	if mst != .Ok {
		rt.print("devmgr: FAILED: no Resource or ACPI tables\n")
		return 1
	}
	blob := (cast([^]u8)uintptr(at))[:size]
	mcfg, st := acpi.find(blob, "MCFG", 0)
	if st != .Ok {
		rt.print("devmgr: no MCFG, so no PCI\n")
		return 0
	}
	find_taken(blob)
	for n := 0; ; n += 1 {
		e, est := acpi.mcfg(mcfg, n)
		if est != .Ok {
			break
		}
		if e.segment != 0 {
			continue // other segments: when hardware has them
		}
		pci_window = e
		clear(&pending)
		seen_bus = {}
		seen_bus[e.start_bus] = true
		_ = append(&pending, e.start_bus)
		for len(pending) > 0 {
			bus := pending[len(pending) - 1]
			resize(&pending, len(pending) - 1)
			scan_bus(&e, bus)
		}
	}
	rt.print("devmgr: ", found, " PCI functions\n")

	pst: vx.Status
	port, pst = rt.port_create()
	if procns.from_spawn(&space) != .Ok || pst != .Ok {
		rt.print("devmgr: FAILED: no namespace, so no drivers\n")
		return 1
	}
	match_drivers()
	start_bus_acpi(tables, size)
	for { // drivers that exit are started again, up to a limit
		pk: [8]vx.Packet
		n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:n] {
			if p.trigger == .Exit && p.key < u64(len(drivers)) {
				driver_exited(int(p.key))
			}
			if p.key == KEY_MINT { // bus-acpi asks, or reports
				from_bus_acpi()
				_ = rt.port_bind(port, mint_end, .Readable, KEY_MINT)
			}
			if p.key &~ 0xffff == KEY_REPORT && p.key & 0xffff < u64(len(drivers)) {
				index := int(p.key & 0xffff)
				clock_report(index)
				if drivers[index].report != vx.HANDLE_NONE {
					_ = rt.port_bind(port, drivers[index].report, .Readable, p.key)
				}
			}
		}
	}
}
