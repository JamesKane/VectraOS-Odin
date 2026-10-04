// ns.dial against a fake netd: a /net with cs, tcp/clone and conversations
// whose data file is a byte stream to another 9P server, as netd's TCP
// conversations are (upstream servers/netd/netd.c at M3 is the model: what
// cs answers, that opening clone moves the fid to N/ctl, that ctl reads as N
// and takes "connect ADDR!PORT", and that N/data beside the clone file takes
// part of a write and returns what has arrived). Upstream has no host test
// for dial.c; the M3 mount scenario covers it there.
//
//   /net/cs            write "tcp!10.0.2.2!5640": reads "/net/tcp/clone 10.0.2.2!5640\n"
//   /net/tcp/clone     opening it makes conversation N
//   /net/tcp/N/ctl     reads "N"; write "connect ADDR!PORT"
//   /net/tcp/N/data    a stream to a server with BOOT's tree
package ns_test

import "abi:vx"
import "core:testing"
import "vx:ns"
import "vx:p9"

CONVS :: 4

// What a stream takes or gives in one write or read: little enough that
// dial's framing has to loop.
STREAM_CHUNK :: 50

Conv :: struct {
	used:        bool,
	opens:       int, // open fids on its files; the conversation ends with the last
	connected:   [dynamic; 64]u8, // what ctl was asked to connect to
	to_remote:   [dynamic; 16384]u8, // request bytes not yet a whole message
	from_remote: [dynamic; 16384]u8, // reply bytes not yet read
	remote:      p9.Server,
	remote_tree: []Tnode,
}

Net :: struct {
	answer: string, // what cs answers this query, set by its write
	asked:  [dynamic; 64]u8, // the last query cs was written
	uname:  [dynamic; 16]u8, // the last Tattach's uname a remote server saw
	convs:  [CONVS]Conv,
	ended:  int, // conversations that ended
}

// Nodes: 1 the root, 2 cs, 3 tcp, 4 tcp/clone; conversation N's directory,
// ctl and data are 16 + 4N and the two after it.
NET_ROOT, NET_CS, NET_TCP, NET_CLONE :: p9.Node(1), p9.Node(2), p9.Node(3), p9.Node(4)

Conv_File :: enum {
	Dir,
	Ctl,
	Data,
}

conv_node :: proc "contextless" (n: int, f: Conv_File) -> p9.Node {
	return p9.Node(16 + 4 * n + int(f))
}

conv_of :: proc "contextless" (node: p9.Node) -> (n: int, f: Conv_File, ok: bool) {
	if node < 16 || node >= 16 + 4 * CONVS || (node - 16) % 4 > 2 {
		return 0, .Dir, false
	}
	return int(node - 16) / 4, Conv_File((node - 16) % 4), true
}

net_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	return NET_ROOT, .Ok
}

net_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	net := (^Net)(ctx)
	switch {
	case dir == NET_ROOT && name == "cs":
		return NET_CS, .Ok
	case dir == NET_ROOT && name == "tcp":
		return NET_TCP, .Ok
	case dir == NET_TCP && name == "clone":
		return NET_CLONE, .Ok
	case dir == NET_TCP && len(name) == 1 && name[0] >= '0' && int(name[0] - '0') < CONVS:
		n := int(name[0] - '0')
		if net.convs[n].used {
			return conv_node(n, .Dir), .Ok
		}
	}
	if n, f, ok := conv_of(dir); ok && f == .Dir {
		switch name {
		case "ctl":
			return conv_node(n, .Ctl), .Ok
		case "data":
			return conv_node(n, .Data), .Ok
		}
	}
	return 0, .Err_Not_Found
}

net_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	switch node {
	case NET_CS, NET_TCP:
		return NET_ROOT, .Ok
	case NET_CLONE:
		return NET_TCP, .Ok
	}
	n, f, _ := conv_of(node)
	return f == .Dir ? NET_TCP : conv_node(n, .Dir), .Ok
}

CONV_NAMES := [Conv_File]string {
	.Dir  = "",
	.Ctl  = "ctl",
	.Data = "data",
}
DIGITS := [CONVS]string{"0", "1", "2", "3"}

net_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	dir := node == NET_ROOT || node == NET_TCP
	name: string
	switch node {
	case NET_ROOT:
		name = "/"
	case NET_CS:
		name = "cs"
	case NET_TCP:
		name = "tcp"
	case NET_CLONE:
		name = "clone"
	case:
		n, f, ok := conv_of(node)
		if !ok {
			return .Err_Not_Found
		}
		dir = f == .Dir
		name = dir ? DIGITS[n] : CONV_NAMES[f]
	}
	out^ = {
		qid = {dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = dir ? p9.DMDIR | 0o555 : 0o666,
		name = name,
	}
	return .Ok
}

