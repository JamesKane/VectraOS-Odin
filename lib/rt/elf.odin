package rt

// vx:rt's ELF: the headers spawn.odin loads images by, and thread.odin finds
// a program's TLS image in (its own, through __ehdr_start).

@(private)
Elf_Header :: struct {
	ident:                                                [16]u8,
	type, machine:                                        u16,
	version:                                              u32,
	entry, phoff, shoff:                                  u64,
	flags:                                                u32,
	ehsize, phentsize, phnum, shentsize, shnum, shstrndx: u16,
}
#assert(size_of(Elf_Header) == 64)

// A segment's permissions: PF_X is bit 0, PF_W bit 1, PF_R bit 2.
@(private)
Elf_Pf :: enum u32 {
	X,
	W,
	R,
}

@(private)
Elf_Phdr :: struct {
	type:                                       u32,
	flags:                                      bit_set[Elf_Pf;u32],
	offset, vaddr, paddr, filesz, memsz, align: u64,
}
#assert(size_of(Elf_Phdr) == 56)

@(private)
PT_LOAD :: 1
@(private)
PT_TLS :: 7
