// rc: the shell, Plan 9's rc (upstream docs/04 §5; M2, its language since M4
// step 7, named gsh until upstream's M6 step 6a4, made 9front's in step 6a6).
// Its language is vx:rc's; this is the host it runs on, and its start.
//
//   rc [-srdiIlxebpvV] [-c command] [-m initial] [file [arg ...]]
//
// As 9front's rc, it reads its flags, sets $pid, $rcname, $cflag and $user, and runs
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
// What 9front's rc runs in a forked child and is not a program (a stage that
// is a function, builtin or block, &, @, `{...}) runs in a child rc: this
// program, spawned with an rcchild= record (upstream's M6 step 6d7b1).
// Descriptors 3 to 9 are given to programs as the musl back end's fd=
// records, and <{...} and >{...} are 9front's, a pipe and /fd/N (upstream's
// 6d7b2, ADR-0018).
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
import "vx:process"
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

// --- cd (ADR-0017, upstream's ADR-0039), as 9front's execcd ---

// One try: dir, joined to a $cdpath entry as 9front's makepath joins them,
// into buf.
cd_try :: proc "contextless" (entry, dir: string, buf: []u8) -> (tried: string, st: vx.Status) {
	n := len(entry)
	for n > 0 && entry[n - 1] == '/' {
		n -= 1
	}
	dir := dir
	for len(entry) > 0 && len(dir) > 0 && dir[0] == '/' {
		dir = dir[1:]
	}
	if len(entry) == 0 {
		tried = dir
	} else {
		if n + 1 + len(dir) >= len(buf) {
			return "", .Err_Range
		}
		copy(buf, entry[:n])
		buf[n] = '/'
		copy(buf[n + 1:], dir)
		tried = string(buf[:n + 1 + len(dir)])
	}
	return tried, procns.chdir(&space, tried)
}

chdir_why :: proc "contextless" (st: vx.Status) -> string {
	return st == .Err_Invalid ? "not a directory" : p9.error_text(st)
}

// cd [dir]: to dir, a relative one through $cdpath unless it starts with /,
// ./ or ../ (9front's searchpath), printing where it went when an entry
// other than "" or "." found it; to $home without one.
cd_builtin :: proc "contextless" (argv: ^rc.Word, n: int) {
	set_status("can't cd")
	if n > 2 {
		err("Usage: cd [directory]\n")
		return
	}
	if n == 1 {
		home := rc.get_var(&sh, "home")
		if home == nil {
			err("Can't cd -- $home empty\n")
			return
		}
		if st := procns.chdir(&space, rc.text(home)); st == .Ok {
			set_status("")
		} else {
			say("Can't cd ", rc.text(home), ": ")
			err(chdir_why(st))
			err("\n")
		}
		return
	}
	dir := rc.text(argv.next)
	searched := len(dir) > 0 && dir[0] != '/' && dir[0] != '#' && !(dir == "." || dir == ".." || str.has_prefix(dir, "./") || str.has_prefix(dir, "../"))
	none: rc.Word // "": the current directory alone (not a heap word: no text)
	cdpath := searched ? rc.get_var(&sh, "cdpath") : nil
	if cdpath == nil {
		cdpath = &none
	}
	st := vx.Status.Err_Not_Found
	for e := cdpath; e != nil; e = e.next {
		buf: [512]u8
		entry := e == &none ? "" : rc.text(e)
		tried: string
		tried, st = cd_try(entry, dir, buf[:])
		if st != .Ok {
			continue
		}
		if entry != "" && entry != "." {
			err(tried)
			err("\n")
		}
		set_status("")
		return
	}
	say("Can't cd ", dir, ": ")
	err(chdir_why(st))
	err("\n")
}

// --- rfork (upstream's 6d7b3), as 9front's execrfork ---

// A note group of the shell's own (rfork s, RFNOTEG): its own pid written
// to its noteid (procfs, as 9front's changenoteid allows).
own_note_group :: proc "contextless" () -> vx.Status {
	if rt.self == vx.HANDLE_NONE {
		return .Err_Bad_State
	}
	me := rt.task_info(rt.self) or_return
	digits: [str.U64_DIGITS]u8
	id := str.format_u64(digits[:], me.id)
	path_buf: [40]u8
	path := str.join(path_buf[:], "/proc/", id, "/noteid") or_else ""
	f: ns.File
	ns.open(&space, path, p9.OWRITE, &f) or_return
	_, st := ns.write(&f, transmute([]u8)id)
	ns.close(&f)
	return st
}

