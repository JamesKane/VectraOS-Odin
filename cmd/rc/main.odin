// rc: the shell, Plan 9's rc (upstream docs/04 §5; M2, its language since M4
// step 7, named gsh until upstream's M6 step 6a4, made 9front's in step 6a6).
// Its language is vx:rc's; this is the host it runs on, and its start.
//
//   rc [-srdiIlxebpvV] [-c command] [-m initial] [file [arg ...]]
//
// As 9front's rc, it reads its flags, sets $pid, $rcname and $cflag, and runs
// `. -bq /rc/lib/rcmain $*` (-m names another rcmain), which sets $home,
// $prompt and $path and then runs the command, the file, or standard input,
// interactively with -i, or when there is no file and standard input is the
// console (never with -I). It exits with $status's first word.
//
// A command is a program found through $path in the shell's namespace (a name
// that starts / ./ ../ or # as written). It is loaded by the shell and spawned
// with a copy of the namespace, the console, and its standard input, output
// and error: the shell's own, a pipe, or a channel the shell copies to or from
// a file, a here document or `{...}'s capture. The shell waits for a
// pipeline's commands, unless it ends with &, and $status is each one's wait
// message (name pid: exit string) joined as rc's concstatus (ADR-0010).
// Without fork, a pipeline's stages and & must be programs (vx:rc);
// descriptors past 2 are not given to programs yet.
//
// rc's Host callbacks are contextless, so everything they reach is too; only
// vx_main has a context.
package rccmd

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rc"
import "vx:rt"
import "vx:str"
import "vx:utf"
import usage_of "gen:usage/rc"

MAX_STAGES :: 16
MAX_FILES :: 16
MAX_BACKGROUND :: 16
// Each stage's output and error, and the pipeline's input and output.
MAX_RELAYS :: 2 * MAX_STAGES + 2
// Port keys: a stage's exit is its number; a relay's readable and peer-closed
// packets are its number past these, in ranges of their own.
KEY_READABLE :: u64(MAX_STAGES)
KEY_CLOSED :: KEY_READABLE + MAX_RELAYS
// The arg= and env= records a child takes (upstream's VX_SPAWN_MAX_ARGS): a
// spawn with more is refused, never cut short.
CHILD_MAX_ARGS :: 4096
// The longest task name: the kernel's field, less its NUL.
MAX_TASK_NAME :: len(vx.Task_Summary{}.name) - 1

space: ns.Namespace
sh: rc.Rc // large (the machine's stacks), so a global, as vx:rc asks

// Where the shell's own messages go: a builtin's descriptor 2 while one runs
// (its >[2] and >[2=1] followed), else the shell's standard error.
errors_to: ^rc.Fd

err :: proc "contextless" (s: string) {
	if errors_to != nil {
		write_out(nil, errors_to^, 2, s)
	} else {
		rt.eprint(s)
	}
}

say :: proc "contextless" (a, b, c: string) {
	err(a)
	err(b)
	err(c)
}

// $status: cut, at a rune boundary, to what an exit string holds (ADR-0013).
set_status :: proc "contextless" (s: string) {
	rc.set_status(&sh, s[:utf.cut(s, vx.ERRMAX)])
}

// --- Builtins: the namespace's ---

// bind's flags word: "-abc". ok is false for any other letter. Unlike
// procns.parse_flags (a flags= value), this takes -a with -b, which ns.bind
// reads as -b.
bind_flags :: proc "contextless" (f: string) -> (flags: ns.Flags, ok: bool) {
	for c in transmute([]u8)f[1:] {
		switch c {
		case 'a':
			flags += {.After}
		case 'b':
			flags += {.Before}
		case 'c':
			flags += {.Create}
		case:
			return {}, false
		}
	}
	return flags, true
}

// A builtin's outcome: $status, and on a failure, a message.
report :: proc "contextless" (what: string, st: vx.Status) {
	if st == .Ok {
		set_status("")
		return
	}
	say("rc: ", what, ": ")
	err(p9.error_text(st))
	err("\n")
	set_status(p9.error_text(st))
}

usage :: proc "contextless" (text: string) { // a builtin's, from rc(1)'s usage fence
	err(text)
	err("\n")
	set_status("usage")
}

// Host.builtin: true if argv's first word was one, which then ran, its
// messages to its own descriptor 2.
builtin :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, argv: ^rc.Word, argc: u32, fds: ^[rc.FDS]rc.Fd) -> bool {
	switch rc.text(argv) {
	case "exec":
		return exec_builtin(argv, fds)
	case "wait":
		return wait_builtin(argv, int(argc))
	}
	errors_to = &fds[2]
	defer errors_to = nil
	return builtin_run(argv, int(argc))
}

