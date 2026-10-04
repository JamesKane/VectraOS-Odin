// The one text format (upstream 02 §4.1): Plan 9's ndb records.
//
// A record is one line of tuples plus the indented lines that follow it. A
// tuple is key=value or a bare key (a flag). Values are bare, "quoted" (""
// is one quote), or x"hex" for bytes that are not printable UTF-8.
//
// The parser is strict: a record with a duplicate key, bad quoting, a control
// character, invalid UTF-8 or more than 64 KiB is rejected whole, never
// repaired, so no two parsers read one record differently.
//
// The writer chooses each value's form itself: bare when it can, quoted when
// it has spaces or quotes, x"hex" when it is not printable UTF-8. Nothing that
// comes from another program can forge a tuple or a record, so nothing
// formats ndb by hand.
//
// No allocation: decoded values go to scratch space the caller owns.
package ndb

import "base:intrinsics"
import "vx:utf"

MAX_RECORD :: 64 * 1024
MAX_TUPLES :: 128

Tuple :: struct {
	key:   string,
	value: string,
	flag:  bool, // a bare key: value is empty
}

Record :: struct {
	tuples: [MAX_TUPLES]Tuple,
	count:  int,
	line:   int, // where the record starts, 1-based
}

Result :: enum {
	Record,
	End,
	Error,
}

// Values point into src or into scratch, so both must outlive them. A zeroed
// reader, given src and scratch, starts at line 1.
Reader :: struct {
	src:          string,
	pos:          int,
	line:         int, // lines consumed
	scratch:      []u8,
	scratch_used: int,
	error:        string, // set when next returns .Error,
	error_line:   int, // with the line it refers to
}

// Reads the next record into rec. At the end of the input, and on an error,
// rec is left empty.
@(require_results)
next :: proc "contextless" (r: ^Reader, rec: ^Record) -> Result {
	rec.count = 0
	for r.pos < len(r.src) && line_is_empty(r) {
		skip_line(r)
	}
	if r.pos >= len(r.src) {
		return .End
	}
	if is_space(peek(r)) {
		return fail(r, rec, "indented line with no record above it")
	}
	start := r.pos
	rec.line = r.line + 1
	for {
		if res := tuples(r, rec); res != .Record {
			return res
		}
		for r.pos < len(r.src) && line_is_empty(r) {
			skip_line(r)
		}
		if r.pos - start > MAX_RECORD {
			return fail(r, rec, "record longer than 64 KiB")
		}
		if !is_space(peek(r)) {
			return .Record // the next record, or the end
		}
	}
}

// The value of key; ok is false if the record lacks it. A flag gives "" and
// true, so ask `has` or look at the tuple to tell a flag from an empty value.
get :: proc "contextless" (rec: ^Record, key: string) -> (value: string, ok: bool) {
	for &t in rec.tuples[:rec.count] {
		if t.key == key {
			return t.value, true
		}
	}
	return "", false
}

has :: proc "contextless" (rec: ^Record, key: string) -> bool {
	_, ok := get(rec, key)
	return ok
}

is_flag :: proc "contextless" (rec: ^Record, key: string) -> bool {
	for &t in rec.tuples[:rec.count] {
		if t.key == key {
			return t.flag
		}
	}
	return false
}

// key's value as a number: decimal digits with no leading zeros, or 0x and
// lowercase hex digits; no sign, no overflow. ok is false otherwise, or if
// the record lacks the key.
get_u64 :: proc "contextless" (rec: ^Record, key: string) -> (n: u64, ok: bool) {
	v := get(rec, key) or_return
	base := u64(10)
	if len(v) > 2 && v[0] == '0' && v[1] == 'x' {
		base = 16
		v = v[2:]
	} else if len(v) == 0 || (len(v) > 1 && v[0] == '0') {
		return 0, false // no leading zeros in decimal
	}
	for i in 0 ..< len(v) {
		c := v[i]
		d := base // not a digit
		switch {
		case c >= '0' && c <= '9':
			d = u64(c - '0')
		case base == 16 && c >= 'a' && c <= 'f':
			d = u64(c - 'a') + 10
		}
		if d >= base {
			return 0, false
		}
		m, mul_overflow := intrinsics.overflow_mul(n, base)
		sum, add_overflow := intrinsics.overflow_add(m, d)
		if mul_overflow || add_overflow {
			return 0, false
		}
		n = sum
	}
	return n, true
}

// --- The parser ---

@(private="file")
fail :: proc "contextless" (r: ^Reader, rec: ^Record, msg: string) -> Result {
	rec.count = 0
	r.error = msg
	r.error_line = r.line + 1
	return .Error
}

@(private="file")
peek :: proc "contextless" (r: ^Reader) -> int {
	return r.pos < len(r.src) ? int(r.src[r.pos]) : -1
}

