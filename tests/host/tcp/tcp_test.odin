// lib/net's TCP between two whole stacks, a client (10.0.2.15) and a server
// (10.0.2.2), joined by a simulated wire that can lose frames. Time is the
// test's: when nothing is moving, it jumps to the next deadline either stack
// asked for. Hand-built segments check what a hostile peer cannot do: reset a
// connection with a guessed sequence number. Each test also checks the
// digest of every frame either stack sent against upstream's.
package tcp_test

import vx "abi:vx"
import "core:testing"
import "vx:net"
import nt "../nettest"

C_MAC :: net.Mac{0x52, 0x54, 0, 0x12, 0x34, 0x56}
S_MAC :: net.Mac{0x52, 0x55, 10, 0, 2, 2}
C_IP :: net.Ip4(0x0a00_020f)
S_IP :: net.Ip4(0x0a00_0202)
SECOND :: net.SECOND

// --- The wire: a queue of frames each way ---

WIRE_FRAMES :: 1024

Wire :: struct {
	frames:      [WIRE_FRAMES][net.ETHER_MAX_FRAME]u8,
	size:        [WIRE_FRAMES]int,
	head, count: int,
	sim:         ^Sim,
}

// The two stacks, the wire between them, and the test's clock.
Sim :: struct {
	client, server:       net.Net,
	to_server, to_client: Wire,
	now:                  vx.Instant,
	sent_frames:          u64,
	digest:               u64,
	lose:                 proc(sim: ^Sim, frame: []u8) -> bool, // nil: nothing is lost
	loss_count:           u32,
	loss_every:           u32,
	frame:                [net.ETHER_MAX_FRAME]u8, // the one being delivered
	buf:                  [net.TCP_BUF]u8,
}

put_frame :: proc "contextless" (ctx: rawptr, frame: []u8) {
	w := (^Wire)(ctx)
	nt.digest_frame(&w.sim.digest, frame)
	w.sim.sent_frames += 1
	if w.count == WIRE_FRAMES {
		return // a full queue drops, as a switch would
	}
	at := (w.head + w.count) % WIRE_FRAMES
	w.count += 1
	copy(w.frames[at][:], frame)
	w.size[at] = len(frame)
}

wire_clear :: proc(w: ^Wire) {
	w.head, w.count = 0, 0
}

// Delivers frames until both queues are empty.
settle :: proc(s: ^Sim) {
	for rounds := 0; (s.to_server.count > 0 || s.to_client.count > 0) && rounds < 100000; rounds += 1 {
		w := &s.to_server if s.to_server.count > 0 else &s.to_client
		to := &s.server if w == &s.to_server else &s.client
		size := w.size[w.head]
		copy(s.frame[:], w.frames[w.head][:size])
		w.head = (w.head + 1) % WIRE_FRAMES
		w.count -= 1
		if s.lose == nil || !s.lose(s, s.frame[:size]) {
			net.input(to, s.frame[:size], s.now)
		}
	}
}

// Time jumps to the next deadline, and the timers run.
advance :: proc(s: ^Sim) {
	next := min(net.poll(&s.client, s.now), net.poll(&s.server, s.now))
	if next != net.NEVER && next > s.now {
		s.now = next
	}
	_ = net.poll(&s.client, s.now)
	_ = net.poll(&s.server, s.now)
	settle(s)
}

setup :: proc() -> ^Sim {
	s := new(Sim)
	s.digest = nt.FNV_OFFSET
	s.now = 1000 * SECOND
	s.to_server.sim, s.to_client.sim = s, s
	net.init(&s.client, C_MAC, 1500, 11, put_frame, &s.to_server)
	net.init(&s.server, S_MAC, 1500, 22, put_frame, &s.to_client)
	net.set_addr(&s.client, C_IP, 0xffff_ff00, S_IP)
	net.set_addr(&s.server, S_IP, 0xffff_ff00, 0)
	return s
}

conv :: proc(t: ^testing.T, n: ^net.Net, loc := #caller_location) -> (c: ^net.Conv, id: net.Conv_Id) {
	st: vx.Status
	id, st = net.conv_new(n, .Tcp)
	testing.expect_value(t, st, vx.Status.Ok, loc = loc)
	return &n.conv[id], id
}

