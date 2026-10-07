// 9P over a ring: 9px+shm, the local transport.
//
// Connecting. A server reads a listen channel, which svcd posts as
// /srv/NAME and hands out to clients. A client sends CONNECT there with
// channel_call; the server creates a ring, keeps the server end, and answers
// with the client end and the ring's memory. Each connection is its own ring,
// so each queue has one producer and one consumer, as lib/ring requires.
//
// Messages. One 9P message is one submission: opcode RING_MSG, its bytes at
// arena_off in the client's arena, len bytes long. The reply is one
// completion: result is its length, aux2 its offset in the server's arena.
//
// Pipelining (upstream's M6 step 6d4a): a connection has several requests in
// flight, and the server answers them in any order. The client's region for
// a request stays its until the reply comes (or, for a flushed request, the
// Rflush), as the server may read it again while it holds the request: so
// its arena is chunks taken and given back in any order (Chunks), and a
// request held for long pins only its own. The server's region for a reply
// is freed once the client has consumed that completion, which is in order,
// so its arena is allotted in order (lib/p9ring's Arena). So each side
// knows, without asking, what of its arena is free.
//
// A reply that carries a handle (Rmap's VMO) has CQE_HANDLE in flags and the
// ring's handle slot in aux (ring_put_handles), which the client takes. A
// request that carries one (dref's VMO) has .Handles and handle_slot.
// Each side copies the other's bytes out before it decodes them, and a peer
// that names bytes outside its arena, or sends a reply that does not fit, is
// treated as gone.
//
// This file is the client, which every program has for its console;
// lib/p9ring is the server.
package rt

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:p9"
import "vx:ring"

CONNECT :: u32(0x3970_6e63) // the listen channel's one ordinal: "cnp9"
CONNECT_REFUSED :: u32(1) // a CONNECT reply's flags: no ring, and no handles
RING_MSG :: u16(1) // the one submission opcode
CQE_HANDLE :: u32(1) // a completion's flags: a handle in slot aux
MSIZE :: 16 * 1024
DEPTH :: 8 // requests in flight on a connection, at most

PARAMS :: vx.Ring_Params {
	sq_entries   = DEPTH,
	cq_entries   = DEPTH,
	sqe_size     = size_of(vx.Sqe),
	cqe_size     = size_of(vx.Cqe),
	client_arena = 2 * MSIZE, // two whole messages, more smaller ones; a call waits for room
	server_arena = 3 * MSIZE, // the client's calls reserve their replies' room, an msize short of it
}

// Maps a ring's memory into this task and attaches to it as one side; a
// ring it will not attach to is unmapped again.
@(require_results)
map_ring :: proc "contextless" (mem: vx.Handle, side: ring.Side, r: ^ring.Ring) -> vx.Status {
	return session_map(mem, side, PARAMS, r)
}

// Lets a ring's memory go from this task's address space.
ring_unmap :: proc "contextless" (r: ^ring.Ring) {
	session_unmap(r)
}

// --- The client's arena: chunks ---
//
// 64 chunks, a bit each. A request of one chunk (most: a read, a walk, a
// clunk, the kind a server holds) is placed from the top down, and a longer
// one (a write's) first fit from the bottom up, so the small ones a server
// holds for long leave the long run a write needs.

@(private="file")
Chunks :: struct {
	size: u64, // the arena's; a chunk is size / 64
	used: u64, // bit i: chunk i taken
}

@(private="file")
chunk_mask :: proc "contextless" (n: u64) -> u64 {
	return n == 64 ? max(u64) : (u64(1) << n) - 1
}

// The offset of length bytes taken; not ok if there is no run that long free.
@(private="file")
chunks_take :: proc "contextless" (a: ^Chunks, length: u64) -> (off: u64, ok: bool) {
	chunk := a.size / 64
	n := (length + chunk - 1) / chunk
	if length == 0 || n > 64 {
		return 0, false
	}
	if n == 1 {
		for i := u64(63); i < 64; i -= 1 { // from the top down, until it wraps
			if a.used & (u64(1) << i) == 0 {
				a.used |= u64(1) << i
				return i * chunk, true
			}
		}
		return 0, false
	}
	mask := chunk_mask(n)
	for i := u64(0); i + n <= 64; i += 1 {
		if a.used & (mask << i) == 0 {
			a.used |= mask << i
			return i * chunk, true
		}
	}
	return 0, false
}

