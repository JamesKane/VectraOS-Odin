// A host for vx:rc's tests: upstream's rc_test.c host (its programs echo,
// cat, wc, true, false, exitwith and warn write into buffers, its files are in
// memory, its directory has a few names for globbing, and a child, code run
// apart from the shell, is a second interpreter on the same host), with every
// callback logged into a transcript; and the deterministic mutator the
// cross-check shares with its C oracle, which runs upstream's rc.c with the
// same host and transcript format.
//
// Where upstream's host reads a word as a C string (a program's name, an
// exit status, a file name), this one does too: up to its first NUL.
package rctest

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:strings"
import "vx:rc"
import "vx:str"

// Upstream's struct rc, which its heap holds too (rc_new takes it from the
// front): a heap this much smaller is the same heap to the allocator, so the
// port runs out of memory where upstream does.
C_RC_SIZE :: 41712 // 41704, aligned

FILES :: 8

File :: struct {
	name: [dynamic; 31]u8, // upstream's char name[32]
	data: [dynamic; 1024]u8,
}

// The children running (upstream's 6d7b1), innermost last: what each was
// started with, so what one inherits is the stage's that started it.
Child_Io :: struct {
	parent: ^rc.Rc,
	fds:    [rc.FDS]rc.Fd, // the stage's
	input:  []u8, // its input
	pipe:   ^[dynamic]u8, // where its output into a pipe goes
}

CHILDREN :: 4
// Upstream's child heaps, 1 MiB each with the interpreter inside.
CHILD_HEAP :: 1 << 20 - C_RC_SIZE

// <{...} and >{...}'s pipes (upstream's 6d7b2): what one child wrote for the
// command to read, or what the command wrote for a >{...} child, run when it
// closes.
Pipe_Fd :: struct {
	used, command_reads: bool,
	data:                [dynamic]u8, // a command's writes past upstream's 1024 bytes are dropped
	r:                   ^rc.Rc,
	fds:                 [rc.FDS]rc.Fd, // the child's, but its end
	code:                [dynamic; 255]u8, // a >{...}'s, run at the close
}
PIPES :: 4
PIPE_HANDLE :: 100 // pipes_fd[i]'s handle: PIPE_HANDLE + i
PIPE_DATA :: 1024

Host :: struct {
	sh:          ^rc.Rc,
	// The children's interpreters and heaps, by depth (bench_make's), kept
	// over a reset; children and nchildren, those running.
	child_sh:    [CHILDREN]^rc.Rc,
	child_heap:  [CHILDREN][]u8,
	child_status: [CHILDREN][dynamic; 255]u8,
	children:    [CHILDREN]Child_Io,
	nchildren:   int,
	pipes_fd:    [PIPES]Pipe_Fd,
	files:       [FILES]File,
	open_now:    [FILES]bool, // the files the shell has open, by handle
	used_closed: bool, // a stage was given a file the shell had already closed
	opened:      int,
	closed:      int,
	out, err:    [dynamic]u8,
	exported:    [dynamic]u8, // exportx's: x's value as rc.next_var gives it
	log:         [dynamic]u8, // the transcript
	stdin:       string, // what rc's own standard input holds, a line at a time
	stdin_at:    int,
}

// The standard input transcripts give the shell, for `. -i '#d/0'`.
STDIN :: "echo in\nif(true) {\necho more\n}\nx=(); echo a^$x\necho last\n"

// Up to the first NUL, as C reads a string.
c_str :: proc(s: string) -> string {
	return str.from_nul_padded(transmute([]u8)s)
}

callbacks :: proc(h: ^Host) -> rc.Host {
	return rc.Host {
		ctx = h,
		run = run,
		write = write_fd,
		readdir = readdir_fake,
		read_file = read_file_fake,
		builtin = host_builtin,
		open = open_fake,
		close = close_fake,
		exists = exists_fake,
		read_line = read_line_fake,
		pipefd = pipefd_fake,
	}
}

