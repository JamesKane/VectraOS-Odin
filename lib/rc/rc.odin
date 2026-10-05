// The rc shell language (Tom Duff's, as 9front's rc has it), for the
// shell, cmd/rc (upstream docs/milestones.md, M4 step 7). A script is read by a lexer,
// parsed into a tree, compiled into code, and run by a machine, as rc does;
// none of it recurses: the parser and the compiler keep stacks of their own,
// and functions run on the machine's frames.
//
// What runs a command is the host's: Host's callbacks start programs (each
// stage of a pipeline at once), open the files redirections name, read
// directories for globbing, and give builtins of the host's own. So the
// language is tested on the host (tests/host/rc), and the shell puts it on vx:rt and
// the namespace.
//
// Freestanding: the interpreter keeps its words, variables and code in a heap
// the caller gives it (init), and makes no system call itself. Its sizes are
// upstream's, so the heap runs out where upstream's does.
//
// Without fork, two things are narrower than rc's: each stage of a pipeline,
// and a command run with &, must be a program (not a function, builtin or
// block); and `{...} and @{...} run in the shell itself, so what they assign
// is seen after (upstream docs/milestones.md, known gaps).
//
// A host drives it like this (upstream's shell's shape, 9front's start):
//
//	sh: rc.Rc // large (the machine's stacks): a global
//	heap: [4 << 20]u8
//	if !rc.init(&sh, heap[:], rc.Host{ctx = &state, run = run, write = write, ...}) { ... }
//	sh.flag['i'] = true // its flags, as rc's arguments set them
//	rc.set_var(&sh, "*", ..args) // and the environment, a list per variable
//	_ = rc.run(&sh, ". -bq /rc/lib/rcmain $*\n")
//	// The exit status: rc.get_var(&sh, "status")'s first word.
//
// rc.run reads a command at a time, as rc does; `. -i '#d/0'` reads the
// shell's standard input a line at a time through Host.read_line, prompting
// on its standard error. An error is written to the shell's standard error
// where it happens (Host.write, Fd_Inherit{2}), and rc.err keeps it.
//
// Its run callback starts each stage with the descriptors it is given
// (rc.Fd's variants: the shell's own, a file its open callback opened, a pipe
// between stages, closed, a capture, or a here document's text), feeds what a
// stage writes to an Fd_Capture to rc.capture_write, waits, and sets $status
// with rc.set_status (the stages' statuses joined by rc.concstatus). To pass
// variables to a program it walks rc.vars/rc.next_var.
package rc

import "base:intrinsics"
import "vx:str"

FDS :: 10 // descriptors 0 to 9, as rc's >[n]

// A word, and a list of them, as the machine keeps them: in the heap, its
// text after the header (text gives it).
Word :: struct {
	next: ^Word,
	len:  int,
}
#assert(size_of(Word) == 16) // upstream's rc_word: the heap's sizes are its

// How a redirection opens its file.
Open_Kind :: enum u8 {
	Read, // <
	Write, // >, which empties the file
	Append, // >>
	Rdwr, // <>
}

// Where a file descriptor goes for a command: one of the shell's own (as it
// inherited them), a file the host opened for a redirection, closed, the
// shell's capture of what it writes (for `{...}), or a pipe to or from the
// next stage of a pipeline. Fd_Dup is only ever a redirection's: where the
// redirections are applied it becomes a copy of what it names.
Fd :: union #no_nil {
	Fd_Inherit,
	Fd_File,
	Fd_Dup,
	Fd_Closed,
	Fd_Capture,
	Fd_Pipe_Out,
	Fd_Pipe_In,
	Fd_Here,
}
Fd_Inherit :: struct {
	which: u8, // which of the shell's own
}
Fd_File :: struct {
	kind:   Open_Kind,
	handle: u32, // as the host's open gave it
	path:   string,
}
Fd_Dup :: struct {
	of: u8, // the descriptor it copies
}
Fd_Closed :: struct {}
Fd_Capture :: struct {
	index: u8, // which capture: give what is written to capture_write
}
Fd_Pipe_Out :: struct {} // a pipeline's: into the next stage
Fd_Pipe_In :: struct {} // from the stage before
Fd_Here :: struct {
	text: string, // a here document's, substituted: the host feeds it
}

