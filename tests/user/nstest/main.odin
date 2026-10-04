// nstest: M2's namespace test, run as a service in the ns scenario
// (tests/qemu/m2/ns.ndb). svcd spawns it from tests/user/nstest.ndb with a
// namespace: bootfs at /, /boot/bin after /bin, and bootfs attached at
// boot/svc after /dev. It checks what it sees through lib/ns, then plays a
// hostile client on its own connection. Each check prints a line only when
// it fails; the last line counts them.
package nstest

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

checks, failures: u32

// Returns ok, so a check can guard what depends on it.
check :: proc "contextless" (ok: bool, what := #caller_expression(ok), loc := #caller_location) -> bool {
	checks += 1
	if ok {
		return true
	}
	failures += 1
	rt.print("nstest: FAILED line ", u64(loc.line), ": ", what, "\n")
	return false
}

// A string comparison that shows what it got when it fails.
check_str :: proc "contextless" (got, want: string, what := #caller_expression(got), loc := #caller_location) {
	check(got == want, what, loc)
	if got != want {
		rt.print("nstest:   got \"", got, "\"\n")
	}
}

space: ns.Namespace
list_out: [dynamic; 512]u8
list_buf: [4096]u8

// The names in a directory, space-separated.
list :: proc "contextless" (path: string) -> string {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return "(cannot open)"
	}
	defer ns.close(&f)
	clear(&list_out)
	n: int
	st: vx.Status
	for {
		n, st = ns.read(&f, list_buf[:])
		if n <= 0 {
			break
		}
		it := p9.Dir_Entries{buf = list_buf[:n]}
		for s in p9.next_entry(&it) {
			if len(list_out) + len(s.name) + 1 >= cap(list_out) {
				return "(too long)" // room for a separator too
			}
			if len(list_out) > 0 {
				_ = append(&list_out, ' ')
			}
			_ = append(&list_out, s.name)
		}
		if it.off != n {
			return "(bad entry)"
		}
	}
	return st != .Ok ? "(read failed)" : string(list_out[:])
}

test_spawn :: proc "contextless" () {
	check(rt.spawn.name == "nstest")
	args := rt.args()
	check(len(args) == 2 && args[0] == "first" && args[1] == "second arg")
	check(rt.spawn_take("bootimage") == vx.HANDLE_NONE) // not granted
	check(rt.spawn_take("listen") == vx.HANDLE_NONE)
}

programs: [512]u8
manifests: [512]u8

test_namespace :: proc "contextless" () {
	check_str(list("/"), "adm bin boot dev dist lib n net proc srv sys tmp")
	boot_bin := list("/boot/bin")
	copy(programs[:], boot_bin) // list's buffer is reused
	progs := string(programs[:len(boot_bin)])
	check_str(list("/bin"), progs) // the empty /bin, then /boot/bin
	check(len(progs) > 29 && progs[:29] == "posix bootfs bus-acpi nstest ") // sbase's directory first
	svc := list("/boot/svc")
	copy(manifests[:], svc) // list's buffer is reused
	svcs := string(manifests[:len(svc)])
	check_str(list("/dev"), svcs) // /dev's own (nothing), then boot/svc attached at /dev
	check(len(svcs) > 22 && svcs[:20] == "bootfs.ndb cons.ndb ")

	// A file, read through a bind and through a second attach.
	WANT :: "# boot/svc/bootfs.ndb"
	got: [len(WANT)]u8
	f: ns.File
	if check(ns.open(&space, "/dev/bootfs.ndb", p9.OREAD, &f) == .Ok) {
		n, _ := ns.read(&f, got[:])
		check(n == len(got) && string(got[:]) == WANT)
		ns.close(&f)
	}
	if check(ns.open(&space, "/bin/nstest", p9.OREAD, &f) == .Ok) {
		n, _ := ns.read(&f, got[:4])
		check(n == 4 && string(got[:4]) == "\x7fELF")
		ns.close(&f)
	}
	// bootfs is read-only.
	check(ns.open(&space, "/boot/svc/bootfs.ndb", p9.OWRITE, &f) == .Err_Access)
	check(ns.open(&space, "/boot/svc/bootfs.ndb", p9.Open_Mode{access = .Read, trunc = true}, &f) == .Err_Access)
	check(ns.open(&space, "/nothing", p9.OREAD, &f) == .Err_Not_Found)

	out: [512]u8
	length := ns.print(&space, out[:])
	SCRIPT :: "mount /srv/bootfs /\nbind /bin /bin\nbind -a /boot/bin /bin\nbind /dev /dev\nmount -a /srv/bootfs /dev boot/svc\n"
	check(string(out[:length]) == SCRIPT)
	if length > 0 {
		rt.print(string(out[:length]))
	}
}

// A hostile client on a connection of its own: raw walks may not leave the
// attach root, and the server keeps working after nonsense.
test_confinement :: proc "contextless" () {
	c := &procns.conn(0).c
	root, rst := p9.client_attach(c, "boot/bin")
	check(rst == .Ok)
	fid, wst := p9.client_walk(c, root, "../../../..")
	check(wst == .Ok)
	s: p9.Stat
	check(p9.client_stat(c, fid, &s) == .Ok && s.name == "bin")
	_ = p9.client_clunk(c, fid)
	_, wst = p9.client_walk(c, root, "../svc")
	check(wst == .Err_Not_Found) // ../ is bin itself; no svc there
	fid, wst = p9.client_walk(c, root, "nstest")
	check(wst == .Ok)
	check(p9.client_create(c, root, "x", 0o644, p9.OWRITE) == .Err_Access)
	check(p9.client_remove(c, fid) == .Err_Access) // and the fid is gone
	check(p9.client_clunk(c, fid) == .Err_Bad_Handle)
	_, ast := p9.client_attach(c, "../..")
	check(ast == .Err_Not_Found)
	_, ast = p9.client_attach(c, "boot/svc/bootfs.ndb")
	check(ast == .Err_Not_Found) // not a directory
	_ = p9.client_clunk(c, root)
	check(len(list("/bin")) > 6) // still serving
}

// A ring connection that ends takes its mapping with it (as_unmap): twenty
// connections to bootfs, each ended, leave the address space as it was.
test_connections_unmap :: proc "contextless" () {
	connector := space.conns[0].connector
	before, bst := rt.task_info(rt.self)
	check(connector != vx.HANDLE_NONE && bst == .Ok)
	for _ in 0 ..< 20 {
		@(static) k: rt.Conn
		check(rt.p9_connect(connector, &k) == .Ok) // which negotiates the version too
		rt.p9_disconnect(&k)
	}
	after, ast := rt.task_info(rt.self)
	check(ast == .Ok && after.mapped == before.mapped)
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	test_spawn()
	st := procns.from_spawn(&space)
	check(st == .Ok)
	if st == .Ok {
		test_namespace()
		test_confinement()
		test_connections_unmap()
	}
	rt.print("nstest: ", u64(checks), " checks, ", u64(failures), " failed\n")
	rt.exits(failures != 0 ? "failed" : "")
}
