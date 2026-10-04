// The lexer (lex.c in rc).
package rc

@(private)
Token_Kind :: enum u8 {
	Eof,
	Nl,
	Word,
	Dollar, // $
	Count, // $#
	Join, // $"
	Sub_Lp, // ( right after $name: a subscript
	Caret,
	Backq,
	Lp,
	Rp,
	Lbrace,
	Rbrace,
	Semi,
	Amp,
	Andand,
	Oror,
	Pipe, // fd0, fd1
	Eq,
	Redir, // rkind, fd0
	Dup, // fd0 = fd1, or (fd1 CLOSE_FD) a close
}

@(private)
Keyword :: enum u8 {
	None,
	For,
	In,
	While,
	If,
	Not,
	Switch,
	Fn,
	Twiddle,
	Bang,
	Subshell,
}

@(private)
CLOSE_FD :: 255 // [n=]: fd1 of a close

@(private)
Token :: struct {
	kind:   Token_Kind,
	kw:     Keyword, // a bare word that is a keyword, where one may be
	quoted: bool, // a word written in quotes
	adj:    bool, // nothing between it and the token before
	fd0:    u8,
	fd1:    u8, // a word's: 1 if it is a variable's name, after $
	rkind:  Open_Kind,
	s:      string, // a word's text, unquoted, its glob characters marked (GLOB before them)
	line:   u32,
}

@(private)
GLOB :: '\x01' // before a * ? or [ written bare: they glob

@(private)
Lexer :: struct {
	text:         string,
	p:            int,
	pending:      Token, // a token held back behind a free caret
	scratch:      []u8, // where word texts are kept for the parse
	used:         int,
	why:          string,
	line:         u32,
	prev_kind:    Token_Kind, // of the token before: all a free caret or a subscript needs of it
	prev_name:    bool, // it was a variable's name
	has_pending:  bool,
	after_dollar: bool,
	failed:       bool,
	incomplete:   bool, // it failed only for the text ending: in a quote, or after a \ that ends a line
}

@(private = "file")
word_char :: proc "contextless" (c: u8) -> bool {
	switch c {
	case '\n', ' ', '\t', '#', ';', '&', '|', '^', '$', '=', '`', '\'', '{', '}', '(', ')', '<', '>', 0:
		return false
	}
	return true
}

@(private = "file")
name_char :: proc "contextless" (c: u8) -> bool { // a variable name's characters
	if c <= ' ' {
		return false
	}
	switch c {
	case '!', '"', '#', '$', '%', '&', '\'', '(', ')', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '`', '{', '|', '}', '~':
		return false
	}
	return true
}

@(private = "file")
lex_keep :: proc "contextless" (lx: ^Lexer, n: int) -> []u8 {
	if len(lx.scratch) - lx.used < n + 1 {
		lx.failed = true
		lx.why = "script too long"
		return nil
	}
	s := lx.scratch[lx.used:][:n + 1]
	lx.used += n + 1
	return s
}

@(private = "file")
keyword :: proc "contextless" (s: string) -> Keyword {
	switch s {
	case "for":
		return .For
	case "in":
		return .In
	case "while":
		return .While
	case "if":
		return .If
	case "not":
		return .Not
	case "switch":
		return .Switch
	case "fn":
		return .Fn
	case "~":
		return .Twiddle
	case "!":
		return .Bang
	case "@":
		return .Subshell
	}
	return .None
}

@(private = "file")
digit :: proc "contextless" (lx: ^Lexer) -> bool {
	return lx.p < len(lx.text) && lx.text[lx.p] >= '0' && lx.text[lx.p] <= '9'
}

@(private = "file")
at :: proc "contextless" (lx: ^Lexer, c: u8) -> bool {
	return lx.p < len(lx.text) && lx.text[lx.p] == c
}

// A [n] or [n=m] or [n=] after a redirection or pipe: false if malformed.
@(private = "file")
lex_fds :: proc "contextless" (lx: ^Lexer, fd0, fd1: ^u8) -> (eq: bool, ok: bool) {
	if !at(lx, '[') {
		return false, true
	}
	lx.p += 1
	if !digit(lx) {
		return false, false
	}
	fd0^ = lx.text[lx.p] - '0'
	lx.p += 1
	if at(lx, '=') {
		lx.p += 1
		eq = true
		fd1^ = CLOSE_FD
		if digit(lx) {
			fd1^ = lx.text[lx.p] - '0'
			lx.p += 1
		}
	}
	if !at(lx, ']') {
		return eq, false
	}
	lx.p += 1
	return eq, true
}

// A \ that ends a line, which is white space wherever it is: it ends a word.
@(private = "file")
continues :: proc "contextless" (s: string, q: int) -> bool {
	return q < len(s) && s[q] == '\\' && (q + 1 == len(s) || s[q + 1] == '\n')
}

@(private = "file")
lex_fail :: proc "contextless" (lx: ^Lexer, why: string, incomplete := false) {
	lx.failed = true
	lx.why = why
	if incomplete {
		lx.incomplete = true
	}
}

