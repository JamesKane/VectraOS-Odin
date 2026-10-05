package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "vx:guide"
import "vx:ndb"
import "vx:p9"

// The manual (upstream docs/12-manual.md; its M6 steps 6a1-6a5 and 6b): pages
// in man/<sect>/<page>, written in guide and read through lib/guide.
//
// ./build man [section ...] title [node] renders a page as man(1) does, so
// the manual can be read before an image boots; ./build man --check runs
// the manual's pass of ./build check alone (12 §7): every page parses, is
// named for its file and directory, and keeps 12 §8's house rules;
// out/man/index/base, the index the image holds at /lib/man/index/base, is
// written from the pages and every link resolves through it, or to a page
// man/missing promises; everything the inventory lists has a page or a
// record in man/missing, the ledger that only shrinks, never both; and a
// program with a page takes its usage message from it.

// What must have a page: kind and name, and the sections a page may be in.
@(private="file")
Man_Item :: struct {
	kind, name: string,
	sects:      bit_set[1 ..= 8],
	listed:     bool, // in man/missing
}

// The index: one entry per name a page documents, and per node.
@(private="file")
Man_Entry :: struct {
	name, page: string,
	node:       string, // the node's id, for a node's entry
	about:      string, // the page's summary, or the node's title
	keys:       string, // the page's or the node's keys=, for lookman
	sect:       int,
}

@(private="file")
Man_Page :: struct {
	path: string,
	text: string,
	sect: int,
	page: string,
}

@(private="file")
Man_Check :: struct {
	items:  [dynamic]Man_Item,
	index:  [dynamic]Man_Entry,
	errors: int,
}

// The formats with a section 6 page, each named for its page. Their keys are
// checked once each parser keeps a key table (12 §7), as upstream's are.
@(private="file")
MAN_FORMATS :: [?]string{"ndb", "guide", "namespace", "svc", "driver", "users", "utf", "vxfs", "store", "release", "slots"}

// Plan 9's headings, in Plan 9's order (12 §8).
@(private="file")
MAN_ORDER :: [?]string{"SYNOPSIS", "DESCRIPTION", "EXAMPLES", "FILES", "SEE ALSO", "DIAGNOSTICS", "BUGS"}

MAN_INDEX :: "out/man/index/base"

@(private="file")
man_error :: proc(c: ^Man_Check, where_: string, line: int, what: string) {
	if line > 0 {
		fmt.eprintfln("  MAN   %s:%d: %s", where_, line, what)
	} else {
		fmt.eprintfln("  MAN   %s: %s", where_, what)
	}
	c.errors += 1
}

@(private="file")
man_need :: proc(c: ^Man_Check, kind, name: string, sects: bit_set[1 ..= 8]) {
	for &it in c.items { // a native program and sbase's of one name: one page covers both
		if it.kind == kind && it.name == name && it.sects & sects != {} {
			it.sects &= sects // the sections both allow
			return
		}
	}
	append(&c.items, Man_Item{kind = kind, name = name, sects = sects})
}

// Every name in a .def file's MACRO(... lines, the name being the first argument.
@(private="file")
man_need_def :: proc(c: ^Man_Check, path, macro, kind: string, sects: bit_set[1 ..= 8]) -> bool {
	text := read_file(path) or_return
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, macro) || len(line) == len(macro) || line[len(macro)] != '(' {
			continue
		}
		args := line[len(macro) + 1:]
		end := strings.index_any(args, ",)")
		man_need(c, kind, strings.trim_space(end < 0 ? args : args[:end]), sects)
	}
	return true
}

