package rt

import vx "abi:vx"
import "vx:p9"

// The console: /srv/cons, the file "cons".
//
// Output goes out a line at a time (or when the buffer fills), so lines from
// different programs do not interleave. If the connection breaks, which it
// does when svcd restarts the console driver, the next write connects again
// through the connector; if that fails too, that line goes to the kernel log,
// and the next one tries again.

@(private="file")
console: struct {
	connector: vx.Handle,
	conn:      Conn,
	fid:       u32,
	open:      bool,
	len:       int,
	line:      [512]u8,
}

@(private="file")
console_open :: proc "contextless" () -> vx.Status {
	if console.conn.end != 0 {
		p9_disconnect(&console.conn)
	}
	console.open = false
	st := p9_connect(console.connector, &console.conn)
	root: u32
	if st == .Ok {
		root, st = p9.client_attach(&console.conn.c, "")
	}
	if st == .Ok {
		console.fid, st = p9.client_walk(&console.conn.c, root, "cons")
		_ = p9.client_clunk(&console.conn.c, root)
	}
	if st == .Ok {
		st = p9.client_open(&console.conn.c, console.fid, p9.ORDWR)
	}
	console.open = st == .Ok
	return st
}

@(private="file")
console_put :: proc "contextless" (data: []u8) -> bool {
	p := data
	for len(p) > 0 {
		if !console.open {
			return false
		}
		n, st := p9.client_write(&console.conn.c, console.fid, 0, p)
		if st != .Ok || n <= 0 {
			return false
		}
		p = p[n:]
	}
	return true
}

console_flush :: proc "contextless" () {
	n := console.len
	console.len = 0
	if n == 0 || console_put(console.line[:n]) {
		return
	}
	if console_open() == .Ok && console_put(console.line[:n]) {
		return // the driver restarted
	}
	_ = debug_write(string(console.line[:n]))
}

@(private="file")
console_print :: proc "contextless" (s: string) {
	for i in 0 ..< len(s) {
		console.line[console.len] = s[i]
		console.len += 1
		if s[i] == '\n' || console.len == len(console.line) {
			console_flush()
		}
	}
}

// Sends output to the console server behind `connector` (a /srv/cons
// connector, which this keeps). Programs get one in their spawn message;
// svcd calls this itself once it has started the console driver.
console_attach :: proc "contextless" (connector: vx.Handle) -> vx.Status {
	console.connector = connector
	st := console_open()
	if st == .Ok {
		print_hook = console_print
	}
	return st
}

// Reads what the console has: a line, in its cooked mode. 0 at end of file.
console_read :: proc "contextless" (buf: []u8) -> (int, vx.Status) {
	if console.len > 0 {
		console_flush() // a prompt goes out before the wait
	}
	if !console.open {
		return 0, .Err_Bad_State
	}
	n, st := p9.client_read(&console.conn.c, console.fid, 0, buf)
	if st != .Ok && console_open() == .Ok {
		n, st = p9.client_read(&console.conn.c, console.fid, 0, buf)
	}
	return n, st
}
