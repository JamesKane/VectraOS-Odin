package build

import "core:fmt"
import "core:os"
import "core:strings"

// The pinned toolchain (ADR-0001), by absolute path: a Swift toolchain's
// clang comes first on PATH on the macOS host, so PATH is never used.

when ODIN_OS == .Darwin {
	ODIN :: "/opt/homebrew/bin/odin"
	CLANG :: "/opt/homebrew/opt/llvm@22/bin/clang"
	LLC :: "/opt/homebrew/opt/llvm@22/bin/llc"
	OBJCOPY :: "/opt/homebrew/opt/llvm@22/bin/llvm-objcopy"
	LLD :: "/opt/homebrew/opt/lld@22/bin/ld.lld"
	NASM :: "/opt/homebrew/bin/nasm"
	MFORMAT :: "/opt/homebrew/bin/mformat"
	MMD :: "/opt/homebrew/bin/mmd"
	MCOPY :: "/opt/homebrew/bin/mcopy"
	GIT :: "/usr/bin/git"
	QEMU_X86_64 :: "/opt/homebrew/bin/qemu-system-x86_64"
	QEMU_AARCH64 :: "/opt/homebrew/bin/qemu-system-aarch64"
	FIRMWARE_X86_64 :: "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
	FIRMWARE_AARCH64 :: "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
} else when ODIN_OS == .Linux {
	ODIN :: "/opt/odin/odin"
	CLANG :: "/usr/bin/clang"
	LLC :: "/usr/bin/llc"
	OBJCOPY :: "/usr/bin/llvm-objcopy"
	LLD :: "/usr/bin/ld.lld"
	NASM :: "/usr/bin/nasm"
	MFORMAT :: "/usr/bin/mformat"
	MMD :: "/usr/bin/mmd"
	MCOPY :: "/usr/bin/mcopy"
	GIT :: "/usr/bin/git"
	QEMU_X86_64 :: "/usr/bin/qemu-system-x86_64"
	QEMU_AARCH64 :: "/usr/bin/qemu-system-aarch64"
	FIRMWARE_X86_64 :: "/usr/share/edk2/ovmf/OVMF_CODE.fd"
	FIRMWARE_AARCH64 :: "/usr/share/edk2/aarch64/QEMU_EFI-pflash.raw"
} else {
	#panic("build runs on macOS or Linux")
}

// What each tool's --version (or `odin version`) must say.
PINS := [?]struct {
	tool:    string,
	args:    []string,
	expect:  string,
} {
	{ODIN, {"version"}, "dev-2026-09:a2fb372b7"},
	{CLANG, {"--version"}, "clang version 22.1.8"},
	{LLC, {"--version"}, "LLVM version 22.1.8"},
	{OBJCOPY, {"--version"}, "LLVM version 22.1.8"},
	{LLD, {"--version"}, "LLD 22.1.8"},
	{NASM, {"--version"}, "NASM version 3.02"},
}

// Refuses to go on with a tool that is missing or not the pinned version.
check_pins :: proc() -> bool {
	ok := true
	for p in PINS {
		if !os.exists(p.tool) {
			fmt.eprintfln("build: %s is missing (ADR-0001)", p.tool)
			ok = false
			continue
		}
		args := make([dynamic]string, context.temp_allocator)
		append(&args, p.tool)
		append(&args, ..p.args)
		out, ran := run_capture(args[:])
		if !ran || !strings.contains(out, p.expect) {
			fmt.eprintfln("build: %s is not the pinned version: want %q (ADR-0001)", p.tool, p.expect)
			ok = false
		}
	}
	return ok
}

Arch :: struct {
	name:         string, // as VectraOS names it: x86_64, aarch64
	odin_target:  string,
	odin_flags:   []string,
	llc_flags:    []string,
	clang_target: string,
	limine:       string, // the target= in ports/limine/port.ndb
	loader:       string, // the loader's name on the ESP
}

ARCHES := [?]Arch {
	{
		name = "x86_64",
		odin_target = "freestanding_amd64_sysv",
		odin_flags = {"-disable-red-zone"},
		llc_flags = {"-code-model=kernel"},
		clang_target = "x86_64-unknown-none-elf",
		limine = "uefi-x86_64",
		loader = "BOOTX64.EFI",
	},
	{
		name = "aarch64",
		odin_target = "freestanding_arm64",
		clang_target = "aarch64-unknown-none-elf",
		limine = "uefi-aarch64",
		loader = "BOOTAA64.EFI",
	},
}

arch_by_name :: proc(name: string) -> (^Arch, bool) {
	for &a in ARCHES {
		if a.name == name {
			return &a, true
		}
	}
	return nil, false
}

Mode :: enum {
	Debug,
	Release,
}

out_dir :: proc(a: ^Arch, mode: Mode) -> string {
	return fmt.tprintf("out/%s/%s", a.name, mode == .Release ? "release" : "debug")
}
