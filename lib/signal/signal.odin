// vx:signal, what the POSIX personality's pieces share (upstream docs/01 §9):
// the musl back end, which builds signals on notes, procfs, which carries out
// the ones a process cannot (SIGKILL, SIGSTOP, SIGCONT), and ptyd, which sends
// a terminal's to its foreground group. The process calls themselves are files
// in /proc (ADR-0011).
//
// Signals are notes (ADR-0010). A signal another process sends (kill) is the
// note "posix: SIGTERM pid=12", which names the sender; one with Plan 9 words
// of its own, from the system, is a Plan 9 note ("interrupt", "hangup",
// "alarm", "sys: write on closed pipe", "sys: trap: ..."). Both map back to
// the signal here, as do the exit strings a process ends with: "killed" is
// SIGKILL's. Signal numbers are Linux's, as musl's are.
package signal

import "vx:note"
import "vx:str"

Signal :: distinct i64

SIGHUP :: Signal(1)
SIGINT :: Signal(2)
SIGQUIT :: Signal(3)
SIGILL :: Signal(4)
SIGTRAP :: Signal(5)
SIGBUS :: Signal(7)
SIGFPE :: Signal(8)
SIGKILL :: Signal(9)
SIGSEGV :: Signal(11)
SIGPIPE :: Signal(13)
SIGALRM :: Signal(14)
SIGTERM :: Signal(15)
SIGCHLD :: Signal(17)
SIGCONT :: Signal(18)
SIGSTOP :: Signal(19)
SIGURG :: Signal(23)
SIGWINCH :: Signal(28)
NSIG :: Signal(64)

// The names of signals 1 to 31; 0 has none.
SIGNAMES := [32]string {
	"",
	"SIGHUP",
	"SIGINT",
	"SIGQUIT",
	"SIGILL",
	"SIGTRAP",
	"SIGABRT",
	"SIGBUS",
	"SIGFPE",
	"SIGKILL",
	"SIGUSR1",
	"SIGSEGV",
	"SIGUSR2",
	"SIGPIPE",
	"SIGALRM",
	"SIGTERM",
	"SIGSTKFLT",
	"SIGCHLD",
	"SIGCONT",
	"SIGSTOP",
	"SIGTSTP",
	"SIGTTIN",
	"SIGTTOU",
	"SIGURG",
	"SIGXCPU",
	"SIGXFSZ",
	"SIGVTALRM",
	"SIGPROF",
	"SIGWINCH",
	"SIGIO",
	"SIGPWR",
	"SIGSYS",
}

// A Plan 9 note that is a signal, or with prefix, the start of a trap note.
@(private="file")
Plan9_Note :: struct {
	note:   string,
	sig:    Signal,
	prefix: bool,
}

// The table, in the order it is searched: the first match wins.
@(private="file")
PLAN9_NOTES := [?]Plan9_Note {
	{"hangup", SIGHUP, false},
	{"interrupt", SIGINT, false},
	{"alarm", SIGALRM, false},
	{"sys: write on closed pipe", SIGPIPE, false},
	{"killed", SIGKILL, false},
	{"sys: trap: fault ", SIGSEGV, true},
	{"sys: trap: general fault", SIGSEGV, true},
	{"sys: trap: illegal instruction", SIGILL, true},
	{"sys: trap: fp disabled", SIGILL, true},
	{"sys: trap: arithmetic", SIGFPE, true},
	{"sys: trap: misaligned", SIGBUS, true},
	{"sys: trap: page not supplied", SIGBUS, true}, // a pager that did not answer in time
	{"sys: breakpoint", SIGTRAP, true},
	{"sys: trap: step", SIGTRAP, true},
}

// The note for signal sig, written into out: from a sender (a pid), "posix:
// NAME pid=N"; from the system (sender 0), its Plan 9 words if it has them,
// else "posix: NAME". A signal with no name is "SIGn".
signal_note :: proc "contextless" (sig: Signal, sender: i64, out: ^[note.ERRMAX]u8) -> string {
	b := note.Buf {
		buf = out[:],
	}
	if sender == 0 && sig != SIGKILL {
		for &n in PLAN9_NOTES {
			if n.sig == sig && !n.prefix {
				note.put(&b, n.note)
				return note.to_string(&b)
			}
		}
	}
	note.put(&b, "posix: ")
	if sig > 0 && sig < 32 {
		note.put(&b, SIGNAMES[sig])
	} else {
		note.put(&b, "SIG")
		note.put_dec(&b, u64(sig))
	}
	if sender > 0 {
		note.put(&b, " pid=")
		note.put_dec(&b, u64(sender))
	}
	return note.to_string(&b)
}

// The signal a note or exit string stands for, and who sent it (0 if it does
// not say); ok is false if it is no signal.
note_signal :: proc "contextless" (s: string) -> (sig: Signal, sender: i64, ok: bool) {
	for &n in PLAN9_NOTES {
		if n.prefix ? str.has_prefix(s, n.note) : s == n.note {
			return n.sig, 0, true
		}
	}
	if !str.has_prefix(s, "posix: SIG") {
		return 0, 0, false
	}
	at := len("posix: ") // the name, from "SIG"
	end := at
	for end < len(s) && s[end] != ' ' {
		end += 1
	}
	name := s[at:end]
	for i in 1 ..< len(SIGNAMES) {
		if SIGNAMES[i] == name {
			sig = Signal(i)
			break
		}
	}
	if sig == 0 && len(name) > 3 && len(name) < 6 { // SIG34: a number, for those with no name
		j := 3
		v: i64
		for j < len(name) && name[j] >= '0' && name[j] <= '9' {
			v = v * 10 + i64(name[j] - '0')
			j += 1
		}
		if j == len(name) && v > 0 && v <= i64(NSIG) {
			sig = Signal(v)
		}
	}
	if sig == 0 {
		return 0, 0, false
	}
	rest := s[end:]
	if len(rest) > 5 && str.has_prefix(rest, " pid=") {
		// 18 digits at most: no overflow, whatever the sender wrote.
		for j := 5; j < len(rest) && j < 5 + 18 && rest[j] >= '0' && rest[j] <= '9'; j += 1 {
			sender = sender * 10 + i64(rest[j] - '0')
		}
	}
	return sig, sender, true
}

// The wait status of a process that ended with this exit string, as
// WEXITSTATUS and WTERMSIG read it: empty is exit code 0; a number is that
// exit code (its low byte), as exit(n) writes it; a signal's note is that
// signal; anything else is exit code 1.
wait_status :: proc "contextless" (exit: string) -> i64 {
	if len(exit) == 0 {
		return 0
	}
	code: i64
	i := 0
	for i < len(exit) && exit[i] >= '0' && exit[i] <= '9' && i < 19 {
		code = code * 10 + i64(exit[i] - '0')
		i += 1
	}
	if i == len(exit) {
		return (code & 0xff) << 8
	}
	if sig, _, ok := note_signal(exit); ok {
		return i64(sig)
	}
	return 1 << 8
}

// Whether sig's default is to be ignored; every other one's ends the process
// (stopping waits for job control, with ptyd).
default_ignored :: proc "contextless" (sig: Signal) -> bool {
	return sig == SIGCHLD || sig == SIGCONT || sig == SIGURG || sig == SIGWINCH
}
