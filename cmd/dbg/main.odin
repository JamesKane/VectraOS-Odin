// dbg: the debugger's command line, `dbg -c` (upstream docs/05 §7), for
// serial consoles and bring-up before the desktop exists. It does everything
// through /proc's debug files (05 §3), as acid did, and vx:debug's index and
// evaluator: the program's ELF is read and indexed when dbg starts.
//
//   dbg -c [-x FILE] PROGRAM [ARG ...]   launch PROGRAM at `run`
//   dbg -c [-x FILE] -p PID              attach to a running process
//   dbg -c [-x FILE] /tmp/crash/NAME.PID open a crash directory (05 §5)
//
// Commands come from the console, or (-x) from FILE, each echoed:
//
//   break FUNC | FILE:LINE | 0xADDR    a breakpoint (before `run`, kept until then)
//   run                                start the program, and wait for an event
//   cont, step                         resume, or step one instruction, and wait
//   bt                                 the call stack, by frame pointers (05 §4)
//   frame N                            choose frame N for print
//   print EXPR                         a C expression at that frame (05 §6.2)
//   regs, info                         the thread's registers; the process's maps and images
//   threads                            every thread: its state, why it stopped, where (M6 step 6d6a)
//   thread N                           make thread N the one commands act on
//   xregs                              the thread's FP/SIMD state: x86_64's XSAVE image, PKRU
//                                      among it; aarch64's V registers
//   kill, quit
//
// When a thread stops with an event, procfs stops the program's other threads
// too, and starts them again with it (all-stop, procfs's debug.odin).
//
// A launched program that crashes leaves a crash directory (procfs saves it,
// 05 §5); dbg then turns to it, so bt and print go on working on the dead
// program, with the same code a live one uses.
//
// Behaviour is upstream's cmd/dbg.c at dfbbe4b, byte for byte on the
// console. tests/host/dbg drives `session` against a recorded procfs.
package dbg

import "base:intrinsics"
import vx "abi:vx"
import "vx:debug"
import "vx:memory"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:process"
import "vx:procns"
import "vx:rt"
import "vx:str"
import "vx:utf"
import usage "gen:usage/dbg"

space: ns.Namespace
me: u64 // dbg's own pid: its wait records are read from /proc/ME/wait

@(private="file")
image: [8 << 20]u8 // the program's ELF
@(private="file")
image_size: int
@(private="file")
arena_mem: [24 << 20]u8 // its index is built here
@(private="file")
ix: debug.Index

// What dbg knows of its target. A session starts from all zeroes, as
// upstream's process does; tests/host/dbg runs several in one process.
@(private="file")
State :: struct {
	program:        [dynamic; 128]u8, // its path
	args:           [dynamic; 16]string,
	pid:            u64,
	crash_dir:      [dynamic; 96]u8, // the crash directory, once the target is one
	live, launched: bool,
	thread:         u32, // the thread commands act on: the one the last event named (0: thread 1)
	regs:           vx.Regs, // the thread's, as it stopped
	have_regs:      bool,
	frame_buf:      [64]debug.Frame,
	frames:         []debug.Frame, // the call stack, in frame_buf
	frame:          int, // the one print evaluates at
	breaks:         [dynamic; 32]u64, // set before `run`, given to procfs once the program exists
	mem_file:       ns.File, // /proc/PID/mem, kept open
	mem_open:       bool,
	crash_maps:     [dynamic; 32]Crash_Map, // a crash directory's mem/0xBASE files
	crash_listed:   bool,
}

@(private="file")
Crash_Map :: struct {
	base, size: u64,
}

@(private="file")
state: State

@(private="file")
target := debug.Target {
	read = target_read,
	reg  = target_reg,
}

// --- Output ---

@(private="file")
say_hex :: proc(v: u64) {
	buf: [18]u8
	rt.print(hex_text(&buf, v))
}

// "0x" and v in lowercase hex, without leading zeros, at the start of buf.
@(private="file")
hex_text :: proc "contextless" (buf: ^[18]u8, v: u64) -> string {
	DIGITS := "0123456789abcdef"
	d: [16]u8
	n := 0
	for x := v; ; x >>= 4 {
		d[n] = DIGITS[x & 15]
		n += 1
		if x >> 4 == 0 {
			break
		}
	}
	buf[0], buf[1] = '0', 'x'
	for i in 0 ..< n {
		buf[2 + i] = d[n - 1 - i]
	}
	return string(buf[:n + 2])
}

// --- Files ---

