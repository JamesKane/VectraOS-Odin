// ping [-N] ADDR: sends N ICMP echo requests (3 unless given), a second
// apart, through /net/icmp (netd), and prints each reply's round trip.
//
// A conversation: open /net/icmp/clone (the fid becomes its ctl), read its
// number, write "connect ADDR" there, then write requests to and read replies
// from N/data. netd fills in the identifier and checksum.
//
// A reply that never comes holds the read until one does; a timeout comes
// with Tflush in the 9P client.
package ping

import "base:intrinsics"
import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

PAYLOAD :: 56 // and 8 bytes of header: 64, as everyone's ping sends
USAGE :: "usage: ping [-N] ADDR"

space: ns.Namespace

// Says what failed, and why if st says, and exits.
fail :: proc(what: string, st := vx.Status.Ok) -> ! {
	rt.print("ping: ", what)
	if st != .Ok {
		rt.print(": ", p9.error_text(st))
	}
	rt.print("\n")
	rt.exits("error")
}

// The count from "-N": the digits are taken while they make at most 1000,
// so the largest is 10009.
parse_count :: proc(flag: string) -> u64 {
	count: u64
	for c in transmute([]u8)flag[1:] {
		if c < '0' || c > '9' || count > 1000 {
			fail(USAGE)
		}
		count = count * 10 + u64(c - '0')
	}
	return count
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	args := rt.args()
	count := u64(3)
	if len(args) > 1 && len(args[0]) > 1 && args[0][0] == '-' {
		count = parse_count(args[0])
		args = args[1:]
	}
	if len(args) != 1 || len(args[0]) > 40 {
		fail(USAGE)
	}
	addr := args[0]

	ctl, data: ns.File
	st := procns.from_spawn(&space)
	if st == .Ok {
		st = ns.open(&space, "/net/icmp/clone", p9.ORDWR, &ctl)
	}
	if st != .Ok {
		fail("/net/icmp/clone", st)
	}
	number: [8]u8
	n, rst := ns.read(&ctl, number[:])
	if rst != .Ok || n == 0 {
		fail("reading the conversation's number", rst)
	}
	msg_buf: [128]u8
	msg, _ := str.join(msg_buf[:], "connect ", addr)
	if _, wst := ns.write(&ctl, transmute([]u8)msg); wst != .Ok { // ctl's offset means nothing
		fail("connect", wst)
	}
	path_buf: [128]u8
	path, _ := str.join(path_buf[:], "/net/icmp/", string(number[:n]), "/data")
	if st = ns.open(&space, path, p9.ORDWR, &data); st != .Ok {
		fail(path, st)
	}

	nap: vx.Handle // a port nothing is bound to: waiting on it is a sleep
	if nap, st = rt.port_create(); st != .Ok {
		fail("port_create", st)
	}
	received: u64
	request: [8 + PAYLOAD]u8
	reply: [8 + PAYLOAD + 64]u8
	for seq in 1 ..= count {
		if seq > 1 { // a second apart
			pk: [1]vx.Packet
			_, _ = rt.port_wait(nap, rt.clock_read() + 1_000_000_000, 0, pk[:])
		}
		request = {}
		request[0] = 8 // echo request
		request[6], request[7] = u8(seq >> 8), u8(seq) // sequence
		sent := rt.clock_read()
		intrinsics.unaligned_store((^vx.Instant)(&request[8]), sent)
		for i in size_of(sent) ..< PAYLOAD {
			request[8 + i] = u8(i)
		}
		if _, wst := ns.write(&data, request[:]); wst != .Ok {
			fail("sending", wst)
		}
		// Replies to earlier requests (late ones) are skipped; this one's comes in turn.
		for {
			got, gst := ns.read(&data, reply[:])
			if gst != .Ok {
				fail("receiving", gst)
			}
			if got < 16 || reply[0] != 0 || u64(reply[6]) << 8 | u64(reply[7]) != seq {
				continue
			}
			then := intrinsics.unaligned_load((^vx.Instant)(&reply[8]))
			rt.print("ping: ", addr, ": seq=", seq, " time=", u64(rt.clock_read() - then) / 1000, "us\n")
			received += 1
			break
		}
	}
	ns.close(&data)
	ns.close(&ctl)
	rt.print("ping: ", count, " sent, ", received, " received\n")
	return received == count ? 0 : 1
}