// A program to run: its words, and its descriptors after redirections (a
// pipeline's stages are joined by the host).
Command :: struct {
	argv: ^Word,
	argc: u32,
	fds:  [FDS]Fd,
}

// The host: what runs commands, and the files and directories the language
// reaches. Every callback may be nil, though a shell wants them all.
Host :: struct {
	ctx:       rawptr,
	// Runs a pipeline of programs (one for a plain command), each stage's
	// standard output into the next's standard input, as one job: waits for
	// it, unless async, and gives each stage's exit status (rc's: "" is
	// success) through set_status. ok is false if a program could not be
	// started (why, in its status). async: the pid it started.
	run:       proc "contextless" (ctx: rawptr, r: ^Rc, stages: []Command, async: bool) -> (pid: u64, ok: bool),
	// Writes to a descriptor of the shell's own (a builtin's output): which
	// is 1 or 2, fd where it goes after the shell's redirections.
	write:     proc "contextless" (ctx: rawptr, fd: Fd, which: u32, s: string),
	// A directory's entries, for globbing: glob_add(g, name) for each; false
	// if it cannot be read.
	readdir:   proc "contextless" (ctx: rawptr, path: string, g: ^Glob) -> bool,
	// The host's builtins (cd, and the shell's namespace commands): true if argv's
	// first word is one, which it ran (setting $status).
	builtin:   proc "contextless" (ctx: rawptr, r: ^Rc, argv: ^Word, argc: u32, fds: ^[FDS]Fd) -> bool,
	// A file's text, for `.`: its length, read into buf; ok is false if it
	// cannot be read or is longer than buf.
	read_file: proc "contextless" (ctx: rawptr, path: string, buf: []u8) -> (n: int, ok: bool),
	// Opens a redirection's file, once, where the redirection is (Write
	// empties it); ok is false if it cannot be (why, in $status). close lets
	// it go when the redirection ends.
	open:      proc "contextless" (ctx: rawptr, r: ^Rc, path: string, kind: Open_Kind) -> (handle: u32, ok: bool),
	close:     proc "contextless" (ctx: rawptr, handle: u32),
	// Whether a path exists, for globbing: a plain name after a pattern must
	// (rc's access check). Optional: without it, such names are kept.
	exists:    proc "contextless" (ctx: rawptr, path: string) -> bool,
	// A line of rc's own standard input (rc's '#d/0', which `. -i` reads),
	// its newline with it, into buf: its length, or 0 at the end or on an
	// error. Optional: without it, standard input is empty.
	read_line: proc "contextless" (ctx: rawptr, buf: []u8) -> int,
	// The host's builtins' names, for whatis.
	builtin_names: []string,
}

// rc's notes, by its signal functions' names (rc's Signame): what trap takes.
Sig :: enum u8 {
	Exit, // sigexit: run once, as the shell exits (sigexit)
	Hup, // sighup
	Int, // sigint
	Quit, // sigquit
	Alrm, // sigalrm
	Kill, // sigkill
	Fpe, // sigfpe
	Term, // sigterm
}

@(private)
SIG_NAMES := [Sig]string {
	.Exit = "sigexit",
	.Hup  = "sighup",
	.Int  = "sigint",
	.Quit = "sigquit",
	.Alrm = "sigalrm",
	.Kill = "sigkill",
	.Fpe  = "sigfpe",
	.Term = "sigterm",
}

// What run made of a text.
Result :: enum u8 {
	Ok,
	Incomplete, // it ends inside a construct: add the next line and run the whole again
	Syntax, // the message in err
	Failed, // a run-time error stopped it (err says which)
	Exit, // exit ran; its status is $status
}

