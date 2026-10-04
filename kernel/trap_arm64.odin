package kernel

foreign _ {
	vx_install_vectors :: proc "c" () ---
	vx_read_esr :: proc "c" () -> u64 ---
}

// The frame vx_sync_entry builds: x0-x30, elr, spsr, then the vector state.
Trap_Frame :: struct {
	x:    [31]u64,
	elr:  u64,
	spsr: u64,
	_:    u64,
	q:    [32][2]u64,
	fpcr: u64,
	fpsr: u64,
}

#assert(size_of(Trap_Frame) == 272 + 512 + 16)

trap_install :: proc "contextless" () {
	vx_install_vectors()
}

@(export, link_name="trap_handler")
trap_handler :: proc "c" (f: ^Trap_Frame) {
	esr := vx_read_esr()
	if esr >> 26 != 0x3c { // not a brk
		puts("vx: unexpected exception, esr=")
		put_hex(esr)
		puts("\n")
		for {}
	}
	trap_common()
	f.elr += 4 // brk does not advance the PC
}