@(private = "file")
lex_raw :: proc "contextless" (lx: ^Lexer) -> (t: Token) {
	text := lx.text
	end := len(text)
	t.line = lx.line
	start := lx.p
	for { // white space, line continuations, comments
		for lx.p < end && (text[lx.p] == ' ' || text[lx.p] == '\t') {
			lx.p += 1
		}
		if lx.p + 2 < end && text[lx.p] == '\\' && text[lx.p + 1] == '\n' {
			lx.p += 2
			lx.line += 1
			continue
		}
		if continues(text, lx.p) { // a \ that ends the text: the line goes on, in more text
			lex_fail(lx, "unexpected end", true)
			return
		}
		if at(lx, '#') {
			for lx.p < end && text[lx.p] != '\n' {
				lx.p += 1
			}
		}
		break
	}
	t.adj = lx.p == start
	t.line = lx.line
	if lx.p >= end {
		return
	}
	c := text[lx.p]
	if lx.after_dollar && c != '\'' && c != '(' && c != '`' && c != '$' && c != '{' { // a variable's name
		lx.after_dollar = false
		s := lx.p
		for lx.p < end && name_char(text[lx.p]) {
			lx.p += 1
		}
		if lx.p == s { // $ alone, or before something no name starts with
			lex_fail(lx, "bad $ name")
			return
		}
		t.kind = .Word
		if keep := lex_keep(lx, lx.p - s); keep != nil {
			t.s = string(keep[:copy(keep, text[s:lx.p])])
		}
		return
	}
	lx.after_dollar = false
	lx.p += 1
	switch c {
	case '\n':
		lx.line += 1
		t.kind = .Nl
	case ';':
		t.kind = .Semi
	case '^':
		t.kind = .Caret
	case '`':
		t.kind = .Backq
	case '(': // right after a variable's name: a subscript
		t.kind = t.adj && lx.prev_kind == .Word && lx.prev_name ? .Sub_Lp : .Lp
	case ')':
		t.kind = .Rp
	case '{':
		t.kind = .Lbrace
	case '}':
		t.kind = .Rbrace
	case '=':
		t.kind = .Eq
	case '$':
		lx.after_dollar = true
		t.kind = .Dollar
		if at(lx, '#') {
			lx.p += 1
			t.kind = .Count
		} else if at(lx, '"') {
			lx.p += 1
			t.kind = .Join
		}
	case '&':
		t.kind = .Amp
		if at(lx, '&') {
			lx.p += 1
			t.kind = .Andand
		}
	case '|':
		if at(lx, '|') {
			lx.p += 1
			t.kind = .Oror
			return
		}
		t.fd0, t.fd1 = 1, 0
		if _, ok := lex_fds(lx, &t.fd0, &t.fd1); !ok || t.fd1 == CLOSE_FD {
			lex_fail(lx, "bad |[n=m]")
		}
		t.kind = .Pipe
	case '<', '>':
		t.kind = .Redir
		t.fd0 = c == '<' ? 0 : 1
		t.rkind = c == '<' ? .Read : .Write
		if c == '>' && at(lx, '>') {
			lx.p += 1
			t.rkind = .Append
		} else if c == '<' && at(lx, '>') {
			lx.p += 1
			t.rkind = .Rdwr
		}
		eq, ok := lex_fds(lx, &t.fd0, &t.fd1)
		if !ok {
			lex_fail(lx, "bad >[n=m]")
		}
		if eq {
			t.kind = .Dup
		}
	case '\'': // a quoted word: '' is a quote
		n := 0
		for q := lx.p;; q += 1 {
			if q >= end {
				lex_fail(lx, "unterminated quote", true)
				return
			}
			if text[q] == '\n' {
				lx.line += 1
			}
			if text[q] == '\'' && (q + 1 >= end || text[q + 1] != '\'') {
				break
			}
			if text[q] == '\'' {
				q += 1
			}
			n += 1
		}
		s := lex_keep(lx, n)
		if s == nil {
			return
		}
		k := 0
		for ; text[lx.p] != '\'' || (lx.p + 1 < end && text[lx.p + 1] == '\''); lx.p += 1 {
			if text[lx.p] == '\'' {
				lx.p += 1
			}
			s[k] = text[lx.p]
			k += 1
		}
		lx.p += 1
		t.kind = .Word
		t.s = string(s[:k])
		t.quoted = true
	case:
		// A bare word: its glob characters marked.
		lx.p -= 1
		s := lx.p
		n := 0
		for q := s; q < end && word_char(text[q]) && !continues(text, q); q += 1 {
			n += text[q] == '*' || text[q] == '?' || text[q] == '[' ? 2 : 1
		}
		keep := lex_keep(lx, n)
		if keep == nil {
			return
		}
		k := 0
		for ; lx.p < end && word_char(text[lx.p]) && !continues(text, lx.p); lx.p += 1 {
			if text[lx.p] == '*' || text[lx.p] == '?' || text[lx.p] == '[' {
				keep[k] = GLOB
				k += 1
			}
			keep[k] = text[lx.p]
			k += 1
		}
		t.kind = .Word
		t.s = string(keep[:k])
		t.kw = keyword(text[s:lx.p])
	}
	return
}

@(private)
wordish :: proc "contextless" (k: Token_Kind) -> bool {
	#partial switch k {
	case .Word, .Dollar, .Count, .Join, .Backq:
		return true
	}
	return false
}

// The next token, with rc's free carets: a word written right after a word
// (or a variable's name) is joined to it, as if by ^.
@(private)
lex :: proc "contextless" (lx: ^Lexer) -> Token {
	if lx.has_pending {
		lx.has_pending = false
		lx.prev_kind, lx.prev_name = lx.pending.kind, lx.pending.fd1 == 1
		return lx.pending
	}
	name := lx.after_dollar
	t := lex_raw(lx)
	if name {
		t.fd1 = 1 // a variable's name: a subscript may follow, and it is never a keyword
		t.kw = .None
	} else if t.kind == .Word {
		t.fd1 = 0
	}
	if t.adj && lx.prev_kind == .Word && wordish(t.kind) && !name {
		lx.pending = t
		lx.has_pending = true
		caret := Token {
			kind = .Caret,
			line = t.line,
			adj  = true,
		}
		lx.prev_kind, lx.prev_name = .Caret, false
		return caret
	}
	lx.prev_kind, lx.prev_name = t.kind, t.fd1 == 1
	return t
}
