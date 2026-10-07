// vx:p9ring, 9P over a ring, the server side (lib/rt/p9conn.odin describes
// the transport, and is the client).
package p9ring

import "base:intrinsics"
import vx "abi:vx"
import "vx:drbg"
import "vx:memory"
import "vx:ndb"
import "vx:p9"
import "vx:ring"
import "vx:rt"
//
// The server waits on one port for everything: READABLE on the listen
// channel; for each connection, its doorbell (COUNTER_GE) and its client
// going away (PEER_CLOSED); and whatever the file server binds there itself,
// such as a driver's Irq, with keys from KEY_USER up, which go to its event
// hook.
//
// A request the file server cannot do yet (p9.serve's .Defer) is held, and
// served again after every event, after every tick, and when the file server
// says something it did may let it go on (`again`): a request on another
// connection, say, that queued what the held one waits for. A connection
// holds up to rt.DEPTH of them (upstream's M6 step 6d4a) and goes on taking
// new requests meanwhile, so replies go out in any order, as 9P allows. Two
// rules keep that safe:
//   - a request on a fid that an earlier held request is on waits behind it,
//     so writes to a pipe, say, stay in their order;
//   - Tflush of a held request drops it, unanswered, before Rflush goes out
//     (9P's rule: the flushed request's reply comes first, or never).
// A held request's bytes stay in the client's arena until it is answered,
// and are copied out again each time it is served.
//
// Threads (upstream's M6 step 6d5a), as 9front's lib9p has them (srv.c's
// srvrelease and srvacquire): requests are served one at a time, under the
// server's lock, by whichever of its threads holds it, so a file server
// that never asks for more is served as by one thread. One whose operation
// is to wait (a device's I/O) lets the lock go with release, and takes it
// back with acquire, its own state its own to keep safe meanwhile; another
// thread goes on serving, a parked one or a new one, up to max_threads. A
// request being served so stays among the held ones, busy: the fid rule
// holds for it, a Tflush of it waits for its reply, a Tversion for every
// busy one, and a connection that goes is closed once its last busy request
// is answered.
//
// All the connections share one table of open files and locks (p9.Shared),
// for the posix extension; its tokens come from the spawn message's
// entropy= record, and without one Tshare is refused.

MAX_CONNS :: 16 // a server's connections, unless it gives more of its own
MAX_CONNS_LIMIT :: 256 // what a port key's slot can name

KEY_USER :: u64(1) << 62 // and up: the file server's own bindings

// The port keys below KEY_USER. A connection's keys carry its slot and the
// slot's generation, so a packet from a binding on a connection that has
// gone is never taken for one about its slot's next connection. The listen
// channel's key is all zeroes.
@(private="file")
Key_Kind :: enum u32 {
	Listen,
	Conn_Bell,
	Conn_Closed,
	Stop, // serve is ending: a thread asleep on the port wakes to see it
}

@(private="file")
Port_Key :: bit_field u64 {
	slot: u32      | 8,
	gen:  u32      | 32,
	kind: Key_Kind | 22,
	user: u8       | 2, // set from KEY_USER up
}
#assert(size_of(Port_Key) == 8)

@(private="file")
conn_key :: proc "contextless" (kind: Key_Kind, slot: int, gen: u32) -> u64 {
	return transmute(u64)Port_Key{slot = u32(slot), gen = gen, kind = kind}
}

// --- The server's arena, allotted in order ---
//
// Regions are taken in order, each contiguous (one that would run past the
// end starts again at 0, the rest of the end going with it), and given back
// in any order; the space comes free as the oldest regions are given back.
// Positions count bytes for ever; a position's offset is it modulo the size.

@(private="file")
REGIONS :: 2 * rt.DEPTH

@(private="file")
Arena :: struct {
	size:         u64,
	head, tail:   u64, // [head, tail): taken
	first, count: int,
	regions:      [REGIONS]struct {
		end:  u64,
		done: bool,
	},
}

