// The expression evaluator and printer (upstream 05 §6.2): a C expression at
// a frame (literals, variables, $registers, the arithmetic, comparison and
// logical operators, unary - ! ~ * &, casts, sizeof, . -> and []), never a
// call into the program, which would change what is being debugged; and a
// value as text, by its type.
//
// The parser keeps its own stacks and never recurses, and nothing reads the
// program but through the target's read callback.
package debug

// --- Values ---

// Types the evaluator makes (literals' and results'), numbered from here, as
// the index's are below it.
SYNTHETIC :: Type_Index(1 << 30)
SYN_LONG :: SYNTHETIC
SYN_ULONG :: SYNTHETIC + 1
SYN_DOUBLE :: SYNTHETIC + 2
SYN_PTR :: SYNTHETIC + 3 // SYN_PTR + n: the nth pointer type a session made

// A value: where it is (an lvalue in the program's memory or registers, or
// Imm, a value in hand: a scalar's bits, widened to 64), and its type.
Value :: struct {
	type: Type_Index,
	loc:  Location,
}

MAX_POINTER_TYPES :: 32

// What one or more evaluations at a frame share: the pointer types they made,
// so a value's type can be printed after; and why the last one failed.
Session :: struct {
	ix:         ^Index,
	t:          ^Target,
	frame:      ^Frame,
	func:       ^Func, // the frame's; nil if it has none
	ptr_target: [dynamic; MAX_POINTER_TYPES]Type_Index, // SYN_PTR + i points at ptr_target[i]
	err:        string, // "" until an evaluation fails
}

// A session for evaluations at frame f.
begin :: proc "contextless" (ix: ^Index, t: ^Target, f: ^Frame) -> Session {
	fn, _ := func_at(ix, frame_lookup_pc(f))
	return Session{ix = ix, t = t, frame = f, func = fn}
}

// A type as the evaluator needs it, with typedefs and qualifiers looked through.
@(private = "file")
Info :: struct {
	kind:     Type_Kind,
	encoding: Encoding,
	target:   Type_Index,
	count:    u32,
	first:    u32,
	size:     u64,
}

@(private = "file")
info :: proc "contextless" (c: ^Session, type: Type_Index) -> Info {
	switch {
	case type == SYN_LONG:
		return Info{kind = .Base, encoding = .Signed, size = 8}
	case type == SYN_ULONG:
		return Info{kind = .Base, encoding = .Unsigned, size = 8}
	case type == SYN_DOUBLE:
		return Info{kind = .Base, encoding = .Float, size = 8}
	case type >= SYN_PTR && u64(type - SYN_PTR) < u64(len(c.ptr_target)):
		return Info{kind = .Pointer, target = c.ptr_target[type - SYN_PTR], size = 8}
	}
	t, _ := resolve(c.ix, type)
	i := Info {
		kind     = t.kind,
		encoding = t.encoding,
		target   = t.target,
		count    = t.count,
		first    = t.first,
		size     = t.size,
	}
	if i.kind == .Pointer && i.size == 0 {
		i.size = 8
	}
	if i.kind == .Enum && i.size == 0 {
		i.size = 4
	}
	if i.kind == .Array { 	// its elements' size, through arrays of arrays, times its count
		n := u64(i.count)
		e, _ := resolve(c.ix, i.target)
		for guard := 0; e.kind == .Array && guard < 8; guard += 1 {
			n *= u64(e.count)
			e, _ = resolve(c.ix, e.target)
		}
		i.size = n * (e.kind == .Pointer && e.size == 0 ? 8 : e.size)
	}
	return i
}

@(private = "file")
pointer_to :: proc "contextless" (c: ^Session, target: Type_Index) -> Type_Index {
	for p, i in c.ptr_target {
		if p == target {
			return SYN_PTR + Type_Index(i)
		}
	}
	if append(&c.ptr_target, target) == 0 {
		return SYN_ULONG // too many: an address, untyped
	}
	return SYN_PTR + Type_Index(len(c.ptr_target) - 1)
}

@(private = "file")
is_signed :: proc "contextless" (i: Info) -> bool {
	return i.kind == .Base && (i.encoding == .Signed || i.encoding == .Signed_Char || i.encoding == .Signed_Fixed)
}

@(private = "file")
is_float :: proc "contextless" (i: Info) -> bool {
	return i.kind == .Base && i.encoding == .Float
}

@(private = "file")
is_scalar :: proc "contextless" (i: Info) -> bool {
	return i.kind == .Base || i.kind == .Pointer || i.kind == .Enum
}

