// An ELF64 image's sections, as the index builder needs them, and its loaded
// bytes, as a debugger reads what a crash directory leaves out. Every header
// and section is checked to lie inside the image.
package debug

import "base:intrinsics"

@(private = "file")
Elf_Header :: struct #packed {
	ident:     [16]u8,
	type:      u16le,
	machine:   u16le,
	version:   u32le,
	entry:     u64le,
	phoff:     u64le,
	shoff:     u64le,
	flags:     u32le,
	ehsize:    u16le,
	phentsize: u16le,
	phnum:     u16le,
	shentsize: u16le,
	shnum:     u16le,
	shstrndx:  u16le,
}
#assert(size_of(Elf_Header) == 64)
#assert(offset_of(Elf_Header, machine) == 18)
#assert(offset_of(Elf_Header, shoff) == 40)
#assert(offset_of(Elf_Header, shstrndx) == 62)

@(private = "file")
Elf_Shdr :: struct #packed {
	name:      u32le,
	type:      u32le,
	flags:     u64le,
	addr:      u64le,
	offset:    u64le,
	size:      u64le,
	link:      u32le,
	info:      u32le,
	addralign: u64le,
	entsize:   u64le,
}
#assert(size_of(Elf_Shdr) == 64)
#assert(offset_of(Elf_Shdr, offset) == 24)

@(private = "file")
Elf_Phdr :: struct #packed {
	type:   u32le,
	flags:  u32le,
	offset: u64le,
	vaddr:  u64le,
	paddr:  u64le,
	filesz: u64le,
	memsz:  u64le,
	align:  u64le,
}
#assert(size_of(Elf_Phdr) == 56)

// A symbol table entry (dwarf.odin reads them).
@(private)
Elf_Sym :: struct #packed {
	name:  u32le,
	info:  u8,
	other: u8,
	shndx: u16le,
	value: u64le,
	size:  u64le,
}
#assert(size_of(Elf_Sym) == 24)

@(private = "file")
SHT_NOTE :: 7
@(private = "file")
SHT_NOBITS :: 8
@(private = "file")
PT_LOAD :: 1
@(private = "file")
NT_GNU_BUILD_ID :: 3

@(private = "file")
SECTION_NAMES := [Section]string {
	.Info        = ".debug_info",
	.Abbrev      = ".debug_abbrev",
	.Line        = ".debug_line",
	.Str         = ".debug_str",
	.Line_Str    = ".debug_line_str",
	.Str_Offsets = ".debug_str_offsets",
	.Addr        = ".debug_addr",
	.Rnglists    = ".debug_rnglists",
	.Loclists    = ".debug_loclists",
	.Loc         = ".debug_loc",
	.Ranges      = ".debug_ranges",
	.Symtab      = ".symtab",
	.Strtab      = ".strtab",
}

// The NUL-terminated string at off in b, or false if it runs past b's end.
@(private)
cstr :: proc "contextless" (b: []u8, off: u64) -> (s: string, ok: bool) {
	if off >= u64(len(b)) {
		return "", false
	}
	for c, i in b[off:] {
		if c == 0 {
			return string(b[off:][:i]), true
		}
	}
	return "", false
}

// Reads image, a little-endian ELF64 file: false if it is not one, or its
// headers lie outside it. Sections it does not have are empty.
@(require_results)
elf_open :: proc "contextless" (image: []u8) -> (e: Elf, ok: bool) {
	size := u64(len(image))
	if size < size_of(Elf_Header) {
		return {}, false
	}
	h := load(image, Elf_Header)
	if h.ident[0] != 0x7f || h.ident[1] != 'E' || h.ident[2] != 'L' || h.ident[3] != 'F' || h.ident[4] != 2 || h.ident[5] != 1 {
		return {}, false // ELF64, little-endian
	}
	e.machine = Machine(h.machine)
	shoff, shentsize, shnum, shstrndx := u64(h.shoff), u64(h.shentsize), u64(h.shnum), u64(h.shstrndx)
	if shentsize < size_of(Elf_Shdr) || shstrndx >= shnum || shoff > size || shnum * shentsize > size - shoff {
		return {}, false
	}
	shdr :: proc "contextless" (image: []u8, shoff, shentsize, i: u64) -> Elf_Shdr {
		return load(image[shoff + i * shentsize:], Elf_Shdr)
	}
	names: []u8
	{ 	// the section names
		s := shdr(image, shoff, shentsize, shstrndx)
		off, length := u64(s.offset), u64(s.size)
		if off > size || length > size - off {
			return {}, false
		}
		names = image[off:][:length]
	}
	for i in 0 ..< shnum {
		s := shdr(image, shoff, shentsize, i)
		off, length := u64(s.offset), u64(s.size)
		if s.type == SHT_NOBITS || off > size || length > size - off {
			continue
		}
		sec := image[off:][:length]
		name, named := cstr(names, u64(s.name))
		if !named {
			continue
		}
		for want, k in SECTION_NAMES {
			if name == want {
				e.sec[k] = sec
			}
		}
		if s.type == SHT_NOTE && name == ".note.gnu.build-id" && length >= 16 {
			namesz, descsz, kind := u64(load(sec, u32le)), u64(load(sec[4:], u32le)), load(sec[8:], u32le)
			desc := 12 + ((namesz + 3) &~ 3)
			if kind == NT_GNU_BUILD_ID && namesz == 4 && descsz <= BUILD_ID_MAX && desc <= length && descsz <= length - desc {
				clear(&e.build_id)
				_ = append(&e.build_id, ..sec[desc:][:descsz])
			}
		}
	}
	return e, true
}

// n = len(buf) bytes at addr in the program image's loaded segments (PT_LOAD),
// by its program headers; false if they are not all in one segment's file
// bytes. What a crash directory leaves out (upstream 05 §5): code and
// read-only data, named by the image.
@(require_results)
image_read :: proc "contextless" (image: []u8, addr: u64, buf: []u8) -> bool {
	size := u64(len(image))
	if size < size_of(Elf_Header) {
		return false
	}
	h := load(image, Elf_Header)
	n := u64(len(buf))
	for i in 0 ..< u64(h.phnum) {
		at, overflow := intrinsics.overflow_add(u64(h.phoff), i * u64(h.phentsize))
		if overflow || at > size || size - at < size_of(Elf_Phdr) {
			continue
		}
		ph := load(image[at:], Elf_Phdr)
		if ph.type != PT_LOAD {
			continue
		}
		off, vaddr, filesz := u64(ph.offset), u64(ph.vaddr), u64(ph.filesz)
		// All as differences, which cannot wrap: the image and the address may be anything.
		if off > size || filesz > size - off || addr < vaddr || addr - vaddr > filesz || n > filesz - (addr - vaddr) {
			continue
		}
		copy(buf, image[off + (addr - vaddr):][:n])
		return true
	}
	return false
}
