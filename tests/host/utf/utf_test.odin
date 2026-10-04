// lib/utf's strict decoding and validation (upstream ADR-0013), ported from
// the decoding and validity cases of upstream's tests/host/utf_test.c. The
// rest of vx-utf (encoding, cutting, searching) is ported when something
// needs it.
package utf_test

import "core:testing"
import "vx:utf"

@(test)
test_decode :: proc(t: ^testing.T) {
	Case :: struct {
		s:    string,
		r:    rune,
		size: int,
	}
	cases := []Case {
		{"a", 'a', 1},
		{"\x00", 0, 1}, // NUL is a rune too, given its length
		{"\x7f", 0x7f, 1},
		{"\xc2\x80", 0x80, 2}, // the first two-byte rune
		{"\xdf\xbf", 0x7ff, 2}, // the last
		{"\xe0\xa0\x80", 0x800, 3}, // the first three-byte rune
		{"\xef\xbf\xbf", 0xffff, 3}, // the last
		{"\xf0\x90\x80\x80", 0x10000, 4},
		{"\xf4\x8f\xbf\xbf", 0x10ffff, 4}, // RUNE_MAX
		{"\xef\xbf\xbd", utf.RUNE_ERROR, 3}, // U+FFFD itself, valid

		{"\xc0\x80", utf.RUNE_ERROR, 1}, // overlong NUL
		{"\xc1\xbf", utf.RUNE_ERROR, 1}, // overlong
		{"\xe0\x9f\xbf", utf.RUNE_ERROR, 1}, // overlong three-byte
		{"\xf0\x8f\xbf\xbf", utf.RUNE_ERROR, 1}, // overlong four-byte
		{"\xed\xa0\x80", utf.RUNE_ERROR, 1}, // U+D800, a surrogate
		{"\xed\xbf\xbf", utf.RUNE_ERROR, 1}, // U+DFFF
		{"\xed\x9f\xbf", 0xd7ff, 3}, // just below them
		{"\xf4\x90\x80\x80", utf.RUNE_ERROR, 1}, // U+110000
		{"\xf5\x80\x80\x80", utf.RUNE_ERROR, 1},
		{"\xff", utf.RUNE_ERROR, 1},
		{"\x80", utf.RUNE_ERROR, 1}, // a stray continuation byte
		{"\xe2\x82", utf.RUNE_ERROR, 1}, // truncated
		{"\xe2\x28\xa1", utf.RUNE_ERROR, 1}, // a bad continuation
		{"", utf.RUNE_ERROR, 0},
	}
	for c in cases {
		r, size := utf.decode(c.s)
		testing.expectf(t, r == c.r, "decode(%q) is %U, want %U", c.s, r, c.r)
		testing.expectf(t, size == c.size, "decode(%q) is %d bytes, want %d", c.s, size, c.size)
	}
}

@(test)
test_valid :: proc(t: ^testing.T) {
	Case :: struct {
		s:    string,
		want: bool,
	}
	cases := []Case {
		{"h\xc3\xa9 \xe2\x82\xac", true},
		{"", true},
		{"\xef\xbf\xbd", true}, // U+FFFD, correctly encoded
		{"a\xc3", false},
		{"\xed\xa0\x80", false},
	}
	for c in cases {
		testing.expectf(t, utf.valid(c.s) == c.want, "valid(%q) is %v", c.s, !c.want)
	}
}
