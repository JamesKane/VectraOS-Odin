package distd_test

import vx "abi:vx"
import "vx:p9"

// What distd's namespace holds in these tests: one writable file server in
// memory, mounted at /, with the store branch at /n, the ESP at /tmp and
// fsd's adm branch at /adm, whose ctl file keeps every command written to
// it. Its callbacks are contextless, as p9.Fs needs, so file bytes come from
// a fixed arena and are never given back (a test's worth).

MEM_NODES :: 4096
ARENA :: 32 << 20

Mem_Node :: struct {
	used:   bool,
	parent: int,
	name:   string, // into the arena
	dir:    bool,
	data:   []u8, // the file's bytes
	room:   int, // what the arena gave, from data's start
	ctl:    bool, // the adm ctl: writes are commands, kept in ctl_log
}

mem_nodes: [MEM_NODES]Mem_Node
arena: [ARENA]u8
arena_used: int
ctl_log: [dynamic; 64]string
ctl_status: vx.Status // what a ctl write answers

arena_take :: proc "contextless" (n: int) -> []u8 {
	if arena_used + n > ARENA {
		return nil
	}
	b := arena[arena_used:][:n]
	arena_used += n
	return b
}

arena_string :: proc "contextless" (s: string) -> string {
	b := arena_take(len(s))
	copy(b, s)
	return string(b)
}

mem_reset :: proc() {
	mem_nodes = {}
	arena_used = 0
	clear(&ctl_log)
	ctl_status = .Ok
	mem_nodes[1] = {used = true, dir = true, name = "/"}
}

// The node at a path from the root ("n/b2/9f"), made with its directories
// if make is set; 0 if there is none.
mem_lookup :: proc "contextless" (path: string, make := false, dir := false) -> int {
	at := 1
	rest := path
	for len(rest) > 0 {
		slash := 0
		for slash < len(rest) && rest[slash] != '/' {
			slash += 1
		}
		name := rest[:slash]
		rest = rest[min(slash + 1, len(rest)):]
		next := mem_child(at, name)
		if next == 0 {
			if !make {
				return 0
			}
			next = mem_new(at, name, len(rest) > 0 || dir)
			if next == 0 {
				return 0
			}
		}
		at = next
	}
	return at
}

mem_child :: proc "contextless" (dir: int, name: string) -> int {
	for &n, i in mem_nodes {
		if n.used && i > 1 && n.parent == dir && n.name == name {
			return i
		}
	}
	return 0
}

mem_new :: proc "contextless" (parent: int, name: string, dir: bool) -> int {
	for &n, i in mem_nodes {
		if i > 1 && !n.used {
			n = {used = true, parent = parent, name = arena_string(name), dir = dir}
			return i
		}
	}
	return 0
}

// A file's bytes set whole, the file made if need be.
mem_put :: proc "contextless" (path: string, data: []u8) -> int {
	i := mem_lookup(path, true)
	b := arena_take(len(data))
	copy(b, data)
	mem_nodes[i].data, mem_nodes[i].room = b, len(b)
	return i
}

mem_get :: proc "contextless" (path: string) -> (data: []u8, ok: bool) {
	i := mem_lookup(path)
	if i == 0 || mem_nodes[i].dir {
		return nil, false
	}
	return mem_nodes[i].data, true
}

@(private="file")
node_index :: proc "contextless" (n: p9.Node) -> int {
	i := int(n)
	return i > 0 && i < MEM_NODES && mem_nodes[i].used ? i : 0
}

@(private="file")
m_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	return 1, .Ok
}

@(private="file")
m_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	d := node_index(dir)
	if d == 0 || !mem_nodes[d].dir {
		return 0, .Err_Not_Found
	}
	c := mem_child(d, name)
	return p9.Node(c), c != 0 ? .Ok : .Err_Not_Found
}

@(private="file")
m_parent :: proc "contextless" (ctx: rawptr, n: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	i := node_index(n)
	return p9.Node(i > 1 ? mem_nodes[i].parent : 1), .Ok
}

@(private="file")
m_stat :: proc "contextless" (ctx: rawptr, n: p9.Node, out: ^p9.Stat) -> vx.Status {
	i := node_index(n)
	if i == 0 {
		return .Err_Not_Found
	}
	m := &mem_nodes[i]
	out^ = {
		qid    = {type = m.dir ? p9.QTDIR : p9.QTFILE, path = u64(i)},
		mode   = m.dir ? p9.DMDIR | 0o755 : 0o644,
		length = u64(len(m.data)),
		name   = m.name,
		uid    = "adm",
		gid    = "adm",
		muid   = "adm",
	}
	return .Ok
}

@(private="file")
m_open :: proc "contextless" (ctx: rawptr, n: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	i := node_index(n)
	if i == 0 {
		return .Err_Not_Found
	}
	if mode.trunc && !mem_nodes[i].dir {
		mem_nodes[i].data = mem_nodes[i].data[:0]
	}
	return .Ok
}

@(private="file")
m_read :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	d := mem_nodes[node_index(n)].data
	if offset >= u64(len(d)) {
		return 0, .Ok
	}
	return u32(copy(buf, d[offset:])), .Ok
}

@(private="file")
m_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	d := node_index(dir)
	k: u32
	for &m, i in mem_nodes {
		if m.used && i > 1 && m.parent == d {
			if k == index {
				return p9.Node(i), .Ok
			}
			k += 1
		}
	}
	return 0, .Err_Not_Found
}

@(private="file")
m_write :: proc "contextless" (ctx: rawptr, n: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	i := node_index(n)
	m := &mem_nodes[i]
	if m.ctl {
		if ctl_status == .Ok {
			_ = append(&ctl_log, arena_string(string(data)))
		}
		return u32(len(data)), ctl_status
	}
	end := int(offset) + len(data)
	if end > m.room {
		grown := arena_take(max(end, 2 * m.room))
		if grown == nil {
			return 0, .Err_No_Space
		}
		copy(grown, m.data)
		m.data, m.room = grown[:len(m.data)], len(grown)
	}
	if end > len(m.data) {
		m.data = ([^]u8)(raw_data(m.data))[:end]
	}
	copy(m.data[offset:], data)
	return u32(len(data)), .Ok
}

@(private="file")
m_create :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string, perm: u32, mode: p9.Open_Mode) -> (node: p9.Node, st: vx.Status) {
	d := node_index(dir)
	if d == 0 || !mem_nodes[d].dir {
		return 0, .Err_Not_Found
	}
	if mem_child(d, name) != 0 {
		return 0, .Err_Exists
	}
	i := mem_new(d, name, perm & p9.DMDIR != 0)
	return p9.Node(i), i != 0 ? .Ok : .Err_No_Space
}

mem_fs :: p9.Fs {
	attach  = m_attach,
	walk    = m_walk,
	parent  = m_parent,
	stat    = m_stat,
	open    = m_open,
	read    = m_read,
	readdir = m_readdir,
	write   = m_write,
	create  = m_create,
}
