// envd: environment groups (upstream's M6 step 6e1c1; ADR-0022, upstream's
// ADR-0044), as 9front's devenv (sys/src/9/port/devenv.c) keeps an Egrp for
// each process group, posted as /srv/env.
//
// A group is a directory of variables, each a file whose bytes are its
// value. A process reaches its group through a connection of its own, not
// its namespace (vx:ns's /env, which a namespace group does not share): it
// attaches with the aname "new" (an empty group), "+TOKEN" (a copy of the
// group TOKEN names: rfork e) or "TOKEN" (that group: what a child shares
// with its parent). A group's token is the root's qid path, 64 random bits:
// knowing it is the authority to reach the group, as a handle is, so it is
// never a small number another process could guess. A group lives while any
// fid holds one of its files (the framework's fid_node), and goes with the
// last.
//
// A variable is created with Tcreate, written (from offset 0 after an open
// with OTRUNC, as 9front's putenv writes), read, listed and removed. There
// are no permissions: whoever holds the token holds the group.
package envd

import "base:intrinsics"
import vx "abi:vx"
import "vx:drbg"
import "vx:memory"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

@(private="file")
GROUPS :: 128
@(private="file")
VARS :: 1024
@(private="file")
NAME_MAX :: 128 // a name is shorter
@(private="file")
MAX_VALUE :: u64(1) << 20
@(private="file")
MAX_BYTES :: u64(32) << 20

@(private="file")
Group :: struct {
	used:  bool,
	token: u64, // the root's qid path: its name, unguessable
	fids:  int, // fids on its files, the framework's count: none, and it goes
}

@(private="file")
Var :: struct {
	group: u32, // its group's index plus 1; 0: the slot is free
	gen:   u32, // its slot's generation, bumped as it is freed: a qid's version
	name:  [dynamic; NAME_MAX - 1]u8,
	data:  []u8, // a mapping of its own, as long as its capacity
	size:  u64,
}

@(private="file")
groups: [GROUPS]Group
@(private="file")
vars: [VARS]Var
@(private="file")
bytes_used: u64

// A node: the group's index plus 1 (bits 40 up), the variable slot's
// generation (bits 16 to 39) and its index plus 1 (0 for the root), so a fid
// on a variable removed finds nothing when its slot is used again (the
// review of 2026-10-07, upstream's 2cc4729).
@(private="file")
Node_Bits :: bit_field u64 {
	var:   u32 | 16, // the slot's index plus 1; 0: the group's root
	gen:   u32 | 24, // the slot's generation, its low 24 bits
	group: u32 | 24, // the group's index plus 1
}
#assert(VARS < 1 << 16)

@(private="file")
node_of :: proc "contextless" (g, v: u32) -> p9.Node {
	n := Node_Bits{var = v, group = g + 1}
	if v != 0 {
		n.gen = vars[v - 1].gen & 0xff_ffff
	}
	return p9.Node(transmute(u64)n)
}

@(private="file")
node_group :: proc "contextless" (node: p9.Node) -> u32 { // plus 1
	return (transmute(Node_Bits)u64(node)).group
}

@(private="file")
node_var :: proc "contextless" (node: p9.Node) -> u32 { // plus 1
	return (transmute(Node_Bits)u64(node)).var
}

@(private="file")
group_of :: proc "contextless" (node: p9.Node) -> ^Group {
	g := node_group(node)
	return g != 0 && g <= GROUPS && groups[g - 1].used ? &groups[g - 1] : nil
}

@(private="file")
var_of :: proc "contextless" (node: p9.Node) -> ^Var {
	n := transmute(Node_Bits)u64(node)
	if n.var == 0 || n.var > VARS || vars[n.var - 1].group != n.group || vars[n.var - 1].gen & 0xff_ffff != n.gen {
		return nil
	}
	return &vars[n.var - 1]
}

// vx:rt's as_unmap wrapper comes with the kernel's M4 port; until then, the
// call itself, as tmpfs makes it.
@(private="file")
unmap :: proc "contextless" (b: []u8) {
	_ = rt.vx_syscall(.As_Unmap, u64(rt.self), u64(uintptr(raw_data(b))), u64(len(b)))
}

@(private="file")
var_free :: proc "contextless" (x: ^Var) {
	if x.data != nil {
		unmap(x.data)
	}
	bytes_used -= u64(len(x.data))
	x^ = {gen = x.gen + 1}
}

