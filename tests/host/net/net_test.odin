// lib/net against a scripted peer. The stack's frames are captured, and the
// peer's are built here: a DHCP exchange to a lease, its renewal and its
// expiry; ARP answers and lookups, with the packet that waited sent once the
// lookup is answered; ICMP echo both ways; UDP conversations; and frames that
// must be refused (bad checksums, fragments, lengths that lie). Each test
// also checks the digest of every frame the stack sent against upstream's.
package net_test

import vx "abi:vx"
import "core:testing"
import "vx:net"
import nt "../nettest"

MAC :: net.Mac{0x52, 0x54, 0, 0x12, 0x34, 0x56}
HOST_MAC :: net.Mac{0x52, 0x55, 10, 0, 2, 2}
GUEST :: net.Ip4(0x0a00_020f)
HOST :: net.Ip4(0x0a00_0202)
DNS :: net.Ip4(0x0a00_0203)
SECOND :: net.SECOND

DHCP_DISCOVER :: 1
DHCP_OFFER :: 2
DHCP_REQUEST :: 3
DHCP_ACK :: 5
DHCP_NAK :: 6

SENT_KEPT :: 16

// What the stack sent: the first SENT_KEPT frames, and the digest of all.
Capture :: struct {
	sent:   [SENT_KEPT][net.ETHER_MAX_FRAME]u8,
	size:   [SENT_KEPT]int,
	count:  int,
	digest: u64,
}

capture :: proc "contextless" (ctx: rawptr, frame: []u8) {
	c := (^Capture)(ctx)
	nt.digest_frame(&c.digest, frame)
	if c.count < SENT_KEPT {
		copy(c.sent[c.count][:], frame)
		c.size[c.count] = len(frame)
		c.count += 1
	}
}

// A stack, what it sent, and the frame the peer is building.
Fixture :: struct {
	stack: net.Net,
	cap:   Capture,
	in_:   nt.Frame,
}

fixture :: proc() -> ^Fixture {
	f := new(Fixture)
	f.cap.digest = nt.FNV_OFFSET
	return f
}

// The last frame sent, or nothing.
last :: proc(f: ^Fixture) -> []u8 {
	if f.cap.count == 0 {
		return nil
	}
	return f.cap.sent[f.cap.count - 1][:f.cap.size[f.cap.count - 1]]
}

bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

// Delivers the frame the peer built.
deliver :: proc(f: ^Fixture, now: vx.Instant) {
	net.input(&f.stack, nt.bytes(&f.in_), now)
}

udp_packet :: proc(f: ^Fixture, src: net.Ip4, sport: u16, dst: net.Ip4, dport: u16, data: []u8) -> []u8 {
	nt.udp_packet(&f.in_, MAC, HOST_MAC, src, sport, dst, dport, data)
	return nt.bytes(&f.in_)
}

ip_packet :: proc(f: ^Fixture, src, dst: net.Ip4, proto: net.Proto, payload: []u8) -> []u8 {
	nt.ip_packet(&f.in_, MAC, HOST_MAC, src, dst, proto, payload)
	return nt.bytes(&f.in_)
}

arp_packet :: proc(f: ^Fixture, op: u16, spa: net.Ip4, tha: net.Mac, tpa: net.Ip4, dst: net.Mac) -> []u8 {
	nt.arp_packet(&f.in_, dst, HOST_MAC, op, spa, tha, tpa)
	return nt.bytes(&f.in_)
}

// A DHCP reply of this type for transaction xid, offering GUEST.
dhcp_reply :: proc(f: ^Fixture, type: u8, xid: u32, lease: u32, truncated: bool) -> []u8 {
	b: [300]u8
	b[0], b[1], b[2] = 2, 1, 6
	nt.put32(b[4:], xid)
	nt.put32(b[16:], u32(GUEST))
	mac := MAC
	copy(b[28:], mac[:])
	nt.put32(b[236:], 0x6382_5363)
	o := 240
	option :: proc(b: []u8, o: ^int, code: u8, v: u32) {
		b[o^], b[o^ + 1] = code, 4
		nt.put32(b[o^ + 2:], v)
		o^ += 6
	}
	b[o], b[o + 1], b[o + 2] = 53, 1, type
	o += 3
	option(b[:], &o, 54, u32(HOST))
	option(b[:], &o, 1, 0xffff_ff00)
	option(b[:], &o, 3, u32(HOST))
	option(b[:], &o, 6, u32(DNS))
	option(b[:], &o, 51, lease)
	if truncated {
		b[o], b[o + 1] = 12, 200 // a host name that runs past the end
		o += 2
	} else {
		b[o] = 255
		o += 1
	}
	return udp_packet(f, HOST, 67, net.BROADCAST, 68, b[:o])
}

