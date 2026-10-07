package backend

import "base:intrinsics"
import vx "abi:vx"
import "linux"
import "vx:memory"
import "vx:p9"
import "vx:rt"

// mmap and its relatives, over VMOs.
//
// An anonymous mapping is a VMO of its own, mapped where the kernel picks or
// at a fixed address. A file's mapping, on a server with 9Px's map extension
// (fsd), is the VMO Tmap gives (upstream docs/proto/map.md): its page cache,
// which every process mapping the file shares, so MAP_SHARED writes reach
// the file and the others, and a read-only MAP_PRIVATE costs no copy. A
// private mapping that may be written, or one from a server without the
// extension, is the file's bytes read into a VMO of its own. Shared mappings
// of other servers' files are refused. A MAP_SHARED anonymous mapping is
// mapped .Shared, so a forked child maps the same VMO; PROT_NONE is
// .No_Access, and mprotect is as_protect (ADR-0020, upstream's M6 step
// 6e1a2).

// The pages len bytes touch, or false if that overflows.
@(private="file")
pages :: proc "contextless" (len: uint) -> (u64, bool) {
	size, ok := memory.page_round(u64(len))
	return size, ok
}

// The kernel's options for prot: PROT_NONE is no access at all; W^X holds.
@(private="file")
mem_vflags :: proc "contextless" (prot: linux.Prot_Flags) -> (vflags: vx.Map_Options) {
	if prot == linux.PROT_NONE {
		return {.No_Access}
	}
	if .Write in prot {
		vflags += {.Write}
	}
	if .Exec in prot {
		vflags += {.Exec}
	}
	return
}

mem_map :: proc "contextless" (addr: uintptr, length: uint, prot: linux.Prot_Flags, flags: int, fd: int, offset: i64) -> int {
	if length == 0 || addr & (memory.PAGE_SIZE - 1) != 0 || offset & (memory.PAGE_SIZE - 1) != 0 || offset < 0 {
		return fail(.EINVAL)
	}
	size, ok := pages(length)
	if !ok {
		return fail(.ENOMEM)
	}
	if prot >= {.Write, .Exec} {
		return fail(.EACCES) // W^X
	}
	anon := flags & linux.MAP_ANONYMOUS != 0
	map_type := flags & linux.MAP_TYPE
	shared := map_type == linux.MAP_SHARED || map_type == linux.MAP_SHARED_VALIDATE
	if map_type != linux.MAP_PRIVATE && !shared {
		return fail(.EINVAL)
	}
	o: ^Ofd
	if !anon {
		o = fd_get(fd)
		if o == nil {
			return fail(.EBADF)
		}
		if o.kind != .File || o.dir {
			return fail(.EACCES)
		}
	}
	mappable := !anon && .Map in o.f.c.extensions
	if shared && !anon && !mappable {
		return fail(.ENODEV) // a file on a server that cannot share its pages
	}
	if mappable && (shared || prot - {.Read, .Exec} == {}) {
		access := o.flags & linux.O_ACCMODE
		if access == linux.O_WRONLY {
			return fail(.EACCES)
		}
		if shared && .Write in prot && access != linux.O_RDWR {
			return fail(.EACCES)
		}
		return mem_map_file(o, size, prot, flags, offset, addr)
	}
	vflags := mem_vflags(prot)
	if shared {
		vflags += {.Shared} // anonymous: kept across fork
	}
	at: u64
	if flags & (linux.MAP_FIXED | linux.MAP_FIXED_NOREPLACE) != 0 {
		at = u64(addr)
	}
	if flags & linux.MAP_FIXED != 0 {
		_ = rt.as_unmap(rt.self, at, size) // Linux's MAP_FIXED replaces what is there
	}
	vmo, st := rt.vmo_create(size)
	if st != .Ok {
		return fail(.ENOMEM)
	}
	// A file's bytes go in first, through a writable mapping of the VMO's own.
	if !anon {
		fill: u64
		fill, st = rt.as_map(rt.self, vmo, 0, size, {.Write})
		if st == .Ok {
			dst := ([^]u8)(uintptr(fill))[:length]
			for done := 0; done < int(length); {
				n, rst := p9.client_read(o.f.c, o.f.fid, u64(offset) + u64(done), dst[done:][:min(int(length) - done, IO_MAX)])
				if rst != .Ok {
					st = rst
				}
				if rst != .Ok || n == 0 {
					break // the file ends here: the rest stays zero, as POSIX has it
				}
				done += n
			}
			_ = rt.as_unmap(rt.self, fill, size)
		}
	}
	if st == .Ok {
		at, st = rt.as_map(rt.self, vmo, 0, size, vflags, at)
	}
	rt.close_all(vmo) // the mapping keeps it
	if st == .Err_Exists && flags & linux.MAP_FIXED_NOREPLACE != 0 {
		return fail(.EEXIST)
	}
	if st != .Ok {
		return errno_of(st)
	}
	return int(at)
}

// A file's pages as its server's VMO (Tmap), mapped. Past the file's last
// page there is no VMO to map: those pages are left unmapped, so a touch
// there faults (SIGSEGV, where POSIX says SIGBUS).
@(private="file")
mem_map_file :: proc "contextless" (o: ^Ofd, size: u64, prot: linux.Prot_Flags, flags: int, offset: i64, addr: uintptr) -> int {
	p9prot := p9.Prot{.Read}
	if .Write in prot {
		p9prot += {.Write}
	}
	if .Exec in prot {
		p9prot += {.Exec}
	}
	vflags := mem_vflags(prot)
	if flags & linux.MAP_TYPE != linux.MAP_PRIVATE {
		vflags += {.Shared} // kept across fork as it is (a pager's VMO is anyway)
	}
	m, st := p9.client_map(o.f.c, o.f.fid, u64(offset), size, p9prot)
	if st != .Ok {
		return errno_of(st)
	}
	at: u64
	if flags & (linux.MAP_FIXED | linux.MAP_FIXED_NOREPLACE) != 0 {
		at = u64(addr)
	}
	if flags & linux.MAP_FIXED != 0 {
		_ = rt.as_unmap(rt.self, at, size)
	}
	at, st = rt.as_map(rt.self, m.vmo, m.vmo_offset, min(m.avail, size), vflags, at)
	rt.close_all(m.vmo) // the mapping keeps it
	if st == .Err_Exists && flags & linux.MAP_FIXED_NOREPLACE != 0 {
		return fail(.EEXIST)
	}
	if st != .Ok {
		return errno_of(st)
	}
	return int(at)
}