// Room for size bytes: a mapping twice as large as before, the old copied
// (tmpfs's way).
@(private="file", require_results)
reserve :: proc "contextless" (x: ^Var, size: u64) -> vx.Status {
	old := u64(len(x.data))
	if size <= old {
		return .Ok
	}
	if size > MAX_VALUE {
		return .Err_No_Memory
	}
	capacity := old != 0 ? old : memory.PAGE_SIZE
	for capacity < size {
		capacity *= 2
	}
	if bytes_used - old + capacity > MAX_BYTES {
		return .Err_No_Memory
	}
	vmo := rt.vmo_create(capacity) or_return
	at, st := rt.as_map(rt.self, vmo, 0, capacity, {.Write})
	_ = rt.handle_close(vmo) // the mapping keeps it
	st or_return
	data := (cast([^]u8)uintptr(at))[:capacity]
	copy(data, x.data[:x.size])
	if x.data != nil {
		unmap(x.data)
	}
	bytes_used += capacity - old
	x.data = data
	return .Ok
}

@(private="file")
var_new :: proc "contextless" (g: u32, name: string) -> ^Var {
	for &x in vars {
		if x.group == 0 {
			x.group = g + 1
			clear(&x.name)
			_ = append(&x.name, name) // it fits: the caller checked
			return &x
		}
	}
	return nil
}

@(private="file")
var_named :: proc "contextless" (g: u32, name: string) -> ^Var {
	for &x in vars {
		if x.group == g + 1 && string(x.name[:]) == name {
			return &x
		}
	}
	return nil
}

@(private="file")
group_new :: proc "contextless" () -> u32 {
	for &g, i in groups {
		if !g.used {
			token: u64
			for token == 0 {
				drbg.read(&server.shared.random, memory.ptr_to_bytes(&token))
			}
			g = {
				used  = true,
				token = token,
			}
			return u32(i)
		}
	}
	return GROUPS
}

@(private="file")
group_free :: proc "contextless" (g: u32) {
	for &x in vars {
		if x.group == g + 1 {
			var_free(&x)
		}
	}
	groups[g] = {}
}

// "TOKEN" or "+TOKEN"'s token in hex: the group it names, or GROUPS.
@(private="file")
group_by_token :: proc "contextless" (hex: string) -> u32 {
	if len(hex) == 0 || len(hex) > 16 {
		return GROUPS
	}
	t: u64
	for c in transmute([]u8)hex {
		d: u64
		switch c {
		case '0' ..= '9':
			d = u64(c - '0')
		case 'a' ..= 'f':
			d = u64(c - 'a') + 10
		case:
			return GROUPS
		}
		t = t << 4 | d
	}
	for &g, i in groups {
		if g.used && g.token == t {
			return u32(i)
		}
	}
	return GROUPS
}

// A copy of group from as a new group: rfork e.
@(private="file", require_results)
group_copy :: proc "contextless" (from: u32) -> (g: u32, st: vx.Status) {
	g = group_new()
	if g == GROUPS {
		return GROUPS, .Err_No_Memory
	}
	for &s in vars {
		if s.group != from + 1 {
			continue
		}
		x := var_new(g, string(s.name[:]))
		st = x != nil ? reserve(x, s.size) : .Err_No_Memory
		if st != .Ok {
			group_free(g)
			return GROUPS, st
		}
		copy(x.data, s.data[:s.size])
		x.size = s.size
	}
	return g, .Ok
}

// --- The file system ---

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if !server.shared.random.seeded {
		return 0, .Err_Unsupported // no tokens to give without entropy
	}
	g := u32(GROUPS)
	switch {
	case aname == "new":
		g = group_new()
		if g == GROUPS {
			st = .Err_No_Memory
		}
	case len(aname) > 0 && aname[0] == '+':
		from := group_by_token(aname[1:])
		if from == GROUPS {
			st = .Err_Not_Found
		} else {
			g, st = group_copy(from)
		}
	case:
		g = group_by_token(aname)
		if g == GROUPS {
			st = .Err_Not_Found
		}
	}
	if st != .Ok {
		return 0, st
	}
	return node_of(g, 0), .Ok
}

