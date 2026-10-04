// lib/drbg against upstream's vx-rand. Upstream has no host test of its own
// for it; upstream.txt is what upstream's vx_drbg prints for the same seed,
// reads and mixes, from a harness built with clang against M4's sources (the
// P4 cross-check), and each line here must match it.
package drbg_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:drbg"

UPSTREAM := #load("upstream.txt", string)

@(test)
test_against_upstream :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	d: drbg.Drbg
	drbg.mix(&d, transmute([]u8)string("seed"), true)
	sizes := []int{0, 1, 31, 32, 33, 64, 100}
	for size in sizes {
		buf: [100]u8
		drbg.read(&d, buf[:size])
		fmt.sbprintf(&b, "drbg %d ", size)
		for x in buf[:size] {
			fmt.sbprintf(&b, "%02x", x)
		}
		fmt.sbprintf(&b, " %d\n", u64(d.counter))
		drbg.mix(&d, buf[:size], false)
	}
	fmt.sbprintf(&b, "seeded %d\n", d.seeded ? 1 : 0)
	got, want := strings.to_string(b), UPSTREAM
	line := 0
	for {
		gl, gok := strings.split_lines_iterator(&got)
		wl, wok := strings.split_lines_iterator(&want)
		line += 1
		if !gok && !wok {
			break
		}
		if !testing.expectf(t, gl == wl, "line %d: got %q, upstream has %q", line, gl, wl) {
			break
		}
	}
}

@(test)
test_unseeded :: proc(t: ^testing.T) {
	// Mixing alone does not seed a generator.
	d: drbg.Drbg
	drbg.mix(&d, transmute([]u8)string("noise"), false)
	testing.expect(t, !d.seeded)
}