builtin_run :: proc "contextless" (argv: ^rc.Word, n: int) -> bool {
	w: [4]string // the first words: all a builtin reads
	words := argv
	for &s in w {
		s = rc.next_word(&words) or_break
	}
	flags: ns.Flags
	flags_ok, first := true, 1
	if n > 1 && str.has_prefix(w[1], "-") {
		flags, flags_ok = bind_flags(w[1])
		first = 2
	}
	switch w[0] {
	case "bind":
		if !flags_ok || n - first != 2 {
			usage(usage_of.TEXT_bind)
		} else {
			report("bind", ns.bind(&space, w[first], w[first + 1], flags))
		}
		return true
	case "mount":
		// A post, /srv/NAME, which this namespace has a connection from (as
		// ns prints it, so its output replays) or srvfs has (srv(1)'s, say);
		// or a 9P server over TCP, tcp!HOST!PORT or 9p://HOST:PORT, through
		// a relay, so the children share its session (procns's relay.odin).
		if !flags_ok || n - first < 2 || n - first > 3 {
			usage(usage_of.TEXT_mount)
			return true
		}
		from, old := w[first], w[first + 1]
		aname := n - first == 3 ? w[first + 2] : ""
		st: vx.Status
		if len(from) > 5 && str.has_prefix(from, "/srv/") {
			st = procns.mount_post(&space, from, aname, old, flags)
		} else {
			st = procns.mount_addr(&space, from, aname, old, flags)
		}
		report("mount", st)
		return true
	case "unmount":
		switch n {
		case 2:
			report("unmount", ns.unmount(&space, "", w[1]))
		case 3:
			report("unmount", ns.unmount(&space, w[1], w[2]))
		case:
			usage(usage_of.TEXT_unmount)
		}
		return true
	}
	return false
}

// --- Files: redirections', globbing's and `.`'s ---

Open_File :: struct {
	f:    ns.File,
	used: bool,
}

files: [MAX_FILES]Open_File

// Host.open: a redirection's file, opened once, where the redirection is.
open_file :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, path: string, kind: rc.Open_Kind) -> (handle: u32, ok: bool) {
	h := 0
	for h < MAX_FILES && files[h].used {
		h += 1
	}
	if h == MAX_FILES {
		set_status("too many files open")
		return 0, false
	}
	f := &files[h].f
	st: vx.Status
	if kind == .Read {
		st = ns.open(&space, path, p9.OREAD, f)
	} else {
		// > truncates (devices ignore that) and makes the file if need be, as
		// rc does; >> writes at its end; <> reads and writes, and makes nothing.
		mode := kind == .Rdwr ? p9.ORDWR : p9.OWRITE
		opened := mode
		opened.trunc = kind == .Write
		st = ns.open(&space, path, opened, f)
		if st == .Err_Not_Found && kind != .Rdwr {
			st = ns.create(&space, path, 0o644, mode, f)
		}
		if st == .Ok && kind == .Append {
			s: p9.Stat
			if p9.client_stat(f.c, f.fid, &s) == .Ok {
				f.offset = s.length
			}
		}
	}
	if st != .Ok {
		set_status(p9.error_text(st))
		return 0, false
	}
	files[h].used = true
	return u32(h), true
}

close_file :: proc "contextless" (ctx: rawptr, handle: u32) {
	if handle >= MAX_FILES || !files[handle].used {
		return
	}
	ns.close(&files[handle].f)
	files[handle].used = false
}

write_file :: proc "contextless" (handle: u32, s: string, broken: ^bool) {
	b := transmute([]u8)s
	for done := 0; done < len(b) && !broken^ && handle < MAX_FILES && files[handle].used; {
		n, _ := ns.write(&files[handle].f, b[done:][:min(len(b) - done, 8192)])
		if n <= 0 {
			broken^ = true
		} else {
			done += n
		}
	}
}

// Host.write: the shell's own output (whatis's), where fd goes.
write_out :: proc "contextless" (ctx: rawptr, fd: rc.Fd, which: u32, s: string) {
	broken := false
	#partial switch v in fd {
	case rc.Fd_Capture:
		rc.capture_write(&sh, fd, s)
	case rc.Fd_File:
		if v.kind != .Read {
			write_file(v.handle, s, &broken)
		}
	case rc.Fd_Inherit:
		if v.which == 2 {
			rt.eprint(s)
		} else {
			rt.print(s)
		}
	}
}

// Host.exists: whether the path names something, for globbing.
exists :: proc "contextless" (ctx: rawptr, path: string) -> bool {
	c, fid, st := ns.walk(&space, path)
	if st != .Ok {
		return false
	}
	_ = p9.client_clunk(c, fid)
	return true
}

dir_buf: [4096]u8

// Host.readdir: a directory's entries, for globbing.
read_dir :: proc "contextless" (ctx: rawptr, path: string, g: ^rc.Glob) -> bool {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return false
	}
	defer ns.close(&f)
	for {
		n, _ := ns.read(&f, dir_buf[:])
		if n <= 0 {
			break
		}
		it := p9.Dir_Entries{buf = dir_buf[:n]}
		for entry in p9.next_entry(&it) {
			rc.glob_add(g, entry.name)
		}
	}
	return true
}

// Host.read_file: a file's text, for `.` and for a script; refused, not cut
// short, if it is longer than buf.
read_whole :: proc "contextless" (ctx: rawptr, path: string, buf: []u8) -> (size: int, ok: bool) {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return 0, false
	}
	defer ns.close(&f)
	n := 0
	st: vx.Status
	for size < len(buf) {
		n, st = ns.read(&f, buf[size:][:min(len(buf) - size, 8192)])
		if st != .Ok || n <= 0 {
			break
		}
		size += n
	}
	if st != .Ok {
		return 0, false
	}
	if size == len(buf) { // too long: refused, not cut short
		more: [1]u8
		if got, _ := ns.read(&f, more[:]); got > 0 {
			return 0, false
		}
	}
	return size, true
}

