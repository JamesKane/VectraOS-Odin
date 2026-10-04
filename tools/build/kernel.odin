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
	run(oc[:]) or_return
	scrub_ir(ir) or_return

	cmds := make([dynamic][]string, context.temp_allocator)
	lls := tree_files(ir) or_return
	for ll in lls {
		if !strings.has_suffix(ll, ".ll") {
			continue
		}
		o := fmt.tprintf("%s/%s.o", obj, filepath.stem(ll))
		l := cmd_make(LLC, "--frame-pointer=all", MODES[mode].llc_opt, "-relocation-model=static", "-filetype=obj")
		append(&l, ..llc_flags)
		append(&l, ll, "-o", o)
		append(&cmds, l[:])
		append(&objs, o)
	}
	asm_files := tree_files(asm_dir) or_return
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

// Makes Odin's IR reproducible, so one commit always gives the same kernel:
//  - Odin writes the wall-clock time into the debug info as the value of
//    ODIN_COMPILE_TIMESTAMP, ignoring SOURCE_DATE_EPOCH; SOURCE_DATE_EPOCH
//    goes there instead. Nothing first-party uses it in code.
//  - Procedure-local statics are named after an entity number that varies
//    from run to run (`proc-.state-4433`). They are internal to their module,
//    so they are renumbered by order of first appearance.
scrub_ir :: proc(ir: string) -> bool {
	files := tree_files(ir) or_return
	for f in files {
		if strings.has_suffix(f, ".ll") {
			text := read_file(f) or_return
			if renamed, changed := renumber_statics(text); changed {
				write_file(f, renamed) or_return
			}
		}
	}
	return scrub_timestamp(ir)
}

// Renames every @"...-.name-DIGITS" global to @"...-.name-K", K counting from
// 0 in order of first appearance in the module.
@(private="file")
renumber_statics :: proc(text: string) -> (string, bool) {
	b := strings.builder_make(context.temp_allocator)
	seen := make(map[string]int, allocator = context.temp_allocator)
	changed := false
	rest := text
	for {
		i := strings.index(rest, `@"`)
		if i < 0 {
			break
		}
		strings.write_string(&b, rest[:i + 2])
		rest = rest[i + 2:]
		end := strings.index_byte(rest, '"')
		if end < 0 {
			break
		}
		name := rest[:end]
		dash := strings.last_index_byte(name, '-')
		digits := dash >= 0 ? name[dash + 1:] : ""
		is_static := dash > 0 && len(digits) > 0 && strings.contains(name[:dash], "-.")
		for c in digits {
			if c < '0' || c > '9' {
				is_static = false
			}
		}
		if is_static {
			k, ok := seen[name]
			if !ok {
				k = len(seen)
				seen[name] = k
			}
			fmt.sbprintf(&b, "%s-%d", name[:dash], k)
			changed = true
		} else {
			strings.write_string(&b, name)
		}
		rest = rest[end:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b), changed
}

@(private="file")
scrub_timestamp :: proc(ir: string) -> bool {
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
