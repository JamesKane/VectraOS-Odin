package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "vx:ndb"

// Vendored code built from ports/<name>/port.ndb (ADR-0002 upstream, kept
// here): the source sets and flags its own build would use, captured once,
// compiled by `build` with the pinned clang. Limine is the only port so far.

Port :: struct {
	name:       string,
	dir:        string, // ports/<name>, which also holds the captured config.h
	src:        string, // third_party/<name>
	head:       ^ndb.Record,
	targets:    [dynamic]^ndb.Record,
	files:      [dynamic]^ndb.Record,
	input_hash: u64,
}

port_load :: proc(name: string) -> (p: Port, ok: bool) {
	p.name = name
	p.dir = fmt.tprintf("ports/%s", name)
	path := fmt.tprintf("%s/port.ndb", p.dir)
	f := read_ndb(path) or_return
	p.targets = make([dynamic]^ndb.Record, context.temp_allocator)
	p.files = make([dynamic]^ndb.Record, context.temp_allocator)
	for rec in f.records {
		switch {
		case ndb.has(rec, "port"):
			p.head = rec
		case ndb.has(rec, "target"):
			append(&p.targets, rec)
		case ndb.has(rec, "file"):
			append(&p.files, rec)
		case:
			fmt.eprintfln("%s:%d: a record must start with port=, target= or file=", path, rec.line)
			return p, false
		}
	}
	if p.head == nil || val(p.head, "src") == "" {
		fmt.eprintfln("%s: needs a port= record with src=", path)
		return p, false
	}
	p.src = val(p.head, "src")

	// The cache key: the port's files, the vendor record, build itself, and
	// every file of the vendored tree, so an edited tree is never built over
	// by what was cached from the old one.
	h := FNV_OFFSET
	h = fnv(h, read_file(path) or_return)
	if os.exists(fmt.tprintf("%s/config.h", p.dir)) {
		h = fnv(h, read_file(fmt.tprintf("%s/config.h", p.dir)) or_return)
	}
	h = fnv(h, read_file("third_party/VENDOR.ndb") or_return)
	h = hash_tree(h, "tools/build") or_return
	h = hash_tree(h, p.src) or_return
	p.input_hash = h
	return p, true
}

// Every file under dir, as paths relative to the repository, in byte order.
tree_files :: proc(dir: string) -> (files: [dynamic]string, ok: bool) {
	files = make([dynamic]string, context.temp_allocator)
	// The walker gives absolute paths; keep them as dir plus the rest.
	abs, aerr := filepath.abs(dir, context.temp_allocator)
	if aerr != nil {
		fmt.eprintfln("build: cannot resolve %s", dir)
		return files, false
	}
	w := os.walker_create(dir)
	defer os.walker_destroy(&w)
	for fi in os.walker_walk(&w) {
		if fi.type == .Regular && strings.has_prefix(fi.fullpath, abs) {
			append(&files, strings.concatenate({dir, fi.fullpath[len(abs):]}, context.temp_allocator))
		}
	}
	if path, err := os.walker_error(&w); err != nil {
		fmt.eprintfln("build: cannot walk %s: %v", path, err)
		return files, false
	}
	slice.sort(files[:])
	return files, true
}

hash_tree :: proc(seed: u64, dir: string) -> (h: u64, ok: bool) {
	h = seed
	files := tree_files(dir) or_return
	for path in files {
		h = fnv(h, path)
		h = fnv(h, read_file(path) or_return)
	}
	return h, true
}

// Files under the comma-separated directories (relative to the port's
// source) ending in ext, relative to the port's source, in byte order.
collect :: proc(p: ^Port, dirs: string, ext: string) -> (out: [dynamic]string, ok: bool) {
	out = make([dynamic]string, context.temp_allocator)
	for d in strings.split(dirs, ",", context.temp_allocator) {
		if d == "" {
			continue
		}
		files := tree_files(fmt.tprintf("%s/%s", p.src, d)) or_return
		for f in files {
			if strings.has_suffix(f, ext) {
				append(&out, f[len(p.src) + 1:])
			}
		}
	}
	slice.sort(out[:])
	return out, true
}

// Each comma-separated extension in its own sorted group, in the order given.
collect_each :: proc(p: ^Port, dirs, exts: string) -> (out: [dynamic]string, ok: bool) {
	out = make([dynamic]string, context.temp_allocator)
	for ext in strings.split(exts, ",", context.temp_allocator) {
		group := collect(p, dirs, ext) or_return
		append(&out, ..group[:])
	}
	return out, true
}

port_target :: proc(p: ^Port, name: string) -> (^ndb.Record, bool) {
	for t in p.targets {
		if val(t, "target") == name {
			return t, true
		}
	}
	fmt.eprintfln("%s/port.ndb: no target=%s", p.dir, name)
	return nil, false
}

file_cflags :: proc(p: ^Port, rel: string) -> string {
	for f in p.files {
		if val(f, "file") == rel {
			return val(f, "cflags")
		}
	}
	return ""
}

