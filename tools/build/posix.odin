package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// The POSIX personality's C side: musl (ADR-0007) and compiler-rt's builtins
// (ADR-0008) into the vectra-musl sysroot, musl's back end beside them, and C
// programs built against it: the C test fixtures, Lua (ADR-0009) and sbase
// (ADR-0010).
//
// out/ARCH/MODE/vectra-musl/lib holds what a program against musl links:
// crt1.o (the back end's), crti.o and crtn.o (musl's), libc.a (musl, and the
// back end once there is one), libclang_rt.builtins.a, and the empty libm.a
// and the rest that musl installs. Programs compile against the vendored
// headers in place (posix_flags), in the order musl's own build uses, as
// upstream's build does: the sysroot has no include directory. musl, the
// builtins and the vendored programs' objects are built once per
// architecture, at their own flags, and cached (out/NAME/ARCH); the back end,
// the archives and the links are per mode.

MUSL_EMPTY_LIBS :: []string{"m", "rt", "pthread", "crypt", "util", "xnet", "resolv", "dl"}

// First-party C against musl (the test fixtures, tests/posix): upstream's
// house flags for C, its flags for POSIX programs, and its mode flags.
C_HOUSE_FLAGS :: []string {
	"-std=c23",
	"-Wall",
	"-Wextra",
	"-Werror",
	"-Wshadow",
	"-Wvla",
	"-Wimplicit-fallthrough",
	"-fno-strict-aliasing",
	"-ftrivial-auto-var-init=zero",
	"-g",
	"-fno-omit-frame-pointer",
	"-mno-omit-leaf-frame-pointer",
}
C_POSIX_PROGRAM_FLAGS :: []string{"-fstack-protector-strong"}
C_MODE_FLAGS := [Mode][]string {
	// Debug traps on undefined behaviour, at -O0.
	.Debug   = {"-O0", "-fsanitize=undefined", "-fno-sanitize=function", "-fsanitize-trap=undefined"},
	.Release = {"-O2"},
}

// How every C program against musl is linked: static, not PIE, from _start.
POSIX_LD_FLAGS :: []string{"-static", "-nostdlib", "--build-id=sha1", "-z", "max-page-size=0x1000", "-z", "noexecstack", "-e", "_start"}

// The back end: an Odin package, with its assembly in arch/ARCH.
BACKEND_PKG :: "ports/musl/vx"

Posix_Ports :: struct {
	musl, compiler_rt, lua, sbase: Port,
}

// Loads the ports and keys each cache on all it reads: musl's also on the
// back end's syscall_arch.h and the generated headers, sbase's on its
// generated files, and every port compiled against musl's headers on musl's.
posix_load :: proc() -> (ps: Posix_Ports, ok: bool) {
	ps.musl = port_load("musl") or_return
	ps.compiler_rt = port_load("compiler-rt") or_return
	ps.lua = port_load("lua") or_return
	ps.sbase = port_load("sbase") or_return
	ps.musl.input_hash = hash_tree(ps.musl.input_hash, fmt.tprintf("%s/arch/generic", BACKEND_PKG)) or_return
	ps.musl.input_hash = hash_tree(ps.musl.input_hash, "ports/musl/generated") or_return
	ps.sbase.input_hash = hash_tree(ps.sbase.input_hash, "ports/sbase/generated") or_return
	for p in ([]^Port{&ps.compiler_rt, &ps.lua, &ps.sbase}) {
		p.input_hash = fnv(p.input_hash, fmt.tprintf("%016x", ps.musl.input_hash))
	}
	return ps, true
}

posix_target :: proc(a: ^Arch) -> string {
	return fmt.tprintf("--target=%s-vectra-unknown-musl", a.name)
}

// The target and include path of everything compiled against musl. The
// triple defines neither __linux__ nor __unix__.
posix_flags :: proc(a: ^Arch) -> []string {
	c := cmd_make(posix_target(a), "-nostdinc", "-isystem", CLANG_RESOURCE_INCLUDE)
	append(&c, "-isystem", fmt.tprintf("third_party/musl/arch/%s", a.name), "-isystem", "third_party/musl/arch/generic")
	append(&c, "-isystem", fmt.tprintf("ports/musl/generated/%s/include", a.name), "-isystem", "third_party/musl/include")
	return c[:]
}