// Gives back the length bytes at off that chunks_take gave.
@(private="file")
chunks_give :: proc "contextless" (a: ^Chunks, off, length: u64) {
	chunk := a.size / 64
	n := (length + chunk - 1) / chunk
	a.used &~= chunk_mask(n) << (off / chunk)
}

// --- Client ---
//
// Several threads share a connection (upstream's M6 step 6d4a), as 9front's
// mount driver shares a mount (devmnt.c's mountio and mountmux). A call
// takes a slot: its own buffer, a tag no call in flight has, and its share
// of both arenas. Whoever waits first leads: it reads every completion and
// hands each reply to its slot, waking that slot's thread; the others sleep
// on the connection's count of replies, and when the leader's own call is
// done, a waiting one leads next. One slot is kept for Tflush, so a call can
// always be flushed.
//
// The server's arena is never overrun: each call reserves room for the
// largest reply its request can have (a read's count, an msize for a stat,
// 512 bytes for the rest, which an Rerror's text fits), and the reservation
// goes back as its reply is taken. The reservations stay an msize short of
// the arena: replies are placed in order, and the one that would run past
// its end starts again at 0, leaving the end's rest unused (less than an
// msize, once between the oldest reply and the newest), so the replies the
// server may be holding always fit. A call that finds no room waits for a
// reply to make some.
//
// A call interrupted (a note, if the connection's `interrupted` says the
// caller wants to hear of it) or past its timeout is flushed: Tflush with its
// tag, and then its reply if that came first (it is answered after all), or
// .Err_Interrupted or .Err_Timed_Out. Its tag and its arena stay its own
// until then, so nothing the server still has is reused. No Rflush within
// the timeout ends the connection.

@(private="file")
KEY_BELL :: 1
@(private="file")
KEY_CLOSED :: 2
RING_KEY_POKE :: u64(3) // a packet ring_waiting's port gets: a note came just before the sleep

// A program's own say in how calls wait, on every connection (the musl back
// end's, upstream's M6 step 6d4b; unset elsewhere):
//   - ring_flush_wanted: an interrupted call is flushed if it says so (a
//     connection's own `interrupted` comes first);
//   - ring_waiting: what the thread is about to sleep on (a port, or a
//     futex word), and (HANDLE_NONE, nil) after, so a note handler that
//     runs just before the sleep can end it (a RING_KEY_POKE packet, or the
//     word moved).
ring_flush_wanted: proc "contextless" () -> bool
ring_waiting: proc "contextless" (port: vx.Handle, word: ^u32)

@(private="file")
Slot_State :: enum u32 {
	Free,
	Taken,
	Sent,
	Done,
}

@(private="file")
Slot :: struct {
	x:         p9.Xfer, // first: the transport finds its slot from it
	buf:       ^[MSIZE]u8, // the request, then the reply; mapped at its first call
	state:     u32, // a Slot_State, atomic: a follower looks without the lock
	gen:       u32, // with the slot's index, the request's user_data
	at, len:   u64, // the request's bytes in the client's arena; len 0: none
	reserve:   u64, // its share of the server's arena
	reply_len: int, // the reply's length, once Done,
	status:    vx.Status, // or why there is none
	// p9_send's call (upstream's M6 step 6d4d1): its reply waits for
	// p9_receive, and its caller's port gets notify_key when it comes.
	async:      bool,
	sent:       p9.Type, // its type, for its reply's
	notify:     vx.Handle,
	notify_key: u64,
}
#assert(offset_of(Slot, x) == 0)

@(private="file")
state_of :: proc "contextless" (s: ^Slot) -> Slot_State {
	return Slot_State(intrinsics.atomic_load(&s.state))
}

@(private="file")
state_set :: proc "contextless" (s: ^Slot, to: Slot_State) {
	intrinsics.atomic_store(&s.state, u32(to))
}