// A listener on the server, a connection to it from the client, and the
// server's side of it, accepted.
connected :: proc(t: ^testing.T, s: ^Sim) -> (cs, ss: ^net.Conv, listener: net.Conv_Id) {
	l: ^net.Conv
	l, listener = conv(t, &s.server)
	testing.expect_value(t, net.tcp_listen(&s.server, l, 7777), vx.Status.Ok)
	testing.expect_value(t, l.tcb.state, net.Tcp_State.Listen)
	cs, _ = conv(t, &s.client)
	testing.expect_value(t, net.tcp_connect(&s.client, cs, S_IP, 7777, s.now), vx.Status.Ok)
	testing.expect_value(t, cs.tcb.state, net.Tcp_State.Syn_Sent)
	settle(s) // ARP first; the SYN waited for it
	testing.expect_value(t, cs.tcb.state, net.Tcp_State.Established)
	sid, st := net.tcp_accept(&s.server, l)
	testing.expect_value(t, st, vx.Status.Ok)
	ss = &s.server.conv[sid]
	testing.expect_value(t, ss.tcb.state, net.Tcp_State.Established)
	testing.expect_value(t, ss.raddr, C_IP)
	testing.expect_value(t, ss.rport, cs.lport)
	testing.expect_value(t, ss.lport, 7777)
	_, st = net.tcp_accept(&s.server, l)
	testing.expect_value(t, st, vx.Status.Err_Should_Wait) // one call, taken once
	return
}

// Sends total bytes of a pattern from a to b, reading as it goes; true if
// all of it arrived, in order, within the time allowed.
transfer :: proc(s: ^Sim, na: ^net.Net, a: ^net.Conv, nb: ^net.Net, b: ^net.Conv, total: int, recovered: ^bool = nil) -> bool {
	buf: [8192]u8
	sent, got := 0, 0
	give_up := s.now + 600 * SECOND
	// Bounded: time may stand still.
	for rounds := 0; got < total && s.now < give_up && rounds < 100000; rounds += 1 {
		for sent < total {
			for &x, i in buf {
				x = u8((sent + i) * 7 + 3)
			}
			chunk := min(total - sent, len(buf))
			taken, st := net.tcp_write(na, a, buf[:chunk], s.now)
			if st != .Ok || taken == 0 {
				break
			}
			sent += taken
		}
		before := s.sent_frames
		settle(s)
		if recovered != nil && a.tcb.in_recovery {
			recovered^ = true
		}
		for {
			n, st := net.tcp_read(nb, b, buf[:], s.now)
			if st != .Ok || n == 0 {
				break
			}
			for x, i in buf[:n] {
				if x != u8((got + i) * 7 + 3) {
					return false
				}
			}
			got += n
		}
		settle(s)
		if s.sent_frames == before {
			advance(s) // nothing moved: a timer must
		}
	}
	return got == total
}

bytes :: proc(s: string) -> []u8 {
	return transmute([]u8)s
}

