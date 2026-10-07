// pwd: prints the current directory (ADR-0017, upstream's ADR-0039), as
// 9front's pwd.
package pwd

import "vx:rt"
import usage "gen:usage/pwd"

// The program ends with run's exit string, as upstream's programs return
// theirs: empty for success (ADR-0010).
@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	if len(rt.args()) != 0 {
		rt.eprint(usage.TEXT, "\n")
		return "usage"
	}
	wd: [rt.WD_MAX]u8
	rt.print(rt.getwd(wd[:]), "\n")
	return ""
}
