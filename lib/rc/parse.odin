// The parser (rc's syn.y, without recursion).
//
// A shunting-yard over commands, with nested contexts: one stack holds what
// is pending, a frame each, and a value stack the trees made so far. A
// prefix construct (if (...), while (...), for (...), !, @, a redirection or
// an assignment before a command) waits for the command after it; a binary
// one (|, &&, ||) for its right side; a list (the script, { ... }, ( ... ),
// `{ ... }) gathers commands until its terminator. rc's precedences, lowest
// first: the bodies of if, while, for and if not; && and ||; ! and @ (and a
// redirection or assignment before a command); |. Words nest too ($ $# $"
// ^ subscripts, ( ... ) lists, `{ ... }) and have frames of their own.
package rc

@(private)
Node_Kind :: enum u8 {
	Word,
	Dol,
	Count,
	Join,
	Sub,
	Conc,
	Backq,
	Paren,
	Simple,
	Seq,
	Async,
	And,
	Or,
	Pipe,
	Bang,
	Subshell,
	Brace,
	If,
	If_Not,
	For,
	While,
	Switch,
	Twiddle,
	Fn,
	Assign,
	Redir,
	Dup,
}

@(private)
Node :: struct {
	kind:    Node_Kind,
	using _: struct #raw_union {
		using io:   Node_Io,
		using word: Node_Word,
	},
	line:    u32, // where it was written
	a, b, c: i32, // children (NONE: none)
	next:    i32, // the next in a list of words or redirections
	s:       string, // a Word's text
	// Its source text, for code a child runs (upstream's 6d7b1): where it
	// starts in the text, plus 1 (0: not known), and where it ends.
	from:    int,
	to:      int,
}

// A redirection's, a Dup's or a Pipe's: its descriptors, and how it opens its file.
@(private)
Node_Io :: struct {
	fd0, fd1: u8,
	rkind:    Redir_Kind,
}

// A Word's.
@(private)
Node_Word :: struct {
	quoted: bool, // written in quotes: never a switch's case
	here:   u8, // a here document's tag: its place in the lexer's heres, plus 1
}
// Upstream's rc_node is 56 bytes, and the parse takes room for len+32 of
// them from the heap: so does this one.
@(private)
NODE_BYTES :: 56
#assert(size_of(Node) == NODE_BYTES)

@(private)
NONE :: -1
@(private)
ALLARGS :: -2 // a For's words: for(i) loops over $*

@(private)
Frame_Kind :: enum u8 {
	List, // term: what ends it; a: what it has gathered (a Seq chain); c: its last link + 1
	Brace, // { ... }
	If_Cond, // if ( ... )
	While_Cond, // while ( ... )
	Switch_Wait, // switch word: its { next; a: the word
	Switch_Body, // a: the subject
	Fn_Body, // a: the names; c: where its { is in the text
	Backq_Body, // `{ ... }; b: the ifs words, or none
	Backq_Wait, // `word: its { next; a: the word
	Prefix, // op, prec; a, b, fd0, fd1, rkind: what it holds
	Bin, // op, prec, fd0, fd1
	Simple, // a: its words' head, b: its redirections' head; c, d: their tails
	Words, // purpose; term; a: head, c: tail; b: what it is for (a name, a variable)
	Want, // a word for purpose; a, fd0, rkind: what it belongs to
	Dol, // op: Dol, Count or Join
	Conc, // a: the left side
	For_Wait, // for(word: `in` or `)` next; a: the variable
}

@(private)
Purpose :: enum u8 {
	Paren, // ( words ): a word
	Sub, // $x( words ): a subscript; b: the name
	For_In, // for(i in words); b: the variable
	Fn_Names, // fn names { ... }
	Patterns, // ~ subject patterns; b: the subject
	Want_Switch,
	Want_Assign, // a: the name
	Want_Redir_Prefix,
	Want_Redir_Epilog,
	Want_Redir_Simple,
	Want_For_Var,
	Want_Twiddle,
	Want_Backq, // `word { ... }: the ifs
}

@(private)
Pframe :: struct {
	kind:       Frame_Kind,
	op:         Node_Kind,
	prec:       u8,
	purpose:    Purpose,
	term:       Token_Kind,
	fd0, fd1:   u8,
	rkind:      Redir_Kind,
	a, b, c, d: i32,
	from:       int, // where its construct's first token is, plus 1 (0: none), for its node's text
}
#assert(size_of(Pframe) == 32)

