// Crash directories (upstream docs/05 §5).
//
// procfs binds each process's exception port, the last in line: a fault that
// neither a debugger nor the program's own handler takes reaches it (vx:rt
// and the musl back end let such a fault happen again, uncaught). procfs then
// stops the process's other threads and saves it as a directory shaped like
// /proc/N, so dbg opens it with the code it uses for a live one:
//
//   /tmp/crash/NAME.PID/
//       info status maps images     as /proc/N's, at the moment of the fault
//       note                        the fault in Plan 9's words: its exit string
//       threads/T/status regs regs.ndb fpregs
//       mem/0xBASE                  each writable mapping's bytes, from its base
//
// Read-only mappings are not copied: the images are named by their build IDs;
// of the writable ones, at most CRASH_MEM_MAX bytes, so one crash does not
// fill /tmp. Each call to tmpfs has a time limit: the process that faulted may
// be tmpfs, or one tmpfs waits on, and procfs would otherwise wait on it as it
// waits on procfs. Then the task is killed with the trap's words, as an
// unhandled fault always ends it. The directories go to tmpfs (connect=tmpfs),
// reached the first time one is needed; /lib/crash and $home/lib/crash wait
// for a file system that keeps them (upstream docs/milestones.md).
package procfs

import "base:intrinsics"
import vx "abi:vx"
import "vx:p9"
import "vx:rt"
import "vx:str"

@(private)
tmpfs: vx.Handle // a connector to /srv/tmpfs
@(private="file")
crash_conn: rt.Conn
@(private="file")
crash_root: p9.Fid // /crash on it, once made
@(private="file")
CRASH_MEM_MAX :: u64(16) << 20
@(private="file")
CRASH_WAIT :: vx.Duration(5_000_000_000)

// A directory `name` made in dir: a fid walked to it, not open, so files can
// be made in it (9P walks only from a fid that is not open). 0 if it cannot be.
@(private="file")
crash_mkdir :: proc "contextless" (c: ^p9.Client, dir: p9.Fid, name: string) -> p9.Fid {
	fid, st := p9.client_walk(c, dir, "")
	if st != .Ok {
		return 0
	}
	st = p9.client_create(c, fid, name, p9.DMDIR | 0o755, p9.OREAD)
	_ = p9.client_clunk(c, fid)
	if st != .Ok {
		return 0
	}
	fid, st = p9.client_walk(c, dir, name)
	return st == .Ok ? fid : 0
}

// The connection to tmpfs, and its /crash, made the first time.
@(private="file")
crash_fs :: proc "contextless" () -> ^p9.Client {
	if crash_root != 0 && !crash_conn.dead {
		return &crash_conn.c
	}
	if crash_root != 0 {
		rt.p9_disconnect(&crash_conn) // it timed out: made again
	}
	crash_root = 0
	if tmpfs == vx.HANDLE_NONE || rt.p9_connect(tmpfs, &crash_conn) != .Ok {
		return nil
	}
	// vx:rt's Conn has no timeout until the P4 back end's port of upstream's
	// ring.c lands; until then a call to tmpfs has no time limit.
	when intrinsics.type_has_field(rt.Conn, "timeout") {
		crash_conn.timeout = CRASH_WAIT
	}
	c := &crash_conn.c
	root, st := p9.client_attach(c, "")
	if st != .Ok {
		rt.p9_disconnect(&crash_conn)
		return nil
	}
	dir: p9.Fid
	dir, st = p9.client_walk(c, root, "crash")
	if st != .Ok { // made: then walked to, for a fid that is not open (an open one cannot be walked from)
		dir = crash_mkdir(c, root, "crash")
		st = dir != 0 ? .Ok : .Err_Not_Found
	}
	_ = p9.client_clunk(c, root)
	if st != .Ok {
		rt.p9_disconnect(&crash_conn)
		return nil
	}
	crash_root = dir
	return c
}

// A file `name` in dir, holding data.
@(private="file")
crash_file :: proc "contextless" (c: ^p9.Client, dir: p9.Fid, name: string, data: []u8) {
	fid, st := p9.client_walk(c, dir, "")
	if st != .Ok {
		return
	}
	if p9.client_create(c, fid, name, 0o644, p9.OWRITE) == .Ok {
		for done := 0; done < len(data); {
			n, wst := p9.client_write(c, fid, u64(done), data[done:][:min(len(data) - done, 1 << 20)])
			if wst != .Ok || n <= 0 {
				break
			}
			done += n
		}
	}
	_ = p9.client_clunk(c, fid)
}

