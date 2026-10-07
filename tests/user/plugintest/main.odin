// plugintest: a host and its plugins sharing structures in place (01 §6.6,
// upstream's M6 step 6e1b3, ADR-0021), run in the plugin scenario
// (tests/qemu/m6/plugin.ndb). Ported from upstream's tests/user/plugintest.c,
// check for check. The host spawns a copy of itself as a plugin for each
// case, joined by a channel, and checks:
//   - a plugin killed while it builds publishes nothing;
//   - a sealed result cannot change under the host, nor be written by it;
//   - a result's links are followed with vx:shared, and one out of bounds
//     is refused;
//   - a lease revoked while the plugin reads reaches it as .Revoked;
//   - a lease lent for one call is gone after the reply, and after a plugin
//     that hangs past the call's deadline.
// Each check prints a line only when it fails; the last line counts them.
//
// Run as a plugin (its first argument "plugin"), it takes its channel end
// ("plugin") and answers one request on it.
package plugintest

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:shared"

Op :: enum u32 {
	Build_Die = 1, // build, say so, and wait to be killed
	Building, // its answer
	Build, // build a list (value 1) or a list with a link out of bounds (0), seal it, send it
	Read, // read a leased VMO until it is revoked
	Reading, // its first answer
	Call, // a call with a lent VMO: read it, keep it, answer its value
	Check, // what the kept lease answers now
	Hang, // a call with a lent VMO: never answered; the lease's status after
	Report, // an answer with a status
}

Msg :: struct {
	h:      vx.Msg_Header,
	op:     Op,
	status: vx.Status,
	value:  u64,
}

#assert(size_of(Msg) == 32)

Node :: struct { // the shared list: links are offsets from the VMO's start
	next:  u64,
	value: u64,
}

LIST_SIZE :: 4 * 4096

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if ok {
		return
	}
	failures += 1
	rt.print("plugintest: FAILED line ", u64(loc.line), ": ", what, "\n")
}

after_ms :: proc "contextless" (ms: i64) -> vx.Instant {
	return rt.clock_read() + vx.Instant(ms * 1_000_000)
}

// The next message on ch, waiting until deadline; its handle, if it has one,
// in h. .Ok, .Err_Timed_Out, or .Err_Peer_Closed.
receive :: proc "contextless" (ch: vx.Handle, m: ^Msg, h: ^vx.Handle, deadline: vx.Instant) -> vx.Status {
	port, st := rt.port_create()
	for st == .Ok {
		got: [1]vx.Handle
		size: vx.Msg_Size
		size, st = rt.channel_read(ch, memory.ptr_to_bytes(m), got[:])
		if st != .Err_Should_Wait {
			if h != nil {
				h^ = size.handles != 0 ? got[0] : vx.HANDLE_NONE
			}
			break
		}
		pk: [1]vx.Packet
		_ = rt.port_bind(port, ch, .Readable, 1)
		_ = rt.port_bind(port, ch, .Peer_Closed, 2)
		n, _ := rt.port_wait(port, deadline, 0, pk[:])
		st = n == 1 ? .Ok : .Err_Timed_Out
	}
	_ = rt.handle_close(port)
	return st
}

send :: proc "contextless" (ch: vx.Handle, op: Op, status: vx.Status, value: u64, h: vx.Handle) -> vx.Status {
	m := Msg{op = op, status = status, value = value}
	handles := [1]vx.Handle{h}
	return rt.channel_write(ch, memory.ptr_to_bytes(&m), handles[:h != vx.HANDLE_NONE ? 1 : 0])
}

word_at :: proc "contextless" (at: u64) -> u64 {
	return intrinsics.volatile_load(cast(^u64)uintptr(at))
}

// --- The plugin ---

revoked: u32 // a touch of a revoked lease, seen by the handler
spare: vx.Handle // what the handler maps in its place
never: u32 // a futex word no one wakes

on_note :: proc "contextless" (e: ^vx.Exception, note: string, fp: rawptr) -> rt.Noted {
	if e.kind != .Revoked {
		return .Dflt
	}
	intrinsics.atomic_store(&revoked, 1)
	at := e.address &~ 4095
	_ = rt.as_unmap(rt.self, at, 4096)
	_, _ = rt.as_map(rt.self, spare, 0, 4096, {}, at) // the load made again sees zero
	return .Cont
}

// A list of eight nodes in a VMO of its own, sealed; with bad, the last link
// points past the VMO. after_seal is its own write's status after the seal.
build :: proc "contextless" (bad: bool) -> (v: vx.Handle, after_seal: vx.Status) {
	st: vx.Status
	v, st = rt.vmo_create(LIST_SIZE)
	if st != .Ok {
		return vx.HANDLE_NONE, st
	}
	at, mst := rt.as_map(rt.self, v, 0, LIST_SIZE, {.Write})
	if mst != .Ok {
		return vx.HANDLE_NONE, mst
	}
	n := ([^]Node)(uintptr(at))[:LIST_SIZE / size_of(Node)]
	for i in u64(0) ..< 8 {
		n[i * 64] = {next = i < 7 ? (i + 1) * 64 * size_of(Node) : 0, value = i + 1}
	}
	if bad {
		n[6 * 64].next = 1 << 40
	}
	_ = rt.as_unmap(rt.self, at, LIST_SIZE) // a seal wants no writable mapping
	after_seal = rt.vmo_seal(v)
	if after_seal == .Ok {
		one := u64(1)
		after_seal = rt.vmo_write(v, 0, memory.ptr_to_bytes(&one)) // its own write refused too
	}
	return
}

