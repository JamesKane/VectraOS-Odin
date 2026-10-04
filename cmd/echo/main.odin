// echo: prints its arguments, separated by spaces, and a newline.
package echo

import "vx:rt"

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	for a, i in rt.args() {
		if i > 0 {
			rt.print(" ")
		}
		rt.print(a)
	}
	rt.print("\n")
	return 0
}
