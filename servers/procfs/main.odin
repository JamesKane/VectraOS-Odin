// procfs: /proc, the tasks (upstream docs/02 §5.1), minimal for M2.
//
// svcd gives it a handle to svcd's own task ("tasks"), so it sees svcd and
// every task svcd's tree has made (abi:vx's task_info), and nothing else; and
// the listen channel it posts as /srv/proc.
//
//   /proc/N/status   one ndb record: name=svcd state=waiting threads=1 mem=412K
//   /proc/N/ctl      write "kill" to kill the task
//
// A task's state reads "waiting" when every thread it has is blocked. The tree
// is made as it is read: a task that has gone is simply not there.
package procfs

import vx "abi:vx"
import "vx:ndb"
import "vx:p9"
import "vx:p9ring"
import "vx:rt"

@(private="file")
tasks: vx.Handle // the root of what procfs shows
@(private="file")
root_id: u64 // its task id
@(private="file")
KILLED :: -9 // the exit status a kill through ctl gives, as Unix's SIGKILL reads

// Node numbers: 1 is /proc; a task's directory, status and ctl are its id
// shifted left two, plus 0, 1 or 2.
@(private="file")
ROOT :: u64(1)
@(private="file")
DIR :: u64(0)
@(private="file")
STATUS :: u64(1)
@(private="file")
CTL :: u64(2)

@(private="file")
task_of :: proc "contextless" (node: u64) -> u64 {
	return node >> 2
}

@(private="file")
task_exists :: proc "contextless" (id: u64) -> (info: vx.Task_Summary, ok: bool) {
	st: vx.Status
	info, st = rt.task_info(tasks, id, {})
	return info, st == .Ok && info.state != .Exited
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: u64, st: vx.Status) {
	if len(aname) != 0 {
		return 0, .Err_Not_Found
	}
	return ROOT, .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: u64, name: string) -> (child: u64, st: vx.Status) {
	if dir == ROOT {
		id: u64
		if len(name) == 0 || len(name) > 19 || name[0] == '0' {
			return 0, .Err_Not_Found
		}
		for c in transmute([]u8)name {
			if c < '0' || c > '9' {
				return 0, .Err_Not_Found
			}
			id = id * 10 + u64(c - '0')
		}
		if _, ok := task_exists(id); !ok {
			return 0, .Err_Not_Found
		}
		return id << 2 | DIR, .Ok
	}
	if dir & 3 != DIR {
		return 0, .Err_Not_Found
	}
	if _, ok := task_exists(task_of(dir)); !ok {
		return 0, .Err_Not_Found
	}
	switch name {
	case "status":
		return dir | STATUS, .Ok
	case "ctl":
		return dir | CTL, .Ok
	}
	return 0, .Err_Not_Found
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, node: u64) -> (parent: u64, st: vx.Status) {
	return node & 3 == DIR ? ROOT : node &~ 3, .Ok
}

@(private="file")
name_buf: [24]u8

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, node: u64, out: ^p9.Stat) -> vx.Status {
	if node == ROOT {
		out^ = {qid = {type = p9.QTDIR, path = ROOT}, mode = p9.DMDIR | 0o555, name = "/"}
	} else {
		switch node & 3 {
		case DIR:
			// The name of a task's directory is its id, in decimal.
			id := task_of(node)
			n := len(name_buf)
			for {
				n -= 1
				name_buf[n] = u8('0' + id % 10)
				id /= 10
				if id == 0 {
					break
				}
			}
			out^ = {qid = {type = p9.QTDIR, path = node}, mode = p9.DMDIR | 0o555, name = string(name_buf[n:])}
		case STATUS:
			out^ = {qid = {type = p9.QTFILE, path = node}, mode = 0o444, name = "status"}
		case CTL:
			out^ = {qid = {type = p9.QTFILE, path = node}, mode = 0o222, name = "ctl"}
		case:
			// Never made: walk and readdir give only the three kinds above.
			out^ = {qid = {type = p9.QTFILE, path = node}}
		}
	}
	out.uid, out.gid, out.muid = "proc", "proc", "proc"
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, node: u64, mode: u8) -> vx.Status {
	writes := mode & 3 == p9.OWRITE || mode & 3 == p9.ORDWR
	if node & 3 == STATUS && writes {
		return .Err_Access
	}
	if node & 3 == CTL && mode & 3 != p9.OWRITE {
		return .Err_Access
	}
	return mode & (p9.OTRUNC | p9.ORCLOSE) != 0 ? .Err_Access : .Ok
}