@(private="file")
is_space :: proc "contextless" (c: int) -> bool {
	return c == ' ' || c == '\t'
}

@(private="file")
is_control :: proc "contextless" (c: int) -> bool {
	return (c >= 0 && c < 0x20) || c == 0x7f
}

// Skips the rest of the line, including its newline.
@(private="file")
skip_line :: proc "contextless" (r: ^Reader) {
	for r.pos < len(r.src) && r.src[r.pos] != '\n' {
		r.pos += 1
	}
	if r.pos < len(r.src) {
		r.pos += 1
	}
	r.line += 1
}

// Whether the line at pos holds nothing but blanks or a comment.
@(private="file")
line_is_empty :: proc "contextless" (r: ^Reader) -> bool {
	p := r.pos
	for p < len(r.src) && is_space(int(r.src[p])) {
		p += 1
	}
	return p == len(r.src) || r.src[p] == '\n' || r.src[p] == '#'
}

@(private="file")
take_scratch :: proc "contextless" (r: ^Reader, n: int) -> ([]u8, bool) {
	if len(r.scratch) - r.scratch_used < n {
		return nil, false
	}
	s := r.scratch[r.scratch_used:][:n]
	r.scratch_used += n
	return s, true
}

@(private="file")
hex_digit :: proc "contextless" (c: int) -> int {
	switch c {
	case '0' ..= '9':
		return c - '0'
	case 'a' ..= 'f':
		return c - 'a' + 10
	case 'A' ..= 'F':
		return c - 'A' + 10
	}
	return -1
}

// A "quoted" value. pos is on the opening quote.
@(private="file")
quoted :: proc "contextless" (r: ^Reader, rec: ^Record, out: ^string) -> Result {
	r.pos += 1
	n := 0
	// First pass: find the end and the decoded length, checking each byte.
	for p := r.pos;; p += 1 {
		if p >= len(r.src) || r.src[p] == '\n' {
			return fail(r, rec, "unterminated quoted value")
		}
		c := int(r.src[p])
		if is_control(c) {
			return fail(r, rec, "control character in a quoted value; use x\"…\"")
		}
		if c == '"' {
			if p + 1 < len(r.src) && r.src[p + 1] == '"' {
				p += 1
				n += 1
				continue
			}
			break
		}
		n += 1
	}
	dst, ok := take_scratch(r, n)
	if !ok {
		return fail(r, rec, "scratch space exhausted")
	}
	k := 0
	for {
		c := r.src[r.pos]
		r.pos += 1
		if c == '"' {
			if peek(r) == '"' {
				r.pos += 1
				dst[k] = '"'
				k += 1
				continue
			}
			break
		}
		dst[k] = c
		k += 1
	}
	if !utf.valid_bytes(dst) {
		return fail(r, rec, "invalid UTF-8 in a quoted value")
	}
	out^ = string(dst)
	return .Record
}

// An x"hex" value. pos is on the x.
@(private="file")
hex :: proc "contextless" (r: ^Reader, rec: ^Record, out: ^string) -> Result {
	r.pos += 2
	start := r.pos
	for r.pos < len(r.src) && hex_digit(int(r.src[r.pos])) >= 0 {
		r.pos += 1
	}
	if peek(r) != '"' {
		return fail(r, rec, "bad hex value")
	}
	digits := r.pos - start
	r.pos += 1
	if digits % 2 != 0 {
		return fail(r, rec, "odd number of digits in a hex value")
	}
	dst, ok := take_scratch(r, digits / 2)
	if !ok {
		return fail(r, rec, "scratch space exhausted")
	}
	for i in 0 ..< digits / 2 {
		hi := hex_digit(int(r.src[start + 2 * i]))
		lo := hex_digit(int(r.src[start + 2 * i + 1]))
		dst[i] = u8(hi << 4 | lo)
	}
	out^ = string(dst)
	return .Record
}

