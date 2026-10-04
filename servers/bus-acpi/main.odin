// bus-acpi: ACPI in user space (upstream's docs/01 §7.2 and ADR-0024; here
// ADR-0012). It runs ACPICA over the firmware's tables: the DSDT and SSDTs
// loaded, their AML run, and the devices present listed with their
// resources (M5 step 7a), each reported to devmgr, which starts a driver
// for a device a match=acpi record names, granted its resources (7d). The
// AML's operation regions, I/O ports and PCI configuration space are minted
// by devmgr on request (7b, regions.odin). It serves /srv/acpi, whose one
// request is power off: S5 through ACPICA, or PSCI through devmgr (7c).
//
// devmgr starts it with the kernel's copy of every table (`acpi`, one
// read-only VMO, each table after the last), the channel it asks devmgr on
// (`devmgr`), its post (`listen`) and the console. tables.odin lays the
// copies out for ACPICA; osl.odin is the rest of the OS layer ACPICA calls.
package bus_acpi

import vx "abi:vx"
import "acpica"
import "vx:acpi"
import "vx:memory"
import "vx:ndb"
import "vx:rt"
import "vx:str"

// --- The devices ---

devices, present: u64

@(private="file")
add_res :: proc "contextless" (d: ^acpi.Device, kind: acpi.Res_Kind, base, size: u64) {
	if d.count < acpi.MAX_RES {
		d.res[d.count] = {kind = kind, base = base, size = size}
		d.count += 1
	}
}

// One _CRS resource: said, and added to the device's report (ctx).
@(private="file")
print_resource :: proc "c" (r: ^acpica.Resource, ctx: rawptr) -> acpica.Status {
	d := cast(^acpi.Device)ctx
	#partial switch r.type {
	case .Io:
		io := r.data.io
		if io.address_length != 0 {
			rt.print(" io=0x")
			print_hex(u64(io.minimum))
			rt.print("/", u64(io.address_length))
			add_res(d, .Io, u64(io.minimum), u64(io.address_length))
		}
	case .Fixed_Io:
		io := r.data.fixed_io
		rt.print(" io=0x")
		print_hex(u64(io.address))
		rt.print("/", u64(io.address_length))
		add_res(d, .Io, u64(io.address), u64(io.address_length))
	case .Memory32:
		m := r.data.memory32
		rt.print(" mem=0x")
		print_hex(u64(m.minimum))
		rt.print("/0x")
		print_hex(u64(m.address_length))
		add_res(d, .Memory, u64(m.minimum), u64(m.address_length))
	case .Fixed_Memory32:
		m := r.data.fixed_memory32
		rt.print(" mem=0x")
		print_hex(u64(m.address))
		rt.print("/0x")
		print_hex(u64(m.address_length))
		add_res(d, .Memory, u64(m.address), u64(m.address_length))
	case .Irq: // the first line: a device with a choice of lines takes it
		irq := r.data.irq
		if irq.interrupt_count != 0 {
			rt.print(" irq=", u64(irq.interrupt))
			add_res(d, .Irq, u64(irq.interrupt), 1)
		}
	case .Extended_Irq:
		irq := r.data.extended_irq
		if irq.interrupt_count != 0 {
			rt.print(" irq=", u64(irq.interrupt))
			add_res(d, .Irq, u64(irq.interrupt), 1)
		}
	}
	return .Ok
}

// A device's _STA: present unless it says not (one without _STA is present).
@(private="file")
is_present :: proc "contextless" (dev: acpica.Handle) -> bool {
	obj: acpica.Object
	out := acpica.Buffer{length = size_of(obj), pointer = &obj}
	st := acpica.evaluate_object(dev, "_STA", nil, &out)
	if st == .Not_Found {
		return true
	}
	return st == .Ok && obj.type == .Integer && obj.integer.value & acpica.STA_DEVICE_PRESENT != 0
}