net_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	net := (^Net)(ctx)
	if n, f, ok := conv_of(node); ok && f != .Dir {
		net.convs[n].opens += 1
	}
	return .Ok
}

// Opening clone makes a conversation, and the fid moves to its ctl.
net_clone :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> (opened: p9.Node, st: vx.Status) {
	net := (^Net)(ctx)
	if node != NET_CLONE {
		return 0, .Err_Not_Found
	}
	for &cv, n in net.convs {
		if !cv.used {
			cv.used, cv.opens = true, 1
			clear(&cv.connected)
			clear(&cv.to_remote)
			clear(&cv.from_remote)
			cv.remote_tree = BOOT[:]
			make_server(&cv.remote, &cv.remote_tree)
			return conv_node(n, .Ctl), .Ok
		}
	}
	return 0, .Err_No_Memory
}

net_clunk :: proc "contextless" (ctx: rawptr, node: p9.Node, opened: bool) {
	net := (^Net)(ctx)
	n, f, ok := conv_of(node)
	if !ok || f == .Dir || !opened {
		return
	}
	cv := &net.convs[n]
	cv.opens -= 1
	if cv.opens == 0 {
		p9.hang_up(&cv.remote)
		cv.used = false
		net.ended += 1
	}
}

net_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	net := (^Net)(ctx)
	if node == NET_CS {
		if offset >= u64(len(net.answer)) {
			return 0, .Ok
		}
		return u32(copy(buf, net.answer[offset:])), .Ok
	}
	n, f, _ := conv_of(node)
	cv := &net.convs[n]
	#partial switch f {
	case .Ctl:
		return offset == 0 ? u32(copy(buf, DIGITS[n])) : 0, .Ok
	case .Data: // what has arrived, a chunk at a time
		got := copy(buf[:min(len(buf), STREAM_CHUNK)], cv.from_remote[:])
		copy(cv.from_remote[:], cv.from_remote[got:])
		resize(&cv.from_remote, len(cv.from_remote) - got)
		return u32(got), .Ok
	}
	return 0, .Err_Access
}

net_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	net := (^Net)(ctx)
	if node == NET_CS {
		clear(&net.asked)
		_ = append(&net.asked, string(data))
		if string(data) != "tcp!10.0.2.2!5640" {
			return 0, .Err_Not_Found // no such host
		}
		net.answer = "/net/tcp/clone 10.0.2.2!5640\n"
		return u32(len(data)), .Ok
	}
	n, f, _ := conv_of(node)
	cv := &net.convs[n]
	#partial switch f {
	case .Ctl:
		CONNECT :: "connect "
		if len(data) <= len(CONNECT) || string(data[:len(CONNECT)]) != CONNECT {
			return 0, .Err_Invalid
		}
		clear(&cv.connected)
		_ = append(&cv.connected, string(data[len(CONNECT):]))
		return u32(len(data)), .Ok
	case .Data: // part of it, then each whole message is served
		taken := append(&cv.to_remote, ..data[:min(len(data), STREAM_CHUNK)])
		for len(cv.to_remote) >= 4 {
			size := int(cv.to_remote[0]) | int(cv.to_remote[1]) << 8 | int(cv.to_remote[2]) << 16 | int(cv.to_remote[3]) << 24
			if len(cv.to_remote) < size {
				break
			}
			req := cv.to_remote[:size]
			m: p9.Msg
			if p9.decode(req, &m) == .Ok && m.type == .Tattach {
				clear(&net.uname)
				_ = append(&net.uname, m.uname)
			}
			resp: [8192]u8
			rn, res := p9.serve(&cv.remote, req, resp[:])
			if res == .Reply {
				_ = append(&cv.from_remote, ..resp[:rn])
			}
			copy(cv.to_remote[:], cv.to_remote[size:])
			resize(&cv.to_remote, len(cv.to_remote) - size)
		}
		return u32(taken), .Ok
	}
	return 0, .Err_Access
}

net_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	return 0, .Err_Not_Found
}

net_server :: proc(s: ^p9.Server, net: ^Net) {
	s^ = {
		fs = {
			ctx = net,
			attach = net_attach,
			walk = net_walk,
			parent = net_parent,
			stat = net_stat,
			open = net_open,
			clone = net_clone,
			read = net_read,
			readdir = net_readdir,
			write = net_write,
			clunk = net_clunk,
		},
		max_msize = 8192,
	}
}