// The DHCP message type in a sent DHCP frame (and its xid), or 0.
dhcp_type :: proc(frame: []u8) -> (type: u8, xid: u32) {
	if len(frame) < 42 + 243 || nt.get16(frame[12:]) != 0x0800 || frame[23] != 17 || nt.get16(frame[36:]) != 67 {
		return
	}
	b := frame[42:]
	return b[242] if b[240] == 53 else 0, nt.get32(b[4:])
}

// A new conversation; a failure is a failed check, and the slot is still safe to use.
new_conv :: proc(t: ^testing.T, f: ^Fixture, proto: net.Proto, loc := #caller_location) -> (c: ^net.Conv, id: net.Conv_Id) {
	st: vx.Status
	id, st = net.conv_new(&f.stack, proto)
	testing.expect_value(t, st, vx.Status.Ok, loc = loc)
	return &f.stack.conv[id], id
}

@(test)
test_addresses :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	Parse :: struct {
		s:  string,
		ip: net.Ip4,
		ok: bool,
	}
	parses := []Parse {
		{"10.0.2.15", GUEST, true},
		{"255.255.255.255", net.BROADCAST, true},
		{"10.0.2", 0, false},
		{"10.0.2.256", 0, false},
		{"10.0.2.15 ", 0, false},
		{"1.2.3.0004", 0, false},
		{"", 0, false},
		{"1..2.3", 0, false},
	}
	for p in parses {
		ip, ok := net.parse_ip(p.s)
		testing.expectf(t, ok == p.ok, "parse_ip(%q): ok %v", p.s, ok)
		if ok {
			testing.expectf(t, ip == p.ip, "parse_ip(%q): %x", p.s, ip)
		}
	}
	buf: [net.IP4_TEXT_MAX]u8
	testing.expect_value(t, net.format_ip(&buf, GUEST), "10.0.2.15")
	testing.expect_value(t, net.format_ip(&buf, 0xc0a8_0064), "192.168.0.100")
	testing.expect_value(t, f.cap.digest, 0xcbf29ce484222325)
}

