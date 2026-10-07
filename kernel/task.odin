package kernel

import "base:intrinsics"
import vx "abi:vx"
import "vx:drbg"
import "vx:memory"
import "vx:utf"

// Tasks, threads, handles and address spaces.
//
// A task is an address space plus a handle table. Its user half is its own
// page tables; the kernel half is shared (arch_new_user_root).

USER_TOP :: Uva(0x0000_8000_0000_0000) // first address past the lower half
USER_MAP_BASE :: Uva(0x0000_1000_0000_0000) // where as_map puts mappings it places
USER_STACK_TOP :: Uva(0x0000_7fff_ffff_0000)
USER_STACK_SIZE :: 256 * 1024
TASK_MAX_IO :: 32 // I/O port ranges per task (bus-acpi: one for each its AML touches)

// I/O ports [base, base + count). The count is a u32 because one range may
// hold all 65,536 ports.
Io_Range :: struct {
	base:  u16,
	count: u32,
}

// --- Handles ---
//
// A handle is a table index in the low 16 bits and that slot's generation in
// the high 16. The generation is bumped each time the slot is freed, so a
// stale handle fails with BAD_HANDLE instead of reaching a new object. Index
// 0 is never used, so no valid handle is 0. Slots are taken lowest first,
// which makes handle values deterministic. A table is one page: 255 handles.

Handle_Entry :: struct {
	obj:        ^Object,
	rights:     vx.Rights,
	generation: u16,
	reserved:   u16,
}

HANDLE_SLOTS :: PAGE_SIZE / size_of(Handle_Entry)

// A mapping in a task's address space: [va, va + size) shows the VMO from
// `offset`. It holds a reference on the VMO.
Mapping :: struct {
	va:           Uva,
	size, offset: u64,
	vmo:          ^Vmo,
	flags:        vx.Map_Options,
	allowed:      vx.Map_Options, // what its VMO's handle gave when it was mapped: as_protect's limit
	key:          u32, // its protection key (ADR-0035): 0, or one its task allocated
	privatized:   bool, // its VMO is a copy of its own, made for a debugger's write (exception.odin)
}

TASK_MAX_MAPPINGS :: PAGE_SIZE / size_of(Mapping)

// A reservation (as_reserve, ADR-0020): address space no placed mapping
// lands in, kept for the task's own as_map at addresses inside it.
Reservation :: struct {
	va:   Uva,
	size: u64, // 0: the slot is free
}

TASK_MAX_RESERVATIONS :: 32

// A task's lock covers its handle table, its address space, its threads and
// its life (state, exit string, bindings on its exit) and where its faults go.
Task :: struct {
	using obj:       Object,
	lock:            Spinlock,
	id:              u64,
	root:            Paddr, // the address space's top table; 0 once torn down
	map_next:        Uva, // the next address as_map places at
	resv:            [TASK_MAX_RESERVATIONS]Reservation, // under the lock; they go with the address space (task_exec)
	keys:            bit_set[0 ..< 16; u16], // its protection keys, 1 to 15 (ADR-0035): as_key_alloc's
	handles:         ^[HANDLE_SLOTS]Handle_Entry, // nil once torn down
	maps:            ^[TASK_MAX_MAPPINGS]Mapping, // size 0 is a free slot
	mapped:          u64, // bytes
	threads:         ^Thread, // started and not yet reaped, through task_next
	live_threads:    u32,
	gone_ticks:      [Cpu_Time]u64, // user and system ticks of its threads reaped (ADR-0041)
	state:           vx.Task_State, // .Exited once torn down
	ending:          bool, // its last thread has exited, or it was killed: torn down soon
	killed:          bool,
	execing:         bool, // in, or the scratch of, a task_exec: no thread starts until the address spaces have changed places
	exit:            [dynamic; vx.ERRMAX]u8, // its exit string (ADR-0010): empty while it runs, and for success
	obs:             Observers, // EXIT bindings
	// The root task's debug capability, until there is a debug-log object; a
	// task gets it from the task that creates it.
	may_debug_write: bool,
	name:            [24]u8,
	parent_id:       u64, // the task that created it, or its nearest live creator; 0 for the root task
	all_next:        ^Task, // in all_tasks
	io:              [dynamic; TASK_MAX_IO]Io_Range, // I/O ports it may use (x86_64, device.odin)
	thread_ids:      u32, // the last thread's id: ids count from 1, in creation order
	// Where its faults go (exception.odin): an in-task handler, then a port.
	exc_handler:     Uva,
	exc_port:        ^Port, // a reference, or nil
	exc_key:         u64,
	dbg_port:        ^Port, // a debugger's, which sees faults first (.First_Chance); a reference, or nil
	dbg_key:         u64,
	watches:         [vx.WATCH_MAX]vx.Watch, // its watchpoints (thread_state .Set_Watch), loaded as its threads run
	watching:        bool, // any of them on
}

#assert(offset_of(Task, obj) == 0) // objects are cast from ^Object

Thread_State :: enum u8 {
	New, // created, never run
	Ready,
	Running,
	Blocked,
	Dead,
}

