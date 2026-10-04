// vx:net's TCP: RFC 793's state machine with RFC 9293's corrections; RFC
// 5961's challenge ACKs for resets and SYNs inside the window; RFC 6298's
// retransmission timer with Karn's rule; NewReno congestion control (RFC
// 5681, RFC 6582): slow start, congestion avoidance, fast retransmit and fast
// recovery with partial ACKs; window scaling (RFC 7323), so a peer may offer
// more than 64 KiB; the MSS option; zero-window probes. No SACK and no
// timestamps yet.
//
// Each connection has a 64 KiB ring each way. Our window is what the receive
// ring has free, which fits 16 bits, so we scale by nothing; data that
// arrives out of order is dropped and ACKed again, and the peer's fast
// retransmit fills the hole. A segment for no connection gets a reset.
package net

import "abi:vx"

TCP_BUF :: 65535 // each way: a window that needs no scaling of ours

Tcp_State :: enum u8 {
	Closed,
	Listen,
	Syn_Sent,
	Syn_Rcvd,
	Established,
	Fin_Wait_1,
	Fin_Wait_2,
	Closing,
	Time_Wait,
	Close_Wait,
	Last_Ack,
}

// The control bits, as the header's flags byte has them (bit i is member i).
Tcp_Flag :: enum u8 {
	Fin = 0,
	Syn = 1,
	Rst = 2,
	Psh = 3,
	Ack = 4,
	Urg = 5,
	Ece = 6,
	Cwr = 7,
}
Tcp_Flags :: bit_set[Tcp_Flag;u8]

// A TCP connection's state (RFC 793 names). Sequence numbers are mod 2^32.
Tcb :: struct {
	state:        Tcp_State,
	orphan:       bool, // the application let go: the stack frees it once closed
	fin_queued:   bool, // the application closed its side: a FIN follows the data
	fin_received: bool, // reads end once rbuf is empty
	ack_now:      bool,
	timing:       bool,
	in_recovery:  bool,
	measured:     bool, // srtt and rttvar hold a sample (a fast link can measure 0)
	accepted:     bool, // a listener's connection that its application has taken
	error:        vx.Status, // why it closed: Refused, Peer_Closed (reset) or Timed_Out
	parent:       Maybe(Conv_Id), // the listener that made it

	iss, snd_una, snd_nxt: u32,
	snd_max, snd_wnd:      u32,
	snd_wl1, snd_wl2:      u32,
	sbuf_seq:              u32, // the sequence number of sbuf's first byte
	snd_scaled:            bool, // the peer offered window scaling
	snd_shift:             u8, // and its scale
	dupacks, retries:      u8,
	persist_shift:         u8,
	mss:                   u16, // the most a segment we send carries
	cwnd, ssthresh:        u32,
	recover:               u32,
	rtt_seq:               u32,
	rtt_start, srtt:       vx.Instant,
	rttvar, rto:           vx.Instant,
	// NEVER when off; linger is TIME_WAIT's, or an orphan's in FIN_WAIT_2.
	rto_at, persist_at: vx.Instant,
	linger_at:          vx.Instant,

	irs, rcv_nxt: u32,
	shead, slen:  u32, // the send ring: where the bytes start, and how many
	rhead, rlen:  u32, // the receive ring
}

@(private="file")
RTO_MIN :: vx.Instant(200_000_000)
@(private="file")
RTO_MAX :: 60 * SECOND
@(private="file")
RTO_INITIAL :: SECOND // RFC 6298 §2.1
@(private="file")
TIME_WAIT :: 10 * SECOND // 2 MSL, with a short MSL: slots are few
@(private="file")
ORPHAN_FIN_WAIT_2 :: 60 * SECOND
@(private="file")
BACKLOG :: 4
@(private="file")
SYN_RETRIES :: 6
@(private="file")
RETRIES :: 12

@(private="file")
Tcp_Offset :: bit_field u8 {
	reserved: u8 | 4,
	words:    u8 | 4, // the header's length in words
}

@(private="file")
Tcp_Header :: struct #packed {
	sport, dport: u16be,
	seq, ack:     u32be,
	offset:       Tcp_Offset,
	flags:        Tcp_Flags,
	window:       u16be,
	sum:          u16be,
	urgent:       u16be,
}
#assert(size_of(Tcp_Header) == 20)
#assert(offset_of(Tcp_Header, sum) == 16)

// The flags a segment is read with: the six of RFC 793.
@(private="file")
FLAGS_READ :: Tcp_Flags{.Fin, .Syn, .Rst, .Psh, .Ack, .Urg}

@(private="file")
seq_lt :: proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) < 0
}

