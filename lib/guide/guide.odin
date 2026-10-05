// vx:guide, the manual's format (upstream docs/12-manual.md §4, its
// ADR-0028; guide(6)). The one parser: man, lookman, sig and build all read
// pages through it, and nothing else parses one.
//
// A page is UTF-8: an optional `@guide=1` line, a header of ndb (one record,
// its first tuple page=) ended by the first blank line, then a body whose
// lines are typed by how they begin. open reads the header; next gives the
// body a block at a time; span_next splits a block's text into its inline
// spans; render (render.odin) writes a page for a terminal. Every value
// points into the page or into the Guide, so the page must outlive what they
// return, and a Guide whose header is in use must not be moved (a quoted
// header value is decoded into its scratch). Nothing is allocated, nothing
// recurses, and nothing is kept between calls but in the caller's Guide.
//
// The parser is strict: what it does not know, it refuses with a message and
// a line, and never guesses (12 §4.7).
package guide

import "vx:ndb"
import "vx:str"
import "vx:utf"

Header :: struct {
	page, summary: string,
	names, src, keys: string, // comma-separated lists (item_next)
	lang:  string,
	sect:  int, // 1 to 8
	level: u64, // 0: none given
	host:  bool,
}

MAX_NODES :: 64

Guide :: struct {
	src:        string,
	pos:        int, // the next line's start
	line:       int, // the lines consumed
	h:          Header,
	nodes:      [dynamic; MAX_NODES]string, // the ids seen, to refuse a repeat
	hscratch:   [2048]u8, // decoded header values
	lscratch:   [1024]u8, // the last @ line's
	error:      string, // set when a call fails,
	error_line: int, // with the line it refers to
}

// A block's kind. The numbers are upstream's; None is no block.
Kind :: enum i32 {
	None       = 0,
	Node       = 1, // @node=: node, title, keys
	Heading    = 2, // "# ": text
	Subheading = 3, // "## ": text
	Para       = 4, // text: the paragraph's lines, newlines and all
	Item       = 5, // "- ": text, with its continuation lines
	Def        = 6, // ": ": text is the term, body its description
	Row        = 7, // "|": text is the row after the first |; cells by cell_next
	Fence      = 8, // text is the lines inside, each with its newline; fence its kind ("" for none)
}

Block :: struct {
	kind:              Kind,
	text, body, fence: string,
	node, title, keys: string,
	line:              int, // where it starts, 1-based
}

// --- Characters and lines ---

@(private)
is_alpha :: proc "contextless" (c: u8) -> bool {return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')}
@(private)
is_digit :: proc "contextless" (c: u8) -> bool {return c >= '0' && c <= '9'}
@(private)
is_alnum :: proc "contextless" (c: u8) -> bool {return is_alpha(c) || is_digit(c)}
@(private)
is_space :: proc "contextless" (c: u8) -> bool {return c == ' ' || c == '\t' || c == '\n'}
@(private)
to_upper :: proc "contextless" (c: u8) -> u8 {return c >= 'a' && c <= 'z' ? c - ('a' - 'A') : c}

// A name a reference can carry: a page's or an indexed function's.
@(private="file")
name_start :: proc "contextless" (c: u8) -> bool {return is_alnum(c) || c == '_'}
@(private="file")
name_char :: proc "contextless" (c: u8) -> bool {return is_alnum(c) || c == '_' || c == '.' || c == '+' || c == '-'}

@(private)
is_blank :: proc "contextless" (l: string) -> bool {
	for i in 0 ..< len(l) {
		if l[i] != ' ' && l[i] != '\t' {
			return false
		}
	}
	return true
}

@(private)
trim :: proc "contextless" (s: string) -> string {
	s := s
	for len(s) > 0 && is_space(s[0]) {
		s = s[1:]
	}
	for len(s) > 0 && is_space(s[len(s) - 1]) {
		s = s[:len(s) - 1]
	}
	return s
}

@(private="file")
fail :: proc "contextless" (g: ^Guide, msg: string, line: int) -> bool {
	g.error = msg
	g.error_line = line
	return false
}

// The line at g.pos, without its newline, and where the following one starts.
@(private="file")
line_at :: proc "contextless" (g: ^Guide) -> (l: string, next: int) {
	e := g.pos
	for e < len(g.src) && g.src[e] != '\n' {
		e += 1
	}
	return g.src[g.pos:e], e < len(g.src) ? e + 1 : e
}

@(private="file")
advance :: proc "contextless" (g: ^Guide, next: int) {
	g.pos = next
	g.line += 1
}

// Lowercase letters, digits and the punctuation 12 §4.2 allows: a page's name.
@(private="file")
page_name :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 || !(is_digit(s[0]) || (s[0] >= 'a' && s[0] <= 'z')) {
		return false
	}
	for i in 1 ..< len(s) {
		c := s[i]
		if !(is_digit(c) || (c >= 'a' && c <= 'z') || c == '.' || c == '_' || c == '+' || c == '-') {
			return false
		}
	}
	return true
}

