// A host for vx:rc's tests: upstream's rc_test.c host (its programs echo,
// cat, wc, true, false, exitwith and warn write into buffers, its files are in
// memory, and its directory has a few names for globbing), with every
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
import "vx:rc"
import "vx:str"

// Upstream's struct rc, which its heap holds too (rc_new takes it from the
// front): a heap this much smaller is the same heap to the allocator, so the
// port runs out of memory where upstream does.
C_RC_SIZE :: 17856

FILES :: 8

File :: struct {
	name: [dynamic; 31]u8, // upstream's char name[32]
	data: [dynamic; 1024]u8,
}

Host :: struct {
	sh:          ^rc.Rc,
	files:       [FILES]File,
	open_now:    [FILES]bool, // the files the shell has open, by handle
	used_closed: bool, // a stage was given a file the shell had already closed
	opened:      int,
	closed:      int,
	out, err:    [dynamic]u8,
	exported:    [dynamic]u8, // exportx's: x's value as rc.next_var gives it
	log:         [dynamic]u8, // the transcript
}

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
	}
}

reset :: proc(h: ^Host) {
	sh := h.sh
	delete(h.out)
	delete(h.err)
	delete(h.exported)
	delete(h.log)
	h^ = {
		sh = sh,
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

// Output to where fd goes: a file, the shell's capture, a pipe, or out/err.
emit :: proc(h: ^Host, fds: ^[rc.FDS]rc.Fd, which: int, s: string, pipe: ^[dynamic]u8) {
	fd := fds[which]
	for guard := 0; guard < 10; guard += 1 {
		d, is := fd.(rc.Fd_Dup)
		if !is || d.of >= rc.FDS {
			break
		}
		fd = fds[d.of]
	}
	switch v in fd {
	case rc.Fd_Capture:
		put(&h.log, "  k")
		esc(&h.log, s)
		put(&h.log, "\n")
		rc.capture_write(h.sh, fd, s)
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
	case rc.Fd_Inherit, rc.Fd_Dup, rc.Fd_Pipe_In:
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

// A pipeline, its stages run in turn; $status as gsh makes it, each stage's
// joined by |.
run :: proc "contextless" (ctx: rawptr, r: ^rc.Rc, stages: []rc.Command, async: bool) -> (pid: u64, ok: bool) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	pipes: [2][dynamic]u8
	status: [dynamic]u8
	defer {
		delete(pipes[0])
		delete(pipes[1])
		delete(status)
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
			fd_desc(&h.log, fd, with_path = false) // upstream's has been freed by now: not compared
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
		in_copy := make([]u8, len(input))
		defer delete(in_copy)
		copy(in_copy, input)
		mypipe := &pipes[i % 2]
		clear(mypipe)
		name := c_str(rc.text(c.argv))
		st := ""
		switch name {
		case "warn": // its words, on its standard error
			for a := c.argv.next; a != nil; a = a.next {
				emit(h, &fds, 2, rc.text(a), mypipe)
				emit(h, &fds, 2, a.next != nil ? " " : "\n", mypipe)
			}
		case "echo":
			for a := c.argv.next; a != nil; a = a.next {
				emit(h, &fds, 1, rc.text(a), mypipe)
				emit(h, &fds, 1, a.next != nil ? " " : "\n", mypipe)
			}
			if c.argv.next == nil {
				emit(h, &fds, 1, "\n", mypipe)
			}
		case "cat":
			emit(h, &fds, 1, string(in_copy), mypipe)
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
			emit(h, &fds, 1, fmt.bprintf(buf[:], "%d\n", words), mypipe)
		case "true":
		case "false":
			st = "false"
		case "exitwith":
			st = c.argv.next != nil ? c_str(rc.text(c.argv.next)) : ""
		case:
			st = "not found"
		}
		if i > 0 {
			append(&status, '|')
		}
		append(&status, st)
	}
	if async {
		pid = 42
	}
	put(&h.log, "  status ")
	esc(&h.log, string(status[:]))
	put(&h.log, "\n")
	rc.set_status(r, string(status[:]))
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

close_fake :: proc "contextless" (ctx: rawptr, handle: u32) {
	context = runtime.default_context()
	h := (^Host)(ctx)
	putf(&h.log, "close %d\n", handle)
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
			fd_desc(&h.log, fd, with_path = false)
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
	return b
}

bench_destroy :: proc(b: ^Bench) {
	destroy(&b.host)
	delete(b.heap)
	free(b.sh)
	free(b)
}

// The transcript of text, run twice in a fresh interpreter (as upstream's
// fuzzer runs it), with a step budget against loops: in b.host.log.
transcript :: proc(b: ^Bench, text: string) -> bool {
	reset(&b.host)
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
// cases.rc and xcheck.rc, then rctest.rc.
mutator_make :: proc(script, words, cases, xcheck, rctest: string) -> Mutator {
	m: Mutator
	append(&m.seeds, script, words)
	for lines in ([]string{cases, xcheck}) {
		rest := lines
		for line in next_line(&rest) {
			append(&m.seeds, line)
		}
	}
	append(&m.seeds, rctest)
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