@(private)
PFRAMES :: 256
@(private)
PVALS :: 256

@(private)
Parser :: struct {
	lx:         Lexer,
	last_end:   int, // where the last token taken ends: a function body's text ends there
	last_start: int, // and where it starts
	look:       [2]Token,
	nlook:      u32,
	nodes:      []Node,
	nnodes:     u32,
	frames:     [dynamic; PFRAMES]Pframe,
	vals:       [dynamic; PVALS]i32,
	why:        string, // a syntax error, if any
	incomplete: bool, // the text ended inside a construct: more may finish it
	line:       u32,
}
// Upstream's parser takes this much of the heap; this one lives in as much.
@(private)
PARSER_BYTES :: 10856
#assert(size_of(Parser) <= PARSER_BYTES)

@(private = "file")
peek :: proc "contextless" (p: ^Parser) -> ^Token {
	if p.nlook == 0 {
		p.look[0] = lex(&p.lx)
		p.nlook = 1
	}
	return &p.look[0]
}

@(private = "file")
peek2 :: proc "contextless" (p: ^Parser) -> ^Token {
	_ = peek(p)
	if p.nlook < 2 {
		p.look[p.nlook] = lex(&p.lx)
		p.nlook += 1
	}
	return &p.look[1]
}

@(private = "file")
take :: proc "contextless" (p: ^Parser) -> Token {
	_ = peek(p)
	t := p.look[0]
	p.look[0] = p.look[1]
	p.nlook -= 1
	p.line = t.line
	p.last_end = t.end
	p.last_start = t.at
	return t
}

@(private = "file")
node_new :: proc "contextless" (p: ^Parser, kind: Node_Kind, a, b, c: i32) -> i32 {
	if int(p.nnodes) == len(p.nodes) {
		p.why = "script too long"
		return NONE
	}
	// Its text: from its first child's, to the last token taken (a binary
	// node's is its children's: it is made after its operator's next is seen).
	from := 0
	for k in ([3]i32{a, b, c}) {
		if k >= 0 && u32(k) < p.nnodes && p.nodes[k].from != 0 && (from == 0 || p.nodes[k].from < from) {
			from = p.nodes[k].from
		}
	}
	p.nodes[p.nnodes] = Node {
		kind = kind,
		line = p.line,
		a    = a,
		b    = b,
		c    = c,
		next = NONE,
		from = from,
		to   = p.last_end,
	}
	p.nnodes += 1
	return i32(p.nnodes - 1)
}

// Lowers node n's text's start to from (plus 1, as Node.from), a token
// before its children: a keyword, a brace, a redirection.
@(private = "file")
set_from :: proc "contextless" (p: ^Parser, n: i32, from: int) {
	if n >= 0 && u32(n) < p.nnodes && from != 0 && (p.nodes[n].from == 0 || from < p.nodes[n].from) {
		p.nodes[n].from = from
	}
}

// A token's start, as Node.from and Pframe.from keep it.
@(private = "file")
start :: proc "contextless" (t: Token) -> int {
	return t.at + 1
}

// node n's fields from a token or frame, if it was made.
@(private = "file")
set_fds :: proc "contextless" (p: ^Parser, n: i32, fd0, fd1: u8, rkind: Redir_Kind = .Read) {
	if n != NONE {
		p.nodes[n].fd0 = fd0
		p.nodes[n].fd1 = fd1
		p.nodes[n].rkind = rkind
	}
}

@(private = "file")
@(require_results)
push :: proc "contextless" (p: ^Parser, f: Pframe) -> bool {
	if len(p.frames) == PFRAMES {
		p.why = "nested too deeply"
		return false
	}
	append(&p.frames, f)
	return true
}

@(private = "file")
@(require_results)
push_val :: proc "contextless" (p: ^Parser, v: i32) -> bool {
	if len(p.vals) == PVALS {
		p.why = "nested too deeply"
		return false
	}
	append(&p.vals, v)
	return true
}

@(private = "file")
pop_val :: proc "contextless" (p: ^Parser) -> i32 {
	if len(p.vals) == 0 {
		return NONE
	}
	v := p.vals[len(p.vals) - 1]
	resize(&p.vals, len(p.vals) - 1)
	return v
}

