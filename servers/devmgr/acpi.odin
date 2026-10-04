package devmgr

// bus-acpi, and the drivers of the ACPI devices it reports (M5 step 7).
//
// devmgr starts bus-acpi (ACPICA in user space; ADR-0012) with a read-only
// duplicate of the tables, the console, its post (/srv/acpi, claim=acpi),
// and a channel. On that channel bus-acpi asks for what its AML first
// touches: memory, I/O ports, a PCI function's configuration space
// (upstream's ADR-0024 item 4). It gets each unless it is RAM (the kernel
// refuses that), the kernel's own (its interrupt controllers and IOMMU, as
// the tables place them; the PIC, the PIT and the console's ports), or a
// driver's; and each answer is said. It also asks for the machine off, where
// the firmware's ACPI cannot do it: devmgr makes the kernel's PSCI call
// (system_power, upstream's ADR-0031).
//
// bus-acpi reports each present device with its hardware ID and _CRS
// resources on the same channel. A device a match=acpi record names
//
//   match=acpi hid=PNP0B00 program=/boot/bin/drv-rtc-cmos clock
//
// gets its driver, granted exactly the device's resources (ADR-0024 item 3):
// an IoRange for each port range, a physical VMO for each memory range, an
// IRQ for each interrupt, unless one is the kernel's or another driver's.
// clock: the driver keeps time and says it on a channel of its own, and
// devmgr sets the kernel's wall clock from it (clock_set, ADR-0031).

import vx "abi:vx"
import "vx:acpi"
import "vx:driver"
import "vx:memory"
import "vx:ndb"
import "vx:rt"
import "vx:str"

KEY_MINT :: u64(1) << 32 // bus-acpi's channel
KEY_REPORT :: u64(1) << 33 // | the driver's index: its clock channel

Range :: struct {
	base, size: u64,
}

taken_memory: [dynamic; 32]Range
taken_io: [dynamic; 8]Range // ports: x86_64's alone
mint_end: vx.Handle // devmgr's end of bus-acpi's channel
pci_window: acpi.Ecam // segment 0's, for configuration space
century_reg: u8 // the FADT's CMOS century register, for clock drivers; 0 if none

// The match=acpi records, kept for bus-acpi's reports.
Acpi_Match :: struct {
	hid:     [dynamic; 15]u8,
	program: [dynamic; MAX_PROGRAM]u8,
	post:    [dynamic; MAX_POST]u8,
	clock:   bool,
}

acpi_matches: [dynamic; 8]Acpi_Match

@(private="file")
take :: proc "contextless" (list: ^[dynamic; $N]Range, base, size: u64) {
	if size != 0 {
		_ = append(list, Range{base, size}) // past the end, not taken: as upstream
	}
}

@(private="file")
overlaps :: proc "contextless" (list: []Range, base, size: u64) -> bool {
	for r in list {
		if base < r.base + r.size && r.base < base + size {
			return true
		}
	}
	return false
}

@(private="file")
le16 :: proc "contextless" (b: []u8) -> u64 {
	return u64(b[0]) | u64(b[1]) << 8
}

@(private="file")
le32 :: proc "contextless" (b: []u8) -> u64 {
	return le16(b) | le16(b[2:]) << 16
}

@(private="file")
le64 :: proc "contextless" (b: []u8) -> u64 {
	return le32(b) | le32(b[4:]) << 32
}

