// cat: prints each file named, in its namespace, or standard input without
// arguments.
package cat

import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

buf: [4096]u8
space: ns.Namespace

@(export, link_name="vx_main")
main :: proc() -> int {
	exit_status := 0
	if len(rt.args()) == 0 {
		for {
			n, st := rt.read(buf[:])
			if n <= 0 {
				return st != .Ok ? 1 : 0
			}
			rt.print(string(buf[:n]))
		}
	}
	if procns.from_spawn(&space) != .Ok {
		return 1
	}
	for name in rt.args() {
		f: ns.File
		st := ns.open(&space, name, p9.OREAD, &f)
		opened := st == .Ok
		for st == .Ok {
			n, rst := ns.read(&f, buf[:])
			if n <= 0 {
				st = rst
				break
			}
			rt.print(string(buf[:n]))
		}
		if opened {
			ns.close(&f)
		}
		if st != .Ok {
			rt.print("cat: ", name, ": ", p9.error_text(st), "\n")
			exit_status = 1
		}
	}
	return exit_status
}
