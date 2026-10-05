package guide

import "vx:utf"

// Rendering for a terminal (upstream 12 §6.1): the page refilled to a width,
// NAME made from the header and SOURCE from src=, indented as Plan 9's.

Out :: struct {
	write: proc "contextless" (ctx: rawptr, s: string),
	ctx:   rawptr,
	width: u32, // 0: 80
}

// Why a page was refused, and the line it refers to (0 when none does).
Error :: struct {
	msg:  string,
	line: int,
}

@(private="file")
INDENT :: 5
@(private="file")
SUB :: 3
@(private="file")
HANG :: 10
@(private="file")
MAXCOLS :: 16
@(private="file")
WORD_MAX :: 256 // a word is written once it holds this much, at a rune's start

@(private="file")
Fill :: struct {
	out:   ^Out,
	width: u32,
	lead:  u32, // where a new line's first word starts
	col:   u32,
	bol:   bool, // nothing written on this line since its start (or its marker)
	word:  [WORD_MAX + 4]u8,
	nword: int,
	wcols: u32,
	error: string, // why a span was refused, once one is
}

// Columns: runes, each one wide.
@(private="file")
cols :: proc "contextless" (s: string) -> u32 {
	c: u32
	for i in 0 ..< len(s) {
		c += u32(s[i] & 0xc0 != 0x80)
	}
	return c
}

@(private="file")
put :: proc "contextless" (f: ^Fill, s: string) {
	if len(s) > 0 {
		f.out.write(f.out.ctx, s)
	}
	f.col += cols(s)
}

@(private="file")
spaces :: proc "contextless" (f: ^Fill, n: u32) {
	SP := "                "
	n := n
	for ; n > 16; n -= 16 {
		put(f, SP)
	}
	put(f, SP[:n])
}

@(private="file")
newline :: proc "contextless" (f: ^Fill) {
	f.out.write(f.out.ctx, "\n")
	f.col, f.bol = 0, true
}

@(private="file")
flush :: proc "contextless" (f: ^Fill) {
	if f.nword == 0 {
		return
	}
	if !f.bol && f.col + 1 + f.wcols > f.width {
		newline(f)
	}
	if f.bol && f.col < f.lead {
		spaces(f, f.lead - f.col)
	}
	if !f.bol {
		put(f, " ")
	}
	put(f, string(f.word[:f.nword]))
	f.bol, f.nword, f.wcols = false, 0, 0
}

// Bytes added to the word being built; a word too long to hold is written as it stands.
@(private="file")
add :: proc "contextless" (f: ^Fill, s: string) {
	for i in 0 ..< len(s) {
		starts := s[i] & 0xc0 != 0x80
		if f.nword >= WORD_MAX && starts {
			flush(f)
		}
		if f.nword == len(f.word) {
			continue // a malformed rune's tail (pages are checked UTF-8)
		}
		f.word[f.nword] = s[i]
		f.nword += 1
		f.wcols += u32(starts)
	}
}

// Text with its whitespace runs as single spaces, each a place to break.
@(private="file")
words :: proc "contextless" (f: ^Fill, s: string, join_first: bool) {
	join_first := join_first
	for i := 0; i < len(s); {
		if is_space(s[i]) {
			for i < len(s) && is_space(s[i]) {
				i += 1
			}
			if i < len(s) {
				flush(f)
			}
			continue
		}
		if !join_first {
			flush(f)
		}
		join_first = true
		j := i
		for j < len(s) && !is_space(s[j]) {
			j += 1
		}
		add(f, s[i:j])
		i = j
	}
}

// A block's inline text, filled. False, with f.error, on a bad span.
@(private="file")
text :: proc "contextless" (f: ^Fill, s: string) -> bool {
	it := Inline{s = s}
	for {
		sp, more := span_next(&it)
		if !more {
			f.error = it.error
			return it.error == ""
		}
		#partial switch sp.kind {
		case .Space:
			flush(f)
		case .Literal: // one unbreakable word, its whitespace runs single spaces
			for i in 0 ..< len(sp.text) {
				run := is_space(sp.text[i])
				if run && i > 0 && is_space(sp.text[i - 1]) {
					continue
				}
				add(f, run ? " " : sp.text[i:i + 1])
			}
		case .Link:
			words(f, sp.label, true)
			// A label of its own (not the target standing for one) is followed by the target.
			if raw_data(sp.label) != raw_data(sp.target) {
				flush(f)
				add(f, "(")
				add(f, sp.target)
				add(f, ")")
			}
		case: // text, a parameter, a reference: as written
			add(f, sp.text)
		}
	}
}