// One connection: a 9P client over its own ring, which the threads of a
// program share. Its client points back into it (ctx), so a Conn stays
// where p9_connect filled it in: never copy or move one.
Conn :: struct {
	c:               p9.Client,
	ring:            ring.Ring,
	end:             vx.Handle,
	port:            vx.Handle,
	dead:            bool,
	timeout:         vx.Duration, // a call not answered in that long is flushed (0: none)
	// When a wait is interrupted (a note): whether the caller wants the call
	// flushed, and .Err_Interrupted. Without it the call goes on (upstream
	// 01 §9).
	interrupted:     proc "contextless" (ctx: rawptr) -> bool,
	interrupted_ctx: rawptr,
	lock:            Mutex, // the slots, tags and arenas, producing, and who leads
	leading:         bool, // a thread reads completions for everyone
	next_tag:        u16,
	budget:          u64, // the server's arena, reserved by calls in flight
	freed:           u32, // a futex: changes when a slot comes free
	replies:         u32, // a futex: changes with each reply taken, and as a leader stops
	arena:           Chunks, // the client's
	slots:           [DEPTH]Slot,
}

// The most of the server's arena a reply to this request can take.
@(private="file")
reply_max :: proc "contextless" (req: []u8, msize: u32) -> u64 {
	SMALL :: u64(512)
	if len(req) < 7 {
		return SMALL
	}
	#partial switch p9.Type(req[4]) {
	case .Tread:
		count := u64(msize)
		if len(req) >= 23 {
			count = u64(req[19]) | u64(req[20]) << 8 | u64(req[21]) << 16 | u64(req[22]) << 24
		}
		return max(count + 11, SMALL)
	case .Tstat, .Treadlink, .Tgetlock:
		return u64(msize)
	}
	return SMALL
}

@(private="file")
bump :: proc "contextless" (word: ^u32) {
	intrinsics.atomic_add(word, 1)
	_, _ = futex_wake(word, max(u32))
}

// Ends the connection: every call in flight is answered .Err_Peer_Closed.
// Under the lock.
@(private="file")
kill :: proc "contextless" (k: ^Conn) {
	k.dead = true
	for &s in k.slots {
		if state_of(&s) != .Sent {
			continue
		}
		s.reply_len, s.status = 0, .Err_Peer_Closed
		state_set(&s, .Done)
	}
	bump(&k.freed)
	bump(&k.replies)
}

@(private="file")
kill_locked :: proc "contextless" (k: ^Conn) {
	mutex_lock(&k.lock)
	kill(k)
	mutex_unlock(&k.lock)
}

// A free slot, its tag chosen, its buffer mapped; waits for one. flush: the
// slot kept for Tflush may be taken. nil once the connection is gone.
@(private="file")
slot_take :: proc "contextless" (k: ^Conn, version, flush: bool) -> ^Slot {
	for {
		mutex_lock(&k.lock)
		if k.dead {
			mutex_unlock(&k.lock)
			return nil
		}
		used := 0
		s: ^Slot
		for &x in k.slots {
			if state_of(&x) != .Free {
				used += 1
			} else if s == nil {
				s = &x
			}
		}
		if s != nil && used < (flush ? DEPTH : DEPTH - 1) {
			tag := p9.NOTAG
			for !version { // the next not in flight, rotating, as a just-freed tag waits its turn
				tag = k.next_tag % p9.NOTAG
				k.next_tag += 1
				taken := false
				for &x in k.slots {
					if state_of(&x) != .Free && x.x.tag == tag {
						taken = true
						break
					}
				}
				if !taken {
					break
				}
			}
			if s.buf == nil {
				if vmo, st := vmo_create(MSIZE); st == .Ok {
					if at, mst := as_map(self, vmo, 0, MSIZE, {.Write}); mst == .Ok {
						s.buf = (^[MSIZE]u8)(uintptr(at))
					}
					close_all(vmo) // the mapping keeps it
				}
			}
			got := s.buf != nil
			if got {
				state_set(s, .Taken)
				s.gen += 1
				s.len, s.reserve = 0, 0
				s.x = {
					req  = s.buf[:],
					resp = s.buf[:],
					tag  = tag,
				}
				s.async, s.notify = false, vx.HANDLE_NONE
			}
			mutex_unlock(&k.lock)
			return got ? s : nil
		}
		seen := intrinsics.atomic_load(&k.freed)
		mutex_unlock(&k.lock)
		_ = futex_wait(&k.freed, seen, vx.INFINITE)
	}
}