// musl's own compile: the target, port.ndb's flags, then the Makefile's
// include path (CFLAGS_ALL) with the back end's syscall_arch.h first.
musl_flags :: proc(musl: ^Port, a: ^Arch) -> []string {
	c := cmd_make(posix_target(a))
	append(&c, ..words(val(musl.head, "cflags")))
	append(&c, fmt.tprintf("-I%s/arch/generic", BACKEND_PKG))
	append(&c, fmt.tprintf("-I%s/arch/%s", musl.src, a.name), fmt.tprintf("-I%s/arch/generic", musl.src))
	append(&c, "-Iports/musl/generated/internal", fmt.tprintf("-I%s/src/include", musl.src), fmt.tprintf("-I%s/src/internal", musl.src))
	append(&c, fmt.tprintf("-Iports/musl/generated/%s/include", a.name), fmt.tprintf("-I%s/include", musl.src))
	return c[:]
}

// One file of a port: its path relative to the port's source (or, under
// ports/, a generated file), and its own flags after the port's.
Source :: struct {
	rel:   string,
	flags: []string,
}

// The files directly in src/rel (not below it) ending in one of exts, as
// paths relative to src, in byte order. A missing directory has none.
list_dir :: proc(src, rel: string, exts: []string) -> (out: [dynamic]string, ok: bool) {
	out = make([dynamic]string, context.temp_allocator)
	dir := fmt.tprintf("%s/%s", src, rel)
	if !os.is_dir(dir) {
		return out, true
	}
	entries, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read %s: %v", dir, err)
		return out, false
	}
	for e in entries {
		if e.type != .Regular {
			continue
		}
		for x in exts {
			if strings.has_suffix(e.name, x) {
				append(&out, fmt.tprintf("%s/%s", rel, e.name))
				break
			}
		}
	}
	slice.sort(out[:])
	return out, true
}

// musl's source set (port.ndb): the .c files directly in each directory
// under src/ and in src/malloc/mallocng, each directory's ARCH/*.c, *.s and
// *.S replacing the generic file of the same name, less exclude=; sorted by
// the object each makes ("src/x/ARCH/name.s" and "src/x/name.c" both make
// "src/x/name").
musl_sources :: proc(musl: ^Port, a: ^Arch) -> (srcs: [dynamic]Source, ok: bool) {
	t := port_target(musl, a.name) or_return
	top := fmt.tprintf("%s/src", musl.src)
	entries, err := os.read_directory_by_path(top, -1, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read %s: %v", top, err)
		return srcs, false
	}
	dirs := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.type == .Directory && !strings.has_prefix(e.name, ".") {
			append(&dirs, fmt.tprintf("src/%s", e.name))
		}
	}
	slice.sort(dirs[:])
	append(&dirs, "src/malloc/mallocng")
	generic := make([dynamic]string, context.temp_allocator)
	specific := make([dynamic]string, context.temp_allocator)
	for d in dirs {
		g := list_dir(musl.src, d, {".c"}) or_return
		s := list_dir(musl.src, fmt.tprintf("%s/%s", d, a.name), {".c", ".s", ".S"}) or_return
		append(&generic, ..g[:])
		append(&specific, ..s[:])
	}
	// Each exclusion must be in the set, so that a misspelt one fails rather
	// than leaving its file in.
	for x in words(val(t, "exclude")) {
		if i, found := slice.linear_search(specific[:], x); found {
			ordered_remove(&specific, i)
		} else if i, found = slice.linear_search(generic[:], x); found {
			ordered_remove(&generic, i)
		} else {
			fmt.eprintfln("build: musl: exclude=%s is not in the source set", x)
			return srcs, false
		}
	}

	Keyed :: struct {
		path, key: string,
	}
	arch_dir := fmt.tprintf("/%s/", a.name)
	object_key :: proc(rel, arch_dir: string) -> string {
		k, _ := strings.replace(rel, arch_dir, "/", 1, context.temp_allocator)
		return strings.trim_suffix(k, filepath.ext(k))
	}
	keyed := make([dynamic]Keyed, context.temp_allocator)
	replaced := make(map[string]bool, allocator = context.temp_allocator)
	for s in specific {
		k := object_key(s, arch_dir)
		append(&keyed, Keyed{s, k})
		replaced[k] = true
	}
	for g in generic {
		if k := object_key(g, arch_dir); !replaced[k] {
			append(&keyed, Keyed{g, k})
		}
	}
	slice.sort_by(keyed[:], proc(x, y: Keyed) -> bool {return x.key < y.key})

	// NOSSP_OBJS: by name, without directory or extension.
	nossp := words(val(musl.head, "nossp"))
	srcs = make([dynamic]Source, context.temp_allocator)
	for k in keyed {
		flags: []string
		if slice.contains(nossp, filepath.stem(k.path)) {
			flags = slice.clone([]string{"-fno-stack-protector"}, context.temp_allocator) // a literal would live in this frame
		}
		append(&srcs, Source{k.path, flags})
	}
	return srcs, true
}