@(private)
VARS :: 64
@(private)
STACK :: 512
@(private)
FRAMES :: 64
@(private)
REDIRS :: 64
@(private)
CAPTURES :: 8
@(private)
STAGES :: 64
@(private)
ERR_MAX :: 127 // upstream's 128-byte buffer, with its NUL
@(private)
SRC_MAX :: 63 // upstream's src[64], with its NUL

// An interpreter. Large (the machine's stacks are fixed arrays): a host keeps
// it in a global. It holds pointers into the heap, so it must not be copied.
Rc :: struct {
	host:     Host,
	budget:   u64, // instructions a run may take (0: as many as it needs): fuzzing's guard against loops
	free:     ^Block,
	heap_size: int,
	vars:     [VARS]^Var,
	stack:    [dynamic; STACK]List,
	frames:   [dynamic; FRAMES]Frame,
	redirs:   [dynamic; REDIRS]Redir,
	captures: [dynamic; CAPTURES]Capture,
	// A pipeline's stages, gathered by Stage until Pipeline runs them: its
	// own, the last it says, so a pipeline in a stage's `{} runs alone. A
	// file a gathered stage was given stays open until its pipeline has run,
	// though the redirection that opened it is undone at once (pop_redirs):
	// each such close waits here, with how many stages were gathered then.
	stages:   [dynamic; STAGES]Command,
	closes:   [dynamic; 2 * STAGES]Pending_Close,
	compiler: Compiler_Scratch,
	ifnot:    bool, // the last if's condition was false: what `if not` runs on
	iflast:   bool, // the last command compiled was an if, so `if not` may follow (rc's lex->iflast)
	failed:   bool, // a run-time error ended the script
	failset:  bool, // and fail set $status for it
	exiting:  bool,
	syntax:   bool, // a run's reader met a syntax error
	incomplete: bool, // or the text's end inside a construct
	src:      [dynamic; SRC_MAX]u8, // where the code being compiled comes from, for errors: a file's name, or rc
	// rc's flags, -e -x -s -v -r and the rest, as flag in rc(1) sets them:
	// the host sets them from its arguments before it runs anything.
	flag:     [128]bool,
	rdcode:   ^Code, // the code a reading frame runs: one Rdcmds
	// Notes waiting for their functions, by Sig (rc's trap): a note handler
	// adds to them, so they are read and written as volatile.
	trap:     [Sig]u32,
	ntrap:    u32,
	trapped:  bool, // sigexit has run, as rc's
	err:      [dynamic; ERR_MAX]u8, // the last error, for the host to show
}

@(private)
List :: struct { // a list on the argument stack
	head, tail: ^Word,
	n:          u32,
}

@(private)
Redir :: struct {
	fd:   u8,
	to:   Fd,
	path: ^Word, // owned
}

@(private)
Frame :: struct { // a thread of rc's: what runs, and where it goes back to
	code:          ^Code,
	pc:            u32,
	locals:        ^Var,
	redirs:        u32, // the redirection stack's height when it started
	rd:            ^Reader, // a frame that reads its commands as it goes (rc's Xrdcmds): where from
	sp, ncaptures: u32, // the stacks' heights when it started, for an error's unwinding to it
}

@(private)
Capture :: struct { // `{...}'s output, gathered
	buf: []u8, // in the heap
	len: int,
}

@(private)
Pending_Close :: struct {
	handle, level: u32,
	path:          ^Word, // the redirection's, freed with it
	close:         bool, // the host has a close for it
}

MIN_HEAP :: 32 * 1024

// Makes r an interpreter whose words, variables and code live in heap, with
// host's callbacks. False if heap is too small.
@(require_results)
init :: proc "contextless" (r: ^Rc, heap: []u8, host: Host) -> bool {
	r^ = {}
	r.host = host
	if !heap_init(r, heap) {
		return false
	}
	set_var_words(r, "ifs", new_word(r, " \t\n"))
	set_status(r, "")
	append(&r.src, "rc")
	r.rdcode = heap_new(r, Code)
	one := heap_new(r, Inst)
	if r.rdcode == nil || one == nil {
		return false
	}
	one.op = .Rdcmds
	r.rdcode^ = {
		refs = 1, // its own reference: never freed
		n    = 1,
		inst = one,
	}
	return true
}