// Gives a slot back, and its handles. Its arena went back with its reply.
@(private="file")
slot_give :: proc "contextless" (k: ^Conn, s: ^Slot) {
	close_all(s.x.handle, s.x.send_handle) // one no call took; one never sent
	s.x.handle, s.x.send_handle = vx.HANDLE_NONE, vx.HANDLE_NONE
	mutex_lock(&k.lock)
	state_set(s, .Free)
	intrinsics.atomic_add(&k.freed, 1)
	mutex_unlock(&k.lock)
	_, _ = futex_wake(&k.freed, max(u32))
}

// A slot's arena and its reservation of the server's, given back. Under the
// lock.
@(private="file")
slot_release :: proc "contextless" (k: ^Conn, s: ^Slot) {
	chunks_give(&k.arena, s.at, s.len)
	s.len = 0
	k.budget -= s.reserve
	s.reserve = 0
}

// A completion, handed to its slot. False if the server broke the protocol.
@(private="file")
deliver :: proc "contextless" (k: ^Conn, c: ^vx.Cqe) -> bool {
	i, gen := c.user_data & 0xff, u32(c.user_data >> 8)
	mutex_lock(&k.lock)
	s := i < DEPTH ? &k.slots[i] : nil
	p: []u8
	ok := s != nil && state_of(s) == .Sent && s.gen == gen && c.result > 0 && c.result <= MSIZE
	if ok {
		p, ok = ring.peer_bytes(&k.ring, c.aux2, u64(c.result))
	}
	if !ok {
		mutex_unlock(&k.lock)
		return false
	}
	copy(s.buf[:], p)
	if c.flags & CQE_HANDLE != 0 {
		h: [1]vx.Handle
		if got, _ := ring_take_handles(k.end, c.aux, h[:]); got == 1 {
			s.x.handle = h[0]
		}
	}
	slot_release(k, s)
	s.reply_len, s.status = int(c.result), .Ok
	state_set(s, .Done)
	intrinsics.atomic_add(&k.replies, 1)
	notify := s.async ? s.notify : vx.HANDLE_NONE
	key := s.notify_key
	mutex_unlock(&k.lock)
	_, _ = futex_wake(&k.replies, max(u32))
	if notify != vx.HANDLE_NONE { // p9_send's caller: its reply is here
		pk := vx.Packet{key = key}
		_ = port_post(notify, &pk)
	}
	return true
}

// Whether the wait is over: s done, or (s nil) a reply taken since `any`.
@(private="file")
waited :: proc "contextless" (k: ^Conn, s: ^Slot, any: u32) -> bool {
	return s != nil ? state_of(s) == .Done : intrinsics.atomic_load(&k.replies) != any
}

// Whether the caller of an interrupted call wants it flushed.
@(private="file")
wants_flush :: proc "contextless" (k: ^Conn) -> bool {
	if k.interrupted != nil {
		return k.interrupted(k.interrupted_ctx)
	}
	return flush_due()
}

// Before a sleep: whether a signal already came that wants the call flushed
// (the program's hook, which looks at what is pending; a connection's own
// is asked only when a wait is interrupted).
@(private="file")
flush_due :: proc "contextless" () -> bool {
	return ring_flush_wanted != nil && ring_flush_wanted()
}

@(private="file")
will_wait :: proc "contextless" (port: vx.Handle, word: ^u32) {
	if ring_waiting != nil {
		ring_waiting(port, word)
	}
}

// Leads: reads every completion, until the wait is over. .Err_Interrupted
// (only with hear), .Err_Timed_Out, .Err_Peer_Closed.
@(private="file", require_results)
lead :: proc "contextless" (k: ^Conn, s: ^Slot, any: u32, deadline: vx.Instant, hear: bool) -> vx.Status {
	for {
		for {
			c: vx.Cqe
			st := ring.consume(&k.ring, memory.ptr_to_bytes(&c))
			if st == .Err_Should_Wait {
				break
			}
			if st != .Ok || !deliver(k, &c) {
				return .Err_Peer_Closed
			}
		}
		if waited(k, s, any) {
			return .Ok
		}
		if hear && flush_due() {
			return .Err_Interrupted // one that came before the sleep
		}
		seen, _ := counter_read(k.end)
		if !ring.prepare_sleep(&k.ring) {
			continue
		}
		pk: [1]vx.Packet
		_ = port_bind(k.port, k.end, .Counter_Ge, KEY_BELL, seen + 1)
		will_wait(k.port, nil)
		got, wst := port_wait(k.port, deadline, 0, pk[:])
		will_wait(vx.HANDLE_NONE, nil)
		ring.end_sleep(&k.ring) // the binding made for this wait may fire later too
		if wst == .Err_Interrupted || (got == 1 && pk[0].key == RING_KEY_POKE) {
			if hear && wants_flush(k) {
				return .Err_Interrupted
			}
			continue
		}
		if wst == .Err_Timed_Out {
			return .Err_Timed_Out
		}
		if got != 1 || pk[0].key == KEY_CLOSED {
			return .Err_Peer_Closed
		}
	}
}

