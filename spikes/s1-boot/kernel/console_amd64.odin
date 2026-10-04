package kernel

// COM1, a 16550 at I/O port 0x3f8.
COM1 :: 0x3f8

foreign _ {
	vx_outb :: proc "c" (port: u16, value: u8) ---
	vx_inb :: proc "c" (port: u16) -> u8 ---
}

console_init :: proc "contextless" () {
	vx_outb(COM1 + 1, 0x00) // no interrupts
	vx_outb(COM1 + 3, 0x80) // DLAB
	vx_outb(COM1 + 0, 0x01) // 115200 baud
	vx_outb(COM1 + 1, 0x00)
	vx_outb(COM1 + 3, 0x03) // 8N1
	vx_outb(COM1 + 2, 0xc7) // FIFOs on, cleared
}

console_map :: proc "contextless" (mm: ^Memmap_Response) {}

putc :: proc "contextless" (c: u8) {
	for vx_inb(COM1 + 5) & 0x20 == 0 {}
	vx_outb(COM1, c)
}
