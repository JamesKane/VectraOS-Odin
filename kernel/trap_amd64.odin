package kernel

foreign _ {
	vx_int3_entry :: proc "c" () ---
	vx_lidt :: proc "c" (descriptor: rawptr) ---
	vx_read_cs :: proc "c" () -> u16 ---
}

Idt_Gate :: struct #packed {
	offset_low:  u16,
	selector:    u16,
	ist:         u8,
	type_attr:   u8,
	offset_mid:  u16,
	offset_high: u32,
	_:           u32,
}

Idt_Descriptor :: struct #packed {
	limit: u16,
	base:  u64,
}

#assert(size_of(Idt_Gate) == 16)

@(private="file")
idt: [256]Idt_Gate

trap_install :: proc "contextless" () {
	entry := u64(uintptr(rawptr(vx_int3_entry)))
	idt[3] = Idt_Gate{
		offset_low  = u16(entry),
		selector    = vx_read_cs(),
		type_attr   = 0x8e, // present, DPL 0, 64-bit interrupt gate
		offset_mid  = u16(entry >> 16),
		offset_high = u32(entry >> 32),
	}
	d := Idt_Descriptor{limit = size_of(idt) - 1, base = u64(uintptr(&idt))}
	vx_lidt(&d)
}

@(export, link_name="trap_handler")
trap_handler :: proc "c" (regs: rawptr) {
	trap_common()
}
