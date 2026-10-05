// lookman: the pages of the manual about every key given (man(1), upstream
// docs/12 §6.1): each record of the index (/lib/man/index) whose name,
// summary or title and keys hold every key, ignoring case, printed once a
// page (or node) as the man command that shows it, with what it is about.
package lookman

import "vx:man"
import "vx:ndb"
import "vx:ns"
import "vx:procns"
import "vx:rt"
import "vx:str"
import usage "gen:usage/lookman"

space: ns.Namespace
index_bufs: man.Index_Buffers

ID_MAX :: 80 // upstream's: a longer "sect page node" is passed over

// What has been printed, as "sect page node": each once.
seen: [dynamic; 512][dynamic; ID_MAX]u8
found: int

lower :: proc "contextless" (c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c - 'A' + 'a' : c
}

// Whether s holds key, ignoring ASCII case.
holds :: proc "contextless" (s, key: string) -> bool {
	for i := 0; i + len(key) <= len(s); i += 1 {
		k := 0
		for k < len(key) && lower(s[i + k]) == lower(key[k]) {
			k += 1
		}
		if k == len(key) {
			return true
		}
	}
	return false
}

each :: proc "contextless" (arg: rawptr, rec: ^ndb.Record) -> bool {
	name, _ := ndb.get(rec, "name")
	page, _ := ndb.get(rec, "page")
	sect, _ := ndb.get(rec, "sect")
	node, _ := ndb.get(rec, "node")
	about, _ := ndb.get(rec, node != "" ? "title" : "summary")
	keys, _ := ndb.get(rec, "keys")
	for key in rt.args() {
		if !holds(name, key) && !holds(about, key) && !holds(keys, key) {
			return true
		}
	}
	if len(sect) + len(page) + len(node) + 3 > ID_MAX {
		return true
	}
	buf: [ID_MAX]u8
	id: string
	if node != "" {
		id, _ = str.join(buf[:], sect, " ", page, " ", node)
	} else {
		id, _ = str.join(buf[:], sect, " ", page)
	}
	for &s in seen {
		if string(s[:]) == id {
			return true
		}
	}
	if len(seen) < cap(seen) {
		_ = append(&seen, [dynamic; ID_MAX]u8{})
		_ = append(&seen[len(seen) - 1], id)
	}
	rt.print("man ", id, " # ", about, "\n")
	found += 1
	return true
}

@(export, link_name="vx_main")
vx_main :: proc() -> int {
	rt.exits(run())
}

run :: proc() -> string {
	if len(rt.args()) == 0 {
		rt.eprint("lookman: ", usage.TEXT, "\n")
		return usage.TEXT
	}
	if procns.from_spawn(&space) != .Ok {
		return "the namespace is incomplete"
	}
	if !man.index(&space, &index_bufs, each, nil) {
		rt.eprint("lookman: cannot read /lib/man/index\n")
		return "no index"
	}
	return found > 0 ? "" : "not found"
}