@(private="file")
seq_leq :: proc "contextless" (a, b: u32) -> bool {
	return i32(a - b) <= 0
}

// What a SYN or FIN counts for in sequence space.
@(private="file")
seq_len :: proc "contextless" (dlen: u32, flags: Tcp_Flags) -> u32 {
	return dlen + u32(.Syn in flags) + u32(.Fin in flags)
}

@(private="file")
STATE_NAMES := [Tcp_State]string {
	.Closed      = "Closed",
	.Listen      = "Listen",
	.Syn_Sent    = "Syn_sent",
	.Syn_Rcvd    = "Syn_received",
	.Established = "Established",
	.Fin_Wait_1  = "Finwait1",
	.Fin_Wait_2  = "Finwait2",
	.Closing     = "Closing",
	.Time_Wait   = "Time_wait",
	.Close_Wait  = "Close_wait",
	.Last_Ack    = "Last_ack",
}

// The state's name, as Plan 9's /net/tcp/N/status says it.
tcp_state_name :: proc "contextless" (s: Tcp_State) -> string {
	return STATE_NAMES[s] if s <= .Last_Ack else "Closed"
}

// One segment to raddr: the header, any options, then size bytes of data
// from ring, starting at index start (it may wrap).
@(private="file")
emit :: proc "contextless" (n: ^Net, raddr: Ip4, lport, rport: Port, seq, ack: u32, flags: Tcp_Flags, window: u16, opt: []u8, ring: []u8, start, size: u32, now: vx.Instant) {
	s := n.frame[L4_AT:]
	hlen := size_of(Tcp_Header) + len(opt)
	total := hlen + int(size)
	h := Tcp_Header {
		sport  = u16be(lport),
		dport  = u16be(rport),
		seq    = u32be(seq),
		ack    = u32be(ack),
		offset = {words = u8(hlen / 4)},
		flags  = flags,
		window = u16be(window),
	}
	store(s, h)
	copy(s[size_of(Tcp_Header):], opt)
	if size > 0 {
		ring_read(s[hlen:total], ring, int(start))
	}
	src := source_for(n, raddr)
	h.sum = u16be(fold(sum16(pseudo(src, raddr, .Tcp, total), s[:total])))
	store(s, h)
	ip_header(n, .Tcp, src, raddr, total)
	ip_route(n, raddr, 20 + total, now)
}

// A segment with no options and no data: a reset, or a reset's ACK.
@(private="file")
emit_bare :: proc "contextless" (n: ^Net, raddr: Ip4, lport, rport: Port, seq, ack: u32, flags: Tcp_Flags, now: vx.Instant) {
	emit(n, raddr, lport, rport, seq, ack, flags, 0, nil, nil, 0, 0, now)
}

// What our window is: the receive ring's free space.
@(private="file")
window_of :: proc "contextless" (t: ^Tcb) -> u16 {
	return u16(TCP_BUF - t.rlen)
}

// A segment on a connection. off is where its data starts, counted from
// sbuf_seq. A SYN carries our MSS, and our window scale (by nothing) when
// we are the first to offer it, or the peer offered it.
@(private="file")
send :: proc "contextless" (n: ^Net, c: ^Conv, seq: u32, flags: Tcp_Flags, off, size: u32, now: vx.Instant) {
	t := &c.tcb
	flags := flags
	opt: [8]u8
	optlen := 0
	if .Syn in flags {
		mss := n.mtu - 40
		opt[0], opt[1], opt[2], opt[3] = 2, 4, u8(mss >> 8), u8(mss) // MSS
		optlen = 4
		if t.state == .Syn_Sent || t.snd_scaled {
			opt[4], opt[5], opt[6], opt[7] = 1, 3, 3, 0 // NOP, window scale 0
			optlen = 8
		}
	}
	if t.state != .Syn_Sent {
		flags += {.Ack}
	}
	if .Ack in flags {
		t.ack_now = false
	}
	emit(n, c.raddr, c.lport, c.rport, seq, t.rcv_nxt, flags, window_of(t), opt[:optlen], c.sbuf[:], (t.shead + off) % TCP_BUF, size, now)
}

@(private="file")
arm :: proc "contextless" (t: ^Tcb, now: vx.Instant) {
	if t.rto_at == NEVER {
		t.rto_at = now + t.rto
	}
}

// The end of the data written so far: where a FIN goes.
@(private="file")
end_of :: proc "contextless" (t: ^Tcb) -> u32 {
	return t.sbuf_seq + t.slen
}

