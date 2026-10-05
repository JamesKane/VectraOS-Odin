// The machine (rc's exec.c), with patterns and globbing (glob.c) and the
// builtins.
package rc

import "base:intrinsics"
import "vx:str"
import vxutf "vx:utf"

// --- Patterns and globbing ---

// The length of the UTF-8 sequence at s[i], 1 when it is not one; and its
// rune, -1 if it is not one: vx:utf's strict decoding, the one rune library
// (upstream ADR-0013).
@(private = "file")
utf :: proc "contextless" (s: string, i: int) -> (n: int, c: i32) {
	r, size := vxutf.decode(s[i:])
	bad := size == 1 && r == vxutf.RUNE_ERROR && s[i] >= vxutf.RUNE_SELF
	return max(size, 1), bad ? -1 : i32(r)
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
		// given it has run. Its path waits with it, for that stage's Fd_File,
		// as a here document's text does for its Fd_Here. A here document has
		// no file to close. More than rc keeps for one pipeline fail the
		// command, so its stages never run (upstream ab83fe6).
		file, is_file := d.to.(Fd_File)
		if len(r.stages) > 0 {
			if len(r.closes) < cap(r.closes) {
				append(&r.closes, Pending_Close{handle = file.handle, level = u32(len(r.stages)), path = d.path, close = is_file && r.host.close != nil})
				continue
			}
			fail(r, "", "too many redirections in one pipeline")
		}
		if is_file && r.host.close != nil {
			r.host.close(r.host.ctx, file.handle)
		}
		forget(r, raw_data(text(d.path)))
		free_words(r, d.path)
	}
}

