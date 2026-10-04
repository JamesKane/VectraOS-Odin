// gsh: the shell, small and in rc's manner.
//
//   ls /; cat /proc/1/status            commands, separated by ; or newlines
//   ns | tail -1                        pipes
//   echo kill > /proc/2/ctl             output into a file
//   pid=2; echo $pid 'a b'              variables, and quoting ('' is a quote)
//   bind -a /boot/bin /bin              builtins: bind, unmount, exit
//
// A command is a program found as given (a path) or in /bin, then
// /boot/bin, through the shell's namespace. It is loaded by the shell and
// spawned with a copy of the namespace, the console, and its end of any
// pipe. A pipe is a channel; output into a file goes through one too, and the
// shell copies it into the file. Commands exit by themselves; the shell waits
// for them all.
package gsh

import vx "abi:vx"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

MAX_WORDS :: 64
MAX_PIPELINE :: 8

space: ns.Namespace

// --- Variables ---

// A variable whose name is empty is a free slot.
Var :: struct {
	name:  [dynamic; 32]u8,
	value: [dynamic; 256]u8,
}

vars: [32]Var

var_get :: proc "contextless" (name: string) -> string {
	for &v in vars {
		if len(v.name) > 0 && string(v.name[:]) == name {
			return string(v.value[:])
		}
	}
	return ""
}

var_set :: proc "contextless" (name, value: string) {
	slot := len(vars)
	for &v, i in vars {
		same := len(v.name) > 0 && string(v.name[:]) == name
		if same || (slot == len(vars) && len(v.name) == 0) {
			slot = i
		}
	}
	if slot == len(vars) || len(name) > cap(vars[0].name) || len(value) > cap(vars[0].value) {
		rt.print("gsh: too many variables, or too long\n")
		return
	}
	v := &vars[slot]
	clear(&v.name)
	_ = append(&v.name, name)
	clear(&v.value)
	_ = append(&v.value, value)
}

is_name_char :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// --- Words ---
//
// A line becomes words and the operators ; | >. A word is unquoted text, with
// $name replaced by the variable's value, and 'quoted' text taken as it is.

// An operator is its own character, so Op(c) makes one.
Op :: enum u8 {
	Word = 0, // not an operator
	Seq  = ';',
	Pipe = '|',
	Into = '>',
}

Word :: struct {
	text: string, // for a word
	op:   Op,
}

Words :: [dynamic; MAX_WORDS]Word

Split_Error :: enum {
	None,
	Too_Long, // too many words, or too much text
	Unterminated, // a quote
}

Byte_Set :: bit_set[0 ..< 128;u128]
BLANK :: Byte_Set{' ', '\t', '\n'}
OPERATOR :: Byte_Set{';', '|', '>'}
WORD_END :: BLANK + OPERATOR + Byte_Set{'#'}

is_in :: proc "contextless" (c: u8, set: Byte_Set) -> bool {
	return c < 128 && int(c) in set
}

word_pool: [4096]u8

split :: proc "contextless" (line: string, words: ^Words) -> Split_Error {
	used, i := 0, 0
	for i < len(line) {
		c := line[i]
		if is_in(c, BLANK) {
			i += 1
			continue
		}
		if c == '#' {
			break
		}
		if len(words) == MAX_WORDS {
			return .Too_Long
		}
		if is_in(c, OPERATOR) {
			_ = append(words, Word{op = Op(c)})
			i += 1
			continue
		}
		start := used
		for i < len(line) && !is_in(line[i], WORD_END) {
			c = line[i]
			if c == '\'' { // to the closing quote; '' inside is one quote
				i += 1
				for ; i < len(line); i += 1 {
					if line[i] == '\'' && (i + 1 >= len(line) || line[i + 1] != '\'') {
						break
					}
					if line[i] == '\'' {
						i += 1
					}
					if used == len(word_pool) {
						return .Too_Long
					}
					word_pool[used] = line[i]
					used += 1
				}
				if i == len(line) {
					return .Unterminated
				}
				i += 1
			} else if c == '$' && i + 1 < len(line) && is_name_char(line[i + 1]) {
				n := i + 1
				for n < len(line) && is_name_char(line[n]) {
					n += 1
				}
				v := var_get(line[i + 1:n])
				if len(v) > len(word_pool) - used {
					return .Too_Long
				}
				copy(word_pool[used:], v)
				used += len(v)
				i = n
			} else {
				if used == len(word_pool) {
					return .Too_Long
				}
				word_pool[used] = c
				used += 1
				i += 1
			}
		}
		_ = append(words, Word{text = string(word_pool[start:used])})
	}
	return .None
}

