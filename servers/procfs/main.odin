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
import "vx:str"

@(private="file")
tasks: vx.Handle // the root of what procfs shows
@(private="file")
root_id: u64 // its task id
@(private="file")
KILLED :: -9 // the exit status a kill through ctl gives, as Unix's SIGKILL reads

// Node numbers: 1 is /proc; a task's directory, status and ctl are its id
// shifted left two, plus its Kind. /proc's number reads as task 0's status,
// which walk and readdir never make, so it is tested for first.
@(private="file")
ROOT :: p9.Node(1)

@(private="file")
Kind :: enum u64 {
	Dir,
	Status,
	Ctl,
	// 3 is never made
}

@(private="file")
node_of :: proc "contextless" (id: u64, k: Kind) -> p9.Node {
	return p9.Node(id << 2 | u64(k))
}

@(private="file")
kind_of :: proc "contextless" (node: p9.Node) -> Kind {
	return Kind(node & 3)
}

@(private="file")
task_of :: proc "contextless" (node: p9.Node) -> u64 {
	return u64(node >> 2)
}

@(private="file")
task_exists :: proc "contextless" (id: u64) -> (info: vx.Task_Summary, ok: bool) {
	st: vx.Status
	info, st = rt.task_info(tasks, id, {})
	return info, st == .Ok && info.state != .Exited
}

@(private="file")
fs_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	if len(aname) != 0 {
		return 0, .Err_Not_Found
	}
	return ROOT, .Ok
}

@(private="file")
fs_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	if dir == ROOT {
		// A task's id, in decimal, without leading zeros.
		if len(name) > 19 || str.has_prefix(name, "0") {
			return 0, .Err_Not_Found
		}
		id, ok := str.parse_u64(name)
		if !ok {
			return 0, .Err_Not_Found
		}
		if _, exists := task_exists(id); !exists {
			return 0, .Err_Not_Found
		}
		return node_of(id, .Dir), .Ok
	}
	if kind_of(dir) != .Dir {
		return 0, .Err_Not_Found
	}
	if _, ok := task_exists(task_of(dir)); !ok {
		return 0, .Err_Not_Found
	}
	switch name {
	case "status":
		return node_of(task_of(dir), .Status), .Ok
	case "ctl":
		return node_of(task_of(dir), .Ctl), .Ok
	}
	return 0, .Err_Not_Found
}

@(private="file")
fs_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	return kind_of(node) == .Dir ? ROOT : node_of(task_of(node), .Dir), .Ok
}

@(private="file")
name_buf: [str.U64_DIGITS]u8

@(private="file")
fs_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	if node == ROOT {
		out^ = {qid = {type = p9.QTDIR, path = u64(ROOT)}, mode = p9.DMDIR | 0o555, name = "/"}
	} else {
		switch kind_of(node) {
		case .Dir:
			// The name of a task's directory is its id, in decimal.
			name := str.format_u64(name_buf[:], task_of(node))
			out^ = {qid = {type = p9.QTDIR, path = u64(node)}, mode = p9.DMDIR | 0o555, name = name}
		case .Status:
			out^ = {qid = {type = p9.QTFILE, path = u64(node)}, mode = 0o444, name = "status"}
		case .Ctl:
			out^ = {qid = {type = p9.QTFILE, path = u64(node)}, mode = 0o222, name = "ctl"}
		case:
			// Never made: walk and readdir give only the three kinds above.
			out^ = {qid = {type = p9.QTFILE, path = u64(node)}}
		}
	}
	out.uid, out.gid, out.muid = "proc", "proc", "proc"
	return .Ok
}

@(private="file")
fs_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	if kind_of(node) == .Status && p9.writes(mode) {
		return .Err_Access
	}
	if kind_of(node) == .Ctl && mode.access != .Write {
		return .Err_Access
	}
	return mode.trunc || mode.rclose ? .Err_Access : .Ok
}

// A task's status record, as it is now; empty if the task has gone or the
// record does not fit.
@(private="file")
status_text :: proc "contextless" (id: u64, buf: []u8) -> int {
	info, ok := task_exists(id)
	if !ok {
		return 0
	}
	w := ndb.Writer{buf = buf}
	ndb.put(&w, "name", str.from_nul_padded(info.name[:]))
	state := "running"
	if info.state == .New {
		state = "new"
	} else if info.threads != 0 && info.blocked == info.threads {
		state = "waiting"
	}
	ndb.put(&w, "state", state)
	ndb.put_u64(&w, "threads", u64(info.threads))
	mem_buf: [str.U64_DIGITS + 1]u8
	mem := str.Buf{buf = mem_buf[:]}
	str.write_u64(&mem, info.mapped / 1024)
	str.write_byte(&mem, 'K')
	ndb.put(&w, "mem", str.to_string(&mem))
	_ = ndb.end(&w)
	return w.failed ? 0 : w.len
}

@(private="file")
fs_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	text: [256]u8
	n := kind_of(node) == .Status ? status_text(task_of(node), text[:]) : 0
	left := offset < u64(n) ? u64(n) - offset : 0
	count = u32(min(u64(len(buf)), left))
	if count > 0 {
		copy(buf, text[offset:][:count])
	}
	return count, .Ok
}

@(private="file")
fs_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	if kind_of(node) != .Ctl {
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
fs_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	if dir != ROOT { // a task's directory: status, ctl
		if index > 1 {
			return 0, .Err_Not_Found
		}
		return node_of(task_of(dir), index != 0 ? .Ctl : .Status), .Ok
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
	return node_of(id, .Dir), .Ok
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
