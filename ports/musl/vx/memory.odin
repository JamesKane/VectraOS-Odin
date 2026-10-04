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
// at a fixed address. A private mapping of a file is its bytes read into
// one: what MAP_PRIVATE promises a reader, without a pager. Shared file
// mappings come with 9Px's Tmap, as does the change of permissions that
// as_protect will give.

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
	// Shared mappings wait for 9Px's Tmap and shared VMOs across fork:
	// refused, anonymous ones too, rather than made private where a program
	// counts on another process seeing its writes.
	if flags & linux.MAP_TYPE != linux.MAP_PRIVATE {
		return anon ? fail(.EINVAL) : fail(.ENODEV)
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