@(private="file")
print_device :: proc "c" (dev: acpica.Handle, depth: u32, ctx: rawptr, ret: ^rawptr) -> acpica.Status {
	devices += 1
	info: ^acpica.Device_Info
	if acpica.get_object_info(dev, &info) != .Ok {
		return .Ok
	}
	defer os_free(info)
	if !is_present(dev) || .Hid not_in info.valid {
		return .Ok
	}
	present += 1
	path_buf: [128]u8
	name := acpica.Buffer{length = len(path_buf), pointer = &path_buf}
	path := ""
	if acpica.get_name(dev, acpica.FULL_PATHNAME_NO_TRAILING, &name) == .Ok {
		path = str.from_nul_padded(path_buf[:])
	}
	hid := string(info.hardware_id.value)
	rt.print("bus-acpi: ", path, " ", hid)
	d := acpi.Device {
		header = {ordinal = acpi.DEVICE},
	}
	copy(d.hid[:len(d.hid) - 1], hid)
	copy(d.path[:len(d.path) - 1], path)
	_ = acpica.walk_resources(dev, acpica.METHOD_NAME__CRS, print_resource, &d)
	rt.print("\n")
	if devmgr != vx.HANDLE_NONE {
		_ = rt.channel_write(devmgr, memory.ptr_to_bytes(&d)) // devmgr matches it to a driver
	}
	return .Ok
}

// --- Power (M5 step 7c) ---

// The machine off: S5 through ACPICA where the firmware has it (_S5, and the
// fixed hardware's sleep registers); else, as on a hardware-reduced firmware
// with no sleep registers (QEMU's aarch64), PSCI, which devmgr asks the
// kernel for. Returns only if the machine is still on.
@(private="file")
power_off :: proc "contextless" () -> vx.Status {
	rt.print("bus-acpi: powering off\n")
	os_sleep(1000) // what the console has, out first: power off does not wait for it
	a, b: u8
	if !hardware_reduced() && acpica.get_sleep_type_data(acpica.STATE_S5, &a, &b) == .Ok {
		rt.print("bus-acpi: S5\n")
		if acpica.enter_sleep_state_prep(acpica.STATE_S5) == .Ok {
			_ = acpica.enter_sleep_state(acpica.STATE_S5)
		}
		rt.print("bus-acpi: S5 did not power off; PSCI then\n")
	}
	rt.print("bus-acpi: PSCI, through devmgr\n")
	h, st := ask(.Off, 0, 0)
	_ = rt.handle_close(h) // none comes with a reply
	return st == .Ok ? .Err_Io : st
}

// /srv/acpi: one request a message, by channel_call (vx:acpi's mint.odin).
@(private="file")
serve :: proc "contextless" (listen, port: vx.Handle) -> ! {
	for {
		_ = rt.port_bind(port, listen, .Readable, 1)
		pk: [1]vx.Packet
		if n, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:]); n != 1 {
			continue
		}
		for {
			req: vx.Msg_Header
			got, rst := rt.channel_read(listen, memory.ptr_to_bytes(&req))
			if rst != .Ok {
				break
			}
			st := vx.Status.Err_Invalid
			if got.bytes == size_of(req) && req.ordinal == acpi.POWER_OFF {
				st = power_off()
			}
			rep := vx.Msg_Header {
				txid    = req.txid,
				ordinal = req.ordinal,
				flags   = u32(i32(st)),
			}
			_ = rt.channel_write(listen, memory.ptr_to_bytes(&rep))
		}
	}
}