// Everything from `state` on belongs to the scheduler and is under its lock.
Thread :: struct {
	using obj:    Object,
	task:         ^Task, // nil for an idle thread
	task_next:    ^Thread, // in its task's list, under the task's lock
	kernel_sp:    u64, // saved by the context switch
	kstack:       u64, // the kernel stack's lowest byte (kstack.odin); 0 for CPU 0's idle thread
	user_entry:   Uva,
	user_sp:      Uva,
	user_arg:     u64,
	user_arg2:    u64,
	started:      bool, // thread_start has taken it (under its task's lock)
	intent:       vx.Intent, // its own (sched_ctx_configure with no context)
	last_of_task: bool, // its exit ended its task (reaped in sched.odin)
	console_line: User_Line, // debug_write output not yet ended, which goes out whole at its newline
	state:        Thread_State,
	// Its scheduling (sched.odin, ADR-0016), under the scheduler's lock: the
	// context it is bound to, holding a reference, and the CPU of that
	// context's reservation it is bound to; the channel_call caller lending
	// it its scheduling, and the thread this one, in channel_call, lends its
	// own to; and whether its loan's call has been answered, so that it
	// keeps the loan only until it blocks, or its slice ends.
	ctx:          ^Sched_Ctx,
	core:         Maybe(u32),
	donor:        ^Thread,
	donee:        ^Thread,
	lend_tail:    bool,
	ticks:        [Cpu_Time]u64, // user and system ticks charged to it (sched_timer, ADR-0041), atomically
	next:         ^Thread, // in the ready queue (under the scheduler's lock)
	wait_next:    ^Thread, // in a port's waiters (under the port's lock); never the same link as next
	sleep_next:   ^Thread, // in its CPU's sleep queue, ordered by wake_at
	sleep_cpu:    ^Cpu, // the CPU whose sleep queue holds it
	cpu:          ^Cpu, // the CPU it runs or last ran on
	wake_at:      Instant, // the deadline it sleeps until
	wake_late:    Instant, // wake_at plus its leeway: the timer may wait until here
	wait_token:   rawptr, // what it waits on, until it is woken or times out (sched.odin)
	wake_pending:   bool, // woken between joining a list of waiters and blocking
	pending_result: vx.Status, // and the result that block returns at once
	wait_result:    vx.Status,
	// Exceptions and interrupts (exception.odin), under its task's lock.
	id:                u32, // in its task
	exited:            bool, // it has exited, and waits to be reaped: no note reaches it
	exc_stopped:       bool, // stopped at its task's exception port, until exception_resume
	exc_first:         bool, // and that port is a debugger's
	exc_action:        Maybe(vx.Resume_Action), // what exception_resume said
	suspend_count:     u32, // thread_suspend, less thread_resume
	parked:            bool, // stopped on its way to user mode while suspended
	stepping:          bool, // a debugger asked for one instruction (arch_frame_step): aarch64's MDSCR_EL1.SS, x86_64's TF
	tls:               u64, // its user thread pointer while it is not running (sched.odin's user_switch)
	// Its protection-key rights (PKRU) while it is not running, loaded as it
	// next runs (user_switch); a new thread's first (ADR-0035).
	rights:            u64,
	user_held:         bool, // stopped at an exception: tls is its own, saved, for a debugger (exception_stop)
	// Where its in-task handler runs, if set (.Set_Note_Stack, ADR-0036): only
	// the thread itself changes them.
	note_stack:        Uva,
	note_stack_size:   u64,
	robust_head:       Uva, // its robust list (thread_set_robust, ADR-0037); 0: none
	robust_owner:      u32, // the owner value its robust lock words hold
	// thread_interrupt's notes not yet delivered, oldest first: each is its
	// own exception (Plan 9 queued notes the same way).
	interrupt_pending: bool, // notes waiting, read without the lock
	notes:             [dynamic; THREAD_MAX_INTERRUPTS]Note,
	exc:               vx.Exception, // the exception it stopped at
}

#assert(size_of(Thread) <= PAGE_SIZE) // a pool object

#assert(offset_of(Thread, obj) == 0) // objects are cast from ^Object

handle_value :: proc "contextless" (index: u32, generation: u16) -> vx.Handle {
	return vx.Handle(u32(generation) << 16 | index)
}

@(private="file")
entry_for :: proc "contextless" (t: ^Task, h: vx.Handle) -> ^Handle_Entry {
	index := u32(h) & 0xffff
	if index == 0 || index >= HANDLE_SLOTS || t.handles == nil {
		return nil
	}
	e := &t.handles[index]
	if e.obj == nil || u32(e.generation) != u32(h) >> 16 {
		return nil
	}
	return e
}

@(private="file")
free_slot :: proc "contextless" (e: ^Handle_Entry) {
	e.obj = nil
	e.generation += 1
	if e.generation == 0 {
		e.generation = 1
	}
}

// Gives the task a handle to obj, taking a reference for it.
@(require_results)
handle_add :: proc "contextless" (t: ^Task, obj: ^Object, rights: vx.Rights) -> (vx.Handle, vx.Status) {
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	if t.handles == nil {
		return 0, .Err_Bad_State
	}
	for i in u32(1) ..< HANDLE_SLOTS {
		e := &t.handles[i]
		if e.obj != nil {
			continue
		}
		if e.generation == 0 {
			e.generation = 1
		}
		e.obj = obj
		e.rights = rights
		object_ref(obj)
		return handle_value(i, e.generation), .Ok
	}
	return 0, .Err_No_Memory
}

// The object behind a handle, with a reference the caller releases, if it is
// of the given type and the handle has every right asked for.
@(require_results)
handle_get :: proc "contextless" (t: ^Task, h: vx.Handle, type: Obj_Type, rights: vx.Rights) -> (^Object, vx.Status) {
	obj, _, st := handle_get_rights(t, h, type, rights)
	return obj, st
}