// Waits for slot s's reply (s nil: for any reply after `any`), leading if no
// one does. .Ok, .Err_Peer_Closed, .Err_Timed_Out, or .Err_Interrupted (only
// with hear).
@(private="file", require_results)
wait :: proc "contextless" (k: ^Conn, s: ^Slot, any: u32, deadline: vx.Instant, hear: bool) -> vx.Status {
	for {
		mutex_lock(&k.lock)
		if waited(k, s, any) {
			mutex_unlock(&k.lock)
			return .Ok
		}
		if k.dead {
			mutex_unlock(&k.lock)
			return .Err_Peer_Closed
		}
		if !k.leading {
			k.leading = true
			mutex_unlock(&k.lock)
			st := lead(k, s, any, deadline, hear)
			mutex_lock(&k.lock)
			k.leading = false
			if st == .Err_Peer_Closed {
				kill(k)
			}
			bump(&k.replies) // the next to wait leads: every waiter looks again
			for &a in k.slots { // and p9_send's callers, to arm their own ports
				if a.async && a.notify != vx.HANDLE_NONE && state_of(&a) == .Sent {
					pk := vx.Packet{key = a.notify_key}
					_ = port_post(a.notify, &pk)
				}
			}
			mutex_unlock(&k.lock)
			if st != .Ok {
				return st
			}
			continue
		}
		// Followers sleep on the count of replies, which also moves when the
		// leader stops: one taken between the look and the sleep ends the sleep.
		value := intrinsics.atomic_load(&k.replies)
		mutex_unlock(&k.lock)
		if hear && flush_due() {
			return .Err_Interrupted // one that came before the sleep
		}
		will_wait(vx.HANDLE_NONE, &k.replies)
		w := futex_wait(&k.replies, value, deadline)
		will_wait(vx.HANDLE_NONE, nil)
		#partial switch w {
		case .Err_Timed_Out:
			return .Err_Timed_Out
		case .Err_Interrupted:
			if hear && wants_flush(k) {
				return .Err_Interrupted
			}
		case .Err_Bad_State:
			if hear && flush_due() {
				return .Err_Interrupted // a poke
			}
		}
	}
}

// Puts slot s's request (n bytes in its buffer) on the ring, once there is
// room for it and its reply. .Ok, or why not.
@(private="file", require_results)
put :: proc "contextless" (k: ^Conn, s: ^Slot, n: int, deadline: vx.Instant) -> vx.Status {
	arena := ring.arena(&k.ring)
	server_size := k.ring.h.server_arena_size
	reserve := reply_max(s.buf[:n], k.c.msize != 0 ? k.c.msize : MSIZE)
	for {
		mutex_lock(&k.lock)
		if k.dead {
			mutex_unlock(&k.lock)
			return .Err_Peer_Closed
		}
		at: u64
		ok := false
		if k.budget + reserve <= server_size - MSIZE {
			at, ok = chunks_take(&k.arena, u64(n))
		}
		if ok {
			entry, sok := ring.produce_slot(&k.ring)
			if !sok { // the server took none of the depth's submissions: broken
				chunks_give(&k.arena, at, u64(n))
				kill(k)
				mutex_unlock(&k.lock)
				return .Err_Peer_Closed
			}
			copy(arena[at:], s.buf[:n])
			e := vx.Sqe {
				opcode    = RING_MSG,
				len       = u32(n),
				arena_off = u32(at),
				user_data = u64(s.gen) << 8 | u64((uintptr(s) - uintptr(&k.slots[0])) / size_of(Slot)),
			}
			if s.x.send_handle != vx.HANDLE_NONE { // dref's VMO, moved to a slot for the server
				h := [1]vx.Handle{s.x.send_handle}
				s.x.send_handle = vx.HANDLE_NONE
				if hslot, hst := ring_put_handles(k.end, h[:]); hst == .Ok {
					e.flags = {.Handles}
					e.handle_slot = hslot
				} else {
					close_all(h[0]) // the server finds none, and the call fails
				}
			}
			copy(entry, memory.ptr_to_bytes(&e))
			s.at, s.len = at, u64(n)
			s.reserve = reserve
			k.budget += reserve
			state_set(s, .Sent)
			if ring.produce(&k.ring) {
				_ = ring_notify(k.end)
			}
			mutex_unlock(&k.lock)
			return .Ok
		}
		any := intrinsics.atomic_load(&k.replies)
		mutex_unlock(&k.lock)
		wait(k, nil, any, deadline, false) or_return // a reply makes room
	}
}

