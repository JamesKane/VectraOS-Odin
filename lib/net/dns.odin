// vx:net's DNS: a stub resolver (RFC 1035).
//
// A records only, from the server DHCP named (or one set by hand), over UDP
// from a random port with a random ID, so an off-path forger must guess
// both. Answers are cached for their TTL (5 s to a day); failures for 10 s.
// A lookup does not wait: resolve answers Err_Should_Wait while the query is
// out, and the caller asks again later, as netd does for a held write.
//
// A reply is hostile. Every length is checked against what arrived; names
// follow compression pointers only backwards, so they cannot loop; the
// question must be the one asked; and only A records for the name asked, or
// for a name a CNAME chain (at most 8 long) leads to from it, are taken.
package net

import "abi:vx"

DNS_ENTRIES :: 16
DNS_ADDRS :: 4
DNS_NAME_MAX :: 253

// A name as text, normalized: lower case, no final dot.
Dns_Name :: [dynamic; DNS_NAME_MAX]u8

// A name's cache entry, or its query in flight.
Dns_Entry :: struct {
	name:          Dns_Name, // empty: unused
	pending:       bool,
	tries:         u8,
	id:            u16, // the query's ID
	port:          Port, // and the port it was sent from
	server:        Ip4,
	status:        vx.Status, // once answered: Ok, Err_Not_Found, Err_Refused or Err_Timed_Out
	addrs:         [dynamic; DNS_ADDRS]Ip4,
	expires, next: vx.Instant, // next: when to ask again
}

@(private="file")
TRIES :: 3
@(private="file")
NEGATIVE :: 10 * SECOND
@(private="file")
CHAIN_MAX :: 8

@(private="file")
Dns_Header :: struct #packed {
	id:      u16be,
	flags:   u8, // QR, opcode, AA, TC, RD
	rflags:  u8, // RA, Z, RCODE
	qdcount: u16be,
	ancount: u16be,
	nscount: u16be,
	arcount: u16be,
}
#assert(size_of(Dns_Header) == 12)

@(private="file")
DNS_RESPONSE :: 0x80 // QR, in flags
@(private="file")
DNS_RECURSE :: 0x01 // RD, in flags
@(private="file")
RCODE_NXDOMAIN :: 3
@(private="file")
TYPE_A :: 1
@(private="file")
TYPE_CNAME :: 5
@(private="file")
CLASS_IN :: 1

// A resource record's fixed part, after its owner name.
@(private="file")
Rr_Fixed :: struct #packed {
	type, class: u16be,
	ttl:         u32be,
	rdlen:       u16be,
}
#assert(size_of(Rr_Fixed) == 10)

@(private="file")
lower :: proc "contextless" (c: u8) -> u8 {
	return c - 'A' + 'a' if c >= 'A' && c <= 'Z' else c
}

// Normalizes a name for asking and comparing into out. Not ok unless it is
// one: labels of 1 to 63 letters, digits, '-' or '_', 253 characters in all.
@(private="file")
normalize :: proc "contextless" (name: string, out: ^Dns_Name) -> bool {
	s := name
	if len(s) > 0 && s[len(s) - 1] == '.' {
		s = s[:len(s) - 1]
	}
	if len(s) == 0 || len(s) > DNS_NAME_MAX {
		return false
	}
	clear(out)
	label := 0
	for c in transmute([]u8)s {
		if c == '.' {
			if label == 0 {
				return false
			}
			label = 0
		} else {
			ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
			label += 1
			if !ok || label > 63 {
				return false
			}
		}
		append(out, lower(c))
	}
	return label != 0
}

