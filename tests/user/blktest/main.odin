// blktest: the block class's conformance test (upstream's docs/proto/block.md
// §7), run as a service in the block scenario (tests/qemu/m5/block.ndb)
// against the scenario's second disk, /srv/disk1, which ./build makes fresh
// for each run: zeros, but for a signature in sector 0 and a GPT of two
// partitions, which partd serves on /srv/disk1.esp and /srv/disk1.vectra.
//
// It checks INFO; reads and writes across sector and page boundaries, and as
// large as the driver takes; FLUSH, WRITE_FUA and DISCARD; every refusal of
// §2 and of CONNECT; a second session on a read-only window; many requests in
// flight at once; partd's partitions as windows. Then it kills the disk
// drivers, through the task tree its manifest gives it, and reads back
// through a new session what it wrote before. Each check prints a line only
// when it fails; the last line counts them.
package blktest

import vx "abi:vx"
import "vx:driver"
import "vx:memory"
import "vx:ring"
import "vx:rt"
import "vx:str"

SIGNATURE :: "VectraOS block test disk"
SPAN :: 3 * 512 // three sectors, across a page boundary in the arena
// Where the whole-disk checks write: past the test partitions, which end at
// sector 83967 (./build's test disk), and before the backup GPT.
BASE :: 100_000

Op :: driver.Block_Op

Session :: struct {
	ring:      ring.Ring,
	end, port: vx.Handle, // a port of its own: nothing left from an earlier session wakes it
	arena:     []u8,
}

connector: vx.Handle
checks, failures: u64

check :: proc(ok: bool, what: string, loc := #caller_location) {
	checks += 1
	if ok {
		return
	}
	failures += 1
	rt.print("blktest: FAILED line ", u64(loc.line), ": ", what, "\n")
}

fail :: proc(what: string) -> ! {
	rt.print("blktest: FAILED: ", what, "\n")
	rt.exits(what)
}

// A session on the window [first, first + count), or why it was refused.
open_window :: proc(s: ^Session, first, count: u64, flags: driver.Block_Connect_Flags) -> vx.Status {
	req := driver.Block_Connect {
		header = {ordinal = driver.BLOCK_CONNECT},
		first  = first,
		count  = count,
		flags  = flags,
	}
	s^ = {}
	st: vx.Status
	s.end, st = rt.session_dial_with(connector, memory.ptr_to_bytes(&req), driver.BLOCK_PARAMS, &s.ring)
	if st != .Ok {
		return st
	}
	pst: vx.Status
	if s.port, pst = rt.port_create(); pst != .Ok {
		fail("port_create")
	}
	s.arena = ring.arena(&s.ring)
	return .Ok
}

close_session :: proc(s: ^Session) {
	rt.close_all(s.end, s.port)
	rt.session_unmap(&s.ring)
	s^ = {}
}

submit :: proc(s: ^Session, e: vx.Sqe) {
	e := e
	slot, ok := ring.produce_slot(&s.ring)
	if !ok {
		fail("the submission queue is full")
	}
	copy(slot, memory.ptr_to_bytes(&e))
	if ring.produce(&s.ring) {
		_ = rt.ring_notify(s.end)
	}
}

// What waiting for a completion came to.
Waited :: enum {
	Done,
	Timed_Out,
	Closed, // the session ended
}

// The next completion, waiting up to 5 s for it.
next :: proc(s: ^Session, c: ^vx.Cqe) -> Waited {
	deadline := rt.clock_read() + 5_000_000_000
	for {
		if ring.consume(&s.ring, memory.ptr_to_bytes(c)) == .Ok {
			return .Done
		}
		seen, _ := rt.counter_read(s.end)
		if !ring.prepare_sleep(&s.ring) {
			ring.end_sleep(&s.ring)
			continue
		}
		pk: [1]vx.Packet
		_ = rt.port_bind(s.port, s.end, .Counter_Ge, 1, seen + 1)
		_ = rt.port_bind(s.port, s.end, .Peer_Closed, 2)
		n, _ := rt.port_wait(s.port, deadline, 0, pk[:])
		ring.end_sleep(&s.ring)
		if n != 1 {
			return .Timed_Out
		}
		if pk[0].key == 2 {
			return ring.consume(&s.ring, memory.ptr_to_bytes(c)) == .Ok ? .Done : .Closed
		}
	}
}