// What updenv (below) last wrote to /env: each name, with hashes of it and
// its value, and the spawn that last exported it (env_round), so one gone
// from the shell since is removed from /env too (the review of 2026-10-07,
// upstream's 2cc4729).
Env_Seen :: struct {
	name, value: u64, // FNV-1a hashes; name 0: the slot is free
	round:       u32,
	text:        [dynamic; 256]u8, // the name
}
env_seen: [512]Env_Seen
env_round: u32

// rfork [fnesFNEm]; without flags, ens. n: a namespace of the shell's own, a
// copy (it leaves its namespace group); N: a clean one, empty; m: no mounts
// after; s: a note group of its own; F: its descriptors past 2 closed; e: an
// environment group of its own, a copy; E: an empty one (ADR-0022, upstream's
// ADR-0044). f changes nothing: the descriptors are the shell's own already.
rfork_builtin :: proc "contextless" (argv: ^rc.Word, n: int) {
	flags := ""
	if n == 1 {
		flags = "ens"
	}
	if n == 2 {
		flags = rc.text(argv.next)
	}
	ok := n <= 2 && len(flags) > 0
	for c in transmute([]u8)flags {
		ok = ok && str.index_byte("fnesFNEm", c) >= 0
	}
	if !ok {
		err("Usage: rfork [fnesFNEm]\n")
		set_status("rfork usage")
		return
	}
	has :: proc "contextless" (flags: string, c: u8) -> bool {
		return str.index_byte(flags, c) >= 0
	}
	st := vx.Status.Ok
	if has(flags, 's') {
		st = own_note_group() // first: N takes /proc away
	}
	if st == .Ok && (has(flags, 'n') || has(flags, 'N')) {
		procns.group_leave(&space)
	}
	if st == .Ok && has(flags, 'N') {
		ns.reset(&space)
	}
	if st == .Ok && has(flags, 'm') {
		space.nomount = true // and the children's after (vx:ns, upstream's 6d7c)
	}
	if st == .Ok && (has(flags, 'e') || has(flags, 'E')) && procns.env_fork(&space, !has(flags, 'E')) == .Ok && has(flags, 'E') {
		env_seen = {} // an empty group: every variable written again at the next spawn
	}
	if st == .Ok && has(flags, 'F') { // a clean table: none past 2
		rt.fds_close()
	}
	if st != .Ok {
		err("rc: rfork failed\n")
		set_status("rfork failed")
		return
	}
	set_status("")
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
	case "cd":
		cd_builtin(argv, n)
		return true
	case "rfork":
		rfork_builtin(argv, n)
		return true
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

// <{...} and >{...}'s pipe ends (upstream's 6d7b2), handles PIPE_BASE and on.
PIPE_BASE :: u32(1) << 16
MAX_PIPES :: 16
pipe_ends: [MAX_PIPES]vx.Handle

close_file :: proc "contextless" (ctx: rawptr, handle: u32) {
	if handle >= PIPE_BASE && handle - PIPE_BASE < MAX_PIPES {
		rt.close_all(pipe_ends[handle - PIPE_BASE])
		pipe_ends[handle - PIPE_BASE] = vx.HANDLE_NONE
		return
	}
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

// A #! script load found on the way (upstream's 6d7c, as 9front's kernel
// runs one): where it is, and its first line, the interpreter and its
// arguments.
Script :: struct {
	path: [dynamic; 256]u8,
	line: [dynamic; 256]u8,
}

script: Script
script_found: bool

// Loads a program through the namespace, found as rc's searchpath finds it:
// a name that starts / ./ ../ or # as written, any other in each of $path's
// directories ("" and . meaning as written). Returns its size (what a spawn
// needs of it), or 0; a #! script found first stops the search (script).
load :: proc "contextless" (name: string) -> int {
	script_found = false
	here := str.has_prefix(name, "/") || str.has_prefix(name, "#") || str.has_prefix(name, "./") || str.has_prefix(name, "../")
	dirs := here ? nil : rc.get_var(&sh, "path")
	if dirs == nil {
		return load_in("", name)
	}
	for d := dirs; d != nil && !script_found; d = d.next {
		if size := load_in(rc.text(d), name); size != 0 {
			return size
		}
	}
	return 0
}

// Loads dir/name into image: its size, or 0 (script_found set if it is a
// #! script).
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
	if size > 2 && image[0] == '#' && image[1] == '!' { // a script: its interpreter runs it
		k := 2
		for k < size && k - 2 < cap(script.line) && image[k] != '\n' {
			k += 1
		}
		clear(&script.line)
		_ = append(&script.line, ..image[2:k])
		clear(&script.path)
		_ = append(&script.path, ..path_buf[:n])
		script_found = true
	}
	return 0
}

// The words of a #! line: the interpreter, then its arguments, split at
// blanks (9front's shargs), eight at most.
script_words :: proc "contextless" (w: ^[dynamic; 8]string) {
	line := string(script.line[:])
	for i := 0; i < len(line) && len(w) < cap(w); {
		for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
			i += 1
		}
		from := i
		for i < len(line) && line[i] != ' ' && line[i] != '\t' {
			i += 1
		}
		if i > from {
			_ = append(w, line[from:i])
		}
	}
}

