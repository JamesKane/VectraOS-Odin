package build

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// Canonical IR: scrub_ir's main step, which makes Odin's LLVM IR depend only
// on the sources, not on the run that compiled them or on where the tree is.
//
// Odin's checker collects each file's entities on two threads even with
// -no-threaded-checker -thread-count:1 (the thread pool always has the main
// thread plus thread-count workers, and the main thread runs tasks while it
// waits), so the order of info->entities varies from run to run. Through it
// varies the order of the procedures in a module (the sort that should fix it
// ties on polymorphic instances, which share their generic's position), and
// with that the names Odin numbers as it goes (string constants `csbs$pkg$N`,
// procedure-local statics `proc-.state-N`, procedure literals
// `_proclit$anon-N`), the order of the compile unit's global-constant list,
// the metadata numbering, and the line a polymorphic instance's
// DISubprogram claims (that of whichever call site instantiated it first).
// Each of those is put into a canonical form here:
//
//  - procedure literals are renamed across the package, by their file, line
//    and body; then, per module,
//  - procedures are sorted by name, declarations after definitions;
//  - numbered globals are renamed by first use (procedures first), and
//    emitted after the other globals in that order;
//  - a polymorphic instance's DISubprogram takes the line of its first
//    parameter (or of its first located instruction);
//  - the compile unit's lists are sorted by content;
//  - metadata and attribute groups are renumbered by first use;
//  - named types are sorted.
//
// Odin has no -ffile-prefix-map either: its DWARF and its source-location
// strings (bounds checks, #caller_location) name every file by its absolute
// path. The repository root becomes /src in both, as -ffile-prefix-map does
// for clang (file_prefix_map), and Odin's own root (base:, core:) becomes
// /odin, so the output does not depend on where either lives; each string's
// length is fixed where it is used. A module that still names either root
// afterwards is an error.

SRC_PREFIX :: "/src"
ODIN_PREFIX :: "/odin"

@(private = "file")
Ir_Func :: struct {
	name:  string,
	lines: [dynamic]string, // its "; Function Attrs" comment, if any, first
	decl:  bool,
}

@(private = "file")
Ir_Module :: struct {
	path:    string,
	stem:    string,
	header:  [dynamic]string,
	types:   [dynamic]string,
	globals: [dynamic]string,
	funcs:   [dynamic]Ir_Func,
	attrs:   [dynamic]string,
	named:   [dynamic]string,
	meta:    [dynamic]string, // the text after "!N = ", indexed by N; "" for none
}

// Canonicalizes the modules of one odin build (one package's IR directory),
// given each file's path and text. Returns the new texts, in the same order.
ir_canonicalize :: proc(paths, texts: []string, root: string) -> (out: []string, ok: bool) {
	mods := make([]Ir_Module, len(paths), context.temp_allocator)
	for p, i in paths {
		mods[i] = ir_parse(p, texts[i]) or_return
	}
	rename_proclits(mods) or_return
	out = make([]string, len(mods), context.temp_allocator)
	roots := [2][2]string{{ll_escape(root), SRC_PREFIX}, {ll_escape(ODIN_ROOT), ODIN_PREFIX}}
	for &m, i in mods {
		canon_module(&m, roots[:]) or_return
		out[i] = emit_module(&m) or_return
		for r in roots {
			if r[0] == r[1] || !strings.contains(out[i], r[0]) {
				continue
			}
			for l in strings.split_lines(out[i], context.temp_allocator) {
				if strings.contains(l, r[0]) {
					fmt.eprintfln("build: %s still names %s after scrub_ir:\n  %.200s", m.path, r[0], l)
					break
				}
			}
			return nil, false
		}
	}
	return out, true
}

