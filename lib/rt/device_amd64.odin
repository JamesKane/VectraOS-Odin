package rt

// Port I/O (lib/rt/arch/x86_64/io.S): only the ports an IoRange has given
// this task; any other faults.
foreign _ {
	vx_inb :: proc "c" (port: u16) -> u8 ---
	vx_outb :: proc "c" (port: u16, value: u8) ---
}

inb :: proc "contextless" (port: u16) -> u8 {
	return vx_inb(port)
}

outb :: proc "contextless" (port: u16, value: u8) {
	vx_outb(port, value)
}