tag: u64

// One request, and its completion (or what went wrong, as its result).
call :: proc(s: ^Session, e: vx.Sqe) -> vx.Cqe {
	e := e
	tag += 1
	e.user_data = tag
	submit(s, e)
	c: vx.Cqe
	if next(s, &c) != .Done {
		return {result = i64(vx.Status.Err_Timed_Out)}
	}
	if c.user_data != e.user_data {
		return {result = i64(vx.Status.Err_Bad_State)}
	}
	return c
}

xfer :: proc(s: ^Session, op: Op, sector: u64, arena_off, length: u32) -> i64 {
	return call(s, {opcode = u16(op), flags = {.Dref}, target = sector, arena_off = arena_off, len = length}).result
}

status :: proc(st: vx.Status) -> i64 {
	return i64(st)
}

fill :: proc(p: []u8, seed: u8) {
	for &b, i in p {
		b = seed + u8(i * 7) + u8(i >> 9)
	}
}

same :: proc(a, b: []u8) -> bool {
	return string(a) == string(b)
}

// The partition partd serves on /srv/POST: `sectors` long, at `first` on the
// disk, beginning with `marker`. `whole` is a session on the whole disk.
check_partition :: proc(post: string, first, sectors: u64, marker: string, whole: ^Session) {
	name_buf: [32]u8
	name, _ := str.join(name_buf[:], "srv:", post)
	keep := connector
	defer connector = keep
	connector = rt.spawn_take(name)
	check(connector != vx.HANDLE_NONE, "a connector to the partition")
	p: Session
	check(connector != vx.HANDLE_NONE && open_window(&p, 0, 0, {}) == .Ok, "a session on the partition")
	if p.end == vx.HANDLE_NONE {
		return
	}
	defer rt.close_all(connector)
	info := call(&p, {opcode = u16(Op.Info)})
	check(info.aux2 == sectors, "the partition's size")
	check(xfer(&p, .Read, 0, 0, 512) == 512 && same(p.arena[:len(marker)], transmute([]u8)marker), "its first sector, the marker")
	fill(p.arena[:1024], 77)
	check(xfer(&p, .Write, sectors - 2, 0, 1024) == 1024, "a write of the partition's last two sectors")
	check(xfer(whole, .Read, first + sectors - 2, 0, 1024) == 1024 && same(whole.arena[:1024], p.arena[:1024]), "the write at the partition's offset on the disk")
	check(xfer(&p, .Read, sectors - 1, 0, 1024) == status(.Err_Range), "a read past the partition's end refused")
	close_session(&p)
	// A window inside it, counted from its start; one past its end refused.
	check(open_window(&p, 1, 4, {.Readonly}) == .Ok, "a read-only window in the partition")
	winfo := call(&p, {opcode = u16(Op.Info)})
	check(winfo.aux2 == 4 && .Readonly in transmute(driver.Block_Info_Flags)winfo.flags, "the window's size, read-only")
	check(xfer(&p, .Write, 0, 0, 512) == status(.Err_Access), "a write to it refused")
	close_session(&p)
	check(open_window(&p, sectors, 0, {}) == .Err_Range, "a window past the partition refused")
	check(open_window(&p, sectors - 1, 2, {}) == .Err_Range, "a window running past it refused")
}

// Kills every disk driver (the boot disk's too: nothing here uses it), and
// waits for this session to end.
kill_drivers :: proc(s: ^Session) {
	tasks := rt.spawn_take("tasks")
	if tasks == vx.HANDLE_NONE {
		fail("no task tree")
	}
	id: u64
	killed := 0
	for {
		info, st := rt.task_info(tasks, id, {.Next})
		if st != .Ok {
			break
		}
		id = info.id
		if str.from_nul_padded(info.name[:]) == "drv-virtio-blk" && rt.task_kill(tasks, "killed", id) == .Ok {
			killed += 1
		}
	}
	if killed == 0 {
		fail("no drv-virtio-blk task")
	}
	c: vx.Cqe
	closed := false
	for _ in 0 ..< 4 {
		if next(s, &c) == .Closed {
			closed = true
			break
		}
	}
	check(closed, "the session ended with its driver")
	close_session(s)
}