// What this tree has that needs a page: its programs, servers and drivers
// (PROGRAMS, but the tests), the POSIX ports' programs, the host tools, the
// syscalls of abi/vx/syscalls.def, lib/p9's 9Px messages, the formats and
// the eight intro pages.
@(private="file")
man_inventory :: proc(c: ^Man_Check) -> bool {
	for p in PROGRAMS {
		from := p.kind == .Odin ? p.dir : p.source
		switch {
		case strings.has_prefix(from, "tests/"): // a test is not a program anyone runs
		case strings.has_prefix(from, "servers/"):
			man_need(c, "server", p.name, {4, 8})
		case strings.has_prefix(from, "drivers/"):
			man_need(c, "driver", p.name, {3})
		case:
			man_need(c, "program", p.name, {1, 8})
		}
	}
	ps := posix_load() or_return
	for port in ([]^Port{&ps.lua, &ps.sbase}) {
		for rec in port.programs {
			man_need(c, "program", val(rec, "program"), {1})
		}
	}
	// The host tools: tools/*, but the build tool, whose page is build's,
	// and abigen, a part of it that ./build runs first.
	tools_dir, err := os.read_directory_by_path("tools", -1, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("build: cannot read tools: %v", err)
		return false
	}
	for e in tools_dir {
		if e.type == .Directory && e.name != "build" && e.name != "abigen" {
			man_need(c, "program", e.name, {1, 8})
		}
	}
	man_need(c, "program", "build", {1, 8})
	man_need_def(c, "abi/vx/syscalls.def", "VX_SYSCALL", "syscall", {2}) or_return
	for m in p9.MESSAGES {
		if m.name != "" {
			man_need(c, "message", m.name, {5})
		}
	}
	for f in MAN_FORMATS {
		man_need(c, "format", f, {6})
	}
	for n in 1 ..= 8 {
		man_need(c, "intro", "intro", {n})
	}
	return true
}

// A name's entry in section sect: a page's (page ""), or a node of that page.
@(private="file")
man_find :: proc(c: ^Man_Check, name: string, sect: int, page := "") -> ^Man_Entry {
	for &e in c.index {
		kind := page != "" ? e.node != "" && e.page == page : e.node == ""
		if e.sect == sect && kind && e.name == name {
			return &e
		}
	}
	return nil
}

@(private="file")
man_index_add :: proc(c: ^Man_Check, e: Man_Entry, where_: string) {
	if man_find(c, e.name, e.sect, e.node != "" ? e.page : "") != nil {
		man_error(c, where_, 0, e.node != "" ? fmt.tprintf("node %s twice", e.name) : fmt.tprintf("%s(%d) is named by two pages", e.name, e.sect))
	}
	append(&c.index, e)
}

// 12 §8's house rules, on a page's raw lines.
@(private="file")
man_house :: proc(c: ^Man_Check, where_: string, text: string) {
	fence := false
	text := text
	line := 0
	for l in strings.split_lines_iterator(&text) {
		line += 1
		ticks := strings.has_prefix(l, "```")
		edge := ticks && (!fence || len(l) == 3)
		if len(l) > 0 && (l[len(l) - 1] == ' ' || l[len(l) - 1] == '\t') {
			man_error(c, where_, line, "a trailing space")
		}
		if !fence && strings.index_byte(l, '\t') >= 0 {
			man_error(c, where_, line, "a tab outside a fence")
		}
		if fence && !edge && strings.rune_count(l) > 80 {
			man_error(c, where_, line, "a fence line wider than 80 columns")
		}
		if edge {
			fence = !fence // opened by ```kind, closed by ``` alone
		}
	}
}

// A ledger record naming a page not yet written, in sect.
@(private="file")
man_promised :: proc(c: ^Man_Check, name: string, sect: int) -> bool {
	for it in c.items {
		if it.listed && sect in it.sects && it.name == name {
			return true
		}
	}
	return false
}

