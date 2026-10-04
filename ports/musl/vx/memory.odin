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
// of other servers' files are refused. Changing permissions waits for
// as_protect.

// The pages len bytes touch, or false if that overflows.
@(private="file")
pages :: proc "contextless" (len: uint) -> (u64, bool) {
	size, ok := memory.page_round(u64(len))
	return size, ok
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
	// Anonymous shared mappings wait for shared VMOs across fork: refused,
	// rather than made private where a program counts on another process
	// seeing its writes.
	map_type := flags & linux.MAP_TYPE
	shared := map_type == linux.MAP_SHARED || map_type == linux.MAP_SHARED_VALIDATE
	if map_type != linux.MAP_PRIVATE && !shared {
		return fail(.EINVAL)
	}
	if shared && anon {
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
	if shared && !mappable {
		return fail(.ENODEV)
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
	// Until as_protect, PROT_NONE is mapped read-write: what it reserves
	// stays reserved, but a guard page does not fault. That is what musl's
	// malloc expects where mprotect is missing: it reserves with PROT_NONE,
	// and takes mprotect's ENOSYS to mean the pages are usable as they are.
	vflags: vx.Map_Options
	if .Write in prot || prot == linux.PROT_NONE {
		vflags += {.Write}
	}
	if .Exec in prot {
		vflags += {.Exec}
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

// A file's pages as its server's VMO (Tmap), mapped. PROT_NONE is mapped
// read-only: what it reserves stays reserved. Past the file's last page
// there is no VMO to map: those pages are left unmapped, so a touch there
// faults (SIGSEGV, where POSIX says SIGBUS).
@(private="file")
mem_map_file :: proc "contextless" (o: ^Ofd, size: u64, prot: linux.Prot_Flags, flags: int, offset: i64, addr: uintptr) -> int {
	p9prot := p9.Prot{.Read}
	vflags: vx.Map_Options
	if .Write in prot {
		p9prot += {.Write}
		vflags += {.Write}
	}
	if .Exec in prot {
		p9prot += {.Exec}
		vflags += {.Exec}
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

// realloc's large blocks, which are musl's own anonymous mappings: moved to
// a new mapping and copied. Without MREMAP_MAYMOVE, only shrinking can be
// done.
mem_remap :: proc "contextless" (addr: uintptr, old_len, new_len: uint, flags: int) -> int {
	if addr & (memory.PAGE_SIZE - 1) != 0 || new_len == 0 || flags & ~int(linux.MREMAP_MAYMOVE) != 0 {
		return fail(.EINVAL) // MREMAP_FIXED: not yet
	}
	old_size, ok1 := pages(old_len)
	new_size, ok2 := pages(new_len)
	if !ok1 || !ok2 {
		return fail(.ENOMEM)
	}
	if new_size <= old_size {
		if new_size < old_size {
			_ = rt.as_unmap(rt.self, u64(addr) + new_size, old_size - new_size)
		}
		return int(addr)
	}
	if flags & linux.MREMAP_MAYMOVE == 0 {
		return fail(.ENOMEM)
	}
	to := mem_map(0, new_len, {.Read, .Write}, linux.MAP_PRIVATE | linux.MAP_ANONYMOUS, -1, 0)
	if to < 0 {
		return to
	}
	intrinsics.mem_copy_non_overlapping(rawptr(uintptr(to)), rawptr(addr), old_len)
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

// Until as_protect: nothing changes, and saying so is the answer musl's
// malloc expects (see mem_map). Asking for read-write after PROT_NONE gets
// what it asked for anyway.
mem_protect :: proc "contextless" () -> int {
	return fail(.ENOSYS)
}
