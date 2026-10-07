package build

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// build: the one build tool. The ./build wrapper at the root compiles it
// when its sources change, then runs it from the repository root.

USAGE :: `usage: ./build <command> [--arch x86_64|aarch64] [--release] [-v]
  all            the kernel, the Limine loaders, the user programs, the
                 vectra-musl sysroot and the C programs against it,
                 out/host/vx9pserve once tools/vx9pserve is there, and
                 out/host/vxstore;
                 with --musl-backend DIR, C programs link against
                 DIR/<arch>/crt1.o and backend.o, not the back end
                 built from ports/musl/vx (bringing it up)
  image [--iso]  GPT disk images: out/<arch>/<mode>/vectra-<arch>.img;
                 with --iso, UEFI CD images too: vectra-<arch>.iso
  qemu           boot an image on the serial console (Ctrl-A X quits)
  test [name...] boot headless and check tests/qemu/*.ndb
  release [--verify RECORD]
                 both architectures' base trees in out/release/store,
                 store-ARCH.tar, and release.ndb (unsigned); --verify
                 rebuilds and compares
  check [STAGE ...] [SUITE ...]
                 the manual's pass, host tests under ASan, the vx-fs
                 image check, vendor-check; only the stages named (man
                 host fuzz vxfs vendor), and in host and fuzz only the
                 suites of tests/host named: check host fs
  vendor-check   check third_party/ against VENDOR.ndb
  loc            the line-count ledger
  man [section ...] title [node]
                 a page of man/, as man(1) shows it;
  man --check    or check's manual pass alone
(abi/vx/abi_gen.odin is made from abi/vx/*.def by tools/abigen, which the
./build wrapper runs first.)`

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	command := os.args[1]
	if command == "man" { // its own arguments: sections, a title, a node, --check
		set_source_date_epoch()
		os.exit(cmd_man(os.args[2:]) ? 0 : 1)
	}
	chosen: bit_set[Arch_Kind] // by --arch; none means all
	names := make([dynamic]string, context.temp_allocator)
	mode := Mode.Debug
	want_iso := false
	backend_override := "" // --musl-backend
	verify := "" // release --verify RECORD
	for i := 2; i < len(os.args); i += 1 {
		switch arg := os.args[i]; arg {
		case "--arch":
			i += 1
			a: ^Arch
			ok := false
			if i < len(os.args) {
				a, ok = arch_by_name(os.args[i])
			}
			if !ok {
				fmt.eprintln("build: --arch takes x86_64 or aarch64")
				os.exit(2)
			}
			chosen += {a.kind}
		case "--release":
			mode = .Release
		case "-v":
			verbose = true
		case "--musl-backend":
			i += 1
			if command != "all" || i == len(os.args) {
				fmt.eprintln("build: --musl-backend DIR goes with all")
				os.exit(2)
			}
			backend_override = os.args[i]
		case "--verify":
			i += 1
			if command != "release" || i == len(os.args) {
				fmt.eprintln("build: --verify RECORD goes with release")
				os.exit(2)
			}
			verify = os.args[i]
		case "--iso":
			if command != "image" {
				fmt.eprintln("build: --iso goes with image")
				os.exit(2)
			}
			want_iso = true
		case:
			if strings.has_prefix(arg, "-") {
				fmt.eprintln(USAGE)
				os.exit(2)
			}
			append(&names, arg)
		}
	}
	arches := make([dynamic]^Arch, context.temp_allocator)
	for &a in ARCHES {
		if chosen == {} || a.kind in chosen {
			append(&arches, &a)
		}
	}
	set_source_date_epoch()
	ok := false
	switch command {
	case "vendor-check":
		ok = cmd_vendor_check()
	case "loc":
		ok = cmd_loc()
	case "check":
		ok = cmd_check(names[:])
	case "release":
		ok = check_pins() && cmd_release(verify)
	case "all", "image", "qemu", "test":
		if !check_pins() {
			os.exit(1)
		}
		ok = true
		switch command {
		case "all":
			// A port that does not load has said why; the kernels still build.
			limine, loaded := port_load("limine")
			for a in arches {
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				lok := loaded
				if loaded {
					_, lok = build_port_target(&limine, a.limine)
				}
				_, kok := build_kernel(a, mode)
				pok := kok && build_programs(a, mode, backend_override)
				ok = ok && lok && kok && pok
			}
			// The host tools' sources compile with the rest, once they are there.
			if os.is_dir(VX9PSERVE_SRC) {
				ok = build_vx9pserve() && ok
			}
			ok = build_vxstore() && ok
		case "image":
			for a in arches {
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				iso := want_iso ? fmt.tprintf("%s/vectra-%s.iso", out_dir(a, mode), a.name) : ""
				ok = build_image(a, mode, image_path(a, mode), iso = iso) && ok
			}
		case "qemu":
			a := arches[0]
			if len(arches) > 1 {
				fmt.eprintln("build: qemu boots one architecture: give --arch")
				os.exit(2)
			}
			ok = cmd_qemu(a, mode)
		case "test":
			ok = cmd_test(arches[:], mode, names[:])
		}
	case:
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	os.exit(ok ? 0 : 1)
}

