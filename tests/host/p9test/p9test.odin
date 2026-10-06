// What the host tests that drive a p9.Fs through lib/p9's server framework
// and client share: a loopback transport and client-side helpers for
// listing and stating. Imported relatively; it has no tests of its own,
// so ./build check runs it only through the suites that import it.
package p9test

import vx "abi:vx"
import "core:strings"
import "vx:p9"

// A p9.Rpc that serves each request at once on the p9.Server ctx points to.
loopback :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int {
	n, res := p9.serve((^p9.Server)(ctx), req, resp)
	return res == .Reply ? n : 0 // a loopback cannot hold a request: a deferral ends it too
}

// The names in a directory read, in order, joined by spaces; not ok if an
// entry is malformed. Allocates from the temp allocator, which the runner
// frees before each test.
names :: proc(dir: []u8) -> (joined: string, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	it := p9.Dir_Entries{buf = dir}
	for st in p9.next_entry(&it) {
		if strings.builder_len(b) > 0 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, st.name)
	}
	return strings.to_string(b), it.off == len(dir)
}

// The names the directory at path (from root) reads as, or what went wrong.
list :: proc(c: ^p9.Client, root: p9.Fid, path: string) -> string {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return "(walk failed)"
	}
	defer _ = p9.client_clunk(c, f)
	if p9.client_open(c, f, p9.OREAD) != .Ok {
		return "(open failed)"
	}
	dir: [4096]u8
	n, re := p9.client_read(c, f, 0, dir[:])
	if re != .Ok {
		return "(read failed)"
	}
	joined, ok := names(dir[:n])
	return ok ? joined : "(bad entry)"
}

// The stat of what is at path (from root); its strings in keep, or empty
// without one.
stat_of :: proc(c: ^p9.Client, root: p9.Fid, path: string, st: ^p9.Stat, keep: ^p9.Stat_Text = nil) -> vx.Status {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return e
	}
	defer _ = p9.client_clunk(c, f)
	return p9.client_stat(c, f, st, keep)
}
