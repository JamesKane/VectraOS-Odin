// cmd/dbg on the host: the program itself, against a recorded procfs. A
// fake file server stands in for procfs, bootfs and tmpfs, mounted at / in
// dbg's namespace through lib/p9's server framework and a loopback client
// (tests/host/p9test). It serves dbgdemo's ELF (fixtures/, as ./build
// compiles tests/user/dbgdemo.c), /proc/PID's debug files in procfs's
// formats, and the crash directory procfs leaves: a session's events, each
// with the registers, stack and data the program had there, as the m4/dbg
// scenario would see them. The test lays the stack out itself (frame
// records, and each variable where the fixture's DWARF puts it), from the
// fixture's own functions, call sites and variables.
//
// Upstream has no host test of dbg; these cases follow its cmd/dbg.c at
// 002a9a8, and check its console output byte for byte, including every line
// tests/qemu/m4/dbg.ndb expects (the scenario runs dbg -c, which launches;
// here dbg attaches with -p, which takes the same path from the first
// event on).
//
// Everything here is global (dbg's state and the fake's), so it is one
// test, in sessions that each start afresh.
package dbg_test

import "base:intrinsics"
import vx "abi:vx"
import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:debug"
import "vx:memory"
import "vx:ndb"
import "vx:ns"
import "vx:p9"
import "vx:rt"
import dbg "../../../cmd/dbg"
import "../p9test"

when ODIN_ARCH == .amd64 {
	fixture := #load("fixtures/dbgdemo-x86_64.elf")
} else {
	fixture := #load("fixtures/dbgdemo-aarch64.elf")
}

ME :: 7 // dbg's pid
PID :: 12 // the demo's
STACK_BASE :: u64(0x7fff_fffe_0000)
STACK_SIZE :: 0x1000
DATA_MAX :: 0x2000

// The fixture's source lines dbg names (tests/user/dbgdemo.c and the shim).
LINE_LEAF_BODY :: 21 // tally.calls++
LINE_FAULT :: 23 // the third call's fault
LINE_MIDDLE_CALL :: 28 // 2 * leaf(n)
LINE_VX_MAIN_CALL :: 35 // sum += middle(i)
LINE_MAIN_CALL :: 56 // lib/vx-rt/rt.c: vx_main()

// --- The fake kernel: dbg makes no system call here but its output ---

@(export, link_name="vx_syscall")
fake_syscall :: proc "c" (nr: vx.Syscall, a0, a1, a2, a3, a4, a5: u64) -> i64 {
	return i64(vx.Status.Err_Unsupported)
}

@(export, link_name="vx_cycles")
fake_cycles :: proc "c" () -> u64 {
	return 0
}

output: [dynamic; 64 * 1024]u8

capture :: proc "contextless" (s: string) {
	_ = append(&output, s)
}

// --- The program, as it stands at each event ---

// One snapshot of the process: its registers, its writable data and its
// stack. Everything else is the image's.
Proc :: struct {
	regs:  vx.Regs,
	data:  [DATA_MAX]u8, // the writable mapping, from data_base
	stack: [STACK_SIZE]u8, // from STACK_BASE
}

// The writable mapping: the image's RW PT_LOAD, in whole pages.
data_base, data_size: u64

region :: proc "contextless" (p: ^Proc, addr: u64, n: u64) -> []u8 {
	switch {
	case addr >= data_base && addr - data_base <= data_size && n <= data_size - (addr - data_base):
		return p.data[addr - data_base:][:n]
	case addr >= STACK_BASE && addr - STACK_BASE <= STACK_SIZE && n <= STACK_SIZE - (addr - STACK_BASE):
		return p.stack[addr - STACK_BASE:][:n]
	}
	return nil
}

proc_read :: proc "contextless" (p: ^Proc, addr: u64, buf: []u8) -> bool {
	if r := region(p, addr, u64(len(buf))); r != nil {
		copy(buf, r)
		return true
	}
	return debug.image_read(fixture, addr, buf)
}

put :: proc(p: ^Proc, addr: u64, v: $T, loc := #caller_location) {
	r := region(p, addr, size_of(T))
	assert(r != nil, "outside the fake's memory", loc)
	v := v
	copy(r, memory.ptr_to_bytes(&v))
}

when ODIN_ARCH == .amd64 {
	set_frame :: proc(r: ^vx.Regs, pc, sp, fp: u64) {r.rip, r.rsp, r.rbp = pc, sp, fp}
	reg_of :: proc "contextless" (r: ^vx.Regs, dwarf: u32) -> (u64, bool) {
		switch dwarf {
		case 6:
			return r.rbp, true
		case 7:
			return r.rsp, true
		}
		return 0, false
	}
} else {
	set_frame :: proc(r: ^vx.Regs, pc, sp, fp: u64) {r.pc, r.sp, r.x[29] = pc, sp, fp}
	reg_of :: proc "contextless" (r: ^vx.Regs, dwarf: u32) -> (u64, bool) {
		switch {
		case dwarf < 31:
			return r.x[dwarf], true
		case dwarf == 31:
			return r.sp, true
		}
		return 0, false
	}
}

