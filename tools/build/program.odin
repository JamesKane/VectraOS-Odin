package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

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
	arch:  string, // built for this architecture only; "" for both
}

PROGRAMS := []Program {
	// In upstream's order, which bootfs.tar keeps: ls /boot/bin shows it.
	{name = "svcd", dir = "servers/svcd", place = .Module},
	{name = "ktest", dir = "tests/kernel/ktest", place = .Module},
	{name = "bootfs", dir = "servers/bootfs", place = .Bootfs},
	{name = "nstest", dir = "tests/user/nstest", place = .Tests},
	{name = "constest", dir = "tests/user/constest", place = .Tests},
	{name = "procfs", dir = "servers/procfs", place = .Bootfs},
	{name = "gsh", dir = "cmd/gsh", place = .Bootfs},
	{name = "ls", dir = "cmd/ls", place = .Bootfs},
	{name = "cat", dir = "cmd/cat", place = .Bootfs},
	{name = "echo", dir = "cmd/echo", place = .Bootfs},
	{name = "ps", dir = "cmd/ps", place = .Bootfs},
	{name = "ns", dir = "cmd/ns", place = .Bootfs},
	{name = "tail", dir = "cmd/tail", place = .Bootfs},
	{name = "drv-uart-16550", dir = "drivers/drv-uart-16550", place = .Bootfs, arch = "x86_64"},
	{name = "drv-uart-pl011", dir = "drivers/drv-uart-pl011", place = .Bootfs, arch = "aarch64"},
}

USER_ODIN_FLAGS := []string {
	"-build-mode:llvm-ir",
	"-no-crt",
	"-default-to-nil-allocator",
	"-disable-init-fini",
	"-disable-non-constant-globals", // their initialisers would need the startup code -disable-init-fini drops
	"-no-rtti",
	"-no-thread-local",
	"-reloc-mode:static",
	"-debug",
	"-vet",
	"-vet-shadowing",
	"-strict-style",
	"-warnings-as-errors",
	"-collection:vx=lib",
	"-collection:abi=abi",
	"-no-threaded-checker",
	"-thread-count:1",
}

program_path :: proc(a: ^Arch, mode: Mode, name: string) -> string {
	return fmt.tprintf("%s/bin/%s", out_dir(a, mode), name)
}

build_program :: proc(a: ^Arch, mode: Mode, p: Program) -> (elf: string, ok: bool) {
	out := fmt.tprintf("%s/prog/%s", out_dir(a, mode), p.name)
	ir := fmt.tprintf("%s/ir", out)
	obj := fmt.tprintf("%s/obj", out)
	elf = program_path(a, mode, p.name)
	_ = os.remove_all(out)
	make_dirs(ir) or_return
	make_dirs(obj) or_return
	make_dirs(dir_of(elf)) or_return

	fmt.eprintfln("  PROG  %s %s", p.name, a.name)
	oc := cmd_make(ODIN, "build", p.dir, fmt.tprintf("-target:%s", a.odin_target), fmt.tprintf("-out:%s", ir))
	append(&oc, ..USER_ODIN_FLAGS)
	append(&oc, mode == .Release ? "-o:speed" : "-o:minimal")
	run(oc[:]) or_return
	scrub_ir(ir) or_return

	cmds := make([dynamic][]string, context.temp_allocator)
	objs := make([dynamic]string, context.temp_allocator)
	lls := tree_files(ir) or_return
	for ll in lls {
		if !strings.has_suffix(ll, ".ll") {
			continue
		}
		o := fmt.tprintf("%s/%s.o", obj, filepath.stem(ll))
		l := cmd_make(LLC, "--frame-pointer=all", mode == .Release ? "-O2" : "-O1", "-relocation-model=static", "-filetype=obj", ll, "-o", o)
		append(&cmds, l[:])
		append(&objs, o)
	}
	asm_files := tree_files(fmt.tprintf("lib/rt/arch/%s", a.name)) or_return
	for s in asm_files {
		if strings.has_suffix(s, ".S") {
			o := fmt.tprintf("%s/%s_S.o", obj, filepath.stem(s))
			c := cmd_make(CLANG, fmt.tprintf("--target=%s", a.clang_target), "-g", "-c", s, "-o", o)
			append(&cmds, c[:])
			append(&objs, o)
		}
	}
	run_parallel(cmds[:]) or_return

	ld := cmd_make(LLD, "-nostdlib", "-static", "-z", "max-page-size=0x1000", "--build-id", "-T", fmt.tprintf("lib/rt/linker/%s.ld", a.name), "-o", elf)
	append(&ld, ..objs[:])
	run(ld[:]) or_return
	return elf, true
}

program_for :: proc(p: Program, a: ^Arch) -> bool {
	return p.arch == "" || p.arch == a.name
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