// Reads the name at start in message m as normalized text into out,
// following compression pointers (each must point before where it was
// found). Not ok if it is malformed. end is where the name ends in place.
@(private="file")
read_name :: proc "contextless" (m: []u8, start: int, out: ^Dns_Name) -> (end: int, ok: bool) {
	clear(out)
	at, limit := start, start
	jumped := false
	for _ in 0 ..< 128 {
		if at >= len(m) {
			return
		}
		l := int(m[at])
		if l & 0xc0 == 0xc0 { // a pointer: two bytes, to somewhere earlier
			if at + 1 >= len(m) {
				return
			}
			to := (l & 0x3f) << 8 | int(m[at + 1])
			if !jumped {
				end = at + 2
			}
			if to >= limit {
				return
			}
			jumped = true
			at, limit = to, to
			continue
		}
		if l & 0xc0 != 0 {
			return // the reserved label types
		}
		if l == 0 {
			if !jumped {
				end = at + 1
			}
			return end, true
		}
		// The text so far, with a dot after each label (the last one is
		// dropped), must leave room for this label and its dot in 254.
		text := len(out) + 1 if len(out) > 0 else 0
		if at + 1 + l > len(m) || text + l + 1 > DNS_NAME_MAX + 1 {
			return
		}
		if len(out) > 0 {
			append(out, '.')
		}
		for c in m[at + 1:][:l] {
			append(out, lower(c))
		}
		at += 1 + l
	}
	return
}

@(private="file")
same :: proc "contextless" (a, b: ^Dns_Name) -> bool {
	return string(a[:]) == string(b[:])
}

// One resource record, read in place.
@(private="file")
Record :: struct {
	name:               Dns_Name,
	type, class, rdlen: u16,
	ttl:                u32,
	rdata:              int, // where its data starts in the message
}

// Reads the record at at^, and moves at^ past it. False if it runs past the message.
@(private="file")
next_record :: proc "contextless" (m: []u8, at: ^int, r: ^Record) -> bool {
	next, ok := read_name(m, at^, &r.name)
	if !ok || next + size_of(Rr_Fixed) > len(m) {
		return false
	}
	f := load(m[next:], Rr_Fixed)
	r.type, r.class, r.ttl, r.rdlen = u16(f.type), u16(f.class), u32(f.ttl), u16(f.rdlen)
	r.rdata = next + size_of(Rr_Fixed)
	if r.rdata + int(r.rdlen) > len(m) {
		return false
	}
	at^ = r.rdata + int(r.rdlen)
	return true
}

@(private="file")
in_chain :: proc "contextless" (chain: ^[dynamic; CHAIN_MAX]Dns_Name, name: ^Dns_Name) -> bool {
	for &link in chain^ {
		if same(&link, name) {
			return true
		}
	}
	return false
}

@(private="file")
query_send :: proc "contextless" (n: ^Net, e: ^Dns_Entry, now: vx.Instant) {
	q: [size_of(Dns_Header) + DNS_NAME_MAX + 2 + 4]u8
	store(q[:], Dns_Header{id = u16be(e.id), flags = DNS_RECURSE, qdcount = 1}) // a standard query
	at := size_of(Dns_Header)
	label := 0 // where the label being copied starts in the name
	for i in 0 ..= len(e.name) {
		if i == len(e.name) || e.name[i] == '.' {
			q[at] = u8(i - label)
			at += 1
			copy(q[at:], e.name[label:i])
			at += i - label
			label = i + 1
		}
	}
	q[at] = 0
	at += 1
	put16(q[at:], TYPE_A)
	put16(q[at + 2:], CLASS_IN)
	at += 4
	_ = udp_out(n, n.addr, e.port, e.server, 53, q[:at], now)
	e.next = now + (SECOND << e.tries)
	e.tries += 1
}

