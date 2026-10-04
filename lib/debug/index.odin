// Questions answered from a vxdi index (ADR-0017): what function and line an
// address is in, where a function or a line is, what variables a function
// has at a pc, and what their types are. An index read from a file is checked
// whole when it is opened, and every query checks each number it follows, so
// a damaged index answers wrongly but never reads outside itself.
package debug

// Opens an index (built, or read from a file into an 8-aligned buffer):
// false if it is not one, of this version, or a table lies outside it.
@(require_results)
open :: proc "contextless" (buf: []u8) -> (ix: Index, ok: bool) {
	if len(buf) < size_of(Header) || uintptr(raw_data(buf)) & 7 != 0 {
		return {}, false
	}
	h := (^Header)(raw_data(buf))
	if string(h.magic[:]) != INDEX_MAGIC || h.version != INDEX_VERSION || h.size > u64(len(buf)) {
		return {}, false
	}
	for t, k in h.tables {
		if t.off & 7 != 0 || t.off > h.size || t.count > (h.size - t.off) / TABLE_ENTRY_SIZE[k] {
			return {}, false
		}
	}
	strings := h.tables[.Strings]
	if h.tables[.Types].count == 0 || strings.count == 0 || buf[strings.off + strings.count - 1] != 0 {
		return {}, false
	}
	return Index {
			header = h,
			funcs = table_view(buf, h.tables[.Funcs], Func),
			lines = table_view(buf, h.tables[.Lines], Line),
			vars = table_view(buf, h.tables[.Vars], Var),
			types = table_view(buf, h.tables[.Types], Type),
			members = table_view(buf, h.tables[.Members], Member),
			syms = table_view(buf, h.tables[.Syms], Sym),
			files = table_view(buf, h.tables[.Files], Name),
			strings = table_view(buf, strings, u8),
			exprs = table_view(buf, h.tables[.Exprs], u8),
		},
		true
}

// A string of the index ("" for one out of range).
str :: proc "contextless" (ix: ^Index, name: Name) -> string {
	if u64(name) >= u64(len(ix.strings)) {
		return ""
	}
	s, _ := cstr(ix.strings, u64(name)) // the table ends with a NUL (open)
	return s
}

// A file's path ("" for one out of range).
file :: proc "contextless" (ix: ^Index, f: File_Index) -> string {
	if u64(f) >= u64(len(ix.files)) {
		return ""
	}
	return str(ix, ix.files[f])
}

// A type (void for one out of range).
type_of :: proc "contextless" (ix: ^Index, t: Type_Index) -> ^Type {
	if u64(t) < u64(len(ix.types)) {
		return &ix.types[t]
	}
	return &ix.types[0]
}

