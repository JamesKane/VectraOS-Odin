package kernel

import "base:intrinsics"
import vx "abi:vx"

// The syscalls, and user memory access.
//
// Every syscall returns an i64: a count or value when >= 0, a Status when
// < 0. That encoding is made in syscall_dispatch alone; the sys_ procedures
// return a vx.Status, with the count or value beside it where there is one.
// The rest of abi/vx/syscalls.def answers .Err_Unsupported until the
// milestone that needs it.

current_task :: #force_inline proc "contextless" () -> ^Task {
	return this_cpu().current.task
}

// A syscall's options argument as its set, or false if it sets a bit that
// no option uses.
@(private)
options_of :: proc "contextless" ($T: typeid, a: u64) -> (T, bool) where intrinsics.type_is_bit_set(T) {
	return transmute(T)u32(a), a &~ u64(transmute(u32)~T{}) == 0
}

// User memory is touched only through these, assembly in each architecture's
// entry.S: a fault inside one resumes at its fault label (uaccess_fixup, from
// the trap handler), which reports the failure. So a range another thread
// unmaps between the check and the copy fails the copy, not the kernel.
foreign _ {
	vx_user_copy :: proc "c" (dst, src: rawptr, n: u64) -> u64 --- // the bytes not copied
	vx_user_copy_fault :: proc "c" () --- // an address only
	vx_user_load32 :: proc "c" (src: rawptr, dst: ^u32) -> bool ---
	vx_user_load32_fault :: proc "c" () --- // an address only
}

// Where a kernel fault on a user address at pc resumes, if pc is inside one
// of the user-access routines; 0 if it is not.
uaccess_fixup :: proc "contextless" (pc: u64) -> u64 {
	copy_at, copy_fault := u64(uintptr(rawptr(vx_user_copy))), u64(uintptr(rawptr(vx_user_copy_fault)))
	load_at, load_fault := u64(uintptr(rawptr(vx_user_load32))), u64(uintptr(rawptr(vx_user_load32_fault)))
	switch {
	case pc >= copy_at && pc < copy_fault:
		return copy_fault
	case pc >= load_at && pc < load_fault:
		return load_fault
	}
	return 0
}

// One aligned 32-bit word of user memory (a futex's), read whole through the
// task's own mapping; false if nothing maps it now.
@(require_results)
user_load32 :: proc "contextless" (src: Uva) -> (v: u32, ok: bool) {
	ok = vx_user_load32(rawptr(uintptr(src)), &v)
	return
}

// User pointers are checked against the current task's page tables before
// the kernel touches them, and then touched only through vx_user_copy.
user_range_ok :: proc "contextless" (addr: Uva, length: u64, write: bool) -> bool {
	if length == 0 {
		return true
	}
	end, overflow := intrinsics.overflow_add(addr, Uva(length))
	if overflow || end > USER_TOP {
		return false
	}
	for page := addr &~ (PAGE_SIZE - 1); page < end; page += PAGE_SIZE {
		if !user_page_ok(current_task().root, page, write) {
			return false
		}
	}
	return true
}

@(require_results)
copy_from_user :: proc "contextless" (dst: rawptr, src: Uva, length: u64) -> vx.Status {
	if !user_range_ok(src, length, false) || vx_user_copy(dst, rawptr(uintptr(src)), length) != 0 {
		return .Err_Invalid
	}
	return .Ok
}

@(require_results)
copy_to_user :: proc "contextless" (dst: Uva, src: rawptr, length: u64) -> vx.Status {
	if !user_range_ok(dst, length, true) || vx_user_copy(rawptr(uintptr(dst)), src, length) != 0 {
		return .Err_Invalid
	}
	return .Ok
}

// Typed copies, whose length comes from the type or the slice.
@(require_results)
copy_in :: proc "contextless" (dst: ^$T, src: Uva) -> vx.Status {
	return copy_from_user(dst, src, size_of(T))
}

@(require_results)
copy_out :: proc "contextless" (dst: Uva, src: ^$T) -> vx.Status {
	return copy_to_user(dst, src, size_of(T))
}

@(require_results)
copy_in_slice :: proc "contextless" (dst: []$T, src: Uva) -> vx.Status {
	return copy_from_user(raw_data(dst), src, u64(len(dst)) * size_of(T))
}

@(require_results)
copy_out_slice :: proc "contextless" (dst: Uva, src: []$T) -> vx.Status {
	return copy_to_user(dst, raw_data(src), u64(len(src)) * size_of(T))
}

// Writes a new handle's value to user memory, or closes the handle if it
// cannot.
@(private="file", require_results)
handle_out :: proc "contextless" (h: vx.Handle, out: Uva) -> vx.Status {
	value := h
	st := copy_out(out, &value)
	if st != .Ok {
		_ = handle_close(current_task(), h)
	}
	return st
}

// Gives the current task a handle to a new object, dropping the creator's reference.
@(private, require_results)
return_handle :: proc "contextless" (obj: ^Object, rights: vx.Rights, out: Uva) -> vx.Status {
	h, st := handle_add(current_task(), obj, rights)
	object_release(obj)
	if st != .Ok {
		return st
	}
	return handle_out(h, out)
}

@(private="file", require_results)
sys_debug_write :: proc "contextless" (ptr: Uva, length: u64) -> vx.Status {
	if !current_task().may_debug_write {
		return .Err_Access
	}
	buf: [256]u8
	p, left := ptr, length
	for left > 0 {
		n := min(left, len(buf))
		copy_in_slice(buf[:n], p) or_return
		self := this_cpu().current
		console_user_write(string(buf[:n]), &self.console_line)
		p += Uva(n)
		left -= n
	}
	return .Ok
}

// The task a task_info or task_kill acts on: the handle's, or with an id,
// that task in the handle's tree. With a reference.
@(private="file", require_results)
task_target :: proc "contextless" (h: vx.Handle, rights: vx.Rights, id: u64, next: bool) -> (target: ^Task, st: vx.Status) {
	t := handle_get_as(current_task(), h, Task, rights) or_return
	if id == 0 && !next {
		return t, .Ok
	}
	found := task_find(t.id, id, next)
	object_release(&t.obj)
	if found == nil {
		return nil, .Err_Not_Found
	}
	return found, .Ok
}

@(private="file", require_results)
sys_task_info :: proc "contextless" (h: vx.Handle, out: Uva, id, flags: u64) -> vx.Status {
	opts, valid := options_of(vx.Task_Info_Options, flags)
	if !valid {
		return .Err_Invalid
	}
	t := task_target(h, {.Inspect}, id, .Next in opts) or_return
	spin_lock(&t.lock)
	info := vx.Task_Summary {
		id       = t.id,
		state    = t.state,
		threads  = t.live_threads,
		mapped   = t.mapped,
		name     = t.name,
	}
	info.exit_len = u32(copy(info.exit[:], t.exit[:]))
	for th := t.threads; th != nil; th = th.task_next {
		if th.state == .Blocked {
			info.blocked += 1
		}
	}
	spin_unlock(&t.lock)
	object_release(&t.obj)
	return copy_out(out, &info)
}

