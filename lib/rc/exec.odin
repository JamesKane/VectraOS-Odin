// The machine (rc's exec.c), with patterns and globbing (glob.c) and the
// builtins.
package rc

import "vx:str"

// --- Patterns and globbing ---

// Whether s matches pattern p, whose * ? and [ match only where GLOB marks
// them; marks are skipped. No recursion: a * is retried from where it last
// matched. A class's ranges compare bytes as signed, as upstream's C does on
// the host and x86_64.
@(private)
match :: proc "contextless" (s, p: string) -> bool {
	n, m := len(s), len(p)
	si, pi := 0, 0
	star_p, star_s := -1, 0
	for si < n {
		if pi < m && p[pi] == GLOB && pi + 1 < m {
			switch p[pi + 1] {
			case '*':
				pi += 2
				star_p, star_s = pi, si
				continue
			case '?':
				pi += 2
				si += 1
				continue
			case '[': // a class: [abc], [a-z], [~abc]
				q := pi + 2
				neg := q < m && p[q] == '~'
				hit := false
				if neg {
					q += 1
				}
				c := i8(s[si])
				for ; q < m && p[q] != ']'; q += 1 {
					if q + 2 < m && p[q + 1] == '-' && p[q + 2] != ']' {
						hit = hit || (c >= i8(p[q]) && c <= i8(p[q + 2]))
						q += 2
					} else {
						hit = hit || s[si] == p[q]
					}
				}
				if q < m && hit != neg {
					pi = q + 1
					si += 1
					continue
				}
			}
		} else if pi < m && p[pi] == s[si] {
			pi += 1
			si += 1
			continue
		}
		if star_p < 0 { // no * to stretch
			return false
		}
		pi = star_p
		star_s += 1
		si = star_s
	}
	for pi + 1 < m && p[pi] == GLOB && p[pi + 1] == '*' {
		pi += 2
	}
	return pi == m
}

@(private = "file")
globby :: proc "contextless" (s: string) -> bool {
	for i := 0; i + 1 < len(s); i += 1 {
		if s[i] == GLOB {
			return true
		}
	}
	return false
}

// A word with its glob marks taken out, in place.
@(private = "file")
deglob :: proc "contextless" (w: ^Word) {
	b := word_room(w)
	k := 0
	for i in 0 ..< w.len {
		if b[i] != GLOB {
			b[k] = b[i]
			k += 1
		}
	}
	w.len = k
}

@(private = "file")
deglob_list :: proc "contextless" (w: ^Word) {
	for x := w; x != nil; x = x.next {
		deglob(x)
	}
}

// One component of a glob, matched against a directory's entries as the
// host gives them (Host.readdir).
Glob :: struct {
	r:    ^Rc,
	pat:  string, // this component's pattern
	dir:  string, // the directory being read, with its / (or empty)
	tail: ^^Word,
	n:    u32,
}

// A directory entry, for the glob being made.
glob_add :: proc "contextless" (g: ^Glob, name: string) {
	if len(name) > 0 && name[0] == '.' && !(len(g.pat) > 0 && g.pat[0] == '.') { // dot files only when asked for
		return
	}
	if !match(name, g.pat) || g.n >= 4096 {
		return
	}
	w := heap_new(g.r, Word, len(g.dir) + len(name) + 2) // room for the '/' glob may add
	if w == nil {
		return
	}
	room := word_room(w)
	copy(room, g.dir)
	copy(room[len(g.dir):], name)
	w.len = len(g.dir) + len(name)
	g.tail^ = w
	g.tail = &w.next
	g.n += 1
}

// Sorts words in place (insertion sort, by bytes: globs give few).
@(private = "file")
sort_words :: proc "contextless" (list: ^Word) -> ^Word {
	list := list
	sorted: ^Word
	for list != nil {
		w := list
		at := &sorted
		list = list.next
		for at^ != nil && !(text(at^) > text(w)) {
			at = &at^.next
		}
		w.next = at^
		at^ = w
	}
	return sorted
}

