// Where a variable is at a frame: its DWARF location expression, evaluated
// against the frame's registers and the program's memory.
package debug

Mem :: distinct u64 // in the program's memory, at this address
Reg :: distinct u32 // in this register (DWARF's numbering)
Imm :: distinct u64 // nowhere: this is the value

// Where a value is; nil for nowhere.
Location :: union {
	Mem,
	Reg,
	Imm,
}

@(private = "file")
Expr :: struct {
	p:   []u8,
	pos: int,
}

// A LEB128 number; as much as there is of one at the end.
@(private = "file")
expr_leb :: proc "contextless" (e: ^Expr, signed: bool) -> u64 {
	v: u64
	shift: u32
	b: u8
	for e.pos < len(e.p) {
		b = e.p[e.pos]
		e.pos += 1
		if shift < 64 {
			v |= u64(b & 0x7f) << shift
		}
		shift += 7
		if b & 0x80 == 0 {
			break
		}
	}
	if signed && shift < 64 && b & 0x40 != 0 {
		v |= ~u64(0) << shift
	}
	return v
}

// An n-byte little-endian number; as much as there is of one at the end.
@(private = "file")
expr_fixed :: proc "contextless" (e: ^Expr, n: int) -> u64 {
	v: u64
	for i := 0; i < n && e.pos < len(e.p); i += 1 {
		v |= u64(e.p[e.pos]) << (8 * uint(i))
		e.pos += 1
	}
	return v
}

// The DWARF expression stack.
@(private = "file")
Stack :: struct {
	v:    [64]u64,
	n:    int,
	bad:  bool, // overflowed, or used empty: the expression is not evaluated
	none: u64, // what top gives when it is empty
}

@(private = "file")
push :: proc "contextless" (s: ^Stack, v: u64) {
	if s.n == len(s.v) {
		s.bad = true
	} else {
		s.v[s.n] = v
		s.n += 1
	}
}

@(private = "file")
pop :: proc "contextless" (s: ^Stack) -> u64 {
	if s.n == 0 {
		s.bad = true
		return 0
	}
	s.n -= 1
	return s.v[s.n]
}

@(private = "file")
top :: proc "contextless" (s: ^Stack) -> ^u64 {
	if s.n == 0 {
		s.bad = true
		return &s.none
	}
	return &s.v[s.n - 1]
}

