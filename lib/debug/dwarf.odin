// Reading DWARF for the index builder (build.odin): the constants it uses, a
// bounded cursor, attribute forms, expressions, location and range lists, and
// line tables, in DWARF 5 (clang's) and DWARF 4 (Odin's, through LLVM).
//
// Every read goes through a Cursor over a section, or a part of one: a read
// past its end marks the cursor bad and returns nothing, and every later read
// from it fails too, so a bad offset ends what was being read, not the
// program.
package debug

// --- The DWARF constants it uses ---

Dw_Tag :: enum u16 {
	Array_Type         = 0x01,
	Enumeration_Type   = 0x04,
	Formal_Parameter   = 0x05,
	Lexical_Block      = 0x0b,
	Member             = 0x0d,
	Pointer_Type       = 0x0f,
	Compile_Unit       = 0x11,
	Structure_Type     = 0x13,
	Subroutine_Type    = 0x15,
	Typedef            = 0x16,
	Union_Type         = 0x17,
	Inlined_Subroutine = 0x1d,
	Subrange_Type      = 0x21,
	Base_Type          = 0x24,
	Const_Type         = 0x26,
	Enumerator         = 0x28,
	Subprogram         = 0x2e,
	Variable           = 0x34,
	Volatile_Type      = 0x35,
	Restrict_Type      = 0x37,
	Atomic_Type        = 0x47,
}

Dw_At :: enum u16 {
	Location             = 0x02,
	Name                 = 0x03,
	Byte_Size            = 0x0b,
	Stmt_List            = 0x10,
	Low_Pc               = 0x11,
	High_Pc              = 0x12,
	Comp_Dir             = 0x1b,
	Const_Value          = 0x1c,
	Upper_Bound          = 0x2f,
	Abstract_Origin      = 0x31,
	Count                = 0x37,
	Data_Member_Location = 0x38,
	Decl_File            = 0x3a,
	Decl_Line            = 0x3b,
	Declaration          = 0x3c,
	Encoding             = 0x3e,
	Frame_Base           = 0x40,
	Type                 = 0x49,
	Ranges               = 0x55,
	Str_Offsets_Base     = 0x72,
	Addr_Base            = 0x73,
	Rnglists_Base        = 0x74,
	Loclists_Base        = 0x8c,
}

Dw_Form :: enum u16 {
	None           = 0x00,
	Addr           = 0x01,
	Block2         = 0x03,
	Block4         = 0x04,
	Data2          = 0x05,
	Data4          = 0x06,
	Data8          = 0x07,
	String         = 0x08,
	Block          = 0x09,
	Block1         = 0x0a,
	Data1          = 0x0b,
	Flag           = 0x0c,
	Sdata          = 0x0d,
	Strp           = 0x0e,
	Udata          = 0x0f,
	Ref_Addr       = 0x10,
	Ref1           = 0x11,
	Ref2           = 0x12,
	Ref4           = 0x13,
	Ref8           = 0x14,
	Ref_Udata      = 0x15,
	Indirect       = 0x16,
	Sec_Offset     = 0x17,
	Exprloc        = 0x18,
	Flag_Present   = 0x19,
	Strx           = 0x1a,
	Addrx          = 0x1b,
	Ref_Sup4       = 0x1c,
	Strp_Sup       = 0x1d,
	Data16         = 0x1e,
	Line_Strp      = 0x1f,
	Ref_Sig8       = 0x20,
	Implicit_Const = 0x21,
	Loclistx       = 0x22,
	Rnglistx       = 0x23,
	Ref_Sup8       = 0x24,
	Strx1          = 0x25,
	Strx2          = 0x26,
	Strx3          = 0x27,
	Strx4          = 0x28,
	Addrx1         = 0x29,
	Addrx2         = 0x2a,
	Addrx3         = 0x2b,
	Addrx4         = 0x2c,
}