// The tuples on one line, up to and including its newline.
@(private="file")
tuples :: proc "contextless" (r: ^Reader, rec: ^Record) -> Result {
	for {
		for is_space(peek(r)) {
			r.pos += 1
		}
		c := peek(r)
		if c == -1 {
			return .Record
		}
		if c == '\n' || c == '#' {
			skip_line(r)
			return .Record
		}

		start := r.pos
		for {
			c = peek(r)
			if c == -1 || is_space(c) || c == '\n' || c == '=' || c == '"' {
				break
			}
			if is_control(c) {
				return fail(r, rec, "control character in a key")
			}
			r.pos += 1
		}
		t := Tuple{key = r.src[start:r.pos], flag = true}
		if len(t.key) == 0 {
			return fail(r, rec, "empty key")
		}
		if !utf.valid(t.key) {
			return fail(r, rec, "invalid UTF-8 in a key")
		}

		if peek(r) == '=' {
			r.pos += 1
			t.flag = false
			c = peek(r)
			res := Result.Record
			if c == '"' {
				res = quoted(r, rec, &t.value)
			} else if c == 'x' && r.pos + 1 < len(r.src) && r.src[r.pos + 1] == '"' {
				res = hex(r, rec, &t.value)
			} else {
				vstart := r.pos
				for {
					c = peek(r)
					if c == -1 || is_space(c) || c == '\n' {
						break
					}
					if c == '"' {
						return fail(r, rec, "quote inside a bare value")
					}
					if is_control(c) {
						return fail(r, rec, "control character in a value; use x\"…\"")
					}
					r.pos += 1
				}
				t.value = r.src[vstart:r.pos]
				if len(t.value) == 0 {
					return fail(r, rec, "empty bare value; write \"\"")
				}
				if !utf.valid(t.value) {
					return fail(r, rec, "invalid UTF-8 in a value; use x\"…\"")
				}
			}
			if res != .Record {
				return res
			}
		} else if peek(r) == '"' {
			return fail(r, rec, "quote inside a key")
		}

		c = peek(r)
		if c != -1 && !is_space(c) && c != '\n' {
			return fail(r, rec, "junk after a value")
		}
		for &u in rec.tuples[:rec.count] {
			if u.key == t.key {
				return fail(r, rec, "duplicate key")
			}
		}
		if rec.count == MAX_TUPLES {
			return fail(r, rec, "too many tuples in one record")
		}
		rec.tuples[rec.count] = t
		rec.count += 1
	}
}

// --- The writer ---

// A record being written into a caller's buffer. Writing past the end, or a
// key that could not be read back, sets `failed`, and the record must not be
// used: nothing is ever written that would read back differently.
Writer :: struct {
	buf:    []u8,
	len:    int,
	failed: bool,
}

// key=value, in whichever form the value needs.
put :: proc "contextless" (w: ^Writer, key: string, v: string) {
	write_key(w, key)
	out(w, "=")
	printable := utf.valid(v)
	bare := len(v) > 0 && printable
	for i in 0 ..< len(v) {
		if !printable {
			break
		}
		c := int(v[i])
		if is_control(c) {
			printable, bare = false, false
		}
		if c == ' ' || c == '"' {
			bare = false
		}
	}
	switch {
	case bare:
		out(w, v)
	case printable:
		out(w, "\"")
		for i in 0 ..< len(v) {
			out(w, v[i] == '"' ? "\"\"" : v[i:i + 1])
		}
		out(w, "\"")
	case:
		digits := "0123456789abcdef"
		out(w, "x\"")
		for i in 0 ..< len(v) {
			pair := [2]u8{digits[v[i] >> 4], digits[v[i] & 0xf]}
			out(w, string(pair[:]))
		}
		out(w, "\"")
	}
}

put_u64 :: proc "contextless" (w: ^Writer, key: string, value: u64) {
	buf: [20]u8
	i := len(buf)
	v := value
	for {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	put(w, key, string(buf[i:]))
}

put_i64 :: proc "contextless" (w: ^Writer, key: string, value: i64) {
	if value >= 0 {
		put_u64(w, key, u64(value))
		return
	}
	buf: [21]u8
	mag := u64(0) - u64(value)
	i := len(buf)
	for {
		i -= 1
		buf[i] = u8('0' + mag % 10)
		mag /= 10
		if mag == 0 {
			break
		}
	}
	i -= 1
	buf[i] = '-'
	put(w, key, string(buf[i:]))
}

// A bare key: a flag that is set.
flag :: proc "contextless" (w: ^Writer, key: string) {
	write_key(w, key)
}

// Ends the record with its newline. False if the record must not be used.
@(require_results)
end :: proc "contextless" (w: ^Writer) -> bool {
	out(w, "\n")
	return !w.failed
}

// The record written so far.
written :: proc "contextless" (w: ^Writer) -> string {
	return string(w.buf[:w.len])
}

@(private="file")
out :: proc "contextless" (w: ^Writer, s: string) {
	if w.failed || len(w.buf) - w.len < len(s) {
		w.failed = true
		return
	}
	copy(w.buf[w.len:], s)
	w.len += len(s)
}

@(private="file")
write_key :: proc "contextless" (w: ^Writer, key: string) {
	for i in 0 ..< len(key) {
		c := int(key[i])
		if is_space(c) || c == '\n' || c == '=' || c == '"' || is_control(c) {
			w.failed = true
		}
	}
	if len(key) == 0 || key[0] == '#' || !utf.valid(key) {
		w.failed = true
	}
	if w.len > 0 && w.buf[w.len - 1] != '\n' {
		out(w, " ")
	}
	out(w, key)
}