// A scalar value's bits, read from where it is and widened to 64.
@(private = "file")
load_bits :: proc "contextless" (c: ^Session, v: Value) -> (bits: u64, ok: bool) {
	i := info(c, v.type)
	n := min(i.size, 8)
	raw: u64
	switch l in v.loc {
	case Imm:
		raw = u64(l)
	case Reg:
		r, have := loc_reg(c.t, c.frame, l)
		if !have {
			c.err = "register not available"
			return 0, false
		}
		raw = r
	case Mem:
		buf: [8]u8
		if !c.t.read(c.t.data, u64(l), buf[:n]) {
			c.err = "cannot read memory"
			return 0, false
		}
		raw = u64(transmute(u64le)buf)
	}
	if is_float(i) && n == 4 { 	// a float: as a double
		raw = transmute(u64)f64(transmute(f32)u32(raw))
	} else if n != 0 && n < 8 {
		mask := u64(1) << (8 * n) - 1
		raw &= mask
		if is_signed(i) && (raw >> (8 * n - 1)) & 1 != 0 {
			raw |= ~mask // sign-extended
		}
	}
	return raw, true
}

@(private = "file")
imm :: #force_inline proc "contextless" (type: Type_Index, v: u64) -> Value {
	return Value{type = type, loc = Imm(v)}
}

// The bits of a value in hand (every value is, once rvalue has made it so).
@(private = "file")
bits_of :: #force_inline proc "contextless" (v: Value) -> u64 {
	b, _ := v.loc.(Imm)
	return u64(b)
}

// --- Lexing ---

// A token: a number or character constant; an identifier; a $register's
// name; an operator or bracket; or a character the language does not have.
// nil at the end.
@(private = "file")
Number :: distinct u64
@(private = "file")
Ident :: distinct string
@(private = "file")
Register :: distinct string
@(private = "file")
Bad_Char :: struct {}

@(private = "file")
Punct :: enum u8 {
	Arrow,
	Shl,
	Shr,
	Le,
	Ge,
	Eq,
	Ne,
	And_And,
	Or_Or,
	Plus,
	Minus,
	Star,
	Slash,
	Percent,
	Amp,
	Pipe,
	Caret,
	Tilde,
	Bang,
	Lt,
	Gt,
	Lparen,
	Rparen,
	Lbracket,
	Rbracket,
	Dot,
	Comma,
}

// The operators, two-character ones first, as they are tried.
@(private = "file", rodata)
PUNCT_TEXT := [Punct]string {
	.Arrow    = "->",
	.Shl      = "<<",
	.Shr      = ">>",
	.Le       = "<=",
	.Ge       = ">=",
	.Eq       = "==",
	.Ne       = "!=",
	.And_And  = "&&",
	.Or_Or    = "||",
	.Plus     = "+",
	.Minus    = "-",
	.Star     = "*",
	.Slash    = "/",
	.Percent  = "%",
	.Amp      = "&",
	.Pipe     = "|",
	.Caret    = "^",
	.Tilde    = "~",
	.Bang     = "!",
	.Lt       = "<",
	.Gt       = ">",
	.Lparen   = "(",
	.Rparen   = ")",
	.Lbracket = "[",
	.Rbracket = "]",
	.Dot      = ".",
	.Comma    = ",",
}

@(private = "file")
Token :: union {
	Number,
	Ident,
	Register,
	Punct,
	Bad_Char,
}

@(private = "file")
at :: #force_inline proc "contextless" (s: string, i: int) -> u8 {
	return i < len(s) ? s[i] : 0
}

@(private = "file")
is_ident_char :: proc "contextless" (ch: u8, first: bool) -> bool {
	return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_' || (!first && ch >= '0' && ch <= '9')
}

@(private = "file")
hex_digit :: proc "contextless" (ch: u8) -> u64 {
	switch ch {
	case '0' ..= '9':
		return u64(ch - '0')
	case 'a' ..= 'f':
		return u64(ch - 'a') + 10
	case 'A' ..= 'F':
		return u64(ch - 'A') + 10
	}
	return 16
}

// The token at s[p:], and where the next one starts.
@(private = "file")
lex :: proc "contextless" (s: string, start: int) -> (tok: Token, next: int) {
	p := start
	for at(s, p) == ' ' || at(s, p) == '\t' {
		p += 1
	}
	ch := at(s, p)
	switch {
	case p >= len(s):
		return nil, p
	case ch >= '0' && ch <= '9':
		v: u64
		if ch == '0' && (at(s, p + 1) == 'x' || at(s, p + 1) == 'X') {
			for p += 2; is_ident_char(at(s, p), false); p += 1 {
				d := hex_digit(at(s, p))
				if d > 15 {
					return Bad_Char{}, p
				}
				v = v << 4 | d
			}
		} else {
			for at(s, p) >= '0' && at(s, p) <= '9' {
				v = v * 10 + u64(at(s, p) - '0')
				p += 1
			}
		}
		for at(s, p) == 'u' || at(s, p) == 'U' || at(s, p) == 'l' || at(s, p) == 'L' {
			p += 1 // suffixes
		}
		return Number(v), p
	case ch == '\'' && at(s, p + 1) != 0 && at(s, p + 2) == '\'':
		return Number(at(s, p + 1)), p + 3
	case ch == '$' || is_ident_char(ch, true):
		reg := ch == '$'
		from := reg ? p + 1 : p
		e := from
		for is_ident_char(at(s, e), false) {
			e += 1
		}
		if reg {
			return Register(s[from:e]), e
		}
		return Ident(s[from:e]), e
	}
	for text, k in PUNCT_TEXT {
		if ch == text[0] && (len(text) == 1 || at(s, p + 1) == text[1]) {
			return k, p + len(text)
		}
	}
	return Bad_Char{}, p
}

