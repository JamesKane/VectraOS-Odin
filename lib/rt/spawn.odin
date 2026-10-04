package rt

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:ndb"
import "vx:process"
import "vx:str"

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
#assert(size_of(Elf_Header) == 64)

// A segment's permissions: PF_X is bit 0, PF_W bit 1, PF_R bit 2.
@(private="file")
Elf_Pf :: enum u32 {
	X,
	W,
	R,
}

@(private="file")
Elf_Phdr :: struct {
	type:                                       u32,
	flags:                                      bit_set[Elf_Pf;u32],
	offset, vaddr, paddr, filesz, memsz, align: u64,
}
#assert(size_of(Elf_Phdr) == 56)

@(private="file")
ELFCLASS64 :: 2
@(private="file")
ELFDATA2LSB :: 1
@(private="file")
ET_EXEC :: 2
@(private="file")
PT_LOAD :: 1

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

// Maps each loadable segment of the image into the task; returns the entry
// point. Each header is read once, from wherever it lies: an image in
// memory need not be aligned.
@(private="file")
elf_load :: proc "contextless" (task: vx.Handle, image: []u8) -> (entry: u64, st: vx.Status) {
	if len(image) < size_of(Elf_Header) {
		return 0, .Err_Invalid
	}
	eh := intrinsics.unaligned_load((^Elf_Header)(raw_data(image)))
	table, o1 := intrinsics.overflow_mul(u64(eh.phnum), size_of(Elf_Phdr))
	table_end, o2 := intrinsics.overflow_add(table, eh.phoff)
	if string(eh.ident[:4]) != "\x7fELF" || eh.ident[4] != ELFCLASS64 || eh.ident[5] != ELFDATA2LSB || eh.type != ET_EXEC ||
	   eh.machine != ELF_MACHINE || eh.phentsize != size_of(Elf_Phdr) || o1 || o2 || table_end > u64(len(image)) || eh.entry >= USER_TOP {
		return 0, .Err_Invalid
	}
	entry_found := false // the entry point must be in an executable segment
	for i in 0 ..< u64(eh.phnum) {
		ph := intrinsics.unaligned_load((^Elf_Phdr)(&image[eh.phoff + i * size_of(Elf_Phdr)]))
		if ph.type != PT_LOAD || ph.memsz == 0 {
			continue
		}
		file_end, o3 := intrinsics.overflow_add(ph.offset, ph.filesz)
		mem_end, o4 := intrinsics.overflow_add(ph.vaddr, ph.memsz)
		// Not in the first page either: there, an address of 0 asks as_map to pick one.
		if ph.vaddr < memory.PAGE_SIZE || ph.filesz > ph.memsz || o3 || file_end > u64(len(image)) || o4 || mem_end > STACK_TOP - STACK_SIZE - memory.PAGE_SIZE ||
		   ph.flags >= {.W, .X} {
			return 0, .Err_Invalid
		}
		base := memory.page_trunc(ph.vaddr)
		top, _ := memory.page_round(mem_end) // below STACK_TOP, so it cannot overflow
		map_size := top - base
		vmo := vmo_create(map_size) or_return
		defer close_all(vmo) // the mapping keeps it
		if ph.filesz > 0 {
			vmo_write(vmo, ph.vaddr - base, image[ph.offset:file_end]) or_return
		}
		flags: vx.Map_Options
		if .W in ph.flags {
			flags += {.Write}
		}
		if .X in ph.flags {
			flags += {.Exec}
		}
		va := as_map(task, vmo, 0, map_size, flags, base) or_return
		if va != base {
			return 0, .Err_Invalid // mapped, but not where the program was linked to run
		}
		if .X in ph.flags && eh.entry >= ph.vaddr && eh.entry < mem_end {
			entry_found = true
		}
	}
	if !entry_found {
		return 0, .Err_Invalid
	}
	return eh.entry, .Ok
}

Spawn_Args :: struct {
	name:         string, // the task's name and the spawn= record
	image:        []u8,
	handles:      []vx.Handle, // given to the child: they leave the caller, whatever happens
	handle_names: []string, // at most CHANNEL_MAX_HANDLES - 1; "self" is added
	records:      string, // more ndb records for the spawn message: arg=, mount=, bind=
	// Who the child runs as (user=): this, or else the caller's own.
	// Advisory until keyd (upstream's M10): a program can say it is anyone.
	user:         string,
	// If set, called once the task exists and its image is loaded, before
	// its message is written or its thread started: it may give the child
	// one more handle, named (a handle left HANDLE_NONE gives none).
	prepare:      proc "contextless" (ctx: rawptr, task: vx.Handle) -> (h: vx.Handle, name: string, st: vx.Status),
	ctx:          rawptr,
	// Exec instead of spawn (ADR-0012): the caller becomes the program, and
	// spawn_elf returns only on a failure. "self" names the caller's own task.
	exec:         bool,
	// If set, a connector to procfs's listen channel: the child is registered
	// there before it runs, with these flags (vx:process). A child that
	// cannot be registered is not started, unless the caller asked for no
	// wait record (.No_Wait): it watches the child itself, so a procfs that
	// is gone leaves it able to run programs.
	proc_conn:    vx.Handle,
	proc_flags:   process.Flags,
	proc_group:   u64, // a note group to join, or 0
	// If set (with proc_conn), called once the child is registered, with its
	// pid, before its thread exists: a debugger sets its breakpoints there,
	// so the program stops at them from its first instruction. A failure
	// ends the spawn.
	registered:   proc "contextless" (ctx: rawptr, pid: u64) -> vx.Status,
}

