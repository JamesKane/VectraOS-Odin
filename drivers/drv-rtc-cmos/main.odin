// drv-rtc-cmos: the PC's CMOS real-time clock (PNP0B00), the first driver
// started from an ACPI device (M5 step 7d). devmgr gives it exactly the
// device's _CRS resources, as bus-acpi reported them: the ports (io0, at
// least the index and data ports 0x70 and 0x71) and the interrupt (irq0,
// unused so far); and a channel ("devmgr") to say the time on. It reads the
// clock once, says it, and devmgr sets the kernel's wall clock from it
// (upstream's ADR-0031). The clock is taken to keep UTC.
//
// The FADT's century register, if it names one, comes as a record
// (fadt century=0x32); without one the century is the 21st.
package rtccmos

import vx "abi:vx"
import "vx:driver"
import "vx:memory"
import "vx:ndb"
import "vx:rt"

// The registers.
SECONDS :: 0x0
MINUTES :: 0x2
HOURS :: 0x4
DAY :: 0x7
MONTH :: 0x8
YEAR :: 0x9
STATUS_A :: 0xa
STATUS_B :: 0xb

A_UPDATING :: 0x80 // an update is under way: the time registers are changing
B_24HOUR :: 0x02
B_BINARY :: 0x04 // binary, not BCD
HOUR_PM :: 0x80 // in 12-hour mode

index_port: u16 // the first of io0's ports; data is the next

cmos :: proc "contextless" (reg: u8) -> u8 {
	rt.outb(index_port, reg) // bit 7 clear: NMIs stay on
	return rt.inb(index_port + 1)
}

Field :: enum {
	Seconds,
	Minutes,
	Hours,
	Day,
	Month,
	Year,
	Century,
}

Reading :: [Field]u8

read_once :: proc "contextless" (century_reg: u8) -> (t: Reading) {
	for spin := 0; spin < 1_000_000 && cmos(STATUS_A) & A_UPDATING != 0; spin += 1 {}
	t[.Seconds] = cmos(SECONDS)
	t[.Minutes] = cmos(MINUTES)
	t[.Hours] = cmos(HOURS)
	t[.Day] = cmos(DAY)
	t[.Month] = cmos(MONTH)
	t[.Year] = cmos(YEAR)
	t[.Century] = century_reg != 0 ? cmos(century_reg) : 0
	return
}

bcd :: proc "contextless" (v: u8, binary: bool) -> u32 {
	return binary ? u32(v) : u32(v >> 4) * 10 + u32(v & 15)
}

// Days from 1970-01-01 to a civil date (Howard Hinnant's days_from_civil).
days_from_civil :: proc "contextless" (year: i64, m, d: u32) -> i64 {
	y := year - (m <= 2 ? 1 : 0)
	era := (y >= 0 ? y : y - 399) / 400
	yoe := u32(y - era * 400)
	doy := (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + i64(doe) - 719468
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	io := rt.spawn_take("io0")
	devmgr := rt.spawn_take("devmgr")
	rec: ndb.Record
	if io == vx.HANDLE_NONE || devmgr == vx.HANDLE_NONE || !rt.spawn_record("io", &rec) {
		return "no CMOS ports"
	}
	base, bok := ndb.get_u64(&rec, "base")
	size, sok := ndb.get_u64(&rec, "size")
	if !bok || !sok || size < 2 || base > 0xfffe {
		return "no CMOS ports"
	}
	if _, st := rt.as_map(rt.self, io, 0, 0, {}); st != .Ok {
		return "cannot use the CMOS ports"
	}
	century_reg: u64
	if rt.spawn_record("fadt", &rec) {
		century_reg, _ = ndb.get_u64(&rec, "century")
	}
	if century_reg > 0x7f {
		century_reg = 0
	}
	index_port = u16(base)

	// Read until two readings agree: an update between the check and the
	// reads would leave a mix of two seconds.
	a := read_once(u8(century_reg))
	for _ in 0 ..< 10 {
		b := read_once(u8(century_reg))
		if a == b {
			break
		}
		a = b
	}
	now := rt.clock_read()
	status := cmos(STATUS_B)
	binary := status & B_BINARY != 0
	sec := bcd(a[.Seconds], binary)
	min_ := bcd(a[.Minutes], binary)
	hour := bcd(a[.Hours] & 0x7f, binary)
	day := bcd(a[.Day], binary)
	month := bcd(a[.Month], binary)
	year := bcd(a[.Year], binary)
	if status & B_24HOUR == 0 {
		hour = hour % 12 + (a[.Hours] & HOUR_PM != 0 ? 12 : 0)
	}
	century := a[.Century] != 0 ? bcd(a[.Century], binary) : 20
	if sec > 59 || min_ > 59 || hour > 23 || day == 0 || day > 31 || month == 0 || month > 12 || year > 99 || century > 99 {
		return "the clock's registers make no time"
	}
	secs := days_from_civil(i64(century) * 100 + i64(year), month, day) * 86400 + i64(hour) * 3600 + i64(min_) * 60 + i64(sec)

	rep := driver.Clock_Report {
		header    = {ordinal = driver.CLOCK_REPORT},
		utc       = secs * 1_000_000_000,
		monotonic = i64(now),
	}
	if rt.channel_write(devmgr, memory.ptr_to_bytes(&rep)) != .Ok {
		return "cannot tell devmgr the time"
	}
	rt.print("drv-rtc-cmos: the clock says ", u64(secs), " s since 1970\n")

	// Kept running, holding the clock's ports: setting it, and its alarms,
	// come with their first users.
	port, _ := rt.port_create()
	for {
		pk: [1]vx.Packet
		_, _ = rt.port_wait(port, vx.INFINITE, 0, pk[:])
	}
}