@(private = "file")
is_word :: proc "contextless" (t: Token, w: string) -> bool {
	id, ok := t.(Ident)
	return ok && string(id) == w
}

@(private = "file")
is_punct :: proc "contextless" (t: Token, want: Punct) -> bool {
	p, ok := t.(Punct)
	return ok && p == want
}

// A type name at s[p:] ("int", "unsigned long", "struct point", "char *",
// ...): the type, and where it ends; false if it is not one.
@(private = "file")
type_name :: proc "contextless" (c: ^Session, s: string, p: int) -> (type: Type_Index, end: int, ok: bool) {
	name: [dynamic; 63]u8 // what fits upstream's 64 bytes with its NUL
	t, q := lex(s, p)
	if _, is_ident := t.(Ident); !is_ident {
		return 0, 0, false
	}
	tagged := is_word(t, "struct") || is_word(t, "union") || is_word(t, "enum")
	if tagged {
		t, q = lex(s, q)
	}
	for { 	// words: "unsigned long int"
		id, is_ident := t.(Ident)
		if !is_ident || len(name) + len(id) + 1 >= 64 {
			break
		}
		if len(name) > 0 {
			_ = append(&name, ' ')
		}
		_ = append(&name, string(id))
		next, r := lex(s, q)
		if _, more := next.(Ident); tagged || !more {
			break
		}
		t, q = next, r
	}
	found: bool
	type, found = type_named(c.ix, string(name[:]))
	if !found && !tagged && is_word(t, "long") && len(name) > 0 {
		type, found = type_named(c.ix, "long") // "long long"
	}
	if !found {
		return 0, 0, false
	}
	for { 	// and its pointers
		star, r := lex(s, q)
		if !is_punct(star, .Star) {
			break
		}
		type = pointer_to(c, type)
		q = r
	}
	return type, q, true
}

// --- Parsing ---

// Operators on the operator stack: binary ones (Punct), and these.
@(private = "file")
Unary :: enum u8 {
	Neg,
	Not,
	Bnot,
	Deref,
	Addr,
	Sizeof,
}
@(private = "file")
Cast :: distinct Type_Index
@(private = "file")
Open :: enum u8 {
	Paren,
	Index,
}
@(private = "file")
Op :: union {
	Unary,
	Cast,
	Open,
	Punct,
}

@(private = "file")
is_open :: proc "contextless" (o: Op, want: Open) -> bool {
	x, ok := o.(Open)
	return ok && x == want
}

@(private = "file")
is_unary :: proc "contextless" (o: Op, want: Unary) -> bool {
	x, ok := o.(Unary)
	return ok && x == want
}

@(private = "file", rodata)
BINARY_PREC := #partial [Punct]int {
	.Star    = 13,
	.Slash   = 13,
	.Percent = 13,
	.Plus    = 12,
	.Minus   = 12,
	.Shl     = 11,
	.Shr     = 11,
	.Lt      = 10,
	.Le      = 10,
	.Gt      = 10,
	.Ge      = 10,
	.Eq      = 9,
	.Ne      = 9,
	.Amp     = 8,
	.Caret   = 7,
	.Pipe    = 6,
	.And_And = 5,
	.Or_Or   = 4,
}

@(private = "file")
prec :: proc "contextless" (o: Op) -> int {
	switch v in o {
	case Open:
		return 0
	case Unary, Cast:
		return 14 // unary binds above binary
	case Punct:
		return BINARY_PREC[v]
	}
	return 1
}

@(private = "file")
is_binary :: proc "contextless" (t: Token) -> bool {
	p, ok := t.(Punct)
	return ok && BINARY_PREC[p] != 0
}

@(private = "file", rodata)
X86_REGS := [16]string{"rax", "rdx", "rcx", "rbx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"}

