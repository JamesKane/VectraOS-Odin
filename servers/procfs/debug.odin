// /proc/N's debug files (upstream docs/05 §3), as acid reads Plan 9's.
//
//   /proc/N/ctl          also: break ADDR [if COND] [after N] · unbreak ADDR ·
//                        watch ADDR LEN write|rw · unwatch ADDR · step T ·
//                        freeze T · thaw T · detach
//   /proc/N/events       a read waits for a debug event, then returns its record:
//                          event=break thread=1 pc=0x401a20
//                          event=step thread=1 pc=0x401a24
//                          event=fault thread=1 pc=0x401a30 addr=0x0 access=read
//                          event=trap thread=1 pc=0x401a40   (a breakpoint the program has)
//                          event=watch thread=1 pc=0x401a50 addr=0x4c2008 access=write
//   /proc/N/mem          the address space as a file: read or write at an address
//   /proc/N/maps         one record per mapping: base= size= prot=r-x offset=
//   /proc/N/images       one record per ELF image: name= base= build-id=
//   /proc/N/info         arch= watchpoints= (the hardware's) breakpoints= (procfs's)
//   /proc/N/threads/T/   status (state= reason= pc=), regs (vx.Regs, binary),
//                        regs.ndb (the same as one record; write NAME=VALUE to
//                        set), fpregs (vx.Fpregs, binary), xregs (the whole
//                        FP/SIMD state, binary: ADR-0035), ctl (step · resume ·
//                        freeze · thaw)
//
// Breakpoints live here, not in the debugger, so a shell script and dbg share
// them: procfs writes the trap (int3, brk #0) through task_mem_rw, which gives
// the task a private copy of the code page, and binds its port to the task's
// exceptions first (.First_Chance) the first time a breakpoint is set or
// events is opened. A thread that reaches one stays stopped, with an event,
// until ctl's start (or the thread's resume or step): then procfs puts the
// code back, steps the thread over it, and puts the trap back. A simple
// condition is evaluated here, without a round trip to the debugger: a
// register, or the word at an address, against a constant (`if rdi==3`, `if
// [0x7f001000]>=100`), and `after N` lets N hits go by. A fault stops the
// thread with an event, and resuming it passes the fault on, to the program's
// handler or the default. Watchpoints are the task's debug registers
// (thread_state .Set_Watch); a thread stopped at one is stepped past it with
// them off, since aarch64 stops before the access and would only stop again.
//
// Reading registers needs the thread held still: stopped at an event, or
// frozen (thread_suspend, as ctl's stop does to every thread).
//
// All-stop (upstream's M6 step 6d6a), as a debugger expects: when a thread
// stops with an event, procfs suspends every other thread of the task (each
// by its own thread_suspend, which counts, so a freeze of the debugger's own
// outlasts it), and starts them again when the stopped one is let go (its
// resume, ctl's start); a step of the stopped one leaves them stopped. While
// a thread steps over a breakpoint, its trap taken out, the others stay
// stopped too, even for a breakpoint whose condition let it go on, so none
// runs past the trap while it is out. A thread made while the others are
// stopped runs. Any number of threads are followed: the tables grow.
package procfs

import "base:intrinsics"
import vx "abi:vx"
import "vx:memory"
import "vx:ndb"
import "vx:rt"
import "vx:str"

DBG_BREAKS :: 32
@(private="file")
DBG_EVENTS :: 32
@(private="file")
DBG_EVENT_LEN :: 160
@(private="file")
DBG_FIRST_THREADS :: 16 // the thread tables' first size; they double from there
@(private="file")
DBG_FIRST_PAUSED :: 64