// No gathered stage keeps a path or here document about to be freed: it
// reads as empty.
@(private = "file")
forget :: proc "contextless" (r: ^Rc, s: [^]u8) {
	for &st in r.stages {
		for &fd in st.fds {
			#partial switch &v in fd {
			case Fd_File:
				if raw_data(v.path) == s {
					v.path = ""
				}
			case Fd_Here:
				if raw_data(v.text) == s {
					v.text = ""
				}
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
	append(&r.frames, Frame{code = code, pc = pc, locals = locals, redirs = u32(len(r.redirs)), sp = u32(len(r.stack)), ncaptures = u32(len(r.captures))})
	return true
}

@(private)
pop_frame :: proc "contextless" (r: ^Rc) {
	f := r.frames[len(r.frames) - 1]
	resize(&r.frames, len(r.frames) - 1)
	free_locals(r, f.locals)
	pop_redirs(r, int(f.redirs))
	code_release(r, f.code)
	reader_free(r, f.rd)
}

@(private)
new_local :: proc "contextless" (r: ^Rc, name: string, val: ^Word) -> ^Var {
	v := new_var(r, name)
	if v == nil {
		free_words(r, val)
		return nil
	}
	v.val = val
	return v
}

// --- Reading commands as they come (rc's Xrdcmds) ---

@(private)
Reader :: struct {
	buf:         []u8, // a file's whole text, or what has been read of standard input: in the heap
	len, pos:    int, // its length, and what has been read of it
	line:        u32, // the lines read so far
	interactive: bool, // -i: prompts, and an error goes back to it rather than ending everything
	tty:         bool, // its text comes a line at a time from rc's standard input
	whole:       bool, // -b: the whole text compiled at once
	quiet:       bool, // -q: -e does not apply to it
	eof:         bool,
	name:        [64]u8, // for errors, file:line: to its first NUL, as upstream's
}
#assert(size_of(Reader) == 112) // upstream's rc_reader: the heap's sizes are its

@(private)
reader_new :: proc "contextless" (r: ^Rc, name: string) -> ^Reader {
	rd := heap_new(r, Reader)
	if rd != nil {
		copy(rd.name[:len(rd.name) - 1], name)
	}
	return rd
}

@(private)
reader_free :: proc "contextless" (r: ^Rc, rd: ^Reader) {
	if rd == nil {
		return
	}
	heap_free(r, raw_data(rd.buf))
	heap_free(r, rd)
}

@(private = "file")
reader_name :: proc "contextless" (rd: ^Reader) -> string {
	return c_name(string(rd.name[:]))
}

// A frame that reads from rd (which it takes), with locals (which it takes).
@(private)
push_reader :: proc "contextless" (r: ^Rc, rd: ^Reader, locals: ^Var) -> bool {
	if rd == nil {
		free_locals(r, locals)
		return false
	}
	if !push_frame(r, r.rdcode, 0, locals) {
		reader_free(r, rd)
		return false
	}
	r.frames[len(r.frames) - 1].rd = rd
	return true
}

// rc's own standard error, whatever a command's redirections are: rc's
// messages go there, as rc's err.
@(private = "file")
errout :: proc "contextless" (r: ^Rc, s: string) {
	if r.host.write != nil {
		r.host.write(r.host.ctx, Fd_Inherit{2}, 2, s)
	}
}

// Whether a word is written bare by rc's %q: else in quotes.
@(private = "file")
bare :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in transmute([]u8)s {
		if !word_char(c) || c == GLOB {
			return false
		}
	}
	return true
}

// A word as rc quotes it (%q), to out: bare when it can be, else in '' with
// '' for a quote.
@(private = "file")
quote :: proc "contextless" (r: ^Rc, s: string, out: proc "contextless" (r: ^Rc, s: string)) {
	if bare(s) {
		out(r, s)
		return
	}
	out(r, "'")
	for i in 0 ..< len(s) {
		if s[i] == '\'' {
			out(r, "'")
		}
		out(r, s[i:][:1])
	}
	out(r, "'")
}

@(private = "file")
errwords :: proc "contextless" (r: ^Rc, w: ^Word) { // rc's %v
	for x := w; x != nil; x = x.next {
		quote(r, text(x), errout)
		errout(r, x.next != nil ? " " : "")
	}
}

// One more line of rd's standard input onto its text: false at the end.
@(private = "file")
reader_more :: proc "contextless" (r: ^Rc, rd: ^Reader, first: bool) -> bool {
	if rd.eof || r.host.read_line == nil {
		rd.eof = true
		return false
	}
	if rd.interactive { // the prompt: $prompt's first word for a command, its second for a line that goes on
		use := get_var(r, "prompt")
		if !first && use != nil {
			use = use.next
		}
		if use != nil {
			errout(r, text(use))
		} else {
			errout(r, first ? "% " : "\t")
		}
	}
	if len(rd.buf) - rd.len < 4096 { // room for a line
		size := len(rd.buf) != 0 ? len(rd.buf) * 2 : 8192
		if size > 1 << 20 {
			errout(r, "rc: line too long\n")
			rd.eof = true
			return false
		}
		more := heap_alloc(r, size)
		if more == nil {
			rd.eof = true
			return false
		}
		copy(([^]u8)(more)[:size], rd.buf[:rd.len])
		heap_free(r, raw_data(rd.buf))
		rd.buf = ([^]u8)(more)[:size]
	}
	n := r.host.read_line(r.host.ctx, rd.buf[rd.len:])
	if n <= 0 {
		rd.eof = true
		return false
	}
	rd.len += min(n, len(rd.buf) - rd.len)
	return true
}

// The next command of the frame's reader, compiled and run in a frame of its
// own; this frame goes back to read the one after.
@(private = "file")
rdcmds :: proc "contextless" (r: ^Rc, f: ^Frame) {
	rd := f.rd
	if r.flag['s'] && !true_status(r) { // -s: a status that is not true, before the next command
		errout(r, "status=")
		errwords(r, get_var(r, "status"))
		errout(r, "\n")
	}
	if rd.tty && rd.pos == rd.len { // what was run, let go
		rd.pos, rd.len = 0, 0
	}
	start := rd.pos
	line0 := rd.line + 1
	code: ^Code
	incomplete := false
	for {
		if rd.pos == rd.len && (!rd.tty || !reader_more(r, rd, rd.pos == start)) {
			break
		}
		from := rd.pos
		if rd.whole {
			rd.pos = rd.len
		} else {
			for rd.pos < rd.len && rd.buf[rd.pos] != '\n' {
				rd.pos += 1
			}
			if rd.pos < rd.len {
				rd.pos += 1
			}
		}
		for c in rd.buf[from:rd.pos] {
			rd.line += c == '\n' ? 1 : 0
		}
		if r.flag['v'] || r.flag['V'] { // -v: input as read
			errout(r, string(rd.buf[from:rd.pos]))
		}
		was := r.src // what it compiles names its file
		source(r, reader_name(rd))
		e := r.flag['e']
		if rd.quiet {
			r.flag['e'] = false // . -q: no -e in it, as rc's
		}
		code = compile_text(r, string(rd.buf[start:rd.pos]), line0, &incomplete)
		r.flag['e'] = e
		r.src = was
		if code != nil || !incomplete {
			break
		}
	}
	if code == nil && start == rd.pos {
		return // the end: the frame returns
	}
	if code == nil { // a syntax error, or the end inside a construct: said, and in $status
		if incomplete && rd.pos == rd.len {
			buf: [96]u8
			errout(r, place(buf[:], reader_name(rd), rd.line))
			errout(r, ": unexpected end of file\n")
			set_status(r, "unexpected end of file")
			r.incomplete = true
		} else {
			errout(r, string(r.err[:]))
			errout(r, "\n")
			r.syntax = true
		}
		if rd.interactive && !rd.eof {
			f.pc -= 1 // the next command, as rc's
		}
		return
	}
	f.pc -= 1 // back for the next command once this one has run
	_ = push_frame(r, code, 0, nil)
	code_release(r, code)
}

// rc's builtins: the ones the language needs. True if argv's first word is one.
@(private = "file")
builtin :: proc "contextless" (r: ^Rc, argv: ^Word, argc: u32) -> bool {
	switch text(argv) {
	case "exit": // exit [status]: with no status, $status as it is (rc's execexit)
		if argc > 2 {
			errout(r, "Usage: exit [status]\nExiting anyway\n") // whole, as upstream's f24356f writes it
		}
		if argc > 1 {
			set_status(r, text(argv.next))
		}
		r.exiting = true
		return true
	case "shift": // shift [n]: from $*, n as atoi reads it (rc's execshift)
		if argc > 2 {
			errout(r, "Usage: shift [n]\n")
			set_status(r, "shift usage")
			return true
		}
		k := 1
		if argc > 1 {
			a := text(argv.next)
			i := 0
			neg := i < len(a) && a[i] == '-'
			if neg || (i < len(a) && a[i] == '+') {
				i += 1
			}
			for k = 0; i < len(a) && a[i] >= '0' && a[i] <= '9' && k < 1_000_000; i += 1 {
				k = k * 10 + int(a[i] - '0')
			}
			if neg {
				k = -k
			}
		}
		star := var_find(r, "*", true)
		for ; k > 0 && star != nil && star.val != nil; k -= 1 {
			first := star.val
			star.val = first.next
			heap_free(r, first)
		}
		set_status(r, "")
		return true
	case "flag": // flag f [+-], as rc's execflag
		f: u8
		if argc > 1 && argv.next.len == 1 {
			f = text(argv.next)[0]
		}
		if argc == 2 && argv.next.len != 0 {
			f = text(argv.next)[0]
			set := f < 128 && r.flag[f]
			set_status(r, set ? "" : "flag not set")
			return true
		}
		v := argc == 3 ? argv.next.next : nil
		if f != 0 && f < 128 && v != nil && (text(v) == "+" || text(v) == "-") {
			r.flag[f] = text(v) == "+"
			set_status(r, "")
			return true
		}
		fail(r, "", "Usage: flag [letter] [+-]")
		return true
	case "whatis":
		whatis(r, argv)
		return true
	}
	return false
}

// rc's own builtins, by name (rc's Builtin[]: cd and the namespace's are the host's).
@(private = "file")
BUILTINS := [?]string{".", "builtin", "eval", "exec", "exit", "flag", "shift", "wait", "whatis"}

@(private = "file")
is_builtin :: proc "contextless" (r: ^Rc, s: string) -> bool {
	for b in BUILTINS {
		if s == b {
			return true
		}
	}
	for b in r.host.builtin_names {
		if s == b {
			return true
		}
	}
	return false
}

// Output on the shell's descriptor 1, for quote.
@(private = "file")
out1 :: proc "contextless" (r: ^Rc, s: string) {
	shell_write(r, 1, s)
}

// whatis name ..., as rc's execwhatis: each name's value (x=val, or
// x=(a 'b c')), then its function (fn name {body}), or builtin name, or
// the program $path finds; $status "not found" for a name that is none.
@(private = "file")
whatis :: proc "contextless" (r: ^Rc, argv: ^Word) {
	if argv.next == nil {
		fail(r, "", "Usage: whatis name ...")
		return
	}
	set_status(r, "")
	for a := argv.next; a != nil; a = a.next {
		name := text(a)
		v := var_find(r, name, false)
		found := v != nil && v.val != nil
		if found {
			out1(r, name)
			out1(r, "=")
			if v.val.next == nil {
				quote(r, text(v.val), out1)
			} else {
				for w := v.val; w != nil; w = w.next {
					out1(r, w == v.val ? "(" : " ")
					quote(r, text(w), out1)
				}
				out1(r, ")")
			}
			out1(r, "\n")
		}
		if g := gvar_find(r, name, false); g != nil && g.fn != nil {
			out1(r, "fn ")
			quote(r, name, out1)
			out1(r, " ")
			out1(r, g.fnsrc != nil ? var_fnsrc(g) : "{}")
			out1(r, "\n")
			continue
		}
		if is_builtin(r, name) {
			out1(r, "builtin ")
			out1(r, name)
			out1(r, "\n")
			continue
		}
		here := str.has_prefix(name, "/") || str.has_prefix(name, "./")
		dirs := here ? nil : get_var(r, "path")
		as_is: Word // "": the name as written
		if dirs == nil {
			dirs = &as_is
		}
		hit := false
		for d := dirs; d != nil && !hit && r.host.exists != nil; d = d.next {
			path_buf: [512]u8
			path := path_join(path_buf[:], d == &as_is ? "" : text(d), name) or_continue
			hit = r.host.exists(r.host.ctx, path)
			if hit {
				out1(r, path)
				out1(r, "\n")
			}
		}
		if !hit && !found {
			set_status(r, "not found")
		}
	}
}

@(private = "file")
DOT_MAX :: 256 * 1024 // a file `.` reads

// Whether a name says where it is, so no directory of $path is tried: it
// starts / ./ or ../ (as rc's searchpath).
@(private = "file")
here_name :: proc "contextless" (s: string) -> bool {
	return str.has_prefix(s, "/") || str.has_prefix(s, "./") || str.has_prefix(s, "../")
}

// A directory of $path joined to a name, into buf, as upstream's `.` and
// whatis join them: "" and . mean the name as written, and so does a
// directory too long for buf. ok is false if the name does not fit.
@(private = "file")
path_join :: proc "contextless" (buf: []u8, dir, name: string) -> (path: string, ok: bool) {
	n := 0
	if len(dir) != 0 && dir != "." && len(dir) + 1 < len(buf) {
		n = copy(buf, dir)
		if buf[n - 1] != '/' {
			buf[n] = '/'
			n += 1
		}
	}
	if n + len(name) >= len(buf) {
		return "", false
	}
	n += copy(buf[n:], name)
	return string(buf[:n]), true
}

// `.` [-biq] file [arg ...], as rc's execdot: the file, found through $path
// unless its name says where it is, read and run a command at a time in a
// frame of its own, $* its arguments and $0 its name. '#d/0' is rc's own
// standard input. -b: compiled whole; -i: interactive; -q: no error if it is
// not there, and no -e in it.
@(private = "file")
dot :: proc "contextless" (r: ^Rc, argv: ^Word) {
	bflag, iflag, qflag := false, false, false
	a := argv.next
	for ; a != nil && a.len != 0 && text(a)[0] == '-'; a = a.next {
		if text(a) == "--" {
			a = a.next
			break
		}
		for c in transmute([]u8)text(a)[1:] {
			switch c {
			case 'b':
				bflag = true
			case 'i':
				iflag = true
			case 'q':
				qflag = true
			case:
				fail(r, "", "Usage: . [-biq] file [arg ...]")
				return
			}
		}
	}
	if a == nil {
		fail(r, "", "Usage: . [-biq] file [arg ...]")
		return
	}
	name := text(a)
	rd: ^Reader
	if name == "#d/0" {
		rd = reader_new(r, name)
		if rd != nil {
			rd.tty = true
		}
	} else { // through $path, as rc's searchpath, unless it starts / ./ or ../
		dirs := here_name(name) ? nil : get_var(r, "path")
		as_is: Word // "": the name as written
		if dirs == nil {
			dirs = &as_is
		}
		buf := heap_alloc(r, DOT_MAX)
		for d := dirs; buf != nil && d != nil && rd == nil; d = d.next {
			path_buf: [512]u8
			path := path_join(path_buf[:], d == &as_is ? "" : text(d), name) or_continue
			got, ok := 0, false
			if r.host.read_file != nil {
				got, ok = r.host.read_file(r.host.ctx, path, ([^]u8)(buf)[:DOT_MAX])
			}
			if !ok {
				continue
			}
			rd = reader_new(r, path)
			if rd != nil {
				rd.buf = ([^]u8)(buf)[:DOT_MAX]
				rd.len = min(got, DOT_MAX)
				buf = nil
			}
		}
		heap_free(r, buf)
		if rd == nil {
			if !qflag { // rc's Xerror3: . can't open: file: why, why its status
				msg: [dynamic; ERR_MAX]u8
				append(&msg, ". can't open: ", name)
				fail(r, "file does not exist", string(msg[:]), "file does not exist")
			}
			return
		}
	}
	if rd == nil {
		fail(r, "", "out of memory")
		return
	}
	rd.interactive = iflag
	rd.whole = bflag && !iflag
	rd.quiet = qflag
	star := new_local(r, "*", copy_words(r, a.next))
	zero := new_local(r, "0", new_word(r, name))
	if star != nil && zero != nil {
		zero.next = star
	}
	_ = push_reader(r, rd, zero != nil ? zero : star)
}

// eval cmd ...: the words, joined by spaces, run as a command line (rc's execeval).
@(private = "file")
eval :: proc "contextless" (r: ^Rc, argv: ^Word) {
	if argv.next == nil {
		fail(r, "", "Usage: eval cmd ...")
		return
	}
	total := 1
	for w := argv.next; w != nil; w = w.next {
		total += w.len + 1
	}
	p := heap_alloc(r, total)
	if p == nil {
		return
	}
	buf := ([^]u8)(p)[:total]
	at := 0
	for w := argv.next; w != nil; w = w.next {
		at += copy(buf[at:], text(w))
		buf[at] = w.next != nil ? ' ' : '\n'
		at += 1
	}
	line: u32
	src := string(r.src[:])
	if len(r.frames) > 0 {
		f := &r.frames[len(r.frames) - 1]
		if f.pc != 0 && f.pc <= f.code.n {
			line = code_inst(f.code)[f.pc - 1].line
		}
		if f.code.src[0] != 0 {
			src = code_src(f.code)
		}
	}
	// Its name, file:line *eval*, in upstream's 64 bytes, where leaves 8.
	at_buf: [64 - 8]u8
	name: [dynamic; 63]u8
	append(&name, place(at_buf[:], src, line), " *eval*")
	rd := reader_new(r, string(name[:]))
	if rd == nil {
		heap_free(r, p)
		return
	}
	rd.buf = buf
	rd.len = at
	_ = push_reader(r, rd, nil)
}

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
	if r.flag['x'] { // -x: each command, as rc's (before its redirections)
		errwords(r, argv)
		errout(r, "\n")
	}
	forced := text(argv) == "builtin" // builtin cmd: no function, as rc's
	if forced {
		if argc == 1 {
			free_words(r, argv)
			fail(r, "", "builtin: empty argument list")
			return
		}
		b := argv
		argv = argv.next
		argc -= 1
		b.next = nil
		free_words(r, b)
	}
	if argc == 1 && text(argv) == "exec" {
		free_words(r, argv)
		fail(r, "", "exec: empty argument list")
		return
	}
	v := forced ? nil : gvar_find(r, text(argv), false)
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
	switch text(argv) {
	case ".":
		dot(r, argv)
		return
	case "eval":
		eval(r, argv)
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
	src := string(r.src[:])
	if len(r.frames) > 0 {
		f := &r.frames[len(r.frames) - 1]
		if f.pc != 0 && f.pc <= f.code.n {
			line = code_inst(f.code)[f.pc - 1].line
		}
		if f.code.src[0] != 0 {
			src = code_src(f.code)
		}
	}
	buf: [96]u8
	set_error(r, place(buf[:], src, line), ": ", a)
	if b != "" {
		if len(r.err) + 3 < ERR_MAX + 1 {
			append(&r.err, ':', ' ')
		}
		add_error(r, b)
	}
	set_status(r, c_name(status != "" ? status : "error"))
	r.failed = true
	r.failset = true
	errout(r, string(r.err[:]))
	errout(r, "\n")
}

// A here document's text with $name, $n and $$ replaced, as rc's psubst: a
// list's words joined by spaces, and a ^ right after a name dropped. It takes
// body, and gives one word.
@(private = "file")
hsubst :: proc "contextless" (r: ^Rc, body: ^Word) -> ^Word {
	s := text(body)
	size := len(s) + 64
	n := 0
	out := ([^]u8)(heap_alloc(r, size))
	for i := 0; out != nil && i < len(s); {
		add := s[i:][:1]
		vals: ^Word
		if s[i] != '$' {
			i += 1
		} else if i + 1 < len(s) && s[i + 1] == '$' {
			add = "$"
			i += 2
		} else {
			i += 1
			s0 := i
			for i < len(s) && name_char(s[i]) {
				i += 1
			}
			if nm := new_word(r, s[s0:i]); nm != nil {
				if nm.len != 0 {
					vals, _, _ = value(r, nm, "")
				}
				free_words(r, nm)
			}
			if i < len(s) && s[i] == '^' {
				i += 1
			}
			add = ""
		}
		need := len(add)
		for w := vals; w != nil; w = w.next {
			need += w.len + 1
		}
		if n + need + 1 > size {
			more_size := (n + need + 1) * 2
			more := ([^]u8)(heap_alloc(r, more_size))
			if more != nil {
				copy(more[:more_size], out[:n])
			}
			heap_free(r, out)
			out, size = more, more_size
			if out == nil {
				break
			}
		}
		n += copy(out[n:size], add)
		for w := vals; w != nil; w = w.next {
			n += copy(out[n:size], text(w))
			if w.next != nil {
				out[n] = ' '
				n += 1
			}
		}
		free_words(r, vals)
	}
	free_words(r, body)
	w := out != nil ? new_word(r, string(out[:n])) : nil
	heap_free(r, out)
	return w
}

// Back to the nearest interactive reader above base, as rc's
// while(!runq->iflag) Xreturn(): false if there is none.
@(private = "file")
unwind :: proc "contextless" (r: ^Rc, base: u32) -> bool {
	i := u32(len(r.frames))
	for i > base && !(r.frames[i - 1].rd != nil && r.frames[i - 1].rd.interactive) {
		i -= 1
	}
	if i == base {
		return false
	}
	for u32(len(r.frames)) > i {
		pop_frame(r)
	}
	rf := &r.frames[i - 1]
	for u32(len(r.stack)) > rf.sp {
		free_words(r, pop_list(r))
	}
	for u32(len(r.captures)) > rf.ncaptures {
		heap_free(r, raw_data(r.captures[len(r.captures) - 1].buf))
		resize(&r.captures, len(r.captures) - 1)
	}
	pop_redirs(r, int(rf.redirs))
	return true
}

// The notes waiting, each to its function, as rc's dotrap: with none, an
// interrupt or quit goes back to the interactive reader (or exits, if none),
// and anything else exits.
@(private = "file")
dotrap :: proc "contextless" (r: ^Rc, base: u32) {
	for &waiting, sig in r.trap {
		if intrinsics.volatile_load(&r.ntrap) == 0 {
			break
		}
		for intrinsics.volatile_load(&waiting) != 0 {
			intrinsics.volatile_store(&waiting, intrinsics.volatile_load(&waiting) - 1)
			intrinsics.volatile_store(&r.ntrap, intrinsics.volatile_load(&r.ntrap) - 1)
			if v := gvar_find(r, SIG_NAMES[sig], false); v != nil && v.fn != nil {
				star := new_local(r, "*", copy_words(r, get_var(r, "*")))
				_ = push_frame(r, v.fn, v.fn_pc, star)
			} else if sig == .Int || sig == .Quit {
				if !unwind(r, base) {
					r.exiting = true
				}
			} else {
				r.exiting = true
			}
		}
	}
}

// The instructions' names, as rc's -r prints them.
@(private = "file")
OP_NAMES := [Op]string {
	.Mark      = "Xmark",
	.Word      = "Xword",
	.Dol       = "Xdol",
	.Count     = "Xcount",
	.Join      = "Xjoin",
	.Sub       = "Xsub",
	.Conc      = "Xconc",
	.Simple    = "Xsimple",
	.Stage     = "Xstage",
	.Pipeline  = "Xpipe",
	.Assign    = "Xassign",
	.Local     = "Xlocal",
	.Unlocal   = "Xunlocal",
	.If        = "Xif",
	.If_Not    = "Xifnot",
	.Was_True  = "Xwastrue",
	.True      = "Xtrue",
	.False     = "Xfalse",
	.Jump      = "Xjump",
	.Bang      = "Xbang",
	.For       = "Xfor",
	.Popm      = "Xpopm",
	.Fn        = "Xfn",
	.Delfn     = "Xdelfn",
	.Return    = "Xreturn",
	.Qw        = "Xqw",
	.Settrue   = "Xsettrue",
	.Match     = "Xmatch",
	.Case      = "Xcase",
	.Backq     = "Xbackq",
	.Backq_End = "Xbackqend",
	.Redir     = "Xredir",
	.Dup       = "Xdup",
	.Popredir  = "Xpopredir",
	.Rdcmds    = "Xrdcmds",
	.Eflag     = "Xeflag",
}

// Runs code from the frame on top until the frames it started with have all
// returned, or an error or exit stops it; an error inside an interactive
// reader goes back to it.
@(private)
execute :: proc "contextless" (r: ^Rc, base: u32) {
	steps: u64
	for {
		if r.failed && !r.exiting { // as rc's Xerror: back to the nearest interactive reader, if one
			if !unwind(r, base) {
				break
			}
			r.failed = false
			r.failset = false
		}
		if intrinsics.volatile_load(&r.ntrap) != 0 && !r.exiting {
			dotrap(r, base)
		}
		if u32(len(r.frames)) <= base || r.failed || r.exiting {
			break
		}
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
		if r.flag['r'] { // -r: each instruction as it runs, as rc's pfnc
			buf: [96]u8
			errout(r, place(buf[:], code_src(f.code), ins.line))
			errout(r, ": ")
			errout(r, OP_NAMES[ins.op])
			errout(r, "\n")
		}
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
				heap_free(r, v.fnsrc)
				v.fnsrc = nil
				if ins.b != 0 {
					t := c_name(string(code_strings(f.code)[ins.b - 1:]))
					v.fnsrc = (^u8)(heap_alloc(r, len(t) + 1))
					if v.fnsrc != nil {
						copy(payload(v.fnsrc), t)
					}
				}
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
					heap_free(r, v.fnsrc)
					v.fnsrc = nil
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
			if Redir_Kind(ins.f1) == .Here { // a here document: its text, substituted unless its tag was quoted
				body := pop_list(r)
				if body != nil && ins.b == 0 {
					body = hsubst(r, body)
				}
				if body == nil || len(r.redirs) == REDIRS {
					free_words(r, body)
					fail(r, "", "<< nested too deeply")
					break
				}
				append(&r.redirs, Redir{fd = ins.f0, to = Fd_Here{text(body)}, path = body})
				break
			}
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
		case .Rdcmds:
			rdcmds(r, f)
		case .Eflag:
			if !true_status(r) {
				r.exiting = true // -e, as rc's Xeflag: exit with the status
			}
		}
	}
}
