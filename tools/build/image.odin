package build

import "core:fmt"
import "core:hash"
import "core:os"

// The disk image: a GPT disk holding one EFI system partition, FAT32, made
// with mtools and wrapped by this file's GPT writer. Everything on the disk
// decides its GUIDs and FAT serial number, and every timestamp is
// SOURCE_DATE_EPOCH, so one commit always gives the same image.

SECTOR :: 512
ESP_BYTES :: 64 << 20
ESP_LBA :: 2048 // 1 MiB in, as partitioning tools align it
GPT_ENTRIES :: 128
GPT_TABLE_BYTES :: GPT_ENTRIES * 128

// C12A7328-F81F-11D2-BA4B-00A0C93EC93B, as stored on disk.
ESP_TYPE := [16]u8{0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b}

image_path :: proc(a: ^Arch, mode: Mode) -> string {
	return fmt.tprintf("%s/vectra-%s.img", out_dir(a, mode), a.name)
}

// Builds the kernel and the loader, then the image. cmdline, if set, is
// added to limine.conf.
build_image :: proc(a: ^Arch, mode: Mode, image: string, cmdline := "", with := "") -> bool {
	limine := port_load("limine") or_return
	loader := build_port_target(&limine, a.limine) or_return
	kernel := build_kernel(a, mode) or_return
	build_programs(a, mode) or_return

	config := "boot/limine.conf"
	conf_text := read_file(config) or_return
	if cmdline != "" {
		config = fmt.tprintf("%s.conf", image)
		write_file(config, fmt.tprintf("%s    cmdline: %s\n", conf_text, cmdline)) or_return
	}

	bootfs := fmt.tprintf("%s.bootfs.tar", image)
	make_bootfs(a, mode, bootfs, with) or_return

	seed := FNV_OFFSET
	seed = fnv(seed, read_file(bootfs) or_return)
	seed = fnv(seed, read_file(loader) or_return)
	seed = fnv(seed, read_file(kernel) or_return)
	seed = fnv(seed, read_file(config) or_return)
	for p in PROGRAMS {
		if p.place == .Module {
			seed = fnv(seed, read_file(program_path(a, mode, p.name)) or_return)
		}
	}

	esp := fmt.tprintf("%s.esp", image)
	esp_file := create_sized(esp, ESP_BYTES) or_return
	os.close(esp_file)
	fmt.eprintfln("  IMG   %s", image)
	serial := fmt.tprintf("%08x", u32(seed >> 32))
	mtools(MFORMAT, esp, "-F", "-N", serial, "-v", "VECTRA", "::") or_return
	mtools(MMD, esp, "::/EFI", "::/EFI/BOOT", "::/boot", "::/boot/vx", "::/boot/limine") or_return
	mtools(MCOPY, esp, loader, fmt.tprintf("::/EFI/BOOT/%s", a.loader)) or_return
	mtools(MCOPY, esp, kernel, "::/boot/vx/kernel.elf") or_return
	for p in PROGRAMS {
		if p.place == .Module {
			mtools(MCOPY, esp, program_path(a, mode, p.name), fmt.tprintf("::/boot/vx/%s", p.name)) or_return
		}
	}
	mtools(MCOPY, esp, bootfs, "::/boot/vx/bootfs.tar") or_return
	mtools(MCOPY, esp, config, "::/boot/limine/limine.conf") or_return
	write_gpt_disk(image, esp, seed) or_return
	_ = os.remove(esp)
	_ = os.remove(bootfs)
	return true
}

@(private="file")
mtools :: proc(tool, image: string, args: ..string) -> bool {
	c := cmd_make(tool, "-i", image)
	append(&c, ..args)
	return run(c[:])
}

@(private="file")
put16 :: proc(p: []u8, v: u16) {
	for i in 0 ..< 2 {
		p[i] = u8(v >> (8 * uint(i)))
	}
}

@(private="file")
put32 :: proc(p: []u8, v: u32) {
	for i in 0 ..< 4 {
		p[i] = u8(v >> (8 * uint(i)))
	}
}

@(private="file")
put64 :: proc(p: []u8, v: u64) {
	for i in 0 ..< 8 {
		p[i] = u8(v >> (8 * uint(i)))
	}
}

// A GUID derived from the image's inputs.
@(private="file")
derived_guid :: proc(out: []u8, seed: u64, what: string) {
	x := fnv(seed, what)
	y := fnv(x, what)
	put64(out, x)
	put64(out[8:], y)
	out[7] = out[7] & 0x0f | 0x40 // version 4 layout
	out[8] = out[8] & 0x3f | 0x80 // RFC 4122 variant
}