// Each writable mapping, a page at a time: a page that cannot be read (never
// touched, say) ends that mapping's file there.
@(private="file")
crash_mem :: proc "contextless" (c: ^p9.Client, dir: p9.Fid, p: ^Proc) {
	@(static) page: [4096]u8
	mem := crash_mkdir(c, dir, "mem")
	if mem == 0 {
		return
	}
	saved: u64
	for at := u64(0); saved < CRASH_MEM_MAX; {
		m, st := rt.as_query(p.task, at)
		if st != .Ok {
			break
		}
		at = m.base + m.size
		if .Write not_in m.flags {
			continue
		}
		fid, wst := p9.client_walk(c, mem, "")
		if wst != .Ok {
			continue
		}
		name: [18]u8
		if p9.client_create(c, fid, hex_text(m.base, &name), 0o644, p9.OWRITE) == .Ok {
			for off := u64(0); off < m.size && saved < CRASH_MEM_MAX; off, saved = off + len(page), saved + len(page) {
				if mem_rw(p, m.base + off, page[:], false) != .Ok {
					break
				}
				if n, e := p9.client_write(c, fid, off, page[:]); e != .Ok || n != len(page) {
					break
				}
			}
		}
		_ = p9.client_clunk(c, fid)
	}
	_ = p9.client_clunk(c, mem)
}

@(private="file")
crash_thread :: proc "contextless" (c: ^p9.Client, threads: p9.Fid, p: ^Proc, tid: u32) {
	@(static) thread_text: [1024]u8
	name: [str.U64_DIGITS]u8
	dir := crash_mkdir(c, threads, str.format_u64(name[:], u64(tid)))
	if dir == 0 {
		return
	}
	n := thread_status_text(p, tid, thread_text[:])
	crash_file(c, dir, "status", thread_text[:n])
	n = regs_ndb_text(p, tid, thread_text[:])
	crash_file(c, dir, "regs.ndb", thread_text[:n])
	r: vx.Regs
	if rt.thread_state(p.task, tid, .Get_Regs, &r) == .Ok {
		crash_file(c, dir, "regs", ptr_bytes(&r))
	}
	fp: vx.Fpregs
	if rt.thread_state(p.task, tid, .Get_Fpregs, &fp) == .Ok {
		crash_file(c, dir, "fpregs", ptr_bytes(&fp))
	}
	_ = p9.client_clunk(c, dir)
}

// Thread tid of p faulted, and nothing took it: saved, then killed.
@(private)
crash :: proc "contextless" (p: ^Proc, tid: u32) {
	e: vx.Exception
	info: vx.Task_Summary
	st := rt.thread_state(p.task, tid, .Get_Exception, &e)
	if st == .Ok {
		info, st = rt.task_info(p.task)
	}
	if st != .Ok {
		_ = rt.exception_resume(p.task, tid, .Kill)
		return
	}
	_ = rt.thread_suspend(p.task, 0) // the others hold still, their registers readable
	h := held_of(p, tid, true)
	if h != nil {
		h^ = {tid = tid, why = .Fault, pc = reg_pc(&e.regs)^}
	}
	note_buf: [vx.ERRMAX]u8
	note := vx.trap_note(e.kind, e.code, e.address, reg_pc(&e.regs)^, &note_buf)
	// NAME.PID
	dirname_buf: [48]u8
	pid: [str.U64_DIGITS]u8
	dirname, _ := str.join(dirname_buf[:], str.from_nul_padded(info.name[:]), ".", str.format_u64(pid[:], p.pid))
	c := crash_fs()
	dir := c != nil ? crash_mkdir(c, crash_root, dirname) : 0
	if dir != 0 {
		crash_file(c, dir, "note", transmute([]u8)note)
		n := status_text(p, text[:])
		crash_file(c, dir, "status", text[:n])
		n = info_text(p, text[:])
		crash_file(c, dir, "info", text[:n])
		n = maps_text(p, text[:])
		crash_file(c, dir, "maps", text[:n])
		n = images_text(p, text[:])
		crash_file(c, dir, "images", text[:n])
		if threads := crash_mkdir(c, dir, "threads"); threads != 0 {
			ti: vx.Thread_Info
			for rt.thread_state(p.task, ti.id, .Next_Thread, &ti) == .Ok {
				crash_thread(c, threads, p, ti.id)
			}
			_ = p9.client_clunk(c, threads)
		}
		crash_mem(c, dir, p)
		_ = p9.client_clunk(c, dir)
	}
	rt.print("procfs: ", dirname, ": ", note, dir != 0 ? "; saved in /tmp/crash\n" : "; not saved\n")
	if h != nil {
		h^ = {}
	}
	_ = rt.exception_resume(p.task, tid, .Kill) // the default: the trap's words end it
}