// --- Running programs ---

IMAGE_SIZE :: 4 << 20
image: [IMAGE_SIZE]u8

// The parts of an ELF file's headers load reads.
Elf_Header :: struct {
	ident:                                                [16]u8,
	type, machine:                                        u16,
	version:                                              u32,
	entry, phoff, shoff:                                  u64,
	flags:                                                u32,
	ehsize, phentsize, phnum, shentsize, shnum, shstrndx: u16,
}
#assert(size_of(Elf_Header) == 64)

Elf_Phdr :: struct {
	type, flags:                                u32,
	offset, vaddr, paddr, filesz, memsz, align: u64,
}
#assert(size_of(Elf_Phdr) == 56)

PT_LOAD :: 1

// What elf_needs found.
Needs :: enum {
	Not_Elf,
	Too_Big, // more than image holds
	Bytes, // so many bytes
}

// The bytes of an ELF image a spawn reads: through the end of its last
// loadable segment (and its program headers), not the symbols and debugging
// sections after them.
elf_needs :: proc "contextless" (have: int) -> (n: int, needs: Needs) {
	if have < size_of(Elf_Header) || string(image[:4]) != "\x7fELF" {
		return 0, .Not_Elf
	}
	eh := intrinsics.unaligned_load((^Elf_Header)(raw_data(image[:size_of(Elf_Header)])))
	end := eh.phoff + u64(eh.phnum) * size_of(Elf_Phdr)
	if eh.phentsize != size_of(Elf_Phdr) || eh.phoff > IMAGE_SIZE || end > IMAGE_SIZE {
		return 0, .Too_Big
	}
	if end > u64(have) {
		return int(end), .Bytes // the headers first
	}
	for i in 0 ..< u64(eh.phnum) {
		at := eh.phoff + i * size_of(Elf_Phdr)
		ph := intrinsics.unaligned_load((^Elf_Phdr)(raw_data(image[at:][:size_of(Elf_Phdr)])))
		if ph.type == PT_LOAD && ph.offset + ph.filesz > end {
			end = ph.offset + ph.filesz
		}
	}
	if end > IMAGE_SIZE {
		return 0, .Too_Big
	}
	return int(end), .Bytes
}

// Loads a program through the namespace, found as rc's searchpath finds it:
// a name that starts / ./ ../ or # as written, any other in each of $path's
// directories ("" and . meaning as written). Returns its size (what a spawn
// needs of it), or 0.
load :: proc "contextless" (name: string) -> int {
	here := str.has_prefix(name, "/") || str.has_prefix(name, "#") || str.has_prefix(name, "./") || str.has_prefix(name, "../")
	dirs := here ? nil : rc.get_var(&sh, "path")
	if dirs == nil {
		return load_in("", name)
	}
	for d := dirs; d != nil; d = d.next {
		if size := load_in(rc.text(d), name); size != 0 {
			return size
		}
	}
	return 0
}

// Loads dir/name into image: its size, or 0.
load_in :: proc "contextless" (dir, name: string) -> int {
	path_buf: [256]u8
	n := 0
	if dir != "" && dir != "." {
		if len(dir) + 1 > len(path_buf) {
			return 0
		}
		n = copy(path_buf[:], dir)
		if path_buf[n - 1] != '/' {
			path_buf[n] = '/'
			n += 1
		}
	}
	if n + len(name) > len(path_buf) {
		return 0
	}
	n += copy(path_buf[n:], name)
	f: ns.File
	if ns.open(&space, string(path_buf[:n]), p9.OREAD, &f) != .Ok {
		return 0
	}
	size, need := 0, 4096
	for size < need { // the headers, then as much as they say
		got, _ := ns.read(&f, image[size:][:min(need - size, 65536)])
		if got <= 0 {
			break
		}
		size += got
		want, needs := elf_needs(size)
		if needs != .Bytes {
			break
		}
		need = max(want, need)
	}
	ns.close(&f)
	if want, needs := elf_needs(size); needs == .Bytes && size >= want {
		return size
	}
	return 0
}

// A variable, exported as rc does: NAME=WORDS, the words of a list separated
// by \x01; but not $* or $0 and the like, nor names a POSIX program could not
// read. Too long to pass, it fails the writer: the spawn is refused, not
// given less.
env_buf: [32 * 1024]u8

export_var :: proc "contextless" (rec: ^ndb.Writer, name: string, val: ^rc.Word) -> bool {
	plain := len(name) > 0 && !(name[0] >= '0' && name[0] <= '9')
	for c in transmute([]u8)name {
		plain = plain && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_')
	}
	if !plain {
		return false
	}
	env := str.Buf{buf = env_buf[:]}
	str.write_string(&env, name)
	str.write_byte(&env, '=')
	for w := val; w != nil; w = w.next {
		str.write_string(&env, rc.text(w))
		if w.next != nil {
			str.write_byte(&env, 1)
		}
	}
	if env.failed {
		rec.failed = true
		return false
	}
	ndb.put(rec, "env", str.to_string(&env))
	_ = ndb.end(rec)
	return true
}

