// man: prints a page of the manual (man(1), upstream docs/12-manual.md §6.1):
// the page title, or one node of it, from the first section that has it,
// refilled to 80 columns by vx:guide. A title with no file of its own is
// found through the index, so `man lookman` prints man(1). -t prints the
// page's contents, its headings and nodes; -w its path.
package mancmd

import "vx:guide"
import "vx:man"
import "vx:ns"
import "vx:procns"
import "vx:rt"
import usage "gen:usage/man"

space: ns.Namespace
index_bufs: man.Index_Buffers
page_buf: [256 * 1024]u8
path_buf: [96]u8
toc_guide: guide.Guide

// Output goes through rt.print's line buffer.
put :: proc "contextless" (ctx: rawptr, s: string) {
	rt.print(s)
}

line :: proc(parts: ..string) {
	for p in parts {
		rt.print(p)
	}
	rt.print("\n")
}

// -t: the headings, subheadings and nodes, one a line; a node as @id and its title.
contents :: proc(text: string) -> string {
	g := &toc_guide
	if !guide.open(g, text) {
		return "bad page"
	}
	for b in guide.next(g) {
		#partial switch b.kind {
		case .Heading:
			line(b.text)
		case .Subheading:
			line("  ", b.text)
		case .Node:
			line("@", b.node, b.title != "" ? " " : "", b.title)
		}
	}
	return g.error != "" ? "bad page" : ""
}

fail :: proc(why: string, what := "") -> string {
	rt.flush()
	rt.eprint("man: ", why, what, "\n")
	return why
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	args := rt.args()
	toc, where_ := false, false
	i := 0
	for ; i < len(args) && len(args[i]) > 1 && args[i][0] == '-'; i += 1 {
		for f in args[i][1:] {
			if f != 't' && f != 'w' {
				return fail(usage.TEXT)
			}
			toc = toc || f == 't'
			where_ = where_ || f == 'w'
		}
	}
	sects: [dynamic; 8]int
	for i < len(args) && len(sects) < 8 && len(args[i]) == 1 && args[i][0] >= '1' && args[i][0] <= '8' {
		append(&sects, int(args[i][0] - '0'))
		i += 1
	}
	if i == len(args) || len(args) - i > 2 {
		return fail(usage.TEXT)
	}
	if len(sects) == 0 {
		for k in 1 ..= 8 {
			append(&sects, k)
		}
	}
	if procns.from_spawn(&space) != .Ok {
		return fail("the namespace is incomplete")
	}
	title := args[i]
	page, path, found := man.read(&space, title, sects[:], page_buf[:], path_buf[:], &index_bufs)
	if !found {
		return fail("no page for ", title)
	}
	status := ""
	switch {
	case where_:
		line(path)
	case toc:
		status = contents(page)
	case:
		node := i + 1 < len(args) ? args[i + 1] : ""
		if len(node) >= 64 { // upstream's limit on a node's name
			return fail("no such node: ", node)
		}
		o := guide.Out{write = put, width = 80}
		if e, ok := guide.render(page, &o, node); !ok {
			return fail(e.msg)
		}
	}
	rt.flush()
	return status
}