// Runs text (a line, or a whole script), read and run a command at a time,
// as rc's Xrdcmds: a syntax error stops it where it is (.Syntax), after the
// commands before it have run; .Incomplete if it ends inside a construct
// (the caller may add the next line and run the whole again).
@(require_results)
run :: proc "contextless" (r: ^Rc, text: string) -> Result {
	clear(&r.err)
	r.failed = false
	r.failset = false
	r.exiting = false
	r.syntax = false
	r.incomplete = false
	rd := reader_new(r, c_name(string(r.src[:])))
	buf := rd != nil ? heap_alloc(r, len(text) + 1) : nil
	if buf == nil {
		reader_free(r, rd)
		return .Failed
	}
	rd.buf = ([^]u8)(buf)[:len(text) + 1]
	rd.len = copy(rd.buf, text)
	base := u32(len(r.frames))
	if !push_reader(r, rd, nil) {
		return .Failed
	}
	execute(r, base)
	if r.exiting {
		sigexit(r) // as rc's Xexit: sigexit first, once
	}
	for u32(len(r.frames)) > base { // after an error or exit: what was running
		pop_frame(r)
	}
	for len(r.stack) > 0 {
		free_words(r, pop_list(r))
	}
	free_stages(r, 0)
	for len(r.captures) > 0 { // an error inside `{}
		heap_free(r, raw_data(r.captures[len(r.captures) - 1].buf))
		resize(&r.captures, len(r.captures) - 1)
	}
	if r.exiting {
		return .Exit
	}
	if r.failed {
		if !r.failset {
			set_status(r, "error") // out of memory, which fail cannot report
		}
		return .Failed
	}
	if r.incomplete {
		return .Incomplete
	}
	return r.syntax ? .Syntax : .Ok
}

// Runs sigexit, once, as rc does when it exits: the host calls it at its end
// too (the end of its input, or an error that ends it).
sigexit :: proc "contextless" (r: ^Rc) {
	v := gvar_find(r, "sigexit", false)
	if r.trapped || v == nil || v.fn == nil {
		return
	}
	r.trapped = true
	exiting := r.exiting
	r.exiting = false
	r.failed = false
	base := u32(len(r.frames))
	star := new_local(r, "*", copy_words(r, get_var(r, "*")))
	if push_frame(r, v.fn, v.fn_pc, star) {
		execute(r, base)
	}
	for u32(len(r.frames)) > base {
		pop_frame(r)
	}
	r.exiting = r.exiting || exiting
}

// A note for rc, from the host's note handler: its function runs before the
// next instruction (rc's notifyf). An interrupt is counted once until it has
// run; .Exit is not a note.
trap :: proc "contextless" (r: ^Rc, sig: Sig) {
	if sig == .Exit || (sig == .Int && intrinsics.volatile_load(&r.trap[.Int]) != 0) {
		return
	}
	intrinsics.volatile_store(&r.trap[sig], intrinsics.volatile_load(&r.trap[sig]) + 1)
	intrinsics.volatile_store(&r.ntrap, intrinsics.volatile_load(&r.ntrap) + 1)
}

// Each function, for the host to export: its name and its body's text.
//
//	it := rc.fns(&sh)
//	for name, src in rc.next_fn(&it) { ... }
Fn_Iterator :: struct {
	r:      ^Rc,
	bucket: int,
	v:      ^Var,
}

fns :: proc "contextless" (r: ^Rc) -> Fn_Iterator {
	return {r = r, v = r.vars[0]}
}

next_fn :: proc "contextless" (it: ^Fn_Iterator) -> (name, src: string, ok: bool) {
	for {
		for it.v == nil {
			it.bucket += 1
			if it.bucket >= VARS {
				return "", "", false
			}
			it.v = it.r.vars[it.bucket]
		}
		v := it.v
		it.v = v.next
		if v.fn != nil {
			return var_name(v), v.fnsrc != nil ? var_fnsrc(v) : "{}", true
		}
	}
}

