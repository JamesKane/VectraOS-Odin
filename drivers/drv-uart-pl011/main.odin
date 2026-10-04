// drv-uart-pl011: the arm PL011 UART as the console.
//
// svcd gives it the UART's registers (a physical VMO) and its IRQ, minted
// from the root Resource by its manifest (boot/svc/cons.ndb), and the listen
// channel it posts as /srv/cons. It serves lib/driver's console over them;
// once it has the registers, the kernel writes to the UART only to report a
// panic.
//
// The IRQ is a level-triggered SPI: the kernel masks it when it fires, and
// the driver clears the UART's interrupts before it acknowledges it.
package uartpl011

import "base:intrinsics"
import vx "abi:vx"
import "vx:driver"
import "vx:p9ring"
import "vx:rt"

// Registers, as u32 indices.
DR :: 0x00 / 4
FR :: 0x18 / 4
IMSC :: 0x38 / 4
MIS :: 0x40 / 4
ICR :: 0x44 / 4

FR_RXFE :: u32(1) << 4 // receive FIFO empty
FR_TXFF :: u32(1) << 5 // transmit FIFO full
FR_TXFE :: u32(1) << 7 // transmit FIFO empty
INT_RX :: u32(1) << 4
INT_TX :: u32(1) << 5
INT_RT :: u32(1) << 6 // receive timeout: bytes waiting below the FIFO level
INT_ALL :: u32(0x7ff)

// The driver serves one UART, so its state is here rather than behind
// driver.Cons's dev pointer, which the callbacks ignore.
regs: [^]u32
imsc: u32 = INT_RX | INT_RT
irq: vx.Handle
cons: driver.Cons
server: p9ring.Server

reg :: #force_inline proc "contextless" (i: int) -> u32 {
	return intrinsics.volatile_load(&regs[i])
}

set :: #force_inline proc "contextless" (i: int, v: u32) {
	intrinsics.volatile_store(&regs[i], v)
}

tx_room :: proc "contextless" (dev: rawptr) -> u32 {
	fr := reg(FR)
	if fr & FR_TXFE != 0 {
		return 16 // the FIFO holds 16
	}
	return fr & FR_TXFF != 0 ? 0 : 1
}

tx_byte :: proc "contextless" (dev: rawptr, b: u8) {
	set(DR, u32(b))
}

tx_wanted :: proc "contextless" (dev: rawptr, on: bool) {
	want := on ? imsc | INT_TX : imsc &~ INT_TX
	if want != imsc {
		imsc = want
		set(IMSC, imsc)
	}
}

service :: proc "contextless" () {
	set(ICR, reg(MIS))
	for reg(FR) & FR_RXFE == 0 {
		driver.cons_input(&cons, u8(reg(DR)))
	}
	driver.cons_pump(&cons)
}

event :: proc "contextless" (ctx: rawptr, pk: ^vx.Packet) {
	if pk.trigger != .Irq {
		return
	}
	service()
	_ = rt.irq_ack(irq)
	_ = rt.port_bind(server.port, irq, .Irq, p9ring.KEY_USER)
}

@(export, link_name="vx_main")
main :: proc() -> int {
	mmio := rt.spawn_take("mmio")
	irq = rt.spawn_take("irq")
	server.listen = rt.spawn_take("listen")
	at: u64
	st := vx.Status.Err_Invalid
	if mmio != vx.HANDLE_NONE && irq != vx.HANDLE_NONE && server.listen != vx.HANDLE_NONE {
		at, st = rt.as_map(rt.self, mmio, 0, 4096, {.Write})
	}
	if st != .Ok {
		rt.print("drv-uart-pl011: no registers, IRQ or listen channel\n")
		return 1
	}
	_ = rt.handle_close(mmio) // the mapping keeps it
	regs = cast([^]u32)uintptr(at)

	set(ICR, INT_ALL)
	set(IMSC, imsc)
	cons = {tx_room = tx_room, tx_byte = tx_byte, tx_wanted = tx_wanted}
	driver.cons_print_here(&cons)
	server.fs = driver.cons_fs(&cons)
	server.event = event
	pst: vx.Status
	server.port, pst = rt.port_create()
	if pst != .Ok || rt.port_bind(server.port, irq, .Irq, p9ring.KEY_USER) != .Ok {
		rt.print("drv-uart-pl011: cannot wait for the IRQ\n")
		return 1
	}
	_ = rt.irq_ack(irq)
	service()
	rt.print("drv-uart-pl011: serving /srv/cons\n")
	return int(p9ring.serve(&server))
}
