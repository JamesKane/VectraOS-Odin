// lib/procns's namespace groups (upstream ADR-0009) on the host, linked
// against lib/rt with a fake kernel underneath: this file defines
// vx_syscall, and plays nsd on the channels the group protocol uses (as
// upstream's servers/nsd keeps a group: its text in a page each member maps,
// after a sequence that is odd while it writes). Upstream has no host test
// for its spawn.c; this checks its protocol as upstream's nsd.h defines it:
// a group made at the first spawn that shares it, a change published from the
// sequence it was made on, a stale change made again after catching up, the
// table rebuilt when another member changes the group, a line that cannot be
// replayed said and skipped, a copy of the records without nsd, and a fork's
// own channel. The namespace's connection is a loopback p9 client.
//
// The group state is the library's own global, so this is one test.
package procns_test

import vx "abi:vx"
import "core:strings"
import "core:testing"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "../p9test"

SRV :: vx.Handle(0x301) // nsd's post
VMO :: vx.Handle(0x302)
CONN_A :: vx.Handle(0x303) // /srv/a's connector, which the test's mount names
CONN_B :: vx.Handle(0x304) // /srv/b's, which nsd hands out and nothing answers
CHAN_FIRST :: vx.Handle(0x400) // member channels, from here up
DUP_FIRST :: vx.Handle(0x800) // duplicates, from here up

// --- The tree /srv/a serves: / {d/ {f}, e/, x/ {y}} ---

Node :: struct {
	parent: p9.Node,
	name:   string,
	dir:    bool,
}

@(rodata)
TREE := [?]Node{{}, {0, "/", true}, {1, "d", true}, {2, "f", false}, {1, "e", true}, {1, "x", true}, {5, "y", false}}

t_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	return 1, .Ok
}

t_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	for n, i in TREE[2:] {
		if n.parent == dir && n.name == name {
			return p9.Node(i + 2), .Ok
		}
	}
	return 0, .Err_Not_Found
}

t_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	return max(TREE[node].parent, 1), .Ok
}

t_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	n := TREE[node]
	out^ = {
		qid = {n.dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = n.dir ? p9.DMDIR | 0o555 : 0o444,
		name = n.name,
	}
	return .Ok
}

t_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	return .Ok
}

t_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	return 0, .Ok
}

t_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	return 0, .Err_Not_Found
}

// --- nsd, played by the fake kernel ---

Nsd :: struct {
	page:          ns.Nsd_Page, // what members map
	calls:         [dynamic; 64]ns.Nsd_Call,
	names:         [256]u8, // NEW's and UPDATE's connector names
	names_len:     int,
	given:         int, // connectors given with NEW and UPDATE
	next_chan:     vx.Handle,
	next_dup:      vx.Handle,
	other_text:    string, // set: another member changes the group just before the next UPDATE
	unmapped:      bool,
	log:           strings.Builder,
}

nsd: Nsd

// What nsd publishes: the text, written while the sequence is odd.
nsd_write :: proc "contextless" (text: string) {
	nsd.page.seq += 1
	nsd.page.len = u32(copy(nsd.page.text[:], text))
	nsd.page.seq += 1
}

nsd_text :: proc() -> string {
	return string(nsd.page.text[:nsd.page.len])
}

