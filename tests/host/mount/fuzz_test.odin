// Upstream's mount_fuzz.c (M6 step 6d10) over its corpus
// (tests/fuzz/corpus/mount), and over inputs a mutator makes from it: hostile
// volumes, mounted and walked whole, beside tests/host/fs's single blocks. An
// input is a format and a list of byte edits to a real image of it: vx-fs
// made by mkfs and the file layer, FAT32 by fat.format and vx:fat's writer,
// FAT12 and FAT16 as mtools made them (tests/host/fatfix) and ISO 9660 with
// Rock Ridge and Joliet as ./build's write_iso made it (out/host/test.iso,
// which ./build check makes before the host suites). The edited image is
// mounted, every directory listed and every file read through the file layer
// (bounded: a loop in a damaged volume must end), a file made and written
// where the format is writable, and vx-fs's checker run. Nothing may fault,
// nothing may leak (ASan), and the image is put back as it was for the next
// input.
//
// An edit is two bytes choosing one of the image's 512-byte chunks that are
// not all zero (where its structures and data are), two bytes an offset in
// it, a byte n, and n % 16 + 1 bytes to write there.
//
// Each input's outcome goes into a transcript (each call's status, each
// entry's name and what was read of it, the checker's counts), and the
// transcript's digest is upstream's: its target, built with clang with the
// same lines printed, over the same inputs and the same image files.
package mount_test

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:fat"
import "vx:fs"
import "vx:iso"
import "../fatfix"

CORPUS := #load_directory("corpus")

MUTATED :: 2000
MAX_NODES :: 512 // a walk's bound: a damaged volume may loop

Image :: struct {
	bytes:  []u8,
	hot:    [dynamic]u32, // the chunks not all zero
	saving: bool, // once made, every edit and write is put back
}

// What was there before an edit or a write, to put back.
Undo :: struct {
	off: int,
	was: []u8,
}

// What upstream's target keeps in statics.
Fuzz :: struct {
	undos:     [dynamic]Undo,
	vxfs_img:  Image,
	fat_img:   [3]Image, // FAT12, FAT16 (mtools's), FAT32 (fat.format's)
	iso_img:   Image,
	buf:       [65536]u8,
	out:       strings.Builder,
	vol:       fs.Vol,
	fat_vol:   fat.Vol,
	iso_vol:   iso.Vol,
	fs_stack:  [MAX_NODES]fs.File,
	fat_stack: [MAX_NODES]fat.Entry,
	iso_stack: [MAX_NODES]iso.Entry,
	t:         ^testing.T,
	live:      int, // the C heap's blocks vx-fs holds
}

// Device callbacks are contextless; their saves go through this.
@(private="file")
fz_global: ^Fuzz

save :: proc "contextless" (m: ^Image, off, n: int) {
	context = {}
	was := ([^]u8)(libc.malloc(uint(max(n, 1))))[:n]
	copy(was, m.bytes[off:][:n])
	fz := fz_global
	if len(fz.undos) == cap(fz.undos) {
		libc.abort() // reserved in advance: no allocator here
	}
	append_elem(&fz.undos, Undo{off, was})
}

put_back :: proc(fz: ^Fuzz, m: ^Image) {
	for len(fz.undos) > 0 {
		u := pop(&fz.undos)
		copy(m.bytes[u.off:], u.was)
		libc.free(raw_data(u.was))
	}
}

find_hot :: proc(m: ^Image) {
	for c := 0; c * 512 < len(m.bytes); c += 1 {
		p := m.bytes[c * 512:][:min(512, len(m.bytes) - c * 512)]
		for b in p {
			if b != 0 {
				append(&m.hot, u32(c))
				break
			}
		}
	}
	m.saving = true
}

