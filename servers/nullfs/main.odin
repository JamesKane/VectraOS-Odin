// nullfs: /dev's null, zero, random and urandom (upstream 02 §5), posted as
// /srv/null.
//
//   null      reads as empty; takes any write
//   zero      reads as zeros; takes any write
//   random    random bytes, from a generator (vx:drbg) seeded with the
//   urandom   entropy svcd gives it; the same generator, as on Linux since 5.6
//
// Without a seed from svcd, random and urandom refuse to be read rather than
// give bytes nobody should trust.
package nullfs

import vx "abi:vx"
import "vx:drbg"
import "vx:ndb"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

@(private="file")
File :: enum u64 {
	None,
	Root,
	Null,
	Zero,
	Random,
	Urandom,
}

@(private="file")
NAMES := [File]string {
	.None    = "",
	.Root    = "/",
	.Null    = "null",
	.Zero    = "zero",
	.Random  = "random",
	.Urandom = "urandom",
}

@(private="file")
randomness: drbg.Drbg

// A node the framework hands back is one this server made, but say so
// rather than index with whatever came.
@(private="file")
file_of :: proc "contextless" (n: p9.Node) -> File {
	return n <= p9.Node(File.Urandom) ? File(n) : .None
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
	if file_of(dir) == .Root {
		for f in File.Null ..= File.Urandom {
			if NAMES[f] == name {
				return p9.Node(f), .Ok
			}
		}
	}
	return 0, .Err_Not_Found
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	return p9.Node(File.Root), .Ok
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, n: p9.Node, out: ^p9.Stat) -> vx.Status {
	root := file_of(n) == .Root
	out^ = {
		qid  = {type = root ? p9.QTDIR : p9.QTFILE, path = u64(n)},
		mode = root ? p9.DMDIR | 0o555 : 0o666,
		name = NAMES[file_of(n)],
		uid  = "sys",
		gid  = "sys",
		muid = "sys",
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	f := file_of(n)
	if f == .Root && mode.access != .Read {
		return .Err_Access
	}
	if (f == .Random || f == .Urandom) && !randomness.seeded && mode.access != .Write {
		return .Err_Bad_State
	}
	return .Ok
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	#partial switch file_of(n) {
	case .Null:
		return 0, .Ok
	case .Zero:
		for &b in buf {
			b = 0
		}
	case:
		drbg.read(&randomness, buf)
	}
	return u32(len(buf)), .Ok
}

// What is written to random or urandom is mixed in, as on Linux; it is not
// counted as a seed. All of it is taken.
@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	if f := file_of(n); f == .Random || f == .Urandom {
		drbg.mix(&randomness, data, false)
	}
	return u32(len(data)), .Ok
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	if file_of(dir) != .Root || u64(index) > u64(File.Urandom - File.Null) {
		return 0, .Err_Not_Found
	}
	return p9.Node(File.Null) + p9.Node(index), .Ok
}

// Not file-private: tests/host drives its Fs on the host.
server := p9ring.Server {
	fs = {attach = fs_attach, walk = fs_walk, parent = fs_parent, stat = fs_stat, open = fs_open, read = fs_read, readdir = fs_readdir, write = fs_write},
	name = "nullfs",
	supported = {.Xattr}, // Tgetattr, for stat; nothing can be changed
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		rt.print("nullfs: no listen channel\n")
		return -1 // upstream's exit string: "no listen channel"
	}
	rec: ndb.Record
	if rt.spawn_record("entropy", &rec) {
		if seed, ok := ndb.get(&rec, "entropy"); ok && len(seed) >= 16 {
			drbg.mix(&randomness, transmute([]u8)seed, true)
		}
	}
	rt.print(randomness.seeded ? "nullfs: serving /srv/null\n" : "nullfs: serving /srv/null, without entropy: random cannot be read\n")
	return int(p9ring.serve(&server))
}