nsd_call :: proc "contextless" (c: ^vx.Call) -> vx.Status {
	req := (^ns.Nsd_Msg)(c.wr_bytes)
	body := ([^]u8)(c.wr_bytes)[size_of(ns.Nsd_Msg):c.wr_len]
	text := string(body[:req.args.text_len])
	names := body[req.args.text_len:]
	rep := (^ns.Nsd_Msg)(c.rd_bytes)
	rep^ = {}
	c.actual = {bytes = size_of(ns.Nsd_Msg)}
	call := ns.Nsd_Call(req.header.ordinal)
	_ = append(&nsd.calls, call)
	give :: proc "contextless" (c: ^vx.Call, h: vx.Handle) {
		c.rd_handles[c.actual.handles] = h
		c.actual.handles += 1
	}
	switch call {
	case .New:
		nsd_write(text)
		nsd.names_len += copy(nsd.names[nsd.names_len:], names)
		nsd.given += int(c.wr_count)
		give(c, nsd.next_chan)
		nsd.next_chan += 1
		give(c, VMO)
		rep.args.seq = nsd.page.seq
	case .Share:
		give(c, nsd.next_chan)
		nsd.next_chan += 1
	case .Hello:
		give(c, VMO)
	case .Update:
		if nsd.other_text != "" {
			nsd_write(nsd.other_text) // another member was first
			nsd.other_text = ""
		}
		if req.args.seq != nsd.page.seq {
			rep.header.flags = transmute(u32)i32(vx.Status.Err_Bad_State) // stale
			break
		}
		nsd_write(text)
		nsd.names_len += copy(nsd.names[nsd.names_len:], names)
		nsd.given += int(c.wr_count)
		rep.args.seq = nsd.page.seq
	case .Connector:
		give(c, text == "/srv/b" ? CONN_B : vx.HANDLE_NONE)
	case .Text:
		rep.header.flags = transmute(u32)i32(vx.Status.Err_Not_Found)
	}
	return .Ok
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	return 0
}

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Channel_Call:
		h := vx.Handle(a0)
		if h == SRV || h >= CHAN_FIRST && h < DUP_FIRST {
			return i64(nsd_call((^vx.Call)(uintptr(a1))))
		}
		return i64(vx.Status.Err_Peer_Closed) // a connector nothing answers
	case .As_Map:
		if vx.Handle(a1) != VMO || a4 != 0 { // read-only
			return i64(vx.Status.Err_Access)
		}
		(^u64)(uintptr(a5))^ = u64(uintptr(&nsd.page))
		return 0
	case .As_Unmap:
		nsd.unmapped = a1 == u64(uintptr(&nsd.page))
		return 0
	case .Handle_Dup:
		(^vx.Handle)(uintptr(a2))^ = nsd.next_dup
		nsd.next_dup += 1
		return 0
	case .Handle_Close:
		return 0
	case .Task_Info:
		(^vx.Task_Summary)(uintptr(a1)).id = 42
		return 0
	}
	return i64(vx.Status.Err_Unsupported)
}

log_hook :: proc "contextless" (s: string) {
	context = {}
	strings.write_string(&nsd.log, s)
}

Fixture :: struct {
	srv:        p9.Server,
	tbuf, rbuf: [8192]u8,
	c:          p9.Client,
	space:      ns.Namespace,
}

exists :: proc(space: ^ns.Namespace, path: string) -> bool {
	c, fid, e := ns.walk(space, path)
	if e != .Ok {
		return false
	}
	_ = p9.client_clunk(c, fid)
	return true
}