@(test)
test_dhcp :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	s := &f.stack
	now := 1000 * SECOND
	net.init(s, MAC, 1500, 42, capture, &f.cap)
	f.cap.count = 0
	net.dhcp_start(s, now)
	type, xid := dhcp_type(last(f))
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, type, DHCP_DISCOVER)
	testing.expect(t, nt.checksums_ok(last(f)))
	testing.expect_value(t, nt.mac_at(last(f)[:6]), net.BROADCAST_MAC)
	testing.expect_value(t, net.Ip4(nt.get32(last(f)[30:])), net.BROADCAST)

	// An offer for another transaction, or whose options run past the end, is ignored.
	net.input(s, dhcp_reply(f, DHCP_OFFER, xid + 1, 86400, false), now)
	net.input(s, dhcp_reply(f, DHCP_OFFER, xid, 86400, true), now)
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Selecting)

	// No answer: DISCOVER again, after 4 s, then 8 s.
	testing.expect_value(t, net.poll(s, now), now + 4 * SECOND)
	testing.expect_value(t, net.poll(s, now + 4 * SECOND), now + 12 * SECOND)
	testing.expect_value(t, f.cap.count, 2)
	now += 4 * SECOND

	net.input(s, dhcp_reply(f, DHCP_OFFER, xid, 86400, false), now)
	rtype, rxid := dhcp_type(last(f))
	testing.expect_value(t, f.cap.count, 3)
	testing.expect_value(t, rtype, DHCP_REQUEST)
	testing.expect_value(t, rxid, xid)
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Requesting)
	testing.expect_value(t, s.addr, 0)
	net.input(s, dhcp_reply(f, DHCP_ACK, xid, 86400, false), now)
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Bound)
	testing.expect_value(t, s.addr, GUEST)
	testing.expect_value(t, s.mask, 0xffff_ff00)
	testing.expect_value(t, s.gw, HOST)
	testing.expect_value(t, s.dns, DNS)
	testing.expect_value(t, s.dhcp.lease, 86400)
	testing.expect_value(t, net.poll(s, now), now + 43200 * SECOND) // T1: half the lease

	// At T1, a REQUEST to the server itself: its MAC first, by ARP; the request waits for the answer.
	now += 43200 * SECOND
	f.cap.count = 0
	_ = net.poll(s, now)
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, nt.get16(last(f)[12:]), 0x0806)
	testing.expect_value(t, net.Ip4(nt.get32(last(f)[38:])), HOST)
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Renewing)
	net.input(s, arp_packet(f, 2, HOST, MAC, GUEST, MAC), now)
	rtype, rxid = dhcp_type(last(f))
	testing.expect_value(t, f.cap.count, 2)
	testing.expect_value(t, rtype, DHCP_REQUEST)
	testing.expect_value(t, nt.mac_at(last(f)[:6]), HOST_MAC)
	testing.expect_value(t, net.Ip4(nt.get32(last(f)[42 + 12:])), GUEST) // ciaddr: the address renewed
	testing.expect(t, nt.checksums_ok(last(f)))
	net.input(s, dhcp_reply(f, DHCP_ACK, rxid, 86400, false), now)
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Bound)
	testing.expect_value(t, s.addr, GUEST)

	// No answer to renewals until the lease runs out: the address goes, and DISCOVER starts over.
	now += 43200 * SECOND
	_ = net.poll(s, now)
	for i := 0; i < 20000 && s.dhcp.state != .Selecting; i += 1 {
		now = net.poll(s, now)
	}
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Selecting)
	testing.expect_value(t, s.addr, 0)

	// A NAK while asking starts over too.
	net.input(s, dhcp_reply(f, DHCP_OFFER, s.dhcp.xid, 86400, false), now)
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Requesting)
	net.input(s, dhcp_reply(f, DHCP_NAK, s.dhcp.xid, 86400, false), now)
	testing.expect_value(t, s.dhcp.state, net.Dhcp_State.Selecting)
	testing.expect_value(t, f.cap.digest, 0x66938cf1aa3a7653)
}

configured :: proc(f: ^Fixture) {
	net.init(&f.stack, MAC, 1500, 7, capture, &f.cap)
	net.set_addr(&f.stack, GUEST, 0xffff_ff00, HOST)
	f.cap.count = 0
}

@(test)
test_arp :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	s := &f.stack
	configured(f)
	now := SECOND
	net.input(s, arp_packet(f, 1, HOST, {}, GUEST, net.BROADCAST_MAC), now)
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, nt.get16(last(f)[20:]), 2)
	testing.expect_value(t, nt.mac_at(last(f)[:6]), HOST_MAC)
	testing.expect_value(t, nt.mac_at(last(f)[22:28]), MAC)
	testing.expect_value(t, net.Ip4(nt.get32(last(f)[28:])), GUEST)
	testing.expect_value(t, net.Ip4(nt.get32(last(f)[38:])), HOST)
	e, found := net.arp_entry(s, HOST)
	testing.expect(t, found)
	testing.expect(t, found && e.resolved) // learned from the request

	// Another host's request: no answer, nothing learned (RFC 826).
	configured(f)
	net.input(s, arp_packet(f, 1, HOST, {}, 0x0a00_0209, net.BROADCAST_MAC), now)
	testing.expect_value(t, f.cap.count, 0)
	_, found = net.arp_entry(s, HOST)
	testing.expect(t, !found)

	// A lookup nobody answers: three requests in all, a second apart, then the packet is dropped.
	c, _ := new_conv(t, f, .Udp)
	testing.expect_value(t, net.conv_connect(s, c, 0x0a00_0209, 53), vx.Status.Ok)
	testing.expect_value(t, net.conv_write(s, c, 0, 0, bytes("q"), now), vx.Status.Ok)
	testing.expect_value(t, f.cap.count, 1)
	for next := net.poll(s, now); next != net.NEVER; next = net.poll(s, now) {
		now = next
	}
	testing.expect_value(t, f.cap.count, 3)
	_, found = net.arp_entry(s, 0x0a00_0209)
	testing.expect(t, !found)
	testing.expect_value(t, s.stats.dropped, 1)

	// Off the subnet: the gateway's MAC.
	net.input(s, arp_packet(f, 2, HOST, MAC, GUEST, MAC), now)
	f.cap.count = 0
	testing.expect_value(t, net.conv_write(s, c, 0x0808_0808, 53, bytes("q"), now), vx.Status.Ok)
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, nt.mac_at(last(f)[:6]), HOST_MAC)
	testing.expect_value(t, net.Ip4(nt.get32(last(f)[30:])), 0x0808_0808)
	testing.expect_value(t, f.cap.digest, 0x3358e385b4cb78d0)
}

