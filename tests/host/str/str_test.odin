// lib/str's helpers, checked against core:strings and core:strconv where
// they share a procedure, and case by case where they do not.
package str_test

import "core:strconv"
import "core:strings"
import "core:testing"
import "vx:str"

@(test)
test_search :: proc(t: ^testing.T) {
	Case :: struct {
		s, sub: string,
	}
	cases := []Case {
		{"", ""},
		{"", "a"},
		{"a", ""},
		{"abc", "a"},
		{"abc", "c"},
		{"abc", "bc"},
		{"abc", "abcd"},
		{"abcabc", "ca"},
		{"/srv/bootfs", "/srv/"},
		{"svcd.ndb", ".ndb"},
		{"aaa", "aa"},
	}
	for c in cases {
		testing.expect_value(t, str.index(c.s, c.sub), strings.index(c.s, c.sub))
		testing.expect_value(t, str.contains(c.s, c.sub), strings.contains(c.s, c.sub))
		testing.expect_value(t, str.has_prefix(c.s, c.sub), strings.has_prefix(c.s, c.sub))
		testing.expect_value(t, str.has_suffix(c.s, c.sub), strings.has_suffix(c.s, c.sub))
		for b in ([]u8{'a', 'c', '/', '.', 'z'}) {
			testing.expect_value(t, str.index_byte(c.s, b), strings.index_byte(c.s, b))
			testing.expect_value(t, str.last_index_byte(c.s, b), strings.last_index_byte(c.s, b))
		}
	}
}

@(test)
test_split_iterator :: proc(t: ^testing.T) {
	inputs := []string{"", "/", "a", "a/b", "/a/b", "a//b", "a/", "a//", "//", "/boot/bin/ls", "vx.skip=a,b"}
	for input in inputs {
		ours, theirs := input, input
		for {
			want, want_ok := strings.split_iterator(&theirs, "/")
			got, got_ok := str.split_iterator(&ours, '/')
			testing.expect_value(t, got_ok, want_ok)
			testing.expect_value(t, got, want)
			if !got_ok || !want_ok {
				break
			}
		}
		testing.expect_value(t, ours, theirs)
	}
}

@(test)
test_split_iterator_fields :: proc(t: ^testing.T) {
	rest := "mount=/ src=/srv/bootfs  flags=a"
	want := []string{"mount=/", "src=/srv/bootfs", "", "flags=a"}
	i := 0
	for field in str.split_iterator(&rest, ' ') {
		if !testing.expect(t, i < len(want)) {
			return
		}
		testing.expect_value(t, field, want[i])
		i += 1
	}
	testing.expect_value(t, i, len(want))
}

@(test)
test_from_nul_padded :: proc(t: ^testing.T) {
	Case :: struct {
		b:    []u8,
		want: string,
	}
	cases := []Case {
		{{}, ""},
		{{0, 0}, ""},
		{{'s', 'v', 'c', 'd', 0, 0, 0}, "svcd"},
		{{'a', 0, 'b'}, "a"}, // only the first NUL counts
		{{'f', 'u', 'l', 'l'}, "full"}, // a name that fills its field has no NUL
	}
	for c in cases {
		testing.expect_value(t, str.from_nul_padded(c.b), c.want)
	}
}

@(test)
test_join :: proc(t: ^testing.T) {
	buf: [14]u8
	s, ok := str.join(buf[:], "/proc/", "7", "/status")
	testing.expect(t, ok)
	testing.expect_value(t, s, "/proc/7/status")
	s, ok = str.join(buf[:], "/proc/", "12", "/status") // one byte too many
	testing.expect(t, !ok)
	testing.expect_value(t, s, "")
	s, ok = str.join(buf[:])
	testing.expect(t, ok)
	testing.expect_value(t, s, "")
}

@(test)
test_format :: proc(t: ^testing.T) {
	unsigned := []u64{0, 1, 9, 10, 99, 100, 4096, 1 << 32, max(u64)}
	for v in unsigned {
		ours: [str.U64_DIGITS]u8
		theirs: [32]u8
		testing.expect_value(t, str.format_u64(ours[:], v), strconv.write_uint(theirs[:], v, 10))
	}
	signed := []i64{0, 1, -1, 42, -42, max(i64), min(i64)}
	for v in signed {
		ours: [str.I64_DIGITS]u8
		theirs: [32]u8
		testing.expect_value(t, str.format_i64(ours[:], v), strconv.write_int(theirs[:], v, 10))
	}

	// Too short a buffer gives "", not a truncated number.
	short: [2]u8
	testing.expect_value(t, str.format_u64(short[:], 100), "")
	testing.expect_value(t, str.format_u64(short[:], 99), "99")
	testing.expect_value(t, str.format_i64(short[:], -10), "")
	testing.expect_value(t, str.format_i64(short[:], -1), "-1")
	testing.expect_value(t, str.format_i64(short[:0], -1), "")
}

@(test)
test_parse_u64 :: proc(t: ^testing.T) {
	Case :: struct {
		s:    string,
		want: u64,
		ok:   bool,
	}
	cases := []Case {
		{"0", 0, true},
		{"7", 7, true},
		{"007", 7, true}, // leading zeros are the caller's to refuse
		{"18446744073709551615", max(u64), true},
		{"18446744073709551616", 0, false}, // overflows by one
		{"99999999999999999999", 0, false},
		{"", 0, false},
		{"-1", 0, false},
		{"+1", 0, false},
		{" 1", 0, false},
		{"1 ", 0, false},
		{"0x10", 0, false},
		{"12a", 0, false},
	}
	for c in cases {
		v, ok := str.parse_u64(c.s)
		testing.expect_value(t, ok, c.ok)
		testing.expect_value(t, v, c.want)
	}
}

@(test)
test_buf :: proc(t: ^testing.T) {
	mem: [16]u8
	b := str.Buf{buf = mem[:]}
	str.write_string(&b, "n=")
	str.write_u64(&b, 42)
	str.write_byte(&b, ' ')
	str.write_i64(&b, -7)
	str.write_bytes(&b, {'!'})
	testing.expect(t, !b.failed)
	testing.expect_value(t, str.to_string(&b), "n=42 -7!")
	testing.expect_value(t, len(str.to_bytes(&b)), 8)

	// A write that does not fit writes nothing, and every later write is
	// ignored, even one that would fit.
	str.write_string(&b, "123456789")
	testing.expect(t, b.failed)
	testing.expect_value(t, b.len, 8)
	str.write_byte(&b, 'x')
	testing.expect_value(t, b.len, 8)

	// Exactly full is not a failure.
	full := str.Buf{buf = mem[:3]}
	str.write_string(&full, "ab")
	str.write_byte(&full, 'c')
	testing.expect(t, !full.failed)
	str.write_byte(&full, 'd')
	testing.expect(t, full.failed)
	testing.expect_value(t, str.to_string(&full), "abc")
}
