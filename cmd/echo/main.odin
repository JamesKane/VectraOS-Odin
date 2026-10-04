// echo: prints its arguments, separated by spaces, and a newline.
package echo

import "vx:rt"

// The program ends with run's exit string, as upstream's programs return
// theirs: empty for success (ADR-0010).
@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	for a, i in rt.args() {
		if i > 0 {
			rt.print(" ")
		}
		rt.print(a)
	}
	rt.print("\n")
	return ""
}