@(test)
test_handshake_and_data :: proc(t: ^testing.T) {
	s := setup()
	defer free(s)
	c, sv, _ := connected(t, s)
	testing.expect(t, c.tcb.snd_scaled) // both offered window scaling
	testing.expect_value(t, c.tcb.snd_shift, 0)
	testing.expect(t, sv.tcb.snd_scaled)
	testing.expect_value(t, sv.tcb.snd_shift, 0)
	testing.expect_value(t, c.tcb.mss, 1460)
	testing.expect_value(t, sv.tcb.mss, 1460)
	buf: [64]u8
	_, st := net.tcp_read(&s.server, sv, buf[:], s.now)
	testing.expect_value(t, st, vx.Status.Err_Should_Wait)
	n: int
	n, st = net.tcp_write(&s.client, c, bytes("hello"), s.now)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 5)
	settle(s)
	n, st = net.tcp_read(&s.server, sv, buf[:], s.now)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, string(buf[:n]), "hello")
	_, st = net.tcp_write(&s.server, sv, bytes("world"), s.now)
	testing.expect_value(t, st, vx.Status.Ok)
	settle(s)
	n, st = net.tcp_read(&s.client, c, buf[:], s.now)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, string(buf[:n]), "world")
	testing.expect_value(t, c.tcb.slen, 0) // all acknowledged
	testing.expect_value(t, sv.tcb.slen, 0)
	testing.expect(t, c.tcb.measured) // RTTs were measured (0 ns, in this test's time)
	testing.expect(t, sv.tcb.measured)

	// A megabyte each way, nothing lost: no retransmission at all.
	before := s.sent_frames
	testing.expect(t, transfer(s, &s.client, c, &s.server, sv, 1 << 20))
	testing.expect(t, transfer(s, &s.server, sv, &s.client, c, 1 << 20))
	testing.expect_value(t, c.tcb.retries, 0)
	testing.expect_value(t, sv.tcb.retries, 0)
	testing.expect(t, !c.tcb.in_recovery)
	testing.expect(t, s.sent_frames - before < 2 * (2 << 20) / 1460 + 200) // data segments and their ACKs, about

	// Close: the client's FIN, end of file at the server; the server's FIN,
	// and the client waits in TIME_WAIT, then is closed.
	net.tcp_close(&s.client, c, s.now)
	settle(s)
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Fin_Wait_2)
	testing.expect_value(t, sv.tcb.state, net.Tcp_State.Close_Wait)
	n, st = net.tcp_read(&s.server, sv, buf[:], s.now)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 0) // end of file
	_, st = net.tcp_write(&s.client, c, bytes("x"), s.now)
	testing.expect(t, st != .Ok) // our side is closed
	_, st = net.tcp_write(&s.server, sv, bytes("late"), s.now)
	testing.expect_value(t, st, vx.Status.Ok) // theirs is not
	net.tcp_close(&s.server, sv, s.now)
	settle(s)
	n, st = net.tcp_read(&s.client, c, buf[:], s.now)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Time_Wait)
	testing.expect_value(t, sv.tcb.state, net.Tcp_State.Closed)
	testing.expect_value(t, sv.tcb.error, vx.Status.Ok)
	advance(s)
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Closed)
	testing.expect_value(t, c.tcb.error, vx.Status.Ok)
	nt.expect_digest(t, s.digest, 0x1fa5e0f1827a0500)
}

// Loses every loss_every'th frame from the client that carries TCP data.
lose_some_data :: proc(s: ^Sim, f: []u8) -> bool {
	data :=
		nt.get16(f[12:]) == 0x0800 &&
		f[23] == 6 &&
		len(f) > 54 &&
		net.Ip4(nt.get32(f[26:])) == C_IP &&
		u32(nt.get16(f[16:])) > 40 + (u32(f[46] >> 4) * 4 - 20)
	if !data {
		return false
	}
	s.loss_count += 1
	return s.loss_count % s.loss_every == 0
}

@(test)
test_loss :: proc(t: ^testing.T) {
	s := setup()
	defer free(s)
	c, sv, _ := connected(t, s)
	// One in 50 data segments lost: NewReno's fast retransmit and recovery
	// repair each, and the stream arrives whole.
	s.lose = lose_some_data
	s.loss_count, s.loss_every = 0, 50
	recovered := false
	testing.expect(t, transfer(s, &s.client, c, &s.server, sv, 2 << 20, &recovered))
	testing.expect(t, recovered)
	testing.expect(t, s.loss_count > 20)
	testing.expect(t, c.tcb.cwnd >= u32(c.tcb.mss)) // it reacted to the loss
	testing.expect(t, c.tcb.ssthresh < max(u32))

	// Heavy loss: one in 3. Timeouts and go-back repair what fast retransmit cannot.
	s.loss_count, s.loss_every = 0, 3
	testing.expect(t, transfer(s, &s.client, c, &s.server, sv, 200_000))
	s.lose = nil
	nt.expect_digest(t, s.digest, 0xc2a40ea086a73889)
}

lose_everything :: proc(s: ^Sim, f: []u8) -> bool {
	return true
}

