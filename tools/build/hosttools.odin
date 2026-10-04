package build

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

// Host tools: programs built for this machine that the scenarios' QEMUs run
// through guestfwd (M3), and the fresh directories they serve.

// vx9pserve, from tools/vx9pserve: the 9P server VectraOS mounts over TCP.
// Rebuilt when its sources, or the libraries it imports, change.
VX9PSERVE :: "out/host/vx9pserve"
VX9PSERVE_SRC :: "tools/vx9pserve"

// vxstore, from tools/vxstore: makes and reads content stores (upstream's
// host/vxstore), with Monocypher's host archive (cobj.odin, ADR-0011).
VXSTORE :: "out/host/vxstore"
VXSTORE_SRC :: "tools/vxstore"

// vxfs, from tools/vxfs: makes, fills and checks vx:fs volume images
// (upstream's host/vxfs), for scenarios with volume= (disk.odin).
VXFS :: "out/host/vxfs"
VXFS_SRC :: "tools/vxfs"

// third_party/u9fs (ADR-0006), built for this machine: the stock 9P2000
// server the u9fs scenario tests against. As upstream left it, but for two
// constants its rune.c uses and nothing defines.
U9FS :: "out/host/u9fs"
U9FS_SRC :: "third_party/u9fs"

@(private="file")
U9FS_UNITS :: []string {
	"authnone",
	"authrhosts",
	"authp9any",
	"convD2M",
	"convM2D",
	"convM2S",
	"convS2M",
	"des",
	"dirmodeconv",
	"doprint",
	"fcallconv",
	"oldfcall",
	"print",
	"random",
	"readn",
	"remotehost",
	"rune",
	"safecpy",
	"strecpy",
	"tokenize",
	"u9fs",
	"utfrune",
}

when ODIN_OS == .Linux {
	UNSHARE :: "/usr/bin/unshare"
}

// What a host tool's build came to, once tried: scenarios run one after
// another in this process, and each asks.
@(private="file")
Tool_State :: enum {
	Untried,
	Built,
	Failed,
}

@(private="file")
vx9pserve_state: Tool_State
@(private="file")
vxstore_state: Tool_State
@(private="file")
vxfs_state: Tool_State
@(private="file")
u9fs_state: Tool_State
@(private="file")
userns_state: Tool_State

// The newest modification time among the files under dirs ending in ext
// (all files for ""), and whether every one could be read.
@(private="file")
newest :: proc(dirs: []string, ext: string) -> (t: time.Time, ok: bool) {
	for d in dirs {
		files := tree_files(d) or_return
		for f in files {
			if !strings.has_suffix(f, ext) {
				continue
			}
			m, err := os.modification_time_by_path(f)
			if err != nil {
				fmt.eprintfln("build: cannot stat %s: %v", f, err)
				return t, false
			}
			if time.diff(t, m) > 0 {
				t = m
			}
		}
	}
	return t, true
}

// Whether out is missing or older than anything it is made from.
@(private="file")
stale :: proc(out: string, dirs: []string, ext: string) -> (is_stale: bool, ok: bool) {
	built, err := os.modification_time_by_path(out)
	if err != nil {
		return true, true
	}
	src := newest(dirs, ext) or_return
	return time.diff(built, src) > 0, true
}

// Builds out/host/vx9pserve if it is stale. Until tools/vx9pserve exists
// this fails, saying so; only scenarios that dial it need it.
build_vx9pserve :: proc() -> bool {
	if vx9pserve_state != .Untried {
		return vx9pserve_state == .Built
	}
	vx9pserve_state = .Failed
	if !os.is_dir(VX9PSERVE_SRC) {
		fmt.eprintfln("build: %s is missing, so %s cannot be built", VX9PSERVE_SRC, VX9PSERVE)
		return false
	}
	if s := stale(VX9PSERVE, {VX9PSERVE_SRC, "lib", "abi"}, ".odin") or_return; s {
		make_dirs("out/host") or_return
		fmt.eprintln("  HOST  vx9pserve")
		run({ODIN, "build", VX9PSERVE_SRC, "-collection:vx=lib", "-collection:abi=abi", "-vet", "-strict-style", "-warnings-as-errors", "-out:" + VX9PSERVE}) or_return
	}
	vx9pserve_state = .Built
	return true
}