// A function, exported as rc does: fn#name, its text `fn name {body}`.
export_fn :: proc "contextless" (rec: ^ndb.Writer, name, src: string) {
	if 2 * len(name) + len(src) + 16 > len(env_buf) { // too long to pass: the spawn is refused, not given less
		rec.failed = true
		return
	}
	env := str.Buf{buf = env_buf[:]}
	str.write_string(&env, "fn#")
	str.write_string(&env, name)
	str.write_string(&env, "=fn ")
	str.write_string(&env, name)
	str.write_byte(&env, ' ')
	str.write_string(&env, src)
	ndb.put(rec, "env", str.to_string(&env))
	_ = ndb.end(rec)
}

// The functions the shell was given (fn#name), defined, as rcmain's loop over
// /env/fn#* does; not with -p. $status is kept as it was.
import_fns :: proc "contextless" () {
	rd := ndb.Reader{src = rt.spawn.text, scratch = env_scratch[:]}
	rec: ndb.Record
	for ndb.next(&rd, &rec) == .Record {
		e := ndb.get(&rec, "env") or_continue
		eq := str.index_byte(e, '=')
		if eq < 4 || !str.has_prefix(e, "fn#") {
			continue
		}
		kept: [4096]u8
		words: [dynamic; 64]string
		at := 0
		for w := rc.get_var(&sh, "status"); w != nil && len(words) < cap(words); w = w.next {
			n := copy(kept[at:], rc.text(w))
			_ = append(&words, string(kept[at:][:n]))
			at += n
		}
		_ = rc.run(&sh, e[eq + 1:])
		rc.set_var(&sh, "status", ..words[:])
	}
}

// The environment the shell was given, as variables (rc's lists, split at \x01).
env_words: [dynamic; CHILD_MAX_ARGS]string
env_scratch: [vx.CHANNEL_MAX_BYTES]u8

import_env :: proc "contextless" () {
	rd := ndb.Reader{src = rt.spawn.text, scratch = env_scratch[:]}
	rec: ndb.Record
	for ndb.next(&rd, &rec) == .Record {
		e := ndb.get(&rec, "env") or_continue
		eq := str.index_byte(e, '=')
		if eq <= 0 || eq >= 64 {
			continue
		}
		if eq > 3 && str.has_prefix(e, "fn#") { // a function: import_fns's
			continue
		}
		clear(&env_words)
		v := e[eq + 1:]
		for len(env_words) < CHILD_MAX_ARGS {
			end := str.index_byte(v, 1)
			_ = append(&env_words, end < 0 ? v : v[:end])
			if end < 0 {
				break
			}
			v = v[end + 1:]
		}
		rc.set_var(&sh, e[:eq], ..env_words[:])
	}
}

records: [vx.CHANNEL_MAX_BYTES - 4096]u8 // room left for spawn's own records

// Spawns one program with its standard input, output and error (channel
// ends, or HANDLE_NONE for the console), which are given away. With exec,
// the program takes this task's place (task_exec, ADR-0012): it returns
// only if it failed.
spawn :: proc "contextless" (argv: ^rc.Word, io: [3]vx.Handle, exec := false) -> (task: vx.Handle, st: vx.Status) {
	IO := [3]string{"stdin", "stdout", "stderr"}
	io := io
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	count := 0
	given := false // to spawn_elf, which takes them whatever happens
	defer if !given {
		rt.close_all(..handles[:count])
		rt.close_all(..io[:])
	}
	size := load(rc.text(argv))
	if size == 0 {
		return vx.HANDLE_NONE, .Err_Not_Found
	}
	rec := ndb.Writer{buf = records[:]}
	args, exported := 0, 0
	for a := argv.next; a != nil; a = a.next {
		ndb.put(&rec, "arg", rc.text(a))
		_ = ndb.end(&rec)
		args += 1
	}
	it := rc.vars(&sh)
	for name, val in rc.next_var(&it) {
		if export_var(&rec, name, val) {
			exported += 1
		}
	}
	fns := rc.fns(&sh)
	for name, src in rc.next_fn(&fns) {
		export_fn(&rec, name, src)
		exported += 1
	}
	// More than a spawn message holds, or than the child takes: refused
	// whole, never run with a list cut short.
	if rec.failed || args > CHILD_MAX_ARGS || exported > CHILD_MAX_ARGS {
		return vx.HANDLE_NONE, .Err_Range
	}
	count = procns.spawn_records(&space, &rec, handles[:vx.CHANNEL_MAX_HANDLES - 5], names[:], 0) or_return
	if con := rt.console_connector(); con != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(con, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "console"
			count += 1
		}
	}
	given = true // nothing fails from here to spawn_elf
	for h, i in io {
		if h != vx.HANDLE_NONE {
			handles[count], names[count] = h, IO[i]
			count += 1
		}
	}
	base := rc.text(argv) // the task's name: the program's, without its directory
	base = base[str.last_index_byte(base, '/') + 1:]
	a := rt.Spawn_Args {
		name         = base[:utf.cut(base, MAX_TASK_NAME)], // whole runes (ADR-0013)
		image        = image[:size],
		handles      = handles[:count],
		handle_names = names[:count],
		records      = ndb.written(&rec),
		exec         = exec,
	}
	return rt.spawn_elf(&a)
}

