package rt

import vx "abi:vx"
import "vx:memory"
import "vx:str"
import "vx:utf"

// Standard input, output and error: pipes.
//
// A spawn message may carry "stdin", "stdout" and "stderr", channel ends that
// the parent (a shell) joins into pipes. Each message on one is a header and
// some bytes; the writer closing its end is the end of the file. Output goes
// a line at a time, as to the console. Without stdout, output goes to the
// console; without stderr, errors (eprint) go to the console, even when
// stdout is a pipe, so they never reach the next program as data. Without
// stdin, read reads the console.

@(private="file")
stdio: struct {
	input, output, err:  vx.Handle,
	port:                vx.Handle,
	msg:                 [size_of(vx.Msg_Header) + 4096]u8, // stdin's current message,
	msg_len, msg_pos:    u32, // and how much of it has been read
	in_ended:            bool,
	closed_bound:        bool, // .Peer_Closed on stdin is bound once; it fires once
	len:                 int,
	line:                struct {
		header: vx.Msg_Header,
		text:   [512]u8, // stdout's line
	},
	err_len:             int,
	err_line:            struct {
		header: vx.Msg_Header,
		text:   [512]u8, // stderr's
	},
}

@(private="file")
never: u32

// Writes msg (a header, then n bytes) to a pipe's channel end.
@(private="file")
pipe_write :: proc "contextless" (end: vx.Handle, msg: []u8) {
	for tries := 0;; tries += 1 {
		st := channel_write(end, msg)
		if st != .Err_Should_Wait {
			return // written, or no one is reading any more
		}
		// The reader is behind: the channel's queue is full. Wait a little and try again.
		_ = futex_wait(&never, 0, clock_read() + (tries < 10 ? 100_000 : 1_000_000))
	}
}

stdout_flush :: proc "contextless" () {
	n := stdio.len
	stdio.len = 0
	if n == 0 || stdio.output == 0 {
		return
	}
	stdio.line.header = {}
	pipe_write(stdio.output, memory.ptr_to_bytes(&stdio.line)[:size_of(vx.Msg_Header) + n])
}

@(private="file")
stderr_flush :: proc "contextless" () {
	n := stdio.err_len
	stdio.err_len = 0
	if n == 0 || stdio.err == 0 {
		return
	}
	stdio.err_line.header = {}
	pipe_write(stdio.err, memory.ptr_to_bytes(&stdio.err_line)[:size_of(vx.Msg_Header) + n])
}

@(private="file")
stderr_put :: proc "contextless" (s: string) {
	switch {
	case stdio.err != 0:
		buffer_line(stdio.err_line.text[:], &stdio.err_len, s, stderr_flush)
	case console_connector() != vx.HANDLE_NONE:
		console_print(s)
	case:
		print(s)
	}
}

// Prints an error, as print prints: to stderr, or without one, to the console.
eprint :: proc "contextless" (args: ..Print_Arg) {
	for a in args {
		switch v in a {
		case string:
			stderr_put(v)
		case u64:
			buf: [str.U64_DIGITS]u8
			stderr_put(str.format_u64(buf[:], v))
		case i64:
			buf: [str.I64_DIGITS]u8
			stderr_put(str.format_i64(buf[:], v))
		}
	}
}

// The standard input, output and error the spawn message gave (HANDLE_NONE
// for the console's): a shell lends its commands duplicates of them.
stdio_handles :: proc "contextless" () -> (input, output, err: vx.Handle) {
	return stdio.input, stdio.output, stdio.err
}

@(private="file")
stdout_print :: proc "contextless" (s: string) {
	buffer_line(stdio.line.text[:], &stdio.len, s, stdout_flush)
}

// Reads up to len(buf) bytes of standard input: 0 at its end.
@(require_results)
read :: proc "contextless" (buf: []u8) -> (int, vx.Status) {
	if stdio.input == 0 {
		return console_read(buf)
	}
	if stdio.len > 0 {
		stdout_flush()
	}
	for stdio.msg_pos == stdio.msg_len && !stdio.in_ended {
		size, st := channel_read(stdio.input, stdio.msg[:])
		switch {
		case st == .Ok && size.bytes >= size_of(vx.Msg_Header):
			stdio.msg_len = size.bytes
			stdio.msg_pos = size_of(vx.Msg_Header)
		case st == .Err_Should_Wait:
			if stdio.port == 0 {
				port, pst := port_create()
				if pst != .Ok {
					return 0, .Err_No_Memory
				}
				stdio.port = port
			}
			_ = port_bind(stdio.port, stdio.input, .Readable, 0)
			if !stdio.closed_bound { // once: binding it each time would leave one per read behind
				stdio.closed_bound = port_bind(stdio.port, stdio.input, .Peer_Closed, 1) == .Ok
			}
			pk: [1]vx.Packet
			_, _ = port_wait(stdio.port, vx.INFINITE, 0, pk[:])
		case st != .Ok:
			stdio.in_ended = true // the writer has gone (or sent what we cannot read)
		}
	}
	n := min(int(stdio.msg_len - stdio.msg_pos), len(buf))
	copy(buf, stdio.msg[stdio.msg_pos:][:n])
	stdio.msg_pos += u32(n)
	return n, .Ok
}

// Reads standard input until buf is full or the input ends; returns how
// much it read. A failure ends the read, with what came before it.
@(require_results)
read_all :: proc "contextless" (buf: []u8) -> (n: int, st: vx.Status) {
	for n < len(buf) {
		got := read(buf[n:]) or_return
		if got == 0 {
			break
		}
		n += got
	}
	return n, .Ok
}

// Ends the program with msg as its exit string (empty: success), as Plan 9's
// exits does. What it printed goes out first, and its pipes close, so a
// reader sees the end of its input before the exit is seen. Every thread
// ends: the program, not just this one.
exits :: proc "contextless" (msg: string) -> ! {
	flush()
	stderr_flush()
	if stdio.output != 0 {
		_ = handle_close(stdio.output)
		stdio.output = 0
		print_hook = nil
	}
	if stdio.err != 0 {
		_ = handle_close(stdio.err)
		stdio.err = 0
	}
	_ = task_kill(self, utf_cut(msg, vx.ERRMAX))
	thread_exit()
}

// The longest prefix of s of at most max_bytes bytes that ends at a rune
// boundary (ADR-0013); a bad byte is a rune of its own.
@(private="file")
utf_cut :: proc "contextless" (s: string, max_bytes: int) -> string {
	if len(s) <= max_bytes {
		return s
	}
	at := 0
	for at < max_bytes {
		_, n := utf.decode(s[at:])
		if at + n > max_bytes {
			break
		}
		at += n
	}
	return s[:at]
}

// Called by start: the console and the pipes the spawn message gives.
stdio_init :: proc "contextless" () {
	if c := spawn_take("console"); c != 0 && console_attach(c) != .Ok {
		print("vx-rt: cannot open the console\n")
	}
	stdio.input = spawn_take("stdin")
	stdio.output = spawn_take("stdout")
	stdio.err = spawn_take("stderr")
	if stdio.output != 0 {
		print_hook = stdout_print
	}
}