// 9front's Updenv (plan9.c), at each spawn: a variable or function whose
// value changed since the last is written to /env, the shell's environment
// group (ADR-0022), which its children share. A hash of each one's value is
// kept, so an unchanged one costs nothing; a table too full writes on.

fnv :: proc "contextless" (s: string) -> u64 {
	h := u64(0xcbf2_9ce4_8422_2325)
	for c in transmute([]u8)s {
		h = (h ~ u64(c)) * 0x100_0000_01b3
	}
	return h | 1
}

// env is NAME=VALUE, eq the '='s place.
updenv :: proc "contextless" (env: string, eq: int) {
	nh, vh := fnv(env[:eq]), fnv(env[eq + 1:])
	at := int(nh % len(env_seen))
	for probe := 0; probe < 8 && env_seen[at].name != 0 && env_seen[at].name != nh; probe += 1 {
		at = (at + 1) % len(env_seen)
	}
	if env_seen[at].name == nh {
		env_seen[at].round = env_round // exported still
	}
	if env_seen[at].name == nh && env_seen[at].value == vh {
		return
	}
	if eq >= 256 {
		return
	}
	path_buf: [8 + 256]u8
	path := str.join(path_buf[:], "/env/", env[:eq]) or_else ""
	f: ns.File
	if ns.create(&space, path, 0o664, {access = .Write, trunc = true}, &f) != .Ok {
		return // no group
	}
	n, wst := ns.write(&f, transmute([]u8)env[eq + 1:])
	ns.close(&f)
	if wst == .Ok && n == len(env) - eq - 1 && (env_seen[at].name == 0 || env_seen[at].name == nh) {
		env_seen[at] = {
			name  = nh,
			value = vh,
			round = env_round,
		}
		_ = append(&env_seen[at].text, env[:eq])
	}
}

