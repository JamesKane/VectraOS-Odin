package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The kernel's pipeline (ADR-0003): Odin emits LLVM IR per package; llc
// makes the objects with a frame pointer in every function; clang assembles
// the entry stubs; ld.lld links them with the linker script.

KERNEL_ODIN_FLAGS := []string {
	"-build-mode:llvm-ir",
	"-no-crt",
	"-default-to-nil-allocator",
	"-disable-init-fini",
	"-no-rtti",
	"-no-thread-local",
	"-reloc-mode:static",
	"-debug",
	"-vet",
	"-vet-shadowing",
	"-strict-style",
	"-warnings-as-errors",
	"-collection:vx=lib",
	// Reproducible IR: the threaded checker numbers entities and orders debug
	// metadata differently from one run to the next.
	"-no-threaded-checker",
	"-thread-count:1",
}

build_kernel :: proc(a: ^Arch, mode: Mode) -> (elf: string, ok: bool) {
	out := fmt.tprintf("%s/kernel", out_dir(a, mode))
	ir := fmt.tprintf("%s/ir", out)
	obj := fmt.tprintf("%s/obj", out)
	elf = fmt.tprintf("%s/kernel.elf", out_dir(a, mode))
	_ = os.remove_all(out)
	make_dirs(ir) or_return
	make_dirs(obj) or_return

	fmt.eprintfln("  KERN  %s %s", a.name, mode == .Release ? "release" : "debug")
	oc := cmd_make(ODIN, "build", "kernel", fmt.tprintf("-target:%s", a.odin_target), fmt.tprintf("-out:%s", ir))
	append(&oc, ..KERNEL_ODIN_FLAGS)
	append(&oc, ..a.odin_flags)
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
		l := cmd_make(LLC, "--frame-pointer=all", mode == .Release ? "-O2" : "-O1", "-relocation-model=static", "-filetype=obj")
		append(&l, ..a.llc_flags)
		append(&l, ll, "-o", o)
		append(&cmds, l[:])
		append(&objs, o)
	}
	asm_files := tree_files(fmt.tprintf("kernel/arch/%s", a.name)) or_return
	for s in asm_files {
		if !strings.has_suffix(s, ".S") {
			continue
		}
		o := fmt.tprintf("%s/%s_S.o", obj, filepath.stem(s))
		c := cmd_make(CLANG, fmt.tprintf("--target=%s", a.clang_target), "-g", "-c", s, "-o", o)
		append(&cmds, c[:])
		append(&objs, o)
	}
	run_parallel(cmds[:]) or_return

	ld := cmd_make(LLD, "-nostdlib", "-static", "-z", "max-page-size=0x1000", "--build-id", "-T", fmt.tprintf("kernel/linker/%s.ld", a.name), "-o", elf)
	append(&ld, ..objs[:])
	run(ld[:]) or_return
	return elf, true
}

// Odin writes the wall-clock time into the debug info as the value of
// ODIN_COMPILE_TIMESTAMP, and ignores SOURCE_DATE_EPOCH. This puts
// SOURCE_DATE_EPOCH there instead, so one commit always gives the same
// kernel. Nothing first-party uses ODIN_COMPILE_TIMESTAMP in code.
scrub_ir :: proc(ir: string) -> bool {
	epoch := os.get_env("SOURCE_DATE_EPOCH", context.temp_allocator)
	stamp := fmt.tprintf("%s000000000", epoch == "" ? "0" : epoch)
	files := tree_files(ir) or_return
	for f in files {
		if !strings.has_suffix(f, ".ll") {
			continue
		}
		text := read_file(f) or_return
		if !strings.contains(text, `name: "ODIN_COMPILE_TIMESTAMP"`) {
			continue
		}
		lines := strings.split_lines(text, context.temp_allocator)
		vars := make([dynamic]string, context.temp_allocator) // "!203", the variables' metadata ids
		for l in lines {
			if strings.contains(l, `DIGlobalVariable(name: "ODIN_COMPILE_TIMESTAMP"`) {
				append(&vars, l[:strings.index_byte(l, ' ')])
			}
		}
		for &l in lines {
			for v in vars {
				key := fmt.tprintf("DIGlobalVariableExpression(var: %s, expr: !DIExpression(DW_OP_constu, ", v)
				i := strings.index(l, key)
				if i < 0 {
					continue
				}
				start := i + len(key)
				end := start + strings.index_byte(l[start:], ',')
				l = strings.concatenate({l[:start], stamp, l[end:]}, context.temp_allocator)
			}
		}
		write_file(f, strings.join(lines, "\n", context.temp_allocator)) or_return
	}
	return true
}