// The names in each set(NAME ...) of compiler-rt's CMakeLists.txt that lists
// names, skipping comments and variables.
cmake_lists :: proc(out: ^[dynamic]string, text: string, lists: []string) -> bool {
	for name in lists {
		head := fmt.tprintf("set(%s\n", name)
		i := strings.index(text, head)
		if i < 0 {
			fmt.eprintfln("build: compiler-rt: no %s in CMakeLists.txt", strings.trim_space(head))
			return false
		}
		rest := text[i + len(head):]
		closed := false
		for line in strings.split_lines_iterator(&rest) {
			entry := strings.trim_space(line)
			if strings.has_prefix(entry, ")") {
				closed = true
				break
			}
			if entry != "" && entry[0] != '#' && entry[0] != '$' {
				append(out, entry)
			}
		}
		if !closed {
			fmt.eprintfln("build: compiler-rt: set(%s does not end", name)
			return false
		}
	}
	return true
}

// compiler-rt's builtins (port.ndb): CMakeLists.txt's lists and extra=, the
// generic files (no directory) replaced by an architecture's file of the
// same base name, as CMake's filter_builtin_sources does; in byte order.
compiler_rt_sources :: proc(rt: ^Port, a: ^Arch) -> (srcs: [dynamic]Source, ok: bool) {
	t := port_target(rt, a.name) or_return
	text := read_file(fmt.tprintf("%s/CMakeLists.txt", rt.src)) or_return
	all := make([dynamic]string, context.temp_allocator)
	cmake_lists(&all, text, words(val(rt.head, "cmake.lists"))) or_return
	append(&all, ..words(val(rt.head, "extra")))
	cmake_lists(&all, text, words(val(t, "cmake.lists"))) or_return
	append(&all, ..words(val(t, "extra")))
	base :: proc(path: string) -> string {
		b := filepath.base(path)
		if i := strings.index_byte(b, '.'); i >= 0 {
			return b[:i]
		}
		return b
	}
	replaced := make(map[string]bool, allocator = context.temp_allocator)
	for f in all {
		if strings.contains_rune(f, '/') {
			replaced[base(f)] = true
		}
	}
	merged := make([dynamic]string, context.temp_allocator)
	for f in all {
		if strings.contains_rune(f, '/') || !replaced[base(f)] {
			append(&merged, f)
		}
	}
	slice.sort(merged[:])
	srcs = make([dynamic]Source, context.temp_allocator)
	for f in merged {
		append(&srcs, Source{rel = f})
	}
	return srcs, true
}

// The repository root as /src in what clang writes (debug info, __FILE__),
// so the outputs do not depend on where the checkout is.
file_prefix_map :: proc() -> (flag: string, ok: bool) {
	root, err := os.get_working_directory(context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot find the working directory: %v", err)
		return "", false
	}
	return fmt.tprintf("-ffile-prefix-map=%s=/src", root), true
}

// The path a port's source is compiled from: under ports/, generated, as it
// is; otherwise in the port's tree.
source_path :: proc(p: ^Port, rel: string) -> string {
	return strings.has_prefix(rel, "ports/") ? rel : fmt.tprintf("%s/%s", p.src, rel)
}

