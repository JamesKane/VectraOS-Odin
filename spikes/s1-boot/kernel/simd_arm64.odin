package kernel

foreign _ {
	vx_read_cpacr :: proc "c" () -> u64 ---
}

simd_report :: proc "contextless" () {
	puts("vx: cpacr_el1=")
	put_hex(vx_read_cpacr())
	puts("\n")
}
