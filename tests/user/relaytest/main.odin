// relaytest: the relay (upstream's M6 step 6d4d2b), run in the relay
// scenario (tests/qemu/m6/relay.ndb) against u9fs over TCP. It spawns a
// relay for tcp!10.0.2.101!564 and connects to it twice: one TCP
// conversation for both; both clients number their fids alike; a file made
// through one is read through the other; threads on both connections at
// once; a flushed read, a hundred times over, leaks nothing; an error comes
// through; a client gone leaves the other working; and the relay goes once
// nothing can reach it. Each check prints a line only when it fails; the
// last line counts them. The checks are upstream's, some of several
// conditions, so the count is too.
package relaytest

import vx "abi:vx"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if !ok {
		failures += 1
		rt.print("relaytest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

ADDRESS :: "tcp!10.0.2.101!564"
HELLO :: "hello from the host\n"

space: ns.Namespace
image: [1 << 20]u8
image_size: int

// The whole of the file at path in the namespace, into buf.
read_path :: proc "contextless" (path: string, buf: []u8) -> (text: string, st: vx.Status) {
	f: ns.File
	ns.open(&space, path, p9.OREAD, &f) or_return
	defer ns.close(&f)
	n := ns.read_all(&f, buf) or_return
	return string(buf[:n]), .Ok
}

// TCP conversations established with u9fs.
conversations :: proc "contextless" () -> int {
	n := 0
	for i in 0 ..< 64 {
		path_buf: [32]u8
		number_buf: [4]u8
		number := str.format_u64(number_buf[:], u64(i))
		buf: [128]u8
		path, _ := str.join(path_buf[:], "/net/tcp/", number, "/status")
		status, st := read_path(path, buf[:])
		if st != .Ok || !str.contains(status, "Established") {
			continue
		}
		path, _ = str.join(path_buf[:], "/net/tcp/", number, "/remote")
		if remote, rst := read_path(path, buf[:]); rst == .Ok && str.contains(remote, "10.0.2.101!564") {
			n += 1
		}
	}
	return n
}

// Starts a relay for ADDRESS: its task, and a connector to it.
spawn_relay :: proc "contextless" () -> (task, connector: vx.Handle) {
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	@(static) records: [8 * 1024]u8
	rec := ndb.Writer {
		buf = records[:],
	}
	ndb.put(&rec, "arg", ADDRESS)
	_ = ndb.end(&rec)
	a, b, cst := rt.channel_create()
	if cst != .Ok {
		return vx.HANDLE_NONE, vx.HANDLE_NONE
	}
	count, st := procns.spawn_records(&space, &rec, handles[:vx.CHANNEL_MAX_HANDLES - 4], names[:], 0)
	if st != .Ok {
		rt.close_all(a, b)
		return vx.HANDLE_NONE, vx.HANDLE_NONE
	}
	handles[count], names[count] = b, "listen"
	count += 1
	if c := rt.console_connector(); c != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(c, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "console"
			count += 1
		}
	}
	args := rt.Spawn_Args {
		name         = "relay",
		image        = image[:image_size],
		handles      = handles[:count],
		handle_names = names[:count],
		records      = ndb.written(&rec),
	}
	task, st = rt.spawn_elf(&args)
	if st != .Ok {
		rt.close_all(a)
		return vx.HANDLE_NONE, vx.HANDLE_NONE
	}
	return task, a
}

// The whole of the file at path from root on c, into buf.
read_file :: proc "contextless" (c: ^p9.Client, root: p9.Fid, path: string, buf: []u8) -> (n: int, st: vx.Status) {
	fid := p9.client_walk(c, root, path) or_return
	defer _ = p9.client_clunk(c, fid)
	p9.client_open(c, fid, p9.OREAD) or_return
	return p9.client_read(c, fid, 0, buf)
}

// Whether the file at path reads as text.
reads_as :: proc "contextless" (c: ^p9.Client, root: p9.Fid, path, text: string) -> bool {
	buf: [64]u8
	n, st := read_file(c, root, path, buf[:])
	return st == .Ok && string(buf[:n]) == text
}

// Whether the file at path reads as count bytes.
reads_count :: proc "contextless" (c: ^p9.Client, root: p9.Fid, path: string, count: int) -> bool {
	buf: [64]u8
	n, st := read_file(c, root, path, buf[:])
	return st == .Ok && n == count
}

a, b: rt.Conn
aroot, broot: p9.Fid

Worker :: struct {
	c:    ^p9.Client,
	root: p9.Fid,
	good: int,
}

work :: proc(arg: rawptr) {
	w := (^Worker)(arg)
	for _ in 0 ..< 50 {
		if reads_as(w.c, w.root, "hello.txt", HELLO) {
			w.good += 1
		}
	}
}

// Made through c: name, holding text.
make_file :: proc "contextless" (c: ^p9.Client, root: p9.Fid, name, text: string) -> bool {
	fid, st := p9.client_walk(c, root, "")
	if st != .Ok {
		return false
	}
	defer _ = p9.client_clunk(c, fid)
	if p9.client_create(c, fid, name, 0o644, p9.OWRITE) != .Ok {
		return false
	}
	n, wst := p9.client_write(c, fid, 0, transmute([]u8)text)
	return wst == .Ok && n == len(text)
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	if f: ns.File; ns.open(&space, "/boot/bin/relay", p9.OREAD, &f) == .Ok {
		image_size, _ = ns.read_all(&f, image[:])
		ns.close(&f)
	}
	check(image_size > 0)
	// The network up first: netd's address from DHCP.
	port, pst := rt.port_create()
	check(pst == .Ok)
	pk: [1]vx.Packet
	for _ in 0 ..< 100 {
		buf: [512]u8
		if status, st := read_path("/net/ipifc/0/status", buf[:]); st == .Ok && str.contains(status, "10.0.2.15") {
			break
		}
		_, _ = rt.port_wait(port, rt.clock_read() + 100_000_000, 0, pk[:]) // a pause: nothing is bound
	}
	before := conversations()

	relay, connector := spawn_relay()
	check(relay != vx.HANDLE_NONE)
	check(rt.p9_connect(connector, &a) == .Ok && a.c.dialect == .P9_2000 && a.c.extensions == {})
	check(rt.p9_connect(connector, &b) == .Ok && b.c.dialect == .P9_2000)
	a.timeout, b.timeout = 5_000_000_000, 5_000_000_000
	ast, bst: vx.Status
	aroot, ast = p9.client_attach(&a.c, "")
	check(ast == .Ok)
	broot, bst = p9.client_attach(&b.c, "")
	check(bst == .Ok)
	check(aroot == broot) // each client's own numbering: the same fids
	check(conversations() == before + 1) // one session for both

	check(reads_as(&a.c, aroot, "hello.txt", HELLO))
	check(reads_count(&b.c, broot, "hello.txt", 20))
	nothing: [64]u8
	_, nst := read_file(&b.c, broot, "nothing", nothing[:])
	check(nst == .Err_Not_Found)

	// Made through one, read through the other.
	check(make_file(&a.c, aroot, "relay.txt", "through the relay\n"))
	check(reads_as(&b.c, broot, "relay.txt", "through the relay\n"))

	// Two threads on each connection, all at once.
	w := [4]Worker{{&a.c, aroot, 0}, {&a.c, aroot, 0}, {&b.c, broot, 0}, {&b.c, broot, 0}}
	t: [4]rt.Thread
	for i in 0 ..< 4 {
		st: vx.Status
		t[i], st = rt.thread_spawn(work, &w[i])
		check(st == .Ok)
	}
	for i in 0 ..< 4 {
		rt.thread_join(&t[i])
	}
	check(w[0].good == 50 && w[1].good == 50 && w[2].good == 50 && w[3].good == 50)

	// Reads flushed as soon as they are sent: none of the relay's calls is
	// kept for them (it has 64), and the connection goes on.
	fid, st := p9.client_walk(&a.c, aroot, "hello.txt")
	check(st == .Ok && p9.client_open(&a.c, fid, p9.OREAD) == .Ok)
	sent := 0
	for _ in 0 ..< 100 {
		r := p9.Msg {
			type   = .Tread,
			fid    = fid,
			offset = 0,
			count  = 20,
		}
		if rt.p9_send(&a, &r, vx.HANDLE_NONE, 0) == .Ok {
			sent += 1
		}
		rt.p9_cancel(&a, r.tag)
	}
	check(sent == 100)
	twenty: [20]u8
	n, rst := p9.client_read(&a.c, fid, 0, twenty[:])
	check(rst == .Ok && n == 20)
	_ = p9.client_clunk(&a.c, fid)
	check(reads_count(&b.c, broot, "hello.txt", 20))

	// A client gone, its fids with it; the other goes on, and so does the
	// relay with its connector gone too, until its last client goes.
	_, st = p9.client_walk(&a.c, aroot, "hello.txt")
	check(st == .Ok)
	rt.p9_disconnect(&a)
	rt.close_all(connector)
	check(reads_count(&b.c, broot, "hello.txt", 20))
	check(rt.port_bind(port, relay, .Exit, 1) == .Ok)
	_, wst := rt.port_wait(port, rt.clock_read() + 200_000_000, 0, pk[:])
	check(wst == .Err_Timed_Out) // still there
	rt.p9_disconnect(&b)
	got, _ := rt.port_wait(port, rt.clock_read() + 5_000_000_000, 0, pk[:])
	check(got == 1) // and gone
	check(conversations() == before)

	rt.print("relaytest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	return 0
}