@(private = "file")
pop :: proc "contextless" (p: ^Parser) -> Pframe {
	f := p.frames[len(p.frames) - 1]
	resize(&p.frames, len(p.frames) - 1)
	return f
}

@(private = "file")
top :: proc "contextless" (p: ^Parser) -> ^Pframe {
	return len(p.frames) > 0 ? &p.frames[len(p.frames) - 1] : nil
}

@(private = "file")
skip_nl :: proc "contextless" (p: ^Parser) {
	for peek(p).kind == .Nl {
		_ = take(p)
	}
}

// Appends node n to a list whose head and tail are head^ and tail^.
@(private = "file")
list_append :: proc "contextless" (p: ^Parser, head, tail: ^i32, n: i32) {
	if n == NONE {
		return
	}
	if head^ == NONE {
		head^ = n
	} else {
		p.nodes[tail^].next = n
	}
	tail^ = n
}

// Builds what the frame on top makes of the value(s) it was waiting for.
@(private = "file")
reduce_one :: proc "contextless" (p: ^Parser) {
	f := pop(p)
	n: i32
	if f.kind == .Bin {
		b := pop_val(p)
		a := pop_val(p)
		n = node_new(p, f.op, a, b, NONE)
		if n != NONE { // |[fd0=fd1]
			p.nodes[n].fd0 = f.fd0
			p.nodes[n].fd1 = f.fd1
		}
		if n != NONE && b >= 0 {
			p.nodes[n].to = p.nodes[b].to // not the operator taken after it
		}
	} else { // Prefix
		cmd := pop_val(p)
		#partial switch f.op {
		case .For, .Assign:
			n = node_new(p, f.op, f.a, f.b, cmd)
		case .Redir:
			n = node_new(p, .Redir, f.a, cmd, NONE)
		case .Dup:
			n = node_new(p, .Dup, NONE, cmd, NONE)
		case .If, .While:
			n = node_new(p, f.op, f.a, cmd, NONE)
		case: // If_Not, Bang, Subshell: b is the command
			n = node_new(p, f.op, NONE, cmd, NONE)
		}
		set_fds(p, n, f.fd0, f.fd1, f.rkind)
		set_from(p, n, f.from)
	}
	_ = push_val(p, n)
}

// Reduces what binds at least as tightly as prec (-1: everything, to the list).
@(private = "file")
reduce :: proc "contextless" (p: ^Parser, prec: int) {
	for f := top(p); f != nil && (f.kind == .Bin || f.kind == .Prefix) && int(f.prec) >= prec; f = top(p) {
		reduce_one(p)
	}
}

@(private = "file")
is_terminator :: proc "contextless" (k: Token_Kind) -> bool {
	return k == .Eof || k == .Rbrace || k == .Rp
}

@(private = "file")
State :: enum u8 {
	Cmd,
	After_Cmd,
	Collect,
	Word,
	After_Atom,
	Done,
}

@(private = "file")
fail :: proc "contextless" (p: ^Parser, why: string) -> State {
	p.why = why
	return .Done
}

