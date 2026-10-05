// What the Odin interface adds to upstream's: the checks a host such as the shell (cmd/rc)
// relies on that upstream's tests reach only through its C API.
package rc_test

import "base:runtime"
import "core:testing"
import rt "../rctest"
import "vx:rc"

@(test)
test_init :: proc(t: ^testing.T) {
	sh := new(rc.Rc)
	defer free(sh)
	small := make([]u8, rc.MIN_HEAP / 2)
	defer delete(small)
	testing.expect(t, !rc.init(sh, small, {}))
	b := shell(t)
	defer rt.bench_destroy(b)
	// A new interpreter: $ifs is blank, tab and newline; $status success.
	w := rc.get_var(b.sh, "ifs")
	got, ok := rc.next_word(&w)
	testing.expect(t, ok)
	testing.expect_value(t, got, " \t\n")
	testing.expect(t, w == nil)
	status := rc.get_var(b.sh, "status")
	testing.expect(t, status != nil)
	testing.expect_value(t, rc.text(status), "")
}

@(test)
test_vars :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	rc.set_var(b.sh, "list", "a", "b c", "")
	expect_out(t, b, "echo $#list $list(2)", "3 b c\n")
	rc.set_var(b.sh, "list")
	expect_out(t, b, "echo $#list", "0\n")
	// A name is read as upstream's C API reads it: to its first NUL.
	rc.set_var(b.sh, "nul\x00ignored", "v")
	expect_out(t, b, "echo $nul", "v\n")
	testing.expect(t, rc.get_var(b.sh, "nul\x00other") != nil)
	// The variables a program would see: each once, a local hiding its global.
	expect_result(t, b, "x=global; y=(1 2); fn f { exportx }; x=local f", .Ok)
	log := string(b.host.log[:])
	testing.expect(t, count(log, "  var [x]") == 1)
	testing.expect(t, count(log, "  var [x][local]") == 1)
	testing.expect(t, count(log, "  var [y][1][2]") == 1)
	testing.expect(t, count(log, "  var [list]") == 0) // no value: not exported
}

count :: proc(s, sub: string) -> int {
	n := 0
	for i := 0; i + len(sub) <= len(s); i += 1 {
		if s[i:][:len(sub)] == sub {
			n += 1
		}
	}
	return n
}

// A stage's file keeps its path until the stage has run: upstream frees the
// path when the redirection is undone, before its pipeline runs.
@(test)
test_stage_path :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	b.sh.host.run = proc "contextless" (ctx: rawptr, r: ^rc.Rc, stages: []rc.Command, async: bool) -> (pid: u64, ok: bool) {
		context = runtime.default_context()
		h := (^rt.Host)(ctx)
		for &c in stages {
			for fd in c.fds {
				if f, is := fd.(rc.Fd_File); is {
					append(&h.out, f.path)
					append(&h.out, ' ')
				}
			}
		}
		rc.set_status(r, "")
		return 0, true
	}
	expect_out(t, b, "echo x > first; cat < first >> second | wc > third", "first first second third ") // the plain command's, then each stage's
	testing.expect_value(t, b.host.closed, b.host.opened)
}

// Output a program writes to anything but a capture is not the shell's.
@(test)
test_capture_write :: proc(t: ^testing.T) {
	b := shell(t)
	defer rt.bench_destroy(b)
	rc.capture_write(b.sh, rc.Fd_Capture{0}, "lost") // no capture open
	rc.capture_write(b.sh, rc.Fd_Inherit{1}, "lost")
	expect_out(t, b, "x=`{echo a; echo b}; echo $#x $x", "2 a b\n")
}
