package kernel

import "base:intrinsics"
import vx "abi:vx"

// Tasks, threads, handles and address spaces.
//
// A task is an address space plus a handle table. Its user half is its own
// page tables; the kernel half is shared (arch_new_user_root).

USER_TOP :: u64(0x0000_8000_0000_0000) // first address past the lower half
USER_MAP_BASE :: u64(0x0000_1000_0000_0000) // where as_map puts mappings it places
USER_STACK_TOP :: u64(0x0000_7fff_ffff_0000)
USER_STACK_SIZE :: u64(256 * 1024)

// --- Handles ---
//
// A handle is a table index in the low 16 bits and that slot's generation in
// the high 16. The generation is bumped each time the slot is freed, so a
// stale handle fails with BAD_HANDLE instead of reaching a new object. Index
// 0 is never used, so no valid handle is 0. Slots are taken lowest first,
// which makes handle values deterministic. A table is one page: 255 handles.

Handle_Entry :: struct {
	obj:        ^Object,
	rights:     u32,
	generation: u16,
	reserved:   u16,
}

HANDLE_SLOTS :: 4096 / size_of(Handle_Entry)

// A mapping in a task's address space: [va, va + size) shows the VMO from
// `offset`. It holds a reference on the VMO.
Mapping :: struct {
	va, size, offset: u64,
	vmo:              ^Vmo,
}

TASK_MAX_MAPPINGS :: 4096 / size_of(Mapping)