// A variable or $register, by name, at the frame.
@(private = "file")
name_value :: proc "contextless" (c: ^Session, t: Token) -> (v: Value, ok: bool) {
	name: string
	reg_name, is_reg := t.(Register)
	if is_reg {
		name = string(reg_name)
	} else {
		name = string(t.(Ident))
	}
	if len(name) >= 64 {
		c.err = "name too long"
		return {}, false
	}
	if is_reg {
		NONE :: max(u32)
		reg := NONE
		switch name {
		case "pc", "rip":
			reg = REG_PC
		case "sp":
			reg = sp_reg(c.t)
		case "fp":
			reg = fp_reg(c.t)
		}
		for x, i in X86_REGS {
			if c.t.machine == .X86_64 && reg == NONE && name == x {
				reg = u32(i)
			}
		}
		if c.t.machine == .AArch64 && reg == NONE && at(name, 0) == 'x' {
			r: u32
			i := 1
			for ; at(name, i) >= '0' && at(name, i) <= '9'; i += 1 {
				r = r * 10 + u32(name[i] - '0')
			}
			if i > 1 && i == len(name) && r <= 30 {
				reg = r
			}
		}
		if reg == NONE {
			c.err = "no such register"
			return {}, false
		}
		return Value{type = SYN_ULONG, loc = Reg(reg)}, true
	}
	pc := frame_lookup_pc(c.frame)
	x, found := local_named(c.ix, c.func, pc, name)
	if !found {
		x, found = global_named(c.ix, name)
	}
	if found {
		l, have := location(c.ix, c.t, c.frame, c.func, x)
		if !have {
			c.err = "variable not available here"
			return {}, false
		}
		return Value{type = x.type, loc = l}, true
	}
	for i in 1 ..< len(c.ix.types) { 	// an enumerator
		ty := &c.ix.types[i]
		for k: u32 = 0; ty.kind == .Enum && k < ty.count && u64(ty.first + k) < u64(len(c.ix.members)); k += 1 {
			m := &c.ix.members[ty.first + k]
			if str(c.ix, m.name) == name {
				return imm(Type_Index(i), u64(m.offset)), true
			}
		}
	}
	c.err = "no such variable"
	return {}, false
}

// A value as an rvalue scalar: arrays decay to pointers to their first
// element, and functions to pointers to themselves.
@(private = "file")
rvalue :: proc "contextless" (c: ^Session, v: ^Value) -> bool {
	i := info(c, v.type)
	if i.kind == .Array {
		a, in_mem := v.loc.(Mem)
		if !in_mem {
			c.err = "array not in memory"
			return false
		}
		v^ = imm(pointer_to(c, i.target), u64(a))
		return true
	}
	if i.kind == .Func {
		addr: u64
		#partial switch l in v.loc {
		case Mem:
			addr = u64(l)
		case Imm:
			addr = u64(l) // (a cast to a function type made it 0, as upstream: see Cast in unary)
		}
		v^ = imm(pointer_to(c, v.type), addr)
		return true
	}
	if !is_scalar(i) {
		c.err = "not a number or pointer"
		return false
	}
	bits := load_bits(c, v^) or_return
	v^ = imm(v.type, bits)
	return true
}

@(private = "file")
deref :: proc "contextless" (c: ^Session, ptr: Value) -> (v: Value, ok: bool) {
	i := info(c, ptr.type)
	ok = i.kind == .Pointer && i.target != 0
	if !ok {
		c.err = i.kind == .Pointer ? "cannot dereference void *" : "not a pointer"
	}
	return Value{type = i.target, loc = Mem(bits_of(ptr))}, ok
}

@(private = "file")
apply_unary :: proc "contextless" (c: ^Session, o: Op, v: ^Value) -> bool {
	if is_unary(o, .Addr) {
		a, in_mem := v.loc.(Mem)
		if !in_mem {
			c.err = "not in memory: no address"
			return false
		}
		v^ = imm(pointer_to(c, v.type), u64(a))
		return true
	}
	if is_unary(o, .Sizeof) {
		v^ = imm(SYN_ULONG, info(c, v.type).size)
		return true
	}
	rvalue(c, v) or_return
	i := info(c, v.type)
	x := bits_of(v^)
	ok := true
	#partial switch u in o {
	case Unary:
		#partial switch u {
		case .Deref:
			v^, ok = deref(c, v^)
		case .Neg:
			v^ = imm(is_signed(i) ? v.type : SYN_LONG, -x)
		case .Not:
			v^ = imm(SYN_LONG, u64(x == 0))
		case .Bnot:
			v^ = imm(v.type, ~x)
		}
	case Cast:
		to := info(c, Type_Index(u))
		if to.size != 0 && to.size < 8 {
			mask := u64(1) << (8 * to.size) - 1
			x &= mask
			if is_signed(to) && (x >> (8 * to.size - 1)) & 1 != 0 {
				x |= ~mask
			}
		}
		if to.kind == .Func {
			// Upstream keeps a cast's bits where a function value's address is
			// never looked for, so it decays to a null pointer.
			x = 0
		}
		v^ = imm(Type_Index(u), x)
	case:
		c.err = "bad operator"
		return false
	}
	return ok
}