// A span's link resolves: name(N), name(N)#node, #node or a URL.
@(private="file")
man_link :: proc(c: ^Man_Check, p: ^Man_Page, target: string, line: int) {
	if target == "" {
		return
	}
	if target[0] == '#' {
		if man_find(c, target[1:], p.sect, p.page) == nil {
			man_error(c, p.path, line, fmt.tprintf("a link to no node of this page: %s", target))
		}
		return
	}
	if target[len(target) - 1] != ')' && strings.index_byte(target, '#') < 0 {
		return // a URL
	}
	it := guide.Inline{s = target}
	sp, ok := guide.span_next(&it)
	if !ok || sp.kind != .Ref {
		return // a URL with a ( in it
	}
	e := man_find(c, sp.name, sp.sect)
	if e == nil && man_promised(c, sp.name, sp.sect) { // linked before it is written
		if it.pos < len(target) {
			man_error(c, p.path, line, "a link to a node of a page not yet written")
		}
		return
	}
	if e == nil {
		man_error(c, p.path, line, fmt.tprintf("a link to nothing: %s", sp.text))
		return
	}
	if it.pos < len(target) && man_find(c, target[it.pos + 1:], e.sect, e.page) == nil {
		man_error(c, p.path, line, fmt.tprintf("a link to no such node: %s", target))
	}
}

@(private="file")
man_spans :: proc(c: ^Man_Check, p: ^Man_Page, text: string, line: int) {
	it := guide.Inline{s = text}
	for sp in guide.span_next(&it) {
		#partial switch sp.kind {
		case .Ref:
			man_link(c, p, sp.text, line)
		case .Link:
			man_link(c, p, sp.target, line)
		}
	}
}

// The second pass: headings in order and capitals, every link resolved.
@(private="file")
man_body :: proc(c: ^Man_Check, p: ^Man_Page) {
	g := new(guide.Guide, context.temp_allocator)
	if !guide.open(g, p.text) {
		return
	}
	last := -1
	for b in guide.next(g) {
		if b.kind == .Heading {
			if strings.to_upper(b.text, context.temp_allocator) != b.text {
				man_error(c, p.path, b.line, "a heading not in capitals")
			}
			for h, k in MAN_ORDER {
				if b.text == h {
					if k <= last {
						man_error(c, p.path, b.line, "a heading out of Plan 9's order (12 §8)")
					}
					last = k
				}
			}
		}
		if b.kind == .Fence || b.kind == .Node {
			continue
		}
		man_spans(c, p, b.text, b.line)
		if b.body != "" {
			man_spans(c, p, b.body, b.line)
		}
	}
}

@(private="file")
man_discard :: proc "contextless" (ctx: rawptr, s: string) {}

// The page names in man/<sect>, in byte order.
man_dir :: proc(sect: int) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	files, err := os.read_directory_by_path(fmt.tprintf("man/%d", sect), -1, context.temp_allocator)
	if err != nil {
		return nil
	}
	for f in files {
		if f.type == .Regular && f.name[0] != '.' {
			append(&names, f.name)
		}
	}
	slice.sort(names[:])
	return names[:]
}