// A word is complete: to whatever wanted it. The next state.
@(private = "file")
word_done :: proc "contextless" (p: ^Parser, w: i32) -> State {
	f := top(p)
	if f == nil {
		return fail(p, "unexpected word")
	}
	#partial switch f.kind {
	case .Simple, .Words:
		list_append(p, &f.a, &f.c, w)
		return .Collect
	case .Want:
		want := pop(p)
		switch want.purpose {
		case .Want_Switch:
			skip_nl(p)
			if peek(p).kind != .Lbrace {
				return fail(p, "switch needs { after its word")
			}
			_ = take(p)
			_ = push(p, {kind = .Switch_Body, a = w, from = want.from})
			_ = push(p, {kind = .List, term = .Rbrace, a = NONE})
			return .Cmd
		case .Want_Assign:
			_ = push(p, {kind = .Prefix, op = .Assign, prec = 2, a = want.a, b = w})
			return .Cmd
		case .Want_Redir_Prefix:
			_ = push(p, {kind = .Prefix, op = .Redir, prec = 2, a = w, fd0 = want.fd0, rkind = want.rkind, from = want.from})
			return .Cmd
		case .Want_Redir_Epilog:
			cmd := pop_val(p)
			n := node_new(p, .Redir, w, cmd, NONE)
			if n != NONE {
				p.nodes[n].fd0 = want.fd0
				p.nodes[n].rkind = want.rkind
			}
			_ = push_val(p, n)
			return .After_Cmd
		case .Want_Redir_Simple:
			s := top(p) // the Simple it is in
			n := node_new(p, .Redir, w, NONE, NONE)
			if n != NONE {
				p.nodes[n].fd0 = want.fd0
				p.nodes[n].rkind = want.rkind
			}
			set_from(p, n, want.from)
			if s != nil {
				list_append(p, &s.b, &s.d, n)
			}
			return .Collect
		case .Want_For_Var:
			_ = push(p, {kind = .For_Wait, a = w, from = want.from})
			return .Cmd
		case .Want_Twiddle:
			_ = push(p, {kind = .Words, purpose = .Patterns, term = .Eof, a = NONE, b = w, c = NONE, from = want.from})
			return .Collect
		case .Want_Backq:
			if peek(p).kind != .Lbrace {
				return fail(p, "` needs { after its separators")
			}
			_ = take(p)
			_ = push(p, {kind = .Backq_Body, b = w, from = want.from})
			_ = push(p, {kind = .List, term = .Rbrace, a = NONE})
			return .Cmd
		case .Paren, .Sub, .For_In, .Fn_Names, .Patterns:
			return fail(p, "unexpected word")
		}
	}
	return fail(p, "unexpected word")
}

// The list on top has ended at its terminator: what it was part of goes on.
@(private = "file")
list_done :: proc "contextless" (p: ^Parser) -> State {
	list := pop(p)
	if top(p) == nil {
		_ = push_val(p, list.a)
		return .Done
	}
	up := pop(p)
	#partial switch up.kind {
	case .Brace:
		n := node_new(p, .Brace, list.a, NONE, NONE)
		set_from(p, n, up.from)
		_ = push_val(p, n)
		return .After_Cmd
	case .If_Cond, .While_Cond:
		_ = push(p, {kind = .Prefix, op = up.kind == .If_Cond ? .If : .While, prec = 0, a = list.a, from = up.from})
		skip_nl(p)
		return .Cmd
	case .Switch_Body:
		n := node_new(p, .Switch, up.a, list.a, NONE)
		set_from(p, n, up.from)
		_ = push_val(p, n)
		return .After_Cmd
	case .Fn_Body: // its body's text kept, { to }, for whatis and export (rc's fnstr)
		n := node_new(p, .Fn, up.a, list.a, NONE)
		if n != NONE {
			p.nodes[n].s = p.lx.text[up.c:max(p.last_end, int(up.c))] // the } just taken ends it
		}
		set_from(p, n, up.from)
		_ = push_val(p, n)
		return .After_Cmd
	case .Backq_Body:
		n := node_new(p, .Backq, list.a, up.b, NONE)
		set_from(p, n, up.from)
		_ = push_val(p, n)
		return .After_Atom
	}
	return fail(p, "misplaced list")
}