// handle_get, and the rights the handle has.
@(require_results)
handle_get_rights :: proc "contextless" (t: ^Task, h: vx.Handle, type: Obj_Type, rights: vx.Rights) -> (^Object, vx.Rights, vx.Status) {
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	e := entry_for(t, h)
	if e == nil || e.obj.type != type {
		return nil, {}, .Err_Bad_Handle
	}
	if rights - e.rights != {} {
		return nil, {}, .Err_Access
	}
	object_ref(e.obj)
	return e.obj, e.rights, .Ok
}

// A second handle to h's object, with h's rights or, if `rights` is given,
// those, which may only be fewer. h needs DUPLICATE.
@(require_results)
handle_dup :: proc "contextless" (t: ^Task, h: vx.Handle, rights: Maybe(vx.Rights)) -> (dup: vx.Handle, st: vx.Status) {
	obj, r := dup_source(t, h, rights) or_return
	defer object_release(obj)
	return handle_add(t, obj, r)
}

@(private="file", require_results)
dup_source :: proc "contextless" (t: ^Task, h: vx.Handle, rights: Maybe(vx.Rights)) -> (obj: ^Object, r: vx.Rights, st: vx.Status) {
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	e := entry_for(t, h)
	if e == nil {
		return nil, {}, .Err_Bad_Handle
	}
	r = rights.? or_else e.rights
	if .Duplicate not_in e.rights || r - e.rights != {} {
		return nil, {}, .Err_Access
	}
	object_ref(e.obj)
	return e.obj, r, .Ok
}

// handle_get for an object of type T, as a ^T.
@(require_results)
handle_get_as :: proc "contextless" (t: ^Task, h: vx.Handle, $T: typeid, rights: vx.Rights) -> (p: ^T, st: vx.Status) {
	#assert(offset_of(T, obj) == 0)
	o := handle_get(t, h, obj_type_of(T), rights) or_return
	return cast(^T)o, .Ok
}

@(require_results)
handle_close :: proc "contextless" (t: ^Task, h: vx.Handle) -> vx.Status {
	spin_lock(&t.lock)
	e := entry_for(t, h)
	obj: ^Object
	if e != nil {
		obj = e.obj
		free_slot(e)
	}
	spin_unlock(&t.lock)
	if obj == nil {
		return .Err_Bad_Handle
	}
	object_release(obj)
	return .Ok
}

// Closes every handle t holds (task_exec): the new program starts with only
// what its spawn message names.
handles_close_all :: proc "contextless" (t: ^Task) {
	for i in 1 ..< HANDLE_SLOTS {
		obj: ^Object
		{
			spin_guard(&t.lock)
			if t.handles == nil {
				return
			}
			e := &t.handles[i]
			obj = e.obj
			if obj != nil {
				free_slot(e)
			}
		}
		if obj != nil {
			object_release(obj)
		}
	}
}

// A handle in flight: the reference the sender's handle held, and its rights.
Moved_Handle :: struct {
	obj:    ^Object,
	rights: vx.Rights,
}

// Takes handles out of the task's table, all or none: each must exist, carry
// TRANSFER, appear once, and not be `forbidden` (a channel end cannot travel
// through itself). Their references move into out.
@(require_results)
handles_take :: proc "contextless" (t: ^Task, values: []vx.Handle, forbidden, forbidden2: ^Object, out: []Moved_Handle) -> vx.Status {
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	for v, i in values {
		e := entry_for(t, v)
		switch {
		case e == nil:
			return .Err_Bad_Handle
		case .Transfer not_in e.rights:
			return .Err_Access
		case e.obj == forbidden || (forbidden2 != nil && e.obj == forbidden2):
			return .Err_Invalid
		}
		for k in 0 ..< i {
			if values[k] == v {
				return .Err_Invalid
			}
		}
	}
	for v, i in values {
		e := entry_for(t, v)
		out[i] = {e.obj, e.rights}
		free_slot(e)
	}
	return .Ok
}

// Installs moved handles in the task's table, writing their values to out.
// On failure none is installed. Either way the moved references are the
// caller's to release.
@(require_results)
handles_put :: proc "contextless" (t: ^Task, moved: []Moved_Handle, out: []vx.Handle) -> vx.Status {
	for m, i in moved {
		h, st := handle_add(t, m.obj, m.rights)
		if st != .Ok {
			for k in 0 ..< i {
				_ = handle_close(t, out[k])
			}
			return st
		}
		out[i] = h
	}
	return .Ok
}

task_pool: Pool(Task)
thread_pool: Pool(Thread)

@(private="file")
next_task_id: u64 = 1

// Every live task, so a task's descendants can be found (task_find). When a
// task goes, its children pass to its parent, so the chain of creators from
// any task back to the root never breaks. The pager walks it too, to find
// every mapping of a VMO (pager.odin).
@(private)
all_tasks: ^Task
@(private)
all_tasks_lock: Spinlock

@(private="file")
task_by_id :: proc "contextless" (id: u64) -> ^Task { // under all_tasks_lock
	for t := all_tasks; t != nil; t = t.all_next {
		if t.id == id {
			return t
		}
	}
	return nil
}

@(private="file")
task_in_tree :: proc "contextless" (task: ^Task, root: u64) -> bool { // under all_tasks_lock
	t := task
	for hops := 0; t != nil && hops < 4096; hops += 1 {
		if t.id == root {
			return true
		}
		t = t.parent_id != 0 ? task_by_id(t.parent_id) : nil
	}
	return false
}

