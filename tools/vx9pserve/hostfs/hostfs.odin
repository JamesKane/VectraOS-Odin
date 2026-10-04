// vx9pserve's file server: a host directory as a p9.Fs (lib/p9's server
// framework), for VectraOS to mount over TCP (upstream 04 §5 M3). macOS and
// Linux.
//
// Nothing outside the directory can be reached. lib/p9 keeps a walk inside
// the attach root and refuses names with '/', "." and ".."; here, every path
// is opened one component at a time with openat and O_NOFOLLOW, from a
// descriptor on the root, so a symbolic link anywhere (even one swapped in
// after a walk) is refused, never followed. Symbolic links are not listed or
// walked to at all.
//
// A node is a path relative to the root, numbered the first time it is walked
// to; the number is its qid path, stable for as long as the server runs.
// Reads and writes open the file each time: the server keeps no descriptors
// but the root's.
package hostfs

import "base:runtime"
import "core:c"
import "core:strings"
import "core:sys/posix"
import "abi:vx"
import "vx:p9"

// A descriptor that only names a directory, for openat: Linux's O_PATH,
// and the nearest macOS has, O_SEARCH.
when ODIN_OS == .Linux {
	O_PATH :: posix.O_Flags{posix.O_Flag_Bits(21)} // 0o10000000
} else {
	O_PATH :: posix.O_SEARCH
}

Hostfs :: struct {
	root:  posix.FD, // a directory-only descriptor on the served directory
	paths: [dynamic]string, // node n's path, relative to the root ("" for the root): n from 1
	ctx:   runtime.Context, // the callbacks' context: paths come from its allocator
}

@(private="file")
status_of :: proc "contextless" (e: posix.Errno) -> vx.Status {
	#partial switch e {
	case .ENOENT, .ENOTDIR, .ELOOP:
		return .Err_Not_Found // a symbolic link is as good as absent
	case .EACCES, .EPERM, .EROFS:
		return .Err_Access
	case .EEXIST, .ENOTEMPTY:
		return .Err_Exists
	case .EISDIR:
		return .Err_Bad_State
	case .ENOMEM, .ENOSPC:
		return .Err_No_Memory
	}
	return .Err_Invalid
}

// The last error, as a Status.
@(private="file")
failed :: proc "contextless" () -> vx.Status {
	return status_of(posix.errno())
}

// Opens a node's path: each directory on the way with O_NOFOLLOW, then the
// last component with flags (and O_NOFOLLOW). -1 and errno on failure.
@(private="file")
open_path :: proc(h: ^Hostfs, path: string, flags: posix.O_Flags, mode: posix.mode_t = {}) -> posix.FD {
	dir, last := open_parent(h, path)
	if dir < 0 {
		return -1
	}
	name := last if len(last) > 0 else "." // "": the root itself
	fd := posix.openat(dir, strings.clone_to_cstring(name, context.temp_allocator), flags + {.NOFOLLOW, .CLOEXEC}, mode)
	saved := posix.errno()
	posix.close(dir)
	posix.set_errno(saved)
	return fd
}

