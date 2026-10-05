// The machine (rc's exec.c), with patterns and globbing (glob.c) and the
// builtins.
package rc

import "vx:str"

// --- Patterns and globbing ---

// The length of the UTF-8 sequence at s[i], 1 when it is not one, as rc's
// nextutf; and its rune (-1 if malformed), as rc's unicode.
@(private = "file")
utf :: proc "contextless" (s: string, i: int) -> (n: int, c: i32) {
	b := s[i]
	size := 4
	v := i32(b & 0x07)
	switch {
	case b < 0x80:
		size, v = 1, i32(b)
	case b < 0xe0:
		size, v = 2, i32(b & 0x1f)
	case b < 0xf0:
		size, v = 3, i32(b & 0x0f)
	}
	n = 1
	for ; n < size && i + n < len(s) && s[i + n] & 0xc0 == 0x80; n += 1 {
		v = v << 6 | i32(s[i + n] & 0x3f)
	}
	return n, n == size ? v : -1
}

// Whether s matches pattern p, as rc's match: * ? and [ are special only
// where GLOB marks them (a doubled mark is the byte itself), ? and a class
// match one rune, and a class's range may be written either way round. No
// recursion: a * is retried from where it last matched, which is exact for
// patterns of *, ? and classes.
@(private)
match :: proc "contextless" (s, p: string) -> bool {
	n, m := len(s), len(p)
	si, pi := 0, 0
	star_p, star_s := -1, 0
	for si < n || pi < m {
		if pi + 1 < m && p[pi] == GLOB && p[pi + 1] == '*' {
			pi += 2
			star_p, star_s = pi, si
			continue
		}
		if si < n && pi < m {
			sl, c := utf(s, si)
			marked := p[pi] == GLOB && pi + 1 < m
			if marked && p[pi + 1] == '?' {
				pi += 2
				si += sl
				continue
			}
			if marked && p[pi + 1] == '[' { // [abc], [a-z], [~abc]
				q := pi + 2
				neg := q < m && p[q] == '~'
				hit, closed := false, false
				if neg {
					q += 1
				}
				for q < m {
					if p[q] == ']' {
						closed = true
						break
					}
					k, lo := utf(p, q)
					q += k
					hi := lo
					if q < m && p[q] == '-' {
						q += 1
						if q >= m {
							break
						}
						k, hi = utf(p, q)
						q += k
						if hi < lo {
							lo, hi = hi, lo
						}
					}
					if lo <= c && c <= hi {
						hit = true
					}
				}
				if closed && hit != neg {
					pi = q + 1
					si += sl
					continue
				}
			} else if marked && p[pi + 1] == GLOB { // the byte itself
				if s[si] == GLOB {
					pi += 2
					si += 1
					continue
				}
			} else if p[pi] != GLOB {
				if pl, _ := utf(p, pi); pl == sl && p[pi:][:pl] == s[si:][:sl] {
					pi += pl
					si += sl
					continue
				}
			}
		}
		if star_p < 0 || star_s >= n { // no * to stretch, or nothing left to give it
			return false
		}
		k, _ := utf(s, star_s)
		star_s += k
		pi, si = star_p, star_s
	}
	return true
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

// A word with its glob marks taken out, in place: as rc's, each mark goes,
// and the byte after it stays (a mark too).
@(private = "file")
deglob :: proc "contextless" (w: ^Word) {
	b := word_room(w)
	k := 0
	for i := 0; i < w.len; i += 1 {
		if b[i] == GLOB && i + 1 < w.len {
			i += 1
		}
		b[k] = b[i]
		k += 1
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
	if (name == "." || name == "..") && !(len(g.pat) > 0 && g.pat[0] == '.') { // . and .. only when asked for, as rc's
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
	globbed, plain_after := false, false // a pattern matched, and a plain component came after it
	for at < len(s) && paths != nil {
		end := at
		for end < len(s) && s[end] != '/' {
			end += 1
		}
		component := s[at:end]
		plain_after = globbed && !globby(component)
		globbed = globbed || globby(component)
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
	if plain_after && r.host.exists != nil { // as rc's globdir: what follows the last pattern must exist
		kept: List
		for paths != nil {
			x := paths
			paths = x.next
			x.next = nil
			if r.host.exists(r.host.ctx, text(x)) {
				list_add(&kept, x)
			} else {
				heap_free(r, x)
			}
		}
		paths = kept.head
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
		fail(r, "", "stack overflow")
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
		fail(r, "", "functions nested too deeply")
		free_locals(r, locals)
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
		fail(r, "", "empty argument list")
		return
	}
	v := gvar_find(r, text(argv), false)
	if v != nil && v.fn != nil && async { // rc runs it in a child, which needs upstream's M6 step 6d: refused, not run in the foreground
		shell_write(r, 2, "rc: a function run with & needs a child (for now)\n")
		set_status(r, "async")
		free_words(r, argv)
		return
	}
	if v != nil && v.fn != nil { // a function: $* the rest, in a frame of its own
		star := new_local(r, "*", argv.next)
		argv.next = nil
		free_words(r, argv)
		_ = push_frame(r, v.fn, v.fn_pc, star)
		return
	}
	defer free_words(r, argv)
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

// Concatenation (rc's ^): one word with each of a list, or pairwise; two
// empty lists make an empty one, as rc's Xconc. bad says why it cannot be.
@(private = "file")
conc :: proc "contextless" (r: ^Rc, a, b: ^Word) -> (out: ^Word, bad: string) {
	a, b := a, b
	na, nb := count_words(a), count_words(b)
	if na == 0 && nb == 0 {
		return nil, ""
	}
	if na == 0 || nb == 0 {
		return nil, "null list in concatenation"
	}
	if na != nb && na != 1 && nb != 1 {
		return nil, "mismatched list lengths in concatenation"
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
	return l.head, ""
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

// The value of the variable named in names, which must be one word (rc's
// Xdol and Xcount), and how many words it has: $1 and the like are $*'s. ok
// is false, with the run failed (what), if names is not one word.
@(private = "file")
value :: proc "contextless" (r: ^Rc, names: ^Word, what: string) -> (out: ^Word, count: u32, ok: bool) {
	if names == nil || names.next != nil {
		fail(r, "", what)
		return nil, 0, false
	}
	if k, num := parse_index(text(names)); num && k != 0 { // $n: the n'th of $*; $0 is a variable of its own, the script's name
		w := get_var(r, "*")
		for i: u32 = 1; w != nil && i < k; i += 1 {
			w = w.next
		}
		if w != nil {
			return new_word(r, text(w)), 1, true
		}
		return nil, 0, true
	}
	if v := var_find(r, text(names), false); v != nil {
		return copy_words(r, v.val), count_words(v.val), true
	}
	return nil, 0, true
}

// A list joined by spaces into one word, "" for none (rc's Xqw); it takes the list.
@(private = "file")
qw :: proc "contextless" (r: ^Rc, list: ^Word) -> ^Word {
	total := 0
	for w := list; w != nil; w = w.next {
		total += w.len + 1
	}
	j := heap_new(r, Word, total + 1)
	if j != nil {
		room := word_room(j)
		for w := list; w != nil; w = w.next {
			j.len += copy(room[j.len:], text(w))
			if w.next != nil {
				room[j.len] = ' '
				j.len += 1
			}
		}
	}
	free_words(r, list)
	return j
}

// A run-time error, as rc's Xerror1 and Xerror2: `where: a[: b]` for the host
// to show, $status status ("": "error"), and the run ends. Each part is read
// as upstream's C reads it, to its first NUL.
@(private = "file")
fail :: proc "contextless" (r: ^Rc, status, a: string, b := "") {
	line: u32
	if len(r.frames) > 0 {
		f := &r.frames[len(r.frames) - 1]
		if f.pc != 0 && f.pc <= f.code.n {
			line = code_inst(f.code)[f.pc - 1].line
		}
	}
	buf: [96]u8
	set_error(r, place(&buf, string(r.src[:]), line), ": ", a)
	if b != "" {
		if len(r.err) + 3 < ERR_MAX + 1 {
			append(&r.err, ':', ' ')
		}
		add_error(r, b)
	}
	set_status(r, c_name(status != "" ? status : "error"))
	r.failed = true
	r.failset = true
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
				fail(r, "", "too many steps")
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
			vals, k, ok := value(r, names, ins.op == .Count ? "$# variable name not singleton!" : "$ variable name not singleton!")
			free_words(r, names)
			l := top_list(r)
			if !ok || l == nil {
				free_words(r, vals)
				break
			}
			#partial switch ins.op {
			case .Dol:
				list_add(l, vals)
			case .Count:
				digits: [str.U64_DIGITS]u8
				list_add(l, new_word(r, str.format_u64(digits[:], u64(k))))
				free_words(r, vals)
			case: // $": one word, joined by spaces
				list_add(l, qw(r, vals))
			}
		case .Sub: // $x(subscripts) as rc's subwords: 1-based, ranges n-m and n-
			subs := pop_list(r)
			names := pop_list(r)
			deglob_list(subs)
			deglob_list(names)
			if names == nil || names.next != nil {
				fail(r, "", "$() variable name not singleton!")
				free_words(r, subs)
				free_words(r, names)
				break
			}
			v := var_find(r, text(names), false) // $1(2) is a variable named 1's, as rc's
			vals := v != nil ? v.val : nil
			nv := count_words(vals)
			for sw := subs; sw != nil && len(r.stack) > 0; sw = sw.next {
				t := text(sw)
				i := 0
				n, m: u32
				for i < len(t) && t[i] >= '0' && t[i] <= '9' && n < 100_000_000 {
					n = n * 10 + u32(t[i] - '0')
					i += 1
				}
				neg := false
				if i < len(t) && t[i] == '-' {
					i += 1
					if i == len(t) {
						neg = n > nv
						m = neg ? 0 : nv - n
					} else {
						to: u32
						for i < len(t) && t[i] >= '0' && t[i] <= '9' && to < 100_000_000 {
							to = to * 10 + u32(t[i] - '0')
							i += 1
						}
						neg = to < n
						m = neg ? 0 : to - n
					}
				}
				if n < 1 || n > nv || neg {
					continue
				}
				m = min(m, nv - n)
				w := vals
				for _ in 1 ..< n {
					w = w.next
				}
				for k: u32 = 0; k <= m && w != nil; k += 1 {
					list_add(top_list(r), new_word(r, text(w)))
					w = w.next
				}
			}
			free_words(r, subs)
			free_words(r, names)
		case .Conc:
			b := pop_list(r)
			a := pop_list(r)
			c, bad := conc(r, a, b)
			free_words(r, a)
			free_words(r, b)
			if bad != "" {
				fail(r, "", bad)
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
				fail(r, "", "pipelines nested too deeply")
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
				} else if v := gvar_find(r, text(c.argv), false); v != nil && v.fn != nil {
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
				fail(r, "", ins.op == .Assign ? "= variable name not singleton!" : "local variable name must be singleton")
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
				v := gvar_find(r, text(n), true)
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
				if v := gvar_find(r, text(n), false); v != nil {
					code_release(r, v.fn)
					v.fn = nil
				}
			}
			free_words(r, names)
		case .Return:
			pop_frame(r)
		case .Qw: // the list on top as one word, its marks gone: a subject is never a pattern
			l := pop_list(r)
			deglob_list(l)
			if mark(r) {
				list_add(top_list(r), qw(r, l))
			}
		case .Settrue:
			set_status(r, "")
		case .Match: // ~ subject patterns: the subject (one word, Qw's) against each
			subj := pop_list(r)
			pats := pop_list(r)
			hit := false
			for p := pats; subj != nil && p != nil && !hit; p = p.next {
				hit = match(text(subj), text(p))
			}
			set_status(r, hit ? "" : "no match")
			free_words(r, subj)
			free_words(r, pats)
		case .Case: // the patterns on top against the subject below them (one word, Qw's)
			pats := pop_list(r)
			hit := false
			if subj := top_list(r); subj != nil && subj.head != nil {
				for p := pats; p != nil && !hit; p = p.next {
					hit = match(text(subj.head), text(p))
				}
			}
			free_words(r, pats)
			if !hit {
				f.pc = ins.a
			}
		case .Backq: // fd 1 into a new capture
			if len(r.captures) == CAPTURES || len(r.redirs) == REDIRS {
				fail(r, "", "` nested too deeply")
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
			// Every byte of $ifs separates, its words joined by spaces as rc's (so
			// a space too when it has several); none (ifs=()) makes the output
			// one word.
			ifs := pop_list(r)
			seps: [dynamic; 64]u8
			for w := ifs; w != nil; w = w.next {
				for b in transmute([]u8)text(w) {
					if len(seps) == cap(seps) {
						break
					}
					append(&seps, b)
				}
				if w.next != nil && len(seps) < cap(seps) {
					append(&seps, ' ')
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
			kind := Open_Kind(ins.f1)
			OPS := [Open_Kind]string {
				.Read   = "<",
				.Write  = ">",
				.Append = ">>",
				.Rdwr   = "<>",
			}
			if path == nil || path.next != nil || len(r.redirs) == REDIRS { // as rc's: > requires file, > requires singleton
				tail := " requires singleton"
				if path == nil {
					tail = " requires file"
				} else if len(r.redirs) == REDIRS {
					tail = " nested too deeply"
				}
				msg: [32]u8
				fail(r, "", str.join(msg[:], OPS[kind], tail) or_else "")
				free_words(r, path)
				break
			}
			handle: u32
			if r.host.open != nil {
				h, ok := r.host.open(r.host.ctx, r, text(path), kind)
				if !ok {
					// rc's Xerror3: `< can't open: file: why`, why (the host's, in $status) the status.
					msg: [dynamic; ERR_MAX]u8
					append(&msg, OPS[kind], " can't open: ")
					append(&msg, text(path))
					why: [dynamic; ERR_MAX]u8
					if st := get_var(r, "status"); st != nil {
						append(&why, text(st))
					}
					if len(why) == 0 {
						append(&why, "cannot open")
					}
					free_words(r, path)
					fail(r, string(why[:]), string(msg[:]), string(why[:]))
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
