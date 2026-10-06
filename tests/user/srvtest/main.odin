// srvtest: /srv as a file tree (upstream's M6 step 6d4d2a), run in the srv
// scenario (tests/qemu/m6/srv.ndb) with the POSIX template's /srv (srvfs): a
// manifest's post listed and opened for a connector that works; a post made,
// opened by its owner and refused to another user, written twice, removed; a
// name taken twice; an entry not posted yet; a post with ORCLOSE gone with
// its maker's fid. Each check prints a line only when it fails; the last
// line counts them. The checks are upstream's, some of several conditions,
// so the count is too.
package srvtest

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if !ok {
		failures += 1
		rt.print("srvtest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

space: ns.Namespace
dir_buf: [4096]u8

// Whether /srv lists name, and its mode and owner if so (the owner in buf).
listed :: proc "contextless" (name: string, buf: []u8) -> (found: bool, mode: u32, owner: string) {
	d: ns.File
	if ns.open(&space, "/srv", p9.OREAD, &d) != .Ok {
		return
	}
	defer ns.close(&d)
	for !found {
		n, st := ns.read(&d, dir_buf[:])
		if st != .Ok || n <= 0 {
			break
		}
		it := p9.Dir_Entries {
			buf = dir_buf[:n],
		}
		for e in p9.next_entry(&it) {
			if e.name == name {
				found, mode = true, e.mode
				owner = string(buf[:copy(buf, e.uid)])
				break
			}
		}
	}
	return
}

is_listed :: proc "contextless" (name: string) -> bool {
	buf: [32]u8
	found, _, _ := listed(name, buf[:])
	return found
}

listed_as :: proc "contextless" (name: string, mode: u32, owner: string) -> bool {
	buf: [32]u8
	found, m, o := listed(name, buf[:])
	return found && m & 0o777 == mode && o == owner
}

// A connector from opening /srv/name on connection c, as the user it
// attached as.
open_post :: proc "contextless" (c: ^p9.Client, root: p9.Fid, name: string) -> (h: vx.Handle, st: vx.Status) {
	fid := p9.client_walk(c, root, name) or_return
	h, st = p9.client_open_handle(c, fid, p9.ORDWR)
	_ = p9.client_clunk(c, fid)
	return
}

// A new post, made (not yet written) in the directory: its fid, open for
// writing.
make_post :: proc "contextless" (c: ^p9.Client, root: p9.Fid, name: string, perm: u32, mode: p9.Open_Mode) -> (fid: p9.Fid, st: vx.Status) {
	fid = p9.client_walk(c, root, "") or_return
	st = p9.client_create(c, fid, name, perm, mode)
	return
}

// h duplicated, and written beside a message to fid.
post_dup :: proc "contextless" (c: ^p9.Client, fid: p9.Fid, h: vx.Handle) -> vx.Status {
	dup := rt.handle_dup(h, vx.RIGHTS_SAME) or_return
	return rt.p9_write_handle(c, fid, dup)
}

// Removing name, on connection c.
remove :: proc "contextless" (c: ^p9.Client, root: p9.Fid, name: string) -> vx.Status {
	fid := p9.client_walk(c, root, name) or_return
	return p9.client_remove(c, fid)
}

// zero, read through connector, reads as zeros.
zeros_through :: proc "contextless" (connector: vx.Handle) -> bool {
	@(static) nc: rt.Conn
	if rt.p9_connect(connector, &nc) != .Ok {
		return false
	}
	defer rt.p9_disconnect(&nc)
	root, ast := p9.client_attach(&nc.c, "")
	if ast != .Ok {
		return false
	}
	zero, wst := p9.client_walk(&nc.c, root, "zero")
	if wst != .Ok || p9.client_open(&nc.c, zero, p9.OREAD) != .Ok {
		return false
	}
	z := [8]u8{1, 1, 1, 1, 1, 1, 1, 1}
	n, rst := p9.client_read(&nc.c, zero, 0, z[:])
	return rst == .Ok && n == 8 && z[0] == 0 && z[7] == 0
}

me, other: rt.Conn

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	check(listed_as("null", 0o666, "sys")) // svcd's, srvmode=

	// This program's own connection to srvfs, as vectra, and another as someone else.
	srv := ns.connector(&space, "/srv")
	check(srv != vx.HANDLE_NONE)
	mroot, oroot: p9.Fid
	ast: vx.Status
	check(rt.p9_connect(srv, &me) == .Ok && .Srv in me.c.extensions)
	me.c.uname = "vectra"
	mroot, ast = p9.client_attach(&me.c, "")
	check(ast == .Ok)
	check(rt.p9_connect(srv, &other) == .Ok)
	other.c.uname = "glenda"
	oroot, ast = p9.client_attach(&other.c, "")
	check(ast == .Ok)
	mc, oc := &me.c, &other.c

	// /srv/null's connector works: its zero reads as zeros.
	null, nst := open_post(mc, mroot, "null")
	check(nst == .Ok && null != vx.HANDLE_NONE)
	check(zeros_through(null))

	// A post of one's own: made, written with a connector, listed as one's own.
	fid, st := make_post(mc, mroot, "mine", 0o600, p9.OWRITE)
	check(st == .Ok)
	check(post_dup(mc, fid, null) == .Ok)
	check(post_dup(mc, fid, null) == .Err_Bad_State) // posted already
	_ = p9.client_clunk(mc, fid)
	check(listed_as("mine", 0o600, "vectra"))
	got: vx.Handle
	got, st = open_post(mc, mroot, "mine")
	check(st == .Ok && got != vx.HANDLE_NONE)
	rt.close_all(got)
	_, st = open_post(oc, oroot, "mine")
	check(st == .Err_Access) // 0600: the owner's
	fid, st = make_post(mc, mroot, "mine", 0o600, p9.OWRITE)
	check(st == .Err_Exists)
	_ = p9.client_clunk(mc, fid)
	check(remove(oc, oroot, "mine") == .Err_Access)
	check(remove(mc, mroot, "mine") == .Ok)
	check(!is_listed("mine"))

	// Made and not posted: there, but no connector to give.
	fid, st = make_post(mc, mroot, "empty", 0o666, p9.OWRITE)
	check(st == .Ok)
	_, st = open_post(oc, oroot, "empty")
	check(st == .Err_Bad_State)
	_ = p9.client_remove(mc, fid)

	// ORCLOSE: the post goes with its maker's fid.
	fid, st = make_post(mc, mroot, "brief", 0o666, p9.Open_Mode{access = .Write, rclose = true})
	check(st == .Ok)
	check(post_dup(mc, fid, null) == .Ok)
	check(is_listed("brief"))
	_ = p9.client_clunk(mc, fid)
	check(!is_listed("brief"))

	rt.close_all(null)
	rt.p9_disconnect(&me)
	rt.p9_disconnect(&other)
	rt.print("srvtest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	return 0
}