// The task `id` (or, with next, the one with the next id after it) in the
// tree under `root`, with a reference; nil if there is none.
task_find :: proc "contextless" (root, id: u64, next: bool) -> ^Task {
	spin_lock(&all_tasks_lock)
	defer spin_unlock(&all_tasks_lock)
	best: ^Task
	for t := all_tasks; t != nil; t = t.all_next {
		if (next ? t.id <= id : t.id != id) || (best != nil && t.id >= best.id) {
			continue
		}
		if task_in_tree(t, root) {
			best = t
		}
	}
	// A task on its way to being destroyed is still listed, and still in
	// memory while the lock is held; it is simply not found.
	if best != nil && !object_tryref(&best.obj) {
		best = nil
	}
	return best
}

// The task is being destroyed: off the list, and its children to its parent.
task_unlist :: proc "contextless" (t: ^Task) {
	spin_lock(&all_tasks_lock)
	unlink(&all_tasks, t, "all_next")
	for c := all_tasks; c != nil; c = c.all_next {
		if c.parent_id == t.id {
			c.parent_id = t.parent_id
		}
	}
	spin_unlock(&all_tasks_lock)
}

@(require_results)
task_create :: proc "contextless" (name: string, parent_id: u64) -> (task: ^Task, st: vx.Status) {
	t := pool_alloc(&task_pool)
	if t == nil {
		return nil, .Err_No_Memory
	}
	defer if st != .Ok {
		pool_free(&task_pool, t)
	}
	handles := phys_alloc_zeroed(0)
	if handles == 0 {
		return nil, .Err_No_Memory
	}
	defer if st != .Ok {
		phys_free(handles, 0)
	}
	maps := phys_alloc_zeroed(0)
	if maps == 0 {
		return nil, .Err_No_Memory
	}
	defer if st != .Ok {
		phys_free(maps, 0)
	}
	root := arch_new_user_root()
	if root == 0 {
		return nil, .Err_No_Memory
	}
	object_init(&t.obj, .Task) // pool_alloc zeroed the rest
	t.id = intrinsics.atomic_add_explicit(&next_task_id, 1, .Relaxed)
	t.root = root
	t.map_next = USER_MAP_BASE
	t.handles = cast(^[HANDLE_SLOTS]Handle_Entry)phys_to_virt(handles)
	t.maps = cast(^[TASK_MAX_MAPPINGS]Mapping)phys_to_virt(maps)
	copy(t.name[:], utf_cut(name, len(t.name) - 1)) // whole runes (ADR-0013)
	t.parent_id = parent_id
	spin_lock(&all_tasks_lock)
	t.all_next = all_tasks
	all_tasks = t
	spin_unlock(&all_tasks_lock)
	return t, .Ok
}

// The longest prefix of s of at most max bytes that ends at a rune boundary:
// where a bounded copy of text is cut (ADR-0013). A bad byte is a rune of
// its own. The kernel cuts, as Plan 9's kstrcpy does, but does not validate.
utf_cut :: proc "contextless" (s: string, max_bytes: int) -> string {
	if len(s) <= max_bytes {
		return s
	}
	at := 0
	for at < max_bytes {
		_, n := utf.decode(s[at:])
		if at + n > max_bytes {
			break
		}
		at += n
	}
	return s[:at]
}

task_name :: proc "contextless" (t: ^Task) -> string {
	n := 0
	for n < len(t.name) && t.name[n] != 0 {
		n += 1
	}
	return string(t.name[:n])
}

// The first of t's mappings that ends after addr (as_query). An ended task's
// table is gone (task_teardown): nothing to find, as task_map refuses.
@(require_results)
task_query :: proc "contextless" (t: ^Task, addr: Uva) -> (info: vx.Map_Info, st: vx.Status) {
	spin_guard(&t.lock)
	if t.maps == nil {
		return {}, .Err_Bad_State
	}
	best: ^Mapping
	for &m in t.maps {
		if m.size != 0 && m.va + Uva(m.size) > addr && (best == nil || m.va < best.va) {
			best = &m
		}
	}
	if best == nil {
		return {}, .Err_Not_Found
	}
	return {base = u64(best.va), size = best.size, offset = best.offset, flags = vx.map_flags(best.flags, best.key)}, .Ok
}

// The page-table flags for a user mapping.
user_map_flags :: proc "contextless" (flags: vx.Map_Options, device: bool) -> Map_Flags {
	mf := Map_Flags{.User}
	if .Write in flags {
		mf += {.Write}
	}
	if .Exec in flags {
		mf += {.Exec}
	}
	if device {
		mf += {.Device}
	}
	return mf
}

// How a page of a mapping is mapped: writable only if the mapping is and,
// for a pager's page, only once it is dirty (pager.odin).
page_map_flags :: proc "contextless" (v: ^Vmo, flags: vx.Map_Options, page: Page) -> Map_Flags {
	mf := user_map_flags(flags, v.physical)
	if v.pager != nil && !page.dirty {
		mf -= {.Write}
	}
	return mf
}

// The start of the first mapping or reservation that [va, end) overlaps, or
// 0 if none does. Under the task's lock.
@(private="file")
task_in_way :: proc "contextless" (t: ^Task, va, end: Uva) -> Uva {
	first: Uva
	if t.maps != nil {
		for m in t.maps {
			if m.size != 0 && m.va < end && va < m.va + Uva(m.size) && (first == 0 || m.va < first) {
				first = m.va
			}
		}
	}
	for r in t.resv {
		if r.size != 0 && r.va < end && va < r.va + Uva(r.size) && (first == 0 || r.va < first) {
			first = r.va
		}
	}
	return first
}

// Whether any mapping overlaps [va, end). Under the task's lock.
@(private="file")
task_maps_in :: proc "contextless" (t: ^Task, va, end: Uva) -> bool {
	if t.maps != nil {
		for m in t.maps {
			if m.size != 0 && m.va < end && va < m.va + Uva(m.size) {
				return true
			}
		}
	}
	return false
}