@(private="file")
para :: proc "contextless" (f: ^Fill, lead: u32, s: string) -> bool {
	f.lead = lead
	ok := text(f, s)
	flush(f)
	if f.col != 0 {
		newline(f)
	}
	return ok
}

// A table cell rendered on one line, into a buffer it is cut to.
@(private="file")
Cell_Buf :: struct {
	bytes: [512]u8,
	n:     int,
	cut:   bool, // something did not fit
}

@(private="file")
cell_write :: proc "contextless" (ctx: rawptr, s: string) {
	b := (^Cell_Buf)(ctx)
	k := min(len(s), len(b.bytes) - b.n)
	copy(b.bytes[b.n:], s[:k])
	b.n += k
	b.cut = b.cut || k < len(s)
}

// A cell, rendered into b, and its width; a bad span's reason goes to f.
// A cell cut at the buffer's end ends on a whole rune. (Upstream's means to
// and does not: it asks vx_utf_cut for the text's own length, which never
// cuts, so a cell of more than 512 bytes can end inside a rune and the page
// render as invalid UTF-8; docs/UPSTREAM-FINDINGS.md.)
@(private="file")
cell :: proc "contextless" (f: ^Fill, c: string, b: ^Cell_Buf) -> (width: u32, ok: bool) {
	b.n, b.cut = 0, false
	o := Out{write = cell_write, ctx = b}
	cf := Fill{out = &o, width = max(u32), bol = true}
	ok = text(&cf, c)
	flush(&cf)
	f.error = cf.error
	if b.cut {
		// Back over the last rune's continuation bytes to its start; drop it if it is short.
		start := b.n
		for start > 0 && b.n - start < utf.UTF_MAX && b.bytes[start - 1] & 0xc0 == 0x80 {
			start -= 1
		}
		if start > 0 && !utf.full_rune(string(b.bytes[start - 1:b.n])) {
			b.n = start - 1
		}
	}
	return cols(string(b.bytes[:b.n])), ok
}

// The widths of a run of rows from g on (the block just read, b, its first).
@(private="file")
widths :: proc "contextless" (f: ^Fill, g: ^Guide, b: Block, w: ^[MAXCOLS]u32) -> bool {
	look := g^ // a copy to read ahead with
	r := b
	buf: Cell_Buf
	w^ = {}
	line := r.line
	for {
		row := r.text
		for k := 0; k < MAXCOLS; k += 1 {
			c := cell_next(&row) or_break
			n := cell(f, c, &buf) or_return
			w[k] = max(w[k], n)
		}
		more: bool
		r, more = next(&look)
		if !more || r.kind != .Row || r.line != line + 1 {
			return true
		}
		line = r.line
	}
}

@(private="file")
row_out :: proc "contextless" (f: ^Fill, row: string, w: ^[MAXCOLS]u32) -> bool {
	row := row
	buf: Cell_Buf
	spaces(f, INDENT)
	pad: u32
	for k := 0;; k += 1 {
		c := cell_next(&row) or_break
		n := cell(f, c, &buf) or_return
		if k > 0 {
			spaces(f, pad + 2)
		}
		put(f, string(buf.bytes[:buf.n]))
		pad = k < MAXCOLS && w[k] > n ? w[k] - n : 0
	}
	newline(f)
	return true
}

// A heading's words at lead, capitals as written (or, from a node's title, made so).
@(private="file")
heading :: proc "contextless" (f: ^Fill, lead: u32, s: string, upper: bool) -> bool {
	if !upper {
		return para(f, lead, s)
	}
	buf: [256]u8
	n := utf.cut(s, min(len(s), len(buf)))
	for i in 0 ..< n {
		buf[i] = to_upper(s[i])
	}
	f.lead = lead
	words(f, string(buf[:n]), false)
	flush(f)
	newline(f)
	return true
}

@(private="file")
title :: proc "contextless" (f: ^Fill, h: ^Header) {
	t: [96]u8
	n := 0
	for i := 0; i < len(h.page) && n + 4 < len(t); i += 1 {
		t[n] = to_upper(h.page[i])
		n += 1
	}
	t[n], t[n + 1], t[n + 2] = '(', u8('0' + h.sect), ')'
	n += 3
	put(f, string(t[:n]))
	if 2 * u32(n) + 1 <= f.width {
		spaces(f, f.width - 2 * u32(n))
		put(f, string(t[:n]))
	}
	newline(f)
}

