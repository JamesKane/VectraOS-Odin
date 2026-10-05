package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "vx:tar"

// The boot image, bootfs.tar, a Limine module: the namespace's mount
// points, boot/bin with each program that lives in bootfs (and
// boot/bin/posix with sbase's, ADR-0010), boot/svc with the service
// manifests from boot/svc/*.ndb, boot/drv with the driver manifests from
// boot/drv/*.ndb, lib/man with the manual (man/ and its index), and lib/ns
// with the namespace templates, namespace(6) files, from boot/lib/ns/. The
// archive is deterministic: fixed order, no times or owners (lib/tar's
// writer).

@(private="file")
BOOTFS_DIRS := []string {
	"adm", // fsd's adm branch, on an installed system (boot/svc/system.ndb)
	"bin",
	"boot",
	"boot/bin",
	"boot/bin/posix",
	"boot/share",
	"boot/share/misc",
	"boot/drv",
	"boot/svc",
	"boot/tests",
	"dev",
	"dist",
	"lib",
	"lib/ns",
	"n",
	"net",
	"proc",
	"srv",
	"sys",
	"tmp",
}

// Whether `name` is in the comma-separated list `with`.
listed :: proc(with, name: string) -> bool {
	rest := with
	for item in strings.split_iterator(&rest, ",") {
		if item == name {
			return true
		}
	}
	return false
}

@(private="file")
Bootfs_Entry :: struct {
	path: string,
	data: string,
	mode: u32,
	link: string, // a hard link's target (a box's names), with no data
}

