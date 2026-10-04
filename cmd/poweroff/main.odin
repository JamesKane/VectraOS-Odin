// poweroff: the machine off (M5 step 7c), by asking bus-acpi on /srv/acpi,
// which enters S5 through ACPICA, or has devmgr make the PSCI call where the
// firmware's ACPI cannot. Its connector is the spawn message's srv:acpi (a
// manifest's connect=acpi), else /srv/acpi in its namespace. It returns only
// if the machine is still on.
package poweroff

import vx "abi:vx"
import "vx:acpi"
import "vx:ns"
import "vx:procns"
import "vx:rt"

space: ns.Namespace

@(export, link_name = "vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	c := rt.spawn_take("srv:acpi")
	if c == vx.HANDLE_NONE && procns.from_spawn(&space) == .Ok {
		c = ns.connector(&space, "/srv/acpi")
	}
	if c == vx.HANDLE_NONE {
		return "no /srv/acpi"
	}
	rt.print("poweroff: asking bus-acpi\n")
	req := vx.Msg_Header {
		ordinal = acpi.POWER_OFF,
	}
	rep: vx.Msg_Header
	call := vx.Call {
		wr_bytes = &req,
		wr_len   = size_of(req),
		rd_bytes = &rep,
		rd_cap   = size_of(rep),
	}
	st := rt.channel_call(c, &call, rt.clock_read() + 10_000_000_000)
	if st == .Ok && rep.flags != 0 {
		st = vx.Status(i32(rep.flags))
	}
	rt.print("poweroff: the machine is still on\n")
	return st == .Ok ? "the machine is still on" : "bus-acpi could not power off"
}
