// What the host tests of lib/net share: big-endian fields, the Internet
// checksum (written again here, so the stack's own is checked against an
// independent one), frame builders for a scripted peer, and the digest of
// every frame a stack sends. Imported relatively; it has no tests of its
// own, so ./build check runs it only through the suites that import it.
//
// The digest is FNV-1a over each frame's length (eight little-endian bytes)
// and then its bytes. The expected digests in the suites came from
// upstream's C (lib/vx-net, built with clang) running the same scenario, so
// a matching digest means every frame sent was the same, byte for byte, in
// the same order.
package nettest

import "core:testing"
import "vx:net"

FNV_OFFSET :: u64(0xcbf29ce484222325)
@(private="file")
FNV_PRIME :: u64(0x100000001b3)

digest_bytes :: proc "contextless" (d: ^u64, b: []u8) {
	for c in b {
		d^ = (d^ ~ u64(c)) * FNV_PRIME
	}
}

digest_frame :: proc "contextless" (d: ^u64, frame: []u8) {
	size := transmute([8]u8)u64le(len(frame))
	digest_bytes(d, size[:])
	digest_bytes(d, frame)
}

// --- Bytes on the wire ---

get16 :: proc "contextless" (b: []u8) -> u16 {
	return u16(b[0]) << 8 | u16(b[1])
}

get32 :: proc "contextless" (b: []u8) -> u32 {
	return u32(b[0]) << 24 | u32(b[1]) << 16 | u32(b[2]) << 8 | u32(b[3])
}

put16 :: proc "contextless" (b: []u8, v: u16) {
	b[0], b[1] = u8(v >> 8), u8(v)
}

put32 :: proc "contextless" (b: []u8, v: u32) {
	b[0], b[1], b[2], b[3] = u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)
}

// The Internet checksum's running sum (RFC 1071).
sum :: proc "contextless" (s: u32, b: []u8) -> u32 {
	s := s
	for i := 0; i + 1 < len(b); i += 2 {
		s += u32(get16(b[i:]))
	}
	if len(b) % 2 == 1 {
		s += u32(b[len(b) - 1]) << 8
	}
	return s
}

fold :: proc "contextless" (s: u32) -> u16 {
	s := s
	for s >> 16 != 0 {
		s = (s & 0xffff) + (s >> 16)
	}
	return ~u16(s)
}

pseudo :: proc "contextless" (src, dst: net.Ip4, proto: net.Proto, size: int) -> u32 {
	s, d := u32(src), u32(dst)
	return (s >> 16) + (s & 0xffff) + (d >> 16) + (d & 0xffff) + u32(proto) + u32(size)
}

// The MAC address at the front of b.
mac_at :: proc(b: []u8) -> (m: net.Mac) {
	copy(m[:], b[:6])
	return
}

// --- A scripted peer's frames ---

// A frame being built: the bytes and how many of them are in use.
Frame :: struct {
	buf: [net.ETHER_MAX_FRAME]u8,
	len: int,
}

bytes :: proc(f: ^Frame) -> []u8 {
	return f.buf[:f.len]
}

eth_header :: proc(b: []u8, dst, src: net.Mac, type: u16) {
	dst, src := dst, src
	copy(b[0:], dst[:])
	copy(b[6:], src[:])
	put16(b[12:], type)
}

eth :: proc(f: ^Frame, dst, src: net.Mac, type: u16) {
	eth_header(f.buf[:], dst, src, type)
	f.len = 14
}

// An IPv4 packet from src to dst, with a header checksum that holds.
ip_packet :: proc(f: ^Frame, dst_mac, src_mac: net.Mac, src, dst: net.Ip4, proto: net.Proto, payload: []u8) {
	eth(f, dst_mac, src_mac, 0x0800)
	ip := f.buf[14:34]
	for &b in ip {
		b = 0
	}
	ip[0] = 0x45
	put16(ip[2:], u16(20 + len(payload)))
	ip[8], ip[9] = 64, u8(proto)
	put32(ip[12:], u32(src))
	put32(ip[16:], u32(dst))
	put16(ip[10:], fold(sum(0, ip)))
	copy(f.buf[34:], payload)
	f.len = 34 + len(payload)
}

// A UDP datagram, with a checksum that holds.
udp_packet :: proc(f: ^Frame, dst_mac, src_mac: net.Mac, src: net.Ip4, sport: u16, dst: net.Ip4, dport: u16, data: []u8) {
	u: [1500]u8
	put16(u[0:], sport)
	put16(u[2:], dport)
	put16(u[4:], u16(8 + len(data)))
	copy(u[8:], data)
	s := fold(sum(pseudo(src, dst, .Udp, 8 + len(data)), u[:8 + len(data)]))
	put16(u[6:], s if s != 0 else 0xffff)
	ip_packet(f, dst_mac, src_mac, src, dst, .Udp, u[:8 + len(data)])
}

// An ARP packet from src_mac, whose sender address is spa.
arp_packet :: proc(f: ^Frame, dst_mac, src_mac: net.Mac, op: u16, spa: net.Ip4, tha: net.Mac, tpa: net.Ip4) {
	src_mac, tha := src_mac, tha
	eth(f, dst_mac, src_mac, 0x0806)
	a := f.buf[14:42]
	put16(a[0:], 1)
	put16(a[2:], 0x0800)
	a[4], a[5] = 6, 4
	put16(a[6:], op)
	copy(a[8:], src_mac[:])
	put32(a[14:], u32(spa))
	copy(a[18:], tha[:])
	put32(a[24:], u32(tpa))
	f.len = 42
}

// Whether a sent frame's IP checksum holds, and its ICMP or UDP one.
checksums_ok :: proc(f: []u8) -> bool {
	if len(f) < 34 {
		return false
	}
	ip := f[14:]
	total := int(get16(ip[2:]))
	if 14 + total > len(f) || total < 20 || fold(sum(0, ip[:20])) != 0 {
		return false
	}
	src, dst := net.Ip4(get32(ip[12:])), net.Ip4(get32(ip[16:]))
	payload := ip[20:total]
	switch net.Proto(ip[9]) {
	case .Icmp:
		return fold(sum(0, payload)) == 0
	case .Udp, .Tcp:
		return fold(sum(pseudo(src, dst, net.Proto(ip[9]), len(payload)), payload)) == 0
	case .None:
	}
	return false
}

// Checks a digest against upstream's, saying both in hex.
expect_digest :: proc(t: ^testing.T, got, want: u64, loc := #caller_location) {
	testing.expectf(t, got == want, "frames digest %016x, upstream's %016x", got, want, loc = loc)
}