// bus-acpi.probe=1 on the command line: asks devmgr for what it must refuse
// (the interrupt controller's page, RAM, the console's ports) and says what
// it got (the acpi scenarios check it).
@(private="file")
probe :: proc "contextless" () {
	KEY :: "bus-acpi.probe=1"
	asked := false
	line := rt.spawn.cmdline
	for word in str.split_iterator(&line, ' ') {
		asked = asked || str.has_prefix(word, KEY)
	}
	if !asked {
		return
	}
	when ODIN_ARCH == .amd64 {
		CONTROLLER :: 0xfee0_0000 // the local APIC
		RAM :: 0x10_0000 // the first MiB past the BIOS's
	} else {
		CONTROLLER :: 0x0800_0000 // QEMU virt's GIC distributor
		RAM :: 0x4000_0000 // its RAM
	}
	said :: proc "contextless" (h: vx.Handle, st: vx.Status) -> string {
		_ = rt.handle_close(h)
		return st == .Ok ? "given" : "refused"
	}
	a := said(ask(.Memory, CONTROLLER, 4096))
	b := said(ask(.Memory, RAM, 4096))
	p := said(ask(.Io, 0x3f8, 8))
	rt.print("bus-acpi: probe: the interrupt controller ", a, ", RAM ", b, ", the console's ports ", p, "\n")
}

@(private="file")
fail :: proc "contextless" (what: string, st: acpica.Status) -> ! {
	rt.print("bus-acpi: FAILED: ", what, ": ", string(acpica.format_exception(st)), "\n")
	rt.exits(what)
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	tables := rt.spawn_take("acpi")
	devmgr = rt.spawn_take("devmgr")
	rec: ndb.Record
	size: u64
	size_ok := false
	if rt.spawn_record("acpi", &rec) {
		size, size_ok = ndb.get_u64(&rec, "size")
	}
	padded, pok := memory.page_round(size)
	if tables == vx.HANDLE_NONE || !size_ok || size == 0 || !pok {
		fail("no ACPI tables", .Not_Found)
	}
	at, st := rt.as_map(rt.self, tables, 0, padded, {})
	if st != .Ok {
		fail("no ACPI tables", .Not_Found)
	}
	heap_vmo, hst := rt.vmo_create(HEAP_BYTES)
	hat: u64
	if hst == .Ok {
		hat, hst = rt.as_map(rt.self, heap_vmo, 0, HEAP_BYTES, {.Write})
	}
	if hst != .Ok {
		fail("no memory", .No_Memory)
	}
	heap = (cast([^]u8)uintptr(hat))[:HEAP_BYTES]
	p := cast([^]u8)os_allocate(size)
	if p == nil {
		fail("no memory for the tables", .No_Memory)
	}
	copies = p[:size]
	copy(copies, (cast([^]u8)uintptr(at))[:size])
	if !lay_out_tables() {
		fail("malformed tables", .Bad_Data)
	}

	probe()
	if s := acpica.initialize_subsystem(); s != .Ok {
		fail("AcpiInitializeSubsystem", s)
	}
	if s := acpica.initialize_tables(nil, 32, false); s != .Ok {
		fail("AcpiInitializeTables", s)
	}
	if s := acpica.load_tables(); s != .Ok {
		fail("AcpiLoadTables", s)
	}
	// The hardware on too (ACPI mode, its fixed registers, its events), all
	// reached through devmgr's grants. Events are set up but not delivered:
	// there is no SCI handler yet.
	if s := acpica.enable_subsystem(acpica.FULL_INITIALIZATION); s != .Ok {
		fail("AcpiEnableSubsystem", s)
	}
	if s := acpica.initialize_objects(acpica.FULL_INITIALIZATION); s != .Ok {
		fail("AcpiInitializeObjects", s)
	}
	_ = acpica.get_devices(nil, print_device, nil, nil)
	rt.print("bus-acpi: ", devices, " devices, ", present, " present with a hardware ID; ", u64(heap_top) >> 10, " KiB of heap\n")

	port, _ := rt.port_create()
	if listen := rt.spawn_take("listen"); listen != vx.HANDLE_NONE {
		rt.print("bus-acpi: serving /srv/acpi\n")
		serve(listen, port)
	}
	for { // no post: nothing to serve
		pk: [1]vx.Packet
		_, _ = rt.port_wait(port, vx.INFINITE, 0, pk[:])
	}
}
