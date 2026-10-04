// lib/gpt, ported from upstream's tests/host/gpt_test.c: tables made here,
// whole and damaged: the primary used when it is sound, the backup when the
// primary's header or entries fail, nothing when both do; partitions that
// overlap or leave the usable range refused; names from UTF-16; GUIDs from
// text; 4 KiB sectors. Added here: the bytes write makes, against upstream's
// C (see expected digests below).
package gpt_test

import sha "core:crypto/hash"
import "core:encoding/hex"
import "core:hash"
import "core:mem"
import "core:testing"
import vx "abi:vx"
import "vx:gpt"

Disk :: struct {
	bytes:   []u8,
	sector:  u32,
	sectors: u64,
	broken:  bool, // every read and write fails
}

disk_read :: proc "contextless" (ctx: rawptr, lba: u64, buf: []u8) -> bool {
	d := (^Disk)(ctx)
	count := u64(len(buf)) / u64(d.sector)
	if d.broken || lba >= d.sectors || count > d.sectors - lba {
		return false
	}
	copy(buf, d.bytes[lba * u64(d.sector):])
	return true
}

disk_write :: proc "contextless" (ctx: rawptr, lba: u64, buf: []u8) -> bool {
	d := (^Disk)(ctx)
	count := u64(len(buf)) / u64(d.sector)
	if d.broken || lba >= d.sectors || count > d.sectors - lba {
		return false
	}
	copy(d.bytes[lba * u64(d.sector):], buf)
	return true
}

put32 :: proc(p: []u8, v: u32) {
	for i in 0 ..< 4 {
		p[i] = u8(v >> (8 * uint(i)))
	}
}

put64 :: proc(p: []u8, v: u64) {
	for i in 0 ..< 8 {
		p[i] = u8(v >> (8 * uint(i)))
	}
}

Part :: struct {
	type:        string, // GUID text
	first, last: u64,
	name:        []u16, // UTF-16
}

ESP :: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
SYSTEM :: "7C6D3E1A-2B4F-4E0A-9C1D-56F2A8B90E35"

guid :: proc(t: ^testing.T, text: string, loc := #caller_location) -> gpt.Guid {
	g, ok := gpt.guid(text)
	testing.expect(t, ok, loc = loc)
	return g
}

// Writes a header for a table at lba whose entries are at entries.
header :: proc(d: ^Disk, lba, alt, entries: u64, ecrc: u32) {
	h := d.bytes[lba * u64(d.sector):][:d.sector]
	mem.zero_slice(h)
	copy(h, "EFI PART")
	put32(h[8:], 0x00010000)
	put32(h[12:], 92)
	put64(h[24:], lba)
	put64(h[32:], alt)
	esect := u64(128 * 128 / d.sector)
	put64(h[40:], 2 + esect)
	put64(h[48:], d.sectors - 2 - esect)
	for &b in h[56:72] {
		b = 0x5a
	}
	put64(h[72:], entries)
	put32(h[80:], 128)
	put32(h[84:], 128)
	put32(h[88:], ecrc)
	put32(h[16:], hash.crc32(h[:92]))
}

// A whole disk with these partitions, primary and backup.
make_disk :: proc(t: ^testing.T, sector: u32, sectors: u64, parts: []Part) -> Disk {
	d := Disk {
		bytes   = make([]u8, sectors * u64(sector)),
		sector  = sector,
		sectors = sectors,
	}
	entries: [128 * 128]u8
	for p, i in parts {
		e := entries[128 * i:]
		g := guid(t, p.type)
		copy(e, g[:])
		for &b in e[16:32] {
			b = u8(i + 1)
		}
		put64(e[32:], p.first)
		put64(e[40:], p.last)
		for u, k in p.name {
			e[56 + 2 * k], e[57 + 2 * k] = u8(u), u8(u >> 8)
		}
	}
	ecrc := hash.crc32(entries[:])
	esect := u64(len(entries)) / u64(sector)
	copy(d.bytes[2 * sector:], entries[:])
	copy(d.bytes[(sectors - 1 - esect) * u64(sector):], entries[:])
	header(&d, 1, sectors - 1, 2, ecrc)
	header(&d, sectors - 1, 1, sectors - 1 - esect, ecrc)
	return d
}

NAME_ESP := []u16{'E', 'F', 'I'}
NAME_VECTRA := []u16{'v', 'e', 'c', 't', 'r', 'a'}
NAME_ODD := []u16{0x00e9, 0x20ac, 0xd83d, 0xde00, 0xdc00} // é € 😀, a lone low surrogate