reset :: proc(h: ^Host) {
	sh, child_sh, child_heap := h.sh, h.child_sh, h.child_heap
	delete(h.out)
	delete(h.err)
	delete(h.exported)
	delete(h.log)
	for &pf in h.pipes_fd {
		delete(pf.data)
	}
	h^ = {
		sh         = sh,
		child_sh   = child_sh,
		child_heap = child_heap,
	}
}

destroy :: proc(h: ^Host) {
	reset(h)
}

// --- The transcript ---

put :: proc(b: ^[dynamic]u8, s: string) {
	append(b, s)
}

putf :: proc(b: ^[dynamic]u8, format: string, args: ..any) {
	buf: [64]u8
	append(b, fmt.bprintf(buf[:], format, ..args))
}

esc :: proc(b: ^[dynamic]u8, s: string) {
	append(b, '[')
	for c in transmute([]u8)s {
		if c >= 0x20 && c < 0x7f && c != '[' && c != ']' && c != '\\' {
			append(b, c)
		} else {
			putf(b, "\\x%02x", c)
		}
	}
	append(b, ']')
}

KIND_CHAR := [rc.Open_Kind]u8 {
	.Read   = 'r',
	.Write  = 'w',
	.Append = 'a',
	.Rdwr   = 'x',
}

fd_desc :: proc(b: ^[dynamic]u8, fd: rc.Fd, with_path := true) {
	switch v in fd {
	case rc.Fd_Inherit:
		putf(b, " i%d", v.which)
	case rc.Fd_File:
		putf(b, " f%c%d:", rune(KIND_CHAR[v.kind]), v.handle)
		if with_path {
			esc(b, v.path)
		}
	case rc.Fd_Dup:
		putf(b, " d%d", v.of)
	case rc.Fd_Closed:
		put(b, " c")
	case rc.Fd_Capture:
		putf(b, " k%d", v.index)
	case rc.Fd_Pipe_Out:
		put(b, " po")
	case rc.Fd_Pipe_In:
		put(b, " pi")
	case rc.Fd_Here:
		put(b, " h")
		if with_path {
			esc(b, v.text)
		}
	case rc.Fd_Pipefd:
		putf(b, " P%d:%d", int(v.reads), v.handle)
	}
}

// --- The host ---

file_of :: proc(h: ^Host, path: string, make: bool) -> int {
	for &f, i in h.files {
		name := c_str(string(f.name[:]))
		if len(name) > 0 && name == path {
			return i
		}
	}
	if !make {
		return -1
	}
	for &f, i in h.files {
		if len(c_str(string(f.name[:]))) == 0 && len(path) < 32 {
			clear(&f.name)
			append(&f.name, path)
			clear(&f.data)
			return i
		}
	}
	return -1
}

// Output to where fd goes: a file, the capture of the interpreter that has
// it, a pipe, or out/err; a child's own descriptors are what the stage that
// started it had.
emit :: proc(h: ^Host, r: ^rc.Rc, fds: ^[rc.FDS]rc.Fd, which: int, s: string, pipe: ^[dynamic]u8) {
	r, fds, pipe := r, fds, pipe
	fd := fds[which]
	for d, guard := h.nchildren, 0; guard < 20; guard += 1 {
		for _ in 0 ..< 10 {
			dup, is := fd.(rc.Fd_Dup)
			if !is || dup.of >= rc.FDS {
				break
			}
			fd = fds[dup.of]
		}
		own, is := fd.(rc.Fd_Inherit)
		if !is || d == 0 {
			break
		}
		d -= 1
		io := &h.children[d]
		r, fds, pipe = io.parent, &io.fds, io.pipe
		fd = fds[own.which]
	}
	switch v in fd {
	case rc.Fd_Capture:
		put(&h.log, "  k")
		esc(&h.log, s)
		put(&h.log, "\n")
		rc.capture_write(r, fd, s)
		return
	case rc.Fd_Pipe_Out:
		put(&h.log, "  p")
		esc(&h.log, s)
		put(&h.log, "\n")
		append(pipe, s)
		return
	case rc.Fd_File:
		if v.kind == .Write || v.kind == .Append { // the file the shell opened
			putf(&h.log, "  f%d", v.handle)
			esc(&h.log, s)
			if v.handle < FILES && len(h.files[v.handle].data) + len(s) <= cap(h.files[v.handle].data) {
				append(&h.files[v.handle].data, s)
			} else {
				put(&h.log, "!")
			}
			put(&h.log, "\n")
			return
		}
	case rc.Fd_Closed:
		return
	case rc.Fd_Pipefd: // a >{...}'s
		k := v.handle - PIPE_HANDLE
		putf(&h.log, "  P%d", v.handle)
		esc(&h.log, s)
		put(&h.log, "\n")
		if k < PIPES && len(h.pipes_fd[k].data) + len(s) <= PIPE_DATA {
			append(&h.pipes_fd[k].data, s)
		}
		return
	case rc.Fd_Inherit, rc.Fd_Dup, rc.Fd_Pipe_In, rc.Fd_Here:
	}
	if v, is := fd.(rc.Fd_Inherit); is && v.which == 2 {
		put(&h.log, "  e")
		esc(&h.log, s)
		put(&h.log, "\n")
		append(&h.err, s)
	} else {
		put(&h.log, "  o")
		esc(&h.log, s)
		put(&h.log, "\n")
		append(&h.out, s)
	}
}