// "/proc/PID/file", or the crash directory's file, in a buffer that lasts
// until the next call.
@(private="file")
target_path :: proc "contextless" (file: string) -> string {
	@(static) path: [160]u8
	b := str.Buf{buf = path[:]}
	if len(state.crash_dir) > 0 {
		str.write_bytes(&b, state.crash_dir[:])
	} else {
		str.write_string(&b, "/proc/")
		str.write_u64(&b, state.pid)
	}
	str.write_byte(&b, '/')
	str.write_string(&b, file)
	return str.to_string(&b)
}

// One read of the file at path, from its start, into buf.
@(private="file")
read_file :: proc "contextless" (path: string, buf: []u8) -> (n: int, st: vx.Status) {
	f: ns.File
	ns.open(&space, path, p9.OREAD, &f) or_return
	defer ns.close(&f)
	return ns.read(&f, buf)
}

// buf filled by one read of path, or false.
@(private="file")
read_whole :: proc "contextless" (path: string, buf: []u8) -> bool {
	n, st := read_file(path, buf)
	return st == .Ok && n == len(buf)
}

@(private="file")
write_file :: proc "contextless" (path, text: string) -> vx.Status {
	f: ns.File
	ns.open(&space, path, p9.OWRITE, &f) or_return
	defer ns.close(&f)
	_, st := ns.write(&f, transmute([]u8)text)
	return st
}

@(private="file")
ctl :: proc "contextless" (text: string) -> vx.Status {
	return write_file(target_path("ctl"), text)
}

// A value of key in an ndb record's text (key=value, the value perhaps
// quoted): the first `key=` at the start or after a space, as upstream
// finds it.
@(private="file")
field :: proc "contextless" (rec: string, key: string) -> string {
	for i := 0; i + len(key) < len(rec); i += 1 {
		if (i > 0 && rec[i - 1] != ' ') || rec[i:][:len(key)] != key || rec[i + len(key)] != '=' {
			continue
		}
		s := i + len(key) + 1
		e := s
		if s < len(rec) && rec[s] == '"' {
			s += 1
			e = s
			for e < len(rec) && rec[e] != '"' {
				e += 1
			}
		} else {
			for e < len(rec) && rec[e] != ' ' && rec[e] != '\n' {
				e += 1
			}
		}
		return rec[s:e]
	}
	return ""
}

// A number, the whole of s: decimal, or 0x and up to 16 hex digits; 0 for
// anything else, which callers take as none (`break 0x40102g` set a
// breakpoint at a wrong address, and said so: the Rust port's finding,
// upstream's 5c1bbc9).
@(private="file")
parse_num :: proc "contextless" (s: string) -> (v: u64) {
	hex := len(s) > 2 && s[0] == '0' && s[1] == 'x'
	if len(s) == 0 || (hex && len(s) > 18) {
		return 0
	}
	for c in transmute([]u8)s[2 if hex else 0:] {
		d: u64 = 16
		switch c {
		case '0' ..= '9':
			d = u64(c - '0')
		case 'a' ..= 'f':
			d = hex ? u64(c - 'a') + 10 : 16
		case 'A' ..= 'F':
			d = hex ? u64(c - 'A') + 10 : 16
		}
		if d >= (hex ? 16 : 10) || (!hex && v > (max(u64) - d) / 10) {
			return 0
		}
		v = hex ? v << 4 | d : v * 10 + d
	}
	return v
}

// --- The program's memory ---

@(private="file")
close_mem :: proc "contextless" () {
	if state.mem_open {
		ns.close(&state.mem_file)
		state.mem_open = false
	}
}

// From a crash directory's mem/0xBASE files: the writable mappings.
@(private="file")
read_crash :: proc "contextless" (addr: u64, buf: []u8) -> bool {
	if !state.crash_listed { // the mem directory's entries, once
		state.crash_listed = true
		@(static) ents: [4096]u8
		dir: ns.File
		if ns.open(&space, target_path("mem"), p9.OREAD, &dir) == .Ok {
			got, _ := ns.read(&dir, ents[:])
			it := p9.Dir_Entries {
				buf = ents[:max(got, 0)],
			}
			for e in p9.next_entry(&it) {
				if append(&state.crash_maps, Crash_Map{parse_num(e.name), e.length}) == 0 {
					break
				}
			}
			ns.close(&dir)
		}
	}
	n := u64(len(buf))
	for m in state.crash_maps {
		// As differences, which cannot wrap: the directory may hold anything.
		if addr < m.base || addr - m.base > m.size || n > m.size - (addr - m.base) {
			continue
		}
		name: [32]u8
		b := str.Buf{buf = name[:]}
		hex: [18]u8
		str.write_string(&b, "mem/")
		str.write_string(&b, hex_text(&hex, m.base))
		f: ns.File
		if ns.open(&space, target_path(str.to_string(&b)), p9.OREAD, &f) != .Ok {
			return false
		}
		f.offset = addr - m.base // ns has no seek: the next read is from here
		got, _ := ns.read(&f, buf)
		ns.close(&f)
		return got == len(buf)
	}
	return false
}