// Compiles a port's sources for one architecture into out/NAME/ARCH/obj, at
// flags and then each file's own, once per change of the port's inputs, as
// build_port_target does for Limine. Returns the objects, in the sources'
// order.
build_cached :: proc(p: ^Port, a: ^Arch, flags: []string, srcs: []Source) -> (objs: []string, ok: bool) {
	outdir := fmt.tprintf("out/%s/%s", p.name, a.name)
	objdir := fmt.tprintf("%s/obj", outdir)
	stamp := fmt.tprintf("%s/stamp", outdir)
	key := fmt.tprintf("%016x\n", p.input_hash)
	list := make([dynamic]string, context.temp_allocator)
	for s in srcs {
		append(&list, object_for(objdir, s.rel))
	}
	if os.exists(stamp) {
		if got, _ := read_file(stamp); got == key {
			fmt.eprintfln("  PORT  %s  %s (cached)", p.name, a.name)
			return list[:], true
		}
		if err := os.remove(stamp); err != nil {
			fmt.eprintfln("build: cannot remove %s: %v", stamp, err)
			return nil, false
		}
	}
	prefix_map := file_prefix_map() or_return
	cmds := make([dynamic][]string, context.temp_allocator)
	for s, i in srcs {
		make_dirs(filepath.dir(list[i])) or_return
		append(&cmds, concat({CLANG}, flags, s.flags, {prefix_map, "-c", source_path(p, s.rel), "-o", list[i]}))
	}
	fmt.eprintfln("  PORT  %s  %s (%d files)", p.name, a.name, len(cmds))
	run_parallel(cmds[:]) or_return
	write_file(stamp, key) or_return
	return list[:], true
}

// llvm-ar, deterministic, with the members in a response file beside the
// archive's objects: libc.a has more than a command line holds. No members
// make an empty archive.
archive :: proc(lib, objdir: string, members: []string) -> bool {
	if os.exists(lib) {
		if err := os.remove(lib); err != nil {
			fmt.eprintfln("build: cannot remove %s: %v", lib, err)
			return false
		}
	}
	list := fmt.tprintf("%s/%s.members", objdir, filepath.base(lib))
	b := strings.builder_make(context.temp_allocator)
	for m in members {
		fmt.sbprintln(&b, m)
	}
	write_file(list, strings.to_string(b)) or_return
	return run({LLVM_AR, "rcsD", lib, fmt.tprintf("@%s", list)})
}

copy_file :: proc(from, to: string) -> bool {
	data := read_file(from) or_return
	return write_file(to, data)
}

// The back end's objects (ADR-0007): crt1.o, the program entry, and one
// object that goes into libc.a.
Backend :: struct {
	crt1, object: string,
}

// Whether ports/musl/vx holds an Odin package.
has_backend :: proc() -> bool {
	files, err := os.read_directory_by_path(BACKEND_PKG, -1, context.temp_allocator)
	if err != nil {
		return false // no directory: no back end
	}
	for f in files {
		if f.type == .Regular && strings.has_suffix(f.name, ".odin") {
			return true
		}
	}
	return false
}

// Builds the back end, if ports/musl/vx is an Odin package, into
// out/ARCH/MODE/musl-vx: the package through the programs' IR pipeline
// (compile_ir) with ports/musl/vx/arch/ARCH/*.S beside it. crt1.S there is
// the entry, _start, and becomes crt1.o; the rest is linked (ld.lld -r) into
// backend.o, whose global symbols are then all made local but
// backend.exports= in ports/musl/port.ndb, so nothing of Odin's (its runtime's
// memset, say) meets musl's names in the link. With override set, the
// objects in override/ARCH (crt1.o, backend.o) are taken instead, for
// bringing the back end up. Either way the object must define every export
// and no other global.
build_backend :: proc(musl: ^Port, a: ^Arch, mode: Mode, override: string) -> (b: Backend, present: bool, ok: bool) {
	exports := words(val(musl.head, "backend.exports"))
	switch {
	case override != "":
		b = {fmt.tprintf("%s/%s/crt1.o", override, a.name), fmt.tprintf("%s/%s/backend.o", override, a.name)}
		for f in ([]string{b.crt1, b.object}) {
			if !os.exists(f) {
				fmt.eprintfln("build: --musl-backend: %s is missing", f)
				return b, true, false
			}
		}
	case has_backend():
		out := fmt.tprintf("%s/musl-vx", out_dir(a, mode))
		fmt.eprintfln("  VX    libc back end %s", a.name)
		objs := compile_ir(a, mode, BACKEND_PKG, fmt.tprintf("%s/arch/%s", BACKEND_PKG, a.name), fmt.tprintf("%s/pkg", out), nil, nil) or_return
		rest := make([dynamic]string, context.temp_allocator)
		for o in objs {
			if filepath.base(o) == "crt1_S.o" {
				b.crt1 = o
			} else {
				append(&rest, o)
			}
		}
		if b.crt1 == "" {
			fmt.eprintfln("build: %s/arch/%s/crt1.S is missing: the back end's _start", BACKEND_PKG, a.name)
			return b, true, false
		}
		b.object = fmt.tprintf("%s/backend.o", out)
		ld := cmd_make(LLD, "-r", "-o", b.object)
		append(&ld, ..rest[:])
		run(ld[:]) or_return
		oc := cmd_make(OBJCOPY)
		for e in exports {
			append(&oc, fmt.tprintf("--keep-global-symbol=%s", e))
		}
		append(&oc, b.object)
		run(oc[:]) or_return
	case:
		return b, false, true
	}
	check_exports(b.object, exports) or_return
	return b, true, true
}