// A T from the start of b, which must hold one.
load_le :: proc(b: []u8, $T: typeid) -> T {
	return intrinsics.unaligned_load((^T)(raw_data(b[:size_of(T)])))
}

// The fixture as the test reads it: its index, and where things are.
ix: debug.Index
arena: []u8
leaf, middle, vx_main_fn, main_fn: ^debug.Func
ret_middle, ret_vx_main, ret_main: u64 // the return addresses of the calls leaf ← middle ← vx_main ← main
fault_pc: u64
tally_addr, label_addr: u64

// The address after the call in `from` to `to`.
call_site :: proc(t: ^testing.T, from: ^debug.Func, to: ^debug.Func, loc := #caller_location) -> u64 {
	when ODIN_ARCH == .amd64 {
		for pc := from.low; pc + 5 <= from.high; pc += 1 {
			b: [5]u8
			if debug.image_read(fixture, pc, b[:]) && b[0] == 0xe8 {
				rel := i64(transmute(i32le)[4]u8{b[1], b[2], b[3], b[4]})
				if u64(i64(pc) + 5 + rel) == to.low {
					return pc + 5
				}
			}
		}
	} else {
		for pc := from.low; pc + 4 <= from.high; pc += 4 {
			b: [4]u8
			if !debug.image_read(fixture, pc, b[:]) {
				continue
			}
			w := u32(transmute(u32le)b)
			if w & 0xfc00_0000 == 0x9400_0000 { // bl
				imm := i64(w & 0x03ff_ffff)
				if imm & (1 << 25) != 0 {
					imm -= 1 << 26
				}
				if u64(i64(pc) + imm * 4) == to.low {
					return pc + 4
				}
			}
		}
	}
	testing.fail_now(t, "no call found", loc)
}

function :: proc(t: ^testing.T, name: string, loc := #caller_location) -> ^debug.Func {
	f, ok := debug.func_named(&ix, name)
	testing.expectf(t, ok, "the fixture has %s", name, loc = loc)
	return f
}

open_fixture :: proc(t: ^testing.T) {
	elf, ok := debug.elf_open(fixture)
	testing.expect(t, ok, "the fixture is an ELF image")
	arena = make([]u8, 16 << 20)
	a := debug.Arena {
		buf = arena,
	}
	index: []u8
	index, ok = debug.build_index(&elf, &a)
	testing.expect(t, ok, "the fixture is indexed")
	ix, ok = debug.open(index)
	testing.expect(t, ok, "its index opens")

	// The writable PT_LOAD, as procfs maps it: whole pages.
	phoff := u64(load_le(fixture[32:][:8], u64le))
	phentsize := u64(load_le(fixture[54:][:2], u16le))
	phnum := u64(load_le(fixture[56:][:2], u16le))
	for i in 0 ..< phnum {
		ph := fixture[phoff + i * phentsize:]
		type := u32(load_le(ph[0:][:4], u32le))
		flags := u32(load_le(ph[4:][:4], u32le))
		vaddr := u64(load_le(ph[16:][:8], u64le))
		memsz := u64(load_le(ph[40:][:8], u64le))
		if type == 1 && flags & 2 != 0 {
			data_base = vaddr &~ 0xfff
			data_size = (vaddr + memsz + 0xfff) &~ 0xfff - data_base
		}
	}
	testing.expect(t, data_size > 0 && data_size <= DATA_MAX, "the fixture has a small writable segment")

	leaf, middle = function(t, "leaf"), function(t, "middle")
	vx_main_fn, main_fn = function(t, "vx_main"), function(t, "main")
	ret_middle = call_site(t, middle, leaf)
	ret_vx_main = call_site(t, vx_main_fn, middle)
	ret_main = call_site(t, main_fn, vx_main_fn)
	fault_pc, ok = debug.line_addr(&ix, "tests/user/dbgdemo.c", LINE_FAULT)
	testing.expect(t, ok, "the fault's line has code")
	v, gok := debug.global_named(&ix, "tally")
	testing.expect(t, gok, "the fixture has tally")
	expr, _ := debug.var_location(&ix, v, 0)
	testing.expect(t, len(expr) == 9 && expr[0] == 0x03, "tally is at a DW_OP_addr")
	tally_addr = u64(load_le(expr[1:], u64le))
	b: [8]u8
	testing.expect(t, debug.image_read(fixture, tally_addr + 16, b[:]), "tally.label is in the image")
	label_addr = u64(transmute(u64le)b)
}