// DWARF expression operations. The ranges lit0-31, reg0-31 and breg0-31 are
// named by their ends.
Dw_Op :: enum u8 {
	Addr                = 0x03,
	Deref               = 0x06,
	Const1u             = 0x08,
	Const1s             = 0x09,
	Const2u             = 0x0a,
	Const2s             = 0x0b,
	Const4u             = 0x0c,
	Const4s             = 0x0d,
	Const8u             = 0x0e,
	Const8s             = 0x0f,
	Constu              = 0x10,
	Consts              = 0x11,
	Dup                 = 0x12,
	Drop                = 0x13,
	Over                = 0x14,
	Pick                = 0x15,
	Swap                = 0x16,
	And                 = 0x1a,
	Minus               = 0x1c,
	Mul                 = 0x1e,
	Neg                 = 0x1f,
	Not                 = 0x20,
	Or                  = 0x21,
	Plus                = 0x22,
	Plus_Uconst         = 0x23,
	Shl                 = 0x24,
	Shr                 = 0x25,
	Xor                 = 0x27,
	Bra                 = 0x28,
	Skip                = 0x2f,
	Lit0                = 0x30,
	Lit31               = 0x4f,
	Reg0                = 0x50,
	Reg31               = 0x6f,
	Breg0               = 0x70,
	Breg31              = 0x8f,
	Regx                = 0x90,
	Fbreg               = 0x91,
	Bregx               = 0x92,
	Piece               = 0x93,
	Deref_Size          = 0x94,
	Xderef_Size         = 0x95,
	Nop                 = 0x96,
	Call2               = 0x98,
	Call4               = 0x99,
	Call_Ref            = 0x9a,
	Form_Tls_Address    = 0x9b,
	Call_Frame_Cfa      = 0x9c,
	Bit_Piece           = 0x9d,
	Implicit_Value      = 0x9e,
	Stack_Value         = 0x9f,
	Implicit_Pointer    = 0xa0,
	Addrx               = 0xa1,
	Constx              = 0xa2,
	Entry_Value         = 0xa3,
	Const_Type          = 0xa4,
	Regval_Type         = 0xa5,
	Deref_Type          = 0xa6,
	Xderef_Type         = 0xa7,
	Convert             = 0xa8,
	Reinterpret         = 0xa9,
	Gnu_Entry_Value     = 0xf3, // LLVM's, in DWARF 4
}

@(private)
Lns :: enum u8 {
	Extended           = 0,
	Copy               = 1,
	Advance_Pc         = 2,
	Advance_Line       = 3,
	Set_File           = 4,
	Set_Column         = 5,
	Negate_Stmt        = 6,
	Set_Basic_Block    = 7,
	Const_Add_Pc       = 8,
	Fixed_Advance_Pc   = 9,
	Set_Prologue_End   = 10,
	Set_Epilogue_Begin = 11,
	Set_Isa            = 12,
}

@(private)
Lne :: enum u8 {
	End_Sequence = 1,
	Set_Address  = 2,
}

@(private)
Lnct :: enum u64 {
	Path            = 1,
	Directory_Index = 2,
}

// DW_LLE_* (DWARF 5 location lists).
@(private)
Lle :: enum u8 {
	End_Of_List      = 0,
	Base_Addressx    = 1,
	Startx_Endx      = 2,
	Startx_Length    = 3,
	Offset_Pair      = 4,
	Default_Location = 5,
	Base_Address     = 6,
	Start_End        = 7,
	Start_Length     = 8,
}

// DW_RLE_* (DWARF 5 range lists).
@(private)
Rle :: enum u8 {
	End_Of_List   = 0,
	Base_Addressx = 1,
	Startx_Endx   = 2,
	Startx_Length = 3,
	Offset_Pair   = 4,
	Base_Address  = 5,
	Start_End     = 6,
	Start_Length  = 7,
}

// --- Reading ---

@(private)
Cursor :: struct {
	data: []u8, // what may be read, from pos
	pos:  int,
	bad:  bool, // a read ran past the end, or found nonsense: every later read fails
}

@(private)
take :: proc "contextless" (c: ^Cursor, n: u64) -> (b: []u8, ok: bool) {
	if c.bad || n > u64(len(c.data) - c.pos) {
		c.bad = true
		c.pos = len(c.data)
		return nil, false
	}
	b = c.data[c.pos:][:n]
	c.pos += int(n)
	return b, true
}

// An n-byte little-endian field: its low 8 bytes if it is wider (a bad
// header's), 0 if it runs past the end.
@(private)
fixed :: proc "contextless" (c: ^Cursor, n: u64) -> u64 {
	b, ok := take(c, n)
	v: u64
	if ok {
		for i in 0 ..< min(n, 8) {
			v |= u64(b[i]) << (8 * i)
		}
	}
	return v
}

@(private)
uleb :: proc "contextless" (c: ^Cursor) -> u64 {
	v: u64
	for shift: u32 = 0;; shift += 7 {
		b, ok := take(c, 1)
		if !ok {
			return 0
		}
		if shift < 64 {
			v |= u64(b[0] & 0x7f) << shift
		}
		if b[0] & 0x80 == 0 {
			return v
		}
	}
}

@(private)
sleb :: proc "contextless" (c: ^Cursor) -> i64 {
	v: u64
	shift: u32
	last: u8
	for {
		b, ok := take(c, 1)
		if !ok {
			return 0
		}
		last = b[0]
		if shift < 64 {
			v |= u64(last & 0x7f) << shift
		}
		shift += 7
		if last & 0x80 == 0 {
			break
		}
	}
	if shift < 64 && last & 0x40 != 0 {
		v |= ~u64(0) << shift
	}
	return i64(v)
}