// A word expanded by globbing: the names it matches, sorted; itself, its
// marks taken out, if none (as rc does). Each /-separated component is
// matched in turn against the directories the one before matched.
@(private = "file")
glob :: proc "contextless" (r: ^Rc, w: ^Word) -> ^Word {
	s := text(w)
	if !globby(s) || r.host.readdir == nil {
		deglob(w)
		return w
	}
	rooted := s[0] == '/'
	paths := new_word(r, rooted ? "/" : "")
	at := rooted ? 1 : 0
	for at < len(s) && paths != nil {
		end := at
		for end < len(s) && s[end] != '/' {
			end += 1
		}
		component := s[at:end]
		next: ^Word
		tail := &next
		for pth := paths; pth != nil; pth = pth.next {
			if !globby(component) { // a plain component: just joined on
				x := heap_new(r, Word, pth.len + len(component) + 2)
				if x == nil {
					break
				}
				room := word_room(x)
				copy(room, text(pth))
				copy(room[pth.len:], component)
				x.len = pth.len + len(component)
				tail^ = x
				tail = &x.next
				continue
			}
			g := Glob {
				r    = r,
				pat  = component,
				dir  = text(pth),
				tail = tail,
			}
			_ = r.host.readdir(r.host.ctx, pth.len > 0 ? text(pth) : ".", &g)
			tail = g.tail
		}
		free_words(r, paths)
		paths = next
		for x := paths; x != nil && end < len(s); x = x.next { // a / after each, for the next component
			word_room(x)[x.len] = '/'
			x.len += 1
		}
		at = end + 1
	}
	if paths == nil {
		deglob(w)
		return w
	}
	free_words(r, w)
	return sort_words(paths)
}

// Every word of a list globbed, in place.
@(private = "file")
glob_list :: proc "contextless" (r: ^Rc, w: ^Word) -> ^Word {
	w := w
	l: List
	for w != nil {
		next := w.next
		w.next = nil
		list_add(&l, glob(r, w))
		w = next
	}
	return l.head
}

// --- The machine ---

@(private = "file")
top_list :: proc "contextless" (r: ^Rc) -> ^List {
	return len(r.stack) > 0 ? &r.stack[len(r.stack) - 1] : nil
}

@(private)
list_add :: proc "contextless" (l: ^List, w: ^Word) {
	w := w
	for w != nil {
		next := w.next
		w.next = nil
		if l.tail != nil {
			l.tail.next = w
		} else {
			l.head = w
		}
		l.tail = w
		l.n += 1
		w = next
	}
}

@(private = "file")
@(require_results)
mark :: proc "contextless" (r: ^Rc) -> bool {
	if len(r.stack) == STACK {
		set_error(r, "stack overflow")
		r.failed = true
		return false
	}
	append(&r.stack, List{})
	return true
}

// The top list's words (the caller's), the list gone.
@(private)
pop_list :: proc "contextless" (r: ^Rc) -> ^Word {
	if len(r.stack) == 0 {
		return nil
	}
	head := r.stack[len(r.stack) - 1].head
	resize(&r.stack, len(r.stack) - 1)
	return head
}

@(private = "file")
has :: proc "contextless" (s: []u8, c: u8) -> bool {
	for x in s {
		if x == c {
			return true
		}
	}
	return false
}

// Redirections from..to of the stack applied to fds, in order.
@(private = "file")
apply_redirs :: proc "contextless" (r: ^Rc, fds: ^[FDS]Fd, from, to: int) {
	for i := from; i < to && i < len(r.redirs); i += 1 {
		d := &r.redirs[i]
		if d.fd >= FDS {
			continue
		}
		if dup, is := d.to.(Fd_Dup); is && dup.of < FDS {
			fds[d.fd] = fds[dup.of] // a copy of what it is now
		} else {
			fds[d.fd] = d.to
		}
	}
}

@(private = "file")
inherited :: proc "contextless" () -> (fds: [FDS]Fd) {
	for &fd, i in fds {
		fd = Fd_Inherit{u8(i)}
	}
	return
}

// The descriptors a command gets: the redirection stack applied, in order.
@(private = "file")
command_fds :: proc "contextless" (r: ^Rc) -> [FDS]Fd {
	fds := inherited()
	apply_redirs(r, &fds, 0, len(r.redirs))
	return fds
}

@(private)
capture_add :: proc "contextless" (r: ^Rc, c: ^Capture, s: string) {
	if c.len + len(s) > len(c.buf) {
		more_cap := (c.len + len(s)) * 2 + 256
		more := heap_alloc(r, more_cap)
		if more == nil {
			return
		}
		if c.buf != nil {
			copy(([^]u8)(more)[:more_cap], c.buf[:c.len])
			heap_free(r, raw_data(c.buf))
		}
		c.buf = ([^]u8)(more)[:more_cap]
	}
	copy(c.buf[c.len:], s)
	c.len += len(s)
}

