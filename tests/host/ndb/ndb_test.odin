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

// Values point into it, so it outlives each parse; one per test thread.
@(thread_local)
scratch: [4096]u8

parse :: proc(src: string) -> (p: Parsed) {
	r := ndb.Reader{src = src, scratch = scratch[:]}
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

value_is :: proc(rec: ^ndb.Record, key, want: string) -> bool {
	v, ok := ndb.get(rec, key)
	return ok && v == want
}

// Writes key=value and reads it back: the value must come back exactly.
round_trip :: proc(value: string) -> bool {
	buf: [512]u8
	w := ndb.Writer{buf = buf[:]}
	ndb.put(&w, "k", value)
	ndb.flag(&w, "f")
	if !ndb.end(&w) {
		return false
	}
	p := parse(ndb.written(&w))
	got, ok := ndb.get(&p.last, "k")
	return p.error == "" && p.records == 1 && ndb.is_flag(&p.last, "f") && ok && got == value
}

@(test)
test_writer :: proc(t: ^testing.T) {
	testing.expect(t, round_trip("plain"))
	testing.expect(t, round_trip(""))
	testing.expect(t, round_trip("two words"))
	testing.expect(t, round_trip(`say "hi"`))
	testing.expect(t, round_trip("#not-a-comment"))
	testing.expect(t, round_trip("line\nbreak k=forged")) // a forged tuple stays inside the value
	testing.expect(t, round_trip("\xff\xfe")) // not UTF-8
	testing.expect(t, round_trip("tab\there"))
	testing.expect(t, round_trip("caf\xc3\xa9 au lait"))
	testing.expect(t, round_trip(`x"41"`)) // looks like hex, is not

	buf: [128]u8
	w := ndb.Writer{buf = buf[:]}
	ndb.put_i64(&w, "min", min(i64))
	ndb.put_u64(&w, "max", max(u64))
	testing.expect(t, ndb.end(&w))
	p := parse(ndb.written(&w))
	testing.expect(t, value_is(&p.last, "min", "-9223372036854775808"))
	testing.expect(t, value_is(&p.last, "max", "18446744073709551615"))

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
	r := ndb.Reader{src = numbers, scratch = scratch[:]}
	rec: ndb.Record
	testing.expect(t, ndb.next(&r, &rec) == .Record)
	v, ok := ndb.get_u64(&rec, "a")
	testing.expect(t, ok && v == 0)
	v, ok = ndb.get_u64(&rec, "b")
	testing.expect(t, ok && v == max(u64))
	for key in ([]string{"c", "d", "e", "f", "g", "h", "r", "s", "t"}) {
		_, ok = ndb.get_u64(&rec, key)
		testing.expectf(t, !ok, "%s= read as a number", key)
	}
	v, ok = ndb.get_u64(&rec, "p")
	testing.expect(t, ok && v == 0x3f8)
	v, ok = ndb.get_u64(&rec, "q")
	testing.expect(t, ok && v == max(u64))
	// 0X and uppercase digits are not ours.
	_, ok = ndb.get_u64(&rec, "u")
	testing.expect(t, !ok)
	_, ok = ndb.get_u64(&rec, "w")
	testing.expect(t, !ok)
}

@(test)
test_records :: proc(t: ^testing.T) {
	// Records, continuation lines, comments and blank lines.
	p := parse("a=1 b=2 flag\n  c=3\nd=4")
	testing.expect(t, p.error == "" && p.records == 2 && value_is(&p.last, "d", "4"))
	p = parse("a=1 b=2 flag\n  c=3\n")
	testing.expect(t, p.error == "" && p.records == 1 && len(p.last.tuples) == 4 && value_is(&p.last, "c", "3"))
	testing.expect(t, ndb.has(&p.last, "flag") && ndb.is_flag(&p.last, "flag"))
	p = parse("a=1\n\n  # comment\n  b=2\nc=3")
	testing.expect(t, p.error == "" && p.records == 2)
	p = parse("# only a comment\n\n")
	testing.expect(t, p.error == "" && p.records == 0)
}

@(test)
test_values :: proc(t: ^testing.T) {
	// Quoted with doubled quotes, '#' inside a bare value, hex bytes.
	p := parse(`k="say ""hi""" color=#1b1d23 # tail` + "\n")
	testing.expect(t, p.error == "" && value_is(&p.last, "k", `say "hi"`) && value_is(&p.last, "color", "#1b1d23"))
	p = parse(`name=x"610a62"`)
	testing.expect(t, p.error == "" && value_is(&p.last, "name", "a\nb"))
	p = parse(`empty=""`)
	testing.expect(t, p.error == "" && value_is(&p.last, "empty", "") && !ndb.is_flag(&p.last, "empty"))
	p = parse("u=\"caf\xc3\xa9\"")
	testing.expect(t, p.error == "" && value_is(&p.last, "u", "caf\xc3\xa9"))
}

@(test)
test_rejected :: proc(t: ^testing.T) {
	// Rejected whole, never repaired.
	bad := []string{
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
		testing.expectf(t, parse(src).error != "", "accepted %q", src)
	}
	p := parse("ok=1\n  indented=1\nb=1 b=2")
	testing.expect(t, p.error != "" && p.error_line == 3)
}

@(test)
test_limits :: proc(t: ^testing.T) {
	// A record over 64 KiB is rejected.
	big := strings.builder_make()
	defer strings.builder_destroy(&big)
	strings.write_string(&big, "k=1\n")
	for strings.builder_len(big) + 8 < 70000 {
		strings.write_string(&big, "  x=1  \n")
	}
	testing.expect(t, parse(strings.to_string(big)).error != "")

	// Every key at most once, and at most MAX_TUPLES of them.
	many := strings.builder_make()
	defer strings.builder_destroy(&many)
	for i in 0 ..= ndb.MAX_TUPLES {
		fmt.sbprintf(&many, "k%d=1 ", i)
	}
	testing.expect(t, parse(strings.to_string(many)).error != "")
}
