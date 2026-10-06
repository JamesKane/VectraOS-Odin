// proctest: the one process table (upstream ADR-0011), run as a service in
// the proc scenario (tests/qemu/m4/proc.ndb). It spawns copies of itself,
// registered with procfs as its children, and checks /proc: status, ppid,
// wait records (the child's exit string, or the note that ended it), note,
// notepg, noteid, ctl, and a note ending a wait read. Each check prints a
// line only when it fails; the last line counts them. It checks namespace
// groups too: a child's bind reaches its parent, and /proc/N/ns says so.
//
// Run as a child (its first argument), it is:
//   exit      ends at once, with the exit string "child done"
//   sleep     waits for ever, so a note ends it, with the note
//   poke      waits a little, posts the note "poke" to its parent, then sleeps
//   bind      binds /boot on /n, in the namespace group it shares with its
//             parent (ADR-0009), and ends
//   loop      calls target(0), target(1), ... every 10 ms, and ends at 20:
//             what the debug files (05 §3) stop at a breakpoint
//   fault     waits a little, then reads address 16, which nothing maps
//   zones     gives procfs a profiling ring, then times a zone of work every
//             few milliseconds, for ever (05 §9)
//
// spawn_elf registers each child with procfs between building it and
// starting its thread (Spawn_Args.proc_conn), so a child cannot end first.
package proctest

import "base:intrinsics"
import vx "abi:vx"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:process"
import "vx:procns"
import "vx:prof"
import "vx:rt"
import "vx:str"

checks, failures: u32
space: ns.Namespace
me: u64

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if ok {
		return
	}
	failures += 1
	rt.print("proctest: FAILED line ", u64(loc.line), ": ", what, "\n")
}

has :: proc "contextless" (s: []u8, want: string) -> bool {
	return str.contains(string(s), want)
}

nap :: proc "contextless" (ms: i64) {
	@(static) never: u32
	_ = rt.futex_wait(&never, 0, rt.clock_read() + ms * 1_000_000)
}

// "/proc/N/file", in a buffer that lasts until the next call.
proc_path :: proc "contextless" (pid: u64, file: string) -> string {
	@(static) path: [64]u8
	digits: [str.U64_DIGITS]u8
	s, _ := str.join(path[:], "/proc/", str.format_u64(digits[:], pid), "/", file)
	return s
}

// A /proc file's contents (one read), or a status.
read_file :: proc "contextless" (pid: u64, file: string, buf: []u8) -> (n: int, st: vx.Status) {
	f: ns.File
	ns.open(&space, proc_path(pid, file), p9.OREAD, &f) or_return
	defer ns.close(&f)
	return ns.read(&f, buf)
}

// What read_file read, or nothing.
read_text :: proc "contextless" (pid: u64, file: string, buf: []u8) -> []u8 {
	n, st := read_file(pid, file, buf)
	return buf[:n] if st == .Ok else nil
}

write_file :: proc "contextless" (pid: u64, file: string, text: string) -> vx.Status {
	f: ns.File
	ns.open(&space, proc_path(pid, file), p9.OWRITE, &f) or_return
	defer ns.close(&f)
	_, st := ns.write(&f, transmute([]u8)text)
	return st
}

number :: proc "contextless" (buf: []u8) -> u64 {
	v: u64
	for c in buf {
		if c < '0' || c > '9' {
			break
		}
		v = v * 10 + u64(c - '0')
	}
	return v
}

image: [1 << 20]u8
image_size: int

// Spawns a copy of this program as a child, registered with procfs, in mode
// `what`. Returns its pid, or 0.
spawn :: proc "contextless" (what: string) -> u64 {
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	@(static) records: [8 * 1024]u8
	rec := ndb.Writer{buf = records[:]}
	ndb.put(&rec, "arg", what)
	_ = ndb.end(&rec)
	count, st := procns.spawn_records(&space, &rec, handles[:vx.CHANNEL_MAX_HANDLES - 4], names[:], 0)
	if st != .Ok {
		return 0
	}
	if c := rt.console_connector(); c != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(c, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "console"
			count += 1
		}
	}
	pid: u64
	a := rt.Spawn_Args {
		name         = "proctest",
		image        = image[:image_size],
		handles      = handles[:count],
		handle_names = names[:count],
		records      = ndb.written(&rec),
		proc_conn    = ns.connector(&space, "/proc"), // registered before it runs
		registered   = note_pid,
		ctx          = &pid,
	}
	task: vx.Handle
	task, st = rt.spawn_elf(&a)
	if st != .Ok {
		return 0
	}
	_ = rt.handle_close(task) // procfs watches it; this test waits through /proc
	return pid
}

