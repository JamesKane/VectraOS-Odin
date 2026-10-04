// procfs: /proc, the one process table (upstream ADR-0011), with 9front's files.
//
// A process's pid is its task's kernel id, which is never reused, and exec
// keeps the task (ADR-0012). Whoever spawns a process registers it here
// before it runs (vx:process), on the listen channel posted as /srv/proc,
// with a handle to its task; svcd is registered through the "tasks" handle it
// gives procfs, and registers the services it started before procfs.
//
//   /proc/N/status   one ndb record: pid=7 name=gsh state=waiting threads=1 mem=412K sid=7
//   /proc/N/ctl      kill · stop [SIG] · start · setsid · childnotes
//   /proc/N/note     a write posts a note (ADR-0010)
//   /proc/N/notepg   a write posts a note to every process in N's note group
//   /proc/N/noteid   N's note group: read it, or write a group's id to join it
//   /proc/N/ppid     the parent's pid
//   /proc/N/ns       its namespace group's text, namespace(6) (ADR-0009), from nsd
//   /proc/N/wait     a read waits for a child to end, then returns its record:
//                    pid=9 name=ls noteid=7 status="" real=12 (ms); its length is the count
//
// As in 9front's pexit, a process that ends leaves a wait record for its
// parent, at most 128 queued, unless it was registered with .No_Wait, or the
// parent has gone or is not registered. A parent that goes leaves its
// children's ppid as it was. A note posted to a process whose wait read
// procfs holds ends that read, "interrupted", after the note, so the caller
// sees the note first, as ptyd does with the reads it holds.
//
// notepg includes the writer, unlike 9front's: a note to oneself is delivered
// before the write returns, so kill(0) signals the caller too, as POSIX has it.
//
// For POSIX (vx:signal), which builds signals on notes: procfs carries out the
// ones a process cannot, being stopped or unable to catch them: a note naming
// SIGKILL kills, SIGSTOP stops, and SIGCONT continues before it is delivered.
// A process that writes `childnotes` to its ctl gets the note "posix: SIGCHLD
// pid=N" when a child ends, stops or continues, and wait records for stops
// (stopped=SIG) and continues (continued) too.
//
// The debug files (upstream 05 §3: events, mem, maps, images, threads/, and
// ctl's break, step and the rest) are debug.odin's; crash directories (05 §5),
// crash.odin's; profiling zones (05 §9, /proc/N/prof), prof.odin's.
package procfs

import vx "abi:vx"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:p9ring"
import "vx:process"
import "vx:rt"
import "vx:signal"
import "vx:str"

MAX_PROCS :: 128
@(private="file")
MAX_RECORDS :: 2048 // wait records, for every parent together: 16 parents' worth
@(private="file")
MAX_WAITS :: 128 // queued for one parent, as 9front's pexit

Proc :: struct {
	used:        bool,
	root:        bool, // svcd, through "tasks": never killed
	nowait:      bool, // its parent wants no record of its end
	stopped:     bool, // ctl stop
	wait_held:   bool, // a read of its wait file is held
	interrupted: bool, // a note came while it was: the read ends
	childnotes:  bool, // SIGCHLD notes, and records of children's stops and continues (POSIX)
	slot:        u32, // its index in procs
	gen:         u32,
	pid, ppid:   u64,
	noteid, sid: u64,
	task:        vx.Handle,
	start:       vx.Instant,
	nwait:       u32, // records queued for it
	first, last: u32, // its queue, through Wait_Record.next; 0 is none
}

@(private="file")
Record_Kind :: enum u8 {
	Ended,
	Stopped,
	Continued,
}

@(private="file")
Wait_Record :: struct {
	next:    u32, // 0: the end
	pid:     u64, // 0: the slot is free
	kind:    Record_Kind,
	sig:     u8, // .Stopped: the signal that stopped it
	noteid:  u64, // its note group then, for a POSIX wait for a group's children
	real_ms: u64,
	name:    [24]u8, // NUL-padded, as task_info gives it
	status:  [dynamic; vx.ERRMAX]u8, // .Ended: its exit string
}

procs: [MAX_PROCS]Proc
@(private="file")
records: [MAX_RECORDS + 1]Wait_Record // records[0] is never used

by_pid :: proc "contextless" (pid: u64) -> ^Proc {
	if pid == 0 {
		return nil
	}
	for &p in procs {
		if p.used && p.pid == pid {
			return &p
		}
	}
	return nil
}

