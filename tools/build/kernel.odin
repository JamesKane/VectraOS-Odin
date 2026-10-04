package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// The kernel's pipeline (ADR-0003): Odin emits LLVM IR per package; llc
// makes the objects with a frame pointer in every function; clang assembles
// the entry stubs; ld.lld links them with the linker script.

// The kernel's and every program's flags for odin.
IR_ODIN_FLAGS :: []string {
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
	// Reproducible IR: the threaded checker numbers entities and orders debug
	// metadata differently from one run to the next.
	"-no-threaded-checker",
	"-thread-count:1",
}

// Compiles an Odin package to objects: odin to IR, scrub_ir, llc per
// module, and clang for each .S file under asm_dir. out (emptied first)
// holds the ir and obj directories. Returns the objects in link order.
compile_ir :: proc(a: ^Arch, mode: Mode, pkg, asm_dir, out: string, odin_flags, llc_flags: []string) -> (objs: [dynamic]string, ok: bool) {
	ir := fmt.tprintf("%s/ir", out)
	obj := fmt.tprintf("%s/obj", out)
	objs = make([dynamic]string, context.temp_allocator)
	_ = os.remove_all(out)
	make_dirs(ir) or_return
	make_dirs(obj) or_return

	oc := cmd_make(ODIN, "build", pkg, fmt.tprintf("-target:%s", a.odin_target), fmt.tprintf("-out:%s", ir))
	append(&oc, ..IR_ODIN_FLAGS)
	append(&oc, ..odin_flags)
	append(&oc, MODES[mode].odin_opt)
	// One module per package in every mode, as -o:minimal makes by default.
	// -o:speed alone makes a single module, written as ir/.ll (so its object
	// was obj/.o), and in it a program's exported vx_main and lib/rt's
	// foreign declaration of it share one LLVM name: odin emits only the
	// declaration, and _start calls an undefined vx_main.
	append(&oc, "-use-separate-modules")
	run(oc[:]) or_return
	scrub_ir(ir) or_return

	cmds := make([dynamic][]string, context.temp_allocator)
	lls := tree_files(ir) or_return
	for ll in lls {
		if !strings.has_suffix(ll, ".ll") {
			continue
		}
		o := fmt.tprintf("%s/%s.o", obj, filepath.stem(ll))
		l := cmd_make(LLC, "--frame-pointer=all", "--enable-shrink-wrap=false", MODES[mode].llc_opt, "-relocation-model=static", "-filetype=obj")
		append(&l, ..llc_flags)
		append(&l, ll, "-o", o)
		append(&cmds, l[:])
		append(&objs, o)
	}
	prefix_map := file_prefix_map() or_return
	asm_files := tree_files(asm_dir) or_return
	for s in asm_files {
		if !strings.has_suffix(s, ".S") {
			continue
		}
		o := fmt.tprintf("%s/%s_S.o", obj, filepath.stem(s))
		c := cmd_make(CLANG, fmt.tprintf("--target=%s", a.clang_target), "-g", prefix_map, "-c", s, "-o", o)
		append(&cmds, c[:])
		append(&objs, o)
	}
	run_parallel(cmds[:]) or_return
	return objs, true
}

build_kernel :: proc(a: ^Arch, mode: Mode) -> (elf: string, ok: bool) {
	out := fmt.tprintf("%s/kernel", out_dir(a, mode))
	elf = fmt.tprintf("%s/kernel.elf", out_dir(a, mode))
	fmt.eprintfln("  KERN  %s %s", a.name, MODES[mode].name)
	objs := compile_ir(a, mode, "kernel", fmt.tprintf("kernel/arch/%s", a.name), out, a.kernel_odin_flags, a.kernel_llc_flags) or_return

	// Link twice: first with an empty symbol map, to learn the addresses, then
	// with the real one, which panic backtraces read. The map is last in
	// .rodata, after all code, so its size moves no function.
	map_s := fmt.tprintf("%s/symbols.S", out)
	map_o := fmt.tprintf("%s/symbols.o", out)
	nomap := fmt.tprintf("%s/kernel_nomap.elf", out)
	for pass in 0 ..< 2 {
		write_symbol_map(pass == 0 ? "" : nomap, map_s, ".section .vx_symbols, \"a\"", "vx_symbols", "kernel::") or_return
		run({CLANG, fmt.tprintf("--target=%s", a.clang_target), "-c", map_s, "-o", map_o}) or_return
		ld := cmd_make(LLD, "-nostdlib", "-static", "-z", "max-page-size=0x1000", "--build-id", "-T", fmt.tprintf("kernel/linker/%s.ld", a.name), "-o", pass == 0 ? nomap : elf)
		append(&ld, ..objs[:])
		append(&ld, map_o)
		run(ld[:]) or_return
	}
	return elf, true
}

// Makes Odin's IR reproducible, so one commit always gives the same kernel
// and programs, wherever the tree is checked out:
//  - ir_canonicalize (ircanon.odin) puts what Odin emits in an order and
//    numbering that does not vary from run to run, and maps the repository
//    root to /src in the debug info and source-location strings;
//  - Odin writes the wall-clock time into the debug info as the value of
//    ODIN_COMPILE_TIMESTAMP, ignoring SOURCE_DATE_EPOCH; SOURCE_DATE_EPOCH
//    goes there instead. Nothing first-party uses it in code.
scrub_ir :: proc(ir: string) -> bool {
	epoch := os.get_env("SOURCE_DATE_EPOCH", context.temp_allocator)
	stamp := fmt.tprintf("%s000000000", epoch == "" ? "0" : epoch)
	root, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot find the working directory: %v", err)
		return false
	}
	all := tree_files(ir) or_return
	paths := make([dynamic]string, context.temp_allocator)
	texts := make([dynamic]string, context.temp_allocator)
	for f in all {
		if strings.has_suffix(f, ".ll") {
			append(&paths, f)
			append(&texts, read_file(f) or_return)
		}
	}
	canon := ir_canonicalize(paths[:], texts[:], root) or_return
	for f, i in paths {
		stamped, _ := scrub_timestamp(canon[i], stamp)
		write_file(f, stamped) or_return
	}
	return true
}

@(private="file")
scrub_timestamp :: proc(text, stamp: string) -> (string, bool) {
	if !strings.contains(text, `name: "ODIN_COMPILE_TIMESTAMP"`) {
		return text, false
	}
	lines := strings.split_lines(text, context.temp_allocator)
	vars := make([dynamic]string, context.temp_allocator) // "!203", the variables' metadata ids
	for l in lines {
		if strings.contains(l, `DIGlobalVariable(name: "ODIN_COMPILE_TIMESTAMP"`) {
			if sp := strings.index_byte(l, ' '); sp > 0 {
				append(&vars, l[:sp])
			}
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
			if n := strings.index_byte(l[start:], ','); n >= 0 {
				l = strings.concatenate({l[:start], stamp, l[start + n:]}, context.temp_allocator)
			}
		}
	}
	return strings.join(lines, "\n", context.temp_allocator), true
}