// The most of a pipeline's $status the hosts keep.
STATUS_MAX :: 8191

// The pipe a /fd/N argument names in a stage's descriptors, or -1.
pipe_of :: proc(fds: ^[rc.FDS]rc.Fd, word: string) -> int {
	arg := c_str(word)
	if len(arg) != 5 || arg[:4] != "/fd/" || arg[4] < '0' || arg[4] > '9' {
		return -1
	}
	if v, is := fds[arg[4] - '0'].(rc.Fd_Pipefd); is && v.handle - PIPE_HANDLE < PIPES {
		return int(v.handle - PIPE_HANDLE)
	}
	return -1
}

// A child rc (upstream's 6d7b1), as 9front's rc forks one: a new interpreter
// on this host, given the shell's variables and functions, its $* the words
// after its code; its descriptors the stage's. Its status, its $status at the
// end. Its steps are as limited as its parent's.
run_child :: proc(h: ^Host, code: string, args: ^rc.Word, io: Child_Io) -> string {
	putf(&h.log, "child %d ", h.nchildren)
	esc(&h.log, code)
	put(&h.log, "\n")
	if h.nchildren == CHILDREN {
		return "too deep"
	}
	d := h.nchildren
	child := h.child_sh[d]
	if child == nil || !rc.init(child, h.child_heap[d], callbacks(h)) {
		return "no memory"
	}
	child.budget = io.parent.budget
	vars := rc.vars(io.parent)
	for name, val in rc.next_var(&vars) {
		if name == "*" || (len(name) > 0 && name[0] >= '0' && name[0] <= '9') {
			continue // the child's own
		}
		words: [dynamic; 64]string
		for w := val; w != nil && len(words) < cap(words); w = w.next {
			append(&words, rc.text(w))
		}
		rc.set_var(child, name, ..words[:])
	}
	fns := rc.fns(io.parent)
	for name, src in rc.next_fn(&fns) {
		fn_name, fn_src := c_str(name), c_str(src)
		if 4 + len(fn_name) + len(fn_src) < 2048 { // upstream's text[2048]
			buf: [2048]u8
			_ = rc.run(child, fmt.bprintf(buf[:], "fn %s %s", fn_name, fn_src))
		}
	}
	star: [dynamic; 64]string
	for w := args; w != nil && len(star) < cap(star); w = w.next {
		append(&star, rc.text(w))
	}
	rc.set_var(child, "*", ..star[:])
	h.children[h.nchildren] = io
	h.nchildren += 1
	_ = rc.run(child, code)
	h.nchildren -= 1
	st := rc.get_var(child, "status")
	status := st != nil ? c_str(rc.text(st)) : ""
	clear(&h.child_status[d])
	append(&h.child_status[d], status[:min(len(status), cap(h.child_status[d]))])
	put(&h.log, "  child status ")
	esc(&h.log, string(h.child_status[d][:]))
	put(&h.log, "\n")
	return string(h.child_status[d][:])
}

