// 9front's pcmd: a function's text rebuilt from its tree (upstream's M6
// step 6d7c).
//
// whatis prints a function, and a child is given it, as 9front's rc rebuilds
// it (pcmd.c) from the tree its parser made (decided upstream 2026-10-06): a
// simple command's redirections lifted out to wrap it, the first outermost
// (simplemung), and each construct's spacing as pcmd's; checked against a
// 9front rc's own output (tests/host/rc). A sequence breaks where the source
// had a newline, else with "; ", as 9front's line numbers make it.
//
// Without recursion: a stack of what is still to print, pushed in reverse.
package rc

@(private)
Pitem_Kind :: enum u8 {
	Node, // node, at ntab tabs: what it prints, expanded
	Lit, // text, or (word) node's word, as pword prints it
	Nl, // a newline, then ntab tabs
	Words, // a chain of words from node, a space between
	Brace, // { a newline, the list node a tab further in, a newline }
	Simple, // the simple command node, from its redirection n on
}

@(private)
Pitem :: struct {
	what: Pitem_Kind,
	ntab: u16,
	word: bool, // a Lit that is node's word
	made: u8, // a Lit made here, in buf: its length ("[2=1]" and the like)
	node: i32,
	n:    u32, // a Simple's: which redirection
	s:    string, // a Lit's text, unless made
	buf:  [24]u8,
}

@(private)
PITEMS :: 2048 // upstream's stack: a function deeper than this keeps no text

// The pcmd stack, kept in the interpreter (Compiler_Scratch).
@(private)
Pstack :: struct {
	items: [dynamic; PITEMS]Pitem,
	full:  bool,
}

@(private = "file")
Pout :: struct {
	r:      ^Rc,
	buf:    [^]u8, // in the heap
	len:    int,
	cap:    int,
	failed: bool,
}

// Adds s to the text, grown in the heap as upstream's (256 bytes first, then
// twice as much, and s's length more each time), so the heap runs out where
// upstream's does.
@(private = "file")
pput :: proc "contextless" (o: ^Pout, s: string) {
	if o.failed || len(s) == 0 {
		return
	}
	if o.len + len(s) + 1 > o.cap {
		more_cap := (o.cap != 0 ? o.cap * 2 : 256) + len(s)
		more := ([^]u8)(heap_alloc(o.r, more_cap))
		if more == nil {
			o.failed = true
			return
		}
		if o.len != 0 {
			copy(more[:o.len], o.buf[:o.len])
		}
		heap_free(o.r, o.buf)
		o.buf, o.cap = more, more_cap
	}
	copy(o.buf[o.len:][:len(s)], s)
	o.len += len(s)
	o.buf[o.len] = 0
}

@(private = "file")
ppush :: proc "contextless" (st: ^Pstack, what: Pitem_Kind, ntab: u16, node: i32) -> ^Pitem {
	if len(st.items) == PITEMS {
		st.full = true
		return nil
	}
	_ = append(&st.items, Pitem{what = what, ntab = ntab, node = node})
	return &st.items[len(st.items) - 1]
}

@(private = "file")
plit :: proc "contextless" (st: ^Pstack, s: string) {
	if it := ppush(st, .Lit, 0, NONE); it != nil {
		it.s = s
	}
}

// A literal made of prefix and an fd in brackets if it is not dflt, as
// pcmd's "[%d]"; or with other, "[a=b]" (other CLOSE_FD: "[a=]"). Digits as
// upstream's: two at most, the other's last.
@(private = "file")
pfd :: proc "contextless" (st: ^Pstack, prefix: string, fd: u32, dflt: u32, other: i32) {
	it := ppush(st, .Lit, 0, NONE)
	if it == nil {
		return
	}
	n := copy(it.buf[:], prefix)
	if fd != dflt || other >= 0 {
		it.buf[n] = '['
		n += 1
		if fd >= 10 {
			it.buf[n] = u8('0' + fd / 10)
			n += 1
		}
		it.buf[n] = u8('0' + fd % 10)
		n += 1
		if other >= 0 {
			it.buf[n] = '='
			n += 1
			if other != CLOSE_FD {
				it.buf[n] = u8('0' + other % 10)
				n += 1
			}
		}
		it.buf[n] = ']'
		n += 1
	}
	it.made = u8(n)
}

