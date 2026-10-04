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

MAX_WORDS :: 64
MAX_PIPELINE :: 8

space: ns.Namespace

// --- Variables ---

Var :: struct {
	name:      [32]u8,
	value:     [256]u8,
	name_len:  int,
	value_len: int,
}

vars: [32]Var

var_get :: proc "contextless" (name: string) -> string {
	for &v in vars {
		if v.name_len > 0 && string(v.name[:v.name_len]) == name {
			return string(v.value[:v.value_len])
		}
	}
	return ""
}

var_set :: proc "contextless" (name, value: string) {
	slot := len(vars)
	for &v, i in vars {
		same := v.name_len > 0 && string(v.name[:v.name_len]) == name
		if same || (slot == len(vars) && v.name_len == 0) {
			slot = i
		}
	}
	if slot == len(vars) || len(name) > len(vars[0].name) || len(value) > len(vars[0].value) {
		rt.print("gsh: too many variables, or too long\n")
		return
	}
	v := &vars[slot]
	copy(v.name[:], name)
	copy(v.value[:], value)
	v.name_len = len(name)
	v.value_len = len(value)
}

find :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

is_name_char :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

// --- Words ---
//
// A line becomes words and the operators ; | >. A word is unquoted text, with
// $name replaced by the variable's value, and 'quoted' text taken as it is.

Word :: struct {
	text: string,
	op:   u8, // ';', '|' or '>' for an operator; 0 for a word
}

word_pool: [4096]u8

// The number of words; -1 when the line is too long, -2 for an unterminated quote.
split :: proc "contextless" (line: string, words: []Word) -> int {
	count, used, i := 0, 0, 0
	for i < len(line) {
		c := line[i]
		if c == ' ' || c == '\t' || c == '\n' {
			i += 1
			continue
		}
		if c == '#' {
			break
		}
		if count == MAX_WORDS {
			return -1
		}
		if c == ';' || c == '|' || c == '>' {
			words[count] = {op = c}
			count += 1
			i += 1
			continue
		}
		start := used
		for i < len(line) {
			c = line[i]
			if c == ' ' || c == '\t' || c == '\n' || c == ';' || c == '|' || c == '>' || c == '#' {
				break
			}
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
						return -1
					}
					word_pool[used] = line[i]
					used += 1
				}
				if i == len(line) {
					return -2 // unterminated
				}
				i += 1
			} else if c == '$' && i + 1 < len(line) && is_name_char(line[i + 1]) {
				n := i + 1
				for n < len(line) && is_name_char(line[n]) {
					n += 1
				}
				v := var_get(line[i + 1:n])
				if len(v) > len(word_pool) - used {
					return -1
				}
				copy(word_pool[used:], v)
				used += len(v)
				i = n
			} else {
				if used == len(word_pool) {
					return -1
				}
				word_pool[used] = c
				used += 1
				i += 1
			}
		}
		words[count] = {text = string(word_pool[start:used])}
		count += 1
	}
	return count
}

word_is :: proc "contextless" (w: Word, s: string) -> bool {
	return w.op == 0 && w.text == s
}

// --- Builtins ---

// bind's flags word: "-abc". ok is false for any other letter.
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
		has_flags := n > 1 && len(w[1].text) > 0 && w[1].text[0] == '-'
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
	for dir, d in DIRS {
		has_slash := find(name, '/') >= 0
		if (d == 0) != has_slash {
			continue
		}
		path: [256]u8
		if len(dir) + len(name) > len(path) {
			continue
		}
		copy(path[:], dir)
		copy(path[len(dir):], name)
		f: ns.File
		if ns.open(&space, string(path[:len(dir) + len(name)]), p9.OREAD, &f) != .Ok {
			continue
		}
		size := 0
		for size < len(image) {
			n, _ := ns.read(&f, image[size:])
			if n <= 0 {
				break
			}
			size += n
		}
		ns.close(&f)
		if size >= 4 && string(image[:4]) == "\x7fELF" {
			return size
		}
	}
	return 0
}

records: [16 * 1024]u8

