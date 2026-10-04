package driver

import vx "abi:vx"

// The net class protocol: frames between a network driver and its one
// client, netd, over a ring session (rt's session.odin) on the driver's post
// (/srv/ether0).
//
//   Info   the completion says the MAC address (aux2, its six bytes from the
//          lowest) and the MTU (aux)
//   Tx     sends the frame at [arena_off, arena_off + len) of the client's
//          arena (with .Dref); completes with its length, or a negative
//          status. The driver has copied the frame by then.
//   Rx     offers slot `target` of the driver's arena (NET_SLOTS of NET_SLOT
//          bytes) for a frame; completes when one arrives, with its length,
//          and aux2 its offset in the driver's arena. The driver writes
//          nothing there again until the client offers that slot again, so
//          the client copies the frame out first.
//
// Frames are whole Ethernet frames, without the FCS. A frame that arrives
// while no slot is offered is dropped, as a full NIC would drop it.
//
// Every request is completed exactly once, so a client keeps no more of them
// outstanding (submitted, not yet completed, Rx offers included) than the
// completion queue holds: a driver whose completion queue is full drops the
// client.

NET_CONNECT :: u32(0x7465_6e63) // "cnet": the listen channel's one ordinal

Net_Op :: enum u16 {
	Info = 1,
	Tx   = 2,
	Rx   = 3,
}

NET_SLOTS :: 64 // frames each side's arena holds
NET_SLOT :: 2048 // bytes a slot holds: an MTU of 1500 and room to spare
NET_MAX_FRAME :: 1514 // 14 bytes of header, 1500 of payload

NET_PARAMS :: vx.Ring_Params {
	sq_entries   = NET_SLOTS * 2, // offers and sends together
	cq_entries   = NET_SLOTS * 2,
	sqe_size     = size_of(vx.Sqe),
	cqe_size     = size_of(vx.Cqe),
	client_arena = NET_SLOTS * NET_SLOT,
	server_arena = NET_SLOTS * NET_SLOT,
}