@(private = "file")
cmd :: proc "contextless" (p: ^Parser) -> State {
	t := peek(p)
	f := top(p)
	if t.kind == .Nl || t.kind == .Semi {
		if f != nil && f.kind != .List { // an empty command: for a prefix waiting (a=b alone, if() alone)
			_ = push_val(p, NONE)
			return .After_Cmd
		}
		_ = take(p)
		return .Cmd
	}
	if is_terminator(t.kind) {
		if f != nil && f.kind != .List {
			_ = push_val(p, NONE)
			return .After_Cmd
		}
		if f == nil || t.kind != f.term {
			if t.kind == .Eof {
				p.incomplete = true
			}
			return fail(p, t.kind == .Eof ? "unexpected end" : "unbalanced brackets")
		}
		if t.kind != .Eof {
			_ = take(p)
		}
		return list_done(p)
	}
	#partial switch t.kind {
	case .Lbrace:
		lb := take(p)
		_ = push(p, {kind = .Brace, from = start(lb)})
		_ = push(p, {kind = .List, term = .Rbrace, a = NONE})
		return .Cmd
	case .Redir:
		r := take(p)
		_ = push(p, {kind = .Want, purpose = .Want_Redir_Prefix, fd0 = r.fd0, rkind = r.rkind, from = start(r)})
		return .Word
	case .Dup:
		r := take(p)
		_ = push(p, {kind = .Prefix, op = .Dup, prec = 2, fd0 = r.fd0, fd1 = r.fd1, from = start(r)})
		return .Cmd
	}
	if t.kind == .Word && !t.quoted && (t.kw == .In || t.kw == .Not) {
		return fail(p, "syntax error") // in and not begin no command: rc's grammar has them only after for( and if
	}
	if t.kind == .Word && !t.quoted && t.kw != .None {
		k := take(p)
		kw := k.kw
		if kw == .If && peek(p).kind == .Word && peek(p).kw == .Not {
			_ = take(p)
			skip_nl(p)
			_ = push(p, {kind = .Prefix, op = .If_Not, prec = 0, from = start(k)})
			return .Cmd
		}
		#partial switch kw {
		case .If, .While:
			if peek(p).kind != .Lp {
				return fail(p, "if and while need ( after them")
			}
			_ = take(p)
			_ = push(p, {kind = kw == .If ? .If_Cond : .While_Cond, from = start(k)})
			_ = push(p, {kind = .List, term = .Rp, a = NONE})
			return .Cmd
		case .For:
			if peek(p).kind != .Lp {
				return fail(p, "for needs ( after it")
			}
			_ = take(p)
			_ = push(p, {kind = .Want, purpose = .Want_For_Var, from = start(k)})
			return .Word
		case .Switch:
			_ = push(p, {kind = .Want, purpose = .Want_Switch, from = start(k)})
			return .Word
		case .Fn:
			_ = push(p, {kind = .Words, purpose = .Fn_Names, term = .Lbrace, a = NONE, c = NONE, from = start(k)})
			return .Collect
		case .Bang:
			_ = push(p, {kind = .Prefix, op = .Bang, prec = 2, from = start(k)})
			return .Cmd
		case .Subshell:
			_ = push(p, {kind = .Prefix, op = .Subshell, prec = 2, from = start(k)})
			return .Cmd
		case .Twiddle:
			_ = push(p, {kind = .Want, purpose = .Want_Twiddle, from = start(k)})
			return .Word
		}
	}
	if t.kind == .Word && peek2(p).kind == .Eq { // name=value [command]
		name := take(p)
		_ = take(p)
		n := node_new(p, .Word, NONE, NONE, NONE)
		if n != NONE {
			p.nodes[n].s = name.s
			p.nodes[n].from = start(name)
		}
		_ = push(p, {kind = .Want, purpose = .Want_Assign, a = n})
		return .Word
	}
	_ = push(p, {kind = .Simple, a = NONE, b = NONE, c = NONE, d = NONE})
	return .Collect
}

@(private = "file")
bin_op :: proc "contextless" (k: Token_Kind) -> Node_Kind {
	if k == .Pipe {
		return .Pipe
	}
	return k == .Andand ? .And : .Or
}

@(private = "file")
dol_op :: proc "contextless" (k: Token_Kind) -> Node_Kind {
	if k == .Dollar {
		return .Dol
	}
	return k == .Count ? .Count : .Join
}

@(private = "file")
after_cmd :: proc "contextless" (p: ^Parser) -> State {
	t := peek(p)
	#partial switch t.kind {
	case .Redir:
		r := take(p)
		_ = push(p, {kind = .Want, purpose = .Want_Redir_Epilog, fd0 = r.fd0, rkind = r.rkind})
		return .Word
	case .Dup:
		r := take(p)
		cmd := pop_val(p)
		n := node_new(p, .Dup, NONE, cmd, NONE)
		if n != NONE {
			p.nodes[n].fd0 = r.fd0
			p.nodes[n].fd1 = r.fd1
		}
		_ = push_val(p, n)
		return .After_Cmd
	case .Pipe, .Andand, .Oror:
		op := take(p)
		prec := op.kind == .Pipe ? 3 : 1
		reduce(p, prec)
		_ = push(p, {kind = .Bin, op = bin_op(op.kind), prec = u8(prec), fd0 = op.fd0, fd1 = op.fd1})
		skip_nl(p)
		return .Cmd
	}
	reduce(p, -1)
	list := top(p)
	if list == nil || list.kind != .List {
		return fail(p, "syntax error")
	}
	cmd := pop_val(p)
	if t.kind == .Amp {
		_ = take(p)
		cmd = node_new(p, .Async, cmd, NONE, NONE)
	} else if t.kind == .Semi || t.kind == .Nl {
		_ = take(p)
	} else if !is_terminator(t.kind) {
		return fail(p, "syntax error")
	}
	// The chain grows to the right, Seq(first, Seq(second, ...)), through its
	// last link (c: its node + 1), so it compiles in a stack of fixed depth.
	if cmd == NONE {
		return .Cmd
	}
	if list.a == NONE {
		list.a = cmd
	} else if list.c == 0 {
		seq := node_new(p, .Seq, list.a, cmd, NONE)
		list.a = seq
		list.c = seq + 1
	} else {
		last := list.c - 1
		seq := node_new(p, .Seq, p.nodes[last].b, cmd, NONE)
		if seq != NONE {
			p.nodes[last].b = seq
			list.c = seq + 1
		}
	}
	if cmd >= 0 && list.a >= 0 {
		p.nodes[list.a].to = p.nodes[cmd].to // the list's text, to its last
	}
	return .Cmd
}