// A pipeline, its stages run in turn; $status as the shell makes it, each stage's
// joined by rc.concstatus.
run :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, stages: []rc.Command, async: bool) -> (pid: u64, ok: bool) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	pipes: [2][dynamic]u8
	status_buf: [STATUS_MAX]u8
	status_len := 0
	defer {
		delete(pipes[0])
		delete(pipes[1])
	}
	putf(&h.log, "run %d", len(stages))
	put(&h.log, async ? " &\n" : "\n")
	for &c, i in stages {
		fds := c.fds
		put(&h.log, " ")
		w := c.argv
		for word in rc.next_word(&w) {
			esc(&h.log, word)
		}
		for fd in fds {
			fd_desc(&h.log, fd) // kept until the stage runs, upstream's as well since its ab83fe6
		}
		if c.child {
			put(&h.log, " child")
		}
		put(&h.log, "\n")
		for fd in fds {
			if f, is := fd.(rc.Fd_File); is && f.kind != .Rdwr && (f.handle >= FILES || !h.open_now[f.handle]) {
				h.used_closed = true
			}
		}
		// Its input: the stage before's output, a file, or nothing; copied,
		// as a stage may write to the file it reads.
		input: []u8
		if _, is := fds[0].(rc.Fd_Pipe_In); is {
			input = pipes[(i + 1) % 2][:]
		}
		if f, is := fds[0].(rc.Fd_File); is && f.kind == .Read && f.handle < FILES {
			input = h.files[f.handle].data[:]
		}
		// A here document's text, a pipeline stage's too.
		if here, is := fds[0].(rc.Fd_Here); is {
			input = transmute([]u8)here.text
		}
		if _, is := fds[0].(rc.Fd_Inherit); is && h.nchildren > 0 { // a child's: the stage's that started it
			input = h.children[h.nchildren - 1].input
		}
		in_copy := make([]u8, len(input))
		defer delete(in_copy)
		copy(in_copy, input)
		mypipe := &pipes[i % 2]
		clear(mypipe)
		name := c_str(rc.text(c.argv))
		st := ""
		if c.child {
			name = "" // its code: run_child's, below
		}
		switch name {
		case "":
			if c.child {
				st = run_child(h, rc.text(c.argv), c.argv.next, {parent = r, fds = c.fds, input = in_copy, pipe = mypipe})
			} else {
				st = "not found"
			}
		case "warn": // its words, on its standard error
			for a := c.argv.next; a != nil; a = a.next {
				emit(h, r, &fds, 2, rc.text(a), mypipe)
				emit(h, r, &fds, 2, a.next != nil ? " " : "\n", mypipe)
			}
		case "echo":
			for a := c.argv.next; a != nil; a = a.next {
				emit(h, r, &fds, 1, rc.text(a), mypipe)
				emit(h, r, &fds, 1, a.next != nil ? " " : "\n", mypipe)
			}
			if c.argv.next == nil {
				emit(h, r, &fds, 1, "\n", mypipe)
			}
		case "cat":
			if c.argv.next == nil {
				emit(h, r, &fds, 1, string(in_copy), mypipe)
				break
			}
			for a := c.argv.next; a != nil; a = a.next { // each /fd/N: what its <{...} wrote
				if k := pipe_of(&fds, rc.text(a)); k >= 0 {
					emit(h, r, &fds, 1, string(h.pipes_fd[k].data[:]), mypipe)
				} else {
					st = "no such file"
				}
			}
		case "wr": // wr /fd/N words...: the words into descriptor N
			k := c.argv.next != nil ? pipe_of(&fds, rc.text(c.argv.next)) : -1
			if k < 0 {
				st = "no such file"
				break
			}
			to := int(rc.text(c.argv.next)[4] - '0')
			for a := c.argv.next.next; a != nil; a = a.next {
				emit(h, r, &fds, to, rc.text(a), mypipe)
				emit(h, r, &fds, to, a.next != nil ? " " : "\n", mypipe)
			}
		case "wc": // words
			words := 0
			for k := 0; k < len(in_copy); {
				for k < len(in_copy) && (in_copy[k] == ' ' || in_copy[k] == '\n') {
					k += 1
				}
				if k < len(in_copy) {
					words += 1
				}
				for k < len(in_copy) && in_copy[k] != ' ' && in_copy[k] != '\n' {
					k += 1
				}
			}
			buf: [16]u8
			emit(h, r, &fds, 1, fmt.bprintf(buf[:], "%d\n", words), mypipe)
		case "true":
		case "false":
			st = "false"
		case "exitwith":
			st = c.argv.next != nil ? c_str(rc.text(c.argv.next)) : ""
		case:
			st = "not found"
		}
		status_len = rc.concstatus(status_buf[:], status_len, st)
	}
	if async { // not waited for: $status as it was, as the shell's host leaves it
		put(&h.log, "  async\n")
		return 42, true
	}
	status := string(status_buf[:status_len])
	put(&h.log, "  status ")
	esc(&h.log, status)
	put(&h.log, "\n")
	rc.set_status(r, status)
	return pid, true
}