// The port keys of a process's bindings, from p9ring.KEY_USER up: its slot
// and the slot's generation, so a packet about a process that has gone is
// never taken for one about the slot's next; and which binding it is.
Proc_Key :: bit_field u64 {
	slot:  u32  | 16,
	gen:   u32  | 24,
	debug: bool | 1, // its exception binding as a debugger's (FIRST_CHANCE), bit 40
	crash: bool | 1, // its exception binding as the last in line, bit 41
	_:     u32  | 20,
	user:  u8   | 2, // KEY_USER
}
#assert(size_of(Proc_Key) == 8)
#assert(p9ring.KEY_USER == 1 << 62)

// The key of a process's EXIT binding.
exit_key :: proc "contextless" (p: ^Proc) -> Proc_Key {
	return {slot = p.slot, gen = p.gen, user = 1}
}

// Whether p has living children that will leave a record, for a wait to wait for.
@(private="file")
has_children :: proc "contextless" (p: ^Proc) -> bool {
	for &c in procs {
		if c.used && c.ppid == p.pid && !c.nowait && &c != p {
			return true
		}
	}
	return false
}

@(private="file")
self_id: u64 // procfs's own pid

// What a status carries in a message header's flags.
@(private="file")
flags_of :: proc "contextless" (st: vx.Status) -> u32 {
	return u32(i32(st))
}

// A new process for task (which it takes, if it succeeds), its parent's pid,
// and flags.
@(private="file", require_results)
admit :: proc "contextless" (task: vx.Handle, ppid: u64, flags: process.Flags, group: u64, root: bool) -> (out: ^Proc, st: vx.Status) {
	info, ist := rt.task_info(task)
	if ist != .Ok || info.state == .Exited {
		return nil, .Err_Invalid
	}
	if by_pid(info.id) != nil {
		return nil, .Err_Exists
	}
	slot := 0
	for slot < MAX_PROCS && procs[slot].used {
		slot += 1
	}
	if slot == MAX_PROCS {
		return nil, .Err_No_Memory
	}
	p := &procs[slot]
	parent := by_pid(ppid)
	p^ = {
		used   = true,
		root   = root,
		nowait = .No_Wait in flags,
		slot   = u32(slot),
		gen    = (p.gen + 1) & 0xff_ffff, // 24 bits in the keys
		pid    = info.id,
		ppid   = ppid,
		task   = task,
		start  = rt.clock_read(),
	}
	p.noteid = parent != nil && flags & {.Note_Group, .Set_Sid} == {} ? parent.noteid : p.pid
	p.sid = parent != nil && .Set_Sid not_in flags ? parent.sid : p.pid
	defer if st != .Ok {
		p^ = {gen = p.gen}
	}
	if group != 0 {
		joined := false
		for &o in procs {
			if o.used && &o != p && o.noteid == group && o.sid == p.sid {
				joined = true
				break
			}
		}
		if !joined {
			return nil, .Err_Access // not a group in its session
		}
		p.noteid = group
	}
	// svcd, the root, never ends; its handle ("tasks") carries no WAIT right.
	// A fault nothing else takes comes to procfs, for a crash directory
	// (crash.odin); but not procfs's own, which would wait for procfs to take
	// it: procfs ends instead, and svcd starts it again.
	if !root {
		rt.port_bind(server.port, task, .Exit, transmute(u64)exit_key(p)) or_return
		if info.id != self_id {
			key := exit_key(p)
			key.crash = true
			rt.exception_bind(task, server.port, transmute(u64)key) or_return
		}
	}
	return p, .Ok
}

// A message on the listen channel that is not CONNECT: a registration
// (vx:process), or a profiling ring.
@(private="file")
registered :: proc "contextless" (ctx: rawptr, msg: []u8, handle: vx.Handle) {
	m: process.Msg
	copy(ptr_bytes(&m), msg)
	whole := len(msg) >= size_of(m)
	if whole && m.header.ordinal == process.PROF && handle != vx.HANDLE_NONE {
		prep := process.Msg {
			header = {txid = m.header.txid, ordinal = process.PROF, flags = flags_of(prof_register(&m, handle))},
		}
		_ = rt.channel_write(server.listen, ptr_bytes(&prep))
		return
	}
	rep := process.Msg {
		header = {txid = m.header.txid, ordinal = process.REGISTER},
	}
	st := whole && m.header.ordinal == process.REGISTER && handle != vx.HANDLE_NONE ? vx.Status.Ok : .Err_Invalid
	p: ^Proc
	if st == .Ok {
		p, st = admit(handle, u64(m.arg[0]), transmute(process.Flags)u32(m.arg[1]), u64(m.arg[2]), false)
	}
	if st == .Ok {
		rep.arg[0] = i64(p.pid)
	} else if handle != vx.HANDLE_NONE {
		_ = rt.handle_close(handle)
	}
	rep.header.flags = flags_of(st)
	_ = rt.channel_write(server.listen, ptr_bytes(&rep))
}