@(private="file", require_results)
sys_port_create :: proc "contextless" (options: u64, out: Uva) -> vx.Status {
	if options != 0 {
		return .Err_Invalid
	}
	p := port_create() or_return
	return return_handle(&p.obj, vx.ALL_RIGHTS - {.Exec, .Map, .Debug}, out)
}

// Returns packets as soon as any are queued; otherwise joins the waiters and
// blocks. The reference handle_get took keeps the port alive through the
// wait, even if another thread closes the handle meanwhile.
@(private="file", require_results)
port_wait_on :: proc "contextless" (p: ^Port, deadline, leeway: Instant, out: Uva, max_packets: u64) -> (count: int, st: vx.Status) {
	for {
		got: [PORT_CAPACITY]vx.Packet
		n := port_take(p, got[:max_packets])
		if n > 0 {
			return n, copy_out_slice(out, got[:n])
		}
		if clock_now() >= deadline {
			return 0, .Err_Timed_Out
		}
		t := this_cpu().current
		if !port_join_waiters(p, t) {
			continue // a packet arrived meanwhile
		}
		woke := thread_block(deadline, leeway)
		if woke != .Ok { // its deadline, or a kill: still on the list, so off it
			port_remove_waiter(p, t)
			return 0, woke
		}
	}
}

@(private="file", require_results)
sys_port_wait :: proc "contextless" (h: vx.Handle, deadline, leeway: i64, out: Uva, max_packets: u64) -> (count: int, st: vx.Status) {
	if max_packets == 0 || max_packets > PORT_CAPACITY || leeway < 0 {
		return 0, .Err_Invalid
	}
	if !user_range_ok(out, max_packets * size_of(vx.Packet), true) {
		return 0, .Err_Invalid
	}
	p := handle_get_as(current_task(), h, Port, {.Wait}) or_return
	defer object_release(&p.obj)
	return port_wait_on(p, Instant(deadline), Instant(leeway), out, max_packets)
}

@(private="file", require_results)
sys_port_post :: proc "contextless" (h: vx.Handle, packet: Uva) -> vx.Status {
	pk: vx.Packet
	copy_in(&pk, packet) or_return
	p := handle_get_as(current_task(), h, Port, {.Signal}) or_return
	defer object_release(&p.obj)
	pk.timestamp = vx.Instant(clock_now())
	pk.source = 0
	pk.trigger = .User
	return port_post(p, pk)
}

// What device objects carry besides the rights to use them: they can be
// passed on, never widened.
@(private="file")
DEVICE_RIGHTS :: vx.Rights{.Duplicate, .Transfer, .Inspect}

// vmo_create(size, options, &out, resource, physical_address): anonymous
// memory, or with {.Physical}, device memory minted from a Resource, or with
// {.Pager} (the fourth argument a Pager, the fifth a key), memory a pager
// supplies.
@(private="file", require_results)
sys_vmo_create :: proc "contextless" (size, options: u64, out: Uva, rh: vx.Handle, pa: Paddr) -> vx.Status {
	opts, valid := options_of(vx.Vmo_Options, options)
	if !valid || opts == {.Physical, .Pager} {
		return .Err_Invalid
	}
	if .Pager in opts {
		if u64(pa) > u64(max(u32)) {
			return .Err_Invalid
		}
		g := handle_get_as(current_task(), rh, Pager, {.Write}) or_return
		v, st := vmo_create_pager(size, g, u32(pa))
		object_release(&g.obj)
		if st != .Ok {
			return st
		}
		return return_handle(&v.obj, vx.ALL_RIGHTS - {.Debug}, out)
	}
	if .Physical in opts {
		r := handle_get_as(current_task(), rh, Resource, {.Manage}) or_return
		pv, st := vmo_create_physical(pa, size)
		object_release(&r.obj)
		if st != .Ok {
			return st
		}
		return return_handle(&pv.obj, vx.Rights{.Read, .Write, .Map} + DEVICE_RIGHTS, out)
	}
	v := vmo_create(size) or_return
	// EXEC included: loaders and JITs map their own code. W^X holds per
	// mapping (task_map), never per VMO.
	return return_handle(&v.obj, vx.ALL_RIGHTS - {.Debug}, out)
}

// --- Pagers (pager.odin) ---

// pager_create(resource, port, key, deadline_ns, &out): needs a Resource
// handle with .Pager (what svcd gives a pager), or the root's.
@(private="file", require_results)
sys_pager_create :: proc "contextless" (rh, ph: vx.Handle, key, deadline: u64, out: Uva) -> vx.Status {
	r, st := handle_get_as(current_task(), rh, Resource, {.Pager})
	if r == nil {
		r = handle_get_as(current_task(), rh, Resource, {.Manage}) or_return
	}
	object_release(&r.obj)
	p := handle_get_as(current_task(), ph, Port, {.Signal}) or_return
	g: ^Pager
	g, st = pager_create(p, key, Instant(deadline))
	object_release(&p.obj)
	if st != .Ok {
		return st
	}
	return return_handle(&g.obj, {.Read, .Write, .Duplicate, .Transfer, .Inspect}, out)
}

// pager_supply(pager, vmo, offset, size, source, source_offset)
@(private="file", require_results)
sys_pager_supply :: proc "contextless" (gh, vh: vx.Handle, offset, size: u64, sh: vx.Handle, src_offset: u64) -> vx.Status {
	g := handle_get_as(current_task(), gh, Pager, {.Write}) or_return
	defer object_release(&g.obj)
	v := handle_get_as(current_task(), vh, Vmo, {}) or_return
	defer object_release(&v.obj)
	src := handle_get_as(current_task(), sh, Vmo, {.Read}) or_return
	defer object_release(&src.obj)
	return pager_supply(g, v, offset, size, src, src_offset)
}