@(private = "file")
ir_parse :: proc(path, text: string) -> (m: Ir_Module, ok: bool) {
	m.path = path
	base := path[strings.last_index_byte(path, '/') + 1:]
	m.stem = strings.trim_suffix(base, ".ll")
	m.header = make([dynamic]string, context.temp_allocator)
	m.types = make([dynamic]string, context.temp_allocator)
	m.globals = make([dynamic]string, context.temp_allocator)
	m.funcs = make([dynamic]Ir_Func, context.temp_allocator)
	m.attrs = make([dynamic]string, context.temp_allocator)
	m.named = make([dynamic]string, context.temp_allocator)
	m.meta = make([dynamic]string, context.temp_allocator)
	lines := strings.split_lines(text, context.temp_allocator)
	comments := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(lines); i += 1 {
		l := lines[i]
		switch {
		case strings.has_prefix(l, "define "), strings.has_prefix(l, "declare "):
			f := Ir_Func {
				lines = make([dynamic]string, context.temp_allocator),
				decl  = l[2] == 'c',
			}
			append(&f.lines, ..comments[:])
			clear(&comments)
			append(&f.lines, l)
			for !f.decl && lines[i] != "}" {
				i += 1
				if i == len(lines) {
					fmt.eprintfln("build: %s: a procedure has no end: %.200s", path, l)
					return m, false
				}
				append(&f.lines, lines[i])
			}
			name, _, _, found := next_global(l, 0)
			if !found {
				fmt.eprintfln("build: %s: a procedure has no name: %.200s", path, l)
				return m, false
			}
			f.name = name
			append(&m.funcs, f)
		case strings.has_prefix(l, "; Function Attrs"):
			append(&comments, l)
		case strings.has_prefix(l, "attributes #"):
			append(&m.attrs, l)
		case len(l) > 1 && l[0] == '!' && is_digit(l[1]):
			eq := strings.index(l, " = ")
			n, nok := strconv.parse_int(l[1:max(eq, 1)], 10)
			if eq < 0 || !nok || n < 0 {
				fmt.eprintfln("build: %s: cannot read metadata: %.200s", path, l)
				return m, false
			}
			for len(m.meta) <= n {
				append(&m.meta, "")
			}
			m.meta[n] = l[eq + 3:]
		case strings.has_prefix(l, "!"):
			append(&m.named, l)
		case strings.has_prefix(l, "@"):
			append(&m.globals, l)
		case strings.has_prefix(l, "%"):
			append(&m.types, l)
		case l == "":
		case strings.has_prefix(l, "; ModuleID"), strings.has_prefix(l, "source_filename"), strings.has_prefix(l, "target "):
			append(&m.header, l)
		case:
			fmt.eprintfln("build: %s: scrub_ir does not know this line: %.200s", path, l)
			return m, false
		}
	}
	if len(comments) > 0 {
		fmt.eprintfln("build: %s: a comment belongs to no procedure: %s", path, comments[0])
		return m, false
	}
	return m, true
}

// Procedure literals are named _proclit$anon-N from one counter for the whole
// build, so they are renamed in every module at once, in the order of their
// defining module, file, line and body.
@(private = "file")
PROCLIT :: "_proclit$anon-"

@(private = "file")
rename_proclits :: proc(mods: []Ir_Module) -> bool {
	Lit :: struct {
		old: int,
		key: string,
	}
	lits := make([dynamic]Lit, context.temp_allocator)
	for &m in mods {
		for f in m.funcs {
			if f.decl {
				continue
			}
			name := strings.trim(f.name, `"`)
			if !strings.has_prefix(name, PROCLIT) {
				continue
			}
			n, nok := strconv.parse_int(name[len(PROCLIT):], 10)
			if !nok {
				continue
			}
			def := f.lines[len(f.lines) - 1]
			for l in f.lines {
				if strings.has_prefix(l, "define ") {
					def = l
				}
			}
			// Its DISubprogram's file and line, then its body without numbers.
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "%s\x00", m.stem)
			if sp, has := meta_ref_after(def, "!dbg "); has && sp < len(m.meta) {
				if file, fok := field_ref(m.meta[sp], "file"); fok && file < len(m.meta) {
					strings.write_string(&b, m.meta[file])
				}
				line, _ := field_int(m.meta[sp], "line")
				fmt.sbprintf(&b, "\x00%010d\x00", line)
			}
			for l in f.lines {
				for c in transmute([]u8)l {
					if !is_digit(c) {
						strings.write_byte(&b, c)
					}
				}
				strings.write_byte(&b, '\n')
			}
			append(&lits, Lit{n, strings.to_string(b)})
		}
	}
	if len(lits) == 0 {
		return true
	}
	slice.sort_by(lits[:], proc(a, b: Lit) -> bool {return a.key < b.key})
	renamed := make(map[int]int, allocator = context.temp_allocator)
	for l, i in lits {
		if l.old in renamed {
			fmt.eprintfln("build: %s%d is defined twice", PROCLIT, l.old)
			return false
		}
		renamed[l.old] = i
	}
	for &m in mods {
		for &l in m.globals {
			l = rename_proclit_refs(l, renamed) or_return
		}
		for &f in m.funcs {
			for &l in f.lines {
				l = rename_proclit_refs(l, renamed) or_return
			}
			name, _, _, _ := next_global(f.lines[len(f.lines) - 1] if f.decl else first_define(f.lines[:]), 0)
			f.name = name
		}
		for &l in m.meta {
			l = rename_proclit_refs(l, renamed) or_return
		}
	}
	return true
}

