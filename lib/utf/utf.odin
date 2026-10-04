// UTF-8, a rune at a time (upstream ADR-0013), as Plan 9's libc has it:
// nothing here reads past the slice it is given.
//
// Decoding is strict and never fails. An overlong form, a surrogate
// (U+D800-U+DFFF), anything above U+10FFFF, a stray continuation byte and a
// truncated sequence each decode to RUNE_ERROR, using up exactly one byte, as
// Plan 9's chartorune does: a decoder always moves on, and valid text after a
// bad byte still decodes. Code that must refuse bad text asks `valid`.
//
// Imports nothing beyond the language, so the kernel, user space and host
// tools share it.
package utf

UTF_MAX :: 4 // bytes in a rune, at most
RUNE_SELF :: 0x80 // a byte below this is a rune by itself
RUNE_ERROR :: rune(0xfffd) // what a bad byte decodes to
RUNE_MAX :: rune(0x10ffff)

// The length of the sequence a lead byte starts: 2 to 4, or 1 for a byte that
// is a rune by itself or can never start one.
@(private="file")
lead_len :: proc "contextless" (c: u8) -> int {
	switch {
	case c >= 0xc2 && c <= 0xdf:
		return 2
	case c & 0xf0 == 0xe0:
		return 3
	case c >= 0xf0 && c <= 0xf4:
		return 4
	}
	return 1
}

@(private="file")
encodable :: proc "contextless" (r: rune) -> bool {
	return r >= 0 && r <= RUNE_MAX && !(r >= 0xd800 && r <= 0xdfff)
}

// Decodes the rune at the start of s. Returns it and the bytes it used: 1 to
// 4, or 0 if s is empty. A bad byte is RUNE_ERROR, and 1.
decode :: proc "contextless" (s: string) -> (r: rune, size: int) {
	if len(s) == 0 {
		return RUNE_ERROR, 0
	}
	c := u32(s[0])
	if c < RUNE_SELF {
		return rune(c), 1
	}
	n, v, lo: u32
	switch {
	case c >= 0xc2 && c <= 0xdf:
		n, v, lo = 2, c & 0x1f, 0x80
	case c & 0xf0 == 0xe0:
		n, v, lo = 3, c & 0x0f, 0x800
	case c >= 0xf0 && c <= 0xf4:
		n, v, lo = 4, c & 0x07, 0x10000
	case:
		return RUNE_ERROR, 1 // a continuation byte, 0xc0, 0xc1 or 0xf5 and up
	}
	if u32(len(s)) < n {
		return RUNE_ERROR, 1
	}
	for i in 1 ..< n {
		b := u32(s[i])
		if b & 0xc0 != 0x80 {
			return RUNE_ERROR, 1
		}
		v = v << 6 | b & 0x3f
	}
	if v < lo || v > u32(RUNE_MAX) || (v >= 0xd800 && v <= 0xdfff) {
		return RUNE_ERROR, 1 // overlong, too big, a surrogate
	}
	return rune(v), int(n)
}

// The bytes r takes; a rune that cannot be encoded takes RUNE_ERROR's 3.
rune_len :: proc "contextless" (r: rune) -> int {
	switch {
	case r >= 0 && r < 0x80:
		return 1
	case r >= 0 && r < 0x800:
		return 2
	case !encodable(r):
		return 3
	case r < 0x10000:
		return 3
	}
	return 4
}

// Encodes r into buf. Returns the bytes written, at the start of buf. A rune
// that cannot be encoded (a surrogate, or above RUNE_MAX) is RUNE_ERROR.
encode :: proc "contextless" (buf: ^[UTF_MAX]u8, r: rune) -> int {
	v := u32(encodable(r) ? r : RUNE_ERROR)
	switch {
	case v < 0x80:
		buf[0] = u8(v)
		return 1
	case v < 0x800:
		buf[0] = u8(0xc0 | v >> 6)
		buf[1] = u8(0x80 | v & 0x3f)
		return 2
	case v < 0x10000:
		buf[0] = u8(0xe0 | v >> 12)
		buf[1] = u8(0x80 | v >> 6 & 0x3f)
		buf[2] = u8(0x80 | v & 0x3f)
		return 3
	}
	buf[0] = u8(0xf0 | v >> 18)
	buf[1] = u8(0x80 | v >> 12 & 0x3f)
	buf[2] = u8(0x80 | v >> 6 & 0x3f)
	buf[3] = u8(0x80 | v & 0x3f)
	return 4
}

