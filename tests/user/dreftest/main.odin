// dreftest: 9Px's dref extension on fsd (upstream docs/proto/dref.md), run in
// the fsddref scenario (tests/qemu/m5/fsddref.ndb) with fsd's home branch on
// /tmp. Reads and writes whose data is in a VMO of its own, far past the
// msize in one message; what fsd refuses; and that fsd, handed its own page
// cache's VMO as a region, refuses it rather than waiting on itself. Each
// check prints a line only when it fails; the last line counts them. The
// checks are upstream's, some of several conditions, so the count is too.
package dreftest

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
		rt.print("dreftest: FAILED line ", u64(loc.line), ": ", what, "\n")
	}
}

SIZE :: 200 * 1024 // more than ten of the ring's 16 KiB messages

data, back: [SIZE]u8
space: ns.Namespace

// The ring connection a namespace's client is (procns makes each one an
// rt.Conn): dref's VMO goes with its request.
conn_of :: proc "contextless" (c: ^p9.Client) -> ^rt.Conn {
	#assert(offset_of(rt.Conn, c) == 0)
	return (^rt.Conn)(c)
}

readref :: proc "contextless" (f: ^ns.File, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (u32, vx.Status) {
	return rt.p9_readref(conn_of(f.c), f.fid, offset, vmo, roffset, count)
}

writeref :: proc "contextless" (f: ^ns.File, offset: u64, vmo: vx.Handle, roffset: u64, count: u32) -> (u32, vx.Status) {
	return rt.p9_writeref(conn_of(f.c), f.fid, offset, vmo, roffset, count)
}

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.exits("no namespace")
	}
	for i in 0 ..< SIZE {
		data[i] = u8(i * 7 + i / 4096)
	}
	out, out_st := rt.vmo_create(SIZE)
	in_vmo, in_st := rt.vmo_create(SIZE + 4096)
	check(out_st == .Ok && in_st == .Ok)
	check(rt.vmo_write(out, 0, data[:]) == .Ok)

	// Written in one Twriteref, read back in one Treadref, at an offset in the VMO.
	f: ns.File
	check(ns.create(&space, "/tmp/dref", 0o644, p9.ORDWR, &f) == .Ok)
	check(f.c != nil && .Dref in f.c.extensions)
	done, st := writeref(&f, 0, out, 0, SIZE)
	check(st == .Ok && done == SIZE)
	done, st = readref(&f, 0, in_vmo, 4096, SIZE)
	check(st == .Ok && done == SIZE)
	check(rt.vmo_read(in_vmo, 4096, back[:]) == .Ok && back == data)
	// Past the end: a short read; at it, none.
	done, st = readref(&f, SIZE - 100, in_vmo, 0, 4096)
	check(st == .Ok && done == 100)
	done, st = readref(&f, SIZE, in_vmo, 0, 4096)
	check(st == .Ok && done == 0)
	// What Tread sees is the same file.
	some: [64]u8
	n, read_st := p9.client_read(f.c, f.fid, 70_000, some[:])
	check(read_st == .Ok && n == len(some) && string(some[:]) == string(data[70_000:][:len(some)]))
	// A region past the VMO's end is refused, having read nothing into it.
	_, st = readref(&f, 0, out, SIZE - 10, 4096)
	check(st != .Ok)
	ns.close(&f)

	// The fid's mode is Tread's and Twrite's rule.
	check(ns.open(&space, "/tmp/dref", p9.OREAD, &f) == .Ok)
	_, st = writeref(&f, 0, out, 0, 4096)
	check(st == .Err_Access)
	done, st = readref(&f, 0, in_vmo, 0, 4096)
	check(st == .Ok && done == 4096)
	// fsd's own page cache as the region: refused, not waited on (its pages
	// were never asked for), and fsd still answers.
	m, map_st := p9.client_map(f.c, f.fid, 0, 8192, {.Read})
	check(map_st == .Ok && m.avail >= 8192)
	_, st = readref(&f, 0, m.vmo, 0, 4096)
	check(st != .Ok)
	rt.close_all(m.vmo)
	done, st = readref(&f, 0, in_vmo, 0, 4096)
	check(st == .Ok && done == 4096)
	ns.close(&f)
	check(ns.open(&space, "/tmp/dref", p9.OWRITE, &f) == .Ok)
	_, st = readref(&f, 0, in_vmo, 0, 4096)
	check(st == .Err_Access)
	ns.close(&f)

	rt.print("dreftest: ", u64(checks), " checks, ", u64(failures), failures != 0 ? " FAILED\n" : " failed\n")
	return 0
}