@(private="file")
Cmp_Op :: enum u8 {
	None,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

@(private="file")
Breakpoint :: struct {
	used:         bool,
	addr:         u64,
	orig:         [len(TRAP)]u8, // the code the trap replaced
	op:           Cmp_Op, // the condition, if any: a register's value, or (mem) the word at `at`
	mem:          bool,
	reg:          int,
	at, value:    u64,
	after, hits:  u64, // it stops once hits > after
}

// Why procfs holds a thread stopped at its exception port.
@(private)
Why :: enum u8 {
	None,
	Break,
	Step,
	Fault,
	Trap,
	Over, // being stepped over its breakpoint
	Watch,
	Wover, // being stepped past its watchpoint
}

@(private)
Held :: struct {
	tid:       u32,
	why:       Why,
	user_step: bool, // .Over, .Wover: a step the debugger asked for, which ends with an event
	bp:        Maybe(int), // .Break, .Over: the breakpoint
	pc:        u64,
}

// A fault the debugger has seen and passed on, on one thread: if the program's
// handler declines it and runs the instruction again (the musl back end's
// fatal path does), the same fault comes back, and goes on without a second
// stop, so it reaches the default and the crash directory (upstream
// f24356f, from this tree's finding).
@(private)
Passed :: struct {
	tid:     u32,
	kind:    vx.Exception_Kind,
	code:    u32,
	pc:      u64,
	address: u64,
}

@(private)
Debugger :: struct {
	bound:    bool, // procfs's port takes the task's exceptions first
	bp:       [DBG_BREAKS]Breakpoint,
	watches:  vx.Watches, // the task's watchpoints, as procfs set them
	// The threads followed, and the faults passed on: in memory of their own
	// (table_grow), freed when the debugger is forgotten. Each table grows
	// alone, so growing the faults' never moves a Held a caller holds.
	threads:  []Held,
	passed:   []Passed,
	// All-stop: the threads procfs suspended for an event or a step over
	// (paused[:npaused]), and whether the debugger has let the task go on
	// since its last event.
	paused:   []u32,
	npaused:  int,
	pausing:  bool,
	stopped:  bool,
	events:   [DBG_EVENTS][dynamic; DBG_EVENT_LEN]u8,
	ev_head:  u32,
	ev_count: u32,
	lost:     u32,
}

@(private="file")
dbgs: [MAX_PROCS]Debugger // by the process's slot

@(private)
dbg_of :: proc "contextless" (p: ^Proc) -> ^Debugger {
	return &dbgs[p.slot]
}

// The key of a process's exception binding: as its exit key, with .debug set.
@(private="file")
dbg_key :: proc "contextless" (p: ^Proc) -> u64 {
	key := exit_key(p)
	key.debug = true
	return transmute(u64)key
}

when ODIN_ARCH == .amd64 {
	@(private="file")
	TRAP :: [1]u8{0xcc} // int3
	@(private="file")
	REG_NAMES := [?]string{"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "rip", "rflags"}
	@(private)
	reg_pc :: proc "contextless" (r: ^vx.Regs) -> ^u64 {
		return &r.rip
	}
	@(private)
	ARCH :: "x86_64"
} else {
	@(private="file")
	TRAP :: [4]u8{0x00, 0x00, 0x20, 0xd4} // brk #0
	@(private="file")
	REG_NAMES := [?]string {
		"x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16",
		"x17", "x18", "x19", "x20", "x21", "x22", "x23", "x24", "x25", "x26", "x27", "x28", "x29", "x30", "sp", "pc", "pstate",
	}
	@(private)
	reg_pc :: proc "contextless" (r: ^vx.Regs) -> ^u64 {
		return &r.pc
	}
	@(private)
	ARCH :: "aarch64"
}

// The trap's bytes, as a variable: task_mem_rw copies from an address.
@(private="file")
trap_bytes := TRAP

@(private="file")
REG_COUNT :: len(REG_NAMES)
#assert(size_of(vx.Regs) == REG_COUNT * size_of(u64))
#assert(size_of(vx.Regs) <= size_of(vx.Fpregs))

@(private="file")
reg_at :: proc "contextless" (r: ^vx.Regs, i: int) -> ^u64 {
	return &(^[REG_COUNT]u64)(r)[i]
}

@(private="file")
reg_index :: proc "contextless" (name: string) -> (int, bool) {
	for n, i in REG_NAMES {
		if n == name {
			return i, true
		}
	}
	return 0, false
}

// --- Text ---

// "0x" and v in lower-case hex, without leading zeros.
@(private)
hex_text :: proc "contextless" (v: u64, out: ^[18]u8) -> string {
	digits: [16]u8
	n := 0
	x := v
	for {
		digits[n] = HEX[x & 15]
		n += 1
		x >>= 4
		if x == 0 {
			break
		}
	}
	out[0], out[1] = '0', 'x'
	for i in 0 ..< n {
		out[2 + i] = digits[n - 1 - i]
	}
	return string(out[:n + 2])
}

@(private="file")
HEX := "0123456789abcdef"

@(private="file")
put_hex :: proc "contextless" (w: ^ndb.Writer, key: string, v: u64) {
	buf: [18]u8
	ndb.put(w, key, hex_text(v, &buf))
}

// A hexadecimal digit's value, or 16.
@(private="file")
hex_digit :: proc "contextless" (c: u8) -> u64 {
	switch c {
	case '0' ..= '9':
		return u64(c - '0')
	case 'a' ..= 'f':
		return u64(c - 'a') + 10
	case 'A' ..= 'F':
		return u64(c - 'A') + 10
	}
	return 16
}

// A number: decimal, or hexadecimal after 0x.
@(private="file")
parse_num :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		if len(s) > 18 {
			return 0, false
		}
		for i in 2 ..< len(s) {
			d := hex_digit(s[i])
			if d == 16 {
				return 0, false
			}
			v = v << 4 | d
		}
		return v, true
	}
	return parse_dec(s)
}

// The next space-separated word of s, taken off it.
@(private="file")
next_word :: proc "contextless" (s: ^string) -> string {
	i := 0
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' {
		i += 1
	}
	w := s[start:i]
	s^ = s[i:]
	return w
}

// --- Events ---

@(private="file")
dbg_event :: proc "contextless" (p: ^Proc, kind: string, tid: u32, pc: u64, extra: string = "") {
	d := dbg_of(p)
	if d.ev_count == DBG_EVENTS { // no one is reading: the newest are lost, and counted
		d.lost += 1
		return
	}
	at := (d.ev_head + d.ev_count) % DBG_EVENTS
	d.ev_count += 1
	buf: [DBG_EVENT_LEN]u8
	w := ndb.Writer{buf = buf[:]}
	ndb.put(&w, "event", kind)
	ndb.put_u64(&w, "thread", u64(tid))
	put_hex(&w, "pc", pc)
	str.write_string(&w, extra)
	_ = ndb.end(&w)
	clear(&d.events[at])
	if !w.failed {
		_ = append(&d.events[at], ..buf[:w.len])
	}
	server.again = true // a read of events held may go on
}

@(private, require_results)
take_event :: proc "contextless" (p: ^Proc, buf: []u8) -> (n: int, st: vx.Status) {
	d := dbg_of(p)
	if d.ev_count == 0 {
		return 0, .Err_Should_Wait
	}
	at := d.ev_head
	d.ev_head = (d.ev_head + 1) % DBG_EVENTS
	d.ev_count -= 1
	return copy(buf, d.events[at][:]), .Ok
}

// --- The task ---

@(private, require_results)
mem_rw :: proc "contextless" (p: ^Proc, addr: u64, buf: []u8, write: bool) -> vx.Status {
	op := [1]vx.Mem_Op{{address = addr, buffer = u64(uintptr(raw_data(buf))), size = u64(len(buf)), write = b32(write)}}
	rt.task_mem_rw(p.task, op[:]) or_return
	return op[0].status
}

