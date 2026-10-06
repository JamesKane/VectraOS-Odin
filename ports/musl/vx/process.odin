package backend

import vx "abi:vx"
import "linux"
import "vx:drbg"
import "vx:memory"
import "vx:ndb"
import "vx:note"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:signal"
import "vx:str"
import "vx:utf"

// The process model, through /proc as 9front's APE builds it (ADR-0011),
// and posix_spawn, execve and fork.
//
// A process's pid is its task's id, which exec keeps (ADR-0012). Its parent,
// note group (POSIX's process group), session and children are procfs's,
// and are files in /proc/N: ppid, noteid, status (sid=), ctl, note, notepg
// and wait. A child is registered with procfs before it runs
// (rt.proc_register). Without /proc in its namespace a process is alone: no
// parent, group or children, and its group and session are itself.

foreign _ {
	getenv :: proc "c" (name: cstring) -> cstring --- // musl's
	// arch/*/context.S: setjmp and longjmp for fork alone. save returns 0,
	// and 1 again when resume jumps back to it (in the child's copy).
	__vx_fork_save :: proc "c" (ctx: ^Fork_Context) -> i32 ---
	__vx_fork_resume :: proc "c" (ctx: ^Fork_Context) -> ! ---
}

// The registers save keeps: callee-saved ones, the stack and return address.
Fork_Context :: struct {
	regs: [24]u64,
}

proc_mounted: bool // /proc is in the namespace: procfs knows this process

posix_pid :: proc "contextless" () -> i64 {
	return i64(task_id)
}

// "/proc/PID/FILE".
@(private="file")
proc_path :: proc "contextless" (pid: i64, file: string, buf: []u8) -> string {
	b := str.Buf {
		buf = buf,
	}
	str.write_string(&b, "/proc/")
	str.write_i64(&b, pid)
	str.write_byte(&b, '/')
	str.write_string(&b, file)
	return b.failed ? "" : str.to_string(&b)
}

// The errno for a /proc call that failed: a process that is not there is
// ESRCH.
@(private="file")
proc_errno :: proc "contextless" (st: vx.Status) -> int {
	#partial switch st {
	case .Err_Not_Found:
		return fail(.ESRCH)
	case .Err_Access:
		return fail(.EPERM)
	}
	return errno_of(st)
}

// Reads /proc/PID/FILE (one read) into buf: what it read, or -errno. With
// unlocked, for a file whose read may wait for long (a child's end), the
// back end is let go for the read itself (upstream's 6d4b).
proc_read :: proc "contextless" (pid: i64, file: string, buf: []u8, unlocked := false) -> (string, int) {
	if !proc_mounted {
		return "", fail(.ESRCH)
	}
	pb: [64]u8
	f: ns.File
	if st := ns.open(namespace(), proc_path(pid, file, pb[:]), p9.OREAD, &f); st != .Ok {
		return "", proc_errno(st)
	}
	held := unlocked ? be_wait_begin() : 0
	n, st := ns.read(&f, buf)
	be_wait_end(held)
	ns.close(&f)
	if st != .Ok {
		return "", proc_errno(st)
	}
	return string(buf[:n]), n
}

proc_write :: proc "contextless" (pid: i64, file: string, text: string) -> int {
	if !proc_mounted {
		return fail(.ESRCH)
	}
	pb: [64]u8
	f: ns.File
	if st := ns.open(namespace(), proc_path(pid, file, pb[:]), p9.OWRITE, &f); st != .Ok {
		return proc_errno(st)
	}
	_, st := ns.write(&f, transmute([]u8)text)
	ns.close(&f)
	return st != .Ok ? proc_errno(st) : 0
}

// A number as strtol reads one: leading blanks, a sign, decimal digits.
@(private="file")
parse_long :: proc "contextless" (s: string) -> (v: i64) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n') {
		i += 1
	}
	neg := i < len(s) && s[i] == '-'
	if i < len(s) && (s[i] == '-' || s[i] == '+') {
		i += 1
	}
	for i < len(s) && s[i] >= '0' && s[i] <= '9' && v < max(i64) / 10 - 9 {
		v = v * 10 + i64(s[i] - '0')
		i += 1
	}
	return neg ? -v : v
}

