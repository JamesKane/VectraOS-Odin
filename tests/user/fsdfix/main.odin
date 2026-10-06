// fsdfix: fsd's review findings fixed in upstream's M6 step 6d5c, in the
// fsdfix scenario (tests/qemu/m6/fsdfix.ndb), as vectra (one of adm), on fsd
// connections of its own:
//   - each open of status reads a copy of its own: a reader part way through
//     does not see a label made since;
//   - a rename or a symlink to ctl or status in adm's root is refused;
//   - the dump view lists more than 256 dated labels;
//   - 40 snapshots opened one after another, more than the 32 slots; with
//     32 held, a 33rd waits for one to be let go;
//   - a snapshot deleted under a fid: the fid finds nothing, and never the
//     next snapshot that takes a slot;
//   - /adm/users rewritten with a user before vectra: a fid attached as
//     vectra is vectra's still;
//   - an orphan let go after halt is not reaped: nothing is committed.
// Each check prints a line only when it fails; the last line counts them.
// The checks are upstream's, some of several conditions, so the count is too.
package fsdfix

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
		rt.print("fsdfix: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

space: ns.Namespace
fsd: vx.Handle
adm, home: rt.Conn
aroot, hroot: p9.Fid

attach :: proc "contextless" (c: ^rt.Conn, aname: string) -> (root: p9.Fid, ok: bool) {
	if rt.p9_connect(fsd, c) != .Ok {
		return 0, false
	}
	c.timeout = 60_000_000_000
	st: vx.Status
	root, st = p9.client_attach(&c.c, aname)
	return root, st == .Ok
}

// v in decimal, into buf.
num :: proc "contextless" (buf: []u8, v: u32) -> string {
	return str.format_u64(buf, u64(v))
}

// One ctl command; its status.
ctl :: proc "contextless" (cmd: string) -> vx.Status {
	fid := p9.client_walk(&adm.c, aroot, "ctl") or_return
	st := p9.client_open(&adm.c, fid, p9.OWRITE)
	if st == .Ok {
		_, st = p9.client_write(&adm.c, fid, 0, transmute([]u8)cmd)
	}
	_ = p9.client_clunk(&adm.c, fid)
	return st
}

// The whole of a file at path from root on c, into buf: its length.
read_all :: proc "contextless" (c: ^p9.Client, root: p9.Fid, path: string, buf: []u8) -> (got: int, st: vx.Status) {
	fid := p9.client_walk(c, root, path) or_return
	st = p9.client_open(c, fid, p9.OREAD)
	for st == .Ok && got < len(buf) {
		n, e := p9.client_read(c, fid, u64(got), buf[got:])
		if e != .Ok || n <= 0 {
			break
		}
		got += n
	}
	_ = p9.client_clunk(c, fid)
	return
}

big: [64 * 1024]u8

// status's commit=.
commit_of :: proc "contextless" () -> u32 {
	n, _ := read_all(&adm.c, aroot, "status", big[:])
	text := string(big[:n])
	at := str.index(text, "commit=")
	if at < 0 {
		return 0
	}
	v: u32
	for c in transmute([]u8)text[at + 7:] {
		if c < '0' || c > '9' {
			break
		}
		v = v * 10 + u32(c - '0')
	}
	return v
}

pause_ms :: proc "contextless" (ms: i64) {
	never: u32
	until := rt.clock_read() + vx.Instant(ms * 1_000_000)
	for rt.clock_read() < until {
		_ = rt.futex_wait(&never, 0, until)
	}
}

a_text: [16 * 1024]u8
users_text: [64 * 1024]u8
dump, snap: rt.Conn
sroots: [33]p9.Fid

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	fsd = ns.connector(&space, "/tmp")
	check(fsd != vx.HANDLE_NONE)
	ok_adm, ok_home: bool
	aroot, ok_adm = attach(&adm, "%adm") // %: as adm, permissively
	if ok_adm {
		hroot, ok_home = attach(&home, "home")
	}
	check(ok_adm && ok_home)
	buf: [512]u8
	fid, fid2: p9.Fid
	st: vx.Status
	n: int

	// status: an open's copy. A reads 64 bytes; a label is made; B sees it; A's rest does not.
	fid, st = p9.client_walk(&adm.c, aroot, "status")
	check(st == .Ok && p9.client_open(&adm.c, fid, p9.OREAD) == .Ok)
	first, _ := p9.client_read(&adm.c, fid, 0, buf[:64])
	check(first == 64)
	check(ctl("snap home home@copy") == .Ok)
	nb, _ := read_all(&adm.c, aroot, "status", big[:])
	check(nb > 0 && str.contains(string(big[:nb]), "label=home@copy "))
	rest := 0
	for {
		got, e := p9.client_read(&adm.c, fid, 64 + u64(rest), a_text[rest:][:4096])
		if e != .Ok || got <= 0 {
			break
		}
		rest += got
	}
	check(rest > 0 && !str.contains(string(a_text[:rest]), "label=home@copy "))
	_ = p9.client_clunk(&adm.c, fid)

	// ctl and status are never made real in adm's root.
	fid, st = p9.client_walk(&adm.c, aroot, "")
	check(st == .Ok && p9.client_create(&adm.c, fid, "spare", 0o644, p9.OWRITE) == .Ok)
	_ = p9.client_clunk(&adm.c, fid)
	check(p9.client_renameat(&adm.c, aroot, "spare", aroot, "ctl") == .Err_Exists)
	check(p9.client_renameat(&adm.c, aroot, "spare", aroot, "status") == .Err_Exists)
	check(p9.client_symlink(&adm.c, aroot, "status", "spare") == .Err_Exists)
	lnk: p9.Fid
	lnk, st = p9.client_walk(&adm.c, aroot, "spare")
	check(st == .Ok && p9.client_remove(&adm.c, lnk) == .Ok)

	// The dump view: 260 dated labels, every one listed.
	snapped := true
	for i in u32(0) ..< 260 {
		if !snapped {
			break
		}
		// home@YYYY-MM-DD: years 2001.., months, days: all distinct dates
		cmd: [25]u8
		copy(cmd[:], "snap home home@2001-01-01")
		y, d := 2001 + i / 28, 1 + i % 28
		cmd[15], cmd[16], cmd[17], cmd[18] = u8('0' + y / 1000), u8('0' + y / 100 % 10), u8('0' + y / 10 % 10), u8('0' + y % 10)
		cmd[23], cmd[24] = u8('0' + d / 10), u8('0' + d % 10)
		snapped = ctl(string(cmd[:])) == .Ok
	}
	check(snapped)
	droot: p9.Fid
	days: u32
	ok: bool
	droot, ok = attach(&dump, "dump")
	check(ok)
	for y in u32(2001) ..= 2010 { // each year's days
		ybuf: [8]u8
		if fid, st = p9.client_walk(&dump.c, droot, num(ybuf[:], y)); st != .Ok {
			continue
		}
		if p9.client_open(&dump.c, fid, p9.OREAD) == .Ok {
			off: u64
			for {
				got, e := p9.client_read(&dump.c, fid, off, big[:])
				if e != .Ok || got <= 0 {
					break
				}
				it := p9.Dir_Entries {
					buf = big[:got],
				}
				for _ in p9.next_entry(&it) {
					days += 1
				}
				off += u64(got)
			}
		}
		_ = p9.client_clunk(&dump.c, fid)
	}
	check(days == 260)

	// 40 snapshots opened one after another: more than the 32 slots.
	opened := true
	for i in u32(0) ..< 40 {
		if !opened {
			break
		}
		cmd_buf, label_buf, nbuf: [32]u8
		label, _ := str.join(label_buf[:], "home@s", num(nbuf[:], i))
		cmd, _ := str.join(cmd_buf[:], "snap home ", label)
		sroot: p9.Fid
		opened = ctl(cmd) == .Ok
		if opened {
			sroot, opened = attach(&snap, label)
		}
		if opened {
			_ = p9.client_clunk(&snap.c, sroot)
		}
		rt.p9_disconnect(&snap)
	}
	check(opened)
	// 32 held: the 33rd waits for one to go.
	all := true
	for i in u32(0) ..< 32 {
		if !all {
			break
		}
		label_buf, nbuf: [32]u8
		label, _ := str.join(label_buf[:], "home@s", num(nbuf[:], i))
		sroots[i], st = p9.client_attach(&home.c, label)
		all = st == .Ok
	}
	check(all)
	sroots[32], st = p9.client_attach(&home.c, "home@s39")
	check(st == .Err_No_Memory)
	_ = p9.client_clunk(&home.c, sroots[0])
	sroots[32], st = p9.client_attach(&home.c, "home@s39")
	check(st == .Ok)
	for i in 1 ..= 32 {
		_ = p9.client_clunk(&home.c, sroots[i])
	}

	// A snapshot deleted under a fid: nothing found by it, before and after
	// another snapshot opens.
	sroot, hello: p9.Fid
	sroot, st = p9.client_attach(&home.c, "home@s1")
	if st == .Ok {
		hello, st = p9.client_walk(&home.c, sroot, "hello.txt")
	}
	check(st == .Ok)
	s: p9.Stat
	keep: p9.Stat_Text
	check(p9.client_stat(&home.c, hello, &s, &keep) == .Ok)
	check(ctl("del home@s1") == .Ok)
	check(p9.client_stat(&home.c, hello, &s, &keep) == .Err_Not_Found)
	st = ctl("snap home home@after")
	if st == .Ok {
		fid2, st = p9.client_attach(&home.c, "home@after")
	}
	check(st == .Ok)
	check(p9.client_stat(&home.c, hello, &s, &keep) == .Err_Not_Found)
	_ = p9.client_clunk(&home.c, fid2)
	_ = p9.client_clunk(&home.c, hello)
	_ = p9.client_clunk(&home.c, sroot)

	// /adm/users rewritten, a user put before vectra: a fid attached as
	// vectra stays vectra's, and the new user attaches as itself.
	un, _ := read_all(&adm.c, aroot, "users", big[:len(big) - 64])
	check(un > 0)
	ul := copy(users_text[:], "4242:alice::\n")
	ul += copy(users_text[ul:], big[:un])
	wrote := false
	if fid, st = p9.client_walk(&adm.c, aroot, "users"); st == .Ok && p9.client_open(&adm.c, fid, p9.Open_Mode{access = .Write, trunc = true}) == .Ok {
		n, st = p9.client_write(&adm.c, fid, 0, users_text[:ul])
		wrote = st == .Ok && n == ul
	}
	check(wrote)
	_ = p9.client_clunk(&adm.c, fid) // read again
	fid, st = p9.client_walk(&home.c, hroot, "")
	check(st == .Ok && p9.client_create(&home.c, fid, "mine", 0o644, p9.OWRITE) == .Ok)
	_ = p9.client_clunk(&home.c, fid)
	fid, st = p9.client_walk(&home.c, hroot, "mine")
	check(st == .Ok && p9.client_stat(&home.c, fid, &s, &keep) == .Ok && s.uid == "vectra")
	_ = p9.client_clunk(&home.c, fid)

	// halt, then the last of an orphan let go: nothing reaped, nothing committed.
	orphan: p9.Fid
	orphan, st = p9.client_walk(&home.c, hroot, "")
	if st == .Ok {
		st = p9.client_create(&home.c, orphan, "orphan", 0o644, p9.OWRITE)
	}
	if st == .Ok {
		n, st = p9.client_write(&home.c, orphan, 0, transmute([]u8)string("gone"))
	}
	check(st == .Ok && n == 4)
	fid, st = p9.client_walk(&home.c, hroot, "orphan")
	check(st == .Ok && p9.client_remove(&home.c, fid) == .Ok)
	check(ctl("halt") == .Ok)
	before := commit_of()
	_ = p9.client_clunk(&home.c, orphan)
	pause_ms(6000) // past fsd's 5-second commit
	check(commit_of() == before)
	sn, _ := read_all(&adm.c, aroot, "status", big[:])
	check(sn > 0 && str.contains(string(big[:sn]), " halted"))

	rt.print("fsdfix: ", u64(checks), " checks, ", u64(failures), " failed\n")
	return 0
}
