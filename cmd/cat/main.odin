// cat: prints each file named, in its namespace, or standard input without
// arguments.
package cat

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

buf: [4096]u8
space: ns.Namespace

// Prints one file, to its end or the first failure.
@(require_results)
print_file :: proc(name: string) -> vx.Status {
	f: ns.File
	ns.open(&space, name, p9.OREAD, &f) or_return
	defer ns.close(&f)
	for {
		n := ns.read(&f, buf[:]) or_return
		if n == 0 {
			return .Ok
		}
		rt.print(string(buf[:n]))
	}
}

// The program ends with run's exit string, as upstream's programs return
// theirs: empty for success (ADR-0010).
@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	exit := ""
	if len(rt.args()) == 0 {
		for {
			n, st := rt.read(buf[:])
			if n <= 0 {
				return st != .Ok ? "read error" : ""
			}
			rt.print(string(buf[:n]))
		}
	}
	if procns.from_spawn(&space) != .Ok {
		return "no namespace"
	}
	for name in rt.args() {
		if st := print_file(name); st != .Ok {
			rt.eprint("cat: ", name, ": ", p9.error_text(st), "\n")
			exit = "error"
		}
	}
	return exit
}