// A NUL-terminated string at the cursor, without its NUL.
@(private = "file")
read_cstr :: proc "contextless" (c: ^Cursor) -> string {
	if !c.bad {
		for b, i in c.data[c.pos:] {
			if b == 0 {
				s := string(c.data[c.pos:][:i])
				c.pos += i + 1
				return s
			}
		}
	}
	c.bad = true
	c.pos = len(c.data)
	return ""
}

// The cursor at off in sec; a cursor that is bad already if off is past its end.
@(private)
cursor_at :: proc "contextless" (sec: []u8, off: u64) -> Cursor {
	if off > u64(len(sec)) {
		return Cursor{data = sec, pos = len(sec), bad = true}
	}
	return Cursor{data = sec, pos = int(off)}
}

// --- One unit ---

@(private)
MAX_ABBREVS :: 4096
@(private)
MAX_SPECS :: 32768
@(private)
MAX_DEPTH :: 64
@(private)
MAX_FILES :: 512

// An attribute's name and form, in an abbreviation.
@(private)
Spec :: struct {
	name:     Dw_At,
	form:     Dw_Form,
	implicit: i64,
}
// The arena's demand is upstream's: the same arena fits or fails alike.
#assert(size_of(Spec) == 16)

@(private)
Abbrev :: struct {
	code:     u64,
	tag:      Dw_Tag,
	children: bool,
	first:    u32, // its specs
	count:    u32,
}
#assert(size_of(Abbrev) == 24)

@(private)
Unit :: struct {
	start:            u64, // the unit's offset in .debug_info
	end:              u64, // and its end
	version:          u16, // 4 or 5
	addr_size:        u8,
	str_offsets_base: u64,
	addr_base:        u64,
	rnglists_base:    u64,
	loclists_base:    u64,
	low_pc:           u64,
	file_base:        u32, // its line table's files, from file_base in the index's
	file_count:       u32,
}

@(private)
Val :: struct {
	form:  Dw_Form,
	u:     u64,
	s:     i64,
	block: Maybe([]u8), // exprloc, a block, data16, or an inline string (without its NUL)
}

@(private)
Builder :: struct {
	elf:       ^Elf,
	fill:      bool, // the second pass
	// What each table holds (counted in the first pass, filled in the
	// second); .Types does not count type 0, void.
	count:     [Table_Kind]u64,
	funcs:     []Func,
	lines:     []Line,
	vars:      []Var,
	types:     []Type, // from type 1: void stays zero, before it
	members:   []Member,
	syms:      []Sym,
	files:     []Name,
	strings:   []u8,
	exprs:     []u8,
	type_dies: []u64, // each type's DIE offset, in order: what type references become
	abbrevs:   []Abbrev,
	nabbrevs:  u32,
	specs:     []Spec,
	nspecs:    u32,
	unit:      Unit,
	dirs:      [MAX_FILES]Maybe(string), // the line table's directories
}

// A string into the table, dir/s if s is relative to a dir: its offset (0,
// the empty string, for none). Counted in the first pass, written in the
// second.
@(private)
emit_str2 :: proc "contextless" (b: ^Builder, dir: Maybe(string), str: Maybe(string)) -> Name {
	s, ok := str.?
	if !ok {
		return 0
	}
	d := dir.? or_else ""
	if len(d) == 0 && len(s) == 0 {
		return 0
	}
	join := len(d) > 0 && (len(s) == 0 || s[0] != '/')
	at := b.count[.Strings]
	length := u64(len(s)) + (join ? u64(len(d)) + 1 : 0)
	b.count[.Strings] += length + 1
	if !b.fill || at > u64(max(u32)) || at > u64(len(b.strings)) || length + 1 > u64(len(b.strings)) - at {
		return 0 // (a fill that does not fit: the passes disagree, and the index is refused)
	}
	out := b.strings[at:]
	n := 0
	if join {
		n += copy(out, d)
		out[n] = '/'
		n += 1
	}
	n += copy(out[n:], s)
	out[n] = 0
	return Name(at)
}

@(private)
emit_str :: proc "contextless" (b: ^Builder, s: Maybe(string)) -> Name {
	return emit_str2(b, nil, s)
}

// The abbreviations at off in .debug_abbrev; false if they are bad or too many.
@(private)
read_abbrevs :: proc "contextless" (b: ^Builder, off: u64) -> bool {
	sec := b.elf.sec[.Abbrev]
	if off >= u64(len(sec)) {
		return false
	}
	c := cursor_at(sec, off)
	b.nabbrevs, b.nspecs = 0, 0
	for {
		code := uleb(&c)
		if code == 0 || c.bad {
			return !c.bad
		}
		if b.nabbrevs == MAX_ABBREVS {
			return false
		}
		a := &b.abbrevs[b.nabbrevs]
		b.nabbrevs += 1
		a^ = Abbrev{code = code, tag = Dw_Tag(u16(uleb(&c))), first = b.nspecs}
		a.children = fixed(&c, 1) != 0
		for {
			name, form := uleb(&c), uleb(&c)
			if c.bad {
				return false
			}
			if name == 0 && form == 0 {
				break
			}
			if b.nspecs == MAX_SPECS {
				return false
			}
			s := &b.specs[b.nspecs]
			b.nspecs += 1
			s^ = Spec{name = Dw_At(u16(name)), form = Dw_Form(u16(form))}
			if s.form == .Implicit_Const {
				s.implicit = sleb(&c)
			}
			a.count += 1
		}
	}
}