word_is :: proc "contextless" (w: Word, s: string) -> bool {
	return w.op == .Word && w.text == s
}

// --- Builtins ---

// bind's flags word: "-abc". ok is false for any other letter. Unlike
// procns.parse_flags (a flags= value), this takes -a with -b, which ns.bind
// reads as -b.
bind_flags :: proc "contextless" (f: string) -> (flags: ns.Flags, ok: bool) {
	for c in transmute([]u8)f[1:] {
		switch c {
		case 'a':
			flags += {.After}
		case 'b':
			flags += {.Before}
		case 'c':
			flags += {.Create}
		case:
			return {}, false
		}
	}
	return flags, true
}

report :: proc "contextless" (what: string, st: vx.Status) {
	if st != .Ok {
		rt.print("gsh: ", what, ": ", p9.error_text(st), "\n")
	}
}

// True if words[0] was a builtin, which then ran.
builtin :: proc "contextless" (w: []Word) -> bool {
	n := len(w)
	switch {
	case word_is(w[0], "bind"):
		has_flags := n > 1 && str.has_prefix(w[1].text, "-")
		flags, ok := ns.Flags{}, true
		if has_flags {
			flags, ok = bind_flags(w[1].text)
		}
		first := has_flags ? 2 : 1
		if !ok || n - first != 2 {
			rt.print("usage: bind [-abc] new old\n")
		} else {
			report("bind", ns.bind(&space, w[first].text, w[first + 1].text, flags))
		}
		return true
	case word_is(w[0], "unmount"):
		switch n {
		case 2:
			report("unmount", ns.unmount(&space, "", w[1].text))
		case 3:
			report("unmount", ns.unmount(&space, w[1].text, w[2].text))
		case:
			rt.print("usage: unmount [new] old\n")
		}
		return true
	case word_is(w[0], "exit"):
		rt.flush()
		rt.thread_exit(0)
	}
	return false
}

// --- Running programs ---

image: [1 << 20]u8

// Loads a program through the namespace: the path as given, or /bin/NAME,
// then /boot/bin/NAME. Returns its size, or 0.
load :: proc "contextless" (name: string) -> int {
	DIRS := [3]string{"", "/bin/", "/boot/bin/"}
	has_slash := str.index_byte(name, '/') >= 0
	for dir, d in DIRS {
		if (d == 0) != has_slash {
			continue
		}
		path_buf: [256]u8
		path, fits := str.join(path_buf[:], dir, name)
		if !fits {
			continue
		}
		f: ns.File
		if ns.open(&space, path, p9.OREAD, &f) != .Ok {
			continue
		}
		size, _ := ns.read_all(&f, image[:]) // what it read before any failure
		ns.close(&f)
		if size >= 4 && string(image[:4]) == "\x7fELF" {
			return size
		}
	}
	return 0
}

records: [16 * 1024]u8

// The longest task name: the kernel's field, less its NUL.
MAX_TASK_NAME :: len(vx.Task_Summary{}.name) - 1

