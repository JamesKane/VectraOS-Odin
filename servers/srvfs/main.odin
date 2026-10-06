// srvfs: /srv as a file tree (upstream's M6 step 6d4d2a), as 9front's
// srv(3) has it, posted as /srv/srv and mounted on /srv by the namespace
// templates.
//
// Each file is a post: a connector (a listen channel's client end) under a
// name, owned by whoever made it, with permissions. Posting is two steps, as
// 9front's: create /srv/NAME (anyone may: the directory is 0777), then write
// it with the connector beside the message (9Px's srv extension, upstream's
// docs/proto/srv.md). Opening a post gives a duplicate of its connector
// beside the Ropen, which the opener connects through and mounts; the mode is
// checked against the owner's bits or the others' (there are no groups here).
// Removing a post, its owner's to do, drops the connector: the server behind
// it goes on for whoever is connected already. A post made with ORCLOSE goes
// when its maker's fid does.
//
// svcd lists here the manifest posts that say srvmode= (owned by sys); the
// rest stay reachable only by the grants manifests give (upstream 01 §2).
package srvfs

import vx "abi:vx"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

@(private="file")
POSTS :: 64
@(private="file")
USERS :: 64
@(private="file")
NAME_MAX :: 63 // a post's name, in bytes
@(private="file")
USER_MAX :: 31 // a user's; a longer one attaches as none

@(private="file")
Post :: struct {
	used:      bool,
	name:      [dynamic; NAME_MAX]u8,
	owner:     u32, // a user's index
	mode:      u32, // its permission bits
	gen:       u32, // the qid's version: a name made again is another file
	connector: vx.Handle,
}

@(private="file")
posts: [POSTS]Post
@(private="file")
users: [dynamic; USERS][dynamic; USER_MAX]u8

// A node: the user who reached it, and the post's index plus 1 (0 for the
// directory).
@(private="file")
Id :: bit_field u64 {
	index: u32 | 32,
	user:  u32 | 32,
}

@(private="file")
node_of :: proc "contextless" (user, index: u32) -> p9.Node {
	return p9.Node(transmute(u64)Id{index = index, user = user})
}

@(private="file")
id_of :: proc "contextless" (n: p9.Node) -> Id {
	return transmute(Id)u64(n)
}

@(private="file")
post_of :: proc "contextless" (n: p9.Node) -> ^Post {
	i := id_of(n).index
	return i != 0 && i <= POSTS && posts[i - 1].used ? &posts[i - 1] : nil
}

@(private="file")
fs_attach_as :: proc "contextless" (ctx: rawptr, aname, uname: string) -> (root: p9.Node, st: vx.Status) {
	if aname != "" {
		return 0, .Err_Not_Found
	}
	name := uname
	if name == "" || len(name) > USER_MAX {
		name = "none"
	}
	u := 0
	for u < len(users) && string(users[u][:]) != name {
		u += 1
	}
	if u == len(users) {
		if len(users) == USERS {
			return 0, .Err_No_Memory
		}
		_ = append(&users, [dynamic; USER_MAX]u8{})
		_ = append(&users[u], name)
	}
	return node_of(u32(u), 0), .Ok
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	return fs_attach_as(ctx, aname, "none")
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	d := id_of(dir)
	if d.index != 0 {
		return 0, .Err_Not_Found
	}
	for &p, i in posts {
		if p.used && string(p.name[:]) == name {
			return node_of(d.user, u32(i) + 1), .Ok
		}
	}
	return 0, .Err_Not_Found
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	return node_of(id_of(n).user, 0), .Ok
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, n: p9.Node, out: ^p9.Stat) -> vx.Status {
	if id_of(n).index == 0 {
		out^ = {
			qid  = {type = p9.QTDIR},
			mode = p9.DMDIR | 0o777,
			name = "/",
			uid  = "sys",
			gid  = "sys",
			muid = "sys",
		}
		return .Ok
	}
	p := post_of(n)
	if p == nil {
		return .Err_Not_Found
	}
	owner := string(users[p.owner][:])
	out^ = {
		qid  = {type = p9.QTFILE, version = p.gen, path = u64(id_of(n).index)},
		mode = p.mode,
		name = string(p.name[:]),
		uid  = owner,
		gid  = owner,
		muid = owner,
	}
	return .Ok
}