@(private, require_results)
dbg_bind :: proc "contextless" (p: ^Proc) -> vx.Status {
	d := dbg_of(p)
	if d.bound {
		return .Ok
	}
	st := rt.exception_bind(p.task, server.port, dbg_key(p), {.First_Chance})
	d.bound = st == .Ok
	return st
}

// The bytes a table of n Ts takes: whole pages.
@(private="file")
table_bytes :: proc "contextless" ($T: typeid, n: int) -> u64 {
	size, _ := memory.page_round(u64(n) * size_of(T))
	return size
}

// A table twice as big as old (or first long, if there is none), in a VMO of
// its own, mapped: old's entries copied, the rest zero, old let go. ok is
// false if there is no memory, old then kept.
@(private="file")
table_grow :: proc "contextless" (old: []$T, first: int) -> (table: []T, ok: bool) {
	n := len(old) == 0 ? first : 2 * len(old)
	size := table_bytes(T, n)
	vmo, st := rt.vmo_create(size)
	if st != .Ok {
		return old, false
	}
	at: u64
	at, st = rt.as_map(rt.self, vmo, 0, size, {.Write})
	_ = rt.handle_close(vmo) // the mapping keeps it
	if st != .Ok {
		return old, false
	}
	table = ([^]T)(uintptr(at))[:n]
	intrinsics.mem_zero(raw_data(table), int(size))
	copy(table, old)
	table_free(old)
	return table, true
}

@(private="file")
table_free :: proc "contextless" (table: []$T) {
	if len(table) != 0 {
		_ = rt.as_unmap(rt.self, u64(uintptr(raw_data(table))), table_bytes(T, len(table)))
	}
}

@(private)
held_of :: proc "contextless" (p: ^Proc, tid: u32, make: bool) -> ^Held {
	d := dbg_of(p)
	free_slot: ^Held
	for &h in d.threads {
		if h.tid == tid {
			return &h
		}
		if h.tid == 0 && free_slot == nil {
			free_slot = &h
		}
	}
	if !make {
		return nil
	}
	if free_slot == nil { // the new half is free
		at := len(d.threads)
		ok: bool
		if d.threads, ok = table_grow(d.threads, DBG_FIRST_THREADS); !ok {
			return nil
		}
		free_slot = &d.threads[at]
	}
	free_slot^ = {tid = tid}
	return free_slot
}

// --- All-stop (see the top) ---

@(private="file")
is_paused :: proc "contextless" (d: ^Debugger, tid: u32) -> bool {
	for t in d.paused[:d.npaused] {
		if t == tid {
			return true
		}
	}
	return false
}

// Every other thread of p suspended: those paused already stay so, and
// threads made since are paused too; one held at an exception of its own
// is not, as it is stopped already and must be able to step when let go.
@(private="file")
pause_others :: proc "contextless" (p: ^Proc, tid: u32) {
	d := dbg_of(p)
	d.pausing = true
	ti: vx.Thread_Info
	for rt.thread_state(p.task, ti.id, .Next_Thread, &ti) == .Ok {
		if ti.id == tid || is_paused(d, ti.id) {
			continue
		}
		if h := held_of(p, ti.id, false); h != nil && h.why != .None {
			continue
		}
		if d.npaused == len(d.paused) {
			ok: bool
			if d.paused, ok = table_grow(d.paused, DBG_FIRST_PAUSED); !ok {
				break // the rest run: no memory to keep them
			}
		}
		if rt.thread_suspend(p.task, ti.id) == .Ok {
			d.paused[d.npaused] = ti.id
			d.npaused += 1
		}
	}
}

// A thread whose exception came while procfs had it paused (it stopped at
// the same time as the one that paused it): not paused any more, as it is
// held at its exception, and a suspended thread could not step over a
// breakpoint when let go.
@(private="file")
unpause_one :: proc "contextless" (p: ^Proc, tid: u32) {
	d := dbg_of(p)
	for &t in d.paused[:d.npaused] {
		if t == tid {
			_ = rt.thread_resume(p.task, tid)
			d.npaused -= 1
			t = d.paused[d.npaused]
			return
		}
	}
}

// The paused threads started again, if the debugger has let the task go on
// and no thread is stepping over a breakpoint or a watchpoint on its own.
@(private="file")
maybe_unpause :: proc "contextless" (p: ^Proc) {
	d := dbg_of(p)
	if !d.pausing || d.stopped {
		return
	}
	for &h in d.threads {
		if h.tid != 0 && (h.why == .Over || h.why == .Wover) && !h.user_step {
			return
		}
	}
	for t in d.paused[:d.npaused] {
		_ = rt.thread_resume(p.task, t) // gone, it may be
	}
	d.npaused = 0
	d.pausing = false
}

// An event reported: the task stays stopped until the debugger lets it go.
@(private="file")
stop_all :: proc "contextless" (p: ^Proc, tid: u32) {
	dbg_of(p).stopped = true
	pause_others(p, tid)
}

@(private="file")
bp_at :: proc "contextless" (d: ^Debugger, addr: u64) -> (int, bool) {
	for &b, i in d.bp {
		if b.used && b.addr == addr {
			return i, true
		}
	}
	return 0, false
}

@(private="file")
bp_condition :: proc "contextless" (p: ^Proc, b: ^Breakpoint, r: ^vx.Regs) -> bool {
	if b.op == .None {
		return true
	}
	v: u64
	if b.mem {
		if mem_rw(p, b.at, ptr_bytes(&v), false) != .Ok {
			return true // unreadable: stop, and let the user see
		}
	} else {
		v = reg_at(r, b.reg)^
	}
	switch b.op {
	case .Eq:
		return v == b.value
	case .Ne:
		return v != b.value
	case .Lt:
		return v < b.value
	case .Le:
		return v <= b.value
	case .Gt:
		return v > b.value
	case .Ge:
		return v >= b.value
	case .None:
	}
	return true
}