// Spawns one command with its own end of the pipes: in and out are channel
// ends (HANDLE_NONE for the console), and are given away.
spawn :: proc "contextless" (w: []Word, input, output: vx.Handle) -> (task: vx.Handle, st: vx.Status) {
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	count := 0
	given := false // to spawn_elf, which takes them whatever happens
	defer if !given {
		rt.close_all(..handles[:count])
		rt.close_all(input, output)
	}
	size := load(w[0].text)
	if size == 0 {
		return vx.HANDLE_NONE, .Err_Not_Found
	}
	rec := ndb.Writer{buf = records[:]}
	for word in w[1:] {
		ndb.put(&rec, "arg", word.text)
		_ = ndb.end(&rec)
	}
	// The handles in upstream's order: the namespace's, the console, stdin,
	// stdout. Room is left for the last three.
	count, st = procns.spawn_records(&space, &rec, handles[:vx.CHANNEL_MAX_HANDLES - 4], names[:], 0)
	if st != .Ok {
		return vx.HANDLE_NONE, st
	}
	if con := rt.console_connector(); con != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(con, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "console"
			count += 1
		}
	}
	given = true // nothing fails from here to spawn_elf
	if input != vx.HANDLE_NONE {
		handles[count], names[count] = input, "stdin"
		count += 1
	}
	if output != vx.HANDLE_NONE {
		handles[count], names[count] = output, "stdout"
		count += 1
	}
	base := w[0].text // the task's name: the program's, without its directory
	base = base[str.last_index_byte(base, '/') + 1:]
	a := rt.Spawn_Args {
		name         = base[:min(len(base), MAX_TASK_NAME)],
		image        = image[:size],
		handles      = handles[:count],
		handle_names = names[:count],
		records      = ndb.written(&rec),
	}
	return rt.spawn_elf(&a)
}

relay_msg: [size_of(vx.Msg_Header) + 4096]u8

// Copies what is waiting on the channel into the file. False once the writer
// has gone and everything it wrote has been copied.
relay :: proc "contextless" (ch: vx.Handle, f: ^ns.File, broken: ^bool) -> bool {
	for {
		size, st := rt.channel_read(ch, relay_msg[:])
		if st == .Err_Should_Wait {
			return true
		}
		if st != .Ok {
			return false
		}
		for done := u32(size_of(vx.Msg_Header)); done < size.bytes && !broken^; {
			n, _ := ns.write(f, relay_msg[done:size.bytes])
			if n <= 0 {
				broken^ = true
			} else {
				done += u32(n)
			}
		}
	}
}

// A pipeline's port keys: a command's .Exit has its stage's index, and the
// channel the file's output comes through has these.
KEY_OUTPUT :: u64(100) // output to copy into the file
KEY_WRITER_GONE :: u64(101) // the last command's end has closed
#assert(MAX_PIPELINE <= KEY_OUTPUT)

