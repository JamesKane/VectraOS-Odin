// lib/signal against upstream's vx-signal. Upstream has no host test of its
// own for it; upstream.txt is what upstream's posix_note, posix_note_signal,
// posix_wait_status and posix_default_ignored print for the same inputs,
// from a harness built with clang against M4's headers (the P4 cross-check),
// and each line here must match it.
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
