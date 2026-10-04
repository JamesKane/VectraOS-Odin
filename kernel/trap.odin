package kernel

// Spike S3's second half: vector state survives a trap whose handler wipes
// every vector register and runs Odin SIMD code of its own (ADR-0004).

foreign _ {
	vx_vreg_trap_test :: proc "c" (input: [^]u8, output: [^]u8) ---
	vx_clobber_vregs :: proc "c" () ---
}

traps_taken: int

trap_test :: proc "contextless" () {
	trap_install()
	input, output: [512]u8
	for i in 0 ..< len(input) {
		input[i] = u8(i * 7 + 3)
	}
	vx_vreg_trap_test(&input[0], &output[0])
	bad := 0
	for i in 0 ..< len(input) {
		if input[i] != output[i] {
			bad += 1
		}
	}
	if traps_taken == 1 && bad == 0 {
		puts("vx: vector state preserved across a trap\n")
	} else {
		puts("vx: vector state CORRUPTED: traps=")
		put_dec(u64(traps_taken))
		puts(" bad bytes=")
		put_dec(u64(bad))
		puts("\n")
	}
}

trap_common :: proc "contextless" () {
	traps_taken += 1
	vx_clobber_vregs()
	simd_check() // Odin's own vector code, inside the handler
}