// A region of length bytes: its index for arena_free, and its offset; not
// ok if there is no room now (or no region left).
@(private="file")
arena_alloc :: proc "contextless" (a: ^Arena, length: u64) -> (index: int, off: u64, ok: bool) {
	if length == 0 || length > a.size || a.count == REGIONS {
		return 0, 0, false
	}
	pos := a.tail
	off = pos % a.size
	if off + length > a.size { // to the start, the end's rest with it
		pos += a.size - off
		off = 0
	}
	if pos + length - a.head > a.size {
		return 0, 0, false
	}
	index = (a.first + a.count) % REGIONS
	a.count += 1
	a.regions[index] = {
		end = pos + length,
	}
	a.tail = pos + length
	return index, off, true
}

// Gives region i back.
@(private="file")
arena_free :: proc "contextless" (a: ^Arena, i: int) {
	a.regions[i].done = true
	for a.count != 0 && a.regions[a.first].done {
		a.head = a.regions[a.first].end
		a.first = (a.first + 1) % REGIONS
		a.count -= 1
	}
}

// A request held for later, or being served (busy): its submission (its
// bytes stay in the client's arena), the VMO it came with, and what the
// rules above look at.
@(private="file")
Held :: struct {
	e:      vx.Sqe,
	handle: vx.Handle, // dref's VMO, the server's until it is answered
	id:     u32, // the connection's count of requests: which one, however the others move
	tag:    u16,
	oldtag: u16, // a Tflush's
	type:   p9.Type,
	busy:   bool, // a thread is serving it
	fid:    p9.Fid, // NOFID: the message has none
}

Server_Conn :: struct {
	used, armed: bool,
	closing:     bool, // its client has gone: closed once nothing is busy
	gen:         u32,
	slot:        int,
	owner:       ^Server,
	held:        [dynamic; rt.DEPTH]Held, // oldest first
	busy:        int, // of them
	next_id:     u32,
	ring:        ring.Ring,
	out:         Arena, // the server's arena: the replies' bytes
	released:    u32, // completions whose bytes have been given back
	end:         vx.Handle,
	srv:         p9.Server,
}

MAX_THREADS :: 16

Server :: struct {
	fs:            p9.Fs,
	supported:     p9.Extensions, // 9Px extensions
	name:          string, // for messages
	listen:        vx.Handle,
	port:          vx.Handle, // the file server may bind its own sources here, keyed from KEY_USER
	listen_armed:  bool,
	ctx:           rawptr,
	event:         proc "contextless" (ctx: rawptr, pk: ^vx.Packet), // a packet keyed from KEY_USER up
	// Optional: does what is due by now, and says when to be called again
	// (vx.INFINITE: never), as a protocol's retransmission timers need.
	tick:          proc "contextless" (ctx: rawptr) -> vx.Instant,
	// Optional: a message on the listen channel that is not CONNECT, with
	// the one handle it may carry (HANDLE_NONE if none), which becomes the
	// hook's. procfs takes registrations this way (vx:process).
	listen_msg:    proc "contextless" (ctx: rawptr, msg: []u8, handle: vx.Handle),
	// Set by the file server when what it just did may let a held request go
	// on: the held requests are served again before the server sleeps.
	again:         bool,
	// Optional, in place of fs: each request as it came, on connection
	// `conn` (its slot), for a server that forwards requests rather than
	// serving them (the relay, upstream's M6 step 6d4d2b). It answers as
	// p9.serve does: the reply's length in resp, or .Defer to be asked
	// again; the rules above hold as for fs, Tflush's too. `closed` is told
	// when a connection has gone, its held requests dropped unanswered.
	raw:           proc "contextless" (ctx: rawptr, conn: int, req: []u8, resp: []u8) -> (reply_len: int, res: p9.Serve_Result),
	closed:        proc "contextless" (ctx: rawptr, conn: int),
	// Whether to go on serving the connections it has once the listen
	// channel's peer has gone: serve then returns when the last one goes.
	// Without it, it returns at once.
	linger:        bool,
	// The threads that may serve it, at most (upstream's M6 step 6d5a): 0
	// or 1, the one that calls serve; more, made as release needs them, and
	// kept. At most MAX_THREADS.
	max_threads:   int,
	// Its connections: default_conns, unless the file server gives more of
	// its own (procfs, which holds one per process) before serving. At most
	// MAX_CONNS_LIMIT. serve points it at default_conns otherwise, so a Server
	// must not move once it serves.
	conns:         []Server_Conn,
	default_conns: [MAX_CONNS]Server_Conn,
	shared:        p9.Shared, // the open files, locks and watches all its connections share (posix, notify)
	// The threads (the server's lock held for these): serving, or waiting
	// for work, rather than let go or parked.
	lock:          rt.Mutex,
	running:       int,
	threads:       int,
	parked:        int,
	tickets:       int,
	unpark:        u32, // atomic, a parked thread's futex: a ticket is there to take
	stopping:      bool,
	deaf:          bool, // the listen channel's peer has gone, and it lingers
	stopped:       vx.Status, // what serve returns
	pool:          [MAX_THREADS]rt.Thread,
}