// A number in /proc/PID/FILE, or, with key, the value of key= in its record.
@(private="file")
proc_number :: proc "contextless" (pid: i64, file: string, key: string = "") -> i64 {
	buf: [512]u8
	text, n := proc_read(pid, file, buf[:])
	if n < 0 {
		return i64(n)
	}
	if key == "" {
		return parse_long(text)
	}
	for at := 0; at + len(key) < len(text); at += 1 {
		if text[at:][:len(key)] == key && (at == 0 || text[at - 1] == ' ') && text[at + len(key)] == '=' {
			return parse_long(text[at + len(key) + 1:])
		}
	}
	return i64(fail(.EINVAL))
}

// Each POSIX process asks procfs for SIGCHLD and its children's stops.
posix_init :: proc "contextless" () {
	proc_mounted = ns.connector(namespace(), "/proc") != vx.HANDLE_NONE
	if proc_mounted {
		_ = proc_write(posix_pid(), "ctl", "childnotes")
	}
}

posix_getppid :: proc "contextless" () -> int {
	r := proc_number(posix_pid(), "ppid")
	return r < 0 ? 0 : int(r)
}

posix_getpgid :: proc "contextless" (pid: i64) -> int {
	pid := pid == 0 ? posix_pid() : pid
	if !proc_mounted {
		return pid == posix_pid() ? int(pid) : fail(.ESRCH)
	}
	return int(proc_number(pid, "noteid"))
}

posix_getsid :: proc "contextless" (pid: i64) -> int {
	pid := pid == 0 ? posix_pid() : pid
	if !proc_mounted {
		return pid == posix_pid() ? int(pid) : fail(.ESRCH)
	}
	return int(proc_number(pid, "status", "sid"))
}

// setpgid writes the group to noteid, as APE does; procfs lets a process
// join a group in its session, or start one named by its own pid.
posix_setpgid :: proc "contextless" (pid, pgid: i64) -> int {
	if pid < 0 || pgid < 0 {
		return fail(.EINVAL)
	}
	pid := pid == 0 ? posix_pid() : pid
	pgid := pgid == 0 ? pid : pgid
	if !proc_mounted {
		return pid == posix_pid() && pgid == pid ? 0 : fail(.EPERM)
	}
	digits: [str.I64_DIGITS]u8
	return proc_write(pid, "noteid", str.format_i64(digits[:], pgid))
}

posix_setsid :: proc "contextless" () -> int {
	if !proc_mounted {
		return fail(.EPERM)
	}
	if r := proc_write(posix_pid(), "ctl", "setsid"); r < 0 {
		return r
	}
	return int(posix_pid())
}

// --- wait ---
//
// Each read of /proc/PID/wait is one child's record, as APE's waitpid reads
// them: one for a child it was not asked about is kept here for a later
// call. WNOHANG reads only while the file's length (records queued) says a
// read will not wait.

@(private="file")
Waited :: struct {
	pid, group: i64,
	status:     i32, // as wait4 reports it
	stopped:    bool,
	continued:  bool,
}

@(private="file")
wait_kept: [dynamic; 128]Waited // as many as procfs keeps for one parent

// A wait record (procfs's ndb) as wait4 reports it.
@(private="file")
wait_parse :: proc "contextless" (text: string) -> (w: Waited, ok: bool) {
	scratch: [note.ERRMAX + 64]u8
	r := ndb.Reader {
		src     = text,
		scratch = scratch[:],
	}
	rec: ndb.Record
	if ndb.next(&r, &rec) != .Record {
		return {}, false
	}
	pid, pok := ndb.get_u64(&rec, "pid")
	if !pok || pid == 0 {
		return {}, false
	}
	group, _ := ndb.get_u64(&rec, "noteid")
	w = {
		pid   = i64(pid),
		group = i64(group),
	}
	if sig, sok := ndb.get_u64(&rec, "stopped"); sok {
		w.stopped = true
		w.status = i32(sig << 8 | 0x7f)
	} else if ndb.has(&rec, "continued") {
		w.continued = true
		w.status = 0xffff
	} else {
		exit, _ := ndb.get(&rec, "status")
		w.status = i32(signal.wait_status(exit))
	}
	return w, true
}