object_for :: proc(objdir, rel: string) -> string {
	return fmt.tprintf("%s/%s.o", objdir, strings.trim_suffix(rel, filepath.ext(rel)))
}

// The loader for one target, built if the cache does not hold it already.
// Returns its path.
build_port_target :: proc(p: ^Port, target: string) -> (result: string, ok: bool) {
	t := port_target(p, target) or_return
	output := val(t, "output")
	root := os.get_working_directory(context.temp_allocator) or_else "."
	outdir := fmt.tprintf("%s/out/%s/%s", root, p.name, target)
	objdir := fmt.tprintf("%s/obj", outdir)
	result = fmt.tprintf("%s/%s", outdir, output)
	stamp := fmt.tprintf("%s/stamp", outdir)
	key := fmt.tprintf("%016x\n", p.input_hash)
	if os.exists(result) && os.exists(stamp) {
		if got, _ := read_file(stamp); got == key {
			fmt.eprintfln("  PORT  %s  %s (cached)", p.name, target)
			return result, true
		}
	}

	cflags := words(val(t, "cflags"))
	cppflags := words(val(p.head, "cppflags"))
	prefix_map := fmt.tprintf("-ffile-prefix-map=%s=/src", root)
	config_inc := fmt.tprintf("-I%s/%s", root, p.dir)
	src := fmt.tprintf("%s/%s", root, p.src)

	c_files := collect(p, val(t, "c.dirs"), ".c") or_return
	s_files := collect(p, val(t, "S.dirs"), ".S") or_return
	nasm_files := collect_each(p, val(t, "nasm.dirs"), val(t, "nasm.ext")) or_return
	cpp_files := collect_each(p, val(t, "cppasm.dirs"), val(t, "cppasm.ext")) or_return

	// One command per source file, in common.mk's link order.
	cmds := make([dynamic][]string, context.temp_allocator)
	objs := make([dynamic]string, context.temp_allocator)
	for list in ([][dynamic]string{c_files, s_files}) {
		for rel in list {
			o := object_for(objdir, rel)
			append(&cmds, concat({CLANG}, cflags, cppflags, {config_inc}, words(file_cflags(p, rel)), {prefix_map, "-c", rel, "-o", o}))
			append(&objs, o)
		}
	}
	for rel in nasm_files {
		o := object_for(objdir, rel)
		append(&cmds, concat({NASM, rel}, words(val(t, "nasmflags")), {"-o", o}))
		append(&objs, o)
	}
	for rel in cpp_files {
		o := object_for(objdir, rel)
		append(&cmds, concat({CLANG}, cflags, cppflags, {config_inc, prefix_map, "-x", "assembler-with-cpp", "-c", rel, "-o", o}))
		append(&objs, o)
	}
	for o in objs {
		make_dirs(filepath.dir(o)) or_return
	}
	fmt.eprintfln("  PORT  %s  %s (%d files)", p.name, target, len(cmds))
	run_parallel(cmds[:], src) or_return

	// Link twice: once without the symbol map, to learn the addresses, then with it.
	ldscript := fmt.tprintf("%s/%s", src, val(t, "ldscript"))
	map_s := fmt.tprintf("%s/full.map.S", outdir)
	map_o := fmt.tprintf("%s/full.map.o", outdir)
	for pass in 0 ..< 2 {
		script := fmt.tprintf("%s/%s", outdir, pass == 0 ? "linker_nomap.ld" : "linker.ld")
		elf := fmt.tprintf("%s/%s", outdir, pass == 0 ? "limine_nomap.elf" : "limine.elf")
		pp := cmd_make(CLANG, "-x", "c", "-E", "-P", "-undef")
		if pass == 0 {
			append(&pp, "-DLINKER_NOMAP")
		}
		append(&pp, ldscript, "-o", script)
		run(pp[:], src) or_return

		if pass == 1 {
			write_symbol_map(fmt.tprintf("%s/limine_nomap.elf", outdir), map_s, ".section .full_map", "full_map") or_return
			run(concat({CLANG}, cflags, cppflags, {config_inc, "-c", map_s, "-o", map_o}), src) or_return
		}

		ld := cmd_make(LLD, fmt.tprintf("-T%s", script))
		append(&ld, ..words(val(t, "ldflags")))
		append(&ld, ..objs[:])
		if pass == 1 {
			append(&ld, map_o)
		}
		append(&ld, "-o", elf)
		run(ld[:]) or_return
	}

	// The loader is the raw image of the PE file the linker script lays out, padded to 4 KiB.
	run({OBJCOPY, "-O", "binary", fmt.tprintf("%s/limine.elf", outdir), result}) or_return
	data := read_file(result) or_return
	padded := make([]u8, (len(data) + 4095) &~ 4095, context.temp_allocator)
	copy(padded, data)
	write_file(result, string(padded)) or_return
	write_file(stamp, key) or_return
	return result, true
}
