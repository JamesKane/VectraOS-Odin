// wstattest: what vx:p9's server does for every file server (upstream's M6
// step 6d4c1), run in the fsdwstat scenario (tests/qemu/m6/fsdwstat.ndb)
// against fsd (its home branch on /tmp) and tmpfs (/n/mem): Twstat's
// rename, truncate, chmod and mtime, all of a wstat or none of it, and what
// it may not change; ORCLOSE at create and at open; DMAPPEND's writes at the
// end; and DMEXCL's one open at a time. Each check prints a line only when
// it fails; the last line counts them. The checks are upstream's, some of
// several conditions, so the count is too.
package wstattest

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if !ok {
		failures += 1
		rt.print("wstattest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

space: ns.Namespace

// dir/name.
at :: proc "contextless" (buf: []u8, dir, name: string) -> string {
	s, _ := str.join(buf, dir, "/", name)
	return s
}

exists :: proc "contextless" (dir, name: string) -> bool {
	buf: [64]u8
	c, fid, st := ns.walk(&space, at(buf[:], dir, name))
	if st != .Ok {
		return false
	}
	_ = p9.client_clunk(c, fid)
	return true
}

rm :: proc "contextless" (dir, name: string) {
	buf: [64]u8
	if c, fid, st := ns.walk(&space, at(buf[:], dir, name)); st == .Ok {
		_ = p9.client_remove(c, fid)
	}
}

stat_of :: proc "contextless" (f: ^ns.File) -> p9.Stat {
	st: p9.Stat
	_ = p9.client_stat(f.c, f.fid, &st)
	return st
}

create :: proc "contextless" (dir, name: string, perm: u32, mode: p9.Open_Mode, f: ^ns.File) -> vx.Status {
	buf: [64]u8
	return ns.create(&space, at(buf[:], dir, name), perm, mode, f)
}

open :: proc "contextless" (dir, name: string, mode: p9.Open_Mode, f: ^ns.File) -> vx.Status {
	buf: [64]u8
	return ns.open(&space, at(buf[:], dir, name), mode, f)
}

write_at :: proc "contextless" (f: ^ns.File, offset: u64, data: string) -> bool {
	n, st := p9.client_write(f.c, f.fid, offset, transmute([]u8)data)
	return st == .Ok && n == len(data)
}

on :: proc "contextless" (dir: string) {
	f, g: ns.File
	// Rename, truncate, chmod, mtime.
	made := create(dir, "a", 0o644, p9.ORDWR, &f) == .Ok
	check(made)
	if !made {
		return
	}
	check(write_at(&f, 0, "hello"))
	w := p9.stat_untouched()
	w.name = "b"
	check(p9.client_wstat(f.c, f.fid, &w) == .Ok && exists(dir, "b") && !exists(dir, "a"))
	w = p9.stat_untouched()
	w.length, w.mode, w.mtime = 2, (stat_of(&f).mode &~ 0o777) | 0o600, 1000
	check(p9.client_wstat(f.c, f.fid, &w) == .Ok)
	st := stat_of(&f)
	check(st.length == 2 && st.mode & 0o777 == 0o600 && st.mtime == 1000)
	w = p9.stat_untouched()
	check(p9.client_wstat(f.c, f.fid, &w) == .Ok) // nothing: a sync
	// What may not change.
	w = p9.stat_untouched()
	w.uid = "someone-else"
	check(p9.client_wstat(f.c, f.fid, &w) == .Err_Access)
	w = p9.stat_untouched()
	w.qid.path = 12345
	check(p9.client_wstat(f.c, f.fid, &w) == .Err_Invalid)
	w = p9.stat_untouched()
	w.mode = stat_of(&f).mode | p9.DMAPPEND
	check(p9.client_wstat(f.c, f.fid, &w) == .Err_Unsupported) // only at create
	// All of it or none: a rename onto a name that is there, with a length.
	check(create(dir, "c", 0o644, p9.OWRITE, &g) == .Ok)
	ns.close(&g)
	w = p9.stat_untouched()
	w.name, w.length = "c", 0
	check(p9.client_wstat(f.c, f.fid, &w) != .Ok && stat_of(&f).length == 2 && exists(dir, "b"))
	ns.close(&f)
	rm(dir, "b")
	rm(dir, "c")

	// ORCLOSE: made with it, gone at the clunk; opened with it, the same.
	wrclose := p9.Open_Mode{access = .Write, rclose = true}
	check(create(dir, "r", 0o644, wrclose, &f) == .Ok && exists(dir, "r"))
	ns.close(&f)
	check(!exists(dir, "r"))
	check(create(dir, "r2", 0o644, p9.OWRITE, &f) == .Ok)
	ns.close(&f)
	check(open(dir, "r2", p9.Open_Mode{access = .Read, rclose = true}, &f) == .Ok)
	ns.close(&f)
	check(!exists(dir, "r2"))

	// DMAPPEND: every write at the end.
	made = create(dir, "app", p9.DMAPPEND | 0o644, p9.ORDWR, &f) == .Ok
	check(made)
	if !made {
		return
	}
	check(.Append in stat_of(&f).qid.type && stat_of(&f).mode & p9.DMAPPEND != 0)
	check(write_at(&f, 0, "ab") && write_at(&f, 0, "cd"))
	buf: [8]u8
	n, rst := p9.client_read(f.c, f.fid, 0, buf[:])
	check(rst == .Ok && string(buf[:n]) == "abcd")
	ns.close(&f)
	rm(dir, "app")

	// DMEXCL: one open at a time.
	made = create(dir, "ex", p9.DMEXCL | 0o644, p9.ORDWR, &f) == .Ok
	check(made)
	if !made {
		return
	}
	check(.Excl in stat_of(&f).qid.type)
	check(open(dir, "ex", p9.OREAD, &g) == .Err_Access)
	ns.close(&f)
	check(open(dir, "ex", p9.OREAD, &g) == .Ok)
	ns.close(&g)
	rm(dir, "ex")
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	on("/tmp") // fsd
	on("/n/mem") // tmpfs
	rt.print("wstattest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	return 0
}