// Retransmits the first unacknowledged segment (fast retransmit, partial ACKs).
@(private="file")
resend_first :: proc "contextless" (n: ^Net, c: ^Conv, now: vx.Instant) {
	t := &c.tcb
	end := end_of(t)
	if seq_lt(t.snd_una, end) {
		size := min(end - t.snd_una, u32(t.mss))
		send(n, c, t.snd_una, Tcp_Flags{.Psh} if size == end - t.snd_una else {}, t.snd_una - t.sbuf_seq, size, now)
	} else if t.fin_queued {
		send(n, c, end, {.Fin}, 0, 0, now)
	}
	t.timing = false // Karn: no sample from what was sent twice
}

// Sends what the windows allow: data, then a FIN once all of it has gone;
// and an ACK if one is owed and nothing else carried it.
@(private="file")
output :: proc "contextless" (n: ^Net, c: ^Conv, now: vx.Instant) {
	t := &c.tcb
	#partial switch t.state {
	case .Established, .Close_Wait, .Fin_Wait_1, .Closing, .Last_Ack:
		end, window := end_of(t), min(t.snd_wnd, t.cwnd)
		for {
			flight := t.snd_nxt - t.snd_una
			unsent := end - t.snd_nxt if seq_lt(t.snd_nxt, end) else 0
			size := min(unsent, window - flight if window > flight else 0, u32(t.mss))
			if size == 0 {
				break
			}
			send(n, c, t.snd_nxt, Tcp_Flags{.Psh} if size == unsent else {}, t.snd_nxt - t.sbuf_seq, size, now)
			if !t.timing && !seq_lt(t.snd_nxt, t.snd_max) { // time new data only
				t.timing = true
				t.rtt_seq = t.snd_nxt
				t.rtt_start = now
			}
			t.snd_nxt += size
			if seq_lt(t.snd_max, t.snd_nxt) {
				t.snd_max = t.snd_nxt
			}
			arm(t, now)
		}
		if t.fin_queued && t.snd_nxt == end {
			send(n, c, end, {.Fin}, 0, 0, now)
			t.snd_nxt = end + 1
			if seq_lt(t.snd_max, t.snd_nxt) {
				t.snd_max = t.snd_nxt
			}
			if t.state == .Established {
				t.state = .Fin_Wait_1
			}
			if t.state == .Close_Wait {
				t.state = .Last_Ack
			}
			arm(t, now)
		}
		// Data waits, nothing is in flight, and the peer offers no window: probe it.
		if t.snd_wnd == 0 && seq_lt(t.snd_nxt, end) && t.snd_nxt == t.snd_una && t.persist_at == NEVER {
			t.persist_at = now + (t.rto << t.persist_shift)
		}
	}
	if t.ack_now && t.state != .Syn_Sent && t.state != .Closed && t.state != .Listen {
		send(n, c, t.snd_nxt, {}, 0, 0, now)
	}
}

// The connection is closed. An orphan, or a listener's connection nobody
// took, goes; otherwise it stays, Closed, for its application to see why.
@(private="file")
closed :: proc "contextless" (c: ^Conv, why: vx.Status) {
	t := &c.tcb
	t.state = .Closed
	if why != .Ok && t.error == .Ok {
		t.error = why
	}
	t.rto_at, t.persist_at, t.linger_at = NEVER, NEVER, NEVER
	_, has_parent := t.parent.?
	if t.orphan || (has_parent && !t.accepted) {
		c.proto = .None
	}
}

// Whether t is a connection the listener lid made.
@(private="file")
made_by :: proc "contextless" (t: ^Tcb, lid: Conv_Id) -> bool {
	p, ok := t.parent.?
	return ok && p == lid
}

// RTO from the estimates (RFC 6298 §2.3), clamped; the initial one before any sample.
@(private="file")
rto_set :: proc "contextless" (t: ^Tcb) {
	if !t.measured {
		t.rto = RTO_INITIAL
		return
	}
	t.rto = clamp(t.srtt + max(4 * t.rttvar, 1_000_000), RTO_MIN, RTO_MAX)
}

@(private="file")
rtt_sample :: proc "contextless" (t: ^Tcb, r: vx.Instant) {
	if !t.measured {
		t.measured = true
		t.srtt = r
		t.rttvar = r / 2
	} else {
		diff := t.srtt - r if t.srtt > r else r - t.srtt
		t.rttvar = (3 * t.rttvar + diff) / 4
		t.srtt = (7 * t.srtt + r) / 8
	}
	rto_set(t)
}