// pager_op(pager, vmo, op, offset, size, ranges): .Dirty answers how many
// ranges, .Idle 1 or 0; the rest, a status.
@(private="file", require_results)
sys_pager_op :: proc "contextless" (gh, vh: vx.Handle, op_word, offset, size: u64, out: Uva) -> (n: int, st: vx.Status) {
	if op_word < u64(min(vx.Pager_Op)) || op_word > u64(max(vx.Pager_Op)) || (offset | size) & (PAGE_SIZE - 1) != 0 {
		return 0, .Err_Invalid
	}
	op := vx.Pager_Op(op_word)
	if _, overflow := intrinsics.overflow_add(offset, size); overflow {
		return 0, .Err_Range
	}
	if op == .Dirty && !user_range_ok(out, vx.PAGER_RANGES * size_of(vx.Pager_Range), true) {
		return 0, .Err_Invalid
	}
	g := handle_get_as(current_task(), gh, Pager, {.Write}) or_return
	defer object_release(&g.obj)
	v := handle_get_as(current_task(), vh, Vmo, {}) or_return
	defer object_release(&v.obj)
	if v.pager != g {
		return 0, .Err_Invalid
	}
	first, count := offset / PAGE_SIZE, size / PAGE_SIZE
	switch op {
	case .Dirty:
		ranges: [dynamic; vx.PAGER_RANGES]vx.Pager_Range
		pager_dirty(v, offset, size, &ranges)
		copy_out_slice(out, ranges[:]) or_return
		return len(ranges), .Ok
	case .Resize: // the pager's alone: every mapping of the VMO shares its size
		if offset != 0 {
			return 0, .Err_Invalid
		}
		return 0, vmo_resize(v, size)
	case .Idle: // only the caller's handle, and this call's own reference
		return intrinsics.atomic_load(&v.refs) <= 2 ? 1 : 0, .Ok
	case .Clean:
		pager_clean(v, first, count)
	case .Evict:
		pager_evict(v, first, count)
	}
	return 0, .Ok
}

// vmo_op(vmo, op, arg): .Resize to arg bytes. A pager-backed VMO is its
// pager's to resize (pager_op .Resize): anyone it is shared with may write
// it, and a writer must not shrink it under the others.
@(private="file", require_results)
sys_vmo_op :: proc "contextless" (h: vx.Handle, op, arg: u64) -> vx.Status {
	if op != u64(vx.Vmo_Resize_Op.Resize) {
		return .Err_Invalid
	}
	v := handle_get_as(current_task(), h, Vmo, {.Write}) or_return
	defer object_release(&v.obj)
	if v.pager != nil {
		return .Err_Access
	}
	return vmo_resize(v, arg)
}

// system_power(resource, op): the machine off, with the root Resource's .Manage.
@(private="file", require_results)
sys_system_power :: proc "contextless" (rh: vx.Handle, op: u64) -> vx.Status {
	if op != u64(vx.Power_Op.Off) {
		return .Err_Invalid
	}
	r := handle_get_as(current_task(), rh, Resource, {.Manage}) or_return
	object_release(&r.obj)
	return arch_system_off()
}

// --- Devices (device.odin) ---

// irq_create(resource, line, options, &out, &msi): a line, or with {.Msi}
// an MSI for the PCI function `line` names, with what to program into it.
@(private="file", require_results)
sys_irq_create :: proc "contextless" (rh: vx.Handle, line, options: u64, out, msi_out: Uva) -> vx.Status {
	opts, valid := options_of(vx.Irq_Options, options)
	if !valid || line > u64(max(u32)) {
		return .Err_Invalid
	}
	r := handle_get_as(current_task(), rh, Resource, {.Manage}) or_return
	defer object_release(&r.obj)
	q: ^Irq
	if .Msi in opts {
		msi: vx.Msi
		q, msi = irq_create_msi(u32(line)) or_return
		if st := copy_out(msi_out, &msi); st != .Ok {
			object_release(&q.obj)
			return st
		}
	} else {
		canonical := arch_irq_canonical(u32(line)) or_return
		q = irq_create(canonical) or_return
	}
	return return_handle(&q.obj, vx.Rights{.Wait, .Write} + DEVICE_RIGHTS, out)
}

// dma_domain_create(resource, source, options, &out): the domain of the
// PCI function whose requester ID is source.
@(private="file", require_results)
sys_dma_domain_create :: proc "contextless" (rh: vx.Handle, source, options: u64, out: Uva) -> vx.Status {
	if options != 0 || source > 0xffff {
		return .Err_Invalid
	}
	r := handle_get_as(current_task(), rh, Resource, {.Manage}) or_return
	d, st := dma_domain_create(u32(source))
	object_release(&r.obj)
	if st != .Ok {
		return st
	}
	return return_handle(&d.obj, vx.Rights{.Map, .Manage, .Wait} + DEVICE_RIGHTS, out)
}

// dma_map(domain, vmo, offset, size, options, &mapped): what the device may
// do is what the VMO handle allows (.Read to read it, .Write to write it).
@(private="file", require_results)
sys_dma_map :: proc "contextless" (dh, vh: vx.Handle, offset, size, options: u64, out: Uva) -> vx.Status {
	MAX_PAGES :: 512
	req: vx.Dma_Mapped
	copy_in(&req, out) or_return
	list := Uva(uintptr(req.addresses))
	opts, valid := options_of(vx.Dma_Options, options)
	pages := size / PAGE_SIZE
	if !valid || opts == {} || pages > MAX_PAGES || !user_range_ok(list, pages * size_of(u64), true) {
		return .Err_Invalid
	}
	d := handle_get_as(current_task(), dh, Dma_Domain, {.Map}) or_return
	defer object_release(&d.obj)
	need: vx.Rights
	if .Read in opts {
		need += {.Read}
	}
	if .Write in opts {
		need += {.Write}
	}
	v := handle_get_as(current_task(), vh, Vmo, need) or_return
	defer object_release(&v.obj)
	if v.pager != nil {
		return .Err_Unsupported // its pages come and go: no device may hold them
	}
	addresses: [MAX_PAGES]u64
	m := dma_map(d, v, offset, size, opts, addresses[:pages]) or_return
	if st := copy_out_slice(list, addresses[:pages]); st != .Ok { // never handed out: the device was never told of it
		_ = dma_unmap(m)
		object_release(&m.obj)
		return st
	}
	return return_handle(&m.obj, {.Inspect}, out + Uva(offset_of(vx.Dma_Mapped, mapping))) // the handle's now, or gone with it
}

@(private="file", require_results)
sys_dma_unmap :: proc "contextless" (mh: vx.Handle) -> vx.Status {
	m := handle_get_as(current_task(), mh, Dma_Mapping, {}) or_return
	defer object_release(&m.obj)
	return dma_unmap(m)
}

// dma_domain_op(domain, op, 0): .Revoke and .Quiesced are the owner's
// (.Manage); .Faults, .Inspect's, answers the count.
@(private="file", require_results)
sys_dma_domain_op :: proc "contextless" (dh: vx.Handle, op_word, arg: u64) -> (faults: u64, st: vx.Status) {
	if arg != 0 || op_word < u64(min(vx.Dma_Op)) || op_word > u64(max(vx.Dma_Op)) {
		return 0, .Err_Invalid
	}
	op := vx.Dma_Op(op_word)
	d := handle_get_as(current_task(), dh, Dma_Domain, op == .Faults ? {.Inspect} : {.Manage}) or_return
	defer object_release(&d.obj)
	switch op {
	case .Revoke:
		dma_revoke(d)
	case .Quiesced:
		dma_quiesced(d)
	case .Faults:
		spin_guard(&d.lock)
		return min(d.faults, u64(max(i64))), .Ok
	}
	return 0, .Ok
}