// Builds out/host/vxstore if it is stale.
build_vxstore :: proc() -> bool {
	if vxstore_state != .Untried {
		return vxstore_state == .Built
	}
	vxstore_state = .Failed
	links := cobj_host_link_flags({"monocypher"}) or_return
	if s := stale(VXSTORE, {VXSTORE_SRC, "lib", "abi", "third_party/monocypher"}, "") or_return; s {
		make_dirs("out/host") or_return
		fmt.eprintln("  HOST  vxstore")
		c := cmd_make(ODIN, "build", VXSTORE_SRC, "-collection:vx=lib", "-collection:abi=abi", "-vet", "-strict-style", "-warnings-as-errors", "-out:" + VXSTORE)
		append(&c, ..links[:])
		run(c[:]) or_return
	}
	vxstore_state = .Built
	return true
}

// Builds out/host/vxfs if it is stale, as tools/vxfs says it is built.
build_vxfs :: proc() -> bool {
	if vxfs_state != .Untried {
		return vxfs_state == .Built
	}
	vxfs_state = .Failed
	if !os.is_dir(VXFS_SRC) {
		fmt.eprintfln("build: %s is missing, so %s cannot be built", VXFS_SRC, VXFS)
		return false
	}
	if s := stale(VXFS, {VXFS_SRC, "lib", "abi"}, ".odin") or_return; s {
		make_dirs("out/host") or_return
		fmt.eprintln("  HOST  vxfs")
		run({ODIN, "build", VXFS_SRC, "-collection:vx=lib", "-collection:abi=abi", "-vet", "-strict-style", "-warnings-as-errors", "-out:" + VXFS}) or_return
	}
	vxfs_state = .Built
	return true
}

// Builds out/host/u9fs if it is stale, as ADR-0006 says: GNU C89, warnings
// off, and Plan 9's values for Bit5 and Runemax, so the tree stays upstream's.
build_u9fs :: proc() -> bool {
	if u9fs_state != .Untried {
		return u9fs_state == .Built
	}
	u9fs_state = .Failed
	if s := stale(U9FS, {U9FS_SRC}, "") or_return; s {
		make_dirs("out/host") or_return
		fmt.eprintln("  HOST  u9fs")
		c := cmd_make(CLANG, "-std=gnu89", "-D_DEFAULT_SOURCE", "-DBit5=2", "-DRunemax=0x10FFFF", "-O2", "-g", "-w", "-I" + U9FS_SRC, "-o", U9FS)
		for u in U9FS_UNITS {
			append(&c, fmt.tprintf("%s/%s.c", U9FS_SRC, u))
		}
		run(c[:]) or_return
	}
	u9fs_state = .Built
	return true
}

// Whether this host gives unprivileged user namespaces, which u9fs needs to
// chroot (ADR-0006); and if not, why not.
user_namespaces :: proc() -> (why: string, ok: bool) {
	when ODIN_OS == .Linux {
		if userns_state == .Untried {
			_, ran := run_capture({UNSHARE, "-r", "true"})
			userns_state = ran ? .Built : .Failed
		}
		if userns_state == .Failed {
			return "`unshare -r` fails here: unprivileged user namespaces are off", false
		}
		return "", true
	} else {
		return "u9fs needs unprivileged user namespaces (`unshare -r`), which only Linux has", false
	}
}

// A fresh copy of tests/fixtures/share at dir, for one QEMU to serve: what
// a guest writes there stays out of the repository and away from other runs.
fresh_share :: proc(dir: string) -> bool {
	if err := os.remove_all(dir); err != nil && err != .Not_Exist {
		fmt.eprintfln("build: cannot clear %s: %v", dir, err)
		return false
	}
	make_dirs(filepath.dir(dir)) or_return
	if err := os.copy_directory_all(dir, "tests/fixtures/share"); err != nil {
		fmt.eprintfln("build: cannot copy tests/fixtures/share to %s: %v", dir, err)
		return false
	}
	return true
}

// The same, as a root for u9fs, which chroots there: with the one user its
// lookups find (ADR-0006).
fresh_u9fs_root :: proc(dir: string) -> bool {
	fresh_share(dir) or_return
	make_dirs(fmt.tprintf("%s/etc", dir)) or_return
	write_file(fmt.tprintf("%s/etc/passwd", dir), "vectra:x:0:0::/:/bin/false\n") or_return
	return write_file(fmt.tprintf("%s/etc/group", dir), "vectra:x:0:\n")
}