// spawn_elf's registered: the child's pid, from procfs.
note_pid :: proc "contextless" (ctx: rawptr, pid: u64) -> vx.Status {
	(^u64)(ctx)^ = pid
	return .Ok
}

// The next wait record, into buf; its length, or a status.
wait_record :: proc "contextless" (buf: []u8) -> (n: int, st: vx.Status) {
	return read_file(me, "wait", buf)
}

wait_text :: proc "contextless" (buf: []u8) -> []u8 {
	n, st := wait_record(buf)
	return buf[:n] if st == .Ok else nil
}

notes_seen: u32

// A busy thread timing zones, 50 of them (upstream's 6d6b).
tick := prof.Zone {
	name = "tick",
}

zones_thread :: proc(arg: rawptr) {
	for _ in 0 ..< 50 {
		t := prof.begin(&tick)
		spin: int
		for k in 0 ..< 2000 {
			intrinsics.volatile_store(&spin, k)
		}
		prof.end(&tick, t)
	}
}

on_note :: proc "contextless" (e: ^vx.Exception, note: string, fp: rawptr) -> rt.Noted {
	if !str.contains(note, "group") && !str.contains(note, "poke") {
		return .Dflt
	}
	notes_seen += 1
	return .Cont
}

// What the debug test stops in: never inlined, and with the C convention, so
// it is a call with its argument in the first argument register.
counter: u64

target :: #force_no_inline proc "c" (n: u64) {
	intrinsics.volatile_store(&counter, intrinsics.volatile_load(&counter) + n)
}

fault_at: uintptr = 16 // nothing maps it; a variable, so the optimizer does not know it

work := prof.Zone {
	name = "work",
}

child :: proc "contextless" (mode: string) -> ! {
	switch mode {
	case "loop":
		for i in u64(0) ..< 20 {
			target(i)
			nap(10)
		}
		rt.exits("looped")
	case "zones":
		if prof.init(ns.connector(&space, "/proc")) != .Ok {
			rt.exits("no ring")
		}
		for {
			t := prof.begin(&work)
			for i := 0; i < 10000; i += 1 {
				intrinsics.volatile_store(&counter, u64(i))
			}
			prof.end(&work, t)
			nap(2)
		}
	case "fault":
		nap(100)
		rt.exits(intrinsics.volatile_load((^u8)(fault_at)) != 0 ? "read" : "zero")
	case "exit":
		rt.exits("child done")
	case "bind":
		rt.exits(ns.bind(&space, "/boot", "/n", ns.REPLACE) == .Ok ? "" : "cannot bind")
	case "poke":
		nap(100) // the parent is in its wait read by now
		info, _ := rt.task_info(rt.self)
		buf: [24]u8
		_ = write_file(number(read_text(info.id, "ppid", buf[:])), "note", "poke")
	}
	for {
		nap(1000) // a note ends it
	}
}

// "0x..." for an address.
hex :: proc "contextless" (v: u64, out: ^[18]u8) -> string {
	digits := "0123456789abcdef"
	n := 2
	out[0], out[1] = '0', 'x'
	for shift := 60; shift >= 0; shift -= 4 {
		if v >> uint(shift) != 0 || shift == 0 || n > 2 {
			out[n] = digits[(v >> uint(shift)) & 15]
			n += 1
		}
	}
	return string(out[:n])
}

addr_of :: proc "contextless" (p: rawptr) -> u64 {
	return u64(uintptr(p))
}

// Reads exactly size_of(T) bytes of a file at offset into v.
read_value :: proc "contextless" (path: string, offset: u64, v: ^$T) -> (opened, whole: bool) {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return false, false
	}
	defer ns.close(&f)
	f.offset = offset
	n, st := ns.read(&f, ([^]u8)(v)[:size_of(T)])
	return true, st == .Ok && n == size_of(T)
}

