// The fake kernel under servers/procfs on the host. This file defines
// vx_syscall (and vx_cycles), so the runtime's calls land here, acting on a
// small table of tasks, each with threads, mappings backed by host memory,
// watchpoints and the bindings procfs makes. The test drives procfs's p9.Fs
// and its listen and port hooks, and plays the kernel's part itself: an
// exit or an exception is a packet it hands to procfs's event hook, keyed as
// procfs bound it.
package procfs_test

import vx "abi:vx"
import "vx:ns"
import procfs "../../../servers/procfs"

TASKS :: vx.Handle(0x101) // the "tasks" handle the fake spawn message gives: svcd's task
LISTEN :: vx.Handle(0x102)
PORT :: vx.Handle(0x103)
NSD :: vx.Handle(0x104)
RING_VMO :: vx.Handle(0x105) // a profiling ring's VMO, which the fake maps at ring's address
TASK_HANDLE :: vx.Handle(0x200) // plus a task's id: a handle to it

Fake_Thread :: struct {
	id:          u32,
	state:       vx.Thread_Run_State,
	regs:        vx.Regs,
	exception:   vx.Exception, // while stopped at a port
	resumed:     vx.Resume_Action, // how it was last resumed (0: not since it stopped)
	resumes:     int,
}

Fake_Map :: struct {
	base:   u64,
	flags:  vx.Map_Options,
	offset: u64,
	bytes:  []u8, // host memory standing in for the mapping's pages
}

Fake_Task :: struct {
	id:          u64,
	name:        string,
	state:       vx.Task_State,
	blocked:     u32,
	mapped:      u64,
	exit:        [dynamic; vx.ERRMAX]u8, // its exit string, once killed
	threads:     [dynamic; 4]Fake_Thread,
	maps:        [dynamic; 4]Fake_Map,
	watches:     vx.Watches,
	suspends:    int, // thread_suspend(task, 0) less thread_resume(task, 0)
	notes:       [dynamic; 8][dynamic; vx.ERRMAX]u8, // posted with thread_interrupt
	exit_key:    u64, // procfs's EXIT binding: 0 if none
	crash_key:   u64, // its exception binding, the last in line
	debug_key:   u64, // its debugger's (First_Chance)
	closed:      bool, // procfs closed its handle
}

tasks: [dynamic; 16]Fake_Task

kernel_log: [dynamic; 4096]u8
now: vx.Instant = 1_000_000_000

// The last message procfs wrote on the listen channel.
reply: [dynamic; 64]u8
reply_handles: int

// What the fake nsd says a group's namespace is.
NS_TEXT :: "mount -a /srv/bootfs /\nbind /boot /n\n"

// The host memory a profiling ring lives in, mapped by both procfs and the
// process that gives it.
ring_words: [64 * 1024 / 8]u64 // u64s, for the header's alignment

ring_mem :: proc "contextless" () -> []u8 {
	return ([^]u8)(&ring_words)[:size_of(ring_words)]
}

add_task :: proc(t: Fake_Task) -> ^Fake_Task {
	_ = append(&tasks, t)
	return &tasks[len(tasks) - 1]
}

task_by_id :: proc "contextless" (id: u64) -> ^Fake_Task {
	for &t in tasks {
		if t.id == id {
			return &t
		}
	}
	return nil
}

// The task a handle reaches: TASKS is svcd's, rt.self (HANDLE_NONE here) procfs's own.
task_of :: proc "contextless" (h: vx.Handle) -> ^Fake_Task {
	switch {
	case h == TASKS:
		return task_by_id(1)
	case h == vx.HANDLE_NONE:
		return task_by_id(2)
	case h > TASK_HANDLE && h < TASK_HANDLE + 0x100:
		return task_by_id(u64(h - TASK_HANDLE))
	}
	return nil
}

thread_of :: proc "contextless" (t: ^Fake_Task, id: u32) -> ^Fake_Thread {
	for &th in t.threads {
		if th.id == id {
			return &th
		}
	}
	return nil
}

// The host bytes of [address, address + size) in t, if one mapping holds them.
memory_of :: proc "contextless" (t: ^Fake_Task, address, size: u64) -> ([]u8, bool) {
	for &m in t.maps {
		end := m.base + u64(len(m.bytes))
		if address >= m.base && address < end && size <= end - address {
			return m.bytes[address - m.base:][:size], true
		}
	}
	return nil, false
}

ptr :: #force_inline proc "contextless" ($T: typeid, a: u64) -> ^T {
	return (^T)(uintptr(a))
}