@(private="file")
node_id :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if !(is_digit(s[i]) || (s[i] >= 'a' && s[i] <= 'z') || s[i] == '-') {
			return false
		}
	}
	return true
}

// The next item of a comma-separated list, consumed from list^, trimmed
// (possibly empty); false at the list's end.
item_next :: proc "contextless" (list: ^string) -> (item: string, ok: bool) {
	if len(list^) == 0 {
		return "", false
	}
	i := 0
	for i < len(list^) && list[i] != ',' {
		i += 1
	}
	item = trim(list[:i])
	list^ = list[min(i + 1, len(list^)):]
	return item, true
}

// Each item of a list: a name (or, with path, any text without spaces), never empty.
@(private="file")
list_ok :: proc "contextless" (list: string, path: bool) -> bool {
	list := list
	if len(list) == 0 {
		return false
	}
	for item in item_next(&list) {
		if len(item) == 0 || (!path && !name_start(item[0])) {
			return false
		}
		for i in 0 ..< len(item) {
			if is_space(item[i]) || (!path && !name_char(item[i])) {
				return false
			}
		}
	}
	return true
}

// --- The header ---

@(private="file")
header_tuple :: proc "contextless" (g: ^Guide, t: ndb.Tuple, rec: ^ndb.Record, line: int) -> bool {
	h := &g.h
	if t.key == "host" {
		if !t.flag {
			return fail(g, "host is a flag", line)
		}
		h.host = true
		return true
	}
	if t.flag {
		return fail(g, "a header key with no value", line)
	}
	switch t.key {
	case "page":
		h.page = t.value
	case "sect":
		if len(t.value) != 1 || t.value[0] < '1' || t.value[0] > '8' {
			return fail(g, "sect= is 1 to 8", line)
		}
		h.sect = int(t.value[0] - '0')
	case "summary":
		h.summary = t.value
	case "names":
		h.names = t.value
	case "src":
		h.src = t.value
	case "keys":
		h.keys = t.value
	case "lang":
		if t.value != "c" && t.value != "lua" && t.value != "rc" {
			return fail(g, "lang= is c, lua or rc", line)
		}
		h.lang = t.value
	case "level":
		level, ok := ndb.get_u64(rec, "level")
		if !ok || level == 0 {
			return fail(g, "level= is an ABI level", line)
		}
		h.level = level
	case:
		return fail(g, "a header key guide does not know", line)
	}
	return true
}

// Reads the page's version line and header. False on an error (g.error).
@(require_results)
open :: proc "contextless" (g: ^Guide, page: string) -> bool {
	g^ = {src = page}
	line := 1
	for i in 0 ..< len(page) {
		c := page[i]
		if (c < 0x20 && c != '\n' && c != '\t') || c == 0x7f {
			return fail(g, "a control character", line)
		}
		if c == '\n' {
			line += 1
		}
	}
	if !utf.valid(page) {
		return fail(g, "not UTF-8", 1)
	}
	l, next := line_at(g)
	if str.has_prefix(l, "@guide=") { // 12 §4.7: version 1 is the only one there is
		if l != "@guide=1" {
			return fail(g, "a version of guide this parser does not know", 1)
		}
		advance(g, next)
	}
	start, first := g.pos, g.line + 1
	for g.pos < len(page) {
		l, next = line_at(g)
		if is_blank(l) {
			break
		}
		advance(g, next)
	}
	hdr := page[start:g.pos]
	if g.pos < len(page) {
		advance(g, next) // the blank line ending it
	}
	r := ndb.Reader{src = hdr, scratch = g.hscratch[:]}
	rec: ndb.Record
	res := ndb.next(&r, &rec)
	if res == .Error {
		return fail(g, r.error, first + r.error_line - 1)
	}
	if res == .End || rec.tuples[0].key != "page" {
		return fail(g, "a page starts with a header whose first tuple is page=", first)
	}
	for t in rec.tuples {
		header_tuple(g, t, &rec, first) or_return
	}
	// The header's values are kept; the record is free for the next one.
	if ndb.next(&r, &rec) != .End {
		return fail(g, "the header is one record", first)
	}
	h := &g.h
	if !page_name(h.page) {
		return fail(g, "page= is lower case: [a-z0-9][a-z0-9._+-]*", first)
	}
	if h.sect == 0 || len(h.summary) == 0 {
		return fail(g, "a header needs sect= and summary=", first)
	}
	if len(h.names) == 0 {
		h.names = h.page
	}
	if !list_ok(h.names, false) || (len(h.keys) > 0 && !list_ok(h.keys, false)) || (len(h.src) > 0 && !list_ok(h.src, true)) {
		return fail(g, "a list in the header has an empty or malformed item", first)
	}
	return true
}

