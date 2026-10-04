// ps: one line per task in /proc: its id, then its status record.
package ps

import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

space: ns.Namespace
buf: [4096]u8

@(export, link_name="vx_main")
main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		return 1
	}
	dir: ns.File
	if ns.open(&space, "/proc", p9.OREAD, &dir) != .Ok {
		rt.print("ps: cannot read /proc\n")
		return 1
	}
	for {
		n, _ := ns.read(&dir, buf[:])
		if n <= 0 {
			break
		}
		for off := 0; off + 2 <= n; {
			size := int(buf[off]) | int(buf[off + 1]) << 8
			entry: p9.Stat
			if off + size + 2 > n || p9.stat_decode(buf[off:off + size + 2], &entry) != .Ok {
				break
			}
			off += size + 2
			path: [64]u8
			if len(entry.name) > len(path) - 14 {
				continue
			}
			copy(path[:], "/proc/")
			copy(path[6:], entry.name)
			copy(path[6 + len(entry.name):], "/status")
			f: ns.File
			status: [256]u8
			got := 0
			if ns.open(&space, string(path[:13 + len(entry.name)]), p9.OREAD, &f) == .Ok {
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
	return 0
}