// A fresh connection's sending side: ISS, window and timers.
@(private="file")
start :: proc "contextless" (n: ^Net, t: ^Tcb) {
	t.iss = random(n)
	t.snd_una, t.snd_max, t.recover = t.iss, t.iss, t.iss
	t.snd_nxt = t.iss + 1
	t.sbuf_seq = t.iss + 1
	t.mss = 536 // until the peer says (RFC 9293 §3.7.1)
	t.ssthresh = max(u32)
	t.rto = RTO_INITIAL
	t.rto_at, t.persist_at, t.linger_at = NEVER, NEVER, NEVER
	t.snd_scaled = false
}

// The MSS and window scale options of a SYN.
@(private="file")
syn_options :: proc "contextless" (n: ^Net, t: ^Tcb, opt: []u8) {
	for i := 0; i < len(opt); {
		kind := opt[i]
		if kind == 0 {
			break
		}
		if kind == 1 {
			i += 1
			continue
		}
		if i + 1 >= len(opt) || opt[i + 1] < 2 || i + int(opt[i + 1]) > len(opt) {
			break // runs past the header
		}
		olen := opt[i + 1]
		if kind == 2 && olen == 4 {
			t.mss = get16(opt[i + 2:])
		}
		if kind == 3 && olen == 3 {
			t.snd_shift = min(opt[i + 2], 14)
			t.snd_scaled = true
		}
		i += int(olen)
	}
	ours := n.mtu - 40
	if t.mss < 64 {
		t.mss = 536
	} else if u32(t.mss) > ours {
		t.mss = u16(ours)
	}
	t.cwnd = 10 * u32(t.mss) // RFC 6928's initial window
}

// The peer's window from a segment, scaled unless it is a SYN's.
@(private="file")
window_update :: proc "contextless" (t: ^Tcb, seq, ack: u32, window: u16, syn: bool) {
	if !(seq_lt(t.snd_wl1, seq) || (t.snd_wl1 == seq && seq_leq(t.snd_wl2, ack))) {
		return
	}
	shift := t.snd_shift if !syn && t.snd_scaled else 0
	t.snd_wnd = u32(window) << shift
	t.snd_wl1 = seq
	t.snd_wl2 = ack
	if t.snd_wnd != 0 {
		t.persist_at = NEVER
		t.persist_shift = 0
	}
}

@(private="file")
reset_reply :: proc "contextless" (n: ^Net, src: Ip4, sport, dport: Port, seq, ack: u32, flags: Tcp_Flags, seglen: u32, now: vx.Instant) {
	if .Rst in flags {
		return
	}
	if .Ack in flags {
		emit_bare(n, src, dport, sport, ack, 0, {.Rst}, now)
	} else {
		emit_bare(n, src, dport, sport, 0, seq + seglen, {.Rst, .Ack}, now)
	}
}

// Takes acknowledged bytes out of the send ring.
@(private="file")
acked :: proc "contextless" (t: ^Tcb, ack: u32) {
	end := end_of(t)
	upto := end if seq_lt(end, ack) else ack
	if seq_lt(t.sbuf_seq, upto) {
		gone := upto - t.sbuf_seq
		t.shead = (t.shead + gone) % TCP_BUF
		t.slen -= gone
		t.sbuf_seq = upto
	}
}