// Flushes slot s's call, which `why` ended (.Err_Interrupted,
// .Err_Timed_Out): its reply's length if it came after all, else why.
@(private="file")
flush :: proc "contextless" (k: ^Conn, s: ^Slot, why: vx.Status) -> (reply_len: int, st: vx.Status) {
	f := slot_take(k, false, true)
	if f == nil {
		return 0, .Err_Peer_Closed
	}
	t := p9.Msg{type = .Tflush, tag = f.x.tag, oldtag = s.x.tag}
	n := p9.encode(&t, f.buf[:])
	deadline := clock_read() + vx.Instant(k.timeout != 0 ? k.timeout : 5_000_000_000)
	st = put(k, f, n, deadline)
	if st == .Ok {
		st = wait(k, f, 0, deadline, false)
	}
	if st == .Err_Timed_Out { // no Rflush: a server that answers nothing more
		kill_locked(k)
	}
	slot_give(k, f)
	if state_of(s) == .Done {
		return s.reply_len, s.status // answered first, or the connection went
	}
	if st != .Ok {
		return 0, .Err_Peer_Closed
	}
	mutex_lock(&k.lock) // Rflush: no reply will come, and what it held is free
	slot_release(k, s)
	state_set(s, .Taken)
	mutex_unlock(&k.lock)
	return 0, why
}

@(private="file")
ring_begin :: proc "contextless" (ctx: rawptr, version: bool) -> ^p9.Xfer {
	s := slot_take((^Conn)(ctx), version, false)
	return s != nil ? &s.x : nil
}

@(private="file")
ring_call :: proc "contextless" (ctx: rawptr, x: ^p9.Xfer, n: int) -> (reply_len: int, st: vx.Status) {
	k := (^Conn)(ctx)
	s := (^Slot)(x)
	deadline := k.timeout != 0 ? clock_read() + vx.Instant(k.timeout) : vx.INFINITE
	put(k, s, n, deadline) or_return
	st = wait(k, s, 0, deadline, true)
	#partial switch st {
	case .Ok:
		return s.reply_len, s.status
	case .Err_Peer_Closed:
		return 0, st
	}
	return flush(k, s, st)
}

@(private="file")
ring_end :: proc "contextless" (ctx: rawptr, x: ^p9.Xfer) {
	slot_give((^Conn)(ctx), (^Slot)(x))
}

@(private="file")
ring_pipe := p9.Pipe {
	msize = MSIZE,
	begin = ring_begin,
	call  = ring_call,
	end   = ring_end,
}

// Lets go of the slots' buffers and handles. The connection is no one
// else's by now.
@(private="file")
slots_unmap :: proc "contextless" (k: ^Conn) {
	for &s in k.slots {
		close_all(s.x.handle, s.x.send_handle)
		if s.buf != nil {
			_ = as_unmap(self, u64(uintptr(s.buf)), MSIZE)
		}
	}
}

// Opens a connection through a connector (a listen channel's client end,
// which stays the caller's) and negotiates 9Px, with the posix, xattr, map
// and dref extensions where the server has them. The connection is ready to
// attach.
@(require_results)
p9_connect :: proc "contextless" (connector: vx.Handle, k: ^Conn) -> vx.Status {
	return p9_connect_within(connector, k, 5_000_000_000)
}