write_fd :: proc "contextless" (ctx: rawptr, fd: rc.Fd, which: u32, s: string) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	putf(&h.log, "write %d", which)
	fd_desc(&h.log, fd)
	put(&h.log, " ")
	esc(&h.log, s)
	put(&h.log, "\n")
	if own, is := fd.(rc.Fd_Inherit); is && h.nchildren > 0 { // a child's builtin: where the stage's descriptor goes
		io := &h.children[h.nchildren - 1]
		h.nchildren -= 1
		emit(h, io.parent, &io.fds, own.which < rc.FDS ? int(own.which) : int(which), s, io.pipe)
		h.nchildren += 1
		return
	}
	if v, is := fd.(rc.Fd_Inherit); is && v.which == 2 {
		append(&h.err, s)
	} else {
		append(&h.out, s)
	}
}

open_fake :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, path: string, kind: rc.Open_Kind) -> (handle: u32, ok: bool) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	k := file_of(h, path, kind != .Read)
	put(&h.log, "open ")
	esc(&h.log, path)
	putf(&h.log, " %c %d\n", rune(KIND_CHAR[kind]), k)
	if k < 0 {
		return 0, false
	}
	if kind == .Write { // emptied once, where the redirection is
		clear(&h.files[k].data)
	}
	h.open_now[k] = true
	h.opened += 1
	return u32(k), true
}

// Host.pipefd: <{...}'s child run now, into the pipe; >{...}'s kept, to run
// on what the command wrote when the pipe closes.
pipefd_fake :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, child: ^rc.Command, command_reads: bool) -> (handle: u32, ok: bool) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	put(&h.log, "pipefd ")
	esc(&h.log, rc.text(child.argv))
	putf(&h.log, " %d\n", int(command_reads))
	k := 0
	for k < PIPES && h.pipes_fd[k].used {
		k += 1
	}
	if k == PIPES || child.argv.len >= 256 {
		return 0, false
	}
	pf := &h.pipes_fd[k]
	clear(&pf.data)
	clear(&pf.code)
	pf.used, pf.command_reads, pf.r, pf.fds = true, command_reads, r, child.fds
	handle = PIPE_HANDLE + u32(k)
	if command_reads {
		pf.fds[1] = rc.Fd_Pipe_Out{}
		_ = run_child(h, rc.text(child.argv), child.argv.next, {parent = r, fds = pf.fds, pipe = &pf.data})
		return handle, true
	}
	append(&pf.code, rc.text(child.argv))
	return handle, true
}