@(private="file", require_results)
sys_irq_ack :: proc "contextless" (h: vx.Handle) -> vx.Status {
	q := handle_get_as(current_task(), h, Irq, {.Write}) or_return
	defer object_release(&q.obj)
	irq_ack(q)
	return .Ok
}

@(private="file", require_results)
sys_iorange_create :: proc "contextless" (rh: vx.Handle, base, count: u64, out: Uva) -> vx.Status {
	r := handle_get_as(current_task(), rh, Resource, {.Manage}) or_return
	io, st := iorange_create(base, count)
	object_release(&r.obj)
	if st != .Ok {
		return st
	}
	return return_handle(&io.obj, vx.Rights{.Map} + DEVICE_RIGHTS, out)
}

// as_map(task, vmo, offset, size, flags, &address): maps part of a VMO. With
// an IoRange in place of the VMO (and the rest 0), it lets the task use those
// I/O ports instead.
@(private="file", require_results)
sys_as_map :: proc "contextless" (th, vh: vx.Handle, offset, size, flags: u64, addr_ptr: Uva) -> vx.Status {
	if io, _ := handle_get_as(current_task(), vh, Iorange, {.Map}); io != nil {
		defer object_release(&io.obj)
		if offset | size | flags != 0 {
			return .Err_Invalid
		}
		target := handle_get_as(current_task(), th, Task, {.Manage}) or_return
		defer object_release(&target.obj)
		return task_enable_io(target, io)
	}
	opts, valid := options_of(vx.Map_Options, flags)
	if !valid {
		return .Err_Invalid
	}
	va: Uva
	copy_in(&va, addr_ptr) or_return
	target := handle_get_as(current_task(), th, Task, {.Manage}) or_return
	defer object_release(&target.obj)
	need := vx.Rights{.Map, .Read}
	if .Write in opts {
		need += {.Write}
	}
	if .Exec in opts {
		need += {.Exec}
	}
	v := handle_get_as(current_task(), vh, Vmo, need) or_return
	at, st := task_map(target, v, offset, size, opts, va)
	object_release(&v.obj)
	if st != .Ok {
		return st
	}
	return copy_out(addr_ptr, &at)
}

// as_unmap(task, address, size): the pages of a range, mapped or not.
@(private="file", require_results)
sys_as_unmap :: proc "contextless" (th: vx.Handle, va: Uva, size: u64) -> vx.Status {
	t := handle_get_as(current_task(), th, Task, {.Manage}) or_return
	defer object_release(&t.obj)
	return task_unmap(t, va, size)
}

// --- Channels ---

@(private="file", require_results)
sys_channel_create :: proc "contextless" (options: u64, out: Uva) -> vx.Status {
	if options != 0 {
		return .Err_Invalid
	}
	if !user_range_ok(out, 2 * size_of(vx.Handle), true) {
		return .Err_Invalid
	}
	a, b := channel_create() or_return
	h: [2]vx.Handle
	st: vx.Status
	h[0], st = handle_add(current_task(), &a.obj, CHANNEL_END_RIGHTS)
	if st == .Ok {
		h[1], st = handle_add(current_task(), &b.obj, CHANNEL_END_RIGHTS)
		if st != .Ok {
			_ = handle_close(current_task(), h[0])
		}
	}
	object_release(&a.obj)
	object_release(&b.obj)
	if st != .Ok {
		return st
	}
	return copy_out(out, &h)
}

// Builds a message from user memory: the body copied in, the handles moved
// out of the caller's table (gone whatever happens next, as with every write).
// `through` is the channel end written to: neither it nor its peer may travel
// in the message.
@(private="file", require_results)
msg_from_user :: proc "contextless" (bytes: Uva, body_len: u32, handles: Uva, count: u32, through: ^Channel) -> (m: ^Channel_Msg, st: vx.Status) {
	if body_len < size_of(vx.Msg_Header) || body_len > vx.CHANNEL_MAX_BYTES || count > vx.CHANNEL_MAX_HANDLES {
		return nil, .Err_Invalid
	}
	values: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	copy_in_slice(values[:count], handles) or_return
	msg := msg_alloc(body_len, count)
	if msg == nil {
		return nil, .Err_No_Memory
	}
	st = copy_in_slice(msg_body(msg), bytes)
	if st == .Ok {
		// The peer's address is only compared, never followed: no lock is needed for that.
		peer := through.pair.ends[peer_side(through.side)]
		st = handles_take(current_task(), values[:count], &through.obj, cast(^Object)peer, msg_handles(msg))
	}
	if st != .Ok {
		msg.count = 0 // nothing was moved
		msg_free(msg)
		return nil, st
	}
	return msg, .Ok
}

// Gives the caller a message: the body copied out, the handles installed.
// The caller has checked the user ranges. The message is freed either way.
@(private="file", require_results)
msg_to_user :: proc "contextless" (m: ^Channel_Msg, bytes, handles: Uva) -> vx.Status {
	values: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	st := copy_out_slice(bytes, msg_body(m))
	if st == .Ok {
		st = handles_put(current_task(), msg_handles(m), values[:m.count])
	}
	if st == .Ok {
		st = copy_out_slice(handles, values[:m.count])
	}
	msg_free(m) // drops the message's references; installed handles hold their own
	return st
}

@(private="file", require_results)
sys_channel_write :: proc "contextless" (h: vx.Handle, bytes: Uva, length: u64, handles: Uva, count: u64) -> vx.Status {
	c := handle_get_as(current_task(), h, Channel, {.Write}) or_return
	defer object_release(&c.obj)
	m := msg_from_user(bytes, u32(min(length, u64(max(u32)))), handles, u32(min(count, u64(max(u32)))), c) or_return
	st := channel_write(c, m)
	if st != .Ok {
		msg_free(m)
	}
	return st
}

@(private="file", require_results)
sys_channel_read :: proc "contextless" (h: vx.Handle, bytes: Uva, cap_bytes: u64, handles: Uva, count_cap: u64, actual: Uva) -> vx.Status {
	if cap_bytes > vx.CHANNEL_MAX_BYTES || count_cap > vx.CHANNEL_MAX_HANDLES {
		return .Err_Invalid
	}
	if !user_range_ok(bytes, cap_bytes, true) || !user_range_ok(handles, count_cap * size_of(vx.Handle), true) || !user_range_ok(actual, size_of(vx.Msg_Size), true) {
		return .Err_Invalid
	}
	c := handle_get_as(current_task(), h, Channel, {.Read}) or_return
	m, need, st := channel_read(c, u32(cap_bytes), u32(count_cap))
	object_release(&c.obj)
	if st == .Ok || st == .Err_Too_Small {
		_ = copy_out(actual, &need)
	}
	if st != .Ok {
		return st
	}
	return msg_to_user(m, bytes, handles)
}

