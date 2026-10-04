package kernel

foreign _ {
	vx_read_cr0 :: proc "c" () -> u64 ---
	vx_read_cr4 :: proc "c" () -> u64 ---
	vx_read_xcr0 :: proc "c" () -> u64 ---
}

simd_report :: proc "contextless" () {
	puts("vx: cr0=")
	put_hex(vx_read_cr0())
	puts(" cr4=")
	cr4 := vx_read_cr4()
	put_hex(cr4)
	if cr4 & (1 << 18) != 0 {
		puts(" xcr0=")
		put_hex(vx_read_xcr0())
	}
	puts("\n")
}