close_fake :: proc "contextless" (ctx: rawptr, handle: u32) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	putf(&h.log, "close %d\n", handle)
	if handle >= PIPE_HANDLE && handle - PIPE_HANDLE < PIPES { // a pipe: a >{...}'s child reads what was written
		pf := &h.pipes_fd[handle - PIPE_HANDLE]
		if !pf.command_reads {
			_ = run_child(h, string(pf.code[:]), nil, {parent = pf.r, fds = pf.fds, input = pf.data[:]})
		}
		pf.used = false
		return
	}
	if handle < FILES {
		h.open_now[handle] = false
	}
	h.closed += 1
}

readdir_fake :: proc "contextless" (ctx: rawptr, path: string, g: ^rc.Glob) -> bool {
	context = runtime.default_context()
	h := (^Host)(ctx)
	put(&h.log, "readdir ")
	esc(&h.log, path)
	put(&h.log, "\n")
	switch path {
	case ".":
		for name in ([]string{"a.c", "b.c", "x.h", ".hidden", "dir"}) {
			rc.glob_add(g, name)
		}
		return true
	case "dir/":
		for name in ([]string{"one.c", "two.txt"}) {
			rc.glob_add(g, name)
		}
		return true
	}
	return false
}

// A line of rc's own standard input.
read_line_fake :: proc "contextless" (ctx: rawptr, buf: []u8) -> int {
	context = runtime.default_context()
	h := (^Host)(ctx)
	n := 0
	for h.stdin_at < len(h.stdin) && n < len(buf) {
		c := h.stdin[h.stdin_at]
		h.stdin_at += 1
		buf[n] = c
		n += 1
		if c == '\n' {
			break
		}
	}
	put(&h.log, "read_line ")
	esc(&h.log, string(buf[:n]))
	put(&h.log, "\n")
	return n
}

// Whether a path exists: the directory's names, and the files written.
exists_fake :: proc "contextless" (ctx: rawptr, path: string) -> bool {
	context = runtime.default_context()
	h := (^Host)(ctx)
	NAMES :: [?]string{"a.c", "b.c", "x.h", ".hidden", "dir", "dir/one.c", "dir/two.txt"}
	found := file_of(h, path, false) >= 0
	for name in NAMES {
		found = found || name == path
	}
	put(&h.log, "exists ")
	esc(&h.log, path)
	putf(&h.log, " %d\n", int(found))
	return found
}

read_file_fake :: proc "contextless" (ctx: rawptr, path: string, buf: []u8) -> (n: int, ok: bool) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	k := file_of(h, path, false)
	n = k < 0 || len(h.files[k].data) > len(buf) ? -1 : len(h.files[k].data)
	put(&h.log, "read ")
	esc(&h.log, path)
	putf(&h.log, " %d\n", n)
	if n < 0 {
		return 0, false
	}
	return copy(buf, h.files[k].data[:]), true
}

host_builtin :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, argv: ^rc.Word, argc: u32, fds: ^[rc.FDS]rc.Fd) -> bool {
	context = runtime.default_context()
	h := (^Host)(ctx)
	put(&h.log, "builtin ")
	esc(&h.log, rc.text(argv))
	putf(&h.log, " %d", argc)
	for fd in fds {
		fd_desc(&h.log, fd)
	}
	put(&h.log, "\n")
	if c_str(rc.text(argv)) == "note" { // note N: rc.trap, as the shell's note handler calls it
		sig: u32
		if argc > 1 {
			for c in transmute([]u8)rc.text(argv.next) {
				if c < '0' || c > '9' || sig >= 1000 {
					break
				}
				sig = sig * 10 + u32(c - '0')
			}
		}
		if sig < len(rc.Sig) {
			rc.trap(r, rc.Sig(sig))
		}
		rc.set_status(r, "")
		return true
	}
	if c_str(rc.text(argv)) != "exportx" {
		return false
	}
	clear(&h.exported)
	it := rc.vars(r)
	for name, val in rc.next_var(&it) {
		put(&h.log, "  var ")
		esc(&h.log, name)
		for w := val; w != nil; w = w.next {
			esc(&h.log, rc.text(w))
		}
		put(&h.log, "\n")
		if name != "x" {
			continue
		}
		for w := val; w != nil && len(h.exported) + w.len + 4 < 256; w = w.next {
			putf(&h.exported, "x=%s;", c_str(rc.text(w)))
		}
	}
	fns := rc.fns(r)
	for name, src in rc.next_fn(&fns) {
		put(&h.log, "  fn ")
		esc(&h.log, name)
		esc(&h.log, src)
		put(&h.log, "\n")
	}
	rc.set_status(r, "")
	return true
}

