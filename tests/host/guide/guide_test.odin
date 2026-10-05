// lib/guide (upstream docs/12-manual.md §4, guide(6)), ported from upstream's
// tests/host/guide_test.c: a page rendered exactly as Plan 9's would be;
// every error the format names refused, at its line; the inline spans and
// table cells; nodes rendered alone; and every page under man/ parsed and
// rendered.
package guide_test

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "vx:guide"
import "vx:utf"

// A sink of a fixed size, so writing needs no context.
Sink :: struct {
	buf:      []u8,
	n:        int,
	overflow: bool,
}

sink_make :: proc(size := 1 << 16) -> ^Sink {
	k := new(Sink, context.temp_allocator)
	k.buf = make([]u8, size, context.temp_allocator)
	return k
}

sink_write :: proc "contextless" (ctx: rawptr, s: string) {
	k := (^Sink)(ctx)
	if len(s) > len(k.buf) - k.n {
		k.overflow = true
		return
	}
	copy(k.buf[k.n:], s)
	k.n += len(s)
}

// The page rendered at width (0: 80), the whole page or a node; ok false if
// it was refused.
render :: proc(page: string, width: u32, node := "") -> (out: string, ok: bool) {
	k := sink_make()
	o := guide.Out{write = sink_write, ctx = k, width = width}
	_, ok = guide.render(page, &o, node)
	return string(k.buf[:k.n]), ok && !k.overflow
}

CAT :: "page=cat sect=1 summary=\"concatenate files\"\n" +
	"    names=cat\n" +
	"    src=cmd/cat.c\n" +
	"\n" +
	"# SYNOPSIS\n" +
	"\n" +
	"```usage\n" +
	"cat [-u] [file ...]\n" +
	"```\n" +
	"\n" +
	"# DESCRIPTION\n" +
	"\n" +
	"`cat` reads each <file> in order and writes it to standard output. With no\n" +
	"<file>, or with a <file> of `-`, it reads standard input. Data is copied as\n" +
	"bytes and never checked: see {text and bytes|utf(6)#bytes}.\n" +
	"\n" +
	": `-u`\n" +
	"  Write each read as it arrives, without collecting full blocks.\n" +
	"\n" +
	"# SEE ALSO\n" +
	"\n" +
	"tail(1), read(2)\n"

CAT_44 :: "CAT(1)                                CAT(1)\n" +
	"\n" +
	"NAME\n" +
	"     cat — concatenate files\n" +
	"\n" +
	"SYNOPSIS\n" +
	"     cat [-u] [file ...]\n" +
	"\n" +
	"DESCRIPTION\n" +
	"     cat reads each <file> in order and\n" +
	"     writes it to standard output. With no\n" +
	"     <file>, or with a <file> of -, it reads\n" +
	"     standard input. Data is copied as bytes\n" +
	"     and never checked: see text and bytes\n" +
	"     (utf(6)#bytes).\n" +
	"\n" +
	"     -u   Write each read as it arrives,\n" +
	"          without collecting full blocks.\n" +
	"\n" +
	"SOURCE\n" +
	"     cmd/cat.c\n" +
	"\n" +
	"SEE ALSO\n" +
	"     tail(1), read(2)\n"

// A header value decoded from ndb's hex form must be UTF-8 too (upstream's
// guide_fuzz's find, 705fd16).
@(test)
test_header_utf8 :: proc(t: ^testing.T) {
	_, ok := render("page=t sect=7 summary=x\"C0\"\n\nText.\n", 80)
	testing.expect(t, !ok)
	_, ok = render("page=t sect=7 summary=x\"C3A9\"\n\nText.\n", 80) // é
	testing.expect(t, ok)
}

@(test)
test_render :: proc(t: ^testing.T) {
	got, ok := render(CAT, 44)
	testing.expect(t, ok)
	testing.expect_value(t, got, CAT_44)
	// No line ends in a space, and none passes the width but an unbreakable word.
	got, ok = render(CAT, 30)
	testing.expect(t, ok)
	testing.expect(t, !strings.contains(got, " \n"))
	// SOURCE goes last when nothing comes after it in Plan 9's order.
	got, ok = render("page=x sect=1 summary=s src=a.c,b.c\n\n# DESCRIPTION\n\nText.\n", 80)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(got, "Text.\n\nSOURCE\n     a.c\n     b.c\n"))
	// A table: columns as wide as their widest cell; a | in a literal is the cell's.
	got, ok = render("page=t sect=7 summary=s\n\n| A | Bee |\n| `x|y` | z |\n", 80)
	testing.expect(t, ok)
	testing.expectf(t, strings.contains(got, "     A    Bee\n     x|y  z\n"), "table rendered as %q", got)
	// A word longer than the line, and multi-byte text, wrap without splitting a rune.
	long_page := strings.concatenate({"page=w sect=7 summary=s\n\n", strings.repeat("é", 300, context.temp_allocator), " end\n"}, context.temp_allocator)
	got, ok = render(long_page, 20)
	testing.expect(t, ok)
	testing.expect(t, utf.valid(got))
	testing.expect(t, strings.contains(got, "end\n"))
}

