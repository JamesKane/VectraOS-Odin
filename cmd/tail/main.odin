// tail [-N] [file]: prints the last N lines (10 unless given) of the file,
// or of standard input.
package tail

import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

text: [64 * 1024]u8 // the end of the input, as a ring
total: u64
buf: [4096]u8
space: ns.Namespace

take :: proc "contextless" (p: []u8) {
	for b in p {
		text[total % len(text)] = b
		total += 1
	}
}

@(export, link_name="vx_main")
main :: proc() -> int {
	lines := u64(10)
	arg := 0
	if len(rt.args()) > 0 && len(rt.spawn.args[0]) > 1 && rt.spawn.args[0][0] == '-' {
		lines = 0
		for c in transmute([]u8)rt.spawn.args[0][1:] {
			if c < '0' || c > '9' || lines > 100000 {
				rt.print("usage: tail [-N] [file]\n")
				return 1
			}
			lines = lines * 10 + u64(c - '0')
		}
		arg = 1
	}
	if arg < len(rt.args()) {
		f: ns.File
		if procns.from_spawn(&space) != .Ok || ns.open(&space, rt.spawn.args[arg], p9.OREAD, &f) != .Ok {
			rt.print("tail: cannot open it\n")
			return 1
		}
		for {
			n, _ := ns.read(&f, buf[:])
			if n <= 0 {
				break
			}
			take(buf[:n])
		}
		ns.close(&f)
	} else {
		for {
			n, _ := rt.read(buf[:])
			if n <= 0 {
				break
			}
			take(buf[:n])
		}
	}
	// Back from the end to the start of the last `lines` lines: past that
	// many newlines, not counting one that ends the input.
	floor := total < len(text) ? 0 : total - len(text)
	start, seen := total, u64(0)
	for lines > 0 && start > floor {
		if start != total && text[(start - 1) % len(text)] == '\n' {
			seen += 1
			if seen == lines {
				break
			}
		}
		start -= 1
	}
	for i in start ..< total {
		rt.print(string(text[i % len(text):][:1]))
	}
	return 0
}