@(private="file")
name :: proc "contextless" (f: ^Fill, h: ^Header) {
	f.lead = INDENT
	list := h.names
	first := true
	for item in item_next(&list) {
		if !first {
			add(f, ",")
		}
		flush(f)
		add(f, item)
		first = false
	}
	flush(f)
	add(f, "—")
	words(f, h.summary, false)
	flush(f)
	newline(f)
}

@(private="file")
source :: proc "contextless" (f: ^Fill, h: ^Header) {
	put(f, "SOURCE")
	newline(f)
	list := h.src
	for item in item_next(&list) {
		spaces(f, INDENT)
		put(f, item)
		newline(f)
	}
}

@(private="file")
fence_out :: proc "contextless" (f: ^Fill, s: string) {
	for i := 0; i < len(s); {
		j := i
		for j < len(s) && s[j] != '\n' {
			j += 1
		}
		if j > i {
			spaces(f, INDENT)
			put(f, s[i:j])
		}
		newline(f)
		i = j + 1
	}
}

@(private="file")
def :: proc "contextless" (f: ^Fill, b: ^Block) -> bool {
	f.lead = INDENT
	text(f, b.text) or_return
	flush(f)
	if len(b.body) == 0 {
		newline(f)
		return true
	}
	if f.col + 2 <= HANG { // a short term: its description on the same line, two spaces on
		spaces(f, HANG - f.col)
		f.bol = true
	} else {
		newline(f)
	}
	return para(f, HANG, b.body)
}

// What Plan 9's order puts after SOURCE.
@(private="file")
is_late :: proc "contextless" (heading: string) -> bool {
	return heading == "SEE ALSO" || heading == "DIAGNOSTICS" || heading == "BUGS"
}

@(private="file")
block_out :: proc "contextless" (f: ^Fill, g: ^Guide, b: ^Block, w: ^[MAXCOLS]u32, row_line: ^int) -> bool {
	switch b.kind {
	case .Node:
		return heading(f, 0, len(b.title) > 0 ? b.title : b.node, true)
	case .Heading:
		return heading(f, 0, b.text, false)
	case .Subheading:
		return heading(f, SUB, b.text, false)
	case .Para:
		return para(f, INDENT, b.text)
	case .Item:
		spaces(f, INDENT)
		put(f, "- ")
		f.bol = true
		return para(f, INDENT + 2, b.text)
	case .Def:
		return def(f, b)
	case .Row:
		if row_line^ + 1 != b.line {
			widths(f, g, b^, w) or_return
		}
		row_line^ = b.line
		return row_out(f, b.text, w)
	case .Fence:
		fence_out(f, b.text)
	case .None:
	}
	return true
}

// Writes the whole page to out, or (node not "") that node alone. On an
// error, what was written before it stands.
@(require_results)
render :: proc "contextless" (page: string, out: ^Out, node := "") -> (err: Error, ok: bool) {
	g: Guide
	if !open(&g, page) {
		return {g.error, g.error_line}, false
	}
	f := Fill{out = out, width = out.width != 0 ? out.width : 80, bol = true}
	on := node == ""
	in_source := on && len(g.h.src) > 0 // SOURCE is still to come
	found := false
	if on {
		title(&f, &g.h)
		newline(&f)
		put(&f, "NAME")
		newline(&f)
		name(&f, &g.h)
	}
	prev := Kind.Heading // .None: the start of a node asked for, which needs no gap
	row_line := 0
	w: [MAXCOLS]u32
	for {
		b, more := next(&g)
		if !more {
			if g.error != "" {
				return {g.error, g.error_line}, false
			}
			break
		}
		if b.kind == .Node && node != "" {
			if on {
				break // the next node: the one asked for has ended
			}
			on = b.node == node
			found = on
			prev = .None
		}
		if !on {
			continue
		}
		if b.kind == .Heading && in_source && is_late(b.text) {
			newline(&f)
			source(&f, &g.h)
			in_source = false
		}
		is_heading := b.kind == .Node || b.kind == .Heading || b.kind == .Subheading
		joined := (prev == .Heading || prev == .Subheading || prev == .Node) && !is_heading
		joined = joined || (b.kind == .Item && prev == .Item) || (b.kind == .Row && row_line + 1 == b.line)
		if !joined && prev != .None {
			newline(&f)
		}
		if !block_out(&f, &g, &b, &w, &row_line) {
			return {f.error, b.line}, false
		}
		if b.kind != .Row {
			row_line = 0
		}
		prev = b.kind
	}
	if node != "" && !found {
		return {"no such node", 0}, false
	}
	if in_source {
		newline(&f)
		source(&f, &g.h)
	}
	return {}, true
}
