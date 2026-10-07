package rt

import vx "abi:vx"
import "vx:memory"
import "vx:ndb"
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

// A pipe's reading end, read as a stream: its messages' bytes in turn.
Pipe_In :: struct {
	end, port:        vx.Handle,
	msg:              [size_of(vx.Msg_Header) + 4096]u8, // the current message,
	msg_len, msg_pos: u32, // and how much of it has been read
	ended:            bool,
	closed_bound:     bool, // .Peer_Closed is bound once; it fires once
}

@(private="file")
stdio: struct {
	input, output, err:  vx.Handle,
	reader:              Pipe_In, // stdin's
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
		put_locked(s) // print's way, under the lock eprint holds
	}
}

// Prints an error, as print prints: to stderr, or without one, to the console.
eprint :: proc "contextless" (args: ..Print_Arg) {
	mutex_lock(&stdio_lock)
	defer mutex_unlock(&stdio_lock)
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

// Reads up to len(buf) bytes from a pipe: 0 at its end.
@(require_results)
pipe_read :: proc "contextless" (p: ^Pipe_In, buf: []u8) -> (int, vx.Status) {
	for p.msg_pos == p.msg_len && !p.ended {
		size, st := channel_read(p.end, p.msg[:])
		switch {
		case st == .Ok && size.bytes >= size_of(vx.Msg_Header):
			p.msg_len = size.bytes
			p.msg_pos = size_of(vx.Msg_Header)
		case st == .Err_Should_Wait:
			if p.port == 0 {
				port, pst := port_create()
				if pst != .Ok {
					return 0, .Err_No_Memory
				}
				p.port = port
			}
			_ = port_bind(p.port, p.end, .Readable, 0)
			if !p.closed_bound { // once: binding it each time would leave one per read behind
				p.closed_bound = port_bind(p.port, p.end, .Peer_Closed, 1) == .Ok
			}
			pk: [1]vx.Packet
			_, _ = port_wait(p.port, vx.INFINITE, 0, pk[:])
		case st != .Ok:
			p.ended = true // the writer has gone (or sent what we cannot read)
		}
	}
	n := min(int(p.msg_len - p.msg_pos), len(buf))
	copy(buf, p.msg[p.msg_pos:][:n])
	p.msg_pos += u32(n)
	return n, .Ok
}

// Writes data to a pipe's writing end, 4096 bytes a message, each after a
// header, as the pipe protocol has it.
pipe_send :: proc "contextless" (end: vx.Handle, data: []u8) {
	msg: struct {
		header: vx.Msg_Header,
		bytes:  [4096]u8,
	}
	for done := 0; done < len(data); {
		n := copy(msg.bytes[:], data[done:])
		msg.header = {}
		pipe_write(end, memory.ptr_to_bytes(&msg)[:size_of(vx.Msg_Header) + n])
		done += n
	}
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
	stdio.reader.end = stdio.input
	return pipe_read(&stdio.reader, buf)
}

// --- Descriptors 3 to 9 (upstream's M6 step 6d7b2, ADR-0018) ---
//
// The spawn message's fd= records (the musl back end's format): fd=N
// pipe=read|write end=NAME, a channel end carrying the pipe protocol; or fd=N
// file=PATH flags=F offset=O [token=T], an open file, which a token joins. A
// program passes them on to its own children (rc) and opens them as /fd/N
// (vx:procns).

FDS :: 10

Fd_Entry :: struct {
	end:       vx.Handle, // a pipe's
	reader:    bool, // the reading end
	file:      bool, // an open file instead: where it is, how it was opened, and where it was at
	flags:     u32,
	offset:    u64,
	path:      [dynamic; 255]u8,
	has_token: bool, // a token to join it by, good once
	token:     [16]u8,
}

@(private="file")
fds: [FDS]Fd_Entry

// Descriptor fd's open-file record, 3 to 9; nil if it is not one.
fd_file :: proc "contextless" (fd: int) -> ^Fd_Entry {
	return fd >= 3 && fd < FDS && fds[fd].file ? &fds[fd] : nil
}

// Descriptor fd's channel end, and whether it is a reading end (0 to 2 are
// stdin, stdout and stderr); HANDLE_NONE if the process has none.
fd_pipe :: proc "contextless" (fd: int) -> (end: vx.Handle, reader: bool) {
	switch fd {
	case 0:
		return stdio.input, true
	case 1:
		return stdio.output, false
	case 2:
		return stdio.err, false
	case 3 ..< FDS:
		return fds[fd].end, fds[fd].reader
	}
	return vx.HANDLE_NONE, false
}

// Descriptors 3 to 9 closed (rc's rfork F): a clean table.
fds_close :: proc "contextless" () {
	for &e in fds[3:] {
		close_all(e.end)
		e = {}
	}
}

@(private="file")
fds_scratch: [vx.CHANNEL_MAX_BYTES]u8

// Called by start, after stdio_init: 3 to 9 from the spawn message's fd=
// records (the musl back end reads them itself).
fds_from_spawn :: proc "contextless" () {
	r := ndb.Reader{src = spawn.text, scratch = fds_scratch[:]}
	rec: ndb.Record
	for ndb.next(&r, &rec) == .Record {
		fd, ok := ndb.get_u64(&rec, "fd")
		if !ok || fd < 3 || fd >= FDS {
			continue
		}
		if path, is_file := ndb.get(&rec, "file"); is_file { // an open file: opened, or joined, when /fd/N is
			if len(path) > 255 {
				continue
			}
			flags, _ := ndb.get_u64(&rec, "flags")
			offset, _ := ndb.get_u64(&rec, "offset")
			fds[fd] = {
				file   = true,
				flags  = u32(flags),
				offset = offset,
			}
			_ = append(&fds[fd].path, path)
			if token, _ := ndb.get(&rec, "token"); len(token) == 16 {
				copy(fds[fd].token[:], token)
				fds[fd].has_token = true
			}
			continue
		}
		pipe, is_pipe := ndb.get(&rec, "pipe")
		if !is_pipe {
			continue
		}
		name, _ := ndb.get(&rec, "end")
		if len(name) >= 16 {
			continue
		}
		end := spawn_take(name)
		if end == vx.HANDLE_NONE {
			continue
		}
		close_all(fds[fd].end)
		fds[fd].end, fds[fd].reader = end, len(pipe) == 4 // "read"
	}
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
//
// It holds stdio_lock to the end, so no other thread prints over the last
// lines (upstream's M6 step 6d1); but a note handler that ends the program
// (.Dflt) may run on a thread that holds it already, interrupted inside a
// print, so it waits for it only 100 ms (UPSTREAM-FINDINGS; upstream's
// 6319e48 does the same).
exits :: proc "contextless" (msg: string) -> ! {
	_ = mutex_lock_until(&stdio_lock, clock_read() + 100_000_000)
	console_flush()
	stdout_flush()
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