// The kernel's MMIO, as the MADT, DMAR and IORT place it, and on x86_64 the
// ports the kernel and the console use; and the FADT's century register.
find_taken :: proc "contextless" (tables: []u8) {
	if t, st := acpi.find(tables, "APIC", 0); st == .Ok && len(t) >= 44 {
		take(&taken_memory, le32(t[36:]) &~ 4095, 4096) // the local APIC
		for off := 44; off + 2 <= len(t) && t[off + 1] >= 2 && off + int(t[off + 1]) <= len(t); off += int(t[off + 1]) {
			e := t[off:][:t[off + 1]]
			switch {
			case e[0] == 1 && len(e) >= 12:
				take(&taken_memory, le32(e[4:]), 4096) // an IOAPIC
			case e[0] == 5 && len(e) >= 12:
				take(&taken_memory, le64(e[4:]), 4096) // the local APIC, moved
			case e[0] == 0xc && len(e) >= 24:
				take(&taken_memory, le64(e[8:]), 0x1_0000) // the GIC distributor
			case e[0] == 0xe && len(e) >= 16:
				take(&taken_memory, le64(e[4:]), le32(e[12:])) // GIC redistributors
			case e[0] == 0xf && len(e) >= 20:
				take(&taken_memory, le64(e[8:]), 0x2_0000) // an ITS
			}
		}
	}
	if t, st := acpi.find(tables, "DMAR", 0); st == .Ok {
		for off := 48; off + 16 <= len(t); {
			length := int(le16(t[off + 2:]))
			if length < 4 || off + length > len(t) {
				break
			}
			if t[off] == 0 && t[off + 1] == 0 { // a remapping unit's registers
				take(&taken_memory, le64(t[off + 8:]), 4096 << (t[off + 5] & 0xf))
			}
			off += length
		}
	}
	if t, st := acpi.find(tables, "IORT", 0); st == .Ok && len(t) >= 44 {
		at := int(le32(t[40:]))
		for i := u64(0); i < le32(t[36:]) && at >= 0 && at + 24 <= len(t); i += 1 {
			length := int(le16(t[at + 1:]))
			if length < 16 || at + length > len(t) {
				break
			}
			if t[at] == 4 {
				take(&taken_memory, le64(t[at + 16:]), 0x2_0000) // an SMMUv3
			}
			at += length
		}
	}
	when ODIN_ARCH == .amd64 {
		take(&taken_io, 0x20, 2) // the PIC
		take(&taken_io, 0xa0, 2)
		take(&taken_io, 0x40, 4) // the PIT
		take(&taken_io, 0x3f8, 8) // the console's UART (boot/svc/cons.ndb)
	}
	if f, st := acpi.find(tables, "FACP", 0); st == .Ok && len(f) > 108 {
		century_reg = f[108]
	}
}

// Whether [base, base + size) of memory (or, with kind .Io, of ports) is a
// driver's: a PCI function's BARs, an ACPI device's grants.
@(private="file")
a_drivers :: proc "contextless" (kind: acpi.Res_Kind, base, size: u64) -> bool {
	for &d in drivers {
		if kind == .Memory && overlaps(d.bars[:], base, size) {
			return true
		}
		for g in d.acpi.res[:min(d.acpi.count, acpi.MAX_RES)] {
			if g.kind == kind && base < g.base + g.size && g.base < base + size {
				return true
			}
		}
	}
	return false
}

@(private="file")
say_mint :: proc "contextless" (m: ^acpi.Mint, st: vx.Status) {
	KINDS := [?]string{"?", "memory", "I/O ports", "PCI configuration"}
	rt.print("devmgr: bus-acpi ", st == .Ok ? "gets " : "refused ", KINDS[u32(m.kind) <= 3 ? u32(m.kind) : 0], " 0x")
	digits := 1
	for digits < 16 && m.base >> (4 * uint(digits)) != 0 {
		digits += 1
	}
	print_hex(m.base, digits)
	rt.print("/", m.size, "\n")
}