@(test)
test_icmp :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	s := &f.stack
	configured(f)
	now := SECOND
	net.input(s, arp_packet(f, 2, HOST, MAC, GUEST, MAC), now)
	echo := [16]u8{8, 0, 0, 0, 0x12, 0x34, 0, 1, 'p', 'i', 'n', 'g', 'p', 'o', 'n', 'g'}
	nt.put16(echo[2:], nt.fold(nt.sum(0, echo[:])))
	f.cap.count = 0
	net.input(s, ip_packet(f, HOST, GUEST, .Icmp, echo[:]), now)
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, last(f)[34], 0)
	testing.expect_value(t, nt.get16(last(f)[38:]), 0x1234)
	testing.expect(t, nt.checksums_ok(last(f)))
	testing.expect_value(t, string(last(f)[42:50]), "pingpong")
	testing.expect_value(t, net.Ip4(nt.get32(last(f)[30:])), HOST)

	// A corrupted request, and one to another address, get nothing.
	echo[9] ~= 1
	net.input(s, ip_packet(f, HOST, GUEST, .Icmp, echo[:]), now)
	echo[9] ~= 1
	net.input(s, ip_packet(f, HOST, 0x0a00_0209, .Icmp, echo[:]), now)
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, s.stats.bad, 1)

	// A ping from a conversation: its identifier is the conversation's port; the reply comes back to it.
	c, _ := new_conv(t, f, .Icmp)
	testing.expect_value(t, net.conv_connect(s, c, HOST, 0), vx.Status.Ok)
	testing.expect(t, c.lport != 0)
	req := [12]u8{8, 0, 0, 0, 0, 0, 0, 7, 'a', 'b', 'c', 'd'}
	testing.expect_value(t, net.conv_write(s, c, 0, 0, req[:], now), vx.Status.Ok)
	testing.expect_value(t, f.cap.count, 2)
	testing.expect_value(t, net.Port(nt.get16(last(f)[38:])), c.lport)
	testing.expect(t, nt.checksums_ok(last(f)))
	reply: [12]u8
	copy(reply[:], last(f)[34:46])
	reply[0] = 0
	nt.put16(reply[2:], 0)
	nt.put16(reply[2:], nt.fold(nt.sum(0, reply[:])))
	net.input(s, ip_packet(f, HOST, GUEST, .Icmp, reply[:]), now)
	buf: [64]u8
	d, got, ok := net.conv_read(c, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, got, 12)
	testing.expect_value(t, d.addr, HOST)
	testing.expect_value(t, buf[0], 0)
	testing.expect_value(t, nt.get16(buf[6:]), 7)
	_, _, ok = net.conv_read(c, buf[:])
	testing.expect(t, !ok)

	// A reply with another identifier is not this conversation's.
	nt.put16(reply[4:], u16(c.lport) + 1)
	nt.put16(reply[2:], 0)
	nt.put16(reply[2:], nt.fold(nt.sum(0, reply[:])))
	net.input(s, ip_packet(f, HOST, GUEST, .Icmp, reply[:]), now)
	_, _, ok = net.conv_read(c, buf[:])
	testing.expect(t, !ok)
	testing.expect_value(t, f.cap.digest, 0x2678ac2a5d5193d3)
}

