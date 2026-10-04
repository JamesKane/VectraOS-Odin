package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// A program's own assembly, beside lib/rt's: DIR/arch/ARCH/*.S, assembled
// as compile_ir assembles lib/rt's. bus-acpi's port I/O at 16 and 32 bits,
// which lib/rt does not give, is the first (ADR-0012).
program_asm :: proc(a: ^Arch, p: Program, out: string) -> (objs: [dynamic]string, ok: bool) {
	objs = make([dynamic]string, context.temp_allocator)
	dir := fmt.tprintf("%s/arch/%s", p.dir, a.name)
	if !os.is_dir(dir) {
		return objs, true
	}
	prefix_map := file_prefix_map() or_return
	cmds := make([dynamic][]string, context.temp_allocator)
	files := tree_files(dir) or_return
	for s in files {
		if !strings.has_suffix(s, ".S") {
			continue
		}
		o := fmt.tprintf("%s/obj/own_%s_S.o", out, filepath.stem(s))
		append(&cmds, concat({CLANG, fmt.tprintf("--target=%s", a.clang_target), "-g", prefix_map, "-c", s, "-o", o}))
		append(&objs, o)
	}
	run_parallel(cmds[:]) or_return
	return objs, true
}