@(private="file", require_results)
sys_channel_call :: proc "contextless" (h: vx.Handle, args_ptr: Uva, deadline: i64) -> vx.Status {
	args: vx.Call
	copy_in(&args, args_ptr) or_return
	if args.rd_cap > vx.CHANNEL_MAX_BYTES || args.rd_count_cap > vx.CHANNEL_MAX_HANDLES {
		return .Err_Invalid
	}
	rd_bytes, rd_handles := Uva(uintptr(args.rd_bytes)), Uva(uintptr(args.rd_handles))
	if !user_range_ok(rd_bytes, u64(args.rd_cap), true) || !user_range_ok(rd_handles, u64(args.rd_count_cap) * size_of(vx.Handle), true) {
		return .Err_Invalid
	}
	c := handle_get_as(current_task(), h, Channel, {.Read, .Write}) or_return
	request, st := msg_from_user(Uva(uintptr(args.wr_bytes)), args.wr_len, Uva(uintptr(args.wr_handles)), args.wr_count, c)
	reply: ^Channel_Msg
	if st == .Ok {
		sent: bool
		reply, sent, st = channel_call(c, request, Instant(deadline))
		if !sent {
			msg_free(request) // once sent, it is the channel's
		}
	}
	object_release(&c.obj)
	if st != .Ok {
		return st
	}
	args.actual = {reply.len, reply.count}
	_ = copy_out(args_ptr + Uva(offset_of(vx.Call, actual)), &args.actual)
	if reply.len > args.rd_cap || reply.count > args.rd_count_cap {
		msg_free(reply)
		return .Err_Too_Small
	}
	return msg_to_user(reply, rd_bytes, rd_handles)
}

// --- Counters, bindings, futexes ---

@(private="file", require_results)
sys_counter_create :: proc "contextless" (initial: u64, out: Uva) -> vx.Status {
	c := counter_create(initial) or_return
	return return_handle(&c.obj, {.Read, .Signal, .Wait, .Duplicate, .Transfer, .Inspect}, out)
}

@(private="file", require_results)
sys_counter_signal :: proc "contextless" (h: vx.Handle, value: u64) -> vx.Status {
	c := handle_get_as(current_task(), h, Counter, {.Signal}) or_return
	defer object_release(&c.obj)
	counter_signal(c, value)
	return .Ok
}

// counter_read on a counter, or on a ring end, whose doorbell it reads.
@(private="file", require_results)
sys_counter_read :: proc "contextless" (h: vx.Handle) -> (value: i64, st: vx.Status) {
	o: ^Object
	o, st = handle_get(current_task(), h, .Counter, {.Read})
	if o == nil {
		o, st = handle_get(current_task(), h, .Ring, {.Read})
	}
	if o == nil {
		return 0, st
	}
	defer object_release(o)
	c := o.type == .Counter ? cast(^Counter)o : (cast(^Ring_End)o).doorbell
	v := counter_read(c)
	if v > u64(max(i64)) {
		return 0, .Err_Range
	}
	return i64(v), .Ok
}

// port_bind(port, source, trigger, key, threshold): a one-shot binding of a
// channel end, counter, task, ring end, Irq or DmaDomain to the port.
@(private="file", require_results)
sys_port_bind :: proc "contextless" (ph, sh: vx.Handle, trigger, key, threshold: u64) -> vx.Status {
	p := handle_get_as(current_task(), ph, Port, {.Write}) or_return
	defer object_release(&p.obj)
	if trigger < u64(min(vx.Trigger)) || trigger > u64(max(vx.Trigger)) {
		return .Err_Invalid
	}
	src: ^Object
	st: vx.Status
	for type in ([]Obj_Type{.Channel, .Counter, .Task, .Ring, .Irq, .Dma_Domain}) {
		if src, st = handle_get(current_task(), sh, type, {.Wait}); src != nil {
			break
		}
	}
	if src == nil {
		return st
	}
	defer object_release(src)
	b := binding_new(p, vx.Trigger(trigger), key, threshold, sh)
	if b == nil {
		return .Err_No_Memory
	}
	#partial switch src.type {
	case .Channel:
		st = channel_bind(cast(^Channel)src, b)
	case .Counter:
		st = counter_bind(cast(^Counter)src, b)
	case .Ring:
		st = ring_bind(cast(^Ring_End)src, b)
	case .Irq:
		st = irq_bind(cast(^Irq)src, b)
	case .Dma_Domain:
		st = dma_bind(cast(^Dma_Domain)src, b)
	case:
		st = task_bind(cast(^Task)src, b)
	}
	if st != .Ok {
		binding_free(b)
	}
	return st
}

// --- Rings ---

@(private="file", require_results)
sys_ring_create :: proc "contextless" (params_ptr, out: Uva) -> vx.Status {
	MEMORY_RIGHTS :: vx.Rights{.Read, .Write, .Map, .Duplicate, .Transfer, .Inspect}
	p: vx.Ring_Params
	copy_in(&p, params_ptr) or_return
	if !user_range_ok(out, size_of(vx.Ring_Handles), true) {
		return .Err_Invalid
	}
	client, server, memory := ring_create(p) or_return
	h: vx.Ring_Handles
	st: vx.Status
	t := current_task()
	h.client, st = handle_add(t, &client.obj, CHANNEL_END_RIGHTS)
	if st == .Ok {
		h.server, st = handle_add(t, &server.obj, CHANNEL_END_RIGHTS)
	}
	if st == .Ok {
		h.memory, st = handle_add(t, &memory.obj, MEMORY_RIGHTS)
	}
	object_release(&client.obj)
	object_release(&server.obj)
	object_release(&memory.obj)
	if st == .Ok {
		st = copy_out(out, &h)
	}
	if st != .Ok {
		for v in ([]vx.Handle{h.client, h.server, h.memory}) {
			if v != 0 {
				_ = handle_close(t, v)
			}
		}
	}
	return st
}

@(private="file", require_results)
sys_ring_notify :: proc "contextless" (h: vx.Handle) -> vx.Status {
	e := handle_get_as(current_task(), h, Ring_End, {.Signal}) or_return
	defer object_release(&e.obj)
	return ring_notify(e)
}