// --- rc_fuzz.c's host ---
//
// Programs that succeed, output dropped, every directory holding a.c and b;
// no files, builtins or `.`.

minimal_callbacks :: proc(h: ^Host) -> rc.Host {
	return rc.Host{ctx = h, run = run_min, write = write_min, readdir = readdir_min}
}

run_min :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, stages: []rc.Command, async: bool) -> (pid: u64, ok: bool) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	putf(&h.log, "run %d", len(stages))
	put(&h.log, async ? " &\n" : "\n")
	for &c in stages {
		put(&h.log, " ")
		w := c.argv
		for word in rc.next_word(&w) {
			esc(&h.log, word)
		}
		for fd in c.fds {
			fd_desc(&h.log, fd)
		}
		put(&h.log, "\n")
	}
	rc.set_status(r, "")
	return 1, true
}

write_min :: proc "contextless" (ctx: rawptr, fd: rc.Fd, which: u32, s: string) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	putf(&h.log, "write %d", which)
	fd_desc(&h.log, fd)
	put(&h.log, " ")
	esc(&h.log, s)
	put(&h.log, "\n")
}

readdir_min :: proc "contextless" (ctx: rawptr, path: string, g: ^rc.Glob) -> bool {
	context = runtime.default_context()
	h := (^Host)(ctx)
	put(&h.log, "readdir ")
	esc(&h.log, path)
	put(&h.log, "\n")
	rc.glob_add(g, "a.c")
	rc.glob_add(g, "b")
	return true
}

// --- Transcripts ---

// What a run left, for the transcript.
result :: proc(h: ^Host, res: rc.Result) {
	putf(&h.log, "result %d ", int(res))
	esc(&h.log, rc.err(h.sh))
	put(&h.log, " status")
	for w := rc.get_var(h.sh, "status"); w != nil; w = w.next {
		esc(&h.log, rc.text(w))
	}
	put(&h.log, "\n")
}

// An interpreter and its host, for transcripts.
Bench :: struct {
	sh:      ^rc.Rc,
	heap:    []u8,
	host:    Host,
	minimal: bool, // upstream's rc_fuzz.c host, not its rc_test.c host
}

bench_make :: proc(heap_size: int, minimal := false) -> ^Bench {
	b := new(Bench)
	b.minimal = minimal
	b.sh = new(rc.Rc)
	b.heap, _ = mem.make_aligned([]u8, heap_size, 16)
	b.host.sh = b.sh
	for i in 0 ..< CHILDREN {
		b.host.child_sh[i] = new(rc.Rc)
		b.host.child_heap[i], _ = mem.make_aligned([]u8, CHILD_HEAP, 16)
	}
	return b
}

bench_destroy :: proc(b: ^Bench) {
	for i in 0 ..< CHILDREN {
		free(b.host.child_sh[i])
		delete(b.host.child_heap[i])
	}
	destroy(&b.host)
	delete(b.heap)
	free(b.sh)
	free(b)
}

// The transcript of text, run twice in a fresh interpreter (as upstream's
// fuzzer runs it), with a step budget against loops: in b.host.log.
transcript :: proc(b: ^Bench, text: string) -> bool {
	reset(&b.host)
	b.host.stdin = STDIN
	if !rc.init(b.sh, b.heap, b.minimal ? minimal_callbacks(&b.host) : callbacks(&b.host)) {
		return false
	}
	b.sh.budget = 20000
	for _ in 0 ..< 2 {
		result(&b.host, rc.run(b.sh, text))
	}
	putf(&b.host.log, "opened %d closed %d used_closed %d\n", b.host.opened, b.host.closed, int(b.host.used_closed))
	return true
}