// The debug files (05 §3): a breakpoint with a condition, its event, the
// thread's status and registers, memory, a step, the maps and image, and a
// fault seen as an event and then passed on.
test_debug :: proc "contextless" () {
	buf: [1024]u8
	cmd_buf: [96]u8
	c := spawn("loop")
	check(c != 0)
	at_buf: [18]u8
	at := hex(addr_of(rawptr(target)), &at_buf)
	when ODIN_ARCH == .amd64 {
		cond, arg := " if rdi==3", "rdi=0x3"
	} else {
		cond, arg := " if x0==3", "x0=0x3"
	}
	cmd, _ := str.join(cmd_buf[:], "break ", at, cond)
	check(write_file(c, "ctl", cmd) == .Ok)
	ev := read_text(c, "events", buf[:]) // waits for the hit
	check(has(ev, "event=break") && has(ev, "thread=1") && has(ev, at))
	t := read_text(c, "threads/1/status", buf[:])
	check(len(t) > 0 && has(t, "state=stopped") && has(t, "reason=break"))
	t = read_text(c, "threads/1/regs.ndb", buf[:])
	check(len(t) > 0 && has(t, arg))
	// Its memory: counter is 0 + 1 + 2 when target(3) is called.
	value: u64
	opened, whole := read_value(proc_path(c, "mem"), addr_of(&counter), &value)
	check(opened)
	check(whole && value == 3)
	regs: vx.Regs
	opened, whole = read_value(proc_path(c, "threads/1/regs"), 0, &regs)
	check(opened)
	check(whole)
	when ODIN_ARCH == .amd64 {
		check(regs.rip == addr_of(rawptr(target)) && regs.rdi == 3)
	} else {
		check(regs.pc == addr_of(rawptr(target)) && regs.x[0] == 3)
	}
	fp: vx.Fpregs
	opened, whole = read_value(proc_path(c, "threads/1/fpregs"), 0, &fp)
	check(opened)
	check(whole)
	// One step: past the breakpoint's instruction.
	check(write_file(c, "threads/1/ctl", "step") == .Ok)
	ev = read_text(c, "events", buf[:])
	check(has(ev, "event=step") && !has(ev, at))
	t = read_text(c, "maps", buf[:])
	check(len(t) > 0 && has(t, "prot=r-x"))
	t = read_text(c, "images", buf[:])
	check(len(t) > 0 && has(t, "name=proctest") && has(t, "build-id="))
	t = read_text(c, "threads", buf[:]) // a directory: its one thread
	check(len(t) > 0)
	t = read_text(c, "info", buf[:])
	check(len(t) > 0 && has(t, "watchpoints=") && has(t, "breakpoints=32"))
	// The breakpoint out; a watchpoint on counter: the next write stops it.
	cmd, _ = str.join(cmd_buf[:], "unbreak ", at)
	check(write_file(c, "ctl", cmd) == .Ok)
	watched_buf: [18]u8
	watched := hex(addr_of(&counter), &watched_buf)
	cmd, _ = str.join(cmd_buf[:], "watch ", watched, " 8 write")
	check(write_file(c, "ctl", cmd) == .Ok)
	check(write_file(c, "ctl", "watch 0x1001 8 write") == .Err_Invalid) // not aligned
	check(write_file(c, "ctl", "start") == .Ok)
	ev = read_text(c, "events", buf[:])
	check(has(ev, "event=watch") && has(ev, watched) && has(ev, "access=write"))
	t = read_text(c, "threads/1/status", buf[:])
	check(len(t) > 0 && has(t, "reason=watch"))
	// Stepped past it, it stops again at the next write: then out, and on.
	check(write_file(c, "ctl", "start") == .Ok)
	ev = read_text(c, "events", buf[:])
	check(has(ev, "event=watch"))
	cmd, _ = str.join(cmd_buf[:], "unwatch ", watched)
	check(write_file(c, "ctl", cmd) == .Ok && write_file(c, "ctl", "start") == .Ok)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "status=looped"))

	// A fault, seen by the debugger first, then passed on: it ends the child.
	c = spawn("fault")
	check(c != 0)
	f: ns.File
	check(ns.open(&space, proc_path(c, "events"), p9.OREAD, &f) == .Ok) // opened: procfs is its debugger
	n, _ := ns.read(&f, buf[:])
	ns.close(&f)
	ev = buf[:max(n, 0)]
	check(has(ev, "event=fault") && has(ev, "addr=0x10") && has(ev, "access=read"))
	check(write_file(c, "ctl", "start") == .Ok)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "sys: trap: fault read addr=0x10"))
	// Its crash directory (05 §5), shaped like /proc/N.
	dir_buf: [48]u8
	digits: [str.U64_DIGITS]u8
	dir, _ := str.join(dir_buf[:], "/tmp/crash/proctest.", str.format_u64(digits[:], c))
	FILES :: [?]string{"/note", "/maps", "/images", "/info", "/threads/1/regs.ndb", "/threads/1/regs"}
	files := FILES
	for name, i in files {
		path_buf: [96]u8
		path, _ := str.join(path_buf[:], dir, name)
		n = -1
		if ns.open(&space, path, p9.OREAD, &f) == .Ok {
			n, _ = ns.read(&f, buf[:])
			ns.close(&f)
		}
		check(n > 0)
		got := buf[:max(n, 0)]
		if i == 0 {
			check(n > 0 && has(got, "sys: trap: fault read addr=0x10"))
		}
		if i == 4 {
			check(n > 0 && has(got, "rsp=") != has(got, "x29="))
		}
	}
	mem_buf: [96]u8
	mem, _ := str.join(mem_buf[:], dir, "/mem")
	check(ns.open(&space, mem, p9.OREAD, &f) == .Ok) // the writable mappings
	n, _ = ns.read(&f, buf[:])
	ns.close(&f)
	check(n > 0) // at least one entry
}

