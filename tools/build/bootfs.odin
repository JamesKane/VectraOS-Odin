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

make_bootfs :: proc(a: ^Arch, mode: Mode, out: string) -> bool {
	paths := make([dynamic]string, context.temp_allocator)
	files := make([dynamic]string, context.temp_allocator)
	// Programs, then the system's manifests: svcd starts services in this order.
	for p in PROGRAMS {
		if p.place == .Bootfs && program_for(p, a) {
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