// Opens the directory a node's path is in, each directory on the way with
// O_NOFOLLOW, and gives the final name in path (for fstatat, mkdirat,
// unlinkat). -1 and errno on failure.
@(private="file")
open_parent :: proc(h: ^Hostfs, path: string) -> (dir: posix.FD, last: string) {
	dir = posix.dup(h.root)
	if dir < 0 {
		return -1, ""
	}
	rest := path
	for {
		slash := strings.index_byte(rest, '/')
		if slash < 0 {
			break
		}
		comp := rest[:slash]
		if len(comp) == 0 || len(comp) >= 256 {
			posix.close(dir)
			posix.set_errno(.ENOENT)
			return -1, ""
		}
		next := posix.openat(dir, strings.clone_to_cstring(comp, context.temp_allocator), O_PATH + {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
		posix.close(dir)
		if next < 0 {
			return -1, ""
		}
		dir = next
		rest = rest[slash + 1:]
	}
	return dir, rest
}

// lstat of a node's path, without following anything.
@(private="file")
lstat_path :: proc(h: ^Hostfs, path: string, st: ^posix.stat_t) -> bool {
	if len(path) == 0 {
		return posix.fstat(h.root, st) == .OK
	}
	dir, last := open_parent(h, path)
	if dir < 0 {
		return false
	}
	r := posix.fstatat(dir, strings.clone_to_cstring(last, context.temp_allocator), st, {.SYMLINK_NOFOLLOW})
	saved := posix.errno()
	posix.close(dir)
	posix.set_errno(saved)
	return r == .OK
}

// The node for a path: the one it already has, or a new one.
@(private="file")
node_of :: proc(h: ^Hostfs, path: string) -> p9.Node {
	for p, i in h.paths {
		if p == path {
			return p9.Node(i + 1)
		}
	}
	append(&h.paths, strings.clone(path))
	return p9.Node(len(h.paths))
}

@(private="file")
path_of :: proc "contextless" (h: ^Hostfs, node: p9.Node) -> (path: string, ok: bool) {
	if node == 0 || int(node) > len(h.paths) {
		return "", false
	}
	return h.paths[node - 1], true
}

// The path of name in the directory at base; not ok if it would not fit
// upstream's 4096-byte buffer.
@(private="file")
child_path :: proc(base, name: string) -> (path: string, ok: bool) {
	path = len(base) > 0 ? strings.concatenate({base, "/", name}, context.temp_allocator) : name
	return path, len(path) < 4096
}

@(private="file")
attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	h := (^Hostfs)(ctx)
	context = h.ctx
	if len(aname) > 0 {
		return 0, .Err_Not_Found // one tree: the directory
	}
	return node_of(h, ""), .Ok
}

@(private="file")
walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	h := (^Hostfs)(ctx)
	context = h.ctx
	base, ok := path_of(h, dir)
	if !ok || len(name) > 255 {
		return 0, .Err_Not_Found
	}
	path, fits := child_path(base, name)
	if !fits || strings.index_byte(name, 0) >= 0 {
		return 0, .Err_Not_Found
	}
	s: posix.stat_t
	if !lstat_path(h, path, &s) {
		return 0, failed()
	}
	if !posix.S_ISDIR(s.st_mode) && !posix.S_ISREG(s.st_mode) {
		return 0, .Err_Not_Found // links, devices, sockets: not here
	}
	return node_of(h, path), .Ok
}

@(private="file")
parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (up: p9.Node, st: vx.Status) {
	h := (^Hostfs)(ctx)
	context = h.ctx
	path, ok := path_of(h, node)
	if !ok || len(path) == 0 {
		return 0, .Err_Not_Found
	}
	return node_of(h, path[:max(strings.last_index_byte(path, '/'), 0)]), .Ok
}

@(private="file")
stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	h := (^Hostfs)(ctx)
	context = h.ctx
	path, ok := path_of(h, node)
	if !ok {
		return .Err_Not_Found
	}
	s: posix.stat_t
	if !lstat_path(h, path, &s) {
		return failed()
	}
	dir := posix.S_ISDIR(s.st_mode)
	// The name is the end of the node's path, which lasts as long as the server.
	name := len(path) > 0 ? path[strings.last_index_byte(path, '/') + 1:] : "/"
	out^ = {
		qid = {dir ? p9.QTDIR : p9.QTFILE, u32(s.st_mtim.tv_sec), u64(node)},
		mode = (dir ? p9.DMDIR : 0) | u32(transmute(posix._mode_t)s.st_mode) & 0o777,
		atime = u32(s.st_atim.tv_sec),
		mtime = u32(s.st_mtim.tv_sec),
		length = dir ? 0 : u64(s.st_size),
		name = name,
		uid = "host",
		gid = "host",
		muid = "host",
	}
	return .Ok
}

@(private="file")
flags_of :: proc "contextless" (mode: p9.Open_Mode) -> (flags: posix.O_Flags) {
	#partial switch mode.access {
	case .Write:
		flags = {.WRONLY}
	case .Rdwr:
		flags = {.RDWR}
	}
	if mode.trunc {
		flags += {.TRUNC}
	}
	return
}

@(private="file")
open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	h := (^Hostfs)(ctx)
	context = h.ctx
	path, ok := path_of(h, node)
	if !ok {
		return .Err_Not_Found
	}
	if mode.rclose {
		return .Err_Access
	}
	s: posix.stat_t
	if !lstat_path(h, path, &s) {
		return failed()
	}
	if posix.S_ISDIR(s.st_mode) {
		return .Ok // the framework allows directories only to be read
	}
	fd := open_path(h, path, flags_of(mode)) // checks permission; truncates if asked
	if fd < 0 {
		return failed()
	}
	posix.close(fd)
	return .Ok
}

@(private="file")
read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	h := (^Hostfs)(ctx)
	context = h.ctx
	path, ok := path_of(h, node)
	if !ok {
		return 0, .Err_Not_Found
	}
	fd := open_path(h, path, {})
	if fd < 0 {
		return 0, failed()
	}
	defer posix.close(fd)
	if offset > u64(max(i64)) {
		return 0, .Ok
	}
	n := posix.pread(fd, raw_data(buf), c.size_t(len(buf)), posix.off_t(offset))
	if n < 0 {
		return 0, failed()
	}
	return u32(n), .Ok
}