// How long a registration may take before procfs is taken to be gone.
@(private="file")
REGISTER_WAIT :: vx.Instant(2_000_000_000)

// Registers a task as a child of the caller with procfs, through a connector
// to its listen channel (vx:process), in note group `group` if not 0.
// Returns the child's pid.
@(require_results)
proc_register :: proc "contextless" (connector, task: vx.Handle, flags: process.Flags, group: u64 = 0) -> (pid: u64, st: vx.Status) {
	parent: i64
	if self != vx.HANDLE_NONE {
		if me, ist := task_info(self); ist == .Ok {
			parent = i64(me.id)
		}
	}
	dup := handle_dup(task, vx.RIGHTS_SAME) or_return
	req := process.Msg {
		header = {ordinal = process.REGISTER},
		arg = {parent, i64(transmute(u32)flags), i64(group)},
	}
	rep: process.Msg
	call := vx.Call {
		wr_bytes   = &req,
		wr_len     = size_of(req),
		wr_handles = &dup,
		wr_count   = 1,
		rd_bytes   = &rep,
		rd_cap     = size_of(rep),
	}
	channel_call(connector, &call, clock_read() + REGISTER_WAIT) or_return
	if call.actual.bytes < size_of(rep) {
		return 0, .Err_Invalid
	}
	process.reply_status(&rep) or_return
	return u64(rep.arg[0]), .Ok
}

// The spawn message being built: its header, then its records.
@(private="file")
spawn_out: struct {
	header:  vx.Msg_Header,
	records: [vx.CHANNEL_MAX_BYTES - size_of(vx.Msg_Header)]u8,
}
#assert(size_of(spawn_out) == vx.CHANNEL_MAX_BYTES)

// Builds and starts the child; returns the parent's handle to it, to watch
// (.Exit) or kill. With a.exec the caller becomes the program instead: the
// image is built the same way, in a scratch task, and task_exec moves it
// into the caller's own task (ADR-0012), so the task, and the pid, carry on
// with only the handles the spawn message names. Only a failure returns.
spawn_elf :: proc "contextless" (a: ^Spawn_Args) -> (task: vx.Handle, st: vx.Status) {
	t, stack, thread, ours, theirs: vx.Handle
	// "self", the caller's handles, and prepare's: given to the child in its
	// message, or closed, whatever happens.
	given: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES]string
	count := 1 + len(a.handles)
	// On the way out, in this order: what was to be given, unless it reached
	// the message; ours, which the child does not need (it reads its message
	// after our end is gone); and, on failure, the child.
	defer if st != .Ok && t != vx.HANDLE_NONE {
		_ = task_kill(t, "spawn failed")
		_ = handle_close(t)
	}
	defer close_all(stack, thread, ours, theirs)
	defer close_all(..given[:]) // HANDLE_NONE once moved

	if count > vx.CHANNEL_MAX_HANDLES - (a.prepare != nil ? 1 : 0) {
		close_all(..a.handles)
		return 0, .Err_Range
	}
	names[0] = "self"
	copy(given[1:], a.handles)
	copy(names[1:], a.handle_names)

	t = task_create(a.name) or_return
	entry := elf_load(t, a.image) or_return
	stack = vmo_create(STACK_SIZE) or_return
	_ = as_map(t, stack, 0, STACK_SIZE, {.Write}, STACK_TOP - STACK_SIZE) or_return
	if a.exec {
		given[0] = handle_dup(self, vx.RIGHTS_SAME) or_return
	} else {
		given[0] = handle_dup(t, vx.ALL_RIGHTS) or_return
	}
	if a.prepare != nil {
		h, name, pst := a.prepare(a.ctx, t)
		if h != vx.HANDLE_NONE { // counted, failure or not, so it is closed with the rest
			given[count], names[count] = h, name
			count += 1
		}
		pst or_return
	}

	// The spawn message: the header, then its records.
	w := ndb.Writer{buf = spawn_out.records[:]}
	ndb.put(&w, "spawn", a.name)
	_ = ndb.end(&w)
	if user := len(a.user) > 0 ? a.user : spawn.user; len(user) > 0 {
		ndb.put(&w, "user", user)
		_ = ndb.end(&w)
	}
	for name, i in names[:count] {
		ndb.put(&w, "handle", name)
		ndb.put_u64(&w, "index", u64(i))
		_ = ndb.end(&w)
	}
	str.write_string(&w, a.records)
	if w.failed {
		return 0, .Err_Range
	}
	spawn_out.header = {ordinal = vx.SPAWN}

	ours, theirs = channel_create() or_return
	wst := channel_write(ours, memory.ptr_to_bytes(&spawn_out)[:size_of(vx.Msg_Header) + w.len], given[:count])
	given = {} // moved, whatever happened
	wst or_return
	if a.exec {
		task_exec(t, theirs, entry, STACK_TOP) or_return // returns only on a failure
	}
	if a.proc_conn != vx.HANDLE_NONE {
		pid, reg := proc_register(a.proc_conn, t, a.proc_flags, a.proc_group)
		if .No_Wait not_in a.proc_flags {
			reg or_return
		}
		if reg == .Ok && a.registered != nil {
			a.registered(a.ctx, pid) or_return
		}
	}
	thread = thread_create(t) or_return
	thread_start(thread, entry, STACK_TOP, theirs, 0) or_return
	theirs = vx.HANDLE_NONE // moved into the child
	return t, .Ok
}