@(private = "file")
first_define :: proc(lines: []string) -> string {
	for l in lines {
		if strings.has_prefix(l, "define ") {
			return l
		}
	}
	return ""
}

@(private = "file")
rename_proclit_refs :: proc(s: string, renamed: map[int]int) -> (string, bool) {
	if !strings.contains(s, PROCLIT) {
		return s, true
	}
	b := strings.builder_make(context.temp_allocator)
	rest := s
	for {
		i := strings.index(rest, PROCLIT)
		if i < 0 {
			break
		}
		strings.write_string(&b, rest[:i + len(PROCLIT)])
		rest = rest[i + len(PROCLIT):]
		n := 0
		for n < len(rest) && is_digit(rest[n]) {
			n += 1
		}
		if n == 0 {
			continue
		}
		old, _ := strconv.parse_int(rest[:n], 10)
		k, found := renamed[old]
		if !found {
			fmt.eprintfln("build: %s%d is used but defined nowhere", PROCLIT, old)
			return s, false
		}
		fmt.sbprintf(&b, "%d", k)
		rest = rest[n:]
	}
	strings.write_string(&b, rest)
	return strings.to_string(b), true
}

@(private = "file")
canon_module :: proc(m: ^Ir_Module, roots: [][2]string) -> bool {
	provide_libcalls(m)
	slice.sort_by(m.funcs[:], proc(a, b: Ir_Func) -> bool {
		if a.decl != b.decl {
			return !a.decl
		}
		return a.name < b.name
	})
	slice.sort(m.types[:])
	rename_numbered_globals(m) or_return
	for r in roots {
		map_root_in_strings(m, r[0], r[1]) or_return
	}
	fix_instance_lines(m) or_return
	sort_unit_lists(m) or_return
	return true
}

// LLVM 22's loop-idiom pass turns a loop that looks for a NUL byte into a
// call to strlen, and Odin runs it at -o:speed whatever the target: it has no
// -fno-builtin, and its freestanding runtime defines memset, memcpy and
// memmove (which LLVM also calls) but not strlen. A module that calls strlen
// without defining it gets a weak definition here, a plain byte loop, which
// llc leaves alone (loop idioms are recognized in Odin's passes, not llc's).
// A real strlen (musl's, beside the Odin back end in libc.a) still wins.
@(private = "file")
STRLEN :: []string {
	"define weak hidden i64 @strlen(ptr %s) nounwind {",
	"entry:",
	"  br label %loop",
	"loop:",
	"  %n = phi i64 [ 0, %entry ], [ %next, %loop ]",
	"  %p = getelementptr inbounds i8, ptr %s, i64 %n",
	"  %c = load i8, ptr %p, align 1",
	"  %next = add i64 %n, 1",
	"  %end = icmp eq i8 %c, 0",
	"  br i1 %end, label %done, label %loop",
	"done:",
	"  ret i64 %n",
	"}",
}

@(private = "file")
provide_libcalls :: proc(m: ^Ir_Module) {
	for &f in m.funcs {
		if f.decl && f.name == "strlen" && strings.has_prefix(f.lines[len(f.lines) - 1], "declare i64 @strlen(ptr") {
			f.decl = false
			clear(&f.lines)
			append(&f.lines, ..STRLEN)
		}
	}
}

// Globals that Odin names from a counter: string constants (csbs$pkg$N, N in
// hex) and procedure-local statics (name-.local-N).
@(private = "file")
numbered_prefix :: proc(name: string) -> (prefix: string, is_static, ok: bool) {
	if strings.has_prefix(name, "csbs$") {
		d := strings.last_index_byte(name, '$')
		if d <= 4 || d == len(name) - 1 {
			return
		}
		for c in transmute([]u8)name[d + 1:] {
			if !is_digit(c) && (c < 'a' || c > 'f') {
				return
			}
		}
		return name[:d + 1], false, true
	}
	dash := strings.last_index_byte(name, '-')
	if dash <= 0 || dash == len(name) - 1 || !strings.contains(name[:dash], "-.") {
		return
	}
	for c in transmute([]u8)name[dash + 1:] {
		if !is_digit(c) {
			return
		}
	}
	return name[:dash + 1], true, true
}