// The object defines each of exports, and no other global or weak symbol.
check_exports :: proc(object: string, exports: []string) -> bool {
	syms := elf_symbols(object) or_return
	ok := true
	defined := make(map[string]bool, allocator = context.temp_allocator)
	for s in syms {
		if !s.defined || s.bind == STB_LOCAL || s.type == STT_FILE || s.type == STT_SECTION {
			continue
		}
		defined[s.name] = true
		if !slice.contains(exports, s.name) {
			fmt.eprintfln("build: %s exports %s, which is not in backend.exports= (ports/musl/port.ndb)", object, s.name)
			ok = false
		}
	}
	for e in exports {
		if !defined[e] {
			fmt.eprintfln("build: %s does not define %s (backend.exports=, ports/musl/port.ndb)", object, e)
			ok = false
		}
	}
	return ok
}

// The sysroot for one architecture and mode.
Sysroot :: struct {
	lib:      string, // out/ARCH/MODE/vectra-musl/lib
	linkable: bool, // it has a back end: crt1.o, and libc.a with it
}

sysroot_lib :: proc(a: ^Arch, mode: Mode) -> string {
	return fmt.tprintf("%s/vectra-musl/lib", out_dir(a, mode))
}

// Builds the vectra-musl sysroot: musl and the builtins (cached), crti.o and
// crtn.o from musl's crt/ARCH, the back end if there is one, and the
// archives.
build_sysroot :: proc(ps: ^Posix_Ports, a: ^Arch, mode: Mode, backend_override := "") -> (s: Sysroot, ok: bool) {
	s.lib = sysroot_lib(a, mode)
	objdir := fmt.tprintf("%s/musl-vx", out_dir(a, mode))
	make_dirs(s.lib) or_return
	make_dirs(objdir) or_return

	musl_srcs := musl_sources(&ps.musl, a) or_return
	musl_objs := build_cached(&ps.musl, a, musl_flags(&ps.musl, a), musl_srcs[:]) or_return
	rt_srcs := compiler_rt_sources(&ps.compiler_rt, a) or_return
	rt_flags := concat(posix_flags(a), words(val(ps.compiler_rt.head, "cflags")))
	rt_objs := build_cached(&ps.compiler_rt, a, rt_flags, rt_srcs[:]) or_return

	prefix_map := file_prefix_map() or_return
	crt := make([dynamic][]string, context.temp_allocator)
	for name in ([]string{"crti", "crtn"}) {
		append(&crt, concat({CLANG, posix_target(a), prefix_map, "-c", fmt.tprintf("%s/crt/%s/%s.s", ps.musl.src, a.name, name), "-o", fmt.tprintf("%s/%s.o", s.lib, name)}))
	}
	run_parallel(crt[:]) or_return

	b, present := build_backend(&ps.musl, a, mode, backend_override) or_return
	s.linkable = present
	members := slice.clone_to_dynamic(musl_objs, context.temp_allocator)
	crt1 := fmt.tprintf("%s/crt1.o", s.lib)
	if present {
		append(&members, b.object)
		copy_file(b.crt1, crt1) or_return
	} else if os.exists(crt1) { // from a back end that has gone
		if err := os.remove(crt1); err != nil {
			fmt.eprintfln("build: cannot remove %s: %v", crt1, err)
			return s, false
		}
	}
	fmt.eprintfln("  AR    vectra-musl %s %s", a.name, MODES[mode].name)
	archive(fmt.tprintf("%s/libc.a", s.lib), objdir, members[:]) or_return
	archive(fmt.tprintf("%s/libclang_rt.builtins.a", s.lib), objdir, rt_objs) or_return
	for e in MUSL_EMPTY_LIBS {
		archive(fmt.tprintf("%s/lib%s.a", s.lib, e), objdir, nil) or_return
	}
	return s, true
}