// The ACK field of a segment on a synchronized connection. False if the
// segment is to be dropped here.
@(private="file")
take_ack :: proc "contextless" (n: ^Net, c: ^Conv, seq, ack: u32, window: u16, dlen: u32, flags: Tcp_Flags, now: vx.Instant) -> bool {
	t := &c.tcb
	if t.state == .Syn_Rcvd {
		if !seq_lt(t.snd_una, ack) || seq_lt(t.snd_max, ack) {
			emit_bare(n, c.raddr, c.lport, c.rport, ack, 0, {.Rst}, now)
			return false
		}
		t.state = .Established
		t.snd_wl1 = seq - 1 // so this segment's window is taken
	}
	if seq_lt(t.snd_max, ack) { // acknowledges what was never sent
		t.ack_now = true
		return false
	}
	if seq_lt(ack, t.snd_una) {
		return true // an old one: nothing to learn, but its data may be new
	}

	window_same := u32(window) << (t.snd_shift if t.snd_scaled else 0) == t.snd_wnd
	if ack == t.snd_una {
		dup := dlen == 0 && .Syn not_in flags && .Fin not_in flags && window_same && t.snd_max != t.snd_una
		if dup {
			t.dupacks += 1
			// The third: fast retransmit, unless this loss is inside a window
			// already recovered (RFC 6582 §3.2 step 2).
			if t.dupacks == 3 && !t.in_recovery && seq_leq(t.recover, ack - 1) {
				flight := t.snd_max - t.snd_una
				t.ssthresh = max(flight / 2, 2 * u32(t.mss))
				t.recover = t.snd_max
				t.in_recovery = true
				resend_first(n, c, now)
				t.cwnd = t.ssthresh + 3 * u32(t.mss)
			} else if t.in_recovery && t.dupacks > 3 {
				t.cwnd += u32(t.mss) // each dupack: a segment has left the network
			}
		}
		window_update(t, seq, ack, window, false)
		return true
	}

	// New data acknowledged.
	newly := ack - t.snd_una
	if t.timing && seq_lt(t.rtt_seq, ack) {
		rtt_sample(t, now - t.rtt_start)
		t.timing = false
	}
	acked(t, ack)
	t.snd_una = ack
	if seq_lt(t.snd_nxt, ack) {
		t.snd_nxt = ack
	}
	t.dupacks = 0
	t.retries = 0
	// The timer's backoff goes (RFC 6298 §5.7 allows it, as BSD does), or
	// after a timeout under loss Karn's rule would keep it backed off for as
	// long as retransmitted data is being acknowledged.
	rto_set(t)
	if t.in_recovery {
		if !seq_lt(ack, t.recover) { // a full ACK: recovery is over
			flight := t.snd_max - t.snd_una
			t.cwnd = min(t.ssthresh, flight + u32(t.mss))
			t.in_recovery = false
		} else { // a partial ACK: the next hole, at once, and the window deflated
			resend_first(n, c, now)
			t.cwnd = t.cwnd - newly if t.cwnd > newly else 0
			t.cwnd += u32(t.mss)
		}
	} else if t.cwnd < t.ssthresh {
		t.cwnd += min(newly, u32(t.mss)) // slow start
	} else {
		more := u32(u64(t.mss) * u64(t.mss) / u64(t.cwnd)) // congestion avoidance
		t.cwnd += more if more != 0 else 1
	}
	t.rto_at = NEVER if t.snd_una == t.snd_max else now + t.rto
	window_update(t, seq, ack, window, false)

	if t.fin_queued && ack == end_of(t) + 1 { // our FIN is acknowledged
		#partial switch t.state {
		case .Fin_Wait_1:
			t.state = .Fin_Wait_2
			if t.orphan {
				t.linger_at = now + ORPHAN_FIN_WAIT_2
			}
		case .Closing:
			t.state = .Time_Wait
			t.linger_at = now + TIME_WAIT
		case .Last_Ack:
			closed(c, .Ok)
			return false
		}
	}
	return true
}

