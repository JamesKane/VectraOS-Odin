// tail [-N] [file]: prints the last N lines (10 unless given) of the file,
// or of standard input.
package tail

import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

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
vx_main :: proc() -> int {
	args := rt.args()
	lines := u64(10)
	if len(args) > 0 && len(args[0]) > 1 && args[0][0] == '-' {
		n, ok := str.parse_u64(args[0][1:])
		// The digits stop being taken once they make more than 100000, so
		// the largest count is 1000009.
		if !ok || n / 10 > 100_000 {
			rt.print("usage: tail [-N] [file]\n")
			return 1
		}
		lines = n
		args = args[1:]
	}
	if len(args) > 0 {
		f: ns.File
		if procns.from_spawn(&space) != .Ok || ns.open(&space, args[0], p9.OREAD, &f) != .Ok {
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
	// What is left of the ring from start is at most two runs: to the end of
	// the buffer, then from its beginning.
	from := int(start % len(text))
	count := int(total - start)
	first := min(count, len(text) - from)
	rt.print(string(text[from:][:first]), string(text[:count - first]))
	return 0
}