@(private="file")
target_read :: proc "contextless" (data: rawptr, addr: u64, buf: []u8) -> bool {
	if len(state.crash_dir) > 0 {
		// Read-only bytes come from the ELF image, by its program headers:
		// what a crash directory leaves out (05 §5).
		return read_crash(addr, buf) || debug.image_read(image[:image_size], addr, buf)
	}
	if !state.mem_open {
		state.mem_open = ns.open(&space, target_path("mem"), p9.OREAD, &state.mem_file) == .Ok
	}
	if !state.mem_open {
		return false
	}
	state.mem_file.offset = addr // the address space as a file: the address is the offset
	got, _ := ns.read(&state.mem_file, buf)
	return got == len(buf)
}

// The innermost frame's registers, by DWARF number.
@(private="file")
target_reg :: proc "contextless" (data: rawptr, dwarf: u32) -> (value: u64, ok: bool) {
	if !state.have_regs {
		return 0, false
	}
	when ODIN_ARCH == .amd64 {
		r := state.regs
		by_dwarf := [17]u64{r.rax, r.rdx, r.rcx, r.rbx, r.rsi, r.rdi, r.rbp, r.rsp, r.r8, r.r9, r.r10, r.r11, r.r12, r.r13, r.r14, r.r15, r.rip}
		if dwarf >= len(by_dwarf) {
			return 0, false
		}
		return by_dwarf[dwarf], true
	} else {
		switch {
		case dwarf < 31:
			return state.regs.x[dwarf], true
		case dwarf == 31:
			return state.regs.sp, true
		}
		return 0, false
	}
}

// --- Where it is ---

// "FUNC (FILE:LINE)" for a pc.
@(private="file")
say_where :: proc(pc: u64) {
	if f, ok := debug.func_at(&ix, pc); ok {
		rt.print(debug.str(&ix, f.name))
	} else if s, sok := debug.sym_at(&ix, pc); sok {
		rt.print(debug.str(&ix, s.name))
	} else {
		rt.print("??")
	}
	l, ok := debug.line_at(&ix, pc)
	if !ok {
		return
	}
	file := debug.file(&ix, l.file)
	if str.has_prefix(file, "/src/") {
		file = file[len("/src/"):] // -ffile-prefix-map's
	}
	rt.print(" (", file, ":", u64(l.line), ")")
}

// threads/N/file, N the thread commands act on: the one the last event named.
@(private="file")
thread_file :: proc "contextless" (file: string) -> string {
	@(static) path: [47]u8
	b := str.Buf{buf = path[:]}
	str.write_string(&b, "threads/")
	str.write_u64(&b, u64(max(state.thread, 1)))
	str.write_byte(&b, '/')
	str.write_string(&b, file)
	return str.to_string(&b)
}

@(private="file")
regs_pc :: proc "contextless" () -> u64 {
	when ODIN_ARCH == .amd64 {
		return state.regs.rip
	} else {
		return state.regs.pc
	}
}

// The thread's registers and the call stack, as it stopped.
@(private="file")
refresh :: proc() {
	state.frames, state.frame = nil, 0
	state.have_regs = read_whole(target_path(thread_file("regs")), memory.ptr_to_bytes(&state.regs))
	if !state.have_regs {
		return
	}
	when ODIN_ARCH == .amd64 {
		state.frames = debug.unwind(&ix, &target, state.regs.rip, state.regs.rsp, state.regs.rbp, state.frame_buf[:])
	} else {
		state.frames = debug.unwind(&ix, &target, state.regs.pc, state.regs.sp, state.regs.x[29], state.frame_buf[:])
	}
}

// --- Events ---