// The input's edits, each saved first.
edit :: proc(m: ^Image, data: []u8) {
	nhot := u32(len(m.hot))
	for at := 0; at + 5 <= len(data) && nhot > 0; {
		chunk := m.hot[(u32(data[at]) | u32(data[at + 1]) << 8) % nhot]
		off := int(chunk) * 512 + int((u32(data[at + 2]) | u32(data[at + 3]) << 8) % 512)
		n := int(data[at + 4] % 16) + 1
		at += 5
		n = min(n, len(data) - at, len(m.bytes) - off)
		save(m, off, n)
		copy(m.bytes[off:][:n], data[at:][:n])
		at += n
	}
}

// The C heap, its blocks counted: a volume let go must have given back all
// it took. Upstream's target leaves that to LeakSanitizer, which this host's
// ASan lacks (macOS on arm64), so its leak (a mount that failed) is caught
// here by the count.
m_alloc :: proc "contextless" (ctx: rawptr, n: int) -> rawptr {
	p := libc.malloc(uint(n))
	if p != nil {
		(^Fuzz)(ctx).live += 1
	}
	return p
}

m_free :: proc "contextless" (ctx: rawptr, p: rawptr, _: int) {
	if p != nil {
		(^Fuzz)(ctx).live -= 1
	}
	libc.free(p)
}

mem :: proc(fz: ^Fuzz) -> fs.Mem {
	return {ctx = fz, alloc = m_alloc, free = m_free}
}

// After an unmount: nothing the volume allocated is still held.
let_go :: proc(fz: ^Fuzz, loc := #caller_location) {
	testing.expectf(fz.t, fz.live == 0, "vx-fs: %d blocks of memory still held after the volume was let go", fz.live, loc = loc)
	fz.live = 0
}

out :: proc(fz: ^Fuzz, f: string, args: ..any) {
	fmt.sbprintf(&fz.out, f, ..args)
}

digest :: proc(b: []u8) -> u64 {
	return fs.xxh64(b, 0)
}

// --- vx-fs ---

vd_read :: proc "contextless" (ctx: rawptr, addr: fs.Addr, b: ^[fs.BLKSZ]u8) -> vx.Status {
	m := (^Image)(ctx)
	if u64(addr) > u64(len(m.bytes)) || fs.BLKSZ > u64(len(m.bytes)) - u64(addr) {
		return .Err_Io
	}
	copy(b[:], m.bytes[addr:][:fs.BLKSZ])
	return .Ok
}

vd_write :: proc "contextless" (ctx: rawptr, addr: fs.Addr, b: ^[fs.BLKSZ]u8) -> vx.Status {
	m := (^Image)(ctx)
	if u64(addr) > u64(len(m.bytes)) || fs.BLKSZ > u64(len(m.bytes)) - u64(addr) {
		return .Err_Io
	}
	if m.saving {
		save(m, int(addr), fs.BLKSZ)
	}
	copy(m.bytes[addr:][:fs.BLKSZ], b[:])
	return .Ok
}

vd_barrier :: proc "contextless" (_: rawptr) -> vx.Status {
	return .Ok
}

vdev :: proc(fz: ^Fuzz) -> fs.Dev {
	return {ctx = &fz.vxfs_img, read = vd_read, write = vd_write, barrier = vd_barrier, size = u64(len(fz.vxfs_img.bytes))}
}

