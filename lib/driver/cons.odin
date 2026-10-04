// vx:driver, what user-space drivers share. cons.odin: the console file
// server that serial drivers share (the serial class). The driver supplies
// the device: how much it can take now, how to send a byte, and whether to
// interrupt when it can take more; it feeds cons the bytes that arrive, and
// pumps output from its interrupt handler.
//
// The tree is one file, /cons. Reads are cooked, as Plan 9's cons is: typed
// bytes are echoed and gathered into a line, with backspace (BS or DEL) and
// kill-line (^U), and a read returns at most one line, once it is ended (by
// return) or sent (^D). ^D on an empty line makes one read return 0, the end
// of the file. Writes go out with each newline as CR LF. A read with nothing
// typed, or a write with no room, waits (p9.serve's .Defer) until the driver's next
// interrupt makes progress.
package driver

import vx "abi:vx"
import "vx:p9"
import "vx:rt"

Cons :: struct {
	dev:       rawptr,
	tx_room:   proc "contextless" (dev: rawptr) -> u32, // bytes the device can take now
	tx_byte:   proc "contextless" (dev: rawptr, b: u8), // one of them
	tx_wanted: proc "contextless" (dev: rawptr, on: bool), // interrupt when it can take more
	out:       Byte_Queue(8192), // output not yet sent
	input:     Byte_Queue(4096), // finished lines, for reads
	line:      [256]u8, // the line being typed
	line_len:  u32,
	eofs:      u32, // ^D on an empty line: reads that return 0
}

// A ring of bytes with free-running indices: N must be a power of two, so
// the indices may wrap.
Byte_Queue :: struct($N: u32) where N & (N - 1) == 0 {
	data:       [N]u8,
	head, tail: u32,
}

@(private="file")
room :: proc "contextless" (q: ^Byte_Queue($N)) -> u32 {
	return N - (q.tail - q.head)
}

@(private="file")
is_empty :: proc "contextless" (q: ^Byte_Queue($N)) -> bool {
	return q.head == q.tail
}

// Adds b, or drops it if the queue is full.
@(private="file")
push :: proc "contextless" (q: ^Byte_Queue($N), b: u8) {
	if room(q) > 0 {
		q.data[q.tail % N] = b
		q.tail += 1
	}
}

// The oldest byte, which the queue must hold.
@(private="file")
pop :: proc "contextless" (q: ^Byte_Queue($N)) -> u8 {
	b := q.data[q.head % N]
	q.head += 1
	return b
}

@(private="file")
ROOT :: p9.Node(1)
@(private="file")
FILE :: p9.Node(2)

// Sends what the device will take, and asks for an interrupt if more is waiting.
cons_pump :: proc "contextless" (c: ^Cons) {
	for n := c.tx_room(c.dev); n > 0 && !is_empty(&c.out); n -= 1 {
		c.tx_byte(c.dev, pop(&c.out))
	}
	c.tx_wanted(c.dev, !is_empty(&c.out))
}

@(private="file")
echo :: proc "contextless" (c: ^Cons, b: u8) {
	if b == '\n' {
		push(&c.out, '\r')
	}
	push(&c.out, b)
}

@(private="file")
erase :: proc "contextless" (c: ^Cons) {
	push(&c.out, '\b')
	push(&c.out, ' ')
	push(&c.out, '\b')
}

// Moves the typed line to the input, as much of it as fits.
@(private="file")
finish_line :: proc "contextless" (c: ^Cons) {
	for b in c.line[:c.line_len] {
		push(&c.input, b)
	}
	c.line_len = 0
}

// A byte from the device, through the line discipline.
cons_input :: proc "contextless" (c: ^Cons, byte: u8) {
	b := byte == '\r' ? '\n' : byte
	switch {
	case b == 0x08 || b == 0x7f: // erase
		if c.line_len > 0 {
			c.line_len -= 1
			erase(c)
		}
	case b == 0x15: // ^U: kill the line
		for ; c.line_len > 0; c.line_len -= 1 {
			erase(c)
		}
	case b == 0x04: // ^D: send the line, or end the file
		if c.line_len > 0 {
			finish_line(c)
		} else {
			c.eofs += 1
		}
	case b == '\n' || b >= 0x20 || b == '\t':
		if c.line_len < len(c.line) - 1 || b == '\n' { // a full line keeps room for its newline
			c.line[c.line_len] = b
			c.line_len += 1
			echo(c, b)
		}
		if b == '\n' {
			finish_line(c)
		}
	}
}

// --- The file system ---

@(private="file")
attach :: proc "contextless" (ctx: rawptr, aname: string) -> (p9.Node, vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return ROOT, .Ok
}

@(private="file")
walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (p9.Node, vx.Status) {
	if dir != ROOT || name != "cons" {
		return 0, .Err_Not_Found
	}
	return FILE, .Ok
}

@(private="file")
parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (p9.Node, vx.Status) {
	return ROOT, .Ok
}

@(private="file")
stat :: proc "contextless" (ctx: rawptr, node: p9.Node, s: ^p9.Stat) -> vx.Status {
	dir := node == ROOT
	s^ = {
		qid  = {dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = dir ? p9.DMDIR | 0o555 : 0o666,
		name = dir ? "/" : "cons",
		uid  = "cons",
		gid  = "cons",
		muid = "cons",
	}
	return .Ok
}

@(private="file")
open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	return mode.trunc || mode.rclose ? .Err_Access : .Ok
}

@(private="file")
read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (u32, vx.Status) {
	c := (^Cons)(ctx) // a stream: offsets mean nothing
	if is_empty(&c.input) {
		if c.eofs == 0 {
			return 0, .Err_Should_Wait
		}
		c.eofs -= 1
		return 0, .Ok
	}
	n := 0
	for n < len(buf) && !is_empty(&c.input) {
		b := pop(&c.input)
		buf[n] = b
		n += 1
		if b == '\n' {
			break // one line at a time
		}
	}
	return u32(n), .Ok
}

@(private="file")
write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (u32, vx.Status) {
	c := (^Cons)(ctx)
	n := 0
	for n < len(data) && room(&c.out) >= 2 { // room for a newline's CR LF
		echo(c, data[n])
		n += 1
	}
	cons_pump(c)
	if n == 0 && len(data) > 0 {
		return 0, .Err_Should_Wait
	}
	return u32(n), .Ok
}

@(private="file")
readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (p9.Node, vx.Status) {
	if index != 0 {
		return 0, .Err_Not_Found
	}
	return FILE, .Ok
}

// The file server for a console, to put in a p9ring.Server.
cons_fs :: proc "contextless" (c: ^Cons) -> p9.Fs {
	return p9.Fs{ctx = c, attach = attach, walk = walk, parent = parent, stat = stat, open = open, read = read, readdir = readdir, write = write}
}

// The driver's own output goes straight to its device's queue.
@(private="file")
cons_self: ^Cons

@(private="file")
print_self :: proc "contextless" (s: string) {
	for b in transmute([]u8)s {
		echo(cons_self, b)
	}
	cons_pump(cons_self)
}

cons_print_here :: proc "contextless" (c: ^Cons) {
	cons_self = c
	rt.print_hook = print_self
}
