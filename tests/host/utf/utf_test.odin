// lib/utf's strict decoding and validation (upstream ADR-0013), ported from
// the decoding and validity cases of upstream's tests/host/utf_test.c. The
// rest of vx-utf (encoding, cutting, searching) is ported when something
// needs it.
package utf_test

import "core:testing"
import "vx:utf"

decodes :: proc(s: string, want: rune, want_size: int) -> bool {
	r, n := utf.decode(s)
	return r == want && n == want_size
}

@(test)
test_decode :: proc(t: ^testing.T) {
	testing.expect(t, decodes("a", 'a', 1))
	testing.expect(t, decodes("\x00", 0, 1)) // NUL is a rune too, given its length
	testing.expect(t, decodes("\x7f", 0x7f, 1))
	testing.expect(t, decodes("\xc2\x80", 0x80, 2)) // the first two-byte rune
	testing.expect(t, decodes("\xdf\xbf", 0x7ff, 2)) // the last
	testing.expect(t, decodes("\xe0\xa0\x80", 0x800, 3)) // the first three-byte rune
	testing.expect(t, decodes("\xef\xbf\xbf", 0xffff, 3)) // the last
	testing.expect(t, decodes("\xf0\x90\x80\x80", 0x10000, 4))
	testing.expect(t, decodes("\xf4\x8f\xbf\xbf", 0x10ffff, 4)) // RUNE_MAX
	testing.expect(t, decodes("\xef\xbf\xbd", utf.RUNE_ERROR, 3)) // U+FFFD itself, valid

	testing.expect(t, decodes("\xc0\x80", utf.RUNE_ERROR, 1)) // overlong NUL
	testing.expect(t, decodes("\xc1\xbf", utf.RUNE_ERROR, 1)) // overlong
	testing.expect(t, decodes("\xe0\x9f\xbf", utf.RUNE_ERROR, 1)) // overlong three-byte
	testing.expect(t, decodes("\xf0\x8f\xbf\xbf", utf.RUNE_ERROR, 1)) // overlong four-byte
	testing.expect(t, decodes("\xed\xa0\x80", utf.RUNE_ERROR, 1)) // U+D800, a surrogate
	testing.expect(t, decodes("\xed\xbf\xbf", utf.RUNE_ERROR, 1)) // U+DFFF
	testing.expect(t, decodes("\xed\x9f\xbf", 0xd7ff, 3)) // just below them
	testing.expect(t, decodes("\xf4\x90\x80\x80", utf.RUNE_ERROR, 1)) // U+110000
	testing.expect(t, decodes("\xf5\x80\x80\x80", utf.RUNE_ERROR, 1))
	testing.expect(t, decodes("\xff", utf.RUNE_ERROR, 1))
	testing.expect(t, decodes("\x80", utf.RUNE_ERROR, 1)) // a stray continuation byte
	testing.expect(t, decodes("\xe2\x82", utf.RUNE_ERROR, 1)) // truncated
	testing.expect(t, decodes("\xe2\x28\xa1", utf.RUNE_ERROR, 1)) // a bad continuation
	testing.expect(t, decodes("", utf.RUNE_ERROR, 0))
}

@(test)
test_valid :: proc(t: ^testing.T) {
	testing.expect(t, utf.valid("h\xc3\xa9 \xe2\x82\xac"))
	testing.expect(t, utf.valid(""))
	testing.expect(t, utf.valid("\xef\xbf\xbd")) // U+FFFD, correctly encoded
	testing.expect(t, !utf.valid("a\xc3"))
	testing.expect(t, !utf.valid("\xed\xa0\x80"))
}
