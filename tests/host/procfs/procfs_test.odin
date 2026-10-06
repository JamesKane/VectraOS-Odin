// servers/procfs on the host: the program itself, linked against lib/rt,
// with a fake kernel underneath (fake_kernel.odin). Its vx_main sets itself
// up and returns at once, the listen channel being closed; its p9.Fs is then
// driven through lib/p9's server framework and client, as tests/host/p9_server
// does, and its listen and port hooks directly: a registration is a message
// handed to listen_msg, a task's end or fault a packet handed to event.
//
// Upstream has no host test for procfs; this is this tree's own, checking
// the files' text byte for byte against upstream's formats (procfs.c,
// debug.c, crash.c, prof.c at 002a9a8).
//
// Everything here is global (the program's state and the fake kernel), so
// it is one test, in steps that build on each other.
package procfs_test

import vx "abi:vx"
import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:p9"
import "vx:process"
import "vx:prof"
import "vx:rt"
import procfs "../../../servers/procfs"
import "../p9test"

when ODIN_ARCH == .amd64 {
	ARG0 :: "rdi"
	ARG1 :: "rsi"
	ARCH :: "x86_64"
	TRAP :: "\xcc"
	set_pc :: proc(r: ^vx.Regs, v: u64) {r.rip = v}
	get_pc :: proc(r: ^vx.Regs) -> u64 {return r.rip}
	set_arg0 :: proc(r: ^vx.Regs, v: u64) {r.rdi = v}
	get_arg1 :: proc(r: ^vx.Regs) -> u64 {return r.rsi}
	trap_pc :: proc(addr: u64) -> u64 {return addr + 1} // int3 reports the instruction after it
} else {
	ARG0 :: "x0"
	ARG1 :: "x1"
	ARCH :: "aarch64"
	TRAP :: "\x00\x00\x20\xd4"
	set_pc :: proc(r: ^vx.Regs, v: u64) {r.pc = v}
	get_pc :: proc(r: ^vx.Regs) -> u64 {return r.pc}
	set_arg0 :: proc(r: ^vx.Regs, v: u64) {r.x[0] = v}
	get_arg1 :: proc(r: ^vx.Regs) -> u64 {return r.x[1]}
	trap_pc :: proc(addr: u64) -> u64 {return addr}
}

// Host memory for a process's mappings: code with an ELF header and a build
// ID at 0x400000, data at 0x600000.
code_mem: [0x1000]u8
data_mem: [0x2000]u8

BUILD_ID :: "000102030405060708090a0b0c0d0e0f10111213"

put32 :: proc(b: []u8, off: int, v: u32) {
	(^u32le)(&b[off])^ = u32le(v)
}

put64 :: proc(b: []u8, off: int, v: u64) {
	(^u64le)(&b[off])^ = u64le(v)
}

// An ELF image's start: its header, a PT_LOAD and a PT_NOTE whose one note,
// at 0x400200, is a 20-byte GNU build ID.
make_image :: proc() {
	for &b, i in code_mem {
		b = u8(0x11 + i % 7)
	}
	copy(code_mem[:], "\x7fELF")
	put64(code_mem[:], 32, 64) // e_phoff
	(^u16le)(&code_mem[54])^ = 56 // e_phentsize
	(^u16le)(&code_mem[56])^ = 2 // e_phnum
	put32(code_mem[:], 64, 1) // PT_LOAD
	put32(code_mem[:], 120, 4) // PT_NOTE
	put64(code_mem[:], 120 + 16, 0x400200) // p_vaddr
	put64(code_mem[:], 120 + 32, 36) // p_filesz
	put32(code_mem[:], 0x200, 4) // namesz
	put32(code_mem[:], 0x204, 20) // descsz
	put32(code_mem[:], 0x208, 3) // NT_GNU_BUILD_ID
	copy(code_mem[0x20c:], "GNU\x00")
	for i in 0 ..< 20 {
		code_mem[0x210 + i] = u8(i)
	}
}

read_file :: proc(c: ^p9.Client, root: p9.Fid, path: string, buf: []u8) -> (string, vx.Status) {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return "", e
	}
	defer _ = p9.client_clunk(c, f)
	if e = p9.client_open(c, f, p9.OREAD); e != .Ok {
		return "", e
	}
	n: int
	n, e = p9.client_read(c, f, 0, buf)
	return string(buf[:max(n, 0)]), e
}

write_file :: proc(c: ^p9.Client, root: p9.Fid, path: string, data: string) -> (int, vx.Status) {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return 0, e
	}
	defer _ = p9.client_clunk(c, f)
	if e = p9.client_open(c, f, p9.OWRITE); e != .Ok {
		return 0, e
	}
	return p9.client_write(c, f, 0, transmute([]u8)data)
}

// A message on the listen channel, and procfs's reply.
listen :: proc(ordinal: u32, args: [3]i64, handle: vx.Handle, size := size_of(process.Msg)) -> (rep: process.Msg) {
	m := process.Msg {
		header = {txid = 77, ordinal = ordinal},
		arg = args,
	}
	clear(&reply)
	procfs.server.listen_msg(nil, ([^]u8)(&m)[:size], handle)
	copy(([^]u8)(&rep)[:size_of(rep)], reply[:])
	return
}

register :: proc(t: ^testing.T, id, ppid: u64, flags: process.Flags = {}, group: u64 = 0, loc := #caller_location) -> vx.Status {
	rep := listen(process.REGISTER, {i64(ppid), i64(transmute(u32)flags), i64(group)}, TASK_HANDLE + vx.Handle(id))
	testing.expect_value(t, rep.header.txid, 77, loc)
	testing.expect_value(t, rep.header.ordinal, process.REGISTER, loc)
	st := process.reply_status(&rep)
	if st == .Ok {
		testing.expect_value(t, rep.arg[0], i64(id), loc)
	}
	return st
}

// A file's text read straight from the Fs: what a held read would get.
fs_read :: proc(pid: u64, f: procfs.File, buf: []u8) -> (string, vx.Status) {
	n, st := procfs.server.fs.read(nil, procfs.node_of(pid, 0, u32(f)), 0, buf)
	return string(buf[:n]), st
}

note_text :: proc(t: ^Fake_Task, i: int) -> string {
	return i < len(t.notes) ? string(t.notes[i][:]) : "(none)"
}

// The registers of a thread stopped at an exception.
exception :: proc(kind: vx.Exception_Kind, pc: u64, code: u32 = 0, address: u64 = 0, arg0: u64 = 0) -> vx.Exception {
	e := vx.Exception{kind = kind, code = code, address = address}
	set_pc(&e.regs, pc)
	set_arg0(&e.regs, arg0)
	return e
}

