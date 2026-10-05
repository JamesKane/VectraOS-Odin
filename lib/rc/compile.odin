// The compiler (rc's code.c, without recursion).
//
// The tree becomes instructions for the machine, as rc's outcode makes them:
// words go onto lists on the machine's stack (Mark starts one, Word adds to
// it), and $ # " ^ and subscripts work on the lists on top. Each node is
// compiled in phases, an explicit stack of (node, phase) items holding what
// is pending: children are pushed after their parent's next phase, so they
// are compiled first.
package rc


@(private)
Op :: enum u8 {
	Mark, // a new list on the stack
	Word, // a: the string, b: its length: added to the top list
	Dol, // the top list's names: their values onto the list below
	Count, // their count
	Join, // their values joined by spaces, one word
	Sub, // the top list subscripts the name in the one below: onto the list below that
	Conc, // the top two lists concatenated, onto the one below
	Simple, // f0: async. The top list is a command: run it
	Stage, // f0/f1: the fds it pipes to the next/from the last; a: its redirections. The top list is a stage
	Pipeline, // a: stages, f0: async
	Assign, // the top list names a variable, the one below its value
	Local, // as Assign, a local of the frame, until Unlocal
	Unlocal,
	If, // a: where to go if $status is false (ifnot = it was)
	If_Not, // a: where to go unless the last if was false
	Was_True, // ifnot = false
	True, // a: where to go if $status is false
	False, // a: where to go if $status is true
	Jump, // a
	Bang, // $status negated
	For, // a: where to go when the list on top is used up; the next word into the frame's newest local
	Popm, // drops the top list
	Fn, // a: where its body ends; the top list names it (them); the body follows
	Delfn, // the top list's functions removed
	Return, // the frame ends
	Qw, // the top list joined by spaces into one word ("" for none): a subject of ~ or switch
	Settrue, // $status true: while()'s empty condition
	Match, // the top list (a subject) against the patterns below: $status
	Case, // a: where to go unless the subject (two lists down) matches the patterns on top
	Backq, // fd 1 into a capture, until Backq_End
	Backq_End, // the capture split by the separators on top (or $ifs) into words, onto the list below
	Redir, // f0: fd, f1: kind; the top list is the file
	Dup, // f0 = f1 (f1 CLOSE_FD: closed)
	Popredir, // a: how many
	Rdcmds, // the frame's reader: the next command read, compiled and run, then this again (rc's Xrdcmds)
	Eflag, // -e: exit unless $status is true
}

@(private)
Inst :: struct {
	op:     Op,
	f0, f1: u8,
	a, b:   u32,
	line:   u32, // the source line it came from, for errors
}
#assert(size_of(Inst) == 16) // upstream's rc_inst

@(private)
Code :: struct {
	refs:    u32, // the running frames and the functions that use it
	n:       u32,
	inst:    ^Inst, // in the heap: code_inst
	strings: ^u8, // in the heap: code_strings
	src:     [64]u8, // the file it came from, for errors at file:line: to its first NUL, as upstream's
}
#assert(size_of(Code) == 88) // upstream's rc_code

@(private)
code_src :: proc "contextless" (c: ^Code) -> string {
	return c_name(string(c.src[:]))
}

@(private)
code_inst :: proc "contextless" (c: ^Code) -> []Inst {
	return ([^]Inst)(c.inst)[:len(payload(c.inst)) / size_of(Inst)]
}

@(private)
code_strings :: proc "contextless" (c: ^Code) -> []u8 {
	return payload(c.strings)
}

@(private)
Compiler :: struct {
	r:     ^Rc,
	nodes: []Node,
	inst:  []Inst,
	n:     u32,
	str:   []u8,
	nstr:  int,
	why:   string,
	line:  u32, // the line of the node being compiled
	noe:   bool, // the item being compiled is in a condition: -e does not apply in it (rc's outcode(c, 0))
	heres: []Here, // the here documents' texts, by a tag word's here (plus 1)
}