// Whether s holds the whole of the rune that starts it (or enough to know it
// is a bad byte), as a reader of a stream must know before it decodes.
full_rune :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	n := lead_len(s[0])
	for k in 1 ..< min(n, len(s)) {
		if s[k] & 0xc0 != 0x80 {
			return true // bad already: one byte
		}
	}
	return len(s) >= n
}

// The runes in s; each bad byte counts as one.
rune_count :: proc "contextless" (s: string) -> (runes: int) {
	for at := 0; at < len(s); runes += 1 {
		_, n := decode(s[at:])
		at += n
	}
	return
}

// Whether the rune decoded as c, n bytes long, is r: RUNE_ERROR matches only
// U+FFFD itself, not a bad byte.
@(private="file")
matches :: proc "contextless" (c: rune, n: int, r: rune) -> bool {
	return c == r && (r != RUNE_ERROR || n == 3)
}

// The offset of the first rune r in s (Plan 9's utfrune); ok is false if
// there is none.
index_rune :: proc "contextless" (s: string, r: rune) -> (at: int, ok: bool) {
	for at < len(s) {
		c, n := decode(s[at:])
		if matches(c, n, r) {
			return at, true
		}
		at += n
	}
	return 0, false
}

// The offset of the last rune r in s (Plan 9's utfrrune).
last_index_rune :: proc "contextless" (s: string, r: rune) -> (last: int, ok: bool) {
	for at := 0; at < len(s); {
		c, n := decode(s[at:])
		if matches(c, n, r) {
			last, ok = at, true
		}
		at += n
	}
	return
}

// Whether s is valid UTF-8 throughout. U+FFFD itself, correctly encoded, is
// valid; only a byte that decodes to it by error is not.
valid :: proc "contextless" (s: string) -> bool {
	i := 0
	for i < len(s) {
		if s[i] < RUNE_SELF {
			i += 1
			continue
		}
		r, n := decode(s[i:])
		if r == RUNE_ERROR && n == 1 {
			return false
		}
		i += n
	}
	return true
}

valid_bytes :: proc "contextless" (b: []u8) -> bool {
	return valid(string(b))
}

// The length of the longest prefix of s of at most max_bytes bytes that ends
// at a rune boundary: where a bounded copy of text is cut. A bad byte is a
// rune of its own.
cut :: proc "contextless" (s: string, max_bytes: int) -> int {
	if len(s) <= max_bytes {
		return len(s)
	}
	at := 0
	for at < max_bytes {
		_, n := decode(s[at:])
		if at + n > max_bytes {
			break
		}
		at += n
	}
	return at
}

// Where the rune before offset at in s starts: at - 1 for a bad byte, or 0
// for at 0. What a line editor's erase takes back.
back :: proc "contextless" (s: string, at: int) -> int {
	if at <= 0 {
		return 0
	}
	for b in 1 ..= min(UTF_MAX, at) {
		start := at - b
		if s[start] & 0xc0 == 0x80 {
			continue // a continuation byte: further back
		}
		r, n := decode(s[start:at])
		return start + n == at && (r != RUNE_ERROR || n == 3) ? start : at - 1
	}
	return at - 1
}

// Whether s may be a name, a path component (ADR-0013, as Plan 9's validname,
// made strict about UTF-8): valid UTF-8, with no control character
// (0x00-0x1f, 0x7f). The rest (".", "..", '/') is the caller's to refuse.
is_name :: proc "contextless" (s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] < 0x20 || s[i] == 0x7f {
			return false
		}
	}
	return valid(s)
}