@(test)
test_refused_and_timeout :: proc(t: ^testing.T) {
	s := setup()
	defer free(s)
	// Nothing listens on 9999: the server resets the SYN, and the connect fails.
	c, _ := conv(t, &s.client)
	testing.expect_value(t, net.tcp_connect(&s.client, c, S_IP, 9999, s.now), vx.Status.Ok)
	settle(s)
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Closed)
	testing.expect_value(t, c.tcb.error, vx.Status.Err_Refused)
	buf: [8]u8
	_, st := net.tcp_read(&s.client, c, buf[:], s.now)
	testing.expect_value(t, st, vx.Status.Err_Refused)

	// Nobody answers at all: SYNs again, backing off, then TIMED_OUT.
	d, _ := conv(t, &s.client)
	s.lose = lose_everything
	testing.expect_value(t, net.tcp_connect(&s.client, d, S_IP, 7777, s.now), vx.Status.Ok)
	start := s.now
	for i := 0; i < 50 && d.tcb.state != .Closed; i += 1 {
		advance(s)
	}
	testing.expect_value(t, d.tcb.state, net.Tcp_State.Closed)
	testing.expect_value(t, d.tcb.error, vx.Status.Err_Timed_Out)
	testing.expect(t, s.now - start > 60 * SECOND) // 1 + 2 + 4 + ... seconds of trying
	s.lose = nil
	nt.expect_digest(t, s.digest, 0xeae5602dd5b710e2)
}

@(test)
test_zero_window :: proc(t: ^testing.T) {
	s := setup()
	defer free(s)
	c, sv, _ := connected(t, s)
	// The server reads nothing: its window closes, the client's ring fills,
	// and the client probes the closed window, backing off.
	total := 0
	for _ in 0 ..< 4 {
		if n, st := net.tcp_write(&s.client, c, s.buf[:], s.now); st == .Ok {
			total += n
		}
		settle(s)
	}
	testing.expect_value(t, sv.tcb.rlen, net.TCP_BUF)
	testing.expect_value(t, c.tcb.snd_wnd, 0)
	testing.expect_value(t, total, 2 * net.TCP_BUF)
	_, st := net.tcp_write(&s.client, c, s.buf[:1], s.now)
	testing.expect_value(t, st, vx.Status.Err_Should_Wait) // the ring is full
	for _ in 0 ..< 5 {
		advance(s)
	}
	testing.expect(t, c.tcb.persist_shift >= 3) // probing, not giving up
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Established)
	// The server reads: the window opens, its update gets through, and the rest flows.
	got := 0
	for i := 0; i < 100 && got < total; i += 1 {
		for {
			n, rst := net.tcp_read(&s.server, sv, s.buf[:], s.now)
			if rst != .Ok || n == 0 {
				break
			}
			got += n
		}
		settle(s)
		advance(s)
	}
	testing.expect_value(t, got, total)
	testing.expect_value(t, c.tcb.slen, 0)
	nt.expect_digest(t, s.digest, 0x1f50ccf9de813f78)
}

// A segment from the server's address and port to the client's connection.
inject :: proc(s: ^Sim, c: ^net.Conv, seq, ack: u32, flags: net.Tcp_Flags) {
	f: [54]u8
	nt.eth_header(f[:], C_MAC, S_MAC, 0x0800)
	ip, tcp := f[14:34], f[34:54]
	ip[0], ip[8], ip[9] = 0x45, 64, 6
	nt.put16(ip[2:], 40)
	nt.put32(ip[12:], u32(S_IP))
	nt.put32(ip[16:], u32(C_IP))
	nt.put16(ip[10:], nt.fold(nt.sum(0, ip)))
	nt.put16(tcp[0:], u16(c.rport))
	nt.put16(tcp[2:], u16(c.lport))
	nt.put32(tcp[4:], seq)
	nt.put32(tcp[8:], ack)
	tcp[12], tcp[13] = 5 << 4, transmute(u8)flags
	nt.put16(tcp[14:], 1000)
	nt.put16(tcp[16:], nt.fold(nt.sum(nt.pseudo(S_IP, C_IP, .Tcp, 20), tcp)))
	net.input(&s.client, f[:], s.now)
}

