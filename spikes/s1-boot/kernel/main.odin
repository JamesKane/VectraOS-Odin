package kernel

import "base:runtime"

hhdm: u64

@(export, link_name="kmain")
kmain :: proc "c" () {
	context = runtime.default_context()

	console_init()
	puts("vx: odin spike kernel, " + ODIN_ARCH_STRING + "\n")

	if !base_revision_supported() {
		puts("vx: limine base revision 6 not supported\n")
		return
	}
	hh := hhdm_response()
	mm := memmap_response()
	if hh == nil || mm == nil {
		puts("vx: missing limine responses\n")
		return
	}
	hhdm = hh.offset

	usable: u64
	for e in mm.entries[:mm.entry_count] {
		if e.type == MEMMAP_USABLE {
			usable += e.length
		}
	}
	puts("vx: hhdm=")
	put_hex(hhdm)
	puts(" usable=")
	put_dec(usable >> 20)
	puts(" MiB\n")

	// Late console set-up that needs the memory map (the PL011's mapping).
	console_map(mm)

	simd_report()
	simd_check()
	trap_test()

	puts("vx: spike ok\n")
}
