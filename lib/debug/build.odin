// The index builder: a vxdi index from an ELF image's DWARF and symbol table
// (ADR-0017).
//
// Two passes over the compilation units: the first counts what each table
// will hold and the bytes of its strings and expressions, then the index is
// allocated whole, and the second fills it. Type references are kept as DIE
// offsets while filling and become type numbers at the end, as a type may be
// referred to before it is defined. DIEs are walked with an explicit stack,
// never recursively.
//
// DWARF 5 units are read as upstream reads them. DWARF 4 units (Odin's,
// through LLVM; docs/PLAN.md P4) differ in their header, their line table's
// header, their location lists (.debug_loc) and range lists
// (.debug_ranges), and in numbering files from 1: file 0, the unit's own
// source, is made from the unit's name, so files are numbered alike. In them
// a DIE without a name takes it, and its type and declaration, from its
// DW_AT_abstract_origin: LLVM names the out-of-line copy of a procedure it
// also inlined, and that copy's parameters, only there. (One image may hold
// both: Odin's units are DWARF 4, those of the assembly beside it DWARF 5.)
package debug

import "base:intrinsics"

@(private = "file")
Die :: struct {
	name:           Maybe(string),
	comp_dir:       Maybe(string),
	has_low:        bool,
	high_is_len:    bool,
	declaration:    bool,
	has_location:   bool,
	has_const:      bool,
	has_frame_base: bool,
	has_ranges:     bool,
	low, high:      u64,
	type_die:       u64,
	byte_size:      u64,
	encoding:       u64,
	count:          u64,
	decl_file:      u64,
	decl_line:      u64,
	member_offset:  u64,
	stmt_list:      u64,
	const_value:    i64,
	location:       Val,
	frame_base:     Val,
	ranges:         Val,
	name_val:       Val,
	comp_dir_val:   Val,
	origin:         u64, // DW_AT_abstract_origin: a DIE's offset in .debug_info, or 0
	low_val:        Val,
	high_val:       Val,
}

// Where a member is, from its DW_AT_data_member_location: a constant, or
// (older producers) DW_OP_plus_uconst N.
@(private = "file")
member_offset :: proc "contextless" (v: ^Val) -> u64 {
	block, ok := v.block.?
	if !ok {
		return v.u
	}
	c := Cursor{data = block}
	if fixed(&c, 1) == u64(Dw_Op.Plus_Uconst) {
		return uleb(&c)
	}
	return 0
}

@(private = "file")
read_attrs :: proc "contextless" (b: ^Builder, c: ^Cursor, a: ^Abbrev) -> (d: Die) {
	for i: u32 = 0; i < a.count && !c.bad; i += 1 {
		s := &b.specs[a.first + i]
		v := read_val(c, &b.unit, s.form, s.implicit)
		#partial switch s.name {
		case .Name:
			d.name_val = v
		case .Comp_Dir:
			d.comp_dir_val = v
		case .Abstract_Origin:
			d.origin = is_ref(v.form) ? b.unit.start + v.u : v.u
		case .Low_Pc:
			d.has_low = true
			d.low_val = v // resolved below, once the bases are known
		case .High_Pc:
			d.high_val = v
			d.high_is_len = v.form != .Addr && !is_addrx(v.form) // a length, from low_pc
		case .Type:
			d.type_die = is_ref(v.form) ? b.unit.start + v.u : v.u
		case .Byte_Size:
			d.byte_size = v.u
		case .Encoding:
			d.encoding = v.u
		case .Count:
			d.count = v.u
		case .Upper_Bound:
			if d.count == 0 {
				d.count = v.u + 1
			}
		case .Decl_File:
			d.decl_file = v.u
		case .Decl_Line:
			d.decl_line = v.u
		case .Declaration:
			d.declaration = v.u != 0
		case .Data_Member_Location:
			d.member_offset = member_offset(&v)
		case .Const_Value:
			d.has_const = true
			d.const_value = v.s != 0 ? v.s : i64(v.u)
		case .Location:
			d.has_location = true
			d.location = v
		case .Frame_Base:
			d.has_frame_base = true
			d.frame_base = v
		case .Ranges:
			d.has_ranges = true
			d.ranges = v
		case .Stmt_List:
			d.stmt_list = v.u
		case .Str_Offsets_Base:
			b.unit.str_offsets_base = v.u
		case .Addr_Base:
			b.unit.addr_base = v.u
		case .Rnglists_Base:
			b.unit.rnglists_base = v.u
		case .Loclists_Base:
			b.unit.loclists_base = v.u
		}
	}
	// Now the unit's bases are known: low_pc as an address, high_pc after it.
	if d.has_low {
		d.low = attr_address(b, &d.low_val)
	}
	if d.high_val.form != .None {
		d.high = d.high_is_len ? d.low + d.high_val.u : attr_address(b, &d.high_val)
	}
	d.name = attr_string(b, &d.name_val)
	d.comp_dir = attr_string(b, &d.comp_dir_val)
	if b.unit.version == 4 && d.origin != 0 {
		from_origin(b, &d)
	}
	return d
}