// Output of the shell's own (a builtin's): to a capture, or the host.
@(private = "file")
shell_write :: proc "contextless" (r: ^Rc, which: u32, s: string) {
	fds := command_fds(r)
	fd := fds[which < FDS ? which : 1]
	if c, is := fd.(Fd_Capture); is && int(c.index) < len(r.captures) {
		capture_add(r, &r.captures[c.index], s)
		return
	}
	if r.host.write != nil {
		r.host.write(r.host.ctx, fd, which, s)
	}
}

@(private)
code_release :: proc "contextless" (r: ^Rc, c: ^Code) {
	if c == nil {
		return
	}
	c.refs -= 1
	if c.refs != 0 {
		return
	}
	heap_free(r, c.inst)
	heap_free(r, c.strings)
	heap_free(r, c)
}

@(private = "file")
free_locals :: proc "contextless" (r: ^Rc, v: ^Var) {
	v := v
	for v != nil {
		next := v.next
		free_words(r, v.val)
		code_release(r, v.fn)
		heap_free(r, v)
		v = next
	}
}

// The stages from base on let go, and the files only they used closed.
@(private)
free_stages :: proc "contextless" (r: ^Rc, base: int) {
	for i in base ..< len(r.stages) {
		free_words(r, r.stages[i].argv)
	}
	if base < len(r.stages) {
		resize(&r.stages, base)
	}
	kept := 0
	for c in r.closes {
		if int(c.level) > base {
			if c.close && r.host.close != nil {
				r.host.close(r.host.ctx, c.handle)
			}
			free_words(r, c.path)
		} else {
			r.closes[kept] = c
			kept += 1
		}
	}
	resize(&r.closes, kept)
}

@(private = "file")
pop_redirs :: proc "contextless" (r: ^Rc, to: int) {
	for len(r.redirs) > to {
		d := r.redirs[len(r.redirs) - 1]
		resize(&r.redirs, len(r.redirs) - 1)
		if d.path == nil {
			continue
		}
		// A file the host opened: closed, or once a stage that may have been
		// given it has run. Its path waits with it, for that stage's Fd_File;
		// upstream frees it here, and a stage's path is read after the free.
		file, _ := d.to.(Fd_File)
		if len(r.stages) > 0 && len(r.closes) < cap(r.closes) {
			append(&r.closes, Pending_Close{handle = file.handle, level = u32(len(r.stages)), path = d.path, close = r.host.close != nil})
			continue
		}
		if r.host.close != nil {
			r.host.close(r.host.ctx, file.handle)
		}
		forget_path(r, file.path)
		free_words(r, d.path)
	}
}

// No gathered stage keeps a path about to be freed: it reads as empty.
@(private = "file")
forget_path :: proc "contextless" (r: ^Rc, path: string) {
	for &st in r.stages {
		for &fd in st.fds {
			if f, is := &fd.(Fd_File); is && raw_data(f.path) == raw_data(path) {
				f.path = ""
			}
		}
	}
}

@(private)
@(require_results)
push_frame :: proc "contextless" (r: ^Rc, code: ^Code, pc: u32, locals: ^Var) -> bool {
	if len(r.frames) == FRAMES {
		set_error(r, "functions nested too deeply")
		free_locals(r, locals)
		r.failed = true
		return false
	}
	code.refs += 1
	append(&r.frames, Frame{code = code, pc = pc, locals = locals, redirs = u32(len(r.redirs))})
	return true
}

@(private)
pop_frame :: proc "contextless" (r: ^Rc) {
	f := r.frames[len(r.frames) - 1]
	resize(&r.frames, len(r.frames) - 1)
	free_locals(r, f.locals)
	pop_redirs(r, int(f.redirs))
	code_release(r, f.code)
}

@(private = "file")
new_local :: proc "contextless" (r: ^Rc, name: string, val: ^Word) -> ^Var {
	v := new_var(r, name)
	if v == nil {
		free_words(r, val)
		return nil
	}
	v.val = val
	return v
}

