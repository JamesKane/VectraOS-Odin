package kernel

import "base:intrinsics"
import vx "abi:vx"

// The syscalls, and user memory access.
//
// Every syscall returns an i64: a count or value when >= 0, a Status when
// < 0. The rest of abi/vx/syscalls.def answers .Err_Unsupported until the
// milestone that needs it.

current_task :: #force_inline proc "contextless" () -> ^Task {
	return this_cpu().current.task
}

@(private="file")
err :: #force_inline proc "contextless" (st: vx.Status) -> i64 {
	return i64(st)
}

@(private="file")
bit :: #force_inline proc "contextless" (r: vx.Right) -> u32 {
	return vx.right_bit(r)
}

// User pointers are checked against the current task's page tables before
// the kernel touches them. Mappings are only ever removed when a task ends,
// so nothing can unmap a range between the check and the copy; with as_unmap
// these become copies that recover from a fault.
user_range_ok :: proc "contextless" (addr, length: u64, write: bool) -> bool {
	if length == 0 {
		return true
	}
	end, overflow := intrinsics.overflow_add(addr, length)
	if overflow || end > USER_TOP {
		return false
	}
	for page := addr &~ 4095; page < end; page += 4096 {
		if !user_page_ok(current_task().root, page, write) {
			return false
		}
	}
	return true
}

@(require_results)
copy_from_user :: proc "contextless" (dst: rawptr, src: u64, length: u64) -> vx.Status {
	if !user_range_ok(src, length, false) {
		return .Err_Invalid
	}
	intrinsics.mem_copy(dst, rawptr(uintptr(src)), int(length))
	return .Ok
}

@(require_results)
copy_to_user :: proc "contextless" (dst: u64, src: rawptr, length: u64) -> vx.Status {
	if !user_range_ok(dst, length, true) {
		return .Err_Invalid
	}
	intrinsics.mem_copy(rawptr(uintptr(dst)), src, int(length))
	return .Ok
}

// Gives the current task a handle to a new object, dropping the creator's reference.
@(private="file")
return_handle :: proc "contextless" (obj: ^Object, rights: u32, out: u64) -> i64 {
	h, st := handle_add(current_task(), obj, rights)
	object_release(obj)
	if st != .Ok {
		return err(st)
	}
	st = copy_to_user(out, &h, size_of(h))
	if st != .Ok {
		_ = handle_close(current_task(), h)
	}
	return err(st)
}

@(private="file")
sys_debug_write :: proc "contextless" (ptr, length: u64) -> i64 {
	if !current_task().may_debug_write {
		return err(.Err_Access)
	}
	buf: [256]u8
	p, left := ptr, length
	for left > 0 {
		n := min(left, len(buf))
		if st := copy_from_user(&buf, p, n); st != .Ok {
			return err(st)
		}
		self := this_cpu().current
		console_user_write(string(buf[:n]), self.console_buf[:], &self.console_len)
		p += n
		left -= n
	}
	return 0
}

