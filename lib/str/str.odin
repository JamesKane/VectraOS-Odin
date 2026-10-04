// vx:str, the string and number helpers every package would otherwise write
// for itself, and Buf, the bounded writer the text and wire encoders share.
// core:strings and core:strconv take a context and allocate, which nothing
// that ships may do; these do neither.
//
// The names and semantics follow core:strings where it has the same
// procedure (index_byte gives -1 when absent; split_iterator does not
// return an empty last field), so code reads as it would on the host.
//
// Imports nothing beyond the language, so the kernel, user space and host
// tools share it.
package str

import "base:intrinsics"

// --- Searching ---

// The index of the first c in s, or -1.
index_byte :: proc "contextless" (s: string, c: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == c {
			return i
		}
	}
	return -1
}

// The index of the last c in s, or -1.
last_index_byte :: proc "contextless" (s: string, c: u8) -> int {
	#reverse for b, i in transmute([]u8)s {
		if b == c {
			return i
		}
	}
	return -1
}

// The index of the first sub in s, or -1. An empty sub is at 0.
index :: proc "contextless" (s, sub: string) -> int {
	for i in 0 ..= len(s) - len(sub) {
		if s[i:][:len(sub)] == sub {
			return i
		}
	}
	return -1
}

contains :: proc "contextless" (s, sub: string) -> bool {
	return index(s, sub) >= 0
}

has_prefix :: proc "contextless" (s, prefix: string) -> bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

has_suffix :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

// The fields of s^ between seps, one per call, consuming s^ as it goes:
//
//	rest := path
//	for name in str.split_iterator(&rest, '/') { ... }
//
// Empty fields between two seps, or before the first, are returned; an empty
// last field (s^ ending in sep, or empty) is not, as in core:strings.
split_iterator :: proc "contextless" (s: ^string, sep: u8) -> (field: string, ok: bool) {
	m := index_byte(s^, sep)
	if m < 0 {
		field = s^
		s^ = s[len(s^):]
		return field, field != ""
	}
	field = s[:m]
	s^ = s[m + 1:]
	return field, true
}

// The bytes of b up to its first NUL, or all of them: a fixed-size name
// field, NUL-padded.
from_nul_padded :: proc "contextless" (b: []u8) -> string {
	s := string(b)
	if n := index_byte(s, 0); n >= 0 {
		return s[:n]
	}
	return s
}

// The parts, one after another, at the start of buf; ok is false (and the
// string empty) if they do not fit.
join :: proc "contextless" (buf: []u8, parts: ..string) -> (s: string, ok: bool) {
	b := Buf{buf = buf}
	for p in parts {
		write_string(&b, p)
	}
	if b.failed {
		return "", false
	}
	return to_string(&b), true
}

// --- Numbers ---

U64_DIGITS :: 20 // the most format_u64 writes
I64_DIGITS :: 21 // and format_i64, with its sign

// v in decimal at the start of buf; "" if buf is too short.
format_u64 :: proc "contextless" (buf: []u8, v: u64) -> string {
	digits: [U64_DIGITS]u8
	i := len(digits)
	n := v
	for {
		i -= 1
		digits[i] = u8('0' + n % 10)
		n /= 10
		if n == 0 {
			break
		}
	}
	if len(digits) - i > len(buf) {
		return ""
	}
	return string(buf[:copy(buf, digits[i:])])
}

// v in decimal, with a '-' if it is negative, at the start of buf; "" if buf
// is too short.
format_i64 :: proc "contextless" (buf: []u8, v: i64) -> string {
	if v >= 0 {
		return format_u64(buf, u64(v))
	}
	if len(buf) == 0 {
		return ""
	}
	buf[0] = '-'
	digits := format_u64(buf[1:], u64(0) - u64(v)) // the magnitude, without overflow at min(i64)
	if digits == "" {
		return ""
	}
	return string(buf[:1 + len(digits)])
}

// Decimal digits, at least one, and nothing else: no sign, no space. ok is
// false otherwise, or if the value overflows a u64. Leading zeros are the
// caller's to refuse.
parse_u64 :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}
	for c in transmute([]u8)s {
		if c < '0' || c > '9' {
			return 0, false
		}
		m, mul_overflow := intrinsics.overflow_mul(v, 10)
		sum, add_overflow := intrinsics.overflow_add(m, u64(c - '0'))
		if mul_overflow || add_overflow {
			return 0, false
		}
		v = sum
	}
	return v, true
}

// --- Buf ---

// Bytes being written into a caller's buffer. A write that does not fit
// sets failed and writes nothing, and every later write is ignored, so a
// writer checks once, at the end. Encoders embed it (`using out: str.Buf`)
// or use it as is.
Buf :: struct {
	buf:    []u8,
	len:    int,
	failed: bool,
}

write_bytes :: proc "contextless" (b: ^Buf, p: []u8) {
	if b.failed || len(p) > len(b.buf) - b.len {
		b.failed = true
		return
	}
	copy(b.buf[b.len:], p) // a memmove: p may already sit where it is going
	b.len += len(p)
}

write_string :: proc "contextless" (b: ^Buf, s: string) {
	write_bytes(b, transmute([]u8)s)
}

write_byte :: proc "contextless" (b: ^Buf, c: u8) {
	if b.failed || b.len == len(b.buf) {
		b.failed = true
		return
	}
	b.buf[b.len] = c
	b.len += 1
}

// v in decimal.
write_u64 :: proc "contextless" (b: ^Buf, v: u64) {
	digits: [U64_DIGITS]u8
	write_string(b, format_u64(digits[:], v))
}

// v in decimal, with a '-' if it is negative.
write_i64 :: proc "contextless" (b: ^Buf, v: i64) {
	digits: [I64_DIGITS]u8
	write_string(b, format_i64(digits[:], v))
}

// What has been written: valid however failed is set, but an encoder whose
// write failed should not use it.
to_bytes :: proc "contextless" (b: ^Buf) -> []u8 {
	return b.buf[:b.len]
}

to_string :: proc "contextless" (b: ^Buf) -> string {
	return string(b.buf[:b.len])
}
