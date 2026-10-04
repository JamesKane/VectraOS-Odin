// vx:net, the first-party TCP/IP stack netd runs (upstream 04 §5 M3), as
// pure computation: the caller hands it each Ethernet frame that arrives and
// the time, calls poll when the deadline poll last returned comes, and gives
// it a procedure that sends a frame. Nothing here makes a system call, so the
// host tests drive it exactly as netd does.
//
// Ethernet, ARP, IPv4 (no fragments: they are dropped, and nothing sent is
// bigger than the MTU), ICMP echo, UDP, a DHCP client (RFC 2131), TCP
// (tcp.odin) and a DNS stub resolver (dns.odin). Loopback: a packet for
// 127/8, or for the interface's own address, never reaches the wire; it is
// queued, and poll takes it in, as if it had arrived. A packet for 127/8
// comes from the address it went to, as Linux's loopback has it, so both ends
// name the same pair; it needs no driver address.
//
// Conversations are Plan 9's (upstream 02 §5): numbered endpoints, each of
// one protocol, with a local port and, once connected, a remote address.
// Datagrams that arrive for one queue in it until read; a full queue drops
// them, as a full socket buffer does. An ICMP conversation's port is the
// echo identifier, as in Plan 9.
//
// Every frame is hostile: lengths are checked against what arrived before
// anything is read, checksums are verified, and nothing a peer sends grows a
// table past its fixed size. Packets are read as slices, so a check that was
// missed traps rather than reading past the frame; lengths on the wire are at
// most 16 bits and every check on them is made in int, so no sum overflows.
//
// Nothing allocates: a Net holds every table and ring (about 4.4 MiB), and
// the caller provides it. All zeroes is not a usable stack; init makes one.
package net

import "base:intrinsics"
import "abi:vx"
import "vx:memory"
import "vx:str"

ETHER_MAX_FRAME :: 1514 // 14 bytes of Ethernet header, 1500 of IP
CONVS :: 32
CONV_QUEUE :: 8192 // bytes of datagrams a conversation holds
ARP_ENTRIES :: 16
LOOP_BYTES :: 65536 // packets looped back, not yet taken in
IP4_TEXT_MAX :: 15 // "255.255.255.255"

// An IPv4 address, in host order (10.0.2.15 is 0x0a00020f).
Ip4 :: distinct u32
// A UDP or TCP port, or an ICMP conversation's echo identifier.
Port :: distinct u16
Mac :: [6]u8
// A conversation's number: its index in Net.conv.
Conv_Id :: distinct u32

BROADCAST :: Ip4(0xffff_ffff)
BROADCAST_MAC :: Mac{0xff, 0xff, 0xff, 0xff, 0xff, 0xff}
SECOND :: vx.Instant(1_000_000_000)
NEVER :: vx.INFINITE // a timer that is off

// A conversation's protocol, by its IP protocol number.
Proto :: enum u8 {
	None = 0, // a free conversation
	Icmp = 1,
	Tcp  = 6,
	Udp  = 17,
}

Dhcp_State :: enum u8 {
	Off, // a static address, or none
	Selecting, // DISCOVER sent
	Requesting, // REQUEST sent for an offer
	Bound,
	Renewing, // past T1: REQUEST to the server
	Rebinding, // past T2: REQUEST to anyone
}

Dhcp :: struct {
	state:                 Dhcp_State,
	xid:                   u32,
	offered, server:       Ip4,
	lease:                 u32, // seconds, as granted
	next, t1, t2, expires: vx.Instant,
	backoff:               u32, // seconds until the next retransmission
}

// A datagram as a conversation hands it out: where it came from, and its
// whole length (more than was read, if the read was short).
Datagram :: struct {
	addr: Ip4,
	port: Port,
	len:  u16,
}

Arp_Entry :: struct {
	ip:       Ip4, // 0: the slot is free
	mac:      Mac,
	resolved: bool,
	tries:    u8, // requests sent while unresolved
	deadline: vx.Instant, // resolved: when it expires; unresolved: when to ask again
	queued:   u16, // bytes of the one IP packet waiting for it, or 0
	packet:   [1500]u8,
}

Conv :: struct {
	proto:        Proto, // .None: free
	lport, rport: Port,
	raddr:        Ip4, // 0 until connected
	queue:        [CONV_QUEUE]u8, // a byte ring of queued headers, each followed by its payload
	head, used:   u32,
	dropped:      u64,
	tcb:          Tcb, // TCP's state
	sbuf:         [TCP_BUF]u8, // TCP: written, not yet acknowledged
	rbuf:         [TCP_BUF]u8, // TCP: received in order, not yet read
}

// The way out: one whole Ethernet frame, which the callee copies before it
// returns.
Send_Proc :: #type proc "contextless" (ctx: rawptr, frame: []u8)

Stats :: struct {
	frames_in, frames_out, dropped, bad: u64,
}