// The task a task_info or task_kill acts on: the handle's, or with an id,
// that task in the handle's tree. With a reference.
@(private="file")
task_target :: proc "contextless" (h: vx.Handle, rights: u32, id: u64, next: bool) -> (^Task, vx.Status) {
	o, st := handle_get(current_task(), h, .Task, rights)
	if o == nil {
		return nil, st
	}
	t := cast(^Task)o
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

@(private="file")
sys_task_info :: proc "contextless" (h: vx.Handle, out, id, flags: u64) -> i64 {
	if flags &~ u64(vx.TASK_NEXT) != 0 {
		return err(.Err_Invalid)
	}
	t, st := task_target(h, bit(.Inspect), id, flags & u64(vx.TASK_NEXT) != 0)
	if t == nil {
		return err(st)
	}
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
	return err(copy_to_user(out, &info, size_of(info)))
}

@(private="file")
sys_port_create :: proc "contextless" (options, out: u64) -> i64 {
	if options != 0 {
		return err(.Err_Invalid)
	}
	p, st := port_create()
	if st != .Ok {
		return err(st)
	}
	return return_handle(&p.obj, ALL_RIGHTS &~ (bit(.Exec) | bit(.Map) | bit(.Debug)), out)
}

// Returns packets as soon as any are queued; otherwise joins the waiters and
// blocks. The reference handle_get took keeps the port alive through the
// wait, even if another thread closes the handle meanwhile.
@(private="file")
port_wait_on :: proc "contextless" (p: ^Port, deadline, leeway: Instant, out, max: u64) -> i64 {
	for {
		got: [PORT_CAPACITY]vx.Packet
		n := port_take(p, got[:max])
		if n > 0 {
			st := copy_to_user(out, &got, u64(n) * size_of(vx.Packet))
			return st == .Ok ? i64(n) : err(st)
		}
		if clock_now() >= deadline {
			return err(.Err_Timed_Out)
		}
		t := this_cpu().current
		if !port_join_waiters(p, t) {
			continue // a packet arrived meanwhile
		}
		woke := thread_block(deadline, leeway)
		if woke == i64(vx.Status.Err_Timed_Out) || woke == i64(vx.Status.Err_Killed) {
			port_remove_waiter(p, t)
			return woke
		}
	}
}

@(private="file")
sys_port_wait :: proc "contextless" (h: vx.Handle, deadline, leeway: i64, out, max: u64) -> i64 {
	if max == 0 || max > PORT_CAPACITY || leeway < 0 {
		return err(.Err_Invalid)
	}
	if !user_range_ok(out, max * size_of(vx.Packet), true) {
		return err(.Err_Invalid)
	}
	o, st := handle_get(current_task(), h, .Port, bit(.Wait))
	if o == nil {
		return err(st)
	}
	result := port_wait_on(cast(^Port)o, Instant(deadline), Instant(leeway), out, max)
	object_release(o)
	return result
}

@(private="file")
sys_port_post :: proc "contextless" (h: vx.Handle, packet: u64) -> i64 {
	pk: vx.Packet
	if st := copy_from_user(&pk, packet, size_of(pk)); st != .Ok {
		return err(st)
	}
	o, st := handle_get(current_task(), h, .Port, bit(.Signal))
	if o == nil {
		return err(st)
	}
	pk.timestamp = vx.Instant(clock_now())
	pk.source = 0
	pk.trigger = .User
	st = port_post(cast(^Port)o, pk)
	object_release(o)
	return err(st)
}

// What device objects carry besides the rights to use them: they can be
// passed on, never widened.
@(private="file")
DEVICE_RIGHTS :: u32(1 << u32(vx.Right.Duplicate) | 1 << u32(vx.Right.Transfer) | 1 << u32(vx.Right.Inspect))

// vmo_create(size, options, &out, resource, physical_address): anonymous
// memory, or with VMO_PHYSICAL, device memory minted from a Resource.
@(private="file")
sys_vmo_create :: proc "contextless" (size, options, out: u64, rh: vx.Handle, pa: u64) -> i64 {
	if options &~ u64(vx.VMO_PHYSICAL) != 0 {
		return err(.Err_Invalid)
	}
	if options & u64(vx.VMO_PHYSICAL) != 0 {
		r, st := handle_get(current_task(), rh, .Resource, bit(.Manage))
		if r == nil {
			return err(st)
		}
		pv, pst := vmo_create_physical(pa, size)
		object_release(r)
		if pst != .Ok {
			return err(pst)
		}
		return return_handle(&pv.obj, bit(.Read) | bit(.Write) | bit(.Map) | DEVICE_RIGHTS, out)
	}
	v, st := vmo_create(size)
	if st != .Ok {
		return err(st)
	}
	// EXEC included: loaders and JITs map their own code. W^X holds per
	// mapping (task_map), never per VMO.
	return return_handle(&v.obj, ALL_RIGHTS &~ bit(.Debug), out)
}

// --- Devices (device.odin) ---

@(private="file")
sys_irq_create :: proc "contextless" (rh: vx.Handle, line, options, out: u64) -> i64 {
	if options != 0 || line > u64(max(u32)) {
		return err(.Err_Invalid)
	}
	r, st := handle_get(current_task(), rh, .Resource, bit(.Manage))
	if r == nil {
		return err(st)
	}
	defer object_release(r)
	canonical, cst := arch_irq_canonical(u32(line))
	if cst != .Ok {
		return err(cst)
	}
	q, qst := irq_create(canonical)
	if qst != .Ok {
		return err(qst)
	}
	return return_handle(&q.obj, bit(.Wait) | bit(.Write) | DEVICE_RIGHTS, out)
}

@(private="file")
sys_irq_ack :: proc "contextless" (h: vx.Handle) -> i64 {
	o, st := handle_get(current_task(), h, .Irq, bit(.Write))
	if o == nil {
		return err(st)
	}
	irq_ack(cast(^Irq)o)
	object_release(o)
	return 0
}

@(private="file")
sys_iorange_create :: proc "contextless" (rh: vx.Handle, base, count, out: u64) -> i64 {
	r, st := handle_get(current_task(), rh, .Resource, bit(.Manage))
	if r == nil {
		return err(st)
	}
	io, ist := iorange_create(base, count)
	object_release(r)
	if ist != .Ok {
		return err(ist)
	}
	return return_handle(&io.obj, bit(.Map) | DEVICE_RIGHTS, out)
}

// as_map(task, vmo, offset, size, flags, &address): maps part of a VMO. With
// an IoRange in place of the VMO (and the rest 0), it lets the task use those
// I/O ports instead.
@(private="file")
sys_as_map :: proc "contextless" (th, vh: vx.Handle, offset, size, flags, addr_ptr: u64) -> i64 {
	if io, _ := handle_get(current_task(), vh, .Iorange, bit(.Map)); io != nil {
		defer object_release(io)
		if offset | size | flags != 0 {
			return err(.Err_Invalid)
		}
		to, tst := handle_get(current_task(), th, .Task, bit(.Manage))
		if to == nil {
			return err(tst)
		}
		st := task_enable_io(cast(^Task)to, cast(^Iorange)io)
		object_release(to)
		return err(st)
	}
	if flags &~ u64(vx.MAP_WRITE | vx.MAP_EXEC) != 0 {
		return err(.Err_Invalid)
	}
	va: u64
	if st := copy_from_user(&va, addr_ptr, size_of(va)); st != .Ok {
		return err(st)
	}
	to, tst := handle_get(current_task(), th, .Task, bit(.Manage))
	if to == nil {
		return err(tst)
	}
	need := bit(.Map) | bit(.Read)
	if flags & u64(vx.MAP_WRITE) != 0 {
		need |= bit(.Write)
	}
	if flags & u64(vx.MAP_EXEC) != 0 {
		need |= bit(.Exec)
	}
	vo, st := handle_get(current_task(), vh, .Vmo, need)
	if vo != nil {
		va, st = task_map(cast(^Task)to, cast(^Vmo)vo, offset, size, u32(flags), va)
		object_release(vo)
	}
	object_release(to)
	if st != .Ok {
		return err(st)
	}
	return err(copy_to_user(addr_ptr, &va, size_of(va)))
}

// --- Channels ---

@(private="file")
sys_channel_create :: proc "contextless" (options, out: u64) -> i64 {
	if options != 0 {
		return err(.Err_Invalid)
	}
	if !user_range_ok(out, 2 * size_of(vx.Handle), true) {
		return err(.Err_Invalid)
	}
	a, b, st := channel_create()
	if st != .Ok {
		return err(st)
	}
	h: [2]vx.Handle
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
		return err(st)
	}
	return err(copy_to_user(out, &h, size_of(h)))
}