// A channel the shell copies from (a program's output, into a file or a
// capture) or into (a file, as a program's input).
Relay :: struct {
	end:   vx.Handle, // the shell's end
	to:    rc.Fd, // a file's, a here document's, or a capture's
	feed:  bool, // into the channel, from the file or the here document
	armed: bool,
	off:   int, // a here document's: what has been fed
}

relays: [dynamic; MAX_RELAYS]Relay

// A relay for fd: the shell's end kept, the program's returned.
relay_for :: proc "contextless" (fd: rc.Fd, feed: bool) -> (theirs: vx.Handle, st: vx.Status) {
	if len(relays) == cap(relays) {
		return vx.HANDLE_NONE, .Err_No_Memory
	}
	ours: vx.Handle
	theirs, ours = rt.channel_create() or_return
	_ = append(&relays, Relay{end = ours, to = fd, feed = feed})
	return theirs, .Ok
}

relay_msg: struct {
	header: vx.Msg_Header,
	bytes:  [4096]u8,
}

// Copies what is waiting on a relay. False once it is done: the writer gone
// and all it wrote copied, or the file all fed.
relay_run :: proc "contextless" (rl: ^Relay, broken: ^bool) -> bool {
	msg := memory.ptr_to_bytes(&relay_msg)
	if rl.feed {
		file := rl.to.(rc.Fd_File) or_else rc.Fd_File{handle = MAX_FILES}
		here, is_here := rl.to.(rc.Fd_Here)
		for {
			n := 0
			if is_here { // from the here document's text
				n = copy(relay_msg.bytes[:], here.text[rl.off:])
				rl.off += n
			} else if file.handle < MAX_FILES && files[file.handle].used {
				n, _ = ns.read(&files[file.handle].f, relay_msg.bytes[:])
			}
			if n <= 0 {
				return false
			}
			relay_msg.header = {}
			st := rt.channel_write(rl.end, msg[:size_of(vx.Msg_Header) + n])
			if st == .Err_Should_Wait { // full: the rest later, from where this left off
				if is_here {
					rl.off -= n
				} else {
					files[file.handle].f.offset -= u64(n)
				}
				return true
			}
			if st != .Ok {
				return false // the reader has gone
			}
		}
	}
	for {
		size, st := rt.channel_read(rl.end, msg)
		if st == .Err_Should_Wait {
			return true
		}
		if st != .Ok {
			return false
		}
		s := string(msg[min(size_of(vx.Msg_Header), size.bytes):size.bytes])
		switch v in rl.to {
		case rc.Fd_Capture:
			rc.capture_write(&sh, rl.to, s)
		case rc.Fd_File:
			write_file(v.handle, s, broken)
		case rc.Fd_Inherit, rc.Fd_Dup, rc.Fd_Closed, rc.Fd_Pipe_Out, rc.Fd_Pipe_In, rc.Fd_Here: // never relayed out
		}
	}
}

background: [MAX_BACKGROUND]vx.Handle

// Lets go of commands run with & that have ended.
reap :: proc "contextless" () {
	for &t in background {
		if t == vx.HANDLE_NONE {
			continue
		}
		if info, st := rt.task_info(t); st == .Ok && info.state == .Exited {
			_ = rt.handle_close(t)
			t = vx.HANDLE_NONE
		}
	}
}

// One of the shell's own standard descriptors, to lend a command.
own_fd :: proc "contextless" (which: u8) -> vx.Handle {
	input, output, errors := rt.stdio_handles()
	switch which {
	case 0:
		return input
	case 1:
		return output
	case 2:
		return errors
	}
	return vx.HANDLE_NONE
}

// A channel no one is at the other end of: reads end, writes fail.
unheard :: proc "contextless" () -> (io: vx.Handle, st: vx.Status) {
	a, b := rt.channel_create() or_return
	_ = rt.handle_close(b)
	return a, .Ok
}

// A stage's standard descriptor i: the program's channel end (or none, for
// the console), making relays and joining pipes as need be.
stage_io :: proc "contextless" (fd: rc.Fd, i: int, pipe_in, pipe_out: vx.Handle) -> (io: vx.Handle, st: vx.Status) {
	share: vx.Handle
	switch v in fd {
	case rc.Fd_Inherit:
		share = own_fd(v.which)
	case rc.Fd_Pipe_In:
		share = pipe_in
	case rc.Fd_Pipe_Out:
		share = pipe_out
	case rc.Fd_Closed, rc.Fd_Dup: // a copy left is of no descriptor
		return unheard()
	case rc.Fd_Here: // read; on an output it is no file, as 9front's read-only one takes no writes (upstream f24356f)
		if i != 0 {
			return unheard()
		}
		return relay_for(fd, true)
	case rc.Fd_File, rc.Fd_Capture:
		return relay_for(fd, i == 0)
	}
	if share == vx.HANDLE_NONE {
		return vx.HANDLE_NONE, .Ok
	}
	return rt.handle_dup(share, vx.RIGHTS_SAME)
}