// Queues a record of what happened to child c for its parent, if there is
// room: as 9front's pexit leaves one, at most MAX_WAITS.
@(private="file")
queue_record :: proc "contextless" (parent, c: ^Proc, kind: Record_Kind, sig: u8) {
	r := u32(1)
	for r <= MAX_RECORDS && records[r].pid != 0 {
		r += 1
	}
	if r > MAX_RECORDS || parent.nwait >= MAX_WAITS {
		return
	}
	info, st := rt.task_info(c.task)
	if st != .Ok {
		return
	}
	rec := &records[r]
	rec^ = {
		pid     = c.pid,
		noteid  = c.noteid,
		kind    = kind,
		sig     = sig,
		real_ms = u64(rt.clock_read() - c.start) / 1_000_000,
		name    = info.name,
	}
	if kind == .Ended {
		_ = append(&rec.status, vx.exit_string(&info))
	}
	if parent.last != 0 {
		records[parent.last].next = r
	} else {
		parent.first = r
	}
	parent.last = r
	parent.nwait += 1
	server.again = true // a wait read held for the parent may go on
}

// Delivers a note: the kernel interrupts p with it, and a wait read p is
// blocked in ends, after the note.
@(private="file", require_results)
deliver :: proc "contextless" (p: ^Proc, note: string) -> vx.Status {
	rt.thread_interrupt(p.task, 0, note) or_return
	if p.wait_held {
		p.interrupted = true // the held read ends
		server.again = true
	}
	return .Ok
}

// Tells c's parent what happened to it: a record (a stop or a continue only
// for a parent that asked for childnotes), and the SIGCHLD note if it did.
@(private="file")
tell_parent :: proc "contextless" (c: ^Proc, kind: Record_Kind, sig: u8) {
	parent := by_pid(c.ppid)
	if parent == nil || c.nowait {
		return
	}
	if kind == .Ended || parent.childnotes {
		queue_record(parent, c, kind, sig)
	}
	if !parent.childnotes {
		return
	}
	note: [vx.ERRMAX]u8
	_ = deliver(parent, signal.signal_note(signal.SIGCHLD, i64(c.pid), &note))
}

// The task has ended: its parent hears, and its own unread records go.
@(private="file")
ended :: proc "contextless" (p: ^Proc) {
	dbg_forget(p)
	prof_forget(p)
	tell_parent(p, .Ended, 0)
	for i := p.first; i != 0; {
		next := records[i].next
		records[i] = {}
		i = next
	}
	_ = rt.handle_close(p.task)
	p^ = {gen = p.gen}
	// Reads held for it go round again, record or not: a debugger's events
	// read, and a parent's wait read that is now waiting for nothing.
	server.again = true
}

// Stops every thread of p, for signal sig (its parent hears which), or
// continues it.
@(private="file", require_results)
stop :: proc "contextless" (p: ^Proc, sig: u8) -> vx.Status {
	if p.stopped {
		return .Ok
	}
	rt.thread_suspend(p.task, 0) or_return
	p.stopped = true
	tell_parent(p, .Stopped, sig)
	return .Ok
}

@(private, require_results)
cont :: proc "contextless" (p: ^Proc) -> vx.Status {
	if !p.stopped {
		return .Ok
	}
	p.stopped = false
	st := rt.thread_resume(p.task, 0)
	tell_parent(p, .Continued, 0)
	return st
}

@(private="file")
event :: proc "contextless" (ctx: rawptr, pk: ^vx.Packet) {
	key := transmute(Proc_Key)pk.key
	if key.slot >= MAX_PROCS {
		return
	}
	p := &procs[key.slot]
	if !p.used || p.gen != key.gen {
		return
	}
	#partial switch pk.trigger {
	case .Exit:
		ended(p)
	case .Exception:
		if key.crash {
			crash(p, u32(pk.value))
		} else {
			dbg_exception(p, u32(pk.value))
		}
	}
}

// Posts a note to p (a write to note or notepg). The signals a process cannot
// act on itself, procfs carries out. svcd takes none: it has no handler, and
// any note would end it, and the system with it.
@(private="file", require_results)
post :: proc "contextless" (p: ^Proc, note: string) -> vx.Status {
	if p.root {
		return .Err_Access
	}
	sig, _, _ := signal.note_signal(note)
	switch sig {
	case signal.SIGKILL:
		return rt.task_kill(p.task, "killed")
	case signal.SIGSTOP:
		return stop(p, u8(sig))
	case signal.SIGCONT:
		_ = cont(p) // and then its handler, if it has one
	}
	return deliver(p, note)
}