// --- The body ---

// Continuation lines (two spaces, not blank) after the current one; the end of the last.
@(private="file")
continued :: proc "contextless" (g: ^Guide) -> int {
	l, n := line_at(g)
	end := g.pos + len(l)
	advance(g, n)
	for g.pos < len(g.src) {
		l, n = line_at(g)
		if !str.has_prefix(l, "  ") || is_blank(l) {
			break
		}
		end = g.pos + len(l)
		advance(g, n)
	}
	return end
}

FENCE_KINDS :: [?]string{"", "usage", "c", "rc", "ndb", "lua", "text"}

@(private="file")
fence :: proc "contextless" (g: ^Guide, b: ^Block, l: string, next: int) -> bool {
	kind := l[3:]
	known := false
	for k in FENCE_KINDS {
		known = known || kind == k
	}
	if !known {
		return fail(g, "a fence kind guide does not know", b.line)
	}
	advance(g, next)
	start := g.pos
	for g.pos < len(g.src) {
		in_line, n := line_at(g)
		if in_line == "```" {
			b.kind, b.fence = .Fence, kind
			b.text = g.src[start:g.pos]
			advance(g, n)
			return true
		}
		advance(g, n)
	}
	return fail(g, "a fence that is never closed", b.line)
}

@(private="file")
directive :: proc "contextless" (g: ^Guide, b: ^Block, l: string, next: int) -> bool {
	r := ndb.Reader{src = l[1:], scratch = g.lscratch[:]}
	rec: ndb.Record
	res := ndb.next(&r, &rec)
	if res == .Error {
		return fail(g, r.error, b.line)
	}
	if res == .End || rec.tuples[0].key != "node" {
		version := res == .Record && rec.tuples[0].key == "guide"
		return fail(g, version ? "@guide= comes first, before the header" : "a directive guide does not know", b.line)
	}
	for t in rec.tuples {
		if t.flag {
			return fail(g, "a directive's key with no value", b.line)
		}
		switch t.key {
		case "node":
			b.node = t.value
		case "title":
			b.title = t.value
		case "keys":
			b.keys = t.value
		case:
			return fail(g, "a node key guide does not know", b.line)
		}
	}
	// A bare id points into the page, so it outlives this line's scratch.
	at, lo := uintptr(raw_data(b.node)), uintptr(raw_data(l))
	if !node_id(b.node) || at < lo || at >= lo + uintptr(len(l)) {
		return fail(g, "a node's id is bare: [a-z0-9-]+", b.line)
	}
	if len(b.keys) > 0 && !list_ok(b.keys, false) {
		return fail(g, "a malformed keys= list", b.line)
	}
	for id in g.nodes {
		if id == b.node {
			return fail(g, "a node id used twice", b.line)
		}
	}
	if append(&g.nodes, b.node) != 1 {
		return fail(g, "more than 64 nodes", b.line)
	}
	advance(g, next)
	b.kind = .Node
	return true
}

// True if a line starts a block of its own rather than going on with a paragraph.
@(private="file")
starts_block :: proc "contextless" (l: string) -> bool {
	if len(l) == 0 {
		return true
	}
	c := l[0]
	return is_blank(l) || c == '@' || c == '#' || c == '|' || str.has_prefix(l, "```") || str.has_prefix(l, "- ") || str.has_prefix(l, ": ") || str.has_prefix(l, "  ")
}

