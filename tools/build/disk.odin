package build

import "core:fmt"
import "core:hash"
import "core:os"
import "core:slice"

// A scenario's second disk (disk=MIB), made fresh for each run, as
// upstream's build.c makes it: sparse zeros, with a signature in sector 0 so
// tests know it from the boot disk, and a GPT of two partitions, an EFI
// system partition of 8 MiB at 1 MiB and a VectraOS system volume of 32 MiB
// after it, each with a line naming it in its first sector (upstream's
// docs/proto/block.md §6). With volume=DIR, the system partition holds a
// vx-fs volume instead, its home branch DIR's tree, made by tools/vxfs
// (hosttools.odin's make_volume).

TEST_DISK_SIGNATURE :: "VectraOS block test disk"

// The VectraOS system volume type, 7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35, as stored on disk.
SYSTEM_TYPE :: [16]u8{0x1a, 0x3e, 0x6d, 0x7c, 0x4f, 0x2b, 0x0a, 0x4e, 0x9c, 0x1d, 0x56, 0xf2, 0xa8, 0xb9, 0x0e, 0x35}

// A scenario's second disk, at path: mib MiB, a GPT with the two test
// partitions; with home or store, the system partition a volume whose home
// and store branches are those directories' trees.
test_disk :: proc(path: string, mib: i64, home: string, store := "") -> bool {
	Test_Part :: struct {
		type:          [16]u8,
		first, count:  u64,
		name, marker:  string,
	}
	PARTS :: [2]Test_Part {
		{type = ESP_TYPE, first = 2048, count = 16384, name = "EFI system partition", marker = "partition esp\n"},
		{type = SYSTEM_TYPE, first = 18432, count = 65536, name = "vectra", marker = "partition vectra\n"},
	}
	parts := PARTS
	total := u64(mib) << 11
	last := total - 1
	if total < 18432 + 65536 + 2048 {
		fmt.eprintfln("build: disk=%d is too small for the test partitions", mib)
		return false
	}
	disk := create_sized(path, i64(total * SECTOR)) or_return
	defer os.close(disk)

	entries: [GPT_ENTRIES]Gpt_Entry
	for p, i in parts {
		e := &entries[i]
		e^ = {
			type_guid = p.type,
			part_guid = derived_guid(u64(i) + 1, "test partition"),
			first_lba = u64le(p.first),
			last_lba  = u64le(p.first + p.count - 1),
		}
		for c, k in p.name {
			e.name[k] = u16le(c)
		}
		if (home != "" || store != "") && i == 1 {
			continue // the volume goes there
		}
		write_at(disk, path, transmute([]u8)p.marker, i64(p.first * SECTOR)) or_return
	}
	if home != "" || store != "" { // the volume, made beside the disk and copied into the partition
		vol := fmt.tprintf("%s.vxfs", path)
		trees := [4]string{0 = store, 2 = home} // store, cfg, home, adm
		make_volume(vol, int(parts[1].count * SECTOR >> 20), trees) or_return
		copy_into(disk, path, vol, i64(parts[1].count * SECTOR), i64(parts[1].first * SECTOR)) or_return
	}
	disk_guid := derived_guid(0, "test disk")
	entries_crc := hash.crc32(slice.to_bytes(entries[:]))
	primary := gpt_header(1, last, 2, last, disk_guid, entries_crc)
	backup := gpt_header(last, 1, last - 32, last, disk_guid, entries_crc)
	// Sector 0: the signature in the boot code's place, and a protective MBR.
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
	copy(mbr.boot[:], TEST_DISK_SIGNATURE)
	write_at(disk, path, slice.bytes_from_ptr(&mbr, size_of(mbr)), 0) or_return
	write_at(disk, path, slice.bytes_from_ptr(&primary, size_of(primary)), SECTOR) or_return
	write_at(disk, path, slice.to_bytes(entries[:]), 2 * SECTOR) or_return
	write_at(disk, path, slice.to_bytes(entries[:]), i64(last - 32) * SECTOR) or_return
	return write_at(disk, path, slice.bytes_from_ptr(&backup, size_of(backup)), i64(last) * SECTOR)
}

// Copies the file at from, which must be size bytes, into f at offset, a
// piece at a time.
@(private="file")
copy_into :: proc(f: ^os.File, path, from: string, size, offset: i64) -> bool {
	src, err := os.open(from)
	if err != nil {
		fmt.eprintfln("build: cannot read %s: %v", from, err)
		return false
	}
	defer os.close(src)
	if got, _ := os.file_size(src); got != size {
		fmt.eprintfln("build: the volume %s is %d bytes, not the partition's %d", from, got, size)
		return false
	}
	buf: [64 * 1024]u8
	for off := i64(0); off < size; {
		n, rerr := os.read(src, buf[:])
		if rerr != nil || n <= 0 {
			fmt.eprintfln("build: cannot read %s: %v", from, rerr)
			return false
		}
		write_at(f, path, buf[:n], offset + off) or_return
		off += i64(n)
	}
	return true
}