@(private)
Citem :: struct {
	node:          i32,
	phase:         u8,
	stage:         bool, // a simple command that is a stage of a pipeline
	out_fd, in_fd: u8, // a stage's: what it pipes to the next stage, and from the one before (NO_FD: none)
	at:            u32, // a jump to patch, or where a loop starts
	cur:           i32, // a list being walked
	count:         u32,
	noe:           bool, // a condition's: -e does not apply in it
}

@(private)
CITEMS :: 1024
@(private)
SWITCH_MAX :: 4096 // commands in a switch's body
@(private)
NO_FD :: 255

// The compiler's stacks, kept in the interpreter rather than on a stack.
@(private)
Compiler_Scratch :: struct {
	items: [CITEMS]Citem,
	body:  [SWITCH_MAX]i32, // a switch's body, flattened
}

@(private = "file")
emit :: proc "contextless" (c: ^Compiler, op: Op, f0: u8 = 0, f1: u8 = 0, a: u32 = 0, b: u32 = 0) -> u32 {
	if int(c.n) == len(c.inst) {
		c.why = "script too long"
		return 0
	}
	c.inst[c.n] = Inst {
		op   = op,
		f0   = f0,
		f1   = f1,
		a    = a,
		b    = b,
		line = c.line,
	}
	c.n += 1
	return c.n - 1
}

@(private = "file")
emit_word :: proc "contextless" (c: ^Compiler, s: string) {
	if len(c.str) - c.nstr < len(s) + 1 {
		c.why = "script too long"
		return
	}
	copy(c.str[c.nstr:], s)
	c.str[c.nstr + len(s)] = 0
	emit(c, .Word, a = u32(c.nstr), b = u32(len(s)))
	c.nstr += len(s) + 1
}

// A here document's redirection: its text as the word, then Redir (b: quoted).
@(private = "file")
emit_here :: proc "contextless" (c: ^Compiler, rd: ^Node) {
	k := 0
	if rd.a != NONE && c.nodes[rd.a].kind == .Word {
		k = int(c.nodes[rd.a].here)
	}
	if k == 0 || k > len(c.heres) || !c.heres[k - 1].read {
		c.why = "here document never ended"
		return
	}
	h := &c.heres[k - 1]
	emit(c, .Mark)
	emit_word(c, h.body)
	emit(c, .Redir, rd.fd0, u8(Redir_Kind.Here), b = u32(h.quoted))
}

// -e after a command, as rc's Xeflag, unless in a condition.
@(private = "file")
eflag :: proc "contextless" (c: ^Compiler) {
	if c.r.flag['e'] && !c.noe {
		emit(c, .Eflag)
	}
}

@(private = "file")
patch :: proc "contextless" (c: ^Compiler, at: u32) {
	if at < c.n {
		c.inst[at].a = c.n
	}
}

// Is node n a case label: a simple command whose first word is `case`?
@(private = "file")
is_case :: proc "contextless" (c: ^Compiler, n: i32) -> bool {
	if n == NONE || c.nodes[n].kind != .Simple || c.nodes[n].a == NONE {
		return false
	}
	w := &c.nodes[c.nodes[n].a]
	return w.kind == .Word && !w.quoted && w.s == "case" // unquoted, as rc's iscase
}

// A switch's body as a list of its commands, in order (its Seq chain
// flattened); a body longer than out is an error, not cut short.
@(private = "file")
flatten :: proc "contextless" (c: ^Compiler, n: i32, out: []i32) -> int {
	stack: [dynamic; 64]i32 // the chain grows to the right (after_cmd): it needs little
	count := 0
	if n != NONE {
		append(&stack, n)
	}
	for len(stack) > 0 {
		x := stack[len(stack) - 1]
		resize(&stack, len(stack) - 1)
		if c.nodes[x].kind == .Seq {
			if len(stack) + 2 > cap(stack) {
				c.why = "switch nested too deeply"
				return 0
			}
			append(&stack, c.nodes[x].b, c.nodes[x].a) // right after left
		} else if count == len(out) {
			c.why = "switch too long"
			return 0
		} else {
			out[count] = x
			count += 1
		}
	}
	return count
}