@(private = "file")
rename_numbered_globals :: proc(m: ^Ir_Module) -> bool {
	defs := make(map[string]int, allocator = context.temp_allocator) // name -> index in globals
	for g, i in m.globals {
		name, _, _, _ := next_global(g, 0)
		if _, _, num := numbered_prefix(name); num {
			defs[name] = i
		}
	}
	if len(defs) == 0 {
		return true
	}
	renamed := make(map[string]string, allocator = context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator) // old names, as renamed
	per_prefix := make(map[string]int, allocator = context.temp_allocator)
	statics := 0
	note :: proc(defs: map[string]int, renamed: ^map[string]string, order: ^[dynamic]string, per_prefix: ^map[string]int, statics: ^int, line: string, skip_own: bool) {
		for i := 0; true; {
			name, start, end, found := next_global(line, i)
			if !found {
				break
			}
			i = end
			if skip_own && start == 0 {
				continue
			}
			if name not_in defs || name in renamed^ {
				continue
			}
			prefix, is_static, _ := numbered_prefix(name)
			if is_static {
				renamed^[name] = fmt.tprintf("%s%d", prefix, statics^)
				statics^ += 1
			} else {
				k := per_prefix^[prefix]
				renamed^[name] = fmt.tprintf("%s%x", prefix, k)
				per_prefix^[prefix] = k + 1
			}
			append(order, name)
		}
	}
	// First use in the procedures, then in the other globals, then in the
	// numbered globals as they are reached; the unused last, by content.
	for f in m.funcs {
		for l in f.lines {
			note(defs, &renamed, &order, &per_prefix, &statics, l, false)
		}
	}
	for g in m.globals {
		name, _, _, _ := next_global(g, 0)
		if name not_in defs {
			note(defs, &renamed, &order, &per_prefix, &statics, g, true)
		}
	}
	for i := 0; i < len(order); i += 1 {
		note(defs, &renamed, &order, &per_prefix, &statics, m.globals[defs[order[i]]], true)
	}
	if len(order) < len(defs) {
		unused := make([dynamic]string, context.temp_allocator)
		for name in defs {
			if name not_in renamed {
				append(&unused, name)
			}
		}
		Ctx :: struct {
			m:    ^Ir_Module,
			defs: map[string]int,
		}
		ctx := Ctx{m, defs}
		context.user_ptr = &ctx
		slice.sort_by(unused[:], proc(a, b: string) -> bool {
			c := (^Ctx)(context.user_ptr)
			ga := c.m.globals[c.defs[a]]
			gb := c.m.globals[c.defs[b]]
			ka := ga[strings.index(ga, " = "):]
			kb := gb[strings.index(gb, " = "):]
			return ka < kb if ka != kb else a < b
		})
		for name in unused {
			note(defs, &renamed, &order, &per_prefix, &statics, fmt.tprintf(`@"%s"`, name), false)
		}
	}

	for &f in m.funcs {
		for &l in f.lines {
			l = rename_globals(l, renamed)
		}
	}
	others := make([dynamic]string, context.temp_allocator)
	for g in m.globals {
		name, _, _, _ := next_global(g, 0)
		if name not_in defs {
			append(&others, rename_globals(g, renamed))
		}
	}
	for name in order {
		append(&others, rename_globals(m.globals[defs[name]], renamed))
	}
	m.globals = others
	for &l in m.meta {
		if strings.contains(l, "@") {
			l = rename_globals(l, renamed)
		}
	}
	return true
}

