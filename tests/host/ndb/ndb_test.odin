// lib/ndb's strict parser and writer (upstream 02 §4.1), ported from
// upstream's tests/host/ndb_test.c.
package ndb_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:ndb"

Parsed :: struct {
	records:    int,
	last:       ndb.Record,
	error:      string, // empty if it parsed
	error_line: int,
}

// Parses all of src. The values in p.last point into scratch, so the caller
// keeps scratch for as long as it reads them.
parse :: proc(src: string, scratch: []u8) -> (p: Parsed) {
	r := ndb.Reader{src = src, scratch = scratch}
	for {
		rec: ndb.Record // the end of input clears the record it is given, so keep the last one apart
		switch ndb.next(&r, &rec) {
		case .End:
			return
		case .Error:
			p.error, p.error_line = r.error, r.error_line
			return
		case .Record:
			p.last = rec
			p.records += 1
		}
	}
}

expect_parsed :: proc(t: ^testing.T, p: Parsed, records: int, loc := #caller_location) {
	testing.expect_value(t, p.error, "", loc)
	testing.expect_value(t, p.records, records, loc)
}

expect_get :: proc(t: ^testing.T, rec: ^ndb.Record, key, want: string, loc := #caller_location) {
	v, ok := ndb.get(rec, key)
	testing.expectf(t, ok, "no %s=", key, loc = loc)
	testing.expect_value(t, v, want, loc)
}

// Writes key=value and reads it back: the value must come back exactly.
expect_round_trip :: proc(t: ^testing.T, value: string, loc := #caller_location) {
	buf: [512]u8
	w := ndb.Writer{buf = buf[:]}
	ndb.put(&w, "k", value)
	ndb.flag(&w, "f")
	if !testing.expectf(t, ndb.end(&w), "%q was not written", value, loc = loc) {
		return
	}
	scratch: [4096]u8
	p := parse(ndb.written(&w), scratch[:])
	expect_parsed(t, p, 1, loc)
	testing.expectf(t, ndb.is_flag(&p.last, "f"), "%q: the flag after it is lost", value, loc = loc)
	expect_get(t, &p.last, "k", value, loc)
}

@(test)
test_writer :: proc(t: ^testing.T) {
	values := []string {
		"plain",
		"",
		"two words",
		`say "hi"`,
		"#not-a-comment",
		"line\nbreak k=forged", // a forged tuple stays inside the value
		"\xff\xfe", // not UTF-8
		"tab\there",
		"caf\xc3\xa9 au lait",
		`x"41"`, // looks like hex, is not
	}
	for v in values {
		expect_round_trip(t, v)
	}

	buf: [128]u8
	scratch: [4096]u8
	w := ndb.Writer{buf = buf[:]}
	ndb.put_i64(&w, "min", min(i64))
	ndb.put_u64(&w, "max", max(u64))
	testing.expect(t, ndb.end(&w))
	p := parse(ndb.written(&w), scratch[:])
	expect_get(t, &p.last, "min", "-9223372036854775808")
	expect_get(t, &p.last, "max", "18446744073709551615")

	// A key that could not be read back fails the record; so does running out of room.
	for key in ([]string{"", "a b", "a=b", `q"`, "#k", "nl\n"}) {
		w = ndb.Writer{buf = buf[:]}
		ndb.flag(&w, key)
		testing.expectf(t, !ndb.end(&w), "key %q was accepted", key)
	}
	w = ndb.Writer{buf = buf[:8]}
	ndb.put(&w, "key", "longer than eight")
	testing.expect(t, !ndb.end(&w))
}

@(test)
test_numbers :: proc(t: ^testing.T) {
	numbers := "a=0 b=18446744073709551615 c=18446744073709551616 d=007 e=-1 f=1x g " +
		"p=0x3f8 q=0xffffffffffffffff r=0x10000000000000000 s=0x t=0xG u=0X1 w=0xA\n"
	scratch: [4096]u8
	r := ndb.Reader{src = numbers, scratch = scratch[:]}
	rec: ndb.Record
	testing.expect_value(t, ndb.next(&r, &rec), ndb.Result.Record)
	Case :: struct {
		key:  string,
		want: u64,
		ok:   bool,
	}
	cases := []Case {
		{"a", 0, true},
		{"b", max(u64), true},
		{"c", 0, false},
		{"d", 0, false},
		{"e", 0, false},
		{"f", 0, false},
		{"g", 0, false},
		{"h", 0, false},
		{"r", 0, false},
		{"s", 0, false},
		{"t", 0, false},
		{"p", 0x3f8, true},
		{"q", max(u64), true},
		// 0X and uppercase digits are not ours.
		{"u", 0, false},
		{"w", 0, false},
	}
	for c in cases {
		v, ok := ndb.get_u64(&rec, c.key)
		testing.expectf(t, ok == c.ok, "get_u64(%s=) ok is %v, want %v", c.key, ok, c.ok)
		if c.ok {
			testing.expectf(t, v == c.want, "%s= read as %d, want %d", c.key, v, c.want)
		}
	}
}

