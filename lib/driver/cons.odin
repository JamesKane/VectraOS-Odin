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
// typed, or a write with no room, waits (p9.DEFER) until the driver's next
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
	out:       [8192]u8, // output not yet sent; free-running indices
	out_head:  u32,
	out_tail:  u32,
	input:     [4096]u8, // finished lines, for reads
	in_head:   u32,
	in_tail:   u32,
	line:      [256]u8, // the line being typed
	line_len:  u32,
	eofs:      u32, // ^D on an empty line: reads that return 0
}

@(private="file")
ROOT :: u64(1)
@(private="file")
FILE :: u64(2)

@(private="file")
out_room :: proc "contextless" (c: ^Cons) -> u32 {
	return len(c.out) - (c.out_tail - c.out_head)
}

@(private="file")
out :: proc "contextless" (c: ^Cons, b: u8) {
	if out_room(c) > 0 {
		c.out[c.out_tail % len(c.out)] = b
		c.out_tail += 1
	}
}

// Sends what the device will take, and asks for an interrupt if more is waiting.
cons_pump :: proc "contextless" (c: ^Cons) {
	for room := c.tx_room(c.dev); room > 0 && c.out_head != c.out_tail; room -= 1 {
		c.tx_byte(c.dev, c.out[c.out_head % len(c.out)])
		c.out_head += 1
	}
	c.tx_wanted(c.dev, c.out_head != c.out_tail)
}

@(private="file")
echo :: proc "contextless" (c: ^Cons, b: u8) {
	if b == '\n' {
		out(c, '\r')
	}
	out(c, b)
}

@(private="file")
erase :: proc "contextless" (c: ^Cons) {
	out(c, '\b')
	out(c, ' ')
	out(c, '\b')
}

@(private="file")
finish_line :: proc "contextless" (c: ^Cons) {
	room := len(c.input) - (c.in_tail - c.in_head)
	for i in 0 ..< min(c.line_len, room) {
		c.input[c.in_tail % len(c.input)] = c.line[i]
		c.in_tail += 1
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
attach :: proc "contextless" (ctx: rawptr, aname: string) -> (u64, vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return ROOT, .Ok
}

@(private="file")
walk :: proc "contextless" (ctx: rawptr, dir: u64, name: string) -> (u64, vx.Status) {
	if dir != ROOT || name != "cons" {
		return 0, .Err_Not_Found
	}
	return FILE, .Ok
}

@(private="file")
parent :: proc "contextless" (ctx: rawptr, node: u64) -> (u64, vx.Status) {
	return ROOT, .Ok
}

@(private="file")
stat :: proc "contextless" (ctx: rawptr, node: u64, s: ^p9.Stat) -> vx.Status {
	dir := node == ROOT
	s^ = {
		qid  = {dir ? p9.QTDIR : p9.QTFILE, 0, node},
		mode = dir ? p9.DMDIR | 0o555 : 0o666,
		name = dir ? "/" : "cons",
		uid  = "cons",
		gid  = "cons",
		muid = "cons",
	}
	return .Ok
}

@(private="file")
open :: proc "contextless" (ctx: rawptr, node: u64, mode: u8) -> vx.Status {
	return mode & (p9.OTRUNC | p9.ORCLOSE) != 0 ? .Err_Access : .Ok
}

@(private="file")
read :: proc "contextless" (ctx: rawptr, node: u64, offset: u64, buf: []u8) -> (u32, vx.Status) {
	c := cast(^Cons)ctx // a stream: offsets mean nothing
	if c.in_head == c.in_tail {
		if c.eofs == 0 {
			return 0, .Err_Should_Wait
		}
		c.eofs -= 1
		return 0, .Ok
	}
	n := 0
	for n < len(buf) && c.in_head != c.in_tail {
		b := c.input[c.in_head % len(c.input)]
		c.in_head += 1
		buf[n] = b
		n += 1
		if b == '\n' {
			break // one line at a time
		}
	}
	return u32(n), .Ok
}

@(private="file")
write :: proc "contextless" (ctx: rawptr, node: u64, offset: u64, data: []u8) -> (u32, vx.Status) {
	c := cast(^Cons)ctx
	n := 0
	for n < len(data) && out_room(c) >= 2 { // room for a newline's CR LF
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
readdir :: proc "contextless" (ctx: rawptr, dir: u64, index: u32) -> (u64, vx.Status) {
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
	for i in 0 ..< len(s) {
		echo(cons_self, s[i])
	}
	cons_pump(cons_self)
}

cons_print_here :: proc "contextless" (c: ^Cons) {
	cons_self = c
	rt.print_hook = print_self
}