// rc's builtins: the ones the language needs. True if argv's first word is one.
@(private = "file")
builtin :: proc "contextless" (r: ^Rc, argv: ^Word, argc: u32) -> bool {
	switch text(argv) {
	case "exit":
		set_status(r, argc > 1 ? text(argv.next) : "")
		r.exiting = true
		return true
	case "shift": // shift [n]: from $*
		k: u32 = 1
		if argc > 1 {
			k = 0
			for c in transmute([]u8)text(argv.next) {
				if c < '0' || c > '9' {
					break
				}
				k = k * 10 + u32(c - '0')
			}
		}
		star := var_find(r, "*", true)
		for ; k != 0 && star != nil && star.val != nil; k -= 1 {
			first := star.val
			star.val = first.next
			heap_free(r, first)
		}
		set_status(r, "")
		return true
	case "whatis":
		for a := argv.next; a != nil; a = a.next {
			v := var_find(r, text(a), false)
			shell_write(r, 1, c_name(text(a)))
			if v != nil && v.fn != nil {
				shell_write(r, 1, " is a function")
			}
			if v != nil && v.val != nil {
				shell_write(r, 1, "=")
				for w := v.val; w != nil; w = w.next {
					shell_write(r, 1, text(w))
					shell_write(r, 1, w.next != nil ? " " : "")
				}
			}
			shell_write(r, 1, "\n")
		}
		set_status(r, "")
		return true
	}
	return false
}

// `.` and `eval`: text run in a frame of its own, on top.
@(private = "file")
run_nested :: proc "contextless" (r: ^Rc, text: string) -> bool {
	code, _ := compile_text(r, text, 1)
	if code == nil {
		set_status(r, "syntax error")
		return false
	}
	ok := push_frame(r, code, 0, nil)
	code_release(r, code) // the frame holds it
	return ok
}

@(private = "file")
DOT_MAX :: 256 * 1024 // a file `.` reads

// Runs a command whose words are argv: a function, a builtin (rc's, then the
// host's), or a program.
@(private = "file")
simple :: proc "contextless" (r: ^Rc, words: ^Word, async: bool) {
	argv := glob_list(r, words)
	argc := count_words(argv)
	if argc == 0 {
		return
	}
	defer free_words(r, argv)
	if v := var_find(r, text(argv), false); v != nil && v.fn != nil { // a function: $* the rest, in a frame of its own
		star := new_local(r, "*", argv.next)
		argv.next = nil
		_ = push_frame(r, v.fn, v.fn_pc, star)
		return
	}
	if builtin(r, argv, argc) {
		return
	}
	if name := text(argv); name == "." || name == "eval" {
		dot := name[0] == '.'
		if dot && argc > 1 && r.host.read_file != nil {
			buf := heap_alloc(r, DOT_MAX)
			n, ok := 0, false
			if buf != nil {
				n, ok = r.host.read_file(r.host.ctx, text(argv.next), ([^]u8)(buf)[:DOT_MAX])
			}
			if !ok || n < 0 || n > DOT_MAX {
				shell_write(r, 2, "rc: cannot read the file\n")
				set_status(r, "cannot read")
			} else {
				_ = run_nested(r, string(([^]u8)(buf)[:n]))
			}
			heap_free(r, buf)
		} else if !dot { // eval: the words joined
			total := 0
			for w := argv.next; w != nil; w = w.next {
				total += w.len + 1
			}
			buf := heap_alloc(r, total + 1)
			if buf != nil {
				b := ([^]u8)(buf)[:total + 1]
				at := 0
				for w := argv.next; w != nil; w = w.next {
					at += copy(b[at:], text(w))
					b[at] = ' '
					at += 1
				}
				_ = run_nested(r, string(b[:at]))
			}
			heap_free(r, buf)
		}
		return
	}
	fds := command_fds(r)
	if r.host.builtin != nil && r.host.builtin(r.host.ctx, r, argv, argc, &fds) {
		return
	}
	cmd := [1]Command{{argv = argv, argc = argc, fds = fds}}
	pid: u64
	if r.host.run == nil {
		set_status(r, "no way to run programs")
	} else {
		pid, _ = r.host.run(r.host.ctx, r, cmd[:], async)
	}
	if async {
		digits: [str.U64_DIGITS]u8
		set_var_words(r, "apid", new_word(r, str.format_u64(digits[:], pid)))
	}
}

