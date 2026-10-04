package vx

// Notes and exit strings in Plan 9's words (ADR-0010). The kernel, which
// ends a task on a fault no one handles, and vx:rt, which hands a fault to a
// program's note handler, both word a trap this way, and what they write is
// part of the interface: a parent reads it as the exit string.

// The note for a trap, as Plan 9 words it: "sys: trap: fault read addr=0x0
// pc=0x401000", "sys: trap: illegal instruction pc=0x401000", "sys:
// breakpoint pc=...". Written into out, which it returns cut to its length:
// never more than ERRMAX bytes, all ASCII.
trap_note :: proc "contextless" (kind: Exception_Kind, code: u32, address, pc: u64, out: ^[ERRMAX]u8) -> string {
	b := Note_Buf{out = out}
	has_address := false
	#partial switch kind {
	case .Page_Fault:
		note_put(&b, "sys: trap: fault ")
		note_put(&b, code == 1 ? "write" : code == 2 ? "exec" : "read")
		has_address = true
	case .Illegal:
		note_put(&b, "sys: trap: illegal instruction")
	case .Breakpoint:
		note_put(&b, "sys: breakpoint")
	case .Arithmetic:
		note_put(&b, "sys: trap: arithmetic")
	case .Alignment:
		note_put(&b, "sys: trap: misaligned")
		has_address = true
	case .Fp_Disabled:
		note_put(&b, "sys: trap: fp disabled")
	case .Step:
		note_put(&b, "sys: trap: step")
	case .Pager_Timeout: // its pager did not supply the page in time
		note_put(&b, "sys: trap: page not supplied")
		has_address = true
	case:
		note_put(&b, "sys: trap: general fault")
	}
	if has_address {
		note_put(&b, " addr=")
		note_hex(&b, address)
	}
	note_put(&b, " pc=")
	note_hex(&b, pc)
	return string(out[:b.len])
}

// A note under construction, cut off at ERRMAX. What trap_note writes is
// ASCII, so a cut never splits a rune.
@(private="file")
Note_Buf :: struct {
	out: ^[ERRMAX]u8,
	len: int,
}

@(private="file")
note_put :: proc "contextless" (b: ^Note_Buf, s: string) {
	b.len += copy(b.out[b.len:], s)
}

// "0x" and the value in lower-case hex, without leading zeros.
@(private="file")
note_hex :: proc "contextless" (b: ^Note_Buf, v: u64) {
	hex := "0123456789abcdef"
	digits: [18]u8
	digits[0], digits[1] = '0', 'x'
	n := 2
	for shift := 60; shift >= 0; shift -= 4 {
		if v >> uint(shift) != 0 || shift == 0 || n > 2 {
			digits[n] = hex[(v >> uint(shift)) & 15]
			n += 1
		}
	}
	note_put(b, string(digits[:n]))
}