// Reads a whole file into buf: how much it read.
read_whole :: proc "contextless" (path: string, buf: []u8) -> int {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return 0
	}
	defer ns.close(&f)
	got := 0
	for got < len(buf) {
		n, st := ns.read(&f, buf[got:])
		if st != .Ok || n <= 0 {
			break
		}
		got += n
	}
	return got
}

// Gives procfs a ring at `at` in process pid's name: the status of the reply.
give_ring :: proc "contextless" (pid: u64, at: u64, vmo: vx.Handle) -> vx.Status {
	vmo := vmo
	req := process.Msg {
		header = {ordinal = process.PROF},
		arg = {i64(pid), i64(at), 0},
	}
	rep: process.Msg
	call := vx.Call {
		wr_bytes   = &req,
		wr_len     = size_of(req),
		wr_handles = &vmo,
		wr_count   = 1,
		rd_bytes   = &rep,
		rd_cap     = size_of(rep),
	}
	rt.channel_call(ns.connector(&space, "/proc"), &call, rt.clock_read() + 2_000_000_000) or_return
	return process.reply_status(&rep)
}

// A ring of its own, mapped here, for give_ring: its address and a handle to
// give. 0 if it cannot be made.
make_ring :: proc "contextless" () -> (at: u64, given: vx.Handle) {
	vmo, st := rt.vmo_create(prof.RING)
	if st != .Ok {
		return 0, vx.HANDLE_NONE
	}
	defer _ = rt.handle_close(vmo)
	at, st = rt.as_map(rt.self, vmo, 0, prof.RING, {.Write})
	if st != .Ok {
		return 0, vx.HANDLE_NONE
	}
	given, st = rt.handle_dup(vmo, vx.RIGHTS_SAME)
	if st != .Ok {
		_ = rt.as_unmap(rt.self, at, prof.RING)
		return 0, vx.HANDLE_NONE
	}
	return at, given
}