@(test)
test_procfs :: proc(t: ^testing.T) {
	names: p9.Stat_Text
	make_image()
	add_task({id = 1, name = "svcd", state = .Running, blocked = 1, mapped = 412 * 1024, threads = {{id = 1, state = .Blocked}}})
	add_task({id = 2, name = "procfs", state = .Running, threads = {{id = 1, state = .Running}}})
	add_task({id = 7, name = "rc", state = .Running, blocked = 1, mapped = 412 * 1024, threads = {{id = 1, state = .Blocked}}})
	ls := add_task({id = 9, name = "ls", state = .Running, mapped = 1536, threads = {{id = 1, state = .Running}, {id = 2, state = .Blocked}}})
	_ = append(&ls.maps, Fake_Map{base = 0x400000, flags = {.Exec}, bytes = code_mem[:]})
	_ = append(&ls.maps, Fake_Map{base = 0x600000, flags = {.Write}, offset = 0x1000, bytes = data_mem[:]})
	_ = append(&ls.maps, Fake_Map{base = 0x700000, flags = {.Write}, bytes = ring_mem()})
	add_task({id = 11, name = "gone", state = .Exited})
	add_task({id = 12, name = "crasher", state = .Running, threads = {{id = 1, state = .Running}, {id = 2, state = .Blocked}}})
	add_task({id = 13, name = "victim", state = .New})
	add_task({id = 14, name = "a-very-long-task-name-24", state = .Running, threads = {{id = 1, state = .Running}}})

	// The spawn message svcd would send: "tasks", "listen", and nsd's post.
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "tasks", TASKS
	rt.spawn.handle_names[1], rt.spawn.handles[1] = "listen", LISTEN
	rt.spawn.handle_names[2], rt.spawn.handles[2] = "srv:nsd", NSD
	rt.spawn.handle_count = 3
	testing.expect_value(t, procfs.vx_main(), int(vx.Status.Err_Peer_Closed)) // set up, then no listen channel to serve
	testing.expect_value(t, procfs.server.listen, LISTEN)
	testing.expect_value(t, procfs.server.port, PORT)
	testing.expect_value(t, string(kernel_log[:]), "")
	testing.expect_value(t, task_by_id(1).exit_key, 0) // svcd's handle has no WAIT right: never bound

	// Registrations (vx:process): svcd's services first, as svcd does once
	// procfs serves; procfs itself among them.
	testing.expect_value(t, register(t, 2, 1, {.No_Wait, .Set_Sid}), vx.Status.Ok)
	testing.expect_value(t, task_by_id(2).exit_key != 0, true)
	testing.expect_value(t, task_by_id(2).crash_key, 0) // procfs's own faults are not its to take
	testing.expect_value(t, register(t, 7, 1, {.No_Wait, .Set_Sid}), vx.Status.Ok)
	testing.expect_value(t, register(t, 9, 7), vx.Status.Ok)
	testing.expect_value(t, ls.crash_key != 0, true)
	testing.expect_value(t, ls.crash_key != ls.exit_key, true)
	testing.expect_value(t, register(t, 9, 7), vx.Status.Err_Exists)
	testing.expect_value(t, ls.closed, true) // the second handle, refused
	ls.closed = false
	testing.expect_value(t, register(t, 11, 7), vx.Status.Err_Invalid) // exited
	testing.expect_value(t, task_by_id(11).closed, true)
	testing.expect_value(t, register(t, 13, 7, {}, 999), vx.Status.Err_Access) // no such group in its session
	testing.expect_value(t, register(t, 13, 7, {}, 1), vx.Status.Err_Access) // svcd's: another session
	testing.expect_value(t, register(t, 13, 7, {}, 7), vx.Status.Ok)
	testing.expect_value(t, register(t, 12, 7, {.Note_Group}), vx.Status.Ok)
	testing.expect_value(t, register(t, 14, 7, {.No_Wait}), vx.Status.Ok)
	{
		rep := listen(process.REGISTER, {7, 0, 0}, vx.HANDLE_NONE)
		testing.expect_value(t, process.reply_status(&rep), vx.Status.Err_Invalid) // no task
		rep = listen(process.REGISTER, {7, 0, 0}, TASK_HANDLE + 12, size = 20)
		testing.expect_value(t, process.reply_status(&rep), vx.Status.Err_Invalid) // too short
		rep = listen(0x1234, {7, 0, 0}, TASK_HANDLE + 12)
		testing.expect_value(t, process.reply_status(&rep), vx.Status.Err_Invalid) // not a call procfs takes
		testing.expect_value(t, rep.header.ordinal, process.REGISTER)
	}

	srv := p9.Server{fs = procfs.server.fs, max_msize = 8192}
	tbuf, rbuf: [8192]u8
	c := p9.Client{rpc = p9test.loopback, ctx = &srv, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {}), vx.Status.Ok)
	_, ae := p9.client_attach(&c, "1")
	testing.expect_value(t, ae, vx.Status.Err_Not_Found) // no aname
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)
	buf: [4096]u8
	text: string

	// The status records, byte for byte.
	Status_Case :: struct {
		path, want: string,
	}
	status_cases := []Status_Case {
		{"1/status", "pid=1 name=svcd state=waiting threads=1 mem=412K sid=1\n"},
		{"2/status", "pid=2 name=procfs state=running threads=1 mem=0K sid=2\n"},
		{"7/status", "pid=7 name=rc state=waiting threads=1 mem=412K sid=7\n"},
		{"9/status", "pid=9 name=ls state=running threads=2 mem=1K sid=7\n"},
		{"13/status", "pid=13 name=victim state=new threads=0 mem=0K sid=7\n"},
		// The name fills its field: no NUL.
		{"14/status", "pid=14 name=a-very-long-task-name-24 state=running threads=1 mem=0K sid=7\n"},
	}
	for sc in status_cases {
		text, e = read_file(&c, root, sc.path, buf[:])
		testing.expectf(t, e == .Ok && text == sc.want, "%s: got %q (%v)", sc.path, text, e)
	}
	// ppid and noteid: as they were registered.
	Number_Case :: struct {
		path, want: string,
	}
	number_cases := []Number_Case {
		{"1/ppid", "0"},
		{"9/ppid", "7"},
		{"7/noteid", "7"},
		{"9/noteid", "7"}, // its parent's
		{"13/noteid", "7"}, // the group it joined
		{"12/noteid", "12"}, // a group of its own (Note_Group)
		{"2/noteid", "2"}, // Set_Sid
		{"14/noteid", "7"},
	}
	for nc in number_cases {
		text, e = read_file(&c, root, nc.path, buf[:])
		testing.expectf(t, e == .Ok && text == nc.want, "%s: got %q (%v)", nc.path, text, e)
	}

	// A read at an offset, and past the end.
	{
		f, _ := p9.client_walk(&c, root, "7/status")
		_ = p9.client_open(&c, f, p9.OREAD)
		n, re := p9.client_read(&c, f, 11, buf[:2])
		testing.expect_value(t, re, vx.Status.Ok)
		testing.expect_value(t, string(buf[:n]), "rc")
		n, re = p9.client_read(&c, f, 1000, buf[:])
		testing.expect_value(t, re, vx.Status.Ok)
		testing.expect_value(t, n, 0)
		_ = p9.client_clunk(&c, f)
	}

	// The tree: processes in table order; a process's files; its threads; prof/.
	testing.expect_value(t, p9test.list(&c, root, ""), "1 2 7 9 13 12 14")
	testing.expect_value(t, p9test.list(&c, root, "9"), "status ctl note notepg noteid ppid wait ns events mem maps images info prof threads")
	testing.expect_value(t, p9test.list(&c, root, "9/threads"), "1 2")
	testing.expect_value(t, p9test.list(&c, root, "9/threads/2"), "status regs regs.ndb fpregs xregs ctl")
	testing.expect_value(t, p9test.list(&c, root, "9/prof"), "ctl zones")

	// Names that are not processes, threads or files.
	for path in ([]string{"4", "11", "01", "0", "1x", "-1", "99999999999999999999", "status", "9/foo", "9/status/x", "9/threads/3", "9/threads/01", "9/threads/0", "9/prof/x", "9/threads/1/foo", "9/zones"}) {
		_, we := p9.client_walk(&c, root, path)
		testing.expectf(t, we == .Err_Not_Found, "%s: %v", path, we)
	}
	// .. from each kind of node.
	Parent_Case :: struct {
		path, want: string,
	}
	parent_cases := []Parent_Case {
		{"9/status/..", "9"},
		{"9/..", "/"},
		{"9/threads/1/..", "threads"},
		{"9/threads/1/regs/..", "1"},
		{"9/prof/zones/..", "prof"},
		{"9/prof/..", "9"},
	}
	for pc in parent_cases {
		f, we := p9.client_walk(&c, root, pc.path)
		st: p9.Stat
		if we == .Ok {
			we = p9.client_stat(&c, f, &st, &names)
			_ = p9.client_clunk(&c, f)
		}
		testing.expectf(t, we == .Ok && st.name == pc.want, "%s: %q (%v)", pc.path, st.name, we)
	}

	// Stats: qid paths are pid << 32 | thread << 8 | file.
	st: p9.Stat
	testing.expect_value(t, p9test.stat_of(&c, root, "", &st, &names), vx.Status.Ok)
	testing.expect_value(t, st.name, "/")
	testing.expect_value(t, st.mode, p9.DMDIR | 0o555)
	testing.expect_value(t, st.qid, p9.Qid{type = p9.QTDIR, path = 1})
	testing.expect_value(t, st.uid, "proc")
	testing.expect_value(t, st.gid, "proc")
	testing.expect_value(t, st.muid, "proc")
	Stat_Case :: struct {
		path, name: string,
		mode:       u32,
		qid:        p9.Qid,
	}
	stat_cases := []Stat_Case {
		{"9", "9", p9.DMDIR | 0o555, {type = p9.QTDIR, path = 9 << 32}},
		{"9/status", "status", 0o444, {type = p9.QTFILE, path = 9 << 32 | 1}},
		{"9/ctl", "ctl", 0o222, {type = p9.QTFILE, path = 9 << 32 | 2}},
		{"9/noteid", "noteid", 0o664, {type = p9.QTFILE, path = 9 << 32 | 5}},
		{"9/mem", "mem", 0o664, {type = p9.QTFILE, path = 9 << 32 | 10}},
		{"9/prof", "prof", p9.DMDIR | 0o555, {type = p9.QTDIR, path = 9 << 32 | 14}},
		{"9/threads", "threads", p9.DMDIR | 0o555, {type = p9.QTDIR, path = 9 << 32 | 15}},
		{"9/prof/ctl", "ctl", 0o222, {type = p9.QTFILE, path = 9 << 32 | 17}},
		{"9/prof/zones", "zones", 0o444, {type = p9.QTFILE, path = 9 << 32 | 18}},
		{"9/threads/2", "2", p9.DMDIR | 0o555, {type = p9.QTDIR, path = 9 << 32 | 2 << 8}},
		{"9/threads/2/regs.ndb", "regs.ndb", 0o664, {type = p9.QTFILE, path = 9 << 32 | 2 << 8 | 3}},
		{"9/threads/2/ctl", "ctl", 0o222, {type = p9.QTFILE, path = 9 << 32 | 2 << 8 | 6}}, // after xregs (ADR-0035), as upstream's
	}
	for sc in stat_cases {
		s: p9.Stat
		se := p9test.stat_of(&c, root, sc.path, &s, &names)
		testing.expectf(t, se == .Ok && s.name == sc.name && s.mode == sc.mode && s.qid == sc.qid, "%s: %v %q %o %v", sc.path, se, s.name, s.mode, s.qid)
	}

	// Open modes, from each file's permissions; nothing removed on clunk.
	open_mode :: proc(c: ^p9.Client, root: p9.Fid, path: string, mode: p9.Open_Mode) -> vx.Status {
		f, _ := p9.client_walk(c, root, path)
		defer _ = p9.client_clunk(c, f)
		return p9.client_open(c, f, mode)
	}
	Open_Case :: struct {
		path: string,
		mode: p9.Open_Mode,
		want: vx.Status,
	}
	open_cases := []Open_Case {
		{"9/status", p9.OWRITE, .Err_Access},
		{"9/status", p9.ORDWR, .Err_Access},
		{"9/status", {access = .Read, rclose = true}, .Err_Access},
		{"9/status", p9.OEXEC, .Ok},
		{"9/ctl", p9.OREAD, .Err_Access},
		{"9/ctl", p9.ORDWR, .Err_Access},
		{"9/ctl", {access = .Write, trunc = true}, .Ok}, // trunc means nothing here
		{"9/noteid", p9.ORDWR, .Ok},
		{"9/mem", p9.ORDWR, .Ok},
		{"9", p9.OREAD, .Ok},
		{"9", p9.OWRITE, .Err_Access},
		{"", p9.OEXEC, .Err_Access}, // the root: only read
		{"9/threads/1/regs", p9.ORDWR, .Ok},
		{"9/threads/1/ctl", p9.OREAD, .Err_Access},
	}
	for oc in open_cases {
		got := open_mode(&c, root, oc.path, oc.mode)
		testing.expectf(t, got == oc.want, "%s %v: %v", oc.path, oc.mode, got)
	}

	// /proc/N/ns: from nsd; nothing for a process in no group.
	text, e = read_file(&c, root, "9/ns", buf[:])
	testing.expect_value(t, text, NS_TEXT)
	text, e = read_file(&c, root, "7/ns", buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, text, "")

	// Notes: posted with thread_interrupt; never to svcd; 1 to ERRMAX bytes.
	n: int
	n, e = write_file(&c, root, "9/note", "hello\n")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, n, 6) // the whole message
	testing.expect_value(t, note_text(ls, 0), "hello")
	_, e = write_file(&c, root, "1/note", "hangup")
	testing.expect_value(t, e, vx.Status.Err_Access)
	_, e = write_file(&c, root, "9/note", "\n")
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	_, e = write_file(&c, root, "9/note", strings.repeat("x", vx.ERRMAX + 1, context.temp_allocator))
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	_, e = write_file(&c, root, "9/note", strings.repeat("x", vx.ERRMAX, context.temp_allocator))
	testing.expect_value(t, e, vx.Status.Ok)
	// notepg: every process in the writer's group, the writer too.
	shell := task_by_id(7)
	clear(&shell.notes)
	clear(&ls.notes)
	_, e = write_file(&c, root, "9/notepg", "group")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, note_text(shell, 0), "group")
	testing.expect_value(t, note_text(ls, 0), "group")
	testing.expect_value(t, len(task_by_id(12).notes), 0) // a group of its own
	testing.expect_value(t, len(task_by_id(14).notes), 1)
	testing.expect_value(t, len(task_by_id(2).notes), 0)
	// The signals procfs carries out: SIGSTOP stops, SIGCONT continues and is delivered.
	clear(&ls.notes)
	_, e = write_file(&c, root, "9/note", "posix: SIGSTOP pid=7")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, ls.suspends, 1)
	testing.expect_value(t, len(ls.notes), 0)
	text, _ = read_file(&c, root, "9/status", buf[:])
	testing.expect_value(t, text, "pid=9 name=ls state=stopped threads=2 mem=1K sid=7\n")
	_, e = write_file(&c, root, "9/note", "posix: SIGCONT pid=7")
	testing.expect_value(t, ls.suspends, 0)
	testing.expect_value(t, note_text(ls, 0), "posix: SIGCONT pid=7")

	// ctl: stop [SIG] and start; their errors; never svcd.
	Ctl_Case :: struct {
		path, cmd: string,
		want:      vx.Status,
	}
	ctl_cases := []Ctl_Case {
		{"9/ctl", "stop 0", .Err_Invalid},
		{"9/ctl", "stop 65", .Err_Invalid},
		{"9/ctl", "stop x", .Err_Invalid},
		{"9/ctl", "stopped", .Err_Invalid},
		{"9/ctl", "bogus", .Err_Invalid},
		{"9/ctl", " kill", .Err_Invalid},
		{"1/ctl", "kill\n", .Err_Access},
		{"1/ctl", "stop", .Err_Access},
		{"1/ctl", "break 0x1000", .Err_Access},
		{"1/ctl", "step 1", .Err_Access},
		{"1/mem", "x", .Err_Access},
		{"9/ctl", "step 0", .Err_Invalid},
		{"9/ctl", "step 4294967296", .Err_Invalid},
		{"9/ctl", "step 2", .Err_Bad_State}, // not stopped at an event
		{"9/threads/2/ctl", "resume", .Err_Bad_State},
		{"9/threads/2/ctl", "sideways", .Err_Invalid},
		{"9/ctl", "unbreak 0x1000", .Err_Invalid}, // ctl's word for a debug verb's Err_Not_Found
		{"9/ctl", "unwatch 0x1000", .Err_Invalid},
		{"9/ctl", "break", .Err_Invalid},
		{"9/ctl", "break 0x400100 if", .Err_Invalid},
		{"9/ctl", "break 0x400100 if x99==1", .Err_Invalid},
		{"9/ctl", "break 0x400100 if [0x10]=1", .Err_Invalid},
		{"9/ctl", "break 0x400100 when", .Err_Invalid},
		{"9/ctl", "watch 0x600008 8 read", .Err_Invalid},
		{"9/noteid", "0", .Err_Invalid},
		{"9/noteid", "999999", .Err_Access}, // no such group
	}
	for cc in ctl_cases {
		_, ce := write_file(&c, root, cc.path, cc.cmd)
		testing.expectf(t, ce == cc.want, "%s %q: %v", cc.path, cc.cmd, ce)
	}
	testing.expect_value(t, task_by_id(1).state, vx.Task_State.Running)
	_, e = write_file(&c, root, "9/ctl", "stop 15")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, ls.suspends, 1)
	_, e = write_file(&c, root, "9/ctl", "stop")
	testing.expect_value(t, ls.suspends, 1) // once
	_, e = write_file(&c, root, "9/ctl", "start\n")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, ls.suspends, 0)

	// noteid: a group in its session, or one of its own.
	_, e = write_file(&c, root, "9/noteid", "12")
	testing.expect_value(t, e, vx.Status.Ok)
	_, e = write_file(&c, root, "9/noteid", "9")
	testing.expect_value(t, e, vx.Status.Ok)
	text, _ = read_file(&c, root, "9/noteid", buf[:])
	testing.expect_value(t, text, "9")
	_, e = write_file(&c, root, "9/noteid", "1")
	testing.expect_value(t, e, vx.Status.Err_Access) // svcd's: another session
	_, e = write_file(&c, root, "9/noteid", "7")
	testing.expect_value(t, e, vx.Status.Ok)
	// setsid: not while a group is the caller's pid.
	_, e = write_file(&c, root, "7/ctl", "setsid")
	testing.expect_value(t, e, vx.Status.Err_Access)

	// Wait records: none yet, but children that will leave one; a note ends
	// a held wait read, after the note.
	_, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_Should_Wait)
	_, e = write_file(&c, root, "7/note", "interrupt")
	testing.expect_value(t, e, vx.Status.Ok)
	_, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_Interrupted)
	_, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_Should_Wait)
	_, e = fs_read(9, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_No_Child) // it has none
	_, e = fs_read(1, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_No_Child) // svcd: its children were registered with No_Wait

	// childnotes: records of a child's stops and continues, and SIGCHLD.
	_, e = write_file(&c, root, "7/ctl", "childnotes")
	testing.expect_value(t, e, vx.Status.Ok)
	clear(&shell.notes)
	now += 3_000_000
	_, e = write_file(&c, root, "9/ctl", "stop 20")
	testing.expect_value(t, note_text(shell, 0), "posix: SIGCHLD pid=9")
	_, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_Interrupted) // the note ended the read held for 7
	_, e = write_file(&c, root, "9/ctl", "start")
	testing.expect_value(t, note_text(shell, 1), "posix: SIGCHLD pid=9")
	_ = p9test.stat_of(&c, root, "7/wait", &st, &names)
	testing.expect_value(t, st.length, 2) // as 9front's: records queued
	text, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, text, "pid=9 name=ls noteid=7 stopped=20\n")
	text, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, text, "pid=9 name=ls noteid=7 continued\n")

	// A child's end: its record, with its exit string and how long it ran.
	victim := task_by_id(13)
	now += 12_000_000
	_, e = write_file(&c, root, "13/note", "posix: SIGKILL pid=7")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, string(victim.exit[:]), "killed")
	fire_exit(victim)
	testing.expect_value(t, victim.closed, true)
	_, e = p9.client_walk(&c, root, "13")
	testing.expect_value(t, e, vx.Status.Err_Not_Found) // gone
	text, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, text, "pid=13 name=victim noteid=7 status=killed real=15\n")
	testing.expect_value(t, note_text(shell, 2), "posix: SIGCHLD pid=13")
	// A child registered with No_Wait leaves none.
	long := task_by_id(14)
	_, e = write_file(&c, root, "14/ctl", "kill")
	fire_exit(long)
	_ = p9test.stat_of(&c, root, "7/wait", &st, &names)
	testing.expect_value(t, st.length, 0)
	// A packet about a slot whose process has gone is ignored.
	fire_exit(long)

	// --- The debug files ---

	// maps, images and info, byte for byte.
	text, _ = read_file(&c, root, "9/maps", buf[:])
	testing.expect_value(t, text, "base=0x400000 size=0x1000 prot=r-x offset=0x0\nbase=0x600000 size=0x2000 prot=rw- offset=0x1000\nbase=0x700000 size=0x109000 prot=rw- offset=0x0\n")
	text, _ = read_file(&c, root, "9/images", buf[:])
	testing.expect_value(t, text, "name=ls base=0x400000 build-id=" + BUILD_ID + "\n")
	text, _ = read_file(&c, root, "9/info", buf[:])
	testing.expect_value(t, text, "arch=" + ARCH + " watchpoints=4 breakpoints=32\n")
	text, _ = read_file(&c, root, "7/maps", buf[:])
	testing.expect_value(t, text, "")
	text, _ = read_file(&c, root, "7/images", buf[:])
	testing.expect_value(t, text, "")

	// mem: a page at a time; a hole ends a read where it starts.
	{
		copy(data_mem[0x10:], "data")
		f, _ := p9.client_walk(&c, root, "9/mem")
		_ = p9.client_open(&c, f, p9.ORDWR)
		n, e = p9.client_read(&c, f, 0x600010, buf[:4])
		testing.expect_value(t, e, vx.Status.Ok)
		testing.expect_value(t, string(buf[:n]), "data")
		n, e = p9.client_read(&c, f, 0x601ffc, buf[:16]) // runs off the mapping's end
		testing.expect_value(t, e, vx.Status.Ok)
		testing.expect_value(t, n, 4)
		n, e = p9.client_read(&c, f, 0x500000, buf[:16])
		testing.expect_value(t, e, vx.Status.Err_Invalid) // the hole itself: an error, not the end
		n, e = p9.client_write(&c, f, 0x600ffe, transmute([]u8)string("abcd")) // across a page
		testing.expect_value(t, e, vx.Status.Ok)
		testing.expect_value(t, n, 4)
		testing.expect_value(t, string(data_mem[0xffe:][:4]), "abcd")
		n, e = p9.client_write(&c, f, 0x601ffe, transmute([]u8)string("wxyz")) // what fits is counted
		testing.expect_value(t, e, vx.Status.Ok)
		testing.expect_value(t, n, 2)
		n, e = p9.client_write(&c, f, 0x500000, transmute([]u8)string("wxyz"))
		testing.expect_value(t, e, vx.Status.Err_Not_Found) // nothing written: the kernel's word
		_ = p9.client_clunk(&c, f)
	}

	// A thread's registers: only while it holds still.
	_, e = read_file(&c, root, "9/threads/1/regs", buf[:])
	testing.expect_value(t, e, vx.Status.Err_Bad_State) // running
	text, e = read_file(&c, root, "9/threads/1/status", buf[:])
	testing.expect_value(t, text, "state=running\n")
	text, e = read_file(&c, root, "9/threads/2/status", buf[:])
	testing.expect_value(t, text, "state=blocked\n")

	// A breakpoint with a condition: the trap written, procfs bound first.
	BP :: 0x400100
	orig := [4]u8{code_mem[0x100], code_mem[0x101], code_mem[0x102], code_mem[0x103]}
	_, e = write_file(&c, root, "9/ctl", "break 0x400100 if " + ARG0 + "==3\n")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, ls.debug_key != 0, true)
	testing.expect_value(t, string(code_mem[0x100:][:len(TRAP)]), TRAP)
	// Hit with the condition false: stepped over at once, the code back for
	// the step and the trap again after it; no event.
	th1 := thread_of(ls, 1)
	fire_exception(ls, 1, exception(.Breakpoint, trap_pc(BP), arg0 = 2))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Step)
	testing.expect_value(t, get_pc(&th1.regs), u64(BP)) // back at the instruction the trap replaced
	testing.expect_value(t, code_mem[0x100], orig[0])
	fire_exception(ls, 1, exception(.Step, BP + 4))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Continue)
	testing.expect_value(t, string(code_mem[0x100:][:len(TRAP)]), TRAP)
	_ = p9test.stat_of(&c, root, "9/events", &st, &names)
	testing.expect_value(t, st.length, 0)
	// Hit with it true: an event, and the thread held.
	fire_exception(ls, 1, exception(.Breakpoint, trap_pc(BP), arg0 = 3))
	testing.expect_value(t, th1.resumed, vx.Resume_Action(0))
	_ = p9test.stat_of(&c, root, "9/events", &st, &names)
	testing.expect_value(t, st.length, 1)
	text, e = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=break thread=1 pc=0x400100\n")
	_, e = fs_read(9, .Events, buf[:])
	testing.expect_value(t, e, vx.Status.Err_Should_Wait) // one record a read
	text, _ = read_file(&c, root, "9/threads/1/status", buf[:])
	testing.expect_value(t, text, "state=stopped reason=break pc=0x400100\n")
	text, _ = read_file(&c, root, "9/threads/1/regs.ndb", buf[:])
	testing.expect_value(t, strings.contains(text, " " + ARG0 + "=0x3 ") || strings.has_prefix(text, ARG0 + "=0x3 "), true)
	{
		f, _ := p9.client_walk(&c, root, "9/threads/1/regs")
		_ = p9.client_open(&c, f, p9.ORDWR)
		r: vx.Regs
		n, e = p9.client_read(&c, f, 0, ([^]u8)(&r)[:size_of(r)])
		testing.expect_value(t, n, size_of(vx.Regs))
		testing.expect_value(t, get_pc(&r), u64(BP))
		set_arg0(&r, 5)
		n, e = p9.client_write(&c, f, 0, ([^]u8)(&r)[:size_of(r)])
		testing.expect_value(t, e, vx.Status.Ok)
		n, e = p9.client_write(&c, f, 0, ([^]u8)(&r)[:8])
		testing.expect_value(t, e, vx.Status.Err_Invalid) // whole, at 0
		_ = p9.client_clunk(&c, f)
	}
	text, _ = read_file(&c, root, "9/threads/1/fpregs", buf[:])
	testing.expect_value(t, len(text), size_of(vx.Fpregs))
	// xregs: the whole state, .Get_Cpu's xstate_size; written whole, at 0.
	{
		xs: [FAKE_XSTATE_SIZE]u8
		for &b, i in xs {
			b = u8(i * 7)
		}
		_, e = write_file(&c, root, "9/threads/1/xregs", string(xs[:]))
		testing.expect_value(t, e, vx.Status.Ok)
		testing.expect_value(t, th1.xstate[FAKE_XSTATE_SIZE - 1], xs[FAKE_XSTATE_SIZE - 1])
		_, e = write_file(&c, root, "9/threads/1/xregs", string(xs[:16]))
		testing.expect_value(t, e, vx.Status.Err_Invalid) // whole, at 0
		text, _ = read_file(&c, root, "9/threads/1/xregs", buf[:])
		testing.expect_value(t, len(text), FAKE_XSTATE_SIZE)
		testing.expect_value(t, text[100], xs[100])
	}
	_, e = write_file(&c, root, "9/threads/1/regs.ndb", ARG1 + "=0x7 " + ARG0 + "=12\n")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, get_arg1(&th1.regs), 7)
	_, e = write_file(&c, root, "9/threads/1/regs.ndb", "nosuch=1")
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	_, e = write_file(&c, root, "9/threads/1/regs.ndb", ARG1)
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	// A step the debugger asks for: over the breakpoint, then an event.
	_, e = write_file(&c, root, "9/threads/1/ctl", "step")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Step)
	testing.expect_value(t, code_mem[0x100], orig[0])
	text, _ = read_file(&c, root, "9/threads/1/status", buf[:])
	testing.expect_value(t, text, "state=running reason=step\n")
	_, e = write_file(&c, root, "9/ctl", "step 1")
	testing.expect_value(t, e, vx.Status.Err_Bad_State) // stepping already
	fire_exception(ls, 1, exception(.Step, BP + 4))
	testing.expect_value(t, string(code_mem[0x100:][:len(TRAP)]), TRAP)
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=step thread=1 pc=0x400104\n")
	// start: let go.
	_, e = write_file(&c, root, "9/ctl", "start")
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Continue)
	// after N: N hits go by.
	_, e = write_file(&c, root, "9/ctl", "break 0x400100 after 1")
	testing.expect_value(t, e, vx.Status.Ok)
	fire_exception(ls, 1, exception(.Breakpoint, trap_pc(BP)))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Step)
	fire_exception(ls, 1, exception(.Step, BP + 4))
	fire_exception(ls, 1, exception(.Breakpoint, trap_pc(BP)))
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=break thread=1 pc=0x400100\n")
	// unbreak while held at it: the code back, the thread held with nothing to step over.
	_, e = write_file(&c, root, "9/ctl", "unbreak 0x400100")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, code_mem[0x100], orig[0])
	text, _ = read_file(&c, root, "9/threads/1/status", buf[:])
	testing.expect_value(t, text, "state=stopped reason=step pc=0x400100\n")
	_, e = write_file(&c, root, "9/threads/1/ctl", "resume")
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Continue)
	// A condition on memory.
	put64(data_mem[:], 0x20, 100)
	_, e = write_file(&c, root, "9/ctl", "break 0x400100 if [0x600020]>=101")
	testing.expect_value(t, e, vx.Status.Ok)
	fire_exception(ls, 1, exception(.Breakpoint, trap_pc(BP)))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Step) // 100: not this time
	fire_exception(ls, 1, exception(.Step, BP + 4))
	put64(data_mem[:], 0x20, 101)
	fire_exception(ls, 1, exception(.Breakpoint, trap_pc(BP)))
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=break thread=1 pc=0x400100\n")
	_, e = write_file(&c, root, "9/ctl", "start")
	fire_exception(ls, 1, exception(.Step, BP + 4))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Continue)

	// The program's own trap; a fault; a note: what each does.
	fire_exception(ls, 2, exception(.Breakpoint, 0x400205))
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=trap thread=2 pc=0x400205\n")
	_, e = write_file(&c, root, "9/threads/2/ctl", "resume")
	testing.expect_value(t, thread_of(ls, 2).resumed, vx.Resume_Action.Pass) // to the program's handler
	fire_exception(ls, 1, exception(.Page_Fault, 0x400200, code = 0, address = 0x10))
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=fault thread=1 pc=0x400200 addr=0x10 access=read\n")
	_, e = write_file(&c, root, "9/ctl", "start")
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Pass) // the fault, passed on
	fire_exception(ls, 1, exception(.Page_Fault, 0x400200, code = 1, address = 0x20))
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=fault thread=1 pc=0x400200 addr=0x20 access=write\n")
	_, e = write_file(&c, root, "9/ctl", "start")
	fire_exception(ls, 1, exception(.Illegal, 0x400200))
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=fault thread=1 pc=0x400200 addr=0x0\n")
	_, e = write_file(&c, root, "9/ctl", "start")
	fire_exception(ls, 1, exception(.Interrupt, 0x400200))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Pass)
	_ = p9test.stat_of(&c, root, "9/events", &st, &names)
	testing.expect_value(t, st.length, 0)

	// A watchpoint: the task's debug registers; stepped past with them off.
	_, e = write_file(&c, root, "9/ctl", "watch 0x600009 8 write")
	testing.expect_value(t, e, vx.Status.Err_Invalid) // not aligned: refused
	testing.expect_value(t, ls.watches.slot[0].kind, vx.Watch_Kind.Off)
	_, e = write_file(&c, root, "9/ctl", "watch 0x600008 8 write")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, ls.watches.slot[0], vx.Watch{address = 0x600008, len = 8, kind = .Write})
	_, e = write_file(&c, root, "9/ctl", "watch 0x600010 4 rw")
	testing.expect_value(t, ls.watches.slot[1], vx.Watch{address = 0x600010, len = 4, kind = .Rw})
	_, e = write_file(&c, root, "9/ctl", "watch 0x600008 4 rw") // the same address: replaced
	testing.expect_value(t, ls.watches.slot[0], vx.Watch{address = 0x600008, len = 4, kind = .Rw})
	fire_exception(ls, 1, exception(.Watchpoint, 0x400300, code = 1, address = 0x600010))
	text, _ = fs_read(9, .Events, buf[:])
	testing.expect_value(t, text, "event=watch thread=1 pc=0x400300 addr=0x600010 access=rw\n")
	text, _ = read_file(&c, root, "9/threads/1/status", buf[:])
	testing.expect_value(t, text, "state=stopped reason=watch pc=0x400300\n")
	_, e = write_file(&c, root, "9/ctl", "start")
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Step)
	testing.expect_value(t, ls.watches.slot[0].kind, vx.Watch_Kind.Off) // off for the step
	fire_exception(ls, 1, exception(.Step, 0x400304))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Continue)
	testing.expect_value(t, ls.watches.slot[1].kind, vx.Watch_Kind.Rw) // back
	_, e = write_file(&c, root, "9/ctl", "unwatch 0x600010")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, ls.watches.slot[1].kind, vx.Watch_Kind.Off)

	// detach: every breakpoint out, the binding gone; an exception queued
	// before it is let go as if no debugger had been there.
	_, e = write_file(&c, root, "9/ctl", "break 0x400100")
	testing.expect_value(t, e, vx.Status.Ok)
	key := ls.debug_key
	_, e = write_file(&c, root, "9/ctl", "detach")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, code_mem[0x100], orig[0])
	testing.expect_value(t, ls.debug_key, 0)
	testing.expect_value(t, ls.watches.slot[0].kind, vx.Watch_Kind.Off)
	ls.debug_key = key // as it was bound
	fire_exception(ls, 1, exception(.Breakpoint, trap_pc(BP)))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Continue) // the trap gone: run the instruction
	testing.expect_value(t, get_pc(&th1.regs), u64(BP))
	fire_exception(ls, 1, exception(.Page_Fault, 0x400200))
	testing.expect_value(t, th1.resumed, vx.Resume_Action.Pass)
	ls.debug_key = 0
	// Opening events binds again: a reader of events is a debugger.
	{
		f, _ := p9.client_walk(&c, root, "9/events")
		testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
		_ = p9.client_clunk(&c, f)
		testing.expect_value(t, ls.debug_key != 0, true)
		f, _ = p9.client_walk(&c, root, "1/events")
		testing.expect_value(t, p9.client_open(&c, f, p9.OREAD), vx.Status.Ok)
		_ = p9.client_clunk(&c, f)
		testing.expect_value(t, task_by_id(1).debug_key, 0) // not svcd's
	}

	// --- All-stop (upstream's 6d6a) ---
	// When a thread stops with an event, every other thread of the task is
	// frozen, each by its own thread_suspend, and thawed when the stopped one
	// is let go. Here with 18 threads, more than the 16 procfs followed
	// before, the last blocked in a call.
	many := add_task({id = 16, name = "many", state = .Running})
	_ = append(&many.maps, Fake_Map{base = 0x400000, flags = {.Exec}, bytes = code_mem[:]})
	for i in u32(1) ..= 18 {
		_ = append(&many.threads, Fake_Thread{id = i, state = i == 18 ? .Blocked : .Running})
	}
	testing.expect_value(t, register(t, 16, 1, {.No_Wait}), vx.Status.Ok)
	frozen :: proc(task: ^Fake_Task) -> (n: int) {
		for th in task.threads {
			n += th.suspends > 0 ? 1 : 0
		}
		return
	}
	ABP :: 0x400180
	orig_180 := code_mem[0x180]
	_, e = write_file(&c, root, "16/ctl", "break 0x400180")
	testing.expect_value(t, e, vx.Status.Ok)
	// Each thread stops at it in turn: the others frozen while it is held,
	// and while it steps over the breakpoint; all thawed once it is past.
	for i in u32(1) ..= 17 {
		th := thread_of(many, i)
		fire_exception(many, i, exception(.Breakpoint, trap_pc(ABP)))
		testing.expectf(t, frozen(many) == 17 && th.suspends == 0, "thread %d: %d others frozen", i, frozen(many))
		text, _ = fs_read(16, .Events, buf[:])
		testing.expect_value(t, text, fmt.tprintf("event=break thread=%d pc=0x400180\n", i))
		_, e = write_file(&c, root, "16/ctl", "start")
		testing.expect_value(t, th.resumed, vx.Resume_Action.Step)
		testing.expect_value(t, frozen(many), 17) // none runs past it while its trap is out
		fire_exception(many, i, exception(.Step, ABP + 4))
		testing.expect_value(t, th.resumed, vx.Resume_Action.Continue)
		testing.expect_value(t, frozen(many), 0)
	}
	// Two threads stopped at once: the second's exception came while it was
	// frozen, so it is thawed and held; ctl's start lets nothing go while its
	// event is unread, then lets both go, the others thawed once both are past.
	fire_exception(many, 3, exception(.Breakpoint, trap_pc(ABP)))
	fire_exception(many, 5, exception(.Breakpoint, trap_pc(ABP)))
	testing.expect_value(t, thread_of(many, 5).suspends, 0)
	testing.expect_value(t, frozen(many), 16)
	text, _ = read_file(&c, root, "16/threads/18/status", buf[:])
	testing.expect_value(t, text, "state=frozen\n") // suspended while blocked in a call
	text, _ = fs_read(16, .Events, buf[:])
	testing.expect_value(t, text, "event=break thread=3 pc=0x400180\n")
	_, e = write_file(&c, root, "16/ctl", "start")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, thread_of(many, 3).resumed, vx.Resume_Action(0)) // 5's stop first
	text, _ = fs_read(16, .Events, buf[:])
	testing.expect_value(t, text, "event=break thread=5 pc=0x400180\n")
	_, e = write_file(&c, root, "16/ctl", "start")
	testing.expect_value(t, thread_of(many, 3).resumed, vx.Resume_Action.Step)
	testing.expect_value(t, thread_of(many, 5).resumed, vx.Resume_Action.Step)
	fire_exception(many, 3, exception(.Step, ABP + 4))
	testing.expect_value(t, frozen(many), 16) // 5 still has the trap out
	testing.expect_value(t, code_mem[0x180], orig_180) // not back in 5's way
	fire_exception(many, 5, exception(.Step, ABP + 4))
	testing.expect_value(t, frozen(many), 0)
	testing.expect_value(t, string(code_mem[0x180:][:len(TRAP)]), TRAP) // back, both past it
	// A step of the stopped thread leaves the others frozen; its resume
	// thaws them. A freeze of the debugger's own outlasts all-stop's.
	_, e = write_file(&c, root, "16/ctl", "freeze 7")
	testing.expect_value(t, e, vx.Status.Ok)
	fire_exception(many, 2, exception(.Breakpoint, trap_pc(ABP)))
	_, _ = fs_read(16, .Events, buf[:])
	testing.expect_value(t, thread_of(many, 7).suspends, 2)
	_, e = write_file(&c, root, "16/threads/2/ctl", "step")
	testing.expect_value(t, e, vx.Status.Ok)
	fire_exception(many, 2, exception(.Step, ABP + 4))
	text, _ = fs_read(16, .Events, buf[:])
	testing.expect_value(t, text, "event=step thread=2 pc=0x400184\n")
	testing.expect_value(t, frozen(many), 17)
	_, e = write_file(&c, root, "16/threads/2/ctl", "resume")
	testing.expect_value(t, thread_of(many, 2).resumed, vx.Resume_Action.Continue)
	testing.expect_value(t, frozen(many), 1)
	testing.expect_value(t, thread_of(many, 7).suspends, 1) // its own freeze
	_, e = write_file(&c, root, "16/ctl", "thaw 7")
	testing.expect_value(t, frozen(many), 0)
	// detach with a thread held: it and the others go on, and the
	// debugger's tables are let go.
	fire_exception(many, 4, exception(.Breakpoint, trap_pc(ABP)))
	testing.expect_value(t, frozen(many), 17)
	_, e = write_file(&c, root, "16/ctl", "detach")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, frozen(many), 0)
	testing.expect_value(t, thread_of(many, 4).resumed, vx.Resume_Action.Continue)
	testing.expect_value(t, vmo_unmapped, vmo_pool_used)
	_, e = write_file(&c, root, "16/ctl", "kill")
	fire_exit(many)

	// --- Profiling zones ---

	// A ring given in another's name: procfs's challenge does not show at
	// the address claimed. Then the process's own, at the right address.
	hdr := (^prof.Header)(&ring_words)
	hdr^ = {magic = prof.MAGIC, version = 1, counter_hz = 24_000_000, cap = 0}
	rep := listen(process.PROF, {9, 0x600000, 0}, RING_VMO)
	testing.expect_value(t, rep.header.ordinal, process.PROF)
	testing.expect_value(t, process.reply_status(&rep), vx.Status.Err_Access)
	rep = listen(process.PROF, {99, 0x700000, 0}, RING_VMO)
	testing.expect_value(t, process.reply_status(&rep), vx.Status.Err_Not_Found) // no such process
	_, e = write_file(&c, root, "9/prof/ctl", "zones on")
	testing.expect_value(t, e, vx.Status.Err_Not_Found) // no ring yet
	rep = listen(process.PROF, {9, 0x700000, 0}, RING_VMO)
	testing.expect_value(t, process.reply_status(&rep), vx.Status.Ok)
	testing.expect_value(t, hdr.nonce & 1, 1) // procfs's challenge, odd
	_, e = write_file(&c, root, "9/prof/ctl", "zones on\n")
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, hdr.enabled, 1)
	_, e = write_file(&c, root, "9/prof/ctl", "zones sideways")
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	_, e = write_file(&c, root, "9/prof/ctl", "zones off")
	testing.expect_value(t, hdr.enabled, 0)
	// zones (upstream's 6d6b): the header, whose head and cap say how many
	// records follow, then every ring's records merged oldest first by their
	// end. What the header says of the VMO is not believed: a lie about its
	// size changes nothing.
	ring_put :: proc(i: u32, owner: u32, ends: []u64) {
		r := prof.ring_at((^prof.Header)(&ring_words), i)
		r.thread = owner
		for e, k in ends {
			prof.ring_records(r)[k] = {start = e - 10, end = e, zone = 1, thread = owner}
		}
		r.head = u64(len(ends))
	}
	zones :: proc(c: ^p9.Client, root: p9.Fid, out: []u8) -> []u8 {
		f, _ := p9.client_walk(c, root, "9/prof/zones")
		_ = p9.client_open(c, f, p9.OREAD)
		got := 0
		for got < len(out) {
			n, e := p9.client_read(c, f, u64(got), out[got:][:min(len(out) - got, 4096)])
			if e != .Ok || n == 0 {
				break
			}
			got += n
		}
		_ = p9.client_clunk(c, f)
		return out[:got]
	}
	ring_put(0, 0, {50}) // shared: a thread past the first 32
	ring_put(1, 3, {150, 350, 550})
	ring_put(2, 4, {250, 450})
	hdr.cap, hdr.head = 0xffff_ffff, 1 << 40 // a header that lies about its size
	@(static) merged: [size_of(prof.Header) + 2 * prof.CAP * size_of(prof.Record)]u8
	{
		got := zones(&c, root, merged[:])
		testing.expect_value(t, len(got), size_of(prof.Header) + 6 * size_of(prof.Record))
		snap := (^prof.Header)(&got[0])
		testing.expect_value(t, snap.magic, prof.MAGIC)
		testing.expect_value(t, snap.head, 6)
		testing.expect_value(t, snap.cap, 6)
		testing.expect_value(t, snap.rings, 0)
		recs := ([^]prof.Record)(&got[size_of(prof.Header)])[:6]
		ENDS := [6]u64{50, 150, 250, 350, 450, 550}
		OWNERS := [6]u32{0, 3, 4, 3, 4, 3}
		for r, i in recs {
			testing.expectf(t, r.end == ENDS[i] && r.thread == OWNERS[i], "record %d: end %d of thread %d", i, r.end, r.thread)
		}
	}
	// A ring that has wrapped: its last CAP records, oldest first, the
	// newest in its first slot.
	{
		r := prof.ring_at(hdr, 2)
		for &rec, k in prof.ring_records(r) {
			rec = {start = 1, end = 600 + u64(k), zone = 1, thread = 4}
		}
		prof.ring_records(r)[0].end = 600 + u64(prof.CAP)
		r.head = u64(prof.CAP) + 1
		got := zones(&c, root, merged[:])
		nrec := (len(got) - size_of(prof.Header)) / size_of(prof.Record)
		testing.expect_value(t, nrec, 4 + int(prof.CAP))
		recs := ([^]prof.Record)(&got[size_of(prof.Header)])[:nrec]
		testing.expect_value(t, recs[4].end, 601) // 50, 150, 350, 550, then ring 2's oldest
		testing.expect_value(t, recs[nrec - 1].end, 600 + u64(prof.CAP))
		by_end := true
		for i in 1 ..< nrec {
			by_end = by_end && recs[i].end >= recs[i - 1].end
		}
		testing.expect_value(t, by_end, true)
	}
	text, _ = read_file(&c, root, "7/prof/zones", buf[:])
	testing.expect_value(t, text, "")

	// --- A crash: no tmpfs here, so not saved; killed with the trap's words ---
	crasher := task_by_id(12)
	clear(&kernel_log)
	fire_exception(crasher, 2, exception(.Page_Fault, 0x401000, code = 1, address = 0), last_in_line = true)
	testing.expect_value(t, string(kernel_log[:]), "procfs: crasher.12: sys: trap: fault write addr=0x0 pc=0x401000; not saved\n")
	testing.expect_value(t, thread_of(crasher, 2).resumed, vx.Resume_Action.Kill)
	testing.expect_value(t, crasher.suspends, 1) // the others held still
	text, _ = read_file(&c, root, "12/threads/2/status", buf[:])
	testing.expect_value(t, text, "state=running\n") // nothing held for it now

	// An end: the debugger's state and the ring go with it; the parent's record.
	_, e = write_file(&c, root, "9/ctl", "break 0x400100")
	_, e = write_file(&c, root, "9/ctl", "kill")
	testing.expect_value(t, string(ls.exit[:]), "killed")
	fire_exit(ls)
	text, _ = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, text, "pid=9 name=ls noteid=7 status=killed real=15\n")
	testing.expect_value(t, p9test.list(&c, root, ""), "1 2 7 12")
	_, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_Should_Wait) // 12 lives on
	fire_exit(crasher)
	_, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_Interrupted) // SIGCHLD ended the held read (childnotes)
	text, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, text, "pid=12 name=crasher noteid=12 status=\"\" real=15\n")
	_, e = fs_read(7, .Wait, buf[:])
	testing.expect_value(t, e, vx.Status.Err_No_Child)

	// A file open before its process went: Err_Not_Found.
	{
		sf, _ := p9.client_walk(&c, root, "7/status")
		_ = p9.client_open(&c, sf, p9.OREAD)
		_, e = write_file(&c, root, "7/ctl", "kill")
		fire_exit(shell)
		_, e = p9.client_read(&c, sf, 0, buf[:])
		testing.expect_value(t, e, vx.Status.Err_Not_Found)
		_ = p9.client_clunk(&c, sf)
	}
	// A registration reuses a slot: its new generation keys its bindings.
	add_task({id = 20, name = "new", state = .Running})
	testing.expect_value(t, register(t, 20, 1), vx.Status.Ok)
	testing.expect_value(t, p9test.list(&c, root, ""), "1 2 20")
}
