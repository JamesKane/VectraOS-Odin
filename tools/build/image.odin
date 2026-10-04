package build

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"

// The disk image: a GPT disk holding one EFI system partition, FAT32, made
// with mtools and wrapped by this file's GPT writer. Everything on the disk
// decides its GUIDs and FAT serial number, and every timestamp is
// SOURCE_DATE_EPOCH, so one commit always gives the same image.

SECTOR :: 512
ESP_BYTES :: 64 << 20
ESP_LBA :: 2048 // 1 MiB in, as partitioning tools align it
GPT_ENTRIES :: 128

// C12A7328-F81F-11D2-BA4B-00A0C93EC93B, as stored on disk.
ESP_TYPE :: [16]u8{0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b}

// The protective MBR in LBA 0 (UEFI 2.10, 5.2.3).
Mbr :: struct #packed {
	boot:       [446]u8,
	partitions: [4]Mbr_Partition,
	signature:  [2]u8,
}
#assert(size_of(Mbr) == SECTOR)

Mbr_Partition :: struct #packed {
	status:    u8,
	chs_first: [3]u8,
	type:      u8,
	chs_last:  [3]u8,
	first_lba: u32le,
	sectors:   u32le,
}
#assert(size_of(Mbr_Partition) == 16)

// The GPT header, at LBA 1 and again in the disk's last LBA (5.3.2).
Gpt_Header :: struct #packed {
	signature:    [8]u8,
	revision:     u32le,
	header_size:  u32le,
	header_crc:   u32le, // over the header, with this field zero
	_:            u32le,
	my_lba:       u64le,
	alt_lba:      u64le,
	first_usable: u64le,
	last_usable:  u64le,
	disk_guid:    [16]u8,
	entries_lba:  u64le,
	entry_count:  u32le,
	entry_size:   u32le,
	entries_crc:  u32le,
}
#assert(size_of(Gpt_Header) == 92)

Gpt_Entry :: struct #packed {
	type_guid:  [16]u8,
	part_guid:  [16]u8,
	first_lba:  u64le,
	last_lba:   u64le,
	attributes: u64le,
	name:       [36]u16le, // UTF-16
}
#assert(size_of(Gpt_Entry) == 128)

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

// A GUID derived from the image's inputs.
@(private="file")
derived_guid :: proc(seed: u64, what: string) -> [16]u8 {
	x := fnv(seed, what)
	y := fnv(x, what)
	g := transmute([16]u8)[2]u64le{u64le(x), u64le(y)}
	g[7] = g[7] & 0x0f | 0x40 // version 4 layout
	g[8] = g[8] & 0x3f | 0x80 // RFC 4122 variant
	return g
}

@(private="file")
gpt_header :: proc(my_lba, alt_lba, entries_lba, last_lba: u64, disk_guid: [16]u8, entries_crc: u32) -> Gpt_Header {
	h := Gpt_Header {
		signature    = "EFI PART",
		revision     = 0x00010000,
		header_size  = size_of(Gpt_Header),
		my_lba       = u64le(my_lba),
		alt_lba      = u64le(alt_lba),
		first_usable = 34,
		last_usable  = u64le(last_lba - 33),
		disk_guid    = disk_guid,
		entries_lba  = u64le(entries_lba),
		entry_count  = GPT_ENTRIES,
		entry_size   = size_of(Gpt_Entry),
		entries_crc  = u32le(entries_crc),
	}
	h.header_crc = u32le(hash.crc32(slice.bytes_from_ptr(&h, size_of(h))))
	return h
}

// A file of size bytes, all zero and sparse where the file system allows,
// open for writing.
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

	disk_guid := derived_guid(seed, "disk")

	entries: [GPT_ENTRIES]Gpt_Entry
	entries[0] = {
		type_guid = ESP_TYPE,
		part_guid = derived_guid(seed, "esp"),
		first_lba = ESP_LBA,
		last_lba  = u64le(ESP_LBA + esp_sectors - 1),
	}
	for c, i in "EFI system partition" {
		entries[0].name[i] = u16le(c)
	}
	entries_crc := hash.crc32(slice.to_bytes(entries[:]))

	// A protective MBR: one partition of type 0xEE covering the disk.
	mbr := Mbr {
		partitions = {
			0 = {
				chs_first = {0, 0x02, 0}, // LBA 1
				type = 0xee,
				chs_last = {0xff, 0xff, 0xff},
				first_lba = 1,
				sectors = u32le(min(last, 0xffffffff)),
			},
		},
		signature  = {0x55, 0xaa},
	}
	primary := gpt_header(1, last, 2, last, disk_guid, entries_crc)
	backup := gpt_header(last, 1, last - 32, last, disk_guid, entries_crc)

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
	write_at(disk, path, slice.bytes_from_ptr(&mbr, size_of(mbr)), 0) or_return
	write_at(disk, path, slice.bytes_from_ptr(&primary, size_of(primary)), SECTOR) or_return
	write_at(disk, path, slice.to_bytes(entries[:]), 2 * SECTOR) or_return
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
	write_at(disk, path, slice.to_bytes(entries[:]), i64(last - 32) * SECTOR) or_return
	write_at(disk, path, slice.bytes_from_ptr(&backup, size_of(backup)), i64(last) * SECTOR) or_return
	return true
}