// Whether [va, end) lies wholly inside one reservation or outside every one.
@(private="file")
task_resv_fits :: proc "contextless" (t: ^Task, va, end: Uva) -> bool {
	for r in t.resv {
		if r.size != 0 && r.va < end && va < r.va + Uva(r.size) {
			return va >= r.va && end <= r.va + Uva(r.size)
		}
	}
	return true
}

// Where as_map places a mapping of size bytes: from map_next on, past any
// reservation or mapping in the way (a mapping placed at an address, as
// mremap's growth in place, may lie there), a guard page after it.
@(private="file")
task_place :: proc "contextless" (t: ^Task, size: u64) -> Uva {
	at := t.map_next
	for _ in 0 ..= TASK_MAX_RESERVATIONS + TASK_MAX_MAPPINGS {
		moved := false
		for r in t.resv {
			if r.size != 0 && r.va < at + Uva(size) && at < r.va + Uva(r.size) {
				at = r.va + Uva(r.size) + PAGE_SIZE
				moved = true
			}
		}
		if t.maps != nil {
			for &m in t.maps {
				if m.size != 0 && m.va < at + Uva(size) && at < m.va + Uva(m.size) {
					at = m.va + Uva(m.size) + PAGE_SIZE
					moved = true
				}
			}
		}
		if !moved {
			break
		}
	}
	return at
}

// Maps [offset, offset + size) of a VMO into a task's address space. With
// va == 0 the kernel picks the address; otherwise va is used and must be
// page-aligned and free. The mapping holds a reference on the VMO. W^X:
// never writable and executable. key is the mapping's protection key, 0 or
// one the task allocated; allowed what the VMO's handle gave, which
// as_protect may later give the mapping and no more (ADR-0035). .No_Access
// maps no page: a touch faults (ADR-0020).
@(require_results)
task_map :: proc "contextless" (t: ^Task, v: ^Vmo, offset, size: u64, flags: vx.Map_Options, want_va: Uva, key: u32, allowed: vx.Map_Options) -> (Uva, vx.Status) {
	if flags >= {.Write, .Exec} {
		return 0, .Err_Access
	}
	vmo_end, overflow := intrinsics.overflow_add(offset, size)
	if size == 0 || (offset | size) & (PAGE_SIZE - 1) != 0 || overflow || vmo_end > v.size {
		return 0, .Err_Range
	}
	mf := user_map_flags(flags, v.physical)
	spin_lock(&t.lock)
	at := want_va != 0 ? want_va : task_place(t, size)
	end, end_overflow := intrinsics.overflow_add(at, Uva(size))
	slot: ^Mapping
	if t.maps != nil {
		for &m in t.maps {
			if m.size == 0 {
				slot = &m
				break
			}
		}
	}
	st := vx.Status.Ok
	switch {
	case t.root == 0 || t.maps == nil || t.ending:
		st = .Err_Bad_State
	case !key_ok(t, key):
		st = .Err_Invalid // a key it has not allocated
	case at & (PAGE_SIZE - 1) != 0 || end_overflow || end > USER_TOP || !task_resv_fits(t, at, end):
		st = .Err_Range
	case task_maps_in(t, at, end):
		st = .Err_Exists // checked against the mappings, not the page tables: a no-access one has no pages
	case vmo_revoked(v) && .No_Access not_in flags:
		st = .Err_Revoked // checked under the lock: a revoke after it finds this mapping (ADR-0021)
	case .Write in flags && vmo_sealed(v):
		st = .Err_Access // under the lock too: vmo_seal looks for writable mappings after it seals
	case slot == nil:
		st = .Err_No_Memory
	}
	// Page by page; a page that is already mapped (by another mapping) fails
	// it, and only the pages this call mapped are taken back out. A pager's
	// pages are mapped as far as it has supplied them, the rest as they are
	// touched (pager.odin).
	done: u64
	locked := vmo_locked(v)
	if locked {
		spin_lock(&v.lock)
		if st == .Ok && vmo_end > v.size {
			st = .Err_Range // shrunk since the check above
		}
	}
	none := .No_Access in flags
	for st == .Ok && done < size {
		page := none ? Page{} : v.pages[(offset + done) / PAGE_SIZE]
		pa := Paddr(page.frame << 12)
		pf := v.pager != nil ? page_map_flags(v, flags, page) : mf
		if pa != 0 && !map_range(t.root, u64(at) + done, pa, PAGE_SIZE, pf, key) {
			st = .Err_No_Memory
		} else {
			done += PAGE_SIZE
		}
	}
	if locked {
		spin_unlock(&v.lock)
	}
	if st != .Ok {
		for off := u64(0); off < done; off += PAGE_SIZE {
			unmap_page(t.root, u64(at) + off)
		}
		root := t.root
		spin_unlock(&t.lock)
		if done != 0 {
			arch_tlb_shootdown(root, at, done) // another thread may have touched them
		}
		return 0, st
	}
	object_ref(&v.obj)
	slot^ = {va = at, size = size, offset = offset, vmo = v, flags = flags, allowed = allowed, key = key}
	t.mapped += size
	if want_va == 0 {
		t.map_next = end + PAGE_SIZE // leave a guard page between placed mappings, past any reservation
	}
	spin_unlock(&t.lock)
	return at, .Ok
}

