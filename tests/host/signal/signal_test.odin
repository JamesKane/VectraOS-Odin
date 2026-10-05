// lib/signal against upstream's vx-signal. Upstream has no host test of its
// own for it; upstream.txt is what upstream's posix_note, posix_note_signal,
// posix_wait_status and posix_default_ignored print for the same inputs,
// from a harness built with clang against M4's headers (the P4 cross-check;
// made again at upstream's f9c14e9 with the page-not-supplied and
// protection-key notes), and each line here must match it.
package signal_test

import "core:fmt"
import "core:strings"
import "core:testing"
import "vx:note"
import "vx:signal"

UPSTREAM := #load("upstream.txt", string)

// The notes and exit strings the harness maps back to signals.
NOTES := []string {
	"",
	"hangup",
	"hangup ",
	"interrupt",
	"alarm",
	"sys: write on closed pipe",
	"killed",
	"sys: trap: fault read addr=0x0 pc=0x401000",
	"sys: trap: fault ",
	"sys: trap: fault",
	"sys: trap: general fault",
	"sys: trap: illegal instruction pc=0x1",
	"sys: trap: fp disabled pc=0x2",
	"sys: trap: arithmetic pc=0x3",
	"sys: trap: misaligned addr=0x8 pc=0x4",
	"sys: breakpoint pc=0x5",
	"sys: trap: step pc=0x6",
	"sys: trap: page not supplied addr=0x1000 pc=0x7",
	"sys: trap: protection key write addr=0x2000 pc=0x8",
	"sys: trap: protection key read addr=0x2000 pc=0x9",
	"sys: trap: protection key",
	"posix: SIGTERM",
	"posix: SIGTERM pid=12",
	"posix: SIGTERM pid=",
	"posix: SIGTERM pid=1x",
	"posix: SIGTERM pid=123456789012345678901234",
	"posix: SIGTERMX pid=12",
	"posix: SIG34",
	"posix: SIG34 pid=7",
	"posix: SIG64",
	"posix: SIG65",
	"posix: SIG0",
	"posix: SIG",
	"posix: SIG1234",
	"posix: SIGKILL",
	"posix: SIGHUP",
	"posix: sigterm",
	"posix:SIGTERM",
	"0",
	"1",
	"255",
	"256",
	"257",
	"12345678901234567890123",
	"1a",
	"error",
	"interrupted",
}

@(test)
test_against_upstream :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	senders := []i64{0, 12, -3}
	for sig in signal.Signal(-1) ..= 66 {
		for sender in senders {
			out: [note.ERRMAX]u8
			fmt.sbprintf(&b, "note %d %d %s\n", i64(sig), sender, signal.signal_note(sig, sender, &out))
		}
	}
	for n in NOTES {
		sig, sender, _ := signal.note_signal(n)
		fmt.sbprintf(&b, "signal [%s] %d %d %d\n", n, i64(sig), sender, signal.wait_status(n))
	}
	for sig in signal.Signal(0) ..= 65 {
		fmt.sbprintf(&b, "ignored %d %d\n", i64(sig), signal.default_ignored(sig) ? 1 : 0)
	}
	got, want := strings.to_string(b), UPSTREAM
	line := 0
	for {
		gl, gok := strings.split_lines_iterator(&got)
		wl, wok := strings.split_lines_iterator(&want)
		line += 1
		if !gok && !wok {
			break
		}
		if !testing.expectf(t, gl == wl, "line %d: got %q, upstream has %q", line, gl, wl) {
			break
		}
	}
}

@(test)
test_round_trip :: proc(t: ^testing.T) {
	// A signal sent by a process comes back as itself, with its sender.
	for sig in signal.Signal(1) ..= signal.NSIG {
		out: [note.ERRMAX]u8
		s := signal.signal_note(sig, 99, &out)
		got, sender, ok := signal.note_signal(s)
		testing.expectf(t, ok, "%s is no signal", s)
		testing.expectf(t, got == sig, "%s is signal %d, not %d", s, got, sig)
		testing.expectf(t, sender == 99, "%s was sent by %d", s, sender)
	}
}

// Upstream's posix_test.c (M6 step 6b): each note and exit string to the
// signal it stands for and its sender, and the wait status a parent sees, a
// pager's timeout among them (SIGBUS).
@(test)
test_posix :: proc(t: ^testing.T) {
	Case :: struct {
		note:   string,
		sig:    signal.Signal, // 0: no signal
		sender: i64,
	}
	cases := []Case {
		{"posix: SIGTERM pid=12", signal.SIGTERM, 12},
		{"interrupt", signal.SIGINT, 0},
		{"sys: trap: arithmetic pc=0x401000", signal.SIGFPE, 0},
		{"sys: trap: page not supplied addr=0x7000 pc=0x401000", signal.SIGBUS, 0},
		{"no such thing", 0, 0},
	}
	for c in cases {
		sig, sender, _ := signal.note_signal(c.note)
		testing.expectf(t, sig == c.sig, "%q: signal %d, want %d", c.note, sig, c.sig)
		testing.expectf(t, sender == c.sender, "%q: sender %d, want %d", c.note, sender, c.sender)
	}

	Status_Case :: struct {
		exit: string,
		want: i64,
	}
	statuses := []Status_Case {
		{"", 0},
		{"3", 3 << 8},
		{"sys: trap: page not supplied addr=0x7000 pc=0x401000", i64(signal.SIGBUS)},
		{"killed", i64(signal.SIGKILL)},
		{"cannot open", 1 << 8},
	}
	for c in statuses {
		got := signal.wait_status(c.exit)
		testing.expectf(t, got == c.want, "%q: wait status %d, want %d", c.exit, got, c.want)
	}

	out: [note.ERRMAX]u8
	testing.expect_value(t, signal.signal_note(signal.SIGQUIT, 0, &out), "posix: SIGQUIT") // ^\ at a terminal: no Plan 9 words
}