Net :: struct {
	ctx:                 rawptr,
	send:                Send_Proc,
	mac:                 Mac,
	mtu:                 u32,
	addr, mask, gw, dns: Ip4, // the interface's; addr is 0 until configured
	dhcp:                Dhcp,
	arp:                 [ARP_ENTRIES]Arp_Entry,
	dns_cache:           [DNS_ENTRIES]Dns_Entry,
	conv:                [CONVS]Conv,
	next_port:           Port,
	seed:                u32, // for transaction IDs and ports: not secret, only varied
	stats:               Stats,
	frame:               [ETHER_MAX_FRAME]u8, // the one being built
	// Looped-back IP packets, each after its length (2 bytes, little-endian).
	loop:                [LOOP_BYTES]u8,
	loop_head:           u32,
	loop_used:           u32,
}

// --- Bytes on the wire: network order ---

@(private="file")
ETHER_IP4 :: 0x0800
@(private="file")
ETHER_ARP :: 0x0806

// Where each layer starts in a frame being built.
@(private)
IP_AT :: 14
@(private)
L4_AT :: 34 // ICMP, UDP and TCP headers, after a 20-byte IP header
@(private="file")
UDP_DATA_AT :: 42

@(private="file")
Ether_Header :: struct #packed {
	dst, src: Mac,
	type:     u16be,
}
#assert(size_of(Ether_Header) == 14)

@(private="file")
Arp_Op :: enum u16 {
	Request = 1,
	Reply   = 2,
}

@(private="file")
Arp_Packet :: struct #packed {
	htype, ptype: u16be, // 1 (Ethernet), 0x0800 (IPv4)
	hlen, plen:   u8, // 6, 4
	op:           u16be,
	sha:          Mac,
	spa:          u32be,
	tha:          Mac,
	tpa:          u32be,
}
#assert(size_of(Arp_Packet) == 28)

@(private="file")
Ip4_Version :: bit_field u8 {
	ihl:     u8 | 4, // the header's length in words
	version: u8 | 4,
}

@(private="file")
Ip4_Header :: struct #packed {
	vihl:     Ip4_Version,
	tos:      u8,
	total:    u16be,
	id:       u16be,
	frag:     u16be, // flags and fragment offset
	ttl:      u8,
	proto:    u8,
	sum:      u16be,
	src, dst: u32be,
}
#assert(size_of(Ip4_Header) == 20)
#assert(offset_of(Ip4_Header, sum) == 10)

@(private="file")
IP_DONT_FRAGMENT :: 0x4000
@(private="file")
IP_FRAGMENT :: 0x3fff // more fragments to come, or an offset

@(private="file")
Udp_Header :: struct #packed {
	sport, dport: u16be,
	len:          u16be,
	sum:          u16be,
}
#assert(size_of(Udp_Header) == 8)

@(private="file")
Icmp_Header :: struct #packed {
	type, code: u8,
	sum:        u16be,
	id, seq:    u16be, // an echo's
}
#assert(size_of(Icmp_Header) == 8)

@(private="file")
ICMP_ECHO_REPLY :: 0
@(private="file")
ICMP_ECHO :: 8

// Reads a T from the front of b; b must hold one (the slice is checked).
@(private)
load :: #force_inline proc "contextless" (b: []u8, $T: typeid) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))
}

// Writes v at the front of b.
@(private)
store :: #force_inline proc "contextless" (b: []u8, v: $T) {
	v := v
	copy(b[:size_of(T)], memory.ptr_to_bytes(&v))
}

@(private)
get16 :: #force_inline proc "contextless" (b: []u8) -> u16 {
	return u16(load(b, u16be))
}

@(private)
put16 :: #force_inline proc "contextless" (b: []u8, v: u16) {
	store(b, u16be(v))
}

// The Internet checksum's running sum (RFC 1071), folded by fold.
@(private)
sum16 :: proc "contextless" (sum: u32, b: []u8) -> u32 {
	s := sum
	for i := 0; i + 1 < len(b); i += 2 {
		s += u32(b[i]) << 8 | u32(b[i + 1])
	}
	if len(b) & 1 != 0 {
		s += u32(b[len(b) - 1]) << 8
	}
	return s
}

@(private)
fold :: proc "contextless" (sum: u32) -> u16 {
	s := sum
	for s >> 16 != 0 {
		s = (s & 0xffff) + (s >> 16)
	}
	return ~u16(s)
}

// The UDP and TCP pseudo-header's sum.
@(private)
pseudo :: proc "contextless" (src, dst: Ip4, proto: Proto, size: int) -> u32 {
	s, d := u32(src), u32(dst)
	return (s >> 16) + (s & 0xffff) + (d >> 16) + (d & 0xffff) + u32(proto) + u32(size)
}

// xorshift32: varied, not secret.
@(private)
random :: proc "contextless" (n: ^Net) -> u32 {
	x := n.seed if n.seed != 0 else 0x9e37_79b9
	x ~= x << 13
	x ~= x >> 17
	x ~= x << 5
	n.seed = x
	return x
}

// --- Addresses as text: "10.0.2.15" ---

// Parses a dotted quad; not ok unless all of s is one. Each part is one to
// three digits, at most 255.
parse_ip :: proc "contextless" (s: string) -> (ip: Ip4, ok: bool) {
	v: u32
	i := 0
	for part in 0 ..< 4 {
		if part > 0 {
			if i >= len(s) || s[i] != '.' {
				return
			}
			i += 1
		}
		octet: u32
		digits := 0
		for ; i < len(s) && s[i] >= '0' && s[i] <= '9' && digits < 3; i += 1 {
			octet = octet * 10 + u32(s[i] - '0')
			digits += 1
		}
		if digits == 0 || octet > 255 {
			return
		}
		v = v << 8 | octet
	}
	if i != len(s) {
		return
	}
	return Ip4(v), true
}