// task_create's .Fork: the new task gets a copy of the parent's memory and
// its handle table, and nothing else; the caller starts a thread in it.
//   - Each mapping is a copy, made now, of what the parent sees there, at
//     the same address with the same permissions. A ring's memory is not
//     copied (a copied ring is broken, a shared one would have two
//     producers), nor is device memory: the child finds those addresses
//     unmapped, and its library connects again.
//   - Each handle keeps its value and rights, so what the parent's memory
//     says about its handles (its file descriptors) holds in the child. A
//     handle to the parent itself becomes one to the child.
//   - A pager's VMO is shared, not copied: the child maps the same one, as
//     a file mapped MAP_SHARED is in both; so is a mapping made .Shared
//     (ADR-0020), MAP_SHARED anonymous memory, and a lease's (ADR-0021), so
//     no copy outlives a revoke.
//   - Its reservations are the parent's.
//   - The in-task fault handler is the parent's (signal handlers are
//     inherited); exception ports, a debugger and I/O ports are not.
@(require_results)
task_fork_copy :: proc "contextless" (parent, child: ^Task) -> vx.Status {
	spin_guard(&parent.lock)
	if parent.root == 0 || parent.ending {
		return .Err_Bad_State
	}
	child.keys = parent.keys // first: the mappings below carry their keys
	child.resv = parent.resv // and its reservations, which they may lie in
	for m in parent.maps {
		if m.size == 0 || m.vmo.physical || m.vmo.ring {
			continue
		}
		// The same VMO: a file's pages, MAP_SHARED memory, a lease (a revoke
		// reaches the child).
		if m.vmo.pager != nil || .Shared in m.flags || m.vmo.lease_of != nil {
			flags, key := m.flags, m.key
			if vmo_revoked(m.vmo) {
				flags, key = {.No_Access}, 0 // a revoked lease's: its place, no pages
			}
			_ = task_map(child, m.vmo, m.offset, m.size, flags, m.va, key, m.allowed) or_return
			continue
		}
		dup := vmo_create(m.size) or_return
		v := m.vmo
		if v.resizable {
			spin_lock(&v.lock) // a page past a shrink's end is absent: the copy's stays zero
		}
		for i in 0 ..< m.size / PAGE_SIZE {
			if pa := vmo_page_in(v, m.offset / PAGE_SIZE + i); pa != 0 {
				page_copy(vmo_page(dup, i), pa)
			}
		}
		if v.resizable {
			spin_unlock(&v.lock)
		}
		_, st := task_map(child, dup, 0, m.size, m.flags, m.va, m.key, m.allowed)
		object_release(&dup.obj) // the child's mapping holds it, if it was made
		if st != .Ok {
			return st
		}
	}
	for e, i in parent.handles {
		e := e
		if e.obj == &parent.obj {
			e.obj = &child.obj
		}
		if e.obj != nil {
			object_ref(e.obj)
		}
		child.handles[i] = e // free slots too: their generations go on from the parent's
	}
	child.map_next = parent.map_next
	child.exc_handler = parent.exc_handler
	return .Ok
}

// Unmaps [va, va + size): whole mappings, or the parts of them in the range;
// a mapping cut in the middle becomes two, so that needs a free slot. The
// page entries are cleared under the lock, the translations shot down after
// it (another CPU spinning on it could not answer), and only then are the
// VMOs let go, which may free their pages.
@(require_results)
task_unmap :: proc "contextless" (t: ^Task, va: Uva, size: u64) -> vx.Status {
	end, overflow := intrinsics.overflow_add(va, Uva(size))
	if size == 0 || (u64(va) | size) & (PAGE_SIZE - 1) != 0 || overflow || end > USER_TOP {
		return .Err_Range
	}
	drop: [dynamic; TASK_MAX_MAPPINGS]^Vmo
	root: Paddr
	{
		spin_guard(&t.lock)
		if t.root == 0 || t.maps == nil || t.ending {
			return .Err_Bad_State
		}
		splits, free_slots := 0, 0
		for m in t.maps {
			if m.size == 0 {
				free_slots += 1
			} else if m.va < va && m.va + Uva(m.size) > end {
				splits += 1
			}
		}
		if splits > free_slots {
			return .Err_No_Memory
		}
		for &m in t.maps {
			m_end := m.va + Uva(m.size)
			if m.size == 0 || m_end <= va || m.va >= end {
				continue
			}
			lo, hi := max(m.va, va), min(m_end, end)
			for p := lo; p < hi; p += PAGE_SIZE {
				unmap_page(t.root, u64(p))
			}
			t.mapped -= u64(hi - lo)
			switch {
			case lo == m.va && hi == m_end: // all of it
				_ = append(&drop, m.vmo)
				m = {}
			case lo == m.va: // its start
				m.offset += u64(hi - m.va)
				m.size = u64(m_end - hi)
				m.va = hi
			case hi == m_end: // its end
				m.size = u64(lo - m.va)
			case: // its middle: the end becomes a mapping of its own
				rest: ^Mapping
				for &r in t.maps {
					if r.size == 0 {
						rest = &r
						break
					}
				}
				object_ref(&m.vmo.obj)
				rest^ = m
				rest.va = hi
				rest.size = u64(m_end - hi)
				rest.offset = m.offset + u64(hi - m.va)
				m.size = u64(lo - m.va)
			}
		}
		root = t.root
	}
	arch_tlb_shootdown(root, va, size)
	for v in drop {
		object_release(&v.obj)
	}
	return .Ok
}

// A key the task may put on a mapping: 0, or one it allocated.
@(private="file")
key_ok :: proc "contextless" (t: ^Task, key: u32) -> bool {
	return key == 0 || (key < 16 && int(key) in t.keys)
}