// How many of items, sorted by key, have their key at or before pc: the
// last such is items[n - 1].
@(private = "file")
count_upto :: proc "contextless" (items: []$T, pc: u64, key: proc "contextless" (x: ^T) -> u64) -> int {
	lo, hi := 0, len(items)
	for lo < hi {
		mid := (lo + hi) / 2
		if key(&items[mid]) <= pc {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The function pc is in.
@(require_results)
func_at :: proc "contextless" (ix: ^Index, pc: u64) -> (f: ^Func, ok: bool) {
	i := count_upto(ix.funcs, pc, proc "contextless" (f: ^Func) -> u64 {return f.low})
	if i > 0 && pc < ix.funcs[i - 1].high {
		return &ix.funcs[i - 1], true
	}
	return nil, false
}

// The ELF symbol pc is in (for code with no DWARF, such as musl's).
@(require_results)
sym_at :: proc "contextless" (ix: ^Index, pc: u64) -> (s: ^Sym, ok: bool) {
	i := count_upto(ix.syms, pc, proc "contextless" (s: ^Sym) -> u64 {return s.addr})
	if i == 0 {
		return nil, false
	}
	s = &ix.syms[i - 1]
	if pc < s.addr + (s.size != 0 ? s.size : 1) {
		return s, true
	}
	return nil, false
}

// The line row pc is in: the last row at or before it, unless that ends a sequence.
@(require_results)
line_at :: proc "contextless" (ix: ^Index, pc: u64) -> (l: ^Line, ok: bool) {
	i := count_upto(ix.lines, pc, proc "contextless" (l: ^Line) -> u64 {return l.addr})
	if i == 0 || .End in ix.lines[i - 1].flags {
		return nil, false
	}
	return &ix.lines[i - 1], true
}

// The function named name.
@(require_results)
func_named :: proc "contextless" (ix: ^Index, name: string) -> (f: ^Func, ok: bool) {
	for &x in ix.funcs {
		if str(ix, x.name) == name {
			return &x, true
		}
	}
	return nil, false
}

// Whether path ends with the path suffix, at a component boundary.
path_ends :: proc "contextless" (path, suffix: string) -> bool {
	if len(suffix) > len(path) || path[len(path) - len(suffix):] != suffix {
		return false
	}
	return len(suffix) == len(path) || path[len(path) - len(suffix) - 1] == '/'
}

// The lowest address of a statement on `line` of a file whose path ends with
// `file`. An address of 0 is never a statement's in a linked program, and is
// passed over, as upstream's 0 meant none.
@(require_results)
line_addr :: proc "contextless" (ix: ^Index, file_suffix: string, line: u32) -> (addr: u64, ok: bool) {
	for &l in ix.lines {
		if l.line != line || .Stmt not_in l.flags || .End in l.flags {
			continue
		}
		if (addr == 0 || l.addr < addr) && path_ends(file(ix, l.file), file_suffix) {
			addr = l.addr
		}
	}
	return addr, addr != 0
}

// The global (or constant) named name.
@(require_results)
global_named :: proc "contextless" (ix: ^Index, name: string) -> (v: ^Var, ok: bool) {
	for &x in ix.vars {
		if x.kind == .Global && str(ix, x.name) == name {
			return &x, true
		}
	}
	return nil, false
}

// The variable of f (which may be nil) named name in scope at pc: the
// innermost block's first.
@(require_results)
local_named :: proc "contextless" (ix: ^Index, f: ^Func, pc: u64, name: string) -> (v: ^Var, ok: bool) {
	if f == nil {
		return nil, false
	}
	best: ^Var
	for i: u32 = 0; i < f.var_count && u64(f.first_var + i) < u64(len(ix.vars)); i += 1 {
		x := &ix.vars[f.first_var + i]
		in_scope := x.scope_high == 0 || (pc >= x.scope_low && pc < x.scope_high)
		if !in_scope || str(ix, x.name) != name {
			continue
		}
		if best == nil || (x.scope_high != 0 && (best.scope_high == 0 || x.scope_high - x.scope_low < best.scope_high - best.scope_low)) {
			best = x
		}
	}
	return best, best != nil
}

// A type with its typedefs and qualifiers looked through, and its number
// (void, 0, if they go round for ever).
resolve :: proc "contextless" (ix: ^Index, t: Type_Index) -> (^Type, Type_Index) {
	n := t
	for _ in 0 ..< 32 {
		x := type_of(ix, n)
		#partial switch x.kind {
		case .Typedef, .Const, .Volatile, .Restrict, .Atomic:
			n = x.target
		case:
			return x, n
		}
	}
	return &ix.types[0], 0
}

// The named type (a typedef, a base type, or a struct, union or enum tag).
@(require_results)
type_named :: proc "contextless" (ix: ^Index, name: string) -> (t: Type_Index, ok: bool) {
	for i in 1 ..< len(ix.types) {
		if ix.types[i].name != 0 && str(ix, ix.types[i].name) == name {
			return Type_Index(i), true
		}
	}
	return 0, false
}

// A variable's location expression at pc (from its list, if it has one);
// false if none applies.
@(require_results)
var_location :: proc "contextless" (ix: ^Index, v: ^Var, pc: u64) -> (expr: []u8, ok: bool) {
	if .Const in v.flags {
		return nil, false
	}
	n := u64(len(ix.exprs))
	if .Loclist not_in v.flags {
		if u64(v.loc) > n || u64(v.loc_len) > n - u64(v.loc) {
			return nil, false
		}
		expr = ix.exprs[v.loc:][:v.loc_len]
		return expr, len(expr) > 0
	}
	for at := u64(v.loc); at + 20 <= n; {
		entry := ix.exprs[at:]
		lo, hi, length := load(entry, u64), load(entry[8:], u64), u64(load(entry[16:], u32))
		if lo == 0 && hi == 0 && length == 0 {
			return nil, false
		}
		if length > n - at - 20 {
			return nil, false
		}
		if pc >= lo && pc < hi {
			expr = entry[20:][:length]
			return expr, length > 0
		}
		at += 20 + length
	}
	return nil, false
}
