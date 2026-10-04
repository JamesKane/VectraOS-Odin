package rt

import vx "abi:vx"
import "vx:memory"
import "vx:ring"

// Ring sessions: opening a ring to a server through its listen channel. A
// server reads requests on a listen channel (a post, /srv/NAME); a client
// sends one with channel_call; the server creates a ring with its protocol's
// parameters, keeps the server end, and answers with the client end and the
// ring's memory. Each session is its own ring, so each queue has one producer.
//
// The ring is attached only if its header is exactly what the protocol's
// parameters make (ring.attach): a server cannot hand a client a ring with
// bigger entries than the client's buffers.

// The reply flag that says a session was refused.
SESSION_REFUSED :: u32(1)

// Maps a ring's memory into this task and attaches to it as one side. A ring
// it will not attach to is unmapped again.
@(require_results)
session_map :: proc "contextless" (mem: vx.Handle, side: ring.Side, params: vx.Ring_Params, r: ^ring.Ring) -> (st: vx.Status) {
	layout := ring.layout(params) or_return
	base := as_map(self, mem, 0, layout.size, {.Write}) or_return
	defer if st != .Ok {
		unmap_memory(base, layout.size)
	}
	return ring.attach(r, (cast([^]u8)uintptr(base))[:layout.size], side, params)
}

// A session is over: its ring's memory leaves this task's address space, and
// the ring is left detached, so every operation on it fails.
session_unmap :: proc "contextless" (r: ^ring.Ring) {
	if r.memory != nil {
		unmap_memory(u64(uintptr(raw_data(r.memory))), u64(len(r.memory)))
	}
	r^ = {}
}

// vx:rt's as_unmap wrapper comes with the kernel's M4 port; until then, the
// call itself, as lib/procns makes it. What the kernel says is ignored: there
// is nothing a caller letting memory go could do about a failure.
@(private)
unmap_memory :: proc "contextless" (base, size: u64) {
	_ = vx_syscall(.As_Unmap, u64(self), base, size)
}

// Opens a session through `connector` (a post's client end, which stays the
// caller's), asking with `ordinal`. Returns this side's ring end.
@(require_results)
session_dial :: proc "contextless" (connector: vx.Handle, ordinal: u32, params: vx.Ring_Params, r: ^ring.Ring) -> (end: vx.Handle, st: vx.Status) {
	req := vx.Msg_Header{ordinal = ordinal}
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
	st = channel_call(connector, &call, clock_read() + 5_000_000_000)
	if st == .Ok && call.actual.handles != 2 {
		st = .Err_Access // refused
	}
	if st == .Ok {
		st = session_map(got[1], .Client, params, r)
	}
	close_all(got[1]) // the mapping keeps the memory
	if st != .Ok {
		close_all(got[0])
		return vx.HANDLE_NONE, st
	}
	return got[0], .Ok
}

// Answers one request read from `listen` (req is its header): a new ring
// with these parameters, mapped and attached as the server, whose server end
// it returns. On failure the request is refused, with a reply without handles.
@(require_results)
session_accept :: proc "contextless" (listen: vx.Handle, req: vx.Msg_Header, params: vx.Ring_Params, r: ^ring.Ring) -> (end: vx.Handle, st: vx.Status) {
	rep := vx.Msg_Header{txid = req.txid, ordinal = req.ordinal}
	p := params
	h: vx.Ring_Handles
	h, st = ring_create(&p)
	if st == .Ok {
		st = session_map(h.memory, .Server, params, r)
	}
	if st == .Ok {
		give := [2]vx.Handle{h.client, h.memory}
		st = channel_write(listen, memory.ptr_to_bytes(&rep), give[:])
		h.client, h.memory = vx.HANDLE_NONE, vx.HANDLE_NONE // moved, whatever happened
	}
	if st == .Ok {
		return h.server, .Ok
	}
	close_all(h.client, h.server, h.memory)
	rep.flags = SESSION_REFUSED
	_ = channel_write(listen, memory.ptr_to_bytes(&rep))
	return vx.HANDLE_NONE, st
}

// Dialling without waiting, for a client that cannot stall on a server that
// may not be there (netd, before its driver starts). session_ask writes the
// request on the connector; when the connector is readable, session_answer
// reads the reply. Only one ask is outstanding per connector, so nothing
// else may read it meanwhile.
@(require_results)
session_ask :: proc "contextless" (connector: vx.Handle, ordinal: u32) -> vx.Status {
	req := vx.Msg_Header{txid = 1, ordinal = ordinal}
	return channel_write(connector, memory.ptr_to_bytes(&req))
}

// The reply to session_ask: .Err_Should_Wait if it has not come; .Err_Access
// if the server refused (it has a client already); otherwise the session,
// attached.
@(require_results)
session_answer :: proc "contextless" (connector: vx.Handle, params: vx.Ring_Params, r: ^ring.Ring) -> (end: vx.Handle, st: vx.Status) {
	rep: vx.Msg_Header
	got: [2]vx.Handle
	size: vx.Msg_Size
	size, st = channel_read(connector, memory.ptr_to_bytes(&rep), got[:])
	if st == .Err_Too_Small { // not a reply this protocol makes: read it, to be rid of it
		@(static) junk: [vx.CHANNEL_MAX_BYTES]u8
		@(static) junk_handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle
		if jsize, jst := channel_read(connector, junk[:], junk_handles[:]); jst == .Ok {
			close_all(..junk_handles[:jsize.handles])
		}
		return vx.HANDLE_NONE, .Err_Access
	}
	if st != .Ok {
		return vx.HANDLE_NONE, st
	}
	if size.bytes != size_of(rep) || size.handles != 2 {
		close_all(..got[:size.handles])
		return vx.HANDLE_NONE, .Err_Access
	}
	st = session_map(got[1], .Client, params, r)
	close_all(got[1]) // the mapping keeps the memory
	if st != .Ok {
		close_all(got[0])
		return vx.HANDLE_NONE, st
	}
	return got[0], .Ok
}
