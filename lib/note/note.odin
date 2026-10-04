// vx:note, notes and exit strings in Plan 9's words (upstream ADR-0010). The
// kernel, which ends a task on a fault no one handled, vx:rt, which hands a
// fault to a program's note handler, procfs and ptyd all use it. It imports
// only vx:utf, so the kernel can too.
package note

import "vx:utf"

// The longest exit string or note, in bytes: Plan 9's ERRMAX (ADR-0010).
// abi/vx gains it with the kernel's M4 port; this is the same number.
ERRMAX :: 128

// The kinds of exception a trap note names, numbered as the kernel's
// exception record numbers them (upstream's abi.h; abi/vx gains them with the
// kernel's M4 port).
Trap :: enum u32 {
	Page_Fault  = 1, // code: read 0, write 1, execute 2
	Illegal, // an undefined or privileged instruction
	Breakpoint, // int3, brk
	Arithmetic, // division by zero, an FP exception
	Alignment,
	Fp_Disabled, // FP/SIMD while the kernel does not save it
	General, // any other fault (x86 #GP, say)
	Interrupt, // thread_interrupt
	Step, // one instruction done
	Watchpoint, // a watched address touched
}

// A string under construction in a caller's buffer, cut off at its capacity
// at a rune boundary (ADR-0013). Once something has been cut, nothing put
// after it is kept: a note never has a hole in the middle.
Buf :: struct {
	buf:  []u8,
	len:  int,
	full: bool,
}

put :: proc "contextless" (b: ^Buf, s: string) {
	if b.full {
		return
	}
	n := utf.cut(s, len(b.buf) - b.len)
	copy(b.buf[b.len:], s[:n])
	b.len += n
	if n < len(s) {
		b.full = true
	}
}

// v as 0x and lower-case hex digits, without leading zeroes.
put_hex :: proc "contextless" (b: ^Buf, v: u64) {
	HEX := "0123456789abcdef"
	digits: [18]u8 = {0 = '0', 1 = 'x'}
	n := 2
	for shift := 60; shift >= 0; shift -= 4 {
		if v >> uint(shift) != 0 || shift == 0 || n > 2 {
			digits[n] = HEX[v >> uint(shift) & 15]
			n += 1
		}
	}
	put(b, string(digits[:n]))
}

put_dec :: proc "contextless" (b: ^Buf, v: u64) {
	digits: [20]u8
	n := len(digits)
	x := v
	for {
		n -= 1
		digits[n] = u8('0' + x % 10)
		x /= 10
		if x == 0 {
			break
		}
	}
	put(b, string(digits[n:]))
}

to_string :: proc "contextless" (b: ^Buf) -> string {
	return string(b.buf[:b.len])
}

// The note for a trap, as Plan 9 words it: "sys: trap: fault read addr=0x0
// pc=0x401000", "sys: trap: illegal instruction pc=0x401000", "sys:
// breakpoint pc=…". The note is written into out; a kind the kernel does not
// name is a general fault.
trap_note :: proc "contextless" (kind: Trap, code: u32, address, pc: u64, out: ^[ERRMAX]u8) -> string {
	b := Buf {
		buf = out[:],
	}
	has_address := false
	#partial switch kind {
	case .Page_Fault:
		put(&b, "sys: trap: fault ")
		put(&b, code == 1 ? "write" : code == 2 ? "exec" : "read")
		has_address = true
	case .Illegal:
		put(&b, "sys: trap: illegal instruction")
	case .Breakpoint:
		put(&b, "sys: breakpoint")
	case .Arithmetic:
		put(&b, "sys: trap: arithmetic")
	case .Alignment:
		put(&b, "sys: trap: misaligned")
		has_address = true
	case .Fp_Disabled:
		put(&b, "sys: trap: fp disabled")
	case .Step:
		put(&b, "sys: trap: step")
	case:
		put(&b, "sys: trap: general fault")
	}
	if has_address {
		put(&b, " addr=")
		put_hex(&b, address)
	}
	put(&b, " pc=")
	put_hex(&b, pc)
	return to_string(&b)
}