@(private)
abbrev_of :: proc "contextless" (b: ^Builder, code: u64) -> (a: ^Abbrev, ok: bool) {
	if code != 0 && code <= u64(b.nabbrevs) && b.abbrevs[code - 1].code == code {
		return &b.abbrevs[code - 1], true
	}
	for &x in b.abbrevs[:b.nabbrevs] {
		if x.code == code {
			return &x, true
		}
	}
	return nil, false
}

// An attribute's value, as its form has it; strings and indexed addresses are
// resolved later (attr_string, attr_address), once the unit's bases are known.
@(private)
read_val :: proc "contextless" (c: ^Cursor, u: ^Unit, form_in: Dw_Form, implicit: i64) -> (v: Val) {
	form := form_in
	if form == .Indirect {
		form = Dw_Form(u16(uleb(c))) // the form is in the data; never another indirect
	}
	v.form = form
	block :: proc "contextless" (c: ^Cursor, n: u64) -> Maybe([]u8) {
		b, ok := take(c, n)
		return ok ? b : nil
	}
	#partial switch form {
	case .Addr:
		v.u = fixed(c, u64(u.addr_size))
	case .Data1, .Ref1, .Flag, .Strx1, .Addrx1:
		v.u = fixed(c, 1)
	case .Data2, .Ref2, .Strx2, .Addrx2:
		v.u = fixed(c, 2)
	case .Strx3, .Addrx3:
		v.u = fixed(c, 3)
	case .Data4, .Ref4, .Ref_Addr, .Sec_Offset, .Strp, .Line_Strp, .Strx4, .Addrx4, .Ref_Sup4, .Strp_Sup:
		v.u = fixed(c, 4)
	case .Data8, .Ref8, .Ref_Sig8, .Ref_Sup8:
		v.u = fixed(c, 8)
	case .Data16:
		v.block = block(c, 16)
	case .Sdata:
		v.s = sleb(c)
		v.u = u64(v.s)
	case .Udata, .Ref_Udata, .Strx, .Addrx, .Loclistx, .Rnglistx:
		v.u = uleb(c)
	case .Implicit_Const:
		v.s = implicit
		v.u = u64(implicit)
	case .Flag_Present:
		v.u = 1
	case .Exprloc, .Block:
		v.block = block(c, uleb(c))
	case .Block1:
		v.block = block(c, fixed(c, 1))
	case .Block2:
		v.block = block(c, fixed(c, 2))
	case .Block4:
		v.block = block(c, fixed(c, 4))
	case .String:
		start := c.pos
		for c.pos < len(c.data) && c.data[c.pos] != 0 {
			c.pos += 1
		}
		if c.pos == len(c.data) {
			c.bad = true
		}
		v.block = c.data[start:c.pos]
		_, _ = take(c, 1)
	case:
		c.bad = true // a form DWARF 5 does not have
	}
	if c.bad {
		v.block = nil
	}
	return v
}

@(private)
is_ref :: proc "contextless" (form: Dw_Form) -> bool {
	#partial switch form {
	case .Ref1, .Ref2, .Ref4, .Ref8, .Ref_Udata:
		return true
	}
	return false
}

@(private)
is_addrx :: proc "contextless" (form: Dw_Form) -> bool {
	#partial switch form {
	case .Addrx, .Addrx1, .Addrx2, .Addrx3, .Addrx4:
		return true
	}
	return false
}

@(private)
attr_string :: proc "contextless" (b: ^Builder, v: ^Val) -> Maybe(string) {
	sec := &b.elf.sec
	#partial switch v.form {
	case .String:
		if s, ok := v.block.?; ok {
			return string(s)
		}
		return nil
	case .Strp:
		return maybe_cstr(sec[.Str], v.u)
	case .Line_Strp:
		return maybe_cstr(sec[.Line_Str], v.u)
	case .Strx, .Strx1, .Strx2, .Strx3, .Strx4:
		so := sec[.Str_Offsets]
		at := b.unit.str_offsets_base + v.u * 4
		if at > u64(len(so)) || u64(len(so)) - at < 4 {
			return nil
		}
		c := cursor_at(so, at)
		return maybe_cstr(sec[.Str], fixed(&c, 4))
	}
	return nil
}