// Where the code run next comes from, for errors (file:line): a script's
// name; "rc" until set. Cut, as upstream's, to 63 bytes.
source :: proc "contextless" (r: ^Rc, name: string) {
	clear(&r.src)
	append(&r.src, name[:min(len(name), SRC_MAX)])
}

// Adds one stage's status to a pipeline's, held in buf (n bytes so far), as
// rc's concstatus: joined by |, which is left out while what came before is
// empty. What does not fit is cut. The new length.
concstatus :: proc "contextless" (buf: []u8, n: int, s: string) -> int {
	n := n
	if n > 0 && n < len(buf) {
		buf[n] = '|'
		n += 1
	}
	return n + copy(buf[n:], s)
}

// The last error: a syntax error's, with its line, or a run-time error's.
err :: proc "contextless" (r: ^Rc) -> string {
	return string(r.err[:])
}

// A word's text.
text :: proc "contextless" (w: ^Word) -> string {
	return string(word_room(w)[:w.len])
}

// The words of a list, one per call: for s in rc.next_word(&w) { ... }
next_word :: proc "contextless" (w: ^^Word) -> (s: string, ok: bool) {
	if w^ == nil {
		return "", false
	}
	s = text(w^)
	w^ = w^.next
	return s, true
}

// A variable's value as a command would see it (a local hides a global), or
// nil if it has none.
get_var :: proc "contextless" (r: ^Rc, name: string) -> ^Word {
	v := var_find(r, c_name(name), false)
	return v != nil ? v.val : nil
}

// Sets a variable to words; none unsets it, in effect.
set_var :: proc "contextless" (r: ^Rc, name: string, words: ..string) {
	l: List
	for w in words {
		list_add(&l, new_word(r, w))
	}
	set_var_words(r, c_name(name), l.head)
}

// $status, from one status string.
set_status :: proc "contextless" (r: ^Rc, s: string) {
	set_var_words(r, "status", new_word(r, s))
}

// Output a program wrote into a capture (fd is a command's Fd_Capture):
// the host gives it here. Anything else is ignored.
capture_write :: proc "contextless" (r: ^Rc, fd: Fd, s: string) {
	c, is := fd.(Fd_Capture)
	if !is || int(c.index) >= len(r.captures) {
		return
	}
	capture_add(r, &r.captures[c.index], s)
}

// The variables with a value, as a command would see them now (a local
// hiding a global of its name), for the host to export as rc does:
//
//	it := rc.vars(&sh)
//	for name, val in rc.next_var(&it) { ... }
Var_Iterator :: struct {
	r:      ^Rc,
	frame:  int, // len(frames): the globals; below it, that frame's locals
	bucket: int,
	v:      ^Var,
}

vars :: proc "contextless" (r: ^Rc) -> Var_Iterator {
	it := Var_Iterator {
		r     = r,
		frame = len(r.frames),
	}
	it.v = r.vars[0]
	return it
}

// Globals first, bucket by bucket, then each frame's locals, innermost first.
next_var :: proc "contextless" (it: ^Var_Iterator) -> (name: string, val: ^Word, ok: bool) {
	r := it.r
	for it.frame >= 0 {
		for it.v == nil {
			if it.frame == len(r.frames) && it.bucket + 1 < VARS {
				it.bucket += 1
				it.v = r.vars[it.bucket]
				continue
			}
			it.frame -= 1
			if it.frame < 0 {
				return "", nil, false
			}
			it.v = r.frames[it.frame].locals
		}
		v := it.v
		it.v = v.next
		if v.val != nil && var_find(r, var_name(v), false) == v {
			return var_name(v), v.val, true
		}
	}
	return "", nil, false
}

// A name as upstream's C API reads it: up to its first NUL.
@(private)
c_name :: proc "contextless" (s: string) -> string {
	return str.from_nul_padded(transmute([]u8)s)
}