// A segment arrived for this connection (not a listener's).
@(private="file")
segment :: proc "contextless" (n: ^Net, c: ^Conv, seq, ack: u32, flags: Tcp_Flags, window: u16, opt: []u8, data: []u8, now: vx.Instant) {
	t := &c.tcb
	if t.state == .Syn_Sent {
		ack_ok := .Ack in flags && seq_lt(t.iss, ack) && seq_leq(ack, t.snd_max)
		if .Ack in flags && !ack_ok {
			if .Rst not_in flags {
				emit_bare(n, c.raddr, c.lport, c.rport, ack, 0, {.Rst}, now)
			}
			return
		}
		if .Rst in flags {
			if ack_ok {
				closed(c, .Err_Refused)
			}
			return
		}
		if .Syn not_in flags {
			return
		}
		t.irs = seq
		t.rcv_nxt = seq + 1
		syn_options(n, t, opt)
		if ack_ok {
			t.snd_una = ack
			t.snd_wnd = u32(window) // a SYN's window is never scaled
			t.snd_wl1 = seq
			t.snd_wl2 = ack
			t.state = .Established
			if t.timing {
				rtt_sample(t, now - t.rtt_start)
				t.timing = false
			}
			t.retries = 0
			t.rto_at = NEVER
			t.ack_now = true
			output(n, c, now)
		} else { // a simultaneous open
			t.state = .Syn_Rcvd
			send(n, c, t.iss, {.Syn}, 0, 0, now)
		}
		return
	}

	// Synchronized states: is the segment inside our window (RFC 9293 §3.10.7.4)?
	seq, data := seq, data
	dlen := u32(len(data))
	seglen := seq_len(dlen, flags)
	wnd := u32(window_of(t))
	in_first := seq_leq(t.rcv_nxt, seq) && seq_lt(seq, t.rcv_nxt + wnd)
	in_last := seglen != 0 && seq_leq(t.rcv_nxt, seq + seglen - 1) && seq_lt(seq + seglen - 1, t.rcv_nxt + wnd)
	acceptable: bool
	if seglen != 0 {
		acceptable = wnd != 0 && (in_first || in_last)
	} else {
		acceptable = in_first if wnd != 0 else seq == t.rcv_nxt // a zero window takes only the next sequence
	}
	if !acceptable {
		if .Rst not_in flags {
			t.ack_now = true
			if t.state == .Time_Wait {
				t.linger_at = now + TIME_WAIT // a FIN again: our ACK was lost
			}
			output(n, c, now)
		}
		return
	}
	if .Rst in flags { // RFC 5961 §3.2: only the exact next sequence resets
		if seq == t.rcv_nxt {
			closed(c, .Err_Peer_Closed)
		} else {
			t.ack_now = true
			output(n, c, now)
		}
		return
	}
	if .Syn in flags { // RFC 5961 §4.2: a challenge ACK
		t.ack_now = true
		output(n, c, now)
		return
	}
	if .Ack not_in flags || !take_ack(n, c, seq, ack, window, dlen, flags, now) {
		if c.proto != .None && t.state != .Closed {
			output(n, c, now)
		}
		return
	}

	// Data, in order only: the part before rcv_nxt was had already; the part
	// past the window is trimmed off, and its FIN with it.
	fin := .Fin in flags
	if seq_lt(seq, t.rcv_nxt) {
		skip := min(t.rcv_nxt - seq, u32(len(data)))
		data = data[skip:]
		seq += skip
		if seq != t.rcv_nxt {
			fin = false // the FIN was had already too
		}
	}
	if seq != t.rcv_nxt { // a hole before it: ask again for what is missing
		data = nil
		fin = false
		t.ack_now = true
	}
	taking := t.state == .Established || t.state == .Fin_Wait_1 || t.state == .Fin_Wait_2
	if len(data) > 0 && taking {
		take := min(u32(len(data)), TCP_BUF - t.rlen)
		if take < u32(len(data)) {
			fin = false
		}
		if !t.orphan { // an orphan's data has no reader: taken, and dropped
			ring_write(c.rbuf[:], int((t.rhead + t.rlen) % TCP_BUF), data[:take])
			t.rlen += take
		}
		t.rcv_nxt += take
		t.ack_now = true
	}
	if fin && taking {
		t.rcv_nxt += 1
		t.fin_received = true
		t.ack_now = true
		#partial switch t.state {
		case .Established:
			t.state = .Close_Wait
		case .Fin_Wait_1:
			t.state = .Closing // both FINs crossed; ours is not yet acknowledged
		case:
			t.state = .Time_Wait
			t.linger_at = now + TIME_WAIT
		}
	}
	output(n, c, now)
}

@(private)
tcp_input :: proc "contextless" (n: ^Net, src, dst: Ip4, s: []u8, now: vx.Instant) {
	if len(s) < size_of(Tcp_Header) || fold(sum16(pseudo(src, dst, .Tcp, len(s)), s)) != 0 {
		n.stats.bad += 1
		return
	}
	h := load(s, Tcp_Header)
	hlen := int(h.offset.words) * 4
	if hlen < size_of(Tcp_Header) || hlen > len(s) {
		n.stats.bad += 1
		return
	}
	if !loopback(dst) && (n.addr == 0 || dst != n.addr) {
		return // no broadcast TCP
	}
	sport, dport, window := Port(h.sport), Port(h.dport), u16(h.window)
	seq, ack := u32(h.seq), u32(h.ack)
	flags := h.flags & FLAGS_READ
	opt, data := s[size_of(Tcp_Header):hlen], s[hlen:]
	seglen := seq_len(u32(len(data)), flags)

	listener: ^Conv
	listener_id: Conv_Id
	for &c, i in n.conv {
		if c.proto != .Tcp || c.lport != dport {
			continue
		}
		if c.tcb.state == .Listen {
			listener, listener_id = &c, Conv_Id(i)
		} else if c.tcb.state != .Closed && c.raddr == src && c.rport == sport {
			segment(n, &c, seq, ack, flags, window, opt, data, now)
			return
		}
	}
	if listener == nil {
		reset_reply(n, src, sport, dport, seq, ack, flags, seglen, now)
		return
	}
	// A listener's: only a SYN makes anything (RFC 9293 §3.10.7.2).
	if .Rst in flags {
		return
	}
	if .Ack in flags {
		reset_reply(n, src, sport, dport, seq, ack, flags, seglen, now)
		return
	}
	if .Syn not_in flags {
		return
	}
	waiting := 0
	for &w in n.conv {
		if w.proto == .Tcp && made_by(&w.tcb, listener_id) && !w.tcb.accepted {
			waiting += 1
		}
	}
	if waiting >= BACKLOG {
		n.stats.dropped += 1 // the backlog is full: the peer will try again
		return
	}
	id, st := conv_new(n, .Tcp)
	if st != .Ok {
		n.stats.dropped += 1
		return
	}
	c := &n.conv[id]
	t := &c.tcb
	c.lport, c.raddr, c.rport = dport, src, sport
	start(n, t)
	t.parent = listener_id
	t.state = .Syn_Rcvd
	t.irs = seq
	t.rcv_nxt = seq + 1
	t.snd_wnd = u32(window)
	t.snd_wl1 = seq
	syn_options(n, t, opt)
	send(n, c, t.iss, {.Syn}, 0, 0, now)
	t.snd_nxt, t.snd_max = t.iss + 1, t.iss + 1
	arm(t, now)
}