// Its end: the wait record procfs left for dbg, its parent; and, for a
// crash, its crash directory.
@(private="file")
ended :: proc() {
	state.live = false
	state.frames, state.frame = nil, 0 // the last stop's stack is no more; a crash's comes from its directory
	state.have_regs = false
	close_mem() // the pid may be another's soon
	@(static) rec: [511]u8
	path: [48]u8
	b := str.Buf{buf = path[:]}
	str.write_string(&b, "/proc/")
	str.write_u64(&b, me)
	str.write_string(&b, "/wait")
	n, st := read_file(str.to_string(&b), rec[:])
	r := string(rec[:n if st == .Ok && n > 0 else 0])
	status, name := field(r, "status"), field(r, "name")
	rt.print("dbg: ", name, " exited")
	if len(status) > 0 {
		rt.print(": ", status)
	}
	rt.print("\n")
	if !str.has_prefix(status, "sys: trap") {
		return
	}
	// A crash: procfs saved it (05 §5).
	clear(&state.crash_dir)
	append(&state.crash_dir, "/tmp/crash/")
	append(&state.crash_dir, name)
	append(&state.crash_dir, ".")
	digits: [str.U64_DIGITS]u8
	append(&state.crash_dir, str.format_u64(digits[:], state.pid))
	note: [128]u8
	if got, nst := read_file(target_path("note"), note[:]); nst != .Ok || got <= 0 {
		clear(&state.crash_dir)
		return
	}
	rt.print("dbg: crash directory ", string(state.crash_dir[:]), "\n")
	fault_thread()
	refresh()
}

// Waits for the next debug event, and says where it stopped.
@(private="file")
wait_event :: proc() {
	@(static) rec: [255]u8
	n, st := read_file(target_path("events"), rec[:])
	if st != .Ok || n <= 0 { // the process has gone
		ended()
		return
	}
	r := string(rec[:n])
	kind, pc, addr := field(r, "event"), field(r, "pc"), field(r, "addr")
	state.thread = u32(parse_num(field(r, "thread")))
	if state.thread == 0 {
		state.thread = 1
	}
	rt.print("dbg: stopped: ", kind)
	if len(addr) > 0 {
		rt.print(" addr=", addr)
	}
	rt.print(" at ")
	say_where(parse_num(pc))
	rt.print("\n")
	refresh()
}

// --- Commands ---

// A breakpoint's address: a function's body, a file:line's first statement,
// or a number; 0 if there is none.
@(private="file")
resolve :: proc "contextless" (spec: string) -> u64 {
	if len(spec) == 0 || len(spec) >= 96 {
		return 0
	}
	if spec[0] >= '0' && spec[0] <= '9' {
		return parse_num(spec)
	}
	if colon := str.index_byte(spec, ':'); colon >= 0 {
		addr, _ := debug.line_addr(&ix, spec[:colon], u32(parse_num(spec[colon + 1:])))
		return addr
	}
	if f, ok := debug.func_named(&ix, spec); ok {
		return f.body
	}
	return 0
}

@(private="file")
set_break :: proc "contextless" (addr: u64) -> vx.Status {
	cmd: [32]u8
	b := str.Buf{buf = cmd[:]}
	hex: [18]u8
	str.write_string(&b, "break ")
	str.write_string(&b, hex_text(&hex, addr))
	return ctl(str.to_string(&b))
}

// The breakpoints set before `run`, given to procfs for the child.
@(private="file")
set_breaks :: proc "contextless" (data: rawptr, child: u64) -> vx.Status {
	state.pid = child
	for addr in state.breaks {
		set_break(addr) or_return
	}
	return .Ok
}

// The longest task name: the kernel's field, less its NUL.
@(private="file")
MAX_TASK_NAME :: len(vx.Task_Summary{}.name) - 1

@(private="file")
records: [8 * 1024]u8

// The run command: the program launched, and its first event.
@(private="file")
start_program :: proc() {
	if state.live {
		rt.print("dbg: already running\n")
		return
	}
	handles: [vx.CHANNEL_MAX_HANDLES - 1]vx.Handle
	names: [vx.CHANNEL_MAX_HANDLES - 1]string
	rec := ndb.Writer {
		buf = records[:],
	}
	for a in state.args {
		ndb.put(&rec, "arg", a)
		_ = ndb.end(&rec)
	}
	count, st := procns.spawn_records(&space, &rec, handles[:vx.CHANNEL_MAX_HANDLES - 4], names[:], 0)
	if st != .Ok {
		rt.print("dbg: cannot give the program a namespace\n")
		return
	}
	if con := rt.console_connector(); con != vx.HANDLE_NONE {
		if h, dst := rt.handle_dup(con, vx.RIGHTS_SAME); dst == .Ok {
			handles[count], names[count] = h, "console"
			count += 1
		}
	}
	base := string(state.program[:])
	base = base[str.last_index_byte(base, '/') + 1:]
	if !launch(base, handles[:count], names[:count], ndb.written(&rec)) {
		state.pid = 0 // set_breaks may have named it: not a program, then
		rt.print("dbg: cannot start the program\n")
		return
	}
	state.live, state.launched = true, true
	// Opening events makes procfs its debugger: faults stop it with an event.
	wait_event()
}