// write's tables, read back: as install writes them (an ESP and the system
// partition), on 512-byte and 4 KiB sectors; the primary damaged, the backup
// still there; an overlap refused before anything is written.
@(test)
test_write :: proc(t: ^testing.T) {
	Case :: struct {
		sector:  u32,
		sectors: u64,
	}
	for c in ([]Case{{512, 65536}, {4096, 8192}}) {
		d := Disk {
			bytes   = make([]u8, c.sectors * u64(c.sector)),
			sector  = c.sector,
			sectors = c.sectors,
		}
		defer delete(d.bytes)
		w, g := new(gpt.Gpt), new(gpt.Gpt)
		defer free(w)
		defer free(g)
		w.sector, w.sectors = c.sector, c.sectors
		w.disk_guid = 0x42
		first := u64(1 << 20 >> (c.sector == 512 ? 9 : 12)) // 1 MiB in
		esp := gpt.Part {
			type  = guid(t, ESP),
			guid  = 1,
			first = first,
			last  = first * 9 - 1, // 8 MiB
		}
		append(&esp.name, "EFI system partition")
		system := gpt.Part {
			type  = guid(t, SYSTEM),
			guid  = 2,
			first = first * 9,
			last  = c.sectors - 1 - 33,
		}
		append(&system.name, "vectra")
		if c.sector == 4096 {
			system.last = c.sectors - 1 - 5 // 128 entries are 4 sectors
		}
		append(&w.parts, esp, system)
		testing.expect_value(t, gpt.write(w, disk_write, &d), vx.Status.Ok)
		testing.expect_value(t, gpt.read(g, c.sector, c.sectors, disk_read, &d), vx.Status.Ok)
		testing.expect(t, !g.backup)
		testing.expect_value(t, len(g.parts), 2)
		testing.expect_value(t, g.parts[1].first, first * 9)
		testing.expect_value(t, string(g.parts[1].name[:]), "vectra")
		testing.expect_value(t, g.parts[1].type, w.parts[1].type)
		testing.expect_value(t, g.disk_guid, w.disk_guid)
		// The protective MBR.
		testing.expect_value(t, d.bytes[510], 0x55)
		testing.expect_value(t, d.bytes[511], 0xaa)
		testing.expect_value(t, d.bytes[446 + 4], 0xee)
		d.bytes[c.sector] ~= 1 // the primary's signature
		testing.expect_value(t, gpt.read(g, c.sector, c.sectors, disk_read, &d), vx.Status.Ok)
		testing.expect(t, g.backup)
		testing.expect_value(t, len(g.parts), 2)
		w.parts[1].first = w.parts[0].last // overlapping
		mem.zero_slice(d.bytes)
		testing.expect_value(t, gpt.write(w, disk_write, &d), vx.Status.Err_Invalid)
		testing.expect_value(t, gpt.read(g, c.sector, c.sectors, disk_read, &d), vx.Status.Err_Invalid) // nothing written
	}
}

// Added here: the disks write makes are byte for byte those of upstream's
// C (scratch oracle gpt_oracle.c: vx_gpt_write with these partitions, a
// name beyond ASCII, beyond the BMP and malformed, and attributes set).
@(test)
test_write_bytes :: proc(t: ^testing.T) {
	Case :: struct {
		sector:  u32,
		sectors: u64,
		sha256:  string,
	}
	cases := []Case {
		{512, 65536, "d033bf928b6c6286e1c737de0c2c0d45f9370e8b5d75e9b3374f6e58d9a86b2c"},
		{4096, 8192, "adbe68bac34e3182a13c6a76586368c3c70e1752958367d247e09f99d2f8cef9"},
	}
	for c in cases {
		d := Disk {
			bytes   = make([]u8, c.sectors * u64(c.sector)),
			sector  = c.sector,
			sectors = c.sectors,
		}
		defer delete(d.bytes)
		w := new(gpt.Gpt)
		defer free(w)
		w.sector, w.sectors = c.sector, c.sectors
		w.disk_guid = 0x42
		first := u64(1 << 20 >> (c.sector == 512 ? 9 : 12))
		esp := gpt.Part {
			type  = guid(t, ESP),
			guid  = 1,
			first = first,
			last  = first * 9 - 1,
		}
		append(&esp.name, "EFI system partition")
		system := gpt.Part {
			type       = guid(t, SYSTEM),
			guid       = 2,
			first      = first * 9,
			last       = c.sector == 4096 ? c.sectors - 1 - 5 : c.sectors - 1 - 33,
			attributes = 0x8000000000000001,
		}
		append(&system.name, "vectra \xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\xff")
		append(&w.parts, esp, system)
		testing.expect_value(t, gpt.write(w, disk_write, &d), vx.Status.Ok)
		digest := sha.hash_bytes(.SHA256, d.bytes, context.temp_allocator)
		testing.expectf(t, string(hex.encode(digest, context.temp_allocator)) == c.sha256, "%d-byte sectors: the disk differs from upstream's", c.sector)
	}
}

