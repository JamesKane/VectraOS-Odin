// ls: lists each directory named (or /), its names sorted and on one line,
// two spaces apart; a file is listed as its own name.
package ls

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

names: [8192]u8
list: [512]string
space: ns.Namespace
buf: [4096]u8

ls :: proc "contextless" (path: string) -> bool {
	c, fid, e := ns.walk(&space, path)
	st: p9.Stat
	if e == .Ok {
		e = p9.client_stat(c, fid, &st)
		_ = p9.client_clunk(c, fid)
	}
	if e != .Ok {
		rt.print("ls: ", path, ": ", p9.error_text(e), "\n")
		return false
	}
	if st.mode & p9.DMDIR == 0 {
		rt.print(path, "\n")
		return true
	}
	f: ns.File
	if ns.open(&space, path, p9.OREAD, &f) != .Ok {
		return false
	}
	used, count := 0, 0
	n: int
	rst: vx.Status
	for {
		n, rst = ns.read(&f, buf[:])
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
			if count == len(list) || len(entry.name) > len(names) - used {
				continue
			}
			copy(names[used:], entry.name)
			name := string(names[used:used + len(entry.name)])
			used += len(entry.name)
			at := count
			count += 1
			for ; at > 0 && list[at - 1] > name; at -= 1 { // insertion sort
				list[at] = list[at - 1]
			}
			list[at] = name
		}
	}
	ns.close(&f)
	for name, i in list[:count] {
		if i > 0 {
			rt.print("  ")
		}
		rt.print(name)
	}
	rt.print("\n")
	return n == 0 && rst == .Ok
}

@(export, link_name="vx_main")
main :: proc() -> int {
	if procns.from_spawn(&space) != .Ok {
		return 1
	}
	if rt.spawn.argc == 0 {
		return ls("/") ? 0 : 1
	}
	exit_status := 0
	for a in rt.spawn.args[:rt.spawn.argc] {
		if !ls(a) {
			exit_status = 1
		}
	}
	return exit_status
}