// Builds a message from user memory: the body copied in, the handles moved
// out of the caller's table (gone whatever happens next, as with every write).
@(private="file")
msg_from_user :: proc "contextless" (bytes: u64, length: u32, handles: u64, count: u32, forbidden: ^Object) -> (^Channel_Msg, vx.Status) {
	if length < size_of(vx.Msg_Header) || length > vx.CHANNEL_MAX_BYTES || count > vx.CHANNEL_MAX_HANDLES {
		return nil, .Err_Invalid
	}
	values: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	if st := copy_from_user(&values, handles, u64(count) * size_of(vx.Handle)); st != .Ok {
		return nil, st
	}
	m := msg_alloc(length, count)
	if m == nil {
		return nil, .Err_No_Memory
	}
	st := copy_from_user(raw_data(msg_body(m)), bytes, u64(length))
	if st == .Ok {
		st = handles_take(current_task(), values[:count], forbidden, msg_handles(m))
	}
	if st != .Ok {
		m.count = 0 // nothing was moved
		msg_free(m)
		return nil, st
	}
	return m, .Ok
}

// Gives the caller a message: the body copied out, the handles installed.
// The caller has checked the user ranges. The message is freed either way.
@(private="file")
msg_to_user :: proc "contextless" (m: ^Channel_Msg, bytes, handles: u64) -> vx.Status {
	values: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	body := msg_body(m)
	st := copy_to_user(bytes, raw_data(body), u64(len(body)))
	if st == .Ok {
		st = handles_put(current_task(), msg_handles(m), values[:m.count])
	}
	if st == .Ok {
		st = copy_to_user(handles, &values, u64(m.count) * size_of(vx.Handle))
	}
	msg_free(m) // drops the message's references; installed handles hold their own
	return st
}