// Spawns the program, registered with procfs as dbg's child (so dbg gets
// its wait record), with the breakpoints set before its thread starts, so it
// stops at them from its first instruction.
@(private="file")
launch :: proc(base: string, handles: []vx.Handle, names: []string, recs: string) -> bool {
	when intrinsics.type_has_field(rt.Spawn_Args, "registered") {
		a := rt.Spawn_Args {
			name         = base[:utf.cut(base, MAX_TASK_NAME)],
			image        = image[:image_size],
			handles      = handles,
			handle_names = names,
			records      = recs,
			proc_conn    = ns.connector(&space, "/proc"), // dbg is its parent: it gets the wait record
			registered   = set_breaks,
		}
		task, st := rt.spawn_elf(&a)
		if st != .Ok {
			return false
		}
		_ = rt.handle_close(task) // procfs watches it
		return true
	} else {
		// Until vx:rt's spawn_elf registers a child before its thread starts
		// (with musl's back end, ADR-0007), the child is registered and its
		// breakpoints set just after it starts, as tests/user/proctest
		// registers its children: a breakpoint on its first instructions may
		// be missed.
		a := rt.Spawn_Args {
			name         = base[:utf.cut(base, MAX_TASK_NAME)],
			image        = image[:image_size],
			handles      = handles,
			handle_names = names,
			records      = recs,
		}
		task, st := rt.spawn_elf(&a)
		if st != .Ok {
			return false
		}
		defer _ = rt.handle_close(task) // procfs watches it
		child: u64
		if child, st = register(task); st == .Ok {
			st = set_breaks(nil, child)
		}
		if st != .Ok {
			_ = rt.task_kill(task, "spawn failed")
			return false
		}
		return true
	}
}

// Registers task with procfs as a child of dbg (vx:process), as upstream's
// vx_proc_register does: its pid.
@(private="file")
register :: proc "contextless" (task: vx.Handle) -> (child: u64, st: vx.Status) {
	dup := rt.handle_dup(task, vx.RIGHTS_SAME) or_return
	req := process.Msg {
		header = {ordinal = process.REGISTER},
		arg = {i64(me), 0, 0},
	}
	rep: process.Msg
	c := vx.Call {
		wr_bytes   = &req,
		wr_len     = size_of(req),
		wr_handles = &dup,
		wr_count   = 1,
		rd_bytes   = &rep,
		rd_cap     = size_of(rep),
	}
	rt.channel_call(ns.connector(&space, "/proc"), &c, rt.clock_read() + 2_000_000_000) or_return
	if c.actual.bytes < size_of(rep) {
		return 0, .Err_Invalid
	}
	process.reply_status(&rep) or_return
	return u64(rep.arg[0]), .Ok
}

@(private="file")
bt :: proc() {
	if len(state.frames) == 0 {
		rt.print("dbg: no stack\n")
		return
	}
	for &f, i in state.frames {
		rt.print(i == state.frame ? "*#" : " #", u64(i), " ")
		say_hex(f.pc)
		rt.print(" in ")
		say_where(debug.frame_lookup_pc(&f))
		rt.print("\n")
	}
}

@(private="file")
print :: proc(expr: string) {
	if len(state.frames) == 0 {
		rt.print("dbg: not stopped\n")
		return
	}
	if len(expr) >= 256 {
		rt.print("dbg: too long\n")
		return
	}
	s := debug.begin(&ix, &target, &state.frames[state.frame])
	v, ok := debug.eval(&s, expr)
	if !ok {
		rt.print("dbg: ", s.err != "" ? s.err : "cannot evaluate", "\n")
		return
	}
	@(static) out: [512]u8
	rt.print("= ", debug.format(&s, v, out[:]), "\n")
}

// threads/N/status's record, for thread n, into buf: its text, or "".
@(private="file")
thread_status :: proc "contextless" (n: u64, buf: []u8) -> string {
	path: [48]u8
	b := str.Buf{buf = path[:len(path) - 1]}
	str.write_string(&b, "threads/")
	str.write_u64(&b, n)
	str.write_string(&b, "/status")
	got, st := read_file(target_path(str.to_string(&b)), buf)
	return string(buf[:got if st == .Ok && got > 0 else 0])
}