@(private = "file")
apply_binary :: proc "contextless" (c: ^Session, op: Punct, a: ^Value, b_in: Value) -> bool {
	b := b_in
	if !rvalue(c, a) || !rvalue(c, &b) {
		return false
	}
	ia, ib := info(c, a.type), info(c, b.type)
	if is_float(ia) || is_float(ib) {
		c.err = "floating-point arithmetic is not supported"
		return false
	}
	pa, pb := ia.kind == .Pointer, ib.kind == .Pointer
	x, y := bits_of(a^), bits_of(b)
	r: u64
	sgn := (is_signed(ia) || a.type == SYN_LONG) && (is_signed(ib) || b.type == SYN_LONG)
	type := sgn ? SYN_LONG : SYN_ULONG
	if pa || pb {
		type = pa ? a.type : b.type
	}
	scale_a := pa ? info(c, ia.target).size : 1
	scale_b := pb ? info(c, ib.target).size : 1
	#partial switch op {
	case .Plus:
		switch {
		case pa && pb:
			c.err = "cannot add two pointers"
			return false
		case pa:
			r = x + y * scale_a
		case pb:
			r = y + x * scale_b
		case:
			r = x + y
		}
	case .Minus:
		switch {
		case pa && pb:
			// Signed: &a[0] - &a[1] is -1. A size the target's types give
			// past max(i64) is no real one: refused, not divided (upstream
			// f24356f, from this tree's finding).
			if scale_a > u64(max(i64)) {
				c.err = "a pointer's type is too large to subtract"
				return false
			}
			r = scale_a != 0 ? u64(div_i64(i64(x - y), i64(scale_a))) : 0
			type = SYN_LONG
		case pb:
			c.err = "cannot subtract a pointer from a number"
			return false
		case:
			r = pa ? x - y * scale_a : x - y
		}
	case .Star:
		r = x * y
	case .Slash, .Percent:
		if y == 0 {
			c.err = "division by zero"
			return false
		}
		switch {
		case sgn:
			q, m := div_i64(i64(x), i64(y)), rem_i64(i64(x), i64(y))
			r = op == .Slash ? u64(q) : u64(m)
		case op == .Slash:
			r = x / y
		case:
			r = x % y
		}
	case .Shl:
		r = y < 64 ? x << y : 0
	case .Shr:
		switch {
		case y >= 64:
			r = 0
		case sgn:
			r = u64(i64(x) >> y)
		case:
			r = x >> y
		}
	case .Amp:
		r = x & y
	case .Pipe:
		r = x | y
	case .Caret:
		r = x ~ y
	case:
		type = SYN_LONG // comparisons and logic: 0 or 1
		lt := sgn ? i64(x) < i64(y) : x < y
		gt := sgn ? i64(x) > i64(y) : x > y
		#partial switch op {
		case .And_And:
			r = u64(x != 0 && y != 0)
		case .Or_Or:
			r = u64(x != 0 || y != 0)
		case .Eq:
			r = u64(x == y)
		case .Ne:
			r = u64(x != y)
		case .Le:
			r = u64(!gt)
		case .Ge:
			r = u64(!lt)
		case .Lt:
			r = u64(lt)
		case .Gt:
			r = u64(gt)
		case:
			c.err = "bad operator"
			return false
		}
	}
	a^ = imm(type, r)
	return true
}

// Signed division and remainder, which wrap where C's would trap: the one
// quotient that does not fit, min(i64) / -1, is min(i64), and its remainder
// 0. (Upstream guards the operator's quotient so; its pointer difference,
// scaled by a hostile type size of 2^64 - 1, would trap.)
@(private = "file")
div_i64 :: proc "contextless" (x, y: i64) -> i64 {
	if y == -1 {
		return -x // wraps for min(i64)
	}
	return x / y
}

@(private = "file")
rem_i64 :: proc "contextless" (x, y: i64) -> i64 {
	if y == -1 {
		return 0
	}
	return x % y
}

// .member or ->member of v.
@(private = "file")
member :: proc "contextless" (c: ^Session, v: ^Value, name: string, arrow: bool) -> bool {
	if arrow {
		rvalue(c, v) or_return
		v^ = deref(c, v^) or_return
	}
	i := info(c, v.type)
	if i.kind != .Struct && i.kind != .Union {
		c.err = "not a struct or union"
		return false
	}
	for k: u32 = 0; k < i.count && u64(i.first + k) < u64(len(c.ix.members)); k += 1 {
		m := &c.ix.members[i.first + k]
		if str(c.ix, m.name) == name {
			a, in_mem := v.loc.(Mem)
			if !in_mem {
				c.err = "member of a value not in memory"
				return false
			}
			v^ = Value{type = m.type, loc = Mem(u64(a) + u64(m.offset))}
			return true
		}
	}
	c.err = "no such member"
	return false
}

