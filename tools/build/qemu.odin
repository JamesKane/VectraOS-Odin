package build

import "core:fmt"

Qemu_Opts :: struct {
	test: bool, // headless, the serial port on stdio, the image never written
}

// QEMU's command line for booting an image. Devices arrive as the kernel
// learns to drive them; M3 brings networking, M5 more disks.
qemu_cmd :: proc(a: ^Arch, image: string, o: Qemu_Opts) -> []string {
	c := make(Cmd, context.temp_allocator)
	switch a.name {
	case "x86_64":
		append(&c, QEMU_X86_64, "-machine", "q35", "-cpu", "max")
		append(&c, "-drive", fmt.tprintf("if=pflash,format=raw,unit=0,readonly=on,file=%s", FIRMWARE_X86_64))
	case "aarch64":
		append(&c, QEMU_AARCH64, "-machine", "virt,gic-version=3", "-cpu", "max")
		append(&c, "-drive", fmt.tprintf("if=pflash,format=raw,unit=0,readonly=on,file=%s", FIRMWARE_AARCH64))
	}
	append(&c, "-m", "512M", "-smp", "4", "-display", "none", "-no-reboot")
	// A test never writes the image, so several can boot one image at once.
	append(&c, "-drive", fmt.tprintf("if=none,id=disk,format=raw,file=%s%s", image, o.test ? ",snapshot=on" : ""))
	append(&c, "-device", "virtio-blk-pci,drive=disk,disable-legacy=on")
	if o.test {
		append(&c, "-serial", "stdio", "-monitor", "none")
	} else {
		append(&c, "-serial", "mon:stdio")
	}
	return c[:]
}