// Steps a thread held at its breakpoint over it: the code put back for one
// instruction, then the trap again (dbg_exception, at the .Step).
@(private="file", require_results)
step_over :: proc "contextless" (p: ^Proc, h: ^Held, user_step: bool) -> vx.Status {
	pause_others(p, h.tid) // none runs past the breakpoint while its trap is out
	i, ok := h.bp.?
	if !ok {
		return .Err_Bad_State
	}
	b := &dbg_of(p).bp[i]
	mem_rw(p, b.addr, b.orig[:], true) or_return
	h.why = .Over
	h.user_step = user_step
	return rt.exception_resume(p.task, h.tid, .Step)
}

// Sets the task's watchpoints: as procfs keeps them, or (off) none, while a
// thread steps past one.
@(private="file", require_results)
set_watches :: proc "contextless" (p: ^Proc, off: bool) -> vx.Status {
	none: vx.Watches
	return rt.thread_state(p.task, 0, .Set_Watch, off ? &none : &dbg_of(p).watches)
}

// Steps a thread held at a watchpoint past it, the watchpoints off for the
// one instruction (dbg_exception puts them back, at the .Step).
@(private="file", require_results)
watch_over :: proc "contextless" (p: ^Proc, h: ^Held, user_step: bool) -> vx.Status {
	pause_others(p, h.tid) // none passes the watchpoint while they are off
	set_watches(p, true) or_return
	h.why = .Wover
	h.user_step = user_step
	return rt.exception_resume(p.task, h.tid, .Step)
}

// Lets a held thread go: over its breakpoint, past its fault (to whoever is
// next in line), or on.
@(private="file", require_results)
release :: proc "contextless" (p: ^Proc, h: ^Held) -> vx.Status {
	#partial switch h.why {
	case .Break:
		return step_over(p, h, false)
	case .Watch:
		return watch_over(p, h, false)
	case .Over, .Wover:
		return .Ok // on its way already
	}
	if h.why == .Fault {
		remember_pass(p, h)
	}
	st := rt.exception_resume(p.task, h.tid, h.why == .Fault || h.why == .Trap ? .Pass : .Continue)
	h^ = {}
	return st
}

// A held thread let go by the debugger: the others with it, once it is past
// its breakpoint.
@(private="file", require_results)
let_go :: proc "contextless" (p: ^Proc, h: ^Held) -> vx.Status {
	dbg_of(p).stopped = false
	st := release(p, h)
	maybe_unpause(p)
	return st
}

// Notes the fault a held thread is let go past, for dbg_exception.
@(private="file")
remember_pass :: proc "contextless" (p: ^Proc, h: ^Held) {
	d := dbg_of(p)
	e: vx.Exception
	if rt.thread_state(p.task, h.tid, .Get_Exception, &e) != .Ok {
		return
	}
	// The thread's place, or a free one, the table grown for it if need be;
	// none (no memory for more): it is then stopped again, as upstream's.
	slot: ^Passed
	for &q in d.passed {
		if q.tid == h.tid {
			slot = &q
			break
		}
		if q.tid == 0 && slot == nil {
			slot = &q
		}
	}
	if slot == nil { // the new half is free
		at := len(d.passed)
		ok: bool
		if d.passed, ok = table_grow(d.passed, DBG_FIRST_THREADS); ok {
			slot = &d.passed[at]
		}
	}
	if slot != nil {
		slot^ = {tid = h.tid, kind = e.kind, code = e.code, pc = reg_pc(&e.regs)^, address = e.address}
	}
}

// Whether this fault is the one the thread was just let go past, come back
// because the program's handler declined it; forgets it either way.
@(private="file")
passed_again :: proc "contextless" (d: ^Debugger, tid: u32, e: ^vx.Exception) -> bool {
	for &q in d.passed {
		if q.tid == tid {
			again := q.kind == e.kind && q.code == e.code && q.pc == reg_pc(&e.regs)^ && q.address == e.address
			q = {}
			return again
		}
	}
	return false
}

@(private="file", require_results)
step_thread :: proc "contextless" (p: ^Proc, tid: u32) -> vx.Status {
	h := held_of(p, tid, false)
	if h == nil || h.why == .Over || h.why == .Wover {
		return .Err_Bad_State // only one stopped at an event
	}
	#partial switch h.why {
	case .Break:
		return step_over(p, h, true)
	case .Watch:
		return watch_over(p, h, true)
	}
	h.why = .Over // a step with no breakpoint to put back
	h.bp = nil
	h.user_step = true
	return rt.exception_resume(p.task, tid, .Step)
}

@(private="file")
fault_access :: proc "contextless" (e: ^vx.Exception) -> string {
	if e.kind != .Page_Fault {
		return ""
	}
	switch e.code {
	case 1:
		return " access=write"
	case 2:
		return " access=exec"
	}
	return " access=read"
}

// Where a trap was: int3 reports the instruction after it.
@(private="file")
trap_addr :: proc "contextless" (pc: u64) -> u64 {
	return pc - 1 when ODIN_ARCH == .amd64 else pc
}

// " addr=0x... access=..." for an event.
@(private="file")
addr_extra :: proc "contextless" (address: u64, access: string, out: ^[64]u8) -> string {
	hex: [18]u8
	s, _ := str.join(out[:], " addr=", hex_text(address, &hex), access)
	return s
}