// p9_connect, waiting at most `wait` for the server to take it and answer
// its version (a console reconnecting while its driver restarts waits less:
// the Rust port's finding, upstream's 5c1bbc9).
@(require_results)
p9_connect_within :: proc "contextless" (connector: vx.Handle, k: ^Conn, wait: vx.Duration) -> (st: vx.Status) {
	k^ = {}
	defer if st != .Ok {
		p9_disconnect(k)
	}
	req := vx.Msg_Header{ordinal = CONNECT}
	rep: vx.Msg_Header
	got: [2]vx.Handle
	call := vx.Call {
		wr_bytes     = &req,
		wr_len       = size_of(req),
		rd_bytes     = &rep,
		rd_cap       = size_of(rep),
		rd_handles   = &got[0],
		rd_count_cap = 2,
	}
	st = channel_call(connector, &call, clock_read() + vx.Instant(wait))
	if st == .Ok && call.actual.handles != 2 {
		st = .Err_Invalid
	}
	if st == .Ok {
		st = map_ring(got[1], .Client, &k.ring)
	}
	close_all(got[1]) // the mapping keeps the memory
	k.end = got[0]
	st or_return
	k.port = port_create() or_return
	port_bind(k.port, k.end, .Peer_Closed, KEY_CLOSED) or_return
	k.arena = {
		size = u64(len(ring.arena(&k.ring))),
	}
	k.c = {
		pipe = &ring_pipe,
		ctx  = k,
	}
	// The version as the connect, within its wait: a server that answers
	// nothing (one waiting on its caller, as tmpfs on procfs's crash) does not
	// hold the caller for ever (the Rust port's finding); the caller's own
	// limit, if any, after.
	k.timeout = wait
	st = p9.client_version(&k.c, MSIZE, {.Posix, .Xattr, .Map, .Dref, .Srv, .Notify}) // what the server has of them
	k.timeout = 0
	return st
}

// Ends the connection: its ring's memory and its slots' buffers are
// unmapped and its handles closed. Safe on a connection that never
// connected.
p9_disconnect :: proc "contextless" (k: ^Conn) {
	slots_unmap(k)
	ring_unmap(&k.ring)
	close_all(k.end, k.port)
	k^ = {
		dead = true,
	}
}

// --- Calls whose replies are taken later ---
//
// For a reader that waits on many things at once (poll's read-ahead, in the
// musl back end): send a request, then look for its reply, arming a port of
// the caller's to hear when one may have come. A connection carries several
// such calls beside its ordinary ones (upstream's M6 step 6d4d1). Whoever
// leads at the time hands a reply to its slot and posts the caller's packet;
// with no leader, the caller's look reads the queue itself; a leader that
// stops posts every waiting caller's packet, so each looks again and arms its
// port on the doorbell.

// Sends t, giving it a tag; its reply is taken by p9_receive with that tag.
// port gets `key` when the reply may have come (HANDLE_NONE: no packet).
@(require_results)
p9_send :: proc "contextless" (k: ^Conn, t: ^p9.Msg, port: vx.Handle, key: u64) -> vx.Status {
	s := slot_take(k, false, false)
	if s == nil {
		return .Err_Peer_Closed
	}
	t.tag = s.x.tag
	n := p9.encode(t, s.buf[:])
	s.async, s.notify, s.notify_key, s.sent = true, port, key, t.type
	st := n != 0 ? put(k, s, n, vx.INFINITE) : .Err_Too_Small
	if st != .Ok {
		s.async = false
		slot_give(k, s)
	}
	return st
}

// The slot of the call sent with tag, if it is one p9_send sent.
@(private="file")
async_slot :: proc "contextless" (k: ^Conn, tag: u16) -> ^Slot {
	for &s in k.slots {
		state := state_of(&s)
		if s.async && s.x.tag == tag && (state == .Sent || state == .Done) {
			return &s
		}
	}
	return nil
}

// Reads what has come, if no one leads: the caller's look.
@(private="file")
take_completions :: proc "contextless" (k: ^Conn) {
	mutex_lock(&k.lock)
	lead := !k.leading && !k.dead
	if lead {
		k.leading = true
	}
	mutex_unlock(&k.lock)
	if !lead {
		return
	}
	broken := false
	for !broken {
		c: vx.Cqe
		st := ring.consume(&k.ring, memory.ptr_to_bytes(&c))
		if st == .Err_Should_Wait {
			break
		}
		broken = st != .Ok || !deliver(k, &c)
	}
	mutex_lock(&k.lock)
	k.leading = false
	if broken {
		kill(k)
	}
	bump(&k.replies) // a thread waiting to lead may now
	mutex_unlock(&k.lock)
}