// A reply to one of our queries, if it is one: true if it was taken.
@(private)
dns_input :: proc "contextless" (n: ^Net, src: Ip4, dport: Port, m: []u8, now: vx.Instant) -> bool {
	e: ^Dns_Entry
	for &d in n.dns_cache {
		if d.pending && d.port == dport && d.server == src {
			e = &d
		}
	}
	if e == nil {
		return false
	}
	if len(m) < size_of(Dns_Header) {
		return true // not its answer
	}
	h := load(m, Dns_Header)
	if u16(h.id) != e.id || h.flags & DNS_RESPONSE == 0 || h.qdcount != 1 {
		return true
	}
	// The question must be ours.
	question: Dns_Name
	at, ok := read_name(m, size_of(Dns_Header), &question)
	if !ok || at + 4 > len(m) || !same(&question, &e.name) || get16(m[at:]) != TYPE_A || get16(m[at + 2:]) != CLASS_IN {
		return true
	}
	at += 4
	rcode := h.rflags & 15
	e.pending = false
	if rcode != 0 {
		e.status = .Err_Not_Found if rcode == RCODE_NXDOMAIN else .Err_Refused // the server failed or refused
		e.expires = now + NEGATIVE
		return true
	}
	// The names that lead to the answer: ours, then each CNAME target from
	// it, in whatever order the records come.
	chain: [dynamic; CHAIN_MAX]Dns_Name
	append(&chain, e.name)
	answers := int(h.ancount)
	ttl := u32(86400)
	r: Record
	for grew := true; grew && len(chain) < CHAIN_MAX; {
		grew = false
		walk := at
		for _ in 0 ..< answers {
			if !next_record(m, &walk, &r) {
				break
			}
			if r.class != CLASS_IN || r.type != TYPE_CNAME || !in_chain(&chain, &r.name) {
				continue
			}
			target: Dns_Name
			if _, target_ok := read_name(m, r.rdata, &target); !target_ok {
				continue
			}
			if in_chain(&chain, &target) || len(chain) == CHAIN_MAX {
				continue
			}
			append(&chain, target)
			ttl = min(ttl, r.ttl)
			grew = true
		}
	}
	clear(&e.addrs)
	walk := at
	for _ in 0 ..< answers {
		if len(e.addrs) == DNS_ADDRS || !next_record(m, &walk, &r) {
			break
		}
		if r.class != CLASS_IN || r.type != TYPE_A || r.rdlen != 4 || !in_chain(&chain, &r.name) {
			continue
		}
		append(&e.addrs, Ip4(load(m[r.rdata:], u32be)))
		ttl = min(ttl, r.ttl)
	}
	if len(e.addrs) == 0 {
		e.status = .Err_Not_Found // the name has no address
		e.expires = now + NEGATIVE
		return true
	}
	e.status = .Ok
	e.expires = now + vx.Instant(max(ttl, 5)) * SECOND
	return true
}

// Retransmissions, and giving up. Returns the next deadline.
@(private)
dns_poll :: proc "contextless" (n: ^Net, now: vx.Instant) -> vx.Instant {
	next := NEVER
	for &e in n.dns_cache {
		if !e.pending {
			continue
		}
		if e.next <= now {
			if e.tries >= TRIES || n.addr == 0 {
				e.pending = false
				e.status = .Err_Timed_Out
				e.expires = now + NEGATIVE
				continue
			}
			query_send(n, &e, now)
		}
		next = min(next, e.next)
	}
	return next
}

// The addresses of name (a dotted quad is its own), as many as fit in addrs:
// how many. Err_Should_Wait while the query is out: ask again after the
// stack has had its input and timers. Err_Not_Found: no such name, or no
// address; Err_Timed_Out: no answer; Err_Bad_State: no address or DNS server
// yet; Err_Invalid: not a name.
@(require_results)
resolve :: proc "contextless" (n: ^Net, name: string, addrs: []Ip4, now: vx.Instant) -> (count: int, st: vx.Status) {
	if ip, ok := parse_ip(name); ok {
		if len(addrs) == 0 {
			return 0, .Ok
		}
		addrs[0] = ip
		return 1, .Ok
	}
	norm: Dns_Name
	if !normalize(name, &norm) {
		return 0, .Err_Invalid
	}
	e, victim: ^Dns_Entry
	for &d in n.dns_cache {
		if len(d.name) > 0 && same(&d.name, &norm) {
			e = &d
		}
		if !d.pending && (victim == nil || len(d.name) == 0 || d.expires < victim.expires) {
			victim = &d
		}
	}
	if e != nil && e.pending {
		return 0, .Err_Should_Wait
	}
	if e != nil && e.expires > now {
		if e.status != .Ok {
			return 0, e.status
		}
		count = copy(addrs, e.addrs[:])
		return count, .Ok
	}
	if n.addr == 0 || n.dns == 0 {
		return 0, .Err_Bad_State
	}
	if e == nil {
		e = victim
	}
	if e == nil {
		return 0, .Err_No_Memory // every entry is a query in flight
	}
	e^ = Dns_Entry {
		name    = norm,
		pending = true,
		server  = n.dns,
	}
	e.id = u16(random(n))
	e.port, _ = free_port(n, .Udp)
	query_send(n, e, now)
	return 0, .Err_Should_Wait
}