@(private = "file")
dol_inst :: proc "contextless" (k: Node_Kind) -> Op {
	if k == .Dol {
		return .Dol
	}
	return k == .Count ? .Count : .Join
}

@(private = "file")
END_CMD :: 200 // a compile item's phase: the command it names has been compiled

@(private = "file")
is_cmd :: proc "contextless" (k: Node_Kind) -> bool { // a command, not a word
	#partial switch k {
	case .Word, .Dol, .Count, .Join, .Sub, .Conc, .Paren, .Backq:
		return false
	}
	return true
}

@(private = "file")
compile_tree :: proc "contextless" (c: ^Compiler, root: i32) -> bool {
	items := &c.r.compiler.items
	ni := 0
	// Pushes an item for node nd at phase ph, in a condition if the item
	// being compiled is or cond says it is one: false (the compile failed)
	// if there is no room.
	push :: proc "contextless" (c: ^Compiler, items: ^[CITEMS]Citem, ni: ^int, nd: i32, ph: u8, cond := false) -> bool {
		if ni^ == CITEMS {
			c.why = "nested too deeply"
			return false
		}
		items[ni^] = Citem {
			node  = nd,
			phase = ph,
			noe   = c.noe || cond,
		}
		ni^ += 1
		return true
	}
	// Pushes an item back at its next phase, with what it keeps: it was just
	// taken off, so there is room.
	again :: proc "contextless" (items: ^[CITEMS]Citem, ni: ^int, it: ^Citem, ph: u8) {
		it.phase = ph
		items[ni^] = it^
		ni^ += 1
	}
	if root != NONE {
		push(c, items, &ni, root, 0) or_return
	}
	for ni > 0 && c.why == "" {
		ni -= 1
		it := items[ni]
		if it.node == NONE {
			continue
		}
		c.noe = it.noe
		t := &c.nodes[it.node]
		if t.line != 0 {
			c.line = t.line
		}
		// As rc's outcode: a command other than if not and a sequence clears
		// iflast as it starts, and sets it, once compiled, to whether it was an if.
		if it.phase == END_CMD {
			c.r.iflast = t.kind == .If
			continue
		}
		if it.phase == 0 && is_cmd(t.kind) && t.kind != .Seq && t.kind != .If_Not {
			c.r.iflast = false
			// Room for the command's next phase too, which upstream pushes
			// unchecked, past its array when this took the last place.
			if ni + 1 >= CITEMS {
				c.why = "nested too deeply"
				return false
			}
			push(c, items, &ni, it.node, END_CMD) or_return
		}
		if it.phase == 0 && t.kind == .If_Not && !c.r.iflast {
			c.why = "`if not' does not follow `if(...)'"
			return false
		}
		switch t.kind {
		case .Word:
			emit_word(c, t.s)
		case .Dol, .Count, .Join:
			if it.phase == 0 {
				emit(c, .Mark)
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.a, 0) or_return
			} else {
				emit(c, dol_inst(t.kind))
			}
		case .Sub: // $name(subscripts)
			if it.phase == 0 {
				emit(c, .Mark)
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.a, 0) or_return
			} else if it.phase == 1 {
				emit(c, .Mark)
				it.cur = t.b
				again(items, &ni, &it, 2)
			} else if it.cur == NONE { // each subscript word, then Sub
				emit(c, .Sub)
			} else {
				w := it.cur
				it.cur = c.nodes[w].next
				again(items, &ni, &it, 2)
				push(c, items, &ni, w, 0) or_return
			}
		case .Conc:
			if it.phase == 0 {
				emit(c, .Mark)
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.a, 0) or_return
			} else if it.phase == 1 {
				emit(c, .Mark)
				again(items, &ni, &it, 2)
				push(c, items, &ni, t.b, 0) or_return
			} else {
				emit(c, .Conc)
			}
		case .Paren: // its words, onto the list being made
			if it.phase == 0 {
				it.cur = t.a
			}
			if it.cur != NONE {
				w := it.cur
				it.cur = c.nodes[w].next
				again(items, &ni, &it, 1)
				push(c, items, &ni, w, 0) or_return
			}
		case .Backq: // `{body}: its separators, then the capture
			if it.phase == 0 {
				emit(c, .Mark)
				if t.b == NONE {
					emit(c, .Mark)
					emit_word(c, "ifs")
					emit(c, .Dol)
					again(items, &ni, &it, 1)
				} else {
					again(items, &ni, &it, 1)
					push(c, items, &ni, t.b, 0) or_return
				}
			} else if it.phase == 1 {
				emit(c, .Backq)
				again(items, &ni, &it, 2)
				push(c, items, &ni, t.a, 0) or_return
			} else {
				emit(c, .Backq_End)
			}
		case .Simple: // its redirections, its words, the command, then the redirections undone
			switch it.phase {
			case 0:
				it.cur = t.b
				it.count = 0
				again(items, &ni, &it, 1)
			case 1: // the next redirection
				if it.cur == NONE {
					emit(c, .Mark)
					it.cur = t.a
					again(items, &ni, &it, 2)
				} else {
					rd := &c.nodes[it.cur]
					r := it.cur
					it.cur = rd.next
					it.count += 1
					if rd.kind == .Dup {
						emit(c, .Dup, rd.fd0, rd.fd1)
						again(items, &ni, &it, 1)
					} else if rd.rkind == .Here {
						emit_here(c, rd)
						again(items, &ni, &it, 1)
					} else {
						emit(c, .Mark)
						it.at = u32(r)
						again(items, &ni, &it, 5) // then Redir, then back to 1
						push(c, items, &ni, rd.a, 0) or_return
					}
				}
			case 5:
				rd := &c.nodes[it.at]
				emit(c, .Redir, rd.fd0, u8(rd.rkind))
				again(items, &ni, &it, 1)
			case 2: // the next word
				if it.cur == NONE {
					if it.stage {
						emit(c, .Stage, it.out_fd, it.in_fd, it.count)
					} else {
						emit(c, .Simple)
						eflag(c)
					}
					if it.count != 0 {
						emit(c, .Popredir, a = it.count)
					}
				} else {
					w := it.cur
					it.cur = c.nodes[w].next
					again(items, &ni, &it, 2)
					push(c, items, &ni, w, 0) or_return
				}
			}
		case .Seq:
			push(c, items, &ni, t.b, 0) or_return
			push(c, items, &ni, t.a, 0) or_return
		case .Brace, .Subshell:
			push(c, items, &ni, t.kind == .Brace ? t.a : t.b, 0) or_return
		case .Async, .Pipe: // a pipeline of programs: each stage, leftmost first, then Pipeline
			async := t.kind == .Async
			chain := async ? t.a : it.node
			if async && chain != NONE && c.nodes[chain].kind == .Simple { // program &
				if it.phase == 0 {
					again(items, &ni, &it, 1)
					push(c, items, &ni, chain, 0) or_return
				} else { // its Simple, the last one emitted, made asynchronous
					#reverse for &inst in c.inst[:c.n] {
						if inst.op == .Simple {
							inst.f0 = 1
							break
						}
					}
				}
				break
			}
			if async && (chain == NONE || c.nodes[chain].kind != .Pipe) {
				c.why = "& runs programs only, not blocks or functions (for now)"
				return false
			}
			if it.phase == 1 {
				emit(c, .Pipeline, u8(async), a = it.count)
				break
			}
			right: [32]i32 // the stages, right to left
			fd0, fd1: [32]u8 // the joints' descriptors, right to left
			n := 0
			x := chain
			for ; x != NONE && c.nodes[x].kind == .Pipe; x = c.nodes[x].a {
				if n == 31 {
					c.why = "pipeline too long"
					return false
				}
				right[n], fd0[n], fd1[n] = c.nodes[x].b, c.nodes[x].fd0, c.nodes[x].fd1
				n += 1
			}
			right[n] = x // the leftmost
			n += 1
			it.count = u32(n)
			again(items, &ni, &it, 1)
			for k in 0 ..< n { // right to left onto the stack: the leftmost compiles first
				node := right[k]
				if node == NONE || c.nodes[node].kind != .Simple {
					c.why = "a pipeline's stages must be programs, not blocks or functions (for now)"
					return false
				}
				// Stage k from the right: it pipes out on joint k-1's fd0, in on joint k's fd1.
				push(c, items, &ni, node, 0) or_return
				items[ni - 1].stage = true
				items[ni - 1].out_fd = k > 0 ? fd0[k - 1] : NO_FD
				items[ni - 1].in_fd = k + 1 < n ? fd1[k] : NO_FD
			}
		case .And, .Or:
			if it.phase == 0 {
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.a, 0, cond = true) or_return
			} else if it.phase == 1 {
				it.at = emit(c, t.kind == .And ? .True : .False)
				again(items, &ni, &it, 2)
				push(c, items, &ni, t.b, 0) or_return
			} else {
				patch(c, it.at)
			}
		case .Bang:
			if it.phase == 0 {
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.b, 0) or_return
			} else {
				emit(c, .Bang)
			}
		case .If:
			if it.phase == 0 {
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.a, 0, cond = true) or_return
			} else if it.phase == 1 {
				it.at = emit(c, .If)
				again(items, &ni, &it, 2)
				push(c, items, &ni, t.b, 0) or_return
			} else {
				emit(c, .Was_True)
				patch(c, it.at)
			}
		case .If_Not:
			if it.phase == 0 {
				it.at = emit(c, .If_Not)
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.b, 0) or_return
			} else {
				patch(c, it.at)
			}
		case .While:
			if it.phase == 0 {
				it.count = c.n // where the condition starts
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.a, 0, cond = true) or_return
			} else if it.phase == 1 {
				if c.n == it.count {
					emit(c, .Settrue) // while(): an empty condition is true
				}
				it.at = emit(c, .True)
				again(items, &ni, &it, 2)
				push(c, items, &ni, t.b, 0) or_return
			} else {
				emit(c, .Jump, a = it.count)
				patch(c, it.at)
			}
		case .For: // for(var in words) body: the words on the stack, the variable a local
			switch it.phase {
			case 0:
				emit(c, .Mark)
				if t.b == ALLARGS {
					emit(c, .Mark)
					emit_word(c, "*")
					emit(c, .Dol)
					again(items, &ni, &it, 2)
				} else {
					it.cur = t.b
					again(items, &ni, &it, 1)
				}
			case 1: // each word
				if it.cur == NONE {
					again(items, &ni, &it, 2)
				} else {
					w := it.cur
					it.cur = c.nodes[w].next
					again(items, &ni, &it, 1)
					push(c, items, &ni, w, 0) or_return
				}
			case 2:
				emit(c, .Mark) // the local's (empty) value
				emit(c, .Mark)
				again(items, &ni, &it, 3)
				push(c, items, &ni, t.a, 0) or_return
			case 3:
				emit(c, .Local)
				it.count = emit(c, .For)
				again(items, &ni, &it, 4)
				push(c, items, &ni, t.c, 0) or_return
			case:
				emit(c, .Jump, a = it.count)
				patch(c, it.count)
				emit(c, .Unlocal)
				emit(c, .Popm) // the used-up list
			}
		case .Assign: // name=value [command]
			switch it.phase {
			case 0:
				emit(c, .Mark)
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.b, 0) or_return
			case 1:
				emit(c, .Mark)
				again(items, &ni, &it, 2)
				push(c, items, &ni, t.a, 0) or_return
			case 2:
				if t.c == NONE {
					emit(c, .Assign)
				} else {
					emit(c, .Local)
					again(items, &ni, &it, 3)
					push(c, items, &ni, t.c, 0) or_return
				}
			case:
				emit(c, .Unlocal)
			}
		case .Redir:
			switch it.phase {
			case 0:
				if t.rkind == .Here {
					emit_here(c, t)
					again(items, &ni, &it, 2)
					push(c, items, &ni, t.b, 0) or_return
					break
				}
				emit(c, .Mark)
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.a, 0) or_return
			case 1:
				emit(c, .Redir, t.fd0, u8(t.rkind))
				again(items, &ni, &it, 2)
				push(c, items, &ni, t.b, 0) or_return
			case:
				emit(c, .Popredir, a = 1)
			}
		case .Dup:
			if it.phase == 0 {
				emit(c, .Dup, t.fd0, t.fd1)
				again(items, &ni, &it, 1)
				push(c, items, &ni, t.b, 0) or_return
			} else {
				emit(c, .Popredir, a = 1)
			}
		case .Twiddle: // ~ subject patterns
			switch it.phase {
			case 0:
				emit(c, .Mark)
				it.cur = t.b
				again(items, &ni, &it, 1)
			case 1:
				if it.cur == NONE {
					emit(c, .Mark)
					again(items, &ni, &it, 2)
					push(c, items, &ni, t.a, 0) or_return
				} else {
					w := it.cur
					it.cur = c.nodes[w].next
					again(items, &ni, &it, 1)
					push(c, items, &ni, w, 0) or_return
				}
			case:
				emit(c, .Qw) // the subject one word, as rc's
				emit(c, .Match)
				eflag(c)
			}
		case .Fn: // fn names { body }: the names, Fn, the body inline, Return
			switch it.phase {
			case 0:
				emit(c, .Mark)
				it.cur = t.a
				again(items, &ni, &it, 1)
			case 1:
				if it.cur != NONE {
					w := it.cur
					it.cur = c.nodes[w].next
					again(items, &ni, &it, 1)
					push(c, items, &ni, w, 0) or_return
				} else if t.b == NONE {
					emit(c, .Delfn)
				} else {
					it.at = emit(c, .Fn)
					again(items, &ni, &it, 2)
					push(c, items, &ni, t.b, 0) or_return
				}
			case:
				emit(c, .Return)
				patch(c, it.at)
			}
		case .Switch: // the subject once; each case's patterns tested against it; Popm
			// Flattened again at each visit: a switch in the body uses the
			// same room.
			body := c.r.compiler.body[:]
			n := flatten(c, t.b, body)
			if it.phase == 0 && (n == 0 || !is_case(c, body[0])) {
				c.why = "case missing in switch"
				break
			}
			if it.phase == 0 {
				emit(c, .Mark)
				it.cur = 0 // the next command of the body
				it.at = 0 // the pending Case to patch, + 1 (0: none)
				it.count = 0 // the Jumps to the end, as a chain through their a's, + 1
				again(items, &ni, &it, 6)
				push(c, items, &ni, t.a, 0) or_return
				break
			}
			if it.phase == 6 { // the subject is on the stack: one word, as rc's
				emit(c, .Qw)
				it.phase = 1
			}
			if it.phase == 3 { // a case's patterns are on the stack: its test
				it.at = emit(c, .Case) + 1
				it.phase = 1
			}
			if it.phase == 4 { // after one of the body's commands
				it.phase = 1
			}
			if int(it.cur) >= n { // the end: every jump to it, and the last case's miss, land here
				if it.at != 0 {
					patch(c, it.at - 1)
				}
				for j := it.count; j != 0; {
					next := c.inst[j - 1].a
					c.inst[j - 1].a = c.n
					j = next
				}
				emit(c, .Popm)
				break
			}
			cmd := body[it.cur]
			it.cur += 1
			if is_case(c, cmd) {
				if it.at != 0 { // the case before: done, to the end; its miss, here
					j := emit(c, .Jump, a = it.count)
					it.count = j + 1
					patch(c, it.at - 1)
				}
				emit(c, .Mark)
				w := c.nodes[c.nodes[cmd].a].next // the patterns, after `case`
				again(items, &ni, &it, 3)
				// Its pattern words, each pushed so they compile in order.
				ws: [dynamic; 64]i32
				for ; w != NONE && len(ws) < cap(ws); w = c.nodes[w].next {
					append(&ws, w)
				}
				if w != NONE {
					c.why = "too many patterns in a case"
					return false
				}
				#reverse for x in ws {
					push(c, items, &ni, x, 0) or_return
				}
			} else {
				again(items, &ni, &it, 4)
				push(c, items, &ni, cmd, 0) or_return
			}
		}
	}
	return c.why == ""
}

