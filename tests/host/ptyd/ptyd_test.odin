// servers/ptyd's terminals on the host: the program itself, linked against
// lib/rt, with a fake kernel underneath, as tests/host/bootfs does. Its spawn
// message mounts no /proc, so it serves without signals (a note to a
// process group needs a /proc to write to), and port_create fails, so
// vx_main returns after saying so. Its p9.Fs is then driven through lib/p9's
// server framework and client, over a transport that holds a request the
// framework defers, as the ring server does, so the test can serve it again.
//
// Upstream tests ptyd only under ctest (M4 step 4c), through the POSIX
// personality; these cases follow its ptyd.c and ctest's terminal checks,
// and the line editing of ADR-0013's cons.ndb case.
package ptyd_test

import vx "abi:vx"
import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:p9"
import "vx:rt"
import ptyd "../../../servers/ptyd"
import "../p9test"

LISTEN :: vx.Handle(0x202)

kernel_log: [1024]u8
kernel_log_len: int

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Handle_Close:
		return 0
	}
	return i64(vx.Status.Err_Unsupported) // port_create among them: vx_main returns
}

// One connection, holding the last request the framework deferred.
Conn :: struct {
	srv:        p9.Server,
	shared:     p9.Shared,
	last:       p9.Serve_Result,
	held:       [8192]u8,
	held_len:   int,
	resp:       [8192]u8,
	tbuf, rbuf: [8192]u8,
	c:          p9.Client,
}

hold_rpc :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int {
	k := (^Conn)(ctx)
	n, res := p9.serve(&k.srv, req, resp)
	k.last = res
	if res == .Defer {
		k.held_len = copy(k.held[:], req)
		return 0 // the client sees no reply: the request is held here
	}
	return res == .Reply ? n : 0
}

// The held request, served again: its read's data, Err_Should_Wait if it is
// still held, or the error it ended with.
again :: proc(k: ^Conn) -> (data: string, st: vx.Status) {
	n, res := p9.serve(&k.srv, k.held[:k.held_len], k.resp[:])
	if res == .Defer {
		return "", .Err_Should_Wait
	}
	m: p9.Msg
	if res != .Reply || p9.decode(k.resp[:n], &m) != .Ok {
		return "", .Err_Invalid
	}
	if m.type == .Rerror {
		return "", p9.error_status(m.ename)
	}
	return strings.clone(string(m.data), context.temp_allocator), .Ok
}

open_path :: proc(t: ^testing.T, c: ^p9.Client, root: p9.Fid, path: string, mode := p9.ORDWR, loc := #caller_location) -> p9.Fid {
	f, e := p9.client_walk(c, root, path)
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	testing.expect_value(t, p9.client_open(c, f, mode), vx.Status.Ok, loc = loc)
	return f
}

// Types text at the master.
type_text :: proc(t: ^testing.T, c: ^p9.Client, master: p9.Fid, text: string, loc := #caller_location) {
	n, e := p9.client_write(c, master, 0, transmute([]u8)text)
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	testing.expect_value(t, n, len(text), loc = loc)
}

// One read of f: what it gave, or why not (Err_Peer_Closed when it was held).
read_once :: proc(c: ^p9.Client, f: p9.Fid) -> (data: string, e: vx.Status) {
	buf: [8192]u8
	n: int
	n, e = p9.client_read(c, f, 0, buf[:])
	return strings.clone(string(buf[:n]), context.temp_allocator), e
}

expect_read :: proc(t: ^testing.T, c: ^p9.Client, f: p9.Fid, want: string, loc := #caller_location) {
	got, e := read_once(c, f)
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	testing.expect_value(t, got, want, loc = loc)
}

// The master's output so far (echo and the slave's writes), drained.
echoed :: proc(t: ^testing.T, k: ^Conn, master: p9.Fid, loc := #caller_location) -> string {
	got, e := read_once(&k.c, master)
	if e == .Err_Peer_Closed && k.last == .Defer {
		return "" // nothing to read: held
	}
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	return got
}

set :: proc(t: ^testing.T, c: ^p9.Client, ctl: p9.Fid, record: string, loc := #caller_location) {
	n, e := p9.client_write(c, ctl, 0, transmute([]u8)record)
	testing.expect_value(t, e, vx.Status.Ok, loc = loc)
	testing.expect_value(t, n, len(record), loc = loc)
}

settings :: proc(c: ^p9.Client, ctl: p9.Fid) -> string {
	got, _ := read_once(c, ctl)
	return got
}