// mremap, of a private mapping (realloc's large blocks, which are musl's own
// anonymous mappings): shrunk in place; grown in place, with a VMO of its
// own after it, where the pages after it are free and it is one mapping
// still; else, with
// MREMAP_MAYMOVE, moved to a new mapping (at new_addr with MREMAP_FIXED)
// and copied. A shared mapping cannot be grown or moved: a copy would not be
// shared, and the VMO's handle is gone (EINVAL).
mem_remap :: proc "contextless" (addr: uintptr, old_len, new_len: uint, flags: int, new_addr: uintptr) -> int {
	if addr & (memory.PAGE_SIZE - 1) != 0 || new_len == 0 || flags & ~int(linux.MREMAP_MAYMOVE | linux.MREMAP_FIXED) != 0 {
		return fail(.EINVAL)
	}
	fixed := flags & linux.MREMAP_FIXED != 0
	if fixed && (flags & linux.MREMAP_MAYMOVE == 0 || new_addr & (memory.PAGE_SIZE - 1) != 0) {
		return fail(.EINVAL)
	}
	old_size, ok1 := pages(old_len)
	new_size, ok2 := pages(new_len)
	if !ok1 || !ok2 {
		return fail(.ENOMEM)
	}
	if new_size <= old_size && !fixed {
		if new_size < old_size {
			_ = rt.as_unmap(rt.self, u64(addr) + new_size, old_size - new_size)
		}
		return int(addr)
	}
	mi, st := rt.as_query(rt.self, u64(addr))
	if st != .Ok || mi.base > u64(addr) {
		return fail(.EFAULT)
	}
	opts := vx.map_options(mi.flags)
	if .Shared in opts {
		return fail(.EINVAL)
	}
	if fixed && u64(new_addr) < u64(addr) + old_size && u64(addr) < u64(new_addr) + new_size {
		return fail(.EINVAL) // the new place overlaps the old, as Linux refuses
	}
	prot := linux.PROT_NONE
	if .No_Access not_in opts {
		prot = {.Read}
		if .Write in opts {
			prot += {.Write}
		}
	}
	// Grown in place only while it is one mapping: a second growth moves it
	// into one again, so a buffer grown step by step never takes more than
	// two of the task's mappings (the review of 2026-10-07, upstream's
	// 2cc4729).
	single := mi.base == u64(addr) && mi.size == old_size
	if !fixed && single { // the pages after it, if they are free
		if more := mem_map(addr + uintptr(old_size), uint(new_size - old_size), prot, linux.MAP_PRIVATE | linux.MAP_ANONYMOUS | linux.MAP_FIXED_NOREPLACE, -1, 0); more >= 0 {
			return int(addr)
		}
	}
	if flags & linux.MREMAP_MAYMOVE == 0 {
		return fail(.ENOMEM)
	}
	at_flags := linux.MAP_PRIVATE | linux.MAP_ANONYMOUS
	if fixed {
		at_flags |= linux.MAP_FIXED
	}
	to := mem_map(fixed ? new_addr : 0, new_len, {.Read, .Write}, at_flags, -1, 0)
	if to < 0 {
		return to
	}
	if prot == linux.PROT_NONE {
		_ = rt.as_protect(rt.self, u64(addr), old_size, {}) // readable, to copy
	}
	intrinsics.mem_copy_non_overlapping(rawptr(uintptr(to)), rawptr(addr), min(old_size, new_size))
	if prot != {.Read, .Write} {
		_ = rt.as_protect(rt.self, u64(to), new_size, mem_vflags(prot))
	}
	_ = rt.as_unmap(rt.self, u64(addr), old_size)
	return to
}

mem_unmap :: proc "contextless" (addr: uintptr, length: uint) -> int {
	if addr & (memory.PAGE_SIZE - 1) != 0 || length == 0 {
		return fail(.EINVAL)
	}
	size, ok := pages(length) // the pages it touches, as Linux takes it
	if !ok {
		return fail(.EINVAL)
	}
	return errno_of(rt.as_unmap(rt.self, u64(addr), size))
}

// mprotect: as_protect, each mapping in the range within the rights its VMO's
// handle gave (a file opened read-only stays so: EACCES); a hole is ENOMEM.
mem_protect :: proc "contextless" (addr: uintptr, length: uint, prot: linux.Prot_Flags) -> int {
	if addr & (memory.PAGE_SIZE - 1) != 0 || prot - {.Read, .Write, .Exec} != {} {
		return fail(.EINVAL)
	}
	if prot >= {.Write, .Exec} {
		return fail(.EACCES) // W^X (01 §11)
	}
	size, ok := pages(length)
	if !ok {
		return fail(.ENOMEM)
	}
	if size == 0 {
		return 0
	}
	st := rt.as_protect(rt.self, u64(addr), size, mem_vflags(prot))
	if st == .Err_Not_Found || st == .Err_Range {
		return fail(.ENOMEM)
	}
	return errno_of(st)
}
