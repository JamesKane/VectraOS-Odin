// constest: the console test, run as a service in the cons scenario
// (tests/qemu/m2/cons.ndb). It reads cooked lines from the console driver
// and prints each back in brackets; "flood" makes it print more than the
// driver's output queue holds, so writes must wait for the UART; end of file
// ends it.
package constest

import "vx:rt"

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.print("constest: ready\n")
	line: [300]u8
	for {
		n, st := rt.console_read(line[:])
		if n == 0 && st == .Ok {
			break
		}
		if st != .Ok {
			rt.print("constest: FAILED to read the console\n")
			return 1
		}
		length := n
		if length > 0 && line[length - 1] == '\n' {
			length -= 1
		}
		rt.print("constest: got [", string(line[:length]), "]\n")
		if string(line[:length]) == "flood" {
			for i in u64(0) ..< 300 {
				rt.print("constest: line ", i, " ......................................\n")
			}
			rt.print("constest: flood done\n")
		}
	}
	rt.print("constest: end of file\n")
	return 0
}