// Test programs named in `with` join the image, with their manifests from
// tests/user/NAME.ndb, after the system's: svcd starts a test after what it
// tests. A `with` name that is no program is a script test: its manifest
// runs a program the image has (lua, rc) on tests/user/NAME.lua or NAME.rc,
// at /boot/tests.
make_bootfs :: proc(a: ^Arch, mode: Mode, out: string, with := "") -> bool {
	entries := make([dynamic]Bootfs_Entry, context.temp_allocator)
	// Programs, then the system's manifests, then the tests': svcd starts
	// services in this order.
	for p in PROGRAMS {
		if (p.place == .Bootfs || (p.place == .Tests && listed(with, p.name))) && program_for(p, a) {
			data := read_file(program_path(a, mode, p.name)) or_return
			append(&entries, Bootfs_Entry{path = fmt.tprintf("boot/bin/%s", p.name), data = data, mode = 0o755})
		}
	}
	// The vendored POSIX programs: each, or a box and each name a hard link
	// to it, in the port's directory under boot/bin.
	ps := posix_load() or_return
	ports := [?]^Port{&ps.lua, &ps.sbase}
	for p in ports {
		dir := val(p.head, "dir")
		sub := dir != "" ? fmt.tprintf("%s/", dir) : ""
		box := val(p.head, "box")
		box_path := ""
		if box != "" {
			box_path = fmt.tprintf("boot/bin/%s%s", sub, box)
			data := read_file(fmt.tprintf("%s/bin/%s%s", out_dir(a, mode), sub, box)) or_return
			append(&entries, Bootfs_Entry{path = box_path, data = data, mode = 0o755})
		}
		names := make([dynamic]string, context.temp_allocator)
		alone := make([dynamic]bool, context.temp_allocator)
		for rec in p.programs {
			append(&names, val(rec, "program"))
			append(&alone, val(rec, "alone") == "yes")
		}
		if slice.contains(words(val(p.head, "box.alias")), "[") {
			append(&names, "[")
			append(&alone, false)
		}
		for name, i in names {
			path := fmt.tprintf("boot/bin/%s%s", sub, name)
			if box != "" && !alone[i] {
				append(&entries, Bootfs_Entry{path = path, mode = 0o755, link = box_path})
			} else {
				data := read_file(fmt.tprintf("%s/bin/%s%s", out_dir(a, mode), sub, name)) or_return
				append(&entries, Bootfs_Entry{path = path, data = data, mode = 0o755})
			}
		}
	}
	// install=FROM:TO, a file of the port's tree at /boot/TO.
	for p in ports {
		for item in words(val(p.head, "install")) {
			colon := strings.last_index_byte(item, ':')
			if colon <= 0 {
				continue
			}
			data := read_file(fmt.tprintf("%s/%s", p.src, item[:colon])) or_return
			append(&entries, Bootfs_Entry{path = fmt.tprintf("boot/%s", item[colon + 1:]), data = data, mode = 0o644})
		}
	}
	// The manual (upstream 12 §5): every page at /lib/man/<sect>/<page>, and
	// the index the manual's pass writes, out/man/index/base, at
	// /lib/man/index/base. The pass's verdict is ./build check's to give.
	_ = check_man()
	for sect in 1 ..= 8 {
		for name in man_dir(sect) {
			data := read_file(fmt.tprintf("man/%d/%s", sect, name)) or_return
			append(&entries, Bootfs_Entry{path = fmt.tprintf("lib/man/%d/%s", sect, name), data = data, mode = 0o644})
		}
	}
	append(&entries, Bootfs_Entry{path = "lib/man/index/base", data = read_file(MAN_INDEX) or_return, mode = 0o644})
	// The service manifests, the driver manifests devmgr matches (M3), and
	// the namespace templates: boot/lib/ns/NAME is /lib/ns/NAME in the image.
	for dir in ([]string{"boot/svc", "boot/drv", "boot/lib/ns"}) {
		if !os.is_dir(dir) {
			continue
		}
		files := tree_files(dir) or_return
		for m in files {
			if dir != "boot/lib/ns" && !strings.has_suffix(m, ".ndb") {
				continue
			}
			path := strings.has_prefix(m, "boot/lib/") ? m[len("boot/"):] : m
			append(&entries, Bootfs_Entry{path = path, data = read_file(m) or_return, mode = 0o644})
		}
	}
	for p in PROGRAMS {
		if p.place != .Tests || !listed(with, p.name) {
			continue
		}
		data := read_file(fmt.tprintf("tests/user/%s.ndb", p.name)) or_return
		append(&entries, Bootfs_Entry{path = fmt.tprintf("boot/svc/%s.ndb", p.name), data = data, mode = 0o644})
		if cmds := fmt.tprintf("tests/user/%s.cmds", p.name); os.exists(cmds) { // a dbg script
			append(&entries, Bootfs_Entry{path = fmt.tprintf("boot/tests/%s.cmds", p.name), data = read_file(cmds) or_return, mode = 0o644})
		}
	}
	rest := with
	for name in strings.split_iterator(&rest, ",") {
		program := false
		for p in PROGRAMS {
			program = program || p.name == name
		}
		if program || name == "" {
			continue
		}
		data := read_file(fmt.tprintf("tests/user/%s.ndb", name)) or_return
		append(&entries, Bootfs_Entry{path = fmt.tprintf("boot/svc/%s.ndb", name), data = data, mode = 0o644})
		for ext in ([]string{"lua", "rc"}) {
			script := fmt.tprintf("tests/user/%s.%s", name, ext)
			if os.exists(script) {
				append(&entries, Bootfs_Entry{path = fmt.tprintf("boot/tests/%s.%s", name, ext), data = read_file(script) or_return, mode = 0o644})
			}
		}
	}
	total := (len(BOOTFS_DIRS) + 2) * 512
	for e in entries {
		total += len(e.data) + 2 * 512
	}
	w := tar.Writer{buf = make([]u8, total, context.temp_allocator)}
	for d in BOOTFS_DIRS {
		tar.add(&w, d, true, 0o755, nil)
	}
	for e in entries {
		if e.link != "" {
			tar.add_link(&w, e.path, e.link, e.mode)
		} else {
			tar.add(&w, e.path, false, e.mode, transmute([]u8)e.data)
		}
	}
	n := tar.end(&w)
	if n == 0 {
		fmt.eprintfln("build: cannot pack %s", out)
		return false
	}
	return write_file(out, string(w.buf[:n]))
}