// Whether a stage's descriptor 2 goes where its 1 does (>[2=1] into a file,
// a capture or a pipe), so it shares 1's channel.
same_as_1 :: proc "contextless" (fd2, fd1: rc.Fd) -> bool {
	#partial switch a in fd2 {
	case rc.Fd_File:
		b, is := fd1.(rc.Fd_File)
		return is && a.kind != .Read && a.kind == b.kind && a.handle == b.handle
	case rc.Fd_Capture:
		b, is := fd1.(rc.Fd_Capture)
		return is && a.index == b.index
	case rc.Fd_Pipe_Out:
		_, is := fd1.(rc.Fd_Pipe_Out)
		return is
	case rc.Fd_Pipe_In:
		_, is := fd1.(rc.Fd_Pipe_In)
		return is
	}
	return false
}

ends: [MAX_STAGES][dynamic; vx.ERRMAX]u8 // each command's exit string, for $status

// Host.run: a pipeline's programs, each spawned with its descriptors; then,
// unless async, the relays served until they and the programs are done.
run :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, stages: []rc.Command, async: bool) -> (pid: u64, ok: bool) {
	reap()
	n := len(stages)
	if n > MAX_STAGES {
		say("rc: too many commands in a pipe", "", "\n")
		set_status("too many commands")
		return 0, false
	}
	port, pst := rt.port_create()
	if pst != .Ok {
		return 0, false
	}
	defer _ = rt.handle_close(port)
	tasks: [MAX_STAGES]vx.Handle
	pipe_in: vx.Handle
	clear(&relays)
	for &c, s in stages {
		clear(&ends[s])
		pipe, io: [3]vx.Handle // pipe: [this stage's output, the next one's input]
		st := vx.Status.Ok
		if s + 1 < n {
			pipe[0], pipe[1], st = rt.channel_create()
		}
		fds := c.fds
		if own, is := fds[0].(rc.Fd_Inherit); async && is && own.which == 0 {
			fds[0] = rc.Fd_Closed{} // & reads nothing, as rc's /dev/null
		}
		for i in 0 ..< 3 {
			if st != .Ok {
				break
			}
			if i == 2 && io[1] != vx.HANDLE_NONE && same_as_1(fds[2], fds[1]) {
				io[2], st = rt.handle_dup(io[1], vx.RIGHTS_SAME)
			} else {
				io[i], st = stage_io(fds[i], i, pipe_in, pipe[0])
			}
		}
		rt.close_all(pipe_in, pipe[0])
		pipe_in = pipe[1]
		if st == .Ok {
			tasks[s], st = spawn(c.argv, io)
		} else {
			rt.close_all(..io[:])
		}
		if st != .Ok {
			// As rc's: the command's name and why, which is its status.
			why := st == .Err_Range ? "argument list too long" : p9.error_text(st)
			// Where the command's own errors would go, as rc writes them.
			to := fds[2]
			#partial switch v in to {
			case rc.Fd_Pipe_Out, rc.Fd_Pipe_In:
				to = rc.Fd_Inherit{2}
			case rc.Fd_File:
				if v.kind == .Read {
					to = rc.Fd_Inherit{2}
				}
			}
			for part in ([?]string{rc.text(c.argv), ": ", why, "\n"}) {
				write_out(nil, to, 2, part)
			}
			_ = append(&ends[s], why)
			tasks[s] = vx.HANDLE_NONE
			continue
		}
		_ = rt.port_bind(port, tasks[s], .Exit, u64(s))
	}
	rt.close_all(pipe_in)

	if async { // not waited for: its relays are not served (vx:rc's gaps), so it gets none
		for rl in relays {
			_ = rt.handle_close(rl.end)
		}
		clear(&relays)
		for t, s in tasks[:n] {
			if t == vx.HANDLE_NONE {
				continue
			}
			if info, ist := rt.task_info(t); s + 1 == n && ist == .Ok {
				pid = info.id
			}
			slot := 0
			for slot < MAX_BACKGROUND && background[slot] != vx.HANDLE_NONE {
				slot += 1
			}
			if slot < MAX_BACKGROUND {
				background[slot] = t
			} else {
				_ = rt.handle_close(t)
			}
		}
		return pid, true // $status as it was, as rc's
	}
	defer rt.close_all(..tasks[:n])

	// Wait for every command; meanwhile serve the relays.
	running, live := 0, len(relays)
	for t in tasks[:n] {
		running += t != vx.HANDLE_NONE ? 1 : 0
	}
	broken := false
	for rl, i in relays {
		if !rl.feed {
			_ = rt.port_bind(port, rl.end, .Peer_Closed, KEY_CLOSED + u64(i))
		}
	}
	for running > 0 || live > 0 {
		feeding := false
		for &rl, i in relays {
			if rl.end == vx.HANDLE_NONE {
				continue
			}
			if rl.feed { // as much as the channel takes; the rest after a moment
				if relay_run(&rl, &broken) {
					feeding = true
				} else {
					_ = rt.handle_close(rl.end)
					rl.end = vx.HANDLE_NONE
					live -= 1
				}
			} else if !rl.armed {
				rl.armed = rt.port_bind(port, rl.end, .Readable, KEY_READABLE + u64(i)) == .Ok
			}
		}
		if running == 0 && live == 0 {
			break
		}
		pk: [8]vx.Packet
		got, _ := rt.port_wait(port, feeding ? rt.clock_read() + 1_000_000 : vx.INFINITE, 0, pk[:])
		for p in pk[:got] {
			if p.trigger == .Exit && p.key < u64(n) {
				running -= 1
				if p.value != 0 {
					if info, ist := rt.task_info(tasks[p.key]); ist == .Ok {
						wait_message(&ends[p.key], &info)
					}
				}
				continue
			}
			i := p.key >= KEY_CLOSED ? p.key - KEY_CLOSED : p.key - KEY_READABLE
			if p.key < KEY_READABLE || i >= u64(len(relays)) || relays[i].end == vx.HANDLE_NONE {
				continue
			}
			rl := &relays[i]
			rl.armed = false
			more := relay_run(rl, &broken)
			if !more || p.key >= KEY_CLOSED { // done, or the writer has gone and all it wrote is copied
				if more {
					_ = relay_run(rl, &broken)
				}
				_ = rt.handle_close(rl.end)
				rl.end = vx.HANDLE_NONE
				live -= 1
			}
		}
	}
	if broken {
		say("rc: write error", "", "\n")
	}
	// The commands' statuses, as rc's concstatus joins them.
	status: [MAX_STAGES * (vx.ERRMAX + 1)]u8
	len_status := 0
	for &e in ends[:n] {
		len_status = rc.concstatus(status[:], len_status, string(e[:]))
	}
	rc.set_status(&sh, string(status[:len_status]))
	return 0, true
}