@(private="file")
gpt_header :: proc(h: []u8, my_lba, alt_lba, entries_lba, last_lba: u64, disk_guid: []u8, entries_crc: u32) {
	copy(h, "EFI PART")
	put32(h[8:], 0x00010000)
	put32(h[12:], 92)
	put64(h[24:], my_lba)
	put64(h[32:], alt_lba)
	put64(h[40:], 34) // first usable LBA
	put64(h[48:], last_lba - 33) // last usable LBA
	copy(h[56:], disk_guid)
	put64(h[72:], entries_lba)
	put32(h[80:], GPT_ENTRIES)
	put32(h[84:], 128)
	put32(h[88:], entries_crc)
	put32(h[16:], hash.crc32(h[:92]))
}

// A file of size bytes, all zero and sparse where the file system allows, open for
// writing.
@(private="file")
create_sized :: proc(path: string, size: i64) -> (f: ^os.File, ok: bool) {
	err: os.Error
	f, err = os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Read_All + {.Write_User})
	if err != nil {
		fmt.eprintfln("build: cannot write %s: %v", path, err)
		return nil, false
	}
	if err = os.truncate(f, size); err != nil {
		fmt.eprintfln("build: cannot size %s: %v", path, err)
		os.close(f)
		return nil, false
	}
	return f, true
}

@(private="file")
write_at :: proc(f: ^os.File, path: string, data: []u8, offset: i64) -> bool {
	if n, err := os.write_at(f, data, offset); err != nil || n != len(data) {
		fmt.eprintfln("build: cannot write %s: %v", path, err)
		return false
	}
	return true
}

// Writes the disk a piece at a time: the zeros between the pieces are the
// sized file's, so nothing the size of the disk is ever in memory.
@(private="file")
write_gpt_disk :: proc(path, esp_path: string, seed: u64) -> bool {
	esp_sectors := u64(ESP_BYTES / SECTOR)
	total := ESP_LBA + esp_sectors + 2048
	last := total - 1

	disk_guid, part_guid: [16]u8
	derived_guid(disk_guid[:], seed, "disk")
	derived_guid(part_guid[:], seed, "esp")

	entries: [GPT_TABLE_BYTES]u8
	copy(entries[:], ESP_TYPE[:])
	copy(entries[16:], part_guid[:])
	put64(entries[32:], ESP_LBA)
	put64(entries[40:], ESP_LBA + esp_sectors - 1)
	for c, i in "EFI system partition" {
		put16(entries[56 + 2 * i:], u16(c))
	}
	entries_crc := hash.crc32(entries[:])

	// A protective MBR: one partition of type 0xEE covering the disk.
	mbr: [SECTOR]u8
	pe := mbr[446:]
	pe[2] = 0x02 // CHS of LBA 1
	pe[4] = 0xee
	pe[5], pe[6], pe[7] = 0xff, 0xff, 0xff
	put32(pe[8:], 1)
	put32(pe[12:], last > 0xffffffff ? 0xffffffff : u32(last))
	mbr[510], mbr[511] = 0x55, 0xaa

	primary, backup: [SECTOR]u8
	gpt_header(primary[:], 1, last, 2, last, disk_guid[:], entries_crc)
	gpt_header(backup[:], last, 1, last - 32, last, disk_guid[:], entries_crc)

	esp, eerr := os.open(esp_path)
	if eerr != nil {
		fmt.eprintfln("build: cannot read %s: %v", esp_path, eerr)
		return false
	}
	defer os.close(esp)
	if size, _ := os.file_size(esp); size != ESP_BYTES {
		fmt.eprintfln("build: %s is %d bytes, not %d", esp_path, size, ESP_BYTES)
		return false
	}

	disk := create_sized(path, i64(total * SECTOR)) or_return
	defer os.close(disk)
	write_at(disk, path, mbr[:], 0) or_return
	write_at(disk, path, primary[:], SECTOR) or_return
	write_at(disk, path, entries[:], 2 * SECTOR) or_return
	buf: [64 * 1024]u8
	for off := i64(0); off < ESP_BYTES; {
		n, err := os.read(esp, buf[:])
		if err != nil || n <= 0 {
			fmt.eprintfln("build: cannot read %s: %v", esp_path, err)
			return false
		}
		write_at(disk, path, buf[:n], ESP_LBA * SECTOR + off) or_return
		off += i64(n)
	}
	write_at(disk, path, entries[:], i64(last - 32) * SECTOR) or_return
	write_at(disk, path, backup[:], i64(last) * SECTOR) or_return
	return true
}