// Each serving thread's own: the request and reply it is serving, and
// whether it let the server go meanwhile (what it was looking at may have
// moved: the connection's held requests, the connections).
@(private="file")
Worker :: struct {
	released: bool,
	req:      [rt.MSIZE]u8,
	resp:     [rt.MSIZE]u8,
}

@(private="file", thread_local)
current: ^Server
@(private="file", thread_local)
self: ^Worker

// A thread release made: it runs the loop, counted among the running by
// release, which made it. The one procedure here with a context, as
// rt.Thread_Proc has one; what it calls is contextless.
@(private="file")
worker_main :: proc(arg: rawptr) {
	s := (^Server)(arg)
	rt.mutex_lock(&s.lock)
	loop(s)
	rt.mutex_unlock(&s.lock)
}

// Lets the server go, for an operation of the file server's that is to
// wait (upstream's M6 step 6d5a, 9front lib9p's srvrelease): another thread
// serves meanwhile, a parked one or a new one if none other is running.
// Nothing of the file server's own is kept safe by the server's lock until
// acquire takes it back. False, and nothing done, outside a ring server's
// call, or while the call must keep the lock (vx:p9's keep_lock, upstream's
// M6 step 6d5b): then acquire is not to be called.
release :: proc "contextless" () -> bool {
	s := current
	if s == nil || self == nil || p9.keep_lock != 0 {
		return false
	}
	self.released = true
	s.running -= 1
	if s.running == 0 && !s.stopping {
		if s.parked > 0 {
			s.parked -= 1
			s.tickets += 1
			s.running += 1
			intrinsics.atomic_add(&s.unpark, 1)
			_, _ = rt.futex_wake(&s.unpark, 1)
		} else if s.threads < s.max_threads && s.threads < MAX_THREADS {
			if t, st := rt.thread_spawn(worker_main, s); st == .Ok {
				s.pool[s.threads] = t
				s.threads += 1
				s.running += 1
			}
		}
	}
	rt.mutex_unlock(&s.lock)
	return true
}

// Takes the server back after a release that let it go (lib9p's srvacquire).
acquire :: proc "contextless" () {
	s := current
	if s == nil || self == nil {
		return
	}
	rt.mutex_lock(&s.lock)
	s.running += 1
}

// Waits, parked, until release needs this thread, or the server stops.
@(private="file")
park :: proc "contextless" (s: ^Server) {
	s.running -= 1
	s.parked += 1
	for s.tickets == 0 && !s.stopping {
		seen := intrinsics.atomic_load(&s.unpark)
		rt.mutex_unlock(&s.lock)
		_ = rt.futex_wait(&s.unpark, seen, vx.INFINITE)
		rt.mutex_lock(&s.lock)
	}
	if s.tickets > 0 {
		s.tickets -= 1 // release counted it running again
	} else {
		s.parked -= 1
		s.running += 1
	}
}

// Ends the server: every thread goes, and serve returns st.
@(private="file")
stop :: proc "contextless" (s: ^Server, st: vx.Status) {
	if s.stopping {
		return
	}
	s.stopping, s.stopped = true, st
	intrinsics.atomic_add(&s.unpark, 1)
	_, _ = rt.futex_wake(&s.unpark, max(u32))
	for _ in 0 ..< s.threads {
		pk := vx.Packet {
			key = conn_key(.Stop, 0, 0),
		}
		_ = rt.port_post(s.port, &pk)
	}
}

// The handle a request came with, if any: the server's while it serves it.
@(private="file")
drop_request_handle :: proc "contextless" () {
	rt.close_all(p9.request_handle)
	p9.request_handle = vx.HANDLE_NONE
}