// What a DWARF 4 DIE leaves to its DW_AT_abstract_origin: the out-of-line
// copy of a function LLVM also inlined, and its parameters and locals, name
// themselves only there. Their name, type and declaration are taken from it,
// one level, in the same unit. (DWARF 5 units are read as upstream reads
// them, which leaves such functions nameless.)
@(private = "file")
from_origin :: proc "contextless" (b: ^Builder, d: ^Die) {
	if d.origin < b.unit.start || d.origin >= b.unit.end {
		return
	}
	c := Cursor {
		data = b.elf.sec[.Info][:b.unit.end],
		pos  = int(d.origin),
	}
	a, found := abbrev_of(b, uleb(&c))
	if !found {
		return
	}
	name_val: Val
	type_die, decl_file, decl_line: Maybe(u64)
	for i: u32 = 0; i < a.count && !c.bad; i += 1 {
		s := &b.specs[a.first + i]
		v := read_val(&c, &b.unit, s.form, s.implicit)
		#partial switch s.name {
		case .Name:
			name_val = v
		case .Type:
			type_die = is_ref(v.form) ? b.unit.start + v.u : v.u
		case .Decl_File:
			decl_file = v.u
		case .Decl_Line:
			decl_line = v.u
		}
	}
	if c.bad {
		return
	}
	if d.name == nil {
		d.name = attr_string(b, &name_val)
	}
	if t, ok := type_die.?; ok && d.type_die == 0 {
		d.type_die = t
	}
	if f, ok := decl_file.?; ok && d.decl_file == 0 {
		d.decl_file = f
	}
	if l, ok := decl_line.?; ok && d.decl_line == 0 {
		d.decl_line = l
	}
}

@(private = "file")
Scope_Kind :: enum u8 {
	None,
	Func,
	Block,
	Type,
	Skip, // inside something whose children are not listed
}

@(private = "file")
Scope :: struct {
	kind:       Scope_Kind,
	type:       u64, // Type: its index
	scope_low:  u64,
	scope_high: u64,
}

@(private = "file")
type_kind_of :: proc "contextless" (tag: Dw_Tag) -> Type_Kind {
	#partial switch tag {
	case .Base_Type:
		return .Base
	case .Pointer_Type:
		return .Pointer
	case .Const_Type:
		return .Const
	case .Volatile_Type:
		return .Volatile
	case .Restrict_Type:
		return .Restrict
	case .Atomic_Type:
		return .Atomic
	case .Typedef:
		return .Typedef
	case .Structure_Type:
		return .Struct
	case .Union_Type:
		return .Union
	case .Array_Type:
		return .Array
	case .Enumeration_Type:
		return .Enum
	case .Subroutine_Type:
		return .Func
	}
	return .Void
}

// A type reference while building: a DIE offset + 1, truncated as the
// index's 32-bit field keeps it; 0 for none.
@(private = "file")
type_ref :: proc "contextless" (die: u64) -> Type_Index {
	return Type_Index(u32(die + 1))
}

