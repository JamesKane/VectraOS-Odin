package kernel

import "base:intrinsics"
import vx "abi:vx"

// Loads the root task's ELF image from its boot module. Static, non-PIE
// executables only; every other program is loaded from user space.

@(private="file")
Elf64_Header :: struct {
	ident:                                               [16]u8,
	type, machine:                                       u16,
	version:                                             u32,
	entry, phoff, shoff:                                 u64,
	flags:                                               u32,
	ehsize, phentsize, phnum, shentsize, shnum, shstrndx: u16,
}

@(private="file")
Elf64_Phdr :: struct {
	type, flags:                                  u32,
	offset, vaddr, paddr, filesz, memsz, align: u64,
}

@(private="file")
PT_LOAD :: 1
@(private="file")
PF_X :: 1
@(private="file")
PF_W :: 2

when ODIN_ARCH == .amd64 {
	@(private="file")
	ELF_MACHINE :: 62 // EM_X86_64
} else {
	@(private="file")
	ELF_MACHINE :: 183 // EM_AARCH64
}

@(require_results)
elf_load :: proc "contextless" (t: ^Task, image: []u8) -> (entry: Uva, st: vx.Status) {
	size := u64(len(image))
	if size < size_of(Elf64_Header) {
		return 0, .Err_Invalid
	}
	eh := cast(^Elf64_Header)raw_data(image)
	table, o1 := intrinsics.overflow_mul(u64(eh.phnum), size_of(Elf64_Phdr))
	table_end, o2 := intrinsics.overflow_add(table, eh.phoff)
	if string(eh.ident[:4]) != "\x7fELF" || eh.ident[4] != 2 || eh.ident[5] != 1 || eh.type != 2 ||
	   eh.machine != ELF_MACHINE || eh.phentsize != size_of(Elf64_Phdr) || o1 || o2 || table_end > size {
		return 0, .Err_Invalid
	}
	ph := (cast([^]Elf64_Phdr)raw_data(image[eh.phoff:table_end]))[:eh.phnum]
	for p in ph {
		if p.type != PT_LOAD || p.memsz == 0 {
			continue
		}
		file_end, o3 := intrinsics.overflow_add(p.offset, p.filesz)
		mem_end, o4 := intrinsics.overflow_add(p.vaddr, p.memsz)
		if p.filesz > p.memsz || o3 || file_end > size || o4 || Uva(mem_end) > USER_TOP || (p.flags & PF_W != 0 && p.flags & PF_X != 0) {
			return 0, .Err_Invalid
		}
		base := p.vaddr &~ (PAGE_SIZE - 1)
		v := vmo_create(mem_end - base) or_return
		vmo_write(v, p.vaddr - base, image[p.offset:file_end])
		flags: vx.Map_Options
		if p.flags & PF_W != 0 {
			flags += {.Write}
		}
		if p.flags & PF_X != 0 {
			flags += {.Exec}
		}
		_, st = task_map(t, v, 0, v.size, flags, Uva(base))
		object_release(&v.obj) // the mapping keeps it
		if st != .Ok {
			return 0, st
		}
	}
	return Uva(eh.entry), .Ok
}