@(private="file")
write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	h := (^Hostfs)(ctx)
	context = h.ctx
	path, ok := path_of(h, node)
	if !ok {
		return 0, .Err_Not_Found
	}
	fd := open_path(h, path, {.WRONLY})
	if fd < 0 {
		return 0, failed()
	}
	defer posix.close(fd)
	if offset > u64(max(i64)) {
		// Upstream reports whatever errno last held here (pwrite is never
		// called); so does this, to answer as it does.
		return 0, failed()
	}
	n := posix.pwrite(fd, raw_data(data), c.size_t(len(data)), posix.off_t(offset))
	if n < 0 {
		return 0, failed()
	}
	return u32(n), .Ok
}

// The index-th entry of a directory, skipping ".", ".." and anything that is
// neither a file nor a directory.
@(private="file")
readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	h := (^Hostfs)(ctx)
	context = h.ctx
	path, ok := path_of(h, dir)
	if !ok {
		return 0, .Err_Not_Found
	}
	fd := open_path(h, path, {.DIRECTORY})
	if fd < 0 {
		return 0, failed()
	}
	d := posix.fdopendir(fd)
	if d == nil {
		posix.close(fd)
		return 0, .Err_No_Memory
	}
	defer posix.closedir(d)
	left := index
	for e := posix.readdir(d); e != nil; e = posix.readdir(d) {
		name := string(cstring(raw_data(e.d_name[:])))
		if name == "." || name == ".." || (e.d_type != .REG && e.d_type != .DIR) {
			continue
		}
		if left == 0 {
			return walk(ctx, dir, name)
		}
		left -= 1
	}
	return 0, .Err_Not_Found
}

@(private="file")
create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	h := (^Hostfs)(ctx)
	context = h.ctx
	base, ok := path_of(h, dir)
	if !ok || len(name) > 255 || strings.index_byte(name, 0) >= 0 {
		return 0, .Err_Invalid
	}
	path, fits := child_path(base, name)
	if !fits {
		return 0, .Err_Invalid
	}
	parent_fd, last := open_parent(h, path)
	if parent_fd < 0 {
		return 0, failed()
	}
	defer posix.close(parent_fd)
	cname := strings.clone_to_cstring(last, context.temp_allocator)
	if perm & p9.DMDIR != 0 {
		if posix.mkdirat(parent_fd, cname, transmute(posix.mode_t)posix._mode_t(perm & 0o777)) != .OK {
			return 0, failed()
		}
	} else {
		fd := posix.openat(parent_fd, cname, flags_of(mode) + {.CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, transmute(posix.mode_t)posix._mode_t(perm & 0o666))
		if fd < 0 {
			return 0, failed()
		}
		posix.close(fd)
	}
	return node_of(h, path), .Ok
}

@(private="file")
remove :: proc "contextless" (ctx: rawptr, node: p9.Node) -> vx.Status {
	h := (^Hostfs)(ctx)
	context = h.ctx
	path, ok := path_of(h, node)
	if !ok || len(path) == 0 {
		return .Err_Access // not the root
	}
	s: posix.stat_t
	if !lstat_path(h, path, &s) {
		return failed()
	}
	parent_fd, last := open_parent(h, path)
	if parent_fd < 0 {
		return failed()
	}
	defer posix.close(parent_fd)
	if posix.unlinkat(parent_fd, strings.clone_to_cstring(last, context.temp_allocator), posix.S_ISDIR(s.st_mode) ? {.REMOVEDIR} : {}) != .OK {
		return failed()
	}
	return .Ok
}

// Makes h serve the directory at dir, and s (a connection before Tversion) a
// server for it; false if the directory cannot be opened. Callbacks run in
// the caller's context, and paths come from its allocator until destroy.
init :: proc(h: ^Hostfs, s: ^p9.Server, dir: string, max_msize: u32) -> bool {
	h^ = {
		root = posix.open(strings.clone_to_cstring(dir, context.temp_allocator), O_PATH + {.DIRECTORY, .CLOEXEC}),
		ctx  = context,
	}
	if h.root < 0 {
		return false
	}
	s^ = {
		fs = {
			ctx = h,
			attach = attach,
			walk = walk,
			parent = parent,
			stat = stat,
			open = open,
			read = read,
			readdir = readdir,
			write = write,
			create = create,
			remove = remove,
		},
		max_msize = max_msize,
	}
	return true
}

destroy :: proc(h: ^Hostfs) {
	for p in h.paths {
		delete(p)
	}
	delete(h.paths)
	posix.close(h.root)
	h^ = {}
}
