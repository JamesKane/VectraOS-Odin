// Added here: lib/iso against upstream's lib/vx-iso, compiled with clang on
// the host as an oracle (a dump program over iso.c at 08cc12f, whose 16 MiB
// limit on a directory's extent changes one damaged copy's listing). Both print
// every entry of the image, each of the three ways, recursively: its node,
// extent, flags, mode, time, link target, parent, the entry its node gives
// again, and its bytes' hash. upstream.txt is the oracle's listing of the
// whole image; FUZZ_HASH, of 1000 damaged copies of it (each with one to
// eight bytes of its descriptors, path tables, directories and continuation
// areas overwritten, chosen by xorshift64 as the oracle chose them), hashed
// (FNV-1a) one listing at a time: 417 different listings, the rest the
// undamaged one. The oracle ran under ASan and UBSan without a report.
package iso_test

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import vx "abi:vx"
import "vx:iso"

UPSTREAM :: #load("upstream.txt", string)
FUZZ_COUNT :: 1000
FUZZ_HASH :: u64(0xafb9053dc6d772a0)

// The oracle's limits: 300 entries a mount, four directories down.
@(private="file")
Lister :: struct {
	v:      ^iso.Vol,
	out:    strings.Builder,
	budget: int,
	data:   []u8,
}

@(private="file")
walk_all :: proc(l: ^Lister, d: ^iso.Entry, path: string, depth: int) {
	it, ost := iso.open_dir(d)
	if ost != .Ok {
		return
	}
	e := new(iso.Entry, context.temp_allocator)
	again := new(iso.Entry, context.temp_allocator)
	st: vx.Status
	for l.budget > 0 {
		st = iso.dir_next(l.v, &it, e)
		if st != .Ok {
			break
		}
		l.budget -= 1
		parent, pst := iso.parent(l.v, e.node)
		gst := iso.get(l.v, e.node, again)
		n, rst := iso.read(l.v, e, 0, l.data)
		sum: u32
		for b in l.data[:n] {
			sum = sum * 31 + u32(b)
		}
		fmt.sbprintf(
			&l.out,
			"%s%s|node=%x lba=%d size=%d dir=%d link=%d mode=%o mtime=%d target=%s parent=%d:%x get=%d:%s read=%d:%d:%08x\n",
			path,
			iso.entry_name(e),
			u64(e.node),
			e.lba,
			e.size,
			int(e.dir),
			int(e.link),
			e.mode,
			e.mtime,
			iso.entry_target(e),
			i32(pst),
			pst == .Ok ? u64(parent) : 0,
			i32(gst),
			gst == .Ok ? iso.entry_name(again) : "",
			i32(rst),
			n,
			sum,
		)
		if e.dir && depth < 4 {
			walk_all(l, e, fmt.tprintf("%s%s/", path, iso.entry_name(e)), depth + 1)
		}
	}
	if l.budget > 0 {
		fmt.sbprintf(&l.out, "%send=%d\n", path, i32(st))
	}
}

@(private="file")
list_image :: proc(l: ^Lister, image: ^[]u8) -> string {
	strings.builder_reset(&l.out)
	AVOIDS := [3]iso.Kinds{{}, {.Rock}, {.Rock, .Joliet}}
	for avoid in AVOIDS {
		st := iso.mount(l.v, dev_of(image), avoid)
		fmt.sbprintf(&l.out, "mount avoid=%d st=%d", transmute(u32)avoid, i32(st))
		if st != .Ok {
			fmt.sbprintln(&l.out)
			continue
		}
		fmt.sbprintfln(&l.out, " kind=%d root=%d/%d skip=%d sectors=%d label=%s", 1 << u32(l.v.kind), l.v.root_lba, l.v.root_len, l.v.susp_skip, l.v.sectors, iso.label(l.v))
		root := new(iso.Entry, context.temp_allocator)
		iso.root_entry(l.v, root)
		l.budget = 300
		walk_all(l, root, "/", 0)
	}
	return strings.to_string(l.out)
}

@(private="file")
lister_make :: proc() -> Lister {
	return Lister{v = new(iso.Vol), out = strings.builder_make(), data = make([]u8, 400_000)}
}

@(private="file")
lister_destroy :: proc(l: ^Lister) {
	free(l.v)
	strings.builder_destroy(&l.out)
	delete(l.data)
}

@(test)
test_upstream_listing :: proc(t: ^testing.T) {
	image := load_image(t)
	defer delete(image)
	l := lister_make()
	defer lister_destroy(&l)
	got := list_image(&l, &image)
	got_lines := strings.split_lines(got, context.temp_allocator)
	want_lines := strings.split_lines(UPSTREAM, context.temp_allocator)
	testing.expect_value(t, len(got_lines), len(want_lines))
	for i in 0 ..< min(len(got_lines), len(want_lines)) {
		testing.expect_value(t, got_lines[i], want_lines[i])
	}
}

@(private="file")
fnv :: proc(h: u64, b: []u8) -> u64 {
	h := h
	for c in b {
		h = (h ~ u64(c)) * 0x100000001b3
	}
	return h
}

@(test)
test_upstream_fuzz :: proc(t: ^testing.T) {
	m := load_image(t)
	defer delete(m)
	c := make([]u8, len(m))
	defer delete(c)
	l := lister_make()
	defer lister_destroy(&l)
	all := u64(0xcbf29ce484222325)
	for k in 0 ..< FUZZ_COUNT {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		copy(c, m)
		rng := u64(0x9e3779b97f4a7c15) * u64(k + 1)
		next :: proc(s: ^u64) -> u64 {
			s^ ~= s^ << 13
			s^ ~= s^ >> 7
			s^ ~= s^ << 17
			return s^
		}
		flips := 1 + int(next(&rng) % 8)
		for _ in 0 ..< flips {
			at := 16 * 2048 + next(&rng) % (31 * 2048)
			c[at] = u8(next(&rng))
		}
		h := fnv(0xcbf29ce484222325, transmute([]u8)list_image(&l, &c))
		for i in 0 ..< u64(8) {
			all = (all ~ ((h >> (8 * i)) & 0xff)) * 0x100000001b3
		}
	}
	testing.expect_value(t, all, FUZZ_HASH)
}