// A redirection's text before what it wraps: " >f", " <[3]f", ">[2=1]".
@(private = "file")
predir :: proc "contextless" (st: ^Pstack, rd: ^Node) {
	OPS := [Redir_Kind]string {
		.Read   = " <",
		.Write  = " >",
		.Append = " >>",
		.Rdwr   = " <>",
		.Here   = " <<",
	}
	if rd.kind == .Dup {
		pfd(st, ">", u32(rd.fd0), 99, i32(rd.fd1))
		return
	}
	dflt: u32 = rd.rkind == .Write || rd.rkind == .Append ? 1 : 0
	_ = ppush(st, .Node, 0, rd.a) // the file (pushed first: it prints after)
	pfd(st, OPS[rd.rkind], u32(rd.fd0), dflt, -1)
}

// Pushes what item it's node prints, at its tabs, in reverse.
@(private = "file")
pexpand :: proc "contextless" (c: ^Compiler, st: ^Pstack, it: ^Pitem) {
	t := &c.nodes[it.node]
	tab := it.ntab
	node :: proc "contextless" (st: ^Pstack, tab: u16, x: i32) {
		_ = ppush(st, .Node, tab, x)
	}
	switch t.kind {
	case .Word:
		if w := ppush(st, .Lit, 0, it.node); w != nil {
			w.word = true // printed by pword
		}
	case .Dol:
		node(st, tab, t.a)
		plit(st, "$")
	case .Count:
		node(st, tab, t.a)
		plit(st, "$#")
	case .Join:
		node(st, tab, t.a)
		plit(st, "$\"")
	case .Sub:
		plit(st, ")")
		_ = ppush(st, .Words, tab, t.b)
		plit(st, "(")
		node(st, tab, t.a)
		plit(st, "$")
	case .Conc:
		node(st, tab, t.b)
		plit(st, "^")
		node(st, tab, t.a)
	case .Backq:
		_ = ppush(st, .Brace, tab, t.a)
		if t.b != NONE {
			node(st, tab, t.b)
		}
		plit(st, "`")
	case .Paren:
		plit(st, ")")
		_ = ppush(st, .Words, tab, t.a)
		plit(st, "(")
	case .Pipefd:
		_ = ppush(st, .Brace, tab, t.a)
		plit(st, t.rkind == .Read ? " <" : " >")
	case .Simple:
		_ = ppush(st, .Simple, tab, it.node)
	case .Seq:
		node(st, tab, t.b)
		// A newline between the two in the source: the gap from the first's
		// end to the second's start.
		nl := false
		if t.a >= 0 && t.b >= 0 && c.nodes[t.a].to != 0 && c.nodes[t.b].from != 0 {
			for q := c.nodes[t.a].to; q < c.nodes[t.b].from - 1 && q < len(c.text) && !nl; q += 1 {
				nl = c.text[q] == '\n'
			}
		}
		if nl {
			_ = ppush(st, .Nl, tab, NONE)
		} else if t.a >= 0 && t.b >= 0 {
			plit(st, "; ")
		}
		node(st, tab, t.a)
	case .Async:
		plit(st, "&")
		node(st, tab, t.a)
	case .And:
		node(st, tab, t.b)
		plit(st, " && ")
		node(st, tab, t.a)
	case .Or:
		node(st, tab, t.b)
		plit(st, " || ")
		node(st, tab, t.a)
	case .Pipe: // pcmd's fields are the other way round: [right=left]
		node(st, tab, t.b)
		if t.fd1 != 0 {
			pfd(st, "|", u32(t.fd1), 99, i32(t.fd0))
		} else {
			pfd(st, "|", u32(t.fd0), 1, -1)
		}
		node(st, tab, t.a)
	case .Bang:
		node(st, tab, t.b)
		plit(st, "! ")
	case .Subshell:
		node(st, tab, t.b)
		plit(st, "@ ")
	case .Brace:
		_ = ppush(st, .Brace, tab, t.a)
	case .If:
		node(st, tab, t.b)
		plit(st, ")")
		node(st, tab, t.a)
		plit(st, "if(")
	case .If_Not:
		node(st, tab, t.b)
		plit(st, "if not ")
	case .While:
		node(st, tab, t.b)
		plit(st, ")")
		node(st, tab, t.a)
		plit(st, "while (")
	case .For:
		node(st, tab, t.c)
		plit(st, ")")
		if t.b == NONE {
			plit(st, " in ()")
		}
		if t.b >= 0 {
			_ = ppush(st, .Words, tab, t.b)
			plit(st, " in ")
		}
		node(st, tab, t.a)
		plit(st, "for(")
	case .Switch:
		_ = ppush(st, .Brace, tab, t.b)
		plit(st, " ")
		node(st, tab, t.a)
		plit(st, "switch ")
	case .Twiddle:
		_ = ppush(st, .Words, tab, t.b)
		plit(st, " ")
		node(st, tab, t.a)
		plit(st, "~ ")
	case .Fn:
		if t.b != NONE {
			_ = ppush(st, .Brace, tab, t.b)
		}
		plit(st, " ")
		_ = ppush(st, .Words, tab, t.a)
		plit(st, "fn ")
	case .Assign:
		if t.c != NONE {
			node(st, tab, t.c)
			plit(st, " ")
		}
		node(st, tab, t.b)
		plit(st, "=")
		node(st, tab, t.a)
	case .Redir, .Dup: // a prefix's or an epilog's: what it wraps after
		if t.kind == .Redir && t.rkind == .Here {
			break // a here document's: not in a function's text
		}
		if t.b != NONE {
			node(st, tab, t.b)
		}
		if t.kind == .Redir && t.b != NONE {
			plit(st, " ")
		}
		predir(st, t)
	}
}

