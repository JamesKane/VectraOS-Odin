package ns

// newns: namespace(6) files (upstream ADR-0009), as Plan 9's newns reads
// them.
//
// One operation a line: mount [-abcC] SERVICE OLD [SPEC], bind [-abcC] NEW
// OLD, unmount [NEW] OLD, cd DIR, clear, and `. FILE`, which includes another
// namespace file. Words are separated by spaces and tabs; a word in single
// quotes may hold them ('' is a quote). $NAME is replaced by the variable's
// value, NAME ending at white space, a '/', a '$' or a quote. A line whose
// first word starts with # is a comment. print writes the same form.
//
// This file parses; who applies an operation decides what a SERVICE is: svcd
// gives a mount the post /srv/NAME names, and a process the connection it
// already has from that service (mount_srv).

import "abi:vx"

Op_Kind :: enum u8 {
	Mount,
	Bind,
	Unmount,
	Cd,
	Clear,
	Include,
}

Op :: struct {
	kind:  Op_Kind,
	flags: Flags, // .After, .Before, .Create
	args:  [dynamic; 3]string, // mount: SERVICE OLD [SPEC]; bind: NEW OLD; unmount: [NEW] OLD; cd, .: one
	line:  int, // its line in the file, from 1
}

// A namespace file being read. Zero but for text (and var) is its start. The
// words an Op holds point into words, and last until the next line is read.
Script :: struct {
	text:  string,
	pos:   int,
	line:  int,
	// $NAME's value, or ""; may be nil (no variables).
	var:   proc "contextless" (ctx: rawptr, name: string) -> string,
	ctx:   rawptr,
	words: [MAX_PATH * 4]u8, // the expanded words of the line last read
}

@(private="file")
is_blank :: proc "contextless" (c: u8) -> bool {
	return c == ' ' || c == '\t'
}

// The line's words, expanded into s.words; ok is false if a quote is not
// closed or the words do not fit.
@(private="file")
script_words :: proc "contextless" (s: ^Script, line: string, words: ^[dynamic; 6]string) -> (ok: bool) {
	used, i := 0, 0
	for i < len(line) {
		for i < len(line) && is_blank(line[i]) {
			i += 1
		}
		if i == len(line) {
			break
		}
		if len(words) == cap(words) {
			return false
		}
		start := used
		quoted := false
		for i < len(line) && (quoted || !is_blank(line[i])) {
			c := line[i]
			i += 1
			if c == '\'' {
				if quoted && i < len(line) && line[i] == '\'' {
					i += 1 // '' inside quotes: one quote
				} else {
					quoted = !quoted
					continue
				}
			} else if c == '$' && !quoted {
				name := i
				for i < len(line) && !is_blank(line[i]) && line[i] != '/' && line[i] != '$' && line[i] != '\'' {
					i += 1
				}
				v := s.var != nil ? s.var(s.ctx, line[name:i]) : ""
				if len(v) > len(s.words) - used {
					return false
				}
				used += copy(s.words[used:], v)
				continue
			}
			if used == len(s.words) {
				return false
			}
			s.words[used] = c
			used += 1
		}
		if quoted {
			return false
		}
		_ = append(words, string(s.words[start:used]))
	}
	return true
}

@(private="file")
Op_Syntax :: struct {
	name:     string,
	kind:     Op_Kind,
	min, max: int, // words after the operation and its flags
	flags:    bool, // takes -abcC
}

@(private="file", rodata)
OPS := [?]Op_Syntax {
	{"mount", .Mount, 2, 3, true},
	{"bind", .Bind, 2, 2, true},
	{"unmount", .Unmount, 1, 2, false},
	{"cd", .Cd, 1, 1, false},
	{"clear", .Clear, 0, 0, false},
	{".", .Include, 1, 1, false},
}

// The next operation: Ok, Err_Not_Found at the end of the file, or
// Err_Invalid for a line that is not one (op.line says which).
@(require_results)
script_next :: proc "contextless" (s: ^Script, op: ^Op) -> vx.Status {
	for {
		if s.pos >= len(s.text) {
			return .Err_Not_Found
		}
		start := s.pos
		for s.pos < len(s.text) && s.text[s.pos] != '\n' {
			s.pos += 1
		}
		line := s.text[start:s.pos]
		s.pos += 1
		s.line += 1
		op^ = {
			line = s.line,
		}
		first := 0
		for first < len(line) && is_blank(line[first]) {
			first += 1
		}
		if first < len(line) && line[first] == '#' {
			continue // a comment, whatever it holds
		}
		w: [dynamic; 6]string
		if !script_words(s, line, &w) {
			return .Err_Invalid
		}
		if len(w) == 0 {
			continue
		}
		syntax: ^Op_Syntax
		for &o in OPS {
			if o.name == w[0] {
				syntax = &o
				break
			}
		}
		if syntax == nil {
			return .Err_Invalid
		}
		at := 1
		if syntax.flags && len(w) > 1 && len(w[1]) > 1 && w[1][0] == '-' {
			for f in transmute([]u8)w[1][1:] {
				switch f {
				case 'a':
					op.flags += {.After}
				case 'b':
					op.flags += {.Before}
				case 'c':
					op.flags += {.Create}
				case 'C': // caching: nothing to do here
				case:
					return .Err_Invalid
				}
			}
			if op.flags >= {.After, .Before} {
				return .Err_Invalid
			}
			at = 2
		}
		op.kind = syntax.kind
		argc := len(w) - at
		if argc < syntax.min || argc > syntax.max {
			return .Err_Invalid
		}
		_ = append(&op.args, ..w[at:])
		return .Ok
	}
}

// Mounts, at old, the service src a connection of this namespace already
// came from (another attach on it): how ns output replays in the process that
// wrote it, or a child that copied its namespace. Err_Not_Found if none did.
@(require_results)
mount_srv :: proc "contextless" (ns: ^Namespace, src, aname, old: string, flags: Flags) -> vx.Status {
	for &c in ns.conns {
		if c.client != nil && string(c.src[:]) == src {
			return mount(ns, c.client, c.connector, src, aname, old, flags)
		}
	}
	return .Err_Not_Found
}