// Whether a record answers wait4(pid, options).
@(private="file")
wait_matches :: proc "contextless" (w: ^Waited, pid: i64, options: linux.Wait_Options) -> bool {
	if w.stopped && .Untraced not_in options {
		return false
	}
	if w.continued && .Continued not_in options {
		return false
	}
	if pid > 0 {
		return w.pid == pid
	}
	if pid == -1 {
		return true
	}
	return w.group == (pid == 0 ? i64(posix_getpgid(0)) : -pid)
}

@(private="file")
wait_take_kept :: proc "contextless" (pid: i64, options: linux.Wait_Options) -> (w: Waited, ok: bool) {
	for &k, i in wait_kept {
		if wait_matches(&k, pid, options) {
			w = k
			copy(wait_kept[i:], wait_kept[i + 1:])
			resize(&wait_kept, len(wait_kept) - 1)
			return w, true
		}
	}
	return {}, false
}

@(private="file")
wait_keep :: proc "contextless" (w: Waited) {
	if len(wait_kept) == cap(wait_kept) { // full: the oldest goes
		copy(wait_kept[:], wait_kept[1:])
		resize(&wait_kept, len(wait_kept) - 1)
	}
	_ = append(&wait_kept, w)
}

// wait4: rusage is not kept, and reads as zero.
posix_wait4 :: proc "contextless" (pid: i64, status: ^i32, options: linux.Wait_Options, ru: ^linux.Rusage) -> int {
	if ru != nil {
		ru^ = {}
	}
	w, found := wait_take_kept(pid, options)
	// A process that is there and not a child: nothing to wait for (an ended
	// child's entry is gone, its record still queued).
	if !found && pid > 0 && proc_mounted {
		parent := proc_number(pid, "ppid")
		if parent >= 0 && parent != posix_pid() {
			return fail(.ECHILD)
		}
	}
	for !found {
		if !proc_mounted {
			return fail(.ECHILD)
		}
		pb: [64]u8
		if .Nohang in options { // only what is queued: the file's length
			f: ns.File
			s: p9.Stat
			e := ns.open(namespace(), proc_path(posix_pid(), "wait", pb[:]), p9.OREAD, &f)
			if e == .Ok {
				e = p9.client_stat(f.c, f.fid, &s)
				ns.close(&f)
			}
			if e != .Ok {
				return proc_errno(e)
			}
			if s.length == 0 {
				return 0 // nothing yet, as APE's waitpid answers
			}
		}
		buf: [512]u8
		text, n := proc_read(posix_pid(), "wait", buf[:], unlocked = true) // until a child ends: others go on
		if n == fail(.ESRCH) {
			return fail(.ECHILD)
		}
		if n < 0 {
			return n // ECHILD (no living children), EINTR (a signal ended it)
		}
		got, ok := wait_parse(text)
		if !ok {
			continue
		}
		w = got
		found = wait_matches(&w, pid, options)
		if !found {
			wait_keep(w)
		}
	}
	if status != nil {
		status^ = w.status
	}
	return int(w.pid)
}

// --- posix_spawn and execve ---
//
// The parent builds the child (rt.spawn_elf) from the program's file: it
// gives it the namespace, the console, its arguments and environment, its
// descriptors and working directory (fd= and cwd= records), and registers it
// with procfs before it runs (posix_spawn), in the group or session
// posix_spawn's attributes ask for; execve goes on in this task (ADR-0012).
// musl's posix_spawn, whose child is a clone that calls execve, is left out
// of the build.

