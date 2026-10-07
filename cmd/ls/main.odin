// ls: lists each directory named (or /), its names sorted and on one line,
// two spaces apart; a file is listed as its own name.
package ls

import vx "abi:vx"
import "vx:ns"
import "vx:p9"
import "vx:procns"
import "vx:rt"

names: [dynamic; 8192]u8 // the text list's strings point into; a fixed capacity never moves it
list: [dynamic; 512]string // sorted; a directory with more entries is listed in part
space: ns.Namespace
buf: [4096]u8

// Not contextless: inject_at needs a context.
ls :: proc(path: string) -> bool {
	c, fid, e := ns.walk(&space, path)
	st: p9.Stat
	if e == .Ok {
		e = p9.client_stat(c, fid, &st)
		_ = p9.client_clunk(c, fid)
	}
	if e != .Ok {
		rt.eprint("ls: ", path, ": ", p9.error_text(e), "\n")
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
	clear(&names)
	clear(&list)
	n: int
	rst: vx.Status
	for {
		n, rst = ns.read(&f, buf[:])
		if n <= 0 {
			break
		}
		it := p9.Dir_Entries{buf = buf[:n]}
		for entry in p9.next_entry(&it) {
			if len(list) == cap(list) || len(entry.name) > cap(names) - len(names) {
				continue
			}
			from := len(names)
			_ = append(&names, entry.name)
			name := string(names[from:])
			at := len(list) // insertion sort: after any equal name
			for at > 0 && list[at - 1] > name {
				at -= 1
			}
			_ = inject_at(&list, at, name)
		}
	}
	ns.close(&f)
	for name, i in list {
		if i > 0 {
			rt.print("  ")
		}
		rt.print(name)
	}
	rt.print("\n")
	return n == 0 && rst == .Ok
}

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
	if len(rt.args()) == 0 {
		return ls(".") ? "" : "error" // the current directory
	}
	exit := ""
	for a in rt.args() {
		if !ls(a) {
			exit = "error"
		}
	}
	return exit
}
