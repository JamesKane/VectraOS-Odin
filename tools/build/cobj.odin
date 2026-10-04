package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Vendored C in Odin programs (ADR-0007's pattern; ADR-0011): a native port
// is C that an Odin package calls through the C ABI, behind a thin Odin
// layer that declares the C functions in a `foreign _` block (lib/crypto).
// The port's ports/NAME/port.ndb is upstream's form:
//
//   port=NAME src=third_party/NAME native=yes archive=yes
//       cflags="..."            its own flags, paths from the repository root
//       sources="a.c b/c.c"     relative to src=
//
// Its sources become one static archive per target, so a program takes only
// the members it uses:
//
//  - for an architecture, out/NAME/ARCH/libNAME.a: compiled once per
//    architecture (both modes link it) with the freestanding flags Odin
//    programs are built with, then the port's cflags, and cached as musl is
//    (its stamp is the port's input hash). A program links it after its own
//    objects when its Program entry names the port in cports (program.odin).
//  - for this machine, out/NAME/host/libNAME.a, for host tests and tools: a
//    package under tests/host that says `// host-links: NAME` in any of its
//    files is linked with it (cmd_check), and host tools pass
//    cobj_host_link_flags to odin.
//
// The archive is the only coupling: an Odin package never names a path to
// it, so `odin check` of a library needs nothing built.

// What a native port compiles with on an architecture, before its cflags:
// freestanding, static and not PIC, as Odin's objects are. No stack
// protector: Odin programs define no __stack_chk_guard.
@(private="file")
COBJ_TARGET_FLAGS :: []string{"-ffreestanding", "-fno-pic", "-fno-stack-protector", "-g"}

// And on this machine: position-independent, so it links into Odin's host
// executables whether or not they are PIE.
@(private="file")
COBJ_HOST_FLAGS :: []string{"-fPIC", "-g"}

// Loads ports/NAME/port.ndb and checks it is a native port.
cobj_load :: proc(name: string) -> (p: Port, ok: bool) {
	p = port_load(name) or_return
	if val(p.head, "native") != "yes" || val(p.head, "archive") != "yes" {
		fmt.eprintfln("%s/port.ndb: a port linked into Odin code needs native=yes archive=yes", p.dir)
		return p, false
	}
	if len(words(val(p.head, "sources"))) == 0 {
		fmt.eprintfln("%s/port.ndb: no sources=", p.dir)
		return p, false
	}
	return p, true
}

// The port's archive for an architecture, built unless the cache has it.
cobj_archive :: proc(name: string, a: ^Arch) -> (lib: string, ok: bool) {
	p := cobj_load(name) or_return
	return cobj_build(&p, a.name, concat({CLANG, fmt.tprintf("--target=%s", a.clang_target)}, COBJ_TARGET_FLAGS))
}

// The port's archive for this machine, built unless the cache has it.
cobj_host_archive :: proc(name: string) -> (lib: string, ok: bool) {
	p := cobj_load(name) or_return
	return cobj_build(&p, "host", concat({CLANG}, COBJ_HOST_FLAGS))
}

// The archives a program links: each port its entry names, in that order.
cobj_program_archives :: proc(prog: Program, a: ^Arch) -> (libs: [dynamic]string, ok: bool) {
	libs = make([dynamic]string, context.temp_allocator)
	for name in prog.cports {
		append(&libs, cobj_archive(name, a) or_return)
	}
	return libs, true
}

// The ports the Odin files directly in dir name in `// host-links: NAME`
// lines (several names may share a line), in the order they appear.
cobj_host_links :: proc(dir: string) -> (names: [dynamic]string, ok: bool) {
	names = make([dynamic]string, context.temp_allocator)
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read %s: %v", dir, err)
		return names, false
	}
	MARK :: "// host-links:"
	for e in entries {
		if e.type != .Regular || !strings.has_suffix(e.name, ".odin") {
			continue
		}
		text := read_file(fmt.tprintf("%s/%s", dir, e.name)) or_return
		for line in strings.split_lines_iterator(&text) {
			if !strings.has_prefix(line, MARK) {
				continue
			}
			for n in words(line[len(MARK):]) {
				if !slice.contains(names[:], n) {
					append(&names, n)
				}
			}
		}
	}
	return names, true
}

// odin's flag linking each named port's host archive; none for no ports.
cobj_host_link_flags :: proc(names: []string) -> (flags: [dynamic]string, ok: bool) {
	flags = make([dynamic]string, context.temp_allocator)
	libs := make([dynamic]string, context.temp_allocator)
	for n in names {
		append(&libs, cobj_host_archive(n) or_return)
	}
	if len(libs) > 0 {
		append(&flags, fmt.tprintf("-extra-linker-flags:%s", strings.join(libs[:], " ", context.temp_allocator)))
	}
	return flags, true
}

// Compiles the port's sources with cc (the compiler and the target's flags)
// and its cflags into out/NAME/TARGET/obj, and archives them as
// out/NAME/TARGET/libNAME.a, unless the stamp there says the port's inputs
// are unchanged since.
@(private="file")
cobj_build :: proc(p: ^Port, target: string, cc: []string) -> (lib: string, ok: bool) {
	outdir := fmt.tprintf("out/%s/%s", p.name, target)
	objdir := fmt.tprintf("%s/obj", outdir)
	lib = fmt.tprintf("%s/lib%s.a", outdir, p.name)
	stamp := fmt.tprintf("%s/stamp", outdir)
	key := fmt.tprintf("%016x\n", p.input_hash)
	if os.exists(lib) && os.exists(stamp) {
		if got, _ := read_file(stamp); got == key {
			return lib, true
		}
	}
	if os.exists(stamp) {
		if err := os.remove(stamp); err != nil {
			fmt.eprintfln("build: cannot remove %s: %v", stamp, err)
			return lib, false
		}
	}
	prefix_map := file_prefix_map() or_return
	cflags := words(val(p.head, "cflags"))
	cmds := make([dynamic][]string, context.temp_allocator)
	objs := make([dynamic]string, context.temp_allocator)
	for rel in words(val(p.head, "sources")) {
		o := object_for(objdir, rel)
		make_dirs(filepath.dir(o)) or_return
		append(&cmds, concat(cc, cflags, {prefix_map, "-c", source_path(p, rel), "-o", o}))
		append(&objs, o)
	}
	fmt.eprintfln("  PORT  %s  %s (%d files)", p.name, target, len(cmds))
	run_parallel(cmds[:]) or_return
	archive(lib, objdir, objs[:]) or_return
	write_file(stamp, key) or_return
	return lib, true
}