@(private = "file")
MAX_VALUES :: 32
@(private = "file")
MAX_OPS :: 64

@(private = "file")
Parse :: struct {
	vals: [dynamic; MAX_VALUES]Value,
	ops:  [dynamic; MAX_OPS]Op,
}

// Applies the operator on top of the stacks to the values under it.
@(private = "file")
reduce :: proc "contextless" (c: ^Session, ps: ^Parse) -> bool {
	o := ps.ops[len(ps.ops) - 1]
	resize(&ps.ops, len(ps.ops) - 1)
	if bin, is_bin := o.(Punct); is_bin {
		if len(ps.vals) < 2 {
			c.err = "missing operand"
			return false
		}
		b := ps.vals[len(ps.vals) - 1]
		resize(&ps.vals, len(ps.vals) - 1)
		return apply_binary(c, bin, &ps.vals[len(ps.vals) - 1], b)
	}
	if len(ps.vals) < 1 {
		c.err = "missing operand"
		return false
	}
	return apply_unary(c, o, &ps.vals[len(ps.vals) - 1])
}

// Evaluates text, a C expression, at the session's frame; false, with why in
// s.err, if it cannot be. The pointer types it makes stay in the session.
@(require_results)
eval :: proc "contextless" (s: ^Session, text_in: string) -> (v: Value, ok: bool) {
	text := text_in
	for ch, i in transmute([]u8)text {
		if ch == 0 {
			text = text[:i] // the end, as upstream's NUL-terminated text has it
			break
		}
	}
	c := s^
	c.err = ""
	ps: Parse
	too_complex :: proc "contextless" (s: ^Session) -> (Value, bool) {
		s.err = "too complex"
		return {}, false
	}
	p := 0
	want_operand := true
	ok = true
	for ok {
		tk, next := lex(text, p)
		if _, bad := tk.(Bad_Char); bad {
			c.err = "unexpected character"
			ok = false
			break
		}
		if tk == nil {
			break
		}
		if want_operand {
			switch t in tk {
			case Number:
				if len(ps.vals) == MAX_VALUES {
					return too_complex(s)
				}
				_ = append(&ps.vals, imm(SYN_LONG, u64(t)))
				want_operand = false
			case Ident, Register:
				if is_word(tk, "sizeof") {
					paren, q := lex(text, next)
					ty: Type_Index
					end: int
					is_type := false
					if is_punct(paren, .Lparen) {
						ty, end, is_type = type_name(&c, text, q)
					}
					close: Token
					after: int
					if is_type {
						close, after = lex(text, end)
					}
					if is_type && is_punct(close, .Rparen) { 	// sizeof(type)
						if len(ps.vals) == MAX_VALUES {
							return too_complex(s)
						}
						_ = append(&ps.vals, imm(SYN_ULONG, info(&c, ty).size))
						next = after
						want_operand = false
					} else {
						if len(ps.ops) == MAX_OPS {
							return too_complex(s)
						}
						_ = append(&ps.ops, Op(Unary.Sizeof))
					}
					break
				}
				if len(ps.vals) == MAX_VALUES {
					return too_complex(s)
				}
				nv: Value
				nv, ok = name_value(&c, tk)
				_ = append(&ps.vals, nv)
				want_operand = false
			case Punct:
				#partial switch t {
				case .Lparen:
					ty, end, is_type := type_name(&c, text, next)
					if len(ps.ops) == MAX_OPS {
						return too_complex(s)
					}
					close: Token
					after: int
					if is_type {
						close, after = lex(text, end)
					}
					if is_type && is_punct(close, .Rparen) { 	// a cast
						_ = append(&ps.ops, Op(Cast(ty)))
						next = after
					} else {
						_ = append(&ps.ops, Op(Open.Paren))
					}
				case .Minus, .Bang, .Tilde, .Star, .Amp, .Plus:
					if len(ps.ops) == MAX_OPS {
						return too_complex(s)
					}
					#partial switch t {
					case .Minus:
						_ = append(&ps.ops, Op(Unary.Neg))
					case .Bang:
						_ = append(&ps.ops, Op(Unary.Not))
					case .Tilde:
						_ = append(&ps.ops, Op(Unary.Bnot))
					case .Star:
						_ = append(&ps.ops, Op(Unary.Deref))
					case .Amp:
						_ = append(&ps.ops, Op(Unary.Addr))
					} // unary +: nothing to do
				case:
					c.err = "expected a value"
					ok = false
				}
			case Bad_Char:
			}
		} else if is_punct(tk, .Dot) || is_punct(tk, .Arrow) { 	// postfix: at once, on the operand
			name: Token
			name, next = lex(text, next)
			if id, is_ident := name.(Ident); is_ident && len(ps.vals) > 0 {
				ok = member(&c, &ps.vals[len(ps.vals) - 1], string(id), is_punct(tk, .Arrow))
			} else {
				c.err = "expected a member"
				ok = false
			}
		} else if is_punct(tk, .Lbracket) {
			if len(ps.ops) == MAX_OPS {
				return too_complex(s)
			}
			_ = append(&ps.ops, Op(Open.Index))
			want_operand = true
		} else if is_punct(tk, .Rparen) || is_punct(tk, .Rbracket) {
			open := is_punct(tk, .Rparen) ? Open.Paren : Open.Index
			for ok && len(ps.ops) > 0 && !is_open(ps.ops[len(ps.ops) - 1], open) {
				ok = reduce(&c, &ps)
			}
			if !ok {
				break
			}
			if len(ps.ops) == 0 {
				c.err = "unbalanced brackets"
				ok = false
				break
			}
			resize(&ps.ops, len(ps.ops) - 1)
			if open == .Index { 	// a[i]: *(a + i)
				if len(ps.vals) < 2 {
					c.err = "missing index"
					ok = false
					break
				}
				idx := ps.vals[len(ps.vals) - 1]
				resize(&ps.vals, len(ps.vals) - 1)
				top := &ps.vals[len(ps.vals) - 1]
				ok = apply_binary(&c, .Plus, top, idx)
				if ok {
					top^, ok = deref(&c, top^)
				}
			}
		} else if is_binary(tk) {
			o := Op(tk.(Punct))
			for ok && len(ps.ops) > 0 {
				prev := ps.ops[len(ps.ops) - 1]
				if _, is_open := prev.(Open); is_open || prec(prev) < prec(o) {
					break
				}
				ok = reduce(&c, &ps)
			}
			if len(ps.ops) == MAX_OPS {
				return too_complex(s)
			}
			_ = append(&ps.ops, o)
			want_operand = true
		} else {
			c.err = "expected an operator"
			ok = false
		}
		p = next
	}
	if ok && want_operand {
		c.err = "expected a value"
		ok = false
	}
	for ok && len(ps.ops) > 0 {
		if _, is_open := ps.ops[len(ps.ops) - 1].(Open); is_open {
			c.err = "unbalanced brackets"
			ok = false
			break
		}
		ok = reduce(&c, &ps)
	}
	if ok && len(ps.vals) != 1 {
		c.err = "not one expression"
		ok = false
	}
	if ok {
		v = ps.vals[0]
	}
	s^ = c // its pointer types, and why it failed
	return v, ok
}

