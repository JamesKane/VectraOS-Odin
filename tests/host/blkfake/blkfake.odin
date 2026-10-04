// A fake kernel with a block device under it, for the host tests of the
// servers that read disks through vx:driver's block client (dosfs, isofs):
// the program itself, linked against lib/rt, runs on it as tests/host/bootfs
// runs bootfs. This package defines vx_syscall, so the runtime's syscalls
// land here:
//
//  - the disk's connector answers a session request (channel_call) with a
//    ring end and the ring's memory, laid out as the kernel lays it out,
//    which as_map hands back;
//  - the block driver is here: whenever the client could be waiting
//    (ring_notify, counter_read, port_wait), it serves what the ring's
//    submission queue holds from the image in `disk` (INFO, READ, WRITE,
//    FLUSH), and port_wait then reports the completion's doorbell;
//  - the first port_create succeeds (the block client's), the next fails,
//    so the program's start mounts the disk, says what it serves and
//    returns "cannot serve" instead of serving rings;
//  - debug_write is kept (log), the clock is fixed (NOW, and UTC_OFFSET).
//
// Imported relatively. It has no tests of its own, so ./build check does
// not run it on its own (it could not link alone: lib/rt names the
// program's vx_main). Its state is global, as the program's is.
package blkfake

import vx "abi:vx"
import "base:runtime"
import "core:mem"
import "vx:driver"
import "vx:ring"
import "vx:rt"

CONNECTOR :: vx.Handle(0x301)
LISTEN :: vx.Handle(0x302)
END :: vx.Handle(0x303) // the client's ring end
MEMORY :: vx.Handle(0x304) // the ring's VMO
PORT :: vx.Handle(0x305)

NOW :: i64(5_000_000_000) // the monotonic clock: 5 s after boot
UTC_OFFSET :: i64(1_759_536_000_000_000_000) // UTC is 2025-10-04 00:00:05

// The disk: its image, its sector size, whether the driver says it is
// read-only, the most one request may move, and what was asked of it.
Disk :: struct {
	image:                   []u8,
	sector:                  u32,
	readonly:                bool,
	max_transfer:            u32,
	reads, writes, flushes:  int,
}

disk: Disk
kernel_log: [4096]u8
kernel_log_len: int

@(private="file")
ring_memory: []u8
@(private="file")
server: ring.Ring
@(private="file")
ports_made: int
@(private="file")
bell_key: u64

// The spawn message a manifest would give: args, the disk's connector named
// srv:NAME, and the listen channel.
spawn :: proc(name: string, args: ..string) {
	rt.spawn = {}
	for a in args {
		append(&rt.spawn.args, a)
	}
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "listen", LISTEN
	rt.spawn.handle_names[1], rt.spawn.handles[1] = name, CONNECTOR
	rt.spawn.handle_count = 2
	ports_made = 0
	kernel_log_len = 0
}

log :: proc() -> string {
	return string(kernel_log[:kernel_log_len])
}

// Serves every submission the ring holds, as a block driver would.
@(private="file")
drive :: proc "contextless" () {
	if !server.intact {
		return
	}
	e: vx.Sqe
	for ring.consume(&server, mem.ptr_to_bytes(&e)) == .Ok {
		c := vx.Cqe{user_data = e.user_data}
		arena := ring_memory[server.h.client_arena_offset:][:server.h.client_arena_size]
		off := e.target * u64(disk.sector)
		in_disk := off <= u64(len(disk.image)) && u64(e.len) <= u64(len(disk.image)) - off && e.len <= u32(len(arena))
		switch driver.Block_Op(e.opcode) {
		case .Info:
			c.result = i64(disk.max_transfer)
			c.aux, c.aux2 = disk.sector, u64(len(disk.image)) / u64(disk.sector)
			c.flags = transmute(u32)driver.Block_Info_Flags{.Cache}
			if disk.readonly {
				c.flags |= transmute(u32)driver.Block_Info_Flags{.Readonly}
			}
		case .Read:
			disk.reads += 1
			c.result = in_disk ? i64(copy(arena[:e.len], disk.image[off:])) : i64(vx.Status.Err_Range)
		case .Write, .Write_Fua:
			disk.writes += 1
			switch {
			case disk.readonly:
				c.result = i64(vx.Status.Err_Access)
			case in_disk:
				c.result = i64(copy(disk.image[off:][:e.len], arena[:e.len]))
			case:
				c.result = i64(vx.Status.Err_Range)
			}
		case .Flush:
			disk.flushes += 1
		case .Discard:
			c.result = i64(vx.Status.Err_Unsupported)
		case:
			c.result = i64(vx.Status.Err_Unsupported)
		}
		slot, ok := ring.produce_slot(&server)
		if !ok {
			return
		}
		copy(slot, mem.ptr_to_bytes(&c))
		_ = ring.produce(&server)
	}
}

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Clock_Read:
		if a0 != 0 {
			(^vx.Clock_Info)(uintptr(a0))^ = {counter_hz = 1_000_000_000, utc_offset = UTC_OFFSET}
		}
		return NOW
	case .Channel_Call: // a session on the disk
		if vx.Handle(a0) != CONNECTOR {
			return i64(vx.Status.Err_Bad_Handle)
		}
		h, st := ring.layout(driver.BLOCK_PARAMS)
		if st != .Ok {
			return i64(st)
		}
		if ring_memory == nil {
			context = runtime.default_context()
			ring_memory = make([]u8, h.size, runtime.heap_allocator())
		}
		mem.zero_slice(ring_memory)
		(^vx.Ring_Header)(raw_data(ring_memory))^ = h
		if ring.attach(&server, ring_memory, .Server, driver.BLOCK_PARAMS) != .Ok {
			return i64(vx.Status.Err_Invalid)
		}
		call := (^vx.Call)(uintptr(a1))
		call.rd_handles[0], call.rd_handles[1] = END, MEMORY
		call.actual = {bytes = size_of(vx.Msg_Header), handles = 2}
		return 0
	case .As_Map:
		if vx.Handle(a1) != MEMORY || a2 != 0 || a3 > u64(len(ring_memory)) {
			return i64(vx.Status.Err_Bad_Handle)
		}
		(^u64)(uintptr(a5))^ = u64(uintptr(raw_data(ring_memory)))
		return 0
	case .As_Unmap, .Handle_Close:
		return 0
	case .Port_Create:
		ports_made += 1
		if ports_made > 1 {
			return i64(vx.Status.Err_Unsupported) // the server's port: start returns
		}
		(^vx.Handle)(uintptr(a1))^ = PORT
		return 0
	case .Port_Bind:
		if vx.Trigger(a2) == .Counter_Ge {
			bell_key = a3
		}
		return 0
	case .Ring_Notify, .Counter_Read:
		drive()
		return 0
	case .Port_Wait:
		drive()
		pk := ([^]vx.Packet)(uintptr(a3))
		pk[0] = {key = bell_key, trigger = .Counter_Ge}
		return 1
	}
	return i64(vx.Status.Err_Unsupported)
}
