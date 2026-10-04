// vx:rc, the rc language, on a host of the test's own (tests/host/rctest,
// upstream's rc_test.c host): its programs (echo, cat, wc, true, false,
// exitwith, warn) write into buffers, its files are in memory, and its
// directory has a few names for globbing. Each script's output is compared
// with what rc gives. Upstream's cases, section by section: each section has
// an interpreter of its own, and upstream's checks on what the host saw end
// the sections that open files.
package rc_test

import "core:fmt"
import "core:strings"
import "core:testing"
import rt "../rctest"
import "vx:rc"

// Upstream's test heap, 4 MiB with its interpreter inside.
TEST_HEAP :: 4 << 20 - rt.C_RC_SIZE

Case :: struct {
	script, want: string,
}

shell :: proc(t: ^testing.T) -> ^rt.Bench {
	b := rt.bench_make(TEST_HEAP)
	ok := rc.init(b.sh, b.heap, rt.callbacks(&b.host))
	testing.expect(t, ok)
	return b
}

script :: proc(b: ^rt.Bench, text: string) -> rc.Result {
	clear(&b.host.out)
	clear(&b.host.err)
	return rc.run(b.sh, text)
}

expect_out :: proc(t: ^testing.T, b: ^rt.Bench, text, want: string, loc := #caller_location) {
	res := script(b, text)
	testing.expectf(t, res == .Ok, "script %q: result %v, %s", text, res, rc.err(b.sh), loc = loc)
	testing.expectf(t, string(b.host.out[:]) == want, "script %q: out %q, wanted %q", text, string(b.host.out[:]), want, loc = loc)
}

expect_cases :: proc(t: ^testing.T, b: ^rt.Bench, cases: []Case, loc := #caller_location) {
	for c in cases {
		expect_out(t, b, c.script, c.want, loc)
	}
}

expect_result :: proc(t: ^testing.T, b: ^rt.Bench, text: string, want: rc.Result, loc := #caller_location) {
	res := script(b, text)
	testing.expectf(t, res == want, "script %q: result %v, wanted %v (%s)", text, res, want, rc.err(b.sh), loc = loc)
}

// Every redirection's file let go.
expect_closed :: proc(t: ^testing.T, b: ^rt.Bench, loc := #caller_location) {
	testing.expect(t, b.host.opened > 0, loc = loc)
	testing.expect_value(t, b.host.closed, b.host.opened, loc = loc)
}

@(test)
test_words :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Words, quoting, lists, carets.
	expect_cases(t, b, {
		{"echo hello world", "hello world\n"},
		{"echo 'it''s' '$x'", "it's $x\n"},
		{"x=(a b c); echo $x $#x $x(2) $\"x", "a b c 3 b a b c\n"},
		{"x=(a b c d); echo $x(2-3) $x(3-)", "b c c d\n"},
		{"x=foo; echo $x.c pre^$x a^(b c)", "foo.c prefoo ab ac\n"},
		{"x=b; echo a$x^c", "abc\n"},
		{"x=(1 2); y=(a b); echo $x^$y", "1a 2b\n"},
		{"echo a=b", "a=b\n"},
	})
}

@(test)
test_control :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Control flow.
	expect_cases(t, b, {
		{"if(false) echo no; if not echo yes", "yes\n"},
		{"if(true) echo yes; if not echo no", "yes\n"},
		{"for(i in 1 2 3) echo $i", "1\n2\n3\n"},
		{"x=(a b c); while(! ~ $#x 0) { echo $x(1); x=$x(2-) }", "a\nb\nc\n"},
		{"switch(b){ case a; echo A; case b c; echo BC; case *; echo other }", "BC\n"},
		{"switch(zz){ case a; echo A; case *; echo other }", "other\n"},
		{"if(~ foo f*) echo match", "match\n"},
		{"if(! ~ foo b*) echo nomatch", "nomatch\n"},
		{"true && echo t; false || echo f; false && echo no", "t\nf\n"},
		{"false; echo $status", "false\n"},
		{"exitwith 3 | true; echo $status", "3|\n"},
		{"if(true | true) echo all; if(false | true) echo no", "all\n"}, // | and 0s are true, as in rc
	})
}

@(test)
test_functions :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Functions: $*, $1, dynamic scope, local assignment.
	expect_cases(t, b, {
		{"fn greet { echo hi $1 $#* }; greet bob jo", "hi bob 2\n"},
		{"fn show { echo $x }; x=1; x=2 show; show", "2\n1\n"},
		{"fn f { echo in f }; fn f; f; echo $status", "not found\n"},
	})
}

@(test)
test_substitution :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Command substitution, nested in braces and an if.
	expect_cases(t, b, {
		{"x=`{echo a b}; echo $#x", "2\n"},
		{"if(true) { y=`{echo z}; echo $y }", "z\n"},
		{"x=`:{echo a:b:c}; echo $x(2)", "b\n"},
		{"echo `{for(i in a b) echo $i}", "a b\n"},
		{"fn c { echo $* }; c x `{for(i in a b) echo $i}", "x a b\n"},
	})
}