// The process stopped in leaf's call number n, at pc: a frame record each
// for leaf, middle, vx_main and main (whose saved fp of 0 ends the chain),
// n in leaf's frame and middle's, and tally as the earlier calls left it.
// When `faulted`, the call has done its sums: the fault is after them.
snapshot :: proc(t: ^testing.T, p: ^Proc, n: int, pc: u64, faulted := false) {
	p^ = {}
	for &b, i in p.data[:data_size] {
		_ = debug.image_read(fixture, data_base + u64(i), ([^]u8)(&b)[:1])
	}
	leaf_fp := STACK_BASE + 0xc00
	middle_fp := STACK_BASE + 0xd00
	vx_main_fp := STACK_BASE + 0xe00
	main_fp := STACK_BASE + 0xf00
	put(p, leaf_fp, middle_fp)
	put(p, leaf_fp + 8, ret_middle)
	put(p, middle_fp, vx_main_fp)
	put(p, middle_fp + 8, ret_vx_main)
	put(p, vx_main_fp, main_fp)
	put(p, vx_main_fp + 8, ret_main)
	put(p, main_fp, u64(0))
	put(p, main_fp + 8, u64(0))
	set_frame(&p.regs, pc, leaf_fp - 0x40, leaf_fp)
	when ODIN_ARCH != .amd64 {
		p.regs.x[30] = ret_middle
	}

	calls := faulted ? n : n - 1
	total := 0
	for k in 1 ..= calls {
		total += k
	}
	put(p, tally_addr, i32(calls))
	put(p, tally_addr + 8, i64(total))

	probe := debug.Target {
		data    = p,
		machine = ODIN_ARCH == .amd64 ? .X86_64 : .AArch64,
		read    = proc "contextless" (data: rawptr, addr: u64, buf: []u8) -> bool {
			return proc_read((^Proc)(data), addr, buf)
		},
		reg     = proc "contextless" (data: rawptr, dwarf: u32) -> (u64, bool) {
			return reg_of(&(^Proc)(data).regs, dwarf)
		},
	}
	frames := [2]debug.Frame{{pc = pc, sp = leaf_fp - 0x40, fp = leaf_fp, inner = true}, {pc = ret_middle, sp = leaf_fp + 0x10, fp = middle_fp}}
	fns := [2]^debug.Func{leaf, middle}
	for &f, i in frames {
		v, ok := debug.local_named(&ix, fns[i], debug.frame_lookup_pc(&f), "n")
		testing.expect(t, ok, "n is a variable of leaf and of middle")
		found, lok := debug.location(&ix, &probe, &f, fns[i], v)
		testing.expect(t, lok, "n has a location")
		addr, in_mem := found.(debug.Mem)
		testing.expect(t, in_mem, "n is in memory (optnone)")
		put(p, u64(addr), i32(n))
	}
}

// --- The fake file server ---

Kind :: enum u8 {
	Dir,
	Text, // text, as it is
	Image, // the fixture
	Ctl, // writes are logged
	Events, // each read, the next event
	Regs, // the live process's registers
	Mem, // the live process's memory, at the offset
	Crash_Regs, // the crashed process's
	Crash_Mem, // the crashed process's memory from base
}

Fnode :: struct {
	parent: p9.Node,
	name:   string,
	kind:   Kind,
	text:   string,
	base:   u64,
}

nodes: [dynamic]Fnode

// The session being played: its events, in order, each with the process
// as it stands there; and what procfs knows once the process has gone.
Stop :: struct {
	record: string,
	p:      Proc,
}

stops: [dynamic]Stop
next_stop: int
live: Proc
crashed: Proc
ctl_log: [dynamic; 4096]u8

node_named :: proc(path: string) -> p9.Node {
	at := p9.Node(1)
	rest := path[1:]
	for name in strings.split_iterator(&rest, "/") {
		found := p9.Node(0)
		for n, i in nodes {
			if i > 1 && n.parent == at && n.name == name {
				found = p9.Node(i)
			}
		}
		if found == 0 {
			append(&nodes, Fnode{parent = at, name = strings.clone(name), kind = .Dir})
			found = p9.Node(len(nodes) - 1)
		}
		at = found
	}
	return at
}

add :: proc(path: string, kind: Kind, text := "", base := u64(0)) {
	n := node_named(path)
	nodes[n].kind, nodes[n].text, nodes[n].base = kind, text, base
}

f_attach :: proc "contextless" (ctx: rawptr, aname: string) -> (root: p9.Node, st: vx.Status) {
	return 1, .Ok
}