// The connection's timers: retransmission, zero-window probes, TIME_WAIT.
// Returns the next deadline.
@(private)
tcp_poll :: proc "contextless" (n: ^Net, c: ^Conv, now: vx.Instant) -> vx.Instant {
	t := &c.tcb
	if t.state == .Closed || t.state == .Listen {
		return NEVER // no timers run
	}
	if t.linger_at <= now {
		closed(c, .Ok if t.state == .Time_Wait else .Err_Timed_Out)
		return NEVER
	}
	if t.rto_at <= now {
		syn := t.state == .Syn_Sent || t.state == .Syn_Rcvd
		t.retries += 1
		if t.retries > (SYN_RETRIES if syn else RETRIES) {
			if !syn {
				emit_bare(n, c.raddr, c.lport, c.rport, t.snd_nxt, 0, {.Rst}, now)
			}
			closed(c, .Err_Timed_Out)
			return NEVER
		}
		t.timing = false
		t.rto = min(t.rto * 2, RTO_MAX)
		flight := t.snd_max - t.snd_una
		t.ssthresh = max(flight / 2, 2 * u32(t.mss))
		t.cwnd = u32(t.mss) // one segment, and slow start again
		t.in_recovery = false
		t.dupacks = 0
		t.recover = t.snd_max
		t.rto_at = now + t.rto
		if syn {
			send(n, c, t.iss, {.Syn}, 0, 0, now)
		} else {
			t.snd_nxt = t.snd_una // go back: send it all again, as the window allows
			output(n, c, now)
		}
	}
	if t.persist_at <= now { // one byte past the window, without counting it sent
		end := end_of(t)
		if t.snd_wnd == 0 && seq_lt(t.snd_nxt, end) {
			send(n, c, t.snd_nxt, {}, t.snd_nxt - t.sbuf_seq, 1, now)
			if seq_lt(t.snd_max, t.snd_nxt + 1) {
				t.snd_max = t.snd_nxt + 1
			}
			if t.persist_shift < 8 {
				t.persist_shift += 1
			}
			t.persist_at = now + min(t.rto << t.persist_shift, RTO_MAX)
		} else {
			t.persist_at = NEVER
		}
	}
	return min(t.rto_at, t.persist_at, t.linger_at)
}

// --- What an application does with a connection ---

// Connects: a SYN to addr!port, from a free local port. The connection is
// made when its state is Established; or, Closed, it failed (tcb.error).
@(require_results)
tcp_connect :: proc "contextless" (n: ^Net, c: ^Conv, addr: Ip4, port: Port, now: vx.Instant) -> vx.Status {
	if c.proto != .Tcp || c.raddr != 0 || c.tcb.state != .Closed || addr == 0 || port == 0 {
		return .Err_Invalid
	}
	if !can_send(n, addr) {
		return .Err_Bad_State
	}
	if c.lport == 0 {
		conv_announce(n, c, 0) or_return
	}
	c.raddr, c.rport = addr, port
	t := &c.tcb
	start(n, t)
	t.state = .Syn_Sent
	t.timing = true
	t.rtt_start = now
	send(n, c, t.iss, {.Syn}, 0, 0, now)
	t.snd_max = t.iss + 1 // the SYN is sent: its ACK is acceptable
	arm(t, now)
	return .Ok
}

// Listens on a port (0: a free one): SYNs that come to it make connections,
// for tcp_accept to take.
@(require_results)
tcp_listen :: proc "contextless" (n: ^Net, c: ^Conv, port: Port) -> vx.Status {
	if c.proto != .Tcp || c.raddr != 0 || c.tcb.state != .Closed {
		return .Err_Invalid
	}
	conv_announce(n, c, port) or_return
	c.tcb.state = .Listen
	return .Ok
}