// After a spawn's exports: what the shell no longer has (x=(), a function
// deleted) goes from /env too, as 9front's rc empties it there.
env_prune :: proc "contextless" () {
	for &e in env_seen {
		if e.name == 0 || e.round == env_round {
			continue
		}
		path_buf: [8 + 256]u8
		if path, ok := str.join(path_buf[:], "/env/", string(e.text[:])); ok {
			if c, fid, st := ns.walk(&space, path); st == .Ok {
				_ = p9.client_remove(c, fid)
			}
		}
		e = {}
	}
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
	words := 0
	for w := val; w != nil; w = w.next {
		words += 1
		if words > CHILD_MAX_ARGS { // more than a child takes: refused, never cut (the Rust port's finding)
			rec.failed = true
			return false
		}
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
	updenv(str.to_string(&env), len(name))
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
	updenv(str.to_string(&env), 3 + len(name))
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
		// More words than a list here holds: not set at all, rather than cut
		// (an rc parent refuses to export one: export_var).
		words_in := 1
		for c in transmute([]u8)e[eq + 1:] {
			words_in += int(c == 1)
		}
		if words_in > CHILD_MAX_ARGS {
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

// The shell itself, for what 9front's rc runs in a forked child (upstream's
// 6d7b1).
RC_SELF :: "/boot/bin/rc"

// Whether a spawn is a command run with &'s: in a note group of its own, as
// 9front's rc runs `rfork s` in its child (code.c's Xasync), so the
// terminal's interrupt does not reach it. Not a <{...}'s (its Xpipefd's has
// none).
spawn_noteg: bool
in_pipefd: bool // pipe_fd's run: not an & job

// A file the shell opened, a descriptor from 3: the musl back end's fd=N
// file=PATH flags=F offset=O token=T (ADR-0018), the open file itself, which
// the program joins, so it takes nothing from it until it reads: a relay
// would read it for the program whether or not it does.
O_WRONLY :: 1 // musl's, Linux's values
O_RDWR :: 2
O_APPEND :: 0o2000

passed_file :: proc "contextless" (fd: rc.Fd) -> bool {
	_, is := fd.(rc.Fd_File)
	return is
}

file_record :: proc "contextless" (rec: ^ndb.Writer, n: int, file: rc.Fd_File) {
	if file.handle >= MAX_FILES || !files[file.handle].used {
		return
	}
	f := &files[file.handle].f
	flags: u64
	switch file.kind {
	case .Read:
	case .Rdwr:
		flags = O_RDWR
	case .Write:
		flags = O_WRONLY
	case .Append:
		flags = O_WRONLY | O_APPEND
	}
	ndb.put_u64(rec, "fd", u64(n))
	ndb.put(rec, "file", file.path)
	ndb.put_u64(rec, "flags", flags)
	ndb.put_u64(rec, "offset", f.offset)
	if f.c != nil {
		if token, st := p9.client_share(f.c, f.fid, 1); st == .Ok {
			ndb.put(rec, "token", string(token[:]))
		}
	}
	_ = ndb.end(rec)
}

// One of the shell's own descriptors that is an open file it was given:
// passed on as it was given, but for its token, which was good once.
own_file_record :: proc "contextless" (rec: ^ndb.Writer, n: int, e: ^rt.Fd_Entry) {
	ndb.put_u64(rec, "fd", u64(n))
	ndb.put(rec, "file", string(e.path[:]))
	ndb.put_u64(rec, "flags", u64(e.flags))
	ndb.put_u64(rec, "offset", e.offset)
	_ = ndb.end(rec)
}

// Spawns one program with its standard input, output and error (channel
// ends, or HANDLE_NONE for the console), which are given away. child: argv
// is rc code and its $*, which a child rc runs (an rcchild= record,
// run_child), given the shell's flags, variables, functions, namespace and
// directory, as rc's fork gives them. With exec, the program takes this
// task's place (task_exec, ADR-0012): it returns only if it failed.
spawn :: proc "contextless" (argv: ^rc.Word, child: bool, io: [rc.FDS]vx.Handle, reads: [rc.FDS]bool, fds: [rc.FDS]rc.Fd, exec := false) -> (task: vx.Handle, st: vx.Status) {
	IO := [rc.FDS]string{"stdin", "stdout", "stderr", "fd3", "fd4", "fd5", "fd6", "fd7", "fd8", "fd9"}
	io := io
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	count := 0
	given := false // to spawn_elf, which takes them whatever happens
	defer if !given {
		rt.close_all(..handles[:count])
		rt.close_all(..io[:])
	}
	size := load(child ? RC_SELF : rc.text(argv))
	rec := ndb.Writer{buf = records[:]}
	args, exported := 0, 0
	base := child ? "rc" : rc.text(argv) // the task's name: the program's, without its directory
	// #!interpreter [args] (upstream's 6d7c): it, given those, the script's
	// path, then the arguments.
	spath: [dynamic; 256]u8
	interp: [dynamic; 256]u8
	if size == 0 && script_found {
		_ = append(&spath, ..script.path[:])
		w: [dynamic; 8]string
		script_words(&w)
		if len(w) > 0 && len(w[0]) < cap(interp) {
			_ = append(&interp, w[0])
			size = load(string(interp[:]))
			if script_found {
				size = 0 // a script's interpreter is a program, not another script
			}
		}
		for i := 1; size != 0 && i < len(w); i += 1 {
			ndb.put(&rec, "arg", w[i])
			_ = ndb.end(&rec)
			args += 1
		}
		if size != 0 {
			ndb.put(&rec, "arg", string(spath[:]))
			_ = ndb.end(&rec)
			args += 1
			base = string(interp[:])
		}
	}
	if size == 0 {
		return vx.HANDLE_NONE, .Err_Not_Found
	}
	if child {
		flags: [dynamic; 64]u8
		for f in u8('A') ..= u8('z') {
			if sh.flag[f] && f != 'c' && f != 'm' && len(flags) < cap(flags) {
				append(&flags, f)
			}
		}
		ndb.put(&rec, "rcchild", rc.text(argv)) // the code; its $* as the arguments
		if len(flags) > 0 {
			ndb.put(&rec, "flags", string(flags[:]))
		}
		_ = ndb.end(&rec)
	}
	for a := argv.next; a != nil; a = a.next {
		ndb.put(&rec, "arg", rc.text(a))
		_ = ndb.end(&rec)
		args += 1
	}
	for i in 3 ..< rc.FDS { // 3 to 9 as the musl back end's records have them (ADR-0018)
		if file, is := fds[i].(rc.Fd_File); is {
			file_record(&rec, i, file)
		}
		if own, is := fds[i].(rc.Fd_Inherit); is {
			if e := rt.fd_file(int(own.which)); e != nil {
				own_file_record(&rec, i, e)
			}
		}
		if io[i] == vx.HANDLE_NONE {
			continue
		}
		digit := [1]u8{'0' + u8(i)}
		ndb.put(&rec, "fd", string(digit[:]))
		ndb.put(&rec, "pipe", reads[i] ? "read" : "write")
		ndb.put(&rec, "end", IO[i])
		_ = ndb.end(&rec)
	}
	env_round += 1 // updenv marks what this spawn exports; env_prune removes the rest
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
	env_prune()
	// More than a spawn message holds, or than the child takes: refused
	// whole, never run with a list cut short.
	if rec.failed || args > CHILD_MAX_ARGS || exported > CHILD_MAX_ARGS {
		return vx.HANDLE_NONE, .Err_Range
	}
	count = procns.spawn_records(&space, &rec, handles[:vx.CHANNEL_MAX_HANDLES - 1 - 1 - rc.FDS], names[:], 0) or_return
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
	path := base // the program's whole path, its exe= record
	base = base[str.last_index_byte(base, '/') + 1:]
	a := rt.Spawn_Args {
		name         = base[:utf.cut(base, MAX_TASK_NAME)], // whole runes (ADR-0013)
		path         = path,
		image        = image[:size],
		handles      = handles[:count],
		handle_names = names[:count],
		records      = ndb.written(&rec),
		exec         = exec,
		// Registered with whatever serves /proc (ADR-0011): the shell watches
		// each command's end itself, so no wait record.
		proc_conn    = ns.connector(&space, "/proc"),
		proc_flags   = spawn_noteg ? process.Flags{.No_Wait, .Note_Group} : process.Flags{.No_Wait},
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
		case rc.Fd_Inherit, rc.Fd_Dup, rc.Fd_Closed, rc.Fd_Pipe_Out, rc.Fd_Pipe_In, rc.Fd_Here, rc.Fd_Pipefd: // never relayed out
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

// One of the shell's own descriptors, 0 to 9 (vx:rt's; ADR-0018), and
// whether it reads.
own_fd :: proc "contextless" (which: u8) -> (end: vx.Handle, reads: bool) {
	return rt.fd_pipe(int(which))
}

// Whether two descriptors go to the one relayed thing: the same file the
// shell opened, here document or capture.
same_relay :: proc "contextless" (a, b: rc.Fd) -> bool {
	#partial switch x in a {
	case rc.Fd_File:
		y, is := b.(rc.Fd_File)
		return is && x.kind == y.kind && x.handle == y.handle && raw_data(x.path) == raw_data(y.path)
	case rc.Fd_Capture:
		y, is := b.(rc.Fd_Capture)
		return is && x.index == y.index
	case rc.Fd_Here:
		y, is := b.(rc.Fd_Here)
		return is && raw_data(x.text) == raw_data(y.text)
	}
	return false
}

// Whether the program reads descriptor i, given where it goes: 0 always; 3
// to 9 as their redirection or the shell's own descriptor has it.
stage_reads :: proc "contextless" (fd: rc.Fd, i: int) -> bool {
	if i < 3 {
		return i == 0
	}
	#partial switch v in fd {
	case rc.Fd_Inherit:
		_, reads := own_fd(v.which)
		return reads
	case rc.Fd_Pipefd:
		return v.reads // the command's end, which it reads or writes
	case rc.Fd_File:
		return v.kind == .Read
	case rc.Fd_Here, rc.Fd_Pipe_In:
		return true
	}
	return false
}

// A channel no one is at the other end of: reads end, writes fail.
unheard :: proc "contextless" () -> (io: vx.Handle, st: vx.Status) {
	a, b := rt.channel_create() or_return
	_ = rt.handle_close(b)
	return a, .Ok
}

// A stage's descriptor: the program's channel end (or none, for the
// console), making relays and joining pipes as need be.
stage_io :: proc "contextless" (fd: rc.Fd, reads: bool, pipe_in, pipe_out: vx.Handle) -> (io: vx.Handle, st: vx.Status) {
	share: vx.Handle
	switch v in fd {
	case rc.Fd_Inherit:
		share, _ = own_fd(v.which)
	case rc.Fd_Pipefd:
		if v.handle - PIPE_BASE < MAX_PIPES {
			share = pipe_ends[v.handle - PIPE_BASE]
		}
	case rc.Fd_Pipe_In:
		share = pipe_in
	case rc.Fd_Pipe_Out:
		share = pipe_out
	case rc.Fd_Closed, rc.Fd_Dup: // a copy left is of no descriptor
		return unheard()
	case rc.Fd_Here: // read; on an output it is no file, as 9front's read-only one takes no writes (upstream f24356f)
		if !reads {
			return unheard()
		}
		return relay_for(fd, true)
	case rc.Fd_File, rc.Fd_Capture:
		return relay_for(fd, reads)
	}
	if share == vx.HANDLE_NONE {
		return vx.HANDLE_NONE, .Ok
	}
	return rt.handle_dup(share, vx.RIGHTS_SAME)
}

ends: [MAX_STAGES][dynamic; vx.ERRMAX]u8 // each command's exit string, for $status

// Host.run: a pipeline's programs, each spawned with its descriptors; then,
// unless async, the relays served until they and the programs are done.
run :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, stages: []rc.Command, async: bool) -> (pid: u64, ok: bool) {
	spawn_noteg = async && !in_pipefd
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
		pipe: [2]vx.Handle // this stage's output, the next one's input
		io: [rc.FDS]vx.Handle
		reads: [rc.FDS]bool
		st := vx.Status.Ok
		if s + 1 < n {
			pipe[0], pipe[1], st = rt.channel_create()
		}
		fds := c.fds
		if own, is := fds[0].(rc.Fd_Inherit); async && is && own.which == 0 {
			fds[0] = rc.Fd_Closed{} // & reads nothing, as rc's /dev/null
		}
		for i in 0 ..< rc.FDS { // 3 to 9 too (ADR-0018)
			if st != .Ok {
				break
			}
			reads[i] = stage_reads(fds[i], i)
			if i >= 3 && passed_file(fds[i]) {
				continue // the open file itself (spawn's file_record)
			}
			// A descriptor on the same file, here document or capture as one
			// before it (>[2=1], <[0=3]): that one's channel, as a dup shares
			// an open file; two relays would each take part of it.
			same := i
			for j in 0 ..< i {
				if io[j] != vx.HANDLE_NONE && same_relay(fds[i], fds[j]) {
					same = j
					break
				}
			}
			if same < i {
				reads[i] = reads[same]
				io[i], st = rt.handle_dup(io[same], vx.RIGHTS_SAME)
			} else {
				io[i], st = stage_io(fds[i], reads[i], pipe_in, pipe[0])
			}
		}
		rt.close_all(pipe_in, pipe[0])
		pipe_in = pipe[1]
		if st == .Ok {
			tasks[s], st = spawn(c.argv, c.child, io, reads, fds)
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
			for part in ([?]string{c.child ? "rc" : rc.text(c.argv), ": ", why, "\n"}) {
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
			// An ended one is kept until wait takes its status (the Rust port's
			// finding: let go before every command, wait found nothing); only a
			// new one needing its place lets one go.
			slot := 0
			for slot < MAX_BACKGROUND && background[slot] != vx.HANDLE_NONE {
				slot += 1
			}
			if slot == MAX_BACKGROUND {
				reap()
				slot = 0
			}
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
	io: [rc.FDS]vx.Handle
	reads: [rc.FDS]bool
	st := vx.Status.Ok
	for i in 0 ..< rc.FDS {
		fd := fds[i]
		passed := i >= 3 && passed_file(fd)
		#partial switch _ in fd {
		case rc.Fd_Inherit, rc.Fd_Closed:
		case:
			if !passed {
				say("rc: exec with a file, here document or capture redirected needs the shell to stay (for now)", "", "\n")
				set_status("exec redirection")
				rt.close_all(..io[:])
				return true
			}
		}
		reads[i] = stage_reads(fd, i)
		if !passed {
			io[i], st = stage_io(fd, reads[i], vx.HANDLE_NONE, vx.HANDLE_NONE)
		}
		if st != .Ok {
			rt.close_all(..io[:])
			break
		}
	}
	if st == .Ok {
		_, st = spawn(argv.next, false, io, reads, fds^, exec = true) // returns only if it failed
	}
	why := p9.error_text(st)
	say("", rc.text(argv.next), ": ")
	say("", why, "\n")
	set_status(why)
	sh.exiting = true // as rc's: it exits all the same
	return true
}

// Host.pipefd (upstream's 6d7b2): a pipe, child started with & on its far
// end as its standard output (or input, when the command writes), as 9front's
// Xpipefd forks it; the near end the command's, PIPE_BASE + its slot.
pipe_fd :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, child: ^rc.Command, command_reads: bool) -> (handle: u32, ok: bool) {
	near := u32(0)
	for near < MAX_PIPES && pipe_ends[near] != vx.HANDLE_NONE {
		near += 1
	}
	far := near + 1
	for far < MAX_PIPES && pipe_ends[far] != vx.HANDLE_NONE {
		far += 1
	}
	if far >= MAX_PIPES {
		set_status("can't make pipe")
		return 0, false
	}
	a, b, st := rt.channel_create()
	if st != .Ok {
		set_status("can't make pipe")
		return 0, false
	}
	pipe_ends[near], pipe_ends[far] = a, b
	c := child^
	c.fds[command_reads ? 1 : 0] = rc.Fd_Pipefd{handle = PIPE_BASE + far, reads = !command_reads}
	in_pipefd = true
	_, ran := run(ctx, r, ([^]rc.Command)(&c)[:1], true)
	in_pipefd = false
	close_file(ctx, PIPE_BASE + far) // the child has its own
	if !ran {
		close_file(ctx, PIPE_BASE + near)
		return 0, false
	}
	return PIPE_BASE + near, true
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

child_code: [vx.CHANNEL_MAX_BYTES]u8
child_args: [dynamic; CHILD_MAX_ARGS]string

// A shell's child (upstream's 6d7b1): its code, run with the shell's state as
// the spawn message gives it, its flags, $*, variables (its $status and $pid
// the shell's) and functions; no rcmain, and no sigexit at its end, as
// 9front's forked rc runs neither.
run_child :: proc "contextless" (rec: ^ndb.Record) -> string {
	c, _ := ndb.get(rec, "rcchild")
	flags, _ := ndb.get(rec, "flags")
	if len(c) > len(child_code) {
		return "child code too long"
	}
	code := string(child_code[:copy(child_code[:], c)])
	for f in transmute([]u8)flags {
		if f < len(sh.flag) {
			sh.flag[f] = true
		}
	}
	clear(&child_args)
	for a in rt.args() {
		if append(&child_args, a) == 0 {
			break
		}
	}
	rc.set_var(&sh, "*", ..child_args[:])
	import_fns()
	_ = rc.run(&sh, code)
	return exit_status()
}

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
HOST_BUILTINS := [?]string{"cd", "rfork", "bind", "mount", "unmount"}

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
		pipefd    = pipe_fd,
	}
	if !rc.init(&sh, heap[:], host) {
		return "no memory"
	}
	import_env()
	_ = rt.notify(on_note)
	child: ndb.Record
	if rt.spawn_record("rcchild", &child) {
		return run_child(&child)
	}

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
	if str.has_prefix(rt.spawn.argv0, "-") {
		sh.flag['l'] = true // a login shell's name, as 9front's (upstream's 6d7c)
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
	if rc.get_var(&sh, "user") == nil { // who it runs as, as 9front's /env/user: the spawn message's user, or none (6d8)
		rc.set_var(&sh, "user", rt.spawn.user != "" ? rt.spawn.user : "none")
	}
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