// ip as a dotted quad, in buf.
format_ip :: proc "contextless" (buf: ^[IP4_TEXT_MAX]u8, ip: Ip4) -> string {
	n := 0
	for part := 3; part >= 0; part -= 1 {
		octet := u8(u32(ip) >> (8 * uint(part)))
		if octet >= 100 {
			buf[n] = '0' + octet / 100
			n += 1
		}
		if octet >= 10 {
			buf[n] = '0' + octet / 10 % 10
			n += 1
		}
		buf[n] = '0' + octet % 10
		n += 1
		if part > 0 {
			buf[n] = '.'
			n += 1
		}
	}
	return string(buf[:n])
}

// ip as a dotted quad, into b.
write_ip :: proc "contextless" (b: ^str.Buf, ip: Ip4) {
	buf: [IP4_TEXT_MAX]u8
	str.write_string(b, format_ip(&buf, ip))
}

// --- Sending ---

@(private="file")
ether_send :: proc "contextless" (n: ^Net, dst: Mac, type: u16, payload: int) {
	store(n.frame[:], Ether_Header{dst = dst, src = n.mac, type = u16be(type)})
	size := IP_AT + payload
	if size < 60 { // Ethernet's minimum, padded with zeros
		for &b in n.frame[size:60] {
			b = 0
		}
		size = 60
	}
	n.stats.frames_out += 1
	n.send(n.ctx, n.frame[:size])
}

@(private="file")
arp_send :: proc "contextless" (n: ^Net, op: Arp_Op, tha: Mac, tpa: Ip4, dst: Mac) {
	store(
		n.frame[IP_AT:],
		Arp_Packet {
			htype = 1,
			ptype = ETHER_IP4,
			hlen = 6,
			plen = 4,
			op = u16be(op),
			sha = n.mac,
			spa = u32be(n.addr),
			tha = tha,
			tpa = u32be(tpa),
		},
	)
	ether_send(n, dst, ETHER_ARP, size_of(Arp_Packet))
}

// Fills in an IPv4 header at IP_AT for size bytes of payload.
@(private)
ip_header :: proc "contextless" (n: ^Net, proto: Proto, src, dst: Ip4, size: int) {
	h := Ip4_Header {
		vihl = {ihl = 5, version = 4},
		total = u16be(20 + size),
		id = u16be(random(n) & 0xffff),
		frag = IP_DONT_FRAGMENT,
		ttl = 64,
		proto = u8(proto),
		src = u32be(src),
		dst = u32be(dst),
	}
	store(n.frame[IP_AT:], h)
	h.sum = u16be(fold(sum16(0, n.frame[IP_AT:L4_AT])))
	store(n.frame[IP_AT:], h)
}

// The ARP entry for ip, if there is one.
arp_entry :: proc "contextless" (n: ^Net, ip: Ip4) -> (e: ^Arp_Entry, ok: bool) {
	for &a in n.arp {
		if a.ip == ip {
			return &a, true
		}
	}
	return nil, false
}

// The ARP entry for ip, or a free (or else the oldest) one, emptied for it.
@(private="file")
arp_slot :: proc "contextless" (n: ^Net, ip: Ip4) -> ^Arp_Entry {
	victim := &n.arp[0]
	for &a in n.arp {
		if a.ip == ip {
			return &a
		}
		if a.ip == 0 || (victim.ip != 0 && a.deadline < victim.deadline) {
			victim = &a
		}
	}
	victim^ = Arp_Entry {
		ip = ip,
	}
	return victim
}

@(private)
loopback :: proc "contextless" (a: Ip4) -> bool {
	return a >> 24 == 127
}

// The address a packet to dst comes from: dst itself, for 127/8.
@(private)
source_for :: proc "contextless" (n: ^Net, dst: Ip4) -> Ip4 {
	return dst if loopback(dst) else n.addr
}

// Whether dst is reachable: on loopback always; otherwise once configured.
@(private)
can_send :: proc "contextless" (n: ^Net, dst: Ip4) -> bool {
	return loopback(dst) || n.addr != 0
}

// Queues the IP packet at IP_AT (size bytes) to be taken in by poll; a full
// queue drops it, as a full interface queue does.
@(private="file")
loop_put :: proc "contextless" (n: ^Net, size: int) {
	if 2 + size > LOOP_BYTES - int(n.loop_used) {
		n.stats.dropped += 1
		return
	}
	at := int(n.loop_head + n.loop_used) % LOOP_BYTES
	head := u16le(size)
	ring_write(n.loop[:], at, memory.ptr_to_bytes(&head))
	ring_write(n.loop[:], (at + 2) % LOOP_BYTES, n.frame[IP_AT:][:size])
	n.loop_used += u32(2 + size)
}

