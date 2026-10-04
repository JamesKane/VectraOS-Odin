package build

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "vx:ndb"

// Releases (upstream's docs/06 §3.1, §4; its M5 step 9a), and the release
// stores the scenarios boot with (steps 9b-9d). Each is a base tree put into
// a content store by vxstore (tools/vxstore): what a boot slot holds under
// boot/ (the kernel, bootfs.tar, the root task's modules, Limine's loader
// and configuration), and bootfs's own files beside them, which distd serves.

// The tree hashes vxstore prints: "b2:" and 64 hex digits (lib/store's names).
@(private="file")
STORE_HEX_LEN :: 67

// A file copied, mode 0644 (not the source's): a store keeps whether a file
// is executable, so what the tree says comes from here, not the build's.
@(private="file")
copy_plain :: proc(from, to: string) -> bool {
	if err := os.copy_file(to, from); err != nil {
		fmt.eprintfln("build: cannot copy %s to %s: %v", from, to, err)
		return false
	}
	return set_mode(to, os.Permissions_Read_All + {.Write_User})
}

@(private="file")
set_mode :: proc(path: string, mode: os.Permissions) -> bool {
	if err := os.change_mode(path, mode); err != nil {
		fmt.eprintfln("build: cannot change the mode of %s: %v", path, err)
		return false
	}
	return true
}

@(private="file")
EXECUTABLE :: os.Permissions_Read_All + os.Permissions_Execute_All + {.Write_User} // 0755

@(private="file")
fresh_dir :: proc(dir: string) -> bool {
	if err := os.remove_all(dir); err != nil && err != .Not_Exist {
		fmt.eprintfln("build: cannot clear %s: %v", dir, err)
		return false
	}
	return make_dirs(dir)
}

// `vxstore put STORE DIR [TAR]`: the tree's hash, and the bytes of its files.
@(private="file")
store_put :: proc(store, dir: string, tar := "") -> (tree: string, bytes: u64, ok: bool) {
	c := cmd_make(VXSTORE, "put", store, dir)
	if tar != "" {
		append(&c, tar)
	}
	out := run_capture(c[:]) or_return
	out = strings.trim_right(out, "\n")
	space := strings.index_byte(out, ' ')
	if space != STORE_HEX_LEN {
		fmt.eprintfln("build: vxstore put %s printed %q, not a tree's hash and its size", dir, out)
		return "", 0, false
	}
	n, nok := strconv.parse_u64_of_base(out[space + 1:], 10)
	if !nok {
		fmt.eprintfln("build: vxstore put %s printed %q, not a tree's hash and its size", dir, out)
		return "", 0, false
	}
	return out[:space], n, true
}

// An architecture's base tree (upstream's 06 §3.1), as a release has it:
// built in release mode under out/release/ARCH/root, put into store, and
// its objects tarred as out/release/store-ARCH.tar. Its hash, and the bytes
// under it.
@(private="file")
release_tree :: proc(a: ^Arch, store: string) -> (tree: string, bytes: u64, ok: bool) {
	limine := port_load("limine") or_return
	loader := build_port_target(&limine, a.limine) or_return
	kernel := build_kernel(a, .Release) or_return
	build_programs(a, .Release) or_return
	root := fmt.tprintf("out/release/%s/root", a.name)
	fresh_dir(root) or_return
	make_dirs(fmt.tprintf("%s/boot/vx", root)) or_return
	make_dirs(fmt.tprintf("%s/boot/limine", root)) or_return
	bootfs := fmt.tprintf("%s/boot/vx/bootfs.tar", root)
	make_bootfs(a, .Release, bootfs) or_return
	copy_plain(loader, fmt.tprintf("%s/boot/limine/%s", root, a.loader)) or_return
	copy_plain("boot/limine.conf", fmt.tprintf("%s/boot/limine/limine.conf", root)) or_return
	to := fmt.tprintf("%s/boot/vx/kernel.elf", root)
	copy_plain(kernel, to) or_return
	set_mode(to, EXECUTABLE) or_return
	for p in PROGRAMS {
		if p.place == .Module {
			to = fmt.tprintf("%s/boot/vx/%s", root, p.name)
			copy_plain(program_path(a, .Release, p.name), to) or_return
			set_mode(to, EXECUTABLE) or_return
		}
	}
	tree, bytes = store_put(store, root, bootfs) or_return
	run({VXSTORE, "tar", store, tree, fmt.tprintf("out/release/store-%s.tar", a.name)}) or_return
	return tree, bytes, true
}