vxfs_make :: proc(t: ^testing.T, fz: ^Fuzz) -> bool {
	fz.vxfs_img.bytes = make([]u8, 512 * fs.BLKSZ)
	v := &fz.vol
	testing.expect_value(t, fs.mkfs(v, vdev(fz), mem(fz), 256, 1, {"home"}, 0o755, 0, 0, 1), vx.Status.Ok) or_return
	defer {
		fs.unmount(v)
		let_go(fz)
	}
	br, st := fs.branch_open(v, "home")
	testing.expect_value(t, st, vx.Status.Ok) or_return
	root: fs.File
	root, st = fs.root(v, &br.t)
	testing.expect_value(t, st, vx.Status.Ok) or_return
	for &b, i in fz.buf {
		b = u8(i * 7)
	}
	ok := true
	f, d: fs.File
	f, st = fs.create(v, &br.t, &root, "small", 0o644, 0, 0, 1)
	ok = st == .Ok && fs.write(v, &br.t, &f, 0, transmute([]u8)string("inline bytes"), 1, 0) == .Ok
	if ok {
		d, st = fs.create(v, &br.t, &root, "dir", fs.DMDIR | 0o755, 0, 0, 1)
		ok = st == .Ok
	}
	if ok {
		f, st = fs.create(v, &br.t, &d, "large", 0o644, 0, 0, 1)
		ok = st == .Ok && fs.write(v, &br.t, &f, 0, fz.buf[:], 1, 0) == .Ok && fs.write(v, &br.t, &f, 200_000, fz.buf[:100], 1, 0) == .Ok // sparse
	}
	if ok {
		_, st = fs.symlink(v, &br.t, &d, "link", "../small", 0, 0, 1)
		ok = st == .Ok
	}
	for i := 0; ok && i < 40; i += 1 { // a directory of many, past a leaf
		name := fmt.tprintf("n%02d", i)
		f, st = fs.create(v, &br.t, &d, name, 0o644, 0, 0, 1)
		ok = st == .Ok && fs.write(v, &br.t, &f, 0, transmute([]u8)name, 1, 0) == .Ok
	}
	testing.expect(t, ok, "vx-fs: the image's tree could not be made") or_return
	testing.expect_value(t, fs.commit(v), vx.Status.Ok) or_return
	return true
}

vxfs_try :: proc(fz: ^Fuzz) {
	v := &fz.vol
	st := fs.mount(v, vdev(fz), mem(fz), 64)
	out(fz, "mount %d\n", i32(st))
	if st != .Ok {
		let_go(fz) // a mount that failed let go of all it took (6d10's find)
		return
	}
	defer {
		fs.unmount(v)
		let_go(fz)
	}
	br: ^fs.Branch
	br, st = fs.branch_open(v, "home")
	out(fz, "branch %d\n", i32(st))
	if st != .Ok {
		return
	}
	top, seen := 0, 0
	fz.fs_stack[top], st = fs.root(v, &br.t)
	out(fz, "root %d\n", i32(st))
	if st == .Ok {
		top += 1
	}
	for top > 0 && seen < MAX_NODES {
		seen += 1
		top -= 1
		dir := fz.fs_stack[top]
		// The names first, at most 64, as upstream's callback takes them.
		names: [64][fs.NAMEMAX]u8
		lens: [64]int
		n := 0
		it: fs.Dir_Iter
		st = fs.readdir_start(&it, v, &br.t, &dir)
		if st == .Ok {
			for e in fs.readdir_next(&it) {
				if n == 64 || len(e.name) > fs.NAMEMAX {
					break
				}
				lens[n] = copy(names[n][:], e.name)
				n += 1
			}
			st = fs.readdir_end(&it)
		}
		out(fz, "dir %d %d\n", i32(st), n)
		if st != .Ok {
			continue
		}
		for i in 0 ..< n {
			name := string(names[i][:lens[i]])
			f, wst := fs.walk(v, &br.t, &dir, name)
			out(fz, "walk %s %d\n", name, i32(wst))
			if wst != .Ok {
				continue
			}
			if fs.is_dir(&f) {
				out(fz, "sub %d\n", top < MAX_NODES ? 1 : 0)
				if top < MAX_NODES {
					fz.fs_stack[top] = f
					top += 1
				}
			} else {
				got, rst := fs.read(v, &br.t, &f, 0, fz.buf[:])
				if rst == .Ok {
					out(fz, "read 0 %d %016x\n", got, digest(fz.buf[:got]))
				} else {
					out(fz, "read %d\n", i32(rst))
				}
			}
		}
	}
	root: fs.File
	root, st = fs.root(v, &br.t)
	out(fz, "root %d\n", i32(st))
	if st == .Ok {
		f: fs.File
		f, st = fs.create(v, &br.t, &root, "fuzzed", 0o644, 0, 0, 2)
		out(fz, "create %d\n", i32(st))
		if st == .Ok {
			out(fz, "write %d\n", i32(fs.write(v, &br.t, &f, 0, fz.buf[:5000], 2, 0)))
		}
	}
	out(fz, "commit %d\n", i32(fs.commit(v)))
	c: fs.Check
	st = fs.check_volume(v, &c)
	out(fz, "check %d %d %d %d %d %d %d %d %d %d %d %d %d\n", i32(st), c.used, c.trees, c.other, c.leaked, c.unallocated, c.shared, c.damaged, c.bad_snaps, c.bad_lists, c.snapshots, c.labels, c.dlists)
}