// One request on bus-acpi's channel, answered.
@(private="file")
answer_mint :: proc "contextless" (m: ^acpi.Mint, bytes: u32) {
	h := vx.HANDLE_NONE
	st := vx.Status.Err_Invalid
	if bytes == size_of(acpi.Mint) && m.header.ordinal == acpi.MINT {
		#partial switch m.kind {
		case .Memory:
			switch {
			case (m.base | m.size) & 4095 != 0 || m.size == 0 || m.size > 1 << 30:
				st = .Err_Invalid
			case overlaps(taken_memory[:], m.base, m.size) || a_drivers(.Memory, m.base, m.size):
				st = .Err_Access
			case:
				h, st = rt.vmo_create_physical(resource, m.base, m.size) // RAM: the kernel's refusal
			}
		case .Io:
			when ODIN_ARCH == .amd64 {
				switch {
				case m.size == 0 || m.base + m.size > 0x1_0000:
					st = .Err_Range
				case overlaps(taken_io[:], m.base, m.size) || a_drivers(.Io, m.base, m.size):
					st = .Err_Access
				case:
					h, st = rt.iorange_create(resource, u16(m.base), u32(m.size))
				}
			} else {
				st = .Err_Unsupported // no I/O ports here
			}
		case .Off:
			say("powering off", " (PSCI)", "\n")
			st = rt.system_power(resource, .Off) // returns only if it did not happen
		case .Pci:
			bus := m.base >> 8 & 0xff
			if m.base >> 16 != 0 || m.size != 4096 || pci_window.base == 0 || bus < u64(pci_window.start_bus) || bus > u64(pci_window.end_bus) {
				st = .Err_Range
			} else {
				h, st = rt.vmo_create_physical(resource, pci_window.base + (m.base & 0xffff) << 12, 4096)
			}
		}
		say_mint(m, st)
	}
	rep := vx.Msg_Header {
		txid    = m.header.txid,
		ordinal = acpi.MINT,
		flags   = u32(i32(st)),
	}
	given := [1]vx.Handle{h}
	handles := given[:h != vx.HANDLE_NONE ? 1 : 0]
	if rt.channel_write(mint_end, memory.ptr_to_bytes(&rep), handles) != .Ok && h != vx.HANDLE_NONE {
		_ = rt.handle_close(h)
	}
}

// What is waiting on bus-acpi's channel: its requests answered, its devices
// matched.
from_bus_acpi :: proc "contextless" () {
	@(static) u: struct #raw_union {
		header: vx.Msg_Header,
		m: acpi.Mint,
		d: acpi.Device,
	}
	for {
		got, st := rt.channel_read(mint_end, memory.ptr_to_bytes(&u))
		if st != .Ok {
			break
		}
		if got.bytes == size_of(acpi.Device) && u.header.ordinal == acpi.DEVICE {
			acpi_device(&u.d)
		} else {
			answer_mint(&u.m, got.bytes)
		}
	}
}

// A match=acpi record, kept for bus-acpi's reports.
keep_acpi_match :: proc "contextless" (rec: ^ndb.Record) {
	hid, _ := ndb.get(rec, "hid")
	program, _ := ndb.get(rec, "program")
	post, _ := ndb.get(rec, "post")
	if hid == "" || len(hid) >= 16 || program == "" || len(program) > MAX_PROGRAM || len(post) > MAX_POST {
		return
	}
	m := Acpi_Match {
		clock = ndb.has(rec, "clock"),
	}
	_ = append(&m.hid, hid) // all fit: checked above
	_ = append(&m.program, program)
	_ = append(&m.post, post)
	_ = append(&acpi_matches, m) // past 8, ignored
}

