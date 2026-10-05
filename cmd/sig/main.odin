// sig: the C declarations of the functions named, from the SYNOPSIS of their
// section 2 pages (man(1), upstream docs/12 §6.1), for pasting into code, as
// Plan 9's sig prints them. A name is a page's (futex_wait) or its C
// function's (vx_futex_wait).
package sig

import "vx:guide"
import "vx:man"
import "vx:ns"
import "vx:procns"
import "vx:rt"
import "vx:str"
import usage "gen:usage/sig"

space: ns.Namespace
index_bufs: man.Index_Buffers
page_buf: [256 * 1024]u8
path_buf: [96]u8
page_guide: guide.Guide

ident :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// Whether the declaration d declares name (or vx_name): it is the identifier
// just before the first (.
declares :: proc(d, name: string) -> bool {
	p := str.index_byte(d, '(')
	if p < 0 {
		return false
	}
	e := p
	for e > 0 && d[e - 1] == ' ' {
		e -= 1
	}
	s := e
	for s > 0 && ident(d[s - 1]) {
		s -= 1
	}
	id := d[s:e]
	return id != "" && (id == name || (len(id) == len(name) + 3 && str.has_prefix(id, "vx_") && id[3:] == name))
}

// Each declaration of the fence (up to a ;) that declares name, printed on one line.
print_decls :: proc(fence, name: string) -> int {
	n := 0
	for at := 0; at < len(fence); {
		end := at
		for end < len(fence) && fence[end] != ';' {
			end += 1
		}
		d := fence[at:end]
		for len(d) > 0 && (d[0] == ' ' || d[0] == '\n') {
			d = d[1:]
		}
		if end < len(fence) && declares(d, name) {
			one: [dynamic; 1024]u8
			for i in 0 ..< len(d) {
				if len(one) + 2 >= cap(one) {
					break
				}
				space_ := d[i] == ' ' || d[i] == '\n'
				if space_ && (len(one) == 0 || one[len(one) - 1] == ' ') {
					continue
				}
				_ = append(&one, space_ ? ' ' : d[i])
			}
			_ = append(&one, ';', '\n')
			rt.print(string(one[:]))
			n += 1
		}
		at = end + 1
	}
	return n
}

sig :: proc(name: string) -> int {
	two := []int{2}
	page, _, found := man.read(&space, name, two, page_buf[:], path_buf[:], &index_bufs)
	if !found && len(name) > 3 && str.has_prefix(name, "vx_") {
		page, _, found = man.read(&space, name[3:], two, page_buf[:], path_buf[:], &index_bufs)
	}
	g := &page_guide
	if !found || !guide.open(g, page) {
		return 0
	}
	synopsis := false
	n := 0
	for b in guide.next(g) {
		if b.kind == .Heading || b.kind == .Node {
			synopsis = b.kind == .Heading && b.text == "SYNOPSIS"
		}
		if synopsis && b.kind == .Fence && b.fence == "c" {
			n += print_decls(b.text, name)
		}
	}
	return n
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	if len(rt.args()) == 0 {
		rt.eprint("sig: ", usage.TEXT, "\n")
		return usage.TEXT
	}
	if procns.from_spawn(&space) != .Ok {
		return "the namespace is incomplete"
	}
	status := ""
	for name in rt.args() {
		if sig(name) == 0 {
			rt.eprint("sig: no declaration of ", name, "\n")
			status = "not found"
		}
	}
	return status
}
