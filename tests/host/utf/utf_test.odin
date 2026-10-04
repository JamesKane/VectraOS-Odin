// lib/utf at every boundary of the encoding (upstream ADR-0013), ported from
// upstream's tests/host/utf_test.c: the first and last rune of each length,
// overlong forms, surrogates, past U+10FFFF, truncated and stray bytes;
// cutting, stepping back, and names.
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

@(test)
test_encode :: proc(t: ^testing.T) {
	runes := []rune{0, 'a', 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff}
	for want in runes {
		buf: [utf.UTF_MAX]u8
		n := utf.encode(&buf, want)
		testing.expectf(t, n == utf.rune_len(want), "encode(%U) wrote %d bytes, rune_len says %d", want, n, utf.rune_len(want))
		r, size := utf.decode(string(buf[:n]))
		testing.expectf(t, r == want, "encode(%U) decodes as %U", want, r)
		testing.expectf(t, size == n, "encode(%U) decodes in %d bytes, not %d", want, size, n)
		testing.expectf(t, utf.full_rune(string(buf[:n])), "encode(%U) is not a full rune", want)
		testing.expectf(t, n == 1 || !utf.full_rune(string(buf[:n - 1])), "encode(%U) less a byte is a full rune", want)
	}
	buf: [utf.UTF_MAX]u8
	testing.expect_value(t, utf.encode(&buf, 0xd800), 3) // as U+FFFD
	r, size := utf.decode(string(buf[:3]))
	testing.expect_value(t, r, utf.RUNE_ERROR)
	testing.expect_value(t, size, 3)
	testing.expect_value(t, utf.encode(&buf, 0x110000), 3)
	testing.expect_value(t, utf.rune_len(0x110000), 3)
	testing.expect(t, utf.full_rune("\xe2\x28")) // bad already: no more bytes needed to know
}

@(test)
test_strings :: proc(t: ^testing.T) {
	s := "a\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80z" // a é € 😀 z: 1+2+3+4+1 bytes
	testing.expect_value(t, utf.rune_count(s), 5)
	testing.expect(t, utf.valid(s))
	at, ok := utf.index_rune(s, 0x20ac)
	testing.expect(t, ok)
	testing.expect_value(t, at, 3)
	_, ok = utf.index_rune(s, 'q')
	testing.expect(t, !ok)
	at, ok = utf.index_rune("abab", 'b')
	testing.expect_value(t, at, 1)
	at, ok = utf.last_index_rune("abab", 'b')
	testing.expect(t, ok)
	testing.expect_value(t, at, 3)
	testing.expect(t, !utf.valid("a\xc3"))
	testing.expect(t, !utf.valid("\xed\xa0\x80"))
	testing.expect(t, utf.valid(""))
	testing.expect_value(t, utf.rune_count("\xff\xfe"), 2) // a bad byte is one rune

	// Cuts end at rune boundaries: never inside é, €, 😀.
	Cut :: struct {
		max, want: int,
	}
	cuts := []Cut{{100, len(s)}, {1, 1}, {2, 1}, {3, 3}, {5, 3}, {6, 6}, {9, 6}, {10, 10}}
	for c in cuts {
		testing.expectf(t, utf.cut(s, c.max) == c.want, "cut(s, %d) is %d, want %d", c.max, utf.cut(s, c.max), c.want)
	}
	testing.expect_value(t, utf.cut("\xff\xfe", 1), 1) // bad bytes cut anywhere

	// Back over one rune at a time.
	Back :: struct {
		s:        string,
		at, want: int,
	}
	backs := []Back {
		{s, len(s), 10},
		{s, 10, 6},
		{s, 6, 3},
		{s, 3, 1},
		{s, 1, 0},
		{s, 0, 0},
		{"a\x80", 2, 1}, // a stray continuation byte: one byte back
		{"\xc3\xa9\x80", 3, 2},
	}
	for c in backs {
		testing.expectf(t, utf.back(c.s, c.at) == c.want, "back(%q, %d) is %d, want %d", c.s, c.at, utf.back(c.s, c.at), c.want)
	}
}

@(test)
test_names :: proc(t: ^testing.T) {
	Case :: struct {
		s:    string,
		want: bool,
	}
	cases := []Case {
		{"caf\xc3\xa9", true},
		{"a b", true},
		{"a\nb", false},
		{"a\tb", false},
		{"\x7f", false},
		{"a\x00b", false},
		{"\xc3", false},
		{"\xc0\xaf", false},
	}
	for c in cases {
		testing.expectf(t, utf.is_name(c.s) == c.want, "is_name(%q) is %v", c.s, !c.want)
	}
}