// Spawns one command with its own end of the pipes: in and out are channel
// ends (HANDLE_NONE for the console), and are given away.
spawn :: proc "contextless" (w: []Word, input, output: vx.Handle) -> (vx.Handle, vx.Status) {
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	count := 0
	rec := ndb.Writer{buf = records[:]}
	size := load(w[0].text)
	st := size > 0 ? vx.Status.Ok : vx.Status.Err_Not_Found
	for i in 1 ..< len(w) {
		if st != .Ok {
			break
		}
		ndb.put(&rec, "arg", w[i].text)
		_ = ndb.end(&rec)
	}
	if st == .Ok {
		count, st = procns.spawn_records(&space, &rec, handles[:vx.CHANNEL_MAX_HANDLES - 4], names[:], count)
	}
	if st == .Ok && rt.console_connector() != 0 {
		if h, dst := rt.handle_dup(rt.console_connector(), vx.RIGHTS_SAME); dst == .Ok {
			handles[count] = h
			names[count] = "console"
			count += 1
		}
	}
	if input != 0 {
		handles[count] = input
		names[count] = "stdin"
		count += 1
	}
	if output != 0 {
		handles[count] = output
		names[count] = "stdout"
		count += 1
	}
	if st != .Ok {
		for h in handles[:count] {
			_ = rt.handle_close(h)
		}
		return 0, st
	}
	base := w[0].text // the task's name: the program's, without its directory
	for i := len(base) - 1; i >= 0; i -= 1 {
		if base[i] == '/' {
			base = base[i + 1:]
			break
		}
	}
	a := rt.Spawn_Args {
		name         = len(base) < 24 ? base : base[:23],
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

// Runs one pipeline: commands joined by |, the last perhaps into a file.
pipeline :: proc "contextless" (words: []Word) {
	w := words
	n := len(w)
	starts: [MAX_PIPELINE + 1]int
	stages := 0
	into := ""
	for i in 0 ..< n {
		if w[i].op == '>' && i + 2 == n && w[i + 1].op == 0 {
			into = w[i + 1].text
			n = i
			break
		}
		if w[i].op != 0 && w[i].op != '|' {
			rt.print("gsh: syntax error\n")
			return
		}
	}
	starts[stages] = 0
	stages += 1
	for i in 0 ..< n {
		if w[i].op != '|' {
			continue
		}
		if stages == MAX_PIPELINE {
			rt.print("gsh: too many commands in a pipe\n")
			return
		}
		starts[stages] = i + 1
		stages += 1
	}
	starts[stages] = n + 1
	for s in 0 ..< stages {
		if starts[s + 1] - 1 == starts[s] {
			rt.print("gsh: syntax error\n")
			return
		}
	}
	if stages == 1 && builtin(w[:n]) {
		return
	}

	file: ns.File
	if into != "" {
		if st := ns.open(&space, into, p9.OWRITE, &file); st != .Ok {
			report("cannot open the file", st)
			return
		}
	}
	tasks: [MAX_PIPELINE]vx.Handle
	prev, sink: vx.Handle
	port, pst := rt.port_create()
	if pst != .Ok {
		return
	}
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
		prev = output != 0 ? other : 0
		if st != .Ok {
			rt.print("gsh: ", w[starts[s]].text, st == .Err_Not_Found ? ": not found\n" : ": cannot run it\n")
			continue
		}
		tasks[s] = task
		_ = rt.port_bind(port, task, .Exit, u64(s))
	}
	if into != "" {
		sink = prev // the last command's output, for the file
	} else if prev != 0 {
		_ = rt.handle_close(prev)
	}
	if sink != 0 {
		_ = rt.port_bind(port, sink, .Peer_Closed, 101)
	}

	// Wait for every command; meanwhile copy the last one's output into the file.
	running := 0
	for t in tasks[:stages] {
		if t != 0 {
			running += 1
		}
	}
	broken, sink_armed := false, false
	for running > 0 || sink != 0 {
		if sink != 0 && !sink_armed {
			sink_armed = rt.port_bind(port, sink, .Readable, 100) == .Ok
		}
		pk: [8]vx.Packet
		got, _ := rt.port_wait(port, vx.INFINITE, 0, pk[:])
		for p in pk[:got] {
			switch {
			case p.trigger == .Exit:
				running -= 1
				var_set("status", i64(p.value) != 0 ? "1" : "0")
			case sink != 0 && p.key == 100: // output to copy
				sink_armed = false
				if !relay(sink, &file, &broken) {
					_ = rt.handle_close(sink)
					sink = 0
				}
			case sink != 0 && p.key == 101 && !relay(sink, &file, &broken): // the writer is done
				_ = rt.handle_close(sink)
				sink = 0
			}
		}
	}
	if broken {
		rt.print("gsh: write error\n")
	}
	for t in tasks[:stages] {
		if t != 0 {
			_ = rt.handle_close(t)
		}
	}
	_ = rt.handle_close(port)
	if into != "" {
		ns.close(&file)
	}
}

// Runs one command, or pipeline, of a line: its words are expanded now, so a
// variable set earlier in the line is seen.
run_command :: proc "contextless" (text: string) {
	w: [MAX_WORDS]Word
	n := split(text, w[:])
	if n < 0 {
		rt.print(n == -2 ? "gsh: unterminated quote\n" : "gsh: line too long\n")
		return
	}
	if n == 0 {
		return
	}
	// name=value alone sets a variable.
	t := w[0].text
	eq := n == 1 && w[0].op == 0 ? find(t, '=') : -1
	if eq > 0 {
		var_set(t[:eq], t[eq + 1:])
	} else {
		pipeline(w[:n])
	}
}

// Runs a line's commands in turn: it splits at each ; outside quotes and
// before a comment.
run_line :: proc "contextless" (line: string) {
	start := 0
	quoted := false
	for i := 0; i <= len(line); i += 1 {
		c := i < len(line) ? line[i] : ';'
		if c == '\'' {
			quoted = !quoted // '' inside quotes toggles twice: still quoted
		}
		if quoted && i < len(line) {
			continue
		}
		end := i
		if c == '#' {
			c = ';' // the rest is a comment
			i = len(line)
		}
		if c != ';' {
			continue
		}
		run_command(line[start:end])
		start = i + 1
	}
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