// The reply to the call p9_send sent with tag: .Ok, with r decoded (its data
// in the slot's buffer, until the slot's next call); .Err_Should_Wait if it
// has not come; the error an Rerror (or Rlerror) names; or .Err_Peer_Closed.
@(require_results)
p9_receive :: proc "contextless" (k: ^Conn, tag: u16, r: ^p9.Msg) -> vx.Status {
	s := async_slot(k, tag)
	if s == nil {
		return .Err_Peer_Closed
	}
	if state_of(s) != .Done {
		take_completions(k)
	}
	if state_of(s) != .Done {
		return .Err_Should_Wait
	}
	n, rst, sent := s.reply_len, s.status, s.sent
	s.async = false
	slot_give(k, s) // its buffer keeps the reply until the slot's next call
	rst or_return
	// Anything but its reply (or its error) means the server is confused,
	// and nothing more it says can be matched to a call.
	ok := p9.decode(s.buf[:n], r) == .Ok && r.tag == tag
	if ok && r.type == .Rerror {
		return p9.error_status(r.ename)
	}
	if ok && r.type == .Rlerror {
		return p9.errno_status(r.ecode)
	}
	if !ok || u8(r.type) != u8(sent) + 1 {
		kill_locked(k)
		return .Err_Peer_Closed
	}
	return .Ok
}

// Lets go of the call p9_send sent with tag, answered or not: Tflush if it
// has not been, and its slot back once the server has let it go.
p9_cancel :: proc "contextless" (k: ^Conn, tag: u16) {
	s := async_slot(k, tag)
	if s == nil {
		return
	}
	s.notify = vx.HANDLE_NONE // no packet for a caller that has gone
	if state_of(s) != .Done {
		_, _ = flush(k, s, .Err_Interrupted)
	}
	s.async = false
	slot_give(k, s)
}

// Arms port to get `key` once a reply may have come. False when one may
// already have: look again rather than wait. ring.end_sleep after.
@(require_results)
p9_arm :: proc "contextless" (k: ^Conn, port: vx.Handle, key: u64) -> bool {
	seen, _ := counter_read(k.end)
	if !ring.prepare_sleep(&k.ring) {
		return false
	}
	return port_bind(port, k.end, .Counter_Ge, key, seen + 1) == .Ok
}

// --- dref ---
//
// Treadref and Twriteref (upstream's docs/proto/dref.md), here rather than in
// lib/p9, which is built for the host too: count bytes of the file at offset
// copied into (or from) vmo at roffset by the server, in one message whatever
// the msize. The VMO stays the caller's: the request carries a duplicate (so
// it needs .Duplicate and .Transfer). Returns how many bytes moved.

@(private="file", require_results)
p9_ref :: proc "contextless" (k: ^Conn, type: p9.Type, fid: p9.Fid, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status) {
	if .Dref not_in k.c.extensions {
		return 0, .Err_Unsupported
	}
	dup := handle_dup(vmo, vx.RIGHTS_SAME) or_return
	taken: bool
	done, taken, st = p9.client_ref(&k.c, type, fid, offset, roffset, count, dup)
	if !taken {
		close_all(dup) // no call to carry it
	}
	return
}

@(require_results)
p9_readref :: proc "contextless" (k: ^Conn, fid: p9.Fid, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status) {
	return p9_ref(k, .Treadref, fid, offset, vmo, roffset, count)
}

@(require_results)
p9_writeref :: proc "contextless" (k: ^Conn, fid: p9.Fid, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (done: u32, st: vx.Status) {
	return p9_ref(k, .Twriteref, fid, offset, vmo, roffset, count)
}

// --- srv (upstream's docs/proto/srv.md, its M6 step 6d4d2a) ---

// Writes to fid with h beside the message (a post), which goes to the
// server whatever the answer, or is closed here if no call carried it.
@(require_results)
p9_write_handle :: proc "contextless" (c: ^p9.Client, fid: p9.Fid, h: vx.Handle) -> vx.Status {
	taken, st := p9.client_write_handle(c, fid, h)
	if !taken {
		close_all(h)
	}
	return st
}