// Sends the IP packet built at IP_AT (size bytes, header included) to its
// next hop: at once if its MAC is known, or else once ARP finds it; or, for
// loopback and the interface's own address, back to this stack.
@(private)
ip_route :: proc "contextless" (n: ^Net, dst: Ip4, size: int, now: vx.Instant) {
	if loopback(dst) || (n.addr != 0 && dst == n.addr) {
		n.stats.frames_out += 1
		loop_put(n, size)
		return
	}
	if dst == BROADCAST || (n.mask != BROADCAST && n.addr != 0 && dst == (n.addr | ~n.mask)) {
		ether_send(n, BROADCAST_MAC, ETHER_IP4, size)
		return
	}
	hop := dst if (dst & n.mask) == (n.addr & n.mask) else n.gw
	if hop == 0 || n.addr == 0 {
		n.stats.dropped += 1 // no route
		return
	}
	e := arp_slot(n, hop)
	if e.resolved && e.deadline > now {
		ether_send(n, e.mac, ETHER_IP4, size)
		return
	}
	if e.resolved { // expired: ask again
		e^ = Arp_Entry {
			ip = hop,
		}
	}
	if e.queued != 0 {
		n.stats.dropped += 1 // one packet waits; the newest replaces it
	}
	copy(e.packet[:], n.frame[IP_AT:][:size])
	e.queued = u16(size)
	if e.tries == 0 {
		e.tries = 1
		e.deadline = now + SECOND
		arp_send(n, .Request, {}, hop, BROADCAST_MAC)
	}
}

// Sends a UDP datagram from src (an address, or 0 for none yet). data may
// already sit where the payload goes.
@(private)
udp_out :: proc "contextless" (n: ^Net, src: Ip4, sport: Port, dst: Ip4, dport: Port, data: []u8, now: vx.Instant) -> vx.Status {
	if len(data) > int(n.mtu) - 28 {
		return .Err_Range
	}
	size := size_of(Udp_Header) + len(data)
	u := n.frame[L4_AT:]
	copy(u[size_of(Udp_Header):], data) // a memmove
	h := Udp_Header {
		sport = u16be(sport),
		dport = u16be(dport),
		len   = u16be(size),
	}
	store(u, h)
	sum := fold(sum16(pseudo(src, dst, .Udp, size), u[:size]))
	h.sum = u16be(sum if sum != 0 else 0xffff)
	store(u, h)
	ip_header(n, .Udp, src, dst, size)
	ip_route(n, dst, 20 + size, now)
	return .Ok
}

// --- Conversations ---

// Conversation id, if it is in use.
conv_get :: proc "contextless" (n: ^Net, id: Conv_Id) -> (c: ^Conv, ok: bool) {
	if id >= CONVS || n.conv[id].proto == .None {
		return nil, false
	}
	return &n.conv[id], true
}

// The number of a conversation of n's.
@(private)
conv_id_of :: proc "contextless" (n: ^Net, c: ^Conv) -> Conv_Id {
	return Conv_Id((uintptr(c) - uintptr(&n.conv[0])) / size_of(Conv))
}

@(private="file")
port_used :: proc "contextless" (n: ^Net, proto: Proto, port: Port) -> bool {
	for &c in n.conv {
		if c.proto == proto && c.lport == port {
			return true
		}
	}
	return false
}

// A new conversation of this protocol.
@(require_results)
conv_new :: proc "contextless" (n: ^Net, proto: Proto) -> (id: Conv_Id, st: vx.Status) {
	if proto != .Icmp && proto != .Udp && proto != .Tcp {
		return 0, .Err_Invalid
	}
	for &c, i in n.conv {
		if c.proto != .None {
			continue
		}
		c.proto = proto
		c.lport, c.rport = 0, 0
		c.raddr = 0
		c.head, c.used = 0, 0
		c.dropped = 0
		c.tcb = Tcb { // the state, not the rings; no timers
			rto_at     = NEVER,
			persist_at = NEVER,
			linger_at  = NEVER,
		}
		return Conv_Id(i), .Ok
	}
	return 0, .Err_No_Memory
}

// The application let go of a conversation. A TCP connection stays until it
// has closed (tcp.odin).
conv_free :: proc "contextless" (n: ^Net, id: Conv_Id, now: vx.Instant) {
	if id >= CONVS {
		return
	}
	if n.conv[id].proto == .Tcp {
		tcp_free(n, &n.conv[id], now)
	} else {
		n.conv[id].proto = .None
	}
}

// A local port nothing of this protocol uses, from the dynamic range.
@(private)
free_port :: proc "contextless" (n: ^Net, proto: Proto) -> (port: Port, ok: bool) {
	for _ in 0 ..< 16384 {
		if n.next_port < 49152 {
			n.next_port = Port(49152 + random(n) % 16384)
		}
		port = n.next_port
		n.next_port += 1
		if !port_used(n, proto, port) {
			return port, true
		}
	}
	return 0, false
}

// Binds a conversation's local port: 0 picks a free one.
@(require_results)
conv_announce :: proc "contextless" (n: ^Net, c: ^Conv, port: Port) -> vx.Status {
	if c.lport != 0 {
		return .Err_Bad_State
	}
	port := port
	if port != 0 && port_used(n, c.proto, port) {
		return .Err_Exists
	}
	if port == 0 {
		ok: bool
		if port, ok = free_port(n, c.proto); !ok {
			return .Err_No_Memory
		}
	}
	c.lport = port
	return .Ok
}