// Sound: the primary, its partitions as written.
@(test)
test_sound :: proc(t: ^testing.T) {
	g := new(gpt.Gpt)
	defer free(g)
	two := []Part{{ESP, 2048, 4095, NAME_ESP}, {SYSTEM, 4096, 8191, NAME_VECTRA}}
	d := make_disk(t, 512, 16384, two)
	defer delete(d.bytes)
	testing.expect_value(t, gpt.read(g, 512, d.sectors, disk_read, &d), vx.Status.Ok)
	testing.expect(t, !g.backup)
	testing.expect_value(t, len(g.parts), 2)
	esp, sys := guid(t, ESP), guid(t, SYSTEM)
	testing.expect_value(t, g.parts[0].type, esp)
	testing.expect_value(t, g.parts[0].first, 2048)
	testing.expect_value(t, g.parts[0].last, 4095)
	testing.expect_value(t, g.parts[1].type, sys)
	testing.expect_value(t, string(g.parts[1].name[:]), "vectra")
	testing.expect_value(t, string(g.parts[0].name[:]), "EFI")
	// As the disk stores the ESP's type GUID (upstream build.c's ESP_TYPE).
	ESP_ON_DISK :: gpt.Guid{0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b}
	testing.expect_value(t, esp, ESP_ON_DISK)

	// The primary's header damaged: the backup.
	d.bytes[512 + 40] ~= 1
	testing.expect_value(t, gpt.read(g, 512, d.sectors, disk_read, &d), vx.Status.Ok)
	testing.expect(t, g.backup)
	testing.expect_value(t, len(g.parts), 2)
	// Both damaged: nothing.
	d.bytes[(d.sectors - 1) * 512 + 40] ~= 1
	testing.expect_value(t, gpt.read(g, 512, d.sectors, disk_read, &d), vx.Status.Err_Invalid)
	testing.expect_value(t, len(g.parts), 0)
}

// The primary's entries damaged: the backup's.
@(test)
test_damaged_entries :: proc(t: ^testing.T) {
	g := new(gpt.Gpt)
	defer free(g)
	two := []Part{{ESP, 2048, 4095, NAME_ESP}, {SYSTEM, 4096, 8191, NAME_VECTRA}}
	d := make_disk(t, 512, 16384, two)
	defer delete(d.bytes)
	d.bytes[2 * 512 + 33] ~= 1
	testing.expect_value(t, gpt.read(g, 512, d.sectors, disk_read, &d), vx.Status.Ok)
	testing.expect(t, g.backup)
	// A header that says it is somewhere else is not the one there. (Upstream's
	// comment; what the case checks is a disk no read of which succeeds.)
	d.broken = true
	testing.expect_value(t, gpt.read(g, 512, d.sectors, disk_read, &d), vx.Status.Err_Io)
}

// Overlapping partitions, or one outside the usable range: refused.
@(test)
test_refused :: proc(t: ^testing.T) {
	g := new(gpt.Gpt)
	defer free(g)
	cases := [][]Part {
		{{ESP, 2048, 4095, nil}, {SYSTEM, 4000, 8191, nil}}, // overlapping
		{{ESP, 2048, 16383, nil}}, // past the usable range
		{{ESP, 10, 100, nil}}, // over the primary's entries
	}
	for parts, i in cases {
		d := make_disk(t, 512, 16384, parts)
		defer delete(d.bytes)
		st := gpt.read(g, 512, d.sectors, disk_read, &d)
		testing.expectf(t, st == .Err_Invalid, "case %d: got %v", i, st)
	}
}

// Names beyond ASCII, a lone surrogate as U+FFFD.
@(test)
test_names :: proc(t: ^testing.T) {
	g := new(gpt.Gpt)
	defer free(g)
	d := make_disk(t, 512, 16384, {{ESP, 2048, 4095, NAME_ODD}})
	defer delete(d.bytes)
	testing.expect_value(t, gpt.read(g, 512, d.sectors, disk_read, &d), vx.Status.Ok)
	testing.expect_value(t, string(g.parts[0].name[:]), "\xc3\xa9\xe2\x82\xac\xf0\x9f\x98\x80\xef\xbf\xbd")
}

// 4 KiB sectors.
@(test)
test_4k :: proc(t: ^testing.T) {
	g := new(gpt.Gpt)
	defer free(g)
	d := make_disk(t, 4096, 4096, {{SYSTEM, 256, 1023, NAME_VECTRA}})
	defer delete(d.bytes)
	testing.expect_value(t, gpt.read(g, 4096, d.sectors, disk_read, &d), vx.Status.Ok)
	testing.expect_value(t, len(g.parts), 1)
	testing.expect_value(t, g.parts[0].first, 256)
}

// GUID text that is not one.
@(test)
test_guid_text :: proc(t: ^testing.T) {
	for text in ([]string {
			"C12A7328F81F11D2BA4B00A0C93EC93B",
			"C12A7328-F81F-11D2-BA4B-00A0C93EC93",
			"G12A7328-F81F-11D2-BA4B-00A0C93EC93B",
			"C12A7328-F81F-11D2-BA4B+00A0C93EC93B",
		}) {
		_, ok := gpt.guid(text)
		testing.expectf(t, !ok, "%s taken as a GUID", text)
	}
}
