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
  check          host tests under ASan, vendor-check
  vendor-check   check third_party/ against VENDOR.ndb
  loc            the line-count ledger
(abi/vx/abi_gen.odin is made from abi/vx/*.def by tools/abigen, which the
./build wrapper runs first.)`

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln(USAGE)
		os.exit(2)
	}
	command := os.args[1]
	chosen: bit_set[Arch_Kind] // by --arch; none means all
	names := make([dynamic]string, context.temp_allocator)
	mode := Mode.Debug
	want_iso := false
	backend_override := "" // --musl-backend
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
		ok = cmd_check()
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
		files, err := os.read_directory_by_path("tests/qemu", -1, context.temp_allocator)
		if err != nil {
			fmt.eprintfln("build: cannot read tests/qemu: %v", err)
			return false
		}
		for f in files {
			if f.type == .Regular && strings.has_suffix(f.name, ".ndb") {
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

// Host tests: every package under tests/host, under ASan.
cmd_check :: proc() -> bool {
	ok := true
	dirs, err := os.read_directory_by_path("tests/host", -1, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read tests/host: %v", err)
		return false
	}
	slice.sort_by(dirs, proc(a, b: os.File_Info) -> bool {return a.name < b.name})
	ran := 0
	for d in dirs {
		if d.type != .Directory {
			continue
		}
		ran += 1
		fmt.eprintfln("  HOST  %s", d.name)
		dir := fmt.tprintf("tests/host/%s", d.name)
		c := cmd_make(ODIN, "test", dir, "-collection:vx=lib", "-collection:abi=abi", "-vet", "-strict-style", "-warnings-as-errors", "-sanitize:address", fmt.tprintf("-out:out/host/%s", d.name))
		// The vendored C a suite says it links (cobj.odin).
		ports, found := cobj_host_links(dir)
		links, built := cobj_host_link_flags(ports[:])
		if !found || !built {
			ok = false
			continue
		}
		append(&c, ..links[:])
		make_dirs("out/host") or_return
		ok = run(c[:]) && ok
	}
	if ran == 0 {
		fmt.eprintln("build: no packages in tests/host")
		ok = false
	}
	ok = cmd_vendor_check() && ok
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