// Connects a conversation to a remote address (and port, for UDP); it then
// receives only from there, and sends there.
@(require_results)
conv_connect :: proc "contextless" (n: ^Net, c: ^Conv, addr: Ip4, port: Port) -> vx.Status {
	if c.raddr != 0 || addr == 0 || (c.proto == .Udp && port == 0) {
		return .Err_Invalid
	}
	if c.lport == 0 {
		conv_announce(n, c, 0) or_return
	}
	c.raddr = addr
	c.rport = port
	return .Ok
}

// How a datagram's header is queued in front of its payload. Its size is
// what each datagram costs the queue beyond its payload, as upstream's.
@(private="file")
Queued :: struct #packed {
	addr: u32le,
	port: u16le,
	len:  u16le,
}
#assert(size_of(Queued) == 8)

// Copies src into ring from index at, wrapping at the end.
@(private)
ring_write :: proc "contextless" (ring: []u8, at: int, src: []u8) {
	first := min(len(src), len(ring) - at)
	copy(ring[at:], src[:first])
	copy(ring, src[first:])
}

// Fills dst from ring, from index at, wrapping at the end.
@(private)
ring_read :: proc "contextless" (dst: []u8, ring: []u8, at: int) {
	first := min(len(dst), len(ring) - at)
	copy(dst, ring[at:][:first])
	copy(dst[first:], ring)
}

@(private="file")
conv_queue :: proc "contextless" (c: ^Conv, addr: Ip4, port: Port, data: []u8) {
	if len(data) > 0xffff || size_of(Queued) + len(data) > CONV_QUEUE - int(c.used) {
		c.dropped += 1
		return
	}
	q := Queued {
		addr = u32le(addr),
		port = u16le(port),
		len  = u16le(len(data)),
	}
	at := int(c.head + c.used) % CONV_QUEUE
	ring_write(c.queue[:], at, memory.ptr_to_bytes(&q))
	ring_write(c.queue[:], (at + size_of(Queued)) % CONV_QUEUE, data)
	c.used += u32(size_of(Queued) + len(data))
}

// Takes the next datagram: its header, and as much of its payload as fits
// in buf (the rest is lost, as a short read of a datagram loses it). Not ok
// if none is queued.
@(require_results)
conv_read :: proc "contextless" (c: ^Conv, buf: []u8) -> (d: Datagram, got: int, ok: bool) {
	if c.used == 0 {
		return
	}
	q: Queued
	ring_read(memory.ptr_to_bytes(&q), c.queue[:], int(c.head))
	d = Datagram {
		addr = Ip4(q.addr),
		port = Port(q.port),
		len  = u16(q.len),
	}
	got = min(int(d.len), len(buf))
	ring_read(buf[:got], c.queue[:], (int(c.head) + size_of(Queued)) % CONV_QUEUE)
	c.head = (c.head + size_of(Queued) + u32(d.len)) % CONV_QUEUE
	c.used -= size_of(Queued) + u32(d.len)
	return d, got, true
}

// Sends on a connected conversation (or, given addr and port, an announced
// UDP one). UDP: data is the payload. ICMP: data is the whole message, type
// and code first; the identifier becomes the conversation's port and the
// checksum is filled in.
@(require_results)
conv_write :: proc "contextless" (n: ^Net, c: ^Conv, addr: Ip4, port: Port, data: []u8, now: vx.Instant) -> vx.Status {
	addr, port := addr, port
	if addr == 0 {
		addr, port = c.raddr, c.rport
	}
	if addr == 0 || c.lport == 0 {
		return .Err_Bad_State
	}
	if !can_send(n, addr) {
		return .Err_Bad_State // no address yet
	}
	if c.proto == .Udp {
		return udp_out(n, source_for(n, addr), c.lport, addr, port, data, now)
	}
	if len(data) < size_of(Icmp_Header) || len(data) > int(n.mtu) - 20 {
		return .Err_Invalid
	}
	m := n.frame[L4_AT:][:len(data)]
	copy(m, data)
	h := load(m, Icmp_Header)
	h.sum = 0
	h.id = u16be(c.lport)
	store(m, h)
	h.sum = u16be(fold(sum16(0, m)))
	store(m, h)
	ip_header(n, .Icmp, source_for(n, addr), addr, len(data))
	ip_route(n, addr, 20 + len(data), now)
	return .Ok
}

// --- DHCP (RFC 2131) ---

@(private="file")
Dhcp_Type :: enum u8 {
	Discover = 1,
	Offer,
	Request,
	Decline,
	Ack,
	Nak,
}

@(private="file")
Dhcp_Option :: enum u8 {
	Pad       = 0,
	Mask      = 1,
	Router    = 3,
	Dns       = 6,
	Requested = 50,
	Lease     = 51,
	Type      = 53,
	Server    = 54,
	Params    = 55,
	T1        = 58,
	T2        = 59,
	End       = 255,
}

// BOOTP's fixed part, through the magic cookie.
@(private="file")
Bootp :: struct #packed {
	op, htype, hlen, hops:          u8,
	xid:                            u32be,
	secs, flags:                    u16be,
	ciaddr, yiaddr, siaddr, giaddr: u32be,
	chaddr:                         Mac,
	chaddr_pad:                     [10]u8,
	sname:                          [64]u8,
	file:                           [128]u8,
	cookie:                         u32be,
}
#assert(size_of(Bootp) == 240)
#assert(offset_of(Bootp, chaddr) == 28)

