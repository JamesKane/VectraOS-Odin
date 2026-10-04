// lib/net's DNS stub resolver against hand-built replies: answers, the cache
// and its TTLs, CNAME chains in any order with compressed names, NXDOMAIN,
// retries and giving up; and replies that must be ignored: the wrong ID,
// port, server or question, and names that loop or run past the end of the
// message. Each test also checks the digest of every frame the stack sent
// against upstream's.
package dns_test

import vx "abi:vx"
import "core:strings"
import "core:testing"
import "vx:net"
import nt "../nettest"

MAC :: net.Mac{0x52, 0x54, 0, 0x12, 0x34, 0x56}
PEER_MAC :: net.Mac{0x52, 0x55, 10, 0, 2, 2}
GUEST :: net.Ip4(0x0a00_020f)
GW :: net.Ip4(0x0a00_0202)
DNS :: net.Ip4(0x0a00_0203)
SECOND :: net.SECOND

// A stack, the last frame it sent, and the reply being built.
Fixture :: struct {
	stack:  net.Net,
	now:    vx.Instant,
	last:   nt.Frame,
	sent:   int,
	digest: u64,
	msg:    [1024]u8,
	mlen:   int,
	frame:  nt.Frame,
}

capture :: proc "contextless" (ctx: rawptr, frame: []u8) {
	f := (^Fixture)(ctx)
	nt.digest_frame(&f.digest, frame)
	copy(f.last.buf[:], frame)
	f.last.len = len(frame)
	f.sent += 1
}

setup :: proc(f: ^Fixture) {
	f.now = 1000 * SECOND
	net.init(&f.stack, MAC, 1500, 5, capture, f)
	net.set_addr(&f.stack, GUEST, 0xffff_ff00, GW)
	f.stack.dns = DNS
	// The DNS server's MAC is known: queries go at once.
	arp: nt.Frame
	nt.arp_packet(&arp, MAC, PEER_MAC, 2, DNS, MAC, GUEST)
	net.input(&f.stack, nt.bytes(&arp), f.now)
	f.sent = 0
}

fixture :: proc() -> ^Fixture {
	f := new(Fixture)
	f.digest = nt.FNV_OFFSET
	setup(f)
	return f
}

// The last query sent: its ID, source port and name (as text, from the
// temporary allocator).
query :: proc(f: ^Fixture) -> (id, port: u16, name: string, ok: bool) {
	last := nt.bytes(&f.last)
	if f.sent == 0 || len(last) < 42 + 12 || nt.get16(last[12:]) != 0x0800 || last[23] != 17 || nt.get16(last[36:]) != 53 {
		return
	}
	port = nt.get16(last[34:])
	m := last[42:]
	id = nt.get16(m)
	b := strings.builder_make(context.temp_allocator)
	at := 12
	for m[at] != 0 {
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, '.')
		}
		strings.write_bytes(&b, m[at + 1:][:m[at]])
		at += 1 + int(m[at])
	}
	return id, port, strings.to_string(b), nt.get16(m[at + 1:]) == 1 && nt.get16(m[at + 3:]) == 1
}

// --- Building a reply ---

put_name :: proc(f: ^Fixture, name: string) {
	rest := name
	for label in strings.split_iterator(&rest, ".") {
		f.msg[f.mlen] = u8(len(label))
		copy(f.msg[f.mlen + 1:], label)
		f.mlen += 1 + len(label)
	}
	f.msg[f.mlen] = 0
	f.mlen += 1
}

begin :: proc(f: ^Fixture, id: u16, rcode: u8, answers: u16, qname: string) {
	f.msg = {}
	nt.put16(f.msg[0:], id)
	f.msg[2], f.msg[3] = 0x81, 0x80 | rcode // a response; recursion available
	nt.put16(f.msg[4:], 1)
	nt.put16(f.msg[6:], answers)
	f.mlen = 12
	put_name(f, qname)
	nt.put16(f.msg[f.mlen:], 1)
	nt.put16(f.msg[f.mlen + 2:], 1)
	f.mlen += 4
}