@(private)
maybe_cstr :: proc "contextless" (sec: []u8, off: u64) -> Maybe(string) {
	if s, ok := cstr(sec, off); ok {
		return s
	}
	return nil
}

// The address an addrx form, or a DW_OP_addrx, names.
@(private)
addr_at :: proc "contextless" (b: ^Builder, index: u64) -> u64 {
	sec := b.elf.sec[.Addr]
	size := u64(b.unit.addr_size)
	at := b.unit.addr_base + index * size
	if at > u64(len(sec)) || u64(len(sec)) - at < size {
		return 0
	}
	c := cursor_at(sec, at)
	return fixed(&c, size)
}

@(private)
attr_address :: proc "contextless" (b: ^Builder, v: ^Val) -> u64 {
	if v.form == .Addr {
		return v.u
	}
	return addr_at(b, v.u) // addrx, addrx1-4
}

// --- Expressions ---

// One operation's operands, skipped, and the operation copied to out at n
// (when out is not nil: the second pass); addrx and constx are rewritten as
// DW_OP_addr. False for an operation it does not know, or that runs past the
// end: the copy stops there.
@(private = "file")
copy_op :: proc "contextless" (b: ^Builder, c: ^Cursor, op_byte: u8, out: []u8, n: ^int) -> bool {
	start := c.pos
	op := Dw_Op(op_byte)
	if op == .Addrx || op == .Constx {
		a := addr_at(b, uleb(c))
		if out != nil && !c.bad && n^ + 9 <= len(out) { 	// a bad one is not counted (emit_expr): nor written
			out[n^] = u8(Dw_Op.Addr)
			for i in 0 ..< 8 {
				out[n^ + 1 + i] = u8(a >> (8 * uint(i)))
			}
		}
		n^ += 9
		return !c.bad
	}
	#partial switch op {
	case .Addr:
		_, _ = take(c, u64(b.unit.addr_size))
	case .Const1u, .Const1s, .Pick, .Deref_Size, .Xderef_Size:
		_, _ = take(c, 1)
	case .Const2u, .Const2s, .Bra, .Skip, .Call2:
		_, _ = take(c, 2)
	case .Const4u, .Const4s, .Call4, .Call_Ref:
		_, _ = take(c, 4)
	case .Const8u, .Const8s:
		_, _ = take(c, 8)
	case .Constu, .Plus_Uconst, .Regx, .Piece, .Convert, .Reinterpret:
		_ = uleb(c)
	case .Consts, .Breg0 ..= .Breg31, .Fbreg:
		_ = sleb(c)
	case .Bregx:
		_ = uleb(c)
		_ = sleb(c)
	case .Bit_Piece, .Regval_Type:
		_ = uleb(c)
		_ = uleb(c)
	case .Implicit_Value, .Entry_Value, .Gnu_Entry_Value:
		_, _ = take(c, uleb(c))
	case .Implicit_Pointer:
		_, _ = take(c, 4)
		_ = sleb(c)
	case .Const_Type:
		_ = uleb(c)
		_, _ = take(c, fixed(c, 1))
	case .Deref_Type, .Xderef_Type:
		_, _ = take(c, 1)
		_ = uleb(c)
	case:
		if op_byte < 0x06 || op_byte > 0x9f || op == .Form_Tls_Address {
			return false // the rest of 0x06-0x9f have no operands
		}
	}
	length := c.pos - start
	if out != nil && !c.bad && n^ + 1 + length <= len(out) {
		out[n^] = op_byte
		copy(out[n^ + 1:], c.data[start:c.pos])
	}
	n^ += 1 + length
	return !c.bad
}

// A DWARF expression into exprs, rewritten to stand alone: its offset and
// length.
@(private)
emit_expr :: proc "contextless" (b: ^Builder, p: Maybe([]u8)) -> (at: u32, length: u32) {
	c := Cursor{data = p.? or_else nil} // a block that ran past its section is empty
	out := 0
	dst: []u8
	if b.fill && b.count[.Exprs] <= u64(len(b.exprs)) {
		dst = b.exprs[b.count[.Exprs]:]
	}
	for c.pos < len(c.data) {
		op := c.data[c.pos]
		c.pos += 1
		before := out
		if !copy_op(b, &c, op, dst, &out) {
			out = before // what it understood
			break
		}
	}
	at = u32(b.count[.Exprs])
	b.count[.Exprs] += u64(out)
	return at, u32(out)
}

@(private = "file")
emit_u64 :: proc "contextless" (b: ^Builder, v: u64, bytes: u64) {
	at := b.count[.Exprs]
	if b.fill && at <= u64(len(b.exprs)) && bytes <= u64(len(b.exprs)) - at {
		for i in 0 ..< bytes {
			b.exprs[at + i] = u8(v >> (8 * i))
		}
	}
	b.count[.Exprs] += bytes
}

