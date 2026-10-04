// drv-uart-16550: the PC serial port as the console.
//
// svcd gives it the port's I/O range and IRQ, minted from the root Resource
// by its manifest (boot/svc/cons.ndb), and the listen channel it posts as
// /srv/cons. It serves lib/driver's console over them; once it has the
// ports, the kernel writes to the port only to report a panic.
//
// The IRQ is an ISA line, edge-triggered: the kernel never masks it, so each
// interrupt is handled until the IIR says nothing is pending, which lowers
// the line for the next edge.
package uart16550

import vx "abi:vx"
import "vx:driver"
import "vx:ndb"
import "vx:p9ring"
import "vx:rt"

RBR :: 0
THR :: 0
IER :: 1
IIR :: 2
FCR :: 2
MCR :: 4
LSR :: 5
MSR :: 6

IER_RX :: 0x01 // data received
IER_TX :: 0x02 // transmitter empty
LSR_DATA :: 0x01
LSR_THRE :: 0x20
IIR_NONE :: 0x01 // no interrupt pending
FIFO_SIZE :: 16

base: u16
ier: u8 = IER_RX
irq: vx.Handle
cons: driver.Cons
server: p9ring.Server

tx_room :: proc "contextless" (dev: rawptr) -> u32 {
	return rt.inb(base + LSR) & LSR_THRE != 0 ? FIFO_SIZE : 0
}

tx_byte :: proc "contextless" (dev: rawptr, b: u8) {
	rt.outb(base + THR, b)
}

tx_wanted :: proc "contextless" (dev: rawptr, on: bool) {
	want := u8(on ? IER_RX | IER_TX : IER_RX)
	if want != ier {
		ier = want
		rt.outb(base + IER, ier)
	}
}

// Everything the port has pending, until the IIR says there is nothing left.
service :: proc "contextless" () {
	for rounds := 0; rounds < 64 && rt.inb(base + IIR) & IIR_NONE == 0; rounds += 1 {
		for rt.inb(base + LSR) & LSR_DATA != 0 {
			driver.cons_input(&cons, rt.inb(base + RBR))
		}
		_ = rt.inb(base + MSR) // modem-status interrupts clear on read
		driver.cons_pump(&cons) // and a transmitter-empty one, on writing or on reading the IIR
	}
	for rt.inb(base + LSR) & LSR_DATA != 0 {
		driver.cons_input(&cons, rt.inb(base + RBR))
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
	io := rt.spawn_take("ioport")
	irq = rt.spawn_take("irq")
	server.listen = rt.spawn_take("listen")
	rec: ndb.Record
	port: u64
	ok := io != 0 && irq != 0 && server.listen != 0 && rt.spawn_record("ioport", &rec)
	if ok {
		port, ok = ndb.get_u64(&rec, "ioport")
	}
	if ok {
		_, st := rt.as_map(rt.self, io, 0, 0, {})
		ok = port <= 0xfff8 && st == .Ok
	}
	if !ok {
		rt.print("drv-uart-16550: no port, IRQ or listen channel\n")
		return 1
	}
	base = u16(port)

	rt.outb(base + IER, 0)
	rt.outb(base + FCR, 0xc7) // FIFOs on and cleared, interrupt at 14 bytes
	rt.outb(base + MCR, 0x0b) // DTR, RTS, and OUT2, which gates the IRQ on a PC
	rt.outb(base + IER, ier)
	cons = {tx_room = tx_room, tx_byte = tx_byte, tx_wanted = tx_wanted}
	driver.cons_print_here(&cons)
	server.fs = driver.cons_fs(&cons)
	server.event = event
	pst: vx.Status
	server.port, pst = rt.port_create()
	if pst != .Ok || rt.port_bind(server.port, irq, .Irq, p9ring.KEY_USER) != .Ok {
		rt.print("drv-uart-16550: cannot wait for the IRQ\n")
		return 1
	}
	_ = rt.irq_ack(irq)
	service() // what arrived before the IRQ was ours
	rt.print("drv-uart-16550: serving /srv/cons\n")
	return int(p9ring.serve(&server))
}