// The command that links a C program against the sysroot, as musl's own
// toolchain wrapper would: crt1.o crti.o, the program, libc.a, the builtins,
// crtn.o.
posix_link_cmd :: proc(s: Sysroot, elf: string, objs: []string) -> []string {
	ld := cmd_make(LLD)
	append(&ld, ..POSIX_LD_FLAGS)
	append(&ld, "-o", elf, fmt.tprintf("%s/crt1.o", s.lib), fmt.tprintf("%s/crti.o", s.lib))
	append(&ld, ..objs)
	append(&ld, fmt.tprintf("%s/libc.a", s.lib), fmt.tprintf("%s/libclang_rt.builtins.a", s.lib), fmt.tprintf("%s/crtn.o", s.lib))
	return ld[:]
}

// Compiles a first-party C program (Program.kind == .C) against musl with
// the house's C flags, and links it if the sysroot has a back end. Returns
// the program's path, or "" when it was only compiled.
build_c_program :: proc(s: Sysroot, a: ^Arch, mode: Mode, p: Program) -> (elf: string, ok: bool) {
	obj := fmt.tprintf("%s/prog/%s/%s.o", out_dir(a, mode), p.name, p.name)
	make_dirs(filepath.dir(obj)) or_return
	prefix_map := file_prefix_map() or_return
	fmt.eprintfln("  CC    %s %s", p.name, a.name)
	run(concat({CLANG}, posix_flags(a), C_HOUSE_FLAGS, C_POSIX_PROGRAM_FLAGS, C_MODE_FLAGS[mode], {prefix_map, "-c", p.source, "-o", obj})) or_return
	if !s.linkable {
		return "", true
	}
	elf = program_path(a, mode, p.name)
	make_dirs(filepath.dir(elf)) or_return
	run(posix_link_cmd(s, elf, {obj})) or_return
	return elf, true
}

// A port's program= records (Lua's lua, sbase's commands): the port's
// sources= and each program's own, compiled once per architecture at the
// port's flags and cached (build_cached), then linked per mode into
// out/ARCH/MODE/bin, or the port's dir= under it. With archive=yes the shared
// sources are linked from an archive, so each program takes only what it
// uses.
//
// With box=NAME, the programs are one binary, as sbase's own sbase-box is:
// each program's main renamed NAME_main on its command line (the tree is not
// edited), and a generated main choosing one by argv[0]. A program= with
// alone=yes is linked by itself all the same (sbase's make, which sbase's
// mkbox leaves out too). Without a back end the objects are compiled and
// nothing is linked.
build_port_programs :: proc(p: ^Port, s: Sysroot, a: ^Arch, mode: Mode) -> bool {
	Prog :: struct {
		name:        string,
		alone:       bool,
		first, end:  int, // its sources in srcs
	}
	box := val(p.head, "box")
	srcs := make([dynamic]Source, context.temp_allocator)
	for rel in words(val(p.head, "sources")) {
		append(&srcs, Source{rel = rel})
	}
	shared := len(srcs)
	progs := make([dynamic]Prog, context.temp_allocator)
	for rec in p.programs {
		name := val(rec, "program")
		alone := box == "" || val(rec, "alone") == "yes"
		flags: []string
		if !alone {
			flags = slice.clone([]string{fmt.tprintf("-Dmain=%s_main", box_ident(name))}, context.temp_allocator)
		}
		first := len(srcs)
		for rel in words(val(rec, "sources")) {
			append(&srcs, Source{rel, flags})
		}
		append(&progs, Prog{name, alone, first, len(srcs)})
	}
	base := concat(posix_flags(a), words(val(p.head, "cflags")))
	objs := build_cached(p, a, base, srcs[:]) or_return

	bin := fmt.tprintf("%s/bin", out_dir(a, mode))
	if d := val(p.head, "dir"); d != "" {
		bin = fmt.tprintf("%s/%s", bin, d)
	}
	objdir := fmt.tprintf("%s/%s-port", out_dir(a, mode), p.name)
	make_dirs(bin) or_return
	make_dirs(objdir) or_return
	boxobj := ""
	if box != "" { // the generated main, at the port's flags
		main_c := fmt.tprintf("%s/%s.c", objdir, box)
		write_file(main_c, box_main(p, box)) or_return
		boxobj = fmt.tprintf("%s/%s.o", objdir, box)
		run(concat({CLANG}, base, {"-c", main_c, "-o", boxobj})) or_return
	}
	if !s.linkable {
		return true
	}
	libs := objs[:shared]
	if val(p.head, "archive") == "yes" {
		ar := fmt.tprintf("%s/lib%s.a", objdir, p.name)
		archive(ar, objdir, objs[:shared]) or_return
		libs = slice.clone([]string{ar}, context.temp_allocator)
	}
	links := make([dynamic][]string, context.temp_allocator)
	if box != "" {
		in_box := cmd_make(boxobj)
		for g in progs {
			if !g.alone {
				append(&in_box, ..objs[g.first:g.end])
			}
		}
		append(&in_box, ..libs)
		append(&links, posix_link_cmd(s, fmt.tprintf("%s/%s", bin, box), in_box[:]))
		fmt.eprintfln("  LD    %s %s", box, a.name)
	}
	for g in progs {
		if g.alone {
			append(&links, posix_link_cmd(s, fmt.tprintf("%s/%s", bin, g.name), concat(objs[g.first:g.end], libs)))
			fmt.eprintfln("  LD    %s %s", g.name, a.name)
		}
	}
	return run_parallel(links[:])
}

