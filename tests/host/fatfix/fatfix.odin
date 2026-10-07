// The FAT images the host suites read (tests/host/fat, and tests/host/mount,
// upstream's mount_fuzz's FAT12 and FAT16), made by mtools (not by the code
// under test), as upstream's ./build makes them (its make_fat_fixtures) into
// out/host: fat12.img, fat16.img and fat32.img, each with the same tree:
// short and long names, UTF-8 (mtools writes none past the BMP;
// tests/host/fat's test_surrogates patches that in), a file of many clusters,
// a directory of many entries, a nested directory, a deleted entry, and a
// file whose time is known (2001-02-03 04:05:06, written with TZ=UTC since
// FAT keeps local time). Made once per run, into out/host/fat-fixtures; the
// suites run from the repository root, as ./build check runs them.
package fatfix

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

FIXTURES :: "out/host/fat-fixtures"
UNICODE_FILE :: "\xc3\x9cn\xc3\xaf" + "code file name with spaces.txt"

when ODIN_OS == .Darwin {
	MFORMAT :: "/opt/homebrew/bin/mformat"
	MCOPY :: "/opt/homebrew/bin/mcopy"
	MDEL :: "/opt/homebrew/bin/mdel"
} else {
	MFORMAT :: "/usr/bin/mformat"
	MCOPY :: "/usr/bin/mcopy"
	MDEL :: "/usr/bin/mdel"
}

@(private="file")
fixtures_once: sync.Once
@(private="file")
fixtures_ok: bool

// big.bin's bytes, here and in the images.
big_byte :: proc(i: int) -> u8 {
	return u8((i * 7 + i / 251) & 0xff)
}

@(private="file")
run :: proc(cmd: ..string) -> bool {
	state, _, stderr, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		fmt.eprintfln("fatfix: %v failed: %v %s", cmd, err, string(stderr))
		return false
	}
	return true
}

@(private="file")
put_file :: proc(path: string, data: []u8) -> bool {
	if err := os.write_entire_file(path, data); err != nil {
		fmt.eprintfln("fatfix: cannot write %s: %v", path, err)
		return false
	}
	return true
}

@(private="file")
make_fixtures :: proc() -> bool {
	src :: FIXTURES + "/src"
	_ = os.remove_all(FIXTURES)
	for d in ([]string{"A Long Directory Name/sub dir", "many"}) {
		if err := os.make_directory_all(fmt.tprintf("%s/%s", src, d)); err != nil {
			fmt.eprintfln("fatfix: cannot make %s/%s: %v", src, d, err)
			return false
		}
	}
	put_file(src + "/SHORT.TXT", transmute([]u8)string("hello\n")) or_return
	put_file(src + "/lower.txt", transmute([]u8)string("lower\n")) or_return
	put_file(src + "/A Long Directory Name/" + UNICODE_FILE, transmute([]u8)string("unicode\n")) or_return
	put_file(src + "/A Long Directory Name/sub dir/deep.txt", transmute([]u8)string("deep\n")) or_return
	put_file(src + "/gone.txt", transmute([]u8)string("gone\n")) or_return
	big := make([]u8, 300_000, context.temp_allocator)
	for &b, i in big {
		b = big_byte(i)
	}
	put_file(src + "/big.bin", big) or_return
	for i in 0 ..< 100 {
		put_file(fmt.tprintf("%s/many/f%03d.txt", src, i), transmute([]u8)fmt.tprintf("f%03d\n", i)) or_return
	}
	when_ := time.unix(981_173_106, 0) // 2001-02-03 04:05:06 UTC
	if err := os.change_times(src + "/SHORT.TXT", when_, when_); err != nil {
		fmt.eprintfln("fatfix: cannot set SHORT.TXT's time: %v", err)
		return false
	}
	_ = os.set_env("TZ", "UTC")
	_ = os.set_env("MTOOLS_SKIP_CHECK", "1")
	Kind :: struct {
		name, label: string,
		geometry:    []string,
	}
	kinds := []Kind {
		{"fat12", "SMALL", {"-T", "2880", "-h", "2", "-s", "18"}},
		{"fat16", "MIDDLE", {"-T", "65536", "-h", "64", "-s", "32"}},
		{"fat32", "LARGE", {"-T", "131072", "-h", "64", "-s", "32", "-F"}},
	}
	for k in kinds {
		img := fmt.tprintf("%s/%s.img", FIXTURES, k.name)
		format := make([dynamic]string, context.temp_allocator)
		append(&format, MFORMAT, "-C", "-i", img, "-v", k.label)
		append(&format, ..k.geometry)
		append(&format, "::")
		run(..format[:]) or_return
		copy_cmd := make([dynamic]string, context.temp_allocator)
		append(&copy_cmd, MCOPY, "-s", "-m", "-i", img)
		for top in ([]string{"SHORT.TXT", "lower.txt", "A Long Directory Name", "gone.txt", "big.bin", "many"}) {
			append(&copy_cmd, fmt.tprintf("%s/%s", src, top))
		}
		append(&copy_cmd, "::/")
		run(..copy_cmd[:]) or_return
		run(MDEL, "-i", img, "::/gone.txt") or_return
	}
	return true
}

// The fixtures' directory, made on first use in this process; ok is false
// if mtools failed.
fixtures :: proc() -> bool {
	sync.once_do(&fixtures_once, proc() {fixtures_ok = make_fixtures()})
	return fixtures_ok
}

// A fixture image, loaded; nil if it cannot be.
load :: proc(name: string) -> []u8 {
	if !fixtures() {
		return nil
	}
	data, err := os.read_entire_file(fmt.tprintf("%s/%s", FIXTURES, name), context.allocator)
	if err != nil {
		return nil
	}
	return data
}