// A variable or parameter: in a function (its scope the innermost block), or
// at the unit's top, a global.
@(private = "file")
emit_var :: proc "contextless" (b: ^Builder, d: ^Die, kind: Var_Kind, scope: ^Scope) {
	if !d.has_location && !d.has_const {
		return
	}
	v := Var {
		name = emit_str(b, d.name),
		type = type_ref(d.type_die),
		kind = kind,
	}
	if scope != nil && scope.kind == .Block {
		v.scope_low, v.scope_high = scope.scope_low, scope.scope_high
	}
	if d.has_const {
		v.flags = {.Const}
		v.value = d.const_value
	} else if d.location.form == .Exprloc || d.location.block != nil {
		v.loc, v.loc_len = emit_expr(b, d.location.block)
	} else { 	// a location list
		v.flags = {.Loclist}
		v.loc = emit_loclist(b, &d.location)
	}
	if b.fill && b.count[.Vars] < u64(len(b.vars)) {
		b.vars[b.count[.Vars]] = v
	}
	b.count[.Vars] += 1
}

// The variables a function lists so far, as its var_count.
@(private = "file")
end_func :: proc "contextless" (b: ^Builder, func: u64) {
	if b.fill && func < u64(len(b.funcs)) {
		b.funcs[func].var_count = u32(b.count[.Vars] - u64(b.funcs[func].first_var))
	}
}

@(private = "file")
die_tree :: proc "contextless" (b: ^Builder, c: ^Cursor) {
	stack: [MAX_DEPTH]Scope
	depth := 0
	func := -1 // the function whose variables are being listed
	for c.pos < len(c.data) && !c.bad {
		die_off := u64(c.pos)
		code := uleb(c)
		if code == 0 { 	// the end of a list of children
			if depth == 0 {
				break
			}
			depth -= 1
			if stack[depth].kind == .Func && func >= 0 {
				end_func(b, u64(func))
				func = -1
			}
			continue
		}
		a, found := abbrev_of(b, code)
		if !found {
			c.bad = true
			break
		}
		d := read_attrs(b, c, a)
		parent: ^Scope = depth > 0 ? &stack[depth - 1] : nil
		me := Scope {
			kind = parent != nil && parent.kind == .Skip ? .Skip : .None,
		}
		in_func := func >= 0 && parent != nil && (parent.kind == .Func || parent.kind == .Block)
		tk := type_kind_of(a.tag)
		switch {
		case me.kind == .Skip:
		// inside something whose children are not listed
		case a.tag == .Compile_Unit:
			b.unit.low_pc = d.low
			read_lines(b, d.stmt_list, d.comp_dir, d.name)
		case a.tag == .Subprogram:
			if d.has_ranges && !d.has_low {
				d.low, d.high = range_bounds(b, &d.ranges)
				d.has_low = d.low < d.high
			}
			if d.has_low && !d.declaration && d.low < d.high && func < 0 {
				func = int(b.count[.Funcs])
				f := Func {
					low       = d.low,
					high      = d.high,
					body      = d.low,
					name      = emit_str(b, d.name),
					file      = d.decl_file < u64(b.unit.file_count) ? File_Index(b.unit.file_base + u32(d.decl_file)) : 0,
					line      = u32(d.decl_line),
					type      = type_ref(d.type_die),
					first_var = u32(b.count[.Vars]),
				}
				if fb, ok := d.frame_base.block.?; d.has_frame_base && ok {
					f.frame_base, f.frame_base_len = emit_expr(b, fb)
				}
				if b.fill && b.count[.Funcs] < u64(len(b.funcs)) {
					b.funcs[b.count[.Funcs]] = f
				}
				b.count[.Funcs] += 1
				me.kind = .Func
			} else {
				me.kind = .Skip // a declaration, or nested: its parameters are not variables of a function
			}
		case a.tag == .Lexical_Block && in_func:
			me.kind = .Block
			if d.has_ranges {
				d.low, d.high = range_bounds(b, &d.ranges)
			}
			me.scope_low, me.scope_high = d.low, d.high
		case a.tag == .Inlined_Subroutine:
			me.kind = .Skip // its variables are the inlined function's (not yet listed)
		case (a.tag == .Formal_Parameter || a.tag == .Variable) && in_func:
			emit_var(b, &d, a.tag == .Formal_Parameter ? .Param : .Local, parent)
		case a.tag == .Variable && depth == 1 && !d.declaration:
			emit_var(b, &d, .Global, nil)
		case tk != .Void:
			t := b.count[.Types]
			name := emit_str(b, d.name)
			if b.fill && t < u64(len(b.types)) && t < u64(len(b.type_dies)) {
				b.type_dies[t] = die_off
				b.types[t] = Type {
					kind     = tk,
					name     = name,
					size     = d.byte_size,
					target   = type_ref(d.type_die),
					first    = u32(b.count[.Members]),
					encoding = Encoding(u32(d.encoding)),
				}
			}
			me.kind = .Type
			me.type = t
			b.count[.Types] += 1
		case (a.tag == .Member || a.tag == .Enumerator) && parent != nil && parent.kind == .Type:
			m := Member {
				name   = emit_str(b, d.name),
				type   = type_ref(d.type_die),
				offset = a.tag == .Member ? i64(d.member_offset) : d.const_value,
			}
			if b.fill && b.count[.Members] < u64(len(b.members)) && parent.type < u64(len(b.types)) {
				b.members[b.count[.Members]] = m
				b.types[parent.type].count += 1
			}
			b.count[.Members] += 1
		case a.tag == .Subrange_Type && parent != nil && parent.kind == .Type && b.fill:
			if parent.type < u64(len(b.types)) {
				t := &b.types[parent.type]
				if t.kind == .Array && t.count == 0 {
					t.count = u32(d.count) // the first dimension
				}
			}
		}
		if a.children {
			if depth == MAX_DEPTH {
				c.bad = true
				break
			}
			if me.kind == .None && parent != nil && (parent.kind == .Func || parent.kind == .Block) {
				me = parent^
				me.kind = .Skip // a type or the like inside a function: its children are not variables
			}
			stack[depth] = me
			depth += 1
		} else if me.kind == .Func { 	// a function with no children: no variables
			if b.fill && u64(func) < u64(len(b.funcs)) {
				b.funcs[func].var_count = 0
			}
			func = -1
		}
	}
}