// --- The tree ---
//
// Node numbers: 1 is /proc; the rest are a process's pid shifted left 32,
// then a thread's id shifted left 8 (0 for the process's own files), then the
// file's number below: a process's, or under threads/T, a thread's.

ROOT :: p9.Node(1)

File :: enum u32 {
	Dir,
	Status,
	Ctl,
	Note,
	Notepg,
	Noteid,
	Ppid,
	Wait,
	Ns,
	Events,
	Mem,
	Maps,
	Images,
	Info,
	Prof,
	Threads,
	// 16 is the count of a process's directory's entries, never a file
	Prof_Ctl = 17, // in prof/, not listed in the process's directory
	Prof_Zones,
}

@(private="file")
PROC_FILES :: 16 // a process's directory: Dir and its entries, Status to Threads

Thread_File :: enum u32 {
	Dir,
	Status,
	Regs,
	Regs_Ndb,
	Fpregs,
	Ctl,
}

@(private="file")
File_Entry :: struct {
	name: string,
	mode: u32,
}

@(private="file")
FILE_TABLE := #sparse[File]File_Entry {
	.Dir        = {},
	.Status     = {"status", 0o444},
	.Ctl        = {"ctl", 0o222},
	.Note       = {"note", 0o222},
	.Notepg     = {"notepg", 0o222},
	.Noteid     = {"noteid", 0o664},
	.Ppid       = {"ppid", 0o444},
	.Wait       = {"wait", 0o444},
	.Ns         = {"ns", 0o444},
	.Events     = {"events", 0o444},
	.Mem        = {"mem", 0o664},
	.Maps       = {"maps", 0o444},
	.Images     = {"images", 0o444},
	.Info       = {"info", 0o444},
	.Prof       = {"prof", p9.DMDIR | 0o555},
	.Threads    = {"threads", p9.DMDIR | 0o555},
	.Prof_Ctl   = {"ctl", 0o222},
	.Prof_Zones = {"zones", 0o444},
}

@(private="file")
THREAD_FILES := [Thread_File]File_Entry {
	.Dir      = {},
	.Status   = {"status", 0o444},
	.Regs     = {"regs", 0o664},
	.Regs_Ndb = {"regs.ndb", 0o664},
	.Fpregs   = {"fpregs", 0o664},
	.Ctl      = {"ctl", 0o222},
}

Node_Bits :: bit_field u64 {
	file: u32 | 8,
	tid:  u32 | 24,
	pid:  u64 | 32,
}
#assert(size_of(Node_Bits) == 8)

@(private="file")
nsd: vx.Handle // a connector to nsd's post, for /proc/N/ns

// The namespace text of the group pid is in, from nsd, into buf; or empty.
@(private="file")
ns_text :: proc "contextless" (pid: u64, buf: []u8) -> int {
	@(static) reply: struct {
		msg:  ns.Nsd_Msg,
		text: [ns.NSD_TEXT_MAX]u8,
	}
	req := ns.Nsd_Msg {
		header = {ordinal = u32(ns.Nsd_Call.Text)},
		args = {task = pid},
	}
	c := vx.Call {
		wr_bytes = &req,
		wr_len   = size_of(req),
		rd_bytes = &reply,
		rd_cap   = size_of(reply),
	}
	if nsd == vx.HANDLE_NONE || rt.channel_call(nsd, &c, rt.clock_read() + 1_000_000_000) != .Ok {
		return 0
	}
	rep := &reply.msg
	if c.actual.bytes < size_of(rep^) || rep.header.flags != 0 || rep.args.text_len > c.actual.bytes - size_of(rep^) {
		return 0
	}
	return copy(buf, reply.text[:rep.args.text_len])
}

@(private="file")
proc_of :: proc "contextless" (node: p9.Node) -> ^Proc {
	return node == ROOT ? nil : by_pid(bits(node).pid)
}

@(private="file")
bits :: proc "contextless" (node: p9.Node) -> Node_Bits {
	return transmute(Node_Bits)u64(node)
}

node_of :: proc "contextless" (pid: u64, tid: u32, file: u32) -> p9.Node {
	return p9.Node(transmute(u64)Node_Bits{file = file, tid = tid, pid = pid})
}

// Whether thread tid of p is alive.
@(private="file")
thread_alive :: proc "contextless" (p: ^Proc, tid: u32) -> bool {
	ti: vx.Thread_Info
	return tid != 0 && rt.thread_state(p.task, tid - 1, .Next_Thread, &ti) == .Ok && ti.id == tid
}