// A record's owner: a name, or (pointer >= 0) a pointer to one.
record :: proc(f: ^Fixture, owner: string, pointer: int, type: u16, ttl: u32, rdata: []u8) {
	if pointer >= 0 {
		f.msg[f.mlen], f.msg[f.mlen + 1] = u8(0xc0 | pointer >> 8), u8(pointer)
		f.mlen += 2
	} else {
		put_name(f, owner)
	}
	nt.put16(f.msg[f.mlen:], type)
	nt.put16(f.msg[f.mlen + 2:], 1)
	nt.put32(f.msg[f.mlen + 4:], ttl)
	nt.put16(f.msg[f.mlen + 8:], u16(len(rdata)))
	copy(f.msg[f.mlen + 10:], rdata)
	f.mlen += 10 + len(rdata)
}

// Delivers the reply, from server to port. Its UDP checksum is 0: none.
reply :: proc(f: ^Fixture, server: net.Ip4, port: u16) {
	b := f.frame.buf[:]
	nt.eth_header(b, MAC, PEER_MAC, 0x0800)
	ip, u := b[14:34], b[34:42]
	for &x in ip {
		x = 0
	}
	ip[0], ip[8], ip[9] = 0x45, 64, 17
	nt.put16(ip[2:], u16(28 + f.mlen))
	nt.put32(ip[12:], u32(server))
	nt.put32(ip[16:], u32(GUEST))
	nt.put16(ip[10:], nt.fold(nt.sum(0, ip)))
	nt.put16(u[0:], 53)
	nt.put16(u[2:], port)
	nt.put16(u[4:], u16(8 + f.mlen))
	nt.put16(u[6:], 0)
	copy(b[42:], f.msg[:f.mlen])
	net.input(&f.stack, b[:42 + f.mlen], f.now)
}

resolve :: proc(f: ^Fixture, name: string) -> (addrs: [4]net.Ip4, n: int, st: vx.Status) {
	n, st = net.resolve(&f.stack, name, addrs[:], f.now)
	return
}

@(test)
test_names :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	a, n, st := resolve(f, "10.0.2.2")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, a[0], GW)
	testing.expect_value(t, f.sent, 0) // no query
	invalid := []string {
		"",
		"a..b",
		"a b",
		".",
		"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.com", // 64
	}
	for name in invalid {
		_, _, st = resolve(f, name)
		testing.expectf(t, st == .Err_Invalid, "resolve(%q): %v", name, st)
	}
	testing.expect_value(t, f.sent, 0)
	f.stack.dns = 0
	_, _, st = resolve(f, "host.example")
	testing.expect_value(t, st, vx.Status.Err_Bad_State) // no server
	testing.expect_value(t, f.digest, 0xcbf29ce484222325)
}