// ./build release: both architectures' base trees in out/release/store,
// each one's objects as out/release/store-ARCH.tar, and the release record,
// out/release/release.ndb, unsigned until upstream's M10 (its 06 §5, and
// ADR-0011: nothing here signs). With --verify RECORD: the trees built again
// and compared with the record's (06 §5.2).
cmd_release :: proc(verify: string) -> bool {
	build_vxstore() or_return
	make_dirs("out/release") or_return
	store := "out/release/store"
	commit, cok := run_capture({GIT, "rev-parse", "HEAD"})
	count, nok := run_capture({GIT, "rev-list", "--count", "HEAD"})
	if !cok || !nok {
		fmt.eprintln("build: ./build release needs git")
		return false
	}
	commit, count = strings.trim_right(commit, "\n"), strings.trim_right(count, "\n")
	dirty, dok := run_capture({GIT, "status", "--porcelain"})
	clean := dok && dirty == ""
	text: [4096]u8
	w := ndb.Writer{buf = text[:]}
	ndb.put(&w, "release", count)
	ndb.put(&w, "name", fmt.tprintf("dev-%s", count))
	ndb.put(&w, "channel", "dev")
	ndb.put(&w, "commit", clean ? commit : fmt.tprintf("%s+dirty", commit))
	ndb.put(&w, "vx-abi", "0") // a draft until upstream's ADR-0004 freezes it
	ndb.flag(&w, "unsigned")
	_ = ndb.end(&w)
	record := ""
	if verify != "" {
		record = read_file(verify) or_return
	}
	mismatches := 0
	for &a in ARCHES {
		tree, bytes := release_tree(&a, store) or_return
		fmt.eprintfln("  TREE  %-8s %s (%d bytes)", a.name, tree, bytes)
		ndb.put(&w, "set", "base")
		ndb.put(&w, "arch", a.name)
		ndb.put(&w, "tree", tree)
		ndb.put_u64(&w, "size", bytes)
		_ = ndb.end(&w)
		if verify != "" {
			same := strings.contains(record, fmt.tprintf("arch=%s tree=%s ", a.name, tree))
			fmt.eprintfln("  VERIFY %-8s %s", a.name, same ? "the record's tree" : "NOT the record's tree")
			if !same {
				mismatches += 1
			}
		}
	}
	if w.failed {
		fmt.eprintln("build: the release record does not fit")
		return false
	}
	if verify != "" {
		return mismatches == 0
	}
	write_file("out/release/release.ndb", ndb.written(&w)) or_return
	fmt.eprintfln("  REL   out/release/release.ndb (release %s, %s, unsigned)", count, clean ? "a clean tree" : "uncommitted changes")
	return true
}