// --- Printing ---

// Text into a caller's buffer, cut short where it is full. It keeps the
// buffer's last byte, as upstream's NUL did, so the same buffer cuts the same
// text at the same place.
@(private = "file")
Out :: struct {
	buf: []u8,
	len: int,
}

@(private = "file")
put :: proc "contextless" (o: ^Out, s: string) {
	for i := 0; i < len(s) && o.len + 1 < len(o.buf); i += 1 {
		o.buf[o.len] = s[i]
		o.len += 1
	}
}

@(private = "file")
put_u :: proc "contextless" (o: ^Out, v: u64, hex: bool) {
	digits := "0123456789abcdef"
	d: [24]u8
	n := 0
	x := v
	for {
		d[n] = digits[hex ? x & 15 : x % 10]
		n += 1
		x = hex ? x >> 4 : x / 10
		if x == 0 {
			break
		}
	}
	if hex {
		put(o, "0x")
	}
	for n > 0 {
		n -= 1
		put(o, string(d[n:][:1]))
	}
}

@(private = "file")
put_i :: proc "contextless" (o: ^Out, v: i64) {
	if v < 0 {
		put(o, "-")
	}
	put_u(o, v < 0 ? u64(0) - u64(v) : u64(v), false)
}

@(private = "file")
put_double :: proc "contextless" (o: ^Out, d_in: f64) {
	d := d_in
	if d != d {
		put(o, "nan")
		return
	}
	if d < 0 {
		put(o, "-")
		d = -d
	}
	if d > 1e18 {
		put(o, "inf-or-large")
		return
	}
	whole := u64(d)
	put_u(o, whole, false)
	frac := u64((d - f64(whole)) * 1e6 + 0.5)
	if frac >= 1000000 {
		frac = 999999
	}
	digits := [6]u8{'0', '0', '0', '0', '0', '0'}
	for i := 5; i >= 0; i -= 1 {
		digits[i] = u8('0' + frac % 10)
		frac /= 10
	}
	last := 5
	for last > 0 && digits[last] == '0' {
		last -= 1
	}
	put(o, ".")
	put(o, string(digits[:last + 1]))
}