// A connection goes: every fid is clunked, and its ring leaves the address
// space, so a long-lived server does not run out of mappings. One with a
// request being served goes once that is done.
@(private="file")
close_conn :: proc "contextless" (c: ^Server_Conn) {
	if c.busy > 0 {
		c.closing = true
		return
	}
	if c.owner != nil && c.owner.closed != nil {
		c.owner.closed(c.owner.ctx, c.slot)
	}
	for h in c.held {
		rt.close_all(h.handle)
	}
	clear(&c.held)
	p9.hang_up(&c.srv)
	_ = rt.handle_close(c.end)
	rt.session_unmap(&c.ring)
	c.used, c.closing = false, false
}

// Answers one CONNECT: a new ring, its client end and memory in the reply;
// or, if that cannot be done, a refusal.
@(private="file")
accept :: proc "contextless" (s: ^Server, req: ^vx.Msg_Header) {
	rep := vx.Msg_Header{txid = req.txid, ordinal = rt.CONNECT}
	if connect(s, &rep) != .Ok {
		rep.flags = rt.CONNECT_REFUSED
		_ = rt.channel_write(s.listen, memory.ptr_to_bytes(&rep))
	}
}

// Makes a connection in a free slot and sends rep with its handles.
@(private="file", require_results)
connect :: proc "contextless" (s: ^Server, rep: ^vx.Msg_Header) -> (st: vx.Status) {
	h: vx.Ring_Handles
	defer if st != .Ok {
		rt.close_all(h.client, h.server, h.memory)
	}
	i := 0
	for i < len(s.conns) && s.conns[i].used {
		i += 1
	}
	if i == len(s.conns) {
		return .Err_No_Memory
	}
	c := &s.conns[i]
	params := rt.PARAMS
	h = rt.ring_create(&params) or_return
	rt.map_ring(h.memory, .Server, &c.ring) or_return
	c.gen += 1
	rt.port_bind(s.port, h.server, .Peer_Closed, conn_key(.Conn_Closed, i, c.gen)) or_return
	give := [2]vx.Handle{h.client, h.memory}
	h.client, h.memory = vx.HANDLE_NONE, vx.HANDLE_NONE // moved, whatever happens
	rt.channel_write(s.listen, memory.ptr_to_bytes(rep), give[:]) or_return
	c.used = true
	c.armed, c.closing = false, false
	clear(&c.held)
	c.released, c.busy = 0, 0
	c.out = {
		size = u64(len(ring.arena(&c.ring))),
	}
	c.end = h.server
	c.slot, c.owner = i, s
	c.srv = {fs = s.fs, max_msize = rt.MSIZE, supported = s.supported, shared = &s.shared}
	return .Ok
}

// Requests served on one connection before the server turns to the others: a
// client that keeps its queue full gets its share, not the whole server.
@(private="file")
BUDGET :: 8

@(private="file")
Drained :: enum u8 {
	Drained, // nothing is left to serve now
	More, // the budget ran out with requests left, or the server was let go during one: look again
	Broken, // the client broke the protocol, or sent something too broken to answer: drop it
}

// Gives back the arena of every completion the client has consumed.
@(private="file")
give_back :: proc "contextless" (c: ^Server_Conn) {
	consumed := ring.peer_consumed(&c.ring)
	for c.released != consumed && c.out.count != 0 {
		arena_free(&c.out, c.out.first)
		c.released += 1
	}
}

// Sends a reply, resp, for the submission e (none: the request was too
// broken to answer), with the reply's handle if the request made one. False
// if the client has broken the protocol: no room in the completion queue or
// the arena, which a client that keeps to the depth always leaves.
@(private="file")
reply :: proc "contextless" (c: ^Server_Conn, e: ^vx.Sqe, resp: []u8) -> bool {
	give_back(c)
	entry: []u8
	off: u64
	ok := false
	if len(resp) > 0 {
		entry, ok = ring.produce_slot(&c.ring)
	}
	if ok {
		_, off, ok = arena_alloc(&c.out, u64(len(resp)))
	}
	if !ok {
		rt.close_all(p9.reply_handle) // no reply to carry it
		p9.reply_handle = vx.HANDLE_NONE
		return false
	}
	copy(ring.arena(&c.ring)[off:], resp)
	out := vx.Cqe{user_data = e.user_data, result = i64(len(resp)), aux2 = off}
	if p9.reply_handle != vx.HANDLE_NONE { // Rmap's VMO, in a slot the completion names
		h := [1]vx.Handle{p9.reply_handle}
		p9.reply_handle = vx.HANDLE_NONE
		if hslot, hst := rt.ring_put_handles(c.end, h[:]); hst == .Ok {
			out.flags, out.aux = rt.CQE_HANDLE, hslot
		} else {
			rt.close_all(h[0]) // the client finds none, and its call fails
		}
	}
	copy(entry, memory.ptr_to_bytes(&out))
	if ring.produce(&c.ring) {
		_ = rt.ring_notify(c.end)
	}
	return true
}

