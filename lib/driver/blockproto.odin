package driver

import vx "abi:vx"

// The block class protocol (upstream docs/proto/block.md): a session per
// client on a block driver's post (/srv/disk0, ...) or on a partition's
// (partd), a ring (rt's session.odin) that reaches one window of the disk.
//
// A client connects with Block_Connect (the window, in the connector's
// sectors, and its flags) and then submits Block_Ops: INFO first, whose
// completion says the sector size (aux), the window's sectors (aux2), the
// most one request may move (result) and Block_Info_Flags (flags); READ and
// WRITE of len bytes at sector target, through the client's arena (.Dref).

BLOCK_CONNECT :: u32(0x6b6c_6263) // "cblk": the connector's one request

// CONNECT's flags. On the wire, bit i is the member of value i.
Block_Connect_Flag :: enum u32 {
	Readonly,
}
Block_Connect_Flags :: bit_set[Block_Connect_Flag;u32]

// CONNECT: a header, then the window, in the connector's sectors.
Block_Connect :: struct {
	header:   vx.Msg_Header,
	first:    u64,
	count:    u64, // 0: from first to the connector's end
	flags:    Block_Connect_Flags,
	reserved: u32,
}
#assert(size_of(Block_Connect) == 40)
#assert(offset_of(Block_Connect, first) == 16)
#assert(offset_of(Block_Connect, count) == 24)
#assert(offset_of(Block_Connect, flags) == 32)

Block_Op :: enum u16 {
	Info      = 1,
	Read      = 2,
	Write     = 3,
	Write_Fua = 4,
	Flush     = 5,
	Discard   = 6,
}

// INFO's completion flags.
Block_Info_Flag :: enum u32 {
	Readonly,
	Cache,
	Discard,
}
Block_Info_Flags :: bit_set[Block_Info_Flag;u32]

BLOCK_ENTRIES :: 128
BLOCK_ARENA :: 1 << 20 // the client's buffers

BLOCK_PARAMS :: vx.Ring_Params {
	sq_entries   = BLOCK_ENTRIES,
	cq_entries   = BLOCK_ENTRIES,
	sqe_size     = size_of(vx.Sqe),
	cqe_size     = size_of(vx.Cqe),
	client_arena = BLOCK_ARENA,
	server_arena = 0,
}