// A thread of p stopped at procfs's port.
@(private)
dbg_exception :: proc "contextless" (p: ^Proc, tid: u32) {
	d := dbg_of(p)
	e: vx.Exception
	if rt.thread_state(p.task, tid, .Get_Exception, &e) != .Ok {
		return
	}
	if !d.bound { // queued before a detach, which let go of the port: let the thread go on
		go := vx.Resume_Action.Continue // a step or a watchpoint: nothing to see now
		#partial switch e.kind {
		case .Breakpoint:
			addr := trap_addr(reg_pc(&e.regs)^)
			now: [len(TRAP)]u8
			// The trap still there is the program's own; one gone was a
			// breakpoint detach took out: the instruction it replaced runs,
			// from its start.
			if mem_rw(p, addr, now[:], false) == .Ok && now != TRAP {
				reg_pc(&e.regs)^ = addr
				_ = rt.thread_state(p.task, tid, .Set_Regs, &e.regs)
			} else {
				go = .Pass
			}
		case .Step, .Watchpoint:
		case:
			go = .Pass // a fault: as if no debugger had been there
		}
		_ = rt.exception_resume(p.task, tid, go)
		return
	}
	unpause_one(p, tid)
	h := held_of(p, tid, true)
	if h == nil { // no memory to follow it: let it go
		_ = rt.exception_resume(p.task, tid, .Pass)
		return
	}
	pc := reg_pc(&e.regs)^
	extra: [64]u8
	#partial switch e.kind {
	case .Step:
		// The trap or the watchpoints back, once the last thread stepping
		// past them is: two threads let go at one breakpoint together (ctl's
		// start) step over it together, and the first back must not put the
		// trap in the second's way (UPSTREAM-FINDINGS).
		if i, ok := h.bp.?; h.why == .Over && ok && d.bp[i].used && !stepping_past(d, tid, .Over, i) {
			_ = mem_rw(p, d.bp[i].addr, trap_bytes[:], true) // the trap, back
		}
		if h.why == .Wover && !stepping_past(d, tid, .Wover, -1) {
			_ = set_watches(p, false) // the watchpoints, back
		}
		if (h.why == .Over || h.why == .Wover) && !h.user_step { // past it, on the way on
			h^ = {}
			_ = rt.exception_resume(p.task, tid, .Continue)
			maybe_unpause(p) // the others with it, unless the debugger holds them
			return
		}
		h^ = {tid = tid, why = .Step, pc = pc}
		stop_all(p, tid)
		dbg_event(p, "step", tid, pc)
	case .Breakpoint:
		addr := trap_addr(pc)
		i, ok := bp_at(d, addr)
		if !ok { // the program's own
			h^ = {tid = tid, why = .Trap, pc = pc}
			stop_all(p, tid)
			dbg_event(p, "trap", tid, pc)
			return
		}
		reg_pc(&e.regs)^ = addr // back at the instruction the trap replaced
		_ = rt.thread_state(p.task, tid, .Set_Regs, &e.regs)
		b := &d.bp[i]
		b.hits += 1
		h^ = {tid = tid, why = .Break, bp = i, pc = addr}
		if b.hits <= b.after || !bp_condition(p, b, &e.regs) { // not this time: on, at once
			_ = step_over(p, h, false)
			return
		}
		stop_all(p, tid)
		dbg_event(p, "break", tid, addr)
	case .Watchpoint:
		h^ = {tid = tid, why = .Watch, pc = pc}
		w := &d.watches.slot[e.code < vx.WATCH_MAX ? e.code : 0]
		stop_all(p, tid)
		dbg_event(p, "watch", tid, pc, addr_extra(e.address, w.kind == .Write ? " access=write" : " access=rw", &extra))
	case .Interrupt: // a note, not a fault: to the program's handler
		h^ = {}
		_ = rt.exception_resume(p.task, tid, .Pass)
	case:
		if passed_again(d, tid, &e) { // seen, passed on, and declined: on, to the task's own port
			h^ = {}
			_ = rt.exception_resume(p.task, tid, .Pass)
			return
		}
		h^ = {tid = tid, why = .Fault, pc = pc}
		stop_all(p, tid)
		dbg_event(p, "fault", tid, pc, addr_extra(e.address, fault_access(&e), &extra))
	}
}

// Whether an event is waiting to be read: then ctl's start lets nothing go
// (upstream's M6 step 6d6a), so a debugger that continues after one
// thread's stop sees the stop another thread made at the same time before
// anything runs on.
@(private)
dbg_pending :: proc "contextless" (p: ^Proc) -> bool {
	return dbg_of(p).ev_count > 0
}

// Whether a thread other than tid is stepping past breakpoint bp (why .Over)
// or a watchpoint (.Wover, bp -1).
@(private="file")
stepping_past :: proc "contextless" (d: ^Debugger, tid: u32, why: Why, bp: int) -> bool {
	for &o in d.threads {
		if o.tid == 0 || o.tid == tid || o.why != why {
			continue
		}
		i, ok := o.bp.?
		if why == .Wover || (ok && i == bp) {
			return true
		}
	}
	return false
}

// Every held thread let go: ctl's start. (release may grow the faults'
// table, never the threads': the loop's slice stays the table.)
@(private)
release_all :: proc "contextless" (p: ^Proc) {
	d := dbg_of(p)
	d.stopped = false
	for &h in d.threads {
		if h.tid != 0 {
			_ = release(p, &h)
		}
	}
	maybe_unpause(p)
}

// --- ctl ---

@(private="file")
Cmp_Text :: struct {
	text: string,
	op:   Cmp_Op,
}

// In the order they are tried: the two-character ones first.
@(private="file")
OPS := [?]Cmp_Text{{"==", .Eq}, {"!=", .Ne}, {"<=", .Le}, {">=", .Ge}, {"<", .Lt}, {">", .Gt}}