plugin :: proc "contextless" () -> string {
	ch := rt.spawn_take("plugin")
	st: vx.Status
	spare, st = rt.vmo_create(4096)
	if ch == vx.HANDLE_NONE || st != .Ok {
		return "no channel"
	}
	_ = rt.notify(on_note)
	m: Msg
	got: vx.Handle
	if receive(ch, &m, &got, after_ms(5000)) != .Ok {
		return "no request"
	}
	value: u64
	#partial switch m.op {
	case .Build_Die:
		_, _ = rt.vmo_create(LIST_SIZE) // half built, never sent
		_ = send(ch, .Building, .Ok, 0, vx.HANDLE_NONE)
		_ = rt.futex_wait(&never, 0, vx.INFINITE) // until the host kills it
	case .Build:
		v, after_seal := build(m.value == 0)
		_ = send(ch, .Report, after_seal, 0, v)
	case .Read:
		at, mst := rt.as_map(rt.self, got, 0, 4096, {})
		if mst != .Ok {
			return "cannot map the lease"
		}
		_ = send(ch, .Reading, .Ok, word_at(at), vx.HANDLE_NONE)
		for end := after_ms(5000); intrinsics.atomic_load(&revoked) == 0 && rt.clock_read() < end; {
			value += word_at(at) // reading, until the host takes it back
		}
		_ = send(ch, .Report, intrinsics.atomic_load(&revoked) != 0 ? .Err_Revoked : .Ok, value, vx.HANDLE_NONE)
	case .Call: // m.h.txid is the call's: the reply goes back with it
		if at, mst := rt.as_map(rt.self, got, 0, 4096, {}); mst == .Ok {
			value = word_at(at)
		}
		m = {h = {txid = m.h.txid}, op = .Report, value = value}
		_ = rt.channel_write(ch, memory.ptr_to_bytes(&m))
		if receive(ch, &m, nil, after_ms(5000)) == .Ok && m.op == .Check {
			rst := rt.vmo_read(got, 0, memory.ptr_to_bytes(&value)) // the call is over
			_ = send(ch, .Report, rst, value, vx.HANDLE_NONE)
		}
	case .Hang:
		_ = rt.vmo_read(got, 0, memory.ptr_to_bytes(&value))
		_ = rt.futex_wait(&never, 0, after_ms(2500)) // past the call's deadline: no answer
		rst := rt.vmo_read(got, 0, memory.ptr_to_bytes(&value))
		_ = send(ch, .Report, rst, value, vx.HANDLE_NONE)
	case:
		return "unknown request"
	}
	return ""
}

// --- The host ---

image: [1 << 20]u8
image_size: int
space: ns.Namespace

// A plugin: its task, and the host's end of its channel.
spawn_plugin :: proc "contextless" () -> (task, end: vx.Handle, ok: bool) {
	a, b, cst := rt.channel_create()
	if cst != .Ok {
		return
	}
	handles := [2]vx.Handle{b, vx.HANDLE_NONE}
	names := [2]string{"plugin", ""}
	count := 1
	if c := rt.console_connector(); c != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(c, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "console"
			count += 1
		}
	}
	args := rt.Spawn_Args {
		name         = "plugin",
		image        = image[:image_size],
		handles      = handles[:count],
		handle_names = names[:count],
		records      = "arg=plugin\n",
	}
	st: vx.Status
	task, st = rt.spawn_elf(&args)
	if st != .Ok {
		_ = rt.handle_close(a)
		return vx.HANDLE_NONE, vx.HANDLE_NONE, false
	}
	return task, a, true
}

// A call to a plugin lending it mem: the call's status, and its reply in r.
lend :: proc "contextless" (end: vx.Handle, op: Op, mem: vx.Handle, r: ^Msg, deadline: vx.Instant) -> vx.Status {
	rq := Msg{op = op}
	lent := [1]vx.Handle{mem}
	call := vx.Call {
		wr_bytes   = &rq,
		wr_len     = size_of(rq),
		wr_handles = raw_data(lent[:]),
		wr_count   = 1,
		rd_bytes   = r,
		rd_cap     = size_of(r^),
		lent       = 1,
	}
	return rt.channel_call(end, &call, deadline)
}

// The sum of a sealed list's values, following links checked by vx:shared;
// refused counts the links it would not follow.
walk :: proc "contextless" (s: []u8) -> (sum: u64, refused: u32) {
	n := shared.at_as(s, 0, Node)
	for hops := 0; n != nil && hops < 64; hops += 1 {
		sum += n.value
		next := intrinsics.volatile_load(&n.next) // read once: the bytes are sealed, but the habit is the safe one
		n = next != 0 ? shared.at_as(s, next, Node) : nil
		if next != 0 && n == nil {
			refused += 1
		}
	}
	return
}

