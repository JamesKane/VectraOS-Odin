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
build_image :: proc(a: ^Arch, mode: Mode, image: string, cmdline := "") -> bool {
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

	seed := FNV_OFFSET
	seed = fnv(seed, read_file(loader) or_return)
	seed = fnv(seed, read_file(kernel) or_return)
	seed = fnv(seed, read_file(config) or_return)
	for p in PROGRAMS {
		if p.place == .Module {
			seed = fnv(seed, read_file(program_path(a, mode, p.name)) or_return)
		}
	}

	esp := fmt.tprintf("%s.esp", image)
	write_file(esp, string(make([]u8, ESP_BYTES, context.temp_allocator))) or_return
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
	mtools(MCOPY, esp, config, "::/boot/limine/limine.conf") or_return
	write_gpt_disk(image, esp, seed) or_return
	_ = os.remove(esp)
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

@(private="file")
write_gpt_disk :: proc(path, esp_path: string, seed: u64) -> bool {
	esp_sectors := u64(ESP_BYTES / SECTOR)
	total := ESP_LBA + esp_sectors + 2048
	last := total - 1

	disk_guid, part_guid: [16]u8
	derived_guid(disk_guid[:], seed, "disk")
	derived_guid(part_guid[:], seed, "esp")

	entries := make([]u8, GPT_TABLE_BYTES, context.temp_allocator)
	copy(entries, ESP_TYPE[:])
	copy(entries[16:], part_guid[:])
	put64(entries[32:], ESP_LBA)
	put64(entries[40:], ESP_LBA + esp_sectors - 1)
	for c, i in "EFI system partition" {
		put16(entries[56 + 2 * i:], u16(c))
	}
	entries_crc := hash.crc32(entries)

	disk := make([]u8, total * SECTOR, context.temp_allocator)

	// A protective MBR: one partition of type 0xEE covering the disk.
	pe := disk[446:]
	pe[2] = 0x02 // CHS of LBA 1
	pe[4] = 0xee
	pe[5], pe[6], pe[7] = 0xff, 0xff, 0xff
	put32(pe[8:], 1)
	put32(pe[12:], last > 0xffffffff ? 0xffffffff : u32(last))
	disk[510], disk[511] = 0x55, 0xaa

	gpt_header(disk[SECTOR:][:SECTOR], 1, last, 2, last, disk_guid[:], entries_crc)
	copy(disk[2 * SECTOR:], entries)
	copy(disk[(last - 32) * SECTOR:], entries)
	gpt_header(disk[last * SECTOR:][:SECTOR], last, 1, last - 32, last, disk_guid[:], entries_crc)

	esp := read_file(esp_path) or_return
	if len(esp) != ESP_BYTES {
		fmt.eprintfln("build: %s is %d bytes, not %d", esp_path, len(esp), ESP_BYTES)
		return false
	}
	copy(disk[ESP_LBA * SECTOR:], esp)
	return write_file(path, string(disk))
}