@(private="file", require_results)
set_break :: proc "contextless" (p: ^Proc, args: string) -> vx.Status {
	args := args
	d := dbg_of(p)
	addr, ok := parse_num(next_word(&args))
	if !ok {
		return .Err_Invalid
	}
	b := Breakpoint{used = true, addr = addr}
	for w := next_word(&args); len(w) != 0; w = next_word(&args) {
		if w == "after" {
			b.after, ok = parse_num(next_word(&args))
			if !ok {
				return .Err_Invalid
			}
			continue
		}
		if w != "if" {
			return .Err_Invalid
		}
		c := next_word(&args) // LHS OP VALUE, with no spaces: rdi==3, [0x1000]>=100
		at := 0
		for at < len(c) && c[at] != '=' && c[at] != '!' && c[at] != '<' && c[at] != '>' {
			at += 1
		}
		if at == 0 || at + 1 >= len(c) {
			return .Err_Invalid
		}
		lhs, rest := c[:at], c[at:]
		oplen := 0
		for o in OPS {
			if len(rest) > len(o.text) && str.has_prefix(rest, o.text) {
				b.op, oplen = o.op, len(o.text)
				break
			}
		}
		if b.op == .None {
			return .Err_Invalid
		}
		b.value, ok = parse_num(rest[oplen:])
		if !ok {
			return .Err_Invalid
		}
		if len(lhs) > 2 && lhs[0] == '[' && lhs[len(lhs) - 1] == ']' {
			b.mem = true
			b.at, ok = parse_num(lhs[1:len(lhs) - 1])
			if !ok {
				return .Err_Invalid
			}
		} else {
			b.reg, ok = reg_index(lhs)
			if !ok {
				return .Err_Invalid
			}
		}
	}
	if i, found := bp_at(d, addr); found { // the same place: its condition and count replaced, the trap kept
		b.orig = d.bp[i].orig
		d.bp[i] = b
		return .Ok
	}
	for &slot in d.bp {
		if slot.used {
			continue
		}
		dbg_bind(p) or_return
		mem_rw(p, addr, b.orig[:], false) or_return
		mem_rw(p, addr, trap_bytes[:], true) or_return
		slot = b
		return .Ok
	}
	return .Err_No_Memory
}

@(private="file", require_results)
clear_break :: proc "contextless" (p: ^Proc, addr: u64) -> vx.Status {
	d := dbg_of(p)
	i, ok := bp_at(d, addr)
	if !ok {
		return .Err_Not_Found
	}
	st := vx.Status.Ok
	stepping := false // a thread stepping over it has the code back already, and must not get the trap
	for &h in d.threads {
		if j, has := h.bp.?; h.tid != 0 && has && j == i {
			stepping = stepping || h.why == .Over
			if h.why == .Break {
				h.why = .Step // held still, with nothing to step over
			}
			h.bp = nil
		}
	}
	if !stepping {
		st = mem_rw(p, addr, d.bp[i].orig[:], true)
	}
	d.bp[i] = {}
	return st
}

// watch ADDR LEN write|rw: a free slot of the hardware's; the same address
// again replaces it.
@(private="file", require_results)
set_watch :: proc "contextless" (p: ^Proc, args: string) -> vx.Status {
	args := args
	d := dbg_of(p)
	addr, ok1 := parse_num(next_word(&args))
	size, ok2 := parse_num(next_word(&args))
	if !ok1 || !ok2 {
		return .Err_Invalid
	}
	kind := next_word(&args)
	if kind != "write" && kind != "rw" {
		return .Err_Invalid
	}
	now: vx.Watches
	rt.thread_state(p.task, 0, .Get_Watch, &now) or_return // the hardware's count
	count := min(now.count, vx.WATCH_MAX)
	slot := -1
	for i in 0 ..< int(count) {
		if d.watches.slot[i].kind != .Off && d.watches.slot[i].address == addr {
			slot = i
			break
		}
	}
	for i in 0 ..< int(count) {
		if slot >= 0 {
			break
		}
		if d.watches.slot[i].kind == .Off {
			slot = i
		}
	}
	if slot < 0 {
		return .Err_No_Memory
	}
	dbg_bind(p) or_return
	was := d.watches.slot[slot]
	d.watches.slot[slot] = {address = addr, len = u32(size), kind = kind == "write" ? .Write : .Rw}
	st := set_watches(p, false)
	if st != .Ok {
		d.watches.slot[slot] = was // refused (not aligned, say): as it was
	}
	return st
}

@(private="file", require_results)
clear_watch :: proc "contextless" (p: ^Proc, addr: u64) -> vx.Status {
	d := dbg_of(p)
	for &w in d.watches.slot {
		if w.kind != .Off && w.address == addr {
			w = {}
			return set_watches(p, false)
		}
	}
	return .Err_Not_Found
}

// Every breakpoint out, every held thread let go, the binding gone.
@(private="file")
detach :: proc "contextless" (p: ^Proc) {
	d := dbg_of(p)
	for &b in d.bp {
		if b.used {
			_ = clear_break(p, b.addr)
		}
	}
	d.watches = {}
	_ = set_watches(p, true)
	release_all(p)
	if d.bound {
		_ = rt.exception_bind(p.task, vx.HANDLE_NONE, 0, {.First_Chance})
	}
	d.stopped = false
	for t in d.paused[:d.npaused] {
		_ = rt.thread_resume(p.task, t) // whatever is in flight
	}
	dbg_forget(p)
}

