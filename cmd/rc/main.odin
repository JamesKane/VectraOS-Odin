// rc: the shell, Plan 9's rc (upstream docs/04 §5; M2, its language since M4
// step 7, named gsh until upstream's M6 step 6a4).
// Its language is rc's, from vx:rc: lists, quoting, ^, $#x and $x(n), if, if
// not, for, while, switch, ~, fn, !, && and ||, pipes, redirections, `{...},
// globbing, $status, $*:
//
//   ls /; cat /proc/1/status            commands, separated by ; or newlines
//   ns | tail -1                        pipes
//   echo kill > /proc/2/ctl             redirections: > >> < >[2=1] >[2]
//   for(p in `{ls /proc}) echo $p       command substitution
//   bind -a /boot/bin /bin              builtins: bind, mount, unmount, and rc's
//   rc script.rc a b                    a script, its arguments in $*
//
// A command is a program found as given (a path) or in /bin, then /boot/bin,
// through the shell's namespace. It is loaded by the shell and spawned with a
// copy of the namespace, the console, and its standard input, output and
// error: the shell's own, a pipe, or a channel the shell copies to or from a
// file (or into `{...}'s capture). The shell waits for a pipeline's commands,
// unless it ends with &, and $status is their exit strings, joined by |, as
// rc's (ADR-0010). Without fork, a pipeline's stages and & must be programs
// (vx:rc); descriptors past 2 are not given to programs yet.
//
// With no arguments the shell reads commands from its input, prompting; a
// construct left open (a brace, an if's condition) continues on the next line.
// At the end of its input, or of a script, or at exit, it exits with $status.
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

usage :: proc "contextless" (text: string) {
	err(text)
	set_status("usage")
}

