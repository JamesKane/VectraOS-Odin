// ps: one line per task in /proc: its id, then its status record.
package ps

import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"
import "vx:str"

space: ns.Namespace
buf: [4096]u8

// The program ends with run's exit string, as upstream's programs return
// theirs: empty for success (ADR-0010).
@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	if procns.from_spawn(&space) != .Ok {
		return "no namespace"
	}
	dir: ns.File
	if ns.open(&space, "/proc", p9.OREAD, &dir) != .Ok {
		rt.eprint("ps: cannot read /proc\n")
		return "no /proc"
	}
	for {
		n, _ := ns.read(&dir, buf[:])
		if n <= 0 {
			break
		}
		it := p9.Dir_Entries{buf = buf[:n]}
		for entry in p9.next_entry(&it) {
			path_buf: [64]u8
			path, fits := str.join(path_buf[:], "/proc/", entry.name, "/status")
			if !fits {
				continue
			}
			f: ns.File
			status: [256]u8
			got := 0
			if ns.open(&space, path, p9.OREAD, &f) == .Ok {
				got, _ = ns.read(&f, status[:])
				ns.close(&f)
			}
			if got <= 0 {
				continue // it has gone meanwhile
			}
			rt.print("id=", entry.name, " ", string(status[:got]))
		}
	}
	ns.close(&dir)
	return ""
}