// Concatenation (rc's ^): one word with each of a list, or pairwise; bad if
// a side is empty, or they are lists of different lengths.
@(private = "file")
conc :: proc "contextless" (r: ^Rc, a, b: ^Word) -> (out: ^Word, bad: bool) {
	a, b := a, b
	na, nb := count_words(a), count_words(b)
	if na == 0 || nb == 0 || (na != nb && na != 1 && nb != 1) {
		return nil, true
	}
	l: List
	for _ in 0 ..< max(na, nb) {
		w := heap_new(r, Word, a.len + b.len + 1)
		if w == nil {
			break
		}
		room := word_room(w)
		copy(room, text(a))
		copy(room[a.len:], text(b))
		w.len = a.len + b.len
		list_add(&l, w)
		if na > 1 {
			a = a.next
		}
		if nb > 1 {
			b = b.next
		}
	}
	return l.head, false
}

@(private = "file")
parse_index :: proc "contextless" (s: string) -> (v: u32, ok: bool) {
	for c in transmute([]u8)s {
		if c < '0' || c > '9' || v > 100_000_000 {
			return 0, false
		}
		v = v * 10 + u32(c - '0')
	}
	return v, len(s) > 0
}

// The values of the variables named in names: $1 and the like are $*'s.
@(private = "file")
values :: proc "contextless" (r: ^Rc, names: ^Word) -> ^Word {
	l: List
	for nm := names; nm != nil; nm = nm.next {
		if k, num := parse_index(text(nm)); num && k != 0 { // $n: the n'th of $*; $0 is a variable of its own, the script's name
			w := get_var(r, "*")
			for i: u32 = 1; w != nil && i < k; i += 1 {
				w = w.next
			}
			if w != nil {
				list_add(&l, new_word(r, text(w)))
			}
			continue
		}
		if v := var_find(r, text(nm), false); v != nil {
			list_add(&l, copy_words(r, v.val))
		}
	}
	return l.head
}

@(private = "file")
fail :: proc "contextless" (r: ^Rc, why: string) {
	set_error(r, why)
	r.failed = true
}

