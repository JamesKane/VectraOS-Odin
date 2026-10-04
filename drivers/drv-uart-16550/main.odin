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

// The interrupts the IER enables.
Ier_Bit :: enum u8 {
	Rx, // data received
	Tx, // transmitter empty
}
Ier :: bit_set[Ier_Bit;u8]

LSR_DATA :: 0x01
LSR_THRE :: 0x20
IIR_NONE :: 0x01 // no interrupt pending
FIFO_SIZE :: 16

// The driver serves one port, so its state is here rather than behind
// driver.Cons's dev pointer, which the callbacks ignore.
base: u16
ier := Ier{.Rx}
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
	want := on ? Ier{.Rx, .Tx} : Ier{.Rx}
	if want != ier {
		ier = want
		rt.outb(base + IER, transmute(u8)ier)
	}
}

// Everything the port has pending, until the IIR says there is nothing left.
service :: proc "contextless" () {
	for _ in 0 ..< 64 {
		if rt.inb(base + IIR) & IIR_NONE != 0 {
			break
		}
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
	// Still pending after the rounds above: the edge-triggered line stays up,
	// so no new edge will come. Come back to it after the other work queued.
	if rt.inb(base + IIR) & IIR_NONE == 0 {
		again := vx.Packet{key = KEY_AGAIN}
		_ = rt.port_post(server.port, &again)
	}
}

// The packet service posts itself when it left something pending.
KEY_AGAIN :: p9ring.KEY_USER + 1

event :: proc "contextless" (ctx: rawptr, pk: ^vx.Packet) {
	if pk.key == KEY_AGAIN {
		service()
		return
	}
	if pk.trigger != .Irq {
		return
	}
	service()
	_ = rt.irq_ack(irq)
	_ = rt.port_bind(server.port, irq, .Irq, p9ring.KEY_USER)
}

// Maps io, the port's I/O range, whose first port the spawn message's
// ioport= record gives, and sets base to it.
@(require_results)
map_ports :: proc "contextless" (io: vx.Handle) -> bool {
	rec: ndb.Record
	rt.spawn_record("ioport", &rec) or_return
	port := ndb.get_u64(&rec, "ioport") or_return
	if port > 0xfff8 {
		return false
	}
	if _, st := rt.as_map(rt.self, io, 0, 0, {}); st != .Ok {
		return false
	}
	base = u16(port)
	return true
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	io := rt.spawn_take("ioport")
	irq = rt.spawn_take("irq")
	server.listen = rt.spawn_take("listen")
	if io == vx.HANDLE_NONE || irq == vx.HANDLE_NONE || server.listen == vx.HANDLE_NONE || !map_ports(io) {
		rt.print("drv-uart-16550: no port, IRQ or listen channel\n")
		return 1
	}

	rt.outb(base + IER, 0)
	rt.outb(base + FCR, 0xc7) // FIFOs on and cleared, interrupt at 14 bytes
	rt.outb(base + MCR, 0x0b) // DTR, RTS, and OUT2, which gates the IRQ on a PC
	rt.outb(base + IER, transmute(u8)ier)
	cons = {tx_room = tx_room, tx_byte = tx_byte, tx_wanted = tx_wanted}
	driver.cons_print_here(&cons)
	server.fs = driver.cons_fs(&cons)
	driver.cons_conns_for(&server) // a connection for every program with console output
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