// The thread that faulted, in a crash directory (its status's reason=fault),
// for the commands to act on, not thread 1 (the Rust port's finding,
// upstream's 5c1bbc9).
@(private="file")
fault_thread :: proc() {
	d: ns.File
	if ns.open(&space, target_path("threads"), p9.OREAD, &d) != .Ok {
		return
	}
	defer ns.close(&d)
	@(static) dir: [8192]u8
	for {
		n, st := ns.read(&d, dir[:])
		if st != .Ok || n <= 0 {
			break
		}
		it := p9.Dir_Entries {
			buf = dir[:n],
		}
		for e in p9.next_entry(&it) {
			tid := parse_num(e.name)
			rec: [256]u8
			if tid != 0 && field(thread_status(tid, rec[:]), "reason") == "fault" {
				state.thread = u32(tid)
			}
		}
	}
}

@(private="file")
threads :: proc() {
	d: ns.File
	if ns.open(&space, target_path("threads"), p9.OREAD, &d) != .Ok {
		rt.print("dbg: no threads\n")
		return
	}
	@(static) dir: [8192]u8
	all, stopped: u64
	for {
		n, st := ns.read(&d, dir[:])
		if st != .Ok || n <= 0 {
			break
		}
		it := p9.Dir_Entries {
			buf = dir[:n],
		}
		for e in p9.next_entry(&it) {
			tid := parse_num(e.name)
			rec: [256]u8
			r := thread_status(tid, rec[:])
			state_word, reason := field(r, "state"), field(r, "reason")
			all += 1
			if state_word == "stopped" || state_word == "frozen" {
				stopped += 1
			}
			rt.print(tid == u64(max(state.thread, 1)) ? " *" : "  ", tid, " ", state_word)
			if len(reason) > 0 {
				rt.print(" ", reason)
			}
			if pc := parse_num(field(r, "pc")); pc != 0 {
				rt.print(" at ")
				say_where(pc)
			}
			rt.print("\n")
		}
	}
	ns.close(&d)
	rt.print("dbg: ", all, " threads, ", stopped, " stopped\n")
}

// As one number, the last byte first.
@(private="file")
say_bytes :: proc "contextless" (p: []u8) {
	DIGITS := "0123456789abcdef"
	out: [130]u8
	k := 0
	for i := len(p) - 1; i >= 0 && k + 2 < len(out); i -= 1 {
		out[k], out[k + 1] = DIGITS[p[i] >> 4], DIGITS[p[i] & 15]
		k += 2
	}
	rt.print("0x", string(out[:k]))
}

@(private="file")
say_reg :: proc "contextless" (name: string, i: u32, p: []u8) {
	rt.print(name, u64(i), "=")
	say_bytes(p)
	rt.print("\n")
}

// A little-endian T at off in b, which holds it.
@(private="file")
load_le :: proc "contextless" ($T: typeid, b: []u8, off: int) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[off:][:size_of(T)])))
}

when ODIN_ARCH == .amd64 {
	// Where XSAVE's standard image keeps component c (CPUID leaf 0xD).
	@(private="file")
	xsave_offset :: proc "contextless" (c: u32) -> int {
		_, b, _, _ := intrinsics.x86_cpuid(0xd, c)
		return int(b)
	}
}