// Changes the rights and key of [va, va + size), every page of which must be
// mapped (.Err_Not_Found otherwise), within the rights each mapping's handle
// gave (.Err_Access past them) and W^X; a mapping the range cuts becomes two
// or three, so that needs free slots (.Err_No_Memory, nothing changed). The
// pages' entries are made again with the new rights (a pager's as far as it
// has supplied them), then shot down (upstream's M6 step 6c4, ahead of 6e's
// other address-space calls).
@(require_results)
task_protect :: proc "contextless" (t: ^Task, va: Uva, size: u64, flags: vx.Map_Options, key: u32) -> vx.Status {
	end, overflow := intrinsics.overflow_add(va, Uva(size))
	if size == 0 || (u64(va) | size) & (PAGE_SIZE - 1) != 0 || overflow || end > USER_TOP {
		return .Err_Range
	}
	if flags >= {.Write, .Exec} {
		return .Err_Access
	}
	root: Paddr
	st := vx.Status.Ok
	{
		spin_guard(&t.lock)
		if t.root == 0 || t.maps == nil || t.ending {
			return .Err_Bad_State
		}
		if !key_ok(t, key) {
			return .Err_Invalid
		}
		covered: u64
		cuts, free_slots := 0, 0
		for m in t.maps {
			if m.size == 0 {
				free_slots += 1
				continue
			}
			m_end := m.va + Uva(m.size)
			if m_end <= va || m.va >= end {
				continue
			}
			if flags & {.Write, .Exec} - m.allowed != {} {
				return .Err_Access // more than its handle gave
			}
			if .Write in flags && vmo_sealed(m.vmo) {
				return .Err_Access // ADR-0021
			}
			covered += u64(min(m_end, end) - max(m.va, va))
			cuts += int(m.va < va) + int(m_end > end)
		}
		if covered != size {
			return .Err_Not_Found // a hole
		}
		if cuts > free_slots {
			return .Err_No_Memory
		}
		for &m in t.maps {
			if m.size == 0 || m.va + Uva(m.size) <= va || m.va >= end {
				continue
			}
			// What lies before the range, then after it, to slots of their own.
			if m.va < va {
				rest := free_mapping(t)
				object_ref(&m.vmo.obj)
				rest^ = m
				rest.size = u64(va - m.va)
				m.offset += u64(va - m.va)
				m.size -= u64(va - m.va)
				m.va = va
			}
			if m_end := m.va + Uva(m.size); m_end > end {
				rest := free_mapping(t)
				object_ref(&m.vmo.obj)
				rest^ = m
				rest.offset += u64(end - m.va)
				rest.size = u64(m_end - end)
				rest.va = end
				m.size = u64(end - m.va)
			}
			m.flags = flags + m.flags & {.Shared} // .Shared is as_map's, and stays
			m.key = key
			v := m.vmo
			locked := vmo_locked(v)
			if locked {
				spin_lock(&v.lock)
			}
			for off := u64(0); off < m.size && st == .Ok; off += PAGE_SIZE {
				index := (m.offset + off) / PAGE_SIZE
				pa := .No_Access in flags || vmo_revoked(v) ? 0 : vmo_page_in(v, index)
				unmap_page(t.root, u64(m.va) + off)
				if pa != 0 && !map_range(t.root, u64(m.va) + off, pa, PAGE_SIZE, page_map_flags(v, m.flags, v.pages[index]), m.key) {
					st = .Err_No_Memory
				}
			}
			if locked {
				spin_unlock(&v.lock)
			}
		}
		root = t.root
	}
	arch_tlb_shootdown(root, va, size)
	return st
}

// A free slot in the task's table of mappings, which the caller has counted.
@(private="file")
free_mapping :: proc "contextless" (t: ^Task) -> ^Mapping {
	for &r in t.maps {
		if r.size == 0 {
			return &r
		}
	}
	kpanic("free_mapping: no slot, after they were counted")
}

// as_reserve (ADR-0020): a reservation of size bytes aligned to align, at a
// random base or (.Fixed) at *va; or (.Release) the one at *va given back,
// after what is mapped in it is unmapped.
@(private="file")
resv_random: drbg.Drbg // the kernel's, seeded from the bootloader's entropy
@(private="file")
resv_random_lock: Spinlock

@(private="file")
resv_random_u64 :: proc "contextless" () -> (x: u64) {
	spin_guard(&resv_random_lock)
	if !resv_random.seeded {
		drbg.mix(&resv_random, memory.ptr_to_bytes(&boot.seed), true)
		drbg.mix(&resv_random, transmute([]u8)string("as_reserve"), false)
		now := clock_now() // without the bootloader's entropy, at least not the same each boot
		drbg.mix(&resv_random, memory.ptr_to_bytes(&now), false)
	}
	drbg.read(&resv_random, memory.ptr_to_bytes(&x))
	return
}

// The reservation of [va, va + size) exactly, or nil. Under the task's lock.
@(private="file")
task_resv_at :: proc "contextless" (t: ^Task, va: Uva, size: u64) -> ^Reservation {
	for &r in t.resv {
		if r.size != 0 && r.va == va && r.size == size {
			return &r
		}
	}
	return nil
}

// Unmaps what is in it first, while it is still reserved, so nothing as_map
// places can land there in between and be unmapped with it; then lets it go.
@(private="file", require_results)
task_release :: proc "contextless" (t: ^Task, va: Uva, size: u64) -> vx.Status {
	spin_lock(&t.lock)
	there := task_resv_at(t, va, size) != nil
	spin_unlock(&t.lock)
	if !there {
		return .Err_Not_Found
	}
	st := task_unmap(t, va, size)
	spin_lock(&t.lock)
	r := task_resv_at(t, va, size)
	if r != nil {
		r^ = {}
	}
	spin_unlock(&t.lock)
	if r == nil {
		return .Err_Not_Found // another thread's release took it
	}
	return st == .Err_Bad_State ? .Ok : st // a task torn down has none left to unmap
}