// A string in the program at addr, quoted: at most max_len bytes, until a NUL.
@(private = "file")
put_string :: proc "contextless" (c: ^Session, o: ^Out, addr: u64, max_len: u64) {
	put(o, "\"")
	for i: u64 = 0; i < max_len; i += 1 {
		if o.len + 8 >= len(o.buf) {
			break // the output is full: no more of the target read for nothing
		}
		ch: [1]u8
		if !c.t.read(c.t.data, addr + i, ch[:]) {
			put(o, "<unreadable>")
			return
		}
		switch {
		case ch[0] == 0:
			put(o, "\"")
			return
		case ch[0] == '"' || ch[0] == '\\':
			put(o, "\\")
			put(o, string(ch[:]))
		case ch[0] == '\n':
			put(o, "\\n")
		case ch[0] == '\t':
			put(o, "\\t")
		case ch[0] < 0x20:
			put(o, "\\?")
		case:
			put(o, string(ch[:]))
		}
	}
	put(o, "...\"")
}

@(private = "file")
is_char_type :: proc "contextless" (c: ^Session, type: Type_Index) -> bool {
	i := info(c, type)
	return i.kind == .Base && i.size == 1 && (i.encoding == .Signed_Char || i.encoding == .Unsigned_Char)
}

// A scalar (base, enum or pointer) value as text.
@(private = "file")
put_scalar :: proc "contextless" (c: ^Session, o: ^Out, type: Type_Index, bits: u64) {
	i := info(c, type)
	if i.kind == .Pointer {
		put_u(o, bits, true)
		if bits != 0 && is_char_type(c, i.target) {
			put(o, " ")
			put_string(c, o, bits, 64)
		}
		return
	}
	if i.kind == .Enum {
		for k: u32 = 0; k < i.count && u64(i.first + k) < u64(len(c.ix.members)); k += 1 {
			m := &c.ix.members[i.first + k]
			if u64(m.offset) == bits {
				put(o, str(c.ix, m.name))
				return
			}
		}
		put_i(o, i64(bits))
		return
	}
	if is_float(i) {
		put_double(o, transmute(f64)bits)
		return
	}
	if i.encoding == .Boolean {
		put(o, bits != 0 ? "true" : "false")
		return
	}
	if is_signed(i) {
		put_i(o, i64(bits))
	} else {
		put_u(o, bits, false)
	}
	if is_char_type(c, type) && bits >= 0x20 && bits < 0x7f {
		q := [4]u8{' ', '\'', u8(bits), '\''}
		put(o, string(q[:]))
	}
}

// A scalar value, read and put; false (and nothing put) if it is not one or
// cannot be read.
@(private = "file")
put_loaded :: proc "contextless" (c: ^Session, o: ^Out, v: Value) -> bool {
	if !is_scalar(info(c, v.type)) {
		return false
	}
	bits := load_bits(c, v) or_return
	put_scalar(c, o, v.type, bits)
	return true
}

// v as text, in buf (at most len(buf) - 1 bytes of it): a struct's members
// one level deep, an array's first elements, a char array or char * as a
// string.
format :: proc "contextless" (s: ^Session, v: Value, buf: []u8) -> string {
	c := s^
	ix := c.ix
	o := Out {
		buf = buf,
	}
	i := info(&c, v.type)
	a, in_mem := v.loc.(Mem)
	switch {
	case is_scalar(i):
		if bits, ok := load_bits(&c, v); ok {
			put_scalar(&c, &o, v.type, bits)
		} else {
			put(&o, c.err)
		}
	case !in_mem:
		put(&o, "<not in memory>")
	case i.kind == .Array && is_char_type(&c, i.target):
		put_string(&c, &o, u64(a), i.count != 0 ? u64(i.count) : 64)
	case i.kind == .Array:
		esize := info(&c, i.target).size
		put(&o, "[")
		for k: u32 = 0; k < i.count && k < 8; k += 1 {
			e := Value {
				type = i.target,
				loc  = Mem(u64(a) + u64(k) * esize),
			}
			if k > 0 {
				put(&o, ", ")
			}
			if !put_loaded(&c, &o, e) {
				put(&o, "{...}")
			}
		}
		put(&o, i.count > 8 ? ", ...]" : "]")
	case i.kind == .Struct || i.kind == .Union:
		put(&o, "{")
		for k: u32 = 0; k < i.count && u64(i.first + k) < u64(len(ix.members)); k += 1 {
			m := &ix.members[i.first + k]
			mv := Value {
				type = m.type,
				loc  = Mem(u64(a) + u64(m.offset)),
			}
			mi := info(&c, m.type)
			if k > 0 {
				put(&o, ", ")
			}
			put(&o, str(ix, m.name))
			put(&o, " = ")
			if put_loaded(&c, &o, mv) {
			} else if mi.kind == .Array && is_char_type(&c, mi.target) {
				put_string(&c, &o, u64(a) + u64(m.offset), mi.count != 0 ? u64(mi.count) : 64)
			} else {
				put(&o, "{...}")
			}
		}
		put(&o, "}")
	case:
		put(&o, "<no value>")
	}
	return string(o.buf[:o.len])
}