@(private="file")
sys_channel_write :: proc "contextless" (h: vx.Handle, bytes, length, handles, count: u64) -> i64 {
	o, st := handle_get(current_task(), h, .Channel, bit(.Write))
	if o == nil {
		return err(st)
	}
	m: ^Channel_Msg
	m, st = msg_from_user(bytes, u32(min(length, u64(max(u32)))), handles, u32(min(count, u64(max(u32)))), o)
	if st == .Ok {
		st = channel_write(cast(^Channel)o, m)
		if st != .Ok {
			msg_free(m)
		}
	}
	object_release(o)
	return err(st)
}

@(private="file")
sys_channel_read :: proc "contextless" (h: vx.Handle, bytes, cap, handles, count_cap, actual: u64) -> i64 {
	if cap > vx.CHANNEL_MAX_BYTES || count_cap > vx.CHANNEL_MAX_HANDLES {
		return err(.Err_Invalid)
	}
	if !user_range_ok(bytes, cap, true) || !user_range_ok(handles, count_cap * size_of(vx.Handle), true) || !user_range_ok(actual, size_of(vx.Msg_Size), true) {
		return err(.Err_Invalid)
	}
	o, st := handle_get(current_task(), h, .Channel, bit(.Read))
	if o == nil {
		return err(st)
	}
	m, need, rst := channel_read(cast(^Channel)o, u32(cap), u32(count_cap))
	object_release(o)
	if rst == .Ok || rst == .Err_Too_Small {
		_ = copy_to_user(actual, &need, size_of(need))
	}
	if rst != .Ok {
		return err(rst)
	}
	return err(msg_to_user(m, bytes, handles))
}

