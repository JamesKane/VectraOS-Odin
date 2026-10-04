// nettest: the network driver's test, run as a service in the net scenario
// (tests/qemu/m3/net.ndb). It opens a session on /srv/ether0, as netd will,
// asks for the MAC address, offers receive slots, and sends an ARP request
// for QEMU's host (10.0.2.2) from the guest's address (10.0.2.15). QEMU's user
// network answers, so a reply means frames went out and came back in,
// through both virtqueues and both MSI-X interrupts. A second session is
// refused while the first is open.
//
// Then it kills the driver, through the task tree its manifest gives it
// (`tasks`), and does it all again: devmgr restarts the driver on the same
// post, so a new session works as the first did.
package nettest

import vx "abi:vx"
import "vx:driver"
import "vx:memory"
import "vx:ring"
import "vx:rt"
import "vx:str"

GUEST_IP :: [4]u8{10, 0, 2, 15}
HOST_IP :: [4]u8{10, 0, 2, 2}

r: ring.Ring
end, port: vx.Handle

fail :: proc(what: string) -> ! {
	rt.print("nettest: FAILED: ", what, "\n")
	rt.exits(what)
}

submit :: proc(e: vx.Sqe) {
	e := e
	slot, ok := ring.produce_slot(&r)
	if !ok {
		fail("the submission queue is full")
	}
	copy(slot, memory.ptr_to_bytes(&e))
	if ring.produce(&r) {
		_ = rt.ring_notify(end)
	}
}

// The next completion, waiting up to `seconds` for it.
next :: proc(seconds: i64) -> (c: vx.Cqe, ok: bool) {
	deadline := rt.clock_read() + vx.Instant(seconds * 1_000_000_000)
	for {
		if ring.consume(&r, memory.ptr_to_bytes(&c)) == .Ok {
			return c, true
		}
		seen, _ := rt.counter_read(end)
		if ring.prepare_sleep(&r) {
			if rt.port_bind(port, end, .Counter_Ge, 1, seen + 1) != .Ok {
				fail("port_bind")
			}
			pk: [1]vx.Packet
			n, st := rt.port_wait(port, deadline, 0, pk[:])
			ring.end_sleep(&r)
			if st == .Err_Timed_Out {
				return {}, false
			}
			if n != 1 {
				fail("waiting for the driver")
			}
		} else {
			ring.end_sleep(&r)
		}
	}
}

// Bytes as hex, separated by colons.
print_mac :: proc(b: []u8) {
	DIGITS := "0123456789abcdef"
	for v, i in b {
		text := [3]u8{DIGITS[v >> 4], DIGITS[v & 15], ':'}
		rt.print(string(text[:i + 1 < len(b) ? 3 : 2]))
	}
}

nap :: proc() {
	pk: [1]vx.Packet
	_, _ = rt.port_wait(port, rt.clock_read() + 100_000_000, 0, pk[:])
}

// Opens a session (waiting for the driver to serve), and checks a second is
// refused while it is open.
open_session :: proc(connector: vx.Handle) {
	st := vx.Status.Err_Peer_Closed
	for tries := 0; tries < 50 && st != .Ok; tries += 1 { // the driver may not be serving yet
		end, st = rt.session_dial(connector, driver.NET_CONNECT, driver.NET_PARAMS, &r)
		if st != .Ok {
			nap()
		}
	}
	if st != .Ok {
		fail("cannot open a session")
	}
	other: ring.Ring
	if _, ost := rt.session_dial(connector, driver.NET_CONNECT, driver.NET_PARAMS, &other); ost == .Ok {
		fail("a second session was opened while the first is open")
	}
	rt.print("nettest: a second session is refused\n")
}

