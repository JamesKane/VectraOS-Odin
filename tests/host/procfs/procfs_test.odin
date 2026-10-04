// servers/procfs's file system on the host: the program itself, linked
// against lib/rt, with a fake kernel underneath. This file defines
// vx_syscall, so the runtime's syscalls land here: task_info and task_kill
// act on a small fake task tree, debug_write is kept, and port_create fails,
// so the program's vx_main sets itself up and returns at once instead of
// serving rings. Its p9.Fs is then driven through lib/p9's server framework
// and client, as tests/host/p9_server does.
//
// Everything here is global (the program's state and the fake kernel), so
// it is one test.
package procfs_test

import vx "abi:vx"
import "core:testing"
import "vx:p9"
import "vx:rt"
import procfs "../../../servers/procfs"

TASKS :: vx.Handle(0x101) // the "tasks" handle the fake spawn message gives
LISTEN :: vx.Handle(0x102)

Fake_Task :: struct {
	id:          u64,
	name:        string,
	state:       vx.Task_State,
	threads:     u32,
	blocked:     u32,
	mapped:      u64,
	exit_status: i64,
}

// The tree TASKS reaches, in id order; the first is the task itself.
fake_tasks := [?]Fake_Task {
	{id = 1, name = "svcd", state = .Running, threads = 1, blocked = 1, mapped = 412 * 1024},
	{id = 2, name = "bootfs", state = .New},
	{id = 3, name = "my task", state = .Running, threads = 2, blocked = 1, mapped = 1536},
	{id = 4, name = "gone", state = .Exited}, // exited, not yet freed: not listed
	{id = 5, name = "a-very-long-task-name-24", state = .Running, threads = 1, mapped = 4096},
	{id = 7, name = "uart", state = .Running, threads = 3, blocked = 3, mapped = 8 * 1024 * 1024},
}

kernel_log: [1024]u8
kernel_log_len: int

summary :: proc "contextless" (t: ^Fake_Task, out: ^vx.Task_Summary) {
	out^ = {id = t.id, state = t.state, threads = t.threads, blocked = t.blocked, mapped = t.mapped, exit_status = t.exit_status}
	copy(out.name[:], t.name)
}

find :: proc "contextless" (id: u64) -> ^Fake_Task {
	if id == 0 {
		return &fake_tasks[0]
	}
	for &t in fake_tasks {
		if t.id == id {
			return &t
		}
	}
	return nil
}

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	#partial switch nr {
	case .Debug_Write:
		s := ([^]u8)(uintptr(a0))[:a1]
		kernel_log_len += copy(kernel_log[kernel_log_len:], s)
		return 0
	case .Task_Info:
		if vx.Handle(a0) != TASKS {
			return i64(vx.Status.Err_Bad_Handle)
		}
		t: ^Fake_Task
		if .Next in transmute(vx.Task_Info_Options)u32(a3) {
			for &c in fake_tasks {
				if c.id > a2 {
					t = &c
					break
				}
			}
		} else {
			t = find(a2)
		}
		if t == nil {
			return i64(vx.Status.Err_Not_Found)
		}
		summary(t, (^vx.Task_Summary)(uintptr(a1)))
		return 0
	case .Task_Kill:
		t := find(a2)
		if vx.Handle(a0) != TASKS || t == nil || t.state == .Exited {
			return i64(vx.Status.Err_Not_Found)
		}
		t.state, t.exit_status, t.threads, t.blocked = .Exited, i64(a1), 0, 0
		return 0
	}
	return i64(vx.Status.Err_Unsupported) // port_create among them: vx_main returns
}

loopback :: proc "contextless" (ctx: rawptr, req: []u8, resp: []u8) -> int {
	n, res := p9.serve((^p9.Server)(ctx), req, resp)
	return res == .Reply ? n : 0 // a loopback cannot hold a request: a deferral ends it too
}

