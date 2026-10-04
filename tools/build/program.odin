package build

import "core:fmt"
import "core:path/filepath"

// User programs: Odin packages built as static, non-PIE ELF files against
// lib/rt, through the same IR pipeline as the kernel (frame pointers in
// every function, reproducible IR); and C programs against musl, the POSIX
// personality (posix.odin).

Program_Place :: enum {
	Module, // on the ESP, a Limine module: the root task's candidates
	Bootfs, // in bootfs.tar
	Tests, // in bootfs.tar for a scenario that names it (with=), with tests/user/NAME.ndb
}

Program_Kind :: enum {
	Odin, // dir is the package
	C, // source is the file, built against the vectra-musl sysroot (build_c_program)
}

Program :: struct {
	name:   string,
	dir:    string,
	source: string,
	kind:   Program_Kind,
	place:  Program_Place,
	only:   bit_set[Arch_Kind], // built for these architectures only; none means all
	cports: []string, // native ports whose archives it links (cobj.odin)
}

PROGRAMS := []Program {
	// In upstream's order, which bootfs.tar keeps: ls /boot/bin shows it.
	{name = "svcd", dir = "servers/svcd", place = .Module},
	{name = "ktest", dir = "tests/kernel/ktest", place = .Module},
	{name = "bootfs", dir = "servers/bootfs", place = .Bootfs},
	{name = "bus-acpi", dir = "servers/bus-acpi", place = .Bootfs, cports = {"acpica"}},
	{name = "nstest", dir = "tests/user/nstest", place = .Tests},
	{name = "constest", dir = "tests/user/constest", place = .Tests},
	{name = "nettest", dir = "tests/user/nettest", place = .Tests},
	{name = "tcptest", dir = "tests/user/tcptest", place = .Tests},
	{name = "proctest", dir = "tests/user/proctest", place = .Tests},
	{name = "procfs", dir = "servers/procfs", place = .Bootfs},
	{name = "nsd", dir = "servers/nsd", place = .Bootfs},
	{name = "tmpfs", dir = "servers/tmpfs", place = .Bootfs},
	{name = "nullfs", dir = "servers/nullfs", place = .Bootfs},
	{name = "sysfs", dir = "servers/sysfs", place = .Bootfs},
	{name = "ptyd", dir = "servers/ptyd", place = .Bootfs},
	{name = "devmgr", dir = "servers/devmgr", place = .Bootfs},
	{name = "netd", dir = "servers/netd", place = .Bootfs},
	{name = "gsh", dir = "cmd/gsh", place = .Bootfs},
	{name = "poweroff", dir = "cmd/poweroff", place = .Bootfs},
	{name = "install", dir = "cmd/install", place = .Bootfs, cports = {"monocypher"}},
	{name = "ls", dir = "cmd/ls", place = .Bootfs},
	{name = "cat", dir = "cmd/cat", place = .Bootfs},
	{name = "echo", dir = "cmd/echo", place = .Bootfs},
	{name = "ps", dir = "cmd/ps", place = .Bootfs},
	{name = "ns", dir = "cmd/ns", place = .Bootfs},
	{name = "tail", dir = "cmd/tail", place = .Bootfs},
	{name = "ping", dir = "cmd/ping", place = .Bootfs},
	{name = "cs", dir = "cmd/cs", place = .Bootfs},
	{name = "dbg", dir = "cmd/dbg", place = .Bootfs},
	{name = "drv-uart-16550", dir = "drivers/drv-uart-16550", place = .Bootfs, only = {.X86_64}},
	{name = "drv-rtc-cmos", dir = "drivers/drv-rtc-cmos", place = .Bootfs, only = {.X86_64}},
	{name = "drv-uart-pl011", dir = "drivers/drv-uart-pl011", place = .Bootfs, only = {.AArch64}},
	{name = "drv-virtio-net", dir = "drivers/drv-virtio-net", place = .Bootfs},
	{name = "dosfs", dir = "servers/dosfs", place = .Bootfs},
	{name = "isofs", dir = "servers/isofs", place = .Bootfs},
	{name = "distd", dir = "servers/distd", place = .Bootfs, cports = {"monocypher"}},
	{name = "ctest", source = "tests/posix/ctest.c", place = .Tests, kind = .C},
	{name = "sbasetest", source = "tests/posix/sbasetest.c", place = .Tests, kind = .C},
	// dbg's fixture, as upstream builds it but against musl: its own
	// functions are optnone, and the house flags give -g and frame pointers.
	// Its lib/vx-rt/rt.c is this tree's stand-in for upstream's runtime.
	{name = "dbgdemo", source = "tests/user/dbgdemo.c", place = .Tests, kind = .C},
}

program_path :: proc(a: ^Arch, mode: Mode, name: string) -> string {
	return fmt.tprintf("%s/bin/%s", out_dir(a, mode), name)
}

build_program :: proc(a: ^Arch, mode: Mode, p: Program) -> (elf: string, ok: bool) {
	elf = program_path(a, mode, p.name)
	make_dirs(filepath.dir(elf)) or_return
	fmt.eprintfln("  PROG  %s %s", p.name, a.name)
	out := fmt.tprintf("%s/prog/%s", out_dir(a, mode), p.name)
	objs := compile_ir(a, mode, p.dir, fmt.tprintf("lib/rt/arch/%s", a.name), out, nil, nil) or_return
	extra := program_asm(a, p, out) or_return
	append(&objs, ..extra[:])

	ld := cmd_make(LLD, "-nostdlib", "-static", "-z", "max-page-size=0x1000", "--build-id", "-T", fmt.tprintf("lib/rt/linker/%s.ld", a.name), "-o", elf)
	append(&ld, ..objs[:])
	libs := cobj_program_archives(p, a) or_return
	append(&ld, ..libs[:])
	run(ld[:]) or_return
	return elf, true
}

program_for :: proc(p: Program, a: ^Arch) -> bool {
	return p.only == {} || a.kind in p.only
}

// Every program for an architecture: the Odin ones, then the POSIX ones
// (build_posix: the C programs here, and the ports' programs), linked against
// the back end, or with backend_override the objects in it.
build_programs :: proc(a: ^Arch, mode: Mode, backend_override := "") -> bool {
	for p in PROGRAMS {
		if p.kind == .Odin && program_for(p, a) {
			build_program(a, mode, p) or_return
		}
	}
	ps := posix_load() or_return
	return build_posix(&ps, a, mode, backend_override)
}
