package nettest

import vx "abi:vx"
import "vx:net"

FUZZ_MAC :: net.Mac{0x52, 0x54, 0, 0x12, 0x34, 0x56}

// Upstream's net fuzzer (tests/fuzz/net_fuzz.c), as a driver: arbitrary
// frames into two stacks. The input is frames, each a big-endian 16-bit
// length and its bytes, with time passing between them. One stack is in the
// middle of DHCP; the other is configured with an ICMP and a UDP
// conversation open, a TCP listener on 7777 and a TCP connect under way to
// 10.0.2.2!80. Whatever arrives, every frame sent must be a legal Ethernet
// frame whose IP header checksum holds, no queue may grow past its size, and
// whatever queued reads back whole; each breach counts in violations.
Net_Fuzz :: struct {
	dhcp, up:   net.Net,
	digest:     u64,
	violations: int,
	stream:     [512]u8,
	buf:        [net.CONV_QUEUE]u8,
}

@(private="file")
check_sent :: proc "contextless" (ctx: rawptr, frame: []u8) {
	f := (^Net_Fuzz)(ctx)
	digest_frame(&f.digest, frame)
	if len(frame) < 60 || len(frame) > net.ETHER_MAX_FRAME {
		f.violations += 1
		return
	}
	if get16(frame[12:]) == 0x0800 {
		total := int(get16(frame[16:]))
		if frame[14] != 0x45 || total < 20 || 14 + total > len(frame) || fold(sum(0, frame[14:34])) != 0 {
			f.violations += 1
		}
	}
}

@(private="file")
check_stack :: proc(f: ^Net_Fuzz, n: ^net.Net) {
	for &c in n.conv {
		if c.used > net.CONV_QUEUE || c.head >= net.CONV_QUEUE {
			f.violations += 1
		}
		t := &c.tcb
		if t.rlen > net.TCP_BUF || t.slen > net.TCP_BUF || t.rhead >= net.TCP_BUF || t.shead >= net.TCP_BUF {
			f.violations += 1
		}
		if c.proto == .Tcp && t.state > .Last_Ack {
			f.violations += 1
		}
	}
	for &e in n.arp {
		if int(e.queued) > len(e.packet) {
			f.violations += 1
		}
	}
}

@(private="file")
digest_stats :: proc(d: ^u64, s: net.Stats) {
	for v in ([4]u64{s.frames_in, s.frames_out, s.dropped, s.bad}) {
		b := transmute([8]u8)u64le(v)
		digest_bytes(d, b[:])
	}
}

// Runs one input. The digest covers every frame sent, every datagram read
// back, and both stacks' counters, as upstream's fuzzer does when built with
// the digest the cross-check adds.
net_fuzz :: proc(f: ^Net_Fuzz, data: []u8) {
	f.digest = FNV_OFFSET
	f.violations = 0
	f.stream = {}
	dhcp, up := &f.dhcp, &f.up
	now := vx.Instant(1_000_000_000)
	net.init(dhcp, FUZZ_MAC, 1500, 1, check_sent, f)
	net.dhcp_start(dhcp, now)
	net.init(up, FUZZ_MAC, 1500, 2, check_sent, f)
	net.set_addr(up, 0x0a00_020f, 0xffff_ff00, 0x0a00_0202)
	icmp, _ := net.conv_new(up, .Icmp)
	_ = net.conv_connect(up, &up.conv[icmp], 0x0a00_0202, 0)
	udp, _ := net.conv_new(up, .Udp)
	_ = net.conv_announce(up, &up.conv[udp], 7777)
	listener, _ := net.conv_new(up, .Tcp)
	_ = net.tcp_listen(up, &up.conv[listener], 7777)
	dial, _ := net.conv_new(up, .Tcp)
	_ = net.tcp_connect(up, &up.conv[dial], 0x0a00_0202, 80, now)

	for at := 0; at + 2 <= len(data); {
		size := min(int(get16(data[at:])), len(data) - at - 2)
		at += 2
		frame := data[at:][:size]
		net.input(dhcp, frame, now)
		net.input(up, frame, now)
		at += size
		now += vx.Instant(size & 0xff) * 100_000_000 // time passes: retransmissions and expiries happen
		_ = net.poll(dhcp, now)
		_ = net.poll(up, now)
		check_stack(f, dhcp)
		check_stack(f, up)
		// What the listener made can be taken, read from and written to.
		if id, st := net.tcp_accept(up, &up.conv[listener]); st == .Ok {
			_, _ = net.tcp_read(up, &up.conv[id], f.stream[:], now)
			_, _ = net.tcp_write(up, &up.conv[id], f.stream[:], now)
		}
	}
	// Whatever queued reads back whole.
	for &c in up.conv {
		for {
			d, got, ok := net.conv_read(&c, f.buf[:])
			if !ok {
				break
			}
			if got != int(d.len) {
				f.violations += 1
			}
			digest_bytes(&f.digest, f.buf[:got])
		}
	}
	digest_stats(&f.digest, up.stats)
	digest_stats(&f.digest, dhcp.stats)
}