Spawn_Ctx :: struct {
	pgid:        i64, // -1 to inherit
	setsid:      bool,
	exec:        bool,
	pid:         i64,
	error:       int,
	// The signals the child keeps: what is ignored stays ignored (but those
	// in sig_default), and the mask is this one's (or blocked, if
	// has_mask), as POSIX has it for exec and posix_spawn.
	sig_default: linux.Sig_Set,
	blocked:     linux.Sig_Set,
	has_mask:    bool,
}

@(private="file")
spawn_prepare :: proc "contextless" (ctx: rawptr, task: vx.Handle) -> (h: vx.Handle, name: string, st: vx.Status) {
	s := (^Spawn_Ctx)(ctx)
	if s.exec {
		s.pid = posix_pid() // the same task, so the same process (ADR-0012)
	} else {
		info, ist := rt.task_info(task)
		s.pid = ist == .Ok ? i64(info.id) : 0
	}
	return vx.HANDLE_NONE, "", .Ok
}

// A C string's bytes.
cstr :: proc "contextless" (p: cstring) -> string {
	return p == nil ? "" : string(p)
}

// path, or for posix_spawnp a name with no '/', searched for in PATH.
@(private="file")
spawn_open :: proc "contextless" (path: string, search: bool) -> int {
	if !search || str.index_byte(path, '/') >= 0 {
		return fd_openat(linux.AT_FDCWD, path, linux.O_RDONLY, 0)
	}
	dirs := cstr(getenv("PATH"))
	if getenv("PATH") == nil {
		dirs = "/usr/local/bin:/bin:/usr/bin"
	}
	fd := fail(.ENOENT)
	for fd < 0 && len(dirs) > 0 {
		n := str.index_byte(dirs, ':')
		if n < 0 {
			n = len(dirs)
		}
		full: [ns.MAX_PATH]u8
		if n + 1 + len(path) < len(full) {
			at := copy(full[:], dirs[:n])
			full[at] = '/'
			at += 1
			at += copy(full[at:], path)
			fd = fd_openat(linux.AT_FDCWD, string(full[:at]), linux.O_RDONLY, 0)
		}
		dirs = dirs[min(n + 1, len(dirs)):]
	}
	return fd
}

// The length of a NULL-terminated list of C strings.
@(private="file")
list_len :: proc "contextless" (list: [^]cstring) -> (n: int) {
	if list == nil {
		return 0
	}
	for list[n] != nil {
		n += 1
	}
	return
}

@(private="file")
spawn_records :: proc "contextless" (w: ^ndb.Writer, argv, envp: [^]cstring, table: ^[FD_MAX]Slot, ctx: ^Spawn_Ctx, handles: []vx.Handle, names: []string) -> (count: int, e: int) {
	args, envs := list_len(argv), list_len(envp)
	if args > rt.SPAWN_MAX_ARGS || envs > rt.SPAWN_MAX_ARGS {
		return 0, fail(.E2BIG) // the child would refuse them
	}
	if args > 0 {
		ndb.put(w, "argv0", cstr(argv[0]))
		_ = ndb.end(w)
		for a in argv[1:args] {
			ndb.put(w, "arg", cstr(a))
			_ = ndb.end(w)
		}
	}
	for v in envp[:envs] {
		ndb.put(w, "env", cstr(v))
		_ = ndb.end(w)
	}
	sig_records(w, ctx)
	if entropy.seeded { // a seed of its own, from this process's generator
		seed: [32]u8
		drbg.read(&entropy, seed[:])
		ndb.put(w, "entropy", string(seed[:]))
		_ = ndb.end(w)
	}
	// Handles: the descriptors' pipes and the namespace's connections,
	// leaving room for the console, "posix" and "self".
	limit := vx.CHANNEL_MAX_HANDLES - 3
	fd_records(table, w, handles, names, &count, limit)
	if w.failed {
		return count, fail(.E2BIG)
	}
	st: vx.Status
	count, st = procns.spawn_records(namespace(), w, handles[:limit], names, count)
	if st != .Ok {
		return count, errno_of(st)
	}
	if c := rt.console_connector(); c != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(c, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "console"
			count += 1
		}
	}
	return count, w.failed ? fail(.E2BIG) : 0
}