test_killed_while_building :: proc "contextless" () {
	task, end, ok := spawn_plugin()
	check(ok)
	check(send(end, .Build_Die, .Ok, 0, vx.HANDLE_NONE) == .Ok)
	m: Msg
	got: vx.Handle
	check(receive(end, &m, &got, after_ms(5000)) == .Ok && m.op == .Building && got == vx.HANDLE_NONE)
	check(rt.task_kill(task, "replaced") == .Ok)
	check(receive(end, &m, &got, after_ms(5000)) == .Err_Peer_Closed && got == vx.HANDLE_NONE) // nothing was published
	rt.close_all(end, task)
}

test_sealed_result :: proc "contextless" (bad: bool) {
	task, end, ok := spawn_plugin()
	check(ok)
	check(send(end, .Build, .Ok, bad ? 0 : 1, vx.HANDLE_NONE) == .Ok)
	m: Msg
	v: vx.Handle
	check(receive(end, &m, &v, after_ms(5000)) == .Ok && m.op == .Report && v != vx.HANDLE_NONE)
	check(m.status == .Err_Access) // the plugin's own write after its seal
	_, st := rt.as_map(rt.self, v, 0, LIST_SIZE, {.Write})
	check(st == .Err_Access) // nor the host's
	one := u64(1)
	check(rt.vmo_write(v, 0, memory.ptr_to_bytes(&one)) == .Err_Access)
	at: u64
	at, st = rt.as_map(rt.self, v, 0, LIST_SIZE, {})
	check(st == .Ok)
	sum, refused := walk(([^]u8)(uintptr(at))[:LIST_SIZE])
	if bad {
		check(sum == 1 + 2 + 3 + 4 + 5 + 6 + 7 && refused == 1) // the seventh's link points out: not followed
	} else {
		check(sum == 36 && refused == 0)
	}
	_ = rt.as_unmap(rt.self, at, LIST_SIZE)
	rt.close_all(v, end, task)
}

test_revoked_while_reading :: proc "contextless" () {
	value := u64(77)
	input, st := rt.vmo_create(4096)
	check(st == .Ok && rt.vmo_write(input, 0, memory.ptr_to_bytes(&value)) == .Ok)
	lease, given: vx.Handle
	lst, gst: vx.Status
	lease, lst = rt.vmo_lease(input)
	if lst == .Ok {
		given, gst = rt.handle_dup(lease, {.Read, .Map, .Transfer})
	}
	check(lst == .Ok && gst == .Ok)
	task, end, ok := spawn_plugin()
	check(ok)
	check(send(end, .Read, .Ok, 0, given) == .Ok)
	m: Msg
	check(receive(end, &m, nil, after_ms(5000)) == .Ok && m.op == .Reading && m.value == 77)
	check(rt.vmo_revoke(lease) == .Ok) // while it reads
	check(receive(end, &m, nil, after_ms(5000)) == .Ok && m.op == .Report && m.status == .Err_Revoked)
	check(rt.vmo_read(input, 0, memory.ptr_to_bytes(&value)) == .Ok && value == 77) // the host's own stays
	rt.close_all(lease, input, end, task)
}

test_lent :: proc "contextless" () {
	value := u64(5150)
	input, st := rt.vmo_create(4096)
	check(st == .Ok && rt.vmo_write(input, 0, memory.ptr_to_bytes(&value)) == .Ok)
	// Answered: read through the lent memory, which is gone once the call is.
	task, end, ok := spawn_plugin()
	check(ok)
	m: Msg
	check(lend(end, .Call, input, &m, after_ms(5000)) == .Ok && m.value == 5150)
	check(send(end, .Check, .Ok, 0, vx.HANDLE_NONE) == .Ok)
	check(receive(end, &m, nil, after_ms(5000)) == .Ok && m.status == .Err_Revoked)
	rt.close_all(end, task)
	// Never answered: the deadline ends the call and the lease with it.
	task, end, ok = spawn_plugin()
	check(ok)
	check(lend(end, .Hang, input, &m, after_ms(1500)) == .Err_Timed_Out) // read by then, even under TCG
	check(receive(end, &m, nil, after_ms(5000)) == .Ok && m.op == .Report && m.status == .Err_Revoked)
	check(rt.vmo_read(input, 0, memory.ptr_to_bytes(&value)) == .Ok && value == 5150)
	rt.close_all(end, task, input)
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	if a := rt.args(); len(a) > 0 && a[0] == "plugin" {
		if why := plugin(); why != "" {
			rt.exits(why)
		}
		return 0
	}
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	if f: ns.File; ns.open(&space, "/boot/bin/plugintest", p9.OREAD, &f) == .Ok {
		image_size, _ = ns.read_all(&f, image[:])
		ns.close(&f)
	}
	check(image_size > 0)
	test_killed_while_building()
	test_sealed_result(false)
	test_sealed_result(true)
	test_revoked_while_reading()
	test_lent()
	rt.print("plugintest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	if failures != 0 {
		rt.exits("FAILED")
	}
	return 0
}
