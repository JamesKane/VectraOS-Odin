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
@(private="file")
options_of :: proc "contextless" ($T: typeid, a: u64) -> (T, bool) where intrinsics.type_is_bit_set(T) {
	return transmute(T)u32(a), a &~ u64(transmute(u32)~T{}) == 0
}

// User pointers are checked against the current task's page tables before
// the kernel touches them. Mappings are only ever removed when a task ends,
// so nothing can unmap a range between the check and the copy; with as_unmap
// these become copies that recover from a fault.
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
	if !user_range_ok(src, length, false) {
		return .Err_Invalid
	}
	intrinsics.mem_copy(dst, rawptr(uintptr(src)), int(length))
	return .Ok
}

@(require_results)
copy_to_user :: proc "contextless" (dst: Uva, src: rawptr, length: u64) -> vx.Status {
	if !user_range_ok(dst, length, true) {
		return .Err_Invalid
	}
	intrinsics.mem_copy(rawptr(uintptr(dst)), src, int(length))
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
@(private="file", require_results)
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
		id          = t.id,
		state       = t.state,
		threads     = t.live_threads,
		exit_status = t.exit_status,
		mapped      = t.mapped,
		name        = t.name,
	}
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
		if woke == .Err_Timed_Out || woke == .Err_Killed {
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
// memory, or with {.Physical}, device memory minted from a Resource.
@(private="file", require_results)
sys_vmo_create :: proc "contextless" (size, options: u64, out: Uva, rh: vx.Handle, pa: Paddr) -> vx.Status {
	opts, valid := options_of(vx.Vmo_Options, options)
	if !valid {
		return .Err_Invalid
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

// --- Devices (device.odin) ---

@(private="file", require_results)
sys_irq_create :: proc "contextless" (rh: vx.Handle, line, options: u64, out: Uva) -> vx.Status {
	if options != 0 || line > u64(max(u32)) {
		return .Err_Invalid
	}
	r := handle_get_as(current_task(), rh, Resource, {.Manage}) or_return
	defer object_release(&r.obj)
	canonical := arch_irq_canonical(u32(line)) or_return
	q := irq_create(canonical) or_return
	return return_handle(&q.obj, vx.Rights{.Wait, .Write} + DEVICE_RIGHTS, out)
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
	va2, st := task_map(target, v, offset, size, opts, va)
	object_release(&v.obj)
	if st != .Ok {
		return st
	}
	return copy_out(addr_ptr, &va2)
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
@(private="file", require_results)
msg_from_user :: proc "contextless" (bytes: Uva, body_len: u32, handles: Uva, count: u32, forbidden: ^Object) -> (m: ^Channel_Msg, st: vx.Status) {
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
		st = handles_take(current_task(), values[:count], forbidden, msg_handles(msg))
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
	m := msg_from_user(bytes, u32(min(length, u64(max(u32)))), handles, u32(min(count, u64(max(u32)))), &c.obj) or_return
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
	request, st := msg_from_user(Uva(uintptr(args.wr_bytes)), args.wr_len, Uva(uintptr(args.wr_handles)), args.wr_count, &c.obj)
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
// channel end, counter, task, ring end or Irq to the port.
@(private="file", require_results)
sys_port_bind :: proc "contextless" (ph, sh: vx.Handle, trigger, key, threshold: u64) -> vx.Status {
	p := handle_get_as(current_task(), ph, Port, {.Write}) or_return
	defer object_release(&p.obj)
	if trigger < u64(min(vx.Trigger)) || trigger > u64(max(vx.Trigger)) {
		return .Err_Invalid
	}
	src: ^Object
	st: vx.Status
	for type in ([]Obj_Type{.Channel, .Counter, .Task, .Ring, .Irq}) {
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
		handles_take(current_task(), values[:count], &e.obj, moved[:count]) or_return
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
sys_task_create :: proc "contextless" (name_ptr: Uva, name_len: u64, out: Uva) -> vx.Status {
	name: [24]u8
	if name_len >= len(name) {
		return .Err_Range
	}
	copy_in_slice(name[:name_len], name_ptr) or_return
	t := task_create(string(name[:name_len]), current_task().id) or_return
	t.may_debug_write = current_task().may_debug_write
	return return_handle(&t.obj, vx.ALL_RIGHTS, out)
}

@(private="file", require_results)
sys_thread_create :: proc "contextless" (th: vx.Handle, out: Uva) -> vx.Status {
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
	return return_handle(&thr.obj, vx.ALL_RIGHTS, out)
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
		handles_take(current_task(), args[:], nil, m[:]) or_return
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

@(private="file", require_results)
sys_task_kill :: proc "contextless" (h: vx.Handle, status, id: u64) -> vx.Status {
	t := task_target(h, {.Manage}, id, false) or_return
	task_kill(t, i64(status))
	object_release(&t.obj)
	return .Ok
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
	// The user side is a checked range, not a kernel slice: copied as memory.
	for done := u64(0); done < size; {
		at := offset + done
		page := page_bytes(v.pages[at / PAGE_SIZE])[at % PAGE_SIZE:]
		n := min(u64(len(page)), size - done)
		user := rawptr(uintptr(buf + Uva(done)))
		if reading {
			intrinsics.mem_copy(user, raw_data(page), int(n))
		} else {
			intrinsics.mem_copy(raw_data(page), user, int(n))
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
		return i64(clock_now())
	case .Task_Create:
		return i64(sys_task_create(Uva(a[0]), a[1], Uva(a[2])))
	case .Task_Kill:
		return i64(sys_task_kill(vx.Handle(a[0]), a[1], a[2]))
	case .Task_Info:
		return i64(sys_task_info(vx.Handle(a[0]), Uva(a[1]), a[2], a[3]))
	case .Thread_Create:
		return i64(sys_thread_create(vx.Handle(a[0]), Uva(a[1])))
	case .Thread_Start:
		return i64(sys_thread_start(vx.Handle(a[0]), Uva(a[1]), Uva(a[2]), vx.Handle(a[3]), a[4]))
	case .Thread_Exit:
		thread_exit_current(i64(a[0]))
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
		return i64(sys_irq_create(vx.Handle(a[0]), a[1], a[2], Uva(a[3])))
	case .Irq_Ack:
		return i64(sys_irq_ack(vx.Handle(a[0])))
	case .Iorange_Create:
		return i64(sys_iorange_create(vx.Handle(a[0]), a[1], a[2], Uva(a[3])))
	case .Vmo_Rw:
		return i64(sys_vmo_rw(vx.Handle(a[0]), a[1], a[2], Uva(a[3]), a[4]))
	case .As_Map:
		return i64(sys_as_map(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], a[4], Uva(a[5])))
	case .Handle_Dup:
		return i64(sys_handle_dup(vx.Handle(a[0]), a[1], Uva(a[2])))
	case .Handle_Close:
		return i64(handle_close(current_task(), vx.Handle(a[0])))
	}
	return i64(vx.Status.Err_Unsupported)
}