@(private="file")
records_buf: [32 * 1024]u8

// Builds and starts the program at path, with the descriptors in table.
// Returns 0 or -errno.
@(private="file")
spawn_image :: proc "contextless" (path: string, search: bool, argv, envp: [^]cstring, table: ^[FD_MAX]Slot, ctx: ^Spawn_Ctx) -> int {
	fd_quiet_reads() // the child's terminal input is the child's
	fd := spawn_open(path, search)
	if fd < 0 {
		return fd
	}
	st: linux.Stat
	r := fd_fstat(fd, &st)
	image := fail(.ENOEXEC)
	is_dir := st.mode & linux.S_IFMT == linux.S_IFDIR
	if r == 0 && st.mode & linux.S_IFMT == linux.S_IFREG && st.size > 0 {
		image = mem_map(0, uint(st.size), {.Read}, linux.MAP_PRIVATE, fd, 0)
	}
	_ = fd_close(fd)
	if image < 0 {
		return is_dir ? fail(.EACCES) : image
	}
	w := ndb.Writer {
		buf = records_buf[:],
	}
	handles: [vx.CHANNEL_MAX_HANDLES]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES]string
	count: int
	count, r = spawn_records(&w, argv, envp, table, ctx, handles[:], names[:])
	base := path[str.last_index_byte(path, '/') + 1:] // the task's name: the file's, without its directory
	base = base[:utf.cut(base, 23)] // whole runes (ADR-0013)
	task := vx.HANDLE_NONE
	if r == 0 {
		a := rt.Spawn_Args {
			name         = base,
			image        = ([^]u8)(uintptr(image))[:st.size],
			handles      = handles[:count],
			handle_names = names[:count],
			records      = ndb.written(&w),
			prepare      = spawn_prepare,
			ctx          = ctx,
			exec         = ctx.exec,
			// Registered before it runs (ADR-0011), in the group or session
			// posix_spawn's attributes ask for.
			proc_conn    = ns.connector(namespace(), "/proc"),
			proc_group   = ctx.pgid > 0 ? u64(ctx.pgid) : 0,
		}
		if ctx.setsid {
			a.proc_flags = {.Set_Sid}
		} else if ctx.pgid == 0 {
			a.proc_flags = {.Note_Group} // a group of its own
		}
		vst: vx.Status
		task, vst = rt.spawn_elf(&a)
		#partial switch vst {
		case .Ok:
		case .Err_Invalid:
			r = fail(.ENOEXEC) // not an image for this machine
		case .Err_Access:
			r = fail(.EPERM) // procfs refused the group
		case:
			r = errno_of(vst)
		}
	} else {
		rt.close_all(..handles[:count])
	}
	_ = mem_unmap(uintptr(image), uint(st.size))
	rt.close_all(task) // procfs has its own, and tells of its end
	return r
}

