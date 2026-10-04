// svcd: the root task, which starts and restarts the system's services. For
// now, it says hello from user space.
package svcd

import "vx:rt"

@(export, link_name="vx_main")
main :: proc() -> int {
	info, st := rt.task_info(rt.self)
	if st != .Ok {
		rt.print("svcd: cannot read its own task\n")
		return 1
	}
	rt.print("svcd: hello from user space (task ")
	rt.print_u64(info.id)
	rt.print(")\n")
	return 0
}