cmd_qemu :: proc(a: ^Arch, mode: Mode) -> bool {
	image := image_path(a, mode)
	build_image(a, mode, image) or_return
	// vx9pserve serves out/share at 10.0.2.100!5640: kept between runs, made once.
	if !build_vx9pserve() {
		fmt.eprintln("build: booting without vx9pserve: mounting 10.0.2.100!5640 will fail")
	}
	share := "out/share"
	if !os.exists(share) {
		fresh_share(share) or_return
	}
	fmt.eprintln("build: starting QEMU; Ctrl-A X quits")
	return run(qemu_cmd(a, image, {share = share}))
}

cmd_test :: proc(arches: []^Arch, mode: Mode, names: []string) -> bool {
	names := names
	if len(names) == 0 {
		all := make([dynamic]string, context.temp_allocator)
		// The top level only: tests/qemu/m2 and the like are run by name.
		// Every scenario but the release gates, which run when named.
		files, err := os.read_directory_by_path("tests/qemu", -1, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("build: cannot read tests/qemu: %v", err)
			return false
		}
		for f in files {
			if f.type == .Regular && strings.has_suffix(f.name, ".ndb") && !scenario_flag(filepath.stem(f.name), "release") {
				append(&all, filepath.stem(f.name))
			}
		}
		if len(all) == 0 {
			fmt.eprintln("build: no scenarios in tests/qemu")
			return false
		}
		slice.sort(all[:])
		names = all[:]
	}
	ok := true
	for a in arches {
		for name in names {
			// An image's build reads and writes hundreds of megabytes, all
			// temporary: let each scenario's go before the next.
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			ok = run_scenario(a, mode, name) && ok
		}
	}
	return ok
}

// Whether a directory holds a suite: any *_test.odin.
@(private="file")
has_tests :: proc(dir: string) -> bool {
	files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err != nil {
		return true // let odin test say what is wrong
	}
	for f in files {
		if strings.has_suffix(f.name, "_test.odin") {
			return true
		}
	}
	return false
}

// ./build check [STAGE ...] [SUITE ...] (upstream's 78e748b): the stages
// named, all without one, and in host and fuzz the suites named, all without
// one, so a fix to one library is checked in seconds rather than the whole
// tree's minutes. This tree's stages are upstream's that it has: man (the
// manual's pass), host (every suite of tests/host, under ASan), fuzz (the
// suites that replay an upstream fuzz target's corpus, those with a corpus
// directory: this tree's fuzzers are host suites, not libFuzzer targets),
// vxfs and vendor. Upstream's format, sa, tidy and time check C this tree
// does not have.
CHECK_STAGES :: []string{"man", "host", "fuzz", "vxfs", "vendor"}
CHECK_ABSENT :: []string{"format", "sa", "tidy", "time"}

@(private="file")
Check_Words :: struct {
	stages: [dynamic]string,
	suites: [dynamic]string,
}

// Whether the words name this stage, or no stage at all.
@(private="file")
check_wants :: proc(w: ^Check_Words, stage: string) -> bool {
	if len(w.stages) == 0 {
		return true
	}
	return slice.contains(w.stages[:], stage)
}

// Whether the words name this suite, or no suite at all.
@(private="file")
check_wants_suite :: proc(w: ^Check_Words, name: string) -> bool {
	return len(w.suites) == 0 || slice.contains(w.suites[:], name)
}

// The manual's pass (man.odin), then host tests: every package under
// tests/host with a suite, under ASan; then the vx-fs image and vendor-check.
cmd_check :: proc(words: []string) -> bool {
	w: Check_Words
	w.stages = make([dynamic]string, context.temp_allocator)
	w.suites = make([dynamic]string, context.temp_allocator)
	for word in words {
		switch {
		case slice.contains(CHECK_STAGES, word):
			append(&w.stages, word)
		case slice.contains(CHECK_ABSENT, word):
			fmt.eprintfln("build: check: this tree has no %s stage (upstream's checks its C; there is none here)", word)
			return false
		case word == "x86_64" || word == "aarch64":
			// Upstream's narrow its analyzer's and tidy's units; the host
			// suites are the host's, so here one would narrow nothing.
			fmt.eprintfln("build: check: %s narrows nothing here: the suites run on the host", word)
			return false
		case:
			append(&w.suites, word)
		}
	}
	ok := true
	if check_wants(&w, "man") {
		ok = check_man() && ok
	}
	if check_wants(&w, "host") || check_wants(&w, "fuzz") {
		ok = check_host(&w) && ok
	}
	if check_wants(&w, "vxfs") {
		ok = check_vxfs_image() && ok
	}
	if check_wants(&w, "vendor") {
		ok = cmd_vendor_check() && ok
	}
	return ok
}