f_walk :: proc "contextless" (ctx: rawptr, dir: p9.Node, name: string) -> (child: p9.Node, st: vx.Status) {
	for n, i in nodes {
		if i > 1 && n.parent == dir && n.name == name {
			return p9.Node(i), .Ok
		}
	}
	return 0, .Err_Not_Found
}

f_parent :: proc "contextless" (ctx: rawptr, node: p9.Node) -> (parent: p9.Node, st: vx.Status) {
	return nodes[node].parent != 0 ? nodes[node].parent : 1, .Ok
}

f_stat :: proc "contextless" (ctx: rawptr, node: p9.Node, out: ^p9.Stat) -> vx.Status {
	n := &nodes[node]
	length: u64
	#partial switch n.kind {
	case .Image:
		length = u64(len(fixture))
	case .Crash_Mem:
		length = n.base == STACK_BASE ? STACK_SIZE : data_size
	}
	dir := n.kind == .Dir
	out^ = {
		qid = {dir ? p9.QTDIR : p9.QTFILE, 0, u64(node)},
		mode = dir ? p9.DMDIR | 0o555 : 0o666,
		length = length,
		name = n.name,
	}
	return .Ok
}

f_open :: proc "contextless" (ctx: rawptr, node: p9.Node, mode: p9.Open_Mode) -> vx.Status {
	return mode.access == .Read || nodes[node].kind == .Ctl ? .Ok : .Err_Access
}

from :: proc "contextless" (data: []u8, offset: u64, buf: []u8) -> u32 {
	if offset >= u64(len(data)) {
		return 0
	}
	return u32(copy(buf, data[offset:]))
}

f_read :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, buf: []u8) -> (count: u32, st: vx.Status) {
	n := &nodes[node]
	#partial switch n.kind {
	case .Text:
		return from(transmute([]u8)n.text, offset, buf), .Ok
	case .Image:
		return from(fixture, offset, buf), .Ok
	case .Events:
		if next_stop >= len(stops) {
			return 0, .Err_Not_Found // the process has gone
		}
		s := &stops[next_stop]
		next_stop += 1
		live = s.p
		return from(transmute([]u8)s.record, 0, buf), .Ok
	case .Regs:
		return from(memory.ptr_to_bytes(&live.regs), offset, buf), .Ok
	case .Crash_Regs:
		return from(memory.ptr_to_bytes(&crashed.regs), offset, buf), .Ok
	case .Mem:
		if !proc_read(&live, offset, buf) {
			return 0, .Err_Access
		}
		return u32(len(buf)), .Ok
	case .Crash_Mem:
		size := n.base == STACK_BASE ? u64(STACK_SIZE) : data_size
		if offset >= size {
			return 0, .Ok
		}
		got := buf[:min(u64(len(buf)), size - offset)]
		if !proc_read(&crashed, n.base + offset, got) {
			return 0, .Err_Access
		}
		return u32(len(got)), .Ok
	}
	return 0, .Err_Invalid
}

f_readdir :: proc "contextless" (ctx: rawptr, dir: p9.Node, index: u32) -> (child: p9.Node, st: vx.Status) {
	left := index
	for n, i in nodes {
		if i > 1 && n.parent == dir {
			if left == 0 {
				return p9.Node(i), .Ok
			}
			left -= 1
		}
	}
	return 0, .Err_Not_Found
}

f_write :: proc "contextless" (ctx: rawptr, node: p9.Node, offset: u64, data: []u8) -> (count: u32, st: vx.Status) {
	if nodes[node].kind != .Ctl {
		return 0, .Err_Access
	}
	_ = append(&ctl_log, nodes[node].text, string(data), "\n")
	return u32(len(data)), .Ok
}

server: p9.Server
client: p9.Client
bufs: [2][8192]u8

// An ndb record, as procfs writes one.
record :: proc(pairs: ..string) -> string {
	buf := make([]u8, 512)
	w := ndb.Writer {
		buf = buf,
	}
	for i := 0; i < len(pairs); i += 2 {
		ndb.put(&w, pairs[i], pairs[i + 1])
	}
	_ = ndb.end(&w)
	return strings.clone(ndb.written(&w))
}

hex :: proc(v: u64) -> string {
	return fmt.aprintf("%#x", v)
}

