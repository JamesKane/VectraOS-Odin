package build

import "core:fmt"

Qemu_Opts :: struct {
	test:  bool, // headless, the serial port on stdio, the image never written
	share: string, // the directory vx9pserve serves at 10.0.2.100!5640
	u9fs:  string, // the root u9fs serves at 10.0.2.101!564, and its log; "" for none
	cdrom: string, // boot this ISO as a CD, with no disk
	rtc:   string, // the real-time clock's starting time (-rtc base=); "" for the host's UTC
	iommu: Iommu_Mode,
	disk:  string, // a second disk, on virtio-blk, or ""
	nvme:  bool, // and on NVMe instead
	persist: bool, // the boot disk's writes kept, even in a test (a boot after reboot: the installed disk)
}

// The machine's IOMMU (upstream's M5 steps 6c, 6d): VT-d on q35, SMMUv3 on
// virt. Upstream's runner has it on for every scenario from M5; here the
// m5/ and m6/ scenarios have it (test.odin), and M4's run as M4's runner ran them.
Iommu_Mode :: enum {
	Off,
	On,
	Caching, // VT-d's caching mode (CAP.CM): what is not present may be cached too
}

// QEMU's command line for booting an image. Devices arrive as the kernel
// learns to drive them: M3 brought networking; M5 a scenario's second disk.
qemu_cmd :: proc(a: ^Arch, image: string, o: Qemu_Opts) -> []string {
	c := make(Cmd, context.temp_allocator)
	machine := a.machine
	if o.iommu != .Off && a.kind == .AArch64 {
		machine = fmt.tprintf("%s,iommu=smmuv3", machine)
	}
	append(&c, a.qemu, "-machine", machine, "-cpu", "max")
	if o.iommu != .Off && a.kind == .X86_64 {
		// No interrupt remapping yet. Virtio devices go through the IOMMU only
		// with iommu_platform=on (below), and then their drivers must accept
		// VIRTIO_F_ACCESS_PLATFORM.
		append(&c, "-device", o.iommu == .Caching ? "intel-iommu,intremap=off,caching-mode=on" : "intel-iommu,intremap=off")
	}
	platform := o.iommu != .Off ? ",iommu_platform=on" : ""
	append(&c, "-drive", fmt.tprintf("if=pflash,format=raw,unit=0,readonly=on,file=%s", a.firmware))
	// The variable store, as upstream's runner gives it: without one the
	// firmware keeps its variables in an NvVars file on the ESP.
	append(&c, "-drive", fmt.tprintf("if=pflash,format=raw,unit=1,snapshot=on,file=%s", a.vars))
	append(&c, "-m", "512M", "-smp", "4", "-display", "none", "-no-reboot")
	if o.cdrom != "" {
		// On virtio-scsi, which both architectures' firmware boots from.
		append(&c, "-drive", fmt.tprintf("if=none,id=cd,media=cdrom,readonly=on,file=%s", o.cdrom))
		append(&c, "-device", "virtio-scsi-pci,id=scsi,disable-legacy=on", "-device", "scsi-cd,drive=cd,bus=scsi.0")
	} else {
		// A test never writes the image, so several can boot one image at once.
		append(&c, "-drive", fmt.tprintf("if=none,id=disk,format=raw,file=%s%s", image, o.test && !o.persist ? ",snapshot=on" : ""))
		append(&c, "-device", fmt.tprintf("virtio-blk-pci,drive=disk,disable-legacy=on%s", platform))
	}
	if o.disk != "" { // after the boot disk, so devmgr finds it second: /srv/disk1
		append(&c, "-drive", fmt.tprintf("if=none,id=disk1,format=raw,discard=unmap,file=%s", o.disk))
		if o.nvme {
			append(&c, "-device", "nvme,drive=disk1,serial=vxdisk1")
		} else {
			append(&c, "-device", fmt.tprintf("virtio-blk-pci,drive=disk1,disable-legacy=on%s", platform))
		}
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
	append(&c, "-device", fmt.tprintf("virtio-net-pci,netdev=net0,disable-legacy=on%s", platform))
	if o.rtc != "" {
		append(&c, "-rtc", fmt.tprintf("base=%s", o.rtc))
	}
	if o.test {
		append(&c, "-serial", "stdio", "-monitor", "none")
	} else {
		append(&c, "-serial", "mon:stdio")
	}
	return c[:]
}