// Whether the user may open the post so: the owner's bits or the others'.
@(private="file")
may :: proc "contextless" (p: ^Post, user: u32, mode: p9.Open_Mode) -> bool {
	bits := user == p.owner ? (p.mode >> 6) & 7 : p.mode & 7
	r := mode.access == .Read || mode.access == .Rdwr
	w := mode.access == .Write || mode.access == .Rdwr
	return (!r || bits & 4 != 0) && (!w || bits & 2 != 0)
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	if id_of(n).index == 0 {
		return mode.access == .Read ? .Ok : .Err_Access
	}
	p := post_of(n)
	if p == nil {
		return .Err_Not_Found
	}
	if mode.trunc {
		return .Err_Access
	}
	return may(p, id_of(n).user, mode) ? .Ok : .Err_Access
}

// The connector, duplicated, beside the Ropen: what a mount connects
// through.
@(private="file")
fs_open_handle :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> (h: vx.Handle, st: vx.Status) {
	if id_of(n).index == 0 {
		return vx.HANDLE_NONE, .Ok // the directory: nothing beside its Ropen
	}
	p := post_of(n)
	if p == nil {
		return vx.HANDLE_NONE, .Err_Not_Found
	}
	if p.connector == vx.HANDLE_NONE {
		return vx.HANDLE_NONE, .Err_Bad_State // made, not posted yet
	}
	return rt.handle_dup(p.connector, vx.RIGHTS_SAME)
}

@(private="file")
fs_create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	d := id_of(dir)
	if d.index != 0 {
		return 0, .Err_Invalid
	}
	if perm &~ 0o777 != 0 {
		return 0, .Err_Unsupported // a post is a file
	}
	if len(name) > NAME_MAX {
		return 0, .Err_Range
	}
	if _, there := fs_walk(ctx, dir, name); there == .Ok {
		return 0, .Err_Exists
	}
	for &p, i in posts {
		if p.used {
			continue
		}
		p = {used = true, owner = d.user, mode = perm, gen = p.gen + 1}
		_ = append(&p.name, name)
		return node_of(d.user, u32(i) + 1), .Ok
	}
	return 0, .Err_No_Memory
}

// The post itself: the connector beside the write, once.
@(private="file")
fs_write_handle :: proc "contextless" (ctx: rawptr, n: p9.Node, h: vx.Handle) -> vx.Status {
	p := post_of(n)
	st := vx.Status.Ok
	if p == nil {
		st = .Err_Not_Found
	} else if p.connector != vx.HANDLE_NONE {
		st = .Err_Bad_State // posted already
	}
	if st != .Ok {
		rt.close_all(h)
		return st
	}
	p.connector = h
	return .Ok
}

// A write without a connector posts nothing.
@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	return 0, .Err_Invalid
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	return 0, .Ok
}

@(private="file")
fs_remove :: proc "contextless" (ctx: rawptr, n: p9.Node) -> vx.Status {
	p := post_of(n)
	if p == nil {
		return .Err_Not_Found
	}
	if p.owner != id_of(n).user {
		return .Err_Access // the owner's to take back
	}
	rt.close_all(p.connector)
	p^ = {gen = p.gen}
	return .Ok
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	d := id_of(dir)
	if d.index != 0 {
		return 0, .Err_Not_Found
	}
	n := u32(0)
	for &p, i in posts {
		if !p.used {
			continue
		}
		if n == index {
			return node_of(d.user, u32(i) + 1), .Ok
		}
		n += 1
	}
	return 0, .Err_Not_Found
}

@(private="file")
server := p9ring.Server {
	fs = {
		attach = fs_attach,
		attach_as = fs_attach_as,
		walk = fs_walk,
		parent = fs_parent,
		stat = fs_stat,
		open = fs_open,
		read = fs_read,
		readdir = fs_readdir,
		write = fs_write,
		create = fs_create,
		remove = fs_remove,
		open_handle = fs_open_handle,
		write_handle = fs_write_handle,
	},
	name = "srvfs",
	supported = {.Xattr, .Srv},
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	if server.listen == vx.HANDLE_NONE {
		rt.print("srvfs: no listen channel\n")
		return -1 // upstream's exit string: "no listen channel"
	}
	rt.print("srvfs: serving /srv/srv\n")
	return int(p9ring.serve(&server))
}
