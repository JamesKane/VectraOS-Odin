package driver

import vx "abi:vx"

// What a clock driver tells devmgr (upstream's M5 step 7d, its ADR-0031).
// devmgr starts a driver whose record says clock with a channel ("devmgr");
// the driver writes one message, the time its hardware keeps, and devmgr sets
// the kernel's wall clock from it with the root Resource, which the driver
// does not hold. No reply.

CLOCK_REPORT :: u32(0x6b63_6c63) // "clck"

Clock_Report :: struct {
	header:    vx.Msg_Header,
	utc:       i64, // ns since 1970, read now
	monotonic: i64, // clock_read() when it was read: devmgr allows for the time since
}
#assert(size_of(Clock_Report) == 32)
#assert(offset_of(Clock_Report, utc) == 16)
#assert(offset_of(Clock_Report, monotonic) == 24)