// Words being gathered: for a simple command, a ( ) list, fn's names, ~'s patterns.
@(private = "file")
collect :: proc "contextless" (p: ^Parser) -> State {
	f := top(p)
	t := peek(p)
	list := f.kind == .Words && f.term == .Rp
	if list && t.kind == .Nl {
		_ = take(p)
		return .Collect
	}
	if t.kind == .Eq && f.kind == .Simple && f.a != NONE && p.nodes[f.a].next == NONE && f.b == NONE {
		// first=value: an assignment, its name any word ($x=1 too), as rc's grammar
		_ = take(p)
		name := f.a
		_ = pop(p)
		_ = push(p, {kind = .Want, purpose = .Want_Assign, a = name})
		return .Word
	}
	#partial switch t.kind {
	case .Word, .Dollar, .Count, .Join, .Backq, .Lp:
		return .Word
	case .Redir:
		if f.kind == .Simple {
			r := take(p)
			_ = push(p, {kind = .Want, purpose = .Want_Redir_Simple, fd0 = r.fd0, rkind = r.rkind, from = start(r)})
			return .Word
		}
	case .Dup:
		if f.kind == .Simple {
			r := take(p)
			n := node_new(p, .Dup, NONE, NONE, NONE)
			if n != NONE {
				p.nodes[n].fd0 = r.fd0
				p.nodes[n].fd1 = r.fd1
			}
			set_from(p, n, start(r))
			list_append(p, &f.b, &f.d, n)
			return .Collect
		}
	}
	done := f^
	if done.kind == .Simple {
		_ = pop(p)
		if done.a == NONE && done.b == NONE {
			return fail(p, "syntax error")
		}
		_ = push_val(p, node_new(p, .Simple, done.a, done.b, NONE))
		return .After_Cmd
	}
	switch done.purpose {
	case .Paren, .Sub, .For_In:
		if t.kind != .Rp {
			if t.kind == .Eof {
				p.incomplete = true
			}
			return fail(p, "( without )")
		}
		_ = take(p)
		_ = pop(p)
		if done.purpose == .Paren {
			n := node_new(p, .Paren, done.a, NONE, NONE)
			set_from(p, n, done.from)
			_ = push_val(p, n)
			return .After_Atom
		}
		if done.purpose == .Sub {
			n := node_new(p, .Sub, done.b, done.a, NONE)
			set_from(p, n, done.from)
			_ = push_val(p, n)
			return .After_Atom
		}
		skip_nl(p) // for(i in words)
		_ = push(p, {kind = .Prefix, op = .For, prec = 0, a = done.b, b = done.a, from = done.from})
		return .Cmd
	case .Fn_Names:
		_ = pop(p)
		if t.kind == .Lbrace {
			lb := take(p)
			_ = push(p, {kind = .Fn_Body, a = done.a, c = i32(lb.at), from = done.from})
			_ = push(p, {kind = .List, term = .Rbrace, a = NONE})
			return .Cmd
		}
		del := node_new(p, .Fn, done.a, NONE, NONE) // fn names: deletes them
		set_from(p, del, done.from)
		_ = push_val(p, del)
		return .After_Cmd
	case .Patterns:
		_ = pop(p)
		tw := node_new(p, .Twiddle, done.b, done.a, NONE)
		set_from(p, tw, done.from)
		_ = push_val(p, tw)
		return .After_Cmd
	case .Want_Switch, .Want_Assign, .Want_Redir_Prefix, .Want_Redir_Epilog, .Want_Redir_Simple, .Want_For_Var, .Want_Twiddle, .Want_Backq:
	}
	return fail(p, "syntax error")
}