@(test)
test_udp :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	s := &f.stack
	configured(f)
	now := SECOND
	ca, a := new_conv(t, f, .Udp)
	cb, b := new_conv(t, f, .Udp)
	testing.expect_value(t, net.conv_announce(s, ca, 7777), vx.Status.Ok)
	testing.expect_value(t, net.conv_announce(s, cb, 7777), vx.Status.Err_Exists)
	testing.expect_value(t, net.conv_announce(s, cb, 0), vx.Status.Ok)
	testing.expect(t, cb.lport >= 49152)

	net.input(s, udp_packet(f, HOST, 5000, GUEST, 7777, bytes("hello")), now)
	buf: [64]u8
	d, got, ok := net.conv_read(ca, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(buf[:got]), "hello")
	testing.expect_value(t, d.addr, HOST)
	testing.expect_value(t, d.port, 5000)

	// A bad checksum, a length past the packet, and a fragment are refused.
	frame := udp_packet(f, HOST, 5000, GUEST, 7777, bytes("hello"))
	frame[len(frame) - 1] ~= 1
	deliver(f, now)
	frame = udp_packet(f, HOST, 5000, GUEST, 7777, bytes("hello"))
	nt.put16(frame[38:], 200)
	deliver(f, now)
	frame = udp_packet(f, HOST, 5000, GUEST, 7777, bytes("hello"))
	nt.put16(frame[20:], 0x2000) // more fragments
	nt.put16(frame[24:], 0)
	nt.put16(frame[24:], nt.fold(nt.sum(0, frame[14:34])))
	deliver(f, now)
	_, _, ok = net.conv_read(ca, buf[:])
	testing.expect(t, !ok)
	testing.expect_value(t, s.stats.bad, 2)

	// An IP length longer than the frame, and a header that claims to be longer than the packet.
	frame = udp_packet(f, HOST, 5000, GUEST, 7777, bytes("hello"))
	net.input(s, frame[:len(frame) - 3], now)
	_, _, ok = net.conv_read(ca, buf[:])
	testing.expect(t, !ok)
	testing.expect_value(t, s.stats.bad, 3)

	// Connected: only from there.
	testing.expect_value(t, net.conv_connect(s, ca, HOST, 6000), vx.Status.Ok)
	net.input(s, udp_packet(f, HOST, 5000, GUEST, 7777, bytes("other")), now)
	net.input(s, udp_packet(f, HOST, 6000, GUEST, 7777, bytes("peer")), now)
	d, got, ok = net.conv_read(ca, buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, got, 4)
	testing.expect_value(t, d.port, 6000)
	_, _, ok = net.conv_read(ca, buf[:])
	testing.expect(t, !ok)

	// A full queue drops; a short read loses the rest of its datagram only.
	big: [1473]u8
	for _ in 0 ..< 20 {
		net.input(s, udp_packet(f, HOST, 6000, GUEST, 7777, big[:1000]), now)
	}
	testing.expect(t, ca.dropped > 0)
	count := 0
	for {
		d, got, ok = net.conv_read(ca, buf[:3])
		if !ok {
			break
		}
		count += 1
		testing.expect_value(t, got, 3)
		testing.expect_value(t, d.len, 1000)
	}
	testing.expect_value(t, count, 20 - int(ca.dropped))
	testing.expect_value(t, ca.used, 0)

	// Sending: the payload, from our port, with a checksum the peer accepts.
	net.input(s, arp_packet(f, 2, HOST, MAC, GUEST, MAC), now)
	f.cap.count = 0
	testing.expect_value(t, net.conv_write(s, ca, 0, 0, bytes("out"), now), vx.Status.Ok)
	testing.expect_value(t, f.cap.count, 1)
	testing.expect_value(t, nt.get16(last(f)[34:]), 7777)
	testing.expect_value(t, nt.get16(last(f)[36:]), 6000)
	testing.expect(t, nt.checksums_ok(last(f)))
	testing.expect_value(t, net.conv_write(s, ca, 0, 0, big[:], now), vx.Status.Err_Range) // past the MTU

	net.conv_free(s, a, now)
	_, ok = net.conv_get(s, a)
	testing.expect(t, !ok)
	_, ok = net.conv_get(s, b)
	testing.expect(t, ok)
	testing.expect_value(t, f.cap.digest, 0x3b86b1491a0984b8)
}