// ring_xfer_handles(ring, PUT, handles, count, 0) -> slot;
// ring_xfer_handles(ring, TAKE, handles out, capacity, slot) -> count.
@(private="file", require_results)
sys_ring_xfer :: proc "contextless" (h: vx.Handle, op: u64, handles: Uva, count, slot: u64) -> (result: u32, st: vx.Status) {
	if op != u64(vx.Ring_Xfer.Put) && op != u64(vx.Ring_Xfer.Take) {
		return 0, .Err_Invalid
	}
	put := op == u64(vx.Ring_Xfer.Put)
	if count > vx.RING_SLOT_HANDLES || (put && count == 0) {
		return 0, .Err_Invalid
	}
	values: [vx.RING_SLOT_HANDLES]vx.Handle
	if put {
		copy_in_slice(values[:count], handles) or_return
	} else if !user_range_ok(handles, count * size_of(vx.Handle), true) {
		return 0, .Err_Invalid
	}
	e := handle_get_as(current_task(), h, Ring_End, {.Write}) or_return
	defer object_release(&e.obj)
	moved: [vx.RING_SLOT_HANDLES]Moved_Handle
	if put {
		peer := e.pair.ends[peer_side(e.side)] // compared only
		handles_take(current_task(), values[:count], &e.obj, cast(^Object)peer, moved[:count]) or_return
		put_slot, pst := ring_put(e, moved[:count])
		if pst != .Ok {
			for m in moved[:count] {
				object_release(m.obj) // gone, as with channel writes
			}
		}
		return put_slot, pst
	}
	n: u32
	n, st = ring_take(e, u32(min(slot, u64(max(u32)))), moved[:])
	if st == .Ok && u64(n) > count {
		st = .Err_Too_Small // nothing installed; the handles are lost
	}
	if st == .Ok {
		st = handles_put(current_task(), moved[:n], values[:n])
	}
	if st == .Ok {
		st = copy_out_slice(handles, values[:n])
	}
	for m in moved[:n] {
		object_release(m.obj)
	}
	return n, st
}

// --- Tasks and threads ---

@(private="file", require_results)
sys_task_create :: proc "contextless" (name_ptr: Uva, name_len: u64, out: Uva, options: u64) -> vx.Status {
	name: [24]u8
	if name_len >= len(name) {
		return .Err_Range
	}
	opts, valid := options_of(vx.Task_Options, options)
	if !valid {
		return .Err_Invalid
	}
	copy_in_slice(name[:name_len], name_ptr) or_return
	t := task_create(string(name[:name_len]), current_task().id) or_return
	t.may_debug_write = current_task().may_debug_write
	if .Fork in opts {
		if st := task_fork_copy(current_task(), t); st != .Ok {
			task_kill(t, "sys: no memory") // never started: torn down with its last reference
			object_release(&t.obj)
			return st
		}
	}
	return return_handle(&t.obj, vx.ALL_RIGHTS, out)
}

// thread_create(task, &out, &id): a thread, and (unless id is 0) its id in
// the task, which exceptions and thread_interrupt name it by.
@(private="file", require_results)
sys_thread_create :: proc "contextless" (th: vx.Handle, out, id_out: Uva) -> vx.Status {
	t := handle_get_as(current_task(), th, Task, {.Manage}) or_return
	spin_lock(&t.lock)
	ending := t.ending || t.killed
	spin_unlock(&t.lock)
	thr: ^Thread
	st := vx.Status.Err_Bad_State
	if !ending {
		thr, st = thread_create(t)
	}
	object_release(&t.obj)
	if st != .Ok {
		return st
	}
	id := thr.id
	return_handle(&thr.obj, vx.ALL_RIGHTS, out) or_return
	if id_out != 0 {
		return copy_out(id_out, &id)
	}
	return .Ok
}

// thread_start(thread, entry, sp, handle, arg2): the handle, unless 0, moves
// from the caller to the thread's task, and the thread gets its value there
// as its first argument.
@(private="file", require_results)
sys_thread_start :: proc "contextless" (h: vx.Handle, entry, sp: Uva, arg: vx.Handle, arg2: u64) -> vx.Status {
	th := handle_get_as(current_task(), h, Thread, {.Manage}) or_return
	defer object_release(&th.obj)
	moved: vx.Handle
	if arg != 0 {
		m: [1]Moved_Handle
		args := [1]vx.Handle{arg}
		handles_take(current_task(), args[:], nil, nil, m[:]) or_return
		out: [1]vx.Handle
		st := handles_put(th.task, m[:], out[:])
		object_release(m[0].obj)
		if st != .Ok {
			return st
		}
		moved = out[0]
	}
	st := thread_start(th, entry, sp, u64(moved), arg2)
	if st != .Ok && moved != 0 {
		_ = handle_close(th.task, moved)
	}
	return st
}

// task_kill(task, msg, len, id): ends it with msg as its exit string.
@(private="file", require_results)
sys_task_kill :: proc "contextless" (h: vx.Handle, msg_ptr: Uva, length, id: u64) -> vx.Status {
	if length > vx.ERRMAX {
		return .Err_Range
	}
	msg: [vx.ERRMAX]u8
	copy_in_slice(msg[:length], msg_ptr) or_return
	t := task_target(h, {.Manage}, id, false) or_return
	task_kill(t, string(msg[:length]))
	object_release(&t.obj)
	return .Ok
}

// Takes two tasks' locks in a fixed order, and gives them back.
@(private="file")
lock_pair :: proc "contextless" (a, b: ^Task) {
	first, second := uintptr(a) < uintptr(b) ? a : b, uintptr(a) < uintptr(b) ? b : a
	spin_lock(&first.lock)
	spin_lock(&second.lock)
}

@(private="file")
unlock_pair :: proc "contextless" (a, b: ^Task) {
	spin_unlock(&a.lock)
	spin_unlock(&b.lock)
}