// --- FAT ---

fd_read :: proc "contextless" (ctx: rawptr, off: u64, b: []u8) -> bool {
	m := (^Image)(ctx)
	if off > u64(len(m.bytes)) || u64(len(b)) > u64(len(m.bytes)) - off {
		return false
	}
	copy(b, m.bytes[off:][:len(b)])
	return true
}

fd_write :: proc "contextless" (ctx: rawptr, off: u64, b: []u8) -> bool {
	m := (^Image)(ctx)
	if off > u64(len(m.bytes)) || u64(len(b)) > u64(len(m.bytes)) - off {
		return false
	}
	if m.saving {
		save(m, int(off), len(b))
	}
	copy(m.bytes[off:][:len(b)], b)
	return true
}

fd_flush :: proc "contextless" (_: rawptr) -> bool {
	return true
}

fdev :: proc(m: ^Image) -> fat.Dev {
	return {ctx = m, read = fd_read, write = fd_write, flush = fd_flush}
}

fat_make :: proc(t: ^testing.T, fz: ^Fuzz, m: ^Image) -> bool {
	m.bytes = make([]u8, 70_000 * 512)
	v := &fz.fat_vol
	testing.expect_value(t, fat.format(fdev(m), 70_000, 0, "FUZZ", 1), vx.Status.Ok) or_return
	testing.expect_value(t, fat.mount(v, fdev(m)), vx.Status.Ok) or_return
	root := fat.root_entry(v)
	f, d: fat.Entry
	ok := fat.create(v, &root, "A long file name.txt", {}, &f) == .Ok && fat.write(v, &f, 0, fz.buf[:]) == .Ok
	ok = ok && fat.create(v, &root, "DIR", {.Directory}, &d) == .Ok
	for i := 0; ok && i < 40; i += 1 { // a directory past a cluster
		name := fmt.tprintf("entry number %02d", i)
		ok = fat.create(v, &d, name, {}, &f) == .Ok && fat.write(v, &f, 0, transmute([]u8)name[:3]) == .Ok
	}
	testing.expect(t, ok, "FAT32: the image's tree could not be made") or_return
	testing.expect_value(t, fat.flush(v), vx.Status.Ok) or_return
	return true
}

fat_try :: proc(fz: ^Fuzz, m: ^Image) {
	v := &fz.fat_vol
	st := fat.mount(v, fdev(m))
	out(fz, "mount %d\n", i32(st))
	if st != .Ok {
		return
	}
	top, seen := 0, 0
	fz.fat_stack[top] = fat.root_entry(v)
	top += 1
	for top > 0 && seen < MAX_NODES {
		seen += 1
		top -= 1
		dir := fz.fat_stack[top]
		it: fat.Iter
		it, st = fat.open_dir(v, &dir)
		out(fz, "open %d\n", i32(st))
		if st != .Ok {
			continue
		}
		e: fat.Entry
		i := 0
		for ; i < 256; i += 1 {
			if st = fat.dir_next(v, &it, &e); st != .Ok {
				break
			}
			_, ps := fat.parent(v, e.node)
			name := fat.entry_name(&e)
			out(fz, "ent %s %d %d parent %d\n", name, transmute(u8)e.attr, e.size, i32(ps))
			if .Directory in e.attr {
				if top < MAX_NODES && name != "." && name != ".." {
					fz.fat_stack[top] = e
					top += 1
				}
				continue
			}
			count, rst := fat.read(v, &e, 0, fz.buf[:])
			if rst == .Ok {
				out(fz, "read 0 %d %016x\n", count, digest(fz.buf[:count]))
			} else {
				out(fz, "read %d\n", i32(rst))
			}
			again: fat.Entry
			out(fz, "lookup %d\n", i32(fat.lookup(v, &dir, fat.entry_name(&e), &again)))
		}
		if i < 256 {
			out(fz, "end %d\n", i32(st))
		}
	}
	root := fat.root_entry(v)
	f: fat.Entry
	st = fat.create(v, &root, "fuzzed", {}, &f)
	out(fz, "create %d\n", i32(st))
	if st == .Ok {
		out(fz, "write %d\n", i32(fat.write(v, &f, 0, fz.buf[:5000])))
	}
	out(fz, "flush %d\n", i32(fat.flush(v)))
}