// *va is where it was made, or with .Err_Exists, where what is in the way
// starts.
@(require_results)
task_reserve :: proc "contextless" (t: ^Task, size, align_in: u64, flags: vx.As_Options, va: ^Uva) -> vx.Status {
	if .Release in flags {
		return task_release(t, va^, size)
	}
	align := align_in != 0 ? align_in : PAGE_SIZE
	if size == 0 || size & (PAGE_SIZE - 1) != 0 || size > u64(USER_TOP - USER_MAP_BASE) || align & (align - 1) != 0 || align < PAGE_SIZE || align > 1 << 39 {
		return .Err_Range
	}
	fixed := va^
	end, overflow := intrinsics.overflow_add(fixed, Uva(size))
	if .Fixed in flags && (u64(fixed) & (align - 1) != 0 || fixed == 0 || overflow || end > USER_TOP) {
		return .Err_Range
	}
	r: [16]Uva // the random bases to try, drawn before the lock
	slots := (u64(USER_TOP - USER_MAP_BASE) - size) / align + 1
	for &x in r {
		x = USER_MAP_BASE + Uva(resv_random_u64() % slots * align)
	}
	spin_guard(&t.lock)
	slot: ^Reservation
	for &x in t.resv {
		if x.size == 0 {
			slot = &x
			break
		}
	}
	at: Uva
	switch {
	case t.root == 0 || t.maps == nil || t.ending:
		return .Err_Bad_State
	case slot == nil:
		return .Err_No_Space
	case .Fixed in flags:
		if in_way := task_in_way(t, fixed, end); in_way != 0 {
			va^ = in_way
			return .Err_Exists
		}
		at = fixed
	case:
		for x in r {
			if task_in_way(t, x, x + Uva(size)) == 0 && !(x <= t.map_next && t.map_next < x + Uva(size)) {
				at = x
				break
			}
		}
		if at == 0 {
			return .Err_No_Memory // a crowded address space: sixteen draws all hit something
		}
	}
	slot^ = {va = at, size = size}
	va^ = at
	return .Ok
}

// Whether addr lies in a mapping of a revoked lease: its page fault is
// .Revoked (ADR-0021).
task_revoked_at :: proc "contextless" (t: ^Task, addr: u64) -> bool {
	spin_guard(&t.lock)
	if t.maps == nil {
		return false
	}
	for m in t.maps {
		if m.size != 0 && Uva(addr) >= m.va && Uva(addr) - m.va < Uva(m.size) {
			return vmo_revoked(m.vmo)
		}
	}
	return false
}

// The protection key of the mapping holding addr (0 if none): a
// .Protection_Key exception's.
task_key_at :: proc "contextless" (t: ^Task, addr: u64) -> u32 {
	spin_guard(&t.lock)
	if t.maps == nil {
		return 0
	}
	for m in t.maps {
		if m.size != 0 && Uva(addr) >= m.va && Uva(addr) - m.va < Uva(m.size) {
			return m.key
		}
	}
	return 0
}

// as_key_alloc and as_key_free (ADR-0035): the task's keys, 1 to arch_keys().
@(require_results)
task_key_alloc :: proc "contextless" (t: ^Task) -> (key: u32, st: vx.Status) {
	n := arch_keys()
	if n == 0 {
		return 0, .Err_Unsupported
	}
	spin_guard(&t.lock)
	for k in 1 ..= n {
		if int(k) not_in t.keys {
			t.keys += {int(k)}
			return k, .Ok
		}
	}
	return 0, .Err_No_Space
}

@(require_results)
task_key_free :: proc "contextless" (t: ^Task, key: u32) -> vx.Status {
	n := arch_keys()
	if n == 0 {
		return .Err_Unsupported
	}
	if key == 0 || key > n {
		return .Err_Invalid
	}
	spin_guard(&t.lock)
	if int(key) not_in t.keys {
		return .Err_Invalid // not its
	}
	if t.maps != nil {
		for m in t.maps {
			if m.size != 0 && m.key == key {
				return .Err_Bad_State // in use: a freed key never names a live mapping under its next owner
			}
		}
	}
	t.keys -= {int(key)}
	return .Ok
}

// A thread of task t that has not started (thread_start, process.odin).
@(require_results)
thread_create :: proc "contextless" (t: ^Task) -> (thread: ^Thread, st: vx.Status) {
	th := pool_alloc(&thread_pool)
	if th == nil {
		return nil, .Err_No_Memory
	}
	defer if st != .Ok {
		pool_free(&thread_pool, th)
	}
	stack := kstack_alloc()
	if stack == 0 {
		return nil, .Err_No_Memory
	}
	object_init(&th.obj, .Thread) // pool_alloc zeroed the rest
	th.task = t
	{
		spin_guard(&t.lock)
		t.thread_ids += 1
		th.id = t.thread_ids
	}
	th.kstack = stack
	th.intent = .Interactive
	th.rights = arch_rights_default() // a new task's first thread's; sys_thread_create gives one of its own task's its creator's
	object_ref(&t.obj)
	th.kernel_sp = arch_thread_initial_sp(th)
	return th, .Ok
}

thread_kstack_top :: proc "contextless" (th: ^Thread) -> u64 {
	return th.kstack + KSTACK_SIZE
}
