// pooltestd: a file server whose reads wait with the server let go
// (upstream's M6 step 6d5a), for pooltest (tests/user/pooltest), posted as
// /srv/pooltest with four threads:
//   fast  answers at once
//   slow  waits 300 ms, let go
//   gate  waits, let go, until open is written
//   open  a write opens the gate (and shuts it again for the next read)
//   peak  how many reads were let go at once, at most
package pooltestd

import "base:intrinsics"
import vx "abi:vx"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

File :: enum u64 {
	Root,
	Fast,
	Slow,
	Gate,
	Open,
	Peak,
}

NAMES := [File]string {
	.Root = "/",
	.Fast = "fast",
	.Slow = "slow",
	.Gate = "gate",
	.Open = "open",
	.Peak = "peak",
}

gate: u32 // atomic, its generation: a write moves it on
waiting, peak: u32 // the server's lock held for these

file_of :: proc "contextless" (n: p9.Node) -> (File, bool) {
	return File(n), n <= p9.Node(File.Peak)
}

fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	return p9.Node(File.Root), .Ok
}

fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	if dir != p9.Node(File.Root) {
		return 0, .Err_Not_Found
	}
	for f in File.Fast ..= File.Peak {
		if NAMES[f] == name {
			return p9.Node(f), .Ok
		}
	}
	return 0, .Err_Not_Found
}

fs_parent :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	return p9.Node(File.Root), .Ok
}

fs_stat :: proc "contextless" (ctx: rawptr, n: p9.Node, out: ^p9.Stat) -> vx.Status {
	f, ok := file_of(n)
	if !ok {
		return .Err_Not_Found
	}
	root := f == .Root
	out^ = {
		qid  = {type = root ? p9.QTDIR : p9.QTFILE, path = u64(n)},
		mode = root ? p9.DMDIR | 0o555 : 0o666,
		name = NAMES[f],
		uid  = "sys",
		gid  = "sys",
		muid = "sys",
	}
	return .Ok
}

fs_open :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	_, ok := file_of(n)
	return ok ? .Ok : .Err_Not_Found
}

fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	if dir != p9.Node(File.Root) || u64(index) + 1 > u64(File.Peak) {
		return 0, .Err_Not_Found
	}
	return p9.Node(index + 1), .Ok
}

// Waits let go: until the deadline, or until the gate moves on from `from`.
wait_released :: proc "contextless" (deadline: vx.Instant, gated: bool, from: u32) {
	waiting += 1
	peak = max(peak, waiting)
	released := p9ring.release()
	if gated {
		for intrinsics.atomic_load(&gate) == from {
			_ = rt.futex_wait(&gate, from, vx.INFINITE)
		}
	} else {
		never: u32
		for rt.clock_read() < deadline {
			_ = rt.futex_wait(&never, 0, deadline)
		}
	}
	if released {
		p9ring.acquire()
	}
	waiting -= 1
}

fs_read :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	f, ok := file_of(n)
	if !ok {
		return 0, .Err_Not_Found
	}
	#partial switch f {
	case .Slow:
		wait_released(rt.clock_read() + 300_000_000, false, 0)
	case .Gate:
		wait_released(vx.INFINITE, true, intrinsics.atomic_load(&gate))
	}
	text: [dynamic; 32]u8
	if f == .Peak {
		_ = append(&text, '0' + u8(peak % 10), '\n') // never past 9: four threads
	} else if f != .Root {
		_ = append(&text, NAMES[f])
		_ = append(&text, '\n')
	}
	if offset >= u64(len(text)) {
		return 0, .Ok
	}
	return u32(copy(buf, text[offset:])), .Ok
}

fs_write :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	if n != p9.Node(File.Open) {
		return 0, .Err_Access
	}
	intrinsics.atomic_add(&gate, 1)
	_, _ = rt.futex_wake(&gate, max(u32))
	return u32(len(data)), .Ok // all of it
}

server := p9ring.Server {
	fs = {attach = fs_attach, walk = fs_walk, parent = fs_parent, stat = fs_stat, open = fs_open, read = fs_read, readdir = fs_readdir, write = fs_write},
	name = "pooltestd",
	max_threads = 4,
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		rt.exits("no listen channel")
	}
	rt.print("pooltestd: serving /srv/pooltest\n")
	if p9ring.serve(&server) != .Ok {
		rt.exits("cannot serve")
	}
	return 0
}