// A task's end as rc's $status has it, into m: the wait message, name pid:
// exit string, cut at a rune boundary to what an exit string holds; nothing
// for success.
wait_message :: proc "contextless" (m: ^[dynamic; $N]u8, info: ^vx.Task_Summary) {
	clear(m)
	exit := vx.exit_string(info)
	if exit == "" {
		return
	}
	name := str.from_nul_padded(info.name[:])
	digits: [str.U64_DIGITS]u8
	_ = append(m, name)
	_ = append(m, ' ')
	_ = append(m, str.format_u64(digits[:], info.id))
	_ = append(m, ": ")
	_ = append(m, exit[:utf.cut(exit, cap(m) - len(m))])
}

// exec cmd ...: the program in this task's place, as rc's execexec. The
// shell relays files, here documents and captures, so a command with one of
// those redirected is refused until the program can be given the file itself.
exec_builtin :: proc "contextless" (argv: ^rc.Word, fds: ^[rc.FDS]rc.Fd) -> bool {
	io: [3]vx.Handle
	st := vx.Status.Ok
	for i in 0 ..< 3 {
		#partial switch _ in fds[i] {
		case rc.Fd_Inherit, rc.Fd_Closed:
		case:
			say("rc: exec with a file, here document or capture redirected needs the shell to stay (for now)", "", "\n")
			set_status("exec redirection")
			rt.close_all(..io[:])
			return true
		}
		io[i], st = stage_io(fds[i], i, vx.HANDLE_NONE, vx.HANDLE_NONE)
		if st != .Ok {
			rt.close_all(..io[:])
			break
		}
	}
	if st == .Ok {
		_, st = spawn(argv.next, io, exec = true) // returns only if it failed
	}
	why := p9.error_text(st)
	say("", rc.text(argv.next), ": ")
	say("", why, "\n")
	set_status(why)
	sh.exiting = true // as rc's: it exits all the same
	return true
}

// wait [pid]: for a command run with &, or for all of them; $status its wait
// message (rc's execwait).
wait_builtin :: proc "contextless" (argv: ^rc.Word, argc: int) -> bool {
	if argc > 2 {
		say("rc: Usage: wait [pid]", "", "\n")
		set_status("error")
		return true
	}
	want: u64
	if argc == 2 {
		for c in transmute([]u8)rc.text(argv.next) {
			if c < '0' || c > '9' {
				break
			}
			want = want * 10 + u64(c - '0')
		}
	}
	set_status("")
	for &t in background {
		if t == vx.HANDLE_NONE {
			continue
		}
		info, ist := rt.task_info(t)
		if ist != .Ok || (want != 0 && info.id != want) {
			continue
		}
		if info.state != .Exited {
			if port, pst := rt.port_create(); pst == .Ok {
				if rt.port_bind(port, t, .Exit, 0) == .Ok {
					pk: [1]vx.Packet
					_, _ = rt.port_wait(port, vx.INFINITE, 0, pk[:])
				}
				_ = rt.handle_close(port)
			}
		}
		if info, ist = rt.task_info(t); ist == .Ok {
			msg: [dynamic; vx.ERRMAX + 64]u8
			wait_message(&msg, &info)
			set_status(string(msg[:]))
		}
		_ = rt.handle_close(t)
		t = vx.HANDLE_NONE
	}
	return true
}

// Notes, to rc's functions for them (rc's notifyf): what rc has a name for
// (rc.note_trap), sigint and the rest; any other, as the system does by
// default.
on_note :: proc "contextless" (e: ^vx.Exception, note: string, fp: rawptr) -> rt.Noted {
	sig, ok := rc.note_trap(note)
	if !ok {
		return .Dflt
	}
	rc.trap(&sh, sig)
	return .Cont
}