@(private="file")
unhold :: proc "contextless" (c: ^Server_Conn, i: int) {
	copy(c.held[i:], c.held[i + 1:])
	resize(&c.held, len(c.held) - 1)
}

// Where the held request with this id is now; len(held) if it has gone.
@(private="file")
find :: proc "contextless" (c: ^Server_Conn, id: u32) -> int {
	for &h, i in c.held {
		if h.id == id {
			return i
		}
	}
	return len(c.held)
}

@(private="file")
Tried :: enum u8 {
	Answered,
	Held,
	Broken,
}

// Serves held[i] once, busy meanwhile: its bytes copied out of the client's
// arena again into this thread's buffer, its VMO lent to the file server
// for the call. Answered, it is no longer held.
@(private="file")
try :: proc "contextless" (c: ^Server_Conn, i: int) -> Tried {
	w := self
	h := c.held[i]
	p, ok := ring.peer_bytes(&c.ring, u64(h.e.arena_off), u64(h.e.len))
	if !ok || h.e.len > len(w.req) {
		return .Broken
	}
	copy(w.req[:], p)
	c.held[i].busy, c.held[i].handle = true, vx.HANDLE_NONE
	c.busy += 1
	p9.request_handle = h.handle
	n: int
	res: p9.Serve_Result
	if s := c.owner; s != nil && s.raw != nil {
		n, res = s.raw(s.ctx, c.slot, w.req[:h.e.len], w.resp[:])
	} else {
		n, res = p9.serve(&c.srv, w.req[:h.e.len], w.resp[:])
	}
	c.busy -= 1
	at := find(c, h.id) // others may have moved it, while the server was let go
	c.held[at].busy = false
	if res == .Defer && !c.closing {
		c.held[at].handle = p9.request_handle // kept until it is served
		p9.request_handle = vx.HANDLE_NONE
		return .Held
	}
	drop_request_handle()
	unhold(c, at)
	if c.closing { // its client went meanwhile: no one to answer
		rt.close_all(p9.reply_handle)
		p9.reply_handle = vx.HANDLE_NONE
		return .Broken
	}
	return reply(c, &h.e, w.resp[:res == .Reply ? n : 0]) ? .Answered : .Broken
}

// Whether an older held request than held[i] is on fid: if so, it waits
// behind that one.
@(private="file")
behind :: proc "contextless" (c: ^Server_Conn, i: int, fid: p9.Fid) -> bool {
	if fid == p9.NOFID {
		return false
	}
	for &h in c.held[:i] {
		if h.fid == fid {
			return true
		}
	}
	return false
}

// Whether held[i] waits for others first: anything behind the fid rule; a
// Tflush whose request is busy (its reply comes first); a Tversion while
// any is. A Tflush that may go drops the held request it names first.
@(private="file")
waits :: proc "contextless" (c: ^Server_Conn, i: int) -> bool {
	h := &c.held[i]
	if h.busy || behind(c, i, h.fid) {
		return true
	}
	if h.type == .Tversion {
		return c.busy > 0
	}
	if h.type != .Tflush {
		return false
	}
	oldtag := h.oldtag
	for &x, j in c.held {
		if j == i || x.tag != oldtag {
			continue
		}
		if x.busy {
			return true
		}
		rt.close_all(x.handle)
		unhold(c, j) // unanswered; then Rflush
		break
	}
	return false
}

// The fid a request is on, for the ordering rule; NOFID if none.
@(private="file")
request_fid :: proc "contextless" (t: ^p9.Msg) -> p9.Fid {
	#partial switch t.type {
	case .Tversion, .Tauth, .Tflush:
		return p9.NOFID
	}
	return t.fid
}

