package build

import "core:fmt"

Qemu_Opts :: struct {
	test:  bool, // headless, the serial port on stdio, the image never written
	share: string, // the directory vx9pserve serves at 10.0.2.100!5640
	u9fs:  string, // the root u9fs serves at 10.0.2.101!564, and its log; "" for none
	cdrom: string, // boot this ISO as a CD, with no disk
}

// QEMU's command line for booting an image. Devices arrive as the kernel
// learns to drive them: M3 brought networking; M5 brings more disks.
qemu_cmd :: proc(a: ^Arch, image: string, o: Qemu_Opts) -> []string {
	c := make(Cmd, context.temp_allocator)
	append(&c, a.qemu, "-machine", a.machine, "-cpu", "max")
	append(&c, "-drive", fmt.tprintf("if=pflash,format=raw,unit=0,readonly=on,file=%s", a.firmware))
	append(&c, "-m", "512M", "-smp", "4", "-display", "none", "-no-reboot")
	if o.cdrom != "" {
		// On virtio-scsi, which both architectures' firmware boots from.
		append(&c, "-drive", fmt.tprintf("if=none,id=cd,media=cdrom,readonly=on,file=%s", o.cdrom))
		append(&c, "-device", "virtio-scsi-pci,id=scsi,disable-legacy=on", "-device", "scsi-cd,drive=cd,bus=scsi.0")
	} else {
		// A test never writes the image, so several can boot one image at once.
		append(&c, "-drive", fmt.tprintf("if=none,id=disk,format=raw,file=%s%s", image, o.test ? ",snapshot=on" : ""))
		append(&c, "-device", "virtio-blk-pci,drive=disk,disable-legacy=on")
	}
	// QEMU's user networking: the guest is 10.0.2.15, the host 10.0.2.2.
	// Each connection to 10.0.2.100!7 gets a `cat` on the host of its own (an
	// echo server, for the tcp scenario), and each to 10.0.2.100!5640 a
	// vx9pserve serving o.share, so no host port is needed. (QEMU will not
	// forward the gateway's own address, so M3's exit test as upstream's 04 §5
	// gives it, tcp!10.0.2.2!5640, needs a vx9pserve listening on the host.)
	// With o.u9fs, each connection to 10.0.2.101!564 gets a u9fs, in a user
	// namespace of its own so that it may chroot (ADR-0006).
	u9fs := ""
	when ODIN_OS == .Linux {
		if o.u9fs != "" {
			u9fs = fmt.tprintf(",guestfwd=tcp:10.0.2.101:564-cmd:%s -r %s -a none -u vectra -n -l %s.log %s", UNSHARE, U9FS, o.u9fs, o.u9fs)
		}
	}
	append(&c, "-netdev", fmt.tprintf("user,id=net0,guestfwd=tcp:10.0.2.100:7-cmd:cat,guestfwd=tcp:10.0.2.100:5640-cmd:%s --stdio %s%s", VX9PSERVE, o.share, u9fs))
	append(&c, "-device", "virtio-net-pci,netdev=net0,disable-legacy=on")
	if o.test {
		append(&c, "-serial", "stdio", "-monitor", "none")
	} else {
		append(&c, "-serial", "mon:stdio")
	}
	return c[:]
}
