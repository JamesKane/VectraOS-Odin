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
	fid:       p9.Fid,
	open:      bool,
	len:       int,
	line:      [512]u8,
	retry_at:  vx.Instant, // no reconnecting before this, after a failure
}

// How long a failed connection is left before the next try.
@(private="file")
RETRY_AFTER :: vx.Instant(1_000_000_000)

// Connects (again). After a failure it does not try for a second, so a
// console that is gone for good costs each line nothing, not a connect's wait.
@(private="file")
console_open :: proc "contextless" () -> (st: vx.Status) {
	if console.conn.end != 0 {
		p9_disconnect(&console.conn)
	}
	console.open = false
	if clock_read() < console.retry_at {
		return .Err_Peer_Closed
	}
	defer {
		console.open = st == .Ok
		if !console.open {
			console.retry_at = clock_read() + RETRY_AFTER
		}
	}
	c := &console.conn.c
	p9_connect(console.connector, &console.conn) or_return
	root := p9.client_attach(c, "") or_return
	fid, walked := p9.client_walk(c, root, "cons")
	_ = p9.client_clunk(c, root) // here, not deferred: the server sees the clunk before the open
	walked or_return
	console.fid = fid
	return p9.client_open(c, console.fid, p9.ORDWR)
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
	buffer_line(console.line[:], &console.len, s, console_flush)
}

// Appends s to a line buffer holding n bytes, calling flush (which empties
// it) after each newline and whenever the buffer fills.
@(private)
buffer_line :: proc "contextless" (line: []u8, n: ^int, s: string, flush: proc "contextless" ()) {
	for c in transmute([]u8)s {
		line[n^] = c
		n^ += 1
		if c == '\n' || n^ == len(line) {
			flush()
		}
	}
}

// Sends output to the console server behind `connector` (a /srv/cons
// connector, which this keeps). Programs get one in their spawn message;
// svcd calls this itself once it has started the console driver.
@(require_results)
console_attach :: proc "contextless" (connector: vx.Handle) -> vx.Status {
	console.connector = connector
	console_open() or_return
	print_hook = console_print
	return .Ok
}

// Reads what the console has: a line, in its cooked mode. 0 at end of file.
@(require_results)
console_read :: proc "contextless" (buf: []u8) -> (int, vx.Status) {
	if console.len > 0 {
		console_flush() // a prompt goes out before the wait
	}
	if console.connector == vx.HANDLE_NONE {
		return 0, .Err_Bad_State
	}
	// Until the console is back (the driver restarting), wait for it rather
	// than fail: a reader takes an error for the end of its input.
	for {
		if console.open {
			if n, st := p9.client_read(&console.conn.c, console.fid, 0, buf); st == .Ok {
				return n, .Ok
			}
		}
		if console_open() == .Ok {
			continue
		}
		@(static) never: u32
		_ = futex_wait(&never, 0, console.retry_at) // a second, then try again
	}
}

// The console's connector, which a shell hands its commands a duplicate of;
// HANDLE_NONE without a console.
console_connector :: proc "contextless" () -> vx.Handle {
	return console.connector
}