@(private="file")
DHCP_COOKIE :: 0x6382_5363
@(private="file")
BOOTP_MIN :: 300 // BOOTP's minimum message

@(private="file")
put_option :: proc "contextless" (o: ^str.Buf, code: Dhcp_Option, value: ..u8) {
	str.write_byte(o, u8(code))
	str.write_byte(o, u8(len(value)))
	str.write_bytes(o, value)
}

@(private="file")
put_option_ip :: proc "contextless" (o: ^str.Buf, code: Dhcp_Option, ip: Ip4) {
	v := u32be(ip)
	put_option(o, code, ..memory.ptr_to_bytes(&v))
}

@(private="file")
dhcp_send :: proc "contextless" (n: ^Net, type: Dhcp_Type, now: vx.Instant) {
	b := n.frame[UDP_DATA_AT:][:BOOTP_MIN] // after the Ethernet, IP and UDP headers
	renewing := n.dhcp.state == .Renewing || n.dhcp.state == .Rebinding
	h := Bootp {
		op    = 1, // a request
		htype = 1, // Ethernet addresses
		hlen  = 6,
		xid   = u32be(n.dhcp.xid),
	}
	if renewing {
		h.ciaddr = u32be(n.addr)
	} else {
		h.flags = 0x8000 // answer by broadcast: we have no address yet
	}
	h.chaddr = n.mac
	h.cookie = DHCP_COOKIE
	store(b, h)
	o := str.Buf {
		buf = b[size_of(Bootp):],
	}
	put_option(&o, .Type, u8(type))
	if type == .Request && !renewing {
		put_option_ip(&o, .Requested, n.dhcp.offered)
		put_option_ip(&o, .Server, n.dhcp.server) // the server chosen
	}
	put_option(&o, .Params, u8(Dhcp_Option.Mask), u8(Dhcp_Option.Router), u8(Dhcp_Option.Dns), u8(Dhcp_Option.Lease))
	str.write_byte(&o, u8(Dhcp_Option.End))
	for &pad in o.buf[o.len:] {
		pad = 0
	}
	unicast := n.dhcp.state == .Renewing
	src := n.addr if renewing else 0
	_ = udp_out(n, src, 68, n.dhcp.server if unicast else BROADCAST, 67, b, now)
}

// Starts DHCP from the beginning: forgets any address and sends DISCOVER.
dhcp_start :: proc "contextless" (n: ^Net, now: vx.Instant) {
	n.addr, n.gw, n.dns = 0, 0, 0
	n.mask = 0
	n.dhcp = Dhcp {
		state   = .Selecting,
		xid     = random(n),
		backoff = 4,
	}
	n.dhcp.next = now + 4 * SECOND
	dhcp_send(n, .Discover, now)
}

// A static address: DHCP stops.
set_addr :: proc "contextless" (n: ^Net, addr, mask, gw: Ip4) {
	n.dhcp.state = .Off
	n.addr, n.mask, n.gw = addr, mask, gw
}

@(private="file")
dhcp_input :: proc "contextless" (n: ^Net, b: []u8, now: vx.Instant) {
	if len(b) < size_of(Bootp) {
		return
	}
	h := load(b, Bootp)
	if h.op != 2 || u32(h.xid) != n.dhcp.xid || h.chaddr != n.mac || h.cookie != DHCP_COOKIE {
		return
	}
	type: u8
	server, mask, router, dns: Ip4
	lease, t1, t2: u32
	for o := size_of(Bootp); o < len(b) && b[o] != u8(Dhcp_Option.End); { // code, length, value
		if b[o] == u8(Dhcp_Option.Pad) {
			o += 1
			continue
		}
		if o + 2 > len(b) || o + 2 + int(b[o + 1]) > len(b) {
			return // runs past the end
		}
		code, v := Dhcp_Option(b[o]), b[o + 2:][:b[o + 1]]
		if code == .Type && len(v) == 1 {
			type = v[0]
		}
		if len(v) >= 4 {
			x := u32(load(v, u32be))
			#partial switch code {
			case .Server:
				server = Ip4(x)
			case .Mask:
				mask = Ip4(x)
			case .Router:
				router = Ip4(x)
			case .Dns:
				dns = Ip4(x)
			case .Lease:
				lease = x
			case .T1:
				t1 = x
			case .T2:
				t2 = x
			}
		}
		o += 2 + len(v)
	}
	yiaddr := Ip4(h.yiaddr)
	if n.dhcp.state == .Selecting && Dhcp_Type(type) == .Offer && yiaddr != 0 && server != 0 {
		n.dhcp.offered = yiaddr
		n.dhcp.server = server
		n.dhcp.state = .Requesting
		n.dhcp.backoff = 4
		n.dhcp.next = now + 4 * SECOND
		dhcp_send(n, .Request, now)
		return
	}
	asking := n.dhcp.state == .Requesting || n.dhcp.state == .Renewing || n.dhcp.state == .Rebinding
	if !asking {
		return
	}
	if Dhcp_Type(type) == .Nak {
		dhcp_start(n, now)
		return
	}
	if Dhcp_Type(type) != .Ack || yiaddr == 0 {
		return
	}
	// A mask must be contiguous ones; without one, the classless default is /24.
	if mask == 0 || (~mask & (~mask + 1)) != 0 {
		mask = 0xffff_ff00
	}
	if lease < 60 {
		lease = 60 // a server's zero or tiny lease would have us ask forever
	}
	n.addr, n.mask, n.gw, n.dns = yiaddr, mask, router, dns
	n.dhcp.state = .Bound
	if server != 0 {
		n.dhcp.server = server
	}
	n.dhcp.lease = lease
	if t1 == 0 || t1 >= lease {
		t1 = lease / 2
	}
	if t2 == 0 || t2 >= lease || t2 <= t1 {
		t2 = lease / 8 * 7
	}
	n.dhcp.t1 = now + vx.Instant(t1) * SECOND
	n.dhcp.t2 = now + vx.Instant(t2) * SECOND
	n.dhcp.expires = now + vx.Instant(lease) * SECOND
	n.dhcp.next = n.dhcp.t1
}