// A group's fids, counted: the last one gone, the group goes. A group made
// by an attach that no fid took (a failed attach) has none from the start.
@(private="file")
fs_fid_node :: proc "contextless" (ctx: rawptr, node: p9.Node, delta: int) {
	g := group_of(node)
	if g == nil {
		return
	}
	g.fids += delta
	if g.fids <= 0 {
		group_free(u32(intrinsics.ptr_sub(g, &groups[0])))
	}
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	if node_var(dir) != 0 || group_of(dir) == nil {
		return 0, .Err_Not_Found
	}
	g := node_group(dir) - 1
	x := var_named(g, name)
	if x == nil {
		return 0, .Err_Not_Found
	}
	return node_of(g, u32(intrinsics.ptr_sub(x, &vars[0])) + 1), .Ok
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	return node_of(node_group(node) - 1, 0), .Ok // the group's root
}

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	g := group_of(node)
	if g == nil {
		return .Err_Not_Found
	}
	if node_var(node) == 0 {
		out^ = {
			qid  = {type = p9.QTDIR, path = g.token}, // the token: how a process learns its group's
			mode = p9.DMDIR | 0o775,
			name = "/",
			uid  = "env",
			gid  = "env",
			muid = "env",
		}
		return .Ok
	}
	x := var_of(node)
	if x == nil {
		return .Err_Not_Found
	}
	out^ = {
		qid    = {type = p9.QTFILE, version = x.gen, path = u64(node)},
		mode   = 0o664,
		length = x.size,
		name   = string(x.name[:]),
		uid    = "env",
		gid    = "env",
		muid   = "env",
	}
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	if node_var(node) == 0 {
		return mode.access == .Read && group_of(node) != nil ? .Ok : .Err_Access
	}
	x := var_of(node)
	if x == nil {
		return .Err_Not_Found
	}
	if mode.trunc {
		x.size = 0 // a new value, as putenv writes it
	}
	return .Ok
}

@(private="file")
fs_create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	if node_var(dir) != 0 || group_of(dir) == nil {
		return 0, .Err_Not_Found
	}
	if perm & p9.DMDIR != 0 {
		return 0, .Err_Access // variables only
	}
	if len(name) == 0 || len(name) >= NAME_MAX {
		return 0, .Err_Invalid
	}
	for c in transmute([]u8)name {
		if c == '/' {
			return 0, .Err_Invalid
		}
	}
	g := node_group(dir) - 1
	x := var_named(g, name)
	if x != nil { // as 9front's devenv: creating one that exists empties it
		x.size = 0
	} else if x = var_new(g, name); x == nil {
		return 0, .Err_No_Memory
	}
	return node_of(g, u32(intrinsics.ptr_sub(x, &vars[0])) + 1), .Ok
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	x := var_of(node)
	if x == nil {
		return 0, .Err_Not_Found
	}
	if offset >= x.size {
		return 0, .Ok
	}
	return u32(copy(buf, x.data[offset:x.size])), .Ok
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	x := var_of(node)
	if x == nil {
		return 0, .Err_Access
	}
	end, overflow := intrinsics.overflow_add(offset, u64(len(data)))
	if overflow {
		return 0, .Err_Range
	}
	reserve(x, end) or_return
	if offset > x.size {
		intrinsics.mem_zero(&x.data[x.size], offset - x.size)
	}
	copy(x.data[offset:], data)
	x.size = max(x.size, end)
	return u32(len(data)), .Ok
}

@(private="file")
fs_remove :: proc "contextless" (ctx: rawptr, node: p9.Node) -> vx.Status {
	x := var_of(node)
	if x == nil {
		return node_var(node) != 0 ? .Err_Not_Found : .Err_Access // a group goes with its fids, not by name
	}
	var_free(x)
	return .Ok
}

@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	if node_var(dir) != 0 || group_of(dir) == nil {
		return 0, .Err_Not_Found
	}
	g := node_group(dir)
	left := index
	for &x, i in vars {
		if x.group != g {
			continue
		}
		if left == 0 {
			return node_of(g - 1, u32(i) + 1), .Ok
		}
		left -= 1
	}
	return 0, .Err_Not_Found
}

// Every process that starts a child or touches /env holds a connection for
// its life: far more than vx:p9ring's default 16 (the review of 2026-10-07).
@(private="file")
CONNS :: 128

@(private="file")
conns: [CONNS]p9ring.Server_Conn

@(private="file")
server := p9ring.Server {
	fs = {
		attach   = fs_attach,
		walk     = fs_walk,
		parent   = fs_parent,
		stat     = fs_stat,
		open     = fs_open,
		read     = fs_read,
		readdir  = fs_readdir,
		write    = fs_write,
		create   = fs_create,
		remove   = fs_remove,
		fid_node = fs_fid_node,
	},
	name = "envd",
	supported = {.Xattr},
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	server.listen = rt.spawn_take("listen")
	server.conns = conns[:]
	if server.listen == vx.HANDLE_NONE {
		rt.print("envd: no listen channel\n")
		return -1 // upstream's exit string: "no listen channel"
	}
	rt.print("envd: serving /srv/env\n")
	return int(p9ring.serve(&server))
}