// Runs one pipeline: commands joined by |, the last perhaps into a file.
pipeline :: proc "contextless" (words: []Word) {
	w := words
	n := len(w)
	into := ""
	for word, i in w {
		if word.op == .Into && i + 2 == n && w[i + 1].op == .Word {
			into = w[i + 1].text
			n = i
			break
		}
		if word.op != .Word && word.op != .Pipe {
			rt.print("gsh: syntax error\n")
			return
		}
	}
	// Where each command's words start; one more, past the end, closes the last.
	starts: [dynamic; MAX_PIPELINE + 1]int
	_ = append(&starts, 0)
	for word, i in w[:n] {
		if word.op != .Pipe {
			continue
		}
		if len(starts) == MAX_PIPELINE {
			rt.print("gsh: too many commands in a pipe\n")
			return
		}
		_ = append(&starts, i + 1)
	}
	_ = append(&starts, n + 1)
	stages := len(starts) - 1
	for s in 0 ..< stages {
		if starts[s + 1] - 1 == starts[s] {
			rt.print("gsh: syntax error\n")
			return
		}
	}
	if stages == 1 && builtin(w[:n]) {
		return
	}

	file: ns.File // closing it when it was never opened does nothing
	if into != "" {
		if st := ns.open(&space, into, p9.OWRITE, &file); st != .Ok {
			report("cannot open the file", st)
			return
		}
	}
	defer ns.close(&file)
	port, pst := rt.port_create()
	if pst != .Ok {
		return
	}
	defer _ = rt.handle_close(port)
	tasks: [MAX_PIPELINE]vx.Handle
	defer rt.close_all(..tasks[:stages])
	prev, sink: vx.Handle
	for s in 0 ..< stages {
		output, other: vx.Handle
		if s + 1 < stages || into != "" {
			a, b, cst := rt.channel_create()
			if cst != .Ok {
				break
			}
			output, other = a, b
		}
		task, st := spawn(w[starts[s]:starts[s + 1] - 1], prev, output)
		prev = output != vx.HANDLE_NONE ? other : vx.HANDLE_NONE
		if st != .Ok {
			rt.print("gsh: ", w[starts[s]].text, st == .Err_Not_Found ? ": not found\n" : ": cannot run it\n")
			continue
		}
		tasks[s] = task
		_ = rt.port_bind(port, task, .Exit, u64(s))
	}
	if into != "" {
		sink = prev // the last command's output, for the file
	} else if prev != vx.HANDLE_NONE {
		_ = rt.handle_close(prev)
	}
	if sink != vx.HANDLE_NONE {
		_ = rt.port_bind(port, sink, .Peer_Closed, KEY_WRITER_GONE)
	}

	// Wait for every command; meanwhile copy the last one's output into the file.
	running := 0
	for t in tasks[:stages] {
		if t != vx.HANDLE_NONE {
			running += 1
		}
	}
	broken, sink_armed := false, false
	for running > 0 || sink != vx.HANDLE_NONE {
		if sink != vx.HANDLE_NONE && !sink_armed {
			sink_armed = rt.port_bind(port, sink, .Readable, KEY_OUTPUT) == .Ok
		}
		pk: [8]vx.Packet
		got, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:got] {
			switch {
			case p.trigger == .Exit:
				running -= 1
				var_set("status", i64(p.value) != 0 ? "1" : "0")
			case sink != vx.HANDLE_NONE && p.key == KEY_OUTPUT:
				sink_armed = false
				if !relay(sink, &file, &broken) {
					_ = rt.handle_close(sink)
					sink = vx.HANDLE_NONE
				}
			case sink != vx.HANDLE_NONE && p.key == KEY_WRITER_GONE && !relay(sink, &file, &broken):
				_ = rt.handle_close(sink)
				sink = vx.HANDLE_NONE
			}
		}
	}
	if broken {
		rt.print("gsh: write error\n")
	}
}

// Runs one command, or pipeline, of a line: its words are expanded now, so a
// variable set earlier in the line is seen.
run_command :: proc "contextless" (text: string) {
	words: Words
	switch split(text, &words) {
	case .Too_Long:
		rt.print("gsh: line too long\n")
		return
	case .Unterminated:
		rt.print("gsh: unterminated quote\n")
		return
	case .None:
	}
	if len(words) == 0 {
		return
	}
	// name=value alone sets a variable.
	t := words[0].text
	eq := len(words) == 1 && words[0].op == .Word ? str.index_byte(t, '=') : -1
	if eq > 0 {
		var_set(t[:eq], t[eq + 1:])
	} else {
		pipeline(words[:])
	}
}

// Runs a line's commands in turn: it splits at each ; outside quotes, and
// stops at a comment.
run_line :: proc "contextless" (line: string) {
	start := 0
	quoted := false // '' inside quotes toggles twice: still quoted
	for c, i in transmute([]u8)line {
		switch c {
		case '\'':
			quoted = !quoted
		case '#':
			if !quoted {
				run_command(line[start:i]) // the rest is a comment
				return
			}
		case ';':
			if !quoted {
				run_command(line[start:i])
				start = i + 1
			}
		}
	}
	run_command(line[start:])
}

@(export, link_name="vx_main")
main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		rt.print("gsh: the namespace is incomplete\n")
	}
	line: [512]u8
	for {
		rt.print("vx% ")
		length := 0
		n: int
		for {
			n, _ = rt.read(line[length:])
			if n <= 0 {
				break
			}
			length += n
			if line[length - 1] == '\n' || length == len(line) {
				break
			}
		}
		if n <= 0 && length == 0 {
			break // the end of the input
		}
		run_line(string(line[:length]))
	}
	rt.print("\n")
	return 0
}