// "sha512-224sum" as an identifier: sha512_224sum.
box_ident :: proc(name: string) -> string {
	id, _ := strings.replace_all(name, "-", "_", context.temp_allocator)
	return id
}

// The box's main, generated from the port's program records: it runs the
// program its name (argv[0]) names, or its first argument's. box.alias=[
// adds "[" as test, as sbase's mkbox does.
box_main :: proc(p: ^Port, box: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "// Generated by build from %s/port.ndb: the %s box's main, which runs the\n", p.dir, box)
	fmt.sbprint(&b, "// program its name (argv[0]) names, or its first argument's.\n\n#include <stdio.h>\n#include <string.h>\n\n")
	for rec in p.programs {
		if val(rec, "alone") != "yes" {
			fmt.sbprintf(&b, "int %s_main(int, char **);\n", box_ident(val(rec, "program")))
		}
	}
	fmt.sbprint(&b, "\nstatic const struct {\n  const char *name;\n  int (*main)(int, char **);\n} programs[] = {\n")
	for rec in p.programs {
		if name := val(rec, "program"); val(rec, "alone") != "yes" {
			fmt.sbprintf(&b, "    {{\"%s\", %s_main}},\n", name, box_ident(name))
		}
	}
	if slice.contains(words(val(p.head, "box.alias")), "[") {
		fmt.sbprint(&b, "    {\"[\", test_main},\n")
	}
	fmt.sbprint(&b, "};\n\nint main(int argc, char **argv) {\n")
	fmt.sbprint(&b, "  for (int shift = 0; shift < 2 && argc > 0; shift++, argc--, argv++) {\n")
	fmt.sbprint(&b, "    const char *name = strrchr(argv[0], '/') ? strrchr(argv[0], '/') + 1 : argv[0];\n")
	fmt.sbprint(&b, "    for (size_t i = 0; i < sizeof programs / sizeof programs[0]; i++)\n")
	fmt.sbprint(&b, "      if (strcmp(programs[i].name, name) == 0) return programs[i].main(argc, argv);\n")
	fmt.sbprint(&b, "  }\n")
	fmt.sbprintf(&b, "  fputs(\"usage: %s program [argument ...]\\n\", stderr);\n", box)
	fmt.sbprint(&b, "  return 1;\n}\n")
	return strings.to_string(b)
}

// The C programs that are built but not yet in PROGRAMS: they need the back
// end to link, and no image holds them until it exists (ADR-0007).
C_PROGRAMS := []Program {
	{name = "ctest", source = "tests/posix/ctest.c", place = .Tests, kind = .C},
	{name = "sbasetest", source = "tests/posix/sbasetest.c", place = .Tests, kind = .C},
}

// Everything POSIX for one architecture and mode: the sysroot, the C test
// fixtures, and the ports' programs. Without a back end the C is compiled,
// and nothing is linked.
build_posix :: proc(ps: ^Posix_Ports, a: ^Arch, mode: Mode, backend_override := "") -> bool {
	s := build_sysroot(ps, a, mode, backend_override) or_return
	if !s.linkable {
		fmt.eprintfln("  NOTE  %s: no musl back end (%s): C programs compiled, not linked", a.name, BACKEND_PKG)
	}
	for p in C_PROGRAMS {
		build_c_program(s, a, mode, p) or_return
	}
	build_port_programs(&ps.lua, s, a, mode) or_return
	build_port_programs(&ps.sbase, s, a, mode) or_return
	return true
}