// The distd scenario's store branch (tests/qemu/m5/distd.ndb's storetree):
// a small release made by vxstore in dir (a file of several blocks, another
// never read before it is damaged, a nested directory, a link, a UTF-8
// name), its record for both architectures, and beside them plain/ (not
// objects): the big file as it is, for comparing, and the store path of the
// block the test damages. The tree is built in dir.src.
make_test_release :: proc(dir: string) -> (out: string, ok: bool) {
	build_vxstore() or_return
	src := fmt.tprintf("%s.src", dir)
	fresh_dir(dir) or_return
	fresh_dir(src) or_return
	make_dirs(fmt.tprintf("%s/bin/deeper", src)) or_return
	make_dirs(fmt.tprintf("%s/plain", dir)) or_return
	make_dirs(fmt.tprintf("%s/records", dir)) or_return
	write_file(fmt.tprintf("%s/README.txt", src), "readme\n") or_return
	write_file(fmt.tprintf("%s/bin/deeper/file.txt", src), "deep\n") or_return
	write_file(fmt.tprintf("%s/Ünïcode.txt", src), "unicode\n") or_return
	big := make([]u8, 300_000, context.temp_allocator)
	other := make([]u8, 200_000, context.temp_allocator)
	for &b, i in big {
		b = u8((i * 7 + i / 251) & 0xff)
	}
	for &b, i in other {
		b = u8((i * 13 + i / 509) & 0xff)
	}
	write_file(fmt.tprintf("%s/big.bin", src), string(big)) or_return
	write_file(fmt.tprintf("%s/other.bin", src), string(other)) or_return
	write_file(fmt.tprintf("%s/plain/big.bin", dir), string(big)) or_return
	if err := os.symlink("README.txt", fmt.tprintf("%s/readme-link", src)); err != nil {
		fmt.eprintfln("build: cannot make the link in %s: %v", src, err)
		return "", false
	}
	tree, _ := store_put(dir, src) or_return
	blocks := run_capture({VXSTORE, "blocks", dir, tree, "other.bin"}) or_return
	lines := strings.split_lines(strings.trim_right(blocks, "\n"), context.temp_allocator)
	if len(lines) < 2 {
		fmt.eprintln("build: other.bin has one block")
		return "", false
	}
	write_file(fmt.tprintf("%s/plain/damage", dir), lines[1]) or_return // other.bin's second block
	record := fmt.tprintf(
		"release=1 name=test-1 channel=dev commit=test vx-abi=0 unsigned\n" +
		"set=base arch=x86_64 tree=%s size=500021\n" +
		"set=base arch=aarch64 tree=%s size=500021\n",
		tree,
		tree,
	)
	write_file(fmt.tprintf("%s/records/1.ndb", dir), record) or_return
	return dir, true
}

// The files an image is made from, which an install medium's release tree
// holds as they are.
Image_Files :: struct {
	loader, kernel, bootfs: string,
}

// An install medium's store (upstream's 06 §8, M5 steps 9c and 9d): the
// image's own boot files and bootfs as release seq's base tree (so the
// installed system is the one tested, its test services included), put in
// a store in IMAGE.releaseSEQ with a release record, which also goes into
// the store's records/; and every object as store.tar, after the record.
// The store.tar's path, and the store's.
make_install_store :: proc(a: ^Arch, mode: Mode, image: string, files: Image_Files, seq: u64) -> (tar, store: string, ok: bool) {
	build_vxstore() or_return
	top := fmt.tprintf("%s.release%d", image, seq)
	root := fmt.tprintf("%s/root", top)
	store = fmt.tprintf("%s/store", top)
	fresh_dir(top) or_return
	make_dirs(fmt.tprintf("%s/boot/vx", root)) or_return
	make_dirs(fmt.tprintf("%s/boot/limine", root)) or_return
	make_dirs(store) or_return
	copy_plain(files.loader, fmt.tprintf("%s/boot/limine/%s", root, a.loader)) or_return
	copy_plain("boot/limine.conf", fmt.tprintf("%s/boot/limine/limine.conf", root)) or_return
	copy_plain(files.kernel, fmt.tprintf("%s/boot/vx/kernel.elf", root)) or_return
	copy_plain(files.bootfs, fmt.tprintf("%s/boot/vx/bootfs.tar", root)) or_return
	for p in PROGRAMS {
		if p.place == .Module {
			copy_plain(program_path(a, mode, p.name), fmt.tprintf("%s/boot/vx/%s", root, p.name)) or_return
		}
	}
	tree, _ := store_put(store, root, files.bootfs) or_return
	record := fmt.tprintf("%s/%d.ndb", top, seq)
	text := fmt.tprintf("release=%d name=test-%d channel=dev commit=test vx-abi=0 unsigned\nset=base arch=%s tree=%s\n", seq, seq, a.name, tree)
	write_file(record, text) or_return
	make_dirs(fmt.tprintf("%s/records", store)) or_return
	write_file(fmt.tprintf("%s/records/%d.ndb", store, seq), text) or_return
	tar = fmt.tprintf("%s/store.tar", top)
	run({VXSTORE, "tar", store, tree, tar, fmt.tprintf("records/%d.ndb=%s", seq, record)}) or_return
	return tar, store, true
}
