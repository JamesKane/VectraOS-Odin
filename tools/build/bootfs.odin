package build

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "vx:tar"

// The boot image, bootfs.tar, a Limine module: the namespace's mount
// points, boot/bin with each program that lives in bootfs, and boot/svc with
// the service manifests from boot/svc/*.ndb. The archive is deterministic:
// fixed order, no times or owners (lib/tar's writer).

@(private="file")
BOOTFS_DIRS := []string{"bin", "boot", "boot/bin", "boot/svc", "dev", "proc", "srv", "tmp"}

// Whether `name` is in the comma-separated list `with`.
listed :: proc(with, name: string) -> bool {
	rest := with
	for len(rest) > 0 {
		i := strings.index_byte(rest, ',')
		item := i < 0 ? rest : rest[:i]
		if item == name {
			return true
		}
		rest = i < 0 ? "" : rest[i + 1:]
	}
	return false
}

// Test programs named in `with` join the image, with their manifests from
// tests/user/NAME.ndb, after the system's: svcd starts a test after what it tests.
make_bootfs :: proc(a: ^Arch, mode: Mode, out: string, with := "") -> bool {
	paths := make([dynamic]string, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	// Programs, then the system's manifests: svcd starts services in this order.
	for p in PROGRAMS {
		if (p.place == .Bootfs || (p.place == .Tests && listed(with, p.name))) && program_for(p, a) {
			append(&paths, fmt.tprintf("boot/bin/%s", p.name))
			append(&files, read_file(program_path(a, mode, p.name)) or_return)
		}
	}
	if os.is_dir("boot/svc") {
		manifests := tree_files("boot/svc") or_return
		slice.sort(manifests[:])
		for m in manifests {
			if strings.has_suffix(m, ".ndb") {
				append(&paths, m)
				append(&files, read_file(m) or_return)
			}
		}
	}
	for p in PROGRAMS {
		if p.place == .Tests && listed(with, p.name) {
			append(&paths, fmt.tprintf("boot/svc/%s.ndb", p.name))
			append(&files, read_file(fmt.tprintf("tests/user/%s.ndb", p.name)) or_return)
		}
	}
	total := (len(BOOTFS_DIRS) + 2) * 512
	for f in files {
		total += len(f) + 2 * 512
	}
	w := tar.Writer{buf = make([]u8, total, context.temp_allocator)}
	for d in BOOTFS_DIRS {
		tar.add(&w, d, true, 0o755, nil)
	}
	for f, i in files {
		tar.add(&w, paths[i], false, strings.has_prefix(paths[i], "boot/bin/") ? 0o755 : 0o644, transmute([]u8)f)
	}
	n := tar.end(&w)
	if n == 0 {
		fmt.eprintfln("build: cannot pack %s", out)
		return false
	}
	return write_file(out, string(w.buf[:n]))
}
