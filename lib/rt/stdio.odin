package rt

import vx "abi:vx"
import "vx:memory"

// Standard input and output: pipes.
//
// A spawn message may carry "stdin" and "stdout", channel ends that the
// parent (a shell) joins into a pipe. Each message on one is a header and
// some bytes; the writer closing its end is the end of the file. Output to
// stdout goes a line at a time, as to the console; without stdout, output
// goes to the console. Without stdin, read reads the console.

@(private="file")
stdio: struct {
	input, output, port: vx.Handle,
	msg:                 [size_of(vx.Msg_Header) + 4096]u8, // stdin's current message,
	msg_len, msg_pos:    u32, // and how much of it has been read
	in_ended:            bool,
	len:                 int,
	line:                struct {
		header: vx.Msg_Header,
		text:   [512]u8, // stdout's line
	},
}

@(private="file")
never: u32

stdout_flush :: proc "contextless" () {
	n := stdio.len
	stdio.len = 0
	if n == 0 || stdio.output == 0 {
		return
	}
	stdio.line.header = {}
	for tries := 0;; tries += 1 {
		st := channel_write(stdio.output, memory.ptr_to_bytes(&stdio.line)[:size_of(vx.Msg_Header) + n])
		if st != .Err_Should_Wait {
			return // written, or no one is reading any more
		}
		// The reader is behind: the channel's queue is full. Wait a little and try again.
		_ = futex_wait(&never, 0, clock_read() + (tries < 10 ? 100_000 : 1_000_000))
	}
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
			_ = port_bind(stdio.port, stdio.input, .Peer_Closed, 1)
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

// Called by start: the console and the pipes the spawn message gives.
stdio_init :: proc "contextless" () {
	if c := spawn_take("console"); c != 0 && console_attach(c) != .Ok {
		print("vx-rt: cannot open the console\n")
	}
	stdio.input = spawn_take("stdin")
	stdio.output = spawn_take("stdout")
	if stdio.output != 0 {
		print_hook = stdout_print
	}
}
