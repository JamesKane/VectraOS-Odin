package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Native ports: vendored C that a first-party Odin program links, built
// freestanding as upstream builds its native programs (not against musl),
// once per architecture, into an archive (ACPICA for bus-acpi, ADR-0012).
// ports/NAME/port.ndb says native=yes, and gives the flags and the sources;
// a Program names the port in native=. Such a program may also have
// assembly of its own in DIR/arch/ARCH/*.S, assembled beside lib/rt's.
//
// tools/build/cobj.odin is to give vendored C archives a general mechanism
// (Monocypher's); this file is bus-acpi's until the two are reconciled.

// Upstream's flags for native programs (its USER_FLAGS and the
// architectures' user_flags), before port.ndb's cflags=.
NATIVE_FLAGS :: []string{"-ffreestanding", "-fno-pic", "-fstack-protector-strong", "-mstack-protector-guard=global"}
NATIVE_ARCH_FLAGS := [Arch_Kind][]string {
	.X86_64  = {"-fcf-protection=full"},
	.AArch64 = {"-mbranch-protection=standard"},
}

// The archive of native port `name` for an architecture, built if the cache
// does not hold it: out/NAME/ARCH/libNAME.a.
native_port_archive :: proc(a: ^Arch, name: string) -> (lib: string, ok: bool) {
	p := port_load(name) or_return
	if val(p.head, "native") != "yes" {
		fmt.eprintfln("ports/%s/port.ndb: not a native port (native=yes)", name)
		return "", false
	}
	// The port's own headers (acvectra.h) are inputs too.
	p.input_hash = hash_tree(p.input_hash, p.dir) or_return
	srcs := make([dynamic]Source, context.temp_allocator)
	for rel in words(val(p.head, "sources")) {
		append(&srcs, Source{rel = rel})
	}
	if len(srcs) == 0 {
		fmt.eprintfln("ports/%s/port.ndb: no sources=", name)
		return "", false
	}
	flags := concat({fmt.tprintf("--target=%s", a.clang_target)}, NATIVE_ARCH_FLAGS[a.kind], NATIVE_FLAGS, words(val(p.head, "cflags")))
	objs := build_cached(&p, a, flags, srcs[:]) or_return

	outdir := fmt.tprintf("out/%s/%s", name, a.name)
	lib = fmt.tprintf("%s/lib%s.a", outdir, name)
	stamp := fmt.tprintf("%s.stamp", lib)
	key := fmt.tprintf("%016x\n", p.input_hash)
	if os.exists(lib) && os.exists(stamp) {
		if got, _ := read_file(stamp); got == key {
			return lib, true
		}
	}
	archive(lib, fmt.tprintf("%s/obj", outdir), objs) or_return
	write_file(stamp, key) or_return
	return lib, true
}

// What a program links beyond its Odin objects: its own assembly
// (DIR/arch/ARCH/*.S), and its native port's archive, last.
native_link_inputs :: proc(a: ^Arch, p: Program, out: string) -> (inputs: [dynamic]string, ok: bool) {
	inputs = make([dynamic]string, context.temp_allocator)
	asm_dir := fmt.tprintf("%s/arch/%s", p.dir, a.name)
	if os.is_dir(asm_dir) {
		prefix_map := file_prefix_map() or_return
		obj := fmt.tprintf("%s/obj", out)
		cmds := make([dynamic][]string, context.temp_allocator)
		files := tree_files(asm_dir) or_return
		for s in files {
			if !strings.has_suffix(s, ".S") {
				continue
			}
			o := fmt.tprintf("%s/own_%s_S.o", obj, filepath.stem(s))
			append(&cmds, concat({CLANG, fmt.tprintf("--target=%s", a.clang_target), "-g", prefix_map, "-c", s, "-o", o}))
			append(&inputs, o)
		}
		run_parallel(cmds[:]) or_return
	}
	if p.native != "" {
		append(&inputs, native_port_archive(a, p.native) or_return)
	}
	return inputs, true
}