@(private = "file")
rename_globals :: proc(s: string, renamed: map[string]string) -> string {
	if strings.index_byte(s, '@') < 0 {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	last := 0
	for i := 0; true; {
		name, start, end, found := next_global(s, i)
		if !found {
			break
		}
		i = end
		if n, has := renamed[name]; has {
			strings.write_string(&b, s[last:start])
			fmt.sbprintf(&b, `@"%s"`, n)
			last = end
		}
	}
	strings.write_string(&b, s[last:])
	return strings.to_string(b)
}

// The next global reference (@name or @"name") in s at or after i, outside
// quoted strings: its name, without quotes, and where its token starts and
// ends.
@(private = "file")
next_global :: proc(s: string, from: int) -> (name: string, start, end: int, ok: bool) {
	for i := from; i < len(s); {
		c := s[i]
		if c == '"' {
			j := strings.index_byte(s[i + 1:], '"')
			i = len(s) if j < 0 else i + j + 2
			continue
		}
		if c != '@' || i + 1 == len(s) {
			i += 1
			continue
		}
		if s[i + 1] == '"' {
			j := strings.index_byte(s[i + 2:], '"')
			if j < 0 {
				return "", 0, 0, false
			}
			return s[i + 2:][:j], i, i + 2 + j + 1, true
		}
		j := i + 1
		for j < len(s) && (is_word(s[j]) || s[j] == '-') {
			j += 1
		}
		if j > i + 1 {
			return s[i + 1:j], i, j, true
		}
		i += 1
	}
	return "", 0, 0, false
}

// A root, as prefix, in the IR's strings: in metadata (DIFile directories), and in the
// string constants Odin's source-code locations point at, whose lengths are
// fixed where they are used.
@(private = "file")
map_root_in_strings :: proc(m: ^Ir_Module, root_esc, prefix: string) -> bool {
	if root_esc == prefix {
		return true
	}
	delta := ll_unescaped_len(root_esc) - len(prefix)
	mapped := make(map[string]int, allocator = context.temp_allocator) // name -> old length, NUL excluded
	needle := fmt.tprintf(`c"%s`, root_esc)
	for &g in m.globals {
		at := strings.index(g, needle)
		if at < 0 {
			continue
		}
		after := g[at + len(needle):]
		if !strings.has_prefix(after, "/") && !strings.has_prefix(after, `\00"`) {
			continue
		}
		name, _, _, _ := next_global(g, 0)
		// `[N x i8] c"` just before.
		head := g[:at]
		if !strings.has_suffix(head, " x i8] ") {
			fmt.eprintfln("build: %s: cannot map the root in %s", m.path, name)
			return false
		}
		open := strings.last_index_byte(head, '[')
		n, nok := 0, false
		if open >= 0 {
			n, nok = strconv.parse_int(head[open + 1:len(head) - len(" x i8] ")], 10)
		}
		if !nok || n <= delta {
			fmt.eprintfln("build: %s: cannot read %s's length", m.path, name)
			return false
		}
		mapped[name] = n - 1
		g = fmt.tprintf("%s[%d x i8] c\"%s%s", head[:open], n - delta, prefix, after)
	}
	if len(mapped) > 0 {
		for &f in m.funcs {
			for &l in f.lines {
				l = fix_lengths(m.path, l, mapped, delta, false) or_return
			}
		}
		for &g in m.globals {
			g = fix_lengths(m.path, g, mapped, delta, true) or_return
		}
	}
	slash := fmt.tprintf(`"%s/`, root_esc)
	whole := fmt.tprintf(`"%s"`, root_esc)
	for &l in m.meta {
		if strings.contains(l, root_esc) {
			l, _ = strings.replace_all(l, slash, fmt.tprintf(`"%s/`, prefix), context.temp_allocator)
			l, _ = strings.replace_all(l, whole, fmt.tprintf(`"%s"`, prefix), context.temp_allocator)
		}
	}
	return true
}

// A mapped string's uses carry its length beside its address: as the second
// field of a string ({ ptr @s, i64 N }) or of the [2 x i64] Odin passes one as.
@(private = "file")
fix_lengths :: proc(path, s: string, mapped: map[string]int, delta: int, skip_own: bool) -> (string, bool) {
	b: strings.Builder
	changed := false
	last := 0
	for i := 0; true; {
		name, start, end, found := next_global(s, i)
		if !found {
			break
		}
		i = end
		old, is_mapped := mapped[name]
		if !is_mapped || (skip_own && start == 0) {
			continue
		}
		rest := s[end:]
		n := fmt.tprintf("%d", old)
		matched := ""
		for form in ([]string{" to i64), i64 ", ", i64 "}) {
			if strings.has_prefix(rest, form) && strings.has_prefix(rest[len(form):], n) {
				after := rest[len(form) + len(n):]
				if len(after) == 0 || !is_digit(after[0]) {
					matched = form
					break
				}
			}
		}
		if matched == "" {
			fmt.eprintfln("build: %s: cannot find the length of %s, which names the root, in:\n  %.300s", path, name, s)
			return s, false
		}
		if !changed {
			b = strings.builder_make(context.temp_allocator)
			changed = true
		}
		strings.write_string(&b, s[last:end])
		fmt.sbprintf(&b, "%s%d", matched, old - delta)
		last = end + len(matched) + len(n)
		i = last
	}
	if !changed {
		return s, true
	}
	strings.write_string(&b, s[last:])
	return strings.to_string(b), true
}

// A polymorphic instance (named with its signature, `pkg::name:proc...`)
// gets the line of its first parameter, which is the generic's declaration,
// or failing that the first line its code is located at.
@(private = "file")
fix_instance_lines :: proc(m: ^Ir_Module) -> bool {
	arg_line := make(map[int]int, allocator = context.temp_allocator)
	loc_line := make(map[int]int, allocator = context.temp_allocator)
	for t in m.meta {
		is_var := strings.has_prefix(t, "!DILocalVariable(") || strings.has_prefix(t, "distinct !DILocalVariable(")
		is_loc := strings.has_prefix(t, "!DILocation(") || strings.has_prefix(t, "distinct !DILocation(")
		if !is_var && !is_loc {
			continue
		}
		scope, sok := field_ref(t, "scope")
		line, lok := field_int(t, "line")
		if !sok || !lok || line <= 0 {
			continue
		}
		if is_var {
			if _, arg := field_int(t, "arg"); !arg {
				continue
			}
			if old, seen := arg_line[scope]; !seen || line < old {
				arg_line[scope] = line
			}
		} else if !strings.contains(t, "inlinedAt:") {
			if old, seen := loc_line[scope]; !seen || line < old {
				loc_line[scope] = line
			}
		}
	}
	for &t, k in m.meta {
		if !strings.contains(t, "!DISubprogram(") {
			continue
		}
		name_at := strings.index(t, `name: "`)
		if name_at < 0 {
			continue
		}
		name := t[name_at + len(`name: "`):]
		name = name[:max(strings.index_byte(name, '"'), 0)]
		if !strings.contains(name, ":proc") {
			continue
		}
		line, found := arg_line[k]
		if !found {
			line, found = loc_line[k]
		}
		if !found {
			continue
		}
		t = set_field_int(t, "line", line)
		t = set_field_int(t, "scopeLine", line)
	}
	return true
}

// The compile unit's lists (its global constants above all) follow the
// checker's order: sort them by their elements' content.
@(private = "file")
sort_unit_lists :: proc(m: ^Ir_Module) -> bool {
	Elem :: struct {
		text: string,
		key:  string,
	}
	for t in m.meta {
		if !strings.contains(t, "!DICompileUnit(") {
			continue
		}
		for fld in ([]string{"enums", "retainedTypes", "globals", "imports"}) {
			list, lok := field_ref(t, fld)
			if !lok || list >= len(m.meta) {
				continue
			}
			lt := m.meta[list]
			if !strings.has_prefix(lt, "!{") || !strings.has_suffix(lt, "}") {
				fmt.eprintfln("build: %s: the compile unit's %s is not a list: %.200s", m.path, fld, lt)
				return false
			}
			elems := make([dynamic]Elem, context.temp_allocator)
			inner := lt[2:len(lt) - 1]
			for e in strings.split_iterator(&inner, ", ") {
				if e == "" {
					continue
				}
				key := e
				if len(e) > 1 && e[0] == '!' && is_digit(e[1]) {
					n, _ := strconv.parse_int(e[1:], 10)
					key = meta_key(m, n, 0)
				}
				append(&elems, Elem{e, key})
			}
			slice.stable_sort_by(elems[:], proc(a, b: Elem) -> bool {return a.key < b.key})
			b := strings.builder_make(context.temp_allocator)
			strings.write_string(&b, "!{")
			for e, i in elems {
				if i > 0 {
					strings.write_string(&b, ", ")
				}
				strings.write_string(&b, e.text)
			}
			strings.write_string(&b, "}")
			m.meta[list] = strings.to_string(b)
		}
	}
	return true
}

// A metadata node's text with its references expanded, a few levels deep:
// a key that does not depend on the numbering.
@(private = "file")
meta_key :: proc(m: ^Ir_Module, n, depth: int) -> string {
	if n >= len(m.meta) {
		return ""
	}
	t := m.meta[n]
	b := strings.builder_make(context.temp_allocator)
	last := 0
	for i := 0; true; {
		r, found := next_ref(t, &i, '!')
		if !found {
			break
		}
		strings.write_string(&b, t[last:r.start])
		if depth < 3 {
			fmt.sbprintf(&b, "(%s)", meta_key(m, r.n, depth + 1))
		} else {
			strings.write_string(&b, "!")
		}
		last = r.end
	}
	strings.write_string(&b, t[last:])
	return strings.to_string(b)
}

@(private = "file")
emit_module :: proc(m: ^Ir_Module) -> (text: string, ok: bool) {
	// Metadata by first use: named metadata, globals, then procedures, each
	// node before the nodes it refers to (depth first).
	mmap := make([]int, len(m.meta), context.temp_allocator)
	slice.fill(mmap, -1)
	next := 0
	stack := make([dynamic]int, context.temp_allocator)
	visit_line :: proc(m: ^Ir_Module, mmap: []int, next: ^int, stack: ^[dynamic]int, line: string) -> bool {
		for i := 0; true; {
			r, found := next_ref(line, &i, '!')
			if !found {
				return true
			}
			append(stack, r.n)
			for len(stack) > 0 {
				x := pop(stack)
				if x >= len(m.meta) || m.meta[x] == "" {
					fmt.eprintfln("build: %s: !%d is used but not defined", m.path, x)
					return false
				}
				if mmap[x] >= 0 {
					continue
				}
				mmap[x] = next^
				next^ += 1
				t := m.meta[x]
				at := len(stack)
				for j := 0; true; {
					sub, sfound := next_ref(t, &j, '!')
					if !sfound {
						break
					}
					if sub.n >= len(mmap) || mmap[sub.n] < 0 {
						append(stack, sub.n)
					}
				}
				slice.reverse(stack[at:])
			}
		}
		return true
	}
	for l in m.named {
		visit_line(m, mmap, &next, &stack, l) or_return
	}
	for l in m.globals {
		visit_line(m, mmap, &next, &stack, l) or_return
	}
	for f in m.funcs {
		for l in f.lines {
			visit_line(m, mmap, &next, &stack, l) or_return
		}
	}
	for t, k in m.meta {
		if t != "" && mmap[k] < 0 {
			fmt.eprintfln("build: %s: !%d is defined but not used", m.path, k)
			return "", false
		}
	}

	// Attribute groups by first use.
	nattr := 0
	for a in m.attrs {
		n, _ := strconv.parse_int(a[len("attributes #"):][:max(strings.index_byte(a[len("attributes #"):], ' '), 0)], 10)
		nattr = max(nattr, n + 1)
	}
	amap := make([]int, nattr, context.temp_allocator)
	slice.fill(amap, -1)
	anext := 0
	for f in m.funcs {
		for l in f.lines {
			if strings.has_prefix(l, ";") {
				continue
			}
			for i := 0; true; {
				r, found := next_ref(l, &i, '#')
				if !found {
					break
				}
				if r.n >= nattr {
					fmt.eprintfln("build: %s: attribute group #%d is used but not defined", m.path, r.n)
					return "", false
				}
				if amap[r.n] < 0 {
					amap[r.n] = anext
					anext += 1
				}
			}
		}
	}
	for &x in amap {
		if x < 0 {
			x = anext
			anext += 1
		}
	}

	b := strings.builder_make(context.temp_allocator)
	line :: proc(b: ^strings.Builder, s: string) {
		strings.write_string(b, s)
		strings.write_byte(b, '\n')
	}
	for l in m.header {
		line(&b, l)
	}
	line(&b, "")
	if len(m.types) > 0 {
		for l in m.types {
			line(&b, l)
		}
		line(&b, "")
	}
	for l in m.globals {
		line(&b, subst_refs(subst_refs(l, '!', mmap), '#', amap))
	}
	line(&b, "")
	for f in m.funcs {
		for l in f.lines {
			line(&b, strings.has_prefix(l, ";") ? l : subst_refs(subst_refs(l, '!', mmap), '#', amap))
		}
		line(&b, "")
	}
	attrs := make([]string, len(m.attrs), context.temp_allocator)
	for a, i in m.attrs {
		attrs[i] = subst_refs(a, '#', amap)
	}
	slice.sort_by(attrs, proc(a, b: string) -> bool {
		na, _ := strconv.parse_int(a[len("attributes #"):][:max(strings.index_byte(a[len("attributes #"):], ' '), 0)], 10)
		nb, _ := strconv.parse_int(b[len("attributes #"):][:max(strings.index_byte(b[len("attributes #"):], ' '), 0)], 10)
		return na < nb
	})
	for a in attrs {
		line(&b, a)
	}
	line(&b, "")
	for l in m.named {
		line(&b, subst_refs(l, '!', mmap))
	}
	line(&b, "")
	inv := make([]int, next, context.temp_allocator)
	for nn, k in mmap {
		if nn >= 0 {
			inv[nn] = k
		}
	}
	for k, nn in inv {
		fmt.sbprintf(&b, "!%d = %s\n", nn, subst_refs(m.meta[k], '!', mmap))
	}
	return strings.to_string(b), true
}

@(private = "file")
Ref :: struct {
	start, end, n: int,
}

// The next reference to a numbered node (!12, #3) in s at or after i^,
// outside quoted strings.
@(private = "file")
next_ref :: proc(s: string, i: ^int, sigil: u8) -> (r: Ref, ok: bool) {
	for i^ < len(s) {
		c := s[i^]
		if c == '"' {
			j := strings.index_byte(s[i^ + 1:], '"')
			i^ = len(s) if j < 0 else i^ + j + 2
			continue
		}
		if c == sigil && i^ + 1 < len(s) && is_digit(s[i^ + 1]) && (i^ == 0 || !is_word(s[i^ - 1])) {
			r.start = i^
			i^ += 1
			for i^ < len(s) && is_digit(s[i^]) {
				r.n = r.n * 10 + int(s[i^] - '0')
				i^ += 1
			}
			r.end = i^
			return r, true
		}
		i^ += 1
	}
	return {}, false
}

@(private = "file")
subst_refs :: proc(s: string, sigil: u8, to: []int) -> string {
	if strings.index_byte(s, sigil) < 0 {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	last := 0
	for i := 0; true; {
		r, found := next_ref(s, &i, sigil)
		if !found {
			break
		}
		strings.write_string(&b, s[last:r.start])
		fmt.sbprintf(&b, "%c%d", rune(sigil), to[r.n] if r.n < len(to) else r.n)
		last = r.end
	}
	strings.write_string(&b, s[last:])
	return strings.to_string(b)
}

// The number after `prefix!` in s (as in "!dbg !12").
@(private = "file")
meta_ref_after :: proc(s, prefix: string) -> (int, bool) {
	at := strings.index(s, fmt.tprintf("%s!", prefix))
	if at < 0 {
		return 0, false
	}
	i := at + len(prefix)
	r, ok := next_ref(s, &i, '!')
	return r.n, ok
}

// A metadata field's position: "name: " after "(" or ", ".
@(private = "file")
field_at :: proc(t, name: string) -> int {
	for sep in ([]string{"(", ", "}) {
		key := fmt.tprintf("%s%s: ", sep, name)
		if at := strings.index(t, key); at >= 0 {
			return at + len(key)
		}
	}
	return -1
}

@(private = "file")
field_ref :: proc(t, name: string) -> (int, bool) {
	at := field_at(t, name)
	if at < 0 || !strings.has_prefix(t[at:], "!") {
		return 0, false
	}
	i := at
	r, ok := next_ref(t, &i, '!')
	return r.n, ok && r.start == at
}

@(private = "file")
field_int :: proc(t, name: string) -> (int, bool) {
	at := field_at(t, name)
	if at < 0 {
		return 0, false
	}
	n := 0
	for n < len(t) - at && is_digit(t[at + n]) {
		n += 1
	}
	v, ok := strconv.parse_int(t[at:at + n], 10)
	return v, ok && n > 0
}

@(private = "file")
set_field_int :: proc(t, name: string, v: int) -> string {
	at := field_at(t, name)
	if at < 0 {
		return t
	}
	n := 0
	for n < len(t) - at && is_digit(t[at + n]) {
		n += 1
	}
	return fmt.tprintf("%s%d%s", t[:at], v, t[at + n:])
}

@(private = "file")
is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_word :: proc(c: u8) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '.' || c == '$'
}

// s as LLVM writes it inside a quoted string.
@(private = "file")
ll_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		if c >= 0x20 && c < 0x7f && c != '"' && c != '\\' {
			strings.write_byte(&b, c)
		} else {
			fmt.sbprintf(&b, "\\%02X", c)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
ll_unescaped_len :: proc(s: string) -> int {
	return len(s) - 2 * strings.count(s, "\\")
}