// A fresh session: the files, and dbg's namespace with them at /. The
// events are the caller's to add; `wait` is dbg's wait record for when the
// process has gone.
setup :: proc(t: ^testing.T, wait: string, script: string) {
	clear(&nodes)
	append(&nodes, Fnode{}, Fnode{kind = .Dir}) // 0 is no node, 1 the root
	clear(&stops)
	next_stop = 0
	clear(&ctl_log)
	clear(&output)

	images := record("name", "dbgdemo", "base", hex(0x200000), "build-id", "00112233")
	add("/boot/bin/dbgdemo", .Image)
	add("/boot/tests/dbgdemo.cmds", .Text, script)
	add("/boot/tests/empty", .Text, "")
	pid := fmt.aprintf("/proc/%d", PID)
	add(fmt.aprintf("%s/images", pid), .Text, images)
	add(fmt.aprintf("%s/maps", pid), .Text, "base=0x200000 size=0x1000 prot=r-- offset=0x0\n")
	add(fmt.aprintf("%s/ctl", pid), .Ctl)
	add(fmt.aprintf("%s/events", pid), .Events)
	add(fmt.aprintf("%s/mem", pid), .Mem)
	add(fmt.aprintf("%s/threads/1/regs", pid), .Regs)
	add(fmt.aprintf("%s/threads/1/regs.ndb", pid), .Text, "pc=0x20291c sp=0x7fffffffec00\n")
	add(fmt.aprintf("%s/threads/1/ctl", pid), .Ctl, "threads/1: ")
	add(fmt.aprintf("/proc/%d/wait", ME), .Text, wait)
	crash := fmt.aprintf("/tmp/crash/dbgdemo.%d", PID)
	add(fmt.aprintf("%s/images", crash), .Text, images)
	add(fmt.aprintf("%s/maps", crash), .Text, "base=0x208000 size=0x1000 prot=rw- offset=0x0\n")
	add(fmt.aprintf("%s/note", crash), .Text, "sys: trap: fault read addr=0x10")
	add(fmt.aprintf("%s/threads/1/regs", crash), .Crash_Regs)
	add(fmt.aprintf("%s/mem/%s", crash, hex(data_base)), .Crash_Mem, base = data_base)
	add(fmt.aprintf("%s/mem/%s", crash, hex(STACK_BASE)), .Crash_Mem, base = STACK_BASE)

	server = {
		fs = {
			attach = f_attach,
			walk = f_walk,
			parent = f_parent,
			stat = f_stat,
			open = f_open,
			read = f_read,
			readdir = f_readdir,
			write = f_write,
		},
		max_msize = 8192,
	}
	client = {
		rpc  = p9test.loopback,
		ctx  = &server,
		tbuf = bufs[0][:],
		rbuf = bufs[1][:],
	}
	testing.expect_value(t, p9.client_version(&client, 8192, {}), vx.Status.Ok)
	dbg.space = {}
	dbg.me = ME
	testing.expect_value(t, ns.mount(&dbg.space, &client, vx.HANDLE_NONE, "/srv/fake", "", "/", {}), vx.Status.Ok)
	rt.print_hook = capture
}

event :: proc(t: ^testing.T, kind: string, n: int, pc: u64, faulted := false) {
	s := Stop{}
	snapshot(t, &s.p, n, pc, faulted)
	if kind == "fault" {
		s.record = record("event", kind, "thread", "1", "pc", hex(pc), "addr", "0x10", "access", "read")
	} else {
		s.record = record("event", kind, "thread", "1", "pc", hex(pc))
	}
	append(&stops, s)
}

expect_lines :: proc(t: ^testing.T, got: string, want: []string, loc := #caller_location) {
	g := strings.split_lines(strings.trim_suffix(got, "\n"))
	for i in 0 ..< max(len(g), len(want)) {
		gl := i < len(g) ? g[i] : "(none)"
		wl := i < len(want) ? want[i] : "(none)"
		if !testing.expectf(t, gl == wl, "line %d: got %q, want %q", i + 1, gl, wl, loc = loc) {
			return
		}
	}
}

SCENARIO :: #load("../../qemu/m4/dbg.ndb", string)

// What tests/qemu/m4/dbg.ndb expects of dbg, matched against its output as
// ./build test matches the console: expect= somewhere in a line, line= a
// whole line, each after the one before; and no line with a fail= pattern.
// Lines other programs print (procfs's, svcd's) are left out.
expect_scenario :: proc(t: ^testing.T, got: string) {
	lines := strings.split_lines(got)
	next := 0
	rest := SCENARIO
	for rec in strings.split_lines_iterator(&rest) {
		whole := strings.has_prefix(rec, "line=\"")
		if !whole && !strings.has_prefix(rec, "expect=\"") && !strings.has_prefix(rec, "fail=\"") {
			continue
		}
		text := strings.trim_suffix(rec[strings.index_byte(rec, '"') + 1:], "\"")
		if strings.has_prefix(rec, "fail=") {
			for l in lines {
				testing.expectf(t, !strings.contains(l, text), "dbg.ndb: %q fails the scenario: %q", text, l)
			}
			continue
		}
		if strings.has_prefix(text, "procfs: ") || strings.has_prefix(text, "svcd: ") {
			continue
		}
		for next < len(lines) && !(whole ? lines[next] == text : strings.contains(lines[next], text)) {
			next += 1
		}
		if !testing.expectf(t, next < len(lines), "dbg.ndb: %q is not in dbg's output, in order", text) {
			return
		}
		next += 1
	}
}