// Runs code from the frame on top until the frames it started with have all
// returned, or an error or exit stops it.
@(private)
execute :: proc "contextless" (r: ^Rc, base: u32) {
	steps: u64
	for u32(len(r.frames)) > base && !r.failed && !r.exiting {
		if r.budget != 0 {
			steps += 1
			if steps > r.budget {
				fail(r, "rc: too many steps")
				break
			}
		}
		f := &r.frames[len(r.frames) - 1]
		if f.pc >= f.code.n {
			pop_frame(r)
			continue
		}
		ins := code_inst(f.code)[f.pc]
		f.pc += 1
		switch ins.op {
		case .Mark:
			_ = mark(r)
		case .Word:
			if l := top_list(r); l != nil {
				list_add(l, new_word(r, string(code_strings(f.code)[ins.a:][:ins.b])))
			}
		case .Dol, .Count, .Join:
			names := pop_list(r)
			deglob_list(names)
			vals := values(r, names)
			free_words(r, names)
			l := top_list(r)
			if l == nil {
				free_words(r, vals)
				break
			}
			#partial switch ins.op {
			case .Dol:
				list_add(l, vals)
			case .Count:
				digits: [str.U64_DIGITS]u8
				list_add(l, new_word(r, str.format_u64(digits[:], u64(count_words(vals)))))
				free_words(r, vals)
			case: // $": one word, joined by spaces
				total := 0
				for w := vals; w != nil; w = w.next {
					total += w.len + 1
				}
				j := heap_new(r, Word, total + 1)
				if j != nil {
					room := word_room(j)
					for w := vals; w != nil; w = w.next {
						j.len += copy(room[j.len:], text(w))
						if w.next != nil {
							room[j.len] = ' '
							j.len += 1
						}
					}
				}
				list_add(l, j)
				free_words(r, vals)
			}
		case .Sub: // $x(subscripts): 1-based, ranges n-m and n-
			subs := pop_list(r)
			names := pop_list(r)
			deglob_list(subs)
			deglob_list(names)
			vals := values(r, names)
			nv := count_words(vals)
			for s := subs; s != nil && len(r.stack) > 0; s = s.next {
				t := text(s)
				dash := str.index_byte(t, '-')
				if dash < 0 {
					dash = len(t)
				}
				from, ok1 := parse_index(t[:dash])
				to, ok2 := from, true
				if dash < len(t) {
					if dash + 1 < len(t) {
						to, ok2 = parse_index(t[dash + 1:])
					} else {
						to = nv
					}
				}
				if !ok1 || !ok2 {
					continue
				}
				i: u32 = 1
				for w := vals; w != nil; w = w.next {
					if i >= from && i <= to {
						list_add(top_list(r), new_word(r, text(w)))
					}
					i += 1
				}
			}
			free_words(r, subs)
			free_words(r, names)
			free_words(r, vals)
		case .Conc:
			b := pop_list(r)
			a := pop_list(r)
			c, bad := conc(r, a, b)
			free_words(r, a)
			free_words(r, b)
			if bad {
				fail(r, "rc: ^ of lists of different lengths, or an empty one")
				break
			}
			if l := top_list(r); l != nil {
				list_add(l, c)
			} else {
				free_words(r, c)
			}
		case .Simple:
			simple(r, pop_list(r), ins.f0 != 0)
		case .Stage: // a: its own redirections, the top of the stack
			argv := glob_list(r, pop_list(r))
			if len(r.stages) == STAGES {
				free_words(r, argv)
				fail(r, "pipelines nested too deeply")
				break
			}
			st := Command {
				argv = argv,
				argc = count_words(argv),
				fds  = inherited(),
			}
			// As rc does in the child: what encloses the pipeline, then the pipe
			// ends, then the stage's own redirections, which may move them.
			own := len(r.redirs) >= int(ins.a) ? len(r.redirs) - int(ins.a) : 0
			apply_redirs(r, &st.fds, 0, own)
			if ins.f0 < FDS {
				st.fds[ins.f0] = Fd_Pipe_Out{}
			}
			if ins.f1 < FDS {
				st.fds[ins.f1] = Fd_Pipe_In{}
			}
			apply_redirs(r, &st.fds, own, len(r.redirs))
			append(&r.stages, st)
		case .Pipeline: // a: how many stages, the last gathered
			first := len(r.stages) >= int(ins.a) ? len(r.stages) - int(ins.a) : 0
			stages := r.stages[first:]
			ok := len(stages) > 0 && len(stages) == int(ins.a)
			for &c in stages {
				if c.argc == 0 {
					ok = false
				} else if v := var_find(r, text(c.argv), false); v != nil && v.fn != nil {
					ok = false
				}
			}
			if !ok {
				shell_write(r, 2, "rc: a pipeline's stages must be programs (for now)\n")
				set_status(r, "pipeline")
			} else if r.host.run != nil {
				_, _ = r.host.run(r.host.ctx, r, stages, ins.f0 != 0)
			}
			free_stages(r, first)
		case .Assign, .Local:
			name := pop_list(r)
			val := glob_list(r, pop_list(r))
			deglob_list(name)
			if name == nil || name.next != nil {
				fail(r, "rc: a variable's name must be one word")
				free_words(r, name)
				free_words(r, val)
				break
			}
			if ins.op == .Assign {
				set_var_words(r, text(name), val)
			} else if v := new_local(r, text(name), val); v != nil {
				v.next = f.locals
				f.locals = v
			}
			free_words(r, name)
		case .Unlocal:
			if v := f.locals; v != nil {
				f.locals = v.next
				v.next = nil
				free_locals(r, v)
			}
		case .If:
			r.ifnot = !true_status(r)
			if r.ifnot {
				f.pc = ins.a
			}
		case .If_Not:
			if !r.ifnot {
				f.pc = ins.a
			}
		case .Was_True:
			r.ifnot = false
		case .True:
			if !true_status(r) {
				f.pc = ins.a
			}
		case .False:
			if true_status(r) {
				f.pc = ins.a
			}
		case .Jump:
			f.pc = ins.a
		case .Bang:
			set_status(r, true_status(r) ? "false" : "")
		case .For: // the next word of the list on top into the newest local
			l := top_list(r)
			if l == nil || l.head == nil {
				f.pc = ins.a
				break
			}
			w := l.head
			l.head = w.next
			if l.head == nil {
				l.tail = nil
			}
			l.n -= 1
			w.next = nil
			// Globbed as it is taken: the names it matches go back on the front of
			// the list, the first of them taken now (they have no marks to match again).
			w = glob(r, w)
			if rest := w.next; rest != nil {
				last := rest
				k: u32 = 1
				for ; last.next != nil; last = last.next {
					k += 1
				}
				last.next = l.head
				if l.head == nil {
					l.tail = last
				}
				l.head = rest
				l.n += k
				w.next = nil
			}
			if f.locals != nil {
				free_words(r, f.locals.val)
				f.locals.val = w
			} else {
				heap_free(r, w)
			}
		case .Popm:
			free_words(r, pop_list(r))
		case .Fn: // the names on top: each the function whose body follows
			names := pop_list(r)
			deglob_list(names)
			for n := names; n != nil; n = n.next {
				v := var_find(r, text(n), true)
				if v == nil {
					continue
				}
				code_release(r, v.fn)
				v.fn = f.code
				v.fn_pc = f.pc
				f.code.refs += 1
			}
			free_words(r, names)
			f.pc = ins.a
		case .Delfn:
			names := pop_list(r)
			deglob_list(names)
			for n := names; n != nil; n = n.next {
				if v := var_find(r, text(n), false); v != nil {
					code_release(r, v.fn)
					v.fn = nil
				}
			}
			free_words(r, names)
		case .Return:
			pop_frame(r)
		case .Match: // ~ subject patterns
			subj := pop_list(r)
			pats := pop_list(r)
			deglob_list(subj)
			hit := false
			for s := subj; s != nil && !hit; s = s.next {
				for p := pats; p != nil && !hit; p = p.next {
					hit = match(text(s), text(p))
				}
			}
			if subj == nil { // ~ () pattern: an empty subject matches only an empty pattern list
				hit = pats == nil
			}
			set_status(r, hit ? "" : "no match")
			free_words(r, subj)
			free_words(r, pats)
		case .Case: // the patterns on top against the subject below them
			pats := pop_list(r)
			hit := false
			if subj := top_list(r); subj != nil {
				for s := subj.head; s != nil && !hit; s = s.next {
					for p := pats; p != nil && !hit; p = p.next {
						hit = match(text(s), text(p))
					}
				}
			}
			free_words(r, pats)
			if !hit {
				f.pc = ins.a
			}
		case .Backq: // fd 1 into a new capture
			if len(r.captures) == CAPTURES || len(r.redirs) == REDIRS {
				fail(r, "rc: ` nested too deeply")
				break
			}
			append(&r.redirs, Redir{fd = 1, to = Fd_Capture{u8(len(r.captures))}})
			append(&r.captures, Capture{})
		case .Backq_End: // the capture split at the separators on top
			c: Capture
			if len(r.captures) > 0 {
				c = r.captures[len(r.captures) - 1]
				resize(&r.captures, len(r.captures) - 1)
			}
			if len(r.redirs) > 0 {
				pop_redirs(r, len(r.redirs) - 1)
			}
			// Every byte of every word of $ifs separates; none (ifs=()) makes the
			// whole output one word.
			ifs := pop_list(r)
			seps: [dynamic; 64]u8
			for w := ifs; w != nil; w = w.next {
				for b in transmute([]u8)text(w) {
					if len(seps) == cap(seps) {
						break
					}
					append(&seps, b)
				}
			}
			out := c.buf[:c.len]
			for i := 0; i < len(out) && len(r.stack) > 0; {
				for i < len(out) && has(seps[:], out[i]) {
					i += 1
				}
				start := i
				for i < len(out) && !has(seps[:], out[i]) {
					i += 1
				}
				if i > start {
					list_add(top_list(r), new_word(r, string(out[start:i])))
				}
			}
			free_words(r, ifs)
			heap_free(r, raw_data(c.buf))
		case .Redir:
			path := glob_list(r, pop_list(r))
			if path == nil || path.next != nil || len(r.redirs) == REDIRS {
				fail(r, "rc: a redirection needs one file")
				free_words(r, path)
				break
			}
			kind := Open_Kind(ins.f1)
			handle: u32
			if r.host.open != nil {
				h, ok := r.host.open(r.host.ctx, r, text(path), kind)
				if !ok {
					shell_write(r, 2, "rc: cannot open ")
					shell_write(r, 2, text(path))
					shell_write(r, 2, "\n")
					free_words(r, path)
					r.failed = true
					break
				}
				handle = h
			}
			append(&r.redirs, Redir{fd = ins.f0, to = Fd_File{kind = kind, handle = handle, path = text(path)}, path = path})
		case .Dup:
			if len(r.redirs) == REDIRS {
				break
			}
			to: Fd = Fd_Dup{ins.f1}
			if ins.f1 == CLOSE_FD {
				to = Fd_Closed{}
			}
			append(&r.redirs, Redir{fd = ins.f0, to = to})
		case .Popredir:
			pop_redirs(r, len(r.redirs) >= int(ins.a) ? len(r.redirs) - int(ins.a) : 0)
		}
	}
}