@(test)
test_records :: proc(t: ^testing.T) {
	scratch: [4096]u8
	// Records, continuation lines, comments and blank lines.
	p := parse("a=1 b=2 flag\n  c=3\nd=4", scratch[:])
	expect_parsed(t, p, 2)
	expect_get(t, &p.last, "d", "4")
	p = parse("a=1 b=2 flag\n  c=3\n", scratch[:])
	expect_parsed(t, p, 1)
	testing.expect_value(t, len(p.last.tuples), 4)
	expect_get(t, &p.last, "c", "3")
	testing.expect(t, ndb.has(&p.last, "flag"))
	testing.expect(t, ndb.is_flag(&p.last, "flag"))
	p = parse("a=1\n\n  # comment\n  b=2\nc=3", scratch[:])
	expect_parsed(t, p, 2)
	p = parse("# only a comment\n\n", scratch[:])
	expect_parsed(t, p, 0)
}

@(test)
test_values :: proc(t: ^testing.T) {
	scratch: [4096]u8
	// Quoted with doubled quotes, '#' inside a bare value, hex bytes.
	p := parse(`k="say ""hi""" color=#1b1d23 # tail` + "\n", scratch[:])
	testing.expect_value(t, p.error, "")
	expect_get(t, &p.last, "k", `say "hi"`)
	expect_get(t, &p.last, "color", "#1b1d23")
	p = parse(`name=x"610a62"`, scratch[:])
	testing.expect_value(t, p.error, "")
	expect_get(t, &p.last, "name", "a\nb")
	p = parse(`empty=""`, scratch[:])
	testing.expect_value(t, p.error, "")
	expect_get(t, &p.last, "empty", "")
	testing.expect(t, !ndb.is_flag(&p.last, "empty"))
	p = parse("u=\"caf\xc3\xa9\"", scratch[:])
	testing.expect_value(t, p.error, "")
	expect_get(t, &p.last, "u", "caf\xc3\xa9")
}

@(test)
test_rejected :: proc(t: ^testing.T) {
	scratch: [4096]u8
	// Rejected whole, never repaired.
	bad := []string {
		"a=1 a=2",
		"a=1\n  a=2", // a duplicate on a continuation line
		`a="open`,
		"a=\"line\nbreak\"",
		`a=b"c`,
		`a"b=1`,
		"a=",
		`a="x"y`,
		`a=x"6"`, // odd number of hex digits
		`a=x"zz"`,
		"a=\"\xff\"", // invalid UTF-8
		"a=\xc0\xaf", // an overlong encoding
		"a=\"\xed\xa0\x80\"", // a surrogate
		"a=\"tab\there\"", // a control character
		"=1",
		"  indented=1",
	}
	for src in bad {
		testing.expectf(t, parse(src, scratch[:]).error != "", "accepted %q", src)
	}
	p := parse("ok=1\n  indented=1\nb=1 b=2", scratch[:])
	testing.expect(t, p.error != "")
	testing.expect_value(t, p.error_line, 3)
}

@(test)
test_limits :: proc(t: ^testing.T) {
	scratch: [4096]u8
	// A record over 64 KiB is rejected.
	big := strings.builder_make()
	defer strings.builder_destroy(&big)
	strings.write_string(&big, "k=1\n")
	for strings.builder_len(big) + 8 < 70000 {
		strings.write_string(&big, "  x=1  \n")
	}
	testing.expect(t, parse(strings.to_string(big), scratch[:]).error != "")

	// Every key at most once, and at most MAX_TUPLES of them.
	many := strings.builder_make()
	defer strings.builder_destroy(&many)
	for i in 0 ..= ndb.MAX_TUPLES {
		fmt.sbprintf(&many, "k%d=1 ", i)
	}
	testing.expect(t, parse(strings.to_string(many), scratch[:]).error != "")
}