// A task's status record, as it is now; empty if the task has gone or the
// record does not fit.
@(private="file")
status_text :: proc "contextless" (id: u64, buf: []u8) -> int {
	info, ok := task_exists(id)
	if !ok {
		return 0
	}
	name_len := 0
	for name_len < len(info.name) && info.name[name_len] != 0 {
		name_len += 1
	}
	w := ndb.Writer{buf = buf}
	ndb.put(&w, "name", string(info.name[:name_len]))
	state := "running"
	if info.state == .New {
		state = "new"
	} else if info.threads != 0 && info.blocked == info.threads {
		state = "waiting"
	}
	ndb.put(&w, "state", state)
	ndb.put_u64(&w, "threads", u64(info.threads))
	mem: [24]u8
	kib := info.mapped / 1024
	n := len(mem)
	n -= 1
	mem[n] = 'K'
	for {
		n -= 1
		mem[n] = u8('0' + kib % 10)
		kib /= 10
		if kib == 0 {
			break
		}
	}
	ndb.put(&w, "mem", string(mem[n:]))
	_ = ndb.end(&w)
	return w.failed ? 0 : w.len
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, node: u64, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	text: [256]u8
	n := node & 3 == STATUS ? status_text(task_of(node), text[:]) : 0
	left := offset < u64(n) ? u64(n) - offset : 0
	count = u32(min(u64(len(buf)), left))
	if count > 0 {
		copy(buf, text[offset:][:count])
	}
	return count, .Ok
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, node: u64, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	if node & 3 != CTL {
		return 0, .Err_Access
	}
	n := len(data)
	for n > 0 && (data[n - 1] == '\n' || data[n - 1] == ' ') {
		n -= 1
	}
	if string(data[:n]) != "kill" {
		return 0, .Err_Invalid
	}
	if task_of(node) == root_id {
		return 0, .Err_Access // not the root of the tree: the system needs it
	}
	if rt.task_kill(tasks, KILLED, task_of(node)) != .Ok {
		return 0, .Err_Not_Found
	}
	return u32(len(data)), .Ok // the whole message was the command
}

// The root's entries are the tasks in id order; entry i is the i-th.
@(private="file")
fs_readdir :: proc "contextless" (ctx: rawptr, dir: u64, index: u32) -> (child: u64, st: vx.Status) {
	if dir != ROOT { // a task's directory: status, ctl
		if index > 1 {
			return 0, .Err_Not_Found
		}
		return dir | (index != 0 ? CTL : STATUS), .Ok
	}
	id: u64
	seen: u32
	for {
		info, ist := rt.task_info(tasks, id, {.Next})
		if ist != .Ok {
			return 0, .Err_Not_Found
		}
		id = info.id
		if info.state == .Exited {
			continue // gone, but not yet freed: not listed
		}
		if seen == index {
			break
		}
		seen += 1
	}
	return id << 2 | DIR, .Ok
}

// Not file-private: tests/host drives its Fs on the host.
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
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	tasks = rt.spawn_take("tasks")
	server.listen = rt.spawn_take("listen")
	info: vx.Task_Summary
	st := vx.Status.Err_Bad_Handle
	if tasks != vx.HANDLE_NONE && server.listen != vx.HANDLE_NONE {
		info, st = rt.task_info(tasks)
	}
	if st != .Ok {
		rt.print("procfs: FAILED: no task tree or listen channel\n")
		return 1
	}
	root_id = info.id
	return int(p9ring.serve(&server))
}