// Serves the requests waiting on one connection, up to its budget: the held
// ones first, oldest first, then new ones. .More if requests are left, or
// if the server was let go during one (what was being looked at may have
// moved: look again).
@(private="file")
drain :: proc "contextless" (c: ^Server_Conn) -> Drained {
	w := self
	if c.closing {
		return .Drained
	}
	for i := 0; i < len(c.held); {
		before := len(c.held)
		wait := waits(c, i)
		if len(c.held) != before { // a Tflush dropped one: start again
			i = 0
			continue
		}
		if wait {
			i += 1
			continue
		}
		w.released = false
		r := try(c, i)
		if r == .Broken {
			return .Broken
		}
		if w.released {
			return .More
		}
		if r == .Held {
			i += 1 // answered: no longer at i
		}
	}
	for _ in 0 ..< BUDGET {
		if len(c.held) == rt.DEPTH {
			return .Drained // a client past the depth waits for its answers
		}
		h := Held {
			fid = p9.NOFID,
		}
		st := ring.consume(&c.ring, memory.ptr_to_bytes(&h.e))
		if st == .Err_Should_Wait {
			return .Drained
		}
		if st != .Ok || h.e.opcode != rt.RING_MSG || h.e.len > len(w.req) {
			return .Broken
		}
		p, ok := ring.peer_bytes(&c.ring, u64(h.e.arena_off), u64(h.e.len))
		if !ok {
			return .Broken
		}
		if .Handles in h.e.flags { // dref's VMO, for Treadref and Twriteref; a post's connector
			got: [1]vx.Handle
			if n, _ := rt.ring_take_handles(c.end, h.e.handle_slot, got[:]); n == 1 {
				h.handle = got[0]
			}
		}
		copy(w.req[:], p)
		t: p9.Msg
		if p9.decode(w.req[:h.e.len], &t) != .Ok {
			rt.close_all(h.handle)
			return .Broken
		}
		h.tag, h.type, h.oldtag = t.tag, t.type, t.oldtag
		h.fid = request_fid(&t)
		h.id = c.next_id
		c.next_id += 1
		_ = append(&c.held, h) // room: checked above
		if waits(c, len(c.held) - 1) {
			continue
		}
		w.released = false
		r := try(c, find(c, h.id)) // a Tflush may have dropped one before it
		if r == .Broken {
			return .Broken
		}
		if w.released {
			return .More
		}
	}
	return .More
}

@(private="file")
junk: [vx.CHANNEL_MAX_BYTES]u8
@(private="file")
junk_handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle

@(private="file")
now :: proc "contextless" () -> i64 {
	return i64(rt.clock_read())
}

// A message on the listen channel: CONNECT, or another the file server
// takes, or nothing anyone wants.
@(private="file")
Listen_Msg :: struct #raw_union {
	header: vx.Msg_Header,
	bytes:  [64]u8,
}