@(private="file")
entry_of :: proc "contextless" (node: p9.Node) -> File_Entry {
	b := bits(node)
	if b.tid != 0 {
		return b.file <= u32(max(Thread_File)) ? THREAD_FILES[Thread_File(b.file)] : {}
	}
	f := File(b.file)
	return f <= max(File) && b.file != PROC_FILES ? FILE_TABLE[f] : {}
}

// The bytes of a value, for a message.
@(private)
ptr_bytes :: proc "contextless" (p: ^$T) -> []u8 {
	return ([^]u8)(p)[:size_of(T)]
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if len(aname) != 0 {
		return 0, .Err_Not_Found
	}
	return ROOT, .Ok
}

// A number in decimal: 1 to 19 digits, as a pid or a thread's id is written.
@(private)
parse_dec :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 || len(s) > 19 {
		return 0, false
	}
	return str.parse_u64(s)
}

// The id a directory is named by: no leading zeros.
@(private="file")
parse_id :: proc "contextless" (name: string) -> (v: u64, ok: bool) {
	v, ok = parse_dec(name)
	return v, ok && name[0] != '0'
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	if dir == ROOT {
		n, ok := parse_id(name)
		if !ok || by_pid(n) == nil {
			return 0, .Err_Not_Found
		}
		return node_of(n, 0, u32(File.Dir)), .Ok
	}
	p := proc_of(dir)
	if p == nil {
		return 0, .Err_Not_Found
	}
	b := bits(dir)
	if b.tid == 0 && File(b.file) == .Threads { // a thread's directory, by its id
		n, ok := parse_id(name)
		if !ok || n > 0xff_ffff || !thread_alive(p, u32(n)) {
			return 0, .Err_Not_Found
		}
		return node_of(p.pid, u32(n), u32(Thread_File.Dir)), .Ok
	}
	if b.tid == 0 && File(b.file) == .Prof { // prof/'s files
		for f in ([]File{.Prof_Ctl, .Prof_Zones}) {
			if FILE_TABLE[f].name == name {
				return node_of(p.pid, 0, u32(f)), .Ok
			}
		}
		return 0, .Err_Not_Found
	}
	if b.file != 0 {
		return 0, .Err_Not_Found
	}
	if b.tid != 0 {
		for e, f in THREAD_FILES {
			if f != .Dir && e.name == name {
				return node_of(p.pid, b.tid, u32(f)), .Ok
			}
		}
		return 0, .Err_Not_Found
	}
	for f := u32(1); f < PROC_FILES; f += 1 {
		if FILE_TABLE[File(f)].name == name {
			return node_of(p.pid, 0, f), .Ok
		}
	}
	return 0, .Err_Not_Found
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	b := bits(node)
	switch {
	case node == ROOT || (b.tid == 0 && b.file == 0):
		return ROOT, .Ok
	case b.tid != 0 && b.file == 0:
		return node_of(b.pid, 0, u32(File.Threads)), .Ok
	case b.tid == 0 && b.file > PROC_FILES:
		return node_of(b.pid, 0, u32(File.Prof)), .Ok
	}
	return node_of(b.pid, b.tid, 0), .Ok // a file: its process's directory, or its thread's
}

@(private="file")
name_buf: [str.U64_DIGITS]u8

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	if node == ROOT {
		out^ = {qid = {type = p9.QTDIR, path = u64(ROOT)}, mode = p9.DMDIR | 0o555, name = "/"}
	} else {
		p := proc_of(node)
		if p == nil {
			return .Err_Not_Found
		}
		b := bits(node)
		if b.file == 0 {
			// Its directory's name: the pid, or the thread's id, in decimal.
			name := str.format_u64(name_buf[:], b.tid != 0 ? u64(b.tid) : p.pid)
			out^ = {qid = {type = p9.QTDIR, path = u64(node)}, mode = p9.DMDIR | 0o555, name = name}
		} else {
			e := entry_of(node)
			out^ = {qid = {type = e.mode & p9.DMDIR != 0 ? p9.QTDIR : p9.QTFILE, path = u64(node)}, mode = e.mode, name = e.name}
			if b.tid == 0 && File(b.file) == .Wait {
				out.length = u64(p.nwait) // as 9front's: more than 0 means a read will not wait
			}
			if b.tid == 0 && File(b.file) == .Events {
				out.length = u64(dbg_of(p).ev_count)
			}
		}
	}
	out.uid, out.gid, out.muid = "proc", "proc", "proc"
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	if mode.rclose {
		return .Err_Access
	}
	if node == ROOT {
		return mode.access == .Read ? .Ok : .Err_Access
	}
	p := proc_of(node)
	if p == nil {
		return .Err_Not_Found
	}
	b := bits(node)
	perm := b.file == 0 ? 0o555 : entry_of(node).mode & 0o777
	reads := mode.access == .Read || mode.access == .Rdwr
	writes := mode.access == .Write || mode.access == .Rdwr
	if (reads && perm & 0o444 == 0) || (writes && perm & 0o222 == 0) {
		return .Err_Access
	}
	if b.tid == 0 && File(b.file) == .Events && !p.root {
		return dbg_bind(p) // a reader of events is a debugger
	}
	return .Ok // trunc means nothing to a file made as it is read
}