// ctl's debug verbs; Err_Not_Found for any other.
@(private, require_results)
dbg_ctl :: proc "contextless" (p: ^Proc, cmd: string) -> vx.Status {
	args := cmd
	verb := next_word(&args)
	switch verb {
	case "break":
		return p.root ? .Err_Access : set_break(p, args)
	case "unbreak":
		n, ok := parse_num(next_word(&args))
		return ok ? clear_break(p, n) : .Err_Invalid
	case "watch":
		return p.root ? .Err_Access : set_watch(p, args)
	case "unwatch":
		n, ok := parse_num(next_word(&args))
		return ok ? clear_watch(p, n) : .Err_Invalid
	case "detach":
		detach(p)
		return .Ok
	case "step", "freeze", "thaw":
	case:
		return .Err_Not_Found
	}
	n, ok := parse_dec(next_word(&args))
	if !ok || n == 0 || n > u64(max(u32)) {
		return .Err_Invalid
	}
	if p.root {
		return .Err_Access
	}
	switch verb {
	case "step":
		return step_thread(p, u32(n))
	case "freeze":
		return rt.thread_suspend(p.task, u32(n))
	}
	return rt.thread_resume(p.task, u32(n))
}

// A thread's ctl: step · resume · freeze · thaw.
@(private, require_results)
thread_ctl :: proc "contextless" (p: ^Proc, tid: u32, cmd: string) -> vx.Status {
	if p.root {
		return .Err_Access
	}
	switch cmd {
	case "step":
		return step_thread(p, tid)
	case "freeze":
		return rt.thread_suspend(p.task, tid)
	case "thaw":
		return rt.thread_resume(p.task, tid)
	case "resume":
		h := held_of(p, tid, false)
		return h != nil ? let_go(p, h) : .Err_Bad_State
	}
	return .Err_Invalid
}

// --- The files ---

@(private)
maps_text :: proc "contextless" (p: ^Proc, buf: []u8) -> int {
	w := ndb.Writer{buf = buf}
	for at := u64(0); !w.failed; {
		m, st := rt.as_query(p.task, at)
		if st != .Ok {
			break
		}
		put_hex(&w, "base", m.base)
		put_hex(&w, "size", m.size)
		opts := vx.map_options(m.flags)
		prot := [3]u8{'r', .Write in opts ? 'w' : '-', .Exec in opts ? 'x' : '-'}
		ndb.put(&w, "prot", string(prot[:]))
		put_hex(&w, "offset", m.offset)
		_ = ndb.end(&w)
		at = m.base + m.size
	}
	return w.failed ? 0 : w.len
}

// A little-endian value at off in b, which holds it.
@(private="file")
load :: proc "contextless" ($T: typeid, b: []u8, off: int) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[off:][:size_of(T)])))
}

// The build ID in a PT_NOTE segment at vaddr, filesz long: (its address, its length).
@(private="file")
find_build_id :: proc "contextless" (p: ^Proc, vaddr, filesz: u64) -> (at: u64, n: u32) {
	for off := u64(0); off + 12 <= filesz; {
		nh: [12]u8
		if mem_rw(p, vaddr + off, nh[:], false) != .Ok {
			break
		}
		namesz, descsz, type := load(u32, nh[:], 0), load(u32, nh[:], 4), load(u32, nh[:], 8)
		name_end := 12 + u64((namesz + 3) & ~u32(3))
		if type == 3 && namesz == 4 && descsz <= 32 { // NT_GNU_BUILD_ID, "GNU"
			return vaddr + off + name_end, descsz
		}
		off += name_end + u64((descsz + 3) & ~u32(3))
	}
	return 0, 0
}

// The program's ELF image: where its header is mapped (the lowest mapping
// that starts with one), and its build ID, from its PT_NOTE.
@(private)
images_text :: proc "contextless" (p: ^Proc, buf: []u8) -> int {
	info, ist := rt.task_info(p.task)
	if ist != .Ok {
		return 0
	}
	at: u64
	for {
		m, st := rt.as_query(p.task, at)
		if st != .Ok {
			break
		}
		at = m.base + m.size
		eh: [64]u8
		if mem_rw(p, m.base, eh[:], false) != .Ok || string(eh[:4]) != "\x7fELF" {
			continue
		}
		phoff, phentsize, phnum := load(u64, eh[:], 32), load(u16, eh[:], 54), load(u16, eh[:], 56)
		id_at: u64
		id_len: u32
		for i in 0 ..< min(phnum, 32) {
			if phentsize < 56 || id_len != 0 {
				break
			}
			ph: [56]u8
			if mem_rw(p, m.base + phoff + u64(i) * u64(phentsize), ph[:], false) != .Ok {
				break
			}
			if load(u32, ph[:], 0) == 4 { // PT_NOTE: its notes
				id_at, id_len = find_build_id(p, load(u64, ph[:], 16), load(u64, ph[:], 32))
			}
		}
		id: [32]u8
		hex: [64]u8
		if id_len != 0 && mem_rw(p, id_at, id[:id_len], false) != .Ok {
			id_len = 0
		}
		for b, i in id[:id_len] {
			hex[2 * i], hex[2 * i + 1] = HEX[b >> 4], HEX[b & 15]
		}
		w := ndb.Writer{buf = buf}
		ndb.put(&w, "name", str.from_nul_padded(info.name[:]))
		put_hex(&w, "base", m.base)
		if id_len != 0 {
			ndb.put(&w, "build-id", string(hex[:2 * id_len]))
		}
		_ = ndb.end(&w)
		return w.failed ? 0 : w.len
	}
	return 0
}

@(private="file")
RUN_STATES := [vx.Thread_Run_State]string {
	.Running   = "running",
	.Blocked   = "blocked",
	.Stopped   = "stopped",
	.Suspended = "frozen",
}

@(private="file")
REASONS := [Why]string {
	.None  = "",
	.Break = "break",
	.Step  = "step",
	.Fault = "fault",
	.Trap  = "trap",
	.Over  = "step",
	.Watch = "watch",
	.Wover = "step",
}