read_file :: proc(c: ^p9.Client, root: u32, path: string, buf: []u8) -> (string, vx.Status) {
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

write_file :: proc(c: ^p9.Client, root: u32, path: string, data: string) -> (int, vx.Status) {
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

stat_of :: proc(c: ^p9.Client, root: u32, path: string, st: ^p9.Stat) -> vx.Status {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return e
	}
	defer _ = p9.client_clunk(c, f)
	return p9.client_stat(c, f, st)
}

// The names a directory reads as, in order, joined by spaces.
list :: proc(c: ^p9.Client, root: u32, path: string, out: []u8) -> string {
	f, e := p9.client_walk(c, root, path)
	if e != .Ok {
		return "(walk failed)"
	}
	defer _ = p9.client_clunk(c, f)
	if p9.client_open(c, f, p9.OREAD) != .Ok {
		return "(open failed)"
	}
	dir: [4096]u8
	n, re := p9.client_read(c, f, 0, dir[:])
	if re != .Ok {
		return "(read failed)"
	}
	used := 0
	for off := 0; off + 2 <= n; {
		length := int(dir[off]) | int(dir[off + 1]) << 8
		st: p9.Stat
		if p9.stat_decode(dir[off:][:length + 2], &st) != .Ok {
			return "(bad entry)"
		}
		if used > 0 {
			used += copy(out[used:], " ")
		}
		used += copy(out[used:], st.name)
		off += length + 2
	}
	return string(out[:used])
}

@(test)
test_procfs :: proc(t: ^testing.T) {
	// The spawn message svcd would send: "tasks" and "listen".
	rt.spawn.handle_names[0], rt.spawn.handles[0] = "tasks", TASKS
	rt.spawn.handle_names[1], rt.spawn.handles[1] = "listen", LISTEN
	rt.spawn.handle_count = 2
	testing.expect_value(t, procfs.vx_main(), int(vx.Status.Err_Unsupported)) // set up, then no port to serve on
	testing.expect_value(t, procfs.server.listen, LISTEN)
	testing.expect_value(t, string(kernel_log[:kernel_log_len]), "")

	srv := p9.Server{fs = procfs.server.fs, max_msize = 8192}
	tbuf, rbuf: [8192]u8
	c := p9.Client{rpc = loopback, ctx = &srv, tbuf = tbuf[:], rbuf = rbuf[:]}
	testing.expect_value(t, p9.client_version(&c, 8192, {}), vx.Status.Ok)
	_, ae := p9.client_attach(&c, "1")
	testing.expect_value(t, ae, vx.Status.Err_Not_Found) // no aname
	root, e := p9.client_attach(&c, "")
	testing.expect_value(t, e, vx.Status.Ok)

	// The status records, byte for byte.
	buf: [512]u8
	text: string
	text, e = read_file(&c, root, "1/status", buf[:])
	testing.expect_value(t, e, vx.Status.Ok)
	testing.expect_value(t, text, "name=svcd state=waiting threads=1 mem=412K\n")
	text, _ = read_file(&c, root, "2/status", buf[:])
	testing.expect_value(t, text, "name=bootfs state=new threads=0 mem=0K\n")
	text, _ = read_file(&c, root, "3/status", buf[:])
	testing.expect_value(t, text, "name=\"my task\" state=running threads=2 mem=1K\n")
	text, _ = read_file(&c, root, "5/status", buf[:])
	testing.expect_value(t, text, "name=a-very-long-task-name-24 state=running threads=1 mem=4K\n") // the name fills its field: no NUL
	text, _ = read_file(&c, root, "7/status", buf[:])
	testing.expect_value(t, text, "name=uart state=waiting threads=3 mem=8192K\n")

	// A read at an offset, and past the end.
	{
		f, _ := p9.client_walk(&c, root, "1/status")
		_ = p9.client_open(&c, f, p9.OREAD)
		n, re := p9.client_read(&c, f, 5, buf[:4])
		testing.expect(t, re == .Ok && string(buf[:n]) == "svcd")
		n, re = p9.client_read(&c, f, 1000, buf[:])
		testing.expect(t, re == .Ok && n == 0)
		_ = p9.client_clunk(&c, f)
	}

	// The tree: live tasks in id order; status and ctl in each.
	names: [256]u8
	testing.expect_value(t, list(&c, root, "", names[:]), "1 2 3 5 7")
	testing.expect_value(t, list(&c, root, "3", names[:]), "status ctl")

	// Names that are not tasks.
	for name in ([]string{"4", "6", "01", "0", "1x", "-1", "99999999999999999999", "status"}) {
		_, we := p9.client_walk(&c, root, name)
		testing.expect_value(t, we, vx.Status.Err_Not_Found)
	}
	for path in ([]string{"1/foo", "1/status/x", "4/status"}) {
		_, we := p9.client_walk(&c, root, path)
		testing.expect_value(t, we, vx.Status.Err_Not_Found)
	}
	{
		f, we := p9.client_walk(&c, root, "1/status/..")
		testing.expect_value(t, we, vx.Status.Ok)
		st: p9.Stat
		_ = p9.client_stat(&c, f, &st)
		testing.expect_value(t, st.name, "1")
		_ = p9.client_clunk(&c, f)
	}

	// Stats.
	st: p9.Stat
	testing.expect_value(t, stat_of(&c, root, "", &st), vx.Status.Ok)
	testing.expect(t, st.name == "/" && st.mode == p9.DMDIR | 0o555 && st.qid == {type = p9.QTDIR, path = 1})
	testing.expect(t, st.uid == "proc" && st.gid == "proc" && st.muid == "proc" && st.length == 0)
	_ = stat_of(&c, root, "7", &st)
	testing.expect(t, st.name == "7" && st.mode == p9.DMDIR | 0o555 && st.qid == {type = p9.QTDIR, path = 7 << 2})
	_ = stat_of(&c, root, "7/status", &st)
	testing.expect(t, st.name == "status" && st.mode == 0o444 && st.qid == {type = p9.QTFILE, path = 7 << 2 | 1} && st.length == 0)
	_ = stat_of(&c, root, "7/ctl", &st)
	testing.expect(t, st.name == "ctl" && st.mode == 0o222 && st.qid == {type = p9.QTFILE, path = 7 << 2 | 2} && st.uid == "proc")

	// Open modes: status is only read, ctl only written, nothing truncated.
	open_mode :: proc(c: ^p9.Client, root: u32, path: string, mode: u8) -> vx.Status {
		f, _ := p9.client_walk(c, root, path)
		defer _ = p9.client_clunk(c, f)
		return p9.client_open(c, f, mode)
	}
	testing.expect_value(t, open_mode(&c, root, "1/status", p9.OWRITE), vx.Status.Err_Access)
	testing.expect_value(t, open_mode(&c, root, "1/status", p9.ORDWR), vx.Status.Err_Access)
	testing.expect_value(t, open_mode(&c, root, "1/status", p9.OREAD | p9.ORCLOSE), vx.Status.Err_Access)
	testing.expect_value(t, open_mode(&c, root, "1/status", p9.OEXEC), vx.Status.Ok)
	testing.expect_value(t, open_mode(&c, root, "1/ctl", p9.OREAD), vx.Status.Err_Access)
	testing.expect_value(t, open_mode(&c, root, "1/ctl", p9.ORDWR), vx.Status.Err_Access)
	testing.expect_value(t, open_mode(&c, root, "1/ctl", p9.OWRITE | p9.OTRUNC), vx.Status.Err_Access)
	testing.expect_value(t, open_mode(&c, root, "1/ctl", p9.OWRITE), vx.Status.Ok)
	testing.expect_value(t, open_mode(&c, root, "1", p9.OREAD), vx.Status.Ok)

	// ctl: only "kill", with trailing newlines and spaces; never the root.
	n: int
	n, e = write_file(&c, root, "7/ctl", "stop\n")
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	n, e = write_file(&c, root, "7/ctl", "kill it")
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	n, e = write_file(&c, root, "7/ctl", " kill")
	testing.expect_value(t, e, vx.Status.Err_Invalid)
	n, e = write_file(&c, root, "1/ctl", "kill\n")
	testing.expect_value(t, e, vx.Status.Err_Access)
	testing.expect_value(t, fake_tasks[0].state, vx.Task_State.Running)
	n, e = write_file(&c, root, "7/ctl", "kill \n\n")
	testing.expect(t, e == .Ok && n == 7) // the whole message
	testing.expect(t, fake_tasks[5].state == .Exited && fake_tasks[5].exit_status == -9)
	_, e = p9.client_walk(&c, root, "7")
	testing.expect_value(t, e, vx.Status.Err_Not_Found) // gone
	testing.expect_value(t, list(&c, root, "", names[:]), "1 2 3 5")

	// A file open before its task went: status reads empty, ctl kills nothing.
	{
		sf, _ := p9.client_walk(&c, root, "5/status")
		cf, _ := p9.client_walk(&c, root, "5/ctl")
		_ = p9.client_open(&c, sf, p9.OREAD)
		_ = p9.client_open(&c, cf, p9.OWRITE)
		n, e = p9.client_write(&c, cf, 0, transmute([]u8)string("kill"))
		testing.expect(t, e == .Ok && n == 4)
		n, e = p9.client_read(&c, sf, 0, buf[:])
		testing.expect(t, e == .Ok && n == 0)
		_, e = p9.client_write(&c, cf, 0, transmute([]u8)string("kill"))
		testing.expect_value(t, e, vx.Status.Err_Not_Found)
		_ = p9.client_clunk(&c, sf)
		_ = p9.client_clunk(&c, cf)
	}
}