// An ACPI device bus-acpi found: started with its driver, if a match=acpi
// record names its hardware ID, granted its _CRS resources, unless one of
// them is the kernel's or another driver's.
@(private="file")
acpi_device :: proc "contextless" (dev: ^acpi.Device) {
	hid := str.from_nul_padded(dev.hid[:15])
	m: ^Acpi_Match
	for &a in acpi_matches {
		if string(a.hid[:]) == hid {
			m = &a
			break
		}
	}
	if m == nil || dev.count > acpi.MAX_RES || len(drivers) == MAX_DRIVERS {
		return
	}
	for r in dev.res[:dev.count] {
		taken := r.kind == .Memory && overlaps(taken_memory[:], r.base, r.size)
		when ODIN_ARCH == .amd64 {
			taken = taken || (r.kind == .Io && overlaps(taken_io[:], r.base, r.size))
		}
		if taken || (r.kind != .Irq && a_drivers(r.kind, r.base, r.size)) {
			say("not starting ", string(m.program[:]), ": a resource is the kernel's or a driver's\n")
			return
		}
	}
	// Its slot is taken even if its post's claim is missing, as upstream's is:
	// its resources are then no one else's.
	_ = append(&drivers, Driver{acpi = dev^, clock = m.clock})
	d := &drivers[len(drivers) - 1]
	d.acpi.hid[15] = 0
	d.acpi.path[47] = 0
	_ = append(&d.program, string(m.program[:]))
	_ = append(&d.post, string(m.post[:]))
	if len(d.post) != 0 {
		claim_buf: [len("claim:") + MAX_POST]u8
		claim, _ := str.join(claim_buf[:], "claim:", string(d.post[:]))
		d.listen = rt.spawn_take(claim)
		if d.listen == vx.HANDLE_NONE {
			say("no claim on /srv/", string(d.post[:]), " for its driver\n")
			return
		}
	}
	say(str.from_nul_padded(d.acpi.path[:]), " ", hid, ": ", string(d.program[:]), "\n")
	if start_driver(len(drivers) - 1) != .Ok {
		say("cannot start ", string(d.program[:]), "\n")
	}
}

// An ACPI device's grants, when its driver starts: its resources (io0, mem0,
// irq0, ..., each with a record, io=0 base=0x70 size=8, saying which range it
// is), the FADT's century register for a clock, and a clock's channel.
@(require_results)
acpi_grants :: proc "contextless" (index: int, g: ^Grants, w: ^ndb.Writer) -> vx.Status {
	d := &drivers[index]
	if d.f == nil {
		nth: [acpi.Res_Kind]u32
		for r in d.acpi.res[:min(d.acpi.count, acpi.MAX_RES)] {
			h := vx.HANDLE_NONE
			st: vx.Status
			kind := "irq"
			#partial switch r.kind {
			case .Io:
				kind = "io"
				when ODIN_ARCH == .amd64 {
					h, st = rt.iorange_create(resource, u16(r.base), u32(r.size))
				} else {
					st = .Err_Unsupported
				}
			case .Memory:
				kind = "mem"
				base := r.base &~ 4095
				end, _ := memory.page_round(r.base + r.size)
				h, st = rt.vmo_create_physical(resource, base, end - base)
			case:
				h, st = rt.irq_create(resource, u32(r.base))
			}
			slot := r.kind == .Io || r.kind == .Memory ? r.kind : .Irq // anything else is an interrupt, as above
			k := nth[slot]
			nth[slot] += 1
			grant(g, numbered(g, kind, k), h, st) or_return
			ndb.put_u64(w, kind, u64(k))
			ndb.put_u64(w, "base", r.base)
			ndb.put_u64(w, "size", r.size)
			_ = ndb.end(w)
		}
		if d.clock && century_reg != 0 {
			ndb.flag(w, "fadt")
			ndb.put_u64(w, "century", u64(century_reg))
			_ = ndb.end(w)
		}
	}
	if d.clock { // a channel to say the time on
		mine, theirs := rt.channel_create() or_return
		if d.report != vx.HANDLE_NONE {
			_ = rt.handle_close(d.report)
		}
		d.report = mine
		grant(g, "devmgr", theirs, .Ok) or_return
		_ = rt.port_bind(port, d.report, .Readable, KEY_REPORT | u64(index))
	}
	return .Ok
}

// Days since 1970-01-01 as a civil date (Howard Hinnant's civil_from_days).
@(private="file")
civil :: proc "contextless" (since_1970: i64) -> (y: i64, m, d: u32) {
	days := since_1970 + 719468
	era := (days >= 0 ? days : days - 146096) / 146097
	doe := u32(days - era * 146097)
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = doy - (153 * mp + 2) / 5 + 1
	m = mp < 10 ? mp + 3 : mp - 9
	y = i64(yoe) + era * 400 + (m <= 2 ? 1 : 0)
	return
}