// The child's table: this one, with the file actions applied in order. A
// chdir among them changes this process's working directory until the child
// is built (the caller puts it back).
@(private="file")
spawn_actions :: proc "contextless" (fa: ^linux.Spawn_File_Actions, vt: ^[FD_MAX]Slot) -> int {
	for &s, i in vt {
		s = fd_table[i]
		if s.o != nil {
			s.o.refs += 1
		}
	}
	if fa == nil || fa.actions == nil {
		return 0
	}
	op := fa.actions // newest first: applied from the oldest
	for op.next != nil {
		op = op.next
	}
	for ; op != nil; op = op.prev {
		fd := int(op.fd)
		if (op.cmd == linux.FDOP_CLOSE || op.cmd == linux.FDOP_DUP2 || op.cmd == linux.FDOP_OPEN) && (fd < 0 || fd >= FD_MAX) {
			return fail(.EBADF)
		}
		path := cstr(cstring(([^]u8)(op)[linux.FDOP_PATH:]))
		switch op.cmd {
		case linux.FDOP_CLOSE:
			if vt[fd].o != nil {
				ofd_release(vt[fd].o)
			}
			vt[fd].o = nil
		case linux.FDOP_DUP2:
			src := int(op.srcfd)
			if src < 0 || src >= FD_MAX || vt[src].o == nil {
				return fail(.EBADF)
			}
			if src != fd {
				vt[src].o.refs += 1
				if vt[fd].o != nil {
					ofd_release(vt[fd].o)
				}
				vt[fd].o = vt[src].o
			}
			vt[fd].cloexec = false
		case linux.FDOP_OPEN:
			got := fd_openat(linux.AT_FDCWD, path, transmute(linux.Open_Flags)op.oflag, op.mode)
			if got < 0 {
				return got
			}
			if vt[fd].o != nil {
				ofd_release(vt[fd].o)
			}
			vt[fd] = {fd_table[got].o, false} // moved from this table to the child's
			fd_table[got].o = nil
		case linux.FDOP_CHDIR:
			if r := fd_chdir(path); r < 0 {
				return r
			}
		case linux.FDOP_FCHDIR:
			d := fd >= 0 && fd < FD_MAX ? vt[fd].o : nil
			if d == nil {
				return fail(.EBADF)
			}
			if d.kind != .File || !d.dir {
				return fail(.ENOTDIR)
			}
			set_cwd(string(d.path[:]))
		case:
			return fail(.EINVAL)
		}
	}
	return 0
}

@(private="file")
spawn_table: [FD_MAX]Slot

@(export, link_name="posix_spawn")
posix_spawn :: proc "c" (pid: ^i32, path: cstring, fa: ^linux.Spawn_File_Actions, attr: ^linux.Spawnattr, argv, envp: [^]cstring) -> i32 {
	flags := attr != nil ? int(attr.flags) : 0
	ctx := Spawn_Ctx {
		pgid   = -1,
		setsid = flags & linux.POSIX_SPAWN_SETSID != 0,
	}
	if flags & linux.POSIX_SPAWN_SETPGROUP != 0 {
		ctx.pgid = i64(attr.pgrp)
	}
	if flags & linux.POSIX_SPAWN_SETSIGDEF != 0 {
		ctx.sig_default = sigset_word(&attr.def)
	}
	if flags & linux.POSIX_SPAWN_SETSIGMASK != 0 {
		ctx.blocked, ctx.has_mask = sigset_word(&attr.mask), true
	}
	// Not through __vx_syscall: a signal now would run its handler in the
	// middle of the back end's work. It waits, as in a call, until the child
	// is made.
	be_me().sig_depth += 1
	saved: [dynamic; ns.MAX_PATH]u8
	_ = append(&saved, cwd())
	r := spawn_actions(fa, &spawn_table)
	if r == 0 {
		r = spawn_image(cstr(path), attr != nil && attr.fn != nil, argv, envp, &spawn_table, &ctx) // posix_spawnp sets fn
	}
	for &s in spawn_table {
		if s.o != nil {
			ofd_release(s.o)
		}
		s = {}
	}
	set_cwd(string(saved[:]))
	be_me().sig_depth -= 1
	if be_me().sig_depth == 0 {
		_ = sig_deliver_pending()
	}
	if r < 0 {
		return i32(-r)
	}
	if pid != nil {
		pid^ = i32(ctx.pid)
	}
	return 0
}

// execve: the program goes on in this task, so as this process, with its
// pid, parent and children (task_exec, ADR-0012), and with this one's
// descriptors but those marked FD_CLOEXEC. Only a failure returns.
proc_execve :: proc "contextless" (path: cstring, argv, envp: [^]cstring) -> int {
	if rt.console_pending() {
		rt.console_flush() // what this program printed goes out before it is gone
	}
	ctx := Spawn_Ctx {
		pgid = -1,
		exec = true,
	}
	return spawn_image(cstr(path), false, argv, envp, &fd_table, &ctx)
}