// A DWARF expression at a frame: where its value is. frame_base is the
// function's (for DW_OP_fbreg), already evaluated; 0 if it has none.
@(private)
eval_expr :: proc "contextless" (t: ^Target, f: ^Frame, frame_base: u64, expr: []u8) -> (loc: Location, ok: bool) {
	e := Expr {
		p = expr,
	}
	st: Stack
	for e.pos < len(e.p) && !st.bad {
		op := Dw_Op(e.p[e.pos])
		e.pos += 1
		// A register on its own, or as the first piece: the value is in it.
		alone :: proc "contextless" (e: ^Expr) -> bool {
			return e.pos == len(e.p) || Dw_Op(e.p[e.pos]) == .Piece
		}
		#partial switch op {
		case .Lit0 ..= .Lit31:
			push(&st, u64(op - .Lit0))
		case .Reg0 ..= .Reg31:
			return Reg(op - .Reg0), alone(&e)
		case .Breg0 ..= .Breg31:
			off := expr_leb(&e, true)
			a := frame_reg(t, f, u32(op - .Breg0)) or_return
			push(&st, a + off)
		case .Minus, .Mul, .And, .Or, .Plus, .Xor, .Shl, .Shr:
			b := pop(&st)
			a := pop(&st)
			r: u64
			#partial switch op {
			case .Minus:
				r = a - b
			case .Mul:
				r = a * b
			case .And:
				r = a & b
			case .Or:
				r = a | b
			case .Plus:
				r = a + b
			case .Xor:
				r = a ~ b
			case .Shl:
				r = b < 64 ? a << b : 0
			case .Shr:
				r = b < 64 ? a >> b : 0
			}
			push(&st, r)
		case .Addr:
			push(&st, expr_fixed(&e, 8))
		case .Deref:
			if st.n == 0 { 	// (upstream reads at an indeterminate address, then fails alike)
				return nil, false
			}
			top(&st)^ = read_u64(t, top(&st)^) or_return
		case .Deref_Size:
			n := expr_fixed(&e, 1)
			if n > 8 || st.n == 0 {
				return nil, false
			}
			buf: [8]u8
			if !t.read(t.data, top(&st)^, buf[:n]) {
				return nil, false
			}
			top(&st)^ = u64(transmute(u64le)buf)
		case .Const1u:
			push(&st, expr_fixed(&e, 1))
		case .Const1s:
			push(&st, u64(i8(expr_fixed(&e, 1))))
		case .Const2u:
			push(&st, expr_fixed(&e, 2))
		case .Const2s:
			push(&st, u64(i16(expr_fixed(&e, 2))))
		case .Const4u:
			push(&st, expr_fixed(&e, 4))
		case .Const4s:
			push(&st, u64(i32(expr_fixed(&e, 4))))
		case .Const8u, .Const8s:
			push(&st, expr_fixed(&e, 8))
		case .Constu:
			push(&st, expr_leb(&e, false))
		case .Consts:
			push(&st, expr_leb(&e, true))
		case .Dup:
			push(&st, top(&st)^)
		case .Drop:
			_ = pop(&st)
		case .Over:
			b := pop(&st)
			a := pop(&st)
			push(&st, a)
			push(&st, b)
			push(&st, a)
		case .Swap:
			b := pop(&st)
			a := pop(&st)
			push(&st, b)
			push(&st, a)
		case .Neg:
			top(&st)^ = -top(&st)^
		case .Not:
			top(&st)^ = ~top(&st)^
		case .Plus_Uconst:
			top(&st)^ += expr_leb(&e, false)
		case .Regx:
			r := Reg(u32(expr_leb(&e, false)))
			return r, alone(&e)
		case .Fbreg:
			off := expr_leb(&e, true)
			if frame_base == 0 {
				return nil, false
			}
			push(&st, frame_base + off)
		case .Bregx:
			r := u32(expr_leb(&e, false))
			off := expr_leb(&e, true)
			a := frame_reg(t, f, r) or_return
			push(&st, a + off)
		case .Call_Frame_Cfa:
			push(&st, f.fp + 16) // with frame pointers, past the frame record
		case .Stack_Value: 	// the value itself
			v := top(&st)^
			return Imm(v), !st.bad
		case .Piece: 	// the first only (the value starts there)
			v := top(&st)^
			return Mem(v), !st.bad
		case .Nop:
		case .Convert, .Reinterpret: 	// types are not tracked
			_ = expr_leb(&e, false)
		case .Regval_Type:
			r := u32(expr_leb(&e, false))
			_ = expr_leb(&e, false)
			a := frame_reg(t, f, r) or_return
			push(&st, a)
		case:
			return nil, false // entry_value and the rest: not known here
		}
	}
	if st.bad || st.n == 0 {
		return nil, false
	}
	return Mem(st.v[st.n - 1]), true
}

// A register's value at a frame, as a location names it.
@(private)
loc_reg :: proc "contextless" (t: ^Target, f: ^Frame, r: Reg) -> (u64, bool) {
	return frame_reg(t, f, u32(r))
}

// A function's frame base at a frame: its DW_AT_frame_base evaluated; 0 if
// it cannot be.
@(private)
frame_base :: proc "contextless" (ix: ^Index, t: ^Target, f: ^Frame, fn: ^Func) -> u64 {
	if fn == nil || fn.frame_base_len == 0 {
		return 0
	}
	n := u64(len(ix.exprs))
	if u64(fn.frame_base) > n || u64(fn.frame_base_len) > n - u64(fn.frame_base) {
		return 0
	}
	l, ok := eval_expr(t, f, 0, ix.exprs[fn.frame_base:][:fn.frame_base_len])
	if !ok {
		return 0
	}
	switch v in l {
	case Reg:
		r, have := loc_reg(t, f, v)
		return have ? r : 0
	case Mem:
		return u64(v)
	case Imm:
		return u64(v)
	}
	return 0
}

// Where variable v is at frame f, whose function is fn (for a local; it may
// be nil).
@(require_results)
location :: proc "contextless" (ix: ^Index, t: ^Target, f: ^Frame, fn: ^Func, v: ^Var) -> (loc: Location, ok: bool) {
	if .Const in v.flags {
		return Imm(u64(v.value)), true
	}
	expr := var_location(ix, v, frame_lookup_pc(f)) or_return
	return eval_expr(t, f, v.kind == .Global ? 0 : frame_base(ix, t, f, fn), expr)
}