@(private = "file")
DW_UT_COMPILE :: 1
@(private = "file")
DW_UT_PARTIAL :: 3

@(private = "file")
read_units :: proc "contextless" (b: ^Builder) {
	info := b.elf.sec[.Info]
	c := Cursor{data = info}
	for c.pos < len(c.data) && !c.bad {
		start := u64(c.pos)
		length := fixed(&c, 4)
		if length >= 0xffff_fff0 || length > u64(len(c.data) - c.pos) {
			break // DWARF64 is not read
		}
		next := c.pos + int(length)
		u := Cursor{data = info[:next], pos = c.pos}
		version := u16(fixed(&u, 2))
		unit_type, addr_size, abbrev_off: u64
		switch version {
		case 5:
			unit_type = fixed(&u, 1)
			addr_size = fixed(&u, 1)
			abbrev_off = fixed(&u, 4)
		case 4: 	// a compile unit: DWARF 4 keeps type units elsewhere
			abbrev_off = fixed(&u, 4)
			addr_size = fixed(&u, 1)
			unit_type = DW_UT_COMPILE
		}
		c.pos = next
		if (version != 5 && version != 4) || (unit_type != DW_UT_COMPILE && unit_type != DW_UT_PARTIAL) || (addr_size != 8 && addr_size != 4) || u.bad {
			continue
		}
		b.unit = Unit {
			start     = start,
			end       = u64(next),
			version   = version,
			addr_size = u8(addr_size),
		}
		if !read_abbrevs(b, abbrev_off) {
			continue
		}
		die_tree(b, &u)
	}
}

@(private = "file")
STT_OBJECT :: 1
@(private = "file")
STT_FUNC :: 2