// The manual's pass of ./build check. It writes the index the image holds.
check_man :: proc() -> bool {
	start := time.tick_now()
	c: Man_Check
	c.items = make([dynamic]Man_Item, context.temp_allocator)
	c.index = make([dynamic]Man_Entry, context.temp_allocator)
	man_inventory(&c) or_return
	pages := make([dynamic]Man_Page, context.temp_allocator)
	g := new(guide.Guide, context.temp_allocator)
	for sect in 1 ..= 8 { // the first pass: parse, and index
		for name in man_dir(sect) {
			p := Man_Page{path = fmt.tprintf("man/%d/%s", sect, name), sect = sect, page = name}
			p.text = read_file(p.path) or_return
			man_house(&c, p.path, p.text)
			o := guide.Out{write = man_discard}
			if !guide.open(g, p.text) {
				man_error(&c, p.path, g.error_line, g.error)
				continue
			}
			if e, ok := guide.render(p.text, &o); !ok {
				man_error(&c, p.path, e.line, e.msg)
				continue
			}
			if g.h.page != p.page || g.h.sect != sect {
				man_error(&c, p.path, 1, "page= and sect= are its file's name and directory")
			}
			summary := strings.clone(g.h.summary, context.temp_allocator)
			keys := strings.clone(g.h.keys, context.temp_allocator)
			// The page's own name is a link to it too, named or not (12 §3:
			// open(2) and vx_create(2)).
			self := false
			names := g.h.names
			for n in guide.item_next(&names) {
				man_index_add(&c, {name = n, page = p.page, about = summary, keys = keys, sect = sect}, p.path)
				self = self || n == p.page
			}
			if !self {
				man_index_add(&c, {name = p.page, page = p.page, about = summary, keys = keys, sect = sect}, p.path)
			}
			for b in guide.next(g) {
				if b.kind == .Node {
					about := strings.clone(b.title, context.temp_allocator)
					node_keys := strings.clone(b.keys, context.temp_allocator)
					man_index_add(&c, {name = b.node, page = p.page, node = b.node, about = about, keys = node_keys, sect = sect}, p.path)
				}
			}
			append(&pages, p)
		}
	}

	// The ledger: each record names something the inventory has, once.
	missing := 0
	if os.exists("man/missing") {
		f := read_ndb("man/missing") or_return
		for rec in f.records {
			kind, name := val(rec, "kind"), val(rec, "name")
			sect, has_sect := ndb.get_u64(rec, "sect")
			only: bit_set[1 ..= 8]
			if has_sect && sect >= 1 && sect <= 8 {
				only = {int(sect)}
			}
			found: ^Man_Item
			for &it in c.items {
				if it.kind == kind && it.name == name && (!has_sect || (only != {} && it.sects == only)) {
					found = &it
					break
				}
			}
			switch {
			case found == nil:
				man_error(&c, "man/missing", rec.line, "names nothing the system has: remove it")
			case found.listed:
				man_error(&c, "man/missing", rec.line, "listed twice")
			}
			if found != nil {
				found.listed = true
			}
			missing += 1
		}
	}
	for &p in pages { // links resolve to pages, or to the ledger
		man_body(&c, &p)
	}
	for it in c.items {
		has := false
		for s in it.sects {
			has = has || man_find(&c, it.name, s) != nil
		}
		sect := ""
		if it.kind == "intro" {
			for s in it.sects {
				sect = fmt.tprintf(" sect=%d", s)
			}
		}
		if has && it.listed {
			man_error(&c, "man/missing", 0, fmt.tprintf("documented now, so remove: kind=%s name=%s%s", it.kind, it.name, sect))
		}
		if !has && !it.listed {
			man_error(&c, "man", 0, fmt.tprintf("no page, and not in man/missing: kind=%s name=%s%s", it.kind, it.name, sect))
		}
	}

	check_usage(&c)

	// The index, as 12 §5 has it: one record per name and node.
	make_dirs("out/man/index") or_return
	w := ndb.Writer{buf = make([]u8, len(c.index) * 512 + 64, context.temp_allocator)}
	for e in c.index {
		ndb.put(&w, "name", e.name)
		ndb.put(&w, "page", e.page)
		ndb.put_u64(&w, "sect", u64(e.sect))
		if e.node != "" {
			ndb.put(&w, "node", e.node)
		}
		if e.about != "" {
			ndb.put(&w, e.node != "" ? "title" : "summary", e.about)
		}
		if e.keys != "" {
			ndb.put(&w, "keys", e.keys)
		}
		if !ndb.end(&w) {
			fmt.eprintln("build: the manual's index does not fit")
			return false
		}
	}
	write_file(MAN_INDEX, ndb.written(&w)) or_return
	ms := time.duration_milliseconds(time.tick_since(start))
	ok := c.errors == 0
	verdict := ok ? "ok" : fmt.tprintf("FAIL: %d errors", c.errors)
	fmt.eprintfln("  MAN   %d pages, %d names, %d missing, %.0f ms (budget 200 ms) %s", len(pages), len(c.index), missing, ms, verdict)
	return ok && ms < 200
}

