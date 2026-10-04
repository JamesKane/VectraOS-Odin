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
// Every offset the file gives is checked: a malformed file is an error, not
// a read past its end.
elf_functions :: proc(path: string) -> (syms: [dynamic]Func_Symbol, ok: bool) {
	data := transmute([]u8)(read_file(path) or_return)
	syms = make([dynamic]Func_Symbol, context.temp_allocator)
	if len(data) < size_of(Elf64_Ehdr) || string(data[:4]) != "\x7fELF" || data[4] != 2 {
		fmt.eprintfln("build: %s is not a 64-bit ELF file", path)
		return syms, false
	}
	eh := (^Elf64_Ehdr)(raw_data(data))^
	sh, sh_ok := elf_table(Elf64_Shdr, data, eh.shoff, u64(eh.shnum) * size_of(Elf64_Shdr))
	sh_ok = sh_ok && int(eh.shstrndx) < len(sh)
	shstr: []u8
	if sh_ok {
		shstr, sh_ok = elf_table(u8, data, sh[eh.shstrndx].offset, sh[eh.shstrndx].size)
	}
	if !sh_ok {
		fmt.eprintfln("build: %s: bad section table", path)
		return syms, false
	}
	for s in sh {
		if s.type != SHT_SYMTAB {
			continue
		}
		st, st_ok := elf_table(Elf64_Sym, data, s.offset, s.size)
		st_ok = st_ok && int(s.link) < len(sh)
		strs: []u8
		if st_ok {
			strs, st_ok = elf_table(u8, data, sh[s.link].offset, sh[s.link].size)
		}
		if !st_ok {
			fmt.eprintfln("build: %s: bad symbol table", path)
			return syms, false
		}
		for sym in st {
			if sym.info & 0xf != STT_FUNC || sym.shndx == 0 || int(sym.shndx) >= len(sh) {
				continue
			}
			section, sok := cstring_at(shstr, sh[sym.shndx].name)
			name, nok := cstring_at(strs, sym.name)
			if !sok || !nok {
				fmt.eprintfln("build: %s: bad symbol name", path)
				return syms, false
			}
			if strings.has_prefix(section, ".text") {
				append(&syms, Func_Symbol{sym.value, name})
			}
		}
	}
	slice.sort_by(syms[:], proc(a, b: Func_Symbol) -> bool {
		return a.addr < b.addr || (a.addr == b.addr && a.name < b.name)
	})
	return syms, true
}

// The size bytes at offset as a table of T, if they are in the file.
@(private="file")
elf_table :: proc($T: typeid, data: []u8, offset, size: u64) -> ([]T, bool) {
	if offset > u64(len(data)) || size > u64(len(data)) - offset {
		return nil, false
	}
	return slice.reinterpret([]T, data[offset:][:size]), true
}

@(private="file")
cstring_at :: proc(table: []u8, off: u32) -> (string, bool) {
	if int(off) >= len(table) {
		return "", false
	}
	return strings.truncate_to_byte(string(table[off:]), 0), true
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
		syms = elf_functions(elf_path) or_return
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
	n := strings.trim_prefix(name, strip)
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