// The suites of tests/host the words name: all of them for host, those with
// an upstream fuzz corpus for fuzz alone. A suite named that is not run (a
// typo, or not a fuzz suite under fuzz alone) fails the check, as a filter
// that matches nothing does: never a silent pass.
@(private="file")
check_host :: proc(w: ^Check_Words) -> bool {
	all := check_wants(w, "host")
	// The usage packages, for the suites that import a program (dbg, dosfs,
	// isofs): gen:usage/NAME.
	ok := make_usage()
	dirs, err := os.read_directory_by_path("tests/host", -1, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read tests/host: %v", err)
		return false
	}
	slice.sort_by(dirs, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	// write_iso's test image, at the date upstream's was written at:
	// tests/host/iso checks it is upstream's image byte for byte, and
	// tests/host/mount mounts it.
	make_dirs("out/host") or_return
	if !make_test_iso("out/host/test.iso", TEST_ISO_EPOCH) {
		fmt.eprintln("  HOST  cannot make out/host/test.iso")
		ok = false
	}
	ran := 0
	checked := make([dynamic]string, context.temp_allocator)
	for d in dirs {
		dir := fmt.tprintf("tests/host/%s", d.name)
		if d.type != .Directory || !has_tests(dir) {
			continue // a helper package the suites import (p9test, blkfake)
		}
		if !check_wants_suite(w, d.name) || (!all && !os.is_dir(fmt.tprintf("%s/corpus", dir))) {
			continue
		}
		ran += 1
		append(&checked, d.name)
		fmt.eprintfln("  HOST  %s", d.name)
		c := cmd_make(ODIN, "test", dir, "-collection:vx=lib", "-collection:abi=abi", "-collection:gen=out/gen", "-vet", "-strict-style", "-warnings-as-errors", "-sanitize:address", fmt.tprintf("-out:out/host/%s", d.name))
		// The vendored C a suite says it links (cobj.odin).
		ports, found := cobj_host_links(dir)
		links, built := cobj_host_link_flags(ports[:])
		if !found || !built {
			ok = false
			continue
		}
		append(&c, ..links[:])
		ok = run(c[:]) && ok
	}
	for name in w.suites {
		if !slice.contains(checked[:], name) {
			fmt.eprintfln("build: check: no suite %s is checked by %s", name, all ? "host" : "fuzz")
			ok = false
		}
	}
	if ran == 0 {
		if len(w.suites) > 0 {
			fmt.eprintln("build: check: no suite is named so: nothing was checked") // never a silent pass
		} else {
			fmt.eprintln("build: no packages in tests/host")
		}
		ok = false
	}
	return ok
}

// Reproducible builds: every timestamp written into an output, such as the
// FAT entries mtools writes, is SOURCE_DATE_EPOCH. If the environment does
// not set it, it is the time of the last commit.
set_source_date_epoch :: proc() {
	_ = os.set_env("MTOOLS_SKIP_CHECK", "1")
	if os.get_env("SOURCE_DATE_EPOCH", context.temp_allocator) != "" {
		return
	}
	epoch := "315532800" // 1980-01-01, FAT's epoch
	if out, ok := run_capture({GIT, "log", "-1", "--format=%ct"}); ok {
		if t := strings.trim_space(out); t != "" {
			epoch = t
		}
	}
	_ = os.set_env("SOURCE_DATE_EPOCH", epoch)
}

// The line-count ledger: first-party lines per top-level directory, then
// vendored lines.
cmd_loc :: proc() -> bool {
	count :: proc(dir: string, exts: []string) -> (lines: int) {
		files, _ := tree_files(dir)
		for f in files {
			if strings.has_suffix(f, "_gen.odin") {
				continue // generated by build
			}
			for e in exts {
				if strings.has_suffix(f, e) {
					data, _ := read_file(f)
					lines += strings.count(data, "\n")
					break
				}
			}
		}
		return
	}
	// The counts are printed as strings: Odin's %7d pads with zeros, not spaces.
	FIRST_PARTY :: []string{".odin", ".S", ".ld"}
	total := 0
	for dir in ([]string{"kernel", "lib", "servers", "drivers", "cmd", "tools", "abi", "tests", "spikes", "ports"}) {
		if !os.exists(dir) {
			continue
		}
		n := count(dir, FIRST_PARTY)
		total += n
		fmt.printfln("  %-14s %7s", dir, fmt.tprint(n))
	}
	fmt.printfln("  %-14s %7s", "first-party", fmt.tprint(total))
	VENDORED :: []string{".c", ".h", ".s", ".S", ".asm_x86_64", ".asm_uefi_x86_64", ".asm_x86", ".asm_aarch64", ".asm_uefi_aarch64"}
	// Files made from a vendored tree, once, count with it.
	vendored := count("third_party", VENDORED) + count("ports/musl/generated", VENDORED) + count("ports/sbase/generated", VENDORED)
	fmt.printfln("  %-14s %7s", "vendored", fmt.tprint(vendored))
	return true
}