// The next block of the body. False after the last, and on an error, with
// g.error set: `for b in guide.next(&g)`, then look at g.error.
next :: proc "contextless" (g: ^Guide) -> (b: Block, ok: bool) {
	if g.error != "" {
		return {}, false
	}
	l: string
	n: int
	for {
		if g.pos >= len(g.src) {
			return {}, false
		}
		l, n = line_at(g)
		if !is_blank(l) {
			break
		}
		advance(g, n)
	}
	b.line = g.line + 1
	start := g.pos
	switch {
	case str.has_prefix(l, "```"):
		ok = fence(g, &b, l, n)
	case l[0] == '@':
		ok = directive(g, &b, l, n)
	case l[0] == '#':
		sub := str.has_prefix(l, "## ")
		if !sub && !str.has_prefix(l, "# ") {
			return b, fail(g, "a heading is # or ##, then a space", b.line)
		}
		skip := sub ? 3 : 2
		b.text = trim(l[skip:])
		if len(b.text) == 0 {
			return b, fail(g, "an empty heading", b.line)
		}
		if !sub && (b.text == "NAME" || b.text == "SOURCE") {
			return b, fail(g, "NAME and SOURCE are made from the header", b.line)
		}
		advance(g, n)
		b.kind, ok = sub ? .Subheading : .Heading, true
	case str.has_prefix(l, "  "):
		return b, fail(g, "a continuation line with nothing to continue", b.line)
	case l[0] == '|':
		b.text = l[1:]
		advance(g, n)
		b.kind, ok = .Row, true
	case str.has_prefix(l, "- "):
		end := continued(g)
		b.text = g.src[start + 2:end]
		b.kind, ok = .Item, true
	case str.has_prefix(l, ": "):
		b.text = trim(l[2:])
		if len(b.text) == 0 {
			return b, fail(g, "a definition with no term", b.line)
		}
		body := n
		end := continued(g)
		if end > body {
			b.body = g.src[body:end]
		}
		b.kind, ok = .Def, true
	case: // a paragraph: lines up to a blank one or another block's
		end := start + len(l)
		advance(g, n)
		for g.pos < len(g.src) {
			more, mn := line_at(g)
			if starts_block(more) {
				break
			}
			end = g.pos + len(more)
			advance(g, mn)
		}
		b.text = g.src[start:end]
		b.kind, ok = .Para, true
	}
	return b, ok
}

// --- Inline spans ---

Span_Kind :: enum i32 {
	None    = 0,
	Text    = 1, // text: words, never whitespace
	Space   = 2, // a run of whitespace, newlines and continuation indents included
	Literal = 3, // text: between the backticks (one space trimmed from each end when both have one)
	Param   = 4, // text: <name>, brackets included
	Ref     = 5, // text: name(N), as written; name and sect
	Link    = 6, // {label|target} or {target}: label (the target when none) and target
}

Span :: struct {
	kind:                       Span_Kind,
	text, name, label, target:  string,
	sect:                       int,
}

Inline :: struct {
	s:     string,
	pos:   int,
	error: string,
}

// The length of a reference name(N) at s[i], or 0, and its section.
@(private="file")
ref_at :: proc "contextless" (s: string, i: int) -> (n: int, sect: int) {
	if !name_start(s[i]) || (i > 0 && name_char(s[i - 1])) {
		return 0, 0
	}
	j := i
	for j < len(s) && name_char(s[j]) {
		j += 1
	}
	if j + 3 > len(s) || s[j] != '(' || s[j + 1] < '1' || s[j + 1] > '8' || s[j + 2] != ')' {
		return 0, 0
	}
	return j + 3 - i, int(s[j + 1] - '0')
}

// The length of a parameter <name> at s[i], or 0.
@(private="file")
param_at :: proc "contextless" (s: string, i: int) -> int {
	if s[i] != '<' || i + 1 >= len(s) || !is_alpha(s[i + 1]) {
		return 0
	}
	j := i + 2
	for j < len(s) && (is_alnum(s[j]) || s[j] == '.' || s[j] == '_' || s[j] == '-') {
		j += 1
	}
	return j < len(s) && s[j] == '>' ? j + 1 - i : 0
}

LINK_SCHEMES :: [?]string{"https:", "gemini:", "gopher:"}