// The thread's whole FP/SIMD state (threads/N/xregs, ADR-0035).
@(private="file")
xregs :: proc() {
	@(static) xs: [64 * 1024]u8
	n, st := read_file(target_path(thread_file("xregs")), xs[:])
	if st != .Ok || n <= 0 {
		rt.print("dbg: no state: is the thread stopped?\n")
		return
	}
	x := xs[:n]
	when ODIN_ARCH == .amd64 {
		if n < 576 {
			rt.print("dbg: a short XSAVE image\n")
			return
		}
		mxcsr, bv, features := load_le(u32, x, 24), load_le(u64, x, 512), rt.cpu().xfeatures
		rt.print("mxcsr=")
		say_hex(u64(mxcsr))
		rt.print(" xstate_bv=")
		say_hex(bv)
		rt.print(" xcr0=")
		say_hex(features)
		rt.print("\n")
		ymm := features & 4 != 0 ? xsave_offset(2) : 0
		for i in 0 ..< 16 {
			v: [32]u8
			copy(v[:16], x[160 + 16 * i:][:16])
			if ymm != 0 && ymm + 16 * (i + 1) <= n {
				copy(v[16:], x[ymm + 16 * i:][:16])
			}
			say_reg(ymm != 0 ? "ymm" : "xmm", u32(i), v[:ymm != 0 ? 32 : 16])
		}
		if features & 0x20 != 0 { // AVX-512's opmasks
			k := xsave_offset(5)
			for i := 0; i < 8 && k + 8 * (i + 1) <= n; i += 1 {
				say_reg("k", u32(i), x[k + 8 * i:][:8])
			}
		}
		if features & 0x200 != 0 { // PKRU: the thread's protection-key rights (ADR-0035)
			at := xsave_offset(9)
			pkru: u32 // not in use: its first value, 0
			if bv & 0x200 != 0 && at + 4 <= n {
				pkru = load_le(u32, x, at)
			}
			rt.print("pkru=")
			say_hex(u64(pkru))
			rt.print("\n")
		} else {
			rt.print("pkru: none (no protection keys)\n")
		}
	} else {
		if n < size_of(vx.Fpregs) {
			rt.print("dbg: a short state\n")
			return
		}
		f: vx.Fpregs
		copy(memory.ptr_to_bytes(&f), x)
		rt.print("fpcr=")
		say_hex(f.fpcr)
		rt.print(" fpsr=")
		say_hex(f.fpsr)
		rt.print("\n")
		for &v, i in f.v {
			say_reg("v", u32(i), v[:])
		}
		rt.print("por_el0: none (no protection keys)\n")
	}
}

@(private="file")
show :: proc(file: string) {
	@(static) text: [4096]u8
	if n, st := read_file(target_path(file), text[:]); st == .Ok && n > 0 {
		rt.print(string(text[:n]))
	}
}

// One command; false to quit.
@(private="file")
command :: proc(line_in: string) -> bool {
	line := line_in
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == ' ') {
		line = line[:len(line) - 1]
	}
	for len(line) > 0 && line[0] == ' ' {
		line = line[1:]
	}
	verb, rest := line, ""
	if sp := str.index_byte(line, ' '); sp >= 0 {
		verb, rest = line[:sp], line[sp:]
	}
	for len(rest) > 0 && rest[0] == ' ' {
		rest = rest[1:]
	}
	if len(verb) == 0 || verb[0] == '#' {
		return true
	}
	switch verb {
	case "quit":
		return false
	case "break":
		addr := resolve(rest)
		switch {
		case addr == 0:
			rt.print("dbg: no such function or line\n")
			return true
		case state.live:
			if set_break(addr) != .Ok {
				rt.print("dbg: cannot set it\n")
				return true
			}
		case:
			if append(&state.breaks, addr) == 0 {
				rt.print("dbg: too many breakpoints before run\n")
				return true
			}
		}
		rt.print("dbg: breakpoint at ")
		say_hex(addr)
		rt.print(" in ")
		say_where(addr)
		rt.print("\n")
	case "run":
		if len(state.crash_dir) > 0 || state.pid != 0 {
			rt.print("dbg: not a program to launch\n")
		} else {
			start_program()
		}
	case "cont", "continue":
		if !state.live {
			rt.print("dbg: not running\n")
			return true
		}
		_ = ctl("start")
		wait_event()
	case "step":
		if !state.live {
			rt.print("dbg: not running\n")
			return true
		}
		_ = write_file(target_path(thread_file("ctl")), "step")
		wait_event()
	case "bt", "where":
		bt()
	case "frame":
		n := parse_num(rest)
		if n >= u64(len(state.frames)) {
			rt.print("dbg: no such frame\n")
			return true
		}
		state.frame = int(n)
		rt.print(" #", n, " in ")
		say_where(debug.frame_lookup_pc(&state.frames[n]))
		rt.print("\n")
	case "print", "p":
		print(rest)
	case "regs":
		show(thread_file("regs.ndb"))
	case "xregs":
		xregs()
	case "threads":
		threads()
	case "thread":
		n := parse_num(rest)
		rec: [256]u8
		if n == 0 || thread_status(n, rec[:]) == "" {
			rt.print("dbg: no such thread\n")
			return true
		}
		state.thread = u32(n)
		refresh()
		rt.print("dbg: thread ", n)
		if state.have_regs {
			rt.print(" at ")
			say_where(regs_pc())
		}
		rt.print("\n")
	case "info":
		show("images")
		show("maps")
	case "kill":
		if state.live {
			_ = ctl("kill")
			wait_event()
		}
	case:
		rt.print("dbg: break, run, cont, step, bt, frame, print, regs, xregs, threads, thread, info, kill, quit\n")
	}
	return true
}