// Upstream's DNS fuzzer (tests/fuzz/dns_fuzz.c), as a driver: a query is put
// in flight, and the input becomes its reply (with the query's ID, from the
// server, to the port it was sent from), so the parser sees everything.
// Whatever arrives, at most DNS_ADDRS addresses come back, and the resolver
// answers again without failing.
Dns_Fuzz :: struct {
	stack:      net.Net,
	digest:     u64,
	violations: int,
	frame:      [1500]u8,
}

@(private="file")
dns_sent :: proc "contextless" (ctx: rawptr, frame: []u8) {
	f := (^Dns_Fuzz)(ctx)
	digest_frame(&f.digest, frame)
}

FUZZ_NAME :: "fuzz.example"

// Runs one input. The digest covers every frame sent, then the second
// lookup's status, count and addresses.
dns_fuzz :: proc(f: ^Dns_Fuzz, data: []u8) {
	f.digest = FNV_OFFSET
	f.violations = 0
	n := &f.stack
	now := vx.Instant(1_000_000_000)
	net.init(n, FUZZ_MAC, 1500, 3, dns_sent, f)
	net.set_addr(n, 0x0a00_020f, 0xffff_ff00, 0x0a00_0202)
	n.dns = 0x0a00_0203
	addrs: [8]net.Ip4
	if _, st := net.resolve(n, FUZZ_NAME, addrs[:], now); st != .Err_Should_Wait {
		f.violations += 1
		return
	}
	e: ^net.Dns_Entry
	for &d in n.dns_cache {
		if d.pending {
			e = &d
		}
	}
	if e == nil || len(data) > 1400 {
		return
	}

	b := f.frame[:]
	for &x in b[:42] {
		x = 0
	}
	eth_header(b, FUZZ_MAC, {}, 0x0800)
	ip, u := b[14:34], b[34:42]
	ip[0], ip[8], ip[9] = 0x45, 64, 17
	put16(ip[2:], u16(28 + len(data)))
	put32(ip[12:], 0x0a00_0203)
	put32(ip[16:], 0x0a00_020f)
	put16(ip[10:], fold(sum(0, ip)))
	put16(u[0:], 53)
	put16(u[2:], u16(e.port))
	put16(u[4:], u16(8 + len(data)))
	copy(b[42:], data)
	if len(data) >= 2 {
		put16(b[42:], e.id) // its answer, as far as the ID goes
	}
	net.input(n, b[:42 + len(data)], now)

	count, st := net.resolve(n, FUZZ_NAME, addrs[:], now)
	st_bytes := transmute([4]u8)i32le(st)
	count_bytes := transmute([4]u8)u32le(count)
	digest_bytes(&f.digest, st_bytes[:])
	digest_bytes(&f.digest, count_bytes[:])
	for a in addrs[:count] {
		a_bytes := transmute([4]u8)u32le(a)
		digest_bytes(&f.digest, a_bytes[:])
	}
	if count > net.DNS_ADDRS || (st == .Ok && count == 0) {
		f.violations += 1
	}
}
