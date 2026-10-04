package rt

import "base:intrinsics"
import vx "abi:vx"
import "vx:ndb"

// Starting a program from an ELF image in memory. The ELF loader lives here,
// in user space; the kernel loads only the root task.
//
// The parent builds the child: a task, a VMO per loadable segment mapped at
// its address, a stack, and a bootstrap channel holding the spawn message,
// which names the handles the child is given. Then it starts the first
// thread. The child gets nothing else: no ambient authority.
//
// The image is the parent's to trust or not, but it is checked like any
// other input: an image that would map outside the lower half, map a page
// both writable and executable, or reach past its own end is refused.

@(private="file")
Elf_Header :: struct {
	ident:                                                [16]u8,
	type, machine:                                        u16,
	version:                                              u32,
	entry, phoff, shoff:                                  u64,
	flags:                                                u32,
	ehsize, phentsize, phnum, shentsize, shnum, shstrndx: u16,
}

@(private="file")
Elf_Phdr :: struct {
	type, flags:                                u32,
	offset, vaddr, paddr, filesz, memsz, align: u64,
}

when ODIN_ARCH == .amd64 {
	@(private="file")
	ELF_MACHINE :: 62 // EM_X86_64
} else {
	@(private="file")
	ELF_MACHINE :: 183 // EM_AARCH64
}

USER_TOP :: u64(0x0000_8000_0000_0000)
// The stack goes just below the top, with an unmapped page above it and
// nothing mapped below it but what the program asks for.
STACK_TOP :: u64(0x0000_7fff_ffff_0000)
STACK_SIZE :: u64(256 * 1024)

// Maps each loadable segment of the image into the task; returns the entry point.
@(private="file")
elf_load :: proc "contextless" (task: vx.Handle, image: []u8) -> (entry: u64, st: vx.Status) {
	eh: Elf_Header
	if len(image) < size_of(eh) {
		return 0, .Err_Invalid
	}
	intrinsics.mem_copy_non_overlapping(&eh, raw_data(image), size_of(eh))
	table, o1 := intrinsics.overflow_mul(u64(eh.phnum), size_of(Elf_Phdr))
	table_end, o2 := intrinsics.overflow_add(table, eh.phoff)
	if string(eh.ident[:4]) != "\x7fELF" || eh.ident[4] != 2 || eh.ident[5] != 1 || eh.type != 2 || eh.machine != ELF_MACHINE ||
	   eh.phentsize != size_of(Elf_Phdr) || o1 || o2 || table_end > u64(len(image)) || eh.entry >= USER_TOP {
		return 0, .Err_Invalid
	}
	for i in 0 ..< u64(eh.phnum) {
		ph: Elf_Phdr
		intrinsics.mem_copy_non_overlapping(&ph, &image[eh.phoff + i * size_of(Elf_Phdr)], size_of(ph))
		if ph.type != 1 || ph.memsz == 0 { // PT_LOAD
			continue
		}
		file_end, o3 := intrinsics.overflow_add(ph.offset, ph.filesz)
		mem_end, o4 := intrinsics.overflow_add(ph.vaddr, ph.memsz)
		if ph.filesz > ph.memsz || o3 || file_end > u64(len(image)) || o4 || mem_end > STACK_TOP - STACK_SIZE - 4096 ||
		   (ph.flags & 2 != 0 && ph.flags & 1 != 0) { // PF_W and PF_X
			return 0, .Err_Invalid
		}
		base := ph.vaddr &~ 4095
		map_size := ((mem_end + 4095) &~ 4095) - base
		vmo := vmo_create(map_size) or_return
		if ph.filesz > 0 {
			st = vmo_write(vmo, ph.vaddr - base, image[ph.offset:file_end])
		}
		if st == .Ok {
			flags: vx.Map_Options
			if ph.flags & 2 != 0 {
				flags += {.Write}
			}
			if ph.flags & 1 != 0 {
				flags += {.Exec}
			}
			_, st = as_map(task, vmo, 0, map_size, flags, base)
		}
		_ = handle_close(vmo) // the mapping keeps it
		if st != .Ok {
			return 0, st
		}
	}
	return eh.entry, .Ok
}

Spawn_Args :: struct {
	name:         string, // the task's name and the spawn= record
	image:        []u8,
	handles:      []vx.Handle, // given to the child: they leave the caller, whatever happens
	handle_names: []string, // at most CHANNEL_MAX_HANDLES - 1; "self" is added
	records:      string, // more ndb records for the spawn message: arg=, mount=, bind=
}

@(private="file")
spawn_out: [vx.CHANNEL_MAX_BYTES]u8

@(private="file")
close_all :: proc "contextless" (handles: []vx.Handle) {
	for h in handles {
		if h != 0 {
			_ = handle_close(h)
		}
	}
}

// Builds and starts the child; returns the parent's handle to it, to watch
// (.Exit) or kill.
spawn_elf :: proc "contextless" (a: ^Spawn_Args) -> (task: vx.Handle, st: vx.Status) {
	if len(a.handles) >= vx.CHANNEL_MAX_HANDLES {
		close_all(a.handles)
		return 0, .Err_Range
	}
	// The spawn message: the header, then its records.
	w := ndb.Writer{buf = spawn_out[size_of(vx.Msg_Header):]}
	ndb.put(&w, "spawn", a.name)
	_ = ndb.end(&w)
	ndb.put(&w, "handle", "self")
	ndb.put_u64(&w, "index", 0)
	_ = ndb.end(&w)
	for name, i in a.handle_names {
		ndb.put(&w, "handle", name)
		ndb.put_u64(&w, "index", u64(i + 1))
		_ = ndb.end(&w)
	}
	if !w.failed && len(a.records) <= len(w.buf) - w.len {
		copy(w.buf[w.len:], a.records)
		w.len += len(a.records)
	} else {
		w.failed = true
	}
	if w.failed {
		close_all(a.handles)
		return 0, .Err_Range
	}
	(cast(^vx.Msg_Header)&spawn_out[0])^ = {ordinal = vx.SPAWN}

	t, me, stack, thread, ours, theirs: vx.Handle
	entry: u64
	t, st = task_create(a.name)
	if st == .Ok {
		entry, st = elf_load(t, a.image)
	}
	if st == .Ok {
		stack, st = vmo_create(STACK_SIZE)
	}
	if st == .Ok {
		_, st = as_map(t, stack, 0, STACK_SIZE, {.Write}, STACK_TOP - STACK_SIZE)
	}
	if st == .Ok {
		me, st = handle_dup(t, vx.ALL_RIGHTS)
	}
	if st == .Ok {
		ours, theirs, st = channel_create()
	}
	if st == .Ok {
		given: [vx.CHANNEL_MAX_HANDLES]vx.Handle
		given[0] = me
		copy(given[1:], a.handles)
		st = channel_write(ours, spawn_out[:size_of(vx.Msg_Header) + w.len], given[:len(a.handles) + 1])
		me = 0 // moved, whatever happened
	} else {
		close_all(a.handles)
	}
	if st == .Ok {
		thread, st = thread_create(t)
	}
	if st == .Ok {
		st = thread_start(thread, entry, STACK_TOP, theirs, 0)
	}
	if st == .Ok {
		theirs = 0 // moved into the child
	}
	close_all({stack, me, thread, ours, theirs}) // the child reads its message after our end is gone
	if st != .Ok {
		if t != 0 {
			_ = task_kill(t, -1)
			_ = handle_close(t)
		}
		return 0, st
	}
	return t, .Ok
}
