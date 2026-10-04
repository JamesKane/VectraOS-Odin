// ns: prints the namespace it was given, its parent's, as a script of mount
// and bind lines that would rebuild it.
package nscmd

import "vx:ns"
import "vx:procns"
import "vx:rt"

space: ns.Namespace
text: [8192]u8

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		return 1
	}
	n := ns.print(&space, text[:])
	rt.print(string(text[:n]))
	return n > 0 ? 0 : 1
}