// --- Usage messages from pages (upstream's M6 step 6a3) ---
//
// A program whose page has a usage fence imports gen:usage/NAME, the package
// build makes in out/gen/usage/NAME/ from the fence's lines that start with
// the program's name, so the message and the page cannot differ. Several
// lines are one message, each after the first under the first's command, as
// Plan 9's are.

USAGE_GEN :: "out/gen/usage"

// A program's page: its own file, or a page that names it (man(1) names
// man, lookman and sig). "" if it has none.
usage_page :: proc(name: string) -> string {
	SECTS :: [?]int{1, 8, 4, 3}
	for s in SECTS {
		path := fmt.tprintf("man/%d/%s", s, name)
		if os.exists(path) {
			return path
		}
	}
	g := new(guide.Guide, context.temp_allocator)
	for s in SECTS {
		for page in man_dir(s) {
			path := fmt.tprintf("man/%d/%s", s, page)
			text, err := os.read_entire_file(path, context.temp_allocator)
			if err != nil || !guide.open(g, string(text)) {
				continue
			}
			names := g.h.names
			for n in guide.item_next(&names) {
				if n == name {
					return path
				}
			}
		}
	}
	return ""
}

// A page's first usage fence. ok is false if it has none.
@(private="file")
usage_fence :: proc(page: string) -> (fence: string, ok: bool) {
	data, err := os.read_entire_file(page, context.temp_allocator)
	if err != nil {
		return "", false
	}
	g := new(guide.Guide, context.temp_allocator)
	if !guide.open(g, string(data)) {
		return "", false // the manual's check says why
	}
	for b in guide.next(g) {
		if b.kind == .Fence && b.fence == "usage" {
			return strings.clone(b.text, context.temp_allocator), true
		}
	}
	return "", false
}

// A fence line's first word.
@(private="file")
usage_word :: proc(line: string) -> string {
	sp := strings.index_byte(line, ' ')
	return sp < 0 ? line : line[:sp]
}

// The usage message a fence gives word: "usage: " and the fence's lines
// whose first word it is, each after the first under the first's command.
// ok is false if there are none.
@(private="file")
usage_lines :: proc(fence, word: string) -> (text: string, ok: bool) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "usage: ")
	lines := 0
	rest := fence
	for l in strings.split_lines_iterator(&rest) {
		if usage_word(l) != word {
			continue
		}
		if lines > 0 {
			strings.write_string(&sb, "\n       ")
		}
		strings.write_string(&sb, l)
		lines += 1
	}
	return strings.to_string(sb), lines > 0
}

// The usage message the page gives the program: "usage: " and the lines of
// its first usage fence that start with name. ok is false if there is none.
usage_text :: proc(page, name: string) -> (text: string, ok: bool) {
	fence := usage_fence(page) or_return
	return usage_lines(fence, name)
}

// Whether a fence line's first word can name a constant, TEXT_word: a C
// name, as upstream's VX_USAGE_word takes.
@(private="file")
usage_ident :: proc(word: string) -> bool {
	if word == "" || (word[0] >= '0' && word[0] <= '9') {
		return false
	}
	for ch in transmute([]u8)word {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_') {
			return false
		}
	}
	return true
}