release_dialed :: proc "contextless" (c: ^p9.Client, connector: vx.Handle) {
	_ = ns.dial_release(c)
}

@(test)
test_dial :: proc(t: ^testing.T) {
	space := new(ns.Namespace)
	defer free(space)
	fx := fixture(t)
	defer free(fx)
	net := new(Net)
	defer free(net)
	net_srv := new(p9.Server)
	defer free(net_srv)
	net_server(net_srv, net)
	bufs := new([2][8192]u8)
	defer free(bufs)
	net_c: p9.Client
	connect(t, &net_c, net_srv, bufs[0][:], bufs[1][:])
	space.release = release_dialed

	// /net is a new name in /, which is enough for a mount (as mntgen gives /n/host).
	testing.expect_value(t, ns.mount(space, &fx.boot_c, vx.HANDLE_NONE, "/srv/bootfs", "", "/", {}), vx.Status.Ok)
	testing.expect_value(t, ns.mount(space, &net_c, vx.HANDLE_NONE, "/srv/net", "", "/net", {}), vx.Status.Ok)
	testing.expect_value(t, ns.mount(space, &net_c, vx.HANDLE_NONE, "/srv/net", "", "/none/net", {}), vx.Status.Err_Not_Found) // /none is not there
	testing.expect_value(t, ns.bind(space, "/net", "/elsewhere", {.After}), vx.Status.Err_Not_Found) // a union needs what it joins

	c, src, st := ns.dial(space, "tcp!10.0.2.2!5640")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, src, "tcp!10.0.2.2!5640")
	testing.expect_value(t, string(net.asked[:]), "tcp!10.0.2.2!5640")
	testing.expect(t, net.convs[0].used)
	testing.expect_value(t, string(net.convs[0].connected[:]), "10.0.2.2!5640")
	testing.expect_value(t, c.msize, 8192) // the remote's, below DIAL_MSIZE
	testing.expect_value(t, c.extensions, p9.Extensions{}) // asked for none: they are for rings
	testing.expect_value(t, ns.mount(space, c, vx.HANDLE_NONE, src, "", "/n", {}), vx.Status.Ok)
	testing.expect_value(t, string(net.uname[:]), "vectra")
	testing.expect_value(t, list(space, "/n"), "bin boot dev readme")
	f: ns.File
	text: [16]u8
	testing.expect_value(t, ns.open(space, "/n/readme", p9.OREAD, &f), vx.Status.Ok)
	n, e := ns.read_all(&f, text[:])
	ns.close(&f)
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, string(text[:n]), "hello")

	// The same address, either way it is written, shares the connection.
	c2, src2, st2 := ns.dial(space, "9p://10.0.2.2:5640")
	testing.expect_value(t, st2, vx.Status.Ok)
	testing.expect(t, c2 == c)
	testing.expect_value(t, src2, "tcp!10.0.2.2!5640")
	testing.expect(t, !net.convs[1].used)
	script: [512]u8
	length := ns.print(space, script[:])
	testing.expect_value(t, string(script[:length]), "mount /srv/bootfs /\nmount /srv/net /net\nmount tcp!10.0.2.2!5640 /n\n")

	// Addresses that cannot be dialed.
	Case :: struct {
		addr: string,
		want: vx.Status,
	}
	cases := []Case {
		{"9p://10.0.2.2", .Err_Invalid}, // no port
		{"9p://:5640", .Err_Invalid}, // no host
		{"9p://10.0.2.2:", .Err_Invalid},
		{"", .Err_Invalid},
		{"tcp!nowhere!564", .Err_Not_Found}, // cs knows no such host
		{"9p://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:1", .Err_Invalid}, // too long as tcp!...
	}
	for k in cases {
		_, _, got := ns.dial(space, k.addr)
		testing.expectf(t, got == k.want, "dial(%q) is %v, want %v", k.addr, got, k.want)
	}
	testing.expect_value(t, string(net.asked[:]), "tcp!nowhere!564")

	// Unmounting its last mount lets the connection go: the conversation
	// ends, and the next dial makes a new one.
	testing.expect_value(t, ns.unmount(space, "", "/n"), vx.Status.Ok)
	testing.expect_value(t, net.ended, 1)
	testing.expect(t, !net.convs[0].used)
	c, src, st = ns.dial(space, "9p://10.0.2.2:5640")
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect(t, net.convs[0].used)
	testing.expect_value(t, ns.mount(space, c, vx.HANDLE_NONE, src, "", "/n", {}), vx.Status.Ok)
	testing.expect_value(t, ns.unmount(space, "", "/n"), vx.Status.Ok)
	testing.expect_value(t, net.ended, 2)
}