// Writes a length emitted as 4 zero bytes at `at`, once it is known.
@(private = "file")
patch_u32 :: proc "contextless" (b: ^Builder, at: u64, v: u32) {
	if b.fill && at <= u64(len(b.exprs)) && 4 <= u64(len(b.exprs)) - at {
		for i in 0 ..< u64(4) {
			b.exprs[at + i] = u8(v >> (8 * i))
		}
	}
}

// The offset a rnglistx or loclistx index names, from the offsets table at base.
@(private = "file")
list_offset :: proc "contextless" (sec: []u8, base: u64, index: u64) -> u64 {
	at := base + index * 4
	if at > u64(len(sec)) || u64(len(sec)) - at < 4 {
		return max(u64)
	}
	c := cursor_at(sec, at)
	return base + fixed(&c, 4)
}

// One entry of the index's form of a location list: lo, hi, the
// expression's length, the expression.
@(private = "file")
emit_entry :: proc "contextless" (b: ^Builder, lo, hi: u64, expr: []u8) {
	emit_u64(b, lo, 8)
	emit_u64(b, hi, 8)
	len_at := b.count[.Exprs]
	emit_u64(b, 0, 4)
	_, elen := emit_expr(b, expr)
	patch_u32(b, len_at, elen)
}

// A location list as the index's: {lo, hi, len, bytes}..., then 0, 0, 0.
// DWARF 5's DW_LLE_* entries from .debug_loclists, or DWARF 4's from
// .debug_loc.
@(private)
emit_loclist :: proc "contextless" (b: ^Builder, v: ^Val) -> u32 {
	at := u32(b.count[.Exprs])
	size := u64(b.unit.addr_size)
	if b.unit.version == 4 {
		// Pairs of addresses from the unit's base; a pair whose first is the
		// largest address sets the base; 0, 0 ends it.
		sec := b.elf.sec[.Loc]
		off := v.u
		if off < u64(len(sec)) {
			c := cursor_at(sec, off)
			base := b.unit.low_pc
			largest := size == 4 ? u64(max(u32)) : max(u64)
			for guard := 0; guard < 4096 && !c.bad; guard += 1 {
				lo, hi := fixed(&c, size), fixed(&c, size)
				if c.bad || (lo == 0 && hi == 0) {
					break
				}
				if lo == largest {
					base = hi
					continue
				}
				expr, ok := take(&c, fixed(&c, 2))
				if !ok {
					break
				}
				emit_entry(b, base + lo, base + hi, expr)
			}
		}
	} else {
		sec := b.elf.sec[.Loclists]
		off := v.form == .Loclistx ? list_offset(sec, b.unit.loclists_base, v.u) : v.u
		if off < u64(len(sec)) {
			c := cursor_at(sec, off)
			base := b.unit.low_pc
			entries: for guard := 0; guard < 4096 && !c.bad; guard += 1 {
				lo, hi: u64
				#partial switch Lle(fixed(&c, 1)) {
				case .Base_Addressx:
					base = addr_at(b, uleb(&c))
					continue
				case .Base_Address:
					base = fixed(&c, size)
					continue
				case .Startx_Endx:
					lo = addr_at(b, uleb(&c))
					hi = addr_at(b, uleb(&c))
				case .Startx_Length:
					lo = addr_at(b, uleb(&c))
					hi = lo + uleb(&c)
				case .Offset_Pair:
					lo = base + uleb(&c)
					hi = base + uleb(&c)
				case .Default_Location:
					lo, hi = 0, max(u64)
				case .Start_End:
					lo = fixed(&c, size)
					hi = fixed(&c, size)
				case .Start_Length:
					lo = fixed(&c, size)
					hi = lo + uleb(&c)
				case:
					break entries // end_of_list, or a kind DWARF 5 does not have
				}
				expr, ok := take(&c, uleb(&c))
				if !ok {
					break
				}
				emit_entry(b, lo, hi, expr)
			}
		}
	}
	emit_u64(b, 0, 8)
	emit_u64(b, 0, 8)
	emit_u64(b, 0, 4)
	return at
}