// --- The shell ---

heap: [4 << 20]u8

// The last $status, as rc exits with it: its first word, or nothing when it
// is true (0s and |s), as rc's Exit; cut to whole runes (ADR-0013).
exit_status :: proc "contextless" () -> string {
	w := rc.get_var(&sh, "status")
	if w == nil {
		return ""
	}
	s := rc.text(w)
	for c in transmute([]u8)s {
		if c != '0' && c != '|' {
			s = s[:utf.cut(s, vx.ERRMAX)]
			return str.from_nul_padded(transmute([]u8)s) // upstream's exit string is a C string
		}
	}
	return ""
}

// What a read gave past the line Host.read_line asked for.
pending: [dynamic; 4096]u8

// Host.read_line: a line of the shell's standard input ('#d/0').
read_line :: proc "contextless" (ctx: rawptr, buf: []u8) -> int {
	n := 0
	for {
		for len(pending) > 0 && n < len(buf) {
			c := pending[0]
			ordered_remove_first(&pending)
			buf[n] = c
			n += 1
			if c == '\n' {
				return n
			}
		}
		if n == len(buf) {
			return n
		}
		resize(&pending, cap(pending))
		got, _ := rt.read(pending[:])
		resize(&pending, max(got, 0))
		if got <= 0 {
			return n
		}
	}
}

// The first byte of a fixed array taken off, the rest moved down.
ordered_remove_first :: proc "contextless" (a: ^[dynamic; 4096]u8) {
	copy(a[:], a[1:])
	resize(a, len(a) - 1)
}

// Writes s into b as an rc word, quoted, as upstream's bootstrap does: cut
// to leave room for what follows it.
quoted :: proc "contextless" (b: ^[dynamic; 512]u8, room: int, s: string) {
	limit := cap(b) - room
	if len(b) < limit {
		append(b, '\'')
	}
	for i := 0; i < len(s) && len(b) + 2 < limit; i += 1 {
		if s[i] == '\'' {
			append(b, '\'')
		}
		append(b, s[i])
	}
	if len(b) < limit {
		append(b, '\'')
	}
}

// The host's builtins, for whatis.
HOST_BUILTINS := [?]string{"bind", "mount", "unmount"}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(shell())
}

// As 9front's rc: the flags, $pid $rcname and $cflag, then rcmain.
shell :: proc() -> string {
	if procns.from_spawn(&space) != .Ok {
		rt.eprint("rc: the namespace is incomplete\n")
	}
	host := rc.Host {
		run       = run,
		write     = write_out,
		readdir   = read_dir,
		builtin   = builtin,
		read_file = read_whole,
		open      = open_file,
		close     = close_file,
		exists    = exists,
		read_line = read_line,
		builtin_names = HOST_BUILTINS[:],
	}
	if !rc.init(&sh, heap[:], host) {
		return "no memory"
	}
	import_env()
	_ = rt.notify(on_note)

	// The flags, as rc's getflags("srdiIlxebpvVc:1m:1").
	args := rt.args()
	cflag, rcmain := "", "/rc/lib/rcmain"
	i := 0
	flags: for ; i < len(args); i += 1 {
		a := args[i]
		if len(a) < 2 || a[0] != '-' {
			break
		}
		if a == "--" {
			i += 1
			break
		}
		for k in 1 ..< len(a) {
			f := a[k]
			if f == 'c' || f == 'm' { // its argument: the rest of the word, or the next
				v := a[k + 1:]
				if v == "" && i + 1 < len(args) {
					i += 1
					v = args[i]
				}
				if v == "" {
					rt.eprint(usage_of.TEXT, "\n")
					return "usage"
				}
				if f == 'c' {
					cflag = v
				} else {
					rcmain = v
				}
				sh.flag[f] = true
				continue flags
			}
			if str.index_byte("srdiIlxebpvV", f) < 0 {
				rt.eprint(usage_of.TEXT, "\n")
				return "usage"
			}
			sh.flag[f] = true
		}
	}
	input, _, _ := rt.stdio_handles()
	if sh.flag['I'] {
		sh.flag['i'] = false
	} else if !sh.flag['i'] && i == len(args) && input == vx.HANDLE_NONE { // no file, and the console: interactive
		sh.flag['i'] = true
	}

	id: u64
	if me, st := rt.task_info(rt.self); rt.self != vx.HANDLE_NONE && st == .Ok {
		id = me.id
	}
	digits: [str.U64_DIGITS]u8
	rc.set_var(&sh, "pid", str.format_u64(digits[:], id))
	rc.set_var(&sh, "rcname", "rc")
	if cflag != "" {
		rc.set_var(&sh, "cflag", cflag)
	}
	rc.set_var(&sh, "*", ..args[i:][:min(len(args) - i, CHILD_MAX_ARGS)])
	if !sh.flag['p'] {
		import_fns()
	}

	// rc's bootstrap: . -bq rcmain $*, then exit.
	boot: [dynamic; 512]u8
	append(&boot, ". -bq ")
	quoted(&boot, 8, rcmain)
	append(&boot, " $*\n")
	_ = rc.run(&sh, string(boot[:]))
	rc.sigexit(&sh) // at the end of the input too, once
	return exit_status()
}
