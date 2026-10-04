package build

import "core:fmt"
import "core:slice"
import "core:strings"

// Just enough ELF64 to read a symbol table.

Elf64_Ehdr :: struct #packed {
	ident:     [16]u8,
	type:      u16,
	machine:   u16,
	version:   u32,
	entry:     u64,
	phoff:     u64,
	shoff:     u64,
	flags:     u32,
	ehsize:    u16,
	phentsize: u16,
	phnum:     u16,
	shentsize: u16,
	shnum:     u16,
	shstrndx:  u16,
}

Elf64_Shdr :: struct #packed {
	name:      u32,
	type:      u32,
	flags:     u64,
	addr:      u64,
	offset:    u64,
	size:      u64,
	link:      u32,
	info:      u32,
	addralign: u64,
	entsize:   u64,
}

Elf64_Sym :: struct #packed {
	name:  u32,
	info:  u8,
	other: u8,
	shndx: u16,
	value: u64,
	size:  u64,
}

SHT_SYMTAB :: 2
STT_FUNC :: 2

Func_Symbol :: struct {
	addr: u64,
	name: string,
}

// Every function symbol in a .text section, by address and then name.
elf_functions :: proc(path: string) -> (syms: [dynamic]Func_Symbol, ok: bool) {
	data := read_file(path) or_return
	syms = make([dynamic]Func_Symbol, context.temp_allocator)
	if len(data) < size_of(Elf64_Ehdr) || data[:4] != "\x7fELF" || data[4] != 2 {
		fmt.eprintfln("build: %s is not a 64-bit ELF file", path)
		return syms, false
	}
	eh := (^Elf64_Ehdr)(raw_data(data))^
	if int(eh.shoff) + int(eh.shnum) * size_of(Elf64_Shdr) > len(data) {
		fmt.eprintfln("build: %s: bad section table", path)
		return syms, false
	}
	sh := slice.from_ptr((^Elf64_Shdr)(raw_data(data[eh.shoff:])), int(eh.shnum))
	shstr := data[sh[eh.shstrndx].offset:]
	for s in sh {
		if s.type != SHT_SYMTAB {
			continue
		}
		st := slice.from_ptr((^Elf64_Sym)(raw_data(data[s.offset:])), int(s.size / size_of(Elf64_Sym)))
		strs := data[sh[s.link].offset:]
		for sym in st {
			if sym.info & 0xf != STT_FUNC || sym.shndx == 0 || int(sym.shndx) >= len(sh) {
				continue
			}
			if !strings.has_prefix(cstring_at(shstr, sh[sym.shndx].name), ".text") {
				continue
			}
			append(&syms, Func_Symbol{sym.value, cstring_at(strs, sym.name)})
		}
	}
	slice.sort_by(syms[:], proc(a, b: Func_Symbol) -> bool {
		return a.addr < b.addr || (a.addr == b.addr && a.name < b.name)
	})
	return syms, true
}

@(private="file")
cstring_at :: proc(table: string, off: u32) -> string {
	s := table[off:]
	n := strings.index_byte(s, 0)
	return n < 0 ? s : s[:n]
}

// A symbol map as assembly: for each function, `.quad address` and `.asciz
// "name"`, then `.quad -1`. Limine links one into itself for its panic
// backtraces (what its gensyms.sh makes with objdump, sort, awk and sed).
// With no ELF file, the map holds only the terminator: the first of two
// links. strip comes off the front of each name that has it (the kernel's
// "kernel::" package prefix).
write_symbol_map :: proc(elf_path, out_path, section, symbol: string, strip := "") -> bool {
	syms: [dynamic]Func_Symbol
	if elf_path != "" {
		ok: bool
		if syms, ok = elf_functions(elf_path); !ok {
			return false
		}
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%s\n.globl %s\n%s:\n", section, symbol, symbol)
	for s in syms {
		fmt.sbprintf(&b, ".quad 0x%016x\n.asciz \"%s\"\n", s.addr, map_name(s.name, strip))
	}
	fmt.sbprintln(&b, ".quad 0xffffffffffffffff")
	return write_file(out_path, strings.to_string(b))
}

// A name as the map holds it: Odin's names for polymorphic and some runtime
// procedures carry their signature (`response:proc"contextless"(...)`), which
// is cut off; what remains is escaped for .asciz.
@(private="file")
map_name :: proc(name, strip: string) -> string {
	n := strings.trim_prefix(name, strip) if strip != "" else name
	if strings.has_prefix(n, "[") { // a file-private procedure: "[main.odin]::selftests"
		if i := strings.index(n, "]::"); i > 0 {
			n = n[i + 3:]
		}
	}
	if i := strings.index(n, ":proc"); i > 0 {
		n = n[:i]
	}
	n, _ = strings.replace_all(n, "\\", "\\\\", context.temp_allocator)
	n, _ = strings.replace_all(n, "\"", "\\\"", context.temp_allocator)
	return n
}