FNV_OFFSET :: u64(0xcbf29ce484222325)

fnv :: proc(h: u64, s: []u8) -> u64 {
	h := h
	for c in s {
		h = (h ~ u64(c)) * 0x100000001b3
	}
	return h
}

// --- The mutator ---

ALPHA := "{}()$#\"'`^|&;<>=[]*?~!@\n \t\\-:.,/abcxyz019\x01\x00"

Mutator :: struct {
	rng:   u64,
	seeds: [dynamic]string,
}

next :: proc(m: ^Mutator) -> u64 { // splitmix64
	m.rng += 0x9e3779b97f4a7c15
	z := m.rng
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

below :: proc(m: ^Mutator, n: int) -> int {
	return int(next(m) % u64(n))
}

// The lines of text that are not empty, one per call.
next_line :: proc(rest: ^string) -> (line: string, ok: bool) {
	for len(rest^) > 0 {
		end := 0
		for end < len(rest^) && rest[end] != '\n' {
			end += 1
		}
		line = rest[:end]
		rest^ = rest[min(end + 1, len(rest^)):]
		if end > 0 {
			return line, true
		}
	}
	return "", false
}

// The seeds, in the oracle's order: the corpus (script, words), the lines of
// cases.rc and xcheck.rc, rctest.rc, then the blocks of blocks.rc (scripts of
// several lines, each ending at a line that is %% alone).
mutator_make :: proc(script, words, cases, xcheck, rctest, blocks: string) -> Mutator {
	m: Mutator
	append(&m.seeds, script, words)
	for lines in ([]string{cases, xcheck}) {
		rest := lines
		for line in next_line(&rest) {
			append(&m.seeds, line)
		}
	}
	append(&m.seeds, rctest)
	rest := blocks
	for len(rest) > 0 {
		end := strings.index(rest, "\n%%\n")
		if end < 0 {
			append(&m.seeds, rest)
			break
		}
		append(&m.seeds, rest[:end + 1])
		rest = rest[end + 4:]
	}
	return m
}

mutator_destroy :: proc(m: ^Mutator) {
	delete(m.seeds)
}

MUTATED_MAX :: 4096

// Mutated input index, into s.
mutate :: proc(m: ^Mutator, index: u64, s: ^[dynamic]u8) {
	m.rng = index * 0x2545f4914f6cdd1d + 1
	clear(s)
	append(s, m.seeds[below(m, len(m.seeds))])
	muts := 1 + below(m, 8)
	for _ in 0 ..< muts {
		switch below(m, 6) {
		case 0:
			if len(s) > 0 {
				pos := below(m, len(s))
				s[pos] = ALPHA[below(m, len(ALPHA))]
			}
		case 1:
			pos := below(m, len(s) + 1)
			c := ALPHA[below(m, len(ALPHA))]
			inject_at(s, pos, c)
		case 2:
			if len(s) > 0 {
				pos := below(m, len(s))
				k := 1 + below(m, min(len(s) - pos, 8))
				remove_range(s, pos, pos + k)
			}
		case 3:
			if len(s) > 0 {
				pos := below(m, len(s))
				k := 1 + below(m, min(len(s) - pos, 16))
				to := below(m, len(s) + 1)
				piece := make([]u8, k)
				defer delete(piece)
				copy(piece, s[pos:pos + k])
				inject_at(s, to, ..piece)
			}
		case 4:
			o := m.seeds[below(m, len(m.seeds))]
			if len(o) > 0 {
				a := below(m, len(o))
				k := 1 + below(m, min(len(o) - a, 32))
				to := below(m, len(s) + 1)
				inject_at(s, to, ..transmute([]u8)o[a:a + k])
			}
		case:
			pos := below(m, len(s) + 1)
			inject_at(s, pos, u8(next(m) & 0xff))
		}
	}
	if len(s) > MUTATED_MAX {
		resize(s, MUTATED_MAX)
	}
}
