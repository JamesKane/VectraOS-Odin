package driver

import vx "abi:vx"
import "vx:memory"
import "vx:ring"
import "vx:rt"

// A block class client (blockproto.odin): a session on a disk's or a
// partition's post, used one request at a time. A transfer goes through the
// session's client arena, so each request moves at most the arena's size or
// the driver's limit, whichever is less; longer reads and writes are split.
// Synchronous: fsd is one event loop, and waits for its disk.
//
// A driver that dies takes its sessions with it (upstream 01 §7.4). The
// client keeps its connector, and when its session goes it dials again,
// until the driver has been restarted (BLK_RECONNECT_FOR), and does the
// request it was waiting for again: a read is read again, a write's bytes
// copied into the new arena and written again, a flush flushed again. Each
// may then have been done twice, which the protocol allows. The new session
// must reach a window of the same size, or the disk is not the one it was.

BLK_RECONNECT_FOR :: vx.Duration(30_000_000_000)

// One session. The ring points into memory mapped for it, so a Blk is
// closed (blk_close), never copied while open.
Blk :: struct {
	ring:                 ring.Ring,
	end, port, connector: vx.Handle,
	arena:                []u8,
	max:                  u32, // bytes one request may move
	sector:               u32, // bytes
	sectors:              u64, // the window's
	flags:                Block_Info_Flags,
	open_with:            Block_Connect_Flags,
	reconnects:           u32,
	timeout:              vx.Duration,
}

@(private="file")
KEY_BELL :: 1
@(private="file")
KEY_CLOSED :: 2

// What blk_wait came to.
@(private="file")
Waited :: enum u8 {
	Done, // the completion came
	Timed_Out, // nothing came in time
	Gone, // the session went (its driver died) without answering
}

@(private="file")
blk_wait :: proc "contextless" (b: ^Blk, c: ^vx.Cqe) -> Waited {
	deadline := rt.clock_read() + b.timeout
	for {
		if ring.consume(&b.ring, memory.ptr_to_bytes(c)) == .Ok {
			return .Done
		}
		seen, _ := rt.counter_read(b.end)
		if !ring.prepare_sleep(&b.ring) {
			ring.end_sleep(&b.ring)
			continue
		}
		pk: [1]vx.Packet
		_ = rt.port_bind(b.port, b.end, .Counter_Ge, KEY_BELL, seen + 1)
		n, _ := rt.port_wait(b.port, deadline, 0, pk[:])
		ring.end_sleep(&b.ring)
		if n == 1 && pk[0].key == KEY_CLOSED {
			// It may have answered as it went.
			return ring.consume(&b.ring, memory.ptr_to_bytes(c)) == .Ok ? .Done : .Gone
		}
		if n != 1 {
			return .Timed_Out
		}
	}
}

// A session on the connector, and what it reaches.
@(private="file", require_results)
blk_dial :: proc "contextless" (b: ^Blk) -> vx.Status {
	req := Block_Connect {
		header = {ordinal = BLOCK_CONNECT},
		flags  = b.open_with,
	}
	b.end = rt.session_dial_with(b.connector, memory.ptr_to_bytes(&req), BLOCK_PARAMS, &b.ring) or_return
	if b.port == vx.HANDLE_NONE {
		b.port = rt.port_create() or_return
	}
	rt.port_bind(b.port, b.end, .Peer_Closed, KEY_CLOSED) or_return
	b.arena = ring.arena(&b.ring)
	return blk_info(b)
}

// Never woken: what the wait between dials sleeps on.
@(private="file")
never: u32

// The session gone: dialled again until the driver is back. False if it is not.
@(private="file")
blk_reconnect :: proc "contextless" (b: ^Blk) -> bool {
	had, sector := b.sectors, b.sector
	rt.close_all(b.end)
	rt.session_unmap(&b.ring)
	b.end = vx.HANDLE_NONE
	until := rt.clock_read() + BLK_RECONNECT_FOR
	for rt.clock_read() < until {
		if blk_dial(b) == .Ok {
			if b.sectors != had || b.sector != sector {
				return false // another disk now
			}
			b.reconnects += 1
			rt.print("vx-blk: the disk's session went; dialled again, and the request done again\n")
			return true
		}
		rt.close_all(b.end)
		b.end = vx.HANDLE_NONE
		rt.session_unmap(&b.ring)
		_ = rt.futex_wait(&never, 0, rt.clock_read() + 100_000_000) // the driver restarting: 0.1 s
	}
	return false
}