@(test)
test_answer_and_cache :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	_, _, st := resolve(f, "Host.Example.")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	id, port, name, ok := query(f)
	testing.expect(t, ok)
	testing.expect_value(t, name, "host.example")
	testing.expect(t, port >= 49152)
	_, _, st = resolve(f, "host.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	testing.expect_value(t, f.sent, 1) // in flight: not asked twice

	// Forgeries are ignored: another ID, another port, another server, another question.
	addr := []u8{1, 2, 3, 4}
	begin(f, id + 1, 0, 1, "host.example")
	record(f, "", 12, 1, 60, addr)
	reply(f, DNS, port)
	begin(f, id, 0, 1, "host.example")
	record(f, "", 12, 1, 60, addr)
	reply(f, DNS, port + 1)
	reply(f, GW, port)
	begin(f, id, 0, 1, "other.example")
	record(f, "", 12, 1, 60, addr)
	reply(f, DNS, port)
	_, _, st = resolve(f, "host.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)

	begin(f, id, 0, 1, "HOST.example") // a server may change the case
	record(f, "", 12, 1, 60, addr)
	reply(f, DNS, port)
	a: [4]net.Ip4
	n: int
	a, n, st = resolve(f, "host.example")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, a[0], 0x0102_0304)
	before := f.sent
	f.now += 59 * SECOND
	_, _, st = resolve(f, "host.example")
	testing.expect_value(t, st, vx.Status.Ok) // from the cache
	testing.expect_value(t, f.sent, before)
	f.now += 2 * SECOND
	_, _, st = resolve(f, "host.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait) // expired: asked again
	testing.expect_value(t, f.sent, before + 1)
	testing.expect_value(t, f.digest, 0x4055dc12e8e3403c)
}

@(test)
test_cname_chain :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	_, _, st := resolve(f, "www.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	id, port, _, ok := query(f)
	testing.expect(t, ok)
	// The A records come before the CNAME that makes them relevant, and one A
	// is for a name off the chain.
	begin(f, id, 0, 4, "www.example")
	record(f, "web.example", -1, 1, 300, {5, 6, 7, 8})
	web := 12 + 13 + 4 // where web.example's name starts: after the question
	record(f, "", web, 1, 30, {5, 6, 7, 9})
	record(f, "evil.example", -1, 1, 300, {6, 6, 6, 6})
	record(f, "", 12, 5, 300, {0xc0, u8(web)}) // the CNAME's target: compressed
	reply(f, DNS, port)
	a: [4]net.Ip4
	n: int
	a, n, st = resolve(f, "www.example")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, a[0], 0x0506_0708)
	testing.expect_value(t, a[1], 0x0506_0709)
	f.now += 31 * SECOND
	_, _, st = resolve(f, "www.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait) // the shortest TTL on the chain ruled
	testing.expect_value(t, f.digest, 0x2be2ea29a7d6b6b8)
}

@(test)
test_failures :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	// NXDOMAIN: not found, remembered for a while.
	_, _, st := resolve(f, "nothing.invalid")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	id, port, _, ok := query(f)
	testing.expect(t, ok)
	begin(f, id, 3, 0, "nothing.invalid")
	reply(f, DNS, port)
	before := f.sent
	_, _, st = resolve(f, "nothing.invalid")
	testing.expect_value(t, st, vx.Status.Err_Not_Found)
	testing.expect_value(t, f.sent, before)
	f.now += 11 * SECOND
	_, _, st = resolve(f, "nothing.invalid")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)

	// A name with no address (NOERROR, no answers) is not found either.
	_, _, st = resolve(f, "empty.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	id, port, _, ok = query(f)
	testing.expect(t, ok)
	begin(f, id, 0, 0, "empty.example")
	reply(f, DNS, port)
	_, _, st = resolve(f, "empty.example")
	testing.expect_value(t, st, vx.Status.Err_Not_Found)

	// No answer: asked three times (after 1 s, then 2 s), then timed out. A
	// fresh stack, so no other query's retries are counted.
	setup(f)
	_, _, st = resolve(f, "silent.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	before = f.sent
	for {
		if _, _, st = resolve(f, "silent.example"); st != .Err_Should_Wait {
			break
		}
		next := net.poll(&f.stack, f.now)
		if next == net.NEVER {
			break
		}
		f.now = next
		_ = net.poll(&f.stack, f.now)
	}
	_, _, st = resolve(f, "silent.example")
	testing.expect_value(t, st, vx.Status.Err_Timed_Out)
	testing.expect_value(t, f.sent, before + 2)
	testing.expect_value(t, f.digest, 0x93ea38e938b357f4)
}

@(test)
test_hostile :: proc(t: ^testing.T) {
	f := fixture()
	defer free(f)
	_, _, st := resolve(f, "loop.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	id, port, _, ok := query(f)
	testing.expect(t, ok)
	addr := []u8{9, 9, 9, 9}
	// An answer whose owner points at itself, and one that points forward: not taken.
	begin(f, id, 0, 2, "loop.example")
	record(f, "", f.mlen, 1, 60, addr)
	record(f, "", 1000, 1, 60, addr)
	reply(f, DNS, port)
	_, _, st = resolve(f, "loop.example")
	testing.expect_value(t, st, vx.Status.Err_Not_Found) // answered, but nothing usable
	// A question whose name runs past the end: ignored, still waiting.
	_, _, st = resolve(f, "cut.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	id, port, _, ok = query(f)
	testing.expect(t, ok)
	begin(f, id, 0, 1, "cut.example")
	f.mlen = 16 // cut inside the name
	reply(f, DNS, port)
	_, _, st = resolve(f, "cut.example")
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	// More answers claimed than there are: the ones there are count.
	begin(f, id, 0, 50, "cut.example")
	record(f, "", 12, 1, 60, addr)
	reply(f, DNS, port)
	a: [4]net.Ip4
	n: int
	a, n, st = resolve(f, "cut.example")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, a[0], 0x0909_0909)
	testing.expect_value(t, f.digest, 0x5722837289cb24f7)
}