@(test)
test_groups :: proc(t: ^testing.T) {
	nsd = {
		next_chan = CHAN_FIRST,
		next_dup  = DUP_FIRST,
	}
	strings.builder_init(&nsd.log)
	defer strings.builder_destroy(&nsd.log)
	rt.print_hook = log_hook
	defer rt.print_hook = nil
	rt.self = vx.Handle(0x101)
	fx := new(Fixture)
	defer free(fx)
	fx.srv = {
		fs = {attach = t_attach, walk = t_walk, parent = t_parent, stat = t_stat, open = t_open, read = t_read, readdir = t_readdir},
		max_msize = 8192,
	}
	fx.c = {
		rpc  = p9test.loopback,
		ctx  = &fx.srv,
		tbuf = fx.tbuf[:],
		rbuf = fx.rbuf[:],
	}
	testing.expect_value(t, p9.client_version(&fx.c, 8192, {}), vx.Status.Ok)
	space := &fx.space

	// No nsd in the spawn message: a namespace of its own, and a child gets
	// a copy, as records.
	testing.expect_value(t, procns.from_spawn(space), vx.Status.Ok)
	testing.expect_value(t, ns.mount(space, &fx.c, CONN_A, "/srv/a", "", "/", {}), vx.Status.Ok)
	testing.expect_value(t, ns.bind(space, "/d", "/e", {}), vx.Status.Ok)
	handles: [8]vx.Handle
	names: [8]string
	buf: [1024]u8
	w := ndb.Writer {
		buf = buf[:],
	}
	count, st := procns.spawn_records(space, &w, handles[:], names[:], 0)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, count, 1)
	testing.expect_value(t, names[0], "ns.00")
	testing.expect_value(t, string(buf[:w.len]), "mount=/ handle=ns.00 src=/srv/a\nbind=/e new=/d\n")
	testing.expect_value(t, len(nsd.calls), 0)

	// With nsd: the first child that shares makes the group, from the table's
	// text and its connector, and gets a channel for it, and nsd's post.
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "srv:nsd", SRV
	rt.spawn.handle_count = 1
	testing.expect_value(t, procns.from_spawn(space), vx.Status.Ok)
	w = {
		buf = buf[:],
	}
	count, st = procns.spawn_records(space, &w, handles[:], names[:], 0)
	testing.expect_value(t, st, vx.Status.Ok)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, names[0], "nsgroup")
	testing.expect_value(t, handles[0], CHAN_FIRST + 1)
	testing.expect_value(t, names[1], "srv:nsd")
	testing.expect_value(t, w.len, 0) // no records: the group says it all
	text: [1024]u8
	testing.expect_value(t, nsd_text(), string(text[:ns.print(space, text[:])]))
	testing.expect_value(t, string(nsd.names[:nsd.names_len]), "/srv/a\n")
	testing.expect_value(t, nsd.given, 1)

	// A change is published, from the sequence the table was built on.
	testing.expect_value(t, ns.bind(space, "/x", "/e", {.After}), vx.Status.Ok)
	testing.expect_value(t, nsd_text(), "mount /srv/a /\nbind /d /e\nbind -a /x /e\n")
	testing.expect(t, exists(space, "/e/y"))

	// Another member changes the group: the table is built again from its
	// text before the next name is resolved.
	nsd_write("mount /srv/a /\nbind /x /d\n")
	testing.expect(t, exists(space, "/d/y"))
	testing.expect(t, !exists(space, "/d/f"))
	testing.expect(t, !exists(space, "/e/y"))

	// A change made while another member was first is stale: made again,
	// after catching up, so both changes are kept.
	nsd.other_text = "mount /srv/a /\nbind /x /d\nbind /d /e\n"
	updates := 0
	for c in nsd.calls {
		updates += int(c == .Update)
	}
	testing.expect_value(t, ns.unmount(space, "", "/d"), vx.Status.Ok)
	after := 0
	for c in nsd.calls {
		after += int(c == .Update)
	}
	testing.expect_value(t, after - updates, 2) // stale once, then taken
	testing.expect_value(t, nsd_text(), "mount /srv/a /\nbind /d /e\n")
	testing.expect(t, exists(space, "/e/y")) // /e was bound to what /d showed: /x
	testing.expect(t, exists(space, "/d/f")) // /d itself is bootfs's again

	// A line that cannot be replayed is said, and the rest replayed: /srv/b's
	// connector comes from nsd, and nothing answers it.
	nsd_write("mount /srv/a /\nmount /srv/b /e\nbind /x /d\n")
	testing.expect(t, exists(space, "/d/y"))
	testing.expect_value(t, strings.to_string(nsd.log), "vx-ns: cannot replay line 2 of the namespace group's: i/o on hungup channel\n")

	// After a fork, the child has a channel of its own, maps the text again,
	// and builds its table from it.
	shares := 0
	for c in nsd.calls {
		shares += int(c == .Share)
	}
	testing.expect_value(t, procns.after_fork(space), vx.Status.Ok)
	testing.expect(t, nsd.unmapped)
	after = 0
	for c in nsd.calls {
		after += int(c == .Share)
	}
	testing.expect_value(t, after - shares, 1)
	testing.expect_value(t, nsd.calls[len(nsd.calls) - 1], ns.Nsd_Call.Connector) // /srv/a, over a new connection
}