@(private = "file")
read_symbols :: proc "contextless" (b: ^Builder) {
	sym, str := b.elf.sec[.Symtab], b.elf.sec[.Strtab]
	for at := 0; at + size_of(Elf_Sym) <= len(sym); at += size_of(Elf_Sym) {
		s := load(sym[at:], Elf_Sym)
		type := s.info & 15
		if (type != STT_OBJECT && type != STT_FUNC) || s.value == 0 || s.shndx == 0 {
			continue // defined objects and functions
		}
		name := emit_str(b, maybe_cstr(str, u64(s.name)))
		if b.fill && b.count[.Syms] < u64(len(b.syms)) {
			b.syms[b.count[.Syms]] = Sym {
				addr = u64(s.value),
				size = u64(s.size),
				name = name,
				func = type == STT_FUNC,
			}
		}
		b.count[.Syms] += 1
	}
}

// --- Sorting (a heap sort: in place, no recursion, and upstream's, so equal
// keys end in the same order) ---

@(private = "file")
heap_sort :: proc "contextless" (a: []$T, cmp: proc "contextless" (x, y: ^T) -> int) {
	n := len(a)
	for start := n / 2; n > 1; {
		root: int
		if start > 0 {
			start -= 1
			root = start
		} else {
			n -= 1
			a[0], a[n] = a[n], a[0]
			root = 0
		}
		for child := 2 * root + 1; child < n; child = 2 * root + 1 {
			if child + 1 < n && cmp(&a[child], &a[child + 1]) < 0 {
				child += 1
			}
			if cmp(&a[root], &a[child]) >= 0 {
				break
			}
			a[root], a[child] = a[child], a[root]
			root = child
		}
	}
}

@(private = "file")
compare_u64 :: #force_inline proc "contextless" (x, y: u64) -> int {
	return int(x > y) - int(x < y)
}

@(private = "file")
by_func_low :: proc "contextless" (x, y: ^Func) -> int {
	return compare_u64(x.low, y.low)
}

// By address, and a sequence's end before the next one starting there.
@(private = "file")
by_line_addr :: proc "contextless" (x, y: ^Line) -> int {
	if x.addr != y.addr {
		return compare_u64(x.addr, y.addr)
	}
	return int(.End in y.flags) - int(.End in x.flags)
}

@(private = "file")
by_sym_addr :: proc "contextless" (x, y: ^Sym) -> int {
	return compare_u64(x.addr, y.addr)
}