// The lowest and highest address a range list covers: DWARF 5's DW_RLE_*
// entries from .debug_rnglists, or DWARF 4's pairs from .debug_ranges.
@(private)
range_bounds :: proc "contextless" (b: ^Builder, v: ^Val) -> (low, high: u64) {
	size := u64(b.unit.addr_size)
	low, high = max(u64), 0
	if b.unit.version == 4 {
		sec := b.elf.sec[.Ranges]
		if v.u >= u64(len(sec)) {
			return
		}
		c := cursor_at(sec, v.u)
		base := b.unit.low_pc
		largest := size == 4 ? u64(max(u32)) : max(u64)
		for guard := 0; guard < 4096 && !c.bad; guard += 1 {
			lo, hi := fixed(&c, size), fixed(&c, size)
			if c.bad || (lo == 0 && hi == 0) {
				break
			}
			if lo == largest {
				base = hi
				continue
			}
			low = min(low, base + lo)
			high = max(high, base + hi)
		}
	} else {
		sec := b.elf.sec[.Rnglists]
		off := v.form == .Rnglistx ? list_offset(sec, b.unit.rnglists_base, v.u) : v.u
		if off >= u64(len(sec)) {
			return
		}
		c := cursor_at(sec, off)
		base := b.unit.low_pc
		entries: for guard := 0; guard < 4096 && !c.bad; guard += 1 {
			lo, hi: u64
			#partial switch Rle(fixed(&c, 1)) {
			case .Base_Addressx:
				base = addr_at(b, uleb(&c))
				continue
			case .Base_Address:
				base = fixed(&c, size)
				continue
			case .Startx_Endx:
				lo = addr_at(b, uleb(&c))
				hi = addr_at(b, uleb(&c))
			case .Startx_Length:
				lo = addr_at(b, uleb(&c))
				hi = lo + uleb(&c)
			case .Offset_Pair:
				lo = base + uleb(&c)
				hi = base + uleb(&c)
			case .Start_End:
				lo = fixed(&c, size)
				hi = fixed(&c, size)
			case .Start_Length:
				lo = fixed(&c, size)
				hi = lo + uleb(&c)
			case:
				break entries // end_of_list, or a kind DWARF 5 does not have
			}
			low = min(low, lo)
			high = max(high, hi)
		}
	}
	if low > high {
		low, high = 0, 0
	}
	return
}

// --- The line table ---

// A file's path into the files table: relative to its directory, and a
// relative directory to directory 0, the compilation's.
@(private = "file")
emit_file :: proc "contextless" (b: ^Builder, path: Maybe(string), dir: u64, ndirs: u32) {
	d: Maybe(string)
	if dir < u64(ndirs) {
		d = b.dirs[dir]
	}
	joined: [512]u8
	if ds, ok := d.?; ok && (len(ds) == 0 || ds[0] != '/') && dir > 0 && ndirs > 0 {
		if d0, ok0 := b.dirs[0].?; ok0 && len(d0) + 1 + len(ds) < len(joined) {
			n := copy(joined[:], d0)
			joined[n] = '/'
			n += 1
			n += copy(joined[n:], ds)
			d = string(joined[:n])
		}
	}
	name := emit_str2(b, d, path)
	if b.fill && b.count[.Files] < u64(len(b.files)) {
		b.files[b.count[.Files]] = name
	}
	b.count[.Files] += 1
	b.unit.file_count += 1
}

// A DWARF 5 line table header's directory or file entry formats, then the
// entries: directories into dirs, files into the files table.
@(private = "file")
line_entries_v5 :: proc "contextless" (b: ^Builder, c: ^Cursor, ndirs: ^u32, is_dirs: bool) {
	nformats := fixed(c, 1)
	formats: [16][2]u64
	if nformats > 16 {
		c.bad = true
		return
	}
	for i in 0 ..< nformats {
		formats[i][0] = uleb(c)
		formats[i][1] = uleb(c)
	}
	count := uleb(c)
	for k: u64 = 0; k < count && !c.bad; k += 1 {
		path: Maybe(string)
		dir: u64
		entry := c.pos
		for i in 0 ..< nformats {
			v := read_val(c, &b.unit, Dw_Form(u16(formats[i][1])), 0)
			switch Lnct(formats[i][0]) {
			case .Path:
				path = attr_string(b, &v)
			case .Directory_Index:
				dir = v.u
			}
		}
		if c.pos == entry { 	// an entry of no bytes: a count from a broken header would never end
			c.bad = true
			break
		}
		if is_dirs {
			if ndirs^ < MAX_FILES {
				b.dirs[ndirs^] = path
				ndirs^ += 1
			}
			continue
		}
		emit_file(b, path, dir, ndirs^)
	}
}

// A DWARF 4 line table header's directories and files, each list ended by an
// empty string. Directory 0 is the compilation's and file 0 its primary
// source, which DWARF 4 leaves out and DWARF 5 lists: they come from the
// unit, so files are numbered as DWARF 5 numbers them.
@(private = "file")
line_entries_v4 :: proc "contextless" (b: ^Builder, c: ^Cursor, comp_dir, name: Maybe(string)) {
	b.dirs[0] = comp_dir
	ndirs: u32 = 1
	for !c.bad {
		d := read_cstr(c)
		if c.bad || len(d) == 0 {
			break
		}
		if ndirs < MAX_FILES {
			b.dirs[ndirs] = d
			ndirs += 1
		}
	}
	emit_file(b, name, 0, ndirs)
	for !c.bad {
		path := read_cstr(c)
		if c.bad || len(path) == 0 {
			break
		}
		dir := uleb(c)
		_ = uleb(c) // modification time
		_ = uleb(c) // length
		if c.bad {
			break
		}
		emit_file(b, path, dir, ndirs)
	}
}