// A process's status record, as it is now.
@(private)
status_text :: proc "contextless" (p: ^Proc, buf: []u8) -> int {
	info, st := rt.task_info(p.task)
	if st != .Ok {
		return 0
	}
	w := ndb.Writer{buf = buf}
	ndb.put_u64(&w, "pid", p.pid)
	ndb.put(&w, "name", str.from_nul_padded(info.name[:]))
	state := "running"
	switch {
	case info.state == .New:
		state = "new"
	case p.stopped:
		state = "stopped"
	case info.threads != 0 && info.blocked == info.threads:
		state = "waiting"
	}
	ndb.put(&w, "state", state)
	ndb.put_u64(&w, "threads", u64(info.threads))
	mem_buf: [str.U64_DIGITS + 1]u8
	mem := str.Buf{buf = mem_buf[:]}
	str.write_u64(&mem, info.mapped / 1024)
	str.write_byte(&mem, 'K')
	ndb.put(&w, "mem", str.to_string(&mem))
	ndb.put_u64(&w, "sid", p.sid)
	_ = ndb.end(&w)
	return w.failed ? 0 : w.len
}

// The next wait record for p, taken from its queue: Err_Should_Wait if there
// is none yet, Err_No_Child if none will come, Err_Interrupted if a note ended
// the wait.
@(private="file", require_results)
take_record :: proc "contextless" (p: ^Proc, buf: []u8) -> (n: int, st: vx.Status) {
	if p.interrupted {
		p.interrupted, p.wait_held = false, false
		return 0, .Err_Interrupted
	}
	if p.first == 0 {
		p.wait_held = has_children(p)
		return 0, p.wait_held ? .Err_Should_Wait : .Err_No_Child
	}
	p.wait_held = false
	rec := &records[p.first]
	p.first = rec.next
	if p.first == 0 {
		p.last = 0
	}
	p.nwait -= 1
	w := ndb.Writer{buf = buf}
	ndb.put_u64(&w, "pid", rec.pid)
	ndb.put(&w, "name", str.from_nul_padded(rec.name[:]))
	ndb.put_u64(&w, "noteid", rec.noteid)
	switch rec.kind {
	case .Stopped:
		ndb.put_u64(&w, "stopped", u64(rec.sig))
	case .Continued:
		ndb.flag(&w, "continued")
	case .Ended:
		ndb.put(&w, "status", string(rec.status[:]))
		ndb.put_u64(&w, "real", rec.real_ms)
	}
	_ = ndb.end(&w)
	rec^ = {}
	return w.failed ? 0 : w.len, .Ok
}

// What of text a read at offset gets, into buf.
@(private)
read_at :: proc "contextless" (text: []u8, offset: u64, buf: []u8) -> u32 {
	if offset >= u64(len(text)) {
		return 0
	}
	return u32(copy(buf, text[offset:]))
}

// A thread's files: status and the registers, binary or as text.
@(private="file")
thread_read :: proc "contextless" (p: ^Proc, tid: u32, f: Thread_File, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	@(static) text: [1024]u8
	n := 0
	#partial switch f {
	case .Status:
		n = thread_status_text(p, tid, text[:])
	case .Regs_Ndb:
		n = regs_ndb_text(p, tid, text[:])
	case .Regs:
		r: vx.Regs
		rt.thread_state(p.task, tid, .Get_Regs, &r) or_return // running: its registers will not hold still
		n = copy(text[:], ptr_bytes(&r))
	case .Fpregs:
		fp: vx.Fpregs
		rt.thread_state(p.task, tid, .Get_Fpregs, &fp) or_return
		n = copy(text[:], ptr_bytes(&fp))
	}
	return read_at(text[:n], offset, buf), .Ok
}

// mem: the task's memory at offset, as much of it as is mapped. A page at a
// time, so a hole ends the read where it starts: what came before it; at the
// hole itself, an error, not an empty read (the end of a file).
@(private="file")
mem_read :: proc "contextless" (p: ^Proc, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	done := 0
	for done < len(buf) {
		at := offset + u64(done)
		n := min(len(buf) - done, int(4096 - at & 4095))
		if mem_rw(p, at, buf[done:][:n], false) != .Ok {
			break
		}
		done += n
	}
	return u32(done), done != 0 || len(buf) == 0 ? .Ok : .Err_Invalid
}

