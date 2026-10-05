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

// A result, and an error that says why.
expect_err :: proc(t: ^testing.T, b: ^rt.Bench, text: string, want: rc.Result, why: string, loc := #caller_location) {
	expect_result(t, b, text, want, loc)
	testing.expectf(t, strings.contains(rc.err(b.sh), why), "script %q: error %q, wanted %q in it", text, rc.err(b.sh), why, loc = loc)
}

// $status's first word.
status_now :: proc(b: ^rt.Bench) -> string {
	w := rc.get_var(b.sh, "status")
	return w != nil ? rc.text(w) : ""
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
	})
	expect_result(t, b, "echo a=b", .Syntax) // = is not a word, as rc's
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
	expect_err(t, b, "echo )", .Syntax, "rc:1: ")
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

// 9front's rc, as its rc(1) and source have it (upstream's M6 step 6a6a):
// each line is one of the differences a survey found, now the same.
@(test)
test_9front :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// Syntax rc's grammar refuses.
	expect_result(t, b, "echo a(b c)", .Syntax)
	expect_result(t, b, "not echo x", .Syntax)
	expect_result(t, b, "in", .Syntax)
	expect_err(t, b, "y=(a b); echo $$y", .Failed, "$ variable name not singleton!")
	expect_err(t, b, "y=(a b); $y=1", .Failed, "= variable name not singleton!")
	expect_cases(t, b, {
		{"x=1; echo for$x", "for 1\n"}, // no caret after a keyword
		{"echo for in not", "for in not\n"},
		// ~ and switch match the list as one word; ~ with no patterns does not match.
		{"x=(a b); if(~ $x 'a b') echo joined", "joined\n"},
		{"if(~ () '') echo empty", "empty\n"},
		{"if(! ~ ()) echo none", "none\n"},
		{"x=(a b); switch($x){case a; echo A; case 'a b'; echo AB}", "AB\n"},
		{"switch(){case ''; echo empty}", "empty\n"},
	})
	expect_err(t, b, "switch(a){echo x; case a; echo A}", .Syntax, "case missing in switch")
	expect_out(t, b, "switch(a){case a; echo A; 'case' b; echo B}", "A\nB\n") // a quoted case is a command
	// if not follows an if, or is refused when compiled.
	expect_err(t, b, "if not echo x", .Syntax, "`if not' does not follow `if(...)'")
	expect_result(t, b, "if(false) echo a; echo mid; if not echo b", .Syntax)
	expect_out(t, b, "if(false) echo a\nif not echo b", "b\n")
	expect_result(t, b, "if(false) echo a; if not echo b; if not echo c", .Syntax) // an if not ends iflast
	expect_out(t, b, "x=y; $x=hello; echo $y", "hello\n") // a name from a variable
	// while() is true; ^ of two empty lists is empty, of one an error.
	expect_result(t, b, "false; while(){ echo once; exit }", .Exit)
	testing.expect_value(t, string(b.host.out[:]), "once\n")
	expect_out(t, b, "x=(); y=(); echo a $x^$y b", "a b\n")
	expect_err(t, b, "x=(); echo a^$x", .Failed, "null list in concatenation")
	expect_err(t, b, "x=(1 2 3); y=(a b); echo $x^$y", .Failed, "mismatched list lengths")
	expect_cases(t, b, {
		// Subscripts as rc's subwords; $1(...) is a variable named 1's.
		{"x=(a b c); echo $x(0-2) . $x(2x) . $x(3-1) . $x(2-9)", ". b . . b c\n"},
		{"fn f { echo $1(1) $#1 $#3 }; f a b", "1 0\n"},
		// $ifs of several words: joined by spaces, so a space separates too.
		{"ifs=(: ';'); x=`{echo 'a:b;c d'}; echo $#x", "4\n"},
	})
	// An empty command is an error.
	expect_err(t, b, "x=(); $x", .Failed, "empty argument list")
	expect_cases(t, b, {
		// A pipeline's status, as concstatus; truth by the first word.
		{"exitwith '' | exitwith 3; echo $status", "3\n"},
		{"exitwith 3 | exitwith ''; echo $status", "3|\n"},
		{"fn t { status=('' no) }; if(t) echo first", "first\n"},
		// Functions are global: a local of the same name does not hide one.
		{"fn f { echo F }; f=1 f", "F\n"},
	})
	expect_result(t, b, "fn g { echo G }; g &", .Ok)
	testing.expect_value(t, string(b.host.out[:]), "")
	testing.expect_value(t, status_now(b), "async")
	expect_cases(t, b, {
		// Globbing: . and .. alone need an explicit dot; a plain name after a
		// pattern must exist; ? and classes match runes; ranges either way round.
		{"echo *", ".hidden a.c b.c dir x.h\n"},
		{"echo */one.c", "dir/one.c\n"},
		{"echo */nosuch", "*/nosuch\n"},
		{"if(~ \xc3\xa9 ?) echo rune", "rune\n"},
		{"if(~ b [c-a]) echo reversed", "reversed\n"},
		{"if(~ \xc3\xa9 [\xc3\xa0-\xc3\xaf]) echo class", "class\n"},
		{"echo a\x01b; if(~ a\x01b a\x01b) echo same", "a\x01b\nsame\n"}, // the glob byte, itself
		// A block's redirection is the whole block's; a failed one says rc's way.
		{"echo data > f; { cat; cat } < f", "data\ndata\n"},
	})
	expect_err(t, b, "cat < nosuchfile", .Failed, "rc:1: < can't open: nosuchfile")
	expect_result(t, b, "echo x >\n", .Syntax)
	// A syntax error's message is $status, as rc's yyerror.
	expect_result(t, b, "echo )", .Syntax)
	testing.expect(t, status_now(b) != "")
	testing.expectf(t, strings.contains(rc.err(b.sh), status_now(b)), "error %q, status %q", rc.err(b.sh), status_now(b))
}

