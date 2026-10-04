package kernel

import "base:runtime"

VERSION :: "0.1.0"

when ODIN_ARCH == .amd64 {
	ARCH_NAME :: "x86_64"
} else when ODIN_ARCH == .arm64 {
	ARCH_NAME :: "aarch64"
} else {
	#panic("VectraOS runs on x86_64 and aarch64")
}

hhdm: u64

@(export, link_name="kmain")
kmain :: proc "c" () {
	context = runtime.default_context()

	console_init()
	if !base_revision_supported() {
		puts("vx: panic: Limine does not speak base revision 6\n")
		return
	}
	hh := hhdm_response()
	mm := memmap_response()
	if hh == nil || mm == nil {
		puts("vx: panic: Limine gave no HHDM or memory map\n")
		return
	}
	hhdm = hh.offset

	usable: u64
	for e in mm.entries[:mm.entry_count] {
		if e.type == MEMMAP_USABLE {
			usable += e.length
		}
	}
	cpus := u64(1)
	if mp := mp_response(); mp != nil {
		cpus = mp.cpu_count
	}

	// Late console set-up that needs the memory map (the PL011's mapping).
	console_map(mm)

	puts("vx: kernel " + VERSION + " " + ARCH_NAME + ", ")
	put_dec(usable >> 20)
	puts(" MiB free, ")
	put_dec(cpus)
	puts(cpus == 1 ? " cpu\n" : " cpus\n")

	simd_report()
	simd_check()
	trap_test()
	puts("vx: first light\n")
}