// Writes out/gen/usage/NAME/usage.odin for each program with a usage line
// on its page (rewritten only when it changes).
make_usage :: proc() -> bool {
	for p in PROGRAMS {
		if p.kind != .Odin {
			continue
		}
		page := usage_page(p.name)
		if page == "" {
			continue
		}
		fence, has := usage_fence(page)
		if !has {
			continue
		}
		text, ok := usage_lines(fence, p.name)
		if !ok {
			continue
		}
		dir := fmt.tprintf("%s/%s", USAGE_GEN, p.name)
		make_dirs(dir) or_return
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "// Made by ./build from %s's usage fence (upstream docs/12 §7). Not to be edited.\npackage usage\n\nTEXT :: %q\n", page, text)
		// The fence's lines for other words (rc(1)'s builtins: bind, mount,
		// unmount), each word its own TEXT_word, as upstream's VX_USAGE_word,
		// for the program that has those as builtins.
		rest := fence
		done := make([dynamic]string, context.temp_allocator)
		for l in strings.split_lines_iterator(&rest) {
			word := usage_word(l)
			if word == p.name || !usage_ident(word) || slice.contains(done[:], word) {
				continue
			}
			append(&done, word)
			words, _ := usage_lines(fence, word)
			fmt.sbprintf(&sb, "TEXT_%s :: %q\n", word, words)
		}
		src := strings.to_string(sb)
		path := fmt.tprintf("%s/usage.odin", dir)
		if old, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil && string(old) == src {
			continue
		}
		write_file(path, src) or_return
	}
	return true
}

// A program with a page takes its usage message from it: it keeps no "usage:
// string of its own, so one that prints a usage message imports
// gen:usage/NAME. A program that prints none needs none.
@(private="file")
check_usage :: proc(c: ^Man_Check) {
	for p in PROGRAMS {
		if p.kind != .Odin || strings.has_prefix(p.dir, "tests/") {
			continue
		}
		page := usage_page(p.name)
		if page == "" {
			continue
		}
		files, _ := tree_files(p.dir)
		own := false
		for f in files {
			if !strings.has_suffix(f, ".odin") {
				continue
			}
			src, _ := os.read_entire_file(f, context.temp_allocator)
			own = own || strings.contains(string(src), "\"usage:")
		}
		_, has := usage_text(page, p.name)
		if has && own {
			man_error(c, p.dir, 0, fmt.tprintf("a program with a page takes its usage message from it: gen:usage/%s, not its own", p.name))
		}
		if !has && own {
			man_error(c, page, 0, fmt.tprintf("%s has a usage message, and its page no usage line for it", p.name))
		}
	}
}

// ./build man [section ...] title [node], or --check.
cmd_man :: proc(args: []string) -> bool {
	if len(args) == 1 && args[0] == "--check" {
		return check_man()
	}
	args := args
	sects := make([dynamic]int, context.temp_allocator)
	for len(args) > 0 && len(args[0]) == 1 && args[0][0] >= '1' && args[0][0] <= '8' && len(sects) < 8 {
		append(&sects, int(args[0][0] - '0'))
		args = args[1:]
	}
	if len(args) < 1 || len(args) > 2 {
		fmt.eprintln("usage: ./build man [section ...] title [node]")
		return false
	}
	if len(sects) == 0 {
		for k in 1 ..= 8 {
			append(&sects, k)
		}
	}
	width := terminal_cols()
	for s in sects {
		path := fmt.tprintf("man/%d/%s", s, args[0])
		if !os.exists(path) {
			continue
		}
		page := read_file(path) or_return
		out := Man_Out{buf = make([]u8, 16 * len(page) + 4096, context.temp_allocator)}
		o := guide.Out{write = man_write, ctx = &out, width = width != 0 ? width : 80}
		e, ok := guide.render(page, &o, len(args) == 2 ? args[1] : "")
		_, _ = os.write(os.stdout, out.buf[:out.n]) // what was written before an error stands
		if !ok {
			fmt.eprintfln("build: %s:%d: %s", path, e.line, e.msg)
			return false
		}
		return true
	}
	fmt.eprintfln("build: no page %s in man/", args[0])
	return false
}

// The rendering, kept until it is written out: the callback has no context.
@(private="file")
Man_Out :: struct {
	buf: []u8,
	n:   int,
}

@(private="file")
man_write :: proc "contextless" (ctx: rawptr, s: string) {
	out := (^Man_Out)(ctx)
	k := min(len(s), len(out.buf) - out.n)
	copy(out.buf[out.n:], s[:k])
	out.n += k
}
