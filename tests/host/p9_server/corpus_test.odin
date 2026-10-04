// Upstream's p9_server fuzzer (tests/fuzz/p9_server_fuzz.c) over its corpus
// (tests/fuzz/corpus/p9_server), and over every truncation of each session:
// each message, framed by its own size[4], goes to serve on a fresh server
// over a small read-only tree. Every reply must decode and answer the same
// tag, and no walk may reach a node outside the attach root: while every
// attach in the session is at "docs", nodes 1 and 4 must stay out of reach,
// and the framework must never ask for the parent of /docs.
package p9_server_test

import vx "abi:vx"
import "core:testing"
import "vx:p9"

CORPUS := #load_directory("corpus")

//   1 /   2 /docs   3 /docs/a.txt   4 /b.txt   5 /docs/sub
Fuzz_Node :: struct {
	parent: p9.Node,
	name:   string,
	dir:    bool,
}

@(rodata)
FUZZ_TREE := [6]Fuzz_Node{{0, "", false}, {0, "/", true}, {1, "docs", true}, {2, "a.txt", false}, {1, "b.txt", false}, {2, "sub", true}}

Fuzz :: struct {
	attached_whole: bool, // some fid was attached at /
	escapes:        int, // asks the framework should never have made
}

fuzz_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	root = len(aname) > 0 ? 2 : 1
	if root == 1 {
		(^Fuzz)(ctx).attached_whole = true
	}
	return root, .Ok
}

fuzz_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	for n, i in FUZZ_TREE[1:] {
		if n.parent == dir && n.name == name {
			return p9.Node(i + 1), .Ok
		}
	}
	return 0, .Err_Not_Found
}

fuzz_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	f := (^Fuzz)(ctx)
	if node == 2 && !f.attached_whole {
		f.escapes += 1 // the framework must never ask past the root
	}
	if FUZZ_TREE[node].parent == 0 {
		return 0, .Err_Not_Found
	}
	return FUZZ_TREE[node].parent, .Ok
}

fuzz_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	f := (^Fuzz)(ctx)
	if !f.attached_whole && (node == 1 || node == 4) {
		f.escapes += 1 // escaped the root
	}
	n := FUZZ_TREE[node]
	out^ = {
		qid = {n.dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = n.dir ? p9.DMDIR | 0o755 : 0o644,
		length = n.dir ? 0 : 5,
		name = n.name,
	}
	return .Ok
}

fuzz_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	return mode.access == .Read ? .Ok : .Err_Access
}

fuzz_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	n := offset >= 5 ? 0 : 5 - int(offset)
	n = min(n, len(buf))
	for &b in buf[:n] {
		b = 'x'
	}
	return u32(n), .Ok
}

fuzz_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	k := index
	for n, i in FUZZ_TREE[1:] {
		if n.parent != dir {
			continue
		}
		if k == 0 {
			return p9.Node(i + 1), .Ok
		}
		k -= 1
	}
	return 0, .Err_Not_Found
}

@(private="file")
p9_server_fuzz :: proc(t: ^testing.T, name: string, data: []u8) -> (served: int) {
	f: Fuzz
	s := new(p9.Server, context.temp_allocator)
	s^ = {
		fs = {
			ctx = &f,
			attach = fuzz_attach,
			walk = fuzz_walk,
			parent = fuzz_parent,
			stat = fuzz_stat,
			open = fuzz_open,
			read = fuzz_read,
			readdir = fuzz_readdir,
		},
		max_msize = 8192,
		supported = {.Dref},
	}
	resp: [8192]u8
	for pos := 0; len(data) - pos >= 4; {
		n := int(data[pos]) | int(data[pos + 1]) << 8 | int(data[pos + 2]) << 16 | int(data[pos + 3]) << 24
		if n < 4 || n > len(data) - pos {
			break
		}
		rn, res := p9.serve(s, data[pos:][:n], resp[:])
		if res == .Reply {
			r: p9.Msg
			testing.expectf(t, p9.decode(resp[:rn], &r) == .Ok, "%s: a reply at %d does not decode", name, pos)
			testing.expectf(t, r.tag == u16(data[pos + 5]) | u16(data[pos + 6]) << 8, "%s: the reply at %d has tag %d", name, pos, r.tag)
			served += 1
		}
		pos += n
	}
	testing.expectf(t, f.escapes == 0, "%s: %d asks outside the root", name, f.escapes)
	return
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	testing.expect_value(t, len(CORPUS), 2)
	for file in CORPUS {
		testing.expectf(t, p9_server_fuzz(t, file.name, file.data) > 0, "%s: nothing served", file.name)
		for cut in 0 ..< len(file.data) {
			_ = p9_server_fuzz(t, file.name, file.data[:cut])
		}
	}
}