at_line :: proc(fn: string, file: string, line: int) -> string {
	return fmt.aprintf("%s (%s:%d)", fn, file, line)
}

DEMO :: "tests/user/dbgdemo.c"
SHIM :: "tests/user/../../lib/vx-rt/rt.c" // the path dbgdemo.c includes it by

@(test)
test_dbg :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // everything here lives as long as the test
	open_fixture(t)
	body := leaf.body
	header := fmt.aprintf("dbg: /boot/bin/dbgdemo: %d functions, %d lines", len(ix.funcs), len(ix.lines))
	stack_at :: proc(pc0: u64, line0: int, star: int) -> []string {
		rows := []struct {
			pc:   u64,
			fn:   string,
			file: string,
			line: int,
		}{{pc0, "leaf", DEMO, line0}, {ret_middle, "middle", DEMO, LINE_MIDDLE_CALL}, {ret_vx_main, "vx_main", DEMO, LINE_VX_MAIN_CALL}, {ret_main, "main", SHIM, LINE_MAIN_CALL}}
		out := make([]string, len(rows))
		for r, i in rows {
			out[i] = fmt.aprintf("%s%d %s in %s", i == star ? "*#" : " #", i, hex(r.pc), at_line(r.fn, r.file, r.line))
		}
		return out
	}
	label := fmt.aprintf("%s \"demo\"", hex(label_addr))

	// 1. What m4/dbg does (tests/user/dbgdemo.cmds), attached rather than
	// launched: a breakpoint in leaf, its stack and variables, the fault on
	// the third call, and the crash directory procfs saved.
	wait := record("pid", "12", "name", "dbgdemo", "noteid", "12", "status", "sys: trap: fault read addr=0x10", "real", "5")
	script := strings.join({"break leaf", "bt", "print n", "cont", "bt", "print n", "print tally", "print tally.label", "cont", "cont", "print tally.calls", "frame 1", "print n * 10", "cont", "bt", "cont", "bt", "print tally.calls", "print tally.total", "run", "cont", "quit", ""}, "\n")
	setup(t, wait, script)
	event(t, "break", 1, body)
	event(t, "break", 2, body)
	event(t, "break", 3, body)
	event(t, "fault", 3, fault_pc, faulted = true)
	snapshot(t, &crashed, 3, fault_pc, faulted = true)
	testing.expect_value(t, dbg.session({"-c", "-x", "/boot/tests/dbgdemo.cmds", "-p", "12"}), "")
	want: [dynamic]string
	append(&want, header, "(dbg) break leaf", fmt.aprintf("dbg: breakpoint at %s in %s", hex(body), at_line("leaf", DEMO, LINE_LEAF_BODY)))
	append(&want, "(dbg) bt", "dbg: no stack", "(dbg) print n", "dbg: not stopped")
	append(&want, "(dbg) cont", fmt.aprintf("dbg: stopped: break at %s", at_line("leaf", DEMO, LINE_LEAF_BODY)))
	append(&want, "(dbg) bt")
	append(&want, ..stack_at(body, LINE_LEAF_BODY, 0))
	append(&want, "(dbg) print n", "= 1")
	append(&want, "(dbg) print tally", fmt.aprintf("= {{calls = 0, total = 0, label = %s}}", label))
	append(&want, "(dbg) print tally.label", fmt.aprintf("= %s", label))
	append(&want, "(dbg) cont", fmt.aprintf("dbg: stopped: break at %s", at_line("leaf", DEMO, LINE_LEAF_BODY)))
	append(&want, "(dbg) cont", fmt.aprintf("dbg: stopped: break at %s", at_line("leaf", DEMO, LINE_LEAF_BODY)))
	append(&want, "(dbg) print tally.calls", "= 2")
	append(&want, "(dbg) frame 1", fmt.aprintf(" #1 in %s", at_line("middle", DEMO, LINE_MIDDLE_CALL)))
	append(&want, "(dbg) print n * 10", "= 30")
	append(&want, "(dbg) cont", fmt.aprintf("dbg: stopped: fault addr=0x10 at %s", at_line("leaf", DEMO, LINE_FAULT)))
	append(&want, "(dbg) bt")
	append(&want, ..stack_at(fault_pc, LINE_FAULT, 0))
	append(&want, "(dbg) cont", "dbg: dbgdemo exited: sys: trap: fault read addr=0x10", "dbg: crash directory /tmp/crash/dbgdemo.12")
	append(&want, "(dbg) bt")
	append(&want, ..stack_at(fault_pc, LINE_FAULT, 0))
	append(&want, "(dbg) print tally.calls", "= 3", "(dbg) print tally.total", "= 6")
	append(&want, "(dbg) run", "dbg: not a program to launch", "(dbg) cont", "dbg: not running", "(dbg) quit")
	expect_lines(t, string(output[:]), want[:])
	expect_scenario(t, string(output[:]))
	// procfs saw the breakpoint, five starts, and nothing at the end: the
	// process had gone.
	testing.expect_value(t, string(ctl_log[:]), fmt.aprintf("break %s\nstart\nstart\nstart\nstart\nstart\n", hex(body)))

	// 2. The crash directory opened directly (05 §5): the program found by
	// its images, the stack and globals from the directory's mem files and
	// the image, and live-only commands refused.
	script = "bt\nframe 1\nprint n\nprint tally\nframe 4\nstep\nkill\ninfo\n"
	setup(t, wait, script)
	snapshot(t, &crashed, 3, fault_pc, faulted = true)
	testing.expect_value(t, dbg.session({"-c", "-x", "/boot/tests/dbgdemo.cmds", "/tmp/crash/dbgdemo.12"}), "")
	clear(&want)
	append(&want, header, "(dbg) bt")
	append(&want, ..stack_at(fault_pc, LINE_FAULT, 0))
	append(&want, "(dbg) frame 1", fmt.aprintf(" #1 in %s", at_line("middle", DEMO, LINE_MIDDLE_CALL)))
	append(&want, "(dbg) print n", "= 3")
	append(&want, "(dbg) print tally", fmt.aprintf("= {{calls = 3, total = 6, label = %s}}", label))
	append(&want, "(dbg) frame 4", "dbg: no such frame", "(dbg) step", "dbg: not running", "(dbg) kill")
	append(&want, "(dbg) info", "name=dbgdemo base=0x200000 build-id=00112233", "base=0x208000 size=0x1000 prot=rw- offset=0x0")
	expect_lines(t, string(output[:]), want[:])
	testing.expect_value(t, string(ctl_log[:]), "")

	// 3. A live process, stepped, its registers shown, then killed: an exit
	// that is not a crash leaves no crash directory to turn to.
	wait = record("pid", "12", "name", "dbgdemo", "noteid", "12", "status", "killed", "real", "5")
	script = "cont\nstep\nregs\nbt\n  print   n  \nkill\nbt\nprint n\n"
	setup(t, wait, script)
	event(t, "break", 1, body)
	when ODIN_ARCH == .amd64 {
		step_pc := body + 1
	} else {
		step_pc := body + 4
	}
	event(t, "step", 1, step_pc)
	testing.expect_value(t, dbg.session({"-c", "-x", "/boot/tests/dbgdemo.cmds", "-p", "12"}), "")
	clear(&want)
	append(&want, header, "(dbg) cont", fmt.aprintf("dbg: stopped: break at %s", at_line("leaf", DEMO, LINE_LEAF_BODY)))
	append(&want, "(dbg) step", fmt.aprintf("dbg: stopped: step at %s", at_line("leaf", DEMO, LINE_LEAF_BODY)))
	append(&want, "(dbg) regs", "pc=0x20291c sp=0x7fffffffec00")
	append(&want, "(dbg) bt")
	append(&want, ..stack_at(step_pc, LINE_LEAF_BODY, 0))
	append(&want, "(dbg)   print   n  ", "= 1")
	append(&want, "(dbg) kill", "dbg: dbgdemo exited: killed")
	append(&want, "(dbg) bt", "dbg: no stack", "(dbg) print n", "dbg: not stopped")
	expect_lines(t, string(output[:]), want[:])
	testing.expect_value(t, string(ctl_log[:]), "start\nthreads/1: step\nkill\n")

	// 4. Attached, and left at once: dbg detaches from what it did not
	// launch.
	setup(t, wait, "quit\nbt\n")
	testing.expect_value(t, dbg.session({"-c", "-x", "/boot/tests/dbgdemo.cmds", "-p", "12"}), "")
	expect_lines(t, string(output[:]), {header, "(dbg) quit"})
	testing.expect_value(t, string(ctl_log[:]), "detach\n")

	// 5. A program to launch, with commands before `run`: breakpoints by
	// function, file:line and address are kept; the rest is refused or
	// explained, comments and blank lines are echoed and skipped.
	script_b := strings.builder_make()
	strings.write_string(&script_b, "break leaf\nbreak dbgdemo.c:28\nbreak 0x10\nbreak nosuch\nbreak nosuch.c:1\nbreak\n")
	strings.write_string(&script_b, "cont\nstep\nbt\nframe 0\nprint n\nkill\nfrobnicate\n# a comment\n\nwhere\np n\n")
	for _ in 0 ..< 30 {
		strings.write_string(&script_b, "break leaf\n")
	}
	strings.write_string(&script_b, "quit\nbt")
	setup(t, wait, strings.to_string(script_b))
	testing.expect_value(t, dbg.session({"-c", "-x", "/boot/tests/dbgdemo.cmds", "/boot/bin/dbgdemo", "crash"}), "")
	line28, _ := debug.line_addr(&ix, "dbgdemo.c", 28)
	clear(&want)
	append(&want, header, "(dbg) break leaf", fmt.aprintf("dbg: breakpoint at %s in %s", hex(body), at_line("leaf", DEMO, LINE_LEAF_BODY)))
	append(&want, "(dbg) break dbgdemo.c:28", fmt.aprintf("dbg: breakpoint at %s in %s", hex(line28), at_line("middle", DEMO, 28)))
	append(&want, "(dbg) break 0x10", "dbg: breakpoint at 0x10 in ??")
	append(&want, "(dbg) break nosuch", "dbg: no such function or line")
	append(&want, "(dbg) break nosuch.c:1", "dbg: no such function or line")
	append(&want, "(dbg) break", "dbg: no such function or line")
	append(&want, "(dbg) cont", "dbg: not running", "(dbg) step", "dbg: not running", "(dbg) bt", "dbg: no stack")
	append(&want, "(dbg) frame 0", "dbg: no such frame", "(dbg) print n", "dbg: not stopped", "(dbg) kill")
	append(&want, "(dbg) frobnicate", "dbg: break, run, cont, step, bt, frame, print, regs, info, kill, quit")
	append(&want, "(dbg) # a comment", "(dbg) ", "(dbg) where", "dbg: no stack", "(dbg) p n", "dbg: not stopped")
	for i in 0 ..< 30 {
		append(&want, "(dbg) break leaf")
		// 3 kept so far: 29 more fit.
		if i < 29 {
			append(&want, fmt.aprintf("dbg: breakpoint at %s in %s", hex(body), at_line("leaf", DEMO, LINE_LEAF_BODY)))
		} else {
			append(&want, "dbg: too many breakpoints before run")
		}
	}
	append(&want, "(dbg) quit")
	expect_lines(t, string(output[:]), want[:])
	testing.expect_value(t, string(ctl_log[:]), "")

	// 6. What ends a session before its commands.
	Case :: struct {
		args:      []string,
		exit:      string,
		said:      string,
	}
	// dbg(1)'s usage fence, as upstream's M6 step 6b gives it to dbg.
	USAGE :: "usage: dbg [-c] [-x file] program [arg ...]\n       dbg [-c] [-x file] -p pid\n       dbg [-c] [-x file] crashdir\n"
	cases := []Case {
		// No program.
		{{}, "usage", USAGE},
		{{"-c", "-x", "/boot/tests/empty"}, "usage", USAGE},
		// Nothing there to index.
		{{"-c", "/boot/bin/nothing"}, "no symbols", "dbg: cannot read the program's symbols\n"},
		{{"-c", "/boot/tests/empty"}, "no symbols", "dbg: cannot read the program's symbols\n"},
		{{"-c", "-p", "99"}, "no symbols", "dbg: cannot read the program's symbols\n"},
		{{"-c", "/tmp/crash/other.3"}, "no symbols", "dbg: cannot read the program's symbols\n"},
		// Paths that do not fit.
		{{"-c", strings.concatenate({"/tmp/crash/", strings.repeat("x", 85)})}, "path too long", ""},
		{{"-c", strings.concatenate({"/boot/bin/", strings.repeat("x", 118)})}, "path too long", ""},
		// A script that is not there, once the program is indexed.
		{{"-c", "-x", "/boot/tests/none", "/boot/bin/dbgdemo"}, "cannot read the script", fmt.aprintf("%s\n", header)},
		// An empty one: nothing to do.
		{{"-c", "-x", "/boot/tests/empty", "/boot/bin/dbgdemo"}, "", fmt.aprintf("%s\n", header)},
	}
	for c in cases {
		setup(t, wait, "")
		testing.expectf(t, dbg.session(c.args) == c.exit, "%v: exit string", c.args)
		testing.expectf(t, string(output[:]) == c.said, "%v: said %q, want %q", c.args, string(output[:]), c.said)
	}
}