@(private)
text: [ns.NSD_TEXT_MAX]u8 // what a file reads as, made as it is read

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	p := proc_of(node)
	if p == nil {
		return 0, .Err_Not_Found
	}
	b := bits(node)
	if b.tid != 0 {
		return thread_read(p, b.tid, Thread_File(b.file), offset, buf)
	}
	n := 0
	#partial switch File(b.file) {
	case .Mem:
		return mem_read(p, offset, buf)
	case .Maps:
		n = maps_text(p, text[:])
	case .Images:
		n = images_text(p, text[:])
	case .Info:
		n = info_text(p, text[:])
	case .Prof_Zones:
		return read_at(prof_snapshot(p), offset, buf), .Ok // a whole ring: bigger than text
	case .Events: // a record each read, as wait's; a read waits for one
		n = take_event(p, text[:]) or_return
		return u32(copy(buf, text[:n])), .Ok
	case .Status:
		n = status_text(p, text[:])
	case .Ns:
		n = ns_text(p.pid, text[:])
	case .Noteid:
		n = copy(text[:], str.format_u64(name_buf[:], p.noteid))
	case .Ppid:
		n = copy(text[:], str.format_u64(name_buf[:], p.ppid))
	case .Wait: // a record each read, whatever the offset, as 9front's
		n = take_record(p, text[:]) or_return
		return u32(copy(buf, text[:n])), .Ok
	}
	return read_at(text[:n], offset, buf), .Ok
}

// What a write says, without the newlines and spaces at its end (echo adds one).
@(private="file")
written :: proc "contextless" (data: []u8) -> string {
	n := len(data)
	for n > 0 && (data[n - 1] == '\n' || data[n - 1] == ' ') {
		n -= 1
	}
	return string(data[:n])
}

@(private="file", require_results)
ctl :: proc "contextless" (p: ^Proc, cmd: string) -> vx.Status {
	switch {
	case cmd == "kill":
		if p.root {
			return .Err_Access // svcd: the system needs it
		}
		return rt.task_kill(p.task, "killed")
	case str.has_prefix(cmd, "stop") && (len(cmd) == 4 || cmd[4] == ' '):
		sig := u64(signal.SIGSTOP) // stop SIG: which signal stopped it, for its parent's wait
		if len(cmd) > 5 {
			ok: bool
			sig, ok = parse_dec(cmd[5:])
			if !ok || sig == 0 || sig > u64(signal.NSIG) {
				return .Err_Invalid
			}
		}
		return p.root ? .Err_Access : stop(p, u8(sig))
	case cmd == "start":
		release_all(p) // threads held at events, and those stopped
		return cont(p)
	case cmd == "setsid":
		// POSIX: refused if any process's group is the caller's pid (a leader,
		// or one that left its group with others still in it), whose group
		// would then span two sessions.
		for &o in procs {
			if o.used && o.noteid == p.pid {
				return .Err_Access
			}
		}
		p.sid, p.noteid = p.pid, p.pid // a session, and a note group, of its own
		return .Ok
	case cmd == "childnotes":
		p.childnotes = true
		return .Ok
	}
	st := dbg_ctl(p, cmd)
	return st == .Err_Not_Found ? .Err_Invalid : st
}

// Joins note group `group`: one that exists in p's session, or a new one
// named by p's own pid, as 9front's changenoteid allows.
@(private="file", require_results)
join_group :: proc "contextless" (p: ^Proc, group: u64) -> vx.Status {
	exists := group == p.pid
	for &o in procs {
		if exists {
			break
		}
		exists = o.used && o.noteid == group && o.sid == p.sid
	}
	if !exists {
		return .Err_Access
	}
	p.noteid = group
	return .Ok
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	p := proc_of(node)
	if p == nil {
		return 0, .Err_Not_Found
	}
	b := bits(node)
	if b.tid != 0 && Thread_File(b.file) == .Regs { // whole, at offset 0
		r: vx.Regs
		if len(data) != size_of(r) || offset != 0 {
			return 0, .Err_Invalid
		}
		copy(ptr_bytes(&r), data)
		return u32(len(data)), rt.thread_state(p.task, b.tid, .Set_Regs, &r)
	}
	if b.tid != 0 && Thread_File(b.file) == .Fpregs {
		fp: vx.Fpregs
		if len(data) != size_of(fp) || offset != 0 {
			return 0, .Err_Invalid
		}
		copy(ptr_bytes(&fp), data)
		return u32(len(data)), rt.thread_state(p.task, b.tid, .Set_Fpregs, &fp)
	}
	if b.tid == 0 && File(b.file) == .Mem {
		return mem_write(p, offset, data)
	}
	s := written(data)
	whole := u32(len(data)) // a command is the whole message
	if b.tid != 0 {
		#partial switch Thread_File(b.file) {
		case .Regs_Ndb:
			return whole, regs_ndb_write(p, b.tid, s)
		case .Ctl:
			return whole, thread_ctl(p, b.tid, s)
		}
		return 0, .Err_Access
	}
	#partial switch File(b.file) {
	case .Prof_Ctl:
		return whole, prof_ctl(p, s)
	case .Ctl:
		return whole, ctl(p, s)
	case .Note:
		if len(s) == 0 || len(s) > vx.ERRMAX {
			return 0, .Err_Invalid
		}
		return whole, post(p, s)
	case .Notepg:
		if len(s) == 0 || len(s) > vx.ERRMAX {
			return 0, .Err_Invalid
		}
		group := p.noteid
		for &o in procs {
			if o.used && o.noteid == group {
				_ = post(&o, s)
			}
		}
		return whole, .Ok
	case .Noteid:
		group, ok := parse_dec(s)
		if !ok || group == 0 {
			return 0, .Err_Invalid
		}
		return whole, join_group(p, group)
	}
	return 0, .Err_Access
}