// One request, and its completion. .Err_Peer_Closed: the session went before
// it was answered (the callers redo it).
@(private="file", require_results)
blk_once :: proc "contextless" (b: ^Blk, e: vx.Sqe, c: ^vx.Cqe) -> vx.Status {
	e := e
	slot, ok := ring.produce_slot(&b.ring)
	if !ok {
		return .Err_Should_Wait
	}
	copy(slot, memory.ptr_to_bytes(&e))
	if ring.produce(&b.ring) {
		_ = rt.ring_notify(b.end)
	}
	switch blk_wait(b, c) {
	case .Gone:
		return .Err_Peer_Closed
	case .Timed_Out:
		return .Err_Timed_Out
	case .Done:
	}
	return c.result < 0 ? vx.Status(c.result) : .Ok
}

@(private="file", require_results)
blk_info :: proc "contextless" (b: ^Blk) -> vx.Status {
	info: vx.Cqe
	blk_once(b, {opcode = u16(Block_Op.Info)}, &info) or_return
	size := u64(len(ring.arena(&b.ring)))
	if info.aux == 0 || info.result < i64(info.aux) {
		return .Err_Unsupported
	}
	b.sector, b.sectors, b.flags = info.aux, info.aux2, transmute(Block_Info_Flags)info.flags
	most := min(u64(info.result), size)
	b.max = u32(most / u64(b.sector) * u64(b.sector))
	if b.max == 0 {
		return .Err_Unsupported // sectors larger than the arena: nothing could ever move
	}
	return .Ok
}

// A session on the connector's whole window. The connector becomes the
// session's: it dials again with it when it must.
@(require_results)
blk_open :: proc "contextless" (b: ^Blk, connector: vx.Handle, flags: Block_Connect_Flags) -> vx.Status {
	b^ = {timeout = 30_000_000_000, connector = connector, open_with = flags}
	return blk_dial(b)
}

blk_close :: proc "contextless" (b: ^Blk) {
	rt.close_all(b.port, b.end, b.connector)
	rt.session_unmap(&b.ring)
	b^ = {}
}

// Whether bytes [off, off + n) are whole sectors inside the window.
@(private="file")
blk_in_window :: proc "contextless" (b: ^Blk, off, n: u64) -> bool {
	if b.sector == 0 || off % u64(b.sector) != 0 || n % u64(b.sector) != 0 {
		return false
	}
	first := off / u64(b.sector)
	return first <= b.sectors && n / u64(b.sector) <= b.sectors - first
}

// Bytes [off, off + len(buf)), both multiples of the sector size, into buf.
@(require_results)
blk_read :: proc "contextless" (b: ^Blk, off: u64, buf: []u8) -> vx.Status {
	if !blk_in_window(b, off, u64(len(buf))) {
		return .Err_Range
	}
	for done := 0; done < len(buf); {
		n := u32(min(len(buf) - done, int(b.max)))
		e := vx.Sqe {
			opcode = u16(Block_Op.Read),
			flags  = {.Dref},
			target = (off + u64(done)) / u64(b.sector),
			len    = n,
		}
		c: vx.Cqe
		st := blk_once(b, e, &c)
		for st == .Err_Peer_Closed && blk_reconnect(b) {
			st = blk_once(b, e, &c)
		}
		st or_return
		if c.result != i64(n) {
			return .Err_Io
		}
		copy(buf[done:], b.arena[:n])
		done += int(n)
	}
	return .Ok
}

// buf to bytes [off, off + len(buf)), both multiples of the sector size.
@(require_results)
blk_write :: proc "contextless" (b: ^Blk, off: u64, buf: []u8) -> vx.Status {
	if !blk_in_window(b, off, u64(len(buf))) {
		return .Err_Range
	}
	for done := 0; done < len(buf); {
		n := u32(min(len(buf) - done, int(b.max)))
		e := vx.Sqe {
			opcode = u16(Block_Op.Write),
			flags  = {.Dref},
			target = (off + u64(done)) / u64(b.sector),
			len    = n,
		}
		c: vx.Cqe
		st: vx.Status
		for {
			copy(b.arena, buf[done:][:n]) // again into a new session's arena, after a reconnect
			st = blk_once(b, e, &c)
			if st != .Err_Peer_Closed || !blk_reconnect(b) {
				break
			}
		}
		st or_return
		if c.result != i64(n) {
			return .Err_Io
		}
		done += int(n)
	}
	return .Ok
}

// Everything written before it durable.
@(require_results)
blk_flush :: proc "contextless" (b: ^Blk) -> vx.Status {
	c: vx.Cqe
	e := vx.Sqe{opcode = u16(Block_Op.Flush)}
	st := blk_once(b, e, &c)
	for st == .Err_Peer_Closed && blk_reconnect(b) {
		st = blk_once(b, e, &c)
	}
	return st
}
