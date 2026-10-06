package ns

// Dialing: 9P over TCP (upstream 02 §3.2, 04 §5 M3), through the namespace's
// own /net. A mount of tcp!HOST!PORT (or 9p://HOST:PORT) asks /net/cs where
// to dial, connects a /net/tcp conversation, and speaks 9P2000 over its data
// file, each message framed by its size, as on any 9P stream. 9Px's
// extensions are for rings, so a TCP connection asks for none.
//
// netd's side of it: writing "tcp!HOST!SERVICE" to /net/cs makes each read a
// line "/net/tcp/clone ADDR!PORT"; opening a clone file moves the fid to a
// new conversation's ctl, which reads as its number N; writing "connect
// ADDR!PORT" there returns once the connection is made, or refused; and
// N/data, beside the clone file, is the stream.
//
// A child cannot be handed a TCP connection as it is handed a ring
// connector, so its spawn records say dial=ADDRESS, and it dials its own
// (lib/procns). Within a process, mounts of one address share a connection.

import "abi:vx"
import "vx:p9"
import "vx:str"

DIAL_MSIZE :: 16384
DIALS :: 4

// One dialed connection. Its client points back into it (ctx, tbuf, rbuf),
// so it never moves: the table is a global.
@(private="file")
Dialed :: struct {
	c:          p9.Client,
	used:       bool,
	addr:       [dynamic; MAX_SRC]u8, // as /net/cs was asked, for sharing
	ctl, data:  File,
	data_path:  [dynamic; 64]u8, // /net/tcp/N/data, for a second open (the relay's reader)
	lock:       u32, // a stream carries one call at a time: threads take turns (dial_lock)
	tbuf, rbuf: [DIAL_MSIZE]u8,
}

@(private="file")
dials: [DIALS]Dialed

// How threads take turns at a dialed connection: a lock on a word, taken or
// let go, which the program gives (vx:procns gives vx:rt's mutex: this
// package makes no system calls, so the host builds it too). Without one,
// the connection is one thread's.
Dial_Lock :: #type proc "contextless" (word: ^u32, take: bool)
dial_lock: Dial_Lock

@(private="file")
dial_take_turn :: proc "contextless" (ctx: rawptr, take: bool) {
	if dial_lock != nil {
		dial_lock(&(^Dialed)(ctx).lock, take)
	}
}

// One 9P exchange over the stream: the request, then a reply as long as its
// size says. 0 if the connection is gone or the reply cannot be one.
@(private="file")
dial_rpc :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int {
	d := (^Dialed)(ctx)
	for sent := 0; sent < len(req); { // a stream write may take part of it
		n, e := write(&d.data, req[sent:])
		if e != .Ok || n == 0 {
			return 0
		}
		sent += n
	}
	if len(resp) < 7 || !read_exactly(&d.data, resp[:4]) {
		return 0
	}
	size := u32(resp[0]) | u32(resp[1]) << 8 | u32(resp[2]) << 16 | u32(resp[3]) << 24
	if size < 7 || u64(size) > u64(len(resp)) || !read_exactly(&d.data, resp[4:size]) {
		return 0
	}
	return int(size)
}

// Fills buf from the stream; false at its end, or on an error.
@(private="file")
read_exactly :: proc "contextless" (f: ^File, buf: []u8) -> bool {
	n, e := read_all(f, buf)
	return e == .Ok && n == len(buf)
}

@(private="file")
dial_close :: proc "contextless" (d: ^Dialed) {
	close(&d.data)
	close(&d.ctl) // the conversation ends with its last file
	d.used = false
}

// Whether c is a dialed connection; if so it is let go. A Namespace's release
// hook calls it first (lib/procns).
dial_release :: proc "contextless" (c: ^p9.Client) -> bool {
	for &d in dials {
		if d.used && &d.c == c {
			dial_close(&d)
			return true
		}
	}
	return false
}

// "9p://HOST:PORT" as "tcp!HOST!PORT", in out; anything else as it is. ok is
// false for an empty address, one that does not fit, or a 9p:// one without
// both a host and a port.
@(private="file")
dial_address :: proc "contextless" (addr: string, out: []u8) -> (s: string, ok: bool) {
	SCHEME :: "9p://"
	if len(addr) > len(SCHEME) && str.has_prefix(addr, SCHEME) {
		rest := addr[len(SCHEME):]
		colon := str.last_index_byte(rest, ':')
		if colon < 1 || colon == len(rest) - 1 {
			return "", false
		}
		return str.join(out, "tcp!", rest[:colon], "!", rest[colon + 1:])
	}
	if len(addr) == 0 {
		return "", false
	}
	return str.join(out, addr)
}

