// Upstream's utf fuzzer (tests/fuzz/utf_fuzz.c) over its corpus
// (tests/fuzz/corpus/utf): the decoder always moves on, by one byte at a bad
// one; what it decodes encodes back to the same bytes wherever the input was
// valid; a cut never splits a rune; and stepping back over the input finds
// the starts stepping forward found.
package utf_test

import "core:slice"
import "core:testing"
import "vx:utf"

CORPUS := #load_directory("corpus")

@(private="file")
utf_fuzz :: proc(t: ^testing.T, name: string, s: string) {
	starts: [dynamic]int
	defer delete(starts)
	valid := true
	for at := 0; at < len(s); {
		r, n := utf.decode(s[at:])
		if !testing.expectf(t, n >= 1 && n <= utf.UTF_MAX && at + n <= len(s), "%s: decode at %d used %d bytes", name, at, n) {
			return
		}
		testing.expectf(t, r <= utf.RUNE_MAX && !(r >= 0xd800 && r <= 0xdfff), "%s: decoded %U", name, r)
		if r == utf.RUNE_ERROR && n != 3 {
			testing.expectf(t, n == 1, "%s: a bad byte at %d used %d bytes", name, at, n)
			valid = false
		} else {
			buf: [utf.UTF_MAX]u8
			m := utf.encode(&buf, r)
			testing.expectf(t, slice.equal(buf[:m], transmute([]u8)s[at:at + n]), "%s: %U at %d does not encode back", name, r, at)
		}
		append(&starts, at)
		at += n
	}
	testing.expectf(t, utf.valid(s) == valid, "%s: valid is %v", name, !valid)
	for max_bytes in 0 ..= min(len(s), 63) { // a cut is at a start, or the end
		c := utf.cut(s, max_bytes)
		testing.expectf(t, c <= max_bytes, "%s: cut(%d) is %d", name, max_bytes, c)
		testing.expectf(t, c == len(s) || slice.contains(starts[:], c), "%s: cut(%d) is %d, not a start", name, max_bytes, c)
	}
	if valid { // back over valid text: the starts, in reverse
		pos := len(s)
		#reverse for start in starts {
			pos = utf.back(s, pos)
			testing.expectf(t, pos == start, "%s: back to %d, want %d", name, pos, start)
		}
	}
}

@(test)
test_corpus :: proc(t: ^testing.T) {
	testing.expect_value(t, len(CORPUS), 2)
	for file in CORPUS {
		utf_fuzz(t, file.name, string(file.data))
	}
}