// --- Receiving ---

@(private="file")
arp_input :: proc "contextless" (n: ^Net, b: []u8, now: vx.Instant) {
	if len(b) < size_of(Arp_Packet) {
		return
	}
	a := load(b, Arp_Packet)
	if a.htype != 1 || a.ptype != ETHER_IP4 || a.hlen != 6 || a.plen != 4 {
		return
	}
	spa, tpa := Ip4(a.spa), Ip4(a.tpa)
	if spa == 0 || a.sha[0] & 1 != 0 {
		return // a probe, or a multicast sender: nothing to learn
	}
	for_us := n.addr != 0 && tpa == n.addr
	// RFC 826: update an entry we have; make one only if the packet is for us.
	e, found := arp_entry(n, spa)
	if !found && for_us {
		e, found = arp_slot(n, spa), true
	}
	if found {
		e.mac = a.sha
		e.resolved = true
		e.tries = 0
		e.deadline = now + 600 * SECOND
		if e.queued != 0 {
			queued := int(e.queued)
			copy(n.frame[IP_AT:], e.packet[:queued])
			e.queued = 0
			ether_send(n, e.mac, ETHER_IP4, queued)
		}
	}
	if for_us && Arp_Op(a.op) == .Request {
		arp_send(n, .Reply, a.sha, spa, a.sha)
	}
}

@(private="file")
deliver :: proc "contextless" (n: ^Net, proto: Proto, lport: Port, src: Ip4, sport: Port, data: []u8) {
	for &c in n.conv {
		if c.proto != proto || c.lport != lport {
			continue
		}
		if c.raddr != 0 && (c.raddr != src || (proto == .Udp && c.rport != sport)) {
			continue
		}
		conv_queue(&c, src, sport, data)
		return
	}
	n.stats.dropped += 1 // nobody listening
}

@(private="file")
icmp_input :: proc "contextless" (n: ^Net, src, dst: Ip4, m: []u8, now: vx.Instant) {
	if len(m) < size_of(Icmp_Header) || fold(sum16(0, m)) != 0 {
		n.stats.bad += 1
		return
	}
	h := load(m, Icmp_Header)
	if h.type == ICMP_ECHO && h.code == 0 && (dst == n.addr || loopback(dst)) { // for us: the same back, as a reply
		r := n.frame[L4_AT:][:len(m)]
		copy(r, m)
		h.type = ICMP_ECHO_REPLY
		h.sum = 0
		store(r, h)
		h.sum = u16be(fold(sum16(0, r)))
		store(r, h)
		ip_header(n, .Icmp, source_for(n, src), src, len(m))
		ip_route(n, src, 20 + len(m), now)
		return
	}
	if h.type == ICMP_ECHO_REPLY {
		deliver(n, .Icmp, Port(h.id), src, 0, m) // a reply, by identifier
	}
}

@(private="file")
udp_input :: proc "contextless" (n: ^Net, src, dst: Ip4, b: []u8, now: vx.Instant) {
	if len(b) < size_of(Udp_Header) {
		n.stats.bad += 1
		return
	}
	h := load(b, Udp_Header)
	size := int(h.len)
	if size < size_of(Udp_Header) || size > len(b) {
		n.stats.bad += 1
		return
	}
	u := b[:size] // the IP payload may be padded
	if h.sum != 0 && fold(sum16(pseudo(src, dst, .Udp, size), u)) != 0 {
		n.stats.bad += 1
		return
	}
	sport, dport := Port(h.sport), Port(h.dport)
	data := u[size_of(Udp_Header):]
	if dport == 68 && sport == 67 {
		dhcp_input(n, data, now)
		return
	}
	if sport == 53 && n.addr != 0 && dst == n.addr && dns_input(n, src, dport, data, now) {
		return
	}
	if !loopback(dst) && (n.addr == 0 || (dst != n.addr && dst != BROADCAST)) {
		return
	}
	deliver(n, .Udp, dport, src, sport, data)
}