// Long enough for a transfer as large as a driver takes.
want: [128 << 10]u8

never: u32

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	connector = rt.spawn_take("srv:disk1")
	if connector == vx.HANDLE_NONE {
		fail("no connector to /srv/disk1")
	}

	// The whole disk.
	s: Session
	if open_window(&s, 0, 0, {}) != .Ok {
		fail("no session on /srv/disk1")
	}
	info := call(&s, {opcode = u16(Op.Info)})
	sector, max_bytes := info.aux, u32(info.result)
	sectors := info.aux2
	check(sector == 512 && sectors == 64 * 2048 && max_bytes >= 64 << 10 && max_bytes <= driver.BLOCK_ARENA, "INFO's sizes")
	check(.Readonly not_in transmute(driver.Block_Info_Flags)info.flags, "the disk is writable")
	rt.print("blktest: ", sectors, " sectors of ", u64(sector), " bytes, up to ", u64(max_bytes >> 10), " KiB a transfer\n")

	check(xfer(&s, .Read, 0, 0, 512) == 512 && same(s.arena[:len(SIGNATURE)], transmute([]u8)string(SIGNATURE)), "sector 0's signature")

	// Across a page boundary in the arena, and three sectors on the disk.
	fill(want[:SPAN], 1)
	copy(s.arena[3584:], want[:SPAN])
	check(xfer(&s, .Write, BASE + 8, 3584, SPAN) == SPAN, "a write across a page boundary")
	for &b in s.arena[65536:][:SPAN] {
		b = 0
	}
	check(xfer(&s, .Read, BASE + 8, 65536, SPAN) == SPAN && same(s.arena[65536:][:SPAN], want[:SPAN]), "reading it back")

	// As large as the driver takes, at the end of the arena.
	big := min(max_bytes, u32(len(want)))
	at := u32(driver.BLOCK_ARENA) - big
	fill(want[:big], 9)
	copy(s.arena[at:], want[:big])
	check(xfer(&s, .Write_Fua, BASE + 1000, at, big) == i64(big), "the largest write, with FUA")
	for &b in s.arena[:big] {
		b = 0
	}
	check(xfer(&s, .Read, BASE + 1000, 0, big) == i64(big) && same(s.arena[:big], want[:big]), "the largest read")
	check(call(&s, {opcode = u16(Op.Flush)}).result == 0, "FLUSH")
	check(call(&s, {opcode = u16(Op.Discard), target = BASE + 4096, offset = 2048}).result == 0, "DISCARD")
	// The last sector of the disk (the backup GPT's header), written back as it was.
	check(xfer(&s, .Read, sectors - 1, 0, 512) == 512 && xfer(&s, .Write, sectors - 1, 0, 512) == 512, "the disk's last sector")

	// Refusals (§2), none of which reaches the device.
	check(xfer(&s, .Read, 0, 0, 0) == status(.Err_Invalid), "no length")
	check(xfer(&s, .Read, 0, 0, 100) == status(.Err_Invalid), "part of a sector")
	check(xfer(&s, .Read, 0, 100, 512) == status(.Err_Invalid), "misaligned in the arena")
	check(xfer(&s, .Read, 0, 0, max_bytes + 512) == status(.Err_Invalid), "too large")
	check(xfer(&s, .Read, sectors, 0, 512) == status(.Err_Range), "past the disk")
	check(xfer(&s, .Read, sectors - 1, 0, 1024) == status(.Err_Range), "running past it")
	check(xfer(&s, .Read, 0, u32(driver.BLOCK_ARENA) - 512, 1024) == status(.Err_Range), "past the arena")
	check(call(&s, {opcode = u16(Op.Read), target = 0, len = 512}).result == status(.Err_Invalid), "no DREF")
	check(call(&s, {opcode = 99}).result == status(.Err_Invalid), "an opcode the class does not have")
	check(call(&s, {opcode = u16(Op.Discard), target = sectors - 1, offset = 2}).result == status(.Err_Range), "a discard past the disk")

	// Many requests in flight at once: every one completes, once.
	seen: [100]bool
	for i in u32(0) ..< 100 {
		submit(&s, {opcode = u16(Op.Read), flags = {.Dref}, user_data = 10_000 + u64(i), target = u64(i), arena_off = i * 4096, len = 4096})
	}
	got := 0
	c: vx.Cqe
	for got < 100 && next(&s, &c) == .Done {
		if c.user_data >= 10_000 && c.user_data < 10_100 && !seen[c.user_data - 10_000] && c.result == 4096 {
			seen[c.user_data - 10_000] = true
			got += 1
		}
	}
	check(got == 100, "a hundred requests in flight")

	// A read-only window: sectors 8 to 23, as a second session at once.
	w: Session
	check(open_window(&w, BASE + 8, 16, {.Readonly}) == .Ok, "a read-only window")
	winfo := call(&w, {opcode = u16(Op.Info)})
	check(winfo.aux2 == 16 && .Readonly in transmute(driver.Block_Info_Flags)winfo.flags, "its size, read-only")
	fill(want[:SPAN], 1)
	check(xfer(&w, .Read, 0, 0, SPAN) == SPAN && same(w.arena[:SPAN], want[:SPAN]), "its first sector, the disk's sector 8")
	check(xfer(&w, .Write, 0, 0, 512) == status(.Err_Access), "a write refused")
	check(xfer(&w, .Read, 16, 0, 512) == status(.Err_Range), "past the window")
	check(xfer(&w, .Read, 15, 0, 1024) == status(.Err_Range), "running past the window")
	check(call(&w, {opcode = u16(Op.Discard), target = 0, offset = 1}).result == status(.Err_Access), "a discard refused")
	close_session(&w)

	// Partitions, through partd: each a window, its first sector the line
	// ./build wrote there; writes land at the partition's offset on the disk.
	check_partition("disk1.esp", 2048, 16384, "partition esp\n", &s)
	check_partition("disk1.vectra", 18432, 65536, "partition vectra\n", &s)
	{
		none := rt.spawn_take("srv:disk1.none")
		keep := connector
		connector = none
		y: Session
		check(none != vx.HANDLE_NONE && open_window(&y, 0, 0, {}) == .Err_Not_Found, "a partition the disk does not have")
		connector = keep
	}

	// CONNECT's refusals.
	x: Session
	check(open_window(&x, sectors, 0, {}) == .Err_Range, "a window past the disk")
	check(open_window(&x, sectors - 8, 16, {}) == .Err_Range, "a window running past it")
	check(open_window(&x, 0, 0, transmute(driver.Block_Connect_Flags)u32(2)) == .Err_Invalid, "a flag the class does not have")
	rt.print("blktest: ok\n")

	// The drivers killed, then restarted by devmgr: what was written is there.
	kill_drivers(&s)
	rt.print("blktest: stopped the drivers; the session ended\n")
	st := vx.Status.Err_Timed_Out
	for _ in 0 ..< 100 { // until the new driver serves the post
		st = open_window(&s, 0, 0, {})
		if st == .Ok {
			break
		}
		_ = rt.futex_wait(&never, 0, rt.clock_read() + 50_000_000)
	}
	check(st == .Ok, "a session on the restarted driver")
	if st == .Ok {
		fill(want[:big], 9)
		check(xfer(&s, .Read, BASE + 1000, 0, big) == i64(big) && same(s.arena[:big], want[:big]), "what was written before")
		close_session(&s)
	}
	rt.print("blktest: ", checks, " checks, ", failures, " failed\n")
	if failures != 0 {
		rt.exits("failed")
	}
	return 0
}