// --- ISO 9660 ---

id_read :: proc "contextless" (ctx: rawptr, off: u64, b: []u8) -> bool {
	m := (^Image)(ctx)
	if off > u64(len(m.bytes)) || u64(len(b)) > u64(len(m.bytes)) - off {
		return false
	}
	copy(b, m.bytes[off:][:len(b)])
	return true
}

iso_try :: proc(fz: ^Fuzz, avoid: iso.Kinds) {
	v := &fz.iso_vol
	st := iso.mount(v, {ctx = &fz.iso_img, read = id_read}, avoid)
	out(fz, "mount %d\n", i32(st))
	if st != .Ok {
		return
	}
	top, seen := 0, 0
	iso.root_entry(v, &fz.iso_stack[top])
	top += 1
	for top > 0 && seen < MAX_NODES {
		seen += 1
		top -= 1
		dir := fz.iso_stack[top]
		it: iso.Iter
		it, st = iso.open_dir(&dir)
		out(fz, "open %d\n", i32(st))
		if st != .Ok {
			continue
		}
		e: iso.Entry
		i := 0
		for ; i < 256; i += 1 {
			if st = iso.dir_next(v, &it, &e); st != .Ok {
				break
			}
			_, ps := iso.parent(v, e.node)
			out(fz, "ent %s %d %d parent %d\n", iso.entry_name(&e), e.dir ? 1 : 0, e.size, i32(ps))
			if e.dir {
				if top < MAX_NODES {
					fz.iso_stack[top] = e
					top += 1
				}
				continue
			}
			count, rst := iso.read(v, &e, 0, fz.buf[:])
			if rst == .Ok {
				out(fz, "read 0 %d %016x\n", count, digest(fz.buf[:count]))
			} else {
				out(fz, "read %d\n", i32(rst))
			}
			again: iso.Entry
			out(fz, "lookup %d\n", i32(iso.lookup(v, &dir, iso.entry_name(&e), &again)))
		}
		if i < 256 {
			out(fz, "end %d\n", i32(st))
		}
	}
}

// --- The target ---

load_image :: proc(t: ^testing.T, m: ^Image, path: string) -> bool {
	data, err := os.read_entire_file(path, context.allocator)
	if !testing.expectf(t, err == nil, "no %s (./build check makes it before the host suites): %v", path, err) {
		return false
	}
	m.bytes = data
	return true
}

make_all :: proc(t: ^testing.T, fz: ^Fuzz) -> bool {
	vxfs_make(t, fz) or_return
	find_hot(&fz.vxfs_img)
	testing.expect(t, fatfix.fixtures(), "mtools could not make the FAT fixtures") or_return
	load_image(t, &fz.fat_img[0], fatfix.FIXTURES + "/fat12.img") or_return
	load_image(t, &fz.fat_img[1], fatfix.FIXTURES + "/fat16.img") or_return
	fat_make(t, fz, &fz.fat_img[2]) or_return
	load_image(t, &fz.iso_img, "out/host/test.iso") or_return
	for &m in fz.fat_img {
		find_hot(&m)
	}
	find_hot(&fz.iso_img)
	return true
}