// An IP packet, from the wire or (looped) from the loopback queue; 127/8 on
// the wire is a forgery (RFC 1122 §3.2.1.3), and dropped.
@(private="file")
ip_input :: proc "contextless" (n: ^Net, b: []u8, looped: bool, now: vx.Instant) {
	if len(b) < size_of(Ip4_Header) {
		n.stats.bad += 1
		return
	}
	h := load(b, Ip4_Header)
	hlen, total := int(h.vihl.ihl) * 4, int(h.total)
	if h.vihl.version != 4 || hlen < 20 || total < hlen || total > len(b) || fold(sum16(0, b[:hlen])) != 0 {
		n.stats.bad += 1
		return
	}
	if h.frag & IP_FRAGMENT != 0 { // not reassembled
		n.stats.dropped += 1
		return
	}
	src, dst := Ip4(h.src), Ip4(h.dst)
	if !looped && (loopback(src) || loopback(dst)) {
		n.stats.bad += 1
		return
	}
	ours := dst == BROADCAST || loopback(dst) || (n.addr != 0 && (dst == n.addr || dst == (n.addr | ~n.mask)))
	dhcp := n.dhcp.state != .Off && Proto(h.proto) == .Udp // an offer may come to the address it offers
	if !ours && !dhcp {
		return
	}
	payload := b[hlen:total]
	#partial switch Proto(h.proto) {
	case .Icmp:
		icmp_input(n, src, dst, payload, now)
	case .Udp:
		udp_input(n, src, dst, payload, now)
	case .Tcp:
		tcp_input(n, src, dst, payload, now)
	}
}

// One Ethernet frame that arrived, without its FCS.
input :: proc "contextless" (n: ^Net, frame: []u8, now: vx.Instant) {
	n.stats.frames_in += 1
	if len(frame) < size_of(Ether_Header) || len(frame) > ETHER_MAX_FRAME {
		n.stats.bad += 1
		return
	}
	h := load(frame, Ether_Header)
	if h.dst != n.mac && h.dst != BROADCAST_MAC {
		return // not ours
	}
	switch h.type {
	case ETHER_ARP:
		arp_input(n, frame[size_of(Ether_Header):], now)
	case ETHER_IP4:
		ip_input(n, frame[size_of(Ether_Header):], false, now)
	}
}

// Does what is due by now (retransmissions, renewals, expiries) and returns
// when to be called again.
poll :: proc "contextless" (n: ^Net, now: vx.Instant) -> vx.Instant {
	next := NEVER
	// What was looped back, as many packets as were queued when this began:
	// replies they make wait for the next call, which is due at once.
	for queued := n.loop_used; queued > 0; {
		head: u16le
		ring_read(memory.ptr_to_bytes(&head), n.loop[:], int(n.loop_head))
		size := u32(head)
		packet: [ETHER_MAX_FRAME]u8
		ring_read(packet[:size], n.loop[:], int(n.loop_head + 2) % LOOP_BYTES)
		n.loop_head = (n.loop_head + 2 + size) % LOOP_BYTES
		n.loop_used -= 2 + size
		queued -= 2 + size
		n.stats.frames_in += 1
		ip_input(n, packet[:size], true, now)
	}
	if n.loop_used != 0 {
		next = now
	}
	for &e in n.arp {
		if e.ip == 0 || e.resolved {
			continue
		}
		if e.deadline <= now {
			if e.tries == 3 { // nobody answered: give up, and drop what waited
				if e.queued != 0 {
					n.stats.dropped += 1
				}
				e = {}
				continue
			}
			e.tries += 1
			e.deadline = now + SECOND
			arp_send(n, .Request, {}, e.ip, BROADCAST_MAC)
		}
		next = min(next, e.deadline)
	}
	for &c in n.conv {
		if c.proto == .Tcp {
			next = min(next, tcp_poll(n, &c, now))
		}
	}
	next = min(next, dns_poll(n, now))
	if n.dhcp.state == .Off {
		return next
	}
	bound := n.dhcp.state == .Bound || n.dhcp.state == .Renewing || n.dhcp.state == .Rebinding
	// The lease ran out, and the address goes; or the offer's server stopped
	// answering (RFC 2131 §4.4.1): start again.
	unanswered := n.dhcp.next <= now && n.dhcp.state == .Requesting && n.dhcp.backoff >= 32
	if (bound && now >= n.dhcp.expires) || unanswered {
		dhcp_start(n, now)
	} else if n.dhcp.next <= now {
		if n.dhcp.state == .Bound || (n.dhcp.state == .Renewing && now >= n.dhcp.t2) {
			n.dhcp.state = .Renewing if n.dhcp.state == .Bound else .Rebinding
			n.dhcp.xid = random(n)
			n.dhcp.backoff = 4
		} else if n.dhcp.backoff < 64 {
			n.dhcp.backoff *= 2
		}
		dhcp_send(n, .Discover if n.dhcp.state == .Selecting else .Request, now)
		n.dhcp.next = now + vx.Instant(n.dhcp.backoff) * SECOND
		if bound {
			limit := n.dhcp.t2 if n.dhcp.state == .Renewing else n.dhcp.expires
			n.dhcp.next = min(n.dhcp.next, limit)
		}
	}
	return min(n.dhcp.next, next)
}

// Sets up a stack for an interface. Its address comes from dhcp_start or
// set_addr. An MTU outside 576..1500 is taken as 1500.
init :: proc "contextless" (n: ^Net, mac: Mac, mtu: u32, seed: u32, send: Send_Proc, ctx: rawptr) {
	n^ = {}
	n.mac = mac
	n.mtu = 1500 if mtu > 1500 || mtu < 576 else mtu
	n.seed = seed
	n.send = send
	n.ctx = ctx
}