@(private = "file")
emit_row :: proc "contextless" (b: ^Builder, addr, file, line: u64, flags: Line_Flags) {
	if b.fill && b.count[.Lines] < u64(len(b.lines)) {
		b.lines[b.count[.Lines]] = Line {
			addr  = addr,
			file  = file < u64(b.unit.file_count) ? File_Index(b.unit.file_base + u32(file)) : 0,
			line  = u32(line),
			flags = flags,
		}
	}
	b.count[.Lines] += 1
}

// The unit's line program at off: its files, then its rows. A DWARF 4 unit's
// files start with its directory and name.
@(private)
read_lines :: proc "contextless" (b: ^Builder, off: u64, comp_dir, name: Maybe(string)) {
	sec := b.elf.sec[.Line]
	b.unit.file_base = u32(b.count[.Files])
	b.unit.file_count = 0
	if off >= u64(len(sec)) {
		return
	}
	c := cursor_at(sec, off)
	unit_len := fixed(&c, 4)
	if unit_len >= 0xffff_fff0 || unit_len > u64(len(c.data) - c.pos) {
		return // DWARF64 is not read
	}
	end := c.pos + int(unit_len)
	c.data = c.data[:end]
	version := fixed(&c, 2)
	addr_size := u64(b.unit.addr_size)
	if b.unit.version == 5 {
		if version != 5 {
			return
		}
		addr_size = fixed(&c, 1)
		_ = fixed(&c, 1) // segment selector size
	} else if version < 2 || version > 4 {
		return
	}
	header_len := fixed(&c, 4)
	if c.bad || header_len > u64(len(c.data) - c.pos) {
		return
	}
	program := c.pos + int(header_len)
	min_inst := fixed(&c, 1)
	if version >= 4 {
		_ = fixed(&c, 1) // maximum operations per instruction: 1 on our machines
	}
	default_stmt := fixed(&c, 1) != 0
	line_base := i8(u8(fixed(&c, 1)))
	line_range := fixed(&c, 1)
	opcode_base := fixed(&c, 1)
	std_lens: [256]u8
	for i in 1 ..< opcode_base {
		std_lens[i] = u8(fixed(&c, 1))
	}
	if version == 5 {
		ndirs: u32
		line_entries_v5(b, &c, &ndirs, true)
		line_entries_v5(b, &c, &ndirs, false)
	} else {
		line_entries_v4(b, &c, comp_dir, name)
	}
	if c.bad || program > end || line_range == 0 {
		return
	}
	c.pos = program
	addr, file, line: u64 = 0, 1, 1
	stmt, prologue_end := default_stmt, false
	for c.pos < len(c.data) && !c.bad {
		op := fixed(&c, 1)
		flags: Line_Flags
		if stmt {
			flags += {.Stmt}
		}
		if prologue_end {
			flags += {.Prologue_End}
		}
		if op >= opcode_base { 	// special: advance, then a row
			adj := op - opcode_base
			addr += adj / line_range * min_inst
			line += u64(i64(i32(line_base) + i32(adj % line_range)))
			emit_row(b, addr, file, line, flags)
			prologue_end = false
			continue
		}
		switch Lns(op) {
		case .Extended:
			length := uleb(&c)
			if length == 0 || length > u64(len(c.data) - c.pos) {
				c.bad = true
				break
			}
			next := c.pos + int(length)
			switch Lne(fixed(&c, 1)) {
			case .End_Sequence:
				emit_row(b, addr, file, line, flags + {.End})
				addr, file, line = 0, 1, 1
				stmt, prologue_end = default_stmt, false
			case .Set_Address:
				addr = fixed(&c, addr_size)
			}
			if !c.bad {
				c.pos = next
			}
		case .Copy:
			emit_row(b, addr, file, line, flags)
			prologue_end = false
		case .Advance_Pc:
			addr += uleb(&c) * min_inst
		case .Advance_Line:
			line += u64(sleb(&c))
		case .Set_File:
			file = uleb(&c)
		case .Set_Column:
			_ = uleb(&c)
		case .Negate_Stmt:
			stmt = !stmt
		case .Set_Basic_Block, .Set_Epilogue_Begin:
		case .Const_Add_Pc:
			addr += (255 - opcode_base) / line_range * min_inst
		case .Fixed_Advance_Pc:
			addr += fixed(&c, 2)
		case .Set_Prologue_End:
			prologue_end = true
		case .Set_Isa:
			_ = uleb(&c)
		case:
			for _ in 0 ..< std_lens[op] { 	// one the header describes
				_ = uleb(&c)
			}
		}
	}
}