one :: proc(fz: ^Fuzz, data: []u8) {
	if len(data) < 1 {
		return
	}
	which := data[0] % 7
	out(fz, "in %d\n", which)
	m := &fz.iso_img
	if which == 0 {
		m = &fz.vxfs_img
	} else if which <= 3 {
		m = &fz.fat_img[which - 1]
	}
	edit(m, data[1:])
	switch which {
	case 0:
		vxfs_try(fz)
	case 1 ..= 3:
		fat_try(fz, m)
	case:
		AVOID := [3]iso.Kinds{{}, {.Rock}, {.Rock, .Joliet}} // each way of reading it
		iso_try(fz, AVOID[which - 4])
	}
	put_back(fz, m)
}

// splitmix64, as the oracle's driver has it.
Rng :: struct {
	s: u64,
}

rnd :: proc(r: ^Rng) -> u64 {
	r.s += 0x9E3779B97F4A7C15
	z := r.s
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

@(test)
test_mount_fuzz :: proc(t: ^testing.T) {
	fz := new(Fuzz)
	defer free(fz)
	fz_global = fz
	fz.t = t
	fz.undos = make([dynamic]Undo, 0, 1 << 16)
	defer delete(fz.undos)
	fz.out = strings.builder_make()
	defer strings.builder_destroy(&fz.out)
	defer {
		delete(fz.vxfs_img.bytes)
		delete(fz.vxfs_img.hot)
		for m in fz.fat_img {
			delete(m.bytes)
			delete(m.hot)
		}
		delete(fz.iso_img.bytes)
		delete(fz.iso_img.hot)
	}
	if !make_all(t, fz) {
		return
	}
	Case :: struct {
		name:   string,
		digest: u64,
	}
	// The transcripts' digests from upstream's target, as above.
	cases := []Case {
		{"fat12", 0x071ca1f04ba1548e}, // FAT12 as mtools made it, unedited
		{"fat16", 0x111f982864ced045}, // FAT16
		{"fat32", 0x1c434ff9fb2c367e}, // FAT32 as fat.format and the writer made it
		{"iso-joliet", 0x00a79c32a5a4fe09}, // ISO 9660 read without Rock Ridge: Joliet's names
		{"iso-plain", 0xcd5966ddae4b37ac}, // and without either: ISO 9660's own
		{"iso-rock", 0x12901261a555711c}, // Rock Ridge's
		{"vxfs", 0x004cffeb545c85cb}, // vx-fs, unedited
		{"vxfs-mount-fails-leak", 0x550354f8002e336f}, // a mount that fails: everything it allocated let go (6d10's find)
	}
	testing.expect_value(t, len(CORPUS), len(cases))
	corp: [8][]u8
	for c, i in cases {
		for f in CORPUS {
			if f.name == c.name {
				corp[i] = f.data
			}
		}
		if !testing.expectf(t, corp[i] != nil, "corpus file %s is missing", c.name) {
			continue
		}
		strings.builder_reset(&fz.out)
		one(fz, corp[i])
		got := digest(fz.out.buf[:])
		testing.expectf(t, got == c.digest, "%s: transcript %016x, upstream's %016x:\n%s", c.name, got, c.digest, strings.to_string(fz.out))
	}
	// A corpus file, its edits kept, and one to four random edits after it.
	strings.builder_reset(&fz.out)
	input: [256]u8
	for i in 0 ..< u64(MUTATED) {
		r := Rng{i + 1}
		n := copy(input[:], corp[i % 8])
		edits := 1 + rnd(&r) % 4
		for _ in 0 ..< edits {
			l := 5 + (rnd(&r) % 16 + 1)
			for _ in 0 ..< l {
				input[n] = u8(rnd(&r))
				n += 1
			}
		}
		one(fz, input[:n])
	}
	got := digest(fz.out.buf[:])
	testing.expectf(t, got == 0x7e12d622c40d4cf6, "mutated: transcript %016x (%d bytes), upstream's 7e12d622c40d4cf6", got, len(fz.out.buf))
	testing.expect_value(t, len(fz.out.buf), 5051858)
}