@(private)
info_text :: proc "contextless" (p: ^Proc, buf: []u8) -> int {
	w := ndb.Writer{buf = buf}
	ndb.put(&w, "arch", ARCH)
	watches: vx.Watches
	if rt.thread_state(p.task, 0, .Get_Watch, &watches) == .Ok {
		ndb.put_u64(&w, "watchpoints", u64(watches.count))
	}
	ndb.put_u64(&w, "breakpoints", DBG_BREAKS)
	_ = ndb.end(&w)
	return w.failed ? 0 : w.len
}

@(private)
thread_status_text :: proc "contextless" (p: ^Proc, tid: u32, buf: []u8) -> int {
	ti: vx.Thread_Info
	if rt.thread_state(p.task, tid - 1, .Next_Thread, &ti) != .Ok || ti.id != tid {
		return 0
	}
	w := ndb.Writer{buf = buf}
	// Suspended while blocked in a call: frozen, as it runs no more when the
	// call returns (upstream's 6d6a).
	run := ti.state == .Blocked && ti.suspend_count != 0 ? vx.Thread_Run_State.Suspended : ti.state
	state := "unknown"
	if u32(run) == 0 {
		state = ""
	} else if run <= .Suspended {
		state = RUN_STATES[run]
	}
	ndb.put(&w, "state", state)
	if h := held_of(p, tid, false); h != nil && h.why != .None {
		ndb.put(&w, "reason", REASONS[h.why])
	}
	r: vx.Regs
	if rt.thread_state(p.task, tid, .Get_Regs, &r) == .Ok {
		put_hex(&w, "pc", reg_pc(&r)^)
	}
	_ = ndb.end(&w)
	return w.failed ? 0 : w.len
}

@(private="file")
put_dec :: proc "contextless" (w: ^ndb.Writer, key: string, v: u64) {
	buf: [20]u8
	ndb.put(w, key, str.format_u64(buf[:], v))
}

// threads/T/sched (upstream's ADR-0038): its intent, and its context's
// period, budget, what is left of it this period, the periods it ran out
// in, and its CPUs; and the channel_call caller it runs for, if any.
@(private)
sched_text :: proc "contextless" (p: ^Proc, tid: u32, buf: []u8) -> int {
	INTENTS := [vx.Intent]string {
		.Realtime          = "realtime",
		.Interactive_Frame = "interactive-frame",
		.Interactive       = "interactive",
		.Throughput        = "throughput",
		.Background        = "background",
	}
	si: vx.Sched_Info
	if rt.thread_state(p.task, tid, .Get_Sched, &si) != .Ok {
		return 0
	}
	w := ndb.Writer{buf = buf}
	intent := "unknown"
	if u32(si.intent) == 0 {
		intent = ""
	} else if si.intent <= .Background {
		intent = INTENTS[si.intent]
	}
	ndb.put(&w, "intent", intent)
	ndb.put(&w, "context", si.bound != 0 ? "yes" : "no")
	if si.period != 0 {
		put_dec(&w, "period", u64(si.period))
		put_dec(&w, "budget", u64(si.budget))
		put_dec(&w, "left", u64(si.left))
		put_dec(&w, "exhausted", si.exhausted)
	}
	if si.reserved != 0 {
		put_hex(&w, "reserved", si.reserved)
		put_dec(&w, "cores", u64(si.reserved_count))
	}
	if si.core >= 0 {
		put_dec(&w, "core", u64(si.core))
	}
	if si.lent_task != 0 {
		put_dec(&w, "lent_task", si.lent_task)
		put_dec(&w, "lent_thread", si.lent_thread)
	}
	_ = ndb.end(&w)
	return w.failed ? 0 : w.len
}

@(private)
regs_ndb_text :: proc "contextless" (p: ^Proc, tid: u32, buf: []u8) -> int {
	r: vx.Regs
	if rt.thread_state(p.task, tid, .Get_Regs, &r) != .Ok {
		return 0
	}
	w := ndb.Writer{buf = buf}
	for name, i in REG_NAMES {
		put_hex(&w, name, reg_at(&r, i)^)
	}
	when ODIN_ARCH == .amd64 {
		// Its protection-key rights (ADR-0035), where there are keys: PKRU,
		// from its extended state at the place CPUID gives it. xregs sets them.
		@(static) xs: [vx.XSTATE_MAX]u8
		if rt.cpu().keys != 0 && rt.thread_state(p.task, tid, .Get_Xstate, &xs) == .Ok {
			_, at, _, _ := intrinsics.x86_cpuid(0xd, 9)
			if int(at) + 4 <= len(xs) {
				put_hex(&w, "rights", u64(intrinsics.unaligned_load((^u32)(&xs[at]))))
			}
		}
	}
	_ = ndb.end(&w)
	return w.failed ? 0 : w.len
}

// NAME=VALUE ...: those registers set, the rest as they are.
@(private, require_results)
regs_ndb_write :: proc "contextless" (p: ^Proc, tid: u32, s: string) -> vx.Status {
	s := s
	r: vx.Regs
	rt.thread_state(p.task, tid, .Get_Regs, &r) or_return
	for t := next_word(&s); len(t) != 0; t = next_word(&s) {
		eq := str.index_byte(t, '=')
		if eq < 0 {
			return .Err_Invalid
		}
		i, ok := reg_index(t[:eq])
		v: u64
		if ok {
			v, ok = parse_num(t[eq + 1:])
		}
		if !ok {
			return .Err_Invalid
		}
		reg_at(&r, i)^ = v
	}
	return rt.thread_state(p.task, tid, .Set_Regs, &r)
}

// A process ended, or its slot is reused: nothing of its debugging is left.
@(private)
dbg_forget :: proc "contextless" (p: ^Proc) {
	d := dbg_of(p)
	table_free(d.threads)
	table_free(d.passed)
	table_free(d.paused)
	d^ = {}
}