// Host.builtin: true if argv's first word was one, which then ran, its
// messages to its own descriptor 2.
builtin :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, argv: ^rc.Word, argc: u32, fds: ^[rc.FDS]rc.Fd) -> bool {
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
			usage("usage: bind [-abc] new old\n")
		} else {
			report("bind", ns.bind(&space, w[first], w[first + 1], flags))
		}
		return true
	case "mount":
		// A service this namespace has a connection from (/srv/NAME, as ns
		// prints it, so its output replays), or a 9P server over TCP,
		// tcp!HOST!PORT or 9p://HOST:PORT.
		if !flags_ok || n - first < 2 || n - first > 3 {
			usage("usage: mount [-abc] /srv/name|tcp!host!port old [aname]\n")
			return true
		}
		from, old := w[first], w[first + 1]
		aname := n - first == 3 ? w[first + 2] : ""
		st: vx.Status
		if len(from) > 5 && str.has_prefix(from, "/srv/") {
			st = ns.mount_srv(&space, from, aname, old, flags)
		} else {
			c, src, dst := ns.dial(&space, from)
			st = dst
			if st == .Ok {
				st = ns.mount(&space, c, vx.HANDLE_NONE, src, aname, old, flags)
			}
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
			usage("usage: unmount [new] old\n")
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
		// rc does; >> writes at its end; <> reads and writes.
		mode := kind == .Rdwr ? p9.ORDWR : p9.OWRITE
		opened := mode
		opened.trunc = kind == .Write
		st = ns.open(&space, path, opened, f)
		if st == .Err_Not_Found {
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

// Loads a program through the namespace: the path as given, or /bin/NAME,
// then /boot/bin/NAME. Returns its size (what a spawn needs of it), or 0.
load :: proc "contextless" (name: string) -> int {
	DIRS := [3]string{"", "/bin/", "/boot/bin/"}
	has_slash := str.index_byte(name, '/') >= 0
	for dir, d in DIRS {
		if (d == 0) != has_slash {
			continue
		}
		path_buf: [256]u8
		path := str.join(path_buf[:], dir, name) or_continue
		f: ns.File
		if ns.open(&space, path, p9.OREAD, &f) != .Ok {
			continue
		}
		size, need := 0, 4096
		for size < need { // the headers, then as much as they say
			n, _ := ns.read(&f, image[size:][:min(need - size, 65536)])
			if n <= 0 {
				break
			}
			size += n
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
// ends, or HANDLE_NONE for the console), which are given away.
spawn :: proc "contextless" (argv: ^rc.Word, io: [3]vx.Handle) -> (task: vx.Handle, st: vx.Status) {
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
	}
	return rt.spawn_elf(&a)
}

// A channel the shell copies from (a program's output, into a file or a
// capture) or into (a file, as a program's input).
Relay :: struct {
	end:   vx.Handle, // the shell's end
	to:    rc.Fd, // a file's, or a capture's
	feed:  bool, // into the channel, from the file
	armed: bool,
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
		for {
			n := 0
			if file.handle < MAX_FILES && files[file.handle].used {
				n, _ = ns.read(&files[file.handle].f, relay_msg.bytes[:])
			}
			if n <= 0 {
				return false
			}
			relay_msg.header = {}
			st := rt.channel_write(rl.end, msg[:size_of(vx.Msg_Header) + n])
			if st == .Err_Should_Wait { // full: the rest later, from where this left off
				files[file.handle].f.offset -= u64(n)
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
		case rc.Fd_Inherit, rc.Fd_Dup, rc.Fd_Closed, rc.Fd_Pipe_Out, rc.Fd_Pipe_In: // never relayed
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
	case rc.Fd_Closed, rc.Fd_Dup: // a channel no one is at the other end of (a copy left is of no descriptor)
		a, b := rt.channel_create() or_return
		_ = rt.handle_close(b)
		return a, .Ok
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
		for i in 0 ..< 3 {
			if st != .Ok {
				break
			}
			if i == 2 && io[1] != vx.HANDLE_NONE && same_as_1(c.fds[2], c.fds[1]) {
				io[2], st = rt.handle_dup(io[1], vx.RIGHTS_SAME)
			} else {
				io[i], st = stage_io(c.fds[i], i, pipe_in, pipe[0])
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
			why := "cannot run it"
			#partial switch st {
			case .Err_Not_Found:
				why = "not found"
			case .Err_Range:
				why = "argument list too long"
			}
			// Where the command's own errors would go, as rc writes them.
			to := c.fds[2]
			#partial switch v in to {
			case rc.Fd_Pipe_Out, rc.Fd_Pipe_In:
				to = rc.Fd_Inherit{2}
			case rc.Fd_File:
				if v.kind == .Read {
					to = rc.Fd_Inherit{2}
				}
			}
			for part in ([?]string{"rc: ", rc.text(c.argv), ": ", why, "\n"}) {
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
		set_status("")
		return pid, true
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
						_ = append(&ends[p.key], vx.exit_string(&info))
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
	// The commands' exit strings, joined by |, as rc's $status.
	status_buf: [MAX_STAGES * (vx.ERRMAX + 1)]u8
	status := str.Buf{buf = status_buf[:]}
	for &e, s in ends[:n] {
		if s > 0 {
			str.write_byte(&status, '|')
		}
		str.write_bytes(&status, e[:])
	}
	rc.set_status(&sh, str.to_string(&status))
	return 0, true
}

// --- The shell ---

heap: [4 << 20]u8
text: [256 * 1024]u8 // a script's, or the lines of a construct still open

// The last $status, as rc exits with it: its words joined, cut to whole runes.
exit_status :: proc "contextless" () -> string {
	@(static) status: [dynamic; vx.ERRMAX]u8
	clear(&status)
	for w := rc.get_var(&sh, "status"); w != nil; w = w.next {
		s := rc.text(w)
		_ = append(&status, s[:utf.cut(s, cap(status) - len(status))])
		if w.next != nil && len(status) < cap(status) {
			_ = append(&status, ' ')
		}
	}
	return string(status[:])
}

show_error :: proc "contextless" () {
	rt.eprint(rc.err(&sh), "\n")
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(shell())
}

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
	}
	if !rc.init(&sh, heap[:], host) {
		return "no memory"
	}
	import_env()

	if args := rt.args(); len(args) > 0 { // rc FILE ARG ...: a script, its arguments in $*, its name in $0
		rc.set_var(&sh, "*", ..args[1:])
		rc.set_var(&sh, "0", args[0])
		n, ok := read_whole(nil, args[0], text[:])
		if !ok {
			say("rc: ", args[0], ": cannot read it\n")
			return "cannot read the script"
		}
		switch rc.run(&sh, string(text[:n])) {
		case .Incomplete:
			rt.eprint("rc: the script ends inside a construct\n")
			return "syntax error"
		case .Syntax:
			show_error()
			return "syntax error"
		case .Failed:
			show_error()
		case .Ok, .Exit:
		}
		return exit_status()
	}

	length := 0 // of text: the lines of a construct still open
	for {
		rt.print(length > 0 ? "\t" : "vx% ")
		start := length
		n := 0
		for {
			n, _ = rt.read(text[length:])
			if n <= 0 {
				break
			}
			length += n
			if text[length - 1] == '\n' || length == len(text) {
				break
			}
		}
		if n <= 0 && length == start {
			break // the end of the input
		}
		if length == len(text) && text[length - 1] != '\n' { // too long: refused whole, never run in pieces
			rest: [64]u8
			for {
				got, _ := rt.read(rest[:])
				if got <= 0 || rest[got - 1] == '\n' {
					break
				}
			}
			say("rc: line too long", "", "\n")
			set_status("line too long")
			length = 0
			continue
		}
		res := rc.run(&sh, string(text[:length]))
		if res == .Incomplete {
			continue // the next line continues it
		}
		length = 0
		#partial switch res {
		case .Syntax, .Failed:
			show_error()
		case .Exit:
			return exit_status()
		}
	}
	rt.print("\n")
	return exit_status()
}