// task_exec(scratch, bootstrap, entry, sp) (ADR-0012): the caller takes the
// address space of scratch, a task it built and never started, and goes on as
// the program in it, keeping its id, parent and EXIT bindings. Its handles
// are all closed but bootstrap, which a new thread gets as its first argument
// at entry, on sp; the calling thread ends. scratch, left with the old
// address space, ends with it. Only a task with one live thread may call it.
@(private="file", require_results)
sys_task_exec :: proc "contextless" (sh, bootstrap: vx.Handle, entry, sp: Uva) -> vx.Status {
	if entry >= USER_TOP || sp > USER_TOP {
		return .Err_Invalid
	}
	t := current_task()
	s := handle_get_as(t, sh, Task, {.Manage}) or_return
	th: ^Thread
	st := vx.Status.Err_Invalid
	if s != t {
		th, st = thread_create(t) // made first: a failure changes nothing
	}
	if st == .Ok {
		// Both are held so until the swap: a thread started meanwhile, in
		// either, would run on tables about to change hands, and then be freed.
		lock_pair(t, s)
		alone := t.live_threads == 1 && !t.ending && !t.killed && !t.execing
		fresh := s.state == .New && s.live_threads == 0 && !s.ending && !s.killed && s.root != 0 && !s.execing
		if alone && fresh {
			t.execing, s.execing = true, true
		} else {
			st = .Err_Bad_State
		}
		unlock_pair(t, s)
	}
	moved: [1]Moved_Handle
	if st == .Ok {
		values := [1]vx.Handle{bootstrap}
		st = handles_take(t, values[:], &t.obj, &s.obj, moved[:])
		if st != .Ok {
			lock_pair(t, s)
			t.execing, s.execing = false, false
			unlock_pair(t, s)
		}
	}
	if st != .Ok {
		if th != nil {
			object_release(&th.obj)
		}
		object_release(&s.obj)
		return st
	}

	// The address spaces change places, and the caller takes the new
	// program's name. Both locks: nothing else maps into either meanwhile.
	lock_pair(t, s)
	t.root, s.root = s.root, t.root
	t.map_next, s.map_next = s.map_next, t.map_next
	t.mapped, s.mapped = s.mapped, t.mapped
	t.maps, s.maps = s.maps, t.maps
	t.name = s.name
	t.exc_handler = 0 // the old program's in-task handler is not in the new one
	unlock_pair(t, s)
	// This CPU leaves the old tables now, before they go with s. No other
	// CPU has them loaded: the caller has no other thread, and without
	// ASIDs, loading tables drops every cached translation (ADR-0012).
	load_user_root(this_cpu(), t.root)

	// Every handle the old program held is closed: the new one starts with
	// only what its spawn message names.
	handles_close_all(t)
	value: [1]vx.Handle
	st = handles_put(t, moved[:], value[:])
	object_release(moved[0].obj)
	{
		spin_guard(&t.lock)
		t.execing = false // the new program's first thread may start now
	}
	task_kill(s, "") // never started: torn down at once, with the old address space
	object_release(&s.obj)
	if st == .Ok {
		st = thread_start(th, entry, sp, u64(value[0]), 0)
	}
	object_release(&th.obj) // a started thread holds its own reference
	if st != .Ok {
		task_exit_with("exec failed")
	}
	thread_exit_current() // the new program goes on in the new thread
}

// clock_read(&info): the clock's counter, for /sys/clock/info; with no
// argument, the time (syscall_dispatch).
@(private="file", require_results)
sys_clock_info :: proc "contextless" (out: Uva) -> (now: Instant, st: vx.Status) {
	info := vx.Clock_Info{counter_hz = clock.hz, flags = arch_counter_flags()}
	copy_out(out, &info) or_return
	return clock_now(), .Ok
}

// --- Memory and handles ---

// vmo_rw(vmo, op, offset, buffer, size): copies between a VMO and the
// caller's memory.
@(private="file", require_results)
sys_vmo_rw :: proc "contextless" (h: vx.Handle, op, offset: u64, buf: Uva, size: u64) -> vx.Status {
	if op != u64(vx.Vmo_Op.Read) && op != u64(vx.Vmo_Op.Write) {
		return .Err_Invalid
	}
	reading := op == u64(vx.Vmo_Op.Read)
	if !user_range_ok(buf, size, reading) {
		return .Err_Invalid
	}
	v := handle_get_as(current_task(), h, Vmo, reading ? vx.Rights{.Read} : vx.Rights{.Write}) or_return
	defer object_release(&v.obj)
	end, overflow := intrinsics.overflow_add(offset, size)
	if v.physical {
		return .Err_Unsupported // device memory is not in the direct map: map it instead
	}
	if overflow || end > v.size {
		return .Err_Range
	}
	if v.pager != nil {
		return pager_vmo_rw(v, reading, offset, buf, size)
	}
	// Through the fault-safe copies: another thread may unmap the buffer meanwhile.
	for done := u64(0); done < size; {
		at := offset + done
		page := page_bytes(vmo_page(v, at / PAGE_SIZE))[at % PAGE_SIZE:]
		n := min(u64(len(page)), size - done)
		user := buf + Uva(done)
		if reading {
			copy_to_user(user, raw_data(page), n) or_return
		} else {
			copy_from_user(raw_data(page), user, n) or_return
		}
		done += n
	}
	return .Ok
}

// vmo_rw on a pager-backed VMO: its pages can go (.Evict, a shrink), so each
// is touched under its lock, through a bounce buffer. A page not supplied is
// .Err_Should_Wait; a write dirties a page as a store through a mapping would.
@(private="file", require_results)
pager_vmo_rw :: proc "contextless" (v: ^Vmo, reading: bool, offset: u64, buf: Uva, size: u64) -> vx.Status {
	for done := u64(0); done < size; {
		at := offset + done
		bounce: [256]u8
		n := min(PAGE_SIZE - at % PAGE_SIZE, size - done, len(bounce))
		user := buf + Uva(done)
		if !reading {
			copy_from_user(&bounce, user, n) or_return
		}
		pa: Paddr
		{
			spin_guard(&v.lock)
			if at / PAGE_SIZE < v.size / PAGE_SIZE {
				pa = vmo_page(v, at / PAGE_SIZE)
			}
			if pa != 0 {
				page := page_bytes(pa)[at % PAGE_SIZE:][:n]
				if reading {
					copy(bounce[:n], page)
				} else {
					copy(page, bounce[:n])
					v.pages[at / PAGE_SIZE].dirty = true
				}
			}
		}
		if pa == 0 {
			return .Err_Should_Wait // a pager has not supplied it
		}
		if reading {
			copy_to_user(user, &bounce, n) or_return
		}
		done += n
	}
	return .Ok
}

@(private="file", require_results)
sys_handle_dup :: proc "contextless" (h: vx.Handle, rights: u64, out: Uva) -> vx.Status {
	want: Maybe(vx.Rights) // nil: RIGHTS_SAME
	if rights != u64(transmute(u32)vx.RIGHTS_SAME) {
		// Bits above the u32 are rights no handle has, as bit 31 is: either
		// fails handle_dup's subset check.
		want = transmute(vx.Rights)u32(rights <= u64(max(u32)) ? rights : u64(transmute(u32)vx.RIGHTS_SAME))
	}
	dup := handle_dup(current_task(), h, want) or_return
	return handle_out(dup, out)
}

// The syscall ABI's one encoding of a result: a count or value when the
// status is .Ok, else the status, which is negative.
@(private="file")
result :: #force_inline proc "contextless" (n: $N, st: vx.Status) -> i64 where intrinsics.type_is_integer(N) {
	return st == .Ok ? i64(n) : i64(st)
}

