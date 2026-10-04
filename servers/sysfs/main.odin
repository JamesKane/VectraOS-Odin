// sysfs: /sys (upstream 02 §5), posted as /srv/sys. M4 serves its clock:
//
//   /sys/clock/info   the cycle counter the one clock is made from, as the
//                     kernel calibrated it (clock_read's Clock_Info):
//                       tsc.hz=3187200000 tsc.invariant tsc.user source=tsc
//                       cntfrq.hz=24000000 cntvct.invariant cntvct.user source=cntvct
//                     so a program timing itself with rdtsc or cntvct_el0
//                     (vx:prof's zones) need not calibrate (upstream 05 §9)
//   /sys/clock/now    monotonic=NS realtime=NS: realtime is UTC, ns since
//                     1970, once a clock driver has set the kernel's wall
//                     clock (upstream ADR-0031); from boot until then
//
// cpu/, mem/, power/ and the rest of upstream 02 §5.1 come with what
// measures them.
package sysfs

import vx "abi:vx"
import "vx:ndb"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

@(private="file")
File :: enum u64 {
	None,
	Root,
	Clock,
	Info,
	Now,
}

@(private="file")
NAMES := [File]string {
	.None  = "",
	.Root  = "/",
	.Clock = "clock",
	.Info  = "info",
	.Now   = "now",
}

@(private="file")
PARENT := [File]File {
	.None  = .None,
	.Root  = .Root,
	.Clock = .Root,
	.Info  = .Clock,
	.Now   = .Clock,
}

// clock_read(&info)'s answer: the counter's frequency, what kind it is, and
// the wall clock's offset.
@(private="file", require_results)
clock_info_read :: proc "contextless" (info: ^vx.Clock_Info) -> (st: vx.Status) {
	info^, st = rt.clock_info()
	return
}

@(private="file")
file_of :: proc "contextless" (n: p9.Node) -> File {
	return n <= p9.Node(File.Now) ? File(n) : .None
}

@(private="file")
is_dir :: proc "contextless" (f: File) -> bool {
	return f == .Root || f == .Clock
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	return p9.Node(File.Root), .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	for f in File.Clock ..= File.Now {
		if PARENT[f] == file_of(dir) && file_of(dir) != .None && NAMES[f] == name {
			return p9.Node(f), .Ok
		}
	}
	return 0, .Err_Not_Found
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	f := file_of(n)
	return p9.Node(f != .None ? PARENT[f] : File.Root), .Ok
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, n: p9.Node, out: ^p9.Stat) -> vx.Status {
	f := file_of(n)
	if f == .None {
		return .Err_Not_Found
	}
	out^ = {
		qid  = {type = is_dir(f) ? p9.QTDIR : p9.QTFILE, path = u64(n)},
		mode = is_dir(f) ? p9.DMDIR | 0o555 : 0o444,
		name = NAMES[f],
		uid  = "sys",
		gid  = "sys",
		muid = "sys",
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	return mode.access == .Read ? .Ok : .Err_Access
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	text: [256]u8
	w := ndb.Writer{buf = text[:]}
	f := file_of(n)
	info: vx.Clock_Info
	now := rt.clock_read()
	if f == .Info && clock_info_read(&info) == .Ok {
		tsc := .Tsc in info.flags
		ndb.put_u64(&w, tsc ? "tsc.hz" : "cntfrq.hz", info.counter_hz)
		if .Invariant in info.flags {
			ndb.flag(&w, tsc ? "tsc.invariant" : "cntvct.invariant")
		}
		if .User in info.flags {
			ndb.flag(&w, tsc ? "tsc.user" : "cntvct.user")
		}
		ndb.put(&w, "source", tsc ? "tsc" : "cntvct")
		_ = ndb.end(&w)
	} else if f == .Now {
		ndb.put_u64(&w, "monotonic", u64(now))
		ndb.put_u64(&w, "realtime", u64(rt.clock_utc()))
		_ = ndb.end(&w)
	} else if is_dir(f) {
		return 0, .Err_Invalid // read as a directory, through readdir
	}
	s := w.failed ? "" : ndb.written(&w)
	if offset >= u64(len(s)) {
		return 0, .Ok
	}
	return u32(copy(buf, s[offset:])), .Ok
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	seen := u32(0)
	for f in File.Clock ..= File.Now {
		if PARENT[f] != file_of(dir) || file_of(dir) == .None {
			continue
		}
		if seen == index {
			return p9.Node(f), .Ok
		}
		seen += 1
	}
	return 0, .Err_Not_Found
}

// Not file-private: tests/host drives its Fs on the host.
server := p9ring.Server {
	fs = {attach = fs_attach, walk = fs_walk, parent = fs_parent, stat = fs_stat, open = fs_open, read = fs_read, readdir = fs_readdir},
	name = "sysfs",
	supported = {.Xattr}, // Tgetattr, for stat
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		rt.print("sysfs: no listen channel\n")
		return -1 // upstream's exit string: "no listen channel"
	}
	rt.print("sysfs: serving /srv/sys\n")
	return int(p9ring.serve(&server))
}