// --- fork ---
//
// The kernel copies this task's memory and handles (task_create's .Fork);
// the child's one thread starts on a small stack of its own at fork_entry,
// which sets its thread pointer and jumps back into the copy of proc_fork's
// frame that __vx_fork_save marked. There it lets go of what the copy cannot
// share (the namespace's and the console's dead connections) and returns 0.
// The parent registers the child with procfs before it runs (ADR-0011).

@(private="file")
fork_jump: Fork_Context
@(private="file")
fork_tls: u64
@(private="file")
fork_rights: u64 // the forking thread's protection-key rights (ADR-0035: kept)
// The parent's pending signals as its memory was copied: the child has none
// of them (POSIX).
@(private="file")
fork_pending: linux.Sig_Set
@(private="file")
fork_stack: struct #align (16) {
	bytes: [4096]u8,
}

@(private="file")
fork_entry :: proc "c" (unused: vx.Handle, unused2: u64) -> ! {
	_ = rt.tls_set(fork_tls)
	rt.rights_set(fork_rights) // the child's first thread starts with key 0 alone
	__vx_fork_resume(&fork_jump)
}

@(private="file")
fork_child :: proc "contextless" () -> int {
	if me, st := rt.task_info(rt.self); st == .Ok {
		task_id = me.id
	}
	// The generator was copied: the child's goes its own way from the parent's.
	tag := "fork child\x00"
	drbg.mix(&entropy, transmute([]u8)tag, false)
	id := task_id
	drbg.mix(&entropy, memory.ptr_to_bytes(&id), false)
	fd_after_fork()
	be_after_fork() // the thread that forked, alone, numbered anew
	clear(&wait_kept) // the parent's children's records are the parent's
	sig_forget_pending(fork_pending) // the parent's, copied with its memory; not those sent to the child since
	if proc_mounted {
		_ = proc_write(posix_pid(), "ctl", "childnotes")
	}
	return 0
}

@(private="file")
fork_parent :: proc "contextless" () -> int {
	child, thread: vx.Handle
	ctx := Spawn_Ctx {
		pgid = -1,
	}
	name := "forked"
	me, ist := rt.task_info(rt.self)
	if ist == .Ok {
		name = str.from_nul_padded(me.name[:])
	}
	fd_quiet_reads() // input that comes next is for whichever reads it, not a read of this one's
	fd_before_fork() // tokens for the child to join this process's open files with
	fork_pending = pending_load()
	st: vx.Status
	child, st = rt.task_fork(name)
	fd_after_fork_parent()
	if st == .Ok {
		_, _, st = spawn_prepare(&ctx, child)
	}
	if conn := ns.connector(namespace(), "/proc"); st == .Ok && conn != vx.HANDLE_NONE {
		_, st = rt.proc_register(conn, child, {}) // before it runs (ADR-0011)
	}
	if st == .Ok {
		thread, st = rt.thread_create(child)
	}
	if st == .Ok {
		top := u64(uintptr(&fork_stack)) + size_of(fork_stack)
		st = rt.thread_start(thread, u64(uintptr(rawptr(fork_entry))), top, vx.HANDLE_NONE, 0)
	}
	rt.close_all(thread)
	if st != .Ok && child != vx.HANDLE_NONE {
		_ = rt.task_kill(child, "fork failed")
	}
	rt.close_all(child)
	if st != .Ok {
		return ctx.error != 0 ? ctx.error : fail(.EAGAIN)
	}
	tag := "fork parent\x00"
	drbg.mix(&entropy, transmute([]u8)tag, false)
	return int(ctx.pid)
}

proc_fork :: proc "contextless" () -> int {
	if rt.console_pending() {
		rt.console_flush() // not twice, once from each
	}
	fork_tls, _ = rt.tls_get()
	fork_rights = rt.rights_get()
	if __vx_fork_save(&fork_jump) != 0 {
		return fork_child()
	}
	return fork_parent()
}