// A type reference (a DIE offset + 1, or 0) as a type number (0: void, or unknown).
@(private = "file")
type_index :: proc "contextless" (b: ^Builder, ref: Type_Index) -> Type_Index {
	if ref == 0 {
		return 0
	}
	die := u64(u32(ref) - 1)
	dies := b.type_dies[:b.count[.Types]]
	lo, hi := 0, len(dies)
	for lo < hi {
		mid := (lo + hi) / 2
		if dies[mid] < die {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(dies) && dies[lo] == die ? Type_Index(lo + 1) : 0 // +1: type 0 is void
}

// Where each function's body starts: its first row marked prologue_end, else
// its second statement row, else its start. lines sorted as the index keeps
// them. Not private: tests/host/debug calls it on rows of its own (upstream's
// debug_test.c calls its func_bodies).
func_bodies :: proc "contextless" (funcs: []Func, lines: []Line) {
	for &f in funcs {
		lo, hi := 0, len(lines)
		for lo < hi {
			mid := (lo + hi) / 2
			if lines[mid].addr < f.low {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		second: u64
		stmts := 0
		for l in lines[lo:] {
			if l.addr >= f.high {
				break
			}
			// An End at the function's first address ends the sequence
			// before it, which the sort puts first: not this one's (the Rust
			// port's finding, its DWARF 5 on aarch64; upstream's 5c1bbc9).
			if .End in l.flags && l.addr == f.low {
				continue
			}
			if .End in l.flags {
				break
			}
			if .Prologue_End in l.flags {
				f.body = l.addr
				second = 0
				break
			}
			if .Stmt in l.flags && l.addr > f.low {
				stmts += 1
				if stmts == 1 {
					second = l.addr
				}
			}
		}
		if second != 0 {
			f.body = second
		}
	}
}

@(private = "file")
align8 :: #force_inline proc "contextless" (v: u64) -> u64 {
	return (v + 7) &~ 7
}

// The typed view of a table in an index buffer of len(buf) bytes (open checks
// that it lies inside; the builder lays it out so).
@(private)
table_view :: proc "contextless" (buf: []u8, t: Table, $T: typeid) -> []T {
	bytes := buf[t.off:][:t.count * size_of(T)]
	return ([^]T)(raw_data(bytes))[:t.count]
}

// Builds the index of elf in arena: the index's bytes (its header first), or
// false if the arena is too small (it needs a few times the DWARF's size).
@(require_results)
build_index :: proc "contextless" (elf: ^Elf, arena: ^Arena) -> (index: []u8, ok: bool) {
	b := Builder {
		elf = elf,
	}
	b.abbrevs = arena_alloc(arena, Abbrev, MAX_ABBREVS) or_return
	b.specs = arena_alloc(arena, Spec, MAX_SPECS) or_return
	b.count[.Strings] = 1 // offset 0: the empty string
	read_units(&b)
	read_symbols(&b)
	counted := b.count
	type_dies, have_dies := arena_alloc(arena, u64, counted[.Types] + 1)
	// The index, whole: its tables one after another, each 8-aligned.
	layout := Header {
		version      = INDEX_VERSION,
		machine      = elf.machine,
		build_id_len = u32(len(elf.build_id)),
	}
	at := align8(size_of(Header))
	for &t, k in layout.tables {
		n := counted[k]
		if k == .Types {
			n += 1 // type 0, void
		}
		bytes, overflow := intrinsics.overflow_mul(n, TABLE_ENTRY_SIZE[k])
		t = Table {
			off   = at,
			count = n,
		}
		next, overflow2 := intrinsics.overflow_add(at, bytes)
		if overflow || overflow2 || next > max(u64) - 7 {
			return nil, false
		}
		at = align8(next)
	}
	layout.size = at
	if !have_dies {
		return nil, false
	}
	out := arena_alloc(arena, u8, at) or_return
	b.type_dies = type_dies
	h := (^Header)(raw_data(out))
	h^ = layout
	copy(h.magic[:], INDEX_MAGIC)
	copy(h.build_id[:], elf.build_id[:])
	b.funcs = table_view(out, layout.tables[.Funcs], Func)
	b.lines = table_view(out, layout.tables[.Lines], Line)
	b.vars = table_view(out, layout.tables[.Vars], Var)
	b.types = table_view(out, layout.tables[.Types], Type)[1:] // type 0, void, stays zero
	b.members = table_view(out, layout.tables[.Members], Member)
	b.syms = table_view(out, layout.tables[.Syms], Sym)
	b.files = table_view(out, layout.tables[.Files], Name)
	b.strings = table_view(out, layout.tables[.Strings], u8)
	b.exprs = table_view(out, layout.tables[.Exprs], u8)
	// The second pass, filling it.
	b.fill = true
	b.count = {}
	b.count[.Strings] = 1
	read_units(&b)
	read_symbols(&b)
	if b.count != counted {
		return nil, false // the passes disagree: a bug, not bad input
	}
	// Type references, from DIE offsets to type numbers.
	for &t in b.types {
		t.target = type_index(&b, t.target)
	}
	for &m in b.members {
		m.type = type_index(&b, m.type)
	}
	for &v in b.vars {
		v.type = type_index(&b, v.type)
	}
	for &f in b.funcs {
		f.type = type_index(&b, f.type)
	}
	for &t in b.types { 	// members' and enumerators' numbers start at 1 in the index too
		if t.kind != .Struct && t.kind != .Union && t.kind != .Enum {
			t.first = 0
		}
	}
	heap_sort(b.funcs, by_func_low)
	heap_sort(b.lines, by_line_addr)
	heap_sort(b.syms, by_sym_addr)
	func_bodies(b.funcs, b.lines)
	return out, true
}
