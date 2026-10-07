// cdtest: the native current directory (upstream's M6 step 6d7a, ADR-0017,
// its ADR-0039), run by rctest (tests/qemu/m6/rcscript.ndb) from / in its
// namespace: rt.getwd, procns.chdir and a relative name opened after each
// change; .. against the path; a file, a missing name and a name too long
// refused, the directory left as it was; a relative create, bind and walk;
// another thread sees the change. rc's cd, and a child's inheriting it, are
// rctest's. Each check prints a line only when it fails; the last line counts
// them. The checks are upstream's, some of several conditions, so the count
// is too.
package cdtest

import "base:intrinsics"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

checks, failures: u32

check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) {
	checks += 1
	if !ok {
		failures += 1
		rt.print("cdtest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

space: ns.Namespace

wd_is :: proc "contextless" (want: string) -> bool {
	wd: [rt.WD_MAX]u8
	return rt.getwd(wd[:]) == want
}

opens :: proc "contextless" (path: string) -> bool {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return false
	}
	ns.close(&f)
	return true
}

seen: bool

other :: proc(arg: rawptr) {
	intrinsics.atomic_store(&seen, wd_is("/boot/bin"))
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	check(wd_is("/")) // rc's, inherited
	check(!opens("echo"))

	check(procns.chdir(&space, "/boot/bin") == .Ok && wd_is("/boot/bin"))
	check(opens("echo") && opens("./echo") && opens("../bin/echo"))
	t, st := rt.thread_spawn(other, nil)
	check(st == .Ok)
	rt.thread_join(&t)
	check(intrinsics.atomic_load(&seen)) // one directory for the process

	check(procns.chdir(&space, "..") == .Ok && wd_is("/boot"))
	check(opens("bin/echo") && !opens("echo"))
	check(procns.chdir(&space, "bin/./../bin//") == .Ok && wd_is("/boot/bin"))
	check(procns.chdir(&space, "../../../..") == .Ok && wd_is("/")) // .. above the root is the root

	// Refused, and left as it was.
	check(procns.chdir(&space, "/boot") == .Ok)
	check(procns.chdir(&space, "bin/echo") == .Err_Invalid && wd_is("/boot")) // not a directory
	check(procns.chdir(&space, "no-such-dir") == .Err_Not_Found && wd_is("/boot"))
	check(procns.chdir(&space, "") == .Err_Invalid && wd_is("/boot"))
	long_name: [300]u8
	for &b in long_name {
		b = 'a'
	}
	check(procns.chdir(&space, string(long_name[:])) != .Ok && wd_is("/boot"))

	// A relative create, walk and bind, in /tmp.
	check(procns.chdir(&space, "/tmp") == .Ok)
	f: ns.File
	check(ns.create(&space, "cdtest.d", p9.DMDIR | 0o755, p9.OREAD, &f) == .Ok)
	ns.close(&f)
	check(procns.chdir(&space, "cdtest.d") == .Ok && wd_is("/tmp/cdtest.d"))
	check(ns.create(&space, "f", 0o644, p9.OWRITE, &f) == .Ok)
	ns.close(&f)
	check(opens("/tmp/cdtest.d/f") && opens("f") && opens("../cdtest.d/f"))
	c, fid, wst := ns.walk(&space, "f")
	check(wst == .Ok)
	if c != nil {
		_ = p9.client_clunk(c, fid)
	}
	check(ns.bind(&space, "/boot/bin", ".", {}) == .Ok) // bind ... .: here
	check(opens("echo") && opens("/tmp/cdtest.d/echo"))
	check(ns.unmount(&space, "", ".") == .Ok && opens("f"))

	rt.print("cdtest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	return 0
}