// The loop each of the server's threads runs, the server's lock held but
// while it sleeps or is parked, until the server stops.
@(private="file")
loop :: proc "contextless" (s: ^Server) {
	w: Worker
	current, self = s, &w
	defer current, self = nil, nil
	for !s.stopping {
		more := false // a connection still has requests: no sleeping this time round
		for &c in s.conns {
			if s.stopping {
				break
			}
			if !c.used {
				continue
			}
			switch drain(&c) {
			case .Broken:
				close_conn(&c)
			case .More:
				more = true
			case .Drained:
			}
		}
		for !s.deaf && !s.stopping {
			msg: Listen_Msg
			handle := [1]vx.Handle{vx.HANDLE_NONE}
			size, st := rt.channel_read(s.listen, msg.bytes[:], handle[:])
			if st == .Err_Should_Wait {
				break
			}
			if st == .Err_Peer_Closed && !s.linger {
				stop(s, st)
				break
			}
			if st == .Err_Peer_Closed {
				s.deaf = true
				break
			}
			req := &msg.header
			if st == .Ok && size.bytes == size_of(req^) && req.ordinal == rt.CONNECT && size.handles == 0 {
				accept(s, req)
			} else if st == .Ok && size.bytes >= size_of(req^) && req.ordinal != rt.CONNECT && s.listen_msg != nil {
				s.listen_msg(s.ctx, msg.bytes[:size.bytes], size.handles > 0 ? handle[0] : vx.HANDLE_NONE)
			} else if st == .Ok && size.handles > 0 {
				_ = rt.handle_close(handle[0])
			}
			// Anything else, including a message too big for us (TOO_SMALL), is dropped.
			if st == .Err_Too_Small {
				if jsize, jst := rt.channel_read(s.listen, junk[:], junk_handles[:]); jst == .Ok {
					rt.close_all(..junk_handles[:jsize.handles])
				}
			}
		}

		if s.deaf && !s.stopping { // lingering: until the last connection goes
			any := false
			for &c in s.conns {
				any = any || c.used
			}
			if !any {
				stop(s, .Err_Peer_Closed)
			}
		}
		if s.stopping {
			break
		}

		// Arm what is idle, then sleep unless something arrived meanwhile. A
		// connection holding requests waits for an event or its doorbell: a
		// new request, or a Tflush of a held one. A thread with another
		// running parks instead: one sleeping on the port is enough.
		if s.again || s.shared.again { // a held request may go on now (an event, for a Tnotify): once more round
			more = true
			s.again, s.shared.again = false, false
		}
		if !more && s.running > 1 {
			park(s)
			continue
		}
		// Only the thread that sleeps marks the rings and unmarks them after:
		// another's unmarking would leave the sleeper's doorbells silent.
		idle := !more
		for &c, i in s.conns {
			if !idle {
				break
			}
			if !c.used || c.closing {
				continue
			}
			seen, _ := rt.counter_read(c.end)
			if !ring.prepare_sleep(&c.ring) {
				idle = false
			} else if !c.armed {
				c.armed = rt.port_bind(s.port, c.end, .Counter_Ge, conn_key(.Conn_Bell, i, c.gen), seen + 1) == .Ok
			}
		}
		if idle && !s.deaf && !s.listen_armed {
			s.listen_armed = rt.port_bind(s.port, s.listen, .Readable, conn_key(.Listen, 0, 0)) == .Ok
		}
		deadline := s.tick(s.ctx) if s.tick != nil else vx.INFINITE
		if idle {
			pk: [16]vx.Packet
			rt.mutex_unlock(&s.lock) // while it sleeps, a thread let go may take the server back
			n, _ := rt.port_wait(s.port, deadline, 0, pk[:]) // Err_Timed_Out: the tick is due
			rt.mutex_lock(&s.lock)
			for &p in pk[:n] {
				if p.key >= KEY_USER {
					if s.event != nil {
						s.event(s.ctx, &p)
					}
					continue
				}
				key := transmute(Port_Key)p.key
				if key.kind == .Listen {
					s.listen_armed = false
					continue
				}
				if key.kind == .Stop || int(key.slot) >= len(s.conns) {
					continue
				}
				c := &s.conns[key.slot]
				if !c.used || c.gen != key.gen {
					continue // about a connection that has gone
				}
				#partial switch key.kind {
				case .Conn_Closed:
					close_conn(c)
				case .Conn_Bell:
					c.armed = false
				}
			}
		}
		if !more { // marked for a sleep, slept or not
			for &c in s.conns {
				if c.used {
					ring.end_sleep(&c.ring)
				}
			}
		}
	}
}

// Serves the file system on the listen channel until the channel goes away
// (or, lingering, its last connection too). The port is made here unless
// the file server made it already, to bind its own sources first.
@(require_results)
serve :: proc "contextless" (s: ^Server) -> vx.Status {
	if s.port == 0 {
		s.port = rt.port_create() or_return
	}
	if s.conns == nil || len(s.conns) > MAX_CONNS_LIMIT {
		s.conns = s.default_conns[:]
	}
	// Tokens for shared open files come from the entropy the spawn message
	// gives (a manifest's `entropy`); without it, Tshare is refused.
	s.shared.now = now
	rec: ndb.Record
	if rt.spawn_record("entropy", &rec) {
		if seed, ok := ndb.get(&rec, "entropy"); ok && len(seed) >= 16 && !s.shared.random.seeded {
			drbg.mix(&s.shared.random, transmute([]u8)seed, true)
		}
	}
	s.max_threads = max(s.max_threads, 1)
	rt.mutex_lock(&s.lock)
	s.threads, s.running = 1, 1
	loop(s)
	st := s.stopped
	rt.mutex_unlock(&s.lock)
	return st
}
