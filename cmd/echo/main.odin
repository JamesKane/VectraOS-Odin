// echo: prints its arguments, separated by spaces, and a newline.
package echo

import "vx:rt"

@(export, link_name="vx_main")
main :: proc() -> int {
	for i in 0 ..< rt.spawn.argc {
		if i > 0 {
			rt.print(" ")
		}
		rt.print(rt.spawn.args[i])
	}
	rt.print("\n")
	return 0
}