// The text compiled into code: nil on a syntax error (in err), or if more
// text could finish it (incomplete^ set). As upstream's, incomplete^ is left
// as it was when there is no memory to parse the text at all.
@(private)
compile_text :: proc "contextless" (r: ^Rc, text: string, line: u32, incomplete: ^bool) -> (code: ^Code) {
	p := (^Parser)(heap_alloc(r, PARSER_BYTES))
	if p == nil {
		return nil
	}
	scratch := 2 * len(text) + 64
	nodes := len(text) + 32
	p.lx = Lexer {
		text = text,
		line = line,
	}
	if s := heap_alloc(r, scratch); s != nil {
		p.lx.scratch = ([^]u8)(s)[:scratch]
	}
	if s := heap_alloc(r, nodes * NODE_BYTES); s != nil {
		p.nodes = ([^]Node)(s)[:nodes]
	}
	p.line = line
	if p.lx.scratch != nil && p.nodes != nil {
		root := parse(p)
		incomplete^ = p.incomplete || p.lx.incomplete
		if p.why != "" { // as rc's yyerror: file:line: message, which is $status too
			buf: [96]u8
			set_error(r, place(buf[:], string(r.src[:]), p.line), ": ", p.why)
			if !incomplete^ {
				set_status(r, p.why)
			}
		} else {
			c := Compiler {
				r     = r,
				nodes = p.nodes,
				heres = p.lx.heres[:],
			}
			insts := nodes * 4 + 16
			strs := scratch + 64
			if s := heap_alloc(r, insts * size_of(Inst)); s != nil {
				c.inst = ([^]Inst)(s)[:insts]
			}
			if s := heap_alloc(r, strs); s != nil {
				c.str = ([^]u8)(s)[:strs]
			}
			if c.inst != nil && c.str != nil && compile_tree(&c, root) {
				code = heap_new(r, Code)
				if code != nil {
					code^ = {
						refs    = 1,
						n       = c.n,
						inst    = raw_data(c.inst),
						strings = raw_data(c.str),
					}
					copy(code.src[:len(code.src) - 1], c_name(string(r.src[:])))
				} else {
					heap_free(r, raw_data(c.inst))
					heap_free(r, raw_data(c.str))
				}
			} else {
				buf: [96]u8
				why := c.why != "" ? c.why : "out of memory"
				set_error(r, place(buf[:], string(r.src[:]), c.line), ": ", why)
				set_status(r, why)
				heap_free(r, raw_data(c.inst))
				heap_free(r, raw_data(c.str))
			}
		}
	}
	heap_free(r, raw_data(p.lx.scratch))
	heap_free(r, raw_data(p.nodes))
	heap_free(r, p)
	return
}
