// What the fs suites share: a device in memory, the C heap as the library's
// memory, upstream's xorshift, and digests of what a run wrote. Each suite
// keeps its own state in locals (the runner runs tests on several threads),
// where upstream's C kept it in file statics.
package fs_test

import "core:c/libc"
import "core:fmt"
import "core:testing"
import vx "abi:vx"
import "vx:fs"

B :: fs.BLKSZ

m_alloc :: proc "contextless" (_: rawptr, n: int) -> rawptr {
	return libc.malloc(uint(n))
}

m_free :: proc "contextless" (_: rawptr, p: rawptr, _: int) {
	libc.free(p)
}

mem :: proc "contextless" () -> fs.Mem {
	return {alloc = m_alloc, free = m_free}
}

// A device of blocks in memory, failing reads or writes on demand.
Memdev :: struct {
	bytes:       []u8,
	fail_reads:  bool,
	fail_writes: bool,
	barriers:    u64,
}

memdev_new :: proc(blocks: u64) -> ^Memdev {
	d := new(Memdev)
	d.bytes = make([]u8, blocks * B)
	return d
}

memdev_free :: proc(d: ^Memdev) {
	delete(d.bytes)
	free(d)
}

md_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
	d := (^Memdev)(ctx)
	if d.fail_reads {
		return .Err_Io
	}
	copy(buf[:], d.bytes[addr:][:B])
	return .Ok
}

md_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, buf: ^[B]u8) -> vx.Status {
	d := (^Memdev)(ctx)
	if d.fail_writes {
		return .Err_Io
	}
	copy(d.bytes[addr:][:B], buf[:])
	return .Ok
}

md_barrier :: proc "contextless" (ctx: rawptr) -> vx.Status {
	(^Memdev)(ctx).barriers += 1
	return .Ok
}

dev_of :: proc(d: ^Memdev) -> fs.Dev {
	return {ctx = d, read = md_read, write = md_write, barrier = md_barrier, size = u64(len(d.bytes))}
}

// Upstream's xorshift, seeded per test as its file statics were.
Rng :: struct {
	s: u64,
}

rnd :: proc(r: ^Rng) -> u64 {
	r.s ~= r.s << 13
	r.s ~= r.s >> 7
	r.s ~= r.s << 17
	return r.s
}

below :: proc(r: ^Rng, n: u32) -> u32 {
	return u32(rnd(r) % u64(n))
}

// What a run left on its device, as upstream's C left it for the same run
// (the suites' digests come from upstream's tests, built with clang and made
// to print xxh64 of their devices at the same points: see fixtures/README).
expect_digest :: proc(t: ^testing.T, what: string, bytes: []u8, want: u64, loc := #caller_location) {
	got := fs.xxh64(bytes, 0)
	testing.expectf(t, got == want, "%s: digest %016x, upstream's %016x", what, got, want, loc = loc)
}

// For working digests out: prints what a run left.
print_digest :: proc(what: string, bytes: []u8) {
	fmt.printfln("%s %016x", what, fs.xxh64(bytes, 0))
}

report :: proc(c: ^fs.Check) -> string {
	return fmt.tprintf("check: used %d trees %d other %d leaked %d unallocated %d shared %d damaged %d snaps %d lists %d", c.used, c.trees, c.other, c.leaked, c.unallocated, c.shared, c.damaged, c.bad_snaps, c.bad_lists)
}

// The volume checks clean, and says so if not.
clean :: proc(t: ^testing.T, v: ^fs.Vol, loc := #caller_location) -> bool {
	c: fs.Check
	st := fs.check_volume(v, &c)
	return testing.expectf(t, st == .Ok, "%v, %s", st, report(&c), loc = loc)
}

bytes_eq :: proc(a, b: []u8) -> bool {
	return fs.bytes_equal(a, b)
}