// Takes a connection the listener l has made: Err_Should_Wait if none has
// been made yet.
@(require_results)
tcp_accept :: proc "contextless" (n: ^Net, l: ^Conv) -> (id: Conv_Id, st: vx.Status) {
	if l.proto != .Tcp || l.tcb.state != .Listen {
		return 0, .Err_Bad_State
	}
	lid := conv_id_of(n, l)
	for &c, i in n.conv {
		t := &c.tcb
		if c.proto != .Tcp || !made_by(t, lid) || t.accepted {
			continue
		}
		if t.state == .Syn_Rcvd {
			continue // not made yet
		}
		t.accepted = true
		return Conv_Id(i), .Ok
	}
	return 0, .Err_Should_Wait
}

// Reads what has arrived, in order, into buf: how many bytes, 0 at the end
// of the stream. Err_Should_Wait: nothing yet. Another error: the connection
// failed.
@(require_results)
tcp_read :: proc "contextless" (n: ^Net, c: ^Conv, buf: []u8, now: vx.Instant) -> (got: int, st: vx.Status) {
	t := &c.tcb
	if t.rlen == 0 {
		if t.fin_received {
			return 0, .Ok
		}
		if t.state == .Closed {
			return 0, t.error
		}
		return 0, .Err_Should_Wait
	}
	before := u32(window_of(t))
	take := min(t.rlen, u32(min(len(buf), TCP_BUF)))
	ring_read(buf[:take], c.rbuf[:], int(t.rhead))
	t.rhead = (t.rhead + take) % TCP_BUF
	t.rlen -= take
	// Tell the peer the window opened, once that is worth a segment: from
	// under an MSS, or by half the ring (RFC 9293 §3.8.6.2.2's receiver side).
	after := u32(window_of(t))
	if (before < u32(t.mss) && after >= u32(t.mss)) || after - before >= TCP_BUF / 2 {
		t.ack_now = true
		output(n, c, now)
	}
	return int(take), .Ok
}

// Writes data into the send ring, as much as fits: how many bytes were
// taken. Err_Should_Wait if none fits. Data written before the connection
// is made goes once it is.
@(require_results)
tcp_write :: proc "contextless" (n: ^Net, c: ^Conv, data: []u8, now: vx.Instant) -> (taken: int, st: vx.Status) {
	t := &c.tcb
	#partial switch t.state {
	case .Syn_Sent, .Syn_Rcvd, .Established, .Close_Wait:
	case:
		return 0, t.error if t.error != .Ok else .Err_Peer_Closed
	}
	if t.fin_queued {
		return 0, t.error if t.error != .Ok else .Err_Peer_Closed
	}
	take := min(TCP_BUF - t.slen, u32(min(len(data), TCP_BUF)))
	if take == 0 {
		return 0, .Err_Should_Wait if len(data) > 0 else .Ok
	}
	ring_write(c.sbuf[:], int((t.shead + t.slen) % TCP_BUF), data[:take])
	t.slen += take
	output(n, c, now)
	return int(take), .Ok
}

// Closes our side: a FIN once the data written has gone. Reading goes on.
tcp_close :: proc "contextless" (n: ^Net, c: ^Conv, now: vx.Instant) {
	t := &c.tcb
	if t.state == .Listen || t.state == .Syn_Sent {
		closed(c, .Ok)
		return
	}
	if t.fin_queued || t.state == .Closed {
		return
	}
	t.fin_queued = true
	output(n, c, now)
}

// The application let go of a connection. A listener's waiting connections
// are reset; a connection with data never read is reset (RFC 2525 §2.17);
// any other is closed as usual, and goes once it is.
@(private)
tcp_free :: proc "contextless" (n: ^Net, c: ^Conv, now: vx.Instant) {
	t := &c.tcb
	if t.state == .Listen {
		id := conv_id_of(n, c)
		for &w in n.conv {
			if w.proto != .Tcp || !made_by(&w.tcb, id) || w.tcb.accepted {
				continue
			}
			if w.tcb.state != .Closed {
				emit_bare(n, w.raddr, w.lport, w.rport, w.tcb.snd_nxt, 0, {.Rst}, now)
			}
			w.proto = .None
		}
	}
	t.orphan = true
	synced := t.state != .Closed && t.state != .Listen && t.state != .Syn_Sent
	if synced && (t.rlen != 0 || t.state == .Syn_Rcvd) {
		emit_bare(n, c.raddr, c.lport, c.rport, t.snd_nxt, 0, {.Rst}, now)
		closed(c, .Ok)
	} else if synced {
		tcp_close(n, c, now)
		if t.state == .Fin_Wait_2 {
			t.linger_at = now + ORPHAN_FIN_WAIT_2
		}
	} else {
		c.proto = .None
	}
}