@(private = "file")
atom :: proc "contextless" (p: ^Parser) -> State {
	t := take(p)
	#partial switch t.kind {
	case .Word: // = is not one: rc's grammar has it only in an assignment
		n := node_new(p, .Word, NONE, NONE, NONE)
		if n == NONE {
			return .Done
		}
		p.nodes[n].s = t.s
		p.nodes[n].from = start(t)
		p.nodes[n].quoted = t.quoted
		p.nodes[n].here = t.here
		_ = push_val(p, n)
		return .After_Atom
	case .Dollar, .Count, .Join:
		_ = push(p, {kind = .Dol, op = dol_op(t.kind), from = start(t)})
		return .Word
	case .Backq:
		if peek(p).kind == .Lbrace {
			_ = take(p)
			_ = push(p, {kind = .Backq_Body, b = NONE, from = start(t)})
			_ = push(p, {kind = .List, term = .Rbrace, a = NONE})
			return .Cmd
		}
		_ = push(p, {kind = .Want, purpose = .Want_Backq, from = start(t)})
		return .Word
	case .Lp:
		_ = push(p, {kind = .Words, purpose = .Paren, term = .Rp, a = NONE, c = NONE, from = start(t)})
		return .Collect
	case .Eof:
		p.incomplete = true
		return fail(p, "unexpected end")
	}
	return fail(p, "expected a word")
}

@(private = "file")
after_atom :: proc "contextless" (p: ^Parser) -> State {
	atom := pop_val(p)
	for f := top(p); f != nil && f.kind == .Dol; f = top(p) { // $ binds to the atom after it
		op := f.op
		dol := f.from
		_ = pop(p)
		if op == .Dol && peek(p).kind == .Sub_Lp { // $x( subscripts )
			_ = take(p)
			_ = push(p, {kind = .Words, purpose = .Sub, term = .Rp, a = NONE, b = atom, c = NONE, from = dol})
			return .Collect
		}
		atom = node_new(p, op, atom, NONE, NONE)
		set_from(p, atom, dol)
	}
	if f := top(p); f != nil && f.kind == .Conc {
		atom = node_new(p, .Conc, f.a, atom, NONE)
		_ = pop(p)
	}
	if peek(p).kind == .Caret {
		_ = take(p)
		_ = push(p, {kind = .Conc, a = atom})
		return .Word
	}
	return word_done(p, atom)
}

// for(var: then `in words)` or `)`.
@(private = "file")
for_wait :: proc "contextless" (p: ^Parser) -> State {
	f := pop(p)
	t := peek(p)
	if t.kind == .Word && t.kw == .In && !t.quoted {
		_ = take(p)
		_ = push(p, {kind = .Words, purpose = .For_In, term = .Rp, a = NONE, b = f.a, c = NONE, from = f.from})
		return .Collect
	}
	if t.kind != .Rp {
		return fail(p, "for( needs in or )")
	}
	_ = take(p)
	skip_nl(p)
	_ = push(p, {kind = .Prefix, op = .For, prec = 0, a = f.a, b = ALLARGS, from = f.from})
	return .Cmd
}

// Parses the text: the tree's root (NONE for nothing), or NONE with why set.
@(private)
parse :: proc "contextless" (p: ^Parser) -> i32 {
	_ = push(p, {kind = .List, term = .Eof, a = NONE})
	s := State.Cmd
	for steps := 0; s != .Done && p.why == "" && steps < 10_000_000; steps += 1 {
		if p.lx.failed {
			p.why = p.lx.why
			break
		}
		if f := top(p); s == .Cmd && f != nil && f.kind == .For_Wait {
			s = for_wait(p)
			continue
		}
		switch s {
		case .Cmd:
			s = cmd(p)
		case .After_Cmd:
			s = after_cmd(p)
		case .Collect:
			s = collect(p)
		case .Word:
			s = atom(p)
		case .After_Atom:
			s = after_atom(p)
		case .Done:
		}
	}
	if p.lx.failed && p.why == "" {
		p.why = p.lx.why
	}
	return p.why != "" ? NONE : pop_val(p)
}