@(test)
test_ptyd :: proc(t: ^testing.T) {
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "listen", LISTEN
	rt.spawn.handle_count = 1
	testing.expect_value(t, ptyd.vx_main(), int(vx.Status.Err_Unsupported))
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "ptyd: serving /srv/ptyd, without /proc: no signals\n")

	k := new(Conn, context.temp_allocator)
	k.srv = {fs = ptyd.server.fs, max_msize = 8192, supported = ptyd.server.supported, shared = &k.shared}
	k.c = {rpc = hold_rpc, ctx = k, tbuf = k.tbuf[:], rbuf = k.rbuf[:]}
	c := &k.c
	testing.expect_value(t, p9.client_version(c, 8192, {.Posix, .Xattr}), vx.Status.Ok)
	testing.expect_value(t, c.extensions, p9.Extensions{.Posix, .Xattr})
	root, e := p9.client_attach(c, "")
	testing.expect_value(t, e, vx.Status.Ok)

	testing.expect_value(t, p9test.list(c, root, ""), "ptmx pts")
	testing.expect_value(t, p9test.list(c, root, "pts"), "")

	// Opening ptmx makes terminal 0; the fid becomes its master.
	master := open_path(t, c, root, "ptmx")
	st: p9.Stat
	testing.expect_value(t, p9.client_stat(c, master, &st), vx.Status.Ok)
	testing.expect_value(t, st.name, "0")
	testing.expect_value(t, st.mode, p9.DMDEVICE | 0o620)
	testing.expect_value(t, st.qid, p9.Qid{type = p9.QTFILE, path = 0x100})
	testing.expect_value(t, p9test.list(c, root, "pts"), "0 0.ctl")
	_ = p9test.stat_of(c, root, "pts/0", &st)
	testing.expect_value(t, st.mode, p9.DMDEVICE | 0o620)
	testing.expect_value(t, st.qid.path, 0x200)
	_ = p9test.stat_of(c, root, "pts/0.ctl", &st)
	testing.expect_value(t, st.name, "0.ctl")
	testing.expect_value(t, st.mode, 0o666)
	testing.expect_value(t, st.qid.path, 0x300)
	_, e = p9.client_walk(c, root, "pts/1")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
	slave := open_path(t, c, root, "pts/0")
	ctl := open_path(t, c, root, "pts/0.ctl")

	// Linux's defaults: ICRNL|IUTF8, OPOST|ONLCR, CS8|CREAD|B38400,
	// ISIG|ICANON|ECHO|ECHOE|ECHOK, 24 by 80.
	cc: [32]u8
	cc[0], cc[1], cc[2], cc[3], cc[4], cc[6], cc[10] = 3, 0x1c, 0x7f, 0x15, 4, 1, 0x1a
	hex := strings.builder_make(context.temp_allocator)
	for b in cc {
		fmt.sbprintf(&hex, "%02x", b)
	}
	testing.expect_value(t, settings(c, ctl), fmt.tprintf("iflag=16640 oflag=5 cflag=191 lflag=59 cc=x\"%s\" rows=24 cols=80 pgrp=0 avail=0\n", strings.to_string(hex)))

	// A read with nothing to give is held, and goes on once a line ends.
	_, e = read_once(c, slave)
	testing.expect_value(t, k.last, p9.Serve_Result.Defer)
	type_text(t, c, master, "hel")
	_, e = again(k)
	testing.expect_value(t, e, vx.Status.Err_Should_Wait) // no line yet
	type_text(t, c, master, "lo\r")
	got: string
	got, e = again(k)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, got, "hello\n") // CR typed is NL read (ICRNL)
	testing.expect_value(t, echoed(t, k, master), "hello\r\n") // echoed, NL as CR NL (ONLCR)

	// Erase and kill take back whole runes (ADR-0013), echoing one \b \b each.
	type_text(t, c, master, "typoo\x08\x7fe\r")
	expect_read(t, c, slave, "type\n")
	testing.expect_value(t, echoed(t, k, master), "typoo\b \b\b \be\r\n")
	type_text(t, c, master, "caf\xc3\xa9\x7fe\r")
	expect_read(t, c, slave, "cafe\n")
	testing.expect_value(t, echoed(t, k, master), "caf\xc3\xa9\b \be\r\n")
	type_text(t, c, master, "\xc3\xa9\xe2\x82\xac\x15ok\r")
	expect_read(t, c, slave, "ok\n")
	testing.expect_value(t, echoed(t, k, master), "\xc3\xa9\xe2\x82\xac\b \b\b \bok\r\n")

	// ^D sends the line as it is; on an empty line it is the end of the file.
	type_text(t, c, master, "abc\x04def\r")
	expect_read(t, c, slave, "abc")
	expect_read(t, c, slave, "def\n")
	type_text(t, c, master, "\x04")
	expect_read(t, c, slave, "")
	_, e = read_once(c, slave)
	testing.expect_value(t, k.last, p9.Serve_Result.Defer) // and once read, gone
	_ = echoed(t, k, master)

	// A full line ends at the last whole rune that fits; the rune it would
	// have split starts the next.
	long := strings.concatenate({strings.repeat("a", 4095, context.temp_allocator), "\xc3\xa9"}, context.temp_allocator)
	type_text(t, c, master, long)
	got, e = again(k) // the read held above
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, len(got), 4095)
	type_text(t, c, master, "\r")
	expect_read(t, c, slave, "\xc3\xa9\n")
	_ = echoed(t, k, master)

	// Without IUTF8, erase takes back a byte.
	set(t, c, ctl, "iflag=256\n")
	type_text(t, c, master, "\xc3\xa9\x7f\r")
	expect_read(t, c, slave, "\xc3\n")
	_ = echoed(t, k, master)
	set(t, c, ctl, "iflag=16640\n")

	// The slave's output reaches the master with NL made CR NL.
	n: int
	n, e = p9.client_write(c, slave, 0, transmute([]u8)string("a\nb"))
	testing.expect_value(t, n, 3)
	testing.expect_value(t, echoed(t, k, master), "a\r\nb")
	set(t, c, ctl, "oflag=0\n")
	n, e = p9.client_write(c, slave, 0, transmute([]u8)string("a\nb"))
	testing.expect_value(t, echoed(t, k, master), "a\nb")
	set(t, c, ctl, "oflag=5\n")

	// Not canonical: bytes as they come, echoed unless ECHO is off.
	set(t, c, ctl, "lflag=8\n")
	type_text(t, c, master, "xy\x7f")
	expect_read(t, c, slave, "xy\x7f")
	testing.expect_value(t, echoed(t, k, master), "xy\x7f") // DEL is no control character to echo as ^?, as upstream has it
	set(t, c, ctl, "lflag=0\n")
	type_text(t, c, master, "q")
	testing.expect_value(t, echoed(t, k, master), "")
	testing.expect(t, strings.contains(settings(c, ctl), " avail=1\n"))
	set(t, c, ctl, "flush\n") // pending input thrown away
	testing.expect(t, strings.contains(settings(c, ctl), " avail=0\n"))
	set(t, c, ctl, "lflag=59\n")

	// ^C with a read held: echoed, the line thrown away, and the read ends
	// interrupted; another read is held as before.
	type_text(t, c, master, "junk")
	_, e = read_once(c, slave)
	testing.expect_value(t, k.last, p9.Serve_Result.Defer)
	type_text(t, c, master, "\x03")
	_, e = again(k)
	testing.expect_value(t, e, vx.Status.Err_Interrupted)
	testing.expect_value(t, echoed(t, k, master), "junk^C\r\n")
	_, e = read_once(c, slave)
	testing.expect_value(t, k.last, p9.Serve_Result.Defer)
	type_text(t, c, master, "\r")
	got, e = again(k)
	testing.expect_value(t, got, "\n") // the line ^C threw away is not read
	_ = echoed(t, k, master)

	// Settings by name; a record that is not one is refused; a size change
	// does not end reads.
	set(t, c, ctl, "rows=30 cols=100 pgrp=7\n")
	testing.expect(t, strings.contains(settings(c, ctl), " rows=30 cols=100 pgrp=7 avail=0\n"))
	_, e = p9.client_write(c, ctl, 0, transmute([]u8)string("\n"))
	testing.expect_value(t, e, vx.Status.Err_Invalid)

	// A second terminal is terminal 1, listed after 0.
	master1 := open_path(t, c, root, "ptmx")
	_ = p9.client_stat(c, master1, &st)
	testing.expect_value(t, st.name, "1")
	testing.expect_value(t, p9test.list(c, root, "pts"), "0 0.ctl 1 1.ctl")
	_ = p9.client_clunk(c, master1)
	testing.expect_value(t, p9test.list(c, root, "pts"), "0 0.ctl") // no slave open: gone

	// The master closed is a hang-up: the slave reads the end of the file
	// and cannot write, no new slave opens, and the terminal goes with the
	// last slave.
	_ = p9.client_clunk(c, master)
	expect_read(t, c, slave, "")
	_, e = p9.client_write(c, slave, 0, transmute([]u8)string("x"))
	testing.expect_value(t, e, vx.Status.Err_Peer_Closed)
	testing.expect_value(t, p9test.list(c, root, "pts"), "")
	f, _ := p9.client_walk(c, root, "pts/0")
	testing.expect_value(t, p9.client_open(c, f, p9.ORDWR), vx.Status.Err_Peer_Closed)
	_ = p9.client_clunk(c, f)
	_ = p9.client_clunk(c, slave)
	_ = p9.client_clunk(c, ctl)
	testing.expect_value(t, ptyd.ptys[0].used, false)
	_, e = p9.client_walk(c, root, "pts/0")
	testing.expect_value(t, e, vx.Status.Err_Not_Found)
}