bytes_at :: #force_inline proc "contextless" (a, n: u64) -> []u8 {
	return ([^]u8)(uintptr(a))[:n]
}

ERR :: #force_inline proc "contextless" (st: vx.Status) -> i64 {
	return i64(st)
}

@(export, link_name="vx_cycles")
fake_cycles :: proc "c" () -> u64 {
	return 0x1234_5678
}

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		_ = append(&kernel_log, ..bytes_at(a0, a1))
		return 0
	case .Clock_Read:
		if a0 != 0 {
			ptr(vx.Clock_Info, a0)^ = {counter_hz = 24_000_000}
			return 0
		}
		return i64(now)
	case .Port_Create:
		ptr(vx.Handle, a1)^ = PORT
		return 0
	case .Port_Bind: // (port, source, trigger, key, threshold)
		t := task_of(vx.Handle(a1))
		if vx.Handle(a0) != PORT || t == nil || vx.Trigger(a2) != .Exit {
			return ERR(.Err_Invalid)
		}
		t.exit_key = a3
		return 0
	case .Exception_Bind: // (task, port, key, options)
		t := task_of(vx.Handle(a0))
		if t == nil {
			return ERR(.Err_Bad_Handle)
		}
		key := vx.Handle(a1) == vx.HANDLE_NONE ? 0 : a2
		if .First_Chance in transmute(vx.Exception_Options)u32(a3) {
			t.debug_key = key
		} else {
			t.crash_key = key
		}
		return 0
	case .Exception_Resume: // (task, thread, action, regs)
		t := task_of(vx.Handle(a0))
		th := t != nil ? thread_of(t, u32(a1)) : nil
		if th == nil || th.state != .Stopped {
			return ERR(.Err_Bad_State)
		}
		th.state, th.resumed = .Running, vx.Resume_Action(a2)
		th.resumes += 1
		return 0
	case .Task_Info: // (task, out, id, flags)
		t := task_of(vx.Handle(a0))
		if t == nil {
			return ERR(.Err_Bad_Handle)
		}
		out := ptr(vx.Task_Summary, a1)
		out^ = {id = t.id, state = t.state, threads = u32(len(t.threads)), blocked = t.blocked, mapped = t.mapped}
		out.exit_len = u32(copy(out.exit[:], t.exit[:]))
		copy(out.name[:], t.name)
		return 0
	case .Task_Kill: // (task, msg, len, id)
		t := task_of(vx.Handle(a0))
		if t == nil || t.state == .Exited {
			return ERR(.Err_Not_Found)
		}
		t.state = .Exited
		clear(&t.exit)
		_ = append(&t.exit, string(bytes_at(a1, a2)))
		return 0
	case .Thread_Interrupt: // (task, thread, note, len)
		t := task_of(vx.Handle(a0))
		if t == nil || t.state == .Exited {
			return ERR(.Err_Bad_State)
		}
		n: [dynamic; vx.ERRMAX]u8
		_ = append(&n, string(bytes_at(a2, a3)))
		_ = append(&t.notes, n)
		return 0
	case .Thread_Suspend, .Thread_Resume: // (task, thread)
		t := task_of(vx.Handle(a0))
		if t == nil {
			return ERR(.Err_Bad_Handle)
		}
		if a1 == 0 {
			t.suspends += nr == .Thread_Suspend ? 1 : -1
		}
		return 0
	case .Thread_State: // (task, thread, op, buffer, size)
		return thread_state(task_of(vx.Handle(a0)), u32(a1), vx.Thread_State_Op(a2), a3, a4)
	case .Task_Mem_Rw: // (task, ops, count)
		t := task_of(vx.Handle(a0))
		if t == nil {
			return ERR(.Err_Bad_Handle)
		}
		for &op in ([^]vx.Mem_Op)(uintptr(a1))[:a2] {
			m, ok := memory_of(t, op.address, op.size)
			op.status = ok ? .Ok : .Err_Not_Found
			if ok && op.write {
				copy(m, bytes_at(op.buffer, op.size))
			} else if ok {
				copy(bytes_at(op.buffer, op.size), m)
			}
		}
		return 0
	case .As_Query: // (task, at, out)
		t := task_of(vx.Handle(a0))
		if t == nil {
			return ERR(.Err_Bad_Handle)
		}
		for &m in t.maps { // in address order
			if m.base + u64(len(m.bytes)) > a1 {
				ptr(vx.Map_Info, a2)^ = {base = m.base, size = u64(len(m.bytes)), offset = m.offset, flags = m.flags}
				return 0
			}
		}
		return ERR(.Err_Not_Found)
	case .As_Map: // (task, vmo, offset, size, flags, &address): procfs maps a ring
		if vx.Handle(a1) != RING_VMO {
			return ERR(.Err_Bad_Handle)
		}
		ptr(u64, a5)^ = u64(uintptr(&ring_words))
		return 0
	case .As_Unmap:
		return 0
	case .Channel_Write: // (channel, bytes, len, handles, count)
		if vx.Handle(a0) != LISTEN {
			return ERR(.Err_Bad_Handle)
		}
		clear(&reply)
		_ = append(&reply, ..bytes_at(a1, a2))
		reply_handles = int(a4)
		return 0
	case .Channel_Read:
		return ERR(.Err_Peer_Closed) // the listen channel: serve returns at once
	case .Channel_Call: // (channel, call, deadline): nsd's Text
		if vx.Handle(a0) != NSD {
			return ERR(.Err_Bad_Handle)
		}
		c := ptr(vx.Call, a1)
		req := (^ns.Nsd_Msg)(c.wr_bytes)
		rep := bytes_at(u64(uintptr(c.rd_bytes)), u64(c.rd_cap))
		out := (^ns.Nsd_Msg)(raw_data(rep))
		out^ = {}
		if ns.Nsd_Call(req.header.ordinal) != .Text || req.args.task != 9 {
			not_found := vx.Status.Err_Not_Found
			out.header.flags = u32(i32(not_found))
			c.actual.bytes = size_of(out^)
			return 0
		}
		out.args.text_len = u32(copy(rep[size_of(out^):], NS_TEXT))
		c.actual.bytes = size_of(out^) + out.args.text_len
		return 0
	case .Handle_Close:
		if t := task_of(vx.Handle(a0)); t != nil && vx.Handle(a0) != TASKS {
			t.closed = true
		}
		return 0
	}
	return ERR(.Err_Unsupported)
}