// A simple command: its redirection it.n on wrapping the rest (the first
// outermost, as simplemung lifts them), then its words.
@(private = "file")
psimple :: proc "contextless" (c: ^Compiler, st: ^Pstack, it: ^Pitem) {
	t := &c.nodes[it.node]
	rd := t.b
	for k := u32(0); rd >= 0 && k < it.n; k += 1 {
		rd = c.nodes[rd].next
	}
	if rd < 0 {
		_ = ppush(st, .Words, it.ntab, t.a)
		return
	}
	if rest := ppush(st, .Simple, it.ntab, it.node); rest != nil {
		rest.n = it.n + 1
	}
	if c.nodes[rd].kind == .Redir {
		plit(st, " ")
	}
	predir(st, &c.nodes[rd])
}

// A word as pcmd prints one: a quoted one quoted, '' for each ', else as it
// is, its glob marks dropped.
@(private = "file")
pword :: proc "contextless" (o: ^Pout, w: ^Node) {
	if w.quoted {
		pput(o, "'")
	}
	for i in 0 ..< len(w.s) {
		if !w.quoted && w.s[i] == GLOB {
			continue
		}
		pput(o, w.s[i:][:1])
		if w.quoted && w.s[i] == '\'' {
			pput(o, "'")
		}
	}
	if w.quoted {
		pput(o, "'")
	}
}

// list as a function's body is printed, "{", a tab in, "}", in the heap (the
// caller frees it): ok is false if it does not fit.
@(private = "file")
pcmd :: proc "contextless" (c: ^Compiler, list: i32) -> (text: [^]u8, n: int, ok: bool) {
	st := &c.r.compiler.pstack
	clear(&st.items)
	st.full = false
	o := Pout {
		r = c.r,
	}
	_ = ppush(st, .Brace, 0, list)
	for len(st.items) > 0 && !st.full && !o.failed {
		it := st.items[len(st.items) - 1]
		resize(&st.items, len(st.items) - 1)
		switch it.what {
		case .Lit:
			switch {
			case it.word:
				pword(&o, &c.nodes[it.node])
			case it.made != 0:
				pput(&o, string(it.buf[:it.made]))
			case:
				pput(&o, it.s)
			}
		case .Nl:
			pput(&o, "\n")
			for _ in 0 ..< it.ntab {
				pput(&o, "\t")
			}
		case .Brace:
			plit(st, "}")
			_ = ppush(st, .Nl, it.ntab, NONE)
			if it.node >= 0 {
				_ = ppush(st, .Node, it.ntab + 1, it.node)
			}
			_ = ppush(st, .Nl, it.ntab + 1, NONE)
			plit(st, "{")
		case .Words: // a chain, a space between
			ws: [dynamic; 256]i32
			for w := it.node; w >= 0 && len(ws) < cap(ws); w = c.nodes[w].next {
				_ = append(&ws, w)
			}
			for k := len(ws) - 1; k >= 0; k -= 1 {
				_ = ppush(st, .Node, it.ntab, ws[k])
				if k != 0 {
					plit(st, " ")
				}
			}
		case .Simple:
			psimple(c, st, &it)
		case .Node:
			if it.node >= 0 {
				pexpand(c, st, &it)
			}
		}
	}
	if st.full || o.failed {
		heap_free(c.r, o.buf)
		return nil, 0, false
	}
	return o.buf, o.len, true
}

// A function's body as 9front's pcmd rebuilds it, into the strings: its
// place there, plus 1; 0 if it does not fit (whatis then prints {}).
@(private)
fn_text :: proc "contextless" (c: ^Compiler, body: i32) -> (src: u32) {
	text, n, ok := pcmd(c, body)
	if ok && len(c.str) - c.nstr >= n + 1 {
		copy(c.str[c.nstr:][:n], text[:n])
		c.str[c.nstr + n] = 0
		src = u32(c.nstr) + 1
		c.nstr += n + 1
	}
	heap_free(c.r, text)
	return
}