@(private="file")
target_ok :: proc "contextless" (t: string) -> bool {
	if len(t) == 0 {
		return false
	}
	if t[0] == '#' {
		return node_id(t[1:])
	}
	for scheme in LINK_SCHEMES {
		if str.has_prefix(t, scheme) {
			for k in 0 ..< len(t) {
				if is_space(t[k]) {
					return false
				}
			}
			return len(t) > 7
		}
	}
	n, _ := ref_at(t, 0)
	if n == 0 {
		return false
	}
	return n == len(t) || (t[n] == '#' && node_id(t[n + 1:]))
}

@(private="file")
span_fail :: proc "contextless" (it: ^Inline, msg: string) -> (Span, bool) {
	it.error = msg
	return {}, false
}

// Backticks from s[i]: how many in the run.
@(private="file")
ticks :: proc "contextless" (s: string, i: int) -> int {
	n := 0
	for i + n < len(s) && s[i + n] == '`' {
		n += 1
	}
	return n
}

// Where a literal opened at s[i] by n backticks closes (the closing run's
// start), and whether it does.
@(private="file")
literal_end :: proc "contextless" (s: string, i, n: int) -> (end: int, ok: bool) {
	for k := i + n; k < len(s); {
		run := ticks(s, k)
		if run == n {
			return k, true
		}
		k += run > 0 ? run : 1
	}
	return 0, false
}

// The next span of it.s. False at its end, and on an unclosed literal or a
// bad link, with it.error set.
span_next :: proc "contextless" (it: ^Inline) -> (sp: Span, ok: bool) {
	s := it.s
	i := it.pos
	if i >= len(s) {
		return {}, false
	}
	c := s[i]
	if is_space(c) {
		j := i
		for j < len(s) && is_space(s[j]) {
			j += 1
		}
		it.pos = j
		return {kind = .Space, text = s[i:j]}, true
	}
	if c == '`' {
		n := ticks(s, i)
		end, closed := literal_end(s, i, n)
		if !closed {
			return span_fail(it, "a literal that is never closed")
		}
		inner := s[i + n:end]
		if len(inner) >= 2 && inner[0] == ' ' && inner[len(inner) - 1] == ' ' && !is_blank(inner) {
			inner = inner[1:len(inner) - 1]
		}
		it.pos = end + n
		return {kind = .Literal, text = inner}, true
	}
	if n := param_at(s, i); n > 0 {
		it.pos = i + n
		return {kind = .Param, text = s[i:i + n]}, true
	}
	if c == '{' {
		j := i + 1
		for j < len(s) && s[j] != '}' && s[j] != '{' {
			j += 1
		}
		if j >= len(s) || s[j] == '{' {
			return span_fail(it, "a { link } that is never closed")
		}
		inner := s[i + 1:j]
		bar := str.index_byte(inner, '|')
		sp = {kind = .Link, text = s[i:j + 1]}
		if bar >= 0 {
			sp.target, sp.label = inner[bar + 1:], trim(inner[:bar])
		} else {
			sp.target, sp.label = inner, inner
		}
		if len(sp.label) == 0 || !target_ok(sp.target) {
			return span_fail(it, "a link to no target guide knows")
		}
		it.pos = j + 1
		return sp, true
	}
	if n, sect := ref_at(s, i); n > 0 {
		it.pos = i + n
		return {kind = .Ref, text = s[i:i + n], name = s[i:i + n - 3], sect = sect}, true
	}
	j := i + 1 // plain text: up to a space or the next span's start
	for j < len(s) && !is_space(s[j]) && s[j] != '`' && s[j] != '{' && param_at(s, j) == 0 {
		if n, _ := ref_at(s, j); n > 0 {
			break
		}
		j += 1
	}
	it.pos = j
	return {kind = .Text, text = s[i:j]}, true
}

// The next cell of a row (a Row block's text), consumed from row^, trimmed;
// a | inside backticks is the cell's. False at the row's end.
cell_next :: proc "contextless" (row: ^string) -> (cell: string, ok: bool) {
	if is_blank(row^) {
		return "", false
	}
	i := 0
	for i < len(row^) && row[i] != '|' {
		n := ticks(row^, i)
		if n == 0 {
			i += 1
		} else if end, closed := literal_end(row^, i, n); closed {
			i = end + n
		} else {
			i += n
		}
	}
	cell = trim(row[:i])
	row^ = row[min(i + 1, len(row^)):]
	return cell, true
}