// A task's lock covers its handle table, its address space, its threads and
// its life (state, exit status, bindings on its exit).
Task :: struct {
	using obj:       Object,
	lock:            Spinlock,
	id:              u64,
	root:            u64, // physical address of the address space's top table; 0 once torn down
	map_next:        u64, // the next address as_map places at
	handles:         [^]Handle_Entry, // HANDLE_SLOTS entries
	maps:            [^]Mapping, // TASK_MAX_MAPPINGS entries; size 0 is a free slot
	mapped:          u64, // bytes
	threads:         ^Thread, // started and not yet reaped, through task_next
	live_threads:    u32,
	state:           vx.Task_State, // .Exited once torn down
	ending:          bool, // its last thread has exited, or it was killed: torn down soon
	killed:          bool,
	exit_status:     i64,
	obs:             Observers, // EXIT bindings
	// The root task's debug capability, until there is a debug-log object; a
	// task gets it from the task that creates it.
	may_debug_write: bool,
	name:            [24]u8,
	parent_id:       u64, // the task that created it, or its nearest live creator; 0 for the root task
	all_next:        ^Task, // in all_tasks
}

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
	user_entry:   u64,
	user_sp:      u64,
	user_arg:     u64,
	user_arg2:    u64,
	intent:       vx.Intent,
	last_of_task: bool, // its exit ended its task (reaped in sched.odin)
	console_len:  int, // bytes of a debug_write line not yet ended,
	console_buf:  [160]u8, // which go out whole, at its newline
	state:        Thread_State,
	next:         ^Thread, // in the ready queue, or in a list of waiters (under that list's lock)
	sleep_next:   ^Thread, // in its CPU's sleep queue, ordered by wake_at
	sleep_cpu:    ^Cpu, // the CPU whose sleep queue holds it
	cpu:          ^Cpu, // the CPU it runs or last ran on
	wake_at:      Instant, // the deadline it sleeps until
	wake_late:    Instant, // wake_at plus its leeway: the timer may wait until here
	wait_token:   rawptr, // what it waits on, until it is woken or times out (sched.odin)
	wake_pending: bool, // woken between joining a list of waiters and blocking
	wait_result:  i64,
}

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
handle_add :: proc "contextless" (t: ^Task, obj: ^Object, rights: u32) -> (vx.Handle, vx.Status) {
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
handle_get :: proc "contextless" (t: ^Task, h: vx.Handle, type: Obj_Type, rights: u32) -> (^Object, vx.Status) {
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	e := entry_for(t, h)
	if e == nil || e.obj.type != type {
		return nil, .Err_Bad_Handle
	}
	if e.rights & rights != rights {
		return nil, .Err_Access
	}
	object_ref(e.obj)
	return e.obj, .Ok
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

// A handle in flight: the reference the sender's handle held, and its rights.
Moved_Handle :: struct {
	obj:    ^Object,
	rights: u32,
}

// Takes handles out of the task's table, all or none: each must exist, carry
// TRANSFER, appear once, and not be `forbidden` (a channel end cannot travel
// through itself). Their references move into out.
@(require_results)
handles_take :: proc "contextless" (t: ^Task, values: []vx.Handle, forbidden: ^Object, out: []Moved_Handle) -> vx.Status {
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	for v, i in values {
		e := entry_for(t, v)
		switch {
		case e == nil:
			return .Err_Bad_Handle
		case e.rights & vx.right_bit(.Transfer) == 0:
			return .Err_Access
		case e.obj == forbidden:
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

task_pool := Pool{size = (size_of(Task) + 15) &~ 15}
thread_pool := Pool{size = (size_of(Thread) + 15) &~ 15}

@(private="file")
next_task_id: u64 = 1

// Every live task, so a task's descendants can be found (task_find). When a
// task goes, its children pass to its parent, so the chain of creators from
// any task back to the root never breaks.
@(private="file")
all_tasks: ^Task
@(private="file")
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
	for link := &all_tasks; link^ != nil; link = &link^.all_next {
		if link^ == t {
			link^ = t.all_next
			break
		}
	}
	for c := all_tasks; c != nil; c = c.all_next {
		if c.parent_id == t.id {
			c.parent_id = t.parent_id
		}
	}
	spin_unlock(&all_tasks_lock)
}

@(require_results)
task_create :: proc "contextless" (name: string, parent_id: u64) -> (^Task, vx.Status) {
	t := cast(^Task)pool_alloc(&task_pool)
	if t == nil {
		return nil, .Err_No_Memory
	}
	handles := phys_alloc_zeroed(0)
	maps := handles != 0 ? phys_alloc_zeroed(0) : 0
	root := maps != 0 ? arch_new_user_root() : 0
	if root == 0 {
		if maps != 0 {
			phys_free(maps, 0)
		}
		if handles != 0 {
			phys_free(handles, 0)
		}
		pool_free(&task_pool, t)
		return nil, .Err_No_Memory
	}
	object_init(&t.obj, .Task) // pool_alloc zeroed the rest
	t.id = intrinsics.atomic_add_explicit(&next_task_id, 1, .Relaxed)
	t.root = root
	t.map_next = USER_MAP_BASE
	t.handles = cast([^]Handle_Entry)phys_to_virt(handles)
	t.maps = cast([^]Mapping)phys_to_virt(maps)
	copy(t.name[:len(t.name) - 1], name)
	t.parent_id = parent_id
	spin_lock(&all_tasks_lock)
	t.all_next = all_tasks
	all_tasks = t
	spin_unlock(&all_tasks_lock)
	return t, .Ok
}

task_name :: proc "contextless" (t: ^Task) -> string {
	n := 0
	for n < len(t.name) && t.name[n] != 0 {
		n += 1
	}
	return string(t.name[:n])
}

// Maps [offset, offset + size) of a VMO into a task's address space. With
// va == 0 the kernel picks the address; otherwise va is used and must be
// page-aligned and free. The mapping holds a reference on the VMO. W^X:
// never writable and executable.
@(require_results)
task_map :: proc "contextless" (t: ^Task, v: ^Vmo, offset, size: u64, flags: u32, want_va: u64) -> (u64, vx.Status) {
	if flags & vx.MAP_WRITE != 0 && flags & vx.MAP_EXEC != 0 {
		return 0, .Err_Access
	}
	vmo_end, overflow := intrinsics.overflow_add(offset, size)
	if size == 0 || (offset | size) & 4095 != 0 || overflow || vmo_end > v.size {
		return 0, .Err_Range
	}
	mf := Map_Flags{.User}
	if flags & vx.MAP_WRITE != 0 {
		mf += {.Write}
	}
	if flags & vx.MAP_EXEC != 0 {
		mf += {.Exec}
	}
	if v.physical {
		mf += {.Device}
	}
	spin_lock(&t.lock)
	defer spin_unlock(&t.lock)
	at := want_va != 0 ? want_va : t.map_next
	end, end_overflow := intrinsics.overflow_add(at, size)
	slot: ^Mapping
	for i in 0 ..< TASK_MAX_MAPPINGS {
		if t.maps != nil && t.maps[i].size == 0 {
			slot = &t.maps[i]
			break
		}
	}
	st := vx.Status.Ok
	switch {
	case t.root == 0 || t.ending:
		st = .Err_Bad_State
	case at & 4095 != 0 || end_overflow || end > USER_TOP:
		st = .Err_Range
	case slot == nil:
		st = .Err_No_Memory
	}
	done: u64
	for ; st == .Ok && done < size; done += 4096 {
		if !map_range(t.root, at + done, v.pages[(offset + done) / 4096], 4096, mf) {
			st = .Err_No_Memory
		}
	}
	if st != .Ok {
		for off := u64(0); off + 4096 <= done; off += 4096 {
			unmap_page(t.root, at + off)
		}
		return 0, st
	}
	object_ref(&v.obj)
	slot^ = {va = at, size = size, offset = offset, vmo = v}
	t.mapped += size
	if want_va == 0 {
		t.map_next = end + 4096 // leave a guard page between placed mappings
	}
	return at, .Ok
}

// A thread of task t that has not started (thread_start, process.odin).
@(require_results)
thread_create :: proc "contextless" (t: ^Task) -> (^Thread, vx.Status) {
	th := cast(^Thread)pool_alloc(&thread_pool)
	if th == nil {
		return nil, .Err_No_Memory
	}
	stack := kstack_alloc()
	if stack == 0 {
		pool_free(&thread_pool, th)
		return nil, .Err_No_Memory
	}
	object_init(&th.obj, .Thread) // pool_alloc zeroed the rest
	th.task = t
	th.kstack = stack
	th.intent = .Interactive
	object_ref(&t.obj)
	th.kernel_sp = arch_thread_initial_sp(th)
	return th, .Ok
}

thread_kstack_top :: proc "contextless" (th: ^Thread) -> u64 {
	return th.kstack + KSTACK_SIZE
}
