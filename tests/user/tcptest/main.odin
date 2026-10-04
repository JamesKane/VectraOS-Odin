// tcptest: TCP through /net/tcp, against QEMU's own stack
// (tests/qemu/m3/tcp.ndb). QEMU hands a connection to 10.0.2.100!7 to a
// `cat` on the host, so what is sent comes back. 256 KiB go through, 4 KiB at
// a time, checked as they return; then hangup sends our FIN, cat sees the end
// of its input and exits, and the read sees the end of the stream. A
// connection to a port nobody listens on is refused.
package tcptest

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

space: ns.Namespace

// Says what failed, and why if st says, and exits.
fail :: proc(what: string, st := vx.Status.Ok) -> ! {
	rt.print("tcptest: FAILED: ", what)
	if st != .Ok {
		rt.print(": ", p9.error_text(st))
	}
	rt.print("\n")
	rt.exits(what)
}

Conn :: struct {
	ctl, data: ns.File,
}

// A connection to addr ("ADDR!PORT"): the status of the connect.
dial :: proc(addr: string, c: ^Conn) -> vx.Status {
	if st := ns.open(&space, "/net/tcp/clone", p9.ORDWR, &c.ctl); st != .Ok {
		fail("/net/tcp/clone", st)
	}
	number: [8]u8
	n, rst := ns.read(&c.ctl, number[:])
	if rst != .Ok || n == 0 || n > 2 {
		fail("reading the conversation's number", rst)
	}
	msg_buf: [64]u8
	msg, _ := str.join(msg_buf[:], "connect ", addr)
	_ = ns.write(&c.ctl, transmute([]u8)msg) or_return // returns once connected, or refused
	path_buf: [64]u8
	path, _ := str.join(path_buf[:], "/net/tcp/", string(number[:n]), "/data")
	if st := ns.open(&space, path, p9.ORDWR, &c.data); st != .Ok {
		fail("opening data", st)
	}
	return .Ok
}

pattern :: proc(i: int) -> u8 {
	return u8(i * 13 + i / 251)
}

TOTAL :: 256 * 1024

out, in_: [4096]u8

echo :: proc() {
	c: Conn
	if st := dial("10.0.2.100!7", &c); st != .Ok {
		fail("connect 10.0.2.100!7", st)
	}
	rt.print("tcptest: connected to 10.0.2.100!7\n")
	for done := 0; done < TOTAL; done += len(out) {
		for &b, i in out {
			b = pattern(done + i)
		}
		for sent := 0; sent < len(out); { // a stream write may take part of it
			w, st := ns.write(&c.data, out[sent:])
			if st != .Ok || w == 0 {
				fail("writing", st)
			}
			sent += w
		}
		for got := 0; got < len(out); {
			r, st := ns.read(&c.data, in_[:len(out) - got])
			if st != .Ok || r == 0 {
				fail("reading the echo", st)
			}
			for b, i in in_[:r] {
				if b != pattern(done + got + i) {
					fail("the echo differs from what was sent")
				}
			}
			got += r
		}
	}
	rt.print("tcptest: 262144 bytes echoed\n")
	if w, _ := ns.write(&c.ctl, transmute([]u8)string("hangup")); w != 6 {
		fail("hangup")
	}
	r, st := ns.read(&c.data, in_[:])
	if st != .Ok || r != 0 {
		fail("expected the end of the stream", st)
	}
	rt.print("tcptest: end of stream after hangup\n")
	ns.close(&c.data)
	ns.close(&c.ctl)
}

// Waits up to 20 s for netd to have an address, as any client must.
await_address :: proc() {
	nap, st := rt.port_create()
	if st != .Ok {
		fail("port_create")
	}
	for _ in 0 ..< 200 {
		f: ns.File
		status: [128]u8
		n := 0
		if ns.open(&space, "/net/ipifc/0/status", p9.OREAD, &f) == .Ok {
			n, _ = ns.read(&f, status[:])
			ns.close(&f)
		}
		// The status says addr= and something other than none.
		text := string(status[:n])
		for j := 0; j + 9 < n; j += 1 {
			if str.has_prefix(text[j:], "addr=") && !str.has_prefix(text[j + 5:], "none") {
				return
			}
		}
		pk: [1]vx.Packet
		_, _ = rt.port_wait(nap, rt.clock_read() + 100_000_000, 0, pk[:])
	}
	fail("no address")
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		fail("no namespace")
	}
	await_address()
	echo()
	c: Conn
	st := dial("10.0.2.2!1", &c)
	if st == .Ok {
		fail("a connection to 10.0.2.2!1 was made")
	}
	rt.print("tcptest: 10.0.2.2!1: ", p9.error_text(st), "\n")
	ns.close(&c.ctl)
	rt.print("tcptest: ok\n")
	return 0
}