syscall_dispatch :: proc "contextless" (nr: u64, a: [6]u64) -> i64 {
	if nr >= vx.SYSCALL_COUNT {
		return i64(vx.Status.Err_Unsupported)
	}
	#partial switch vx.Syscall(nr) {
	case .Debug_Write:
		return i64(sys_debug_write(Uva(a[0]), a[1]))
	case .Clock_Read:
		if a[0] != 0 {
			return result(sys_clock_info(Uva(a[0])))
		}
		return i64(clock_now())
	case .Task_Create:
		return i64(sys_task_create(Uva(a[0]), a[1], Uva(a[2]), a[3]))
	case .Task_Kill:
		return i64(sys_task_kill(vx.Handle(a[0]), Uva(a[1]), a[2], a[3]))
	case .Task_Exec:
		return i64(sys_task_exec(vx.Handle(a[0]), vx.Handle(a[1]), Uva(a[2]), Uva(a[3])))
	case .Task_Info:
		return i64(sys_task_info(vx.Handle(a[0]), Uva(a[1]), a[2], a[3]))
	case .Thread_Create:
		return i64(sys_thread_create(vx.Handle(a[0]), Uva(a[1]), Uva(a[2])))
	case .Thread_Start:
		return i64(sys_thread_start(vx.Handle(a[0]), Uva(a[1]), Uva(a[2]), vx.Handle(a[3]), a[4]))
	case .Thread_Exit:
		thread_exit_current()
	case .Port_Create:
		return i64(sys_port_create(a[0], Uva(a[1])))
	case .Port_Bind:
		return i64(sys_port_bind(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], a[4]))
	case .Port_Wait:
		return result(sys_port_wait(vx.Handle(a[0]), i64(a[1]), i64(a[2]), Uva(a[3]), a[4]))
	case .Port_Post:
		return i64(sys_port_post(vx.Handle(a[0]), Uva(a[1])))
	case .Counter_Create:
		return i64(sys_counter_create(a[0], Uva(a[1])))
	case .Counter_Signal:
		return i64(sys_counter_signal(vx.Handle(a[0]), a[1]))
	case .Counter_Read:
		return result(sys_counter_read(vx.Handle(a[0])))
	case .Futex_Wait:
		return i64(futex_wait(Uva(a[0]), u32(a[1]), Instant(a[2])))
	case .Futex_Wake:
		return result(futex_wake(Uva(a[0]), u32(a[1])))
	case .Channel_Create:
		return i64(sys_channel_create(a[0], Uva(a[1])))
	case .Channel_Write:
		return i64(sys_channel_write(vx.Handle(a[0]), Uva(a[1]), a[2], Uva(a[3]), a[4]))
	case .Channel_Read:
		return i64(sys_channel_read(vx.Handle(a[0]), Uva(a[1]), a[2], Uva(a[3]), a[4], Uva(a[5])))
	case .Channel_Call:
		return i64(sys_channel_call(vx.Handle(a[0]), Uva(a[1]), i64(a[2])))
	case .Ring_Create:
		return i64(sys_ring_create(Uva(a[0]), Uva(a[1])))
	case .Ring_Notify:
		return i64(sys_ring_notify(vx.Handle(a[0])))
	case .Ring_Xfer_Handles:
		return result(sys_ring_xfer(vx.Handle(a[0]), a[1], Uva(a[2]), a[3], a[4]))
	case .Vmo_Create:
		return i64(sys_vmo_create(a[0], a[1], Uva(a[2]), vx.Handle(a[3]), Paddr(a[4])))
	case .Irq_Create:
		return i64(sys_irq_create(vx.Handle(a[0]), a[1], a[2], Uva(a[3]), Uva(a[4])))
	case .Irq_Ack:
		return i64(sys_irq_ack(vx.Handle(a[0])))
	case .Dma_Domain_Create:
		return i64(sys_dma_domain_create(vx.Handle(a[0]), a[1], a[2], Uva(a[3])))
	case .Dma_Map:
		return i64(sys_dma_map(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], a[4], Uva(a[5])))
	case .Dma_Unmap:
		return i64(sys_dma_unmap(vx.Handle(a[0])))
	case .Dma_Domain_Op:
		return result(sys_dma_domain_op(vx.Handle(a[0]), a[1], a[2]))
	case .Pager_Create:
		return i64(sys_pager_create(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], Uva(a[4])))
	case .Pager_Supply:
		return i64(sys_pager_supply(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], vx.Handle(a[4]), a[5]))
	case .Pager_Op:
		return result(sys_pager_op(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], a[4], Uva(a[5])))
	case .Vmo_Op:
		return i64(sys_vmo_op(vx.Handle(a[0]), a[1], a[2]))
	case .System_Power:
		return i64(sys_system_power(vx.Handle(a[0]), a[1]))
	case .Iorange_Create:
		return i64(sys_iorange_create(vx.Handle(a[0]), a[1], a[2], Uva(a[3])))
	case .Vmo_Rw:
		return i64(sys_vmo_rw(vx.Handle(a[0]), a[1], a[2], Uva(a[3]), a[4]))
	case .As_Map:
		return i64(sys_as_map(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], a[4], Uva(a[5])))
	case .As_Query:
		return i64(sys_as_query(vx.Handle(a[0]), Uva(a[1]), Uva(a[2])))
	case .Exception_Bind:
		return i64(sys_exception_bind(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3]))
	case .Exception_Resume:
		return result(sys_exception_resume(vx.Handle(a[0]), a[1], a[2], Uva(a[3])))
	case .Thread_State:
		return i64(sys_thread_state(vx.Handle(a[0]), a[1], a[2], Uva(a[3]), a[4]))
	case .Thread_Interrupt:
		return i64(sys_thread_interrupt(vx.Handle(a[0]), a[1], Uva(a[2]), a[3]))
	case .Thread_Suspend:
		return i64(sys_thread_suspend(vx.Handle(a[0]), a[1], false))
	case .Thread_Resume:
		return i64(sys_thread_suspend(vx.Handle(a[0]), a[1], true))
	case .Task_Mem_Rw:
		return i64(sys_task_mem_rw(vx.Handle(a[0]), Uva(a[1]), a[2]))
	case .Vmo_Clone:
		return i64(sys_vmo_clone(vx.Handle(a[0]), a[1], a[2], a[3], Uva(a[4])))
	case .As_Unmap:
		return i64(sys_as_unmap(vx.Handle(a[0]), Uva(a[1]), a[2]))
	case .Handle_Dup:
		return i64(sys_handle_dup(vx.Handle(a[0]), a[1], Uva(a[2])))
	case .Handle_Close:
		return i64(handle_close(current_task(), vx.Handle(a[0])))
	}
	return i64(vx.Status.Err_Unsupported)
}