@(test)
test_nodes :: proc(t: ^testing.T) {
	page := "page=rc sect=1 summary=shell\n\n# DESCRIPTION\n\nMain.\n\n@node=quoting title=\"Quoting\"\n\nQuotes.\n\n@node=vars\n\nVariables.\n"
	got, ok := render(page, 80, "quoting")
	testing.expect(t, ok)
	testing.expect_value(t, got, "QUOTING\n     Quotes.\n")
	got, ok = render(page, 80, "vars")
	testing.expect(t, ok)
	testing.expect_value(t, got, "VARS\n     Variables.\n")
	_, ok = render(page, 80, "nope")
	testing.expect(t, !ok)
	got, ok = render(page, 80)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(got, "Main.\n\nQUOTING\n     Quotes.\n\nVARS\n     Variables.\n"))
}

// Each page is refused, its error naming the line.
@(test)
test_errors :: proc(t: ^testing.T) {
	Bad :: struct {
		page, error: string,
		line:        int,
	}
	bad := []Bad {
		{"sect=1 page=x summary=s\n", "first tuple is page=", 1},
		{"page=x summary=s\n", "needs sect=", 1},
		{"page=x sect=9 summary=s\n", "1 to 8", 1},
		{"page=X sect=1 summary=s\n", "lower case", 1},
		{"page=x sect=1 summary=s colour=red\n", "does not know", 1},
		{"page=x sect=1 summary=s lang=go\n", "c, lua or rc", 1},
		{"page=x sect=1 summary=s host=yes\n", "flag", 1},
		{"page=x sect=1 summary=s names=a,,b\n", "empty or malformed", 1},
		{"page=x sect=1 summary=s\npage=y sect=1 summary=s\n", "one record", 1},
		{"@guide=2\npage=x sect=1 summary=s\n", "version", 1},
		{"page=x sect=1 summary=s\n\n```perl\nx\n```\n", "fence kind", 3},
		{"page=x sect=1 summary=s\n\n```\nnever closed\n", "never closed", 3},
		{"page=x sect=1 summary=s\n\n### Deep\n", "# or ##", 3},
		{"page=x sect=1 summary=s\n\n# NAME\n", "made from the header", 3},
		{"page=x sect=1 summary=s\n\nText.\n\n  dangling\n", "nothing to continue", 5},
		{"page=x sect=1 summary=s\n\n@include=y\n", "directive", 3},
		{"page=x sect=1 summary=s\n\n@guide=1\n", "comes first", 3},
		{"page=x sect=1 summary=s\n\n@node=a\n\n@node=a\n", "used twice", 5},
		{"page=x sect=1 summary=s\n\n@node=Big\n", "bare", 3},
		{"page=x sect=1 summary=s\n\n@node=\"a\"\n", "bare", 3},
		{"page=x sect=1 summary=s\n\n@node=a colour=red\n", "node key", 3},
		{"page=x sect=1 summary=s\n\n: \n", "no term", 3},
		{"page=x sect=1 summary=s\n\nAn `open literal.\n", "never closed", 3},
		{"page=x sect=1 summary=s\n\nSee {here|nowhere}.\n", "no target", 3},
		{"page=x sect=1 summary=s\n\nSee {unclosed.\n", "never closed", 3},
		{"page=x sect=1 summary=s\n\nSee {ftp://x}.\n", "no target", 3},
		{"page=x sect=1 summary=s\n\nA\x01 control.\n", "control", 3},
		{"page=x sect=1 summary=s\n\n\xff\n", "UTF-8", 1},
	}
	for c, i in bad {
		o := guide.Out{write = sink_write, ctx = sink_make()}
		err, ok := guide.render(c.page, &o)
		testing.expectf(t, !ok, "page %d accepted", i)
		testing.expectf(t, strings.contains(err.msg, c.error), "page %d: %q, not %q", i, err.msg, c.error)
		testing.expectf(t, err.line == c.line, "page %d: line %d, not %d", i, err.line, c.line)
	}
	// What is allowed: @guide=1 first, a target of each kind, a node with keys.
	_, ok := render("@guide=1\npage=x sect=1 summary=s\n\nA.\n", 80)
	testing.expect(t, ok)
	_, ok = render("page=x sect=1 summary=s\n\n{rc(1)} {a|rc(1)#quoting} {b|#n} {c|https://x.org/a} {d|gemini://g} {e|gopher://h}\n\n@node=n keys=a,b\n", 80)
	testing.expect(t, ok)
}