@(private="file")
sys_channel_call :: proc "contextless" (h: vx.Handle, args_ptr: u64, deadline: i64) -> i64 {
	args: vx.Call
	if st := copy_from_user(&args, args_ptr, size_of(args)); st != .Ok {
		return err(st)
	}
	if args.rd_cap > vx.CHANNEL_MAX_BYTES || args.rd_count_cap > vx.CHANNEL_MAX_HANDLES {
		return err(.Err_Invalid)
	}
	rd_bytes, rd_handles := u64(uintptr(args.rd_bytes)), u64(uintptr(args.rd_handles))
	if !user_range_ok(rd_bytes, u64(args.rd_cap), true) || !user_range_ok(rd_handles, u64(args.rd_count_cap) * size_of(vx.Handle), true) {
		return err(.Err_Invalid)
	}
	o, st := handle_get(current_task(), h, .Channel, bit(.Read) | bit(.Write))
	if o == nil {
		return err(st)
	}
	request, reply: ^Channel_Msg
	request, st = msg_from_user(u64(uintptr(args.wr_bytes)), args.wr_len, u64(uintptr(args.wr_handles)), args.wr_count, o)
	if st == .Ok {
		sent: bool
		reply, sent, st = channel_call(cast(^Channel)o, request, Instant(deadline))
		if !sent {
			msg_free(request) // once sent, it is the channel's
		}
	}
	object_release(o)
	if st != .Ok {
		return err(st)
	}
	args.actual = {reply.len, reply.count}
	_ = copy_to_user(args_ptr + u64(offset_of(vx.Call, actual)), &args.actual, size_of(args.actual))
	if reply.len > args.rd_cap || reply.count > args.rd_count_cap {
		msg_free(reply)
		return err(.Err_Too_Small)
	}
	return err(msg_to_user(reply, rd_bytes, rd_handles))
}

// --- Counters, bindings, futexes ---

@(private="file")
sys_counter_create :: proc "contextless" (initial, out: u64) -> i64 {
	c, st := counter_create(initial)
	if st != .Ok {
		return err(st)
	}
	return return_handle(&c.obj, bit(.Read) | bit(.Signal) | bit(.Wait) | bit(.Duplicate) | bit(.Transfer) | bit(.Inspect), out)
}

@(private="file")
sys_counter_signal :: proc "contextless" (h: vx.Handle, value: u64) -> i64 {
	o, st := handle_get(current_task(), h, .Counter, bit(.Signal))
	if o == nil {
		return err(st)
	}
	counter_signal(cast(^Counter)o, value)
	object_release(o)
	return 0
}

// counter_read on a counter, or on a ring end, whose doorbell it reads.
@(private="file")
sys_counter_read :: proc "contextless" (h: vx.Handle) -> i64 {
	o, st := handle_get(current_task(), h, .Counter, bit(.Read))
	if o == nil {
		o, st = handle_get(current_task(), h, .Ring, bit(.Read))
	}
	if o == nil {
		return err(st)
	}
	c := o.type == .Counter ? cast(^Counter)o : (cast(^Ring_End)o).doorbell
	v := counter_read(c)
	object_release(o)
	return v > u64(max(i64)) ? err(.Err_Range) : i64(v)
}