// mem, written: a page at a time, as reads go; what was written before a page
// that cannot be is counted, not reported as nothing.
@(private="file")
mem_write :: proc "contextless" (p: ^Proc, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	@(static) buf: [rt.MSIZE]u8 // task_mem_rw's buffer is the caller's to read and write
	if p.root {
		return 0, .Err_Access
	}
	if len(data) > len(buf) {
		return 0, .Err_Invalid
	}
	copy(buf[:], data)
	done := 0
	for done < len(data) {
		at := offset + u64(done)
		n := min(len(data) - done, int(4096 - at & 4095))
		if wst := mem_rw(p, at, buf[done:][:n], true); wst != .Ok {
			if done == 0 {
				return 0, wst
			}
			break
		}
		done += n
	}
	return u32(done), .Ok
}

// The root's entries are the processes, in table order; a process's are its files.
@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	p := proc_of(dir)
	b := bits(dir)
	if dir != ROOT && b.tid == 0 && File(b.file) == .Threads { // the threads, by id
		if p == nil {
			return 0, .Err_Not_Found
		}
		ti: vx.Thread_Info
		for _ in 0 ..= index {
			rt.thread_state(p.task, ti.id, .Next_Thread, &ti) or_return
		}
		return node_of(p.pid, ti.id, u32(Thread_File.Dir)), .Ok
	}
	if dir != ROOT && b.tid == 0 && File(b.file) == .Prof { // ctl, zones
		if p == nil || index >= 2 {
			return 0, .Err_Not_Found
		}
		return node_of(p.pid, 0, u32(File.Prof_Ctl) + index), .Ok
	}
	if dir != ROOT {
		entries := b.tid != 0 ? u32(len(Thread_File)) : PROC_FILES
		if p == nil || index + 1 >= entries {
			return 0, .Err_Not_Found
		}
		return dir | p9.Node(index + 1), .Ok
	}
	seen: u32
	for &o in procs {
		if !o.used {
			continue
		}
		if seen == index {
			return node_of(o.pid, 0, u32(File.Dir)), .Ok
		}
		seen += 1
	}
	return 0, .Err_Not_Found
}

@(private="file")
conns: [MAX_PROCS]p9ring.Server_Conn // a connection for each process, at most

// Not file-private: tests/host drives its Fs and hooks on the host.
server := p9ring.Server {
	fs = {
		attach = fs_attach,
		walk = fs_walk,
		parent = fs_parent,
		stat = fs_stat,
		open = fs_open,
		read = fs_read,
		readdir = fs_readdir,
		write = fs_write,
	},
	name = "procfs",
	event = event,
	listen_msg = registered,
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	tasks := rt.spawn_take("tasks")
	nsd = rt.spawn_take("srv:nsd")
	tmpfs = rt.spawn_take("srv:tmpfs") // for crash directories
	server.listen = rt.spawn_take("listen")
	server.conns = conns[:]
	if me, st := rt.task_info(rt.self); st == .Ok {
		self_id = me.id
	}
	st := vx.Status.Err_Bad_Handle
	if tasks != vx.HANDLE_NONE && server.listen != vx.HANDLE_NONE {
		server.port, st = rt.port_create()
	}
	if st == .Ok {
		_, st = admit(tasks, 0, {}, 0, true)
	}
	if st != .Ok {
		rt.print("procfs: FAILED: no task tree or listen channel\n")
		return 1
	}
	return int(p9ring.serve(&server))
}