@(test)
test_spans :: proc(t: ^testing.T) {
	Want :: struct {
		kind: guide.Span_Kind,
		text: string,
	}
	want := []Want {
		{.Text, "Use"},
		{.Space, " "},
		{.Literal, "a `b` c"},
		{.Space, " "},
		{.Text, "and"},
		{.Space, " "},
		{.Param, "<file-1>"},
		{.Text, ","},
		{.Space, " "},
		{.Ref, "rc(1)"},
		{.Text, "."},
		{.Space, " "},
		{.Link, "{x|vx_create(2)}"},
		{.Text, "<no"},
	}
	it := guide.Inline{s = "Use ``a `b` c`` and <file-1>, rc(1). {x|vx_create(2)}<no"}
	for w, i in want {
		sp, ok := guide.span_next(&it)
		testing.expectf(t, ok, "span %d: none", i)
		testing.expectf(t, sp.kind == w.kind, "span %d: kind %v, not %v", i, sp.kind, w.kind)
		testing.expectf(t, sp.text == w.text, "span %d: %q, not %q", i, sp.text, w.text)
		if sp.kind == .Ref {
			testing.expect_value(t, sp.sect, 1)
			testing.expect_value(t, sp.name, "rc")
		}
		if sp.kind == .Link {
			testing.expect_value(t, sp.label, "x")
			testing.expect_value(t, sp.target, "vx_create(2)")
		}
	}
	_, more := guide.span_next(&it)
	testing.expect(t, !more)
	testing.expect_value(t, it.error, "")

	// A reference needs a name before it ends: "x(1)" in "ax(1)" is the name "ax".
	ref := guide.Inline{s = "ax(1) (b(2))"}
	sp, _ := guide.span_next(&ref)
	testing.expect_value(t, sp.kind, guide.Span_Kind.Ref)
	testing.expect_value(t, sp.name, "ax")
	_, _ = guide.span_next(&ref)
	sp, _ = guide.span_next(&ref)
	testing.expect_value(t, sp.kind, guide.Span_Kind.Text)
	testing.expect_value(t, sp.text, "(")
	sp, _ = guide.span_next(&ref)
	testing.expect_value(t, sp.kind, guide.Span_Kind.Ref)
	testing.expect_value(t, sp.sect, 2)

	row := " a | `x|y` |  | last"
	for want_cell in ([]string{"a", "`x|y`", "", "last"}) {
		cell, ok := guide.cell_next(&row)
		testing.expect(t, ok)
		testing.expect_value(t, cell, want_cell)
	}
	_, more = guide.cell_next(&row)
	testing.expect(t, !more)
}

// Every page under man/ parses and renders, whole and node by node, and is
// named for its file and directory.
@(test)
test_pages :: proc(t: ^testing.T) {
	pages := 0
	for sect in 1 ..= 8 {
		dir := fmt.tprintf("man/%d", sect)
		files, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil {
			continue
		}
		for f in files {
			path := fmt.tprintf("%s/%s", dir, f.name)
			data, rerr := os.read_entire_file(path, context.temp_allocator)
			if !testing.expectf(t, rerr == nil, "%s: %v", path, rerr) {
				continue
			}
			text := string(data)
			o := guide.Out{write = sink_write, ctx = sink_make(1 << 18)}
			e, ok := guide.render(text, &o)
			testing.expectf(t, ok, "%s:%d: %s", path, e.line, e.msg)
			g := new(guide.Guide, context.temp_allocator)
			if !testing.expectf(t, guide.open(g, text), "%s: %s", path, g.error) {
				continue
			}
			testing.expect_value(t, g.h.sect, sect)
			testing.expect_value(t, g.h.page, f.name)
			for b in guide.next(g) {
				if b.kind == .Node {
					_, nok := render(text, 80, b.node)
					testing.expectf(t, nok, "%s: node %s", path, b.node)
				}
			}
			pages += 1
		}
	}
	testing.expect(t, pages >= 1)
}

// A cell of more than 512 bytes is cut at the buffer's end, on a whole rune
// (upstream's cut inside a rune until its f24356f, from this tree's finding).
// long_cell.txt is upstream's guide.c at 08cc12f rendering the same two
// pages, each after a line "=== lead L ok 1", which both must match byte for
// byte.
LONG_CELL :: #load("long_cell.txt", string)

@(test)
test_long_cell :: proc(t: ^testing.T) {
	all := strings.builder_make(context.temp_allocator)
	for lead in ([]string{"", "x"}) {
		cell := strings.concatenate({lead, strings.repeat("é", 300, context.temp_allocator)}, context.temp_allocator)
		page := strings.concatenate({"page=t sect=7 summary=s\n\n| ", cell, " | b |\n| c | d |\n"}, context.temp_allocator)
		got, ok := render(page, 80)
		testing.expect(t, ok)
		testing.expectf(t, utf.valid(got), "lead %q: not UTF-8", lead)
		// The cell is one long word, written in two at 256 bytes, then cut.
		testing.expectf(t, strings.contains(got, "é  b\n"), "lead %q: %q", lead, got)
		fmt.sbprintf(&all, "=== lead %s ok %d\n%s", lead, int(ok), got)
	}
	testing.expect_value(t, strings.to_string(all), LONG_CELL)
}