// port_bind(port, source, trigger, key, threshold): a one-shot binding of a
// channel end, counter, task, ring end or Irq to the port.
@(private="file")
sys_port_bind :: proc "contextless" (ph, sh: vx.Handle, trigger, key, threshold: u64) -> i64 {
	po, st := handle_get(current_task(), ph, .Port, bit(.Write))
	if po == nil {
		return err(st)
	}
	defer object_release(po)
	if trigger < u64(vx.Trigger.User) || trigger > u64(vx.Trigger.Irq) {
		return err(.Err_Invalid)
	}
	src: ^Object
	for type in ([]Obj_Type{.Channel, .Counter, .Task, .Ring, .Irq}) {
		if src, st = handle_get(current_task(), sh, type, bit(.Wait)); src != nil {
			break
		}
	}
	if src == nil {
		return err(st)
	}
	defer object_release(src)
	b := binding_new(cast(^Port)po, vx.Trigger(trigger), key, threshold, sh)
	if b == nil {
		return err(.Err_No_Memory)
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
	return err(st)
}

// --- Rings ---

@(private="file")
sys_ring_create :: proc "contextless" (params_ptr, out: u64) -> i64 {
	p: vx.Ring_Params
	if st := copy_from_user(&p, params_ptr, size_of(p)); st != .Ok {
		return err(st)
	}
	if !user_range_ok(out, size_of(vx.Ring_Handles), true) {
		return err(.Err_Invalid)
	}
	client, server, memory, st := ring_create(p)
	if st != .Ok {
		return err(st)
	}
	END_RIGHTS := bit(.Read) | bit(.Write) | bit(.Wait) | bit(.Signal) | bit(.Duplicate) | bit(.Transfer) | bit(.Inspect)
	MEMORY_RIGHTS := bit(.Read) | bit(.Write) | bit(.Map) | bit(.Duplicate) | bit(.Transfer) | bit(.Inspect)
	h: vx.Ring_Handles
	t := current_task()
	h.client, st = handle_add(t, &client.obj, END_RIGHTS)
	if st == .Ok {
		h.server, st = handle_add(t, &server.obj, END_RIGHTS)
	}
	if st == .Ok {
		h.memory, st = handle_add(t, &memory.obj, MEMORY_RIGHTS)
	}
	object_release(&client.obj)
	object_release(&server.obj)
	object_release(&memory.obj)
	if st == .Ok {
		st = copy_to_user(out, &h, size_of(h))
	}
	if st != .Ok {
		for v in ([]vx.Handle{h.client, h.server, h.memory}) {
			if v != 0 {
				_ = handle_close(t, v)
			}
		}
	}
	return err(st)
}

@(private="file")
sys_ring_notify :: proc "contextless" (h: vx.Handle) -> i64 {
	o, st := handle_get(current_task(), h, .Ring, bit(.Signal))
	if o == nil {
		return err(st)
	}
	st = ring_notify(cast(^Ring_End)o)
	object_release(o)
	return err(st)
}

// ring_xfer_handles(ring, PUT, handles, count, 0) -> slot;
// ring_xfer_handles(ring, TAKE, handles out, capacity, slot) -> count.
@(private="file")
sys_ring_xfer :: proc "contextless" (h: vx.Handle, op, handles, count, slot: u64) -> i64 {
	if op != u64(vx.Ring_Xfer.Put) && op != u64(vx.Ring_Xfer.Take) {
		return err(.Err_Invalid)
	}
	put := op == u64(vx.Ring_Xfer.Put)
	if count > vx.RING_SLOT_HANDLES || (put && count == 0) {
		return err(.Err_Invalid)
	}
	values: [vx.RING_SLOT_HANDLES]vx.Handle
	if put {
		if st := copy_from_user(&values, handles, count * size_of(vx.Handle)); st != .Ok {
			return err(st)
		}
	} else if !user_range_ok(handles, count * size_of(vx.Handle), true) {
		return err(.Err_Invalid)
	}
	o, st := handle_get(current_task(), h, .Ring, bit(.Write))
	if o == nil {
		return err(st)
	}
	defer object_release(o)
	e := cast(^Ring_End)o
	moved: [vx.RING_SLOT_HANDLES]Moved_Handle
	if put {
		if st = handles_take(current_task(), values[:count], o, moved[:count]); st != .Ok {
			return err(st)
		}
		result := ring_put(e, moved[:count])
		if result < 0 {
			for m in moved[:count] {
				object_release(m.obj) // gone, as with channel writes
			}
		}
		return result
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
		st = copy_to_user(handles, &values, u64(n) * size_of(vx.Handle))
	}
	for m in moved[:n] {
		object_release(m.obj)
	}
	return st == .Ok ? i64(n) : err(st)
}

// --- Tasks and threads ---

@(private="file")
sys_task_create :: proc "contextless" (name_ptr, name_len, out: u64) -> i64 {
	name: [24]u8
	if name_len >= len(name) {
		return err(.Err_Range)
	}
	if st := copy_from_user(&name, name_ptr, name_len); st != .Ok {
		return err(st)
	}
	t, st := task_create(string(name[:name_len]), current_task().id)
	if st != .Ok {
		return err(st)
	}
	t.may_debug_write = current_task().may_debug_write
	return return_handle(&t.obj, ALL_RIGHTS, out)
}

@(private="file")
sys_thread_create :: proc "contextless" (th: vx.Handle, out: u64) -> i64 {
	o, st := handle_get(current_task(), th, .Task, bit(.Manage))
	if o == nil {
		return err(st)
	}
	t := cast(^Task)o
	spin_lock(&t.lock)
	ending := t.ending || t.killed
	spin_unlock(&t.lock)
	thr: ^Thread
	if ending {
		st = .Err_Bad_State
	} else {
		thr, st = thread_create(t)
	}
	object_release(o)
	if st != .Ok {
		return err(st)
	}
	return return_handle(&thr.obj, ALL_RIGHTS, out)
}

// thread_start(thread, entry, sp, handle, arg2): the handle, unless 0, moves
// from the caller to the thread's task, and the thread gets its value there
// as its first argument.
@(private="file")
sys_thread_start :: proc "contextless" (h: vx.Handle, entry, sp: u64, arg: vx.Handle, arg2: u64) -> i64 {
	o, st := handle_get(current_task(), h, .Thread, bit(.Manage))
	if o == nil {
		return err(st)
	}
	th := cast(^Thread)o
	moved: vx.Handle
	if arg != 0 {
		m: [1]Moved_Handle
		args := [1]vx.Handle{arg}
		st = handles_take(current_task(), args[:], nil, m[:])
		if st == .Ok {
			out: [1]vx.Handle
			st = handles_put(th.task, m[:], out[:])
			moved = out[0]
			object_release(m[0].obj)
		}
	}
	if st == .Ok {
		st = thread_start(th, entry, sp, u64(moved), arg2)
		if st != .Ok && moved != 0 {
			_ = handle_close(th.task, moved)
		}
	}
	object_release(o)
	return err(st)
}

@(private="file")
sys_task_kill :: proc "contextless" (h: vx.Handle, status, id: u64) -> i64 {
	t, st := task_target(h, bit(.Manage), id, false)
	if t == nil {
		return err(st)
	}
	task_kill(t, i64(status))
	object_release(&t.obj)
	return 0
}

// --- Memory and handles ---

// vmo_rw(vmo, op, offset, buffer, size): copies between a VMO and the
// caller's memory.
@(private="file")
sys_vmo_rw :: proc "contextless" (h: vx.Handle, op, offset, buf, size: u64) -> i64 {
	if op != u64(vx.Vmo_Op.Read) && op != u64(vx.Vmo_Op.Write) {
		return err(.Err_Invalid)
	}
	reading := op == u64(vx.Vmo_Op.Read)
	if !user_range_ok(buf, size, reading) {
		return err(.Err_Invalid)
	}
	o, st := handle_get(current_task(), h, .Vmo, reading ? bit(.Read) : bit(.Write))
	if o == nil {
		return err(st)
	}
	defer object_release(o)
	v := cast(^Vmo)o
	end, overflow := intrinsics.overflow_add(offset, size)
	if v.physical {
		return err(.Err_Unsupported) // device memory is not in the direct map: map it instead
	}
	if overflow || end > v.size {
		return err(.Err_Range)
	}
	for done := u64(0); done < size; {
		at := offset + done
		in_page := at & 4095
		n := min(4096 - in_page, size - done)
		page := rawptr(uintptr(u64(uintptr(phys_to_virt(v.pages[at / 4096]))) + in_page))
		user := rawptr(uintptr(buf + done))
		if reading {
			intrinsics.mem_copy(user, page, int(n))
		} else {
			intrinsics.mem_copy(page, user, int(n))
		}
		done += n
	}
	return 0
}

@(private="file")
sys_handle_dup :: proc "contextless" (h: vx.Handle, rights, out: u64) -> i64 {
	t := current_task()
	spin_lock(&t.lock)
	index := u32(h) & 0xffff
	e: ^Handle_Entry
	if index != 0 && index < HANDLE_SLOTS && t.handles[index].obj != nil && u32(t.handles[index].generation) == u32(h) >> 16 {
		e = &t.handles[index]
	}
	st := vx.Status.Ok
	obj: ^Object
	r := u32(rights)
	switch {
	case e == nil:
		st = .Err_Bad_Handle
	case e.rights & bit(.Duplicate) == 0 || (rights != u64(vx.RIGHTS_SAME) && rights &~ u64(e.rights) != 0):
		st = .Err_Access // needs DUPLICATE, and can only reduce rights
	case:
		obj = e.obj
		if rights == u64(vx.RIGHTS_SAME) {
			r = e.rights
		}
		object_ref(obj)
	}
	spin_unlock(&t.lock)
	if obj == nil {
		return err(st)
	}
	return return_handle(obj, r, out)
}

syscall_dispatch :: proc "contextless" (nr: u64, a: [6]u64) -> i64 {
	if nr >= vx.SYSCALL_COUNT {
		return err(.Err_Unsupported)
	}
	#partial switch vx.Syscall(nr) {
	case .Debug_Write:
		return sys_debug_write(a[0], a[1])
	case .Clock_Read:
		return i64(clock_now())
	case .Task_Create:
		return sys_task_create(a[0], a[1], a[2])
	case .Task_Kill:
		return sys_task_kill(vx.Handle(a[0]), a[1], a[2])
	case .Task_Info:
		return sys_task_info(vx.Handle(a[0]), a[1], a[2], a[3])
	case .Thread_Create:
		return sys_thread_create(vx.Handle(a[0]), a[1])
	case .Thread_Start:
		return sys_thread_start(vx.Handle(a[0]), a[1], a[2], vx.Handle(a[3]), a[4])
	case .Thread_Exit:
		thread_exit_current(i64(a[0]))
	case .Port_Create:
		return sys_port_create(a[0], a[1])
	case .Port_Bind:
		return sys_port_bind(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], a[4])
	case .Port_Wait:
		return sys_port_wait(vx.Handle(a[0]), i64(a[1]), i64(a[2]), a[3], a[4])
	case .Port_Post:
		return sys_port_post(vx.Handle(a[0]), a[1])
	case .Counter_Create:
		return sys_counter_create(a[0], a[1])
	case .Counter_Signal:
		return sys_counter_signal(vx.Handle(a[0]), a[1])
	case .Counter_Read:
		return sys_counter_read(vx.Handle(a[0]))
	case .Futex_Wait:
		return futex_wait(a[0], u32(a[1]), Instant(a[2]))
	case .Futex_Wake:
		return futex_wake(a[0], u32(a[1]))
	case .Channel_Create:
		return sys_channel_create(a[0], a[1])
	case .Channel_Write:
		return sys_channel_write(vx.Handle(a[0]), a[1], a[2], a[3], a[4])
	case .Channel_Read:
		return sys_channel_read(vx.Handle(a[0]), a[1], a[2], a[3], a[4], a[5])
	case .Channel_Call:
		return sys_channel_call(vx.Handle(a[0]), a[1], i64(a[2]))
	case .Ring_Create:
		return sys_ring_create(a[0], a[1])
	case .Ring_Notify:
		return sys_ring_notify(vx.Handle(a[0]))
	case .Ring_Xfer_Handles:
		return sys_ring_xfer(vx.Handle(a[0]), a[1], a[2], a[3], a[4])
	case .Vmo_Create:
		return sys_vmo_create(a[0], a[1], a[2], vx.Handle(a[3]), a[4])
	case .Irq_Create:
		return sys_irq_create(vx.Handle(a[0]), a[1], a[2], a[3])
	case .Irq_Ack:
		return sys_irq_ack(vx.Handle(a[0]))
	case .Iorange_Create:
		return sys_iorange_create(vx.Handle(a[0]), a[1], a[2], a[3])
	case .Vmo_Rw:
		return sys_vmo_rw(vx.Handle(a[0]), a[1], a[2], a[3], a[4])
	case .As_Map:
		return sys_as_map(vx.Handle(a[0]), vx.Handle(a[1]), a[2], a[3], a[4], a[5])
	case .Handle_Dup:
		return sys_handle_dup(vx.Handle(a[0]), a[1], a[2])
	case .Handle_Close:
		return err(handle_close(current_task(), vx.Handle(a[0])))
	}
	return err(.Err_Unsupported)
}