// Info, then an ARP request and its reply. False if no reply came.
exchange :: proc() -> bool {
	submit({opcode = u16(driver.Net_Op.Info), user_data = 1})
	c, ok := next(5)
	if !ok || c.user_data != 1 || c.result != 0 {
		fail("INFO")
	}
	mac: [6]u8
	for &b, i in mac {
		b = u8(c.aux2 >> (8 * uint(i)))
	}
	rt.print("nettest: MAC ")
	print_mac(mac[:])
	rt.print(", MTU ", u64(c.aux), "\n")

	for s in u64(0) ..< 8 {
		submit({opcode = u16(driver.Net_Op.Rx), user_data = 100 + s, target = s})
	}

	// An ARP request (RFC 826), broadcast: who has 10.0.2.2? tell 10.0.2.15.
	guest, host := GUEST_IP, HOST_IP
	f := ring.arena(&r)[:60]
	for &b in f {
		b = 0 // padded to Ethernet's 60 bytes
	}
	for &b in f[:6] {
		b = 0xff
	}
	copy(f[6:], mac[:])
	f[12], f[13] = 0x08, 0x06 // ARP
	f[14], f[15], f[16], f[17] = 0, 1, 0x08, 0 // Ethernet, IPv4
	f[18], f[19], f[20], f[21] = 6, 4, 0, 1 // address sizes; a request
	copy(f[22:], mac[:])
	copy(f[28:], guest[:])
	copy(f[38:], host[:])
	submit({opcode = u16(driver.Net_Op.Tx), flags = {.Dref}, user_data = 2, arena_off = 0, len = 60})

	sent := false
	for {
		c, ok = next(10)
		if !ok {
			return false
		}
		if c.user_data == 2 {
			if c.result != 60 {
				fail("TX")
			}
			sent = true
			rt.print("nettest: sent an ARP request for 10.0.2.2\n")
			continue
		}
		if c.user_data < 100 || c.user_data >= 108 || c.result < 42 {
			fail("an RX completion")
		}
		frame, fok := ring.peer_bytes(&r, c.aux2, u64(c.result))
		if !fok {
			fail("an RX frame outside the driver's arena")
		}
		reply := frame[12] == 0x08 && frame[13] == 0x06 && frame[20] == 0 && frame[21] == 2 &&
			string(frame[28:32]) == string(host[:]) && string(frame[38:42]) == string(guest[:]) &&
			string(frame[:6]) == string(mac[:])
		submit({opcode = u16(driver.Net_Op.Rx), user_data = c.user_data, target = c.user_data - 100}) // offered again
		if !reply {
			continue // something else on the wire
		}
		rt.print("nettest: 10.0.2.2 is at ")
		print_mac(frame[22:28])
		rt.print("\n")
		if !sent {
			fail("a reply before the request completed")
		}
		return true
	}
}

// Kills the driver, found by name in the task tree, and waits for its
// session to end.
kill_driver :: proc(tasks: vx.Handle) {
	id: u64
	found := false
	for !found {
		info, st := rt.task_info(tasks, id, {.Next})
		if st != .Ok {
			break
		}
		id = info.id
		found = str.from_nul_padded(info.name[:]) == "drv-virtio-net"
	}
	if !found {
		fail("no drv-virtio-net task")
	}
	if rt.task_kill(tasks, "killed", id) != .Ok {
		fail("cannot kill the driver")
	}
	if rt.port_bind(port, end, .Peer_Closed, 2) != .Ok {
		fail("port_bind")
	}
	for {
		pk: [1]vx.Packet
		if n, _ := rt.port_wait(port, rt.clock_read() + 5_000_000_000, 0, pk[:]); n != 1 {
			fail("the session outlived the driver")
		}
		if pk[0].key == 2 {
			break
		}
	}
	rt.close_all(end)
	rt.print("nettest: stopped the driver; its session ended\n")
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	connector, tasks := rt.spawn_take("srv:ether0"), rt.spawn_take("tasks")
	if connector == vx.HANDLE_NONE || tasks == vx.HANDLE_NONE {
		fail("no connector to /srv/ether0, or no task tree")
	}
	pst: vx.Status
	if port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	open_session(connector)
	if !exchange() {
		fail("no ARP reply")
	}
	rt.print("nettest: ok\n")
	kill_driver(tasks)
	open_session(connector) // the restarted driver serves the same post
	if !exchange() {
		fail("no ARP reply from the restarted driver")
	}
	rt.print("nettest: ok after the restart\n")
	return 0
}
