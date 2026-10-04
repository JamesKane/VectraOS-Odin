package build

import "core:fmt"
import "core:path/filepath"

// User programs: Odin packages built as static, non-PIE ELF files against
// lib/rt, through the same IR pipeline as the kernel (frame pointers in
// every function, reproducible IR).

Program_Place :: enum {
	Module, // on the ESP, a Limine module: the root task's candidates
	Bootfs, // in bootfs.tar
	Tests, // in bootfs.tar for a scenario that names it (with=), with tests/user/NAME.ndb
}

Program :: struct {
	name:  string,
	dir:   string,
	place: Program_Place,
	only:  bit_set[Arch_Kind], // built for these architectures only; none means all
}

PROGRAMS := []Program {
	// In upstream's order, which bootfs.tar keeps: ls /boot/bin shows it.
	{name = "svcd", dir = "servers/svcd", place = .Module},
	{name = "ktest", dir = "tests/kernel/ktest", place = .Module},
	{name = "bootfs", dir = "servers/bootfs", place = .Bootfs},
	{name = "nstest", dir = "tests/user/nstest", place = .Tests},
	{name = "constest", dir = "tests/user/constest", place = .Tests},
	{name = "nettest", dir = "tests/user/nettest", place = .Tests},
	{name = "tcptest", dir = "tests/user/tcptest", place = .Tests},
	{name = "procfs", dir = "servers/procfs", place = .Bootfs},
	{name = "devmgr", dir = "servers/devmgr", place = .Bootfs},
	{name = "netd", dir = "servers/netd", place = .Bootfs},
	{name = "gsh", dir = "cmd/gsh", place = .Bootfs},
	{name = "ls", dir = "cmd/ls", place = .Bootfs},
	{name = "cat", dir = "cmd/cat", place = .Bootfs},
	{name = "echo", dir = "cmd/echo", place = .Bootfs},
	{name = "ps", dir = "cmd/ps", place = .Bootfs},
	{name = "ns", dir = "cmd/ns", place = .Bootfs},
	{name = "tail", dir = "cmd/tail", place = .Bootfs},
	{name = "ping", dir = "cmd/ping", place = .Bootfs},
	{name = "cs", dir = "cmd/cs", place = .Bootfs},
	{name = "drv-uart-16550", dir = "drivers/drv-uart-16550", place = .Bootfs, only = {.X86_64}},
	{name = "drv-uart-pl011", dir = "drivers/drv-uart-pl011", place = .Bootfs, only = {.AArch64}},
	{name = "drv-virtio-net", dir = "drivers/drv-virtio-net", place = .Bootfs},
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

	ld := cmd_make(LLD, "-nostdlib", "-static", "-z", "max-page-size=0x1000", "--build-id", "-T", fmt.tprintf("lib/rt/linker/%s.ld", a.name), "-o", elf)
	append(&ld, ..objs[:])
	run(ld[:]) or_return
	return elf, true
}

program_for :: proc(p: Program, a: ^Arch) -> bool {
	return p.only == {} || a.kind in p.only
}

build_programs :: proc(a: ^Arch, mode: Mode) -> bool {
	for p in PROGRAMS {
		if !program_for(p, a) {
			continue
		}
		build_program(a, mode, p) or_return
	}
	return true
}