// v's last two decimal digits, then sep unless it is 0.
@(private="file")
two :: proc "contextless" (v: u64, sep: u8) {
	b := [3]u8{u8('0' + v / 10 % 10), u8('0' + v % 10), sep}
	rt.print(string(b[:sep != 0 ? 3 : 2]))
}

// A clock driver's time: the kernel's wall clock, set from it.
clock_report :: proc "contextless" (index: int) {
	d := &drivers[index]
	for {
		r: driver.Clock_Report
		got, st := rt.channel_read(d.report, memory.ptr_to_bytes(&r))
		if st != .Ok {
			break
		}
		if got.bytes != size_of(r) || r.header.ordinal != driver.CLOCK_REPORT || r.utc <= 0 {
			continue
		}
		utc := r.utc + (i64(rt.clock_read()) - r.monotonic) // the time since it was read
		if rt.clock_set(resource, utc) != .Ok {
			continue
		}
		secs := utc / 1_000_000_000
		y, mo, da := civil(secs / 86400)
		rt.print("devmgr: the wall clock is ", u64(y), "-")
		two(u64(mo), '-')
		two(u64(da), ' ')
		two(u64(secs % 86400 / 3600), ':')
		two(u64(secs % 3600 / 60), ':')
		two(u64(secs % 60), 0)
		rt.print(" UTC, from ", string(d.program[:]), "\n")
	}
}

// bus-acpi: ACPICA over the tables, given a read-only duplicate of them,
// the console, its post, and the channel it asks devmgr on. Started once;
// restarts come with its service (upstream's M5 step 7).
start_bus_acpi :: proc "contextless" (tables: vx.Handle, size: u64) {
	g: Grants
	given := false // to spawn_elf, which takes them whatever happens
	defer if !given {
		rt.close_all(..g.handles[:])
	}
	@(static) records: [1024]u8
	w := ndb.Writer{buf = records[:]}
	ndb.flag(&w, "acpi")
	ndb.put_u64(&w, "size", size)
	_ = ndb.end(&w)
	if rt.spawn.cmdline != "" { // its options: bus-acpi.KEY=VALUE words
		ndb.put(&w, "cmdline", rt.spawn.cmdline)
		_ = ndb.end(&w)
	}
	st := grant(&g, "acpi", rt.handle_dup(tables, {.Read, .Map, .Transfer}))
	if st == .Ok {
		mine, theirs, cst := rt.channel_create()
		st = cst
		if st == .Ok {
			mint_end = mine
			st = grant(&g, "devmgr", theirs, .Ok)
			_ = rt.port_bind(port, mint_end, .Readable, KEY_MINT)
		}
	}
	if post := rt.spawn_take("claim:acpi"); st == .Ok && post != vx.HANDLE_NONE { // /srv/acpi, bus-acpi's to serve
		st = grant(&g, "listen", post, .Ok)
	}
	if c := rt.console_connector(); st == .Ok && c != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(c, vx.RIGHTS_SAME); dst == .Ok {
			_ = grant(&g, "console", h, dst)
		}
	}
	length := st == .Ok ? read_whole("/boot/bin/bus-acpi", image[:]) : 0
	if st != .Ok || length == 0 || w.failed {
		say("cannot start ", "bus-acpi", "\n")
		return
	}
	a := rt.Spawn_Args {
		name         = "bus-acpi",
		image        = image[:length],
		handles      = g.handles[:],
		handle_names = g.names[:],
		records      = ndb.written(&w),
	}
	given = true
	task, sst := rt.spawn_elf(&a)
	if sst != .Ok {
		say("cannot start ", "bus-acpi", "\n")
		return
	}
	_ = rt.handle_close(task)
	say("started ", "bus-acpi", "\n")
}