@(test)
test_hostile_segments :: proc(t: ^testing.T) {
	s := setup()
	defer free(s)
	c, _, _ := connected(t, s)
	// A reset whose sequence number is in the window but not the next one gets
	// a challenge ACK, not a reset (RFC 5961); one outside the window, nothing.
	wire_clear(&s.to_server)
	inject(s, c, c.tcb.rcv_nxt + 100, 0, {.Rst})
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Established)
	testing.expect_value(t, s.to_server.count, 1)
	inject(s, c, c.tcb.rcv_nxt + 200_000, 0, {.Rst})
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Established)
	// A SYN on an open connection: a challenge ACK too.
	inject(s, c, c.tcb.rcv_nxt, 0, {.Syn})
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Established)
	// An ACK for data never sent changes nothing.
	inject(s, c, c.tcb.rcv_nxt, c.tcb.snd_max + 5000, {.Ack})
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Established)
	testing.expect_value(t, c.tcb.snd_una, c.tcb.snd_max)
	settle(s)
	// The exact next sequence number resets it.
	inject(s, c, c.tcb.rcv_nxt, 0, {.Rst})
	testing.expect_value(t, c.tcb.state, net.Tcp_State.Closed)
	testing.expect_value(t, c.tcb.error, vx.Status.Err_Peer_Closed)
	nt.expect_digest(t, s.digest, 0xdf8590035f1fcce3)
}

@(test)
test_backlog_and_orphans :: proc(t: ^testing.T) {
	s := setup()
	defer free(s)
	l, lid := conv(t, &s.server)
	testing.expect_value(t, net.tcp_listen(&s.server, l, 80), vx.Status.Ok)
	cs: [6]^net.Conv
	for &c, i in cs {
		c, _ = conv(t, &s.client)
		testing.expect_value(t, net.tcp_connect(&s.client, c, S_IP, 80, s.now), vx.Status.Ok)
		if i == 0 {
			settle(s) // ARP first: a lookup holds one packet, so the SYNs would replace each other
		}
	}
	settle(s)
	up := 0
	for c in cs {
		up += int(c.tcb.state == .Established)
	}
	testing.expect_value(t, up, 4) // the backlog; the others' SYNs were dropped, to be sent again
	ids: [6]net.Conv_Id
	taken := 0
	for {
		id, st := net.tcp_accept(&s.server, l)
		if st != .Ok {
			break
		}
		ids[taken] = id
		taken += 1
	}
	testing.expect_value(t, taken, 4)
	for _ in 0 ..< 10 {
		advance(s) // the others try again, and get in
	}
	up = 0
	for c in cs {
		up += int(c.tcb.state == .Established)
	}
	testing.expect_value(t, up, 6)

	// The listener goes: the connections it made that nobody took are reset.
	net.conv_free(&s.server, lid, s.now)
	settle(s)
	reset := 0
	for c in cs {
		reset += int(c.tcb.state == .Closed && c.tcb.error == .Err_Peer_Closed)
	}
	testing.expect_value(t, reset, 2)
	testing.expect_value(t, s.server.conv[lid].proto, net.Proto.None)

	// An orphan with unread data is reset; one without closes with a FIN and is freed once closed.
	s0, s1 := &s.server.conv[ids[0]], &s.server.conv[ids[1]]
	c0, c1: ^net.Conv
	for c in cs {
		if c.lport == s0.rport {
			c0 = c
		}
		if c.lport == s1.rport {
			c1 = c
		}
	}
	if !testing.expect(t, c0 != nil) || !testing.expect(t, c1 != nil) {
		return
	}
	_, st := net.tcp_write(&s.client, c0, bytes("unread"), s.now)
	testing.expect_value(t, st, vx.Status.Ok)
	settle(s)
	net.conv_free(&s.server, ids[0], s.now)
	settle(s)
	testing.expect_value(t, c0.tcb.state, net.Tcp_State.Closed)
	testing.expect_value(t, c0.tcb.error, vx.Status.Err_Peer_Closed)
	testing.expect_value(t, s0.proto, net.Proto.None)
	net.conv_free(&s.server, ids[1], s.now)
	settle(s)
	testing.expect_value(t, c1.tcb.state, net.Tcp_State.Close_Wait)
	testing.expect_value(t, s1.proto, net.Proto.Tcp) // still closing
	net.tcp_close(&s.client, c1, s.now)
	settle(s)
	// The orphan closed first, so it waits out TIME_WAIT, and then it goes.
	testing.expect_value(t, c1.tcb.state, net.Tcp_State.Closed)
	testing.expect_value(t, s1.tcb.state, net.Tcp_State.Time_Wait)
	advance(s)
	testing.expect_value(t, s1.proto, net.Proto.None)
	nt.expect_digest(t, s.digest, 0x2d05d6283ecafb37)
}