@(test)
test_redirections :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Redirections and pipes.
	expect_cases(t, b, {
		{"echo data > f; cat < f", "data\n"},
		{"echo more >> f; cat < f", "data\nmore\n"},
		{"{ echo x; echo y } > g; cat < g", "x\ny\n"},
		{"echo one two three | wc", "3\n"},
		{"echo a b | cat | wc", "2\n"},
		{"echo oops >[1=2]; echo fine", "fine\n"},
	})
	// A stage's own files stay open until it runs; its redirections come after
	// the pipe, so >[2=1] follows it, and >f takes the output from it.
	expect_cases(t, b, {
		{"echo data > f; cat < f | wc", "1\n"},
		{"echo a b c | wc > h; cat < h", "3\n"},
		{"warn oops >[2=1] | wc", "1\n"},
		{"echo hi > f | wc; cat < f", "0\nhi\n"},
		{"echo x | echo `{echo a b | wc}", "2\n"}, // the inner pipeline runs its own stages only
	})
	testing.expect(t, !b.host.used_closed)
	expect_closed(t, b)
}

@(test)
test_globbing :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Globbing: marks only where written bare; no match keeps the word.
	expect_cases(t, b, {
		{"echo *.c", "a.c b.c\n"},
		{"echo '*.c' z* ?.h", "*.c z* x.h\n"},
		{"echo dir/*.c", "dir/one.c\n"},
		{"x=*.c; echo $#x", "2\n"},
		{"for(f in *.c) echo $f", "a.c\nb.c\n"},
		{"echo `{for(f in dir/*.c) echo $f}", "dir/one.c\n"},
		{"x='*.c'; echo $x; for(f in '*.c') echo $f", "*.c\n*.c\n"},
	})
}

@(test)
test_scripts :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Scripts: comments, continuations, several lines; . and eval.
	expect_out(t, b, "# a comment\necho a \\\n  b\necho c # another", "a b\nc\n")
	expect_result(t, b, "echo 'echo from dot' > s.rc", .Ok)
	expect_out(t, b, ". s.rc", "from dot\n")
	expect_out(t, b, "eval echo evaluated", "evaluated\n")
	expect_closed(t, b)
}

@(test)
test_refusals :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// What it refuses, and exit.
	expect_result(t, b, "if(", .Incomplete)
	expect_result(t, b, "for(i in a b) {", .Incomplete)
	expect_result(t, b, "echo )", .Syntax)
	testing.expectf(t, strings.contains(rc.err(b.sh), "line 1"), "error %q", rc.err(b.sh))
	expect_result(t, b, "echo 'unterminated", .Incomplete) // more lines may close it
	expect_result(t, b, "echo a \\\n", .Incomplete)
	expect_out(t, b, "echo a\\\nb", "a b\n") // a \ ending a line is white space, mid-word too
	expect_out(t, b, "ifs=() { x=`{echo a b}; echo $#x }", "1\n")
	rc.set_var(b.sh, "0", "myscript")
	expect_out(t, b, "echo $0 $#0", "myscript 1\n")
	{ // Long scripts and switches: run whole, or refused, never cut short.
		text := strings.builder_make(context.temp_allocator)
		for i in 0 ..< 2000 {
			fmt.sbprintf(&text, "x=%d\n", i)
		}
		strings.write_string(&text, "echo $x\n")
		expect_out(t, b, strings.to_string(text), "1999\n")
		strings.builder_reset(&text)
		strings.write_string(&text, "switch(c299){\n")
		for i in 0 ..< 300 {
			fmt.sbprintf(&text, "case c%d\n echo %d\n", i, i)
		}
		strings.write_string(&text, "}\n")
		expect_out(t, b, strings.to_string(text), "299\n")
	}
	expect_result(t, b, "x=() ; echo a^$x", .Failed)
	expect_result(t, b, "fn f { echo }; f | wc", .Ok)
	testing.expectf(t, strings.contains(string(b.host.err[:]), "pipeline"), "err %q", string(b.host.err[:]))
	expect_result(t, b, "echo before; exit 'it failed'; echo after", .Exit)
	testing.expect_value(t, string(b.host.out[:]), "before\n")
	expect_out(t, b, "echo $status", "it failed\n")
	expect_result(t, b, "cat < nosuchfile", .Failed)
	testing.expect_value(t, b.host.closed, b.host.opened) // every redirection's file let go
}

@(test)
test_export :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Variables as a program would get them: a local hides its global.
	expect_result(t, b, "x=global; y=(a b); fn f { exportx }; x=local f", .Ok)
	testing.expect_value(t, string(b.host.exported[:]), "x=local;")
	expect_result(t, b, "exportx", .Ok)
	testing.expect_value(t, string(b.host.exported[:]), "x=global;")
}

@(test)
test_heap :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// The heap gives back what it lent: a long loop runs in it without running out.
	expect_out(t, b, "for(i in 1 2 3 4 5 6 7 8 9 10) { x=`{echo $i $i $i}; y=$x^-; z=$y(1) }; echo $z", "10-\n")
	for _ in 0 ..< 200 {
		_ = script(b, "x=`{echo a b c d e f g}; y=($x $x $x); fn f { echo $y }; f > /dev/null")
	}
	expect_out(t, b, "echo still", "still\n")
}