// /sys/clock (02 §5.1), and profiling zones (05 §9): a child times a zone;
// with zones on, /proc/N/prof/zones has its records, named, in cycles.
test_prof :: proc "contextless" () {
	buf: [256]u8
	n := read_whole("/sys/clock/info", buf[:])
	info := buf[:n]
	check(has(info, ".hz=") && has(info, ".user") && has(info, "source="))
	n = read_whole("/sys/clock/now", buf[:])
	check(n > 0 && has(buf[:n], "monotonic="))
	clock, cst := rt.clock_info()
	check(cst == .Ok && clock.counter_hz > 1_000_000)
	c0 := rt.cycles()
	nap(10)
	c1 := rt.cycles()
	check(c1 > c0 && (c1 - c0) * 1000 / max(clock.counter_hz, 1) >= 9) // 10 ms of cycles, read in user mode

	c := spawn("zones")
	check(c != 0)
	st := vx.Status.Err_Not_Found
	for tries := 0; tries < 100 && st != .Ok; tries += 1 { // until it has given procfs its ring
		st = write_file(c, "prof/ctl", "zones on")
		if st != .Ok {
			nap(5)
		}
	}
	check(st == .Ok)
	check(write_file(c, "prof/ctl", "zones sideways") == .Err_Invalid)
	nap(100)
	@(static) ring: struct #align (8) {
		bytes: [prof.RING]u8,
	}
	got := read_whole(proc_path(c, "prof/zones"), ring.bytes[:])
	h := (^prof.Header)(&ring)
	whole := got >= size_of(prof.Header)
	check(whole && h.magic == prof.MAGIC && h.counter_hz == clock.counter_hz && h.nzones == 1)
	check(whole && string(h.names[0][:5]) == "work\x00")
	records := whole ? (got - size_of(prof.Header)) / size_of(prof.Record) : 0
	check(records >= 5)
	ordered := true
	r := ([^]prof.Record)(&ring.bytes[size_of(prof.Header)])[:records]
	for i in 0 ..< records {
		ordered = ordered && r[i].zone == 1 && r[i].end > r[i].start && (i == 0 || r[i].start >= r[i - 1].start)
	}
	check(ordered)
	// A ring given in another's name: procfs's challenge does not show in
	// that process's memory, whatever the giver wrote in the ring.
	at, given := make_ring()
	check(at != 0)
	if at != 0 {
		forged := (^prof.Header)(uintptr(at))
		forged.magic, forged.cap = prof.MAGIC, 16
		check(give_ring(c, 4096, given) == .Err_Access)
		_ = rt.as_unmap(rt.self, at, prof.RING)
	}
	check(write_file(c, "prof/ctl", "zones off") == .Ok) // its own ring is still the one

	// A ring per thread (upstream's M6 step 6d6b): four busy threads of this
	// process's own, each one's records in a ring it claimed, carrying its
	// id; the file has all four, merged by their ends.
	check(prof.init(ns.connector(&space, "/proc")) == .Ok)
	check(write_file(me, "prof/ctl", "zones on") == .Ok)
	@(static) busy: [4]rt.Thread
	for &b in busy {
		bst: vx.Status
		b, bst = rt.thread_spawn(zones_thread, nil)
		check(bst == .Ok)
	}
	for &b in busy {
		rt.thread_join(&b)
	}
	owners: [4]u32
	owned := 0
	own := true
	vmo := prof.header()
	for i in u32(1) ..= prof.THREADS {
		if vmo == nil {
			break
		}
		rg := prof.ring_at(vmo, i)
		who := intrinsics.atomic_load(&rg.thread)
		head := intrinsics.atomic_load(&rg.head)
		if who == 0 || head == 0 {
			continue
		}
		if owned < 4 {
			owners[owned] = who
		}
		owned += 1
		for k in 0 ..< min(head, u64(prof.CAP)) {
			own = own && prof.ring_records(rg)[k].thread == who
		}
		own = own && head >= 50
	}
	check(owned == 4 && own && owners[0] != owners[1] && owners[2] != owners[3] && owners[0] != owners[3])
	check(vmo != nil && intrinsics.atomic_load(&prof.ring_at(vmo, 0).head) == 0) // none shared
	check(write_file(me, "prof/ctl", "zones off") == .Ok)
	got = read_whole(proc_path(me, "prof/zones"), ring.bytes[:])
	nm := got > size_of(prof.Header) ? (got - size_of(prof.Header)) / size_of(prof.Record) : 0
	m := ([^]prof.Record)(&ring.bytes[size_of(prof.Header)])[:nm]
	by_end := nm >= 200
	seen: u32
	for i in 0 ..< nm {
		by_end = by_end && (i == 0 || m[i].end >= m[i - 1].end)
		for o, k in owners {
			if m[i].thread == o {
				seen |= 1 << u32(k)
			}
		}
	}
	check(by_end && seen == 0xf)

	// A ring whose header lies about its size: procfs reads it within its own.
	if vmo != nil {
		vmo.cap = 0xffff_ffff
		intrinsics.atomic_store(&vmo.head, u64(1) << 40)
	}
	got = read_whole(proc_path(me, "prof/zones"), ring.bytes[:])
	check(got >= size_of(prof.Header) && got <= int(prof.RING))
	t := read_text(me, "status", buf[:]) // procfs is still there
	check(len(t) > 0 && has(t, "name=proctest"))

	check(write_file(c, "note", "done") == .Ok)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "status=done"))
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	if args := rt.args(); len(args) > 0 {
		child(args[0])
	}
	info, ist := rt.task_info(rt.self)
	check(ist == .Ok)
	me = info.id
	f: ns.File
	if ns.open(&space, "/boot/bin/proctest", p9.OREAD, &f) == .Ok {
		image_size, _ = ns.read_all(&f, image[:])
		ns.close(&f)
	}
	check(image_size > 0)
	buf: [512]u8

	// Its own entry: pid = its task id; its parent is svcd.
	t := read_text(me, "status", buf[:])
	check(len(t) > 0 && has(t, "name=proctest") && has(t, "pid="))
	t = read_text(me, "ppid", buf[:])
	check(len(t) > 0 && number(t) == 1)
	_, wst := wait_record(buf[:])
	check(wst == .Err_No_Child) // no children yet
	check(write_file(1, "note", "hangup") == .Err_Access) // svcd takes no notes: one would end it

	// A child's end leaves a record with its exit string.
	c := spawn("exit")
	check(c != 0)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "status=\"child done\"") && has(t, "name=proctest"))

	// A note ends a child with no handler, with the note as its exit string.
	c = spawn("sleep")
	t = read_text(c, "ppid", buf[:])
	check(len(t) > 0 && number(t) == me)
	check(write_file(c, "note", "hello") == .Ok)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "status=hello"))

	// Children are in their parent's note group: notepg reaches them all, and the writer.
	check(rt.notify(on_note) == .Ok)
	a, b := spawn("sleep"), spawn("sleep")
	group := number(read_text(a, "noteid", buf[:]))
	mine := number(read_text(me, "noteid", buf[:]))
	check(group != 0 && b != 0 && mine == group)
	check(write_file(me, "notepg", "group") == .Ok)
	check(notes_seen == 1)
	for _ in 0 ..< 2 {
		t = wait_text(buf[:])
		check(len(t) > 0 && has(t, "status=group"))
	}

	// noteid: a group of its own, by its own pid; not one that does not exist.
	c = spawn("sleep")
	check(write_file(c, "noteid", "999999") == .Err_Access)
	digits: [str.U64_DIGITS]u8
	check(write_file(c, "noteid", str.format_u64(digits[:], c)) == .Ok)
	t = read_text(c, "noteid", buf[:])
	check(len(t) > 0 && number(t) == c)

	// ctl: stop and start, then kill: its record says "killed".
	check(write_file(c, "ctl", "stop") == .Ok)
	t = read_text(c, "status", buf[:])
	check(len(t) > 0 && has(t, "state=stopped"))
	check(write_file(c, "ctl", "start") == .Ok)
	check(write_file(c, "ctl", "bogus") == .Err_Invalid)
	check(write_file(c, "ctl", "kill") == .Ok)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "status=killed"))

	// A note to a process waiting in a wait read ends the read, after the note.
	c = spawn("poke")
	notes_seen = 0
	_, wst = wait_record(buf[:])
	check(wst == .Err_Interrupted && notes_seen == 1)
	check(write_file(c, "ctl", "kill") == .Ok)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "status=killed"))
	_, wst = wait_record(buf[:])
	check(wst == .Err_No_Child)

	// A namespace group (ADR-0009): a child shares its parent's, so its bind
	// reaches the parent, whose /proc/N/ns says so, and stays after it has gone.
	_, _, e := ns.walk(&space, "/n/bin")
	check(e == .Err_Not_Found) // /n is empty
	check(spawn("bind") != 0)
	t = wait_text(buf[:])
	check(len(t) > 0 && has(t, "status=\"\""))
	pc, fid, we := ns.walk(&space, "/n/bin")
	check(we == .Ok)
	if we == .Ok {
		_ = p9.client_clunk(pc, fid)
	}
	t = read_text(me, "ns", buf[:])
	check(len(t) > 0 && has(t, "bind /boot /n"))

	test_debug()
	test_prof()
	rt.print("proctest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	if failures != 0 {
		rt.exits("failed")
	}
	return 0
}