// What the shell wrote on its standard error contains want.
expect_errout :: proc(t: ^testing.T, b: ^rt.Bench, want: string, loc := #caller_location) {
	testing.expectf(t, strings.contains(string(b.host.err[:]), want), "standard error %q, wanted %q in it", string(b.host.err[:]), want, loc = loc)
}

// The second part (upstream's M6 step 6a6b): reading a command at a time,
// here documents, flag and the flags it sets, ., eval, and interactive input.
@(test)
test_9front_reading :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	// A script runs as it is read: a syntax error stops at its line, the lines
	// before it run.
	expect_result(t, b, "echo ok\necho )\necho after", .Syntax)
	testing.expect_value(t, string(b.host.out[:]), "ok\n")
	// Here documents: substituted unless the tag is quoted; several on a line,
	// in order; a block's; [n]; one that never ends asks for more.
	expect_cases(t, b, {
		{"x=(a b); cat <<EOF\nv=$x $$x $x^y\nEOF\n", "v=a b $x a by\n"},
		{"cat <<'EOF'\nraw $x\nEOF\n", "raw $x\n"},
		{"fn f { cat <<EOF\n$1 $2\nEOF\n}; f p q", "p q\n"},
		{"cat <<A; cat <<B\none\nA\ntwo\nB\n", "one\ntwo\n"},
		{"{ cat } <<EOF\nblock\nEOF\n", "block\n"},
		{"cat <<[0]EOF\nzero\nEOF\n", "zero\n"},
	})
	expect_result(t, b, "cat <<EOF\nnever ends\n", .Incomplete)
	// Descriptors of more digits lex, and past the ones there are, are refused.
	expect_result(t, b, "echo x >[10] f\n", .Syntax)
	// flag, and what the flags do.
	expect_out(t, b, "flag z; echo $status", "flag not set\n")
	expect_err(t, b, "flag", .Failed, "Usage: flag [letter] [+-]")
	expect_result(t, b, "flag x +\necho hi 'a b'\nflag x -", .Ok)
	expect_errout(t, b, "echo hi 'a b'\n")
	expect_result(t, b, "flag e +\nif(false) echo no\necho yes\nfalse\necho never\n", .Exit)
	testing.expect_value(t, string(b.host.out[:]), "yes\n")
	_ = script(b, "flag e -")
	expect_result(t, b, "flag s +\nfalse\nflag s -", .Ok)
	expect_errout(t, b, "status=false\n")
	expect_result(t, b, "flag v +\necho v\nflag v -", .Ok)
	expect_errout(t, b, "echo v\n")
	expect_result(t, b, "flag r +\ntrue\nflag r -", .Ok)
	expect_errout(t, b, "Xsimple")
	// .: $0 and $*, $path, -q; refused with no file, or one not there.
	expect_result(t, b, "echo 'echo $0 $* $#*' > d.rc", .Ok)
	expect_out(t, b, ". d.rc a b", "d.rc a b 2\n")
	expect_out(t, b, "path=(/x .); . d.rc z", "d.rc z 1\n")
	expect_out(t, b, ". -q nofile; echo q", "q\n")
	expect_err(t, b, ". nofile", .Failed, ". can't open: nofile: file does not exist")
	expect_err(t, b, ".", .Failed, "Usage: . [-biq] file [arg ...]")
	expect_result(t, b, "echo 'echo first' > bad.rc; echo 'echo )' >> bad.rc", .Ok)
	expect_err(t, b, ". bad.rc", .Syntax, "bad.rc:2:")
	testing.expect_value(t, string(b.host.out[:]), "first\n")
	_ = script(b, "path=()")
	// eval.
	expect_err(t, b, "eval", .Failed, "Usage: eval cmd ...")
	expect_out(t, b, "eval 'y=5'; echo $y", "5\n")
	expect_err(t, b, "eval 'echo )'", .Syntax, "*eval*")
	// Interactive: prompts on rc's standard error; an error goes back to it,
	// and the next line runs.
	b.host.stdin, b.host.stdin_at = "x=(); echo a^$x\necho two\n", 0
	expect_out(t, b, ". -i '#d/0'", "two\n")
	expect_errout(t, b, "% ")
	expect_errout(t, b, "null list")
	b.host.stdin, b.host.stdin_at = "prompt=('> ' '>> ')\nif(true) {\necho in\n}\n", 0
	expect_out(t, b, ". -i '#d/0'", "in\n")
	expect_errout(t, b, ">> ")
	_ = script(b, "prompt=()")
	b.host.stdin, b.host.stdin_at = "echo s1\nx=(); echo a^$x\necho s2\n", 0 // not interactive: an error ends it
	expect_result(t, b, ". '#d/0'", .Failed)
	testing.expect_value(t, string(b.host.out[:]), "s1\n")
	b.host.stdin = ""
}