thread_state :: proc "contextless" (t: ^Fake_Task, tid: u32, op: vx.Thread_State_Op, buf, size: u64) -> i64 {
	if t == nil {
		return ERR(.Err_Bad_Handle)
	}
	#partial switch op {
	case .Next_Thread:
		for &th in t.threads { // in id order
			if th.id > tid {
				ptr(vx.Thread_Info, buf)^ = {id = th.id, state = th.state}
				return 0
			}
		}
		return ERR(.Err_Not_Found)
	case .Get_Watch:
		w := ptr(vx.Watches, buf)
		w^ = t.watches
		w.count = 4
		return 0
	case .Set_Watch:
		w := ptr(vx.Watches, buf)
		for s in w.slot {
			if s.kind != .Off && (s.len == 0 || s.address % u64(s.len) != 0) {
				return ERR(.Err_Invalid)
			}
		}
		t.watches = w^
		return 0
	}
	th := thread_of(t, tid)
	if th == nil {
		return ERR(.Err_Not_Found)
	}
	#partial switch op {
	case .Get_Exception:
		if th.state != .Stopped || size != size_of(vx.Exception) {
			return ERR(.Err_Bad_State)
		}
		ptr(vx.Exception, buf)^ = th.exception
	case .Get_Regs:
		if th.state != .Stopped && th.state != .Suspended {
			return ERR(.Err_Bad_State)
		}
		ptr(vx.Regs, buf)^ = th.regs
	case .Set_Regs:
		th.regs = ptr(vx.Regs, buf)^
	case .Get_Fpregs:
		if th.state != .Stopped && th.state != .Suspended {
			return ERR(.Err_Bad_State)
		}
		fp := bytes_at(buf, size)
		for &b, i in fp {
			b = u8(i)
		}
	case .Set_Fpregs:
	case:
		return ERR(.Err_Unsupported)
	}
	return 0
}

// The kernel's part: an EXIT packet for the task, as procfs bound it.
fire_exit :: proc(t: ^Fake_Task) {
	pk := vx.Packet{key = t.exit_key, trigger = .Exit, value = u64(len(t.exit))}
	procfs.server.event(nil, &pk)
}

// Stops thread tid of t at an exception and tells procfs: at its debugger's
// port if it has one, else (crash) at the last in line.
fire_exception :: proc(t: ^Fake_Task, tid: u32, e: vx.Exception, last_in_line := false) {
	th := thread_of(t, tid)
	th.state = .Stopped
	th.exception = e
	th.exception.thread = tid
	th.regs = e.regs
	th.resumed = {}
	key := last_in_line ? t.crash_key : t.debug_key
	pk := vx.Packet{key = key, trigger = .Exception, value = u64(tid)}
	procfs.server.event(nil, &pk)
}
