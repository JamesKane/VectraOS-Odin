// What a debugger asks of a stopped program reads it only through a Target:
// a live process's /proc files, or a crash directory. The call stack comes
// from the frame-pointer chain, since frame pointers are always on (upstream
// 05 §4), in Odin's code as in C's (docs/PLAN.md §3: llc --frame-pointer=all).
package debug

Target :: struct {
	data:    rawptr,
	machine: Machine,
	// len(buf) bytes at addr in the program; false if they cannot be read.
	read:    proc "contextless" (data: rawptr, addr: u64, buf: []u8) -> bool,
	// The innermost frame's register `dwarf` (DWARF's numbering); false if
	// unknown. May be nil: no register is known.
	reg:     proc "contextless" (data: rawptr, dwarf: u32) -> (value: u64, ok: bool),
}

Frame :: struct {
	pc, sp, fp: u64,
	inner:      bool, // the innermost: every register is known, not only these
}

// DWARF's numbers for the frame pointer, stack pointer and link register.
@(private)
fp_reg :: proc "contextless" (t: ^Target) -> u32 {
	return t.machine == .AArch64 ? 29 : 6
}
@(private)
sp_reg :: proc "contextless" (t: ^Target) -> u32 {
	return t.machine == .AArch64 ? 31 : 7
}
@(private = "file")
AARCH64_LR :: 30

// Not a DWARF register: the pc.
REG_PC :: 0xffff

@(private)
target_reg :: proc "contextless" (t: ^Target, reg: u32) -> (u64, bool) {
	if t.reg == nil {
		return 0, false
	}
	return t.reg(t.data, reg)
}

@(private)
read_u64 :: proc "contextless" (t: ^Target, addr: u64) -> (v: u64, ok: bool) {
	buf: [8]u8
	if !t.read(t.data, addr, buf[:]) {
		return 0, false
	}
	return u64(transmute(u64le)buf), true
}

// A register's value at a frame: the pc, fp and sp at any; the others only
// at the innermost.
@(private)
frame_reg :: proc "contextless" (t: ^Target, f: ^Frame, reg: u32) -> (u64, bool) {
	switch reg {
	case REG_PC:
		return f.pc, true
	case fp_reg(t):
		return f.fp, true
	case sp_reg(t):
		return f.sp, true
	}
	if !f.inner {
		return 0, false
	}
	return target_reg(t, reg)
}

// The frames from the innermost (pc, sp and fp as it stopped) outwards, into
// frames: at most len(frames). A frame record is the caller's fp, then the
// return address, on both machines, in C and in Odin. A pc still in its
// function's prologue has not made its record yet: its caller's is found from
// sp (x86_64) or the link register (aarch64). The walk stops where the chain
// does not go up the stack, or cannot be read.
//
// The prologue is the code before the function's body (its first
// prologue_end row): the record is assumed made there. llc's shrink-wrapping,
// on at -O1, can move it past the body, into the paths that need it; a pc
// before it then names the caller's record as the function's own, and the
// caller is missed. Code built with llc --enable-shrink-wrap=false always
// makes it at its first instructions.
unwind :: proc "contextless" (ix: ^Index, t: ^Target, pc, sp, fp_in: u64, frames: []Frame) -> []Frame {
	if len(frames) == 0 {
		return frames[:0]
	}
	n := 0
	frames[n] = Frame {
		pc    = pc,
		sp    = sp,
		fp    = fp_in,
		inner = true,
	}
	n += 1
	fp := fp_in
	if f, ok := func_at(ix, pc); ok && pc < f.body && n < len(frames) {
		// In the prologue: its frame record is not there yet.
		ret, caller_fp, caller_sp: u64 = 0, fp, sp
		found: bool
		if t.machine == .AArch64 {
			ret, found = target_reg(t, AARCH64_LR) // sp as the caller left it at low
		} else if pc == f.low {
			ret, found = read_u64(t, sp) // before push %rbp
			caller_sp = sp + 8 // the caller's, before its call pushed the return address
		} else {
			ret, found = read_u64(t, sp + 8) // after it, before mov %rsp, %rbp
			if found {
				caller_fp, found = read_u64(t, sp)
			}
			caller_sp = sp + 16
		}
		if !found || ret == 0 {
			return frames[:n]
		}
		frames[n] = Frame {
			pc = ret,
			sp = caller_sp,
			fp = caller_fp,
		}
		n += 1
		fp = caller_fp
	}
	for n < len(frames) && fp != 0 && fp & 7 == 0 {
		next_fp, ok1 := read_u64(t, fp)
		if !ok1 {
			break
		}
		ret, ok2 := read_u64(t, fp + 8)
		if !ok2 || ret == 0 {
			break
		}
		frames[n] = Frame {
			pc = ret,
			sp = fp + 16,
			fp = next_fp,
		}
		n += 1
		if next_fp <= fp {
			break // the chain must go up the stack
		}
		fp = next_fp
	}
	return frames[:n]
}

// The pc to look a frame's function and line up by: a return address is the
// instruction after the call, which may be the next function's or line's.
frame_lookup_pc :: proc "contextless" (f: ^Frame) -> u64 {
	return f.inner ? f.pc : f.pc - 1
}