// The program's ELF, read whole, and its index.
@(private="file")
load :: proc(path: string) -> bool {
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return false
	}
	image_size = 0
	for image_size < len(image) {
		n, st := ns.read(&f, image[image_size:])
		if st != .Ok || n <= 0 {
			break
		}
		image_size += n
	}
	more: [1]u8
	whole := true
	if image_size == len(image) {
		n, st := ns.read(&f, more[:])
		whole = st != .Ok || n <= 0
	}
	ns.close(&f)
	if !whole { // never indexed, or launched, cut short
		rt.print("dbg: the program is larger than dbg can load (8 MiB)\n")
		return false
	}
	elf, ok := debug.elf_open(image[:image_size])
	if !ok {
		return false
	}
	arena := debug.Arena {
		buf = arena_mem[:],
	}
	index: []u8
	index, ok = debug.build_index(&elf, &arena)
	if !ok {
		return false
	}
	ix, ok = debug.open(index)
	if !ok {
		return false
	}
	target.machine = elf.machine
	return true
}

// The program's path, from a process's (or a crash directory's) images: its
// name, in /boot/bin.
@(private="file")
load_named :: proc() -> bool {
	rec: [256]u8
	n, st := read_file(target_path("images"), rec[:])
	name := field(string(rec[:n if st == .Ok && n > 0 else 0]), "name")
	if len(name) == 0 || len(name) > 64 {
		return false
	}
	clear(&state.program)
	append(&state.program, "/boot/bin/")
	append(&state.program, name)
	return load(string(state.program[:]))
}

@(private="file")
script_text: [16 * 1024]u8

// dbg with its arguments, once its namespace is up and `me` known: its exit
// string ("" for success).
session :: proc(argv: []string) -> string {
	state = {}
	a := 0
	script := ""
	if a < len(argv) && argv[a] == "-c" {
		a += 1 // the command line: the only face dbg has yet
	}
	if a + 1 < len(argv) && argv[a] == "-x" {
		script = argv[a + 1]
		a += 2
	}
	if a >= len(argv) {
		rt.print(usage.TEXT, "\n")
		return "usage"
	}
	target_arg := argv[a]
	ok: bool
	switch {
	case target_arg == "-p" && a + 1 < len(argv): // attach
		state.pid = parse_num(argv[a + 1])
		state.live = true
		ok = load_named()
	case len(target_arg) > len("/tmp/crash/") && str.has_prefix(target_arg, "/tmp/crash/"): // a crash directory
		if len(target_arg) >= cap(state.crash_dir) {
			return "path too long"
		}
		append(&state.crash_dir, target_arg)
		ok = load_named()
		if ok {
			fault_thread()
			refresh()
		}
	case: // a program to launch
		if len(target_arg) >= cap(state.program) {
			return "path too long"
		}
		append(&state.program, target_arg)
		for arg in argv[a + 1:] {
			if append(&state.args, arg) == 0 {
				break
			}
		}
		ok = load(string(state.program[:]))
	}
	if !ok {
		rt.print("dbg: cannot read the program's symbols\n")
		return "no symbols"
	}
	rt.print("dbg: ", string(state.program[:]), ": ", u64(len(ix.funcs)), " functions, ", u64(len(ix.lines)), " lines\n")
	// Commands: from the script, or the console.
	if script != "" {
		f: ns.File
		if ns.open(&space, script, p9.OREAD, &f) != .Ok {
			return "cannot read the script"
		}
		n, _ := ns.read_all(&f, script_text[:])
		ns.close(&f)
		rest := string(script_text[:n])
		for line in str.split_iterator(&rest, '\n') {
			rt.print("(dbg) ", line, "\n")
			if !command(line) {
				break
			}
		}
	} else {
		for {
			rt.print("(dbg) ")
			n, st := rt.read(script_text[:])
			if st != .Ok || n <= 0 || !command(string(script_text[:n])) {
				break
			}
		}
	}
	if state.live && state.launched {
		_ = ctl("kill") // what dbg launched does not outlive it
	} else if state.live {
		_ = ctl("detach")
	}
	return ""
}

// The program ends with run's exit string, as upstream's programs return
// theirs: empty for success (ADR-0010).
@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	if procns.from_spawn(&space) != .Ok {
		return "no namespace"
	}
	if info, st := rt.task_info(rt.self); st == .Ok {
		me = info.id
	}
	return session(rt.args())
}