// A 9P connection to addr (tcp!HOST!PORT or 9p://HOST:PORT), negotiated: the
// one this process has already, or a new one. src is its address as dialed
// (what /net/cs was asked), for mount and ns output; it lasts as long as the
// connection.
@(require_results)
dial :: proc "contextless" (ns: ^Namespace, addr: string) -> (c: ^p9.Client, src: string, st: vx.Status) {
	want_buf: [MAX_SRC]u8
	want, ok := dial_address(addr, want_buf[:])
	if !ok {
		return nil, "", .Err_Invalid
	}
	d: ^Dialed
	for &k in dials {
		if k.used && string(k.addr[:]) == want {
			return &k.c, string(k.addr[:]), .Ok
		}
		if !k.used && d == nil {
			d = &k
		}
	}
	if d == nil {
		return nil, "", .Err_No_Memory
	}

	// Where to dial: the connection server's first answer, "/net/tcp/clone ADDR!PORT".
	line_buf: [128]u8
	n: int
	{
		cs: File
		open(ns, "/net/cs", p9.ORDWR, &cs) or_return
		_, st = write(&cs, transmute([]u8)want)
		if st == .Ok {
			cs.offset = 0
			n, st = read(&cs, line_buf[:])
		}
		close(&cs)
	}
	if st != .Ok || n == 0 {
		return nil, "", st != .Ok ? st : .Err_Not_Found
	}
	line := string(line_buf[:n])
	if line[len(line) - 1] == '\n' {
		line = line[:len(line) - 1]
	}
	space := str.index_byte(line, ' ')
	if space < 0 || space + 1 == len(line) {
		return nil, "", .Err_Invalid
	}
	clone_path, dest := line[:space], line[space + 1:]

	d^ = {
		used = true,
	}
	_ = append(&d.addr, want) // it fit want_buf, which is as long
	if st = open(ns, clone_path, p9.ORDWR, &d.ctl); st != .Ok {
		d.used = false
		return nil, "", st
	}
	number_buf: [8]u8
	got, ne := read(&d.ctl, number_buf[:])
	number := string(number_buf[:got])
	msg_buf: [96]u8
	msg, mok := str.join(msg_buf[:len(msg_buf) - 1], "connect ", dest) // upstream keeps a byte for its NUL
	if ne == .Ok && got > 0 && mok {
		_, st = write(&d.ctl, transmute([]u8)msg) // returns once connected
	} else {
		st = ne != .Ok ? ne : .Err_Invalid
	}
	// The data file is beside the clone file: /net/tcp/N/data.
	path_buf: [64]u8
	dir := str.last_index_byte(clone_path, '/') + 1
	path, fits := str.join(path_buf[:], clone_path[:dir], number, "/data")
	if st == .Ok && fits {
		st = open(ns, path, p9.ORDWR, &d.data)
		_ = append(&d.data_path, path) // it fit path_buf, which is as long
	} else if st == .Ok {
		st = .Err_Invalid
	}
	if st != .Ok {
		close(&d.ctl)
		d.used = false
		return nil, "", st
	}
	// A Plan 9 server refuses "none" until a connection has authenticated;
	// and there are no user names before keyd (M8), so a dialed server sees
	// this one.
	d.c = {
		rpc   = dial_rpc,
		ctx   = d,
		tbuf  = d.tbuf[:],
		rbuf  = d.rbuf[:],
		lock  = dial_take_turn,
		uname = "vectra",
	}
	if st = p9.client_version(&d.c, DIAL_MSIZE, {}); st != .Ok {
		dial_close(d)
		return nil, "", st
	}
	return &d.c, string(d.addr[:]), .Ok
}

// A dialed connection's stream: its data file and that file's path, for a
// second open (the relay's reader). The file is the caller's to use from
// here, as nothing calls through c again. Not ok if c was not dialed.
dial_stream :: proc "contextless" (c: ^p9.Client) -> (data: File, path: string, ok: bool) {
	for &d in dials {
		if d.used && &d.c == c {
			return d.data, string(d.data_path[:]), true
		}
	}
	return {}, "", false
}
