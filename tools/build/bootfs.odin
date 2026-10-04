package build

import "core:fmt"
import "core:os"
import "core:strings"
import "vx:tar"

// The boot image, bootfs.tar, a Limine module: the namespace's mount
// points, boot/bin with each program that lives in bootfs, boot/svc with the
// service manifests from boot/svc/*.ndb, boot/drv with the driver
// manifests from boot/drv/*.ndb, and lib/ns with the namespace templates
// from boot/lib/ns. The archive is deterministic:
// fixed order, no times or owners (lib/tar's writer).

@(private="file")
BOOTFS_DIRS := []string{"bin", "boot", "boot/bin", "boot/bin/posix", "boot/share", "boot/share/misc", "boot/drv", "boot/svc", "boot/tests", "dev", "lib", "lib/ns", "n", "net", "proc", "srv", "sys", "tmp"}

// Whether any program, of any kind, is called `name`.
@(private="file")
is_program :: proc(name: string) -> bool {
	for p in PROGRAMS {
		if p.name == name {
			return true
		}
	}
	for p in C_PROGRAMS {
		if p.name == name {
			return true
		}
	}
	return false
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
}

// Test programs named in `with` join the image, with their manifests from
// tests/user/NAME.ndb, after the system's: svcd starts a test after what it tests.
make_bootfs :: proc(a: ^Arch, mode: Mode, out: string, with := "") -> bool {
	entries := make([dynamic]Bootfs_Entry, context.temp_allocator)
	// Programs, then the system's manifests: svcd starts services in this order.
	for p in PROGRAMS {
		if (p.place == .Bootfs || (p.place == .Tests && listed(with, p.name))) && program_for(p, a) {
			data := read_file(program_path(a, mode, p.name)) or_return
			append(&entries, Bootfs_Entry{fmt.tprintf("boot/bin/%s", p.name), data, 0o755})
		}
	}
	// The service manifests, then the driver manifests devmgr matches (M3).
	for dir in ([]string{"boot/svc", "boot/drv"}) {
		if !os.is_dir(dir) {
			continue
		}
		manifests := tree_files(dir) or_return
		for m in manifests {
			if strings.has_suffix(m, ".ndb") {
				append(&entries, Bootfs_Entry{m, read_file(m) or_return, 0o644})
			}
		}
	}
	// The namespace templates, namespace(6) files, from boot/lib/ns as lib/ns
	// (upstream ADR-0009): a manifest's ns=NAME reads /lib/ns/NAME.
	if os.is_dir("boot/lib/ns") {
		templates := tree_files("boot/lib/ns") or_return
		for t in templates {
			append(&entries, Bootfs_Entry{strings.trim_prefix(t, "boot/"), read_file(t) or_return, 0o644})
		}
	}
	for p in PROGRAMS {
		if p.place == .Tests && listed(with, p.name) {
			data := read_file(fmt.tprintf("tests/user/%s.ndb", p.name)) or_return
			append(&entries, Bootfs_Entry{fmt.tprintf("boot/svc/%s.ndb", p.name), data, 0o644})
			if cmds := fmt.tprintf("tests/user/%s.cmds", p.name); os.exists(cmds) { // a dbg script
				append(&entries, Bootfs_Entry{fmt.tprintf("boot/tests/%s.cmds", p.name), read_file(cmds) or_return, 0o644})
			}
		}
	}
	// A `with` name that is no program is a script test: its manifest runs a
	// program the image has (lua, gsh) on tests/user/NAME.lua or NAME.rc, at
	// /boot/tests.
	rest := with
	for name in strings.split_iterator(&rest, ",") {
		if is_program(name) {
			continue
		}
		manifest := read_file(fmt.tprintf("tests/user/%s.ndb", name)) or_return
		append(&entries, Bootfs_Entry{fmt.tprintf("boot/svc/%s.ndb", name), manifest, 0o644})
		for ext in ([]string{"lua", "rc"}) {
			if script := fmt.tprintf("tests/user/%s.%s", name, ext); os.exists(script) {
				append(&entries, Bootfs_Entry{fmt.tprintf("boot/tests/%s.%s", name, ext), read_file(script) or_return, 0o644})
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
		tar.add(&w, e.path, false, e.mode, transmute([]u8)e.data)
	}
	n := tar.end(&w)
	if n == 0 {
		fmt.eprintfln("build: cannot pack %s", out)
		return false
	}
	return write_file(out, string(w.buf[:n]))
}
