// UTF-8, strictly (upstream ADR-0013): no overlong encodings, no surrogates,
// nothing above U+10FFFF. Decoding is forgiving (a bad byte decodes to
// RUNE_ERROR); code that must refuse bad text asks `valid`.
//
// Imports nothing beyond the language, so the kernel, user space and host
// tools share it.
package utf

UTF_MAX :: 4 // bytes in a rune, at most
RUNE_SELF :: 0x80 // a byte below this is a rune by itself
RUNE_ERROR :: rune(0xfffd) // what a bad byte decodes to
RUNE_MAX :: rune(0x10ffff)

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
		return RUNE_ERROR, 1
	}
	return rune(v), int(n)
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
